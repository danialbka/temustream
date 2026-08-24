#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BunnyFFmpegTrackKind) {
    BunnyFFmpegTrackKindAudio = 0,
    BunnyFFmpegTrackKindSubtitle = 1,
};

/// A media track discovered by Bunny's own libavformat demuxer.
@interface BunnyFFmpegTrack : NSObject

@property(nonatomic, readonly) NSInteger streamIndex;
@property(nonatomic, readonly) BunnyFFmpegTrackKind kind;
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, copy, nullable, readonly) NSString *language;
@property(nonatomic, copy, readonly) NSString *codecName;

- (instancetype)init NS_UNAVAILABLE;

@end

/// Immutable description of the source opened by Bunny's decoder.
@interface BunnyFFmpegMediaInfo : NSObject

@property(nonatomic, readonly) NSTimeInterval duration;
@property(nonatomic, readonly) CGSize presentationSize;
@property(nonatomic, readonly) double nominalFrameRate;
@property(nonatomic, readonly) BOOL hasVideo;
@property(nonatomic, readonly) BOOL hasAudio;
@property(nonatomic, copy, readonly) NSString *containerName;
@property(nonatomic, copy, nullable, readonly) NSString *videoCodecName;
@property(nonatomic, copy, nullable, readonly) NSString *audioCodecName;
@property(nonatomic, copy, readonly) NSArray<BunnyFFmpegTrack *> *audioTracks;
@property(nonatomic, copy, readonly) NSArray<BunnyFFmpegTrack *> *subtitleTracks;
@property(nonatomic, readonly) NSInteger selectedAudioStreamIndex;
@property(nonatomic, readonly) NSInteger selectedSubtitleStreamIndex;

- (instancetype)init NS_UNAVAILABLE;

@end

/// Direct FFmpeg playback backend owned by Bunny.
///
/// libavformat performs probing/network reads and libavcodec performs decode.
/// VideoToolbox frames stay as CVPixelBuffers and are enqueued without a copy;
/// software-only formats use one bounded libswscale conversion. Audio is
/// normalized once to interleaved 48 kHz float PCM for Apple's audio renderer.
@interface BunnyFFmpegDecoder : NSObject

@property(nonatomic, strong, readonly) AVSampleBufferDisplayLayer *videoLayer;
@property(nonatomic, strong, readonly) AVSampleBufferAudioRenderer *audioRenderer;
@property(nonatomic, strong, readonly) AVSampleBufferRenderSynchronizer *synchronizer;

/// UI/state callbacks are always delivered on the main queue.
@property(nonatomic, copy, nullable) void (^onOpen)(BunnyFFmpegMediaInfo *info);
@property(nonatomic, copy, nullable) void (^onFirstFrame)(void);
@property(nonatomic, copy, nullable) void (^onSubtitle)(NSString * _Nullable text,
                                                            NSTimeInterval start,
                                                            NSTimeInterval duration);
@property(nonatomic, copy, nullable) void (^onSeekCompleted)(NSTimeInterval position,
                                                                 BOOL succeeded);
@property(nonatomic, copy, nullable) void (^onMetrics)(NSInteger decodedVideoFrames,
                                                           NSInteger droppedVideoFrames,
                                                           NSInteger renderedAudioFrames,
                                                           NSTimeInterval bufferedDuration,
                                                           NSTimeInterval videoQueueEnd,
                                                           NSTimeInterval audioQueueEnd);
@property(nonatomic, copy, nullable) void (^onEnded)(void);
@property(nonatomic, copy, nullable) void (^onFailure)(NSError *error);

- (instancetype)initWithURL:(NSURL *)URL;
- (instancetype)initWithURL:(NSURL *)URL
    preferHardwareVideoDecoding:(BOOL)preferHardwareVideoDecoding NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Starts one serial, bounded demux/decode worker. Calling more than once is a no-op.
- (void)start;
- (void)playAtRate:(float)rate;
- (void)pause;
- (void)seekToTime:(NSTimeInterval)time;
- (void)selectAudioStreamIndex:(NSInteger)streamIndex;
- (void)selectSubtitleStreamIndex:(NSInteger)streamIndex;
- (void)stop;

@property(nonatomic, readonly) NSTimeInterval currentTime;
@property(nonatomic, readonly) float rate;
/// True only after libavcodec returns an actual VideoToolbox CVPixelBuffer.
@property(nonatomic, readonly) BOOL hardwareVideoDecode;
/// True when libavcodec opened a VideoToolbox context, before the first frame arrives.
@property(nonatomic, readonly) BOOL hardwareVideoDecoderNegotiated;
/// Whether this decoder instance may negotiate VideoToolbox before software decode.
@property(nonatomic, readonly) BOOL prefersHardwareVideoDecoding;
@property(nonatomic, getter=isMuted) BOOL muted;

@end

FOUNDATION_EXPORT NSString *const BunnyFFmpegDecoderErrorDomain;
/// NSError user-info flag indicating that reopening with software video decode may recover.
FOUNDATION_EXPORT NSString *const BunnyFFmpegDecoderSoftwareRetryKey;

NS_ASSUME_NONNULL_END
