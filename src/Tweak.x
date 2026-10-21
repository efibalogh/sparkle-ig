#import "SPKStrings.h"
#import "App/SPKFlexLoader.h"
#import "InstagramHeaders.h"
#import "Shared/ActionButton/ActionButtonCore.h"
#import "Tweak.h"
#import "Utils.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

///////////////////////////////////////////////////////////

// Screenshot handlers

#define VOID_HANDLESCREENSHOT(orig) [SPKUtils getBoolPref:@"msgs_disable_screenshot_detection"] ? nil : orig;
#define NONVOID_HANDLESCREENSHOT(orig) return VOID_HANDLESCREENSHOT(orig)

///////////////////////////////////////////////////////////

// * Tweak version *
NSString *SPKVersionString = @"v1.5.1";

// Variables that work across features
__weak id SPKPendingDirectVisualMessageToMarkSeen = nil;
NSString *SPKForcedStorySeenMediaPK = nil;
BOOL SPKForceMarkStoryAsSeen = NO;
BOOL SPKForceStoryAutoAdvance = NO;

static NSString *SPKIdentifierStringFromValue(id value) {
    if (!value || value == (id)kCFNull)
        return nil;
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)value;
        return string.length > 0 ? string : nil;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *string = [value stringValue];
        return string.length > 0 ? string : nil;
    }
    return nil;
}

static id SPKValueForSelectorOrKey(id object, NSString *name) {
    if (!object || name.length == 0)
        return nil;

    SEL selector = NSSelectorFromString(name);
    if ([object respondsToSelector:selector]) {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    }

    @try {
        return [object valueForKey:name];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL SPKObjectIsKindOfClassNamed(id object, NSString *className) {
    if (!object || className.length == 0)
        return NO;
    Class cls = NSClassFromString(className);
    if (cls && [object isKindOfClass:cls])
        return YES;

    // IG 436+ : several of these view models became Swift classes whose runtime
    // name is mangled (_TtC<len><Module><len><Class>) or dotted (Module.Class), so
    // NSClassFromString(bareName) returns nil. Walk the class chain and compare the
    // simple (last dotted component) name, with a mangled-suffix backstop.
    for (Class c = [object class]; c; c = class_getSuperclass(c)) {
        NSString *name = NSStringFromClass(c);
        if (name.length == 0)
            continue;
        if ([name isEqualToString:className])
            return YES;
        NSString *simple = [[name componentsSeparatedByString:@"."] lastObject];
        if ([simple isEqualToString:className])
            return YES;
        // Mangled form ".._TtC..NN<ClassName>" ends with the digit-length-prefixed name.
        NSString *mangledSuffix = [NSString stringWithFormat:@"%lu%@", (unsigned long)className.length, className];
        if ([name hasSuffix:mangledSuffix])
            return YES;
    }
    return NO;
}

static NSArray *SPKFilterDirectInboxObjects(NSArray *originalObjs) {
    if (![originalObjs isKindOfClass:[NSArray class]])
        return originalObjs;

    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;

        // Section header
        if (SPKObjectIsKindOfClassNamed(obj, @"IGDirectInboxHeaderCellViewModel")) {
            NSString *title = SPKValueForSelectorOrKey(obj, @"title");

            // "Suggestions" header
            if ([title isEqualToString:@"Suggestions"]) {
                if ([SPKUtils getBoolPref:@"general_hide_suggested_users_msgs"]) {
                    SPKLog(@"General", @"[Sparkle] Hiding suggested chats (header: messages tab)");
                    shouldHide = YES;
                }
            }

            // "Accounts to follow/message" header
            else if ([title hasPrefix:@"Accounts to"]) {
                if ([SPKUtils getBoolPref:@"general_hide_suggested_users_msgs"]) {
                    SPKLog(@"General", @"[Sparkle] Hiding suggested users: (header: inbox view)");
                    shouldHide = YES;
                }
            }
        }

        // Suggested recipients
        else if (SPKObjectIsKindOfClassNamed(obj, @"IGDirectInboxSuggestedThreadCellViewModel")) {
            if ([SPKUtils getBoolPref:@"general_hide_suggested_users_msgs"]) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested chats (recipients: channels tab)");
                shouldHide = YES;
            }
        }

        // "Accounts to follow" recipients
        else if (SPKObjectIsKindOfClassNamed(obj, @"IGDiscoverPeopleItemConfiguration") ||
                 SPKObjectIsKindOfClassNamed(obj, @"IGDiscoverPeopleConnectionItemConfiguration")) {
            if ([SPKUtils getBoolPref:@"general_hide_suggested_users_msgs"]) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested chats: (recipients: inbox view)");
                shouldHide = YES;
            }
        }

        // Hide notes tray
        else if (SPKObjectIsKindOfClassNamed(obj, @"IGDirectNotesTrayRowViewModel")) {
            if ([SPKUtils getBoolPref:@"msgs_hide_notes_tray"]) {
                SPKLog(@"General", @"[Sparkle] Hiding notes tray");
                shouldHide = YES;
            }
        }

        if (!shouldHide) {
            [filteredObjs addObject:obj];
        }
    }

    return [filteredObjs copy];
}

