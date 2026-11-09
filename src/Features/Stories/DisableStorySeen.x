#import "../../InstagramHeaders.h"
#import "../../Shared/Stories/SPKStoryContext.h"
#import "../../Shared/Stories/SPKStoryLocalSeen.h"
#import "../../Tweak.h"
#import "../../Utils.h"

static inline BOOL SPKShouldBlockStoryAutoAdvance(void) {
    return [SPKUtils getBoolPref:@"stories_stop_auto_advance"] && !SPKForceStoryAutoAdvance;
}

// Shared by both seen entry points. `viewer` only has to answer `userSession`
// (and optionally `currentViewModel`) for Seen Locally, so the 454+ viewer
// context stands in for the view controller.
static void SPKHandleStorySeenReport(id viewer, id sectionController, id item, void (^orig)(void)) {
    BOOL forcedStoryMatches = SPKForceMarkStoryAsSeen;
    if (forcedStoryMatches && SPKForcedStorySeenMediaPK.length > 0) {
        NSString *mediaPK = SPKStoryMediaIdentifier(item);
        forcedStoryMatches = [mediaPK isEqualToString:SPKForcedStorySeenMediaPK];
    }

    BOOL shouldBlockSeen = !SPKStorySeenReceiptsSessionEnabled() &&
                           SPKStoryManualSeenAppliesToContext(SPKStoryContextFromMedia(item));
    if (shouldBlockSeen && !forcedStoryMatches) {
        SPKLog(@"General", @"[Sparkle] Prevented automatic story seen marking");
        // Keep Seen Locally: the story still turns seen on this device, without
        // the view receipt Instagram's own mark would queue.
        if (SPKStoryLocalSeenEnabled())
            SPKStoryLocalSeenMarkItem(viewer, sectionController, item);
        return;
    }

    orig();
    if (shouldBlockSeen)
        SPKStoryLocalSeenNoteItemSent(viewer, sectionController, item);
}

// Up to 453 the viewer view controller receives the seen callback.
%group SPKDisableStorySeenLegacyHooks

%hook IGStoryViewerViewController
- (void)fullscreenSectionController:(id)arg1 didMarkItemAsSeen:(id)arg2 {
    SPKHandleStorySeenReport(self, arg1, arg2, ^{
        %orig;
    });
}
%end

%end

// 454+ moved the callback into a dedicated reporter object.
%group SPKDisableStorySeenReporterHooks

%hook IGStoryViewerItemSeenReporter
- (void)reportSeenItem:(id)item sectionController:(id)sectionController {
    // IG 455 rewrote the reporter in Swift: the ivar lost its underscore.
    id viewerContext = [SPKUtils getIvarForObj:self name:"_viewerContext"];
    if (!viewerContext)
        viewerContext = [SPKUtils getIvarForObj:self name:"viewerContext"];
    Class viewerContextClass = NSClassFromString(@"IGStoryViewerContext");
    if (viewerContextClass && viewerContext && ![viewerContext isKindOfClass:viewerContextClass])
        viewerContext = nil;
    SPKHandleStorySeenReport(viewerContext, sectionController, item, ^{
        %orig;
    });
}
%end

%end

%group SPKDisableStorySeenHooks

%hook IGStoryViewerViewController
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
        // IG 455 folded the Swift twin into a Swift IGStoryFullscreenSectionController,
        // so the plain name no longer resolves and the twin class is gone.
        Class sectionController = SPKStoryFullscreenSectionControllerClass();
        if (sectionController)
            %init(SPKStoryAutoAdvanceHooks, IGStoryFullscreenSectionController = sectionController);
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
        Class viewerClass = objc_getClass("IGStoryViewerViewController");
        if (viewerClass && class_getInstanceMethod(viewerClass, NSSelectorFromString(@"fullscreenSectionController:didMarkItemAsSeen:")))
            %init(SPKDisableStorySeenLegacyHooks);
        Class reporterClass = SPKStoryViewerItemSeenReporterClass();
        if (reporterClass && class_getInstanceMethod(reporterClass, @selector(reportSeenItem:sectionController:)))
            %init(SPKDisableStorySeenReporterHooks, IGStoryViewerItemSeenReporter = reporterClass);
    });
}
