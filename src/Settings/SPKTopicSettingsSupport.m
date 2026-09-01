#import "SPKSettingsInfoSheetViewController.h"
#import "SPKStrings.h"
#import "SPKTopicSettingsSupport.h"
#import "../Features/Feed/HeaderActionButton.h"
#import "SPKHeaderButtonDefaultActionPickerViewController.h"
#import "../Shared/UI/SPKNotificationCenter.h"
#import "SPKActionButtonDefaultActionPickerViewController.h"
#import "SPKBulkActionMenuEditViewController.h"
#import "SPKEditActionsListViewController.h"
#import "SPKPreferences.h"
#import "SPKSettingsViewController.h"

#import "../AssetUtils.h"
#import "../Shared/AutoSave/SPKAutoSave.h"
#import "../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../Shared/ActionButton/SPKActionDescriptor.h"
#import "../Utils.h"

CGFloat const SPKSettingsCellIconPointSize = 24.0;

UIViewController *SPKSettingsTopPresenter(void) {
    UIViewController *presenter = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (presenter.presentedViewController)
        presenter = presenter.presentedViewController;
    return presenter;
}

void SPKSettingsReloadPresenter(UIViewController *presenter) {
    SPKSettingsViewController *settingsVC = nil;
    if ([presenter isKindOfClass:SPKSettingsViewController.class]) {
        settingsVC = (SPKSettingsViewController *)presenter;
    } else if ([presenter isKindOfClass:UINavigationController.class]) {
        UIViewController *top = ((UINavigationController *)presenter).topViewController;
        if ([top isKindOfClass:SPKSettingsViewController.class])
            settingsVC = (SPKSettingsViewController *)top;
    }
    [settingsVC.tableView reloadData];
}

NSDictionary *SPKTopicSection(NSString *header, NSArray *rows, NSString *footer) {
    NSMutableDictionary *section = [@{
        @"header" : header ?: @"",
        @"rows" : rows ?: @[]
    } mutableCopy];

    if (footer.length > 0) {
        section[@"footer"] = footer;
    }

    return [section copy];
}

NSDictionary *SPKTopicSectionWithInfoSheet(NSDictionary *section, BOOL usesInfoSheet) {
    if (![section isKindOfClass:[NSDictionary class]])
        return section;

    NSMutableDictionary *overridden = [section mutableCopy];
    overridden[SPKTopicSectionInfoSheetKey] = @(usesInfoSheet);
    return [overridden copy];
}

UIImage *SPKSettingsIcon(NSString *name) {
    return [SPKAssetUtils instagramIconNamed:name pointSize:SPKSettingsCellIconPointSize];
}