static NSString *SPKStoryMediaIdentifierFromObject(id object, NSInteger depth) {
    if (!object || depth > 3)
        return nil;

    for (NSString *name in @[ @"pk", @"mediaPK", @"mediaPk", @"mediaID", @"mediaId", @"id", @"itemID", @"itemId" ]) {
        NSString *identifier = SPKIdentifierStringFromValue(SPKValueForSelectorOrKey(object, name));
        if (identifier.length > 0)
            return identifier;
    }

    for (NSString *name in @[ @"media", @"mediaItem", @"storyItem", @"item", @"model" ]) {
        id nested = SPKValueForSelectorOrKey(object, name);
        if (nested && nested != object) {
            NSString *identifier = SPKStoryMediaIdentifierFromObject(nested, depth + 1);
            if (identifier.length > 0)
                return identifier;
        }
    }

    return nil;
}

NSString *SPKStoryMediaIdentifier(id media) {
    return SPKStoryMediaIdentifierFromObject(media, 0);
}

static void SPKShowPendingRepostFeedbackIfNeeded(SPKActionButtonSource source) {
    NSDictionary<NSString *, NSString *> *feedback = SPKConsumePendingRepostFeedback(source);
    if (!feedback)
        return;
    NSString *iconResource = feedback[@"iconResource"] ?: @"ig_icon_reshare_outline_24";
    SPKNotify(kSPKNotificationRepost, feedback[@"title"] ?: SPKL(@"GENERAL_REPOST_TAPPED_TOAST"), nil, iconResource, SPKNotificationToneForIconResource(iconResource));
}

@interface _UISheetDetent : NSObject
+ (instancetype)_mediumDetent;
+ (instancetype)_largeDetent;
@end

@interface _UISheetPresentationController : NSObject
@property (nonatomic, assign, setter=_setPresentsAtStandardHalfHeight:) BOOL _presentsAtStandardHalfHeight;
@property (nonatomic, copy, setter=_setDetents:) NSArray *_detents;
@property (nonatomic, assign, setter=_setIndexOfCurrentDetent:) NSInteger _indexOfCurrentDetent;
@property (nonatomic, assign, setter=_setPrefersScrollingExpandsToLargerDetentWhenScrolledToEdge:) BOOL _prefersScrollingExpandsToLargerDetentWhenScrolledToEdge;
@property (nonatomic, assign, setter=_setIndexOfLastUndimmedDetent:) NSInteger _indexOfLastUndimmedDetent;
@end

static const void *kSPKFlexThreeFingerGestureKey = &kSPKFlexThreeFingerGestureKey;

// MARK: Liquid glass

%group SPKTweakLaunchCriticalHooks

%hook IGDSLauncherConfig
- (_Bool)isLiquidGlassInAppNotificationEnabled {
    return [SPKUtils spk_liquidGlassLauncherPrefKey:@"interface_liquid_glass" orig:%orig];
}
- (_Bool)isLiquidGlassContextMenuEnabled {
    return [SPKUtils spk_liquidGlassLauncherPrefKey:@"interface_liquid_glass" orig:%orig];
}
- (_Bool)isLiquidGlassToastEnabled {
    return [SPKUtils spk_liquidGlassLauncherPrefKey:@"interface_liquid_glass" orig:%orig];
}
- (_Bool)isLiquidGlassToastPeekEnabled {
    return [SPKUtils spk_liquidGlassLauncherPrefKey:@"interface_liquid_glass" orig:%orig];
}
- (_Bool)isLiquidGlassAlertDialogEnabled {
    return [SPKUtils spk_liquidGlassLauncherPrefKey:@"interface_liquid_glass" orig:%orig];
}
- (_Bool)isLiquidGlassIconBarButtonEnabled {
    return [SPKUtils spk_liquidGlassLauncherPrefKey:@"interface_liquid_glass" orig:%orig];
}
%end

// IG 447 moved the toast gate off IGDSLauncherConfig into this Swift class.
// The launcher-config toast hooks above still cover older versions.
%hook _TtC20IGDSToastLiquidGlass20IGDSToastLiquidGlass
+ (_Bool)isEnabled {
    return [SPKUtils spk_liquidGlassLauncherPrefKey:@"interface_liquid_glass" orig:%orig];
}
%end

// MARK: Bug reports

// Disable sending modded insta bug reports
%hook IGWindow
- (void)showDebugMenu {
    return;
}
%end

