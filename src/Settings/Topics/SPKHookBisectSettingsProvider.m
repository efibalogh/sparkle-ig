#import "SPKStrings.h"
#import "SPKHookBisectSettingsProvider.h"

#if SPK_DEV

#import <UIKit/UIKit.h>

#import "../../App/SPKHookBisect.h"
#import "../../App/SPKPerfMeter.h"
#import "../../Utils.h"
#import "../SPKSettingsViewController.h"
#import "../SPKTopicSettingsSupport.h"

// The bulk buttons flip many switches at once, so the visible rows have to be
// re-read. Same shape as the settings-lock rows in SPKToolsSettingsProvider.
static void SPKHookBisectReloadVisibleSettings(void) {
    UIViewController *presenter = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (presenter.presentedViewController)
        presenter = presenter.presentedViewController;

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

static UIViewController *SPKHookBisectVisiblePresenter(void) {
    UIViewController *presenter = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (presenter.presentedViewController)
        presenter = presenter.presentedViewController;
    return presenter;
}

static NSString *SPKHookBisectStateReport(void) {
    NSMutableArray<NSString *> *skipped = [NSMutableArray array];
    for (NSDictionary *group in SPKHookBisectRegisteredGroups()) {
        for (NSString *installerName in group[@"installers"] ?: @[]) {
            if (SPKHookBisectInstallerIsSkipped(installerName))
                [skipped addObject:[NSString stringWithFormat:@"%@ / %@", group[@"surface"] ?: @"Unknown", installerName]];
        }
    }

    NSMutableString *state = [NSMutableString stringWithFormat:@"\n\nHook bisect\nMaster disable all: %@\nConfigured to skip on launch: %lu of %lu\n",
                                                               [SPKUtils getBoolPref:@"tools_disable_all"] ? @"yes" : @"no",
                                                               (unsigned long)SPKHookBisectSkippedCount(),
                                                               (unsigned long)SPKHookBisectRegisteredInstallerCount()];
    if (skipped.count == 0) {
        [state appendString:@"(none)\n"];
    } else {
        for (NSString *entry in skipped)
            [state appendFormat:@"%@\n", entry];
    }
    return state;
}

static void SPKSharePerformanceReport(void) {
    NSMutableString *report = [SPKPerfMeterTextReport() mutableCopy];
    [report appendString:SPKHookBisectStateReport()];

    NSDateFormatter *filenameFormatter = [[NSDateFormatter alloc] init];
    filenameFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    filenameFormatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *filename = [NSString stringWithFormat:@"Sparkle-Performance-%@.txt",
                                                     [filenameFormatter stringFromDate:[NSDate date]]];
    NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
    NSError *writeError = nil;
    BOOL wroteFile = [report writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:&writeError];

    UIViewController *presenter = SPKHookBisectVisiblePresenter();
    if (!presenter)
        return;
    NSArray *items = wroteFile ? @[ fileURL ] : @[ report ];
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    share.popoverPresentationController.sourceView = presenter.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),
                                                                CGRectGetMidY(presenter.view.bounds), 1.0, 1.0);
    if (wroteFile) {
        share.completionWithItemsHandler = ^(__unused UIActivityType activityType,
                                             __unused BOOL completed,
                                             __unused NSArray *returnedItems,
                                             __unused NSError *activityError) {
            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
        };
    }
    [presenter presentViewController:share animated:YES completion:nil];
}

static SPKSetting *SPKHookBisectInstallerRow(NSString *installerName) {
    BOOL essential = SPKHookBisectInstallerIsEssential(installerName);
    // ON = installed. Reading "turn the hook off" matches what the user is
    // doing; the underlying pref stores the inverse (skipped).
    SPKSetting *row = [SPKSetting switchCellWithTitle:SPKHookBisectDisplayName(installerName)
                                             subtitle:essential ? SPKL(@"SETTINGS_HOOK_BISECT_ALWAYS_INSTALLED_TEXT") : @""
                                          defaultsKey:@""];
    row.requiresRestart = YES;
    row.switchValueProvider = ^BOOL {
        return !SPKHookBisectInstallerIsSkipped(installerName);
    };
    row.switchChangeHandler = ^(BOOL isOn) {
        SPKHookBisectSetInstaller(installerName, !isOn);
    };
    if (essential) {
        row.enabledProvider = ^BOOL {
            return NO;
        };
    }
    return row;
}