UIImage *SPKSettingsSystemIcon(NSString *name, CGFloat pointSize, UIImageSymbolWeight weight) {
    UIImage *symbol = [SPKAssetUtils resolvedImageNamed:name
                                              pointSize:pointSize
                                                 weight:weight
                                                 source:SPKResolvedImageSourceSystemSymbol
                                          renderingMode:UIImageRenderingModeAlwaysTemplate];
    if (!symbol)
        return nil;

    // SF Symbols size by cap-height, so a wide/tall glyph (e.g.
    // button.vertical.right.press) renders to a larger bounding box than the
    // IG asset icons, which are a fixed square. Aspect-fit the symbol into the
    // same square canvas so it lines up with the other settings rows.
    CGFloat side = SPKSettingsCellIconPointSize;
    CGSize canvasSize = CGSizeMake(side, side);
    CGSize sourceSize = symbol.size;
    if (sourceSize.width <= 0.0 || sourceSize.height <= 0.0) {
        return symbol;
    }

    CGFloat scale = MIN(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height);
    CGSize drawSize = CGSizeMake(sourceSize.width * scale, sourceSize.height * scale);
    CGRect drawRect = CGRectMake((canvasSize.width - drawSize.width) / 2.0,
                                 (canvasSize.height - drawSize.height) / 2.0,
                                 drawSize.width,
                                 drawSize.height);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize format:format];
    UIImage *normalized = [renderer imageWithActions:^(UIGraphicsImageRendererContext *_Nonnull context) {
        (void)context;
        [symbol drawInRect:CGRectIntegral(drawRect)];
    }];
    return [normalized imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

SPKSetting *SPKSettingWithHelp(SPKSetting *setting, NSString *helpText) {
    setting.helpText = helpText;
    return setting;
}

SPKSetting *SPKSettingApplyIconTint(SPKSetting *setting, UIColor *tintColor) {
    setting.iconTintColor = tintColor;
    return setting;
}

static UIImage *SPKSelectedMenuIconInMenu(UIMenu *menu) {
    for (UIMenuElement *element in menu.children) {
        if ([element isKindOfClass:[UIMenu class]]) {
            UIImage *icon = SPKSelectedMenuIconInMenu((UIMenu *)element);
            if (icon)
                return icon;
            continue;
        }

        if (![element isKindOfClass:[UICommand class]])
            continue;
        UICommand *command = (UICommand *)element;
        NSDictionary *propertyList = command.propertyList;
        NSString *defaultsKey = propertyList[@"defaultsKey"];
        NSString *value = propertyList[@"value"];
        NSString *iconName = propertyList[@"iconName"];
        if (defaultsKey.length == 0 || value.length == 0 || iconName.length == 0)
            continue;

        // Read through the namespaced accessor so the selected-icon lookup
        // matches how menuChanged: writes (per-account effective key). A raw
        // standardUserDefaults read misses the value when per-account prefs are
        // enabled, leaving the cell stuck on its fallback icon.
        NSString *saved = [SPKUtils getStringPref:defaultsKey];
        if ([saved isEqualToString:value]) {
            return SPKSettingsIcon(iconName);
        }
    }

    return nil;
}

SPKSetting *SPKSettingApplySelectedMenuIcon(SPKSetting *setting, UIImage *fallbackIcon) {
    __weak SPKSetting *weakSetting = setting;
    setting.iconProvider = ^UIImage * {
        SPKSetting *strongSetting = weakSetting;
        if (!strongSetting)
            return fallbackIcon;
        return SPKSelectedMenuIconInMenu(strongSetting.baseMenu) ?: fallbackIcon ?
                                                                                 : strongSetting.icon;
    };
    return setting;
}

SPKSetting *SPKTopicNavigationSetting(NSString *title, NSString *iconName, CGFloat iconSize, NSArray *sections) {
    CGFloat resolvedIconSize = iconSize > 0.0 ? iconSize : SPKSettingsCellIconPointSize;
    return SPKSettingApplyIconTint([SPKSetting navigationCellWithTitle:title
                                                              subtitle:@""
                                                                  icon:[SPKAssetUtils instagramIconNamed:iconName pointSize:resolvedIconSize]
                                                           navSections:sections],
                                   [SPKUtils SPKColor_InstagramPrimaryText]);
}

SPKSetting *SPKActionButtonDefaultActionNavigationSetting(SPKActionButtonSource source) {
    SPKSetting *setting = [SPKSetting navigationCellWithTitle:SPKL(@"SPKTOPICSETTINGSSUPPORT_GENERAL_DEFAULT_TAP_ACTION_TITLE")
                                                     subtitle:@""
                                                         icon:SPKSettingsIcon(@"action")
                                               viewController:[[SPKActionButtonDefaultActionPickerViewController alloc] initWithSource:source]];
    setting.accessoryTextProvider = ^NSString * {
        return SPKActionButtonDefaultActionTitleForSource(source);
    };
    setting.iconProvider = ^UIImage * {
        return SPKSettingsIcon(SPKActionButtonDefaultActionIconNameForSource(source));
    };
    return setting;
}

static UICommand *SPKMenuCommand(NSString *title, NSString *imageName, NSString *fallback, NSString *defaultsKey, NSString *value, BOOL requiresRestart) {
    NSMutableDictionary *propertyList = [@{
        @"defaultsKey" : defaultsKey,
        @"value" : value
    } mutableCopy];

    if (requiresRestart) {
        propertyList[@"requiresRestart"] = @YES;
    }
    if (imageName.length > 0) {
        propertyList[@"iconName"] = imageName;
    }

    UIImage *image = [SPKAssetUtils resolvedImageNamed:imageName
                                    fallbackSystemName:fallback
                                             pointSize:22.0
                                                weight:UIImageSymbolWeightRegular
                                                source:(imageName.length > 0 ? SPKResolvedImageSourceInstagramIcon : SPKResolvedImageSourceSystemSymbol)
                                         renderingMode:UIImageRenderingModeAlwaysTemplate];

    return [UICommand commandWithTitle:title
                                 image:image
                                action:@selector(menuChanged:)
                          propertyList:[propertyList copy]];
}

SPKSetting *SPKActionButtonConfigurationNavigationSetting(SPKActionButtonSource source, NSString *topicTitle, NSArray<NSString *> *supportedActions, NSArray<SPKActionMenuSection *> *defaultSections) {
    SPKEditActionsListViewController *controller = [[SPKEditActionsListViewController alloc] initWithSource:source topicTitle:topicTitle];
    (void)supportedActions;
    (void)defaultSections;
    return [SPKSetting navigationCellWithTitle:SPKL(@"SPKTOPICSETTINGSSUPPORT_GENERAL_CONFIGURE_ACTIONS_TITLE")
                                      subtitle:@""
                                          icon:SPKSettingsIcon(@"slider")
                                viewController:controller];
}

UIMenu *SPKReelsTapControlMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_DEFAULT"), nil, nil, @"reels_tap_control", @"default", YES),
        [UIMenu menuWithTitle:@""
                        image:nil
                   identifier:nil
                      options:UIMenuOptionsDisplayInline
                     children:@[
                         SPKMenuCommand(SPKL(@"MENU_PAUSE_PLAY"), nil, nil, @"reels_tap_control", @"pause", YES),
                         SPKMenuCommand(SPKL(@"MENU_MUTE_UNMUTE"), nil, nil, @"reels_tap_control", @"mute", YES)
                     ]]
    ]];
}

