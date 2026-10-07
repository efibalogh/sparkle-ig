#import "SPKStrings.h"
#import "../../Utils.h"
#import <objc/message.h>
#import <objc/runtime.h>

// IGAudioStatusAnnouncer keeps one global sticky sound state: 0 unset, 1 user
// muted, 2 user unmuted. Reels follow it once it is set, but while it is unset
// they pick sound on or off by themselves, inconsistently. Starting muted means
// writing 1 whenever the state is unset; a tap still writes 2 as usual.
static const long long kSPKStickySoundStateUnset = 0;
static const long long kSPKStickySoundStateMuted = 1;
static const long long kSPKStickySoundStateReason = 5; // what IG's own mute toggle passes

// The first activation after launch is where IG restores the previous session's
// state, so that one is overridden even when set; later ones only fill an unset state.
static BOOL sSPKReelsDidOverrideLaunchSoundState = NO;

static long long *SPKReelsStickySoundStateSlot(id announcer) {
    Ivar ivar = announcer ? class_getInstanceVariable([announcer class], "_stickySoundState") : NULL;
    if (!ivar)
        return NULL;
    return (long long *)((uint8_t *)(__bridge void *)announcer + ivar_getOffset(ivar));
}

static void SPKReelsWriteMutedSoundState(id announcer) {
    SEL setter = @selector(setStickySoundState:forReason:);
    if ([announcer respondsToSelector:setter]) {
        ((void (*)(id, SEL, long long, long long))objc_msgSend)(announcer,
                                                                setter,
                                                                kSPKStickySoundStateMuted,
                                                                kSPKStickySoundStateReason);
        return;
    }

    // 410 has no setter: write the state and notify listeners the way the setter does.
    long long *slot = SPKReelsStickySoundStateSlot(announcer);
    if (!slot)
        return;
    *slot = kSPKStickySoundStateMuted;
    Ivar enabledIvar = class_getInstanceVariable([announcer class], "_audioEnabled");
    if (enabledIvar)
        *((BOOL *)((uint8_t *)(__bridge void *)announcer + ivar_getOffset(enabledIvar))) = NO;

    SEL notify = @selector(audioStatusDidChangeIsAudioEnabled:forReason:);
    id listeners = [SPKUtils getIvarForObj:announcer name:"_announcerForDefaultBehaviors"];
    if ([listeners respondsToSelector:notify])
        ((void (*)(id, SEL, BOOL, long long))objc_msgSend)(listeners, notify, NO, kSPKStickySoundStateReason);
}

static void SPKReelsApplyStartMuted(id announcer) {
    if (![SPKUtils getBoolPref:@"reels_disable_auto_unmute"])
        return;
    long long *slot = SPKReelsStickySoundStateSlot(announcer);
    if (!slot)
        return;

    BOOL launch = !sSPKReelsDidOverrideLaunchSoundState;
    sSPKReelsDidOverrideLaunchSoundState = YES;
    if (*slot == kSPKStickySoundStateMuted || (!launch && *slot != kSPKStickySoundStateUnset))
        return;
    SPKReelsWriteMutedSoundState(announcer);
}

// * Reels refresh gate (Prevent Doom Scrolling, Confirm Reels Refresh)
// One pull reaches the controller through several runtime-dispatched calls whose
// order and role differ by IG version and iOS: the control's ValueChanged action,
// its release delegate callback, and up to 449 the network refresh itself. On 450
// the network refresh is Swift and called directly, and on iOS 26+ the control is
// already loading when the finger lifts, so it never reports the release. The one
// call every build shares is the control sending ValueChanged as it starts loading,
// before any target hears of it, so that is the gate. Calls arriving while the
// prompt is up wait for the answer, and calls made while a confirmed refresh runs
// pass straight through, so a pull asks exactly once.
static BOOL sSPKReelsRunningConfirmedRefresh = NO;
static __weak IGSundialFeedViewController *sSPKReelsTabTapController = nil;
static BOOL sSPKReelsRefreshPromptPending = NO;
static NSMutableArray<dispatch_block_t> *sSPKReelsDeferredRefreshCalls = nil;

static BOOL SPKReelsShouldGateRefresh(void) {
    return [SPKUtils getBoolPref:@"reels_prevent_doom_scroll"] || [SPKUtils getBoolPref:@"reels_confirm_refresh"];
}

