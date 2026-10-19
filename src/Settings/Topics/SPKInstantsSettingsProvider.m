#import "SPKStrings.h"
#import "SPKInstantsSettingsProvider.h"
#include <UIKit/UIKit.h>

#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../../Shared/Instants/SPKInstantsManualSeenUsers.h"
#import "../../Utils.h"
#import "../SPKPreferenceAvailability.h"
#import "../SPKSettingsViewController.h"
#import "../SPKTopicSettingsSupport.h"

static NSString *const kSPKInstantsActionButtonEnabledKey = @"instants_action_btn";

static NSArray *SPKInstantsSettingsSections(void);

@interface SPKInstantsSettingsViewController : SPKSettingsViewController
@end

@implementation SPKInstantsSettingsViewController
- (instancetype)init {
    return [super initWithTitle:SPKL(@"INSTANTS_CONFIRMATION_INSTANTS_TITLE") sections:SPKInstantsSettingsSections() reduceMargin:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self replaceSections:SPKInstantsSettingsSections()];
}

- (void)switchChanged:(UISwitch *)sender {
    SPKSetting *row = [self settingForSender:sender];
    [super switchChanged:sender];
    // The switch flips the users list between Excluded and Included, so its title and
    // help have to be rebuilt.
    if ([row.defaultsKey isEqualToString:@"instants_manual_seen"])
        [self replaceSections:SPKInstantsSettingsSections()];
}
@end

static NSString *const kSPKInstantsHideInInboxKey = @"instants_hide_in_inbox";

// With the inbox stack hidden there is no way to reach an Instant, so every other
// row on the page is locked. Values are kept, only editing is blocked, and each
// row's own enabled condition still applies once the lock lifts.
static NSArray *SPKInstantsLockSectionsWhileHidden(NSArray *sections) {
    for (NSDictionary *section in sections) {
        for (SPKSetting *row in section[@"rows"]) {
            if (![row isKindOfClass:SPKSetting.class] || [row.defaultsKey isEqualToString:kSPKInstantsHideInInboxKey])
                continue;
            BOOL (^ownEnabled)(void) = row.enabledProvider;
            row.enabledProvider = ^BOOL {
                if ([SPKUtils getBoolPref:kSPKInstantsHideInInboxKey])
                    return NO;
                return ownEnabled ? ownEnabled() : YES;
            };
        }
    }
    return sections;
}

