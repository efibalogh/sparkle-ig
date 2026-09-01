#import <objc/message.h>
#import "SPKStrings.h"
#import <objc/runtime.h>
#import <substrate.h>

#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Shared/Messages/SPKDirectAutoSave.h"
#import "../../Shared/Messages/SPKDirectInboxMenu.h"
#import "../../Shared/Messages/SPKDirectSeenContext.h"
#import "../../Shared/Messages/SPKPresenceTracking.h"
#import "../../Shared/Stories/SPKStoryContext.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Tweak.h"
#import "../../Utils.h"
#import "DeletedMessagesLog/SPKDeletedMessagesViewController.h"
#import "MessageSeenButtons.h"
#import "../../App/SPKPerfMeter.h"

NSNotificationName const SPKMessageSeenButtonPositionDidChangeNotification = @"SPKMessageSeenButtonPositionDidChangeNotification";

#ifdef __cplusplus
extern "C" {
#endif
#ifdef __cplusplus
}
#endif

@interface UIViewController (SPKRefreshNavigationBar)
- (void)refreshRightBarButtonItems;
- (void)updateThreadNavigationBar;
@end

static NSString *const kSPKSeenMessagesBarIconResource = @"eye";
static const void *kSPKDirectThreadIdAssocKey = &kSPKDirectThreadIdAssocKey;
static NSInteger kSPKSeenAutoBypassCount = 0;
static NSMutableDictionary<NSString *, NSNumber *> *SPKSeenAutoLastTriggerTimes = nil;
static __weak id SPKDirectActiveMarkSeenTarget = nil;
static NSString *SPKDirectActiveMarkSeenThreadId = nil;

static id SPKKVCObject(id target, NSString *key);
static id SPKFindDirectMarkSeenTarget(id root, NSMutableSet<NSValue *> *visited);

static inline BOOL SPKDirectManualSeenRulesEnabled(void) {
    return [SPKUtils getBoolPref:@"msgs_manual_seen"] || SPKDirectManualSeenThreadCount(NO) > 0;
}

static inline BOOL SPKDirectSeenHooksNeeded(void) {
    return SPKDirectManualSeenRulesEnabled() ||
           [SPKUtils getBoolPref:@"msgs_manual_visual_seen"] ||
           [SPKUtils getBoolPref:@"msgs_advance_visual_on_seen"];
}
static inline BOOL SPKAutoSeenOnSendEnabled(void) {
    return SPKDirectManualSeenRulesEnabled() && [SPKUtils getBoolPref:@"msgs_seen_on_send"];
}

static inline BOOL SPKAutoSeenOnReplyEnabled(void) {
    return SPKDirectManualSeenRulesEnabled() && [SPKUtils getBoolPref:@"msgs_seen_on_reply"];
}

static inline BOOL SPKAutoSeenOnReactionEnabled(void) {
    return SPKDirectManualSeenRulesEnabled() && [SPKUtils getBoolPref:@"msgs_seen_on_reaction"];
}

static inline BOOL SPKAutoSeenOnTypingEnabled(void) {
    return SPKDirectManualSeenRulesEnabled() && [SPKUtils getBoolPref:@"msgs_seen_on_typing"];
}

static BOOL SPKValueIsPresent(id value) {
    if (!value || value == (id)kCFNull)
        return NO;
    if ([value isKindOfClass:[NSString class]])
        return [(NSString *)value length] > 0;
    if ([value isKindOfClass:[NSArray class]])
        return [(NSArray *)value count] > 0;
    if ([value isKindOfClass:[NSDictionary class]])
        return [(NSDictionary *)value count] > 0;
    return YES;
}

// Walks the thread's object graph looking for the first object that responds to
// `selector`. Used to reach both `markLastMessageAsSeen` and (on the same last-
// seen tracker family) `hasUnseenMessages`.
static id SPKFindDirectSeenResponder(id root, SEL selector, NSMutableSet<NSValue *> *visited) {
    if (!root)
        return nil;

    NSValue *pointerValue = [NSValue valueWithNonretainedObject:root];
    if ([visited containsObject:pointerValue])
        return nil;
    [visited addObject:pointerValue];

    if ([root respondsToSelector:selector])
        return root;

    if ([root isKindOfClass:[UIView class]]) {
        id target = SPKFindDirectSeenResponder([SPKUtils nearestViewControllerForView:(UIView *)root], selector, visited);
        if (target)
            return target;
    }

    for (NSString *selectorName in @[
             @"object",
             @"value",
             @"containingViewController",
             @"presentingViewController",
             @"currentThread"
         ]) {
        SEL accessor = NSSelectorFromString(selectorName);
        if (![root respondsToSelector:accessor])
            continue;

        id candidate = ((id (*)(id, SEL))objc_msgSend)(root, accessor);
        id target = SPKFindDirectSeenResponder(candidate, selector, visited);
        if (target)
            return target;
    }

    if ([root isKindOfClass:[UIViewController class]]) {
        UIViewController *viewController = (UIViewController *)root;
        id parentTarget = SPKFindDirectSeenResponder(viewController.parentViewController, selector, visited);
        if (parentTarget)
            return parentTarget;

        id presentingTarget = SPKFindDirectSeenResponder(viewController.presentingViewController, selector, visited);
        if (presentingTarget)
            return presentingTarget;

        id navigationTarget = SPKFindDirectSeenResponder(viewController.navigationController, selector, visited);
        if (navigationTarget)
            return navigationTarget;

        for (UIViewController *child in [(UIViewController *)root childViewControllers]) {
            id target = SPKFindDirectSeenResponder(child, selector, visited);
            if (target)
                return target;
        }
    }

    for (NSString *key in @[
             @"_lastSeenMessageTracker",
             @"lastSeenMessageTracker",
             @"_messageListViewController",
             @"messageListViewController",
             @"_directMessageListViewController",
             @"directMessageListViewController",
             @"_threadViewFeatureDelegateContainer",
             @"threadViewFeatureDelegateContainer",
             @"_threadViewControllerFeatureDelegate",
             @"threadViewControllerFeatureDelegate",
             @"_threadViewFeatureDelegate",
             @"threadViewFeatureDelegate",
             @"_featureDelegate",
             @"featureDelegate",
             @"_threadViewController",
             @"threadViewController",
             @"_containingViewController",
             @"containingViewController",
             @"_stateProvider",
             @"stateProvider",
             @"_delegate",
             @"delegate",
             @"_messageListController",
             @"messageListController",
             @"_messageList",
             @"messageList"
         ]) {
        id candidate = [key hasPrefix:@"_"] ? [SPKUtils getIvarForObj:root name:key.UTF8String] : SPKKVCObject(root, key);
        id target = SPKFindDirectSeenResponder(candidate, selector, visited);
        if (target)
            return target;
    }

    return nil;
}

static id SPKFindDirectMarkSeenTarget(id root, NSMutableSet<NSValue *> *visited) {
    return SPKFindDirectSeenResponder(root, @selector(markLastMessageAsSeen), visited);
}