%hook IGBugReportUploader
- (id)initWithNetworker:(id)arg1
             pandoGraphQLService:(id)arg2
                 analyticsLogger:(id)arg3
                    userDefaults:(id)arg4
             launcherSetProvider:(id)arg5
    shouldPersistLastBugReportId:(id)arg6 {
    return nil;
}
%end

%end

// MARK: Screenshots

%group SPKTweakPrivacyHooks

// Disable anti-screenshot feature on visual messages
%hook IGStoryViewerContainerView
- (void)setShouldBlockScreenshot:(BOOL)arg1 viewModel:(id)arg2 {
    VOID_HANDLESCREENSHOT(%orig);
}
%end

// Disable screenshot logging/detection
%hook IGDirectVisualMessageViewerSession
- (id)visualMessageViewerController:(id)arg1 didDetectScreenshotForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {
    NONVOID_HANDLESCREENSHOT(%orig);
}
%end

%hook IGDirectVisualMessageReplayService
- (id)visualMessageViewerController:(id)arg1 didDetectScreenshotForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {
    NONVOID_HANDLESCREENSHOT(%orig);
}
%end

%hook IGDirectVisualMessageReportService
- (id)visualMessageViewerController:(id)arg1 didDetectScreenshotForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {
    NONVOID_HANDLESCREENSHOT(%orig);
}
%end

%hook IGDirectVisualMessageScreenshotSafetyLogger
- (id)initWithUserSession:(id)arg1 entryPoint:(NSInteger)arg2 {
    if ([SPKUtils getBoolPref:@"msgs_disable_screenshot_detection"]) {
        SPKLog(@"General", @"[Sparkle] Disable visual message screenshot safety logger");
        return nil;
    }

    return %orig;
}
%end

%hook IGScreenshotObserver
- (id)initForController:(id)arg1 {
    NONVOID_HANDLESCREENSHOT(%orig);
}
%end

%hook IGScreenshotObserverDelegate
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
    VOID_HANDLESCREENSHOT(%orig);
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
    VOID_HANDLESCREENSHOT(%orig);
}
%end

%hook IGDirectMediaViewerViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
    VOID_HANDLESCREENSHOT(%orig);
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
    VOID_HANDLESCREENSHOT(%orig);
}
%end

%hook IGStoryViewerViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
    VOID_HANDLESCREENSHOT(%orig);
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
    VOID_HANDLESCREENSHOT(%orig);
}
%end

// IG 451 moved the story viewer's screenshot callbacks off the view controller
// into this handler. Demangled name: IGStoryViewerScreenshotHandler.IGStoryViewerScreenshotHandler
%hook _TtC30IGStoryViewerScreenshotHandler30IGStoryViewerScreenshotHandler
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
    VOID_HANDLESCREENSHOT(%orig);
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
    VOID_HANDLESCREENSHOT(%orig);
}
%end

%hook IGSundialFeedViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
    VOID_HANDLESCREENSHOT(%orig);
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
    VOID_HANDLESCREENSHOT(%orig);
}
%end

%hook IGDirectVisualMessageViewerController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
    VOID_HANDLESCREENSHOT(%orig);
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
    VOID_HANDLESCREENSHOT(%orig);
}
%end

%end

/////////////////////////////////////////////////////////////////////////////

// MARK: Hide items

// Direct suggested chats (in search bar)
// The recipient's own bot flags identify Meta AI, Support AI and AI agents
// without matching their localized display names.
static BOOL SPKDirectRecipientIsAIBot(id recipient) {
    if (!recipient)
        return NO;
    if ([recipient respondsToSelector:@selector(isMetaAiBot)] && [recipient isMetaAiBot])
        return YES;
    if ([recipient respondsToSelector:@selector(isConnectedAIBot)] && [recipient isConnectedAIBot])
        return YES;
    Ivar metadataIvar = class_getInstanceVariable([recipient class], "_genAIBotMetadata");
    return metadataIvar && object_getIvar(recipient, metadataIvar) != nil;
}

BOOL showSearchSectionLabelForTag(NSInteger tag) {
    if (
        (tag == 18 && [SPKUtils getBoolPref:@"general_hide_meta_ai_msgs"])           // AI
        || (tag == 20 && [SPKUtils getBoolPref:@"general_hide_meta_ai_msgs"])        // Ask Meta AI
        || (tag == 2 && [SPKUtils getBoolPref:@"general_hide_suggested_users_msgs"]) // More suggestions
        || (tag == 13 && [SPKUtils getBoolPref:@"msgs_hide_suggested_chats"])        // Suggested channels
    ) {
        return false;
    }

    return true;
}

%group SPKTweakMessagesHooks

