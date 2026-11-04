#import "SPKStrings.h"
#import "SPKStorageUsageViewController.h"

#import "../Shared/Avatars/SPKAvatarCache.h"
#import "../Shared/SPKStoragePaths.h"
#import "../Shared/UI/SPKIGAlertPresenter.h"
#import "../Utils.h"
#import "SPKTopicSettingsSupport.h"
#import "../Shared/UI/SPKNotificationCenter.h"

@interface SPKStorageUsageViewController ()
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *breakdown;
@end

@implementation SPKStorageUsageViewController

- (instancetype)init {
    return [super initWithTitle:SPKL(@"ALERT_ACTION_STORAGE") sections:@[] reduceMargin:NO];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadStatsAndRebuild];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadStatsAndRebuild];
}

- (void)reloadStatsAndRebuild {
    self.breakdown = [SPKStoragePaths storageBreakdown];
    [self rebuildSections];
}

- (NSString *)formattedKey:(NSString *)key {
    unsigned long long bytes = [self.breakdown[key] unsignedLongLongValue];
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

- (void)rebuildSections {
    NSMutableArray *sections = [NSMutableArray array];

    [sections addObject:SPKTopicSection(SPKL(@"MESSAGES_DELETED_MESSAGES_STORAGE_OVERVIEW_HEADER"), @[
                  [SPKSetting valueCellWithTitle:SPKL(@"SETTINGS_STORAGE_USAGE_TOTAL_TITLE")
                                        subtitle:[self formattedKey:@"total"]
                                            icon:SPKSettingsIcon(@"info")],
              ],
                                        SPKL(@"SETTINGS_STORAGE_USAGE_DEVICE_STORAGE_USED_SPARKLE_DATA_INSTAGRAM_S_OWN_CACHE_FOOTER"))];

    [sections addObject:SPKTopicSection(SPKL(@"SETTINGS_STORAGE_USAGE_BREAKDOWN_HEADER"), @[
                  [SPKSetting valueCellWithTitle:SPKL(@"DATA_GENERAL_GALLERY_TITLE")
                                        subtitle:[self formattedKey:@"gallery"]
                                            icon:SPKSettingsIcon(@"sparkle_gallery")],
                  [SPKSetting valueCellWithTitle:SPKL(@"DOWNLOADS_GENERAL_DOWNLOADS_TITLE")
                                        subtitle:[self formattedKey:SPKL(@"SETTINGS_STORAGE_USAGE_DOWNLOADS_TEXT")]
                                            icon:SPKSettingsIcon(@"download")],
                  [SPKSetting valueCellWithTitle:SPKL(@"ALERT_ACTION_DELETED_MESSAGES")
                                        subtitle:[self formattedKey:@"deletedMessages"]
                                            icon:SPKSettingsIcon(@"channels")],
                  [SPKSetting valueCellWithTitle:SPKL(@"DATA_GENERAL_PROFILE_ANALYZER_TITLE")
                                        subtitle:[self formattedKey:@"profileAnalyzer"]
                                            icon:SPKSettingsIcon(@"profile_analyzer")],
                  [SPKSetting valueCellWithTitle:SPKL(@"SETTINGS_STORAGE_USAGE_PROFILE_PICTURES_TITLE")
                                        subtitle:[self formattedKey:@"avatars"]
                                            icon:SPKSettingsIcon(@"user_circle")],
                  [SPKSetting valueCellWithTitle:SPKL(@"SETTINGS_STORAGE_USAGE_FONTS_TITLE")
                                        subtitle:[self formattedKey:@"fonts"]
                                            icon:SPKSettingsIcon(@"text")],
                  [SPKSetting valueCellWithTitle:SPKL(@"SETTINGS_STORAGE_USAGE_LANGUAGE_PACKS_TITLE")
                                        subtitle:[self formattedKey:@"languages"]
                                            icon:SPKSettingsIcon(@"translate")],
              ],
                                        nil)];

    SPKSetting *clearAvatars = [SPKSetting buttonCellWithTitle:SPKL(@"SETTINGS_STORAGE_USAGE_CLEAR_CACHED_PROFILE_PICTURES_TITLE")
                                                      subtitle:nil
                                                          icon:SPKSettingsIcon(@"user_circle")
                                                        action:^{
                                                            [self confirmClearAvatars];
                                                        }];
    clearAvatars.tintColor = [SPKUtils SPKColor_InstagramDestructive];
    clearAvatars.iconTintColor = [SPKUtils SPKColor_InstagramDestructive];

    [sections addObject:SPKTopicSection(SPKL(@"SETTINGS_STORAGE_USAGE_PROFILE_PICTURES_TITLE"), @[ clearAvatars ],
                                        SPKL(@"SETTINGS_STORAGE_USAGE_PROFILE_PICTURES_SHARED_CACHE_REUSED_ACROSS_SPARKLE_CLEARING_FREES_FOOTER"))];

    [self replaceSections:sections];
}

- (void)confirmClearAvatars {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"SETTINGS_STORAGE_USAGE_CLEAR_CACHED_PROFILE_PICTURES_QUESTION")
                                                message:SPKL(@"SETTINGS_STORAGE_USAGE_REMOVES_DEVICE_PROFILE_PICTURES_THEY_RE_DOWNLOAD_NEXT_SHOWN_TEXT")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CLEAR")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  [[SPKAvatarCache shared] purge];
                                                                                  [self reloadStatsAndRebuild];
                                                                                  SPKNotify(kSPKNotificationSettingsClearCache, SPKL(@"SETTINGS_STORAGE_USAGE_PROFILE_PICTURES_CLEARED_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                              }],
                                                ]];
}

@end
