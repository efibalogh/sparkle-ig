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
#import "../../Features/Interface/SPKNativeTabBar.h"

FOUNDATION_EXPORT BOOL SPKLiquidGlassInstagramEnabled(void);

// Whether the glass interface is active this launch: the forced mode when one
// is picked, otherwise what Instagram itself gives this account.
static BOOL SPKLiquidGlassSwitchIsOn(void) {
    NSString *mode = [SPKUtils getStringPref:kSPKPrefInterfaceLiquidGlassMode];
    if ([mode isEqualToString:@"on"])
        return YES;
    if ([mode isEqualToString:@"off"])
        return NO;
    return SPKLiquidGlassInstagramEnabled();
}

// Opens the Notifications page with its live preview; search still indexes its rows.
static SPKSetting *SPKNotificationsNavigationSetting(void) {
    SPKSetting *setting = [SPKSetting navigationCellWithTitle:SPKL(@"INTERFACE_NOTIFICATIONS_HEADER")
                                                     subtitle:nil
                                                         icon:SPKSettingsIcon(@"notification")
                                               viewController:[SPKNotificationSettingsProvider settingsViewController]];
    setting.searchSectionsProvider = ^NSArray * {
        return [SPKNotificationSettingsProvider sections];
    };
    return setting;
}

// Why the system tab bar ignores some of this page, said once under the group
// it affects. Nil while Instagram's own bar is in use.
static NSString *SPKSystemTabBarGlassFooter(void) {
    if (!SPKSystemTabBarInUse())
        return nil;
    if (![SPKUtils getBoolPref:kSPKPrefInterfaceNativeTabBar])
        return SPKL(@"INTERFACE_LIQUID_GLASS_SYSTEM_TAB_BAR_BUILT_IN_FOOTER");
    return SPKL(@"INTERFACE_LIQUID_GLASS_SYSTEM_TAB_BAR_FOOTER");
}

static NSString *SPKSystemTabBarBlackGlassFooter(void) {
    if (!SPKSystemTabBarInUse() || !SPKPrefIsAvailable(@"interface_oled_black_glass") ||
        ![SPKUtils getBoolPref:@"interface_oled_dark_mode"])
        return nil;
    return SPKL(@"INTERFACE_APPEARANCE_OLED_BLACK_GLASS_SYSTEM_TAB_BAR_FOOTER");
}

@implementation SPKInterfaceSettingsProvider

+ (SPKSetting *)rootSetting {
    NSMutableArray *sections = [NSMutableArray arrayWithArray:@[
        SPKTopicSection(SPKL(@"INTERFACE_NOTIFICATIONS_HEADER"), @[
            SPKSettingWithHelp(SPKNotificationsNavigationSetting(), SPKL(@"INTERFACE_NOTIFICATIONS_HELP"))
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
                        SPKSystemTabBarBlackGlassFooter()),
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
            ({
                SPKSetting *clipboardLink = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_EXPLORE_SEARCH_OPEN_CLIPBOARD_LINK_TITLE")
                                                                                          icon:SPKSettingsIcon(@"link")
                                                                                   defaultsKey:@"interface_open_clipboard_link"],
                                                               SPKL(@"INTERFACE_EXPLORE_SEARCH_OPEN_CLIPBOARD_LINK_HELP"));
                clipboardLink.reloadsTableOnSwitchChange = YES;
                clipboardLink;
            }),
            ({
                SPKSetting *clipboardUsername = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_EXPLORE_SEARCH_OPEN_CLIPBOARD_USERNAME_TITLE")
                                                                                              icon:SPKSettingsIcon(@"mention")
                                                                                       defaultsKey:@"interface_open_clipboard_username"],
                                                                   SPKL(@"INTERFACE_EXPLORE_SEARCH_OPEN_CLIPBOARD_USERNAME_HELP"));
                clipboardUsername.hiddenProvider = ^BOOL {
                    return ![SPKUtils getBoolPref:@"interface_open_clipboard_link"];
                };
                clipboardUsername;
            }),
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
                // The system tab bar is not Instagram's floating bar, so the
                // scroll behavior it configures does not reach it. Asked of the
                // running bar: foldables pick the system bar by themselves.
                if (SPKSystemTabBarInUse())
                    return NO;
                return SPKLiquidGlassSwitchIsOn();
            };
            tabBarBehavior.helpText = SPKL(@"INTERFACE_TAB_BAR_BEHAVIOR_HELP");
            return tabBarBehavior;
        };

        if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"26.0")) {
            // Full Liquid Glass: real glass material, progressive blur, tab bar.
            SPKSetting *liquidGlass = [SPKSetting menuCellWithTitle:SPKL(@"INTERFACE_CAPTURE_LIQUID_GLASS_TITLE")
                                                               icon:nil
                                                               menu:SPKLiquidGlassModeMenu()];
            liquidGlass.defaultsKey = kSPKPrefInterfaceLiquidGlassMode;
            liquidGlass.helpText = SPKL(@"INTERFACE_LIQUID_GLASS_HELP");
            SPKSetting *scrollEdgeStyle = [SPKSetting menuCellWithTitle:SPKL(@"INTERFACE_SCROLL_EDGE_EFFECT_TITLE")
                                                                   icon:nil
                                                                   menu:SPKScrollEdgeStyleMenu()];
            scrollEdgeStyle.defaultsKey = kSPKPrefInterfaceScrollEdgeStyle;
            scrollEdgeStyle.helpText = SPKL(@"INTERFACE_SCROLL_EDGE_EFFECT_HELP");
            SPKSetting *nativeTabBar = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_NATIVE_TAB_BAR_TITLE")
                                                                                     icon:nil
                                                                              defaultsKey:kSPKPrefInterfaceNativeTabBar
                                                                          requiresRestart:YES],
                                                          SPKL(@"INTERFACE_NATIVE_TAB_BAR_HELP"));
            nativeTabBar.hiddenProvider = ^BOOL {
                return !SPKPrefIsAvailable(kSPKPrefInterfaceNativeTabBar);
            };
            nativeTabBar.reloadsTableOnSwitchChange = YES;
            // Where Instagram runs the system bar by itself, the switch has
            // nothing to force or give back.
            nativeTabBar.enabledProvider = ^BOOL {
                return !SPKSystemTabBarInUse() || [SPKUtils getBoolPref:kSPKPrefInterfaceNativeTabBar];
            };

            [sections addObject:SPKTopicSection(SPKL(@"INTERFACE_LIQUID_GLASS_BLUR_HEADER"), @[
                          liquidGlass,
                          scrollEdgeStyle,
                          nativeTabBar,
                          tabBarBehaviorCell(),
                      ],
                                                SPKSystemTabBarGlassFooter())];
        } else {
            // Pre-iOS 26 can't render the glass material, but the same tab bar
            // experiment gates still reshape the bar into the floating pill.
            // Expose that as a focused toggle sharing the Liquid Glass pref.
            SPKSetting *pillTabBar = [SPKSetting menuCellWithTitle:SPKL(@"INTERFACE_LIQUID_GLASS_BLUR_PILL_SHAPED_TAB_BAR_TITLE")
                                                              icon:nil
                                                              menu:SPKLiquidGlassModeMenu()];
            pillTabBar.defaultsKey = kSPKPrefInterfaceLiquidGlassMode;
            pillTabBar.helpText = SPKL(@"INTERFACE_PILL_TAB_BAR_HELP");

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
