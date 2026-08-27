#import "BunnyFFmpegDecoder.h"
#import "StremioPlaybackCore.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Libavcodec/avcodec.h>
#import <Libavformat/avformat.h>
#import <Libavutil/avutil.h>
#import <Libavutil/channel_layout.h>
#import <Libavutil/dict.h>
#import <Libavutil/error.h>
#import <Libavutil/frame.h>
#import <Libavutil/hwcontext.h>
#import <Libavutil/imgutils.h>
#import <Libavutil/log.h>
#import <Libavutil/mathematics.h>
#import <Libavutil/pixdesc.h>
#import <Libavutil/pixfmt.h>
#import <Libavutil/rational.h>
#import <Libswresample/swresample.h>
#import <Libswscale/swscale.h>
#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import <stdint.h>
#import <stdlib.h>
#import <unistd.h>

NSString *const BunnyFFmpegDecoderErrorDomain = @"BunnyFFmpegDecoder";
NSString *const BunnyFFmpegDecoderSoftwareRetryKey = @"BunnyFFmpegDecoderSoftwareRetry";

static const NSTimeInterval BunnyDecoderMaximumQueueDuration = 2.0;
static const NSTimeInterval BunnyDecoderLateFrameTolerance = 0.100;
static const NSUInteger BunnyDecoderMaximumCompressedPacketCount = 8192;
static const NSInteger BunnyDecoderNoSelectionRequest = NSIntegerMin;
static void *BunnyDecoderQueueKey = &BunnyDecoderQueueKey;

static void BunnyFreeAudioPCMBlock(
    void *refCon,
    void *memoryBlock,
    size_t sizeInBytes
) {
    (void)refCon;
    (void)sizeInBytes;
    free(memoryBlock);
}

static void BunnyFreeBitmapPixels(void *info, const void *data, size_t size) {
    (void)info;
    (void)size;
    free((void *)data);
}

static BOOL BunnyIsBitmapSubtitleCodec(enum AVCodecID codecID) {
    return codecID == AV_CODEC_ID_HDMV_PGS_SUBTITLE
        || codecID == AV_CODEC_ID_DVD_SUBTITLE
        || codecID == AV_CODEC_ID_DVB_SUBTITLE
        || codecID == AV_CODEC_ID_XSUB;
}

static const size_t BunnyMaximumBitmapSubtitleBytes = 64 * 1024 * 1024;
static const unsigned int BunnyMaximumBitmapSubtitleParts = 64;

static BOOL BunnyIs4KDimensions(int width, int height) {
    // Cinema encodes are commonly 3840x1600 or 4096x1716 after removing
    // letterbox pixels. Pixel-counting against 3840x2160 misclassifies those
    // sources as 1080p even though their decode cost and bitrate are 4K-class.
    return MAX(width, height) >= 3000;
}

@interface BunnyFFmpegTrack ()
@property(nonatomic) NSInteger streamIndex;
@property(nonatomic) BunnyFFmpegTrackKind kind;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy, nullable) NSString *language;
@property(nonatomic, copy) NSString *codecName;
- (instancetype)initWithStreamIndex:(NSInteger)streamIndex
                                kind:(BunnyFFmpegTrackKind)kind
                               title:(NSString *)title
                            language:(nullable NSString *)language
                           codecName:(NSString *)codecName;
@end

@implementation BunnyFFmpegTrack

- (instancetype)initWithStreamIndex:(NSInteger)streamIndex
                                kind:(BunnyFFmpegTrackKind)kind
                               title:(NSString *)title
                            language:(nullable NSString *)language
                           codecName:(NSString *)codecName {
    self = [super init];
    if (self) {
        _streamIndex = streamIndex;
        _kind = kind;
        _title = [title copy];
        _language = [language copy];
        _codecName = [codecName copy];
    }
    return self;
}

@end

@interface BunnyFFmpegBitmapSubtitlePart ()
@property(nonatomic, strong) UIImage *image;
@property(nonatomic) CGRect sourceRect;
- (instancetype)initWithImage:(UIImage *)image sourceRect:(CGRect)sourceRect;
@end

@implementation BunnyFFmpegBitmapSubtitlePart

- (instancetype)initWithImage:(UIImage *)image sourceRect:(CGRect)sourceRect {
    self = [super init];
    if (self) {
        _image = image;
        _sourceRect = sourceRect;
    }
    return self;
}

@end

@interface BunnyFFmpegBitmapSubtitleCue ()
@property(nonatomic, copy) NSArray<BunnyFFmpegBitmapSubtitlePart *> *parts;
@property(nonatomic) CGSize sourceSize;
- (instancetype)initWithParts:(NSArray<BunnyFFmpegBitmapSubtitlePart *> *)parts
                    sourceSize:(CGSize)sourceSize;
@end

@implementation BunnyFFmpegBitmapSubtitleCue

- (instancetype)initWithParts:(NSArray<BunnyFFmpegBitmapSubtitlePart *> *)parts
                    sourceSize:(CGSize)sourceSize {
    self = [super init];
    if (self) {
        _parts = [parts copy];
        _sourceSize = sourceSize;
    }
    return self;
}

@end

@interface BunnyFFmpegMediaInfo ()
@property(nonatomic) NSTimeInterval duration;
@property(nonatomic) CGSize presentationSize;
@property(nonatomic) double nominalFrameRate;
@property(nonatomic) BOOL hasVideo;
@property(nonatomic) BOOL hasAudio;
@property(nonatomic, copy) NSString *containerName;
@property(nonatomic, copy, nullable) NSString *videoCodecName;
@property(nonatomic, copy, nullable) NSString *audioCodecName;
@property(nonatomic, copy) NSArray<BunnyFFmpegTrack *> *audioTracks;
@property(nonatomic, copy) NSArray<BunnyFFmpegTrack *> *subtitleTracks;
@property(nonatomic) NSInteger selectedAudioStreamIndex;
@property(nonatomic) NSInteger selectedSubtitleStreamIndex;
- (instancetype)initPrivate;
@end

@implementation BunnyFFmpegMediaInfo
- (instancetype)initPrivate {
    return [super init];
}
@end

@interface BunnyFFmpegDecoder () {
    NSURL *_URL;
    dispatch_queue_t _decodeQueue;
    dispatch_queue_t _videoRenderQueue;
    dispatch_queue_t _audioRenderQueue;
    dispatch_group_t _decodeGroup;
    NSLock *_controlLock;
    NSLock *_pendingSampleLock;
    NSMutableArray *_pendingVideoSamples;
    NSMutableArray *_pendingAudioSamples;
    NSMutableArray<NSValue *> *_pendingCompressedPackets;
    NSUInteger _compressedPacketReadIndex;
    size_t _pendingCompressedPacketBytes;
    double _compressedPacketStartTime;
    double _compressedPacketEndTime;
    atomic_bool _started;
    atomic_bool _stopRequested;
    atomic_bool _seekInterrupt;
    atomic_bool _mediaOpened;
    StremioBunnyClock *_rustClock;

    NSTimeInterval _pendingSeek;
    NSTimeInterval _pendingAudioRendererRecoveryTime;
    NSTimeInterval _scheduledAudioRendererRecoveryTime;
    NSUInteger _audioRendererRecoveryGeneration;
    BOOL _audioRendererRecoveryInFlight;
    NSInteger _requestedAudioIndex;
    NSInteger _requestedSubtitleIndex;
    float _desiredRate;
    BOOL _waitingForPreroll;

    AVFormatContext *_formatContext;
    AVCodecContext *_videoCodecContext;
    AVCodecContext *_audioCodecContext;
    AVCodecContext *_subtitleCodecContext;
    struct SwsContext *_scaleContext;
    struct SwrContext *_resampleContext;
    CVPixelBufferPoolRef _pixelBufferPool;
    int _pixelBufferPoolWidth;
    int _pixelBufferPoolHeight;
    OSType _pixelBufferPoolFormat;
    CMVideoFormatDescriptionRef _videoFormatDescription;
    CMAudioFormatDescriptionRef _audioFormatDescription;

    NSInteger _videoStreamIndex;
    NSInteger _audioStreamIndex;
    NSInteger _subtitleStreamIndex;
    double _timelineOrigin;
    double _duration;
    double _discardBefore;
    double _lastVideoPTS;
    double _lastVideoEnd;
    double _lastAudioPTS;
    double _lastAudioEnd;
    int _resampleInputRate;
    enum AVSampleFormat _resampleInputFormat;
    int _resampleInputChannels;
    atomic_bool _hardwareVideoDecode;
    atomic_bool _hardwareVideoDecoderNegotiated;
    BOOL _preferHardwareVideoDecoding;
    BOOL _isAdaptiveInput;
    BOOL _hasVideo;
    BOOL _hasAudio;
    BOOL _firstFrameEmitted;
    NSInteger _decodedVideoFrames;
    NSInteger _droppedVideoFrames;
    NSInteger _renderedAudioFrames;
    NSInteger _rebufferCount;
    BOOL _audioFailureReported;
    BOOL _didLogBitmapSubtitle;
    BOOL _audioRenderTimelineInitialized;
    NSUInteger _audioTimingDiscontinuityLogCount;
    NSError *_fatalDecodeError;
    NSInteger _consecutiveVideoDecodeFailures;
    NSInteger _consecutiveVideoOutputFailures;
#if TARGET_OS_SIMULATOR
    BOOL _didInjectHardwareDecodeFailure;
    BOOL _audioPCMAuditEnabled;
    BOOL _hasLastAuditedPCMSample;
    float _lastAuditedPCMSample[2];
    NSUInteger _audioPCMAnomalyLogCount;
#endif
    NSTimeInterval _lastMetricsAt;
    NSTimeInterval _lastPrerollLogAt;
}
@property(nonatomic, strong, readwrite) AVSampleBufferDisplayLayer *videoLayer;
@property(nonatomic, strong, readwrite) AVSampleBufferAudioRenderer *audioRenderer;
@property(nonatomic, strong, readwrite) AVSampleBufferRenderSynchronizer *synchronizer;
- (BOOL)shouldInterruptFFmpeg;
- (void)reportAudioFailureAtStage:(NSString *)stage code:(NSInteger)code;
- (void)drainPendingVideoSamples;
- (void)drainPendingAudioSamples;
- (void)audioRendererNeedsRecovery:(NSNotification *)notification;
- (void)commitAudioRendererRecoveryGeneration:(NSUInteger)generation
                                          name:(NSNotificationName)name;
- (void)clearAndFlushRenderersRemovingImage:(BOOL)removeImage;
- (BOOL)processControlRequests;
- (BOOL)performSeek:(NSTimeInterval)time;
- (void)resumeAfterPrerollIfReady;
- (void)beginAutomaticRebufferIfNeededForPresentationTime:(double)presentationTime
                                                 duration:(double)duration;
- (NSTimeInterval)decodedQueueDuration;
- (NSTimeInterval)prerollDuration;
- (void)enqueueCompressedPacket:(AVPacket *)packet;
- (AVPacket * _Nullable)dequeueCompressedPacket;
- (AVPacket * _Nullable)dequeueCompressedPacketForStreamIndex:(NSInteger)streamIndex;
- (AVPacket * _Nullable)dequeueCompressedPacketForLaggingTrackIfNeeded;
- (void)clearCompressedPackets;
- (BOOL)compressedPacketBufferIsFull;
- (NSUInteger)compressedPacketCount;
- (void)decodeSelectedPacket:(AVPacket *)packet;
- (NSInteger)bestDecodableStreamOfType:(enum AVMediaType)type
                          relatedStream:(NSInteger)relatedStream;
- (NSInteger)bestDecodableAdaptiveVideoStream;
- (NSInteger)bestDecodableAudioStreamForAdaptiveVideo:(NSInteger)videoStreamIndex;
- (BOOL)isSelectableAdaptiveAudioStreamIndex:(NSInteger)streamIndex;
- (void)recordFatalVideoDecodeFailure:(int)code operation:(NSString *)operation;
- (void)recordVideoCodecFailureAtStage:(NSString *)stage code:(int)code;
- (void)recordVideoOutputFailureAtStage:(NSString *)stage;
- (nullable UIImage *)imageForBitmapSubtitleRect:(AVSubtitleRect *)rect;
- (nullable BunnyFFmpegBitmapSubtitleCue *)bitmapSubtitleCueForSubtitle:(AVSubtitle *)subtitle;
- (void)publishSubtitleClear;
@end

static enum AVPixelFormat BunnyGetHardwarePixelFormat(
    AVCodecContext *context,
    const enum AVPixelFormat *formats
) {
    for (const enum AVPixelFormat *format = formats;
         *format != AV_PIX_FMT_NONE;
         format++) {
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) {
            NSLog(
                @"BUNNY_DECODER hardware_format codec=%s selected=videotoolbox",
                context->codec ? context->codec->name : "unknown"
            );
            return *format;
        }
    }
    enum AVPixelFormat fallback = formats[0];
    for (const enum AVPixelFormat *format = formats;
         *format != AV_PIX_FMT_NONE;
         format++) {
        const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(*format);
        if (descriptor != NULL && !(descriptor->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
            fallback = *format;
            break;
        }
    }
    NSLog(
        @"BUNNY_DECODER hardware_format codec=%s selected=%s reason=videotoolbox-unavailable",
        context->codec ? context->codec->name : "unknown",
        fallback != AV_PIX_FMT_NONE ? av_get_pix_fmt_name(fallback) : "none"
    );
    return fallback;
}

static int BunnyInterruptCallback(void *opaque) {
    BunnyFFmpegDecoder *decoder = (__bridge BunnyFFmpegDecoder *)opaque;
    return [decoder shouldInterruptFFmpeg];
}

static NSString *BunnyString(const char *value) {
    if (value == NULL || value[0] == '\0') {
        return @"";
    }
    NSString *string = [NSString stringWithUTF8String:value];
    return string ?: @"";
}

static NSString *BunnyDictionaryString(AVDictionary *dictionary, const char *key) {
    AVDictionaryEntry *entry = av_dict_get(dictionary, key, NULL, 0);
    return entry ? BunnyString(entry->value) : @"";
}

static NSError *BunnyError(int code, NSString *operation) {
    char message[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, message, sizeof(message));
    NSString *reason = BunnyString(message);
    if (reason.length == 0) {
        reason = @"Unknown FFmpeg error";
    }
    return [NSError errorWithDomain:BunnyFFmpegDecoderErrorDomain
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:@"%@ (%@)", operation, reason],
                           }];
}

