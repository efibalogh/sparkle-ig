#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"

static inline BOOL SPKHideMetaAIDirect(void) {
    return [SPKUtils getBoolPref:@"general_hide_meta_ai_msgs"];
}

static inline BOOL SPKHideMetaAIExplore(void) {
    return [SPKUtils getBoolPref:@"general_hide_meta_ai_explore"];
}

static inline BOOL SPKHideMetaAIComments(void) {
    return [SPKUtils getBoolPref:@"general_hide_meta_ai_comments"];
}

static inline BOOL SPKHideMetaAICreation(void) {
    return [SPKUtils getBoolPref:@"general_hide_meta_ai_creation"];
}

static inline BOOL SPKHideMetaAIGlobal(void) {
    return [SPKUtils getBoolPref:@"general_hide_meta_ai_global"];
}

// Drops the gen-AI rows from a Direct message long-press menu.
// 31: Restyle
// 41: Make AI image
static NSArray *SPKHideMetaAIDirectMenuOptions(NSArray *options) {
    if (!SPKHideMetaAIDirect() || ![options isKindOfClass:NSArray.class])
        return options;
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"NOT (SELF IN %@)", @[ @(31), @(41) ]];
    return [options filteredArrayUsingPredicate:predicate];
}

%group SPKHideMetaAIHooks

// Direct

// Meta AI button functionality on direct search bar
%hook IGDirectInboxViewController
- (void)searchBarMetaAIButtonTappedOnSearchBar:(id)arg1 {
    if (SPKHideMetaAIDirect()) {
        SPKLog(@"General", @"[Sparkle] Hiding meta ai: direct search bar functionality");

        return;
    }

    return %orig;
}
%end

// AI agents in direct new message view
%hook IGDirectRecipientGenAIBotsResult
- (id)initWithGenAIBots:(id)arg1 lastFetchedTimestamp:(id)arg2 {
    if (SPKHideMetaAIDirect()) {
        SPKLog(@"General", @"[Sparkle] Hiding meta ai: direct recipient ai agents");

        return nil;
    }

    return %orig;
}
%end

