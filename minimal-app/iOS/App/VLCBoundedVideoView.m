#import "VLCBoundedVideoView.h"

#import <MobileVLCKit/MobileVLCKit.h>
#import <os/lock.h>

// VLCKit 3.x distributes these C declarations in headers that are deliberately
// excluded from its Clang module. Keep the exact, small LibVLC surface needed
// by this renderer local instead of weakening the framework's module map.
typedef struct libvlc_media_player_t libvlc_media_player_t;
typedef void *(*libvlc_video_lock_cb)(void *opaque, void **planes);
typedef void (*libvlc_video_unlock_cb)(
    void *opaque,
    void *picture,
    void *const *planes
);
typedef void (*libvlc_video_display_cb)(void *opaque, void *picture);
typedef unsigned (*libvlc_video_format_cb)(
    void **opaque,
    char *chroma,
    unsigned *width,
    unsigned *height,
    unsigned *pitches,
    unsigned *lines
);
typedef void (*libvlc_video_cleanup_cb)(void *opaque);

extern void libvlc_video_set_callbacks(
    libvlc_media_player_t *player,
    libvlc_video_lock_cb lock,
    libvlc_video_unlock_cb unlock,
    libvlc_video_display_cb display,
    void *opaque
);
extern void libvlc_video_set_format_callbacks(
    libvlc_media_player_t *player,
    libvlc_video_format_cb setup,
    libvlc_video_cleanup_cb cleanup
);

// MobileVLCKit exposes this accessor in its own PrivateHeaders. Re-declaring
// the framework-owned category keeps the C bridge isolated from Swift and
// avoids exposing LibVLC internals to the rest of the app.
@interface VLCMediaPlayer (VLCBoundedVideoViewInternal)
@property (nonatomic, readonly) libvlc_media_player_t *playerInstance;
@end

typedef struct VLCBoundedFrame {
    void *bytes;
    size_t byteCount;
    size_t width;
    size_t height;
    size_t pitch;
} VLCBoundedFrame;

@interface VLCBoundedVideoView ()
- (unsigned)configureChroma:(char *)chroma
                       width:(unsigned *)width
                      height:(unsigned *)height
                     pitches:(unsigned *)pitches
                       lines:(unsigned *)lines;
- (VLCBoundedFrame *)makeFrame;
- (void)enqueueFrame:(VLCBoundedFrame *)frame;
- (void)displayLatestFrame;
@end

static unsigned VLCBoundedSetup(
    void **opaque,
    char *chroma,
    unsigned *width,
    unsigned *height,
    unsigned *pitches,
    unsigned *lines
) {
    VLCBoundedVideoView *view = (__bridge VLCBoundedVideoView *)(*opaque);
    return [view configureChroma:chroma
                           width:width
                          height:height
                         pitches:pitches
                           lines:lines];
}

static void *VLCBoundedLock(void *opaque, void **planes) {
    VLCBoundedVideoView *view = (__bridge VLCBoundedVideoView *)opaque;
    VLCBoundedFrame *frame = [view makeFrame];
    if (frame == NULL) {
        planes[0] = NULL;
        return NULL;
    }
    planes[0] = frame->bytes;
    return frame;
}

static void VLCBoundedUnlock(void *opaque, void *picture, void *const *planes) {
    (void)planes;
    VLCBoundedVideoView *view = (__bridge VLCBoundedVideoView *)opaque;
    VLCBoundedFrame *frame = picture;
    if (frame != NULL) {
        [view enqueueFrame:frame];
    }
}

static void VLCBoundedReleaseBytes(void *info, const void *data, size_t size) {
    (void)info;
    (void)size;
    free((void *)data);
}

@implementation VLCBoundedVideoView {
    VLCMediaPlayer *_player;
    CGSize _maximumPixelSize;
    os_unfair_lock _frameLock;
    CGImageRef _pendingImage;
    BOOL _displayScheduled;
    BOOL _detached;
    size_t _frameWidth;
    size_t _frameHeight;
    size_t _framePitch;
    size_t _frameByteCount;
    CGSize _sourceVideoSize;
    CGSize _outputVideoSize;
    BOOL _hasRenderedFrame;
    uint64_t _displayedFrameCount;
    uint64_t _droppedFrameCount;
}