static NSError *BunnyVideoDecodeError(int code, NSString *operation) {
    NSError *base = BunnyError(code, operation);
    NSMutableDictionary *userInfo = [base.userInfo mutableCopy];
    userInfo[BunnyFFmpegDecoderSoftwareRetryKey] = @YES;
    return [NSError errorWithDomain:base.domain code:base.code userInfo:userInfo];
}

@implementation BunnyFFmpegDecoder

- (instancetype)initWithURL:(NSURL *)URL {
    return [self initWithURL:URL preferHardwareVideoDecoding:YES];
}

- (instancetype)initWithURL:(NSURL *)URL
    preferHardwareVideoDecoding:(BOOL)preferHardwareVideoDecoding {
    self = [super init];
    if (self) {
        _URL = URL;
        _preferHardwareVideoDecoding = preferHardwareVideoDecoding;
        dispatch_queue_attr_t decodeAttributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL,
            QOS_CLASS_USER_INITIATED,
            0
        );
        dispatch_queue_attr_t renderAttributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL,
            QOS_CLASS_USER_INTERACTIVE,
            0
        );
        _decodeQueue = dispatch_queue_create(
            "app.temustream.bunny.ffmpeg.decode",
            decodeAttributes
        );
        _videoRenderQueue = dispatch_queue_create(
            "app.temustream.bunny.video-render",
            renderAttributes
        );
        _audioRenderQueue = dispatch_queue_create(
            "app.temustream.bunny.audio-render",
            renderAttributes
        );
        dispatch_queue_set_specific(
            _decodeQueue,
            BunnyDecoderQueueKey,
            BunnyDecoderQueueKey,
            NULL
        );
        _decodeGroup = dispatch_group_create();
        _controlLock = [NSLock new];
        _pendingSampleLock = [NSLock new];
        _pendingVideoSamples = [NSMutableArray array];
        _pendingAudioSamples = [NSMutableArray array];
        _pendingCompressedPackets = [NSMutableArray array];
        _compressedPacketReadIndex = 0;
        _pendingCompressedPacketBytes = 0;
        _compressedPacketStartTime = NAN;
        _compressedPacketEndTime = NAN;
        atomic_init(&_started, false);
        atomic_init(&_stopRequested, false);
        atomic_init(&_seekInterrupt, false);
        atomic_init(&_mediaOpened, false);
        atomic_init(&_hardwareVideoDecode, false);
        atomic_init(&_hardwareVideoDecoderNegotiated, false);
        _rustClock = stremio_bunny_clock_create();
        _pendingSeek = NAN;
        _pendingAudioRendererRecoveryTime = NAN;
        _scheduledAudioRendererRecoveryTime = NAN;
        _audioRendererRecoveryGeneration = 0;
        _audioRendererRecoveryInFlight = NO;
        _requestedAudioIndex = BunnyDecoderNoSelectionRequest;
        _requestedSubtitleIndex = BunnyDecoderNoSelectionRequest;
        // Playback begins only after the Swift owner receives the first-frame
        // callback and explicitly requests a rate. Starting at 1x here let an
        // automatic language-track seek start the clock before 4K preroll was
        // complete, producing the large late-frame cascade seen on device.
        _desiredRate = 0.0f;
        _waitingForPreroll = NO;
        _videoStreamIndex = -1;
        _audioStreamIndex = -1;
        _subtitleStreamIndex = -1;
        _discardBefore = -INFINITY;
        _lastVideoPTS = NAN;
        _lastVideoEnd = 0;
        _lastAudioPTS = NAN;
        _lastAudioEnd = 0;
        _resampleInputRate = 0;
        _resampleInputFormat = AV_SAMPLE_FMT_NONE;
        _resampleInputChannels = 0;
        _audioRenderTimelineInitialized = NO;
#if TARGET_OS_SIMULATOR
        _audioPCMAuditEnabled = [NSProcessInfo.processInfo.environment[
            @"SKELETON_BUNNY_PCM_AUDIT"
        ] isEqualToString:@"1"];
#endif

        _videoLayer = [AVSampleBufferDisplayLayer layer];
        _videoLayer.backgroundColor = UIColor.blackColor.CGColor;
        _videoLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        _audioRenderer = [AVSampleBufferAudioRenderer new];
        _synchronizer = [AVSampleBufferRenderSynchronizer new];
        [_synchronizer addRenderer:_videoLayer];
        [_synchronizer addRenderer:_audioRenderer];
        _synchronizer.delaysRateChangeUntilHasSufficientMediaData = YES;
        [_synchronizer setRate:0 time:kCMTimeZero];

        NSNotificationCenter *notificationCenter = NSNotificationCenter.defaultCenter;
        [notificationCenter addObserver:self
                               selector:@selector(audioRendererNeedsRecovery:)
                                   name:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification
                                 object:_audioRenderer];
        [notificationCenter addObserver:self
                               selector:@selector(audioRendererNeedsRecovery:)
                                   name:AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification
                                 object:_audioRenderer];

        __weak typeof(self) weakSelf = self;
        [_videoLayer requestMediaDataWhenReadyOnQueue:_videoRenderQueue usingBlock:^{
            [weakSelf drainPendingVideoSamples];
        }];
        [_audioRenderer requestMediaDataWhenReadyOnQueue:_audioRenderQueue usingBlock:^{
            [weakSelf drainPendingAudioSamples];
        }];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self stop];
    stremio_bunny_clock_destroy(_rustClock);
    _rustClock = NULL;
}

- (void)start {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&_started, &expected, true)) {
        return;
    }
    atomic_store(&_stopRequested, false);
    dispatch_group_async(_decodeGroup, _decodeQueue, ^{
        @autoreleasepool {
            [self runDecoder];
        }
    });
}

- (void)playAtRate:(float)rate {
    float boundedRate = fminf(fmaxf(rate, 0.25f), 2.0f);
    [_controlLock lock];
    _desiredRate = boundedRate;
    BOOL waitingForPreroll = _waitingForPreroll;
    [_controlLock unlock];
    if (waitingForPreroll) {
        return;
    }
    stremio_bunny_clock_set_rate(_rustClock, boundedRate);
    [_synchronizer setRate:boundedRate time:kCMTimeInvalid];
}

- (void)pause {
    [_controlLock lock];
    _desiredRate = 0;
    [_controlLock unlock];
    stremio_bunny_clock_set_rate(_rustClock, 0);
    [_synchronizer setRate:0 time:kCMTimeInvalid];
}

- (void)seekToTime:(NSTimeInterval)time {
    NSTimeInterval boundedTime = fmax(time, 0);
    if (_duration > 0) {
        boundedTime = fmin(boundedTime, fmax(_duration - 0.05, 0));
    }
    [_controlLock lock];
    _pendingSeek = boundedTime;
    // A user seek already performs the required serialized renderer flush.
    // Supersede any pending route recovery rather than seeking twice.
    _pendingAudioRendererRecoveryTime = NAN;
    _scheduledAudioRendererRecoveryTime = NAN;
    _audioRendererRecoveryGeneration++;
    atomic_store(&_seekInterrupt, true);
    [_controlLock unlock];
    stremio_bunny_clock_seek(_rustClock, llround(boundedTime * 1000000));
    stremio_bunny_clock_set_rate(_rustClock, 0);
    [_synchronizer setRate:0 time:kCMTimeInvalid];
}

- (void)selectAudioStreamIndex:(NSInteger)streamIndex {
    [_controlLock lock];
    _requestedAudioIndex = streamIndex;
    atomic_store(&_seekInterrupt, true);
    [_controlLock unlock];
}

- (void)selectSubtitleStreamIndex:(NSInteger)streamIndex {
    [_controlLock lock];
    _requestedSubtitleIndex = streamIndex;
    atomic_store(&_seekInterrupt, true);
    [_controlLock unlock];
}

- (void)stop {
    if (!atomic_load(&_started)) {
        return;
    }
    atomic_store(&_stopRequested, true);
    atomic_store(&_seekInterrupt, true);
    [_controlLock lock];
    _desiredRate = 0;
    _waitingForPreroll = NO;
    _pendingAudioRendererRecoveryTime = NAN;
    _scheduledAudioRendererRecoveryTime = NAN;
    _audioRendererRecoveryGeneration++;
    _audioRendererRecoveryInFlight = NO;
    [_controlLock unlock];
    stremio_bunny_clock_set_rate(_rustClock, 0);
    [_synchronizer setRate:0 time:kCMTimeInvalid];

    // The decode block retains this decoder until runDecoder returns, and all
    // FFmpeg resources are decode-queue-owned. Waiting for a slow network read
    // here only blocks the caller (normally MainActor) without making renderer
    // teardown safer. The interrupt flag above makes the worker exit promptly.
    [_videoLayer stopRequestingMediaData];
    [_audioRenderer stopRequestingMediaData];
    [self clearAndFlushRenderersRemovingImage:YES];
    stremio_bunny_clock_set_rate(_rustClock, 0);
    [_synchronizer setRate:0 time:kCMTimeInvalid];
}

- (NSTimeInterval)currentTime {
    CMTime time = _synchronizer.currentTime;
    NSTimeInterval seconds = CMTimeGetSeconds(time);
    if (isfinite(seconds)) {
        stremio_bunny_clock_observe(_rustClock, llround(fmax(seconds, 0) * 1000000));
    }
    return (NSTimeInterval)stremio_bunny_clock_position_us(_rustClock) / 1000000.0;
}

- (float)rate {
    return _synchronizer.rate;
}

- (BOOL)isMuted {
    return _audioRenderer.isMuted;
}

- (BOOL)hardwareVideoDecode {
    return atomic_load(&_hardwareVideoDecode);
}

- (BOOL)hardwareVideoDecoderNegotiated {
    return atomic_load(&_hardwareVideoDecoderNegotiated);
}

- (BOOL)prefersHardwareVideoDecoding {
    return _preferHardwareVideoDecoding;
}

- (BOOL)shouldInterruptFFmpeg {
    return atomic_load(&_stopRequested) || atomic_load(&_seekInterrupt);
}

- (void)setMuted:(BOOL)muted {
    _audioRenderer.muted = muted;
}

- (void)audioRendererNeedsRecovery:(NSNotification *)notification {
    if (notification.object != _audioRenderer
        || !atomic_load(&_started)
        || !atomic_load(&_mediaOpened)
        || !_hasAudio
        || atomic_load(&_stopRequested)) {
        return;
    }

    CMTime rendererTime = _synchronizer.currentTime;
    NSTimeInterval playhead = CMTimeGetSeconds(rendererTime);
    if (!isfinite(playhead)) {
        return;
    }

    [_controlLock lock];
    if (_audioRendererRecoveryInFlight) {
        [_controlLock unlock];
        return;
    }
    _scheduledAudioRendererRecoveryTime = fmax(playhead, 0);
    NSUInteger generation = ++_audioRendererRecoveryGeneration;
    [_controlLock unlock];

    // Route replacement commonly produces both renderer notifications.
    // Promote only the final one into the decoder's serial control path.
    __weak typeof(self) weakSelf = self;
    NSNotificationName name = notification.name;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.180 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^{
            [weakSelf commitAudioRendererRecoveryGeneration:generation name:name];
        }
    );
}

- (void)commitAudioRendererRecoveryGeneration:(NSUInteger)generation
                                          name:(NSNotificationName)name {
    if (atomic_load(&_stopRequested) || !atomic_load(&_mediaOpened)) {
        return;
    }
    [_controlLock lock];
    if (generation != _audioRendererRecoveryGeneration
        || _audioRendererRecoveryInFlight
        || !isfinite(_scheduledAudioRendererRecoveryTime)) {
        [_controlLock unlock];
        return;
    }
    NSTimeInterval playhead = CMTimeGetSeconds(_synchronizer.currentTime);
    if (!isfinite(playhead)) {
        playhead = _scheduledAudioRendererRecoveryTime;
    }
    playhead = fmax(playhead, 0);
    if (_duration > 0) {
        playhead = fmin(playhead, fmax(_duration - 0.05, 0));
    }
    _scheduledAudioRendererRecoveryTime = NAN;
    _pendingAudioRendererRecoveryTime = playhead;
    atomic_store(&_seekInterrupt, true);
    [_controlLock unlock];
    NSLog(
        @"BUNNY_DECODER audio_renderer_recovery queued reason=%@ position=%.3f",
        name,
        playhead
    );
}

