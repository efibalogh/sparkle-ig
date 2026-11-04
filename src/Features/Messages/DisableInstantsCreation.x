#import "SPKStrings.h"
// Instants (QuickSnap) creation controls.
//
// Three user-facing behaviours:
//   - Disable Instants Creation  -> hard-block capture (photo AND video). The
//                                    shutter is darkened, the whole
//                                    IGCameraCaptureButtonDelegate surface is
//                                    swallowed (so press-and-hold can't record),
//                                    and the hardware Camera Control is disabled.
//   - Confirm Instant Videos      -> let video finalization finish, then hold
//                                    only Instagram's send continuation while
//                                    asking for confirmation.
//   - Skip Camera After Instants  -> skip the camera IG auto-opens after the last
//                                    received Instant is viewed.
//
// Why gate the continuation, not the shutter: video finalization supplies a
// completion block after its asset writer has finished. Holding that block does
// not alter when recording starts or which frames enter the finished clip.

#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <substrate.h>

#import "../../Settings/SPKPreferences.h"
#import "../../Shared/Account/SPKAccountManager.h"
#import "../../Shared/Instants/SPKInstantsVideoConfirmation.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Utils.h"

static NSString *const kSPKQuickSnapDisableCreationPref = @"instants_disable_creation";
static NSString *const kSPKQuickSnapConfirmCapturePref = @"instants_confirm_capture";
static NSString *const kSPKQuickSnapDisableCameraControlPref = @"instants_disable_camera_control";
static NSString *const kSPKQuickSnapSkipCameraAfterViewingPref = @"instants_skip_camera_after_viewing";
NSNotificationName const SPKInstantsVideoSendConfirmedNotification = @"SPKInstantsVideoSendConfirmedNotification";

typedef void (*SPKQuickSnapVoidIMP)(id, SEL);
typedef void (*SPKQuickSnapVoidOneArgIMP)(id, SEL, id);
typedef void (*SPKQuickSnapVoidLongLongIMP)(id, SEL, long long);
typedef void (*SPKQuickSnapViewAppearIMP)(id, SEL, _Bool);
typedef void (*SPKQuickSnapLayoutIMP)(id, SEL);

// IGCameraCaptureButtonDelegate surface (QuickSnap camera control view) — used to
// hard-block capture in "Disable Creation" mode only.
static SPKQuickSnapVoidIMP orig_captureButtonDidTouchDown = NULL;
static SPKQuickSnapVoidIMP orig_captureButtonDidBeginExpanding = NULL;
static SPKQuickSnapVoidIMP orig_captureButtonDidEndExpanding = NULL;
static SPKQuickSnapVoidIMP orig_captureButtonDidReleaseBeforeExpandingFinished = NULL;
static SPKQuickSnapVoidIMP orig_captureButtonDidReleaseAfterExpandingFinished = NULL;
static SPKQuickSnapVoidIMP orig_captureButtonDidReleaseFromInterruption = NULL;
static SPKQuickSnapVoidIMP orig_captureButtonDidConfirm = NULL;
static SPKQuickSnapLayoutIMP orig_cameraControlViewLayoutSubviews = NULL;

static SPKQuickSnapVoidOneArgIMP orig_quickSnapPeekViewDidSelectCamera = NULL;
static SPKQuickSnapVoidOneArgIMP orig_cornerStackDidSelectCamera = NULL;
static SPKQuickSnapVoidLongLongIMP orig_didTapCameraButtonWithCameraEntryPoint = NULL;
static SPKQuickSnapVoidIMP orig_headerDidTapCameraButton = NULL;
static SPKQuickSnapViewAppearIMP orig_consumptionViewDidAppear = NULL;
static SPKQuickSnapViewAppearIMP orig_consumptionViewDidDisappear = NULL;
static SPKQuickSnapViewAppearIMP orig_creationViewWillAppear = NULL;

// Skip-camera state. We arm a flag when the consumption (viewing) controller is
// the last thing the user saw, and consume it when the creation camera tries to
// appear — instead of relying on a fragile time window. Explicit camera entry
// (tapping the camera button) clears the flag so we never skip a camera the
// user actually asked for.
static BOOL sSPKQuickSnapConsumptionWasVisible = NO;
static BOOL sSPKQuickSnapSkipNextCreation = NO;
static BOOL sSPKQuickSnapExplicitCameraEntry = NO;

static BOOL sSPKQuickSnapSendConfirmVisible = NO;
static NSUInteger sSPKQuickSnapSendConfirmGeneration = 0;

