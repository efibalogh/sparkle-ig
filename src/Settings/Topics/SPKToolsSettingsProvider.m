#import "SPKStrings.h"
#import "SPKToolsSettingsProvider.h"
#include <UIKit/UIKit.h>

#import "../../App/SPKFlexLoader.h"
#import "../../App/SPKStabilityGuard.h"
#import "../../AssetUtils.h"
#import "../../Shared/Gallery/SPKGalleryLockViewController.h"
#import "../../Shared/Settings/SPKSettingsLockManager.h"
#import "../../Shared/UI/SPKIGAlertPresenter.h"
#import "../../Utils.h"
#import "../SPKOnboardingViewController.h"
#import "../SPKWhatsNewViewController.h"
#import "../SPKSettingsViewController.h"
#import "../SPKTopicSettingsSupport.h"
#if SPK_DEV
#import "SPKHookBisectSettingsProvider.h"
#endif
#import "SPKInterfaceSettingsProvider.h"

static NSDictionary *SPKSettingsLockSection(void) {
    SPKSetting *lockSwitch = [SPKSetting switchCellWithTitle:SPKL(@"TOOLS_GENERAL_SETTINGS_PASSCODE_LOCK_TITLE")
                                                        icon:SPKSettingsIcon(@"lock")
                                                 defaultsKey:@""];
    lockSwitch.switchValueProvider = ^BOOL {
        return [SPKSettingsLockManager sharedManager].isLockEnabled;
    };
    lockSwitch.switchChangeHandler = ^(BOOL enabled) {
        SPKSettingsLockManager *currentManager = [SPKSettingsLockManager sharedManager];
        UIViewController *presenter = SPKSettingsTopPresenter();
        if (enabled && !currentManager.isLockEnabled) {
            [SPKGalleryLockViewController presentMode:SPKGalleryLockModeSetPasscode
                                           forManager:currentManager
                                   fromViewController:presenter
                                           completion:^(__unused BOOL success) {
                                               SPKSettingsReloadPresenter(presenter);
                                           }];
            return;
        }
        if (!enabled && currentManager.isLockEnabled) {
            [SPKIGAlertPresenter presentAlertFromViewController:presenter
                                                          title:SPKL(@"SETTINGS_TOOLS_DISABLE_SETTINGS_PASSCODE_TEXT")
                                                        message:SPKL(@"SETTINGS_TOOLS_SPARKLE_SETTINGS_NO_LONGER_REQUIRE_AUTHENTICATION_OPEN_TEXT")
                                                        actions:@[
                                                            [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                        style:SPKIGAlertActionStyleCancel
                                                                                      handler:^{
                                                                                          SPKSettingsReloadPresenter(presenter);
                                                                                      }],
                                                            [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_DISABLE")
                                                                                        style:SPKIGAlertActionStyleDestructive
                                                                                      handler:^{
                                                                                          [currentManager removePasscode];
                                                                                          SPKSettingsReloadPresenter(presenter);
                                                                                      }],
                                                        ]];
        }
    };

    lockSwitch.helpText = SPKL(@"TOOLS_SETTINGS_LOCK_PASSCODE_HELP");

    SPKSetting *changePasscode = [SPKSetting buttonCellWithTitle:SPKL(@"TOOLS_GENERAL_CHANGE_SETTINGS_PASSCODE_TITLE")
                                                        subtitle:nil
                                                            icon:SPKSettingsIcon(@"key")
                                                          action:^{
                                                              [SPKGalleryLockViewController presentMode:SPKGalleryLockModeChangePasscode
                                                                                             forManager:[SPKSettingsLockManager sharedManager]
                                                                                     fromViewController:SPKSettingsTopPresenter()
                                                                                             completion:^(__unused BOOL success){
                                                                                             }];
                                                          }];
    changePasscode.enabledProvider = ^BOOL {
        return [SPKSettingsLockManager sharedManager].isLockEnabled;
    };

    return SPKTopicSection(SPKL(@"TOOLS_SETTINGS_LOCK_HEADER"), @[ lockSwitch, changePasscode ], nil);
}

