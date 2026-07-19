#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

volatile int32_t SPEMockKSBackgroundTransitions = 0;
volatile int32_t SPEMockKSForegroundTransitions = 0;
volatile int32_t SPEMockKSConfigPiPCalls = 0;
volatile int32_t SPEMockKSNativeStartCalls = 0;

#if defined(__arm64__)
__asm__(
    ".text\n"
    ".p2align 2\n"
    ".globl _$s8KSPlayer10KSMEPlayerC15enterBackgroundyyF\n"
    "_$s8KSPlayer10KSMEPlayerC15enterBackgroundyyF:\n"
    "cbz x20, 1f\n"
    "adrp x8, _SPEMockKSBackgroundTransitions@PAGE\n"
    "add x8, x8, _SPEMockKSBackgroundTransitions@PAGEOFF\n"
    "ldr w9, [x8]\n"
    "add w9, w9, #1\n"
    "str w9, [x8]\n"
    "1: ret\n"
    ".p2align 2\n"
    ".globl _$s8KSPlayer10KSMEPlayerC15enterForegroundyyF\n"
    "_$s8KSPlayer10KSMEPlayerC15enterForegroundyyF:\n"
    "cbz x20, 2f\n"
    "adrp x8, _SPEMockKSForegroundTransitions@PAGE\n"
    "add x8, x8, _SPEMockKSForegroundTransitions@PAGEOFF\n"
    "ldr w9, [x8]\n"
    "add w9, w9, #1\n"
    "str w9, [x8]\n"
    "2: ret\n"
    ".p2align 2\n"
    ".globl _$s8KSPlayer10KSMEPlayerC9configPIPyyF\n"
    "_$s8KSPlayer10KSMEPlayerC9configPIPyyF:\n"
    "cbz x20, 3f\n"
    "adrp x8, _SPEMockKSConfigPiPCalls@PAGE\n"
    "add x8, x8, _SPEMockKSConfigPiPCalls@PAGEOFF\n"
    "ldr w9, [x8]\n"
    "add w9, w9, #1\n"
    "str w9, [x8]\n"
    "3: ret\n"
    ".p2align 2\n"
    ".globl _$s8KSPlayer28KSPictureInPictureControllerC5start5layeryAA20KSComplexPlayerLayerC_tF\n"
    "_$s8KSPlayer28KSPictureInPictureControllerC5start5layeryAA20KSComplexPlayerLayerC_tF:\n"
    "cbz x20, 4f\n"
    "cbz x0, 4f\n"
    "adrp x8, _SPEMockKSNativeStartCalls@PAGE\n"
    "add x8, x8, _SPEMockKSNativeStartCalls@PAGEOFF\n"
    "ldr w9, [x8]\n"
    "add w9, w9, #1\n"
    "str w9, [x8]\n"
    "4: ret\n"
);
#endif

static UIView *SPEFindView(UIView *root, NSString *accessibilityIdentifier) {
    if ([root.accessibilityIdentifier isEqualToString:accessibilityIdentifier]) {
        return root;
    }
    for (UIView *subview in root.subviews) {
        UIView *match = SPEFindView(subview, accessibilityIdentifier);
        if (match != nil) {
            return match;
        }
    }
    return nil;
}

static NSInteger SPEMockKSInitializerCount = 0;

@interface SPEMockPiPPlaybackDelegate : NSObject <AVPictureInPictureSampleBufferPlaybackDelegate>
@end