static void SPKReelsFinishRefresh(IGSundialFeedViewController *controller, IGRefreshControl *control) {
    IGRefreshControl *refreshControl = control;
    if (!refreshControl && [controller respondsToSelector:@selector(refreshControl)])
        refreshControl = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(refreshControl));
    if (!refreshControl)
        refreshControl = [SPKUtils getIvarForObj:controller name:"_refreshControl"];
    if ([refreshControl respondsToSelector:@selector(finishLoading)])
        [refreshControl finishLoading];
    if ([controller respondsToSelector:@selector(finishPullToRefreshLoading)])
        [controller finishPullToRefreshLoading];
}

static void SPKReelsRunConfirmedRefresh(dispatch_block_t orig) {
    sSPKReelsRunningConfirmedRefresh = YES;
    orig();
    NSArray<dispatch_block_t> *deferred = [sSPKReelsDeferredRefreshCalls copy];
    [sSPKReelsDeferredRefreshCalls removeAllObjects];
    for (dispatch_block_t call in deferred)
        call();
    sSPKReelsRunningConfirmedRefresh = NO;
}

// Returns YES when the call was consumed: it runs later, or never.
static BOOL SPKReelsDeferIfGated(dispatch_block_t orig) {
    if (sSPKReelsRunningConfirmedRefresh)
        return NO;
    if (sSPKReelsRefreshPromptPending) {
        if (!sSPKReelsDeferredRefreshCalls)
            sSPKReelsDeferredRefreshCalls = [NSMutableArray array];
        [sSPKReelsDeferredRefreshCalls addObject:[orig copy]];
        return YES;
    }
    return NO;
}

static void SPKReelsHandleRefresh(IGSundialFeedViewController *controller, IGRefreshControl *control, BOOL userInitiated, dispatch_block_t orig) {
    if (!userInitiated || SPKReelsDeferIfGated(orig) || sSPKReelsRunningConfirmedRefresh) {
        if (!userInitiated || sSPKReelsRunningConfirmedRefresh)
            orig();
        return;
    }

    if ([SPKUtils getBoolPref:@"reels_prevent_doom_scroll"]) {
        SPKReelsFinishRefresh(controller, control);
        return;
    }

    if (![SPKUtils getBoolPref:@"reels_confirm_refresh"]) {
        orig();
        return;
    }

    sSPKReelsRefreshPromptPending = YES;
    [SPKUtils
        showConfirmation:^(void) {
            sSPKReelsRefreshPromptPending = NO;
            SPKReelsRunConfirmedRefresh(orig);
        }
        cancelHandler:^(void) {
            sSPKReelsRefreshPromptPending = NO;
            [sSPKReelsDeferredRefreshCalls removeAllObjects];
            SPKReelsFinishRefresh(controller, control);
        }
        title:SPKL(@"REELS_REELS_PLAYBACK_CONFIRM_REELS_REFRESH_TEXT")
        message:SPKL(@"REELS_REELS_PLAYBACK_REFRESH_REELS_FEED_CONFIRMATION_MESSAGE")];
}

static IMP sSPKOrigRefreshControlSendActions = NULL;

static void SPKReelsRefreshControlSendActions(UIControl *self, SEL _cmd, UIControlEvents events) {
    void (^orig)(void) = ^{
        ((void (*)(id, SEL, UIControlEvents))sSPKOrigRefreshControlSendActions)(self, _cmd, events);
    };
    id delegate = [self respondsToSelector:@selector(delegate)] ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(delegate)) : nil;
    Class feedClass = objc_getClass("IGSundialFeedViewController");
    if (!(events & UIControlEventValueChanged) || !feedClass || ![delegate isKindOfClass:feedClass] || !SPKReelsShouldGateRefresh()) {
        orig();
        return;
    }
    SPKReelsHandleRefresh(delegate, (IGRefreshControl *)self, YES, orig);
}

// UIControl owns -sendActionsForControlEvents:, so the override is added to
// IGRefreshControl alone rather than swizzling every control in the app.
static void SPKReelsInstallRefreshControlGate(void) {
    Class cls = objc_getClass("IGRefreshControl");
    SEL sel = @selector(sendActionsForControlEvents:);
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method)
        return;
    IMP inherited = method_getImplementation(method);
    if (class_addMethod(cls, sel, (IMP)SPKReelsRefreshControlSendActions, method_getTypeEncoding(method)))
        sSPKOrigRefreshControlSendActions = inherited;
    else
        sSPKOrigRefreshControlSendActions = method_setImplementation(method, (IMP)SPKReelsRefreshControlSendActions);
}

%group SPKReelsPlaybackHooks

