#import "SPKStrings.h"
#import "SPKGallerySettingsViewController.h"
#import "../../AssetUtils.h"
#import "../../Settings/SPKTopicSettingsSupport.h"
#import "../../Utils.h"
#import "../Account/SPKAccountManager.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "SPKGalleryCoreDataStack.h"
#import "SPKGalleryDeleteViewController.h"
#import "SPKGalleryFile.h"
#import "SPKGalleryGridDensity.h"
#import "SPKGalleryHiddenSources.h"
#import "SPKGalleryImportViewController.h"
#import "SPKGalleryLockViewController.h"
#import "SPKGalleryManager.h"

@interface SPKGalleryHiddenSourcesViewController : SPKSettingsViewController
@end

static SPKSetting *SPKGallerySearchChangePasscodeSetting(void) {
    SPKSetting *setting = [SPKSetting buttonCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_CHANGE_PASSCODE_TITLE")
                                                 subtitle:nil
                                                     icon:SPKSettingsIcon(@"key")
                                                   action:^{
                                                       [SPKGalleryLockViewController presentMode:SPKGalleryLockModeChangePasscode
                                                                              fromViewController:SPKSettingsTopPresenter()
                                                                                      completion:^(__unused BOOL success){
                                                                                      }];
                                                   }];
    setting.enabledProvider = ^BOOL {
        return [SPKGalleryManager sharedManager].isLockEnabled;
    };
    return setting;
}

@implementation SPKGalleryHiddenSourcesViewController

