#import <Foundation/Foundation.h>

@class SPKSetting;
@class UIViewController;

/// Data > Backup & Transfer > Export with only the Gallery checked, for the Gallery
/// home's Back Up row. The other items stay available to check.
FOUNDATION_EXPORT UIViewController *SPKDataGalleryExportViewController(void);

@interface SPKDataSettingsProvider : NSObject
+ (SPKSetting *)rootSetting;
@end
