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

%end

// Auto-advance installs unconditionally and re-checks the pref per item, so the
// toggle works after enabling it mid-session or switching to an account that
// has it on.
%group SPKStoryAutoAdvanceHooks

%hook IGStoryFullscreenSectionController
- (void)storyPlayerMediaViewDidPlayToEnd:(id)arg1 {
    if (SPKShouldBlockStoryAutoAdvance()) {
        return;
    }

    %orig;
}
%end

%end

// Instagram 450+ can serve a Swift section controller in place of the Objective-C
// one, chosen per account server-side. It receives the same play-to-end callback.
%group SPKStoryAutoAdvanceSwiftHooks

%hook SPKStoryFullscreenSectionControllerSwift
- (void)storyPlayerMediaViewDidPlayToEnd:(id)arg1 {
    if (SPKShouldBlockStoryAutoAdvance()) {
        return;
    }

    %orig;
}
%end

%end

void SPKInstallDisableStorySeenHooksIfNeeded(void) {
    static dispatch_once_t advanceOnceToken;
    dispatch_once(&advanceOnceToken, ^{
        %init(SPKStoryAutoAdvanceHooks);
        Class swiftSectionController = objc_getClass("_TtC39IGStoryFullscreenSectionControllerSwift39IGStoryFullscreenSectionControllerSwift");
        if (swiftSectionController)
            %init(SPKStoryAutoAdvanceSwiftHooks, SPKStoryFullscreenSectionControllerSwift = swiftSectionController);
    });

    if (!SPKStoryManualSeenEnabled() &&
        SPKStoryManualSeenUserList(NO).count == 0) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKDisableStorySeenHooks);
    });
}
