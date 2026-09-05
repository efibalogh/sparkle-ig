#import "SPKGeneralSettingsProvider.h"
#import "SPKStrings.h"

#import "../../AssetUtils.h"
#import "../../Shared/Account/SPKAccountManager.h"
#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Shared/MediaPreview/SPKFullScreenImageViewController.h"
#import "../../Shared/UI/SPKIGAlertPresenter.h"
#import "../../Utils.h"
#import "../SPKActionSectionIconPickerViewController.h"
#import "../SPKAppIconCatalog.h"
#import "../SPKAppIconPickerViewController.h"
#import "../SPKPreferenceAvailability.h"
#import "../SPKTopicSettingsSupport.h"

// Media Preview & Menu rows. Built rather than declared inline because the Live Text
// toggle is omitted outright on systems whose VisionKit can't analyze images: it is
// not a setting the user can act on there, so it isn't shown at all.
static NSArray<SPKSetting *> *SPKGeneralMediaPreviewRows(void) {
    NSMutableArray<SPKSetting *> *rows = [NSMutableArray array];
    [rows addObject:SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_MEDIA_PREVIEW_MENU_SHOW_MEDIA_INFO_TITLE")
                                                                  icon:SPKSettingsIcon(@"info")
                                                           defaultsKey:@"general_preview_show_metadata"],
                                       SPKL(@"GENERAL_MEDIA_PREVIEW_MENU_SHOW_MEDIA_INFO_HELP"))];
    if (SPKLiveTextIsSupported()) {
        [rows addObject:SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_MEDIA_PREVIEW_MENU_SELECT_TEXT_TITLE")
                                                                      icon:SPKSettingsIcon(@"text")
                                                               defaultsKey:@"general_preview_live_text"],
                                           SPKL(@"GENERAL_MEDIA_PREVIEW_MENU_SELECT_TEXT_HELP"))];
    }
    [rows addObject:SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_MEDIA_PREVIEW_MENU_SHOW_DATE_MENU_TITLE")
                                                                  icon:SPKSettingsIcon(@"calendar")
                                                           defaultsKey:@"general_action_btn_show_date"],
                                       SPKL(@"GENERAL_MEDIA_PREVIEW_MENU_SHOW_DATE_MENU_HELP"))];
    return rows;
}

static SPKSetting *SPKTappableTextLinksSetting(void) {
    SPKSetting *setting = [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_TEXT_LINKS_TITLE")
                                                     icon:SPKSettingsIcon(@"web")
                                              defaultsKey:@"general_tappable_text_links"];
    setting.requiresRestart = YES;
    return setting;
}

@implementation SPKGeneralSettingsProvider

+ (SPKSetting *)defaultMenuIconSetting {
    SPKActionSectionIconPickerViewController *controller =
        [[SPKActionSectionIconPickerViewController alloc] initWithSelectedIconName:SPKActionButtonOpenMenuIconName()
                                                                          onSelect:^(NSString *iconName) {
                                                                              SPKPreferenceSetObject(iconName.length > 0 ? iconName : @"action", @"general_action_btn_default_menu_icon");
                                                                              [[NSNotificationCenter defaultCenter] postNotificationName:SPKActionButtonConfigurationDidChangeNotification object:nil];
                                                                          }];
    controller.title = SPKL(@"GENERAL_GENERAL_OPEN_MENU_ICON_TITLE");

    SPKSetting *setting = [SPKSetting navigationCellWithTitle:SPKL(@"GENERAL_GENERAL_OPEN_MENU_ICON_TITLE")
                                                     subtitle:@""
                                                         icon:SPKSettingsIcon(@"action")
                                               viewController:controller];
    // The row's icon mirrors the chosen glyph, so the (cryptic) catalog name is
    // redundant as accessory text — let the adaptive icon convey the selection.
    setting.iconProvider = ^UIImage * {
        return SPKSettingsIcon(SPKActionButtonOpenMenuIconName());
    };
    setting.helpText = SPKL(@"GENERAL_APP_OPEN_MENU_ICON_HELP");
    return setting;
}