%hook IGDirectInboxSearchSectionPartitioningComponent
- (id)initWithSectionTitle:(id)arg1
               maxRecipients:(NSInteger)maxRecipients
                 filterBlock:(id)arg3
                  comparator:(id)arg4
            expandedSections:(id)arg5
                        type:(NSInteger)arg6
    recipientListSectionType:(NSInteger)tag {
    if (showSearchSectionLabelForTag(tag)) {
        return %orig(arg1, maxRecipients, arg3, arg4, arg5, arg6, tag);
    } else {
        return %orig(arg1, 0, arg3, arg4, arg5, arg6, tag);
    }
}
%end

%hook IGDirectInboxSearchListAdapterDataSource
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig();
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];
    BOOL hideMetaAI = [SPKUtils getBoolPref:@"general_hide_meta_ai_msgs"];

    // Header of the section being walked, and whether this pass emptied it.
    // Section tags shift between IG versions, so a header is also dropped when
    // every row under it was filtered out.
    id currentHeader = nil;
    BOOL currentSectionKeptRow = NO;
    BOOL currentSectionDroppedRow = NO;
    NSMutableSet *emptiedHeaders = [NSMutableSet set];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;
        BOOL isHeader = [obj isKindOfClass:%c(IGLabelItemViewModel)];

        if (isHeader) {
            if (currentHeader && currentSectionDroppedRow && !currentSectionKeptRow) {
                [emptiedHeaders addObject:[NSValue valueWithNonretainedObject:currentHeader]];
            }
            currentHeader = obj;
            currentSectionKeptRow = NO;
            currentSectionDroppedRow = NO;

            NSNumber *tag = [obj valueForKey:@"tag"];
            if (tag && !showSearchSectionLabelForTag([tag intValue])) {
                shouldHide = YES;
            }

        }

        // AI agents section
        else if (
            [obj isKindOfClass:%c(IGDirectInboxSearchAIAgentsPillsSectionViewModel)] || [obj isKindOfClass:%c(IGDirectInboxSearchAIAgentsSuggestedPromptViewModel)] || [obj isKindOfClass:%c(IGDirectInboxSearchAIAgentsSuggestedPromptLoggingViewModel)]) {

            if (hideMetaAI) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested chats (ai agents)");

                shouldHide = YES;
            }

        }

        // Recipients list
        else if ([obj isKindOfClass:%c(IGDirectRecipientCellViewModel)]) {

            // Broadcast channels
            if ([[obj recipient] isBroadcastChannel]) {
                if ([SPKUtils getBoolPref:@"msgs_hide_suggested_chats"]) {
                    SPKLog(@"General", @"[Sparkle] Hiding suggested chats (broadcast channels recipient)");

                    shouldHide = YES;
                }
            }

            // Meta AI (special section types)
            else if (([obj sectionType] == 20) || [obj sectionType] == 18) {
                if (hideMetaAI) {
                    SPKLog(@"General", @"[Sparkle] Hiding meta ai suggested chats (meta ai recipient)");

                    shouldHide = YES;
                }
            }

            // Meta AI and other AI bots (Support AI, AI agents)
            else if (hideMetaAI && SPKDirectRecipientIsAIBot([obj recipient])) {
                SPKLog(@"General", @"[Sparkle] Hiding meta ai suggested chats (ai bot recipient)");

                shouldHide = YES;
            }

            // Meta AI (catch-all)
            else if ([[[obj recipient] threadName] isEqualToString:@"Meta AI"]) {
                if (hideMetaAI) {
                    SPKLog(@"General", @"[Sparkle] Hiding meta ai suggested chats (meta ai recipient)");

                    shouldHide = YES;
                }
            }
        }

        if (!isHeader) {
            if (shouldHide) {
                currentSectionDroppedRow = YES;
            } else {
                currentSectionKeptRow = YES;
            }
        }

        // Populate new objs array
        if (!shouldHide) {
            [filteredObjs addObject:obj];
        }
    }

    if (currentHeader && currentSectionDroppedRow && !currentSectionKeptRow) {
        [emptiedHeaders addObject:[NSValue valueWithNonretainedObject:currentHeader]];
    }

    if (emptiedHeaders.count > 0) {
        NSIndexSet *headerIndexes = [filteredObjs indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
            return [emptiedHeaders containsObject:[NSValue valueWithNonretainedObject:obj]];
        }];
        [filteredObjs removeObjectsAtIndexes:headerIndexes];
    }

    return [filteredObjs copy];
}
%end

