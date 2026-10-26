#import "../../Utils.h"
#import "SPKStrings.h"

static inline BOOL SPKBlockDisappearingSwipeUpEnabled(void) {
    return [SPKUtils getBoolPref:@"msgs_disable_vanish_swipe_up"];
}

static inline BOOL SPKHideVanishScreenshotEnabled(void) {
    return [SPKUtils getBoolPref:@"msgs_hide_vanish_screenshot"];
}

%group SPKShhConfirmHooks

%hook IGDirectBottomSwipeableScrollManager
- (id)initWithKeyboardVisibleSwipeThreshold:(double)arg1
               keyboardHiddenSwipeThreshold:(double)arg2
                           keyboardObserver:(id)arg3
                       enableHapticFeedback:(BOOL)arg4
                                launcherSet:(id)arg5 {
    if (SPKBlockDisappearingSwipeUpEnabled()) {
        SPKLog(@"General", @"[Sparkle] Blocking disappearing swipe-up initializer (launcherSet)");
        return nil;
    }

    return %orig;
}

- (id)initWithKeyboardVisibleSwipeThreshold:(double)arg1
               keyboardHiddenSwipeThreshold:(double)arg2
                           keyboardObserver:(id)arg3
                       enableHapticFeedback:(BOOL)arg4 {
    if (SPKBlockDisappearingSwipeUpEnabled()) {
        SPKLog(@"General", @"[Sparkle] Blocking disappearing swipe-up initializer");
        return nil;
    }

    return %orig;
}
%end

%hook IGDirectThreadViewBottomSwipeFeatureController
// From 453 the Swift controller builds the scroll manager through its Swift
// initializer, which skips the init hooks above. Every swipe path no-ops while
// the manager is nil, and this setup is only reached through objc_msgSend.
- (void)setupBottomSwipeableScrollManagerIfNecessary {
    if (SPKBlockDisappearingSwipeUpEnabled()) {
        SPKLog(@"General", @"[Sparkle] Blocking disappearing swipe-up scroll manager setup");
        return;
    }

    %orig;
}

- (void)swipeableScrollManagerDidEndDraggingAboveSwipeThreshold:(id)arg1 {
    if (SPKBlockDisappearingSwipeUpEnabled()) {
        SPKLog(@"General", @"[Sparkle] Blocking disappearing swipe-up threshold action");
        return;
    }

    if ([SPKUtils getBoolPref:@"msgs_confirm_vanish_mode"]) {
        SPKLog(@"General", @"[Sparkle] Confirm shh mode triggered");

        [SPKUtils
            showConfirmation:^(void) {
                %orig;
            }
                       title:SPKL(@"MESSAGES_CONFIRMATION_CONFIRM_VANISH_MODE_TITLE")
                     message:SPKL(@"MESSAGES_VANISH_MODE_CONFIRM_CHANGE_DISAPPEARING_MESSAGES_CHAT_CONFIRMATION_MESSAGE")];
    } else {
        return %orig;
    }
}
%end

%hook IGDirectThreadViewController
- (void)swipeableScrollManagerDidEndDraggingAboveSwipeThreshold:(id)arg1 {
    if (SPKBlockDisappearingSwipeUpEnabled()) {
        SPKLog(@"General", @"[Sparkle] Blocking disappearing swipe-up threshold action");
        return;
    }

    if ([SPKUtils getBoolPref:@"msgs_confirm_vanish_mode"]) {
        SPKLog(@"General", @"[Sparkle] Confirm shh mode triggered");

        [SPKUtils
            showConfirmation:^(void) {
                %orig;
            }
                       title:SPKL(@"MESSAGES_CONFIRMATION_CONFIRM_VANISH_MODE_TITLE")
                     message:SPKL(@"MESSAGES_VANISH_MODE_CONFIRM_CHANGE_DISAPPEARING_MESSAGES_CHAT_CONFIRMATION_MESSAGE")];
    } else {
        return %orig;
    }
}

- (id)bottomSwipeHandler {
    if (SPKBlockDisappearingSwipeUpEnabled()) {
        SPKLog(@"General", @"[Sparkle] Blocking disappearing swipe-up handler");
        return nil;
    }

    return %orig;
}