// The meter is what makes a bisect round decidable: "feels smoother" is not a
// result, "180ms blocked instead of 4.2s" is.
static NSArray<SPKSetting *> *SPKPerfMeterRows(void) {
    SPKSetting *meter = [SPKSetting switchCellWithTitle:SPKL(@"HOOKBISECT_GENERAL_PERFORMANCE_METER_TITLE") defaultsKey:@""];
    meter.switchValueProvider = ^BOOL {
        return SPKPerfMeterIsEnabled();
    };
    meter.switchChangeHandler = ^(BOOL isOn) {
        SPKPreferenceSetObject(@(isOn), kSPKPerfMeterEnabledKey);
        SPKPerfMeterSetEnabled(isOn);
        if (isOn && [SPKUtils getBoolPref:kSPKPerfMeterHUDKey])
            SPKPerfMeterSetHUDVisible(YES);
        SPKHookBisectReloadVisibleSettings();
    };

    SPKSetting *hud = [SPKSetting switchCellWithTitle:SPKL(@"HOOKBISECT_GENERAL_SCREEN_HUD_TITLE") defaultsKey:@""];
    hud.switchValueProvider = ^BOOL {
        return [SPKUtils getBoolPref:kSPKPerfMeterHUDKey];
    };
    hud.switchChangeHandler = ^(BOOL isOn) {
        SPKPreferenceSetObject(@(isOn), kSPKPerfMeterHUDKey);
        SPKPerfMeterSetHUDVisible(isOn && SPKPerfMeterIsEnabled());
    };
    hud.enabledProvider = ^BOOL {
        return SPKPerfMeterIsEnabled();
    };

    SPKSetting *summary = [SPKSetting buttonCellWithTitle:SPKL(@"HOOKBISECT_GENERAL_BLOCKED_TIME_TITLE")
                                                 subtitle:@""
                                                     icon:nil
                                                   action:^{
                                                       SPKHookBisectReloadVisibleSettings();
                                                   }];
    summary.accessoryTextProvider = ^NSString * {
        return SPKPerfMeterSummary();
    };

    // The whole point of the scope timers: the answer is readable here, without
    // attaching a console.
    SPKSetting *worst = [SPKSetting buttonCellWithTitle:SPKL(@"HOOKBISECT_GENERAL_MOST_EXPENSIVE_HOOK_TITLE")
                                               subtitle:@""
                                                   icon:nil
                                                 action:^{
                                                     SPKPerfMeterLogSnapshot(@"worst hook");
                                                     SPKHookBisectReloadVisibleSettings();
                                                 }];
    worst.accessoryTextProvider = ^NSString * {
        return SPKPerfMeterWorstScopeSummary();
    };

    SPKSetting *reset = [SPKSetting buttonCellWithTitle:SPKL(@"HOOKBISECT_GENERAL_START_NEW_MEASUREMENT_TITLE")
                                               subtitle:@""
                                                   icon:nil
                                                 action:^{
                                                     SPKPerfMeterLogSnapshot(@"before reset");
                                                     SPKPerfMeterReset();
                                                     SPKHookBisectReloadVisibleSettings();
                                                 }];
    reset.enabledProvider = ^BOOL {
        return SPKPerfMeterIsEnabled();
    };

    SPKSetting *log = [SPKSetting buttonCellWithTitle:SPKL(@"HOOKBISECT_GENERAL_LOG_SNAPSHOT_TITLE")
                                             subtitle:@""
                                                 icon:nil
                                               action:^{
                                                   SPKPerfMeterLogSnapshot(@"manual");
                                               }];
    log.enabledProvider = ^BOOL {
        return SPKPerfMeterIsEnabled();
    };

    SPKSetting *share = [SPKSetting buttonCellWithTitle:SPKL(@"HOOKBISECT_GENERAL_SHARE_PERFORMANCE_REPORT_TITLE")
                                               subtitle:@""
                                                   icon:nil
                                                 action:^{
                                                     SPKSharePerformanceReport();
                                                 }];
    share.enabledProvider = ^BOOL {
        return SPKPerfMeterIsEnabled();
    };

    return @[ meter, hud, summary, worst, reset, log, share ];
}

@implementation SPKHookBisectSettingsProvider

