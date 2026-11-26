#import "SPKStrings.h"
#import "SPKDataSettingsProvider.h"
#import <UIKit/UIKit.h>

#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../SPKSettingsTransferManager.h"
#import "../SPKStorageUsageViewController.h"
#import "../SPKTopicSettingsSupport.h"

#pragma mark - Export / Import selection

@interface SPKSettingsTransferSelectionViewController : SPKSettingsViewController
@property (nonatomic, assign) BOOL importMode;
@property (nonatomic, assign) BOOL includeSettings;
@property (nonatomic, assign) BOOL includeGallery;
@property (nonatomic, assign) BOOL includeDeletedMessages;
@property (nonatomic, assign) BOOL includeProfileAnalyzer;
- (instancetype)initWithImportMode:(BOOL)importMode;
@end

@implementation SPKSettingsTransferSelectionViewController

- (instancetype)initWithImportMode:(BOOL)importMode {
    if ((self = [super initWithTitle:(importMode ? SPKL(@"DATA_BACKUP_TRANSFER_IMPORT_TITLE") : SPKL(@"DATA_BACKUP_TRANSFER_EXPORT_TITLE")) sections:@[] reduceMargin:NO])) {
        _importMode = importMode;
        _includeSettings = YES;
        _includeGallery = YES;
        _includeDeletedMessages = YES;
        _includeProfileAnalyzer = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupTransferActionItem];
    [self rebuildSections];
    [self updateActionEnabled];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setupTransferActionItem];
    [self updateActionEnabled];
}

- (void)setupTransferActionItem {
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[SPKAssetUtils instagramIconNamed:(self.importMode ? @"arrow_down" : @"arrow_up")]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(runTransfer)];
    self.navigationItem.rightBarButtonItem.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
}

- (void)rebuildSections {
    SPKSetting *settingsRow = [SPKSetting buttonCellWithTitle:SPKL(@"DATA_GENERAL_SETTINGS_TITLE")
                                                     subtitle:@""
                                                         icon:SPKSettingsIcon(@"settings")
                                                       action:^{
                                                           self.includeSettings = !self.includeSettings;
                                                           [self rebuildSections];
                                                           [self updateActionEnabled];
                                                       }];
    settingsRow.userInfo = @{@"checkmarked" : @(self.includeSettings)};

    SPKSetting *galleryRow = [SPKSetting buttonCellWithTitle:SPKL(@"DATA_GENERAL_GALLERY_TITLE")
                                                    subtitle:@""
                                                        icon:SPKSettingsIcon(@"sparkle_gallery")
                                                      action:^{
                                                          self.includeGallery = !self.includeGallery;
                                                          [self rebuildSections];
                                                          [self updateActionEnabled];
                                                      }];
    galleryRow.userInfo = @{@"checkmarked" : @(self.includeGallery)};

    SPKSetting *deletedMessagesRow = [SPKSetting buttonCellWithTitle:SPKL(@"ALERT_ACTION_DELETED_MESSAGES")
                                                            subtitle:@""
                                                                icon:SPKSettingsIcon(@"channels")
                                                              action:^{
                                                                  self.includeDeletedMessages = !self.includeDeletedMessages;
                                                                  [self rebuildSections];
                                                                  [self updateActionEnabled];
                                                              }];
    deletedMessagesRow.userInfo = @{@"checkmarked" : @(self.includeDeletedMessages)};

    SPKSetting *profileAnalyzerRow = [SPKSetting buttonCellWithTitle:SPKL(@"DATA_GENERAL_PROFILE_ANALYZER_TITLE")
                                                            subtitle:@""
                                                                icon:SPKSettingsIcon(@"profile_analyzer")
                                                              action:^{
                                                                  self.includeProfileAnalyzer = !self.includeProfileAnalyzer;
                                                                  [self rebuildSections];
                                                                  [self updateActionEnabled];
                                                              }];
    profileAnalyzerRow.userInfo = @{@"checkmarked" : @(self.includeProfileAnalyzer)};

    NSString *footer = self.importMode
                           ? SPKL(@"SETTINGS_DATA_PREFERENCES_RESTORED_REPLACING_CURRENT_VALUES_IMPORTED_SCOPE_GALLERY_DELETED_TEXT")
                           : nil;
    NSArray *sections = @[ SPKTopicSection(@"", @[ settingsRow, galleryRow, deletedMessagesRow, profileAnalyzerRow ], footer) ];
    [self replaceSections:sections];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    SPKSetting *row = self.sections[indexPath.section][@"rows"][indexPath.row];
    if (row.userInfo[@"checkmarked"]) {
        BOOL checked = [row.userInfo[@"checkmarked"] boolValue];
        if (checked) {
            UIImageView *checkmarkView = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"circle_check_filled"]];
            checkmarkView.tintColor = [SPKUtils SPKColor_InstagramBlue];
            cell.accessoryView = checkmarkView;
        } else {
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    }
    return cell;
}

