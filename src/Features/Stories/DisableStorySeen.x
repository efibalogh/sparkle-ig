#import "../../InstagramHeaders.h"
#import "../../Shared/Stories/SPKStoryContext.h"
#import "../../Shared/Stories/SPKStoryLocalSeen.h"
#import "../../Tweak.h"
#import "../../Utils.h"

static inline BOOL SPKShouldBlockStoryAutoAdvance(void) {
    return [SPKUtils getBoolPref:@"stories_stop_auto_advance"] && !SPKForceStoryAutoAdvance;
}

%group SPKDisableStorySeenHooks

%hook IGStoryViewerViewController
- (void)fullscreenSectionController:(id)arg1 didMarkItemAsSeen:(id)arg2 {
    BOOL forcedStoryMatches = SPKForceMarkStoryAsSeen;
    if (forcedStoryMatches && SPKForcedStorySeenMediaPK.length > 0) {
        NSString *mediaPK = SPKStoryMediaIdentifier(arg2);
        forcedStoryMatches = [mediaPK isEqualToString:SPKForcedStorySeenMediaPK];
    }

    BOOL shouldBlockSeen = !SPKStorySeenReceiptsSessionEnabled() &&
                           SPKStoryManualSeenAppliesToContext(SPKStoryContextFromMedia(arg2));
    if (shouldBlockSeen && !forcedStoryMatches) {
        SPKLog(@"General", @"[Sparkle] Prevented automatic story seen marking");
        // Keep Seen Locally: the story still turns seen on this device, without
        // the view receipt Instagram's own mark would queue.
        if (SPKStoryLocalSeenEnabled())
            SPKStoryLocalSeenMarkItem(self, arg1, arg2);
        return;
    }

    %orig;
    if (shouldBlockSeen)
        SPKStoryLocalSeenNoteItemSent(self, arg1, arg2);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig(animated);
    SPKStoryEndSeenReceiptsSessionForViewer((UIViewController *)self);
}
%end

%hook IGStoryFullscreenSectionController
- (void)storyPlayerMediaViewDidPlayToEnd:(id)arg1 {
    if (SPKShouldBlockStoryAutoAdvance()) {
        return;
    }

    %orig;
}

- (void)advanceToNextReelForAutoScroll {
    if (SPKShouldBlockStoryAutoAdvance()) {
        return;
    }

    %orig;
}
%end

%end

void SPKInstallDisableStorySeenHooksIfNeeded(void) {
    if (!SPKStoryManualSeenEnabled() &&
        SPKStoryManualSeenUserList(NO).count == 0 &&
        ![SPKUtils getBoolPref:@"stories_stop_auto_advance"]) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKDisableStorySeenHooks);
    });
}
