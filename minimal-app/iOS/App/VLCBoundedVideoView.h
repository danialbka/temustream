#import <UIKit/UIKit.h>

@class VLCMediaPlayer;

NS_ASSUME_NONNULL_BEGIN

/// A bounded-memory LibVLC renderer for source frames that exceed the iOS
/// OpenGL texture ceiling. LibVLC still performs demuxing and decoding; this
/// view only replaces its final video-output stage.
@interface VLCBoundedVideoView : UIView

@property (nonatomic, readonly) BOOL hasRenderedFrame;
@property (nonatomic, readonly) CGSize sourceVideoSize;
@property (nonatomic, readonly) CGSize outputVideoSize;
/// Frames committed to the CALayer by this renderer.
@property (nonatomic, readonly) uint64_t displayedFrameCount;
/// Decoded frames replaced before the main thread could display them.
@property (nonatomic, readonly) uint64_t droppedFrameCount;
@property (nonatomic, copy, nullable) void (^onFirstFrame)(void);
@property (nonatomic, copy, nullable) void (^onFrameMetrics)(
    uint64_t displayedFrameCount,
    uint64_t droppedFrameCount
);

- (instancetype)initWithPlayer:(VLCMediaPlayer *)player
               maximumPixelSize:(CGSize)maximumPixelSize NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Stops callbacks before SwiftUI releases the hosting view.
- (void)detach;

@end

NS_ASSUME_NONNULL_END