static BOOL SPKMarkDirectThreadMessagesAsSeen(id controller) {
    id target = SPKFindDirectMarkSeenTarget(controller, [NSMutableSet set]);
    SPKDirectThreadContext *context = SPKDirectThreadContextFromSource(controller);
    if (!target &&
        SPKDirectActiveMarkSeenTarget &&
        SPKDirectActiveMarkSeenThreadId.length > 0 &&
        context.threadId.length > 0 &&
        [SPKDirectActiveMarkSeenThreadId isEqualToString:context.threadId]) {
        target = SPKFindDirectMarkSeenTarget(SPKDirectActiveMarkSeenTarget, [NSMutableSet set]);
        if (target) {
            SPKLog(@"Messages", @"[Sparkle MessagesSeen] Using active mark target fallback threadId=%@ source=%@<%p> target=%@<%p>",
                   context.threadId ?: @"(unknown)",
                   NSStringFromClass([controller class]),
                   controller,
                   NSStringFromClass([target class]),
                   target);
        }
    }
    if (!target) {
        SPKLog(@"General", @"[Sparkle MessagesSeen] No markLastMessageAsSeen target for controller=%@<%p> threadId=%@ activeThreadId=%@",
               NSStringFromClass([controller class]),
               controller,
               context.threadId ?: @"(unknown)",
               SPKDirectActiveMarkSeenThreadId ?: @"(none)");
        return NO;
    }

    kSPKSeenAutoBypassCount++;
    @try {
        ((void (*)(id, SEL))objc_msgSend)(target, @selector(markLastMessageAsSeen));
        SPKLog(@"General", @"[Sparkle MessagesSeen] Marked via target=%@<%p> controller=%@<%p>",
               NSStringFromClass([target class]),
               target,
               NSStringFromClass([controller class]),
               controller);
    } @catch (NSException *exception) {
        if (kSPKSeenAutoBypassCount > 0)
            kSPKSeenAutoBypassCount--;
        SPKLog(@"General", @"[Sparkle MessagesSeen] markLastMessageAsSeen failed target=%@<%p> exception=%@",
               NSStringFromClass([target class]),
               target,
               exception);
        return NO;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (kSPKSeenAutoBypassCount > 0) {
            kSPKSeenAutoBypassCount--;
        }
    });

    return YES;
}

static BOOL SPKSeenAutoShouldTrigger(id source, NSString *reason) {
    if (!source || reason.length == 0)
        return NO;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!SPKSeenAutoLastTriggerTimes) {
        SPKSeenAutoLastTriggerTimes = [NSMutableDictionary dictionary];
    }

    NSString *key = [NSString stringWithFormat:@"%@:%p", reason, source];
    NSNumber *lastTrigger = SPKSeenAutoLastTriggerTimes[key];
    if (lastTrigger && (now - lastTrigger.doubleValue) < 0.75) {
        return NO;
    }

    SPKSeenAutoLastTriggerTimes[key] = @(now);
    return YES;
}

static void SPKTriggerAutoSeenForSource(id source, NSString *reason) {
    if (!SPKDirectManualSeenAppliesToSource(source)) {
        SPKDirectThreadContext *context = SPKDirectThreadContextFromSource(source);
        SPKLog(@"Messages", @"[Sparkle MessagesSeen] Auto seen skipped reason=%@ threadId=%@ source=%@<%p> manual seen does not apply",
               reason,
               context.threadId ?: @"(unknown)",
               NSStringFromClass([source class]),
               source);
        return;
    }
    if (!SPKSeenAutoShouldTrigger(source, reason)) {
        SPKDirectThreadContext *context = SPKDirectThreadContextFromSource(source);
        SPKLog(@"Messages", @"[Sparkle MessagesSeen] Auto seen debounced reason=%@ threadId=%@ source=%@<%p>",
               reason,
               context.threadId ?: @"(unknown)",
               NSStringFromClass([source class]),
               source);
        return;
    }

    SPKDirectThreadContext *context = SPKDirectThreadContextFromSource(source);
    SPKLog(@"Messages", @"[Sparkle MessagesSeen] Auto seen scheduled reason=%@ threadId=%@ source=%@<%p>",
           reason,
           context.threadId ?: @"(unknown)",
           NSStringFromClass([source class]),
           source);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKMarkDirectThreadMessagesAsSeen(source);
    });
}

void SPKMarkDirectThreadSeenAfterOutgoingMessage(id source, BOOL isReply) {
    if (isReply) {
        if (!SPKAutoSeenOnReplyEnabled())
            return;
        SPKTriggerAutoSeenForSource(source, @"reply");
        return;
    }

    if (!SPKAutoSeenOnSendEnabled())
        return;
    SPKTriggerAutoSeenForSource(source, @"send");
}

void SPKMarkDirectThreadSeenAfterReaction(id source) {
    if (!SPKAutoSeenOnReactionEnabled())
        return;
    SPKTriggerAutoSeenForSource(source, @"reaction");
}

// Resolves the 1:1 chat partner from a thread context. Returns nil PK for
// group chats or when the participant list can't be narrowed to a single
// non-owner user — callers fall back to the full log in that case.
static void SPKDirectResolveChatPartner(SPKDirectThreadContext *context, NSString **outPK, NSString **outName) {
    if (outPK)
        *outPK = nil;
    if (outName)
        *outName = nil;
    if (!context || context.isGroup)
        return;

    NSArray<NSDictionary *> *users = context.users;
    if (![users isKindOfClass:NSArray.class] || users.count == 0)
        return;

    // Current account PK so we can exclude ourselves from the participant list.
    NSString *currentPk = nil;
    @try {
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            id session = nil;
            @try {
                session = [w valueForKey:@"userSession"];
            } @catch (__unused id e) {
            }
            id user = session ? [session valueForKey:@"user"] : nil;
            for (NSString *key in @[ @"pk", @"instagramUserID", @"instagramUserId", @"userID", @"userId" ]) {
                id v = nil;
                @try {
                    v = [user valueForKey:key];
                } @catch (__unused id e) {
                }
                if ([v isKindOfClass:NSString.class] && [v length]) {
                    currentPk = v;
                    break;
                }
                if ([v isKindOfClass:NSNumber.class]) {
                    currentPk = [v stringValue];
                    break;
                }
            }
            if (currentPk.length)
                break;
        }
    } @catch (__unused id e) {
    }

    NSMutableArray<NSDictionary *> *others = [NSMutableArray array];
    for (NSDictionary *u in users) {
        if (![u isKindOfClass:NSDictionary.class])
            continue;
        NSString *pk = [u[@"pk"] isKindOfClass:NSString.class] ? u[@"pk"] : nil;
        if (!pk.length)
            continue;
        if (currentPk.length && [pk isEqualToString:currentPk])
            continue;
        [others addObject:u];
    }

    // Only a clean 1:1 (exactly one other participant) deep-links.
    if (others.count != 1)
        return;

    NSDictionary *partner = others.firstObject;
    NSString *pk = [partner[@"pk"] isKindOfClass:NSString.class] ? partner[@"pk"] : nil;
    NSString *username = [partner[@"username"] isKindOfClass:NSString.class] ? partner[@"username"] : nil;
    NSString *fullName = [partner[@"fullName"] isKindOfClass:NSString.class] ? partner[@"fullName"] : nil;
    if (outPK)
        *outPK = pk;
    if (outName)
        *outName = username.length ? username : fullName;
}

