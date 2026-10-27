#import "SPKStrings.h"
#import "SPKInterfaceSettingsProvider.h"
#import "../../Shared/Fonts/SPKFontManager.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../SPKFontPickerViewController.h"
#import "../../Utils.h"
#import "../SPKPreferenceAvailability.h"
#import "../SPKPreferences.h"
#import "../SPKTopicSettingsSupport.h"
#import "../../Shared/Navigation/SPKTabConfiguration.h"
#import "../SPKTabEditorViewController.h"
#import "SPKNotificationSettingsProvider.h"

@implementation SPKInterfaceSettingsProvider

+ (SPKSetting *)rootSetting {
    NSMutableArray *sections = [NSMutableArray arrayWithArray:@[
        SPKTopicSection(SPKL(@"INTERFACE_NOTIFICATIONS_HEADER"), @[
            SPKSettingWithHelp([SPKSetting navigationCellWithTitle:SPKL(@"INTERFACE_NOTIFICATIONS_HEADER")
                                                          subtitle:nil
                                                              icon:SPKSettingsIcon(@"notification")
                                                       navSections:[SPKNotificationSettingsProvider sections]],
                               SPKL(@"INTERFACE_NOTIFICATIONS_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"INTERFACE_TABS_HEADER"), @[
            SPKSettingWithHelp([SPKSetting navigationCellWithTitle:SPKL(@"INTERFACE_TABS_TAB_EDITOR_TITLE")
                                                          subtitle:nil
                                                              icon:SPKSettingsIcon(@"edit")
                                                    viewController:[[SPKTabEditorViewController alloc] init]],
                               SPKL(@"INTERFACE_TABS_TAB_EDITOR_HELP")),
        ],
                        nil),
        SPKTopicSection(SPKL(@"INTERFACE_APPEARANCE_HEADER"), @[
            ({
                SPKSetting *appFont = [SPKSetting navigationCellWithTitle:SPKL(@"FONT_APP_FONT_TITLE")
                                                                 subtitle:nil
                                                                     icon:SPKSettingsIcon(@"text")
                                                           viewController:[[SPKFontPickerViewController alloc] init]];
                appFont.accessoryTextProvider = ^NSString * {
                    return [SPKFontManager selectedFamilyName] ?: SPKL(@"FONT_DEFAULT_ROW_TITLE");
                };
                appFont.helpText = SPKL(@"INTERFACE_APPEARANCE_APP_FONT_HELP");
                appFont;
            }),
            ({
                SPKSetting *oled = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_APPEARANCE_OLED_DARK_MODE_TITLE")
                                                                                 icon:SPKSettingsIcon(@"moon")
                                                                          defaultsKey:@"interface_oled_dark_mode"
                                                                      requiresRestart:YES],
                                                      SPKL(@"INTERFACE_APPEARANCE_OLED_DARK_MODE_HELP"));
                oled.reloadsTableOnSwitchChange = YES;
                oled;
            }),
            ({
                SPKSetting *blackGlass = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_APPEARANCE_OLED_BLACK_GLASS_TITLE")
                                                                                       icon:SPKSettingsIcon(@"moon_filled")
                                                                                defaultsKey:@"interface_oled_black_glass"
                                                                            requiresRestart:YES],
                                                            SPKL(@"INTERFACE_APPEARANCE_OLED_BLACK_GLASS_HELP"));
                blackGlass.hiddenProvider = ^BOOL {
                    return !SPKPrefIsAvailable(@"interface_oled_black_glass") || ![SPKUtils getBoolPref:@"interface_oled_dark_mode"];
                };
                blackGlass;
            }),
        ],
                        nil),
        SPKTopicSection(SPKL(@"INTERFACE_EXPLORE_SEARCH_HEADER"), @[
            ({
                SPKSetting *s = [SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_EXPLORE_SEARCH_HIDE_EXPLORE_POSTS_GRID_TITLE")
                                                           icon:SPKSettingsIcon(@"grid_tall")
                                                    defaultsKey:@"interface_hide_explore_grid"];
                s.switchChangeHandler = ^(BOOL isOn) {
                    SPKPreferenceSetObject(@(isOn), @"interface_hide_explore_grid");
                    [[NSNotificationCenter defaultCenter] postNotificationName:SPKHideExploreGridPreferenceDidChangeNotification object:nil];
                };
                s.helpText = SPKL(@"INTERFACE_EXPLORE_SEARCH_HIDE_EXPLORE_GRID_HELP");
                s;
            }),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_EXPLORE_SEARCH_SQUARE_GRID_TITLE")
                                                          icon:SPKSettingsIcon(@"grid_square")
                                                   defaultsKey:@"interface_explore_square_grid"],
                               SPKL(@"INTERFACE_EXPLORE_SEARCH_SQUARE_GRID_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_EXPLORE_SEARCH_OPEN_CLIPBOARD_LINK_TITLE")
                                                          icon:SPKSettingsIcon(@"link")
                                                   defaultsKey:@"interface_open_clipboard_link"],
                               SPKL(@"INTERFACE_EXPLORE_SEARCH_OPEN_CLIPBOARD_LINK_HELP"))
        ],
                        nil),

        SPKTopicSection(@"", @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_EXPLORE_SEARCH_HIDE_TRENDING_SEARCHES_TITLE")
                                                          icon:SPKSettingsIcon(@"trending")
                                                   defaultsKey:@"interface_hide_trending_searches"
                                               requiresRestart:YES],
                               SPKL(@"INTERFACE_EXPLORE_SEARCH_HIDE_TRENDING_SEARCHES_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_EXPLORE_SEARCH_HIDE_RECENT_SEARCHES_TITLE")
                                                          icon:SPKSettingsIcon(@"search")
                                                   defaultsKey:@"general_hide_recent_searches"
                                               requiresRestart:YES],
                               SPKL(@"INTERFACE_EXPLORE_SEARCH_HIDE_RECENT_SEARCHES_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_EXPLORE_SEARCH_PIN_PEOPLE_TITLE")
                                                          icon:SPKSettingsIcon(@"pin")
                                                   defaultsKey:@"interface_search_pins"],
                               SPKL(@"INTERFACE_EXPLORE_SEARCH_PIN_PEOPLE_HELP")),
        ],
                        nil),
        SPKTopicSection(SPKL(@"INTERFACE_CAPTURE_HEADER"), @[
            ({
                SPKSetting *s = [SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_CAPTURE_HIDE_UI_CAPTURE_TITLE")
                                                           icon:nil
                                                    defaultsKey:@"interface_hide_ui_on_capture"];
                s.switchChangeHandler = ^(BOOL isOn) {
                    [[NSUserDefaults standardUserDefaults] setBool:isOn forKey:@"interface_hide_ui_on_capture"];
                    [[NSNotificationCenter defaultCenter] postNotificationName:SPKHideUIOnCapturePreferenceDidChangeNotification object:nil];
                };
                s.helpText = SPKL(@"INTERFACE_CAPTURE_HIDE_UI_CAPTURE_HELP");
                s;
            })
        ],
                        nil)
    ]];

    {
        // Tab Bar Behavior is shared by both presentations: it configures the
        // scroll behavior of the (pill/glass) tab bar and is enabled whenever
        // the Liquid Glass pref is on.
        SPKSetting *(^tabBarBehaviorCell)(void) = ^SPKSetting * {
            SPKSetting *tabBarBehavior = [SPKSetting menuCellWithTitle:SPKL(@"INTERFACE_CAPTURE_TAB_BAR_BEHAVIOR_TITLE")
                                                                  icon:nil
                                                                  menu:SPKLiquidGlassTabBarStateMenu()];
            tabBarBehavior.defaultsKey = kSPKPrefInterfaceLiquidGlassTabBarMode;
            tabBarBehavior.enabledProvider = ^BOOL {
                return [SPKUtils getBoolPref:kSPKPrefInterfaceLiquidGlass];
            };
            tabBarBehavior.helpText = SPKL(@"INTERFACE_TAB_BAR_BEHAVIOR_HELP");
            return tabBarBehavior;
        };

        if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"26.0")) {
            // Full Liquid Glass: real glass material, progressive blur, tab bar.
            SPKSetting *liquidGlass = [SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_CAPTURE_LIQUID_GLASS_TITLE")
                                                          defaultsKey:kSPKPrefInterfaceLiquidGlass
                                                      requiresRestart:YES];
            liquidGlass.switchValueProvider = ^BOOL {
                return [SPKUtils getBoolPref:kSPKPrefInterfaceLiquidGlass];
            };
            liquidGlass.helpText = SPKL(@"INTERFACE_LIQUID_GLASS_HELP");
            liquidGlass.switchChangeHandler = ^(BOOL isOn) {
                [[NSUserDefaults standardUserDefaults] setBool:isOn forKey:kSPKPrefInterfaceLiquidGlass];
                [SPKUtils showRestartConfirmation];
            };
            SPKSetting *scrollEdgeStyle = [SPKSetting menuCellWithTitle:SPKL(@"INTERFACE_SCROLL_EDGE_EFFECT_TITLE")
                                                                   icon:nil
                                                                   menu:SPKScrollEdgeStyleMenu()];
            scrollEdgeStyle.defaultsKey = kSPKPrefInterfaceScrollEdgeStyle;
            scrollEdgeStyle.helpText = SPKL(@"INTERFACE_SCROLL_EDGE_EFFECT_HELP");

            [sections addObject:SPKTopicSection(SPKL(@"INTERFACE_LIQUID_GLASS_BLUR_HEADER"), @[
                          liquidGlass,
                          scrollEdgeStyle,
                          tabBarBehaviorCell(),
                      ],
                                                nil)];
        } else {
            // Pre-iOS 26 can't render the glass material, but the same tab bar
            // experiment gates still reshape the bar into the floating pill.
            // Expose that as a focused toggle sharing the Liquid Glass pref.
            SPKSetting *pillTabBar = [SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_LIQUID_GLASS_BLUR_PILL_SHAPED_TAB_BAR_TITLE")
                                                        defaultsKey:kSPKPrefInterfaceLiquidGlass
                                                    requiresRestart:YES];
            pillTabBar.switchValueProvider = ^BOOL {
                return [SPKUtils getBoolPref:kSPKPrefInterfaceLiquidGlass];
            };
            pillTabBar.helpText = SPKL(@"INTERFACE_PILL_TAB_BAR_HELP");
            pillTabBar.switchChangeHandler = ^(BOOL isOn) {
                [[NSUserDefaults standardUserDefaults] setBool:isOn forKey:kSPKPrefInterfaceLiquidGlass];
                [SPKUtils showRestartConfirmation];
            };

            [sections addObject:SPKTopicSection(SPKL(@"INTERFACE_TAB_BAR_HEADER"), @[
                          pillTabBar,
                          tabBarBehaviorCell(),
                      ],
                                                nil)];
        }
    }

    return SPKTopicNavigationSetting(SPKL(@"INTERFACE_TITLE"), @"interface", 24.0, sections);
}

@end