// The writer may finish off the main thread. Protect the narrow recording flag
// independently; all alert and camera-control state remains main-thread-owned.
static os_unfair_lock sSPKQuickSnapVideoStateLock = OS_UNFAIR_LOCK_INIT;
static BOOL sSPKQuickSnapVideoCaptureArmed = NO;
static NSUInteger sSPKQuickSnapVideoCaptureGeneration = 0;

// Posted by the settings toggle so a visible camera refreshes its darken state
// live (no app or Instants restart needed).
static NSString *const kSPKQuickSnapCreationPrefChangedNotification = @"SPKQuickSnapCreationPrefChangedNotification";

// The currently on-screen camera control view, tracked from its layout pass so a
// live pref change can re-apply the lock state to it immediately.
static __weak UIView *sSPKQuickSnapVisibleControlView = nil;

// Tracks whether the QuickSnap camera UI is currently on screen, so the global
// setEnabled: and asset-writer hooks only act in that context (not the main
// Stories/Reels camera).
static BOOL sSPKQuickSnapCameraOnScreen = NO;

static BOOL SPKQuickSnapCreationDisabled(void) {
    return [SPKUtils getBoolPref:kSPKQuickSnapDisableCreationPref];
}

static BOOL SPKQuickSnapSendConfirmEnabled(void) {
    return [SPKUtils getBoolPref:kSPKQuickSnapConfirmCapturePref];
}

static BOOL SPKQuickSnapDisableCameraControlEnabled(void) {
    return [SPKUtils getBoolPref:kSPKQuickSnapDisableCameraControlPref] && SPKDeviceHasCameraControl();
}

static BOOL SPKQuickSnapHardwareCaptureShouldBeDisabled(void) {
    return SPKDeviceHasCameraControl() &&
           (SPKQuickSnapDisableCameraControlEnabled() || SPKQuickSnapSendConfirmEnabled());
}

static BOOL SPKQuickSnapSkipCameraAfterViewingEnabled(void) {
    return [SPKUtils getBoolPref:kSPKQuickSnapSkipCameraAfterViewingPref];
}

static void SPKQuickSnapNotifyBlocked(void) {
    SPKNotify(kSPKNotificationInstantsCaptureBlocked,
              SPKL(@"MESSAGES_DISABLE_INSTANTS_CREATION_INSTANT_CAPTURE_BLOCKED_TEXT"),
              nil,
              @"lock_filled",
              SPKNotificationToneInfo);
}

// MARK: - Capture confirmation

static UIView *SPKQuickSnapFindCaptureButton(UIView *root);

static BOOL SPKQuickSnapViewIsModernControlView(UIView *view) {
    Class controlClass = NSClassFromString(@"_TtC34IGQuickSnapCameraControlController28IGQuickSnapCameraControlView");
    if (!controlClass)
        return NO;
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:controlClass])
            return YES;
    }
    return NO;
}

static void SPKQuickSnapSetVideoCaptureArmed(BOOL armed) {
    os_unfair_lock_lock(&sSPKQuickSnapVideoStateLock);
    sSPKQuickSnapVideoCaptureArmed = armed;
    sSPKQuickSnapVideoCaptureGeneration += 1;
    os_unfair_lock_unlock(&sSPKQuickSnapVideoStateLock);
}

static NSUInteger SPKQuickSnapArmVideoCapture(void) {
    os_unfair_lock_lock(&sSPKQuickSnapVideoStateLock);
    sSPKQuickSnapVideoCaptureArmed = YES;
    sSPKQuickSnapVideoCaptureGeneration += 1;
    NSUInteger generation = sSPKQuickSnapVideoCaptureGeneration;
    os_unfair_lock_unlock(&sSPKQuickSnapVideoStateLock);
    return generation;
}

static void SPKQuickSnapExpireVideoCapture(NSUInteger generation) {
    os_unfair_lock_lock(&sSPKQuickSnapVideoStateLock);
    if (generation == sSPKQuickSnapVideoCaptureGeneration) {
        sSPKQuickSnapVideoCaptureArmed = NO;
        sSPKQuickSnapVideoCaptureGeneration += 1;
    }
    os_unfair_lock_unlock(&sSPKQuickSnapVideoStateLock);
}

static BOOL SPKQuickSnapConsumeVideoCaptureArmed(NSUInteger *generation) {
    os_unfair_lock_lock(&sSPKQuickSnapVideoStateLock);
    BOOL armed = sSPKQuickSnapVideoCaptureArmed;
    sSPKQuickSnapVideoCaptureArmed = NO;
    if (generation)
        *generation = sSPKQuickSnapVideoCaptureGeneration;
    os_unfair_lock_unlock(&sSPKQuickSnapVideoStateLock);
    return armed;
}