- (void)runDecoder {
    NSError *error = nil;
    if (![self openInput:&error]) {
        [self finishWithError:error];
        [self releaseFFmpegResources];
        return;
    }
    atomic_store(&_mediaOpened, true);

    [self publishMediaInfo];
    AVPacket *packet = av_packet_alloc();
    if (packet == NULL) {
        [self finishWithError:BunnyError(AVERROR(ENOMEM), @"Could not allocate a packet")];
        [self releaseFFmpegResources];
        return;
    }

    BOOL reachedEnd = NO;
    BOOL decodersDrained = NO;
    BOOL completedPlayback = NO;
    while (!atomic_load(&_stopRequested)) {
        if (_fatalDecodeError) {
            error = _fatalDecodeError;
            break;
        }
        BOOL hadControlRequest = atomic_load(&_seekInterrupt);
        BOOL completedControlSeek = [self processControlRequests];
        if (completedControlSeek) {
            // A successful seek after EOF starts a fresh demux/decode pass.
            reachedEnd = NO;
            decodersDrained = NO;
        }
        if (hadControlRequest || completedControlSeek) {
            // Compressed packets belong to the old demux position and track
            // selection. Keeping them after a seek/audio switch can replay
            // stale media and defeats the exact renderer realignment.
            [self clearCompressedPackets];
        }
        if (atomic_load(&_stopRequested)) {
            break;
        }
        // Some fragmented MP4/HLS and provider MKVs store a long run of one
        // track before its companion. If that leading track fills its decoded
        // queue while playback is paused for preroll, strict FIFO decoding
        // deadlocks even though the lagging packets are already buffered.
        AVPacket *balancingPacket = [self dequeueCompressedPacketForLaggingTrackIfNeeded];
        if (balancingPacket != NULL) {
            [self decodeSelectedPacket:balancingPacket];
            av_packet_free(&balancingPacket);
            [self resumeAfterPrerollIfReady];
            [self publishFirstFrameIfNeeded];
            [self publishMetricsIfNeeded];
            continue;
        }
        if (reachedEnd) {
            if ([self compressedPacketCount] > 0 && ![self queueIsFull]) {
                AVPacket *bufferedPacket = [self dequeueCompressedPacket];
                if (bufferedPacket != NULL) {
                    [self decodeSelectedPacket:bufferedPacket];
                    av_packet_free(&bufferedPacket);
                    [self resumeAfterPrerollIfReady];
                    [self publishFirstFrameIfNeeded];
                    [self publishMetricsIfNeeded];
                    continue;
                }
            }
            if ([self compressedPacketCount] > 0) {
                usleep(2 * 1000);
                [self publishMetricsIfNeeded];
                continue;
            }
            if (!decodersDrained) {
                [self drainDecoders];
                decodersDrained = YES;
                if (_fatalDecodeError) {
                    error = _fatalDecodeError;
                    break;
                }
            }

            // FFmpeg can reach EOF while the bounded render queues still hold
            // up to two seconds of media. Keep the decoder alive so those
            // samples play, and so a seek from the tail can restart demuxing.
            double playbackTail = fmax(_lastVideoEnd, _lastAudioEnd);
            if (self.currentTime + 0.050 >= playbackTail) {
                completedPlayback = YES;
                break;
            }
            [self publishMetricsIfNeeded];
            usleep(2 * 1000);
            continue;
        }

        // Decode buffered packets before reading more whenever the renderers
        // have room. While the small decoded queue is full, continue reading
        // compressed packets into a memory-bounded reservoir. This separates
        // provider/network jitter from 4K VideoToolbox scheduling without
        // retaining seconds of full-resolution CVPixelBuffers.
        if (![self queueIsFull] && [self compressedPacketCount] > 0) {
            AVPacket *bufferedPacket = [self dequeueCompressedPacket];
            if (bufferedPacket != NULL) {
                [self decodeSelectedPacket:bufferedPacket];
                av_packet_free(&bufferedPacket);
                [self resumeAfterPrerollIfReady];
                [self publishFirstFrameIfNeeded];
                [self publishMetricsIfNeeded];
                continue;
            }
        }
        if ([self queueIsFull] && [self compressedPacketBufferIsFull]) {
            usleep(2 * 1000);
            [self publishMetricsIfNeeded];
            continue;
        }

        int result = av_read_frame(_formatContext, packet);
        if (result == AVERROR(EAGAIN)) {
            usleep(2 * 1000);
            continue;
        }
        if (result < 0) {
            if (atomic_load(&_seekInterrupt)) {
                BOOL completedInterruptedSeek = [self processControlRequests];
                if (completedInterruptedSeek) {
                    reachedEnd = NO;
                    decodersDrained = NO;
                    [self clearCompressedPackets];
                }
                av_packet_unref(packet);
                continue;
            }
            if (result == AVERROR_EOF) {
                reachedEnd = YES;
                av_packet_unref(packet);
                continue;
            }
            error = BunnyError(result, @"The stream stopped reading");
            break;
        }

        BOOL selectedPacket = packet->stream_index == _videoStreamIndex
            || packet->stream_index == _audioStreamIndex
            || packet->stream_index == _subtitleStreamIndex;
        if (selectedPacket) {
            if ([self queueIsFull] || [self compressedPacketCount] > 0) {
                [self enqueueCompressedPacket:packet];
            } else {
                [self decodeSelectedPacket:packet];
            }
        }
        av_packet_unref(packet);
        [self resumeAfterPrerollIfReady];
        [self publishFirstFrameIfNeeded];
        [self publishMetricsIfNeeded];
    }

    av_packet_free(&packet);
    [self clearCompressedPackets];

    if (!atomic_load(&_stopRequested)) {
        if (error) {
            [self finishWithError:error];
        } else if (completedPlayback) {
            void (^handler)(void) = self.onEnded;
            if (handler) {
                dispatch_async(dispatch_get_main_queue(), handler);
            }
        }
    }
    [self releaseFFmpegResources];
}

- (BOOL)openInput:(NSError * _Nullable __autoreleasing *)errorOut {
    static dispatch_once_t networkOnce;
    dispatch_once(&networkOnce, ^{
        avformat_network_init();
        // Some valid provider and HLS sources repeat recoverable timestamp
        // warnings for every packet. Printing those messages can itself steal
        // time from the decode queue, so Bunny reports only FFmpeg errors and
        // keeps its own structured playback diagnostics for everything else.
        av_log_set_level(AV_LOG_ERROR);
    });

    _formatContext = avformat_alloc_context();
    if (_formatContext == NULL) {
        if (errorOut) {
            *errorOut = BunnyError(AVERROR(ENOMEM), @"Could not allocate the demuxer");
        }
        return NO;
    }
    _formatContext->interrupt_callback.callback = BunnyInterruptCallback;
    _formatContext->interrupt_callback.opaque = (__bridge void *)self;

    AVDictionary *options = NULL;
    av_dict_set(&options, "rw_timeout", "15000000", 0);
    av_dict_set(&options, "timeout", "15000000", 0);
    av_dict_set(&options, "reconnect", "1", 0);
    av_dict_set(&options, "reconnect_streamed", "1", 0);
    av_dict_set(&options, "reconnect_delay_max", "2", 0);
    av_dict_set(&options, "http_persistent", "1", 0);
    av_dict_set(&options, "http_multiple", "1", 0);
    // The default protocol socket buffer is too small for bursty high-bitrate
    // provider files. This remains compressed data, so a few MiB is cheap and
    // prevents a short radio/CDN pause from starving VideoToolbox.
    av_dict_set(&options, "buffer_size", "4194304", 0);
    NSString *extension = _URL.pathExtension.lowercaseString;
    _isAdaptiveInput = [extension isEqualToString:@"mpd"]
        || [extension isEqualToString:@"m3u8"];
    av_dict_set(&options, "probesize", _isAdaptiveInput ? "1000000" : "8000000", 0);
    av_dict_set(&options, "analyzeduration", _isAdaptiveInput ? "1000000" : "8000000", 0);
    av_dict_set(&options, "scan_all_pmts", "1", 0);
    av_dict_set(&options, "user_agent", "Bunny/1.0 TemuStremio iOS", 0);

    NSString *input = _URL.isFileURL ? _URL.path : _URL.absoluteString;
    int result = avformat_open_input(
        &_formatContext,
        input.fileSystemRepresentation,
        NULL,
        &options
    );
    av_dict_free(&options);
    if (result < 0) {
        if (errorOut) {
            *errorOut = BunnyError(result, @"Bunny could not open this source");
        }
        return NO;
    }

    result = avformat_find_stream_info(_formatContext, NULL);
    if (result < 0) {
        if (errorOut) {
            *errorOut = BunnyError(result, @"Bunny could not inspect this source");
        }
        return NO;
    }

    _videoStreamIndex = _isAdaptiveInput
        ? [self bestDecodableAdaptiveVideoStream]
        : [self bestDecodableStreamOfType:AVMEDIA_TYPE_VIDEO relatedStream:-1];
    _audioStreamIndex = _isAdaptiveInput
        ? [self bestDecodableAudioStreamForAdaptiveVideo:_videoStreamIndex]
        : [self bestDecodableStreamOfType:AVMEDIA_TYPE_AUDIO
                              relatedStream:_videoStreamIndex];
    _subtitleStreamIndex = -1;
    _hasVideo = _videoStreamIndex >= 0;
    _hasAudio = _audioStreamIndex >= 0;
    if (!_hasVideo && !_hasAudio) {
        if (errorOut) {
            *errorOut = BunnyError(AVERROR_STREAM_NOT_FOUND, @"No playable video or audio track was found");
        }
        return NO;
    }

    // Adaptive manifests expose every representation as a stream. Marking
    // unselected streams discarded lets demuxers avoid unnecessary segment
    // requests while retaining their metadata for the track picker.
    for (unsigned int index = 0; index < _formatContext->nb_streams; index++) {
        AVStream *stream = _formatContext->streams[index];
        switch (stream->codecpar->codec_type) {
        case AVMEDIA_TYPE_VIDEO:
            stream->discard = (NSInteger)index == _videoStreamIndex
                ? AVDISCARD_DEFAULT
                : AVDISCARD_ALL;
            break;
        case AVMEDIA_TYPE_AUDIO:
            stream->discard = (NSInteger)index == _audioStreamIndex
                ? AVDISCARD_DEFAULT
                : AVDISCARD_ALL;
            break;
        case AVMEDIA_TYPE_SUBTITLE:
            stream->discard = AVDISCARD_ALL;
            break;
        default:
            break;
        }
    }

    if (_hasVideo) {
        _videoCodecContext = [self openCodecForStreamIndex:_videoStreamIndex
                                                    video:YES
                                         hardwareEnabled:_preferHardwareVideoDecoding
                                                    error:errorOut];
        if (_videoCodecContext == NULL) {
            return NO;
        }
        atomic_store(
            &_hardwareVideoDecoderNegotiated,
            _videoCodecContext->hw_device_ctx != NULL
        );
    }
    if (_hasAudio) {
        _audioCodecContext = [self openCodecForStreamIndex:_audioStreamIndex
                                                    video:NO
                                         hardwareEnabled:NO
                                                    error:errorOut];
        if (_audioCodecContext == NULL) {
            return NO;
        }
    }

    _timelineOrigin = [self sourceTimelineOrigin];
    _duration = _formatContext->duration != AV_NOPTS_VALUE
        ? (double)_formatContext->duration / AV_TIME_BASE
        : 0;
    return YES;
}