// Meta AI in message composer
%hook IGDirectCommandSystemListViewController
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig();
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;

        if (SPKHideMetaAIDirect()) {

            if ([obj isKindOfClass:%c(IGDirectCommandSystemViewModel)]) {
                IGDirectCommandSystemViewModel *typedObj = (IGDirectCommandSystemViewModel *)obj;
                IGDirectCommandSystemRow *cmdSystemRow = (IGDirectCommandSystemRow *)[typedObj row];

                IGDirectCommandSystemResult *_commandResult_command = MSHookIvar<IGDirectCommandSystemResult *>(cmdSystemRow, "_commandResult_command");

                if (_commandResult_command != nil) {

                    // Meta AI
                    if ([[_commandResult_command title] isEqualToString:@"Meta AI"]) {
                        SPKLog(@"General", @"[Sparkle] Hiding meta ai: direct message composer suggestion");

                        shouldHide = YES;
                    }

                    // Meta AI (Imagine)
                    else if ([[_commandResult_command commandString] hasPrefix:@"/imagine"]) {
                        SPKLog(@"General", @"[Sparkle] Hiding meta ai: direct message composer /imagine suggestion");

                        shouldHide = YES;
                    }
                }
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

// Suggested AI chats in direct inbox header
%hook IGDirectInboxNavigationHeaderView
- (id)initWithFrame:(CGRect)arg1
                title:(id)arg2
            titleView:(id)arg3
    directInboxConfig:(IGDirectInboxConfig *)config
          userSession:(id)arg5
      loggingDelegate:(id)arg6 {
    if (SPKHideMetaAIDirect()) {
        SPKLog(@"General", @"[Sparkle] Hiding meta ai: suggested ai chats in direct inbox header");

        @try {
            [config setValue:0 forKey:@"shouldShowAIChatsEntrypointButton"];
        }
        @catch (NSException *exception) {
            SPKLog(@"General", @"[Sparkle] WARNING: %@\n\nFull object: %@", exception.reason, config);
        }
    }

    return %orig(arg1, arg2, arg3, [config copy], arg5, arg6);
}
%end

// Meta AI "imagine" in media picker
%hook IGDirectMediaPickerViewController
- (id)initWithUserSession:(id)arg1
                    config:(IGDirectMediaPickerConfig *)config
              capabilities:(id)arg3
            threadMetadata:(id)arg4
             messageSender:(id)arg5
     threadAnalyticsLogger:(id)arg6
      multimodalPerfLogger:(id)arg7
      localSendSpeedLogger:(id)arg8
    sendAttributionFactory:(id)arg9 {
    if (SPKHideMetaAIDirect()) {
        SPKLog(@"General", @"[Sparkle] Hiding meta ai: imagine tile in media picker");

        @try {
            IGDirectMediaPickerGalleryConfig *galleryConfig = [config valueForKey:@"galleryConfig"];

            [galleryConfig setValue:0 forKey:@"isImagineEntryPointEnabled"];
        }
        @catch (NSException *exception) {
            SPKLog(@"General", @"[Sparkle] WARNING: %@\n\nFull object: %@", exception.reason, config);
        }
    }

    return %orig(arg1, [config copy], arg3, arg4, arg5, arg6, arg7, arg8, arg9);
}
%end

// Write with meta ai in message composer
%hook IGDirectComposer
- (id)initWithLayoutSpecProvider:(id)arg1
                     userSession:(id)arg2
                 userLauncherSet:(id)arg3
                          config:(IGDirectComposerConfig *)config
                           style:(id)arg5
                            text:(id)arg6 {
    return %orig(arg1, arg2, arg3, [self patchConfig:config], arg5, arg6);
}

- (id)initWithLayoutSpecProvider:(id)arg1
                     userSession:(id)arg2
                 userLauncherSet:(id)arg3
                          config:(IGDirectComposerConfig *)config
                           style:(id)arg5
                            text:(id)arg6
           shouldUpdateModeLater:(BOOL)arg7 {
    return %orig(arg1, arg2, arg3, [self patchConfig:config], arg5, arg6, arg7);
}

// Returns void on 410, so the result is passed through untyped: declared as an
// object, ARC would retain whatever the return register happens to hold.
- (void *)_initializeWithLayoutSpecProvider:(id)arg1
                            userSession:(id)arg2
                        userLauncherSet:(id)arg3
                                 config:(IGDirectComposerConfig *)config
                                  style:(id)arg5
                                   text:(id)arg6
                  shouldUpdateModeLater:(BOOL)arg7 {
    return %orig(arg1, arg2, arg3, [self patchConfig:config], arg5, arg6, arg7);
}

- (void)setConfig:(IGDirectComposerConfig *)config {
    %orig([self patchConfig:config]);

    return;
}

%new - (IGDirectComposerConfig *)patchConfig:(IGDirectComposerConfig *)config {
if (SPKHideMetaAIDirect()) {

    SPKLog(@"General", @"[Sparkle] Hiding meta ai: reconfiguring direct composer");

    // writeWithAIEnabled
    @try {
        [config setValue:0 forKey:@"writeWithAIEnabled"];
    }
    @catch (NSException *exception) {
        SPKLog(@"General", @"[Sparkle] WARNING: %@\n\nFull object: %@", exception.reason, config);
    }
}

return [config copy];
}
%end

// Demangled name: IGAIRewrite.IGAIRewriteStoryRepliesPresenter
%hook _TtC11IGAIRewrite32IGAIRewriteStoryRepliesPresenter
- (BOOL)shouldShowAIRewriteButton:(id)arg1 input:(id)arg2 {
    if (SPKHideMetaAIDirect()) {
        SPKLog(@"General", @"[Sparkle] Hiding meta ai: disable ai rewrite story reply presenter");

        return NO;
    }

    return %orig(arg1, arg2);
}

%end

// Direct sticker tray picker view
%hook IGStickerTrayListAdapterDataSource
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig();
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;

        if (SPKHideMetaAIDirect()) {

            if ([obj isKindOfClass:%c(IGDirectUnifiedComposerAIStickerModel)]) {
                SPKLog(@"General", @"[Sparkle] Hiding meta ai: AI stickers option in sticker view");

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

// Long press menu on messages
// Demangled name: IGDirectMessageMenuConfiguration.IGDirectMessageMenuConfiguration
%hook _TtC32IGDirectMessageMenuConfiguration32IGDirectMessageMenuConfiguration
+ (id)menuConfigurationWithEligibleOptions:(id)options
                          messageViewModel:(id)arg2
                               contentType:(id)arg3
                                 isSticker:(_Bool)arg4
                            isMusicSticker:(_Bool)arg5
                          directNuxManager:(id)arg6
                       sessionUserDefaults:(id)arg7
                               launcherSet:(id)arg8
                               userSession:(id)arg9
                                tapHandler:(id)arg10 {
    return %orig(SPKHideMetaAIDirectMenuOptions(options), arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10);
}

// IG 448 renamed the launcherSet: argument to mobileConfig: with the same shape.
+ (id)menuConfigurationWithEligibleOptions:(id)options
                          messageViewModel:(id)arg2
                               contentType:(id)arg3
                                 isSticker:(_Bool)arg4
                            isMusicSticker:(_Bool)arg5
                          directNuxManager:(id)arg6
                       sessionUserDefaults:(id)arg7
                              mobileConfig:(id)arg8
                               userSession:(id)arg9
                                tapHandler:(id)arg10 {
    return %orig(SPKHideMetaAIDirectMenuOptions(options), arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10);
}
%end

// Expanded in-chat photo UI
// Demangled name: IGDirectAggregatedMediaViewerComponentsSwift.IGDirectAggregatedMediaViewerViewControllerTitleViewModelObject
%hook _TtC44IGDirectAggregatedMediaViewerComponentsSwift63IGDirectAggregatedMediaViewerViewControllerTitleViewModelObject
- (id)initWithAuthorProfileImage:(id)arg1
                  authorUsername:(id)arg2
                      canForward:(_Bool)arg3
                         canSave:(_Bool)arg4
                   canAddToStory:(_Bool)arg5
                canShowAIRestyle:(_Bool)arg6
                       canUnsend:(_Bool)arg7
                       canReport:(_Bool)arg8
                   displayConfig:(id)arg9
                       isPending:(_Bool)arg10
             isMoreMenuListStyle:(_Bool)arg11
             senderIsCurrentUser:(_Bool)arg12
             shouldHideInfoViews:(_Bool)arg13
                        subtitle:(id)arg14
                      entryPoint:(long long)arg15
                    canTapAuthor:(_Bool)arg16 {
    BOOL showAiRestyle = SPKHideMetaAIDirect() ? false : arg6;

    return %orig(arg1, arg2, arg3, arg4, arg5, showAiRestyle, arg7, arg8, arg9, arg10, arg11, arg12, arg13, arg14, arg15, arg16);
}
%end

// AI generated DM channel themes
%hook IGDirectThreadThemePickerViewController
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig();
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;

        if (SPKHideMetaAIDirect()) {

            if (
                [obj isKindOfClass:%c(IGDirectThreadThemePickerOption)] && [[obj valueForKey:@"themeId"] isEqualToString:@"direct_ai_theme_creation"]) {
                SPKLog(@"General", @"[Sparkle] Hiding meta ai: AI generated DM channel themes");

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

// "Click to summarize" pill under DM navigation bar
%hook IGDirectThreadViewMetaAISummaryFeatureController
- (id)initWithUserSession:(id)arg1 mutableStateProvider:(id)arg2 threadViewControllerFeatureDelegate:(id)arg3 presentingViewController:(id)arg4 {
    if (SPKHideMetaAIDirect()) {
        return nil;
    }

    return %orig(arg1, arg2, arg3, arg4);
}
%end

/////////////////////////////////////////////////////////////////////////////

// Explore

// Meta AI explore search summary
%hook IGDiscoveryListKitGQLDataSource
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig();
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;

        // Meta AI summary
        if ([obj isKindOfClass:%c(IGSearchMetaAIHCMModel)]) {

            if (SPKHideMetaAIExplore()) {
                SPKLog(@"General", @"[Sparkle] Hiding explore meta ai search summary");

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

// Meta AI search bar ring button
%hook IGSearchBarDonutButton
- (void)didMoveToWindow {
    %orig;
    SPK_PERF_SCOPE(@"HideMetaAI.didMoveToWindow");

    if (SPKHideMetaAIExplore()) {
        [self removeFromSuperview];
    }
}
%end

/////////////////////////////////////////////////////////////////////////////

// Reels/Sundial

// Suggested AI searches in comment section
%hook IGCommentConfig
- (id)initWithUserSession:(id)session
       commentThreadConfiguration:(IGCommentThreadConfiguration *)threadConfig
    sponsoredSupportConfiguration:(id)supportConfig
              CTAPresenterContext:(id)context
                        replyText:(id)text
                  loggingDelegate:(id)loggingDelegate
         presentingViewController:(id)vc
       childCommentThreadDelegate:(id)threadDelegate {
    if (SPKHideMetaAIComments()) {
        [threadConfig setValue:@(YES) forKey:@"disableMetaAICarousel"];
    }
    return %orig(session, threadConfig, supportConfig, context, text, loggingDelegate, vc, threadDelegate);
}
%end

// Suggested AI searches in comment section (workaround if setting comment thread config fails)
%hook IGCommentThreadAICarousel
- (id)initWithLauncherSet:(id)arg1 hasSearchPrefix:(BOOL)arg2 {
    if (SPKHideMetaAIComments()) {
        SPKLog(@"General", @"[Sparkle] Hiding meta ai: suggested ai searches comment carousel");

        return nil;
    }

    return %orig;
}

// IG 451 added a trailing floatsAsCenteredPill: to this initializer.
- (id)initWithLauncherSet:(id)arg1 hasSearchPrefix:(BOOL)arg2 floatsAsCenteredPill:(BOOL)arg3 {
    if (SPKHideMetaAIComments()) {
        SPKLog(@"General", @"[Sparkle] Hiding meta ai: suggested ai searches comment carousel");

        return nil;
    }

    return %orig;
}
%end

%hook _TtC34IGCommentThreadAICarouselPillSwift30IGCommentThreadAICarouselSwift
- (id)initWithLauncherSet:(id)arg1 hasSearchPrefix:(BOOL)arg2 {
    if (SPKHideMetaAIComments()) {
        SPKLog(@"General", @"[Sparkle] Hiding meta ai: suggested ai searches comment carousel");

        return nil;
    }

    return %orig;
}

// IG 451 added a trailing floatsAsCenteredPill: to this initializer.
- (id)initWithLauncherSet:(id)arg1 hasSearchPrefix:(BOOL)arg2 floatsAsCenteredPill:(BOOL)arg3 {
    if (SPKHideMetaAIComments()) {
        SPKLog(@"General", @"[Sparkle] Hiding meta ai: suggested ai searches comment carousel");

        return nil;
    }

    return %orig;
}
%end

/////////////////////////////////////////////////////////////////////////////

// Story

// AI images "add to story" suggestion
// Demangled name: IGGalleryDestinationToolbar.IGGalleryDestinationToolbarView
%hook _TtC27IGGalleryDestinationToolbar31IGGalleryDestinationToolbarView
- (void)setTools:(id)tools {
    NSArray *newTools = [tools copy];

    if (SPKHideMetaAICreation()) {
        SPKLog(@"General", @"[Sparkle] Hiding meta ai: ai images add to story suggestion");

        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"NOT (SELF IN %@)", @[ @(9), @(10), @(11) ]];
        newTools = [tools filteredArrayUsingPredicate:predicate];
    }

    %orig(newTools);

    return;
}
%end

// AI generated fonts in text entry
%hook IGCreationTextToolView
- (id)initWithMenuConfiguration:(unsigned long long)configuration userSession:(id)session creationEntryPoint:(long long)point isAIFontsEnabled:(_Bool)enabled genAINuxManager:(id)manager showFontBadge:(_Bool)badge {
    return %orig(configuration, session, point, SPKHideMetaAICreation() ? false : enabled, manager, badge);
}
%end

// Text rewrite in text entry
%hook IGStoryTextMentionLocationPickerView
- (id)initWithIsTextRewriteEnabled:(_Bool)arg1
             isImageRewriteEnabled:(_Bool)arg2
      isStackedToolSelectorEnabled:(_Bool)arg3
          isMentionLocationVisible:(_Bool)arg4
           isEnabledForFeedCaption:(_Bool)arg5
                  isFeedEntryPoint:(_Bool)arg6 {
    _Bool isTextRewriteEnabled = SPKHideMetaAICreation() ? false : arg1;
    _Bool isImageRewriteEnabled = SPKHideMetaAICreation() ? false : arg2;

    return %orig(isTextRewriteEnabled, isImageRewriteEnabled, arg3, arg4, arg5, arg6);
}
%end

// "Imagine background" and the Restyle button in the story editor action bar.
// Both toolbar classes take the full button array before layout, so dropping an
// entry there lets the remaining tools close the gap. Entries are either the
// button itself or a labeled wrapper around it, depending on the setter.
static NSArray *SPKCreationToolbarButtonsWithoutAI(id buttons) {
    if (!SPKHideMetaAICreation() || ![buttons isKindOfClass:NSArray.class])
        return buttons;

    static NSSet<NSString *> *hiddenIdentifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hiddenIdentifiers = [NSSet setWithObjects:@"contextual-background", @"ai-modify", nil];
    });

    return [(NSArray *)buttons filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id obj, NSDictionary *bindings) {
                                   id button = obj;
                                   if (![button isKindOfClass:UIView.class])
                                       button = [obj respondsToSelector:@selector(button)] ? [(IGCreationActionBarLabeledButton *)obj button] : nil;
                                   if (![button isKindOfClass:UIView.class])
                                       return YES;
                                   NSString *identifier = ((UIView *)button).accessibilityIdentifier;
                                   return !(identifier && [hiddenIdentifiers containsObject:identifier]);
                               }]];
}

%hook _TtC17IGCreationOSSwift19IGCreationHeaderBar
- (void)setButtons:(id)buttons {
    %orig(SPKCreationToolbarButtonsWithoutAI(buttons));
}

- (void)setButtons:(id)buttons maxItems:(NSInteger)max {
    %orig(SPKCreationToolbarButtonsWithoutAI(buttons), max);
}
%end

%hook _TtC17IGCreationOSSwift35IGCreationVerticalScrollableToolbar
- (void)setButtons:(id)buttons {
    %orig(SPKCreationToolbarButtonsWithoutAI(buttons));
}

- (void)setButtons:(id)buttons numDynamicButtons:(NSInteger)count {
    %orig(SPKCreationToolbarButtonsWithoutAI(buttons), count);
}
%end

/////////////////////////////////////////////////////////////////////////////

// Other

// Meta AI-branded search bars
%hook IGSearchBar
- (id)initWithConfig:(IGSearchBarConfig *)config {
    return %orig([self sanitizePlaceholderForConfig:config]);
}

- (id)initWithConfig:(IGSearchBarConfig *)config userSession:(id)arg2 {
    return %orig([self sanitizePlaceholderForConfig:config], arg2);
}

- (void)setConfig:(IGSearchBarConfig *)config {
    %orig([self sanitizePlaceholderForConfig:config]);

    return;
}

%new - (IGSearchBarConfig *)sanitizePlaceholderForConfig:(IGSearchBarConfig *)config {
if (SPKHideMetaAIGlobal()) {

    SPKLog(@"General", @"[Sparkle] Hiding meta ai: reconfiguring search bar");

    NSString *placeholder = [config valueForKey:@"placeholder"];

    if ([placeholder containsString:@"Meta AI"]) {

        // placeholder
        @try {
            [config setValue:@"Search" forKey:@"placeholder"];
        }
        @catch (NSException *exception) {
            SPKLog(@"General", @"[Sparkle] WARNING: %@\n\nFull object: %@", exception.reason, config);
        }

        // shouldAnimatePlaceholder
        @
        try {
            [config setValue:0 forKey:@"shouldAnimatePlaceholder"];
        }
        @catch (NSException *exception) {
            SPKLog(@"General", @"[Sparkle] WARNING: %@\n\nFull object: %@", exception.reason, config);
        }

        SPKLog(@"General", @"[Sparkle] Changed search bar placeholder from: \"%@\" to \"%@\"", placeholder, [config valueForKey:@"placeholder"]);

        // leftIconStyle
        @try {
            [config setValue:0 forKey:@"leftIconStyle"];
        }
        @catch (NSException *exception) {
            SPKLog(@"General", @"[Sparkle] WARNING: %@\n\nFull object: %@", exception.reason, config);
        }

        // rightButtonStyle
        @
        try {
            [config setValue:0 forKey:@"rightButtonStyle"];
        }
        @catch (NSException *exception) {
            SPKLog(@"General", @"[Sparkle] WARNING: %@\n\nFull object: %@", exception.reason, config);
        }
    }
}

return [config copy];
}
%end

@interface IGDirectMessageCellShortcutView : UIView
@end

@interface IGDirectMessageCellShortcutManager : NSObject
@end

// The "Restyle / Create with Meta AI" shortcut on a DM message-cell action row.
// Identify it by the icon button's accessibility metadata — the same signal the
// old per-view hook used, but read off the model object so it works even if the
// button was already pulled from the view hierarchy elsewhere.
// Signals for the Restyle button are language-independent and shared via SPKUtils:
// its tap target-action (_didTapRestyleShortcut) and its gen-AI glyph asset name.
// The target-action is primary — a code symbol wired at button creation, so it's
// present when our hooks run (unlike currentImage, which loads later).

static BOOL SPKShortcutViewIsMetaAI(UIView *shortcutView) {
    if (![shortcutView isKindOfClass:UIView.class])
        return NO;
    @try {
        UIButton *iconButton = MSHookIvar<UIButton *>(shortcutView, "_iconButton");
        if (iconButton == nil)
            return NO;

        // Primary: the Restyle tap action (language-independent, always wired).
        if ([SPKUtils control:iconButton hasTapActionContaining:@"Restyle"])
            return YES;

        // 437 backstop: the shortcut view's type enum (6 == Restyle / Create-with-AI).
        long long shortcutType = MSHookIvar<long long>(shortcutView, "_shortcutType");
        if (shortcutType == 6)
            return YES;

        // The gen-AI paintbrush glyph asset name.
        NSString *iconName = [SPKUtils igImageNameForImage:iconButton.currentImage];
        if ([iconName containsString:@"gen_ai"])
            return YES;

        // Automation identifier — also not localized.
        NSString *identifier = [iconButton accessibilityIdentifier] ?: @"";
        if ([identifier containsString:@"restyle"] || [identifier containsString:@"meta_ai"])
            return YES;

        // Last-resort English label match (localized: only helps on English).
        NSString *label = [iconButton accessibilityLabel] ?: @"";
        return ([label caseInsensitiveCompare:@"Restyle"] == NSOrderedSame ||
                [label caseInsensitiveCompare:@"Create with Meta AI"] == NSOrderedSame);
    }
    @catch (NSException *exception) {
        return NO;
    }
}

// Prune the AI shortcut at the manager level, right after it builds the view
// row, so the layout pass sees one fewer item and reserves no slot for it — the
// remaining shortcuts fill the space as if the AI button never existed. (The old
// approach removed the view from its superview after layout, leaving its gap.)
%hook IGDirectMessageCellShortcutManager
- (void)configureWithEligibleViewModels:(id)models
          needsUserInterfaceStyleUpdate:(BOOL)update
                      reactionPillColor:(id)pillColor
                        normalTintColor:(id)tintColor {
    %orig;

    if (!(SPKHideMetaAIDirect() || SPKHideMetaAIGlobal()))
        return;

    @try {
        NSMutableArray *order = MSHookIvar<NSMutableArray *>(self, "_shortcutViewsInDisplayOrder");
        NSMutableDictionary *byType = MSHookIvar<NSMutableDictionary *>(self, "_viewsByType");
        if (![order isKindOfClass:NSArray.class])
            return;

        for (UIView *shortcutView in [order copy]) {
            if (!SPKShortcutViewIsMetaAI(shortcutView))
                continue;

            SPKLog(@"General", @"[Sparkle] Removing Meta AI shortcut from DM cell action row");
            [order removeObjectIdenticalTo:shortcutView];
            if ([byType isKindOfClass:NSDictionary.class]) {
                for (id key in [byType allKeys]) {
                    if (byType[key] == shortcutView)
                        [byType removeObjectForKey:key];
                }
            }
            [shortcutView removeFromSuperview];
        }
    }
    @catch (NSException *exception) {
        SPKLog(@"General", @"[Sparkle] WARNING: Meta AI shortcut prune failed: %@", exception.reason);
    }
}
%end

// Older IG (e.g. 410.1.0) has no IGDirectMessageCellShortcutManager. Cache its
// presence once so the button-level fallback below only engages on builds that
// lack the manager path.
static BOOL SPKHasShortcutManager(void) {
    static BOOL has;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        has = (NSClassFromString(@"IGDirectMessageCellShortcutManager") != nil);
    });
    return has;
}

// Themed in-app buttons
%hook UIButton
- (void)didMoveToWindow {
    %orig;
    SPK_PERF_SCOPE(@"HideMetaAI.didMoveToWindow2");

    if (SPKHideMetaAIDirect() || SPKHideMetaAICreation() || SPKHideMetaAIGlobal()) {
        NSString *accessibilityID = self.accessibilityIdentifier;
        BOOL matchByID = ([accessibilityID containsString:@"meta_ai"] ||
                          [accessibilityID containsString:@"restyle"] ||
                          [accessibilityID containsString:@"magic_mod"] ||
                          [accessibilityID containsString:@"ai_restyle"] ||
                          [accessibilityID containsString:@"imagine"]);

        // On builds without the shortcut manager, the DM "Restyle / Create with
        // Meta AI" affordance is a bare IGTapButton. Identify it primarily by its
        // tap target-action (_didTapRestyleShortcut) — a code symbol, so it's
        // language-independent and already wired here (the icon loads later, which
        // is why the currentImage check missed). Fall back to the gen-AI glyph name.
        // Where the manager DOES exist it prunes the shortcut row instead.
        //
        // Scope strictly to IGTapButton: matching every UIButton reaches UIKit's
        // private nav/toolbar buttons (_UIButtonBarButton, _UIModernBarButton), and
        // removeFromSuperview on those corrupts the button bar's constraint graph
        // ("no common ancestor" Auto Layout crash).
        BOOL matchesRestyle = NO;
        if (!matchByID && !SPKHasShortcutManager() && [self isKindOfClass:%c(IGTapButton)]) {
            matchesRestyle = [SPKUtils control:self hasTapActionContaining:@"Restyle"] ||
                             [[SPKUtils igImageNameForImage:self.currentImage] containsString:@"gen_ai"];
        }

        if (matchByID) {
            SPKLog(@"General", @"[Sparkle] Hiding UIButton (id: %@)", accessibilityID);
            self.hidden = YES;
            [self removeFromSuperview];
        } else if (matchesRestyle) {
            // On 410 the IGTapButton sits inside a circular background wrapper view
            // ([button] -> [circle] -> [container]). Removing only the button leaves
            // the empty circle, so lift up to the wrapper — but never remove a view
            // that also hosts another control (the shared container with the forward
            // button), which would take the forward button down with it.
            UIView *viewToRemove = self;
            UIView *wrapper = self.superview;
            if ([wrapper isKindOfClass:UIView.class]) {
                // Lift only to a wrapper that holds nothing but this button. Text
                // inputs are not controls, so counting controls alone would also
                // remove a container that hosts a text field beside the button.
                BOOL hostsOnlyThisButton = YES;
                for (UIView *sub in wrapper.subviews) {
                    if (sub == self)
                        continue;
                    if ([sub isKindOfClass:UIControl.class] || [sub isKindOfClass:UIScrollView.class] ||
                        [sub conformsToProtocol:@protocol(UITextInput)] || sub.subviews.count > 0) {
                        hostsOnlyThisButton = NO;
                        break;
                    }
                }
                if (hostsOnlyThisButton)
                    viewToRemove = wrapper;
            }
            SPKLog(@"General", @"[Sparkle] Hiding DM Restyle button (410), removing %@", [viewToRemove class]);
            self.hidden = YES;
            [viewToRemove removeFromSuperview];
        }
    }
}

- (void)setAccessibilityIdentifier:(NSString *)accessibilityIdentifier {
    %orig;

    if (SPKHideMetaAIDirect() || SPKHideMetaAICreation() || SPKHideMetaAIGlobal()) {
        if ([accessibilityIdentifier containsString:@"meta_ai"] ||
            [accessibilityIdentifier containsString:@"restyle"] ||
            [accessibilityIdentifier containsString:@"magic_mod"] ||
            [accessibilityIdentifier containsString:@"ai_restyle"] ||
            [accessibilityIdentifier containsString:@"imagine"]) {

            SPKLog(@"General", @"[Sparkle] Hiding UIButton via setAccessibilityIdentifier: %@", accessibilityIdentifier);
            self.hidden = YES;
            [self removeFromSuperview];
        }
    }
}
%end

// Home feed meta ai button
%hook IGFloatingActionButton.IGFloatingActionButton
- (void)didMoveToSuperview {
    %orig;
    if (SPKHideMetaAIGlobal()) {
        [self removeFromSuperview];
        SPKLog(@"General", @"[Sparkle] Hiding meta ai: home feed meta ai button");
    }
}
%end

// Share sheet "Meta AI" destination in the external share row. The view, its
// controller and the ordering helper are one Swift module, so their own calls
// never reach an ObjC hook; layoutSubviews always comes through UIKit. Options
// are matched by the helper's analytics string, which is stable across
// languages, never by the label. The option list itself is left untouched: the
// buttons are built once at init, and taps map back through that list.
static BOOL SPKExternalShareOptionIsMetaAI(NSNumber *option) {
    static NSMutableDictionary<NSNumber *, NSNumber *> *cache;
    static Class helperClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
        helperClass = objc_getClass("_TtC22IGExternalShareOptions28IGExternalShareOptionsHelper");
    });
    if (![option isKindOfClass:NSNumber.class])
        return NO;
    NSNumber *cached = cache[option];
    if (cached)
        return cached.boolValue;

    SEL loggingSelector = NSSelectorFromString(@"externalShareOptionsLoggingString:");
    NSString *loggingName = nil;
    if ([helperClass respondsToSelector:loggingSelector]) {
        @try {
            id value = ((id (*)(id, SEL, long long))objc_msgSend)(helperClass, loggingSelector, option.longLongValue);
            loggingName = [value isKindOfClass:NSString.class] ? [(NSString *)value lowercaseString] : nil;
        } @catch (__unused NSException *exception) {
        }
    }
    // 454 reports the destination as "meta_ai" (option 41).
    BOOL isMetaAI = [loggingName isEqualToString:@"meta_ai"];
    cache[option] = @(isMetaAI);
    return isMetaAI;
}