static BOOL SPKQuickSnapVideoCaptureGenerationIsCurrent(NSUInteger generation) {
    os_unfair_lock_lock(&sSPKQuickSnapVideoStateLock);
    BOOL current = generation == sSPKQuickSnapVideoCaptureGeneration;
    os_unfair_lock_unlock(&sSPKQuickSnapVideoStateLock);
    return current;
}

static void SPKQuickSnapRearmCaptureControl(UIView *controlView) {
    UIView *captureButton = SPKQuickSnapFindCaptureButton(controlView);
    if (!captureButton)
        return;

    SEL recognizerSelector = @selector(longPressGestureRecognizer);
    UIGestureRecognizer *recognizer = nil;
    if ([captureButton respondsToSelector:recognizerSelector]) {
        recognizer = ((id (*)(id, SEL))objc_msgSend)(captureButton, recognizerSelector);
    }
    UIControl *gestureView = [recognizer.view isKindOfClass:UIControl.class] ? (UIControl *)recognizer.view : nil;
    if (gestureView) {
        gestureView.enabled = NO;
        gestureView.enabled = YES;
    } else if (!recognizer) {
        // The Swift shutter keeps its press recognizer in Swift storage, but it is
        // attached to the button, so cycling it resets an interrupted press.
        for (UIGestureRecognizer *candidate in captureButton.gestureRecognizers) {
            if (![candidate isKindOfClass:UILongPressGestureRecognizer.class] || !candidate.enabled)
                continue;
            candidate.enabled = NO;
            candidate.enabled = YES;
        }
    }

    SEL stateSelector = @selector(setButtonState:);
    if ([captureButton respondsToSelector:stateSelector]) {
        ((void (*)(id, SEL, long long))objc_msgSend)(captureButton, stateSelector, 1);
    }
}

static void SPKQuickSnapInvalidateConfirmation(void) {
    sSPKQuickSnapSendConfirmGeneration += 1;
    sSPKQuickSnapSendConfirmVisible = NO;
    SPKQuickSnapSetVideoCaptureArmed(NO);
}

static NSUInteger SPKQuickSnapBeginConfirmation(void) {
    if (sSPKQuickSnapSendConfirmVisible)
        return 0;
    sSPKQuickSnapSendConfirmVisible = YES;
    sSPKQuickSnapSendConfirmGeneration += 1;
    return sSPKQuickSnapSendConfirmGeneration;
}

static BOOL SPKQuickSnapResolveConfirmation(NSUInteger generation) {
    if (!sSPKQuickSnapSendConfirmVisible || generation != sSPKQuickSnapSendConfirmGeneration)
        return NO;
    sSPKQuickSnapSendConfirmVisible = NO;
    return YES;
}

static void SPKQuickSnapPresentVideoConfirmation(void (^completion)(void), NSUInteger videoGeneration) {
    if (!SPKQuickSnapVideoCaptureGenerationIsCurrent(videoGeneration))
        return;
    UIView *controlView = sSPKQuickSnapVisibleControlView;
    if (!controlView.window || !SPKQuickSnapSendConfirmEnabled())
        return;

    NSUInteger generation = SPKQuickSnapBeginConfirmation();
    if (generation == 0)
        return;
    SPKQuickSnapRearmCaptureControl(controlView);
    __weak UIView *weakControlView = controlView;
    [SPKUtils
        showConfirmation:^{
            if (!SPKQuickSnapResolveConfirmation(generation))
                return;
            if (completion)
                completion();
            [[NSNotificationCenter defaultCenter] postNotificationName:SPKInstantsVideoSendConfirmedNotification
                                                                object:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                SPKQuickSnapRearmCaptureControl(weakControlView);
            });
        }
        cancelHandler:^{
            if (!SPKQuickSnapResolveConfirmation(generation))
                return;
            SPKQuickSnapRearmCaptureControl(weakControlView);
        }
        title:SPKL(@"INSTANTS_CONFIRMATION_SEND_VIDEO_TITLE")
        message:SPKL(@"INSTANTS_CONFIRMATION_SEND_VIDEO_MESSAGE")];
}