- (NSInteger)bestDecodableStreamOfType:(enum AVMediaType)type
                          relatedStream:(NSInteger)relatedStream {
    const AVCodec *decoder = NULL;
    int best = av_find_best_stream(
        _formatContext,
        type,
        -1,
        (int)relatedStream,
        &decoder,
        0
    );
    if (best >= 0 && decoder != NULL) {
        AVStream *stream = _formatContext->streams[best];
        if (type != AVMEDIA_TYPE_VIDEO
            || !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            return best;
        }
    }

    // Metadata and cover-art streams occasionally win FFmpeg's normal ranking.
    // Prefer any real, decodable media track over failing the whole source.
    NSInteger fallback = -1;
    NSInteger fallbackScore = NSIntegerMin;
    for (unsigned int index = 0; index < _formatContext->nb_streams; index++) {
        AVStream *stream = _formatContext->streams[index];
        if (stream->codecpar->codec_type != type
            || avcodec_find_decoder(stream->codecpar->codec_id) == NULL) {
            continue;
        }
        BOOL attachedPicture = (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0;
        NSInteger score = (stream->disposition & AV_DISPOSITION_DEFAULT) ? 100 : 0;
        if (type == AVMEDIA_TYPE_VIDEO) {
            score += attachedPicture ? -1000 : 1000;
            score += stream->codecpar->width > 0 && stream->codecpar->height > 0 ? 10 : 0;
        }
        if (score > fallbackScore) {
            fallback = index;
            fallbackScore = score;
        }
    }
    return fallback;
}

- (NSInteger)bestDecodableAdaptiveVideoStream {
    NSInteger best = -1;
    int64_t bestPixels = -1;
    int64_t bestBitrate = -1;
    NSInteger smallestOversized = -1;
    int64_t smallestOversizedPixels = INT64_MAX;
    // VideoToolbox is available on physical iPhones, but the simulator can
    // advertise the format and then fall back to software frames. Decoding a
    // 1080p60 segment from its preceding HLS keyframe makes a simple scrub take
    // 4-7 seconds there. Keep device quality unchanged while selecting the
    // 720p rendition for simulator-only decoder/UI verification.
#if TARGET_OS_SIMULATOR
    const int64_t maximumPerformancePixels = 1280LL * 720LL;
#else
    const int64_t maximumPerformancePixels = 4096LL * 2160LL;
#endif

    for (unsigned int index = 0; index < _formatContext->nb_streams; index++) {
        AVStream *stream = _formatContext->streams[index];
        AVCodecParameters *parameters = stream->codecpar;
        if (parameters->codec_type != AVMEDIA_TYPE_VIDEO
            || (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)
            || avcodec_find_decoder(parameters->codec_id) == NULL
            || parameters->width <= 0
            || parameters->height <= 0) {
            continue;
        }

        int64_t pixels = (int64_t)parameters->width * parameters->height;
        if (pixels > maximumPerformancePixels) {
            if (pixels < smallestOversizedPixels) {
                smallestOversized = (NSInteger)index;
                smallestOversizedPixels = pixels;
            }
            continue;
        }

        int64_t bitrate = parameters->bit_rate;
        AVDictionaryEntry *variantBitrate = av_dict_get(
            stream->metadata,
            "variant_bitrate",
            NULL,
            0
        );
        if (variantBitrate != NULL && variantBitrate->value != NULL) {
            bitrate = MAX(bitrate, strtoll(variantBitrate->value, NULL, 10));
        }
        if (pixels > bestPixels || (pixels == bestPixels && bitrate > bestBitrate)) {
            best = (NSInteger)index;
            bestPixels = pixels;
            bestBitrate = bitrate;
        }
    }

    if (best >= 0) {
        return best;
    }
    if (smallestOversized >= 0) {
        return smallestOversized;
    }
    return [self bestDecodableStreamOfType:AVMEDIA_TYPE_VIDEO relatedStream:-1];
}

- (NSInteger)bestDecodableAudioStreamForAdaptiveVideo:(NSInteger)videoStreamIndex {
    if (videoStreamIndex < 0) {
        return [self bestDecodableStreamOfType:AVMEDIA_TYPE_AUDIO relatedStream:-1];
    }

    for (unsigned int programIndex = 0;
         programIndex < _formatContext->nb_programs;
         programIndex++) {
        AVProgram *program = _formatContext->programs[programIndex];
        BOOL containsSelectedVideo = NO;
        for (unsigned int streamOffset = 0;
             streamOffset < program->nb_stream_indexes;
             streamOffset++) {
            if ((NSInteger)program->stream_index[streamOffset] == videoStreamIndex) {
                containsSelectedVideo = YES;
                break;
            }
        }
        if (!containsSelectedVideo) {
            continue;
        }

        NSInteger bestAudio = -1;
        NSInteger bestScore = NSIntegerMin;
        for (unsigned int streamOffset = 0;
             streamOffset < program->nb_stream_indexes;
             streamOffset++) {
            unsigned int streamIndex = program->stream_index[streamOffset];
            if (streamIndex >= _formatContext->nb_streams) {
                continue;
            }
            AVStream *stream = _formatContext->streams[streamIndex];
            if (stream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO
                || avcodec_find_decoder(stream->codecpar->codec_id) == NULL) {
                continue;
            }
            NSInteger score = (stream->disposition & AV_DISPOSITION_DEFAULT) ? 100 : 0;
            if (score > bestScore) {
                bestAudio = (NSInteger)streamIndex;
                bestScore = score;
            }
        }
        if (bestAudio >= 0) {
            return bestAudio;
        }
    }

    return [self bestDecodableStreamOfType:AVMEDIA_TYPE_AUDIO
                              relatedStream:videoStreamIndex];
}

- (BOOL)isSelectableAdaptiveAudioStreamIndex:(NSInteger)streamIndex {
    if (!_isAdaptiveInput || _videoStreamIndex < 0) {
        return YES;
    }

    NSUInteger programMemberships = 0;
    BOOL sharesSelectedVideoProgram = NO;
    for (unsigned int programIndex = 0;
         programIndex < _formatContext->nb_programs;
         programIndex++) {
        AVProgram *program = _formatContext->programs[programIndex];
        BOOL containsAudio = NO;
        BOOL containsSelectedVideo = NO;
        for (unsigned int offset = 0;
             offset < program->nb_stream_indexes;
             offset++) {
            NSInteger candidate = (NSInteger)program->stream_index[offset];
            containsAudio |= candidate == streamIndex;
            containsSelectedVideo |= candidate == _videoStreamIndex;
        }
        if (containsAudio) {
            programMemberships++;
            sharesSelectedVideoProgram |= containsSelectedVideo;
        }
    }

    // In a muxed HLS master, each quality variant exposes its own copy of the
    // same audio stream. Those are not user-selectable tracks: crossing program
    // boundaries forces a second rendition download and can cause a long audio
    // rebuild. Real alternate renditions are either shared by several programs
    // (common for AAC/AC3/EAC3 groups) or explicitly belong to the selected
    // video's program.
    return sharesSelectedVideoProgram || programMemberships > 1;
}

- (AVCodecContext *)openCodecForStreamIndex:(NSInteger)streamIndex
                                       video:(BOOL)isVideo
                            hardwareEnabled:(BOOL)hardwareEnabled
                                       error:(NSError * _Nullable __autoreleasing *)errorOut {
    if (streamIndex < 0 || streamIndex >= (NSInteger)_formatContext->nb_streams) {
        if (errorOut) {
            *errorOut = BunnyError(AVERROR_STREAM_NOT_FOUND, @"The selected media track is unavailable");
        }
        return NULL;
    }
    AVStream *stream = _formatContext->streams[streamIndex];
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (codec == NULL) {
        if (errorOut) {
            *errorOut = BunnyError(AVERROR_DECODER_NOT_FOUND, @"FFmpeg has no decoder for this track");
        }
        return NULL;
    }

    BOOL canUseVideoToolbox = NO;
    if (isVideo && hardwareEnabled) {
        for (int index = 0; ; index++) {
            const AVCodecHWConfig *configuration = avcodec_get_hw_config(codec, index);
            if (configuration == NULL) {
                break;
            }
            if (configuration->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX
                && (configuration->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
                canUseVideoToolbox = YES;
                break;
            }
        }
    }

    for (int attempt = 0; attempt < (canUseVideoToolbox ? 2 : 1); attempt++) {
        BOOL hardwareAttempt = canUseVideoToolbox && attempt == 0;
        AVCodecContext *context = avcodec_alloc_context3(codec);
        if (context == NULL) {
            if (errorOut) {
                *errorOut = BunnyError(AVERROR(ENOMEM), @"Could not allocate a codec");
            }
            return NULL;
        }
        int result = avcodec_parameters_to_context(context, stream->codecpar);
        if (result < 0) {
            avcodec_free_context(&context);
            if (errorOut) {
                *errorOut = BunnyError(result, @"Could not configure the codec");
            }
            return NULL;
        }
        context->pkt_timebase = stream->time_base;
        context->flags2 |= AV_CODEC_FLAG2_FAST;
        context->thread_count = 0;
        context->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;

        AVBufferRef *hardwareDevice = NULL;
        if (hardwareAttempt) {
            // VideoToolbox owns its own asynchronous decode pipeline. FFmpeg
            // frame/slice workers can force a software-format negotiation on
            // Apple platforms, so keep only one submitter for the HW context.
            context->thread_count = 1;
            context->thread_type = 0;
            context->extra_hw_frames = BunnyIs4KDimensions(
                stream->codecpar->width,
                stream->codecpar->height
            ) ? 12 : 8;
            result = av_hwdevice_ctx_create(
                &hardwareDevice,
                AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                NULL,
                NULL,
                0
            );
            if (result >= 0) {
                context->hw_device_ctx = av_buffer_ref(hardwareDevice);
                context->get_format = BunnyGetHardwarePixelFormat;
            }
            av_buffer_unref(&hardwareDevice);
            if (result < 0) {
                avcodec_free_context(&context);
                continue;
            }
        }

        result = avcodec_open2(context, codec, NULL);
        if (result >= 0) {
            return context;
        }
        avcodec_free_context(&context);
        if (!hardwareAttempt && errorOut) {
            *errorOut = BunnyError(result, @"Could not start the decoder");
        }
    }
    return NULL;
}

- (double)sourceTimelineOrigin {
    if (_formatContext->start_time != AV_NOPTS_VALUE) {
        return (double)_formatContext->start_time / AV_TIME_BASE;
    }
    double origin = INFINITY;
    NSInteger indices[] = { _videoStreamIndex, _audioStreamIndex };
    for (NSUInteger index = 0; index < 2; index++) {
        NSInteger streamIndex = indices[index];
        if (streamIndex < 0) {
            continue;
        }
        AVStream *stream = _formatContext->streams[streamIndex];
        if (stream->start_time != AV_NOPTS_VALUE) {
            origin = fmin(origin, stream->start_time * av_q2d(stream->time_base));
        }
    }
    return isfinite(origin) ? origin : 0;
}

- (void)publishMediaInfo {
    NSMutableArray<BunnyFFmpegTrack *> *audioTracks = [NSMutableArray array];
    NSMutableArray<BunnyFFmpegTrack *> *subtitleTracks = [NSMutableArray array];
    for (unsigned int index = 0; index < _formatContext->nb_streams; index++) {
        AVStream *stream = _formatContext->streams[index];
        enum AVMediaType type = stream->codecpar->codec_type;
        if (type != AVMEDIA_TYPE_AUDIO && type != AVMEDIA_TYPE_SUBTITLE) {
            continue;
        }
        if (type == AVMEDIA_TYPE_AUDIO
            && ![self isSelectableAdaptiveAudioStreamIndex:index]) {
            continue;
        }
        if (avcodec_find_decoder(stream->codecpar->codec_id) == NULL) {
            continue;
        }
        NSString *language = BunnyDictionaryString(stream->metadata, "language");
        NSString *metadataTitle = BunnyDictionaryString(stream->metadata, "title");
        const AVCodecDescriptor *descriptor = avcodec_descriptor_get(stream->codecpar->codec_id);
        NSString *codecName = descriptor ? BunnyString(descriptor->name) : @"unknown";
        NSString *fallbackTitle = type == AVMEDIA_TYPE_AUDIO
            ? [NSString stringWithFormat:@"Audio %lu", (unsigned long)audioTracks.count + 1]
            : [NSString stringWithFormat:@"Subtitle %lu", (unsigned long)subtitleTracks.count + 1];
        NSString *title = metadataTitle.length > 0
            ? metadataTitle
            : (language.length > 0 ? language.uppercaseString : fallbackTitle);
        BunnyFFmpegTrack *track = [[BunnyFFmpegTrack alloc]
            initWithStreamIndex:index
                           kind:type == AVMEDIA_TYPE_AUDIO
                                    ? BunnyFFmpegTrackKindAudio
                                    : BunnyFFmpegTrackKindSubtitle
                          title:title
                       language:language.length > 0 ? language : nil
                      codecName:codecName];
        if (type == AVMEDIA_TYPE_AUDIO) {
            [audioTracks addObject:track];
        } else {
            [subtitleTracks addObject:track];
        }
    }

    BunnyFFmpegMediaInfo *info = [[BunnyFFmpegMediaInfo alloc] initPrivate];
    info.duration = _duration;
    info.hasVideo = _hasVideo;
    info.hasAudio = _hasAudio;
    info.containerName = _formatContext->iformat
        ? BunnyString(_formatContext->iformat->name)
        : @"unknown";
    info.audioTracks = audioTracks;
    info.subtitleTracks = subtitleTracks;
    info.selectedAudioStreamIndex = _audioStreamIndex;
    info.selectedSubtitleStreamIndex = _subtitleStreamIndex;

    if (_hasVideo) {
        AVStream *stream = _formatContext->streams[_videoStreamIndex];
        const AVCodecDescriptor *descriptor = avcodec_descriptor_get(stream->codecpar->codec_id);
        info.videoCodecName = descriptor ? BunnyString(descriptor->name) : @"unknown";
        AVRational aspect = av_guess_sample_aspect_ratio(_formatContext, stream, NULL);
        CGFloat ratio = aspect.num > 0 && aspect.den > 0 ? av_q2d(aspect) : 1;
        info.presentationSize = CGSizeMake(
            stream->codecpar->width * ratio,
            stream->codecpar->height
        );
        AVRational frameRate = av_guess_frame_rate(_formatContext, stream, NULL);
        info.nominalFrameRate = frameRate.num > 0 && frameRate.den > 0
            ? av_q2d(frameRate)
            : 0;
    } else {
        info.presentationSize = CGSizeZero;
        info.nominalFrameRate = 0;
    }
    if (_hasAudio) {
        AVStream *stream = _formatContext->streams[_audioStreamIndex];
        const AVCodecDescriptor *descriptor = avcodec_descriptor_get(stream->codecpar->codec_id);
        info.audioCodecName = descriptor ? BunnyString(descriptor->name) : @"unknown";
    }

    BOOL negotiatedHardware = _videoCodecContext != NULL
        && _videoCodecContext->hw_device_ctx != NULL;
    NSLog(
        @"BUNNY_DECODER opened container=%@ video=%@ audio=%@ video_path=%@ size=%.0fx%.0f",
        info.containerName,
        info.videoCodecName ?: @"none",
        info.audioCodecName ?: @"none",
        negotiatedHardware ? @"videotoolbox" : @"software",
        info.presentationSize.width,
        info.presentationSize.height
    );

    void (^handler)(BunnyFFmpegMediaInfo *) = self.onOpen;
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(info);
        });
    }
}

- (BOOL)processControlRequests {
    NSTimeInterval seekTime = NAN;
    NSTimeInterval audioRendererRecoveryTime = NAN;
    NSInteger requestedAudio = BunnyDecoderNoSelectionRequest;
    NSInteger requestedSubtitle = BunnyDecoderNoSelectionRequest;
    [_controlLock lock];
    seekTime = _pendingSeek;
    _pendingSeek = NAN;
    audioRendererRecoveryTime = _pendingAudioRendererRecoveryTime;
    _pendingAudioRendererRecoveryTime = NAN;
    BOOL hasAudioRendererRecovery = isfinite(audioRendererRecoveryTime);
    if (hasAudioRendererRecovery) {
        _audioRendererRecoveryInFlight = YES;
    }
    requestedAudio = _requestedAudioIndex;
    _requestedAudioIndex = BunnyDecoderNoSelectionRequest;
    requestedSubtitle = _requestedSubtitleIndex;
    _requestedSubtitleIndex = BunnyDecoderNoSelectionRequest;
    // Clearing while holding the same lock used by seekToTime prevents a new
    // request from losing its wakeup between dequeue and avformat_seek_file.
    atomic_store(&_seekInterrupt, false);
    [_controlLock unlock];

    // `_seekInterrupt` exists to wake a blocked av_read_frame. Once the
    // decoder queue owns the request it must be cleared before invoking
    // avformat_seek_file, otherwise FFmpeg interrupts its own seek.
    BOOL didSeek = isfinite(seekTime) && [self performSeek:seekTime];

    if (hasAudioRendererRecovery && !didSeek) {
        // Both renderer notifications may arrive from arbitrary threads. The
        // control request is consumed on the decode queue, and performSeek:
        // synchronously flushes the audio render queue before re-enqueueing,
        // exactly as AVFoundation requires for a route/configuration reset.
        didSeek = [self performSeek:audioRendererRecoveryTime];
        NSLog(
            @"BUNNY_DECODER audio_renderer_recovery completed=%@ position=%.3f",
            didSeek ? @"yes" : @"no",
            audioRendererRecoveryTime
        );
    }

    if (requestedAudio != BunnyDecoderNoSelectionRequest
        && requestedAudio != _audioStreamIndex) {
        NSTimeInterval selectionTime = self.currentTime;
        [_synchronizer setRate:0
                          time:CMTimeMakeWithSeconds(selectionTime, 60000)];
        [self switchAudioStream:requestedAudio];
        // Re-read from the same timeline point after replacing the codec.
        // Continuing from the demuxer's current packet can enqueue the new
        // track behind the synchronizer clock, which presents as a crackle or
        // a burst of stale audio on AVSampleBufferAudioRenderer.
        if (_audioStreamIndex == requestedAudio && !didSeek) {
            didSeek = [self performSeek:selectionTime];
        }
    }
    if (requestedSubtitle != BunnyDecoderNoSelectionRequest
        && requestedSubtitle != _subtitleStreamIndex) {
        NSTimeInterval selectionTime = self.currentTime;
        [self switchSubtitleStream:requestedSubtitle];
        // Subtitle packets are sparse and the cue covering the current time
        // may already have passed through the demuxer. Re-read from the
        // preceding keyframe so selecting a track takes effect immediately.
        if (requestedSubtitle >= 0
            && _subtitleStreamIndex == requestedSubtitle
            && !didSeek) {
            didSeek = [self performSeek:selectionTime];
        }
    }
    if (hasAudioRendererRecovery) {
        [_controlLock lock];
        _audioRendererRecoveryInFlight = NO;
        [_controlLock unlock];
    }
    return didSeek;
}