%hook IGSundialPlaybackControlsTestConfiguration
- (id)initWithLauncherSet:(id)set
                     tapToPauseEnabled:(_Bool)tapPauseEnabled
      combineSingleTapPlaybackControls:(_Bool)controls
        isVideoPreviewThumbnailEnabled:(_Bool)previewThumbEnabled
                minScrubberDurationSec:(long long)minSec
         seekResumeScrubberCooldownSec:(double)seekSec
          tapResumeScrubberCooldownSec:(double)tapSec
    persistentScrubberMinVideoDuration:(long long)duration
        isScrubberForShortVideoEnabled:(_Bool)shortScrubberEnabled {
    _Bool userTapPauseEnabled = tapPauseEnabled;
    if ([[SPKUtils getStringPref:@"reels_tap_control"] isEqualToString:@"pause"])
        userTapPauseEnabled = true;
    else if ([[SPKUtils getStringPref:@"reels_tap_control"] isEqualToString:@"mute"])
        userTapPauseEnabled = false;

    return %orig(set, userTapPauseEnabled, controls, previewThumbEnabled, minSec, seekSec, tapSec, duration, shortScrubberEnabled);
}
%end

%hook IGSundialFeedViewController
// Up to 449 the pull lands here after the control's action, so this only waits
// for or follows the gate; called alone it still gates.
- (void)_refreshReelsWithParamsForNetworkRequest:(NSInteger)arg1 userDidPullToRefresh:(BOOL)arg2 {
    SPKReelsHandleRefresh(self, nil, arg2, ^{
        %orig(arg1, arg2);
    });
}

- (void)refreshControl:(id)control didReleaseWithRefreshControlState:(long long)state {
    if (SPKReelsDeferIfGated(^{
            %orig(control, state);
        }))
        return;
    %orig(control, state);
}

- (void)triggerRefreshFromTabTap {
    if (![SPKUtils getBoolPref:@"reels_confirm_refresh"]) {
        %orig;
        return;
    }
    SPKReelsHandleRefresh(self, nil, YES, ^{
        %orig;
    });
}

// From 450 on iOS 26+ the re-tap refresh no longer goes through
// -triggerRefreshFromTabTap. A re-tap only sometimes refreshes, and when it does
// it starts the fetch synchronously in here, so the re-tap runs untouched and
// the fetch it makes is what gets confirmed.
- (void)scrollToTopOnTappedTabBar {
    sSPKReelsTabTapController = self;
    %orig;
    sSPKReelsTabTapController = nil;
}
%end

// * Start reels muted by seeding the global sticky sound state
// Volume presses, the ringer switch and unplugging headphones are left alone:
// they write the sticky state themselves, so blocking them would turn a start
// muted preference into a permanent mute lock and keep sound on after an unplug.
%hook IGAudioStatusAnnouncer
// IG may restore last session's sound state or reset it to unset here.
- (void)_applicationDidBecomeActive {
    %orig;
    SPKReelsApplyStartMuted(self);
}
- (void)_applicationDidBecomeActive:(id)notification {
    %orig(notification);
    SPKReelsApplyStartMuted(self);
}
%end

%end

%group SPKReelsTabTapFetchHooks
%hook IGSundialUnconnectedFeedNetworkSource
- (BOOL)fetchDataWithAdditionalParameters:(id)parameters {
    IGSundialFeedViewController *controller = sSPKReelsTabTapController;
    if (!controller || sSPKReelsRunningConfirmedRefresh || ![SPKUtils getBoolPref:@"reels_confirm_refresh"])
        return %orig(parameters);

    // The answer comes later, so report the fetch as started; cancel unwinds
    // the loading state the same way a cancelled pull does.
    SPKReelsHandleRefresh(controller, nil, YES, ^{
        %orig(parameters);
    });
    return YES;
}
%end
%end

extern "C" void SPKInstallReelsPlaybackHooksIfNeeded(void) {
    BOOL shouldInstall = ![[SPKUtils getStringPref:@"reels_tap_control"] isEqualToString:@"default"] ||
                         [SPKUtils getBoolPref:@"reels_prevent_doom_scroll"] ||
                         [SPKUtils getBoolPref:@"reels_confirm_refresh"] ||
                         [SPKUtils getBoolPref:@"reels_disable_auto_unmute"];
    if (!shouldInstall)
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKReelsPlaybackHooks);

        SPKReelsInstallRefreshControlGate();
        if (objc_getClass("IGSundialUnconnectedFeedNetworkSource")) {
            %init(SPKReelsTabTapFetchHooks);
        }

        // Surface hooks install after launch, usually past the first activation.
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
            return;
        Class announcerClass = NSClassFromString(@"IGAudioStatusAnnouncer");
        if ([announcerClass respondsToSelector:@selector(sharedInstance)])
            SPKReelsApplyStartMuted([announcerClass sharedInstance]);
    });
}