// Direct suggested chats (thread creation view)
%hook IGDirectThreadCreationViewController
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig();
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;

        // Meta AI suggested user in direct new message view
        if ([SPKUtils getBoolPref:@"general_hide_meta_ai_msgs"]) {

            if ([obj isKindOfClass:%c(IGDirectCreateChatCellViewModel)]) {

                // "AI Chats"
                if ([[obj valueForKey:@"title"] isEqualToString:@"AI chats"]) {
                    SPKLog(@"General", @"[Sparkle] Hiding meta ai: direct thread creation ai chats section");

                    shouldHide = YES;
                }

            }

            else if ([obj isKindOfClass:%c(IGDirectRecipientCellViewModel)]) {

                // Meta AI suggested user
                if ([[[obj recipient] threadName] isEqualToString:@"Meta AI"]) {
                    SPKLog(@"General", @"[Sparkle] Hiding meta ai: direct thread creation ai suggestion");

                    shouldHide = YES;
                }
            }
        }

        // Invite friends to insta contacts upsell
        if ([SPKUtils getBoolPref:@"general_hide_suggested_users_msgs"]) {
            if ([obj isKindOfClass:%c(IGContactInvitesSearchUpsellViewModel)]) {
                SPKLog(@"General", @"[Sparkle] Hiding suggested users: invite contacts upsell");

                shouldHide = YES;
            }
        }

        // Populate new objs array
        if (!shouldHide) {
            [filteredObjs addObject:obj];
        }
    }

    return [filteredObjs copy];
}
%end

// Direct suggested chats (inbox view)
%hook IGDirectInboxListAdapterDataSource
- (id)objectsForListAdapter:(id)arg1 {
    return SPKFilterDirectInboxObjects(%orig());
}
%end

// Direct suggested chats (inbox view, latest Swift data source)
%hook _TtC34IGDirectInboxListAdapterDataSource34IGDirectInboxListAdapterDataSource
- (id)objectsForListAdapter:(id)arg1 {
    return SPKFilterDirectInboxObjects(%orig());
}
%end

%end

%group SPKTweakGeneralUIHooks

// Explore page results
%hook IGSearchListKitDataSource
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig();
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;

        // Meta AI
        if ([SPKUtils getBoolPref:@"general_hide_meta_ai_explore"]) {

            // Section header
            if ([obj isKindOfClass:%c(IGLabelItemViewModel)]) {

                // "Ask Meta AI" search results header
                if ([[obj valueForKey:@"labelTitle"] isEqualToString:@"Ask Meta AI"]) {
                    shouldHide = YES;
                }

            }

            // Empty search bar upsell view
            else if ([obj isKindOfClass:%c(IGSearchNullStateUpsellViewModel)]) {
                shouldHide = YES;
            }

            // Meta AI search suggestions
            else if ([obj isKindOfClass:%c(IGSearchResultNestedGroupViewModel)]) {
                shouldHide = YES;
            }

            // Meta AI suggested search results
            else if ([obj isKindOfClass:SPKResolveIGClass(@"IGSearchViewModels.IGSearchResultViewModel", @"IGSearchResultViewModel")]) {

                // itemType 6 is meta ai suggestions
                if ([obj itemType] == 6) {
                    if ([SPKUtils getBoolPref:@"general_hide_meta_ai_explore"]) {
                        shouldHide = YES;
                    }

                }

                // Meta AI user account in search results
                else if ([[[obj title] string] isEqualToString:@"meta.ai"]) {
                    if ([SPKUtils getBoolPref:@"general_hide_meta_ai_explore"]) {
                        shouldHide = YES;
                    }
                }
            }
        }

        // No suggested users
        if ([SPKUtils getBoolPref:@"general_hide_suggested_users_search"]) {

            // Section header
            if ([obj isKindOfClass:%c(IGLabelItemViewModel)]) {

                // "Suggested for you" search results header
                if ([[obj valueForKey:@"labelTitle"] isEqualToString:@"Suggested for you"]) {
                    shouldHide = YES;
                }

            }

            // Instagram users
            else if ([obj isKindOfClass:%c(IGDiscoverPeopleItemConfiguration)]) {
                shouldHide = YES;
            }

            // See all suggested users
            else if ([obj isKindOfClass:%c(IGSeeAllItemConfiguration)] && ((IGSeeAllItemConfiguration *)obj).destination == 4) {
                shouldHide = YES;
            }
        }

        // Populate new objs array
        if (!shouldHide) {
            [filteredObjs addObject:obj];
        }
    }

    return [filteredObjs copy];
}
%end

%end

%group SPKTweakFeedHooks