- (BOOL)performSeek:(NSTimeInterval)time {
    NSTimeInterval originalTime = self.currentTime;
    float resumeRate;
    [_controlLock lock];
    resumeRate = _desiredRate;
    _waitingForPreroll = YES;
    [_controlLock unlock];

    [_synchronizer setRate:0 time:CMTimeMakeWithSeconds(time, 60000)];
    [self clearAndFlushRenderersRemovingImage:YES];
    [self publishSubtitleClear];
    int64_t timestamp = llround((time + _timelineOrigin) * AV_TIME_BASE);
    int result = avformat_seek_file(
        _formatContext,
        -1,
        INT64_MIN,
        timestamp,
        INT64_MAX,
        AVSEEK_FLAG_BACKWARD
    );
    if (result >= 0) {
        stremio_bunny_clock_seek(_rustClock, llround(time * 1000000));
        stremio_bunny_clock_set_rate(_rustClock, 0);
        if (_videoCodecContext) {
            avcodec_flush_buffers(_videoCodecContext);
        }
        if (_audioCodecContext) {
            avcodec_flush_buffers(_audioCodecContext);
        }
        if (_subtitleCodecContext) {
            avcodec_flush_buffers(_subtitleCodecContext);
        }
        if (_resampleContext) {
            swr_close(_resampleContext);
            swr_init(_resampleContext);
        }
        _discardBefore = fmax(time - 0.015, 0);
        _lastVideoPTS = NAN;
        _lastAudioPTS = NAN;
        _lastVideoEnd = time;
        _lastAudioEnd = time;
        _audioRenderTimelineInitialized = NO;
        [_synchronizer setRate:0 time:CMTimeMakeWithSeconds(time, 60000)];
    } else {
        [_controlLock lock];
        _waitingForPreroll = NO;
        [_controlLock unlock];
        stremio_bunny_clock_seek(_rustClock, llround(originalTime * 1000000));
        stremio_bunny_clock_set_rate(_rustClock, resumeRate);
        [_synchronizer setRate:resumeRate
                          time:CMTimeMakeWithSeconds(originalTime, 60000)];
    }

    void (^handler)(NSTimeInterval, BOOL) = self.onSeekCompleted;
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(time, result >= 0);
        });
    }
    return result >= 0;
}

- (void)switchAudioStream:(NSInteger)streamIndex {
    if (streamIndex < 0
        || streamIndex >= (NSInteger)_formatContext->nb_streams
        || _formatContext->streams[streamIndex]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
        return;
    }
    NSError *error = nil;
    AVCodecContext *replacement = [self openCodecForStreamIndex:streamIndex
                                                         video:NO
                                              hardwareEnabled:NO
                                                         error:&error];
    if (replacement == NULL) {
        [self finishWithError:error];
        return;
    }
    if (_audioStreamIndex >= 0) {
        _formatContext->streams[_audioStreamIndex]->discard = AVDISCARD_ALL;
    }
    _formatContext->streams[streamIndex]->discard = AVDISCARD_DEFAULT;
    avcodec_free_context(&_audioCodecContext);
    _audioCodecContext = replacement;
    _audioStreamIndex = streamIndex;
    swr_free(&_resampleContext);
    _resampleInputRate = 0;
    _resampleInputFormat = AV_SAMPLE_FMT_NONE;
    _resampleInputChannels = 0;
    _audioRenderTimelineInitialized = NO;
    [_pendingSampleLock lock];
    [_pendingAudioSamples removeAllObjects];
    [_pendingSampleLock unlock];
    dispatch_sync(_audioRenderQueue, ^{
        [self->_audioRenderer flush];
    });
    _lastAudioEnd = self.currentTime;
}

- (void)switchSubtitleStream:(NSInteger)streamIndex {
    if (_subtitleStreamIndex >= 0) {
        _formatContext->streams[_subtitleStreamIndex]->discard = AVDISCARD_ALL;
    }
    avcodec_free_context(&_subtitleCodecContext);
    _subtitleStreamIndex = -1;
    if (streamIndex >= 0
        && streamIndex < (NSInteger)_formatContext->nb_streams
        && _formatContext->streams[streamIndex]->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
        NSError *error = nil;
        _subtitleCodecContext = [self openCodecForStreamIndex:streamIndex
                                                       video:NO
                                            hardwareEnabled:NO
                                                       error:&error];
        if (_subtitleCodecContext) {
            _subtitleStreamIndex = streamIndex;
            _formatContext->streams[streamIndex]->discard = AVDISCARD_DEFAULT;
        }
    }
    [self publishSubtitleClear];
}

- (void)decodeSelectedPacket:(AVPacket *)packet {
    if (packet->stream_index == _videoStreamIndex) {
        [self decodeVideoPacket:packet];
    } else if (packet->stream_index == _audioStreamIndex) {
        [self decodeAudioPacket:packet];
    } else if (packet->stream_index == _subtitleStreamIndex) {
        [self decodeSubtitlePacket:packet];
    }
}

- (void)enqueueCompressedPacket:(AVPacket *)packet {
    AVPacket *copy = av_packet_clone(packet);
    if (copy == NULL) {
        return;
    }
    [_pendingCompressedPackets addObject:[NSValue valueWithPointer:copy]];
    _pendingCompressedPacketBytes += (size_t)MAX(copy->size, 0);

    if (copy->stream_index >= 0
        && copy->stream_index < (NSInteger)_formatContext->nb_streams) {
        AVStream *stream = _formatContext->streams[copy->stream_index];
        int64_t timestamp = copy->dts != AV_NOPTS_VALUE ? copy->dts : copy->pts;
        if (timestamp != AV_NOPTS_VALUE) {
            double time = timestamp * av_q2d(stream->time_base) - _timelineOrigin;
            if (isfinite(time)) {
                _compressedPacketStartTime = isfinite(_compressedPacketStartTime)
                    ? fmin(_compressedPacketStartTime, time)
                    : time;
                _compressedPacketEndTime = isfinite(_compressedPacketEndTime)
                    ? fmax(_compressedPacketEndTime, time)
                    : time;
            }
        }
    }
}

- (AVPacket *)dequeueCompressedPacket {
    if ([self compressedPacketCount] == 0) {
        return NULL;
    }
    NSValue *value = _pendingCompressedPackets[_compressedPacketReadIndex];
    _compressedPacketReadIndex++;
    AVPacket *packet = value.pointerValue;
    if (packet != NULL) {
        size_t packetBytes = (size_t)MAX(packet->size, 0);
        _pendingCompressedPacketBytes = packetBytes <= _pendingCompressedPacketBytes
            ? _pendingCompressedPacketBytes - packetBytes
            : 0;
    }
    if ([self compressedPacketCount] == 0) {
        [_pendingCompressedPackets removeAllObjects];
        _compressedPacketReadIndex = 0;
        _compressedPacketStartTime = NAN;
        _compressedPacketEndTime = NAN;
    } else {
        AVPacket *firstPacket = _pendingCompressedPackets[
            _compressedPacketReadIndex
        ].pointerValue;
        if (firstPacket != NULL
            && firstPacket->stream_index >= 0
            && firstPacket->stream_index < (NSInteger)_formatContext->nb_streams) {
            AVStream *stream = _formatContext->streams[firstPacket->stream_index];
            int64_t timestamp = firstPacket->dts != AV_NOPTS_VALUE
                ? firstPacket->dts
                : firstPacket->pts;
            _compressedPacketStartTime = timestamp != AV_NOPTS_VALUE
                ? timestamp * av_q2d(stream->time_base) - _timelineOrigin
                : NAN;
        } else {
            _compressedPacketStartTime = NAN;
        }
        // Removing index zero for every packet makes a multi-second 4K
        // reservoir O(n²). Compact only occasionally so dequeue remains O(1)
        // during the performance-critical decode path.
        if (_compressedPacketReadIndex >= 1024
            && _compressedPacketReadIndex * 2 >= _pendingCompressedPackets.count) {
            [_pendingCompressedPackets removeObjectsInRange:NSMakeRange(
                0,
                _compressedPacketReadIndex
            )];
            _compressedPacketReadIndex = 0;
        }
    }
    return packet;
}

- (AVPacket *)dequeueCompressedPacketForStreamIndex:(NSInteger)streamIndex {
    if (streamIndex < 0 || [self compressedPacketCount] == 0) {
        return NULL;
    }
    for (NSUInteger index = _compressedPacketReadIndex;
         index < _pendingCompressedPackets.count;
         index++) {
        AVPacket *packet = _pendingCompressedPackets[index].pointerValue;
        if (packet == NULL || packet->stream_index != streamIndex) {
            continue;
        }
        if (index == _compressedPacketReadIndex) {
            return [self dequeueCompressedPacket];
        }
        [_pendingCompressedPackets removeObjectAtIndex:index];
        size_t packetBytes = (size_t)MAX(packet->size, 0);
        _pendingCompressedPacketBytes = packetBytes <= _pendingCompressedPacketBytes
            ? _pendingCompressedPacketBytes - packetBytes
            : 0;
        return packet;
    }
    return NULL;
}

- (AVPacket *)dequeueCompressedPacketForLaggingTrackIfNeeded {
    if (!_hasVideo || !_hasAudio || [self compressedPacketCount] == 0) {
        return NULL;
    }
    double playhead = self.currentTime;
    double videoAhead = fmax(_lastVideoEnd - playhead, 0);
    double audioAhead = fmax(_lastAudioEnd - playhead, 0);
    NSTimeInterval target = [self decodedQueueDuration];
    double videoHardCap = fmax(target + 0.35, 1.20);

    if (videoAhead >= videoHardCap && audioAhead < target) {
        return [self dequeueCompressedPacketForStreamIndex:_audioStreamIndex];
    }
    if (audioAhead >= 8.0 && videoAhead < target) {
        return [self dequeueCompressedPacketForStreamIndex:_videoStreamIndex];
    }
    return NULL;
}

- (void)clearCompressedPackets {
    for (NSUInteger index = _compressedPacketReadIndex;
         index < _pendingCompressedPackets.count;
         index++) {
        NSValue *value = _pendingCompressedPackets[index];
        AVPacket *packet = value.pointerValue;
        if (packet != NULL) {
            av_packet_free(&packet);
        }
    }
    [_pendingCompressedPackets removeAllObjects];
    _compressedPacketReadIndex = 0;
    _pendingCompressedPacketBytes = 0;
    _compressedPacketStartTime = NAN;
    _compressedPacketEndTime = NAN;
}

- (BOOL)compressedPacketBufferIsFull {
    int64_t pixels = 0;
    if (_hasVideo && _videoStreamIndex >= 0) {
        AVCodecParameters *parameters = _formatContext->streams[_videoStreamIndex]->codecpar;
        pixels = (int64_t)parameters->width * parameters->height;
    }
    BOOL is4K = _hasVideo
        && _videoStreamIndex >= 0
        && BunnyIs4KDimensions(
            _formatContext->streams[_videoStreamIndex]->codecpar->width,
            _formatContext->streams[_videoStreamIndex]->codecpar->height
        );
    size_t maximumBytes = is4K
        ? 64ULL * 1024ULL * 1024ULL
        : (pixels >= 1920LL * 1080LL
            ? 32ULL * 1024ULL * 1024ULL
            : 16ULL * 1024ULL * 1024ULL);
    double bufferedDuration = isfinite(_compressedPacketStartTime)
        && isfinite(_compressedPacketEndTime)
        ? _compressedPacketEndTime - _compressedPacketStartTime
        : 0;
    double maximumDuration = is4K ? 10.0 : 8.0;
    return _pendingCompressedPacketBytes >= maximumBytes
        || [self compressedPacketCount] >= BunnyDecoderMaximumCompressedPacketCount
        || bufferedDuration >= maximumDuration;
}

- (NSUInteger)compressedPacketCount {
    return _pendingCompressedPackets.count >= _compressedPacketReadIndex
        ? _pendingCompressedPackets.count - _compressedPacketReadIndex
        : 0;
}

- (void)decodeVideoPacket:(AVPacket *)packet {
    if (_videoCodecContext == NULL) {
        return;
    }
#if TARGET_OS_SIMULATOR
    if (_preferHardwareVideoDecoding
        && !_didInjectHardwareDecodeFailure
        && [NSProcessInfo.processInfo.environment[
            @"SKELETON_BUNNY_FORCE_HARDWARE_DECODE_FAILURE"
        ] isEqualToString:@"1"]) {
        _didInjectHardwareDecodeFailure = YES;
        [self recordFatalVideoDecodeFailure:AVERROR(EINVAL)
                                  operation:@"The hardware video decoder rejected this stream"];
        return;
    }
#endif
    int result = avcodec_send_packet(_videoCodecContext, packet);
    if (result == AVERROR(EAGAIN)) {
        [self receiveVideoFrames];
        result = avcodec_send_packet(_videoCodecContext, packet);
    }
    if (result >= 0) {
        [self receiveVideoFrames];
    } else if (result != AVERROR_EOF) {
        [self recordVideoCodecFailureAtStage:@"codec_send" code:result];
    } else {
        [self recordFatalVideoDecodeFailure:result
                                  operation:@"The video decoder stopped unexpectedly"];
    }
}

- (void)receiveVideoFrames {
    AVFrame *frame = av_frame_alloc();
    if (frame == NULL) {
        [self recordFatalVideoDecodeFailure:AVERROR(ENOMEM)
                                  operation:@"Could not allocate a decoded video frame"];
        return;
    }
    int result = 0;
    while (!atomic_load(&_stopRequested)
           && _fatalDecodeError == nil
           && (result = avcodec_receive_frame(_videoCodecContext, frame)) >= 0) {
        _consecutiveVideoDecodeFailures = 0;
        [self emitVideoFrame:frame];
        av_frame_unref(frame);
    }
    if (result < 0 && result != AVERROR(EAGAIN) && result != AVERROR_EOF) {
        [self recordVideoCodecFailureAtStage:@"codec_receive" code:result];
    }
    av_frame_free(&frame);
}

