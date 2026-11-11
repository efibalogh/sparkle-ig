#import <UIKit/UIKit.h>

#import "../../Settings/SPKSettingsViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// Settings → Downloads → File Names: custom names for files saved to Photos or
/// shared, with a live preview. See SPKExportFileNaming.
@interface SPKFileNamesSettingsViewController : SPKSettingsViewController

/// The Downloads page row that opens this page.
+ (SPKSetting *)navigationSetting;

/// Sections used for settings search indexing.
+ (NSArray *)searchSections;

@end

NS_ASSUME_NONNULL_END