// Story tray
%hook IGMainStoryTrayDataSource
- (id)allItemsForTrayUsingCachedValue:(BOOL)cached {
    NSArray *originalObjs = %orig(cached);
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (IGStoryTrayViewModel *obj in originalObjs) {
        BOOL shouldHide = NO;

        if ([SPKUtils getBoolPref:@"general_hide_suggested_users_feed"]) {
            if ([obj isKindOfClass:%c(IGStoryTrayViewModel)]) {
                NSNumber *type = [((IGStoryTrayViewModel *)obj) valueForKey:@"type"];

                // 8/9 looks to be the types for recommended stories
                if ([type isEqual:@(8)] || [type isEqual:@(9)]) {
                    SPKLog(@"General", @"[Sparkle] Hiding suggested users: story tray");

                    shouldHide = YES;
                }
            }
        }

        if ([SPKUtils getBoolPref:@"general_hide_ads_feed"]) {
            // "New!" account id is 3538572169
            if ([obj isKindOfClass:%c(IGStoryTrayViewModel)] && (obj.isUnseenNux == YES || [obj.pk isEqualToString:@"3538572169"])) {
                SPKLog(@"General", @"[Sparkle] Removing ads: story tray");

                shouldHide = YES;
            }
        }

        // Populate new objs array
        if (!shouldHide) {
            [filteredObjs addObject:obj];
        }
    }

    return [filteredObjs copy];
}
%end

// Story tray expanded footer (Suggested accounts to follow)
%hook IGStoryTraySectionController
- (void)storyTrayControllerShowSUPOGEducationBump {
    if ([SPKUtils getBoolPref:@"general_hide_suggested_users_feed"])
        return;

    return %orig();
}
%end

%end

%group SPKTweakGeneralMenuHooks

// Modern IGDS app menus
%hook IGDSMenu
- (id)initWithMenuItems:(NSArray<IGDSMenuItem *> *)originalObjs edr:(BOOL)edr headerLabelText:(id)headerLabelText {
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;

        // Meta AI
        if (
            [[obj valueForKey:@"title"] isEqualToString:@"AI images"] || [[obj valueForKey:@"title"] isEqualToString:@"Meta AI"]) {

            if ([SPKUtils getBoolPref:@"general_hide_meta_ai_global"]) {
                SPKLog(@"General", @"[Sparkle] Hiding meta ai from IGDS menu");

                shouldHide = YES;
            }
        }

        // Populate new objs array
        if (!shouldHide) {
            [filteredObjs addObject:obj];
        }
    }

    return %orig([filteredObjs copy], edr, headerLabelText);
}
%end

%end

/////////////////////////////////////////////////////////////////////////////

// MARK: Confirm buttons

%group SPKTweakFeedConfirmHooks

%hook IGFeedItemUFICell
- (void)UFIButtonBarDidTapOnLike:(id)arg1 {
    %orig;
}

- (void)UFIButtonBarDidTapOnRepost:(id)arg1 {
    if ([SPKUtils getBoolPref:@"feed_confirm_repost"]) {
        SPKLog(@"General", @"[Sparkle] Confirm repost triggered");

        [SPKUtils
            showConfirmation:^(void) {
                %orig;
                SPKShowPendingRepostFeedbackIfNeeded(SPKActionButtonSourceFeed);
            }
            cancelHandler:^{
                SPKConsumePendingRepostFeedback(SPKActionButtonSourceFeed);
            }
            title:SPKL(@"FEED_CONFIRMATION_CONFIRM_REPOST_TITLE")
            message:SPKL(@"GENERAL_TWEAK_REPOST_POST_CONFIRMATION_MESSAGE")];
    } else {
        %orig;
        SPKShowPendingRepostFeedbackIfNeeded(SPKActionButtonSourceFeed);
        return;
    }
}

- (void)UFIButtonBarDidLongPressOnRepost:(id)arg1 {
    if ([SPKUtils getBoolPref:@"feed_confirm_repost"]) {
        SPKLog(@"General", @"[Sparkle] Confirm repost triggered (long press ignored)");
    } else {
        return %orig;
    }
}
- (void)UFIButtonBarDidLongPressOnRepost:(id)arg1 withGestureRecognizer:(id)arg2 {
    if ([SPKUtils getBoolPref:@"feed_confirm_repost"]) {
        SPKLog(@"General", @"[Sparkle] Confirm repost triggered (long press ignored)");
    } else {
        return %orig;
    }
}
%end

%end

%group SPKTweakReelsConfirmHooks

%hook IGSundialViewerVerticalUFI
// IG 436+ variant: handler renamed to `didTapRepostButton` (no underscore, no arg).
- (void)didTapRepostButton {
    if ([SPKUtils getBoolPref:@"reels_confirm_repost"]) {
        SPKLog(@"General", @"[Sparkle] Confirm repost triggered");

        [SPKUtils
            showConfirmation:^(void) {
                %orig;
                SPKShowPendingRepostFeedbackIfNeeded(SPKActionButtonSourceReels);
            }
            cancelHandler:^{
                SPKConsumePendingRepostFeedback(SPKActionButtonSourceReels);
            }
            title:SPKL(@"GENERAL_TWEAK_CONFIRM_REEL_REPOST_TEXT")
            message:SPKL(@"GENERAL_TWEAK_REPOST_REEL_CONFIRMATION_MESSAGE")];
    } else {
        %orig;
        SPKShowPendingRepostFeedbackIfNeeded(SPKActionButtonSourceReels);
        return;
    }
}