static NSArray<UIMenuElement *> *SPKDirectSeenButtonMenuChildren(id source) {
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    SPKDirectSeenDebugPrintEnabled = YES;
    SPKDirectThreadContext *context = SPKDirectThreadContextFromSource(source);
    SPKDirectSeenDebugPrintEnabled = NO;
    NSString *toggleTitle = SPKDirectCurrentThreadRuleActionTitle(context);
    if (toggleTitle.length > 0) {
        BOOL applies = SPKDirectManualSeenAppliesToSource(context);
        UIImage *toggleImage = [SPKAssetUtils menuIconNamed:applies ? @"eye_off" : @"eye"];
        UIAction *toggleAction = [UIAction actionWithTitle:toggleTitle
                                                     image:toggleImage
                                                identifier:nil
                                                   handler:^(__unused UIAction *action) {
                                                       NSString *title = nil;
                                                       NSString *subtitle = nil;
                                                       if (!SPKDirectToggleCurrentThreadRule(context, &title, &subtitle)) {
                                                           SPKLog(@"Messages", @"[Sparkle MessagesSeen] Eye menu toggle failed threadId=%@ source=%@<%p>",
                                                                  context.threadId ?: @"(unknown)",
                                                                  NSStringFromClass([source class]),
                                                                  source);
                                                           SPKNotify(kSPKNotificationDirectThreadSeenRule, SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_CHAT_NOT_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
                                                           return;
                                                       }
                                                       SPKNotify(kSPKNotificationDirectThreadSeenRule, title, subtitle, @"circle_check_filled", SPKNotificationToneSuccess);
                                                       dispatch_async(dispatch_get_main_queue(), ^{
                                                           if ([source respondsToSelector:@selector(refreshRightBarButtonItems)]) {
                                                               [source refreshRightBarButtonItems];
                                                           } else if ([source respondsToSelector:@selector(updateThreadNavigationBar)]) {
                                                               [source updateThreadNavigationBar];
                                                           }
                                                       });
                                                   }];
        [children addObject:toggleAction];
    }

    // Same rule as the DM viewer's action-button entry: only offer it when auto-save is
    // on and the thread actually resolved.
    NSString *autoSaveTitle = [SPKUtils getBoolPref:@"msgs_auto_save"]
                                  ? SPKDirectAutoSaveCurrentThreadActionTitle(context)
                                  : nil;
    if (autoSaveTitle.length > 0) {
        BOOL autoSaveApplies = SPKDirectAutoSaveAppliesToCurrentThread(context);
        UIImage *autoSaveImage = [SPKAssetUtils menuIconNamed:autoSaveApplies ? @"download_off" : @"download"];
        UIAction *autoSaveAction = [UIAction actionWithTitle:autoSaveTitle
                                                       image:autoSaveImage
                                                  identifier:nil
                                                     handler:^(__unused UIAction *action) {
                                                         SPKDirectPresentAutoSaveThreadRuleToggle(context);
                                                     }];
        [children addObject:autoSaveAction];
    }

    // Only offered when activity notifications are on and the thread is a 1:1: presence
    // is reported per user, so a group has nothing to track.
    NSString *presenceTitle = SPKPresenceNotificationsEnabled() ? SPKPresenceCurrentChatActionTitle(context) : nil;
    if (presenceTitle.length > 0) {
        BOOL isTracked = [presenceTitle isEqualToString:@"Stop Tracking Activity"];
        UIAction *presenceAction = [UIAction actionWithTitle:presenceTitle
                                                       image:[SPKAssetUtils menuIconNamed:isTracked ? @"activity_filled" : @"activity"]
                                                  identifier:nil
                                                     handler:^(__unused UIAction *action) {
                                                         SPKPresencePresentChatRuleToggle(context);
                                                     }];
        [children addObject:presenceAction];
    }

    UIImage *logImage = [SPKAssetUtils menuIconNamed:@"channels"];
    NSString *partnerPK = nil;
    NSString *partnerName = nil;
    SPKDirectResolveChatPartner(context, &partnerPK, &partnerName);
    // Pass threadId for groups too — presentForThreadId: resolves a group entry
    // via groupForThreadId:, so a group thread opens scoped to its own log.
    NSString *threadId = context.threadId;
    UIAction *logAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_DELETED_MESSAGES")
                                              image:logImage
                                         identifier:nil
                                            handler:^(__unused UIAction *action) {
                                                if (threadId.length || partnerPK.length) {
                                                    [SPKDeletedMessagesViewController presentForThreadId:threadId senderPK:partnerPK senderName:partnerName fromViewController:nil];
                                                } else {
                                                    // Unresolved thread/participant — open the full list.
                                                    [SPKDeletedMessagesViewController presentFromViewController:nil];
                                                }
                                            }];
    [children addObject:logAction];

    UIImage *settingsImage = [SPKAssetUtils menuIconNamed:@"settings"];
    UIAction *settingsAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_MESSAGES_SETTINGS")
                                                   image:settingsImage
                                              identifier:nil
                                                 handler:^(__unused UIAction *action) {
                                                     SPKNotify(kSPKNotificationOpenTopicSettings, SPKL(@"COMMON_OPENED_SETTINGS_TOAST"), nil, @"settings", SPKNotificationToneForIconResource(@"settings"));
                                                     [SPKUtils showSettingsForTopicTitle:@"Messages"];
                                                 }];
    [children addObject:settingsAction];

    return children;
}

// The menu is assigned once when the button is installed, but both toggles are titled
// from live state ("Auto-Save This Chat" / "Stop Auto-Saving This Chat"). Resolving the
// children on each presentation keeps them honest without depending on a nav-bar rebuild
// that the composer-bubble placement never gets.
static UIMenu *SPKDirectSeenButtonMenu(id source) {
    __weak id weakSource = source;
    UIDeferredMenuElement *deferred =
        [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
            completion(SPKDirectSeenButtonMenuChildren(weakSource) ?: @[]);
        }];
    return [UIMenu menuWithTitle:@"" children:@[ deferred ]];
}

static void SPKDirectRememberActiveThreadContextForController(id controller, NSString *eventName) {
    SPKDirectThreadContext *context = SPKDirectThreadContextFromSource(controller);
    if (context.threadId.length == 0) {
        SPKLog(@"Messages", @"[Sparkle MessagesSeen] Active thread context not set event=%@ controller=%@<%p> missing threadId",
               eventName,
               NSStringFromClass([controller class]),
               controller);
        return;
    }

    objc_setAssociatedObject(controller, kSPKDirectThreadIdAssocKey, context.threadId, OBJC_ASSOCIATION_COPY_NONATOMIC);
    SPKDirectSetActiveThreadContext(context);

    id markTarget = SPKFindDirectMarkSeenTarget(controller, [NSMutableSet set]);
    if (markTarget) {
        SPKDirectActiveMarkSeenTarget = markTarget;
        SPKDirectActiveMarkSeenThreadId = [context.threadId copy];
        SPKLog(@"Messages", @"[Sparkle MessagesSeen] Active mark target set event=%@ threadId=%@ target=%@<%p>",
               eventName,
               context.threadId ?: @"(unknown)",
               NSStringFromClass([markTarget class]),
               markTarget);
    }
}