- (void)emitVideoFrame:(AVFrame *)frame {
    AVStream *stream = _formatContext->streams[_videoStreamIndex];
    double frameDuration = 0;
    if (frame->duration > 0) {
        frameDuration = frame->duration * av_q2d(stream->time_base);
    }
    if (frameDuration <= 0) {
        AVRational frameRate = av_guess_frame_rate(_formatContext, stream, frame);
        frameDuration = frameRate.num > 0 && frameRate.den > 0
            ? av_q2d(av_inv_q(frameRate))
            : 1.0 / 30.0;
    }
    int64_t timestamp = frame->best_effort_timestamp != AV_NOPTS_VALUE
        ? frame->best_effort_timestamp
        : frame->pts;
    double presentationTime = timestamp != AV_NOPTS_VALUE
        ? timestamp * av_q2d(stream->time_base) - _timelineOrigin
        : (isfinite(_lastVideoPTS) ? _lastVideoPTS + frameDuration : self.currentTime);
    presentationTime = fmax(presentationTime, 0);
    _lastVideoPTS = presentationTime;

    if (presentationTime + frameDuration < _discardBefore) {
        return;
    }
    [self beginAutomaticRebufferIfNeededForPresentationTime:presentationTime
                                                   duration:frameDuration];
    double playhead = self.currentTime;
    if (_synchronizer.rate > 0
        && presentationTime + frameDuration < playhead - BunnyDecoderLateFrameTolerance) {
        [_pendingSampleLock lock];
        _droppedVideoFrames++;
        [_pendingSampleLock unlock];
        return;
    }

    CVPixelBufferRef pixelBuffer = [self pixelBufferForFrame:frame];
    if (pixelBuffer == NULL) {
        [_pendingSampleLock lock];
        _droppedVideoFrames++;
        [_pendingSampleLock unlock];
        [self recordVideoOutputFailureAtStage:@"pixel_buffer"];
        return;
    }
    CMSampleBufferRef sampleBuffer = [self videoSampleBufferForPixelBuffer:pixelBuffer
                                                          presentationTime:presentationTime
                                                                  duration:frameDuration];
    CVPixelBufferRelease(pixelBuffer);
    if (sampleBuffer == NULL) {
        [_pendingSampleLock lock];
        _droppedVideoFrames++;
        [_pendingSampleLock unlock];
        [self recordVideoOutputFailureAtStage:@"sample_buffer"];
        return;
    }
    _consecutiveVideoOutputFailures = 0;

    // A seek can be serviced while backpressure is holding this sample. Do not
    // let that pre-seek frame flash after the renderers have been flushed.
    if (!atomic_load(&_stopRequested)
        && !atomic_load(&_seekInterrupt)
        && presentationTime + frameDuration >= _discardBefore) {
        [_pendingSampleLock lock];
        BOOL shouldWakeRenderer = _pendingVideoSamples.count == 0;
        [_pendingVideoSamples addObject:(__bridge id)sampleBuffer];
        [_pendingSampleLock unlock];
        _lastVideoEnd = presentationTime + frameDuration;
        if (shouldWakeRenderer) {
            dispatch_async(_videoRenderQueue, ^{
                [self drainPendingVideoSamples];
            });
        }
    }
    CFRelease(sampleBuffer);
}

- (void)recordVideoCodecFailureAtStage:(NSString *)stage code:(int)code {
    if (_fatalDecodeError) {
        return;
    }
    _consecutiveVideoDecodeFailures++;
    NSLog(
        @"BUNNY_DECODER video_decode_warning stage=%@ code=%d consecutive=%ld",
        stage,
        code,
        (long)_consecutiveVideoDecodeFailures
    );
    if (_consecutiveVideoDecodeFailures >= 3) {
        [self recordFatalVideoDecodeFailure:code
                                  operation:@"The active video decoder rejected this stream"];
    }
}

- (void)recordVideoOutputFailureAtStage:(NSString *)stage {
    if (_fatalDecodeError) {
        return;
    }
    _consecutiveVideoOutputFailures++;
    NSLog(
        @"BUNNY_DECODER video_output_warning stage=%@ consecutive=%ld",
        stage,
        (long)_consecutiveVideoOutputFailures
    );
    if (_consecutiveVideoOutputFailures >= 3) {
        [self recordFatalVideoDecodeFailure:AVERROR(EINVAL)
                                  operation:@"Bunny could not render the decoded video format"];
    }
}

- (void)recordFatalVideoDecodeFailure:(int)code operation:(NSString *)operation {
    if (_fatalDecodeError) {
        return;
    }
    _fatalDecodeError = BunnyVideoDecodeError(code, operation);
    NSLog(
        @"BUNNY_DECODER video_decode_failure software_retry=yes error=%@",
        _fatalDecodeError.localizedDescription
    );
}

- (CVPixelBufferRef)pixelBufferForFrame:(AVFrame *)frame CF_RETURNS_RETAINED {
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX && frame->data[3] != NULL) {
        atomic_store(&_hardwareVideoDecode, true);
        CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)frame->data[3];
        return CVPixelBufferRetain(pixelBuffer);
    }

    const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(
        (enum AVPixelFormat)frame->format
    );
    BOOL highBitDepth = descriptor != NULL && descriptor->comp[0].depth > 8;
    BOOL fullRange = frame->color_range == AVCOL_RANGE_JPEG;
    OSType pixelFormat = highBitDepth
        ? (fullRange
            ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        : (fullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    enum AVPixelFormat destinationFormat = highBitDepth ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;

    if (_pixelBufferPool != NULL
        && (_pixelBufferPoolWidth != frame->width
            || _pixelBufferPoolHeight != frame->height
            || _pixelBufferPoolFormat != pixelFormat)) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    if (_pixelBufferPool == NULL) {
        NSDictionary *attributes = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
            (NSString *)kCVPixelBufferWidthKey: @(frame->width),
            (NSString *)kCVPixelBufferHeightKey: @(frame->height),
            (NSString *)kCVPixelBufferBytesPerRowAlignmentKey: @64,
            (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVReturn poolResult = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            NULL,
            (__bridge CFDictionaryRef)attributes,
            &_pixelBufferPool
        );
        if (poolResult != kCVReturnSuccess) {
            return NULL;
        }
        _pixelBufferPoolWidth = frame->width;
        _pixelBufferPoolHeight = frame->height;
        _pixelBufferPoolFormat = pixelFormat;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            _pixelBufferPool,
            &pixelBuffer
        ) != kCVReturnSuccess) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *destination[] = {
        CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
        CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1),
        NULL,
        NULL,
    };
    int destinationStride[] = {
        (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
        (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
        0,
        0,
    };
    _scaleContext = sws_getCachedContext(
        _scaleContext,
        frame->width,
        frame->height,
        (enum AVPixelFormat)frame->format,
        frame->width,
        frame->height,
        destinationFormat,
        SWS_FAST_BILINEAR,
        NULL,
        NULL,
        NULL
    );
    if (_scaleContext == NULL) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    int convertedHeight = sws_scale(
        _scaleContext,
        (const uint8_t *const *)frame->data,
        frame->linesize,
        0,
        frame->height,
        destination,
        destinationStride
    );
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    if (convertedHeight <= 0) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    CFStringRef primaries = CVColorPrimariesGetStringForIntegerCodePoint(
        frame->color_primaries
    );
    CFStringRef transfer = CVTransferFunctionGetStringForIntegerCodePoint(
        frame->color_trc
    );
    CFStringRef matrix = CVYCbCrMatrixGetStringForIntegerCodePoint(frame->colorspace);
    if (primaries) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            primaries,
            kCVAttachmentMode_ShouldPropagate
        );
    }
    if (transfer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            transfer,
            kCVAttachmentMode_ShouldPropagate
        );
    }
    if (matrix) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            matrix,
            kCVAttachmentMode_ShouldPropagate
        );
    }
    return pixelBuffer;
}

- (CMSampleBufferRef)videoSampleBufferForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                     presentationTime:(double)presentationTime
                                             duration:(double)duration CF_RETURNS_RETAINED {
    if (_videoFormatDescription == NULL
        || !CMVideoFormatDescriptionMatchesImageBuffer(_videoFormatDescription, pixelBuffer)) {
        if (_videoFormatDescription) {
            CFRelease(_videoFormatDescription);
            _videoFormatDescription = NULL;
        }
        if (CMVideoFormatDescriptionCreateForImageBuffer(
                kCFAllocatorDefault,
                pixelBuffer,
                &_videoFormatDescription
            ) != noErr) {
            return NULL;
        }
    }
    CMSampleTimingInfo timing = {
        .duration = CMTimeMakeWithSeconds(duration, 60000),
        .presentationTimeStamp = CMTimeMakeWithSeconds(presentationTime, 60000),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus result = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        _videoFormatDescription,
        &timing,
        &sampleBuffer
    );
    return result == noErr ? sampleBuffer : NULL;
}

- (void)decodeAudioPacket:(AVPacket *)packet {
    if (_audioCodecContext == NULL) {
        return;
    }
    int result = avcodec_send_packet(_audioCodecContext, packet);
    if (result == AVERROR(EAGAIN)) {
        [self receiveAudioFrames];
        result = avcodec_send_packet(_audioCodecContext, packet);
    }
    if (result >= 0) {
        [self receiveAudioFrames];
    } else {
        [self reportAudioFailureAtStage:@"codec_send" code:result];
    }
}

- (void)receiveAudioFrames {
    AVFrame *frame = av_frame_alloc();
    if (frame == NULL) {
        return;
    }
    int result = 0;
    while (!atomic_load(&_stopRequested)
           && (result = avcodec_receive_frame(_audioCodecContext, frame)) >= 0) {
        [self emitAudioFrame:frame];
        av_frame_unref(frame);
    }
    if (result < 0 && result != AVERROR(EAGAIN) && result != AVERROR_EOF) {
        [self reportAudioFailureAtStage:@"codec_receive" code:result];
    }
    av_frame_free(&frame);
}

- (void)emitAudioFrame:(AVFrame *)frame {
    if (![self configureResamplerForFrame:frame]) {
        return;
    }
    int inputRate = frame->sample_rate > 0 ? frame->sample_rate : _audioCodecContext->sample_rate;
    int outputCapacity = (int)av_rescale_rnd(
        swr_get_delay(_resampleContext, inputRate) + frame->nb_samples,
        48000,
        inputRate,
        AV_ROUND_UP
    );
    if (outputCapacity <= 0) {
        [self reportAudioFailureAtStage:@"output_capacity" code:outputCapacity];
        return;
    }
    const size_t bytesPerFrame = sizeof(float) * 2;
    size_t capacityBytes = (size_t)outputCapacity * bytesPerFrame;
    void *memory = malloc(capacityBytes);
    if (memory == NULL) {
        [self reportAudioFailureAtStage:@"audio_memory_allocate" code:ENOMEM];
        return;
    }
    uint8_t *output[] = { (uint8_t *)memory, NULL };
    int outputSamples = swr_convert(
        _resampleContext,
        output,
        outputCapacity,
        (const uint8_t **)frame->extended_data,
        frame->nb_samples
    );
    if (outputSamples <= 0) {
        [self reportAudioFailureAtStage:@"resample" code:outputSamples];
        free(memory);
        return;
    }

#if TARGET_OS_SIMULATOR
    if (_audioPCMAuditEnabled) {
        float *pcm = (float *)memory;
        NSUInteger nonFiniteSamples = 0;
        NSUInteger outOfRangeSamples = 0;
        NSUInteger largeJumps = 0;
        float maximumMagnitude = 0;
        for (int sampleIndex = 0; sampleIndex < outputSamples; sampleIndex++) {
            for (int channel = 0; channel < 2; channel++) {
                float value = pcm[sampleIndex * 2 + channel];
                if (!isfinite(value)) {
                    nonFiniteSamples++;
                    continue;
                }
                maximumMagnitude = fmaxf(maximumMagnitude, fabsf(value));
                if (fabsf(value) > 1.0f) {
                    outOfRangeSamples++;
                }
                if ((_hasLastAuditedPCMSample || sampleIndex > 0)
                    && fabsf(value - _lastAuditedPCMSample[channel]) > 0.5f) {
                    largeJumps++;
                }
                _lastAuditedPCMSample[channel] = value;
            }
            _hasLastAuditedPCMSample = YES;
        }
        if ((nonFiniteSamples > 0 || outOfRangeSamples > 0 || largeJumps > 0)
            && _audioPCMAnomalyLogCount < 20) {
            _audioPCMAnomalyLogCount++;
            NSLog(
                @"BUNNY_DECODER audio_pcm_anomaly nonfinite=%lu out_of_range=%lu large_jumps=%lu peak=%.6f samples=%d",
                (unsigned long)nonFiniteSamples,
                (unsigned long)outOfRangeSamples,
                (unsigned long)largeJumps,
                maximumMagnitude,
                outputSamples
            );
        }
    }
#endif

    // swr_get_delay() intentionally over-allocates the destination. Expose
    // only the frames swr_convert() actually initialized; handing CoreMedia
    // the capacity as data length lets its audio buffer list include an
    // uninitialized tail, which becomes full-scale crackle under load.
    size_t audioDataBytes = (size_t)outputSamples * bytesPerFrame;
    CMBlockBufferCustomBlockSource blockSource = {0};
    blockSource.version = kCMBlockBufferCustomBlockSourceVersion;
    blockSource.FreeBlock = BunnyFreeAudioPCMBlock;
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus blockResult = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        memory,
        capacityBytes,
        NULL,
        &blockSource,
        0,
        audioDataBytes,
        0,
        &blockBuffer
    );
    if (blockResult != kCMBlockBufferNoErr || blockBuffer == NULL) {
        free(memory);
        [self reportAudioFailureAtStage:@"block_buffer_create" code:blockResult];
        return;
    }

    AVStream *stream = _formatContext->streams[_audioStreamIndex];
    int64_t timestamp = frame->best_effort_timestamp != AV_NOPTS_VALUE
        ? frame->best_effort_timestamp
        : frame->pts;
    double sourcePresentationTime = timestamp != AV_NOPTS_VALUE
        ? timestamp * av_q2d(stream->time_base) - _timelineOrigin
        : (isfinite(_lastAudioPTS)
               ? _lastAudioPTS + (double)frame->nb_samples / inputRate
               : self.currentTime);
    sourcePresentationTime = fmax(sourcePresentationTime, 0);
    _lastAudioPTS = sourcePresentationTime;
    double frameDuration = (double)outputSamples / 48000.0;
    if (sourcePresentationTime + frameDuration < _discardBefore) {
        CFRelease(blockBuffer);
        return;
    }

    // AAC commonly uses a 44.1 kHz clock while Bunny renders 48 kHz PCM.
    // Rounding every packet's source PTS independently creates alternating
    // one-sample gaps/overlaps at CoreMedia. AVSampleBufferAudioRenderer can
    // turn those discontinuities into full-scale clicks. Once a continuous
    // run begins, schedule near-adjacent buffers from the exact prior PCM end.
    double presentationTime = sourcePresentationTime;
    if (_audioRenderTimelineInitialized) {
        double timingDelta = sourcePresentationTime - _lastAudioEnd;
        if (fabs(timingDelta) <= 0.005) {
            presentationTime = _lastAudioEnd;
        } else if (_audioTimingDiscontinuityLogCount < 8) {
            _audioTimingDiscontinuityLogCount++;
            NSLog(
                @"BUNNY_DECODER audio_timeline_discontinuity delta_ms=%.3f source=%.6f expected=%.6f",
                timingDelta * 1000.0,
                sourcePresentationTime,
                _lastAudioEnd
            );
        }
    }

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 48000),
        .presentationTimeStamp = CMTimeMakeWithSeconds(presentationTime, 48000),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    size_t sampleSize = bytesPerFrame;
    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus result = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        blockBuffer,
        _audioFormatDescription,
        outputSamples,
        1,
        &timing,
        1,
        &sampleSize,
        &sampleBuffer
    );
    CFRelease(blockBuffer);
    if (result != noErr || sampleBuffer == NULL) {
        [self reportAudioFailureAtStage:@"sample_buffer_create" code:result];
        return;
    }
    if (!atomic_load(&_stopRequested)
        && !atomic_load(&_seekInterrupt)
        && presentationTime + frameDuration >= _discardBefore) {
        [_pendingSampleLock lock];
        BOOL shouldWakeRenderer = _pendingAudioSamples.count == 0;
        [_pendingAudioSamples addObject:(__bridge id)sampleBuffer];
        [_pendingSampleLock unlock];
        if (shouldWakeRenderer) {
            dispatch_async(_audioRenderQueue, ^{
                [self drainPendingAudioSamples];
            });
        }
        _lastAudioEnd = presentationTime + frameDuration;
        _audioRenderTimelineInitialized = YES;
    }
    CFRelease(sampleBuffer);
}