@implementation SPKToolsSettingsProvider

+ (SPKSetting *)rootSetting {
    BOOL flexInstalled = SPKFlexIsBundled();
    NSString *flexFooter = flexInstalled ? nil : SPKL(@"FLEX_SETTINGS_NOT_INSTALLED_FOOTER");
    SPKSetting *flexGesture = [SPKSetting switchCellWithTitle:SPKL(@"TOOLS_SETTINGS_LOCK_THREE_FINGER_HOLD_TITLE") defaultsKey:@"tools_flex_instagram"];
    SPKSetting *flexLaunch = [SPKSetting switchCellWithTitle:SPKL(@"TOOLS_SETTINGS_LOCK_OPEN_APP_LAUNCH_TITLE") defaultsKey:@"tools_flex_app_launch"];
    SPKSetting *flexFocus = [SPKSetting switchCellWithTitle:SPKL(@"TOOLS_SETTINGS_LOCK_OPEN_APP_FOCUS_TITLE") defaultsKey:@"tools_flex_app_start"];
    SPKSetting *flexOpen = [SPKSetting buttonCellWithTitle:SPKL(@"TOOLS_SETTINGS_LOCK_OPEN_FLEX_NOW_TITLE")
                                                  subtitle:@""
                                                      icon:nil
                                                    action:^(void) {
                                                        SPKFlexShowExplorer(@"settings");
                                                    }];
    if (flexInstalled) {
        flexOpen.helpText = SPKL(@"TOOLS_FLEX_OPEN_NOW_HELP");
        flexGesture.helpText = SPKL(@"TOOLS_FLEX_THREE_FINGER_HOLD_HELP");
        flexLaunch.helpText = SPKL(@"TOOLS_FLEX_OPEN_APP_LAUNCH_HELP");
        flexFocus.helpText = SPKL(@"TOOLS_FLEX_OPEN_APP_FOCUS_HELP");
    }
    if (!flexInstalled) {
        flexGesture.userInfo = @{@"enabled" : @NO};
        flexLaunch.userInfo = @{@"enabled" : @NO};
        flexFocus.userInfo = @{@"enabled" : @NO};
        flexOpen.userInfo = @{@"enabled" : @NO};
    }
    NSMutableArray *sections = [NSMutableArray arrayWithArray:@[
        SPKTopicSection(SPKL(@"TOOLS_FLEX_HEADER"), @[ flexOpen, flexGesture, flexLaunch, flexFocus ], flexFooter),
        SPKTopicSection(SPKL(@"TOOLS_TWEAK_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"TOOLS_TWEAK_QUICK_SETTINGS_ACCESS_TITLE")
                                    defaultsKey:@"tools_settings_shortcut"
                                requiresRestart:YES],
                               SPKL(@"TOOLS_TWEAK_QUICK_SETTINGS_ACCESS_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"TOOLS_TWEAK_SHORTCUT_HAPTICS_TITLE")
                                    defaultsKey:@"tools_shortcut_haptics"],
                               SPKL(@"TOOLS_TWEAK_SHORTCUT_HAPTICS_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"TOOLS_TWEAK_SHOW_SETTINGS_APP_LAUNCH_TITLE")
                                    defaultsKey:@"tools_open_settings_on_launch"],
                               SPKL(@"TOOLS_TWEAK_SHOW_SETTINGS_APP_LAUNCH_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"TOOLS_TWEAK_DISABLE_ALL_SETTINGS_TITLE")
                                    defaultsKey:@"tools_disable_all"
                                requiresRestart:YES],
                               SPKL(@"TOOLS_TWEAK_DISABLE_ALL_SETTINGS_HELP")),
            SPKSettingWithHelp([SPKSetting buttonCellWithTitle:SPKL(@"TOOLS_TWEAK_SHOW_ONBOARDING_TITLE")
                                       subtitle:@""
                                           icon:nil
                                         action:^(void) {
                                             [SPKOnboardingViewController presentFromViewController:nil onFinish:nil];
                                         }],
                               SPKL(@"TOOLS_TWEAK_SHOW_ONBOARDING_HELP")),
            SPKSettingWithHelp([SPKSetting buttonCellWithTitle:SPKL(@"TOOLS_TWEAK_SHOW_WHAT_S_NEW_TITLE")
                                       subtitle:@""
                                           icon:nil
                                         action:^(void) {
                                             [SPKWhatsNewViewController presentFromViewController:nil onFinish:nil];
                                         }],
                               SPKL(@"TOOLS_TWEAK_SHOW_WHATS_NEW_HELP")),
        ],
                        nil),

        SPKTopicSection(@"", @[
            SPKSettingWithHelp([SPKSetting buttonCellWithTitle:SPKL(@"TOOLS_TWEAK_RESET_SAFE_STARTUP_MODE_TITLE")
                                       subtitle:@""
                                           icon:nil
                                         action:^(void) {
                                             SPKStabilityGuardReset();
                                             [SPKUtils showRestartConfirmation];
                                         }],
                               SPKL(@"TOOLS_TWEAK_RESET_SAFE_STARTUP_MODE_HELP")),
#if SPK_DEV
            // Dev builds only: wipe the intro-sheet state so the onboarding /
            // What's New gating fires from scratch on the next launch.
            [SPKSetting buttonCellWithTitle:SPKL(@"TOOLS_TWEAK_DEV_RESET_INTRO_STATE_TITLE")
                                   subtitle:@""
                                       icon:nil
                                     action:^(void) {
                                         NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                                         [defaults removeObjectForKey:@"app_first_run"];
                                         [defaults removeObjectForKey:@"app_last_whatsnew_version"];
                                         [SPKUtils showRestartConfirmation];
                                     }],
#endif
        ], nil),
#if SPK_DEV
        SPKTopicSection(SPKL(@"TOOLS_DIAGNOSTICS_HEADER"),
                        @[ SPKSettingWithHelp([SPKHookBisectSettingsProvider rootSetting], SPKL(@"TOOLS_DIAGNOSTICS_HOOK_BISECT_HELP")) ],
                        nil),
#endif
        SPKSettingsLockSection(),
    ]];

    // The TestFlight/Beta popup suppression is always active on release builds.
    // On dev builds, we keep a toggle to allow disabling it for testing.
    NSMutableArray *instagramCells = [NSMutableArray array];