- (instancetype)initWithPlayer:(VLCMediaPlayer *)player
               maximumPixelSize:(CGSize)maximumPixelSize {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _player = player;
        _maximumPixelSize = CGSizeMake(
            MAX(maximumPixelSize.width, 2),
            MAX(maximumPixelSize.height, 2)
        );
        _frameLock = OS_UNFAIR_LOCK_INIT;
        self.backgroundColor = UIColor.blackColor;
        self.clipsToBounds = YES;
        self.layer.contentsGravity = kCAGravityResizeAspect;
        self.layer.magnificationFilter = kCAFilterLinear;
        self.layer.minificationFilter = kCAFilterLinear;

        player.drawable = nil;
        libvlc_media_player_t *instance = player.playerInstance;
        libvlc_video_set_callbacks(
            instance,
            VLCBoundedLock,
            VLCBoundedUnlock,
            NULL,
            (__bridge void *)self
        );
        libvlc_video_set_format_callbacks(instance, VLCBoundedSetup, NULL);
    }
    return self;
}

- (void)dealloc {
    [self detach];
    os_unfair_lock_lock(&_frameLock);
    CGImageRef pendingImage = _pendingImage;
    _pendingImage = NULL;
    os_unfair_lock_unlock(&_frameLock);
    if (pendingImage != NULL) {
        CGImageRelease(pendingImage);
    }
}

- (BOOL)hasRenderedFrame {
    return _hasRenderedFrame;
}

- (CGSize)sourceVideoSize {
    os_unfair_lock_lock(&_frameLock);
    CGSize value = _sourceVideoSize;
    os_unfair_lock_unlock(&_frameLock);
    return value;
}

- (CGSize)outputVideoSize {
    os_unfair_lock_lock(&_frameLock);
    CGSize value = _outputVideoSize;
    os_unfair_lock_unlock(&_frameLock);
    return value;
}

- (uint64_t)displayedFrameCount {
    os_unfair_lock_lock(&_frameLock);
    uint64_t value = _displayedFrameCount;
    os_unfair_lock_unlock(&_frameLock);
    return value;
}

- (uint64_t)droppedFrameCount {
    os_unfair_lock_lock(&_frameLock);
    uint64_t value = _droppedFrameCount;
    os_unfair_lock_unlock(&_frameLock);
    return value;
}

- (void)detach {
    if (_detached) {
        return;
    }
    _detached = YES;
    // VLCMediaPlayer.stop synchronizes with LibVLC's playback queue. Once it
    // returns, LibVLC will no longer call this view's unretained callback token.
    [_player stop];
    _player = nil;
}

- (unsigned)configureChroma:(char *)chroma
                       width:(unsigned *)width
                      height:(unsigned *)height
                     pitches:(unsigned *)pitches
                       lines:(unsigned *)lines {
    const double sourceWidth = MAX(*width, 2u);
    const double sourceHeight = MAX(*height, 2u);
    const double scale = MIN(
        1.0,
        MIN(_maximumPixelSize.width / sourceWidth,
            _maximumPixelSize.height / sourceHeight)
    );
    unsigned outputWidth = MAX((unsigned)floor(sourceWidth * scale), 2u);
    unsigned outputHeight = MAX((unsigned)floor(sourceHeight * scale), 2u);
    outputWidth &= ~1u;
    outputHeight &= ~1u;

    memcpy(chroma, "RV32", 4);
    *width = outputWidth;
    *height = outputHeight;
    pitches[0] = outputWidth * 4;
    lines[0] = outputHeight;

    os_unfair_lock_lock(&_frameLock);
    _sourceVideoSize = CGSizeMake(sourceWidth, sourceHeight);
    _outputVideoSize = CGSizeMake(outputWidth, outputHeight);
    _frameWidth = outputWidth;
    _frameHeight = outputHeight;
    _framePitch = pitches[0];
    _frameByteCount = _framePitch * _frameHeight;
    os_unfair_lock_unlock(&_frameLock);

    NSLog(
        @"VLC_FRAME_BRIDGE configured source=%ux%u output=%ux%u",
        (unsigned)sourceWidth,
        (unsigned)sourceHeight,
        outputWidth,
        outputHeight
    );
    return 1;
}

