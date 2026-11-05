// Hide Instants in Inbox: keeps the Instants card stack off the Direct inbox,
// the same result as Instagram's own "Hide Instants in inbox" setting, which is
// server-stored and only offered to accounts inside its rollout.
//
// Only selectors Instagram reaches through objc_msgSend are hooked. The peek is
// presented and laid out from the inbox controllers and the inbox camera media
// coordinator; the presentation manager's own configure/visibility methods are
// only ever called from Swift and would never fire.
//
// Every hook reads the pref at call time. Turning it on detaches a card that is
// already mounted in any live inbox straight away (the settings switch posts
// SPKInstantsHideInInboxDidChangeNotification); turning it off lets the next peek
// attempt mount it again.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "../../InstagramHeaders.h"
#import "../../Utils.h"

static NSString *const kSPKInstantsHideInInboxPref = @"instants_hide_in_inbox";

static NSString *const kSPKInstantsHideInInboxDidChangeNotification = @"SPKInstantsHideInInboxDidChangeNotification";

static BOOL SPKInstantsHideInInboxEnabled(void) {
    return [SPKUtils getBoolPref:kSPKInstantsHideInInboxPref];
}

// Inboxes whose peek hooks have fired, so a pref change can reach one that is
// not laying out right now (e.g. sitting under the Settings sheet). Weak, so a
// dismissed inbox drops out on its own. Main thread only.
static NSHashTable<UIViewController *> *SPKInstantsSeenInboxes(void) {
    static NSHashTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static void SPKInstantsRememberInbox(UIViewController *inbox) {
    if (NSThread.isMainThread && inbox)
        [SPKInstantsSeenInboxes() addObject:inbox];
}

// The card is shared with the profile corner stack, so it is only detached when
// it currently sits inside this inbox. Detaching rather than hiding leaves no
// state behind for the next host that mounts it.
static void SPKInstantsDetachInboxCard(UIViewController *inbox) {
    if (!inbox.isViewLoaded || ![inbox respondsToSelector:@selector(userSession)])
        return;
    IGUserSession *session = [(id)inbox userSession];
    if (![session respondsToSelector:@selector(quickSnapPresentationManager)])
        return;
    id manager = [session quickSnapPresentationManager];
    if (![manager respondsToSelector:@selector(cardView)])
        return;
    UIView *card = [manager cardView];
    if ([card isKindOfClass:UIView.class] && card.superview && [card isDescendantOfView:inbox.view])
        [card removeFromSuperview];
}

%group SPKInstantsHideInInboxObjCHooks
%hook IGDirectInboxViewController
- (void)tryShowQuickSnapPeek {
    SPKInstantsRememberInbox(self);
    if (SPKInstantsHideInInboxEnabled())
        return SPKInstantsDetachInboxCard(self);
    %orig;
}

- (void)networkingCoordinator_layoutQuickSnapPeekIfNeeded {
    SPKInstantsRememberInbox(self);
    if (SPKInstantsHideInInboxEnabled())
        return SPKInstantsDetachInboxCard(self);
    %orig;
}

- (void)cameraMediaLayoutQuickSnapPeekIfNeeded {
    SPKInstantsRememberInbox(self);
    if (SPKInstantsHideInInboxEnabled())
        return SPKInstantsDetachInboxCard(self);
    %orig;
}
%end
%end

%group SPKInstantsHideInInboxSwiftHooks
%hook IGDirectInboxSwiftViewController
- (void)tryShowQuickSnapPeek {
    SPKInstantsRememberInbox(self);
    if (SPKInstantsHideInInboxEnabled())
        return SPKInstantsDetachInboxCard(self);
    %orig;
}

- (void)networkingCoordinator_layoutQuickSnapPeekIfNeeded {
    SPKInstantsRememberInbox(self);
    if (SPKInstantsHideInInboxEnabled())
        return SPKInstantsDetachInboxCard(self);
    %orig;
}

- (void)cameraMediaLayoutQuickSnapPeekIfNeeded {
    SPKInstantsRememberInbox(self);
    if (SPKInstantsHideInInboxEnabled())
        return SPKInstantsDetachInboxCard(self);
    %orig;
}
%end
%end

// The coordinator has no view of its own; its inbox delegate's layout hooks
// above take care of a card that is already mounted.
%group SPKInstantsHideInInboxCoordinatorHooks
%hook IGDirectInboxCameraMediaCoordinator
- (void)tryShowQuickSnapPeek {
    if (SPKInstantsHideInInboxEnabled())
        return;
    %orig;
}
%end
%end

%group SPKInstantsHideInInboxGateHooks
%hook IGQuickSnapExperimentationHelper
+ (BOOL)isQuicksnapEnabledInInbox:(id)session {
    if (SPKInstantsHideInInboxEnabled())
        return NO;
    return %orig;
}
%end
%end

static BOOL SPKInstantsInboxClassHasPeek(Class cls) {
    return cls && class_getInstanceMethod(cls, @selector(tryShowQuickSnapPeek)) &&
           class_getInstanceMethod(cls, @selector(networkingCoordinator_layoutQuickSnapPeekIfNeeded)) &&
           class_getInstanceMethod(cls, @selector(cameraMediaLayoutQuickSnapPeekIfNeeded));
}

extern "C" void SPKInstallInstantsHideInInboxHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Builds without the modern inbox peek (410.1.0 has no Instants) get
        // nothing, so no hook lands on a missing selector.
        Class objcInbox = SPKDirectObjCInboxClass();
        if (SPKInstantsInboxClassHasPeek(objcInbox))
            %init(SPKInstantsHideInInboxObjCHooks, IGDirectInboxViewController = objcInbox);

        Class swiftInbox = SPKDirectSwiftInboxClass();
        if (SPKInstantsInboxClassHasPeek(swiftInbox))
            %init(SPKInstantsHideInInboxSwiftHooks, IGDirectInboxSwiftViewController = swiftInbox);

        Class coordinator = SPKResolveIGClass(@"IGDirectInboxViewControllerSwift.IGDirectInboxCameraMediaCoordinator", nil);
        if (coordinator && class_getInstanceMethod(coordinator, @selector(tryShowQuickSnapPeek)))
            %init(SPKInstantsHideInInboxCoordinatorHooks, IGDirectInboxCameraMediaCoordinator = coordinator);

        Class helper = SPKResolveIGClass(@"IGQuickSnapExperimentation.IGQuickSnapExperimentationHelper", nil);
        if (helper && class_getClassMethod(helper, @selector(isQuicksnapEnabledInInbox:)))
            %init(SPKInstantsHideInInboxGateHooks, IGQuickSnapExperimentationHelper = helper);

        [[NSNotificationCenter defaultCenter] addObserverForName:kSPKInstantsHideInInboxDidChangeNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(__unused NSNotification *note) {
                                                          if (!SPKInstantsHideInInboxEnabled())
                                                              return;
                                                          for (UIViewController *inbox in SPKInstantsSeenInboxes().allObjects)
                                                              SPKInstantsDetachInboxCard(inbox);
                                                      }];

        SPKLog(@"Instants", @"[Sparkle] Instants hide-in-inbox hooks installed");
    });
}
