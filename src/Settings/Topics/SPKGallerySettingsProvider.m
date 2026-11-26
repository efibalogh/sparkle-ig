#import "SPKStrings.h"
#import "SPKGallerySettingsProvider.h"
#import "../SPKNewBadges.h"
#import "../SPKSetting.h"
#import "../SPKTopicSettingsSupport.h"
#import "SPKDataSettingsProvider.h"

#import "../../Shared/AutoSave/SPKAutoSave.h"
#import "../../Shared/AutoSave/SPKAutoSaveSettingsViewController.h"
#import "../../Shared/Gallery/SPKGalleryFile.h"
#import "../../Shared/Gallery/SPKGalleryImportViewController.h"
#import "../../Shared/Gallery/SPKGalleryManager.h"
#import "../../Shared/Gallery/SPKGallerySettingsViewController.h"
#import "../../Shared/Gallery/SPKGalleryViewController.h"
#import "../../Shared/Instants/SPKInstantsAutoSave.h"
#import "../../Shared/Messages/SPKDirectAutoSave.h"
#import "../../Shared/Stories/SPKStoryAutoSave.h"
#import "../../Utils.h"

// The page is a generic settings page that reloads its table each time it appears,
// so every live value below is a provider read at cell configuration: the rows
// refresh in place with no section rebuild.

// Shown even while the Gallery is locked: the lock relocks on every exit, so hiding
// them would hide them for good, and Gallery Settings shows the same counts anyway.
static NSString *SPKGalleryHomeStatsSubtitle(void) {
    SPKGalleryStorageStats *stats = [SPKGalleryStorageStats currentStats];
    return [NSString stringWithFormat:SPKL(@"GALLERY_HOME_STATS_SUBTITLE_FORMAT"),
                                      SPKLP(@"COMMON_FILE_COUNT", stats.totalFiles),
                                      [NSByteCountFormatter stringFromByteCount:stats.totalSize countStyle:NSByteCountFormatterCountStyleFile]];
}

// Which surfaces auto-save, named as the Auto-Save page names them. Read through the
// surfaces' own filter configs, so per-account values resolve like everywhere else.
static NSString *SPKGalleryHomeAutoSaveValue(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (SPKAutoSaveFilterEnabled(SPKStoryAutoSaveFilterConfig()))
        [names addObject:SPKL(@"STORIES_OTHER_STORIES_TITLE")];
    if (SPKAutoSaveFilterEnabled(SPKDirectAutoSaveFilterConfig()))
        [names addObject:SPKL(@"MESSAGES_CONFIRMATION_MESSAGES_TITLE")];
    if (SPKAutoSaveFilterEnabled(SPKInstantsAutoSaveFilterConfig()))
        [names addObject:SPKL(@"INSTANTS_CONFIRMATION_INSTANTS_TITLE")];

    if (names.count == 0)
        return SPKL(@"MENU_OFF");
    // Listing surfaces on a Gallery page would claim they fill the Gallery.
    if (SPKAutoSaveDestination() == SPKDownloadDestinationPhotos)
        return SPKL(@"GALLERY_HOME_AUTO_SAVE_PHOTOS_VALUE");
    if (names.count == 1)
        return names[0];
    if (names.count == 2)
        return [NSString stringWithFormat:SPKL(@"GALLERY_HOME_AUTO_SAVE_TWO_SURFACES_FORMAT"), names[0], names[1]];
    return [NSString stringWithFormat:SPKL(@"GALLERY_HOME_AUTO_SAVE_THREE_SURFACES_FORMAT"), names[0], names[1], names[2]];
}

@implementation SPKGallerySettingsProvider

+ (SPKSetting *)rootSetting {
    SPKSetting *openGallery = [SPKSetting buttonCellWithTitle:SPKL(@"ALERT_ACTION_OPEN_GALLERY")
                                                     subtitle:@""
                                                         icon:SPKSettingsIcon(@"sparkle_gallery")
                                                       action:^(void) {
                                                           [SPKGalleryViewController presentGallery];
                                                       }];
    openGallery.subtitleProvider = ^NSString * {
        return SPKGalleryHomeStatsSubtitle();
    };
    openGallery.iconProvider = ^UIImage * {
        return SPKSettingsIcon([SPKGalleryManager sharedManager].isLockEnabled ? @"lock" : @"sparkle_gallery");
    };

    // Opens the existing Auto-Save page rather than mirroring it: nothing is
    // duplicated, and its settings stay indexed for search under Downloads only.
    SPKSetting *autoSave = [SPKSetting navigationCellWithTitle:SPKL(@"GALLERY_HOME_AUTO_SAVE_TITLE")
                                                      subtitle:@""
                                                          icon:SPKSettingsIcon(@"download")
                                                viewController:[SPKAutoSaveSettingsViewController new]];
    autoSave.accessoryTextProvider = ^NSString * {
        return SPKGalleryHomeAutoSaveValue();
    };
    SPKSettingMarkedNewWithID(autoSave, @"v1.7.0", @"gallery_home_auto_save");

    // A navigation row, so a settings search hit opens it. No folder context here,
    // so it imports to the Gallery root.
    SPKSetting *import = SPKSettingWithHelp([SPKSetting navigationCellWithTitle:SPKL(@"GALLERY_GALLERY_SETTINGS_IMPORT_MEDIA_TITLE")
                                                                       subtitle:@""
                                                                           icon:SPKSettingsIcon(@"media")
                                                                 viewController:[[SPKGalleryImportViewController alloc] initWithDestinationFolderPath:nil]],
                                            SPKL(@"GALLERY_IMPORT_MEDIA_HELP"));

    SPKSetting *backUp = SPKSettingWithHelp([SPKSetting navigationCellWithTitle:SPKL(@"GALLERY_HOME_BACK_UP_TITLE")
                                                                       subtitle:@""
                                                                           icon:SPKSettingsIcon(@"cloud")
                                                                 viewController:SPKDataGalleryExportViewController()],
                                            SPKL(@"GALLERY_HOME_BACK_UP_HELP"));
    SPKSettingMarkedNewWithID(backUp, @"v1.7.0", @"gallery_home_back_up");

    SPKSetting *gallerySettings = [SPKSetting navigationCellWithTitle:SPKL(@"GALLERY_GENERAL_GALLERY_SETTINGS_TITLE")
                                                             subtitle:@""
                                                                 icon:SPKSettingsIcon(@"settings")
                                                       viewController:[[SPKGallerySettingsViewController alloc] init]];
    gallerySettings.searchSectionsProvider = ^NSArray * {
        return [SPKGallerySettingsViewController searchSections];
    };

    return SPKTopicNavigationSetting(SPKL(@"GALLERY_TITLE"), @"sparkle_gallery", 24.0, @[
        SPKTopicSection(@"", @[ openGallery ], SPKL(@"GALLERY_HOME_TAB_SHORTCUT_FOOTER")),
        SPKTopicSection(SPKL(@"GALLERY_HOME_SAVING_HEADER"), @[ autoSave ], SPKL(@"GALLERY_HOME_AUTO_SAVE_FOOTER")),
        SPKTopicSection(SPKL(@"GALLERY_HOME_MANAGE_HEADER"), @[ import, backUp, gallerySettings ], nil)
    ]);
}

@end