void SPKInstantsVideoConfirmationHandleLongPress(UIView *captureButton, UIGestureRecognizer *gesture) {
    if (!SPKQuickSnapViewIsModernControlView(captureButton))
        return;
    switch (gesture.state) {
    case UIGestureRecognizerStateBegan:
        if (SPKQuickSnapSendConfirmEnabled() && !SPKQuickSnapCreationDisabled()) {
            NSUInteger generation = SPKQuickSnapArmVideoCapture();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               SPKQuickSnapExpireVideoCapture(generation);
                           });
        } else {
            SPKQuickSnapSetVideoCaptureArmed(NO);
        }
        break;
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        SPKQuickSnapSetVideoCaptureArmed(NO);
        break;
    default:
        break;
    }
}

// The writer opens its session on the first frame of a video take. Arming here
// covers the Swift shutter (IGQuickSnapCaptureButton, server-gated per account),
// whose press delegate is a Swift-only protocol and whose recognizer begins on
// touch-down, so neither tells a photo from a video. Photos never open a writer
// session, so this arms for videos only.
static void (*orig_assetWriterStartSession)(id, SEL, CMTime) = NULL;
static void replaced_assetWriterStartSession(id self, SEL _cmd, CMTime startTime) {
    if (orig_assetWriterStartSession)
        orig_assetWriterStartSession(self, _cmd, startTime);
    if (!sSPKQuickSnapCameraOnScreen || !SPKQuickSnapSendConfirmEnabled() || SPKQuickSnapCreationDisabled())
        return;
    NSUInteger generation = SPKQuickSnapArmVideoCapture();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKQuickSnapExpireVideoCapture(generation);
    });
}

static void (*orig_assetWriterFinishWriting)(id, SEL, void (^)(void)) = NULL;
static void replaced_assetWriterFinishWriting(id self, SEL _cmd, void (^completion)(void)) {
    NSUInteger videoGeneration = 0;
    BOOL shouldConfirm = completion && SPKQuickSnapSendConfirmEnabled() &&
                         SPKQuickSnapConsumeVideoCaptureArmed(&videoGeneration);
    if (!shouldConfirm || !orig_assetWriterFinishWriting) {
        if (orig_assetWriterFinishWriting)
            orig_assetWriterFinishWriting(self, _cmd, completion);
        return;
    }

    void (^capturedCompletion)(void) = [completion copy];
    orig_assetWriterFinishWriting(self, _cmd, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKQuickSnapPresentVideoConfirmation(capturedCompletion, videoGeneration);
        });
    });
}

// MARK: - Capture button delegate gate

static BOOL SPKQuickSnapShouldBlockCapture(SEL selector, BOOL notify) {
    if (SPKQuickSnapCreationDisabled()) {
        SPKLog(@"General", @"[Sparkle] Blocking Instant capture (%@)", NSStringFromSelector(selector));
        if (notify)
            SPKQuickSnapNotifyBlocked();
        return YES;
    }
    return NO;
}

static void replaced_captureButtonDidTouchDown(id self, SEL _cmd) {
    if (!SPKQuickSnapShouldBlockCapture(_cmd, NO) && orig_captureButtonDidTouchDown)
        orig_captureButtonDidTouchDown(self, _cmd);
}

static void replaced_captureButtonDidBeginExpanding(id self, SEL _cmd) {
    if (!SPKQuickSnapShouldBlockCapture(_cmd, NO) && orig_captureButtonDidBeginExpanding)
        orig_captureButtonDidBeginExpanding(self, _cmd);
}

static void replaced_captureButtonDidEndExpanding(id self, SEL _cmd) {
    if (!SPKQuickSnapShouldBlockCapture(_cmd, NO) && orig_captureButtonDidEndExpanding)
        orig_captureButtonDidEndExpanding(self, _cmd);
}

static void replaced_captureButtonDidReleaseBeforeExpandingFinished(id self, SEL _cmd) {
    if (!SPKQuickSnapShouldBlockCapture(_cmd, YES) && orig_captureButtonDidReleaseBeforeExpandingFinished)
        orig_captureButtonDidReleaseBeforeExpandingFinished(self, _cmd);
}

static void replaced_captureButtonDidReleaseAfterExpandingFinished(id self, SEL _cmd) {
    if (!SPKQuickSnapShouldBlockCapture(_cmd, YES) && orig_captureButtonDidReleaseAfterExpandingFinished)
        orig_captureButtonDidReleaseAfterExpandingFinished(self, _cmd);
}

static void replaced_captureButtonDidReleaseFromInterruption(id self, SEL _cmd) {
    SPKQuickSnapInvalidateConfirmation();
    if (!SPKQuickSnapShouldBlockCapture(_cmd, NO) && orig_captureButtonDidReleaseFromInterruption)
        orig_captureButtonDidReleaseFromInterruption(self, _cmd);
}