- (instancetype)init {
    return [super initWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_HIDDEN_SOURCES_TITLE") sections:@[] reduceMargin:NO];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self rebuildSections];
}

- (void)rebuildSections {
    NSMutableArray<SPKSetting *> *rows = [NSMutableArray array];
    NSArray<NSNumber *> *sources = @[
        @(SPKGallerySourceFeed),
        @(SPKGallerySourceStories),
        @(SPKGallerySourceReels),
        @(SPKGallerySourceProfile),
        @(SPKGallerySourceDMs),
        @(SPKGallerySourceThumbnail),
        @(SPKGallerySourceInstants),
        @(SPKGallerySourceAudioPage),
        @(SPKGallerySourceComments),
        @(SPKGallerySourceOther),
    ];
    for (NSNumber *sourceValue in sources) {
        SPKGallerySource source = (SPKGallerySource)sourceValue.integerValue;
        SPKSetting *row = [SPKSetting switchCellWithTitle:[SPKGalleryFile labelForSource:source]
                                                     icon:SPKSettingsIcon([SPKGalleryFile symbolNameForSource:source])
                                              defaultsKey:@""];
        row.switchValueProvider = ^BOOL {
            return SPKGallerySourceIsHidden(source);
        };
        row.switchChangeHandler = ^(BOOL hidden) {
            SPKGallerySetSourceHidden(source, hidden);
        };
        [rows addObject:row];
    }
    // The note is about the list as a whole, so it stays a footer: repeated once
    // per source in an info sheet it would say the same thing eight times.
    [self replaceSections:@[ SPKTopicSection(SPKL(@"GALLERY_GALLERY_SETTINGS_SOURCES_HEADER"), rows, SPKL(@"GALLERY_SOURCES_HIDE_SOURCE_HELP")) ]];
}

@end

static NSString *const kFavoritesAtTopKey = @"gallery_show_favorites_top";
static NSString *const kGalleryLongPressTabKey = @"gallery_quick_access_tab";
static NSString *const kGalleryQuickAccessDisabledValue = @"none";

@interface SPKGalleryStorageStats : NSObject
@property (nonatomic, assign) NSInteger totalFiles;
@property (nonatomic, assign) NSInteger imageCount;
@property (nonatomic, assign) NSInteger videoCount;
@property (nonatomic, assign) NSInteger audioCount;
@property (nonatomic, assign) long long totalSize;
@end

@implementation SPKGalleryStorageStats
@end

@interface SPKGallerySettingsViewController ()
@property (nonatomic, strong) SPKGalleryStorageStats *stats;
@end

@implementation SPKGallerySettingsViewController

+ (NSArray *)searchSections {
    return @[
        SPKTopicSection(SPKL(@"ALERT_ACTION_STORAGE"), @[
            [SPKSetting valueCellWithTitle:SPKL(@"SETTINGS_STORAGE_USAGE_TOTAL_TITLE")
                                  subtitle:SPKL(@"GALLERY_GALLERY_SETTINGS_GALLERY_STORAGE_FILE_COUNT_SUBTITLE")
                                      icon:SPKSettingsIcon(@"info")],
            [SPKSetting valueCellWithTitle:SPKL(@"GALLERY_GALLERY_FILTER_IMAGES_TITLE")
                                  subtitle:SPKL(@"GALLERY_GALLERY_SETTINGS_SAVED_IMAGE_COUNT_SUBTITLE")
                                      icon:SPKSettingsIcon(@"photo")],
            [SPKSetting valueCellWithTitle:SPKL(@"GALLERY_GALLERY_FILTER_VIDEOS_TITLE")
                                  subtitle:SPKL(@"GALLERY_GALLERY_SETTINGS_SAVED_VIDEO_COUNT_SUBTITLE")
                                      icon:SPKSettingsIcon(@"video")],
            [SPKSetting valueCellWithTitle:SPKL(@"MESSAGES_DIRECT_MESSAGE_MENU_AUDIO_TITLE")
                                  subtitle:SPKL(@"GALLERY_GALLERY_SETTINGS_SAVED_AUDIO_COUNT_SUBTITLE")
                                      icon:SPKSettingsIcon(@"audio")]
        ],
                        nil),
        SPKTopicSection(SPKL(@"GALLERY_GALLERY_SETTINGS_BROWSING_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_SHOW_FAVORITES_TOP_TITLE")
                                           icon:SPKSettingsIcon(@"heart")
                                    defaultsKey:kFavoritesAtTopKey],
                               SPKL(@"GALLERY_BROWSING_SHOW_FAVORITES_TOP_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_SHOW_FILES_SUBFOLDERS_TITLE")
                                           icon:SPKSettingsIcon(@"folder")
                                    defaultsKey:kSPKGalleryFlatBrowsingKey],
                               SPKL(@"GALLERY_BROWSING_SHOW_FILES_SUBFOLDERS_HELP")),
            SPKSettingWithHelp([SPKSetting navigationCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_HIDDEN_SOURCES_TITLE")
                                           subtitle:@""
                                               icon:SPKSettingsIcon(@"eye_off")
                                     viewController:[SPKGalleryHiddenSourcesViewController new]],
                               SPKL(@"GALLERY_VISIBILITY_HIDDEN_SOURCES_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"GALLERY_GALLERY_SETTINGS_EDITING_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_ASK_REPLACE_ORIGINAL_TITLE")
                                           icon:SPKSettingsIcon(@"left_right")
                                    defaultsKey:@"trim_gallery_prompt_replace"],
                               SPKL(@"GALLERY_EDITING_ASK_REPLACE_ORIGINAL_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"NOTIFICATION_PREVIEW_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_MEDIA_PREVIEW_MENU_SHOW_MEDIA_INFO_TITLE")
                                           icon:SPKSettingsIcon(@"info")
                                    defaultsKey:@"gallery_preview_show_metadata"],
                               SPKL(@"GALLERY_PREVIEW_SHOW_MEDIA_INFO_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"GALLERY_GALLERY_SETTINGS_LOCK_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_GALLERY_PASSCODE_LOCK_TITLE")
                                           icon:SPKSettingsIcon(@"lock")
                                    defaultsKey:@""],
                               SPKL(@"GALLERY_LOCK_PASSCODE_HELP")),
            // Settings search runs this row's action on tap, so it has to do the real thing.
            SPKGallerySearchChangePasscodeSetting()
        ],
                        nil),
        SPKTopicSection(SPKL(@"DATA_BACKUP_TRANSFER_IMPORT_TITLE"), @[
            // A navigation row, not a button: this mirror feeds the settings search index, and a
            // button row's action is what search runs on tap — an empty one silently does nothing.
            // The framework pushes navViewController itself, so the result is actually reachable.
            // No folder context from search, so it imports to the gallery root (nil).
            SPKSettingWithHelp([SPKSetting navigationCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_IMPORT_MEDIA_TITLE")
                                           subtitle:nil
                                               icon:SPKSettingsIcon(@"media")
                                     viewController:[[SPKGalleryImportViewController alloc] initWithDestinationFolderPath:nil]],
                               SPKL(@"GALLERY_IMPORT_MEDIA_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"ALERT_ACTION_DELETE"), @[
            SPKSettingWithHelp([SPKSetting buttonCellWithTitle:SPKL(@"GALLERY_GALLERY_DELETE_DELETE_FILES_TITLE")
                                       subtitle:nil
                                           icon:SPKSettingsIcon(@"trash")
                                         action:^{
                                         }],
                               SPKL(@"GALLERY_DELETE_FILES_HELP"))
        ],
                        nil)
    ];
}