- (VLCBoundedFrame *)makeFrame {
    os_unfair_lock_lock(&_frameLock);
    const size_t width = _frameWidth;
    const size_t height = _frameHeight;
    const size_t pitch = _framePitch;
    const size_t byteCount = _frameByteCount;
    const BOOL detached = _detached;
    os_unfair_lock_unlock(&_frameLock);
    if (detached || byteCount == 0) {
        return NULL;
    }

    VLCBoundedFrame *frame = calloc(1, sizeof(VLCBoundedFrame));
    if (frame == NULL) {
        return NULL;
    }
    frame->bytes = malloc(byteCount);
    if (frame->bytes == NULL) {
        free(frame);
        return NULL;
    }
    frame->byteCount = byteCount;
    frame->width = width;
    frame->height = height;
    frame->pitch = pitch;
    return frame;
}

- (void)enqueueFrame:(VLCBoundedFrame *)frame {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(
        NULL,
        frame->bytes,
        frame->byteCount,
        VLCBoundedReleaseBytes
    );
    CGImageRef image = NULL;
    if (provider != NULL && colorSpace != NULL) {
        image = CGImageCreate(
            frame->width,
            frame->height,
            8,
            32,
            frame->pitch,
            colorSpace,
            kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
            provider,
            NULL,
            false,
            kCGRenderingIntentDefault
        );
    }
    if (provider != NULL) {
        CGDataProviderRelease(provider);
    } else {
        free(frame->bytes);
    }
    if (colorSpace != NULL) {
        CGColorSpaceRelease(colorSpace);
    }
    free(frame);
    if (image == NULL) {
        return;
    }

    os_unfair_lock_lock(&_frameLock);
    CGImageRef replacedImage = _pendingImage;
    _pendingImage = image;
    if (replacedImage != NULL) {
        _droppedFrameCount += 1;
    }
    const BOOL shouldSchedule = !_displayScheduled;
    _displayScheduled = YES;
    os_unfair_lock_unlock(&_frameLock);
    if (replacedImage != NULL) {
        CGImageRelease(replacedImage);
    }

    if (shouldSchedule) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self displayLatestFrame];
        });
    }
}

- (void)displayLatestFrame {
    os_unfair_lock_lock(&_frameLock);
    CGImageRef image = _pendingImage;
    _pendingImage = NULL;
    os_unfair_lock_unlock(&_frameLock);

    BOOL displayedImage = image != NULL;
    if (displayedImage) {
        self.layer.contents = (__bridge id)image;
        CGImageRelease(image);
        if (!_hasRenderedFrame) {
            _hasRenderedFrame = YES;
            NSLog(@"VLC_FRAME_BRIDGE first_frame");
            if (self.onFirstFrame != nil) {
                self.onFirstFrame();
            }
        }
    }

    os_unfair_lock_lock(&_frameLock);
    if (displayedImage) {
        _displayedFrameCount += 1;
    }
    const uint64_t displayedFrameCount = _displayedFrameCount;
    const uint64_t droppedFrameCount = _droppedFrameCount;
    const BOOL hasAnotherFrame = _pendingImage != NULL;
    if (!hasAnotherFrame) {
        _displayScheduled = NO;
    }
    os_unfair_lock_unlock(&_frameLock);
    if (displayedImage && self.onFrameMetrics != nil) {
        self.onFrameMetrics(displayedFrameCount, droppedFrameCount);
    }
    if (hasAnotherFrame) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self displayLatestFrame];
        });
    }
}

@end