static void replaced_captureButtonDidConfirm(id self, SEL _cmd) {
    if (sSPKQuickSnapSendConfirmVisible)
        return;
    if (!SPKQuickSnapShouldBlockCapture(_cmd, YES) && orig_captureButtonDidConfirm)
        orig_captureButtonDidConfirm(self, _cmd);
}

// The Swift shutter reports presses to a Swift-only delegate, so the
// IGCameraCaptureButtonDelegate gate above never sees them. Its press handler is
// a gesture target and therefore @objc, which makes it the one hookable point.
static void (*orig_nativeShutterPress)(id, SEL, id) = NULL;
static void replaced_nativeShutterPress(id self, SEL _cmd, id gesture) {
    UIGestureRecognizerState state = [gesture isKindOfClass:UIGestureRecognizer.class]
                                         ? [(UIGestureRecognizer *)gesture state]
                                         : UIGestureRecognizerStatePossible;
    if (SPKQuickSnapShouldBlockCapture(_cmd, state == UIGestureRecognizerStateEnded))
        return;
    if (state == UIGestureRecognizerStateCancelled || state == UIGestureRecognizerStateFailed)
        SPKQuickSnapSetVideoCaptureArmed(NO);
    if (orig_nativeShutterPress)
        orig_nativeShutterPress(self, _cmd, gesture);
}

// MARK: - Hardware Camera Control (iPhone 16/17) — dedicated toggle
//
// The side Camera Control button is routed by the Swift-only
// IGQuickSnapCreationVolumeButtonInteractionController into a system
// AVCaptureEventInteraction whose handler is Swift/AVKit-internal (no ObjC
// selector to hook — verified via a full class-dump). We can't prompt on it, but
// we CAN keep the interaction disabled.
//
// Driven by its own pref (`instants_disable_camera_control`). It is also disabled
// while video confirmation is enabled because that Swift/AVKit path has no
// verified post-capture continuation and must not silently bypass confirmation.


static void (*orig_avCaptureEventInteraction_setEnabled)(id, SEL, BOOL) = NULL;
static void replaced_avCaptureEventInteraction_setEnabled(id self, SEL _cmd, BOOL enabled) {
    if (enabled && sSPKQuickSnapCameraOnScreen && SPKQuickSnapHardwareCaptureShouldBeDisabled()) {
        enabled = NO;
    }
    if (orig_avCaptureEventInteraction_setEnabled)
        orig_avCaptureEventInteraction_setEnabled(self, _cmd, enabled);
}

static void SPKQuickSnapDisableHardwareCaptureInTree(UIView *root) {
    if (!root)
        return;
    Class interactionClass = NSClassFromString(@"AVCaptureEventInteraction");
    if (!interactionClass)
        return;

    BOOL disable = SPKQuickSnapHardwareCaptureShouldBeDisabled();

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];

        for (id<UIInteraction> interaction in view.interactions) {
            if ([interaction isKindOfClass:interactionClass] &&
                [interaction respondsToSelector:@selector(setEnabled:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(interaction, @selector(setEnabled:), !disable);
            }
        }

        for (UIView *subview in view.subviews) {
            [queue addObject:subview];
        }
    }
}

// MARK: - Darkened shutter (Disable Creation only)

static UIView *SPKQuickSnapFindCaptureButton(UIView *root) {
    if (!root)
        return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (view.hidden)
            continue;
        NSString *className = NSStringFromClass(view.class);
        if ([className containsString:@"IGCameraCaptureButton"] ||
            [className containsString:@"IGQuickSnapCaptureButton"]) {
            return view;
        }
        for (UIView *subview in view.subviews) {
            [queue addObject:subview];
        }
    }
    return nil;
}

static void SPKQuickSnapApplyLockState(UIView *controlView) {
    UIView *captureButton = SPKQuickSnapFindCaptureButton(controlView);
    if (!captureButton)
        return;

    if (SPKQuickSnapCreationDisabled()) {
        captureButton.userInteractionEnabled = NO;
        captureButton.alpha = 0.4;
    } else {
        captureButton.userInteractionEnabled = YES;
        captureButton.alpha = 1.0;
    }
}

static void replaced_cameraControlViewLayoutSubviews(id self, SEL _cmd) {
    if (orig_cameraControlViewLayoutSubviews)
        orig_cameraControlViewLayoutSubviews(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) {
        UIView *controlView = (UIView *)self;
        sSPKQuickSnapVisibleControlView = controlView;
        sSPKQuickSnapCameraOnScreen = (controlView.window != nil);
        SPKQuickSnapApplyLockState(controlView);
        UIView *scope = controlView.window ?: controlView;
        SPKQuickSnapDisableHardwareCaptureInTree(scope);
    }
}

