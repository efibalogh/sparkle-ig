#import "SPKStrings.h"
#import "SPKNotificationSettingsProvider.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Utils.h"
#import "../SPKPreferenceAvailability.h"
#import "../SPKTopicSettingsSupport.h"

@implementation SPKNotificationSettingsProvider

+ (NSArray<NSDictionary *> *)spk_featureSectionsForHaptics:(BOOL)haptics {
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];

    for (NSDictionary *sectionInfo in SPKNotificationPreferenceSections()) {
        NSMutableArray<SPKSetting *> *rows = [NSMutableArray array];
        for (NSDictionary *item in sectionInfo[@"items"] ?: @[]) {
            NSString *identifier = item[@"identifier"];
            NSString *title = item[@"title"] ?: SPKL(@"SETTINGS_NOTIFICATION_FEATURE_TEXT");
            NSString *iconName = item[@"iconName"] ?: @"info";
            SPKSetting *setting = [SPKSetting switchCellWithTitle:title
                                                         subtitle:@""
                                                             icon:SPKSettingsIcon(iconName)
                                                      defaultsKey:haptics ? SPKNotificationHapticDefaultsKey(identifier) : SPKNotificationDefaultsKey(identifier)];
            setting.userInfo = @{@"defaultValue" : @YES};
            [rows addObject:setting];
        }

        NSString *sectionTitle = sectionInfo[@"title"] ?: @"";
        [sections addObject:SPKTopicSection(sectionTitle, [rows copy], nil)];
    }

    return [sections copy];
}

+ (void)spk_showNextNotificationPreview {
    static NSUInteger toneIndex = 0;

    NSArray<NSDictionary *> *configs = @[
        @{
            @"title" : SPKL(@"SETTINGS_NOTIFICATION_SAVED_GALLERY_TEXT"),
            @"subtitle" : SPKL(@"SETTINGS_NOTIFICATION_NOTIFICATION_PREVIEW_SUCCESS_TONE_TEXT"),
            @"iconResource" : @"circle_check_filled",
            @"tone" : @(SPKNotificationToneSuccess)
        },
        @{
            @"title" : SPKL(@"SETTINGS_NOTIFICATION_SOMETHING_WENT_WRONG_TEXT"),
            @"subtitle" : SPKL(@"SETTINGS_NOTIFICATION_NOTIFICATION_PREVIEW_ERROR_TONE_TEXT"),
            @"iconResource" : @"error_filled",
            @"tone" : @(SPKNotificationToneError)
        },
        @{
            @"title" : SPKL(@"SETTINGS_NOTIFICATION_HEADS_UP_TEXT"),
            @"subtitle" : SPKL(@"SETTINGS_NOTIFICATION_NOTIFICATION_PREVIEW_INFO_TONE_TEXT"),
            @"iconResource" : @"info_filled",
            @"tone" : @(SPKNotificationToneInfo)
        }
    ];

    NSDictionary *config = configs[toneIndex % configs.count];
    toneIndex++;

    SPKNotify(kSPKNotificationSettingsClearCache,
              config[@"title"],
              config[@"subtitle"],
              config[@"iconResource"],
              [config[@"tone"] unsignedIntegerValue]);
}

+ (NSArray *)sections {
    BOOL (^instagramStyle)(void) = ^BOOL {
        return SPKNotificationUsesInstagramStyle();
    };

    SPKSetting *style = SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"NOTIFICATION_APPEARANCE_STYLE_TITLE")
                                                                subtitle:@""
                                                                    menu:SPKNotificationStyleMenu()],
                                           SPKL(@"NOTIFICATION_APPEARANCE_STYLE_HELP"));
    SPKSetting *example = [SPKSetting buttonCellWithTitle:SPKL(@"NOTIFICATION_PREVIEW_TEST_NOTIFICATION_TITLE")
                                                 subtitle:@""
                                                     icon:nil
                                                   action:^{
                                                       [self spk_showNextNotificationPreview];
                                                   }];

    // Glow and Tint by Result are one preference: the pill shows the result's colour
    // as a glow, the Instagram toast as a tint, so each style names it for what it does.
    SPKSetting *glow = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"NOTIFICATION_APPEARANCE_GLOW_TITLE")
                                                                 subtitle:@""
                                                              defaultsKey:kSPKNotificationPillGlowEnabledKey],
                                          SPKL(@"NOTIFICATION_APPEARANCE_GLOW_HELP"));
    glow.hiddenProvider = instagramStyle;
    SPKSetting *tint = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"NOTIFICATION_APPEARANCE_TINT_TITLE")
                                                                 subtitle:@""
                                                              defaultsKey:kSPKNotificationPillGlowEnabledKey],
                                          SPKL(@"NOTIFICATION_APPEARANCE_TINT_HELP"));
    tint.hiddenProvider = ^BOOL {
        return !instagramStyle();
    };
    SPKSetting *liquidGlass = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"INTERFACE_CAPTURE_LIQUID_GLASS_TITLE")
                                                                        subtitle:@""
                                                                     defaultsKey:kSPKNotificationPillLiquidGlassEnabledKey],
                                                 SPKL(@"NOTIFICATION_APPEARANCE_LIQUID_GLASS_HELP"));
    liquidGlass.hiddenProvider = ^BOOL {
        return instagramStyle() || !SPKPrefIsAvailable(kSPKNotificationPillLiquidGlassEnabledKey);
    };

    SPKSetting *progress = SPKSettingWithHelp([SPKSetting menuCellWithTitle:SPKL(@"NOTIFICATION_APPEARANCE_DOWNLOAD_PROGRESS_TITLE")
                                                                   subtitle:@""
                                                                       menu:SPKNotificationProgressSubtitleStyleMenu()],
                                              SPKL(@"NOTIFICATION_APPEARANCE_DOWNLOAD_PROGRESS_HELP"));

    return @[
        SPKTopicSection(SPKL(@"NOTIFICATION_STYLE_HEADER"), @[ style, example ], nil),
        SPKTopicSection(SPKL(@"NOTIFICATION_APPEARANCE_HEADER"), @[ glow, tint, liquidGlass ], nil),
        SPKTopicSection(SPKL(@"NOTIFICATION_BEHAVIOR_HEADER"), @[
            [SPKSetting menuCellWithTitle:SPKL(@"NOTIFICATION_APPEARANCE_POSITION_TITLE")
                                 subtitle:@""
                                     menu:SPKNotificationPillPositionMenu()],
            [SPKSetting stepperCellWithTitle:SPKL(@"NOTIFICATION_APPEARANCE_DURATION_TITLE")
                                    subtitle:SPKL(@"NOTIFICATION_APPEARANCE_DISMISS_AFTER_SUBTITLE")
                                 defaultsKey:kSPKNotificationPillDurationKey
                                         min:0.5
                                         max:5.0
                                        step:0.25
                                       label:SPKL(@"NOTIFICATION_APPEARANCE_DURATION_UNIT")
                               singularLabel:@" second"],
            progress
        ],
                        nil),
        SPKTopicSection(@"", @[
            [SPKSetting navigationCellWithTitle:SPKL(@"NOTIFICATION_CATEGORIES_TITLE")
                                       subtitle:@""
                                           icon:SPKSettingsIcon(@"notification")
                                    navSections:[self spk_featureSectionsForHaptics:NO]],
            [SPKSetting navigationCellWithTitle:SPKL(@"NOTIFICATION_PREVIEW_HAPTICS_TITLE")
                                       subtitle:@""
                                           icon:SPKSettingsIcon(@"haptics")
                                    navSections:[self spk_featureSectionsForHaptics:YES]]
        ],
                        nil)
    ];
}

@end