// Hides the button and slides the buttons after it (same container) left by
// one slot, so the row has no gap. Runs after every layout pass, which resets
// the frames, so the shift never accumulates.
static void SPKCollapseExternalShareButton(UIView *button) {
    UIView *container = button.superview;
    if (!container)
        return;
    button.hidden = YES;

    CGFloat step = 0;
    UIView *next = nil;
    for (UIView *sibling in container.subviews) {
        if (sibling == button || sibling.hidden || CGRectGetMinX(sibling.frame) <= CGRectGetMinX(button.frame))
            continue;
        if (!next || CGRectGetMinX(sibling.frame) < CGRectGetMinX(next.frame))
            next = sibling;
    }
    step = next ? CGRectGetMinX(next.frame) - CGRectGetMinX(button.frame) : 0;
    if (step <= 0)
        return;
    for (UIView *sibling in container.subviews) {
        if (sibling != button && CGRectGetMinX(sibling.frame) > CGRectGetMinX(button.frame))
            sibling.frame = CGRectOffset(sibling.frame, -step, 0);
    }
    if ([container isKindOfClass:UIScrollView.class]) {
        UIScrollView *scrollView = (UIScrollView *)container;
        CGSize size = scrollView.contentSize;
        size.width = MAX(CGRectGetWidth(scrollView.bounds), size.width - step);
        scrollView.contentSize = size;
    }
}