UIMenu *SPKMainFeedModeMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_FOR_YOU"), @"heart", nil, @"feed_mode", @"default", YES),
        SPKMenuCommand(SPKL(@"MENU_FOLLOWING"), @"users", nil, @"feed_mode", @"following", YES)
    ]];
}

UIMenu *SPKSeenButtonPositionMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_TOP"), @"arrow_up", nil, @"msgs_seen_button_position", @"top", NO),
        SPKMenuCommand(SPKL(@"MENU_BOTTOM"), @"arrow_down", nil, @"msgs_seen_button_position", @"bottom", NO)
    ]];
}

UIMenu *SPKHiddenChatsRevealResetMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_LEAVING_THE_INBOX"), nil, nil, @"msgs_hidden_chats_reveal_reset", @"leave_inbox", NO),
        SPKMenuCommand(SPKL(@"MENU_APP_BACKGROUNDED"), nil, nil, @"msgs_hidden_chats_reveal_reset", @"background", NO),
        SPKMenuCommand(SPKL(@"MENU_MANUALLY"), nil, nil, @"msgs_hidden_chats_reveal_reset", @"never", NO)
    ]];
}

UIMenu *SPKLastActiveFormatMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_OFF"), nil, nil, @"msgs_last_active_format", @"off", NO),
        SPKMenuCommand(SPKL(@"MENU_SMART"), nil, nil, @"msgs_last_active_format", @"smart", NO),
        SPKMenuCommand(SPKL(@"MENU_DATE_TIME"), nil, nil, @"msgs_last_active_format", @"datetime", NO)
    ]];
}

UIMenu *SPKLiquidGlassTabBarStateMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_DEFAULT"), nil, nil, kSPKPrefInterfaceLiquidGlassTabBarMode, @"default", YES),
        [UIMenu menuWithTitle:@""
                        image:nil
                   identifier:nil
                      options:UIMenuOptionsDisplayInline
                     children:@[
                         SPKMenuCommand(SPKL(@"MENU_FIXED"), nil, nil, kSPKPrefInterfaceLiquidGlassTabBarMode, @"fixed", YES),
                         SPKMenuCommand(SPKL(@"MENU_HIDE_SCROLL"), nil, nil, kSPKPrefInterfaceLiquidGlassTabBarMode, @"hide", YES)
                     ]]
    ]];
}

UIMenu *SPKSwipeCloseCommentsDirectionMenu(void) {
    static NSString *const kSPKSwipeCloseCommentsDirectionKey = @"general_comments_swipe_close_direction";
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_BOTH"), @"left_right", nil, kSPKSwipeCloseCommentsDirectionKey, @"both", NO),
        SPKMenuCommand(SPKL(@"MENU_LEFT"), @"arrow_left", nil, kSPKSwipeCloseCommentsDirectionKey, @"left", NO),
        SPKMenuCommand(SPKL(@"MENU_RIGHT"), @"arrow_right", nil, kSPKSwipeCloseCommentsDirectionKey, @"right", NO)
    ]];
}