#if SPK_DEV
    [instagramCells addObject:SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"TOOLS_DIAGNOSTICS_DEV_HIDE_TESTFLIGHT_POPUP_TITLE")
                                                      defaultsKey:@"tools_hide_testflight_popup"
                                                  requiresRestart:YES],
                                                 SPKL(@"TOOLS_INSTAGRAM_HIDE_TESTFLIGHT_POPUP_HELP"))];
#endif
    [instagramCells addObject:SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"TOOLS_DIAGNOSTICS_FIX_DUPLICATE_NOTIFICATIONS_TITLE")
                                                      defaultsKey:@"tools_fix_duplicate_notifications"],
                                                 SPKL(@"TOOLS_INSTAGRAM_FIX_DUPLICATE_NOTIFICATIONS_HELP"))];
    [instagramCells addObject:SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"TOOLS_DIAGNOSTICS_DISABLE_SAFE_MODE_TITLE")
                                                      defaultsKey:@"tools_disable_safe_mode"],
                                                 SPKL(@"TOOLS_INSTAGRAM_DISABLE_SAFE_MODE_HELP"))];

    [sections addObject:SPKTopicSection(SPKL(@"ABOUT_INFORMATION_INSTAGRAM_TITLE"), instagramCells, nil)];

    return SPKTopicNavigationSetting(SPKL(@"TOOLS_TITLE"), @"toolbox", 24.0, sections);
}

@end