%hook _TtC22IGExternalShareOptions26IGExternalShareOptionsView
- (void)layoutSubviews {
    %orig;
    if (!SPKHideMetaAIGlobal() || ![self respondsToSelector:@selector(shareOptions)])
        return;
    NSArray *options = self.shareOptions;
    if (![options isKindOfClass:NSArray.class])
        return;
    NSIndexSet *metaAI = [options indexesOfObjectsPassingTest:^BOOL(id option, NSUInteger idx, BOOL *stop) {
        return SPKExternalShareOptionIsMetaAI(option);
    }];
    if (metaAI.count == 0)
        return;

    // Swift [UIView] storage bridges as an NSArray. Only trust it when it lines
    // up one to one with the options, so a layout change can never hide the
    // wrong destination.
    id buttons = [SPKUtils getIvarForObj:self name:"buttons"];
    if (![buttons isKindOfClass:NSArray.class] || [(NSArray *)buttons count] != options.count) {
        static dispatch_once_t mismatchToken;
        dispatch_once(&mismatchToken, ^{
            SPKLog(@"General", @"[Sparkle] Share sheet meta ai: buttons %@ (%lu) do not match %lu options, skipping",
                   buttons ? NSStringFromClass([buttons class]) : @"nil",
                   [buttons respondsToSelector:@selector(count)] ? (unsigned long)[(NSArray *)buttons count] : 0UL,
                   (unsigned long)options.count);
        });
        return;
    }
    [metaAI enumerateIndexesWithOptions:NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *stop) {
        UIView *button = [(NSArray *)buttons objectAtIndex:idx];
        if ([button isKindOfClass:UIView.class])
            SPKCollapseExternalShareButton(button);
    }];
}
%end