UIMenu *SPKCacheAutoClearMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_NEVER"), nil, nil, @"general_cache_auto_clear", @"never", NO),
        SPKMenuCommand(SPKL(@"MENU_ALWAYS"), nil, nil, @"general_cache_auto_clear", @"always", NO),
        SPKMenuCommand(SPKL(@"MENU_DAILY"), nil, nil, @"general_cache_auto_clear", @"daily", NO),
        SPKMenuCommand(SPKL(@"MENU_WEEKLY"), nil, nil, @"general_cache_auto_clear", @"weekly", NO),
        SPKMenuCommand(SPKL(@"MENU_MONTHLY"), nil, nil, @"general_cache_auto_clear", @"monthly", NO)
    ]];
}

UIMenu *SPKNotificationProgressSubtitleStyleMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_BOTH"), nil, nil, kSPKNotificationProgressSubtitleStyleKey, @"both", NO),
        SPKMenuCommand(SPKL(@"MENU_PERCENT"), nil, nil, kSPKNotificationProgressSubtitleStyleKey, @"percent", NO),
        SPKMenuCommand(SPKL(@"MENU_BYTES"), nil, nil, kSPKNotificationProgressSubtitleStyleKey, @"bytes", NO),
        SPKMenuCommand(SPKL(@"MENU_OFF"), nil, nil, kSPKNotificationProgressSubtitleStyleKey, @"off", NO)
    ]];
}

UIMenu *SPKNotificationPillPositionMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_TOP"), nil, nil, kSPKNotificationPillPositionKey, @"top", NO),
        SPKMenuCommand(SPKL(@"MENU_BOTTOM"), nil, nil, kSPKNotificationPillPositionKey, @"bottom", NO)
    ]];
}

UIMenu *SPKMediaVideoQualityMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_DEFAULT"), nil, nil, @"downloads_video_quality", @"high_ignore_dash", NO),
        [UIMenu menuWithTitle:@""
                        image:nil
                   identifier:nil
                      options:UIMenuOptionsDisplayInline
                     children:@[
                         SPKMenuCommand(SPKL(@"MENU_ALWAYS_ASK"), nil, nil, @"downloads_video_quality", @"always_ask", NO),
                         SPKMenuCommand(SPKL(@"MENU_HIGH"), nil, nil, @"downloads_video_quality", @"high", NO),
                         SPKMenuCommand(SPKL(@"MENU_MEDIUM"), nil, nil, @"downloads_video_quality", @"medium", NO),
                         SPKMenuCommand(SPKL(@"MENU_LOW"), nil, nil, @"downloads_video_quality", @"low", NO)
                     ]]
    ]];
}

UIMenu *SPKMediaPhotoQualityMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_ALWAYS_ASK"), nil, nil, @"downloads_photo_quality", @"always_ask", NO),
        SPKMenuCommand(SPKL(@"MENU_MAX"), nil, nil, @"downloads_photo_quality", @"max", NO),
        SPKMenuCommand(SPKL(@"MENU_HIGH"), nil, nil, @"downloads_photo_quality", @"high", NO),
        SPKMenuCommand(SPKL(@"MENU_MEDIUM"), nil, nil, @"downloads_photo_quality", @"medium", NO),
        SPKMenuCommand(SPKL(@"MENU_LOW"), nil, nil, @"downloads_photo_quality", @"low", NO)
    ]];
}

// Auto-save mirrors the download quality menus minus "Always Ask": there's no user
// present to answer a picker mid-story. "Default" (ignore DASH) is the auto-save
// default -- it takes the ready-to-play file instead of running an FFmpeg merge for
// every story you happen to watch.
UIMenu *SPKAutoSaveDestinationMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_SPARKLE_GALLERY"), nil, nil, kSPKAutoSaveDestinationKey, @"gallery", NO),
        SPKMenuCommand(SPKL(@"MENU_PHOTOS_APP"), nil, nil, kSPKAutoSaveDestinationKey, @"photos", NO)
    ]];
}

UIMenu *SPKAutoSaveVideoQualityMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_DEFAULT"), nil, nil, kSPKAutoSaveVideoQualityKey, @"high_ignore_dash", NO),
        [UIMenu menuWithTitle:@""
                        image:nil
                   identifier:nil
                      options:UIMenuOptionsDisplayInline
                     children:@[
                         SPKMenuCommand(SPKL(@"MENU_HIGH"), nil, nil, kSPKAutoSaveVideoQualityKey, @"high", NO),
                         SPKMenuCommand(SPKL(@"MENU_MEDIUM"), nil, nil, kSPKAutoSaveVideoQualityKey, @"medium", NO),
                         SPKMenuCommand(SPKL(@"MENU_LOW"), nil, nil, kSPKAutoSaveVideoQualityKey, @"low", NO)
                     ]]
    ]];
}