static NSArray *SPKInstantsSettingsSections(void) {
    return SPKInstantsLockSectionsWhileHidden(@[
        SPKTopicSection(SPKL(@"INSTANTS_INBOX_HEADER"), @[
            ({
                SPKSetting *s = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INSTANTS_INBOX_HIDE_INSTANTS_TITLE")
                                                                              icon:SPKSettingsIcon(@"circle_off")
                                                                       defaultsKey:kSPKInstantsHideInInboxKey],
                                                   SPKL(@"INSTANTS_INBOX_HIDE_INSTANTS_HELP"));
                // Detaches a stack already mounted in the inbox now, rather than
                // on the inbox's next layout pass.
                s.switchChangeHandler = ^(BOOL isOn) {
                    SPKPreferenceSetObject(@(isOn), kSPKInstantsHideInInboxKey);
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"SPKInstantsHideInInboxDidChangeNotification" object:nil];
                };
                s.reloadsTableOnSwitchChange = YES;
                s;
            }),
        ],
                        nil),
        SPKTopicSection(SPKL(@"FEED_ACTION_BUTTON_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INSTANTS_ACTION_BUTTON_INSTANTS_ACTION_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(@"action")
                                    defaultsKey:kSPKInstantsActionButtonEnabledKey],
                               SPKL(@"INSTANTS_ACTION_BUTTON_ENABLED_HELP")),
            SPKActionButtonDefaultActionNavigationSetting(SPKActionButtonSourceInstants),
            SPKActionButtonConfigurationNavigationSetting(SPKActionButtonSourceInstants, SPKL(@"INSTANTS_CONFIRMATION_INSTANTS_TITLE"), SPKActionButtonSupportedActionsForSource(SPKActionButtonSourceInstants), SPKActionButtonDefaultSectionsForSource(SPKActionButtonSourceInstants))
        ],
                        nil),
        SPKTopicSection(SPKL(@"INSTANTS_PRIVACY_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INSTANTS_PRIVACY_ALLOW_SCREENSHOTS_TITLE")
                                           icon:SPKSettingsIcon(@"warning")
                                    defaultsKey:@"instants_allow_screenshot"],
                               SPKL(@"INSTANTS_PRIVACY_ALLOW_SCREENSHOTS_HELP")),
        ],
                        nil),
        SPKTopicSection(SPKL(@"INSTANTS_SEEN_RECEIPTS_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"MESSAGES_MESSAGING_MANUALLY_MARK_SEEN_TITLE")
                                           icon:SPKSettingsIcon(@"eye")
                                    defaultsKey:@"instants_manual_seen"],
                               SPKL(@"INSTANTS_SEEN_RECEIPTS_MANUALLY_MARK_SEEN_HELP")),
            ({
                SPKSetting *s = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INSTANTS_SEEN_RECEIPTS_ADVANCE_AFTER_MARK_SEEN_TITLE")
                                                                              icon:SPKSettingsIcon(@"autoscroll")
                                                                       defaultsKey:@"instants_advance_on_manual_seen"],
                                                   SPKL(@"INSTANTS_SEEN_RECEIPTS_ADVANCE_AFTER_MARK_SEEN_HELP"));
                // The eye button only exists while Manually Mark Seen applies to someone.
                s.enabledProvider = ^BOOL {
                    return SPKInstantsManualSeenAllUsersMode() || SPKInstantsManualSeenUserCount() > 0;
                };
                s;
            }),
            ({
                BOOL allUsers = SPKInstantsManualSeenAllUsersMode();
                SPKSetting *s = [SPKSetting navigationCellWithTitle:SPKInstantsManualSeenListTitle()
                                                           subtitle:@""
                                                               icon:SPKSettingsIcon(@"users")
                                                     viewController:SPKInstantsManualSeenListViewController()];
                // Flips between an exclude and an include list with the switch above.
                s.helpText = allUsers ? SPKL(@"INSTANTS_SEEN_RECEIPTS_EXCLUDED_USERS_HELP")
                                      : SPKL(@"INSTANTS_SEEN_RECEIPTS_INCLUDED_USERS_HELP");
                s.accessoryTextProvider = ^NSString * {
                    return [NSString stringWithFormat:@"%lu", (unsigned long)SPKInstantsManualSeenUserCount()];
                };
                s;
            }),
        ],
                        nil),
        SPKTopicSection(SPKL(@"INSTANTS_CREATION_HEADER"), @[
            ({
                SPKSetting *s = [SPKSetting switchCellWithTitle:SPKL(@"INSTANTS_CREATION_DISABLE_INSTANTS_CREATION_TITLE") icon:SPKSettingsIcon(@"instants") defaultsKey:@"instants_disable_creation"];
                s.switchChangeHandler = ^(BOOL isOn) {
                    SPKPreferenceSetObject(@(isOn), @"instants_disable_creation");
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"SPKQuickSnapCreationPrefChangedNotification" object:nil];
                };
                s.helpText = SPKL(@"INSTANTS_CREATION_DISABLE_CREATION_HELP");
                s;
            }),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INSTANTS_CREATION_SKIP_CAMERA_AFTER_INSTANTS_TITLE")
                                           icon:SPKSettingsIcon(@"camera")
                                    defaultsKey:@"instants_skip_camera_after_viewing"],
                               SPKL(@"INSTANTS_CREATION_SKIP_CAMERA_HELP")),
            ({
                BOOL cameraControlAvailable = SPKPrefIsAvailable(@"instants_disable_camera_control");
                SPKSetting *s = [SPKSetting switchCellWithTitle:SPKL(@"INSTANTS_CREATION_DISABLE_CAMERA_CONTROL_TITLE")
                                                       subtitle:cameraControlAvailable ? @"" : SPKL(@"SETTINGS_INSTANTS_REQUIRES_IPHONE_CAMERA_CONTROL_TEXT")
                                                           icon:SPKSettingsSystemIcon(@"button.vertical.right.press", SPKSettingsCellIconPointSize, UIImageSymbolWeightSemibold)
                                                    defaultsKey:@"instants_disable_camera_control"];
                s.helpText = SPKL(@"INSTANTS_CREATION_DISABLE_CAMERA_CONTROL_HELP");
                s;
            }),
        ],
                        nil),
        SPKTopicSection(@"", @[
            // Same glyph the button itself wears: the global "Open Menu Icon" choice.
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INSTANTS_CREATION_CAMERA_VIEW_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(SPKActionButtonOpenMenuIconName())
                                    defaultsKey:@"instants_camera_btn"],
                               SPKL(@"INSTANTS_CREATION_CAMERA_VIEW_BUTTON_HELP")),
        ],
                        nil),
        SPKTopicSection(SPKL(@"FEED_CONFIRMATION_HEADER"), @[
            ({
                SPKSetting *s = [SPKSetting switchCellWithTitle:SPKL(@"INSTANTS_CONFIRMATION_CONFIRM_INSTANT_CAPTURE_TITLE")
                                                           icon:SPKSettingsIcon(@"instants_burst")
                                                    defaultsKey:@"instants_confirm_capture"];
                s.switchChangeHandler = ^(BOOL isOn) {
                    SPKPreferenceSetObject(@(isOn), @"instants_confirm_capture");
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"SPKQuickSnapCreationPrefChangedNotification" object:nil];
                };
                s.helpText = SPKL(@"INSTANTS_CONFIRMATION_CONFIRM_CAPTURE_HELP");
                s;
            }),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INSTANTS_CONFIRMATION_CONFIRM_INSTANT_REACTION_TITLE")
                                           icon:SPKSettingsIcon(@"reactions")
                                    defaultsKey:@"instants_confirm_reaction"],
                               SPKL(@"INSTANTS_CONFIRMATION_CONFIRM_REACTION_HELP")),
        ],
                        nil),
    ]);
}

@implementation SPKInstantsSettingsProvider

+ (UIViewController *)makeSettingsViewController {
    return [[SPKInstantsSettingsViewController alloc] init];
}

+ (SPKSetting *)rootSetting {
    SPKSetting *setting = [SPKSetting navigationCellWithTitle:SPKL(@"INSTANTS_CONFIRMATION_INSTANTS_TITLE")
                                                     subtitle:@""
                                                         icon:SPKSettingsIcon(@"instants")
                                               viewController:[[SPKInstantsSettingsViewController alloc] init]];
    setting.searchSectionsProvider = ^NSArray * {
        return SPKInstantsSettingsSections();
    };
    return SPKSettingApplyIconTint(setting, [SPKUtils SPKColor_InstagramPrimaryText]);
}

@end