// Share menu recipients
%hook IGDirectRecipientListViewController
- (id)objectsForListAdapter:(id)arg1 {
    NSArray *originalObjs = %orig();
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;

        if (SPKHideMetaAIDirect()) {
            if ([obj isKindOfClass:%c(IGDirectRecipientCellViewModel)]) {

                // Meta AI (catch-all)
                if ([[[obj recipient] threadName] isEqualToString:@"Meta AI"]) {
                    SPKLog(@"General", @"[Sparkle] Hiding meta ai suggested as recipient (share menu)");

                    shouldHide = YES;
                }
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

extern "C" void SPKInstallHideMetaAIHooksIfEnabled(void) {
    if (!SPKHideMetaAIDirect() &&
        !SPKHideMetaAIExplore() &&
        !SPKHideMetaAIComments() &&
        !SPKHideMetaAICreation() &&
        !SPKHideMetaAIGlobal()) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKHideMetaAIHooks,
                       IGCreationTextToolView = SPKResolveIGClass(@"IGStoryPostCaptureTextControls.IGCreationTextToolView", @"IGCreationTextToolView"),
                       IGDirectInboxNavigationHeaderView = SPKResolveIGClass(@"IGDirectInboxNavigationHeaderView.IGDirectInboxNavigationHeaderView", @"IGDirectInboxNavigationHeaderView"),
                       IGDirectThreadViewMetaAISummaryFeatureController = SPKResolveIGClass(@"IGDirectThreadViewMetaAISummaryFeatureController.IGDirectThreadViewMetaAISummaryFeatureController", @"IGDirectThreadViewMetaAISummaryFeatureController"));
    });
}