- (instancetype)init {
    return [super initWithTitle:SPKL(@"GALLERY_GENERAL_GALLERY_SETTINGS_TITLE") sections:@[] reduceMargin:NO];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadStats];
    [self rebuildSections];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadStats];
    [self rebuildSections];
}

- (void)reloadStats {
    NSManagedObjectContext *ctx = [SPKGalleryCoreDataStack shared].viewContext;
    NSFetchRequest *req = [[NSFetchRequest alloc] initWithEntityName:@"SPKGalleryFile"];
    NSArray<SPKGalleryFile *> *files = [ctx executeFetchRequest:req error:nil] ?: @[];

    SPKGalleryStorageStats *stats = [SPKGalleryStorageStats new];
    for (SPKGalleryFile *file in files) {
        stats.totalFiles += 1;
        stats.totalSize += file.fileSize;
        if (file.mediaType == SPKGalleryMediaTypeAudio) {
            stats.audioCount += 1;
        } else if (file.mediaType == SPKGalleryMediaTypeVideo) {
            stats.videoCount += 1;
        } else {
            stats.imageCount += 1;
        }
    }
    self.stats = stats;
}

- (NSString *)formattedSize:(long long)bytes {
    return [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile];
}

- (void)rebuildSections {
    NSMutableArray *sections = [NSMutableArray array];

    [sections addObject:SPKTopicSection(SPKL(@"ALERT_ACTION_STORAGE"), @[
                  [SPKSetting valueCellWithTitle:SPKL(@"SETTINGS_STORAGE_USAGE_TOTAL_TITLE")
                                        subtitle:[NSString stringWithFormat:SPKL(@"GALLERY_GALLERY_SETTINGS_VALUE_FILES_VALUE_FORMAT"), (long)self.stats.totalFiles, [self formattedSize:self.stats.totalSize]]
                                            icon:SPKSettingsIcon(@"info")],
                  [SPKSetting valueCellWithTitle:SPKL(@"GALLERY_GALLERY_FILTER_IMAGES_TITLE")
                                        subtitle:[NSString stringWithFormat:@"%ld", (long)self.stats.imageCount]
                                            icon:SPKSettingsIcon(@"photo")],
                  [SPKSetting valueCellWithTitle:SPKL(@"GALLERY_GALLERY_FILTER_VIDEOS_TITLE")
                                        subtitle:[NSString stringWithFormat:@"%ld", (long)self.stats.videoCount]
                                            icon:SPKSettingsIcon(@"video")],
                  [SPKSetting valueCellWithTitle:SPKL(@"MESSAGES_DIRECT_MESSAGE_MENU_AUDIO_TITLE")
                                        subtitle:[NSString stringWithFormat:@"%ld", (long)self.stats.audioCount]
                                            icon:SPKSettingsIcon(@"audio")]
              ],
                                        nil)];

    SPKSetting *favoritesRow = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_SHOW_FAVORITES_TOP_TITLE") icon:SPKSettingsIcon(@"heart") defaultsKey:kFavoritesAtTopKey],
                                                  SPKL(@"GALLERY_BROWSING_SHOW_FAVORITES_TOP_HELP"));
    favoritesRow.action = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SPKGalleryFavoritesSortPreferenceChanged" object:nil];
    };
    // Defaults ON; the backing pref stores the *disabled* state, so the switch inverts.
    SPKSetting *pinFolderRow = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_PIN_FOLDER_BAR_TITLE") icon:SPKSettingsIcon(@"pin") defaultsKey:@""],
                                                  SPKL(@"GALLERY_BROWSING_PIN_FOLDER_BAR_HELP"));
    pinFolderRow.switchValueProvider = ^BOOL {
        return ![[NSUserDefaults standardUserDefaults] boolForKey:kSPKGalleryFolderBarPinDisabledKey];
    };
    pinFolderRow.switchChangeHandler = ^(BOOL isOn) {
        [[NSUserDefaults standardUserDefaults] setBool:!isOn forKey:kSPKGalleryFolderBarPinDisabledKey];
        [[NSNotificationCenter defaultCenter] postNotificationName:kSPKGalleryGridControlsChangedNotification object:nil];
    };
    SPKSetting *flatBrowsingRow = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_SHOW_FILES_SUBFOLDERS_TITLE") icon:SPKSettingsIcon(@"folder") defaultsKey:kSPKGalleryFlatBrowsingKey],
                                                     SPKL(@"GALLERY_BROWSING_SHOW_FILES_SUBFOLDERS_HELP"));
    flatBrowsingRow.action = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kSPKGalleryBrowsingScopeChangedNotification object:nil];
    };
    [sections addObject:SPKTopicSection(SPKL(@"GALLERY_GALLERY_SETTINGS_BROWSING_HEADER"), @[favoritesRow, pinFolderRow, flatBrowsingRow],
                                        nil)];

    [sections addObject:SPKTopicSection(SPKL(@"GALLERY_GALLERY_SETTINGS_EDITING_HEADER"), @[
                  SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_ASK_REPLACE_ORIGINAL_TITLE")
                                                 icon:SPKSettingsIcon(@"left_right")
                                          defaultsKey:@"trim_gallery_prompt_replace"],
                                     SPKL(@"GALLERY_EDITING_ASK_REPLACE_ORIGINAL_HELP"))
              ],
                                        nil)];

    SPKSetting *accountFilterRow = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_ACCOUNT_ONLY_TITLE") icon:SPKSettingsIcon(@"user_circle") defaultsKey:@"gallery_filter_current_account"],
                                                      SPKL(@"GALLERY_VISIBILITY_ACCOUNT_ONLY_HELP"));
    __weak typeof(self) weakAccountSelf = self;
    accountFilterRow.action = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SPKGalleryHiddenSourcesDidChangeNotification object:nil];
        if ([SPKUtils getBoolPref:@"gallery_filter_current_account"]) {
            [weakAccountSelf promptClaimUnassignedFiles];
        }
    };
    [sections addObject:SPKTopicSection(SPKL(@"GALLERY_GALLERY_SETTINGS_VISIBILITY_HEADER"), @[
                  accountFilterRow,
                  SPKSettingWithHelp([SPKSetting navigationCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_HIDDEN_SOURCES_TITLE")
                                                 subtitle:@""
                                                     icon:SPKSettingsIcon(@"eye_off")
                                           viewController:[SPKGalleryHiddenSourcesViewController new]],
                                     SPKL(@"GALLERY_VISIBILITY_HIDDEN_SOURCES_HELP"))
              ],
                                        nil)];

    // Grid section: pinch-to-zoom toggle. Defaults ON; the backing pref stores
    // the *disabled* state, so the switch inverts.
    SPKSetting *pinchRow = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_PINCH_ZOOM_TITLE") icon:SPKSettingsIcon(@"pinch") defaultsKey:@""],
                                              SPKL(@"GALLERY_GRID_PINCH_ZOOM_HELP"));
    pinchRow.switchValueProvider = ^BOOL {
        return ![[NSUserDefaults standardUserDefaults] boolForKey:kSPKGalleryGridPinchDisabledKey];
    };
    pinchRow.switchChangeHandler = ^(BOOL isOn) {
        [[NSUserDefaults standardUserDefaults] setBool:!isOn forKey:kSPKGalleryGridPinchDisabledKey];
        [[NSNotificationCenter defaultCenter] postNotificationName:kSPKGalleryGridControlsChangedNotification object:nil];
    };

    SPKSetting *sourceUsernameRow = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_SHOW_SOURCE_USERNAME_TITLE") icon:SPKSettingsIcon(@"user_circle") defaultsKey:@""],
                                                       SPKL(@"GALLERY_GRID_SOURCE_USERNAME_HELP"));
    sourceUsernameRow.switchValueProvider = ^BOOL {
        return ![[NSUserDefaults standardUserDefaults] boolForKey:kSPKGalleryGridShowSourceUsernameDisabledKey];
    };
    sourceUsernameRow.switchChangeHandler = ^(BOOL isOn) {
        [[NSUserDefaults standardUserDefaults] setBool:!isOn forKey:kSPKGalleryGridShowSourceUsernameDisabledKey];
        [[NSNotificationCenter defaultCenter] postNotificationName:kSPKGalleryGridControlsChangedNotification object:nil];
    };

    [sections addObject:SPKTopicSection(SPKL(@"GALLERY_GALLERY_SETTINGS_GRID_HEADER"), @[ pinchRow, sourceUsernameRow ],
                                        nil)];

    [sections addObject:SPKTopicSection(SPKL(@"NOTIFICATION_PREVIEW_HEADER"), @[
                  SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GENERAL_MEDIA_PREVIEW_MENU_SHOW_MEDIA_INFO_TITLE")
                                                 icon:SPKSettingsIcon(@"info")
                                          defaultsKey:@"gallery_preview_show_metadata"],
                                     SPKL(@"GALLERY_PREVIEW_SHOW_MEDIA_INFO_HELP"))
              ],
                                        nil)];

    NSMutableArray *lockRows = [NSMutableArray array];

    __weak typeof(self) weakSelf = self;
    SPKSetting *lockSwitch = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_GALLERY_PASSCODE_LOCK_TITLE") icon:SPKSettingsIcon(@"lock") defaultsKey:@""],
                                                SPKL(@"GALLERY_LOCK_PASSCODE_HELP"));
    lockSwitch.switchValueProvider = ^BOOL {
        return [SPKGalleryManager sharedManager].isLockEnabled;
    };
    lockSwitch.switchChangeHandler = ^(BOOL isOn) {
        [weakSelf handleLockToggleEnabled:isOn];
    };
    [lockRows addObject:lockSwitch];

    SPKSetting *changePasscode = [SPKSetting buttonCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_CHANGE_PASSCODE_TITLE")
                                                            subtitle:nil
                                                                icon:SPKSettingsIcon(@"key")
                                                              action:^{
                                                                  [SPKGalleryLockViewController presentMode:SPKGalleryLockModeChangePasscode
                                                                                         fromViewController:self
                                                                                                 completion:^(BOOL success){
                                                                                                 }];
                                                              }];
    changePasscode.enabledProvider = ^BOOL {
        return [SPKGalleryManager sharedManager].isLockEnabled;
    };
    [lockRows addObject:changePasscode];

    [sections addObject:SPKTopicSection(SPKL(@"GALLERY_GALLERY_SETTINGS_LOCK_HEADER"), lockRows, nil)];

    SPKSetting *importRow = SPKSettingWithHelp([SPKSetting buttonCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_IMPORT_MEDIA_TITLE")
                                                       subtitle:nil
                                                           icon:SPKSettingsIcon(@"media")
                                                         action:^{
                                                             SPKGalleryImportViewController *vc = [[SPKGalleryImportViewController alloc] initWithDestinationFolderPath:self.importDestinationFolderPath];
                                                             [self.navigationController pushViewController:vc animated:YES];
                                                         }],
                                               SPKL(@"GALLERY_IMPORT_MEDIA_HELP"));
    [sections addObject:SPKTopicSection(SPKL(@"DATA_BACKUP_TRANSFER_IMPORT_TITLE"), @[ importRow ],
                                        nil)];

    SPKSetting *deleteRow = SPKSettingWithHelp([SPKSetting buttonCellWithTitle:SPKL(@"GALLERY_GALLERY_DELETE_DELETE_FILES_TITLE")
                                                       subtitle:nil
                                                           icon:SPKSettingsIcon(@"trash")
                                                         action:^{
                                                             SPKGalleryDeleteViewController *vc = [[SPKGalleryDeleteViewController alloc] initWithMode:SPKGalleryDeletePageModeRoot];
                                                             __weak typeof(self) weakSelf = self;
                                                             vc.onDidDelete = ^{
                                                                 [weakSelf reloadStats];
                                                                 [weakSelf rebuildSections];
                                                                 [[NSNotificationCenter defaultCenter] postNotificationName:@"SPKGalleryFavoritesSortPreferenceChanged" object:nil];
                                                             };
                                                             [self.navigationController pushViewController:vc animated:YES];
                                                         }],
                                               SPKL(@"GALLERY_DELETE_FILES_HELP"));
    deleteRow.tintColor = [SPKUtils SPKColor_InstagramDestructive];
    deleteRow.iconTintColor = [SPKUtils SPKColor_InstagramDestructive];

    [sections addObject:SPKTopicSection(SPKL(@"ALERT_ACTION_DELETE"), @[ deleteRow ], nil)];

    [self replaceSections:sections];
}

