#import "../../InstagramHeaders.h"
#import "../../Tweak.h"
#import "../../Utils.h"

static inline BOOL SPKUnlimitedReplayEnabled(void) {
    return [SPKUtils getBoolPref:@"msgs_manual_visual_seen"];
}

static inline BOOL SPKShouldBlockDMStoryAutoAdvance(void) {
    return [SPKUtils getBoolPref:@"msgs_stop_visual_auto_advance"];
}

static inline BOOL SPKShouldPassThroughManualDirectSeen(id message) {
    return (message && SPKPendingDirectVisualMessageToMarkSeen && message == SPKPendingDirectVisualMessageToMarkSeen);
}

%group SPKDisableDMStorySeenHooks

%hook IGDirectVisualMessageViewerEventHandler
- (void)visualMessageViewerController:(id)arg1 didBeginPlaybackForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {
    if (!SPKUnlimitedReplayEnabled()) {
        return %orig;
    }

    if (SPKShouldPassThroughManualDirectSeen(arg2)) {
        return %orig;
    }
}

- (void)visualMessageViewerController:(id)arg1 didEndPlaybackForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 mediaCurrentTime:(CGFloat)arg4 forNavType:(NSInteger)arg5 {
    if (!SPKUnlimitedReplayEnabled()) {
        return %orig;
    }

    if (SPKShouldPassThroughManualDirectSeen(arg2)) {
        return %orig;
    }
}
%end

%end

// The DM visual-message viewer shares the story player's playback pipeline, so it
// auto-advances to the next item (or dismisses) when the current media plays to
// end. Blocking that keeps the current visual message on screen; manual taps and
// the eye button still advance normally. Installs unconditionally and re-checks
// the pref per item, so enabling it mid-session or per account takes effect.
%group SPKDMVisualAutoAdvanceHooks

%hook IGDirectVisualMessageViewerController
- (void)storyPlayerMediaViewDidPlayToEnd:(id)arg1 {
    if (SPKShouldBlockDMStoryAutoAdvance()) {
        return;
    }

    %orig;
}
%end

%end

void SPKInstallDisableDMStorySeenHooksIfNeeded(void) {
    static dispatch_once_t advanceOnceToken;
    dispatch_once(&advanceOnceToken, ^{
        %init(SPKDMVisualAutoAdvanceHooks);
    });

    if (![SPKUtils getBoolPref:@"msgs_manual_visual_seen"]) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKDisableDMStorySeenHooks);
    });
}
