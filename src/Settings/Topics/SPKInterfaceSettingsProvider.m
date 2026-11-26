#import "SPKStrings.h"
#import "../SPKNewBadges.h"
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

// The Liquid Glass symbol only exists from iOS 27, so iOS 26 falls back to
// Instagram's opacity glyph.
static UIImage *SPKLiquidGlassSettingsIcon(void) {
    return SPKSettingsSystemIcon(@"capsule.on.rectangle.liquid.glass", SPKSettingsCellIconPointSize, UIImageSymbolWeightSemibold)
               ?: SPKSettingsIcon(@"liquid_glass");
}

// The Tab Bar page is the staged Tab Editor, which is not built from settings
// rows, so search gets stand-ins: each opens the editor itself.
static NSArray *SPKTabBarSearchSections(UIViewController *editor) {
    SPKSetting * (^entry)(NSString *, NSString *) = ^SPKSetting *(NSString *title, NSString *iconName) {
        return [SPKSetting navigationCellWithTitle:title
                                          subtitle:nil
                                              icon:iconName ? SPKSettingsIcon(iconName) : nil
                                    viewController:editor];
    };
    NSMutableArray *rows = [NSMutableArray arrayWithArray:@[
        entry(SPKL(@"INTERFACE_TABS_HEADER"), @"edit"),
        entry(SPKL(@"INTERFACE_TAB_BAR_SHORTCUTS_HEADER"), @"settings"),
        entry(SPKL(@"SETTINGS_TAB_EDITOR_LAUNCH_TAB_TEXT"), @"home"),
    ]];
    // Mirrors the page: where Instagram runs the system bar by itself, the
    // swipe and appearance rows are not on it.
    if (SPKTabEditorInstagramOwnsSystemTabBar())
        return @[ SPKTopicSection(SPKL(@"INTERFACE_TAB_BAR_TITLE"), rows, nil) ];
    [rows addObject:entry(SPKL(@"SETTINGS_TAB_EDITOR_SWIPE_BETWEEN_TABS_TEXT"), @"left_right")];
    [rows addObject:entry(SPKL(@"INTERFACE_TAB_BAR_BEHAVIOR_TITLE"), nil)];
    if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"26.0"))
        [rows addObject:entry(SPKL(@"INTERFACE_NATIVE_TAB_BAR_TITLE"), nil)];
    else
        [rows addObject:entry(SPKL(@"INTERFACE_TAB_BAR_PILL_SHAPED_TITLE"), nil)];
    return @[ SPKTopicSection(SPKL(@"INTERFACE_TAB_BAR_TITLE"), rows, nil) ];
}

static SPKSetting *SPKTabBarNavigationSetting(void) {
    SPKTabEditorViewController *editor = [[SPKTabEditorViewController alloc] init];
    SPKSetting *setting = [SPKSetting navigationCellWithTitle:SPKL(@"INTERFACE_TAB_BAR_TITLE")
                                                     subtitle:nil
                                                         icon:SPKSettingsIcon(@"layout")
                                               viewController:editor];
    __weak SPKTabEditorViewController *weakEditor = editor;
    setting.searchSectionsProvider = ^NSArray * {
        return weakEditor ? SPKTabBarSearchSections(weakEditor) : @[];
    };
    setting.addedContentItems = @[ SPKTabEditorNewItemHolds, SPKTabEditorNewItemSystemTabBar ];
    return SPKSettingWithHelp(setting, SPKL(@"INTERFACE_TAB_BAR_HELP"));
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
        SPKTopicSection(SPKL(@"INTERFACE_TAB_BAR_HEADER"), @[
            SPKTabBarNavigationSetting(),
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
            ({
                // Full Liquid Glass: real glass material and progressive blur.
                // Hidden below iOS 26, where only the tab bar's pill shape is
                // offered (on the Tab Bar page).
                SPKSetting *liquidGlass = [SPKSetting menuCellWithTitle:SPKL(@"INTERFACE_CAPTURE_LIQUID_GLASS_TITLE")
                                                                   icon:SPKLiquidGlassSettingsIcon()
                                                                   menu:SPKLiquidGlassModeMenu()];
                liquidGlass.defaultsKey = kSPKPrefInterfaceLiquidGlassMode;
                liquidGlass.helpText = SPKL(@"INTERFACE_LIQUID_GLASS_HELP");
                liquidGlass.hiddenProvider = ^BOOL {
                    return !SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"26.0");
                };
                liquidGlass;
            }),
            ({
                SPKSetting *scrollEdgeStyle = [SPKSetting menuCellWithTitle:SPKL(@"INTERFACE_SCROLL_EDGE_EFFECT_TITLE")
                                                                       icon:SPKSettingsSystemIcon(@"square.topthird.inset.filled", SPKSettingsCellIconPointSize, UIImageSymbolWeightRegular)
                                                                       menu:SPKScrollEdgeStyleMenu()];
                scrollEdgeStyle.defaultsKey = kSPKPrefInterfaceScrollEdgeStyle;
                scrollEdgeStyle.helpText = SPKL(@"INTERFACE_SCROLL_EDGE_EFFECT_HELP");
                scrollEdgeStyle.hiddenProvider = ^BOOL {
                    return !SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"26.0");
                };
                scrollEdgeStyle;
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
            SPKSettingMarkedNew(SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_EXPLORE_SEARCH_RESTORE_ACCOUNT_SEARCH_TITLE")
                                                          icon:SPKSettingsIcon(@"user_circle")
                                                   defaultsKey:@"interface_restore_account_search"],
                               SPKL(@"INTERFACE_EXPLORE_SEARCH_RESTORE_ACCOUNT_SEARCH_HELP")), @"v1.7.0"),
        ],
                        nil),
        SPKTopicSection(SPKL(@"INTERFACE_CAPTURE_HEADER"), @[
            ({
                SPKSetting *s = [SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_CAPTURE_HIDE_UI_CAPTURE_TITLE")
                                                           icon:SPKSettingsSystemIcon(@"rays", SPKSettingsCellIconPointSize, UIImageSymbolWeightSemibold)
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

    return SPKTopicNavigationSetting(SPKL(@"INTERFACE_TITLE"), @"interface", 24.0, sections);
}

@end