+ (SPKSetting *)rootSetting {
    NSArray<NSDictionary *> *groups = SPKHookBisectRegisteredGroups();

    // Button rather than static: the live count comes from accessoryTextProvider,
    // which the table only honours for button and navigation cells. Tapping just
    // re-reads the counters.
    SPKSetting *status = [SPKSetting buttonCellWithTitle:SPKL(@"HOOKBISECT_GENERAL_SKIPPED_INSTALLERS_TITLE")
                                                subtitle:@""
                                                    icon:nil
                                                  action:^{
                                                      SPKHookBisectReloadVisibleSettings();
                                                  }];
    status.accessoryTextProvider = ^NSString * {
        return [NSString stringWithFormat:SPKL(@"COMMON_PROGRESS_FORMAT"),
                                          (unsigned long)SPKHookBisectSkippedCount(),
                                          (unsigned long)SPKHookBisectRegisteredInstallerCount()];
    };

    SPKSetting *skipHalf = [SPKSetting buttonCellWithTitle:SPKL(@"HOOKBISECT_GENERAL_SKIP_HALF_REMAINING_TITLE")
                                                  subtitle:@""
                                                      icon:nil
                                                    action:^{
                                                        NSUInteger skipped = SPKHookBisectSkipHalfOfRemaining();
                                                        SPKHookBisectReloadVisibleSettings();
                                                        if (skipped > 0)
                                                            [SPKUtils showRestartConfirmation];
                                                    }];

    SPKSetting *skipAll = [SPKSetting buttonCellWithTitle:SPKL(@"HOOKBISECT_GENERAL_SKIP_ALL_TITLE")
                                                 subtitle:@""
                                                     icon:nil
                                                   action:^{
                                                       SPKHookBisectSetAll(YES);
                                                       SPKHookBisectReloadVisibleSettings();
                                                       [SPKUtils showRestartConfirmation];
                                                   }];

    SPKSetting *restoreAll = [SPKSetting buttonCellWithTitle:SPKL(@"HOOKBISECT_GENERAL_RESTORE_ALL_TITLE")
                                                    subtitle:@""
                                                        icon:nil
                                                      action:^{
                                                          SPKHookBisectSetAll(NO);
                                                          SPKHookBisectReloadVisibleSettings();
                                                          [SPKUtils showRestartConfirmation];
                                                      }];

    // Individual switches use switchChangeHandler, which returns before the
    // table's own requiresRestart prompt, and prompting per row would fight the
    // workflow (a bisect round flips many rows at once). One explicit relaunch.
    SPKSetting *relaunch = [SPKSetting buttonCellWithTitle:SPKL(@"HOOKBISECT_GENERAL_RELAUNCH_INSTAGRAM_TITLE")
                                                  subtitle:@""
                                                      icon:nil
                                                    action:^{
                                                        [SPKUtils showRestartConfirmation];
                                                    }];

    NSMutableArray *sections = [NSMutableArray array];
    [sections addObject:SPKTopicSection(SPKL(@"HOOKBISECT_MEASUREMENT_HEADER"),
                                        SPKPerfMeterRows(),
                                        SPKL(@"SETTINGS_HOOK_BISECT_MEASURES_LONG_MAIN_THREAD_BLOCKED_WHAT_LAGGY_ACTUALLY_COUNTS_TEXT"))];
    [sections addObject:SPKTopicSection(SPKL(@"HOOKBISECT_BISECT_HEADER"),
                                        @[ status, skipHalf, skipAll, restoreAll, relaunch ],
                                        SPKL(@"SETTINGS_HOOK_BISECT_TURN_INSTALLER_OFF_KEEP_HOOKS_BEING_INSTALLED_NEXT_LAUNCH_TEXT"))];

    for (NSDictionary *group in groups) {
        NSArray<NSString *> *installers = group[@"installers"];
        NSMutableArray *rows = [NSMutableArray array];
        for (NSString *installerName in installers) {
            [rows addObject:SPKHookBisectInstallerRow(installerName)];
        }
        if (rows.count > 0)
            [sections addObject:SPKTopicSection(group[@"surface"], rows, nil)];
    }

    if (groups.count == 0) {
        [sections addObject:SPKTopicSection(@"",
                                            @[ [SPKSetting staticCellWithTitle:SPKL(@"HOOKBISECT_BISECT_NO_INSTALLERS_RECORDED_YET_TITLE")
                                                                      subtitle:SPKL(@"HOOKBISECT_BISECT_REOPEN_PAGE_MOMENT_AFTER_LAUNCH_SUBTITLE")
                                                                          icon:nil] ],
                                            nil)];
    }

    return [SPKSetting navigationCellWithTitle:SPKL(@"HOOKBISECT_BISECT_HOOK_BISECT_TITLE")
                                      subtitle:@""
                                          icon:SPKSettingsIcon(@"beaker")
                                   navSections:sections];
}

@end

#endif // SPK_DEV