- (void)promptClaimUnassignedFiles {
    NSString *pk = [SPKAccountManager currentAccountPK];
    if (pk.length == 0)
        return;
    NSUInteger count = [SPKGalleryFile unassignedFileCount];
    if (count == 0)
        return;

    NSString *username = [SPKAccountManager currentAccountUsername];
    NSString *who = username.length > 0 ? [@"@" stringByAppendingString:username] : SPKL(@"GALLERY_GALLERY_SETTINGS_ACCOUNT_TEXT");
    NSString *message = [NSString stringWithFormat:SPKL(@"GALLERY_SETTINGS_ASSIGN_UNASSIGNED_FILES_FORMAT"),
                                                   SPKLP(@"COMMON_FILE_COUNT", (NSInteger)count), who];

    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"GALLERY_GALLERY_SETTINGS_CLAIM_EXISTING_FILES_QUESTION")
                                                message:message
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_NOT_NOW")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:nil],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_ASSIGN")
                                                                                style:SPKIGAlertActionStyleDefault
                                                                              handler:^{
                                                                                  [SPKGalleryFile claimUnassignedFilesForAccountPK:pk username:username];
                                                                                  [[NSNotificationCenter defaultCenter] postNotificationName:SPKGalleryHiddenSourcesDidChangeNotification object:nil];
                                                                              }]
                                                ]];
}