- (void)shhModeTransitionButtonDidTap:(id)arg1 {
    if ([SPKUtils getBoolPref:@"msgs_confirm_vanish_mode"]) {
        SPKLog(@"General", @"[Sparkle] Confirm shh mode triggered");

        [SPKUtils
            showConfirmation:^(void) {
                %orig;
            }
                       title:SPKL(@"MESSAGES_CONFIRMATION_CONFIRM_VANISH_MODE_TITLE")
                     message:SPKL(@"MESSAGES_VANISH_MODE_CONFIRM_CHANGE_DISAPPEARING_MESSAGES_CHAT_CONFIRMATION_MESSAGE")];
    } else {
        return %orig;
    }
}

- (void)messageListViewControllerDidToggleShhMode:(id)arg1 {
    if ([SPKUtils getBoolPref:@"msgs_confirm_vanish_mode"]) {
        SPKLog(@"General", @"[Sparkle] Confirm shh mode triggered");

        [SPKUtils
            showConfirmation:^(void) {
                %orig;
            }
                       title:SPKL(@"MESSAGES_CONFIRMATION_CONFIRM_VANISH_MODE_TITLE")
                     message:SPKL(@"MESSAGES_VANISH_MODE_CONFIRM_CHANGE_DISAPPEARING_MESSAGES_CHAT_CONFIRMATION_MESSAGE")];
    } else {
        return %orig;
    }
}

- (void)messageListViewControllerDidTakeScreenshot:(id)arg1 isRecording:(BOOL)arg2 productType:(NSInteger)arg3 {
    if (SPKHideVanishScreenshotEnabled()) {
        SPKLog(@"General", @"[Sparkle] Suppressing vanish screenshot callback (thread controller)");
        return;
    }

    %orig;
}
%end

%hook IGDirectThreadViewMessageListFeatureController
- (void)messageListViewControllerDidToggleShhMode:(id)arg1 {
    if ([SPKUtils getBoolPref:@"msgs_confirm_vanish_mode"]) {
        SPKLog(@"General", @"[Sparkle] Confirm shh mode triggered");

        [SPKUtils
            showConfirmation:^(void) {
                %orig;
            }
                       title:SPKL(@"MESSAGES_CONFIRMATION_CONFIRM_VANISH_MODE_TITLE")
                     message:SPKL(@"MESSAGES_VANISH_MODE_CONFIRM_CHANGE_DISAPPEARING_MESSAGES_CHAT_CONFIRMATION_MESSAGE")];
    } else {
        return %orig;
    }
}

- (void)messageListViewControllerDidTakeScreenshot:(id)arg1 isRecording:(BOOL)arg2 productType:(NSInteger)arg3 {
    if (SPKHideVanishScreenshotEnabled()) {
        SPKLog(@"General", @"[Sparkle] Suppressing vanish screenshot callback (thread controller)");
        return;
    }

    %orig;
}
%end

%hook IGDirectMessageListViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
    if (SPKHideVanishScreenshotEnabled()) {
        SPKLog(@"General", @"[Sparkle] Suppressing vanish screenshot callback (screenshot taken)");
        return;
    }

    %orig;
}

- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
    if (SPKHideVanishScreenshotEnabled()) {
        SPKLog(@"General", @"[Sparkle] Suppressing vanish screenshot callback (active capture)");
        return;
    }

    %orig;
}
%end

%end

void SPKInstallShhConfirmHooksIfNeeded(void) {
    if (![SPKUtils getBoolPref:@"msgs_disable_vanish_swipe_up"] &&
        ![SPKUtils getBoolPref:@"msgs_hide_vanish_screenshot"] &&
        ![SPKUtils getBoolPref:@"msgs_confirm_vanish_mode"]) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Swift class from 450, where only the mangled name is guaranteed.
        Class scrollManager = objc_getClass("IGDirectBottomSwipeableScrollManager") ?: objc_getClass("_TtC46IGDirectThreadViewBottomSwipeFeatureController36IGDirectBottomSwipeableScrollManager");
        // The feature controller followed it into Swift in 453.
        Class bottomSwipeController = objc_getClass("IGDirectThreadViewBottomSwipeFeatureController") ?: objc_getClass("_TtC46IGDirectThreadViewBottomSwipeFeatureController46IGDirectThreadViewBottomSwipeFeatureController");
        %init(SPKShhConfirmHooks, IGDirectBottomSwipeableScrollManager = scrollManager, IGDirectThreadViewBottomSwipeFeatureController = bottomSwipeController);
    });
}