- (BOOL)configureResamplerForFrame:(AVFrame *)frame {
    int inputRate = frame->sample_rate > 0 ? frame->sample_rate : _audioCodecContext->sample_rate;
    enum AVSampleFormat inputFormat = (enum AVSampleFormat)frame->format;
    int inputChannels = frame->ch_layout.nb_channels > 0
        ? frame->ch_layout.nb_channels
        : _audioCodecContext->ch_layout.nb_channels;
    if (_resampleContext
        && inputRate == _resampleInputRate
        && inputFormat == _resampleInputFormat
        && inputChannels == _resampleInputChannels) {
        return YES;
    }

    swr_free(&_resampleContext);
    AVChannelLayout inputLayout = {0};
    if (frame->ch_layout.nb_channels > 0) {
        av_channel_layout_copy(&inputLayout, &frame->ch_layout);
    } else if (_audioCodecContext->ch_layout.nb_channels > 0) {
        av_channel_layout_copy(&inputLayout, &_audioCodecContext->ch_layout);
    } else {
        av_channel_layout_default(&inputLayout, MAX(inputChannels, 1));
    }
    AVChannelLayout outputLayout = AV_CHANNEL_LAYOUT_STEREO;
    int result = swr_alloc_set_opts2(
        &_resampleContext,
        &outputLayout,
        AV_SAMPLE_FMT_FLT,
        48000,
        &inputLayout,
        inputFormat,
        inputRate,
        0,
        NULL
    );
    av_channel_layout_uninit(&inputLayout);
    int initializationResult = result < 0 ? result : swr_init(_resampleContext);
    if (initializationResult < 0) {
        [self reportAudioFailureAtStage:@"resampler_configure" code:initializationResult];
        swr_free(&_resampleContext);
        return NO;
    }
    _resampleInputRate = inputRate;
    _resampleInputFormat = inputFormat;
    _resampleInputChannels = inputChannels;
    _audioRenderTimelineInitialized = NO;

    if (_audioFormatDescription == NULL) {
        AudioStreamBasicDescription description = {
            .mSampleRate = 48000,
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = sizeof(float) * 2,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = sizeof(float) * 2,
            .mChannelsPerFrame = 2,
            .mBitsPerChannel = 32,
        };
        OSStatus formatResult = CMAudioFormatDescriptionCreate(
                kCFAllocatorDefault,
                &description,
                0,
                NULL,
                0,
                NULL,
                NULL,
                &_audioFormatDescription
            );
        if (formatResult != noErr) {
            [self reportAudioFailureAtStage:@"audio_format_create" code:formatResult];
            return NO;
        }
    }
    return YES;
}

- (void)reportAudioFailureAtStage:(NSString *)stage code:(NSInteger)code {
    if (_audioFailureReported) {
        return;
    }
    _audioFailureReported = YES;
    NSLog(@"BUNNY_DECODER audio_failure stage=%@ code=%ld", stage, (long)code);
}

- (void)drainPendingVideoSamples {
    while (_videoLayer.readyForMoreMediaData && !atomic_load(&_stopRequested)) {
        id sample = nil;
        [_pendingSampleLock lock];
        if (_pendingVideoSamples.count > 0) {
            sample = _pendingVideoSamples.firstObject;
            [_pendingVideoSamples removeObjectAtIndex:0];
        }
        [_pendingSampleLock unlock];
        if (sample == nil) {
            return;
        }
        [_videoLayer enqueueSampleBuffer:(__bridge CMSampleBufferRef)sample];
        [_pendingSampleLock lock];
        _decodedVideoFrames++;
        [_pendingSampleLock unlock];
        [self publishFirstFrameIfNeeded];
    }
}

- (void)drainPendingAudioSamples {
    while (_audioRenderer.readyForMoreMediaData && !atomic_load(&_stopRequested)) {
        id sample = nil;
        [_pendingSampleLock lock];
        if (_pendingAudioSamples.count > 0) {
            sample = _pendingAudioSamples.firstObject;
            [_pendingAudioSamples removeObjectAtIndex:0];
        }
        [_pendingSampleLock unlock];
        if (sample == nil) {
            return;
        }
        CMSampleBufferRef sampleBuffer = (__bridge CMSampleBufferRef)sample;
        [_audioRenderer enqueueSampleBuffer:sampleBuffer];
        NSInteger renderedSamples = CMSampleBufferGetNumSamples(sampleBuffer);
        [_pendingSampleLock lock];
        BOOL isFirstAudio = _renderedAudioFrames == 0;
        _renderedAudioFrames += renderedSamples;
        [_pendingSampleLock unlock];
        if (isFirstAudio) {
            NSLog(@"BUNNY_DECODER audio_renderer_started samples=%ld", (long)renderedSamples);
        }
        // Startup requires evidence from both renderers. With non-interleaved
        // sources, audio can become the final missing renderer after the
        // decode queue has already reached its bounded preroll target.
        [self publishFirstFrameIfNeeded];
    }
}

- (void)clearAndFlushRenderersRemovingImage:(BOOL)removeImage {
    [_pendingSampleLock lock];
    [_pendingVideoSamples removeAllObjects];
    [_pendingAudioSamples removeAllObjects];
    [_pendingSampleLock unlock];

    dispatch_sync(_videoRenderQueue, ^{
        if (removeImage) {
            [self->_videoLayer flushAndRemoveImage];
        } else {
            [self->_videoLayer flush];
        }
    });
    dispatch_sync(_audioRenderQueue, ^{
        [self->_audioRenderer flush];
    });
}

- (void)decodeSubtitlePacket:(AVPacket *)packet {
    if (_subtitleCodecContext == NULL) {
        return;
    }
    AVSubtitle subtitle = {0};
    int gotSubtitle = 0;
    int result = avcodec_decode_subtitle2(
        _subtitleCodecContext,
        &subtitle,
        &gotSubtitle,
        packet
    );
    if (result < 0 || !gotSubtitle) {
        return;
    }
    AVStream *stream = _formatContext->streams[_subtitleStreamIndex];
    double packetPTS;
    if (packet->pts != AV_NOPTS_VALUE) {
        packetPTS = packet->pts * av_q2d(stream->time_base) - _timelineOrigin;
    } else if (subtitle.pts != AV_NOPTS_VALUE) {
        packetPTS = subtitle.pts / (double)AV_TIME_BASE - _timelineOrigin;
    } else {
        packetPTS = self.currentTime;
    }
    double start = fmax(packetPTS + subtitle.start_display_time / 1000.0, 0);
    BOOL hasFiniteEnd = subtitle.end_display_time != UINT32_MAX
        && subtitle.end_display_time > subtitle.start_display_time;
    BOOL bitmapCodec = BunnyIsBitmapSubtitleCodec(_subtitleCodecContext->codec_id);
    double duration = hasFiniteEnd
        ? (subtitle.end_display_time - subtitle.start_display_time) / 1000.0
        : (bitmapCodec ? 3600 : 4);

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (unsigned int index = 0; index < subtitle.num_rects; index++) {
        AVSubtitleRect *rect = subtitle.rects[index];
        BOOL isASS = rect->text == NULL && rect->ass != NULL;
        NSString *line = rect->text ? BunnyString(rect->text) : BunnyString(rect->ass);
        line = [self normalizedSubtitleText:line stripASSPrefix:isASS];
        if (line.length > 0) {
            [lines addObject:line];
        }
    }

    BunnyFFmpegBitmapSubtitleCue *bitmapCue =
        [self bitmapSubtitleCueForSubtitle:&subtitle];
    if (bitmapCue != nil) {
        if (!_didLogBitmapSubtitle) {
            _didLogBitmapSubtitle = YES;
            NSLog(
                @"BUNNY_DECODER bitmap_subtitle codec=%s parts=%lu canvas=%.0fx%.0f",
                _subtitleCodecContext->codec ? _subtitleCodecContext->codec->name : "unknown",
                (unsigned long)bitmapCue.parts.count,
                bitmapCue.sourceSize.width,
                bitmapCue.sourceSize.height
            );
        }
        void (^handler)(BunnyFFmpegBitmapSubtitleCue *, NSTimeInterval, NSTimeInterval) =
            self.onBitmapSubtitle;
        if (handler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(bitmapCue, start, duration);
            });
        }
    } else if (lines.count > 0) {
        NSString *text = [lines componentsJoinedByString:@"\n"];
        void (^handler)(NSString *, NSTimeInterval, NSTimeInterval) = self.onSubtitle;
        if (handler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(text, start, duration);
            });
        }
    } else if (bitmapCodec) {
        void (^handler)(BunnyFFmpegBitmapSubtitleCue *, NSTimeInterval, NSTimeInterval) =
            self.onBitmapSubtitle;
        if (handler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(nil, start, 0);
            });
        }
    } else {
        void (^handler)(NSString *, NSTimeInterval, NSTimeInterval) = self.onSubtitle;
        if (handler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(nil, start, 0);
            });
        }
    }
    avsubtitle_free(&subtitle);
}

- (UIImage *)imageForBitmapSubtitleRect:(AVSubtitleRect *)rect {
    if (rect == NULL
        || rect->type != SUBTITLE_BITMAP
        || rect->w <= 0
        || rect->h <= 0
        || rect->w > 8192
        || rect->h > 8192
        || rect->data[0] == NULL
        || rect->data[1] == NULL
        || rect->linesize[0] <= 0) {
        return nil;
    }

    size_t width = (size_t)rect->w;
    size_t height = (size_t)rect->h;
    if (width > SIZE_MAX / 4) {
        return nil;
    }
    size_t rowBytes = width * 4;
    if (height > SIZE_MAX / rowBytes) {
        return nil;
    }
    size_t byteCount = rowBytes * height;
    if (byteCount == 0
        || byteCount > BunnyMaximumBitmapSubtitleBytes
        || rowBytes > INT_MAX) {
        return nil;
    }

    uint8_t *pixels = calloc(1, byteCount);
    if (pixels == NULL) {
        return nil;
    }
    struct SwsContext *context = sws_getContext(
        rect->w,
        rect->h,
        AV_PIX_FMT_PAL8,
        rect->w,
        rect->h,
        AV_PIX_FMT_BGRA,
        SWS_POINT,
        NULL,
        NULL,
        NULL
    );
    if (context == NULL) {
        free(pixels);
        return nil;
    }
    uint8_t *destinationData[4] = { pixels, NULL, NULL, NULL };
    int destinationLinesize[4] = { (int)rowBytes, 0, 0, 0 };
    int convertedRows = sws_scale(
        context,
        (const uint8_t * const *)rect->data,
        rect->linesize,
        0,
        rect->h,
        destinationData,
        destinationLinesize
    );
    sws_freeContext(context);
    if (convertedRows != rect->h) {
        free(pixels);
        return nil;
    }

    // swscale returns straight-alpha BGRA. Core Graphics' fast iOS bitmap
    // format is premultiplied BGRA, so normalize once before handing ownership
    // of the buffer to CGImage.
    for (size_t offset = 0; offset < byteCount; offset += 4) {
        uint16_t alpha = pixels[offset + 3];
        pixels[offset] = (uint8_t)((pixels[offset] * alpha + 127) / 255);
        pixels[offset + 1] = (uint8_t)((pixels[offset + 1] * alpha + 127) / 255);
        pixels[offset + 2] = (uint8_t)((pixels[offset + 2] * alpha + 127) / 255);
    }

    CGDataProviderRef provider = CGDataProviderCreateWithData(
        NULL,
        pixels,
        byteCount,
        BunnyFreeBitmapPixels
    );
    if (provider == NULL) {
        free(pixels);
        return nil;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) {
        CGDataProviderRelease(provider);
        return nil;
    }
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGBitmapByteOrder32Little
        | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst;
    CGImageRef imageRef = CGImageCreate(
        width,
        height,
        8,
        32,
        rowBytes,
        colorSpace,
        bitmapInfo,
        provider,
        NULL,
        false,
        kCGRenderingIntentDefault
    );
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if (imageRef == NULL) {
        return nil;
    }
    UIImage *image = [UIImage imageWithCGImage:imageRef scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(imageRef);
    return image;
}

- (BunnyFFmpegBitmapSubtitleCue *)bitmapSubtitleCueForSubtitle:(AVSubtitle *)subtitle {
    if (subtitle == NULL
        || subtitle->num_rects == 0
        || subtitle->num_rects > BunnyMaximumBitmapSubtitleParts) {
        return nil;
    }

    int canvasWidth = _subtitleCodecContext ? _subtitleCodecContext->width : 0;
    int canvasHeight = _subtitleCodecContext ? _subtitleCodecContext->height : 0;
    if ((canvasWidth <= 0 || canvasHeight <= 0) && _videoStreamIndex >= 0) {
        AVCodecParameters *video = _formatContext->streams[_videoStreamIndex]->codecpar;
        if (canvasWidth <= 0) {
            canvasWidth = video->width;
        }
        if (canvasHeight <= 0) {
            canvasHeight = video->height;
        }
    }

    int64_t maximumX = 0;
    int64_t maximumY = 0;
    size_t totalBitmapBytes = 0;
    NSMutableArray<BunnyFFmpegBitmapSubtitlePart *> *parts = [NSMutableArray array];
    for (unsigned int index = 0; index < subtitle->num_rects; index++) {
        AVSubtitleRect *rect = subtitle->rects[index];
        if (rect == NULL || rect->type != SUBTITLE_BITMAP || rect->w <= 0 || rect->h <= 0) {
            continue;
        }
        size_t rectWidth = (size_t)rect->w;
        size_t rectHeight = (size_t)rect->h;
        if (rectWidth > SIZE_MAX / 4) {
            return nil;
        }
        size_t rectRowBytes = rectWidth * 4;
        if (rectHeight > SIZE_MAX / rectRowBytes) {
            return nil;
        }
        size_t rectByteCount = rectRowBytes * rectHeight;
        if (rectByteCount > BunnyMaximumBitmapSubtitleBytes - totalBitmapBytes) {
            return nil;
        }
        totalBitmapBytes += rectByteCount;
        UIImage *image = [self imageForBitmapSubtitleRect:rect];
        if (image == nil) {
            continue;
        }
        CGRect sourceRect = CGRectMake(rect->x, rect->y, rect->w, rect->h);
        [parts addObject:[[BunnyFFmpegBitmapSubtitlePart alloc]
            initWithImage:image
               sourceRect:sourceRect]];
        maximumX = MAX(maximumX, (int64_t)rect->x + rect->w);
        maximumY = MAX(maximumY, (int64_t)rect->y + rect->h);
    }
    if (parts.count == 0) {
        return nil;
    }
    canvasWidth = MAX(canvasWidth, (int)MIN(maximumX, INT_MAX));
    canvasHeight = MAX(canvasHeight, (int)MIN(maximumY, INT_MAX));
    if (canvasWidth <= 0 || canvasHeight <= 0 || canvasWidth > 32768 || canvasHeight > 32768) {
        return nil;
    }
    return [[BunnyFFmpegBitmapSubtitleCue alloc]
        initWithParts:parts
           sourceSize:CGSizeMake(canvasWidth, canvasHeight)];
}

- (void)publishSubtitleClear {
    void (^textHandler)(NSString *, NSTimeInterval, NSTimeInterval) = self.onSubtitle;
    void (^bitmapHandler)(BunnyFFmpegBitmapSubtitleCue *, NSTimeInterval, NSTimeInterval) =
        self.onBitmapSubtitle;
    if (textHandler == nil && bitmapHandler == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (textHandler) {
            textHandler(nil, 0, 0);
        }
        if (bitmapHandler) {
            bitmapHandler(nil, 0, 0);
        }
    });
}