+ (SPKSetting *)appIconSetting {
    SPKAppIconPickerViewController *controller = [[SPKAppIconPickerViewController alloc] initWithSelectedIdentifier:[SPKAppIconCatalog currentAppIconIdentifier]
                                                                                                           onSelect:nil];
    SPKSetting *setting = [SPKSetting navigationCellWithTitle:SPKL(@"GENERAL_GENERAL_APP_ICON_TITLE")
                                                     subtitle:@""
                                                         icon:SPKSettingsIcon(@"app")
                                               viewController:controller];
    setting.accessoryTextProvider = ^NSString * {
        SPKAppIconItem *currentIcon = [SPKAppIconCatalog currentAppIcon];
        return currentIcon.displayName.length > 0 ? currentIcon.displayName : SPKL(@"MENU_DEFAULT");
    };
    setting.helpText = SPKL(@"GENERAL_APP_APP_ICON_HELP");
    return setting;
}

+ (SPKSetting *)perAccountSetting {
    SPKSetting *setting = [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_GENERAL_PER_ACCOUNT_SETTINGS_TITLE")
                                                     icon:SPKSettingsIcon(@"user_circle")
                                              defaultsKey:kSPKPrefPerAccountSettings];
    setting.helpText = SPKL(@"GENERAL_ACCOUNTS_PER_ACCOUNT_SETTINGS_HELP");
    // Changes which key namespace every feature reads, and most enabled-state is
    // captured at hook install, so a restart applies it cleanly.
    setting.requiresRestart = YES;
    return setting;
}