@implementation SPEMockPiPPlaybackDelegate

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
                        setPlaying:(BOOL)playing {
    (void)pictureInPictureController;
    (void)playing;
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:
    (AVPictureInPictureController *)pictureInPictureController {
    (void)pictureInPictureController;
    return CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(60.0, 600));
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:
    (AVPictureInPictureController *)pictureInPictureController {
    (void)pictureInPictureController;
    return NO;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
 didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {
    (void)pictureInPictureController;
    (void)newRenderSize;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
                    skipByInterval:(CMTime)skipInterval
                 completionHandler:(void (^)(void))completionHandler {
    (void)pictureInPictureController;
    (void)skipInterval;
    completionHandler();
}

@end

__attribute__((objc_runtime_name("_TtC8KSPlayer28KSPictureInPictureController")))
@interface SPEMockKSPictureInPictureController : AVPictureInPictureController {
    BOOL _mockAutomaticPiPEnabled;
}
@end

@implementation SPEMockKSPictureInPictureController

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
- (instancetype)initWithContentSource:(AVPictureInPictureControllerContentSource *)contentSource
    API_AVAILABLE(ios(15.0)) {
    (void)contentSource;
    SPEMockKSInitializerCount += 1;
    // AVKit returns nil for real PiP controllers in Simulator. Keep this test
    // double alive so the enhancer's subclass wrapper and configuration can be
    // asserted without pretending that system PiP itself is available.
    return self;
}
#pragma clang diagnostic pop

- (void)setCanStartPictureInPictureAutomaticallyFromInline:(BOOL)enabled {
    _mockAutomaticPiPEnabled = enabled;
}

- (BOOL)canStartPictureInPictureAutomaticallyFromInline {
    return _mockAutomaticPiPEnabled;
}

- (BOOL)isPictureInPicturePossible {
    return NO;
}

- (BOOL)isPictureInPictureActive {
    return NO;
}

@end

__attribute__((objc_runtime_name("_TtC7Stremio17VideoControlsView")))
@interface SPEMockVideoControlsView : UIView {
@public
    UIStackView *controlsStack;
    UIButton *pictureInPictureButton;
}
@property(nonatomic, assign) NSInteger pipTriggerCount;
@end

@implementation SPEMockVideoControlsView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
        controlsStack = [[UIStackView alloc] initWithFrame:CGRectZero];
        controlsStack.axis = UILayoutConstraintAxisHorizontal;
        controlsStack.alignment = UIStackViewAlignmentCenter;
        controlsStack.distribution = UIStackViewDistributionFill;
        controlsStack.spacing = 12.0;
        [self addSubview:controlsStack];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.text = @"Stremio controls";
        label.textColor = UIColor.whiteColor;
        [controlsStack addArrangedSubview:label];

        UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
        [play setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
        play.tintColor = UIColor.whiteColor;
        [controlsStack addArrangedSubview:play];

        pictureInPictureButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [pictureInPictureButton setImage:[UIImage systemImageNamed:@"pip.enter"]
                                forState:UIControlStateNormal];
        [pictureInPictureButton addTarget:self
                                   action:@selector(onPipClicked:)
                         forControlEvents:UIControlEventTouchUpInside];
        pictureInPictureButton.hidden = YES;
    }
    return self;
}

- (void)onPipClicked:(UIButton *)sender {
    (void)sender;
    self.pipTriggerCount += 1;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    controlsStack.frame = CGRectInset(self.bounds, 24.0, 24.0);
}

@end

__attribute__((objc_runtime_name("_TtC7Stremio20PlayerViewController")))
@interface SPEMockPlayerViewController : UIViewController
@property(nonatomic, strong) SPEMockVideoControlsView *controls;
@property(nonatomic, strong) UILabel *resultLabel;
@end

@implementation SPEMockPlayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    self.controls = [[SPEMockVideoControlsView alloc] initWithFrame:CGRectZero];
    self.controls.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.controls];

    self.resultLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.resultLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultLabel.numberOfLines = 0;
    self.resultLabel.textAlignment = NSTextAlignmentCenter;
    self.resultLabel.textColor = UIColor.whiteColor;
    self.resultLabel.font = [UIFont monospacedSystemFontOfSize:16.0
                                                      weight:UIFontWeightSemibold];
    self.resultLabel.text = @"Waiting for enhancer…";
    [self.view addSubview:self.resultLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.controls.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.controls.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.controls.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.controls.heightAnchor constraintEqualToConstant:100.0],
        [self.resultLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.resultLabel.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [self.resultLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor
                                                                    constant:24.0],
        [self.resultLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor
                                                                   constant:-24.0],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.controls setNeedsLayout];
    [self.controls layoutIfNeeded];

    AVPlayerLayer *probeLayer = [AVPlayerLayer playerLayerWithPlayer:nil];
    AVPictureInPictureController *probeController =
        [[AVPictureInPictureController alloc] initWithPlayerLayer:probeLayer];
    __block AVPictureInPictureController *ksProbeController = nil;
    if (@available(iOS 15.0, *)) {
        AVSampleBufferDisplayLayer *displayLayer = [AVSampleBufferDisplayLayer layer];
        SPEMockPiPPlaybackDelegate *playbackDelegate =
            [[SPEMockPiPPlaybackDelegate alloc] init];
        AVPictureInPictureControllerContentSource *contentSource =
            [[AVPictureInPictureControllerContentSource alloc]
                initWithSampleBufferDisplayLayer:displayLayer
                                playbackDelegate:playbackDelegate];
        ksProbeController = [[SPEMockKSPictureInPictureController alloc]
            initWithContentSource:contentSource];
    }

    Class renderDelegateClass = NSClassFromString(@"SPEPictureInPictureDelegate");
    id renderDelegate = [[renderDelegateClass alloc] init];
    NSObject *mockPlaybackDelegate = [[NSObject alloc] init];
    [renderDelegate setValue:self.controls forKey:@"controls"];
    [renderDelegate setValue:mockPlaybackDelegate forKey:@"playbackDelegate"];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [renderDelegate performSelector:NSSelectorFromString(
        @"pictureInPictureControllerWillStartPictureInPicture:") withObject:nil];
    [renderDelegate performSelector:NSSelectorFromString(
        @"pictureInPictureControllerDidStopPictureInPicture:") withObject:nil];
#pragma clang diagnostic pop
    BOOL ksRenderHandoff = SPEMockKSBackgroundTransitions == 1 &&
        SPEMockKSForegroundTransitions == 1;

    typedef BOOL (*SPETestKSNativePiPBridgeFunction)(id player, id playerLayer);
    SPETestKSNativePiPBridgeFunction testKSNativePiPBridge =
        (SPETestKSNativePiPBridgeFunction)dlsym(
            RTLD_DEFAULT, "SPETestKSNativePiPBridge");
    NSObject *mockPlayerLayer = [[NSObject alloc] init];
    BOOL ksNativeBridge = testKSNativePiPBridge != NULL &&
        testKSNativePiPBridge(mockPlaybackDelegate, mockPlayerLayer) &&
        SPEMockKSConfigPiPCalls == 1 && SPEMockKSNativeStartCalls == 1;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIButton *rotate = (UIButton *)SPEFindView(self.controls,
            @"stremio-player-rotate-button");
        UIButton *pip = (UIButton *)SPEFindView(self.controls,
            @"stremio-player-pip-button");
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        BOOL buttonFound = [rotate isKindOfClass:UIButton.class];
        BOOL pipFound = [pip isKindOfClass:UIButton.class];
        BOOL pipVisible = pipFound && !pip.hidden && pip.alpha > 0.0 && pip.enabled;
        BOOL vlcDisabled = ![defaults boolForKey:@"useVLCKit"];
        BOOL avDisabled = ![defaults boolForKey:@"useAVPlayer"];
        BOOL ksPipEnabled = ![defaults boolForKey:
            @"disableKSSampleBufferPictureInPictureSupport"];
        BOOL nativePiPSupported = AVPictureInPictureController.isPictureInPictureSupported;
        BOOL nativeAutoPiPEnabled = !nativePiPSupported ||
            probeController.canStartPictureInPictureAutomaticallyFromInline;
        BOOL ksSubclassHooked = SPEMockKSInitializerCount == 1 &&
            ksProbeController != nil &&
            ksProbeController.canStartPictureInPictureAutomaticallyFromInline;
        BOOL allOrientations = self.supportedInterfaceOrientations == UIInterfaceOrientationMaskAll;

        if (pipVisible) {
            [pip sendActionsForControlEvents:UIControlEventTouchUpInside];
        }
        BOOL pipAction = self.controls.pipTriggerCount == 1;

        self.controls.pipTriggerCount = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.controls performSelector:NSSelectorFromString(
            @"spe_applicationDidEnterBackground:") withObject:nil];
        [self.controls performSelector:NSSelectorFromString(
            @"spe_applicationDidEnterBackground:") withObject:nil];
        BOOL automaticPiP = self.controls.pipTriggerCount == 1;
        [self.controls performSelector:NSSelectorFromString(
            @"spe_applicationWillEnterForeground:") withObject:nil];