static void SPKDirectClearActiveThreadContextForController(id controller, NSString *eventName) {
    NSString *threadId = objc_getAssociatedObject(controller, kSPKDirectThreadIdAssocKey);
    SPKDirectThreadContext *activeContext = SPKDirectActiveThreadContext();
    if (threadId.length == 0) {
        SPKLog(@"Messages", @"[Sparkle MessagesSeen] Active thread context clear skipped event=%@ controller=%@<%p> no cached threadId",
               eventName,
               NSStringFromClass([controller class]),
               controller);
        return;
    }
    if (activeContext.threadId.length == 0) {
        SPKLog(@"Messages", @"[Sparkle MessagesSeen] Active thread context clear skipped event=%@ threadId=%@ no active context",
               eventName,
               threadId);
        return;
    }
    if (![activeContext.threadId isEqualToString:threadId]) {
        SPKLog(@"Messages", @"[Sparkle MessagesSeen] Active thread context clear skipped event=%@ cachedThreadId=%@ activeThreadId=%@",
               eventName,
               threadId,
               activeContext.threadId);
        return;
    }

    SPKDirectSetActiveThreadContext(nil);
    if ([SPKDirectActiveMarkSeenThreadId isEqualToString:threadId]) {
        SPKDirectActiveMarkSeenTarget = nil;
        SPKDirectActiveMarkSeenThreadId = nil;
    }
    objc_setAssociatedObject(controller, kSPKDirectThreadIdAssocKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

// The "start/stop marking seen" row is contributed to the shared inbox long-press
// menu rather than hooked here: several Sparkle features want rows on that same
// menu, and a per-feature hook would leave them wrapping each other in install
// order. See SPKDirectInboxMenu.
static void SPKInstallDirectInboxSeenContextMenuHook(void) {
    SPKDirectInboxMenuRegisterProvider(@"seen", 10, ^NSArray<UIMenuElement *> *(SPKDirectThreadContext *context, id viewModel) {
        NSString *title = SPKDirectCurrentThreadRuleActionTitle(context);
        if (title.length == 0) {
            SPKLog(@"Messages", @"[Sparkle MessagesSeen] Inbox menu row skipped: no rule title viewModel=%@<%p>",
                   NSStringFromClass([viewModel class]),
                   viewModel);
            return nil;
        }

        BOOL applies = SPKDirectManualSeenAppliesToSource(context);
        // Instagram's own rows in this menu carry 24pt glyphs, so ours matches them
        // rather than the 22pt Sparkle uses in menus it owns outright.
        UIImage *image = [SPKAssetUtils menuIconNamed:applies ? @"eye_off" : @"eye"
                                            pointSize:kSPKInstagramMenuIconPointSize];
        UIAction *toggleAction = [UIAction actionWithTitle:title
                                                     image:image
                                                identifier:nil
                                                   handler:^(__unused UIAction *action) {
                                                       NSString *notificationTitle = nil;
                                                       NSString *notificationSubtitle = nil;
                                                       if (!SPKDirectToggleCurrentThreadRule(context, &notificationTitle, &notificationSubtitle)) {
                                                           SPKLog(@"Messages", @"[Sparkle MessagesSeen] Inbox menu toggle failed threadId=%@", context.threadId ?: @"(unknown)");
                                                           SPKNotify(kSPKNotificationDirectThreadSeenRule, SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_CHAT_NOT_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
                                                           return;
                                                       }
                                                       SPKNotify(kSPKNotificationDirectThreadSeenRule, notificationTitle, notificationSubtitle, @"circle_check_filled", SPKNotificationToneSuccess);
                                                   }];
        return @[ toggleAction ];
    });
    SPKDirectInboxMenuInstallHooksIfNeeded();
}

static id SPKKVCObject(id target, NSString *key) {
    if (!target || key.length == 0)
        return nil;

    @try {
        return [target valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void SPKPlayButtonTappedHaptic(void) {
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
}

#pragma mark - Composer seen bubble

// Optional relocation of the manual-seen eye button out of the nav bar into a
// fixed bubble above the thread composer, within thumb reach. The bubble's
// *position* never moves (muscle memory); it stays visible the whole time you're
// in the thread and only hides while the composer has text (you started typing).
// Tapping marks the thread seen but leaves the bubble in place — tying its
// visibility to seen-state proved unpredictable (the seen pulse fires on scroll,
// not just on new messages), so we keep it simple and always-available.

// IMPORTANT: IG lays out the thread view (message list + composer) with manual
// frames, not Auto Layout. Adding AL constraints into that hierarchy (e.g.
// anchoring to composerView) triggers a relayout loop that blanks the message
// list. So the bubble is a plain frame-positioned CONTAINER — all Auto Layout is
// confined inside it (never referencing IG's views), and we set its frame each
// layout pass from IG's already-settled geometry.

static NSInteger const kSPKThreadSeenBubbleTag = 921346;
static const void *kSPKThreadSeenBubbleComposerBottomKey = &kSPKThreadSeenBubbleComposerBottomKey;
static const void *kSPKThreadSeenKeyboardObserverKey = &kSPKThreadSeenKeyboardObserverKey;
// You can drag the bubble anywhere to peek at what's underneath; it stays where
// dropped ("displaced") until you scroll the thread, which snaps it home. The
// displaced frame is remembered on the container so layout passes don't yank it.
static const void *kSPKThreadSeenBubbleDisplacedKey = &kSPKThreadSeenBubbleDisplacedKey;
static const void *kSPKThreadSeenScrollViewKey = &kSPKThreadSeenScrollViewKey;
// Baseline contentOffset.y captured when a displaced bubble first sees the thread
// scroll; snap-home fires once cumulative offset drifts past the threshold.
static const void *kSPKThreadSeenScrollBaselineKey = &kSPKThreadSeenScrollBaselineKey;
static CGFloat const kSPKThreadSeenBubbleSize = 44.0;
// How far you must scroll before a displaced bubble snaps home — enough to read a
// bit under it without it darting back on the first pixel of movement. Measured as
// cumulative contentOffset drift (NOT single-gesture finger travel), so multiple
// short flicks and momentum scrolling accumulate toward it.
static CGFloat const kSPKThreadSeenScrollSnapThreshold = 200.0;
static __weak UIViewController *SPKThreadSeenBubbleActiveVC = nil;

static inline BOOL SPKThreadSeenBubbleDisplaced(UIView *container) {
    return [objc_getAssociatedObject(container, kSPKThreadSeenBubbleDisplacedKey) boolValue];
}

static inline void SPKSetThreadSeenBubbleDisplaced(UIView *container, BOOL displaced) {
    objc_setAssociatedObject(container, kSPKThreadSeenBubbleDisplacedKey,
                             displaced ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Clearing displacement resets the scroll baseline so the next displacement
    // re-captures a fresh reference offset (recorded lazily on the next scroll).
    if (!displaced)
        objc_setAssociatedObject(container, kSPKThreadSeenScrollBaselineKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Seen button placement: "top" (nav bar, default) or "bottom" (composer bubble).
static inline BOOL SPKThreadSeenButtonAtBottom(void) {
    return [[SPKUtils getStringPref:@"msgs_seen_button_position"] isEqualToString:@"bottom"];
}

static inline BOOL SPKThreadSeenBubbleEnabled(void) {
    return SPKDirectManualSeenRulesEnabled() && SPKThreadSeenButtonAtBottom();
}

static UIView *SPKThreadComposerView(UIViewController *controller) {
    if ([controller respondsToSelector:@selector(composerView)]) {
        id view = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(composerView));
        if ([view isKindOfClass:[UIView class]])
            return (UIView *)view;
    }

    // IG 410 exposes no `composerView` getter — only the backing ivar (the getter
    // arrives later). Read it directly so the bubble tracks the composer there
    // too, instead of falling back to the keyboard's frame alone.
    for (Class cls = [controller class]; cls && cls != [UIViewController class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, "_composerView");
        if (!ivar)
            continue;
        id view = object_getIvar(controller, ivar);
        return [view isKindOfClass:[UIView class]] ? (UIView *)view : nil;
    }
    return nil;
}

static NSUInteger SPKThreadComposerTextLength(UIViewController *controller) {
    if (![controller respondsToSelector:@selector(composerText)])
        return 0;
    id text = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(composerText));
    if ([text isKindOfClass:[NSString class]])
        return [(NSString *)text length];
    if ([text isKindOfClass:[NSAttributedString class]])
        return [(NSAttributedString *)text length];
    return 0;
}

static SPKChromeButton *SPKThreadSeenBubbleInnerButton(UIView *container) {
    for (UIView *subview in container.subviews) {
        if ([subview isKindOfClass:[SPKChromeButton class]])
            return (SPKChromeButton *)subview;
    }
    return nil;
}

// The bubble matches the composer by reusing IG's actual blur material. The blur
// lives inside an SPKChromeCanvas so "Hide UI on Capture" redacts it (secure-field
// content is excluded from captures). NO shadow/border on the container — those
// render OUTSIDE the secure canvas and would leak into screenshots.

// IG builds the composer pill from a UIVisualEffectView (see
// +buildLightBlurOvalBackgroundViewWithBlurEffectStyle:). Reuse its exact blur
// effect so the bubble is the same material as the composer, tracking theme
// switches. Returns nil when no blur is found (falls back to chrome material).
static UIVisualEffect *SPKThreadComposerBlurEffect(UIViewController *controller) {
    UIView *composer = SPKThreadComposerView(controller);
    if (!composer)
        return nil;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:composer];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:[UIVisualEffectView class]]) {
            UIVisualEffect *effect = ((UIVisualEffectView *)view).effect;
            if ([effect isKindOfClass:[UIBlurEffect class]])
                return effect;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static void SPKApplyThreadSeenBubbleMaterial(UIViewController *controller, UIView *container) {
    SPKChromeButton *inner = SPKThreadSeenBubbleInnerButton(container);
    if (!inner)
        return;
    UIVisualEffect *composerEffect = SPKThreadComposerBlurEffect(controller);
    // Blur lives inside the button's own bubble → morphs with the iOS 26 menu
    // glass animation and redacts on capture.
    inner.bubbleEffect = composerEffect ?: [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
}

// Our container, if one is currently installed on the controller's view.
static UIView *SPKThreadSeenBubbleContainer(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded)
        return nil;
    UIView *container = [controller.view viewWithTag:kSPKThreadSeenBubbleTag];
    if (!container || !SPKThreadSeenBubbleInnerButton(container))
        return nil;
    return container;
}

static void SPKUpdateThreadSeenBubbleVisibility(UIViewController *controller, BOOL animated) {
    UIView *container = SPKThreadSeenBubbleContainer(controller);
    if (!container)
        return;

    // Always available while in the thread; only hides while you're typing.
    BOOL visible = SPKThreadComposerTextLength(controller) == 0;

    CGFloat target = visible ? 1.0 : 0.0;
    container.userInteractionEnabled = visible;
    if (ABS(container.alpha - target) < 0.01)
        return;

    if (animated) {
        [UIView animateWithDuration:0.2
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                         animations:^{
                             container.alpha = target;
                         }
                         completion:nil];
    } else {
        container.alpha = target;
    }
}

// The native "jump to present" button (IGDSMediaIconButton) lives in this same
// bottom-trailing slot above the composer and persists in the hierarchy with an
// animated alpha, so we read its stable frame and stack our bubble ABOVE it to
// avoid obscuring it. Excludes the composer's own inline icon buttons (which sit
// lower, inside the composer). Returns nil when no such button is found.
static UIView *SPKThreadJumpToPresentButton(UIViewController *controller, CGFloat composerTop) {
    Class buttonClass = NSClassFromString(@"IGDSMediaIconButton");
    if (!buttonClass)
        return nil;

    UIView *root = controller.view;
    CGFloat width = CGRectGetWidth(root.bounds);
    UIView *best = nil;
    CGFloat bestBottom = -CGFLOAT_MAX;
    NSMutableArray<UIView *> *queue = [root.subviews mutableCopy];
    while (queue.count > 0) {
        UIView *view = queue.lastObject;
        [queue removeLastObject];
        // The jump-to-present button is a FIXED overlay, never inside the scrolling
        // message list. Message bubbles carry their own IGDSMediaIconButtons (reel
        // send/save/play), so prune every scroll-view subtree to avoid matching them.
        if ([view isKindOfClass:[UIScrollView class]])
            continue;
        if ([view isKindOfClass:buttonClass]) {
            CGRect frame = [root convertRect:view.bounds fromView:view];
            // Nearest to the composer wins (largest maxY), which is the jump button
            // sitting just above the composer rather than anything higher up.
            if (CGRectGetMidX(frame) > width * 0.6 &&
                CGRectGetWidth(frame) <= 64.0 && CGRectGetHeight(frame) <= 64.0 &&
                CGRectGetMaxY(frame) <= composerTop + 6.0 &&
                CGRectGetMaxY(frame) > bestBottom) {
                best = view;
                bestBottom = CGRectGetMaxY(frame);
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return best;
}

// Frame-position the container: fixed trailing, sitting just above the composer
// (or, when present, above the native jump-to-present button). Composer bottom is
// tracked from the keyboard so the bubble slides up with it.
static void SPKLayoutThreadSeenBubble(UIViewController *controller) {
    UIView *container = SPKThreadSeenBubbleContainer(controller);
    if (!container)
        return;

    UIView *root = controller.view;
    // While the user has dragged it aside, leave the position alone (just keep it
    // frontmost) — scrolling the thread is what snaps it home again.
    if (SPKThreadSeenBubbleDisplaced(container)) {
        [root bringSubviewToFront:container];
        return;
    }

    CGRect bounds = root.bounds;
    UIEdgeInsets safe = root.safeAreaInsets;
    CGFloat size = kSPKThreadSeenBubbleSize;
    CGFloat margin = 12.0;
    CGFloat gap = 10.0;

    // Composer bottom follows the keyboard (see the keyboard observer); at rest it
    // is the safe-area bottom. Composer height comes from the composer's own bounds.
    CGFloat defaultBottom = CGRectGetHeight(bounds) - safe.bottom;
    NSNumber *trackedBottom = objc_getAssociatedObject(container, kSPKThreadSeenBubbleComposerBottomKey);
    CGFloat composerBottom = trackedBottom ? trackedBottom.doubleValue : defaultBottom;
    if (composerBottom <= CGRectGetHeight(bounds) * 0.4 || composerBottom > defaultBottom)
        composerBottom = defaultBottom;

    CGFloat composerHeight = 52.0;
    UIView *composer = SPKThreadComposerView(controller);
    if (composer && [composer isDescendantOfView:root])
        composerHeight = MAX(composerHeight, CGRectGetHeight(composer.bounds));
    CGFloat composerTop = composerBottom - composerHeight;

    // The keyboard is not the only thing that lifts the composer: opening an
    // in-app tray (GIF/sticker picker, media tray) raises it while the keyboard
    // notification reports the keyboard LEAVING, which alone would drop the
    // bubble to the bottom of the screen, on top of the tray. So also read the
    // composer's real position and let it raise the bubble — never lower it,
    // since mid keyboard animation the composer's frame can still be stale
    // while the keyboard's end frame is already correct.
    if (composer && composer.window) {
        CGRect composerFrame = [root convertRect:composer.bounds fromView:composer];
        CGFloat actualTop = CGRectGetMinY(composerFrame);
        if (CGRectGetHeight(composerFrame) > 0.0 &&
            actualTop > CGRectGetHeight(bounds) * 0.2 &&
            actualTop < CGRectGetHeight(bounds)) {
            composerTop = MIN(composerTop, actualTop);
        }
    }

    CGFloat x = CGRectGetWidth(bounds) - safe.right - margin - size;
    CGFloat baseTop = composerTop;

    // Stack above the jump-to-present button only when it actually sits above the
    // composer top (ignores a stale, un-raised frame mid keyboard animation).
    UIView *jumpButton = SPKThreadJumpToPresentButton(controller, composerTop);
    if (jumpButton) {
        CGRect jumpFrame = [root convertRect:jumpButton.bounds fromView:jumpButton];
        if (CGRectGetMinY(jumpFrame) < baseTop) {
            baseTop = CGRectGetMinY(jumpFrame);
            x = CGRectGetMidX(jumpFrame) - size / 2.0;
        }
    }

    CGFloat y = baseTop - gap - size;
    CGRect frame = CGRectMake(x, y, size, size);
    if (!CGRectEqualToRect(container.frame, frame))
        container.frame = frame;
    [root bringSubviewToFront:container];
}

// Block-based keyboard observer (NOT addObserver:self — that would clobber IG's
// own keyboard registrations for the same notification). Tracks the composer
// bottom from the keyboard's end frame and repositions in the keyboard's curve.
// (Interactive swipe-to-dismiss snaps to the final position when it commits;
// a per-frame follow proved too janky to be worth it.)
static void SPKEnsureThreadSeenKeyboardObserver(UIViewController *controller) {
    if (objc_getAssociatedObject(controller, kSPKThreadSeenKeyboardObserverKey))
        return;

    __weak UIViewController *weakController = controller;
    id token = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIKeyboardWillChangeFrameNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    UIViewController *strong = weakController;
                    if (!strong || !SPKThreadSeenBubbleEnabled())
                        return;
                    UIView *container = SPKThreadSeenBubbleContainer(strong);
                    if (!container)
                        return;

                    // Opening/closing the composer resets any drag-peek — otherwise a
                    // bubble dropped low would be stranded behind the keyboard.
                    SPKSetThreadSeenBubbleDisplaced(container, NO);

                    UIView *root = strong.view;
                    CGFloat composerBottom = CGRectGetHeight(root.bounds) - root.safeAreaInsets.bottom;
                    NSValue *endValue = note.userInfo[UIKeyboardFrameEndUserInfoKey];
                    if ([endValue isKindOfClass:[NSValue class]]) {
                        CGRect keyboardEnd = [root convertRect:endValue.CGRectValue fromView:nil];
                        composerBottom = CGRectGetMinY(keyboardEnd);
                    }
                    objc_setAssociatedObject(container, kSPKThreadSeenBubbleComposerBottomKey, @(composerBottom), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                    double duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
                    NSInteger curve = [note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
                    // Re-run once the change has settled: when the composer is
                    // lifted by an in-app tray (GIF/sticker picker) rather than
                    // by the keyboard itself, IG may not have moved it yet at
                    // notification time, so this pass is the one that reads its
                    // final position.
                    void (^settle)(BOOL) = ^(__unused BOOL finished) {
                        UIViewController *settled = weakController;
                        if (!settled || !SPKThreadSeenBubbleEnabled())
                            return;
                        // Animated so the correction glides rather than snaps;
                        // a no-op when the position was already right.
                        [UIView animateWithDuration:0.2
                                              delay:0.0
                                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                                         animations:^{
                                             SPKLayoutThreadSeenBubble(settled);
                                         }
                                         completion:nil];
                    };

                    if (duration > 0.0) {
                        [UIView animateWithDuration:duration
                                              delay:0.0
                                            options:(UIViewAnimationOptions)((NSUInteger)curve << 16) | UIViewAnimationOptionBeginFromCurrentState
                                         animations:^{
                                             SPKLayoutThreadSeenBubble(strong);
                                         }
                                         completion:settle];
                    } else {
                        SPKLayoutThreadSeenBubble(strong);
                        settle(YES);
                    }
                }];
    objc_setAssociatedObject(controller, kSPKThreadSeenKeyboardObserverKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SPKRemoveThreadSeenKeyboardObserver(UIViewController *controller) {
    id token = objc_getAssociatedObject(controller, kSPKThreadSeenKeyboardObserverKey);
    if (token) {
        [[NSNotificationCenter defaultCenter] removeObserver:token];
        objc_setAssociatedObject(controller, kSPKThreadSeenKeyboardObserverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// The message list is the largest scroll view in the thread hierarchy. We watch
// its pan recognizer (finger-driven scrolls only) to snap a displaced bubble home.
static UIScrollView *SPKThreadMessageScrollView(UIViewController *controller) {
    UIScrollView *best = nil;
    CGFloat bestArea = 0.0;
    NSMutableArray<UIView *> *queue = [controller.view.subviews mutableCopy];
    while (queue.count > 0) {
        UIView *view = queue.lastObject;
        [queue removeLastObject];
        if ([view isKindOfClass:[UIScrollView class]]) {
            CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
            if (area > bestArea) {
                bestArea = area;
                best = (UIScrollView *)view;
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return best;
}

static void SPKEnsureThreadSeenScrollWatcher(UIViewController *controller) {
    if (objc_getAssociatedObject(controller, kSPKThreadSeenScrollViewKey))
        return;
    UIScrollView *scrollView = SPKThreadMessageScrollView(controller);
    if (!scrollView)
        return;
    [scrollView.panGestureRecognizer addTarget:controller action:@selector(spk_threadSeenScrollPanned:)];
    objc_setAssociatedObject(controller, kSPKThreadSeenScrollViewKey, scrollView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SPKRemoveThreadSeenScrollWatcher(UIViewController *controller) {
    UIScrollView *scrollView = objc_getAssociatedObject(controller, kSPKThreadSeenScrollViewKey);
    if (scrollView) {
        [scrollView.panGestureRecognizer removeTarget:controller action:@selector(spk_threadSeenScrollPanned:)];
        objc_setAssociatedObject(controller, kSPKThreadSeenScrollViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Snap the bubble back to its home position, animated.
static void SPKSnapThreadSeenBubbleHome(UIViewController *controller) {
    UIView *container = SPKThreadSeenBubbleContainer(controller);
    if (!container || !SPKThreadSeenBubbleDisplaced(container))
        return;
    SPKSetThreadSeenBubbleDisplaced(container, NO);
    [UIView animateWithDuration:0.3
                          delay:0.0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         SPKLayoutThreadSeenBubble(controller);
                     }
                     completion:nil];
}

static void SPKInstallThreadSeenBubble(UIViewController *controller, BOOL refreshMenu) {
    if (!controller || !controller.isViewLoaded)
        return;

    UIView *root = controller.view;
    UIView *container = [root viewWithTag:kSPKThreadSeenBubbleTag];

    if (!SPKThreadSeenBubbleEnabled() || !SPKDirectShouldShowSeenButtonForSource(controller)) {
        [container removeFromSuperview];
        return;
    }

    SPKChromeButton *inner = container ? SPKThreadSeenBubbleInnerButton(container) : nil;
    if (!inner) {
        [container removeFromSuperview];
        CGFloat size = kSPKThreadSeenBubbleSize;
        container = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, size, size)];
        container.tag = kSPKThreadSeenBubbleTag;
        container.translatesAutoresizingMaskIntoConstraints = YES;
        // No shadow/border on the container: it lives outside the secure canvas, so
        // any such adornment would survive "Hide UI on Capture".

        // The composer-matching blur is the button's OWN bubble (set via
        // bubbleEffect in SPKApplyThreadSeenBubbleMaterial), so it redacts on
        // capture and morphs with the button (iOS 26 menu glass animation).
        inner = [[SPKChromeButton alloc] initWithSymbol:@"" pointSize:24.0 diameter:size];
        [inner setIconResource:kSPKSeenMessagesBarIconResource pointSize:24.0];
        inner.iconTint = UIColor.labelColor;
        inner.bubbleColor = UIColor.clearColor;
        inner.showsMenuAsPrimaryAction = NO;
        inner.clipsToBounds = NO;
        inner.menuWillDisplayHandler = ^{ SPKPlayButtonTappedHaptic(); };
        [inner addTarget:controller action:@selector(spk_didTapThreadSeenBubble:) forControlEvents:UIControlEventTouchUpInside];
        [container addSubview:inner];
        // All Auto Layout stays inside the container — the fixed-size inner button
        // (its own width/height constraints) is pinned to the container's top-left.
        [NSLayoutConstraint activateConstraints:@[
            [inner.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [inner.topAnchor constraintEqualToAnchor:container.topAnchor],
        ]];

        // Drag-to-peek: a quick tap still marks seen (the pan only takes over once
        // you actually move), but dragging relocates the bubble until you scroll.
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:controller action:@selector(spk_threadSeenBubblePanned:)];
        [container addGestureRecognizer:pan];

        [root addSubview:container];
        refreshMenu = YES;
    }

    // Re-match the composer blur material each install (tracks theme switches).
    SPKApplyThreadSeenBubbleMaterial(controller, container);

    if (refreshMenu && inner)
        inner.menu = SPKDirectSeenButtonMenu(controller);

    SPKLayoutThreadSeenBubble(controller);
    SPKUpdateThreadSeenBubbleVisibility(controller, NO);
}

// Live-reconcile an open thread when the placement pref changes from the settings
// sheet. A page-sheet dismiss doesn't re-run viewDidAppear, so without this the
// bubble half wouldn't update until the thread is left and re-entered. Handles
// both directions: the nav-bar button is rebuilt via the refresh selector, and
// the bubble is installed or torn down by SPKInstallThreadSeenBubble (a no-op
// removal when placement is now "top").
static void SPKReconcileThreadSeenPlacement(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded)
        return;

    // Rebuild the nav bar so the top button appears/disappears for the new pref.
    if ([controller respondsToSelector:@selector(refreshRightBarButtonItems)])
        [controller performSelector:@selector(refreshRightBarButtonItems)];
    else if ([controller respondsToSelector:@selector(updateThreadNavigationBar)])
        [controller performSelector:@selector(updateThreadNavigationBar)];

    if (SPKThreadSeenBubbleEnabled()) {
        SPKThreadSeenBubbleActiveVC = controller;
        UIView *existing = SPKThreadSeenBubbleContainer(controller);
        if (existing)
            SPKSetThreadSeenBubbleDisplaced(existing, NO);
        SPKInstallThreadSeenBubble(controller, YES);
        SPKEnsureThreadSeenKeyboardObserver(controller);
        SPKEnsureThreadSeenScrollWatcher(controller);
        SPKUpdateThreadSeenBubbleVisibility(controller, NO);
    } else {
        // Now "top" — SPKInstallThreadSeenBubble removes the bubble (disabled).
        SPKInstallThreadSeenBubble(controller, NO);
    }
}

%group SPKMessageSeenButtonHooks

%hook IGTallNavigationBarView
- (void)setRightBarButtonItems:(NSArray<UIBarButtonItem *> *)items {
    NSMutableArray *new_items = [[items filteredArrayUsingPredicate:
                                            [NSPredicate predicateWithBlock:^BOOL(UIBarButtonItem *value, NSDictionary *_) {
                                                if ([value.accessibilityIdentifier isEqualToString:@"spk-seen-btn"]) {
                                                    return false;
                                                }
                                                if ([SPKUtils getBoolPref:@"msgs_hide_reels_blend"]) {
                                                    return ![value.accessibilityIdentifier isEqualToString:@"blend-button"];
                                                }

                                                return true;
                                            }]] mutableCopy];

    // Messages seen — skip the nav-bar button when the user has moved it to the
    // composer bubble.
    if (SPKDirectManualSeenRulesEnabled() && !SPKThreadSeenButtonAtBottom()) {
        UIViewController *nearestVC = [SPKUtils nearestViewControllerForView:self];
        Class directThreadClass = NSClassFromString(@"IGDirectThreadViewController");
        if (directThreadClass && [nearestVC isKindOfClass:directThreadClass] && SPKDirectShouldShowSeenButtonForSource(nearestVC)) {
            SPKChromeButton *chromeButton = nil;
            UIBarButtonItem *seenButton = SPKChromeBarButtonItem(@"", 24.0, self, @selector(seenButtonHandler:), &chromeButton);
            [chromeButton setIconResource:kSPKSeenMessagesBarIconResource pointSize:24.0];
            seenButton.accessibilityIdentifier = @"spk-seen-btn";
            chromeButton.bubbleColor = UIColor.clearColor;
            chromeButton.iconTint = UIColor.labelColor;
            chromeButton.menu = SPKDirectSeenButtonMenu(nearestVC);
            chromeButton.showsMenuAsPrimaryAction = NO;
            chromeButton.menuWillDisplayHandler = ^{ SPKPlayButtonTappedHaptic(); };
            [new_items addObject:seenButton];
        }
    }

    %orig([new_items copy]);
}

// Messages seen button
%new - (void)seenButtonHandler:(UIBarButtonItem *)sender {
(void)sender;
SPKPlayButtonTappedHaptic();
UIViewController *nearestVC = [SPKUtils nearestViewControllerForView:self];
if ([nearestVC isKindOfClass:%c(IGDirectThreadViewController)]) {
    if (SPKMarkDirectThreadMessagesAsSeen(nearestVC)) {
        SPKNotify(kSPKNotificationThreadMessagesMarkSeen, SPKL(@"MESSAGES_SEEN_MARKED_MESSAGES_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
    } else {
        SPKNotify(kSPKNotificationThreadMessagesMarkSeen, SPKL(@"MESSAGES_SEEN_MARK_MESSAGES_FAILED_TOAST"), nil, @"error_filled", SPKNotificationToneError);
    }
}
}
%end

%hook IGDirectThreadViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!SPKDirectSeenHooksNeeded())
        return;
    SPKDirectRememberActiveThreadContextForController(self, @"viewWillAppear");
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!SPKDirectSeenHooksNeeded())
        return;
    SPKDirectRememberActiveThreadContextForController(self, @"viewDidAppear");
    // Track the open thread regardless of placement so a live placement change
    // from the settings sheet can reconcile it (the top→bottom case needs this
    // even though no bubble exists yet).
    SPKThreadSeenBubbleActiveVC = self;
    if (SPKThreadSeenBubbleEnabled()) {
        // Fresh appearance always starts at the home position.
        UIView *existing = SPKThreadSeenBubbleContainer(self);
        if (existing)
            SPKSetThreadSeenBubbleDisplaced(existing, NO);
        SPKInstallThreadSeenBubble(self, YES);
        SPKEnsureThreadSeenKeyboardObserver(self);
        SPKEnsureThreadSeenScrollWatcher(self);
        SPKUpdateThreadSeenBubbleVisibility(self, NO);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"MessageSeenButtons.viewDidLayoutSubviews");
    // Cheap reposition only — the bubble is installed in viewDidAppear. Avoids
    // rebuilding thread context on every layout pass.
    if (SPKThreadSeenBubbleEnabled())
        SPKLayoutThreadSeenBubble(self);
}

// Composer text listener callback — hide the bubble the moment you start typing,
// bring it back when the composer is cleared.
- (void)composer:(id)composer didChangeToText:(id)text mode:(id)mode {
    %orig;
    if (SPKThreadSeenBubbleEnabled())
        SPKUpdateThreadSeenBubbleVisibility(self, YES);
    // Mark seen the moment you start typing a reply. The auto-seen pipeline is
    // debounced per source+reason, so it fires once when the composer goes from
    // empty to non-empty rather than on every keystroke.
    if (SPKAutoSeenOnTypingEnabled() && SPKThreadComposerTextLength(self) > 0)
        SPKTriggerAutoSeenForSource(self, @"typing");
}

%new - (void)spk_didTapThreadSeenBubble:(UIButton *)sender {
(void)sender;
SPKPlayButtonTappedHaptic();
if (SPKMarkDirectThreadMessagesAsSeen(self)) {
    SPKNotify(kSPKNotificationThreadMessagesMarkSeen, SPKL(@"MESSAGES_SEEN_MARKED_MESSAGES_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
} else {
    SPKNotify(kSPKNotificationThreadMessagesMarkSeen, SPKL(@"MESSAGES_SEEN_MARK_MESSAGES_FAILED_TOAST"), nil, @"error_filled", SPKNotificationToneError);
}
// The bubble stays put after marking — no seen-state-driven hide/reappear.
}

// Drag-to-peek: relocate the bubble under the finger and mark it displaced so the
// layout passes stop repositioning it. It stays where you drop it until you scroll.
%new - (void)spk_threadSeenBubblePanned:(UIPanGestureRecognizer *)pan {
    UIView *container = SPKThreadSeenBubbleContainer(self);
    if (!container)
        return;
    UIView *root = self.view;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged: {
            SPKSetThreadSeenBubbleDisplaced(container, YES);
            CGPoint t = [pan translationInView:root];
            CGPoint c = container.center;
            c.x += t.x;
            c.y += t.y;
            // Keep it fully on-screen, inside the safe area.
            UIEdgeInsets safe = root.safeAreaInsets;
            CGFloat half = CGRectGetWidth(container.bounds) / 2.0;
            CGFloat minX = safe.left + half;
            CGFloat maxX = CGRectGetWidth(root.bounds) - safe.right - half;
            CGFloat minY = safe.top + half;
            CGFloat maxY = CGRectGetHeight(root.bounds) - safe.bottom - half;
            c.x = MAX(minX, MIN(maxX, c.x));
            c.y = MAX(minY, MIN(maxY, c.y));
            container.center = c;
            [pan setTranslation:CGPointZero inView:root];
            [root bringSubviewToFront:container];
            break;
        }
        default:
            break;
    }
}

// A finger-driven scroll of the thread snaps a displaced bubble back home, but
// only once cumulative scroll passes a threshold so a nudge doesn't reclaim it.
//
// We measure the scroll view's contentOffset drift, NOT the pan's translation:
// translationInView: resets to zero every time the finger lifts, so a series of
// short flicks (the usual way you read a thread) never accumulates, and momentum
// scrolling — where the finger isn't moving at all — contributes nothing. Offset
// is absolute and persists across flicks and inertia, so drift accumulates
// reliably regardless of how the user scrolls.
%new - (void)spk_threadSeenScrollPanned:(UIPanGestureRecognizer *)pan {
    UIView *container = SPKThreadSeenBubbleContainer(self);
    if (!container || !SPKThreadSeenBubbleDisplaced(container))
        return;
    UIScrollView *scrollView = [pan.view isKindOfClass:[UIScrollView class]]
                                   ? (UIScrollView *)pan.view : nil;
    if (!scrollView)
        return;
    CGFloat offset = scrollView.contentOffset.y;
    NSNumber *baseline = objc_getAssociatedObject(container, kSPKThreadSeenScrollBaselineKey);
    if (!baseline) {
        // First scroll after displacement — anchor here and wait for real drift.
        objc_setAssociatedObject(container, kSPKThreadSeenScrollBaselineKey, @(offset),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (fabs(offset - baseline.doubleValue) > kSPKThreadSeenScrollSnapThreshold)
        SPKSnapThreadSeenBubbleHome(self);
}

- (void)viewDidDisappear:(BOOL)animated {
    if (!SPKDirectSeenHooksNeeded()) {
        %orig;
        return;
    }
    if (self.isMovingFromParentViewController || self.isBeingDismissed || self.parentViewController == nil) {
        SPKDirectClearActiveThreadContextForController(self, @"viewDidDisappear");
        if (SPKThreadSeenBubbleActiveVC == self)
            SPKThreadSeenBubbleActiveVC = nil;
        SPKRemoveThreadSeenScrollWatcher(self);
    } else {
        NSString *threadId = objc_getAssociatedObject(self, kSPKDirectThreadIdAssocKey);
        if (threadId.length > 0 && [SPKDirectActiveThreadContext().threadId isEqualToString:threadId]) {
            SPKLog(@"Messages", @"[Sparkle MessagesSeen] Active thread context clear skipped event=viewDidDisappear threadId=%@ controller still retained",
                   threadId);
        }
    }
    %orig;
}

- (void)dealloc {
    if (SPKDirectSeenHooksNeeded()) {
        SPKDirectClearActiveThreadContextForController(self, @"dealloc");
    }
    SPKRemoveThreadSeenKeyboardObserver(self);
    SPKRemoveThreadSeenScrollWatcher(self);
    %orig;
}
%end

// Messages seen logic
%hook IGDirectThreadViewListAdapterDataSource
- (BOOL)shouldUpdateLastSeenMessage {
    if (!SPKDirectManualSeenRulesEnabled())
        return %orig;
    if (SPKDirectManualSeenAppliesToSource(self)) {
        if (kSPKSeenAutoBypassCount > 0) {
            return %orig;
        }
        return false;
    }

    return %orig;
}
%end

%hook IGDirectMessageListViewController
- (BOOL)messageListDataSourceShouldUpdateSeenState:(id)arg1 {
    if (!SPKDirectManualSeenRulesEnabled())
        return %orig;
    if (SPKDirectManualSeenAppliesToSource(self)) {
        if (kSPKSeenAutoBypassCount > 0) {
            return %orig;
        }
        return false;
    }

    return %orig;
}
%end

%hook IGDirectMessageSenderFeatureController
- (void)sendMessageWithText:(id)text
                       quotedMessageId:(id)quotedMessageId
                      powerupsMetadata:(id)powerupsMetadata
          animatedEmojiCharacterRanges:(id)animatedEmojiCharacterRanges
                   imageGlyphLocations:(id)imageGlyphLocations
                messageSentSpeedMarker:(id)messageSentSpeedMarker
                  localSendSpeedMarker:(id)localSendSpeedMarker
                          foaLSSLogger:(id)foaLSSLogger
                          foaS2SLogger:(id)foaS2SLogger
                          igdS2SLogger:(id)igdS2SLogger
                        e2eloggerLogId:(id)e2eloggerLogId
    richTextFormatActionButtonsPressed:(id)richTextFormatActionButtonsPressed
                expressiveTextMetadata:(id)expressiveTextMetadata {
    BOOL isReply = SPKValueIsPresent(quotedMessageId);
    %orig;
    SPKMarkDirectThreadSeenAfterOutgoingMessage(self, isReply);
}

- (void)sendTextMessageWithText:(id)text
                         quotedMessage:(id)quotedMessage
                      powerupsMetadata:(id)powerupsMetadata
          animatedEmojiCharacterRanges:(id)animatedEmojiCharacterRanges
                   imageGlyphLocations:(id)imageGlyphLocations
                messageSentSpeedMarker:(id)messageSentSpeedMarker
                  localSendSpeedMarker:(id)localSendSpeedMarker
                          foaLSSLogger:(id)foaLSSLogger
                          foaS2SLogger:(id)foaS2SLogger
                          igdS2SLogger:(id)igdS2SLogger
                        e2eloggerLogId:(id)e2eloggerLogId
                      metaAIPromptData:(id)metaAIPromptData
    richTextFormatActionButtonsPressed:(id)richTextFormatActionButtonsPressed
                    scheduledTimestamp:(id)scheduledTimestamp
                expressiveTextMetadata:(id)expressiveTextMetadata {
    BOOL isReply = SPKValueIsPresent(quotedMessage);
    %orig;
    SPKMarkDirectThreadSeenAfterOutgoingMessage(self, isReply);
}
%end

%end

void SPKInstallMessageSeenButtonHooksIfNeeded(void) {
    if (!SPKDirectManualSeenRulesEnabled() && ![SPKUtils getBoolPref:@"msgs_hide_reels_blend"])
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKMessageSeenButtonHooks);
        SPKInstallDirectInboxSeenContextMenuHook();

        // Reconcile the currently open thread when placement changes live.
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKMessageSeenButtonPositionDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            UIViewController *active = SPKThreadSeenBubbleActiveVC;
            if (active)
                SPKReconcileThreadSeenPlacement(active);
        }];
    });
}