static void (*orig_cameraControlViewWillMoveToWindow)(id, SEL, id) = NULL;
static void replaced_cameraControlViewWillMoveToWindow(id self, SEL _cmd, id window) {
    if (orig_cameraControlViewWillMoveToWindow)
        orig_cameraControlViewWillMoveToWindow(self, _cmd, window);
    // Track QuickSnap camera presence so the global AVCaptureEventInteraction
    // clamp only applies while the Instants camera is up.
    sSPKQuickSnapCameraOnScreen = (window != nil);
    if (!window) {
        if (sSPKQuickSnapVisibleControlView == (UIView *)self)
            sSPKQuickSnapVisibleControlView = nil;
        SPKQuickSnapInvalidateConfirmation();
    }
    if (window && [self isKindOfClass:[UIView class]]) {
        UIView *controlView = (UIView *)self;
        sSPKQuickSnapVisibleControlView = controlView;
        SPKQuickSnapApplyLockState(controlView);
        SPKQuickSnapDisableHardwareCaptureInTree(window);
    }
}

// MARK: - Skip camera after viewing

static void SPKDismissQuickSnapCreationController(id controller) {
    if (![controller isKindOfClass:[UIViewController class]])
        return;

    UIViewController *viewController = (UIViewController *)controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        UINavigationController *navigationController = viewController.navigationController;
        if (navigationController && navigationController.viewControllers.count > 1) {
            [navigationController popViewControllerAnimated:NO];
        } else {
            [viewController dismissViewControllerAnimated:NO completion:nil];
        }
    });
}

static void SPKMarkQuickSnapExplicitCameraEntry(void) {
    sSPKQuickSnapExplicitCameraEntry = YES;
    sSPKQuickSnapSkipNextCreation = NO;
}

static void replaced_quickSnapPeekViewDidSelectCamera(id self, SEL _cmd, id arg) {
    SPKMarkQuickSnapExplicitCameraEntry();
    if (orig_quickSnapPeekViewDidSelectCamera)
        orig_quickSnapPeekViewDidSelectCamera(self, _cmd, arg);
}

// IG 444 moved the corner-stack camera intent off PresentationManager and onto a
// dedicated router. Keep a separate replacement/original pair in case a transition build
// temporarily exposes the selector on both classes.
static void replaced_cornerStackDidSelectCamera(id self, SEL _cmd, id arg) {
    SPKMarkQuickSnapExplicitCameraEntry();
    if (orig_cornerStackDidSelectCamera)
        orig_cornerStackDidSelectCamera(self, _cmd, arg);
}

static void replaced_didTapCameraButtonWithCameraEntryPoint(id self, SEL _cmd, long long point) {
    SPKMarkQuickSnapExplicitCameraEntry();
    if (orig_didTapCameraButtonWithCameraEntryPoint)
        orig_didTapCameraButtonWithCameraEntryPoint(self, _cmd, point);
}

// The camera button in the viewer's own navigation bar. It is a *third* entry point, with
// its own zero-argument selector on the header button controller — distinct from the peek
// view's and the history section's. Without marking it, tapping it while the skip flag is
// armed made the creation page open and immediately get dismissed again, which read as
// "the camera button just closes the viewer".
static void replaced_headerDidTapCameraButton(id self, SEL _cmd) {
    SPKMarkQuickSnapExplicitCameraEntry();
    if (orig_headerDidTapCameraButton)
        orig_headerDidTapCameraButton(self, _cmd);
}

static void replaced_consumptionViewDidAppear(id self, SEL _cmd, _Bool animated) {
    if (orig_consumptionViewDidAppear)
        orig_consumptionViewDidAppear(self, _cmd, animated);

    if (SPKQuickSnapSkipCameraAfterViewingEnabled()) {
        sSPKQuickSnapConsumptionWasVisible = YES;
        sSPKQuickSnapSkipNextCreation = YES;
        sSPKQuickSnapExplicitCameraEntry = NO;
    }
}

static void replaced_consumptionViewDidDisappear(id self, SEL _cmd, _Bool animated) {
    if (orig_consumptionViewDidDisappear)
        orig_consumptionViewDidDisappear(self, _cmd, animated);
    sSPKQuickSnapConsumptionWasVisible = NO;
}