#pragma clang diagnostic pop

        BOOL startingLandscape = UIInterfaceOrientationIsLandscape(
            self.view.window.windowScene.interfaceOrientation);

        if (buttonFound) {
            [rotate sendActionsForControlEvents:UIControlEventTouchUpInside];
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL endingLandscape = UIInterfaceOrientationIsLandscape(
                self.view.window.windowScene.interfaceOrientation);
            BOOL rotationChanged = buttonFound && startingLandscape != endingLandscape;
            if (buttonFound) {
                [rotate sendActionsForControlEvents:UIControlEventTouchUpInside];
            }

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                BOOL returnedLandscape = UIInterfaceOrientationIsLandscape(
                    self.view.window.windowScene.interfaceOrientation);
                BOOL rotationReturned = buttonFound && returnedLandscape == startingLandscape;
                BOOL passed = buttonFound && pipFound && pipVisible && pipAction && automaticPiP &&
                    nativeAutoPiPEnabled && ksSubclassHooked && ksRenderHandoff && ksNativeBridge &&
                    vlcDisabled && avDisabled && ksPipEnabled && allOrientations &&
                    rotationChanged && rotationReturned;
                self.resultLabel.text = [NSString stringWithFormat:
                    @"%@\n\nRotate button: %@\nPiP button: %@\nPiP action: %@\nAuto PiP: %@\nNative auto PiP: %@\nKS subclass hook: %@\nKS render handoff: %@\nKS native bridge: %@\nKSPlayer default: %@\nKS PiP enabled: %@\nOrientation hook: %@\nFirst toggle: %@\nSecond toggle: %@",
                    passed ? @"PASS" : @"FAIL",
                    buttonFound ? @"FOUND" : @"MISSING",
                    pipVisible ? @"VISIBLE" : @"MISSING",
                    pipAction ? @"FIRED" : @"NOT FIRED",
                    automaticPiP ? @"FIRED ONCE" : @"FAILED",
                    nativePiPSupported
                        ? (nativeAutoPiPEnabled ? @"ON" : @"OFF")
                        : @"N/A IN SIMULATOR",
                    ksSubclassHooked ? @"CAPTURED" : @"FAILED",
                    ksRenderHandoff ? @"BACKGROUND + FOREGROUND" : @"FAILED",
                    ksNativeBridge ? @"CONFIG + START" : @"FAILED",
                    (vlcDisabled && avDisabled) ? @"ON" : @"OFF",
                    ksPipEnabled ? @"YES" : @"NO",
                    allOrientations ? @"ALL" : @"LIMITED",
                    rotationChanged ? @"CHANGED" : @"UNCHANGED",
                    rotationReturned ? @"RETURNED" : @"NOT RETURNED"];
                self.resultLabel.textColor = passed ? UIColor.systemGreenColor : UIColor.systemRedColor;

                NSLog(@"[EnhancerHarness] %@ rotate=%d pip=%d pipAction=%d autoPiP=%d nativeAuto=%d ksSubclass=%d ksRender=%d ksNative=%d ks=%d ksPip=%d orientations=%lu first=%d second=%d",
                      passed ? @"PASS" : @"FAIL", buttonFound, pipVisible, pipAction, automaticPiP,
                      nativeAutoPiPEnabled, ksSubclassHooked, ksRenderHandoff, ksNativeBridge,
                      vlcDisabled && avDisabled, ksPipEnabled,
                      (unsigned long)self.supportedInterfaceOrientations,
                      rotationChanged, rotationReturned);
            });
        });
    });
}

@end

@interface SPEHarnessAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end


@implementation SPEHarnessAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[SPEMockPlayerViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SPEHarnessAppDelegate.class));
    }
}
