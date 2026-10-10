#import "SPKReelsSettingsProvider.h"
#import "SPKStrings.h"

#import "../../Features/Reels/HideReelsHeader.h"
#import "../../Features/Reels/ReelsAutoScrollDefault.h"
#import "../../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../../Utils.h"
#import "../SPKTopicSettingsSupport.h"

static NSString *const kSPKReelsActionButtonEnabledKey = @"reels_action_btn";

@implementation SPKReelsSettingsProvider

+ (SPKSetting *)rootSetting {
    return SPKTopicNavigationSetting(SPKL(@"REELS_TITLE"), @"reels", 24.0, @[
        SPKTopicSection(SPKL(@"FEED_ACTION_BUTTON_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"REELS_ACTION_BUTTON_REELS_ACTION_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(@"action")
                                    defaultsKey:kSPKReelsActionButtonEnabledKey],
                               SPKL(@"REELS_ACTION_BUTTON_ENABLED_HELP")),
            SPKActionButtonDefaultActionNavigationSetting(SPKActionButtonSourceReels),
            SPKActionButtonConfigurationNavigationSetting(SPKActionButtonSourceReels, @"Reels", SPKActionButtonSupportedActionsForSource(SPKActionButtonSourceReels), SPKActionButtonDefaultSectionsForSource(SPKActionButtonSourceReels))
        ],
                        nil),
        SPKTopicSection(SPKL(@"GENERAL_BEHAVIOR_HEADER"), @[
            SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"REELS_BEHAVIOR_TAP_CONTROLS_TITLE")
                                         icon:SPKSettingsIcon(@"play")
                                         menu:SPKReelsTapControlMenu()],
                               SPKL(@"REELS_BEHAVIOR_TAP_CONTROLS_HELP")),
            ({
                SPKSetting *playbackControls = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"REELS_BEHAVIOR_PLAYBACK_CONTROLS_TITLE")
                                                                                             icon:SPKSettingsPlaybackIcon()
                                                                                      defaultsKey:@"reels_playback_controls"],
                                                                 SPKL(@"REELS_BEHAVIOR_PLAYBACK_CONTROLS_HELP"));
                // Gates the Keep Speed For row below.
                playbackControls.reloadsTableOnSwitchChange = YES;
                playbackControls;
            }),
            ({
                SPKSetting *speedScope = [SPKSetting menuCellWithTitle:SPKL(@"PLAYBACK_PANEL_KEEP_SPEED_TITLE")
                                                                  icon:SPKSettingsIcon(@"clock")
                                                                  menu:SPKPlaybackSpeedScopeMenu(@"reels_playback_speed_scope")];
                speedScope.defaultsKey = @"reels_playback_speed_scope";
                speedScope.helpText = SPKL(@"PLAYBACK_PANEL_KEEP_SPEED_HELP");
                speedScope.enabledProvider = ^BOOL {
                    return [SPKUtils getBoolPref:@"reels_playback_controls"];
                };
                speedScope;
            }),
            ({
                SPKSetting *autoScroll = SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"REELS_BEHAVIOR_AUTO_SCROLL_DEFAULT_TITLE")
                                                                                     icon:SPKSettingsIcon(@"autoscroll")
                                                                                     menu:SPKReelsAutoScrollDefaultMenu()],
                                                           SPKL(@"REELS_BEHAVIOR_AUTO_SCROLL_DEFAULT_HELP"));
                // Disable Scrolling Reels forces it off.
                autoScroll.enabledProvider = ^BOOL {
                    return ![SPKUtils getBoolPref:@"reels_disable_scrolling"];
                };
                autoScroll;
            }),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"REELS_BEHAVIOR_START_MUTED_TITLE")
                                           icon:SPKSettingsIcon(@"volume_off")
                                    defaultsKey:@"reels_disable_auto_unmute"
                                requiresRestart:YES],
                               SPKL(@"REELS_BEHAVIOR_START_MUTED_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"REELS_BEHAVIOR_DISABLE_REELS_TAB_REFRESH_TITLE")
                                           icon:SPKSettingsIcon(@"arrow_cw")
                                    defaultsKey:@"reels_disable_tab_refresh"],
                               SPKL(@"REELS_BEHAVIOR_DISABLE_TAB_REFRESH_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"REELS_LIMITS_HEADER"), @[
            ({
                SPKSetting *stopLooping = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"REELS_LIMITS_STOP_LOOPING_TITLE")
                                                                                        icon:SPKSettingsIcon(@"loop")
                                                                                 defaultsKey:@"reels_stop_looping"],
                                                            SPKL(@"REELS_LIMITS_STOP_LOOPING_HELP"));
                // Auto Scroll in force overrides it.
                stopLooping.enabledProvider = ^BOOL {
                    return ![SPKReelsAutoScrollEffectiveMode() isEqualToString:@"on"];
                };
                stopLooping;
            }),
            ({
                SPKSetting *disableScrolling = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"REELS_LIMITS_DISABLE_SCROLLING_REELS_TITLE")
                                                                                             icon:SPKSettingsIcon(@"autoscroll_off")
                                                                                      defaultsKey:@"reels_disable_scrolling"
                                                                                  requiresRestart:YES],
                                                                 SPKL(@"REELS_LIMITS_DISABLE_SCROLLING_HELP"));
                // Gates the Auto Scroll and Stop Looping rows.
                disableScrolling.reloadsTableOnSwitchChange = YES;
                disableScrolling;
            }),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"REELS_LIMITS_PREVENT_DOOM_SCROLLING_TITLE")
                                           icon:SPKSettingsIcon(@"arrow_down")
                                    defaultsKey:@"reels_prevent_doom_scroll"],
                               SPKL(@"REELS_LIMITS_PREVENT_DOOM_SCROLLING_HELP")),
            SPKSettingWithHelp([SPKSetting stepperCellWithTitle:SPKL(@"REELS_LIMITS_DOOM_SCROLLING_LIMIT_TITLE")
                                        subtitle:SPKL(@"REELS_LIMITS_ONLY_LOADS_SUBTITLE")
                                     defaultsKey:@"reels_doom_scroll_limit"
                                             min:1
                                             max:100
                                            step:1
                                           label:@"reels"
                                   singularLabel:@"reel"],
                               SPKL(@"REELS_LIMITS_DOOM_SCROLLING_LIMIT_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"FEED_LAYOUT_HEADER"), @[
            ({
                // The reels viewer keeps one navigation bar per session, so turning this off has
                // to reach the bar that is already built or it stays hidden until relaunch.
                SPKSetting *hideHeader = [SPKSetting switchCellWithTitle:SPKL(@"REELS_LAYOUT_HIDE_REELS_HEADER_TITLE")
                                                                    icon:SPKSettingsIcon(@"reels")
                                                             defaultsKey:@"reels_hide_header"];
                hideHeader.action = ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:SPKHideReelsHeaderDidChangeNotification
                                                                        object:nil];
                };
                hideHeader.helpText = SPKL(@"REELS_LAYOUT_HIDE_REELS_HEADER_HELP");
                hideHeader;
            }),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"REELS_LAYOUT_HIDE_VIEWER_COMMENT_BAR_TITLE")
                                           icon:SPKSettingsIcon(@"comment")
                                    defaultsKey:@"reels_hide_viewer_comment_bar"
                                requiresRestart:YES],
                               SPKL(@"REELS_LAYOUT_HIDE_VIEWER_COMMENT_BAR_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_LAYOUT_HIDE_REPOST_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(@"repost")
                                    defaultsKey:@"reels_hide_repost_btn"
                                requiresRestart:YES],
                               SPKL(@"REELS_LAYOUT_HIDE_REPOST_BUTTON_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"REELS_LAYOUT_HIDE_VISUAL_SEARCH_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(@"visual_search")
                                    defaultsKey:@"reels_hide_visual_search_btn"],
                               SPKL(@"REELS_LAYOUT_HIDE_VISUAL_SEARCH_BUTTON_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"REELS_LAYOUT_SHOW_REPOST_DATE_TITLE")
                                           icon:SPKSettingsIcon(@"calendar")
                                    defaultsKey:@"reels_show_repost_date"],
                               SPKL(@"REELS_LAYOUT_SHOW_REPOST_DATE_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"FEED_METRICS_HEADER"), @[
            [SPKSetting switchCellWithTitle:SPKL(@"FEED_METRICS_HIDE_LIKE_COUNT_TITLE")
                                           icon:SPKSettingsIcon(@"heart")
                                    defaultsKey:@"reels_hide_like_count"],
            [SPKSetting switchCellWithTitle:SPKL(@"FEED_METRICS_HIDE_COMMENT_COUNT_TITLE")
                                           icon:SPKSettingsIcon(@"comment")
                                    defaultsKey:@"reels_hide_comment_count"],
            [SPKSetting switchCellWithTitle:SPKL(@"FEED_METRICS_HIDE_REPOST_COUNT_TITLE")
                                           icon:SPKSettingsIcon(@"repost")
                                    defaultsKey:@"reels_hide_repost_count"],
            [SPKSetting switchCellWithTitle:SPKL(@"FEED_METRICS_HIDE_RESHARE_COUNT_TITLE")
                                           icon:SPKSettingsIcon(@"messages")
                                    defaultsKey:@"reels_hide_reshare_count"],
            [SPKSetting switchCellWithTitle:SPKL(@"REELS_METRICS_HIDE_SAVE_COUNT_TITLE")
                                           icon:SPKSettingsIcon(@"save")
                                    defaultsKey:@"reels_hide_save_count"]
        ],
                        nil),
        SPKTopicSection(SPKL(@"FEED_CONFIRMATION_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_CONFIRMATION_CONFIRM_LIKE_TITLE")
                                           icon:SPKSettingsIcon(@"heart")
                                    defaultsKey:@"reels_confirm_like"],
                               SPKL(@"REELS_CONFIRMATION_CONFIRM_LIKE_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_CONFIRMATION_CONFIRM_DOUBLE_TAP_TITLE")
                                           icon:SPKSettingsIcon(@"heart")
                                    defaultsKey:@"reels_confirm_double_tap_like"],
                               SPKL(@"REELS_CONFIRMATION_CONFIRM_DOUBLE_TAP_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"REELS_CONFIRMATION_CONFIRM_REEL_REFRESH_TITLE")
                                           icon:SPKSettingsIcon(@"arrow_cw")
                                    defaultsKey:@"reels_confirm_refresh"],
                               SPKL(@"REELS_CONFIRMATION_CONFIRM_REFRESH_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_CONFIRMATION_CONFIRM_REPOST_TITLE")
                                           icon:SPKSettingsIcon(@"repost")
                                    defaultsKey:@"reels_confirm_repost"],
                               SPKL(@"REELS_CONFIRMATION_CONFIRM_REPOST_HELP"))
        ],
                        nil)
    ]);
}

@end