+ (SPKSetting *)perAccountInfoSetting {
    return SPKSettingWithHelp([SPKSetting buttonCellWithTitle:SPKL(@"ALERT_ACTION_HOW_WORKS")
                                                     subtitle:nil
                                                         icon:SPKSettingsIcon(@"info")
                                                       action:^{
                                                           NSString *message =
                                                               SPKL(@"SETTINGS_GENERAL_EACH_LOGGED_ACCOUNT_GETS_OWN_SPARKLE_SETTINGS_NEWLY_SEEN_TEXT");

                                                           [SPKIGAlertPresenter presentAlertFromViewController:topMostController()
                                                                                                         title:SPKL(@"GENERAL_GENERAL_PER_ACCOUNT_SETTINGS_TITLE")
                                                                                                       message:message
                                                                                                       actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK") style:SPKIGAlertActionStyleCancel handler:nil] ]];
                                                       }],
                              SPKL(@"GENERAL_ACCOUNTS_HOW_IT_WORKS_HELP"));
}

+ (SPKSetting *)rootSetting {
    SPKSetting *clearCacheSetting = [SPKSetting buttonCellWithTitle:SPKL(@"GENERAL_GENERAL_CLEAR_CACHE_TITLE")
                                                           subtitle:@""
                                                               icon:SPKSettingsIcon(@"trash")
                                                             action:^(void) {
                                                                 unsigned long long freedBytes = [SPKUtils cleanCacheReturningFreedBytes];
                                                                 NSString *subtitle = freedBytes > 0
                                                                                          ? [NSString stringWithFormat:@"Freed %@", [NSByteCountFormatter stringFromByteCount:(long long)freedBytes countStyle:NSByteCountFormatterCountStyleFile]]
                                                                                          : SPKL(@"SETTINGS_GENERAL_CACHE_ALREADY_EMPTY_TEXT");
                                                                 SPKNotify(kSPKNotificationSettingsClearCache, SPKL(@"SETTINGS_GENERAL_CACHE_CLEARED_TEXT"), subtitle, @"circle_check_filled", SPKNotificationToneForIconResource(@"circle_check_filled"));
                                                             }];
    clearCacheSetting.tintColor = [SPKUtils SPKColor_InstagramDestructive];
    clearCacheSetting.iconTintColor = [SPKUtils SPKColor_InstagramDestructive];
    clearCacheSetting.accessoryTextProvider = ^NSString * {
        return [SPKUtils formattedCacheSize];
    };
    clearCacheSetting.helpText = SPKL(@"GENERAL_STORAGE_CLEAR_CACHE_HELP");

    return SPKTopicNavigationSetting(SPKL(@"GENERAL_TITLE"), @"settings", 24.0, @[
        SPKTopicSection(SPKL(@"GENERAL_ACCOUNTS_HEADER"), @[
            [self perAccountSetting],
            [self perAccountInfoSetting]
        ],
                        nil),
        SPKTopicSection(SPKL(@"GENERAL_BEHAVIOR_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"ALERT_ACTION_COPY_TEXT")
                                                          icon:SPKSettingsIcon(@"text")
                                                   defaultsKey:@"general_copy_text"],
                               SPKL(@"GENERAL_BEHAVIOR_COPY_TEXT_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_BEHAVIOR_HIDE_RECENT_SEARCHES_TITLE")
                                                          icon:SPKSettingsIcon(@"search")
                                                   defaultsKey:@"general_hide_recent_searches"
                                               requiresRestart:YES],
                               SPKL(@"GENERAL_BEHAVIOR_HIDE_RECENT_SEARCHES_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_BEHAVIOR_COPY_LINKS_WITHOUT_TRACKING_TITLE")
                                                          icon:SPKSettingsIcon(@"user_unfollow")
                                                   defaultsKey:@"general_strip_share_link_tracking"],
                               SPKL(@"GENERAL_BEHAVIOR_COPY_LINKS_WITHOUT_TRACKING_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_BEHAVIOR_HOLD_SEND_COPY_LINK_TITLE")
                                                          icon:SPKSettingsIcon(@"link")
                                                   defaultsKey:@"general_hold_send_copy_link"],
                               SPKL(@"GENERAL_BEHAVIOR_HOLD_SEND_COPY_LINK_HELP")),
            SPKSettingWithHelp(SPKTappableTextLinksSetting(), SPKL(@"GENERAL_TEXT_LINKS_HELP")),
            SPKSettingWithHelp(SPKSettingApplySelectedMenuIcon([SPKSetting menuCellWithTitle:SPKL(@"GENERAL_TEXT_LINKS_OPENING_MODE_TITLE")
                                                                                        icon:SPKSettingsIcon(@"link")
                                                                                        menu:SPKTextLinkOpeningModeMenu()],
                                                               SPKSettingsIcon(@"external_link")),
                               SPKL(@"GENERAL_TEXT_LINKS_OPENING_MODE_HELP")),
        ],
                        nil),
        SPKTopicSection(SPKL(@"GENERAL_SHARING_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_SHARING_HIDE_CREATE_GROUP_BUTTON_TITLE")
                                                          icon:SPKSettingsIcon(@"group")
                                                   defaultsKey:@"general_hide_create_group"],
                               SPKL(@"GENERAL_SHARING_HIDE_CREATE_GROUP_BUTTON_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_SHARING_CONFIRM_CREATE_GROUP_TITLE")
                                                          icon:SPKSettingsIcon(@"group")
                                                   defaultsKey:@"general_confirm_create_group"],
                               SPKL(@"GENERAL_SHARING_CONFIRM_CREATE_GROUP_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_SHARING_CONFIRM_SENDING_POST_TITLE")
                                                          icon:SPKSettingsIcon(@"messages")
                                                   defaultsKey:@"general_confirm_send"],
                               SPKL(@"GENERAL_SHARING_CONFIRM_SENDING_POST_HELP")),
        ],
                        nil),
        SPKTopicSection(SPKL(@"GENERAL_RECOMMENDATIONS_HEADER"), @[
            SPKSettingWithHelp([SPKSetting navigationCellWithTitle:SPKL(@"GENERAL_ADS_HEADER")
                                                          subtitle:@""
                                                              icon:SPKSettingsIcon(@"ads")
                                                       navSections:@[
                                                           SPKTopicSection(SPKL(@"GENERAL_ADS_HEADER"), @[
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_ADS_HIDE_FEED_ADS_TITLE")
                                                                                   defaultsKey:@"general_hide_ads_feed"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_ADS_HIDE_STORY_ADS_TITLE")
                                                                                   defaultsKey:@"general_hide_ads_stories"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_ADS_HIDE_REELS_ADS_TITLE")
                                                                                   defaultsKey:@"general_hide_ads_reels"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_ADS_HIDE_EXPLORE_ADS_TITLE")
                                                                                   defaultsKey:@"general_hide_ads_explore"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_ADS_HIDE_REELS_SHOPPING_CTA_TITLE")
                                                                                   defaultsKey:@"general_hide_reels_shopping_cta"]
                                                           ],
                                                                           nil)
                                                       ]],
                               SPKL(@"GENERAL_RECOMMENDATIONS_ADS_HELP")),
            SPKSettingWithHelp([SPKSetting navigationCellWithTitle:SPKL(@"GENERAL_ADS_META_AI_TITLE")
                                                          subtitle:@""
                                                              icon:SPKSettingsIcon(@"meta_ai")
                                                       navSections:@[
                                                           SPKTopicSection(@"", @[
                                                               SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_ADS_HIDE_DIRECT_TITLE")
                                                                                                      defaultsKey:@"general_hide_meta_ai_msgs"],
                                                                                  SPKL(@"GENERAL_ADS_HIDE_DIRECT_HELP")),
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_ADS_HIDE_EXPLORE_SEARCH_TITLE")
                                                                                   defaultsKey:@"general_hide_meta_ai_explore"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_ADS_HIDE_COMMENTS_TITLE")
                                                                                   defaultsKey:@"general_hide_meta_ai_comments"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_ADS_HIDE_CREATION_TOOLS_TITLE")
                                                                                   defaultsKey:@"general_hide_meta_ai_creation"],
                                                               SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_ADS_HIDE_GLOBAL_AI_CHROME_TITLE")
                                                                                                      defaultsKey:@"general_hide_meta_ai_global"],
                                                                                  SPKL(@"GENERAL_ADS_HIDE_GLOBAL_AI_CHROME_HELP"))
                                                           ],
                                                                           nil)
                                                       ]],
                               SPKL(@"GENERAL_RECOMMENDATIONS_META_AI_HELP")),
            SPKSettingWithHelp([SPKSetting navigationCellWithTitle:SPKL(@"GENERAL_ADS_SUGGESTED_USERS_TITLE")
                                                          subtitle:@""
                                                              icon:SPKSettingsIcon(@"users")
                                                       navSections:@[
                                                           SPKTopicSection(SPKL(@"GENERAL_ADS_SUGGESTED_USERS_TITLE"), @[
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_SUGGESTED_USERS_HIDE_FEED_SUGGESTIONS_TITLE")
                                                                                   defaultsKey:@"general_hide_suggested_users_feed"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_SUGGESTED_USERS_HIDE_REELS_SUGGESTIONS_TITLE")
                                                                                   defaultsKey:@"general_hide_suggested_users_reels"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_SUGGESTED_USERS_HIDE_DIRECT_SUGGESTIONS_TITLE")
                                                                                   defaultsKey:@"general_hide_suggested_users_msgs"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_SUGGESTED_USERS_HIDE_SEARCH_SUGGESTIONS_TITLE")
                                                                                   defaultsKey:@"general_hide_suggested_users_search"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_SUGGESTED_USERS_HIDE_PROFILE_SUGGESTIONS_TITLE")
                                                                                   defaultsKey:@"general_hide_suggested_users_profile"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_SUGGESTED_USERS_HIDE_ACTIVITY_SUGGESTIONS_TITLE")
                                                                                   defaultsKey:@"general_hide_suggested_users_activity"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_SUGGESTED_USERS_HIDE_FOLLOW_LIST_SUGGESTIONS_TITLE")
                                                                                   defaultsKey:@"general_hide_suggested_users_follow_lists"],
                                                               [SPKSetting switchCellWithTitle:SPKL(@"GENERAL_SUGGESTED_USERS_HIDE_SUBSCRIPTION_SUGGESTIONS_TITLE")
                                                                                   defaultsKey:@"general_hide_suggested_users_subscriptions"]
                                                           ],
                                                                           nil)
                                                       ]],
                               SPKL(@"GENERAL_RECOMMENDATIONS_SUGGESTED_USERS_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"GENERAL_MEDIA_PREVIEW_MENU_HEADER"), SPKGeneralMediaPreviewRows(), nil),
        SPKTopicSection(SPKL(@"GENERAL_COMMENTS_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_COMMENTS_COPY_COMMENT_TITLE")
                                                          icon:SPKSettingsIcon(@"copy")
                                                   defaultsKey:@"general_comments_copy_text"],
                               SPKL(@"GENERAL_COMMENTS_COPY_COMMENT_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_COMMENTS_COMMENT_MEDIA_ACTIONS_TITLE")
                                                          icon:SPKSettingsIcon(@"action")
                                                   defaultsKey:@"general_comments_media_actions"],
                               SPKL(@"GENERAL_COMMENTS_COMMENT_MEDIA_ACTIONS_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_COMMENTS_SHOW_GIF_TITLE_TITLE")
                                                          icon:SPKSettingsIcon(@"gif")
                                                   defaultsKey:@"general_comments_gif_title"],
                               SPKL(@"GENERAL_COMMENTS_SHOW_GIF_TITLE_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_COMMENTS_UPLOAD_PHOTO_GALLERY_TITLE")
                                                          icon:SPKSettingsIcon(@"photo")
                                                   defaultsKey:@"general_comments_gallery_upload"],
                               SPKL(@"GENERAL_COMMENTS_UPLOAD_PHOTO_GALLERY_HELP"))
        ],
                        nil),
        SPKTopicSection(@"", @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_COMMENTS_SWIPE_CLOSE_COMMENTS_TITLE")
                                                          icon:SPKSettingsIcon(@"left_right")
                                                   defaultsKey:@"general_comments_swipe_close"],
                               SPKL(@"GENERAL_COMMENTS_SWIPE_CLOSE_COMMENTS_HELP")),
            SPKSettingWithHelp(SPKSettingApplySelectedMenuIcon([SPKSetting menuCellWithTitle:SPKL(@"GENERAL_COMMENTS_SWIPE_DIRECTION_TITLE") icon:SPKSettingsIcon(@"left_right") menu:SPKSwipeCloseCommentsDirectionMenu()], SPKSettingsIcon(@"left_right")),
                               SPKL(@"GENERAL_COMMENTS_SWIPE_DIRECTION_HELP")),
        ],
                        nil),
        SPKTopicSection(@"", @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_COMMENTS_CONFIRM_COMMENT_LIKE_TITLE")
                                                          icon:SPKSettingsIcon(@"heart")
                                                   defaultsKey:@"general_comments_confirm_like"],
                               SPKL(@"GENERAL_COMMENTS_CONFIRM_COMMENT_LIKE_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_COMMENTS_HIDE_COMMENT_SHOPPING_TITLE")
                                                          icon:SPKSettingsIcon(@"shopping_bag")
                                                   defaultsKey:@"general_comments_hide_shopping"],
                               SPKL(@"GENERAL_COMMENTS_HIDE_COMMENT_SHOPPING_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_COMMENTS_HIDE_GIFTS_BUTTON_TITLE")
                                                          icon:SPKSettingsIcon(@"gift")
                                                   defaultsKey:@"general_comments_hide_gifts_button"],
                               SPKL(@"GENERAL_COMMENTS_HIDE_GIFTS_BUTTON_HELP")),
        ],
                        nil),
        SPKTopicSection(SPKL(@"ALERT_ACTION_STORAGE"), @[
            clearCacheSetting,
            SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"GENERAL_STORAGE_AUTO_CLEAR_CACHE_TITLE")
                                                        icon:SPKSettingsIcon(@"clock")
                                                        menu:SPKCacheAutoClearMenu()],
                               SPKL(@"GENERAL_STORAGE_AUTO_CLEAR_CACHE_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"GENERAL_APP_HEADER"), @[
            [self appIconSetting],
            [self defaultMenuIconSetting],
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_APP_DISABLE_APP_HAPTICS_TITLE")
                                                          icon:SPKSettingsIcon(@"haptics")
                                                   defaultsKey:@"general_disable_haptics"],
                               SPKL(@"GENERAL_APP_DISABLE_APP_HAPTICS_HELP"))
        ],
                        nil),
    ]);
}

@end