- (NSString *)normalizedSubtitleText:(NSString *)text stripASSPrefix:(BOOL)stripASSPrefix {
    if (text.length == 0) {
        return @"";
    }
    NSString *normalized = text;
    if (stripASSPrefix) {
        NSUInteger commaCount = 0;
        NSUInteger textStart = NSNotFound;
        for (NSUInteger index = 0; index < normalized.length; index++) {
            if ([normalized characterAtIndex:index] == ',') {
                commaCount++;
                // AVSubtitleRect.ass is an event payload with eight fields
                // before Text: read order, layer, style, name, three margins,
                // and effect. Commas after this point belong to the caption.
                if (commaCount == 8) {
                    textStart = index + 1;
                    break;
                }
            }
        }
        if (textStart != NSNotFound && textStart < normalized.length) {
            normalized = [normalized substringFromIndex:textStart];
        }
    }
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\\N" withString:@"\n"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\\h" withString:@" "];
    NSRegularExpression *tags = [NSRegularExpression
        regularExpressionWithPattern:@"\\{[^}]*\\}"
        options:0
        error:nil];
    normalized = [tags stringByReplacingMatchesInString:normalized
                                                 options:0
                                                   range:NSMakeRange(0, normalized.length)
                                            withTemplate:@""];
    return [normalized stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (void)drainDecoders {
    if (_videoCodecContext) {
        avcodec_send_packet(_videoCodecContext, NULL);
        [self receiveVideoFrames];
    }
    if (_audioCodecContext) {
        avcodec_send_packet(_audioCodecContext, NULL);
        [self receiveAudioFrames];
    }
}

- (void)resumeAfterPrerollIfReady {
    if (atomic_load(&_stopRequested)) {
        return;
    }
    [_controlLock lock];
    BOOL waitingForPreroll = _waitingForPreroll;
    [_controlLock unlock];
    if (!waitingForPreroll) {
        return;
    }

    double playhead = self.currentTime;
    double queueEnd = _hasVideo && _hasAudio
        ? fmin(_lastVideoEnd, _lastAudioEnd)
        : fmax(_lastVideoEnd, _lastAudioEnd);
    NSTimeInterval target = [self prerollDuration];
    BOOL atPlaybackTail = _duration > 0 && queueEnd + 0.050 >= _duration;
    if (queueEnd - playhead < target && !atPlaybackTail) {
        return;
    }

    float resumeRate = 0;
    [_controlLock lock];
    if (_waitingForPreroll) {
        _waitingForPreroll = NO;
        resumeRate = _desiredRate;
    }
    [_controlLock unlock];
    if (resumeRate > 0 && !atomic_load(&_stopRequested)) {
        stremio_bunny_clock_set_rate(_rustClock, resumeRate);
        [_synchronizer setRate:resumeRate time:kCMTimeInvalid];
        NSLog(
            @"BUNNY_DECODER rebuffer_end count=%ld buffered=%.3f target=%.3f",
            (long)_rebufferCount,
            queueEnd - playhead,
            target
        );
    }
}

- (void)beginAutomaticRebufferIfNeededForPresentationTime:(double)presentationTime
                                                 duration:(double)duration {
    [_controlLock lock];
    BOOL waitingForPreroll = _waitingForPreroll;
    float desiredRate = _desiredRate;
    [_controlLock unlock];
    if (waitingForPreroll || desiredRate <= 0 || _synchronizer.rate <= 0) {
        return;
    }

    double playhead = self.currentTime;
    if (presentationTime + duration >= playhead - BunnyDecoderLateFrameTolerance) {
        return;
    }

    [_controlLock lock];
    if (!_waitingForPreroll && _desiredRate > 0) {
        _waitingForPreroll = YES;
        _rebufferCount++;
    }
    BOOL beganRebuffer = _waitingForPreroll;
    [_controlLock unlock];
    if (beganRebuffer) {
        stremio_bunny_clock_set_rate(_rustClock, 0);
        [_synchronizer setRate:0
                          time:CMTimeMakeWithSeconds(playhead, 60000)];
        NSLog(
            @"BUNNY_DECODER rebuffer_begin count=%ld late_by=%.3f compressed_bytes=%llu",
            (long)_rebufferCount,
            playhead - (presentationTime + duration),
            (unsigned long long)_pendingCompressedPacketBytes
        );
    }
}

- (NSTimeInterval)decodedQueueDuration {
    if (!_hasVideo || _videoStreamIndex < 0) {
        return BunnyDecoderMaximumQueueDuration;
    }
    AVCodecParameters *parameters = _formatContext->streams[_videoStreamIndex]->codecpar;
    int64_t pixels = (int64_t)parameters->width * parameters->height;
    if (BunnyIs4KDimensions(parameters->width, parameters->height)) {
        // Keep the expensive full-resolution IOSurface queue short. Network
        // reserve lives in the compressed packet buffer instead.
        return 0.85;
    }
    if (pixels >= 1920LL * 1080LL) {
        return 1.2;
    }
    if (pixels >= 1280LL * 720LL) {
        return 1.5;
    }
    return BunnyDecoderMaximumQueueDuration;
}

- (NSTimeInterval)prerollDuration {
    if (!_hasVideo || _videoStreamIndex < 0) {
        return 0.30;
    }
    AVCodecParameters *parameters = _formatContext->streams[_videoStreamIndex]->codecpar;
    int64_t pixels = (int64_t)parameters->width * parameters->height;
    if (BunnyIs4KDimensions(parameters->width, parameters->height)) {
        return 0.65;
    }
    if (pixels >= 1920LL * 1080LL) {
        return 0.45;
    }
    return 0.30;
}

- (BOOL)queueIsFull {
    double playhead = self.currentTime;
    NSTimeInterval target = [self decodedQueueDuration];
    double videoAhead = fmax(_lastVideoEnd - playhead, 0);
    double audioAhead = fmax(_lastAudioEnd - playhead, 0);
    if (_hasVideo && _hasAudio) {
        // A shared max() bound lets whichever track arrives first block its
        // companion. Large interleaved MKVs commonly expose audio before the
        // first 4K keyframe, which previously deadlocked startup with a full
        // audio queue and zero decoded video. Fill the common A/V window, but
        // retain asymmetric hard caps: video IOSurfaces are expensive while
        // decoded PCM is comparatively small.
        if (fmin(videoAhead, audioAhead) >= target) {
            return YES;
        }
        if (videoAhead >= fmax(target + 0.35, 1.20)) {
            return YES;
        }
        if (audioAhead >= 8.0) {
            return YES;
        }
        return NO;
    }
    return fmax(videoAhead, audioAhead) >= target;
}

- (void)publishFirstFrameIfNeeded {
    if (_firstFrameEmitted) {
        return;
    }
    [_pendingSampleLock lock];
    BOOL hasRenderedVideo = !_hasVideo || _decodedVideoFrames > 0;
    BOOL hasRenderedAudio = !_hasAudio || _renderedAudioFrames > 0;
    [_pendingSampleLock unlock];
    if (!hasRenderedVideo || !hasRenderedAudio) {
        return;
    }
    double playhead = self.currentTime;
    double queueEnd = _hasVideo && _hasAudio
        ? fmin(_lastVideoEnd, _lastAudioEnd)
        : fmax(_lastVideoEnd, _lastAudioEnd);
    BOOL atPlaybackTail = _duration > 0 && queueEnd + 0.050 >= _duration;
    NSTimeInterval decodedTarget = _URL.isFileURL
        ? [self prerollDuration]
        : fmax([self decodedQueueDuration] - 0.10, [self prerollDuration]);
    if (!_URL.isFileURL && _hasVideo && _videoStreamIndex >= 0) {
        AVCodecParameters *parameters = _formatContext->streams[_videoStreamIndex]->codecpar;
        if (BunnyIs4KDimensions(parameters->width, parameters->height)) {
            // Do not make first picture depend on CDN throughput. Once the
            // decoded 4K preroll is ready, start immediately; the demux loop
            // keeps filling the bounded compressed reservoir opportunistically.
            decodedTarget = [self prerollDuration];
        }
    }
    if (queueEnd - playhead < decodedTarget && !atPlaybackTail) {
        return;
    }
    if (atomic_load(&_stopRequested)) {
        return;
    }
    _firstFrameEmitted = YES;
    double compressedDuration = isfinite(_compressedPacketStartTime)
        && isfinite(_compressedPacketEndTime)
        ? _compressedPacketEndTime - _compressedPacketStartTime
        : 0;
    NSLog(
        @"BUNNY_DECODER initial_preroll decoded=%.3f compressed=%.3f compressed_bytes=%llu",
        queueEnd - playhead,
        compressedDuration,
        (unsigned long long)_pendingCompressedPacketBytes
    );
    void (^handler)(void) = self.onFirstFrame;
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), handler);
    }
}

- (void)publishMetricsIfNeeded {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - _lastMetricsAt < 0.25) {
        return;
    }
    _lastMetricsAt = now;
    double queueEnd = _hasVideo && _hasAudio
        ? fmin(_lastVideoEnd, _lastAudioEnd)
        : fmax(_lastVideoEnd, _lastAudioEnd);
    double buffered = fmax(queueEnd - self.currentTime, 0);
    [_pendingSampleLock lock];
    NSInteger decoded = _decodedVideoFrames;
    NSInteger dropped = _droppedVideoFrames;
    NSInteger renderedAudio = _renderedAudioFrames;
    NSUInteger pendingVideo = _pendingVideoSamples.count;
    NSUInteger pendingAudio = _pendingAudioSamples.count;
    [_pendingSampleLock unlock];
    double videoQueueEnd = _hasVideo ? _lastVideoEnd : NAN;
    double audioQueueEnd = _hasAudio ? _lastAudioEnd : NAN;
    if (!_firstFrameEmitted && now - _lastPrerollLogAt >= 1) {
        _lastPrerollLogAt = now;
        NSLog(
            @"BUNNY_DECODER preroll video_end=%.3f audio_end=%.3f video_rendered=%ld audio_rendered=%ld pending_video=%lu pending_audio=%lu compressed=%lu",
            videoQueueEnd,
            audioQueueEnd,
            (long)decoded,
            (long)renderedAudio,
            (unsigned long)pendingVideo,
            (unsigned long)pendingAudio,
            (unsigned long)[self compressedPacketCount]
        );
    }
    void (^handler)(NSInteger, NSInteger, NSInteger, NSTimeInterval, NSTimeInterval,
                    NSTimeInterval) = self.onMetrics;
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(decoded, dropped, renderedAudio, buffered, videoQueueEnd, audioQueueEnd);
        });
    }
}

- (void)finishWithError:(NSError *)error {
    if (error == nil || atomic_load(&_stopRequested)) {
        return;
    }
    void (^handler)(NSError *) = self.onFailure;
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(error);
        });
    }
}

- (void)releaseFFmpegResources {
    atomic_store(&_mediaOpened, false);
    sws_freeContext(_scaleContext);
    _scaleContext = NULL;
    swr_free(&_resampleContext);
    avcodec_free_context(&_subtitleCodecContext);
    avcodec_free_context(&_audioCodecContext);
    avcodec_free_context(&_videoCodecContext);
    if (_formatContext) {
        avformat_close_input(&_formatContext);
    }
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    if (_videoFormatDescription) {
        CFRelease(_videoFormatDescription);
        _videoFormatDescription = NULL;
    }
    if (_audioFormatDescription) {
        CFRelease(_audioFormatDescription);
        _audioFormatDescription = NULL;
    }
}

@end
