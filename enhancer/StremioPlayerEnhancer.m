#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static NSString *const SPEConfiguredDefaultsKey = @"StremioPlayerEnhancerConfiguredV7";
static NSString *const SPEUseVLCKey = @"useVLCKit";
static NSString *const SPEUseAVPlayerKey = @"useAVPlayer";
static NSString *const SPEAnyRotationKey = @"anyRotationOnVideo";
static NSString *const SPEDisableKSPiPKey = @"disableKSSampleBufferPictureInPictureSupport";

static const void *SPERotationButtonKey = &SPERotationButtonKey;
static const void *SPEButtonOrientationKey = &SPEButtonOrientationKey;
static const void *SPEPiPButtonKey = &SPEPiPButtonKey;
static const void *SPEAutoPiPObserverKey = &SPEAutoPiPObserverKey;
static const void *SPEAutoPiPInFlightKey = &SPEAutoPiPInFlightKey;
static const void *SPEOwnedPiPControllerKey = &SPEOwnedPiPControllerKey;
static const void *SPEOwnedPiPDelegateKey = &SPEOwnedPiPDelegateKey;
static const void *SPEOwnedPiPLayerKey = &SPEOwnedPiPLayerKey;
static const void *SPEOwnedKSPlayerKey = &SPEOwnedKSPlayerKey;
static const void *SPEOwnedKSPlayerLayerKey = &SPEOwnedKSPlayerLayerKey;
static const void *SPEPiPDiscoveryStateKey = &SPEPiPDiscoveryStateKey;
static IMP SPEOriginalControlsLayout = NULL;
static IMP SPEOriginalPiPInitWithContentSource = NULL;
static IMP SPEOriginalPiPInitWithPlayerLayer = NULL;
static IMP SPEOriginalKSPiPInitWithContentSource = NULL;
static IMP SPEOriginalPiPStart = NULL;
static NSHashTable<AVPictureInPictureController *> *SPEPiPControllers = nil;

static void SPEConfigurePiPController(AVPictureInPictureController *controller);
static void SPESetKSPlayerBackgroundState(id player, BOOL background);

#if defined(__arm64__)
// Native Swift instance methods receive `self` in x20. This tiny ABI bridge
// preserves the caller's callee-saved register while invoking an exported
// no-argument KSPlayer method discovered with dlsym.
__asm__(
    ".text\n"
    ".p2align 2\n"
    ".private_extern _SPECallSwiftVoidMethod\n"
    "_SPECallSwiftVoidMethod:\n"
    "stp x20, x30, [sp, #-16]!\n"
    "mov x16, x0\n"
    "mov x20, x1\n"
    "blr x16\n"
    "ldp x20, x30, [sp], #16\n"
    "ret\n"
    ".p2align 2\n"
    ".private_extern _SPECallSwiftVoidMethodWithObject\n"
    "_SPECallSwiftVoidMethodWithObject:\n"
    "stp x20, x30, [sp, #-16]!\n"
    "mov x16, x0\n"
    "mov x20, x1\n"
    "mov x0, x2\n"
    "blr x16\n"
    "ldp x20, x30, [sp], #16\n"
    "ret\n"
);
extern void SPECallSwiftVoidMethod(void *function, void *object);
extern void SPECallSwiftVoidMethodWithObject(void *function, void *object,
                                             void *argument);
#endif

@interface SPEPictureInPictureDelegate : NSObject <AVPictureInPictureControllerDelegate>
@property(nonatomic, weak) id controls;
@property(nonatomic, strong) id playbackDelegate;
@property(nonatomic, assign) BOOL ksBackgroundActive;
@end

@implementation SPEPictureInPictureDelegate

- (void)pictureInPictureControllerWillStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    (void)pictureInPictureController;
    if (!self.ksBackgroundActive) {
        SPESetKSPlayerBackgroundState(self.playbackDelegate, YES);
        self.ksBackgroundActive = YES;
    }
    NSLog(@"[StremioPlayerEnhancer] Native PiP will start");
}

- (void)pictureInPictureControllerDidStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    (void)pictureInPictureController;
    NSLog(@"[StremioPlayerEnhancer] Native PiP did start");
}

- (void)pictureInPictureControllerDidStopPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    (void)pictureInPictureController;
    if (self.ksBackgroundActive) {
        SPESetKSPlayerBackgroundState(self.playbackDelegate, NO);
        self.ksBackgroundActive = NO;
    }
    id controls = self.controls;
    if (controls != nil) {
        objc_setAssociatedObject(controls, SPEAutoPiPInFlightKey, @NO,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSLog(@"[StremioPlayerEnhancer] Native PiP did stop");
}

- (void)pictureInPictureController:
    (AVPictureInPictureController *)pictureInPictureController
 failedToStartPictureInPictureWithError:(NSError *)error {
    (void)pictureInPictureController;
    if (self.ksBackgroundActive) {
        SPESetKSPlayerBackgroundState(self.playbackDelegate, NO);
        self.ksBackgroundActive = NO;
    }
    id controls = self.controls;
    if (controls != nil) {
        objc_setAssociatedObject(controls, SPEAutoPiPInFlightKey, @NO,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSLog(@"[StremioPlayerEnhancer] Native PiP failed: %@", error.localizedDescription);
}

- (void)pictureInPictureController:
    (AVPictureInPictureController *)pictureInPictureController
 restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:
    (void (^)(BOOL restored))completionHandler {
    (void)pictureInPictureController;
    completionHandler(YES);
}

@end

static void SPESetKSPlayerBackgroundState(id player, BOOL background) {
    if (player == nil) {
        return;
    }
#if defined(__arm64__)
    const char *symbol = background
        ? "$s8KSPlayer10KSMEPlayerC15enterBackgroundyyF"
        : "$s8KSPlayer10KSMEPlayerC15enterForegroundyyF";
    void *function = dlsym(RTLD_DEFAULT, symbol);
    if (function == NULL) {
        NSLog(@"[StremioPlayerEnhancer] KSPlayer %@ render transition unavailable",
              background ? @"background" : @"foreground");
        return;
    }
    SPECallSwiftVoidMethod(function, (__bridge void *)player);
    NSLog(@"[StremioPlayerEnhancer] KSPlayer %@ render transition applied",
          background ? @"background" : @"foreground");
#else
    (void)background;
#endif
}

#if TARGET_OS_SIMULATOR && defined(__arm64__)
// Simulator-only ABI probe used by the harness. The real methods are supplied
// by small assembly test doubles in the harness executable.
__attribute__((visibility("default")))
BOOL SPETestKSNativePiPBridge(id player, id playerLayer) {
    void *configure = dlsym(
        RTLD_DEFAULT, "$s8KSPlayer10KSMEPlayerC9configPIPyyF");
    void *start = dlsym(
        RTLD_DEFAULT,
        "$s8KSPlayer28KSPictureInPictureControllerC5start5layeryAA20KSComplexPlayerLayerC_tF");
    if (configure == NULL || start == NULL || player == nil || playerLayer == nil) {
        return NO;
    }
    SPECallSwiftVoidMethod(configure, (__bridge void *)player);
    SPECallSwiftVoidMethodWithObject(start, (__bridge void *)player,
                                    (__bridge void *)playerLayer);
    return YES;
}
#endif

static Class SPEClass(NSString *swiftName, const char *runtimeName) {
    Class cls = NSClassFromString(swiftName);
    return cls ?: objc_getClass(runtimeName);
}

static UIViewController *SPEOwningViewController(UIResponder *responder) {
    UIResponder *candidate = responder;
    while (candidate != nil) {
        if ([candidate isKindOfClass:UIViewController.class]) {
            return (UIViewController *)candidate;
        }
        candidate = candidate.nextResponder;
    }
    return nil;
}

static UIImage *SPERotationImageForOrientation(UIInterfaceOrientation orientation) {
    NSString *symbol = UIInterfaceOrientationIsLandscape(orientation)
        ? @"rectangle.portrait.rotate"
        : @"rectangle.landscape.rotate";
    UIImage *image = [UIImage systemImageNamed:symbol];
    return image ?: [UIImage systemImageNamed:@"rotate.right"];
}

static void SPEUpdateRotationButton(UIButton *button, UIWindowScene *scene) {
    if (button == nil || scene == nil) {
        return;
    }

    BOOL landscape = UIInterfaceOrientationIsLandscape(scene.interfaceOrientation);
    NSNumber *previousLandscape = objc_getAssociatedObject(button, SPEButtonOrientationKey);
    if (previousLandscape != nil && previousLandscape.boolValue == landscape) {
        return;
    }

    [button setImage:SPERotationImageForOrientation(scene.interfaceOrientation)
            forState:UIControlStateNormal];
    button.accessibilityValue = landscape
        ? @"Switch to portrait"
        : @"Switch to landscape";
    objc_setAssociatedObject(button, SPEButtonOrientationKey, @(landscape),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SPEShowRotationError(UIButton *button) {
    UIColor *oldColor = button.tintColor;
    button.tintColor = UIColor.systemRedColor;
    [UIView animateWithDuration:0.25
                          delay:0.5
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ button.tintColor = oldColor ?: UIColor.whiteColor; }
                     completion:nil];
}

static void SPEToggleOrientation(id self, SEL _cmd, UIButton *button) {
    (void)_cmd;
    UIView *controlsView = [self isKindOfClass:UIView.class] ? (UIView *)self : nil;
    UIWindowScene *scene = controlsView.window.windowScene;
    UIViewController *playerController = SPEOwningViewController(controlsView);

    if (scene == nil || playerController == nil) {
        SPEShowRotationError(button);
        return;
    }

    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:SPEAnyRotationKey];

    if (@available(iOS 16.0, *)) {
        [playerController setNeedsUpdateOfSupportedInterfaceOrientations];
        [playerController.view.window.rootViewController
            setNeedsUpdateOfSupportedInterfaceOrientations];

        UIInterfaceOrientationMask target = UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)
            ? UIInterfaceOrientationMaskPortrait
            : UIInterfaceOrientationMaskLandscapeRight;
        UIWindowSceneGeometryPreferencesIOS *preferences =
            [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:target];

        __weak UIButton *weakButton = button;
        __weak UIWindowScene *weakScene = scene;
        [scene requestGeometryUpdateWithPreferences:preferences
                                       errorHandler:^(NSError *error) {
            NSLog(@"[StremioPlayerEnhancer] Rotation request failed: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{ SPEShowRotationError(weakButton); });
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SPEUpdateRotationButton(weakButton, weakScene);
        });
    } else {
        // Geometry requests that override sensor Rotation Lock require iOS 16.
        SPEShowRotationError(button);
    }
}

static UIInterfaceOrientationMask SPEPlayerSupportedOrientations(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return UIInterfaceOrientationMaskAll;
}

static BOOL SPEPlayerShouldAutorotate(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return YES;
}

static UIStackView *SPEControlsStack(id controls) {
    Ivar ivar = class_getInstanceVariable(object_getClass(controls), "controlsStack");
    if (ivar == NULL) {
        ivar = class_getInstanceVariable([controls class], "controlsStack");
    }
    id value = ivar ? object_getIvar(controls, ivar) : nil;
    return [value isKindOfClass:UIStackView.class] ? (UIStackView *)value : nil;
}

static UIButton *SPEButtonFromIvar(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable([object class], name);
    id value = ivar ? object_getIvar(object, ivar) : nil;
    return [value isKindOfClass:UIButton.class] ? (UIButton *)value : nil;
}

static id SPEFirstObjectWordFromIvar(id object, const char *name) {
    if (object == nil) {
        return nil;
    }
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (ivar == NULL) {
        return nil;
    }

    uint8_t *bytes = (__bridge void *)object;
    void *value = *(void **)(bytes + ivar_getOffset(ivar));
    return (__bridge id)value;
}

static AVSampleBufferDisplayLayer *SPEFindSampleBufferLayer(CALayer *root) {
    if ([root isKindOfClass:AVSampleBufferDisplayLayer.class]) {
        return (AVSampleBufferDisplayLayer *)root;
    }
    for (CALayer *sublayer in root.sublayers) {
        AVSampleBufferDisplayLayer *match = SPEFindSampleBufferLayer(sublayer);
        if (match != nil) {
            return match;
        }
    }
    return nil;
}

static void SPELogPiPDiscovery(id controls, NSString *state) {
    NSString *previous = objc_getAssociatedObject(controls, SPEPiPDiscoveryStateKey);
    if ([previous isEqualToString:state]) {
        return;
    }
    objc_setAssociatedObject(controls, SPEPiPDiscoveryStateKey, state,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSLog(@"[StremioPlayerEnhancer] PiP discovery %@", state);
}

static id SPEKSPlaybackDelegate(id controls, id *playerLayerOut,
                                UIView **playerViewOut) API_AVAILABLE(ios(15.0)) {
    UIView *controlsView = [controls isKindOfClass:UIView.class] ? controls : nil;
    UIViewController *playerController = SPEOwningViewController(controlsView);
    id manager = SPEFirstObjectWordFromIvar(playerController, "playerManager");
    id playerLayer = SPEFirstObjectWordFromIvar(manager, "playerItem");
    id player = SPEFirstObjectWordFromIvar(playerLayer, "player");
    UIView *playerView = SPEFirstObjectWordFromIvar(playerController, "playerView");

    if (playerLayerOut != NULL) {
        *playerLayerOut = playerLayer;
    }
    if (playerViewOut != NULL) {
        *playerViewOut = [playerView isKindOfClass:UIView.class]
            ? playerView
            : playerController.view;
    }

    Protocol *protocol = @protocol(AVPictureInPictureSampleBufferPlaybackDelegate);
    if (player != nil && [player conformsToProtocol:protocol]) {
        return player;
    }

    NSString *managerName = manager ? NSStringFromClass([manager class]) : @"none";
    NSString *layerName = playerLayer ? NSStringFromClass([playerLayer class]) : @"none";
    NSString *playerName = player ? NSStringFromClass([player class]) : @"none";
    SPELogPiPDiscovery(controls, [NSString stringWithFormat:
        @"delegate-missing manager=%@ layer=%@ player=%@",
        managerName, layerName, playerName]);
    return nil;
}

static BOOL SPEIsKSNativePiPController(id controller) {
    if (![controller isKindOfClass:AVPictureInPictureController.class]) {
        return NO;
    }
    return [NSStringFromClass([controller class])
        containsString:@"KSPictureInPictureController"];
}

static AVPictureInPictureController *SPEFindCapturedKSNativePiPController(void) {
    for (AVPictureInPictureController *controller in SPEPiPControllers.allObjects) {
        if (SPEIsKSNativePiPController(controller)) {
            return controller;
        }
    }
    return nil;
}

static AVPictureInPictureController *SPEEnsureKSNativePiPController(
    id controls, id playerLayer, id playbackDelegate) {
    AVPictureInPictureController *existing =
        objc_getAssociatedObject(controls, SPEOwnedPiPControllerKey);
    id existingPlayer = objc_getAssociatedObject(controls, SPEOwnedKSPlayerKey);
    id existingPlayerLayer =
        objc_getAssociatedObject(controls, SPEOwnedKSPlayerLayerKey);
    if (existingPlayer == playbackDelegate && existingPlayerLayer == playerLayer &&
        SPEIsKSNativePiPController(existing)) {
        return existing;
    }

#if defined(__arm64__)
    void *configure = dlsym(
        RTLD_DEFAULT, "$s8KSPlayer10KSMEPlayerC9configPIPyyF");
    if (configure == NULL) {
        SPELogPiPDiscovery(controls, @"ks-native-config-unavailable");
        return nil;
    }

    // Ask the exact KSMEPlayer instance to create and retain its own concrete
    // KSPictureInPictureController. The initializer hook captures that object.
    SPECallSwiftVoidMethod(configure, (__bridge void *)playbackDelegate);
    AVPictureInPictureController *controller =
        SPEFindCapturedKSNativePiPController();

    // The stored protocol existential starts with its class instance. This is
    // only a safety net in case a future initializer no longer reaches our
    // Objective-C hook.
    if (controller == nil) {
        id storedController = SPEFirstObjectWordFromIvar(
            playbackDelegate, "pipController");
        if (SPEIsKSNativePiPController(storedController)) {
            controller = storedController;
        }
    }

    if (controller == nil) {
        SPELogPiPDiscovery(controls, @"ks-native-controller-missing");
        return nil;
    }

    SPEConfigurePiPController(controller);
    objc_setAssociatedObject(controls, SPEOwnedPiPControllerKey, controller,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, SPEOwnedKSPlayerKey, playbackDelegate,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, SPEOwnedKSPlayerLayerKey, playerLayer,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, SPEOwnedPiPDelegateKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPELogPiPDiscovery(controls, [NSString stringWithFormat:
        @"ks-native-controller-ready layer=%@ player=%@ controller=%@ possible=%d",
        playerLayer ? NSStringFromClass([playerLayer class]) : @"none",
        NSStringFromClass([playbackDelegate class]),
        NSStringFromClass([controller class]),
        controller.pictureInPicturePossible]);
    return controller;
#else
    (void)playerLayer;
    (void)playbackDelegate;
    return nil;
#endif
}

static AVPictureInPictureController *SPEEnsureOwnedPiPController(id controls) {
    if (@available(iOS 15.0, *)) {
        id playerLayer = nil;
        UIView *playerView = nil;
        id playbackDelegate = SPEKSPlaybackDelegate(controls, &playerLayer, &playerView);
        if (playbackDelegate == nil) {
            return nil;
        }

        AVPictureInPictureController *nativeController =
            SPEEnsureKSNativePiPController(controls, playerLayer, playbackDelegate);
        if (nativeController != nil) {
            return nativeController;
        }

        AVSampleBufferDisplayLayer *displayLayer =
            SPEFindSampleBufferLayer(playerView.layer);
        if (displayLayer == nil) {
            if (playbackDelegate != nil) {
                SPELogPiPDiscovery(controls, @"sample-buffer-layer-missing");
            }
            return nil;
        }

        AVPictureInPictureController *existing =
            objc_getAssociatedObject(controls, SPEOwnedPiPControllerKey);
        AVSampleBufferDisplayLayer *existingLayer =
            objc_getAssociatedObject(controls, SPEOwnedPiPLayerKey);
        if (existing != nil && existingLayer == displayLayer) {
            return existing;
        }
        if (existing.pictureInPictureActive) {
            return existing;
        }

        AVPictureInPictureControllerContentSource *contentSource =
            [[AVPictureInPictureControllerContentSource alloc]
                initWithSampleBufferDisplayLayer:displayLayer
                                playbackDelegate:playbackDelegate];
        AVPictureInPictureController *controller =
            [[AVPictureInPictureController alloc] initWithContentSource:contentSource];
        if (controller == nil) {
            SPELogPiPDiscovery(controls, @"controller-init-failed");
            return nil;
        }

        SPEPictureInPictureDelegate *delegate = [[SPEPictureInPictureDelegate alloc] init];
        delegate.controls = controls;
        delegate.playbackDelegate = playbackDelegate;
        controller.delegate = delegate;
        SPEConfigurePiPController(controller);

        objc_setAssociatedObject(controls, SPEOwnedPiPControllerKey, controller,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controls, SPEOwnedPiPDelegateKey, delegate,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controls, SPEOwnedPiPLayerKey, displayLayer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controls, SPEOwnedKSPlayerKey, playbackDelegate,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controls, SPEOwnedKSPlayerLayerKey, playerLayer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SPELogPiPDiscovery(controls, [NSString stringWithFormat:
            @"owned-controller-ready manager=%@ layer=%@ player=%@ possible=%d",
            NSStringFromClass([SPEFirstObjectWordFromIvar(
                SPEOwningViewController((UIView *)controls), "playerManager") class]),
            playerLayer ? NSStringFromClass([playerLayer class]) : @"none",
            NSStringFromClass([playbackDelegate class]),
            controller.pictureInPicturePossible]);
        return controller;
    }
    return nil;
}

static void SPEConfigurePiPController(AVPictureInPictureController *controller) {
    if (controller == nil) {
        return;
    }

    if (@available(iOS 14.2, *)) {
        controller.canStartPictureInPictureAutomaticallyFromInline = YES;
    }

    if (SPEPiPControllers == nil) {
        SPEPiPControllers = [NSHashTable weakObjectsHashTable];
    }
    BOOL alreadyCaptured = [SPEPiPControllers containsObject:controller];
    [SPEPiPControllers addObject:controller];
    if (!alreadyCaptured) {
        NSLog(@"[StremioPlayerEnhancer] Captured native PiP controller class=%@ (possible=%d)",
              NSStringFromClass(controller.class), controller.pictureInPicturePossible);
    }
}

static id SPEPiPInitWithContentSource(id self, SEL _cmd, id contentSource) {
    id controller = ((id (*)(id, SEL, id))SPEOriginalPiPInitWithContentSource)(
        self, _cmd, contentSource);
    SPEConfigurePiPController(controller);
    return controller;
}

static id SPEPiPInitWithPlayerLayer(id self, SEL _cmd, id playerLayer) {
    id controller = ((id (*)(id, SEL, id))SPEOriginalPiPInitWithPlayerLayer)(
        self, _cmd, playerLayer);
    SPEConfigurePiPController(controller);
    return controller;
}

static id SPEKSPiPInitWithContentSource(id self, SEL _cmd, id contentSource) {
    id controller = ((id (*)(id, SEL, id))SPEOriginalKSPiPInitWithContentSource)(
        self, _cmd, contentSource);
    SPEConfigurePiPController(controller);
    return controller;
}

static void SPEPiPStart(id self, SEL _cmd) {
    // KSPlayer's PiP controller overrides initWithContentSource:, so a hook on
    // AVKit's base initializer alone cannot see it. Capturing at the common
    // start method is a second safety net for this and future subclasses.
    SPEConfigurePiPController(self);
    ((void (*)(id, SEL))SPEOriginalPiPStart)(self, _cmd);
}

static AVPictureInPictureController *SPEBestPiPController(void) {
    AVPictureInPictureController *fallback = nil;
    for (AVPictureInPictureController *controller in SPEPiPControllers.allObjects) {
        if (controller.pictureInPictureActive) {
            return controller;
        }
        if (controller.pictureInPicturePossible) {
            return controller;
        }
        fallback = controller;
    }
    return fallback;
}

static BOOL SPEStartCapturedPiP(id controls) {
    AVPictureInPictureController *ownedController =
        objc_getAssociatedObject(controls, SPEOwnedPiPControllerKey);
    AVPictureInPictureController *controller =
        ownedController ?: SPEBestPiPController();
    if (controller == nil) {
        return NO;
    }

    SPEConfigurePiPController(controller);
    if (controller.pictureInPictureActive) {
        return YES;
    }
    if (!controller.pictureInPicturePossible) {
        return NO;
    }

    id playerLayer = objc_getAssociatedObject(controls, SPEOwnedKSPlayerLayerKey);
    if (controller == ownedController && SPEIsKSNativePiPController(controller) &&
        playerLayer != nil) {
#if defined(__arm64__)
        void *start = dlsym(
            RTLD_DEFAULT,
            "$s8KSPlayer28KSPictureInPictureControllerC5start5layeryAA20KSComplexPlayerLayerC_tF");
        if (start == NULL) {
            NSLog(@"[StremioPlayerEnhancer] KSPlayer native PiP start unavailable");
            return NO;
        }
        SPECallSwiftVoidMethodWithObject(start, (__bridge void *)controller,
                                        (__bridge void *)playerLayer);
        NSLog(@"[StremioPlayerEnhancer] Started KSPlayer native PiP pipeline");
        return YES;
#else
        return NO;
#endif
    }

    [controller startPictureInPicture];
    NSLog(@"[StremioPlayerEnhancer] Started fallback AVKit PiP controller");
    return YES;
}

static void SPELogPiPState(id controls, NSString *source) {
    AVPictureInPictureController *controller =
        objc_getAssociatedObject(controls, SPEOwnedPiPControllerKey);
    controller = controller ?: SPEBestPiPController();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSLog(@"[StremioPlayerEnhancer] PiP %@ controllers=%lu class=%@ possible=%d active=%d "
          "vlc=%d av=%d ksDisabled=%d supported=%d",
          source, (unsigned long)SPEPiPControllers.allObjects.count,
          controller ? NSStringFromClass(controller.class) : @"none",
          controller.pictureInPicturePossible, controller.pictureInPictureActive,
          [defaults boolForKey:SPEUseVLCKey], [defaults boolForKey:SPEUseAVPlayerKey],
          [defaults boolForKey:SPEDisableKSPiPKey],
          AVPictureInPictureController.isPictureInPictureSupported);
}

static void SPEInvokeStremioPiPFallback(id controls, UIButton *button) {
    SEL selector = NSSelectorFromString(@"onPipClicked:");
    Method method = class_getInstanceMethod([controls class], selector);
    if (method != NULL) {
        ((void (*)(id, SEL, id))method_getImplementation(method))(
            controls, selector, button);
    }
}

static void SPERetryPiPStart(id controls, UIButton *button, NSUInteger attempt) {
    if (SPEStartCapturedPiP(controls)) {
        return;
    }
    if (attempt >= 6) {
        SPEShowRotationError(button);
        objc_setAssociatedObject(controls, SPEAutoPiPInFlightKey, @NO,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[StremioPlayerEnhancer] Native PiP remained unavailable");
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SPERetryPiPStart(controls, button, attempt + 1);
    });
}

static void SPETogglePictureInPicture(id self, SEL _cmd, UIButton *button) {
    (void)_cmd;
    SPEEnsureOwnedPiPController(self);
    SPELogPiPState(self, @"button-tap");
    AVPictureInPictureController *controller =
        objc_getAssociatedObject(self, SPEOwnedPiPControllerKey);
    controller = controller ?: SPEBestPiPController();
    if (controller.pictureInPictureActive) {
        [controller stopPictureInPicture];
        return;
    }

    if (SPEStartCapturedPiP(self)) {
        return;
    }

    // Let Stremio/KSPlayer lazily create its controller, then start that
    // controller directly as soon as AVKit marks it possible.
    SPEInvokeStremioPiPFallback(self, button);
    SPERetryPiPStart(self, button, 0);
}

static void SPEStartPiPIfNeeded(id controls) {
    if ([objc_getAssociatedObject(controls, SPEAutoPiPInFlightKey) boolValue]) {
        return;
    }

    UIButton *button = objc_getAssociatedObject(controls, SPEPiPButtonKey);
    if (button == nil) {
        button = SPEButtonFromIvar(controls, "pictureInPictureButton");
    }

    UIView *controlsView = [controls isKindOfClass:UIView.class] ? (UIView *)controls : nil;
    if (button == nil || controlsView.window == nil || button.hidden || !button.enabled) {
        return;
    }

    SPEEnsureOwnedPiPController(controls);
    objc_setAssociatedObject(controls, SPEAutoPiPInFlightKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPELogPiPState(controls, @"background");
    if (!SPEStartCapturedPiP(controls)) {
        SPEInvokeStremioPiPFallback(controls, button);
        SPERetryPiPStart(controls, button, 0);
    }
    NSLog(@"[StremioPlayerEnhancer] Requested automatic Picture in Picture");
}

static void SPEApplicationWillResignActive(id self, SEL _cmd, NSNotification *notification) {
    (void)_cmd;
    (void)notification;

    // WillResignActive is also sent for Control Centre and system overlays.
    // Wait briefly and start PiP only if this became a real background exit.
    __weak id weakControls = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
            SPEStartPiPIfNeeded(weakControls);
        }
    });
}

static void SPEApplicationDidEnterBackground(id self, SEL _cmd, NSNotification *notification) {
    (void)_cmd;
    (void)notification;
    SPEStartPiPIfNeeded(self);
}

static void SPEApplicationWillEnterForeground(id self, SEL _cmd, NSNotification *notification) {
    (void)_cmd;
    (void)notification;
    objc_setAssociatedObject(self, SPEAutoPiPInFlightKey, @NO,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SPEInstallAutomaticPiP(id controls) {
    if ([objc_getAssociatedObject(controls, SPEAutoPiPObserverKey) boolValue]) {
        return;
    }

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:controls
               selector:NSSelectorFromString(@"spe_applicationWillResignActive:")
                   name:UIApplicationWillResignActiveNotification
                 object:nil];
    [center addObserver:controls
               selector:NSSelectorFromString(@"spe_applicationDidEnterBackground:")
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
    [center addObserver:controls
               selector:NSSelectorFromString(@"spe_applicationWillEnterForeground:")
                   name:UIApplicationWillEnterForegroundNotification
                 object:nil];

    objc_setAssociatedObject(controls, SPEAutoPiPObserverKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SPEInstallPiPButton(id controls) {
    UIStackView *stack = SPEControlsStack(controls);
    if (stack == nil) {
        return;
    }

    UIButton *button = objc_getAssociatedObject(controls, SPEPiPButtonKey);
    if (button == nil) {
        // Stremio 2.0.3 already creates a correctly wired PiP button but hides
        // it whenever the selected player manager reports PiP unavailable.
        // Reuse that control so the app's own PlayerManagerPiP lifecycle,
        // restoration, audio-session and progress handling remain intact.
        button = SPEButtonFromIvar(controls, "pictureInPictureButton");
    }

    if (button == nil) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setImage:[UIImage systemImageNamed:@"pip.enter"]
                forState:UIControlStateNormal];
        [button addTarget:controls
                   action:NSSelectorFromString(@"spe_togglePictureInPicture:")
         forControlEvents:UIControlEventTouchUpInside];
    }

    // Replace Stremio's manager-gated action with the native controller path.
    // The original action is still invoked as a lazy-initialization fallback.
    [button removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [button addTarget:controls
               action:NSSelectorFromString(@"spe_togglePictureInPicture:")
     forControlEvents:UIControlEventTouchUpInside];

    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.hidden = NO;
    button.alpha = 1.0;
    button.enabled = YES;
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = @"Picture in Picture";
    button.accessibilityIdentifier = @"stremio-player-pip-button";

    if (![stack.arrangedSubviews containsObject:button]) {
        [stack addArrangedSubview:button];
    }

    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *configuration = button.configuration;
        if (configuration == nil) {
            configuration = [UIButtonConfiguration plainButtonConfiguration];
        }
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(8, 8, 8, 8);
        button.configuration = configuration;
    }

    if (button.constraints.count == 0) {
        [NSLayoutConstraint activateConstraints:@[
            [button.widthAnchor constraintGreaterThanOrEqualToConstant:44.0],
            [button.heightAnchor constraintEqualToConstant:44.0],
        ]];
    }

    objc_setAssociatedObject(controls, SPEPiPButtonKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPEEnsureOwnedPiPController(controls);
}

static void SPEInstallRotationButton(id controls) {
    if (objc_getAssociatedObject(controls, SPERotationButtonKey) != nil) {
        UIButton *button = objc_getAssociatedObject(controls, SPERotationButtonKey);
        SPEUpdateRotationButton(button, ((UIView *)controls).window.windowScene);
        return;
    }

    UIStackView *stack = SPEControlsStack(controls);
    if (stack == nil) {
        return;
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = @"Rotate video";
    button.accessibilityIdentifier = @"stremio-player-rotate-button";
    [button addTarget:controls
               action:NSSelectorFromString(@"spe_toggleOrientation:")
     forControlEvents:UIControlEventTouchUpInside];

    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(8, 8, 8, 8);
        button.configuration = configuration;
    }

    [stack addArrangedSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:44.0],
        [button.heightAnchor constraintEqualToConstant:44.0],
    ]];

    objc_setAssociatedObject(controls, SPERotationButtonKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPEUpdateRotationButton(button, ((UIView *)controls).window.windowScene);
}

static void SPEControlsLayout(id self, SEL _cmd) {
    if (SPEOriginalControlsLayout != NULL) {
        ((void (*)(id, SEL))SPEOriginalControlsLayout)(self, _cmd);
    }
    SPEInstallPiPButton(self);
    SPEInstallAutomaticPiP(self);
    SPEInstallRotationButton(self);
}

static void SPEConfigurePlayerDefaults(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:SPEConfiguredDefaultsKey]) {
        return;
    }

    // Stremio's default KSPlayer path is hardware accelerated and implements
    // native sample-buffer PiP. MobileVLCKit remains available in Settings as
    // a compatibility fallback, but it cannot supply native PiP in this build.
    [defaults setBool:NO forKey:SPEUseVLCKey];
    [defaults setBool:NO forKey:SPEUseAVPlayerKey];
    [defaults setBool:NO forKey:SPEDisableKSPiPKey];
    [defaults setBool:YES forKey:SPEAnyRotationKey];
    [defaults setBool:YES forKey:SPEConfiguredDefaultsKey];
}

static void SPEInstallAVKitHooks(void) {
    Class pipClass = AVPictureInPictureController.class;
    Method contentSourceInitializer = class_getInstanceMethod(
        pipClass, NSSelectorFromString(@"initWithContentSource:"));
    if (contentSourceInitializer != NULL &&
        method_getImplementation(contentSourceInitializer) != (IMP)SPEPiPInitWithContentSource) {
        SPEOriginalPiPInitWithContentSource = method_setImplementation(
            contentSourceInitializer, (IMP)SPEPiPInitWithContentSource);
    }
    Method playerLayerInitializer = class_getInstanceMethod(
        pipClass, @selector(initWithPlayerLayer:));
    if (playerLayerInitializer != NULL &&
        method_getImplementation(playerLayerInitializer) != (IMP)SPEPiPInitWithPlayerLayer) {
        SPEOriginalPiPInitWithPlayerLayer = method_setImplementation(
            playerLayerInitializer, (IMP)SPEPiPInitWithPlayerLayer);
    }

    Method startMethod = class_getInstanceMethod(
        pipClass, @selector(startPictureInPicture));
    if (startMethod != NULL &&
        method_getImplementation(startMethod) != (IMP)SPEPiPStart) {
        SPEOriginalPiPStart = method_setImplementation(startMethod, (IMP)SPEPiPStart);
    }

    // KSPlayer 2.3.x ships an AVPictureInPictureController subclass with its
    // own initWithContentSource: implementation. Hook that concrete method so
    // the controller is captured as soon as KSMEPlayer lazily creates it.
    Class ksPiPClass = SPEClass(@"KSPlayer.KSPictureInPictureController",
                                "_TtC8KSPlayer28KSPictureInPictureController");
    Method ksContentSourceInitializer = ksPiPClass == Nil ? NULL :
        class_getInstanceMethod(ksPiPClass, NSSelectorFromString(@"initWithContentSource:"));
    if (ksContentSourceInitializer != NULL) {
        IMP implementation = method_getImplementation(ksContentSourceInitializer);
        if (implementation != (IMP)SPEKSPiPInitWithContentSource &&
            implementation != (IMP)SPEPiPInitWithContentSource) {
            SPEOriginalKSPiPInitWithContentSource = method_setImplementation(
                ksContentSourceInitializer, (IMP)SPEKSPiPInitWithContentSource);
            NSLog(@"[StremioPlayerEnhancer] Hooked KSPlayer native PiP controller");
        }
    }
}

static void SPEInstallHooks(void) {
    Class controlsClass = SPEClass(@"Stremio.VideoControlsView",
                                   "_TtC7Stremio17VideoControlsView");
    if (controlsClass != Nil) {
        class_addMethod(controlsClass,
                        NSSelectorFromString(@"spe_toggleOrientation:"),
                        (IMP)SPEToggleOrientation,
                        "v@:@");
        class_addMethod(controlsClass,
                        NSSelectorFromString(@"spe_togglePictureInPicture:"),
                        (IMP)SPETogglePictureInPicture,
                        "v@:@");
        class_addMethod(controlsClass,
                        NSSelectorFromString(@"spe_applicationWillResignActive:"),
                        (IMP)SPEApplicationWillResignActive,
                        "v@:@");
        class_addMethod(controlsClass,
                        NSSelectorFromString(@"spe_applicationDidEnterBackground:"),
                        (IMP)SPEApplicationDidEnterBackground,
                        "v@:@");
        class_addMethod(controlsClass,
                        NSSelectorFromString(@"spe_applicationWillEnterForeground:"),
                        (IMP)SPEApplicationWillEnterForeground,
                        "v@:@");

        Method layout = class_getInstanceMethod(controlsClass, @selector(layoutSubviews));
        if (layout != NULL && method_getImplementation(layout) != (IMP)SPEControlsLayout) {
            SPEOriginalControlsLayout = method_setImplementation(layout, (IMP)SPEControlsLayout);
        }
    }

    Class playerClass = SPEClass(@"Stremio.PlayerViewController",
                                 "_TtC7Stremio20PlayerViewController");
    if (playerClass != Nil) {
        class_addMethod(playerClass, @selector(supportedInterfaceOrientations),
                        (IMP)SPEPlayerSupportedOrientations, "Q@:");
        class_addMethod(playerClass, @selector(shouldAutorotate),
                        (IMP)SPEPlayerShouldAutorotate, "B@:");
    }
}

__attribute__((constructor))
static void SPEBootstrap(void) {
    // Persist the engine choice before Stremio has a chance to initialize and
    // cache its player settings during application startup.
    SPEInstallAVKitHooks();
    SPEConfigurePlayerDefaults();
    dispatch_async(dispatch_get_main_queue(), ^{
        // A dependent dylib's constructor may run before Swift classes in the
        // main executable and bundled frameworks are discoverable by name.
        // Repeating this idempotent install on the first main turn catches the
        // concrete KSPlayer subclass without ever stacking hook wrappers.
        SPEInstallAVKitHooks();
        SPEInstallHooks();
        NSLog(@"[StremioPlayerEnhancer] Loaded");
    });
}