- (void)_didTapRepostButton {
    if ([SPKUtils getBoolPref:@"reels_confirm_repost"]) {
        SPKLog(@"General", @"[Sparkle] Confirm repost triggered");

        [SPKUtils
            showConfirmation:^(void) {
                %orig;
                SPKShowPendingRepostFeedbackIfNeeded(SPKActionButtonSourceReels);
            }
            cancelHandler:^{
                SPKConsumePendingRepostFeedback(SPKActionButtonSourceReels);
            }
            title:SPKL(@"GENERAL_TWEAK_CONFIRM_REEL_REPOST_TEXT")
            message:SPKL(@"GENERAL_TWEAK_REPOST_REEL_CONFIRMATION_MESSAGE")];
    } else {
        %orig;
        SPKShowPendingRepostFeedbackIfNeeded(SPKActionButtonSourceReels);
        return;
    }
}

- (void)_didTapRepostButton:(id)arg1 {
    if ([SPKUtils getBoolPref:@"reels_confirm_repost"]) {
        SPKLog(@"General", @"[Sparkle] Confirm repost triggered");

        [SPKUtils
            showConfirmation:^(void) {
                %orig;
                SPKShowPendingRepostFeedbackIfNeeded(SPKActionButtonSourceReels);
            }
            cancelHandler:^{
                SPKConsumePendingRepostFeedback(SPKActionButtonSourceReels);
            }
            title:SPKL(@"GENERAL_TWEAK_CONFIRM_REEL_REPOST_TEXT")
            message:SPKL(@"GENERAL_TWEAK_REPOST_REEL_CONFIRMATION_MESSAGE")];
    } else {
        %orig;
        SPKShowPendingRepostFeedbackIfNeeded(SPKActionButtonSourceReels);
        return;
    }
}

- (void)_didLongPressRepostButton:(id)arg1 {
    if ([SPKUtils getBoolPref:@"reels_confirm_repost"]) {
        SPKLog(@"General", @"[Sparkle] Confirm repost triggered (long press ignored)");
    } else {
        return %orig;
    }
}

// IG 436+ renamed this handler to drop the leading underscore.
- (void)didLongPressRepostButton:(id)arg1 {
    if ([SPKUtils getBoolPref:@"reels_confirm_repost"]) {
        SPKLog(@"General", @"[Sparkle] Confirm repost triggered (long press ignored)");
    } else {
        return %orig;
    }
}
%end

%end

/////////////////////////////////////////////////////////////////////////////

%group SPKTweakFlexEarlyCompatibilityHooks

%hook UIWindow
- (BOOL)_shouldCreateContextAsSecure {
    Class flexWindowClass = SPKFlexWindowClass();
    if (flexWindowClass && [self isKindOfClass:flexWindowClass]) {
        return YES;
    }
    return %orig;
}

- (void)becomeKeyWindow {
    %orig;

    if (objc_getAssociatedObject(self, kSPKFlexThreeFingerGestureKey)) {
        return;
    }

    Class flexWindowClass = SPKFlexWindowClass();
    if (flexWindowClass && [self isKindOfClass:flexWindowClass]) {
        return;
    }

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(spk_handleFlexGesture:)];
    longPress.minimumPressDuration = 1.0;
    longPress.numberOfTouchesRequired = 3;
    longPress.cancelsTouchesInView = NO;
    longPress.delaysTouchesBegan = NO;
    longPress.delaysTouchesEnded = NO;
    [self addGestureRecognizer:longPress];
    objc_setAssociatedObject(self, kSPKFlexThreeFingerGestureKey, longPress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new - (void)spk_handleFlexGesture:(UILongPressGestureRecognizer *)sender {
if (sender.state != UIGestureRecognizerStateBegan)
    return;

if ([SPKUtils getBoolPref:@"tools_flex_instagram"]) {
    SPKFlexShowExplorer(@"three_finger");
}
}
%end

%hook _UISheetPresentationController
- (id)initWithPresentedViewController:(id)present presentingViewController:(id)presenter {
    self = %orig;
    if ([present isKindOfClass:%c(FLEXNavigationController)]) {
        if ([self respondsToSelector:@selector(_setPresentsAtStandardHalfHeight:)]) {
            self._presentsAtStandardHalfHeight = YES;
        } else {
            self._detents = @[ [%c(_UISheetDetent) _mediumDetent], [%c(_UISheetDetent) _largeDetent] ];
        }
        self._indexOfCurrentDetent = 1;
        self._prefersScrollingExpandsToLargerDetentWhenScrolledToEdge = NO;
        self._indexOfLastUndimmedDetent = 1;
    }

    return self;
}
%end

%end

%group SPKTweakFlexLoadedCompatibilityHooks

%hook FLEXExplorerViewController
- (BOOL)_canShowWhileLocked {
    return YES;
}
%end

%end

static BOOL SPKPrefEnabled(NSString *key) {
    return [SPKUtils getBoolPref:key];
}

static BOOL SPKAnyPrefEnabled(NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        if (SPKPrefEnabled(key)) {
            return YES;
        }
    }

    return NO;
}