UIMenu *SPKAutoSavePhotoQualityMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand(SPKL(@"MENU_HIGH"), nil, nil, kSPKAutoSavePhotoQualityKey, @"high", NO),
        SPKMenuCommand(SPKL(@"MENU_LOW"), nil, nil, kSPKAutoSavePhotoQualityKey, @"low", NO)
    ]];
}

// Every auto-save surface offers the same All/Selected choice over its own pref; only
// the subject noun differs ("Users" for stories/instants, "Chats" for DMs).
UIMenu *SPKAutoSaveFilterModeMenu(NSString *filterModeKey, NSString *subjectPlural) {
    return [UIMenu menuWithChildren:@[
        SPKMenuCommand([NSString stringWithFormat:@"All %@", subjectPlural], nil, nil, filterModeKey, @"all", NO),
        SPKMenuCommand([NSString stringWithFormat:SPKL(@"SETTINGS_TOPIC_SETTINGS_SUPPORT_SELECTED_VALUE_FORMAT"), subjectPlural], nil, nil, filterModeKey, @"selected", NO)
    ]];
}

UIMenu *SPKStoryAutoSaveFilterModeMenu(void) {
    return SPKAutoSaveFilterModeMenu(@"stories_auto_save_filter_mode", SPKL(@"SETTINGS_TOPIC_SETTINGS_SUPPORT_USERS_TEXT"));
}

SPKSetting *SPKFeedHeaderButtonDefaultActionNavigationSetting(void) {
    // A navigation row (like the media action button's Default Tap Action) rather
    // than a menu-button cell: the selected value renders as a full-width subtitle
    // beneath the title instead of squeezing / truncating the title on one line.
    SPKSetting *setting = [SPKSetting navigationCellWithTitle:SPKL(@"SPKTOPICSETTINGSSUPPORT_GENERAL_DEFAULT_TAP_ACTION_TITLE")
                                                     subtitle:@""
                                                         icon:SPKSettingsIcon(@"action")
                                               viewController:[SPKHeaderButtonDefaultActionPickerViewController new]];
    setting.accessoryTextProvider = ^NSString * {
        return SPKHeaderButtonDefaultActionTitle();
    };
    setting.iconProvider = ^UIImage * {
        return SPKSettingsIcon(SPKHeaderButtonDefaultActionIconName());
    };
    return setting;
}

UIMenu *SPKGalleryShortcutTargetMenu(void) {
    NSString *const kGalleryLongPressTabKey = @"gallery_quick_access_tab";
    NSString *const kGalleryQuickAccessDisabledValue = @"none";

    NSMutableArray<UIMenuElement *> *commands = [NSMutableArray array];

    NSArray<NSDictionary *> *items = @[
        @{@"title" : SPKL(@"SETTINGS_TOPIC_SETTINGS_SUPPORT_NONE_TEXT"), @"value" : kGalleryQuickAccessDisabledValue, @"icon" : @"circle_off"},
        @{@"title" : SPKL(@"SETTINGS_TOPIC_SETTINGS_SUPPORT_HOME_TEXT"), @"value" : @"mainfeed-tab", @"icon" : @"home"},
        @{@"title" : SPKL(@"REELS_TITLE"), @"value" : @"reels-tab", @"icon" : @"reels"}
    ];

    NSMutableArray *allItems = [items mutableCopy];
    if ([SPKUtils tabOrderSetTo:@"classic"]) {
        [allItems addObject:@{@"title" : SPKL(@"TAB_CREATE"), @"value" : @"camera-tab", @"icon" : @"plus"}];
    } else {
        [allItems addObject:@{@"title" : SPKL(@"MESSAGES_CONFIRMATION_MESSAGES_TITLE"), @"value" : @"direct-inbox-tab", @"icon" : @"messages"}];
    }
    [allItems addObject:@{@"title" : SPKL(@"PROFILE_TITLE"), @"value" : @"profile-tab", @"icon" : @"user_circle"}];

    for (NSDictionary *item in allItems) {
        NSString *title = item[@"title"];
        NSString *value = item[@"value"];
        NSString *iconName = item[@"icon"];

        [commands addObject:SPKMenuCommand(title, iconName, nil, kGalleryLongPressTabKey, value, YES)];
    }

    return [UIMenu menuWithChildren:commands];
}