- (void)updateActionEnabled {
    self.navigationItem.rightBarButtonItem.enabled = self.includeSettings || self.includeGallery || self.includeDeletedMessages || self.includeProfileAnalyzer;
}

- (void)runTransfer {
    if (!(self.includeSettings || self.includeGallery || self.includeDeletedMessages || self.includeProfileAnalyzer))
        return;
    UIViewController *presenter = self.navigationController ?: self;
    if (self.importMode) {
        [[SPKSettingsTransferManager sharedManager] importFromController:presenter includeSettings:self.includeSettings includeGallery:self.includeGallery includeDeletedMessages:self.includeDeletedMessages includeProfileAnalyzer:self.includeProfileAnalyzer];
    } else {
        [[SPKSettingsTransferManager sharedManager] exportFromController:presenter includeSettings:self.includeSettings includeGallery:self.includeGallery includeDeletedMessages:self.includeDeletedMessages includeProfileAnalyzer:self.includeProfileAnalyzer];
    }
}

@end

UIViewController *SPKDataGalleryExportViewController(void) {
    SPKSettingsTransferSelectionViewController *vc = [[SPKSettingsTransferSelectionViewController alloc] initWithImportMode:NO];
    vc.includeSettings = NO;
    vc.includeDeletedMessages = NO;
    vc.includeProfileAnalyzer = NO;
    return vc;
}

#pragma mark - Provider

@implementation SPKDataSettingsProvider

+ (SPKSetting *)rootSetting {
    SPKSetting *resetAllSettings = [SPKSetting buttonCellWithTitle:SPKL(@"DATA_GENERAL_RESET_ALL_SETTINGS_TITLE")
                                                          subtitle:@""
                                                              icon:SPKSettingsIcon(@"arrow_ccw")
                                                            action:^(void) {
                                                                UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject;
                                                                UIViewController *presenter = scene.windows.firstObject.rootViewController;
                                                                while (presenter.presentedViewController)
                                                                    presenter = presenter.presentedViewController;
                                                                [[SPKSettingsTransferManager sharedManager] resetAllSettingsFromController:presenter];
                                                            }];
    resetAllSettings.helpText = SPKL(@"DATA_RESET_ALL_SETTINGS_HELP");
    resetAllSettings.tintColor = [SPKUtils SPKColor_InstagramDestructive];
    resetAllSettings.iconTintColor = [SPKUtils SPKColor_InstagramDestructive];

    NSArray *sections = @[
        SPKTopicSection(SPKL(@"ALERT_ACTION_STORAGE"), @[
            [SPKSetting navigationCellWithTitle:SPKL(@"DATA_STORAGE_STORAGE_USAGE_TITLE")
                                       subtitle:@""
                                           icon:SPKSettingsIcon(@"info")
                                 viewController:[SPKStorageUsageViewController new]]
        ],
                        nil),
        SPKTopicSection(SPKL(@"DATA_BACKUP_TRANSFER_HEADER"), @[
            SPKSettingWithHelp(SPKSettingApplyIconTint([SPKSetting navigationCellWithTitle:SPKL(@"DATA_BACKUP_TRANSFER_EXPORT_TITLE")
                                                               subtitle:@""
                                                                   icon:SPKSettingsIcon(@"arrow_up")
                                                         viewController:[[SPKSettingsTransferSelectionViewController alloc] initWithImportMode:NO]],
                                    [SPKUtils SPKColor_InstagramPrimaryText]),
                               SPKL(@"DATA_BACKUP_TRANSFER_EXPORT_HELP")),
            SPKSettingWithHelp(SPKSettingApplyIconTint([SPKSetting navigationCellWithTitle:SPKL(@"DATA_BACKUP_TRANSFER_IMPORT_TITLE")
                                                               subtitle:@""
                                                                   icon:SPKSettingsIcon(@"arrow_down")
                                                         viewController:[[SPKSettingsTransferSelectionViewController alloc] initWithImportMode:YES]],
                                    [SPKUtils SPKColor_InstagramPrimaryText]),
                               SPKL(@"DATA_BACKUP_TRANSFER_IMPORT_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"ALERT_ACTION_RESET"), @[
            resetAllSettings
        ],
                        nil)
    ];

    return SPKTopicNavigationSetting(SPKL(@"DATA_TITLE"), @"cloud", 24.0, sections);
}

@end