static void SPKInstallTweakPrivacyHooksIfNeeded(void) {
    if (!SPKPrefEnabled(@"msgs_disable_screenshot_detection")) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKTweakPrivacyHooks,
                       IGDirectVisualMessageViewerSession = SPKResolveIGClass(@"IGDirectVisualMessageViewerSession.IGDirectVisualMessageViewerSession", @"IGDirectVisualMessageViewerSession"),
                       IGDirectVisualMessageReplayService = SPKResolveIGClass(@"IGDirectVisualMessageServiceKit.IGDirectVisualMessageReplayService", @"IGDirectVisualMessageReplayService"),
                       IGDirectMediaViewerViewController = SPKResolveIGClass(@"IGDirectMediaViewerKitSwift.IGDirectMediaViewerViewController", @"IGDirectMediaViewerViewController"));
    });
}

static void SPKInstallTweakFlexSupportHooksIfNeeded(void) {
    if (!SPKFlexIsBundled()) {
        return;
    }

    static dispatch_once_t flexEarlyOnceToken;
    dispatch_once(&flexEarlyOnceToken, ^{
        %init(SPKTweakFlexEarlyCompatibilityHooks);
    });
}

void SPKInstallFlexLoadedCompatibilityHooksIfNeeded(void) {
    static dispatch_once_t flexLoadedOnceToken;
    dispatch_once(&flexLoadedOnceToken, ^{
        %init(SPKTweakFlexLoadedCompatibilityHooks);
    });
}

void SPKInstallTweakLaunchCriticalHooks(void) {
    static dispatch_once_t launchOnceToken;
    dispatch_once(&launchOnceToken, ^{
        %init(SPKTweakLaunchCriticalHooks);
    });

    SPKInstallTweakFlexSupportHooksIfNeeded();
}

void SPKInstallTweakFeedHooksIfNeeded(void) {
    if (SPKAnyPrefEnabled(@[
            @"general_hide_ads_feed",
            @"general_hide_suggested_users_feed"
        ])) {
        static dispatch_once_t feedOnceToken;
        dispatch_once(&feedOnceToken, ^{
            %init(SPKTweakFeedHooks,
                           IGMainStoryTrayDataSource = SPKResolveIGClass(@"IGMainStoryTrayDataSource.IGMainStoryTrayDataSource", @"IGMainStoryTrayDataSource"));
        });
    }

    if (SPKAnyPrefEnabled(@[
            @"feed_confirm_repost"
        ])) {
        static dispatch_once_t confirmOnceToken;
        dispatch_once(&confirmOnceToken, ^{
            %init(SPKTweakFeedConfirmHooks);
        });
    }
}

void SPKInstallTweakStoryHooksIfNeeded(void) {
    SPKInstallTweakPrivacyHooksIfNeeded();
    SPKInstallTweakFeedHooksIfNeeded();
}

void SPKInstallTweakReelsHooksIfNeeded(void) {
    SPKInstallTweakPrivacyHooksIfNeeded();

    if (!SPKAnyPrefEnabled(@[
            @"reels_confirm_repost"
        ])) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKTweakReelsConfirmHooks, IGSundialViewerVerticalUFI = SPKReelsVerticalUFIClass());
    });
}

void SPKInstallTweakMessagesHooksIfNeeded(void) {
    SPKInstallTweakPrivacyHooksIfNeeded();

    if (!SPKAnyPrefEnabled(@[
            @"general_hide_meta_ai_msgs",
            @"general_hide_suggested_users_msgs",
            @"msgs_hide_suggested_chats",
            @"msgs_hide_notes_tray"
        ])) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKTweakMessagesHooks);
    });
}

void SPKInstallTweakGeneralUIHooksIfNeeded(void) {
    if (SPKAnyPrefEnabled(@[
            @"general_hide_meta_ai_explore",
            @"general_hide_suggested_users_search"
        ])) {
        static dispatch_once_t generalOnceToken;
        dispatch_once(&generalOnceToken, ^{
            %init(SPKTweakGeneralUIHooks,
                           IGSearchListKitDataSource = SPKResolveIGClass(@"IGGenericSearch.IGSearchListKitDataSource", @"IGSearchListKitDataSource"));
        });
    }

    if (SPKPrefEnabled(@"general_hide_meta_ai_global")) {
        static dispatch_once_t menuOnceToken;
        dispatch_once(&menuOnceToken, ^{
            %init(SPKTweakGeneralMenuHooks);
        });
    }

    SPKInstallTweakFlexSupportHooksIfNeeded();
}