static void replaced_creationViewWillAppear(id self, SEL _cmd, _Bool animated) {
    BOOL shouldSkip = SPKQuickSnapSkipCameraAfterViewingEnabled() &&
                      sSPKQuickSnapSkipNextCreation &&
                      !sSPKQuickSnapExplicitCameraEntry;

    sSPKQuickSnapSkipNextCreation = NO;

    if (shouldSkip) {
        SPKLog(@"General", @"[Sparkle] Skipping Instant camera after viewing");
        SPKDismissQuickSnapCreationController(self);
        return;
    }

    if (orig_creationViewWillAppear)
        orig_creationViewWillAppear(self, _cmd, animated);
}

// MARK: - Install

static void SPKHookInstanceMethod(const char *className, SEL selector, IMP replacement, IMP *original) {
    Class cls = objc_getClass(className);
    if (!cls || !class_getInstanceMethod(cls, selector))
        return;

    MSHookMessageEx(cls, selector, replacement, original);
}

void SPKInstallDisableInstantsCreationHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *cameraControlView = "_TtC34IGQuickSnapCameraControlController28IGQuickSnapCameraControlView";

        // Install the whole surface unconditionally — each handler decides what to
        // do per-mode at call time by reading the live pref. This lets the toggles
        // take effect without an app restart. The hooks only ever fire while the
        // QuickSnap (Instants) camera is on screen, so they're free otherwise.
        SPKHookInstanceMethod(cameraControlView, @selector(captureButtonDidTouchDown),
                              (IMP)replaced_captureButtonDidTouchDown,
                              (IMP *)&orig_captureButtonDidTouchDown);
        SPKHookInstanceMethod(cameraControlView, @selector(captureButtonDidBeginExpanding),
                              (IMP)replaced_captureButtonDidBeginExpanding,
                              (IMP *)&orig_captureButtonDidBeginExpanding);
        SPKHookInstanceMethod(cameraControlView, @selector(captureButtonDidEndExpanding),
                              (IMP)replaced_captureButtonDidEndExpanding,
                              (IMP *)&orig_captureButtonDidEndExpanding);
        SPKHookInstanceMethod(cameraControlView, @selector(captureButtonDidReleaseBeforeExpandingFinished),
                              (IMP)replaced_captureButtonDidReleaseBeforeExpandingFinished,
                              (IMP *)&orig_captureButtonDidReleaseBeforeExpandingFinished);
        SPKHookInstanceMethod(cameraControlView, @selector(captureButtonDidReleaseAfterExpandingFinished),
                              (IMP)replaced_captureButtonDidReleaseAfterExpandingFinished,
                              (IMP *)&orig_captureButtonDidReleaseAfterExpandingFinished);
        SPKHookInstanceMethod(cameraControlView, @selector(captureButtonDidReleaseFromInterruption),
                              (IMP)replaced_captureButtonDidReleaseFromInterruption,
                              (IMP *)&orig_captureButtonDidReleaseFromInterruption);
        SPKHookInstanceMethod(cameraControlView, @selector(captureButtonDidConfirm),
                              (IMP)replaced_captureButtonDidConfirm,
                              (IMP *)&orig_captureButtonDidConfirm);

        // Darken + hardware-disable are driven from the control view layout;
        // SPKQuickSnapApplyLockState no-ops when creation isn't disabled.
        SPKHookInstanceMethod(cameraControlView, @selector(layoutSubviews),
                              (IMP)replaced_cameraControlViewLayoutSubviews,
                              (IMP *)&orig_cameraControlViewLayoutSubviews);
        SPKHookInstanceMethod(cameraControlView, @selector(willMoveToWindow:),
                              (IMP)replaced_cameraControlViewWillMoveToWindow,
                              (IMP *)&orig_cameraControlViewWillMoveToWindow);

        SPKHookInstanceMethod("_TtC24IGQuickSnapCaptureButton24IGQuickSnapCaptureButton",
                              @selector(handlePressGesture:),
                              (IMP)replaced_nativeShutterPress,
                              (IMP *)&orig_nativeShutterPress);

        // Keep the global writer hook out of older Instagram builds where the
        // modern QuickSnap control-view pipeline is absent.
        Class modernControlClass = objc_getClass(cameraControlView);
        if (modernControlClass &&
            class_getInstanceMethod(modernControlClass, @selector(captureButtonDidReleaseBeforeExpandingFinished))) {
            SPKHookInstanceMethod("AVAssetWriter",
                                  @selector(startSessionAtSourceTime:),
                                  (IMP)replaced_assetWriterStartSession,
                                  (IMP *)&orig_assetWriterStartSession);
            SPKHookInstanceMethod("AVAssetWriter",
                                  @selector(finishWritingWithCompletionHandler:),
                                  (IMP)replaced_assetWriterFinishWriting,
                                  (IMP *)&orig_assetWriterFinishWriting);
        }

        // Robustly keep the hardware Camera Control's AVCaptureEventInteraction
        // disabled while the QuickSnap camera is up and the pref is on — IG may
        // re-enable it after our layout-time pass, so we clamp its setEnabled:.
        Class captureEventInteraction = NSClassFromString(@"AVCaptureEventInteraction");
        if (captureEventInteraction && class_getInstanceMethod(captureEventInteraction, @selector(setEnabled:))) {
            MSHookMessageEx(captureEventInteraction, @selector(setEnabled:),
                            (IMP)replaced_avCaptureEventInteraction_setEnabled,
                            (IMP *)&orig_avCaptureEventInteraction_setEnabled);
        }

        // Live refresh: when the creation pref toggles, re-apply the darken
        // state to the on-screen camera so it updates without leaving Instants.
        [[NSNotificationCenter defaultCenter] addObserverForName:kSPKQuickSnapCreationPrefChangedNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(__unused NSNotification *note) {
                                                          if (SPKQuickSnapCreationDisabled() || !SPKQuickSnapSendConfirmEnabled())
                                                              SPKQuickSnapInvalidateConfirmation();
                                                          UIView *controlView = sSPKQuickSnapVisibleControlView;
                                                          if (!controlView.window)
                                                              return;
                                                          SPKQuickSnapApplyLockState(controlView);
                                                          UIView *scope = controlView.window ?: controlView;
                                                          SPKQuickSnapDisableHardwareCaptureInTree(scope);
                                                          [controlView setNeedsLayout];
                                                      }];
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKAccountDidChangeNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(__unused NSNotification *note) {
                                                          SPKQuickSnapInvalidateConfirmation();
                                                      }];

        // Explicit camera entry points (clear the skip flag).
        SPKHookInstanceMethod("_TtC30IGQuickSnapPresentationManager30IGQuickSnapPresentationManager",
                              @selector(quickSnapPeekViewDidSelectCamera:),
                              (IMP)replaced_quickSnapPeekViewDidSelectCamera,
                              (IMP *)&orig_quickSnapPeekViewDidSelectCamera);
        SPKHookInstanceMethod("_TtC34IGQuickSnapCornerStackIntentRouter34IGQuickSnapCornerStackIntentRouter",
                              @selector(quickSnapPeekViewDidSelectCamera:),
                              (IMP)replaced_cornerStackDidSelectCamera,
                              (IMP *)&orig_cornerStackDidSelectCamera);
        SPKHookInstanceMethod("_TtC44IGQuickSnapImmersiveViewerSectionControllers45IGQuickSnapStandaloneHistorySectionController",
                              @selector(didTapCameraButtonWithCameraEntryPoint:),
                              (IMP)replaced_didTapCameraButtonWithCameraEntryPoint,
                              (IMP *)&orig_didTapCameraButtonWithCameraEntryPoint);
        SPKHookInstanceMethod("_TtC45IGQuickSnapNavigationV3HeaderButtonController45IGQuickSnapNavigationV3HeaderButtonController",
                              @selector(didTapCameraButton),
                              (IMP)replaced_headerDidTapCameraButton,
                              (IMP *)&orig_headerDidTapCameraButton);

        // Viewing (consumption) lifecycle — arm/disarm the skip flag.
        SPKHookInstanceMethod("_TtC26IGQuickSnapConsumptionCore36IGQuickSnapConsumptionViewController",
                              @selector(viewDidAppear:),
                              (IMP)replaced_consumptionViewDidAppear,
                              (IMP *)&orig_consumptionViewDidAppear);
        SPKHookInstanceMethod("_TtC26IGQuickSnapConsumptionCore36IGQuickSnapConsumptionViewController",
                              @selector(viewDidDisappear:),
                              (IMP)replaced_consumptionViewDidDisappear,
                              (IMP *)&orig_consumptionViewDidDisappear);

        // Creation camera appearance — consume the skip flag.
        SPKHookInstanceMethod("_TtC23IGQuickSnapCreationCore33IGQuickSnapCreationViewController",
                              @selector(viewWillAppear:),
                              (IMP)replaced_creationViewWillAppear,
                              (IMP *)&orig_creationViewWillAppear);
    });
}