- (void)handleLockToggleEnabled:(BOOL)enabled {
    SPKGalleryManager *mgr = [SPKGalleryManager sharedManager];
    if (enabled && !mgr.isLockEnabled) {
        __weak typeof(self) weakSelf = self;
        [SPKGalleryLockViewController presentMode:SPKGalleryLockModeSetPasscode
                               fromViewController:self
                                       completion:^(BOOL success) {
                                           [weakSelf rebuildSections];
                                       }];
        return;
    }

    if (enabled && mgr.isLockEnabled) {
        [self rebuildSections];
        return;
    }

    if (!enabled && !mgr.isLockEnabled) {
        [self rebuildSections];
        return;
    }

    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"GALLERY_GALLERY_SETTINGS_DISABLE_PASSCODE_TEXT")
                                                message:SPKL(@"GALLERY_GALLERY_SETTINGS_GALLERY_NO_LONGER_REQUIRE_AUTHENTICATION_OPEN_TEXT")
                                                actions:@[
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                style:SPKIGAlertActionStyleCancel
                                                                              handler:^{
                                                                                  [self rebuildSections];
                                                                              }],
                                                    [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_DISABLE")
                                                                                style:SPKIGAlertActionStyleDestructive
                                                                              handler:^{
                                                                                  [mgr removePasscode];
                                                                                  [self rebuildSections];
                                                                              }],
                                                ]];
}

@end
