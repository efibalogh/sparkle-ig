#import "SPKStrings.h"
#import "SPKFeedSettingsProvider.h"

#import "../../Features/Feed/HeaderActionButton.h"
#import "../../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../SPKTopicSettingsSupport.h"

static NSString *const kSPKFeedActionButtonEnabledKey = @"feed_action_btn";

@implementation SPKFeedSettingsProvider

+ (SPKSetting *)rootSetting {
    return SPKTopicNavigationSetting(SPKL(@"FEED_TITLE"), @"feed", 24.0, @[
        SPKTopicSection(SPKL(@"FEED_ACTION_BUTTON_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_ACTION_BUTTON_FEED_ACTION_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(@"action")
                                    defaultsKey:kSPKFeedActionButtonEnabledKey],
                               SPKL(@"FEED_ACTION_BUTTON_ENABLED_HELP")),
            SPKActionButtonDefaultActionNavigationSetting(SPKActionButtonSourceFeed),
            SPKActionButtonConfigurationNavigationSetting(SPKActionButtonSourceFeed, @"Feed", SPKActionButtonSupportedActionsForSource(SPKActionButtonSourceFeed), SPKActionButtonDefaultSectionsForSource(SPKActionButtonSourceFeed))
        ],
                        nil),
        SPKTopicSection(SPKL(@"FEED_HEADER_SHORTCUT_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_HEADER_SHORTCUT_FEED_HEADER_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(@"action")
                                    defaultsKey:kSPKHeaderButtonEnabledKey],
                               SPKL(@"FEED_HEADER_SHORTCUT_ENABLED_HELP")),
            SPKFeedHeaderButtonDefaultActionNavigationSetting(),
            SPKSettingWithHelp([SPKSetting navigationCellWithTitle:SPKL(@"FEED_HEADER_SHORTCUT_CONFIGURE_DESTINATIONS_TITLE")
                                           subtitle:@""
                                               icon:SPKSettingsIcon(@"sliders")
                                        navSections:@[
                                            SPKTopicSection(SPKL(@"FEED_DESTINATIONS_HEADER"), @[
                                                [SPKSetting switchCellWithTitle:SPKL(@"DATA_GENERAL_GALLERY_TITLE")
                                                                               icon:SPKSettingsIcon(@"sparkle_gallery")
                                                                        defaultsKey:@"feed_header_button_dest_gallery"],
                                                [SPKSetting switchCellWithTitle:SPKL(@"DATA_GENERAL_PROFILE_ANALYZER_TITLE")
                                                                               icon:SPKSettingsIcon(@"profile_analyzer")
                                                                        defaultsKey:@"feed_header_button_dest_analyzer"],
                                                [SPKSetting switchCellWithTitle:SPKL(@"ALERT_ACTION_DELETED_MESSAGES")
                                                                               icon:SPKSettingsIcon(@"channels")
                                                                        defaultsKey:@"feed_header_button_dest_deleted"],
                                                [SPKSetting switchCellWithTitle:SPKL(@"DOWNLOADS_GENERAL_DOWNLOADS_TITLE")
                                                                               icon:SPKSettingsIcon(@"download")
                                                                        defaultsKey:@"feed_header_button_dest_downloads"],
                                                [SPKSetting switchCellWithTitle:SPKL(@"FEED_DESTINATIONS_SPARKLE_SETTINGS_TITLE")
                                                                               icon:SPKSettingsIcon(@"settings")
                                                                        defaultsKey:@"feed_header_button_dest_settings"],
                                            ],
                                                            nil)
                                        ]],
                               SPKL(@"FEED_HEADER_SHORTCUT_CONFIGURE_DESTINATIONS_HELP")),
        ],
                        nil),
        SPKTopicSection(SPKL(@"FEED_LAYOUT_HEADER"), @[
            SPKSettingWithHelp(SPKSettingApplySelectedMenuIcon([SPKSetting menuCellWithTitle:SPKL(@"FEED_LAYOUT_MAIN_FEED_TITLE") icon:SPKSettingsIcon(@"feed") menu:SPKMainFeedModeMenu()], SPKSettingsIcon(@"feed")),
                               SPKL(@"FEED_LAYOUT_MAIN_FEED_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_LAYOUT_DISABLE_APP_ICON_GESTURE_TITLE")
                                           icon:SPKSettingsIcon(@"app")
                                    defaultsKey:@"feed_disable_appicon_gesture"],
                               SPKL(@"FEED_LAYOUT_DISABLE_APP_ICON_GESTURE_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_LAYOUT_HIDE_STORIES_TRAY_TITLE")
                                           icon:SPKSettingsIcon(@"story")
                                    defaultsKey:@"feed_hide_stories_tray"],
                               SPKL(@"FEED_LAYOUT_HIDE_STORIES_TRAY_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_LAYOUT_HIDE_ENTIRE_FEED_TITLE")
                                           icon:SPKSettingsIcon(@"feed")
                                    defaultsKey:@"feed_hide_entire_feed"],
                               SPKL(@"FEED_LAYOUT_HIDE_ENTIRE_FEED_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_LAYOUT_HIDE_SUGGESTED_POSTS_TITLE")
                                           icon:SPKSettingsIcon(@"carousel")
                                    defaultsKey:@"feed_hide_suggested_posts"],
                               SPKL(@"FEED_LAYOUT_HIDE_SUGGESTED_POSTS_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_LAYOUT_HIDE_SUGGESTED_REELS_TITLE")
                                           icon:SPKSettingsIcon(@"reels_gallery")
                                    defaultsKey:@"feed_hide_suggested_reels"],
                               SPKL(@"FEED_LAYOUT_HIDE_SUGGESTED_REELS_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_LAYOUT_HIDE_SUGGESTED_THREADS_TITLE")
                                           icon:SPKSettingsIcon(@"threads")
                                    defaultsKey:@"feed_hide_suggested_threads"],
                               SPKL(@"FEED_LAYOUT_HIDE_SUGGESTED_THREADS_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_LAYOUT_HIDE_META_PROMOTIONS_TITLE")
                                           icon:SPKSettingsIcon(@"ads")
                                    defaultsKey:@"feed_hide_meta_promotions"],
                               SPKL(@"FEED_LAYOUT_HIDE_META_PROMOTIONS_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_LAYOUT_HIDE_REPOST_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(@"repost")
                                    defaultsKey:@"feed_hide_repost_btn"
                                requiresRestart:YES],
                               SPKL(@"FEED_LAYOUT_HIDE_REPOST_BUTTON_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"FEED_METRICS_HEADER"), @[
            [SPKSetting switchCellWithTitle:SPKL(@"FEED_METRICS_HIDE_LIKE_COUNT_TITLE")
                                           icon:SPKSettingsIcon(@"heart")
                                    defaultsKey:@"feed_hide_like_count"],
            [SPKSetting switchCellWithTitle:SPKL(@"FEED_METRICS_HIDE_COMMENT_COUNT_TITLE")
                                           icon:SPKSettingsIcon(@"comment")
                                    defaultsKey:@"feed_hide_comment_count"],
            [SPKSetting switchCellWithTitle:SPKL(@"FEED_METRICS_HIDE_REPOST_COUNT_TITLE")
                                           icon:SPKSettingsIcon(@"repost")
                                    defaultsKey:@"feed_hide_repost_count"],
            [SPKSetting switchCellWithTitle:SPKL(@"FEED_METRICS_HIDE_RESHARE_COUNT_TITLE")
                                           icon:SPKSettingsIcon(@"messages")
                                    defaultsKey:@"feed_hide_reshare_count"]
        ],
                        nil),
        SPKTopicSection(SPKL(@"FEED_MEDIA_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_MEDIA_LONG_PRESS_EXPAND_TITLE")
                                           icon:SPKSettingsIcon(@"expand")
                                    defaultsKey:@"feed_long_press_expand"],
                               SPKL(@"FEED_MEDIA_LONG_PRESS_EXPAND_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_MEDIA_DISABLE_VIDEO_AUTOPLAY_TITLE")
                                           icon:SPKSettingsIcon(@"autoplay_off")
                                    defaultsKey:@"feed_disable_autoplay"
                                requiresRestart:YES],
                               SPKL(@"FEED_MEDIA_DISABLE_VIDEO_AUTOPLAY_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_MEDIA_START_EXPANDED_VIDEOS_MUTED_TITLE")
                                           icon:SPKSettingsIcon(@"volume_off")
                                    defaultsKey:@"feed_expanded_vid_start_muted"],
                               SPKL(@"FEED_MEDIA_START_EXPANDED_VIDEOS_MUTED_HELP")),
        ],
                        nil),
        SPKTopicSection(SPKL(@"FEED_REFRESH_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_REFRESH_DISABLE_HOME_TAB_REFRESH_TITLE")
                                           icon:SPKSettingsIcon(@"home")
                                    defaultsKey:@"feed_disable_home_refresh"],
                               SPKL(@"FEED_REFRESH_DISABLE_HOME_TAB_REFRESH_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_REFRESH_DISABLE_BACKGROUND_REFRESH_TITLE")
                                           icon:SPKSettingsIcon(@"arrow_cw")
                                    defaultsKey:@"feed_disable_bg_refresh"],
                               SPKL(@"FEED_REFRESH_DISABLE_BACKGROUND_REFRESH_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"FEED_CONFIRMATION_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_CONFIRMATION_CONFIRM_LIKE_TITLE")
                                           icon:SPKSettingsIcon(@"heart")
                                    defaultsKey:@"feed_confirm_post_like"],
                               SPKL(@"FEED_CONFIRMATION_CONFIRM_LIKE_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_CONFIRMATION_CONFIRM_DOUBLE_TAP_TITLE")
                                           icon:SPKSettingsIcon(@"heart")
                                    defaultsKey:@"feed_confirm_double_tap_like"],
                               SPKL(@"FEED_CONFIRMATION_CONFIRM_DOUBLE_TAP_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_CONFIRMATION_CONFIRM_REPOST_TITLE")
                                           icon:SPKSettingsIcon(@"repost")
                                    defaultsKey:@"feed_confirm_repost"],
                               SPKL(@"FEED_CONFIRMATION_CONFIRM_REPOST_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_CONFIRMATION_CONFIRM_POSTING_COMMENT_TITLE")
                                           icon:SPKSettingsIcon(@"comment")
                                    defaultsKey:@"feed_confirm_post_comment"],
                               SPKL(@"FEED_CONFIRMATION_CONFIRM_POSTING_COMMENT_HELP"))
        ],
                        nil)
    ]);
}

@end
