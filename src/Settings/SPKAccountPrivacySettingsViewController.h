#import <UIKit/UIKit.h>

#import "SPKSettingsViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// Instagram's own account privacy switches, which write to the account rather
/// than to local preferences. Shown as a fitted sheet holding only the two
/// switches; slow saves and any failure are reported through notification pills.
@interface SPKAccountPrivacySettingsViewController : SPKSettingsViewController

/// Sections for settings search, built without touching the network.
+ (NSArray *)searchSections;

/// Presents the switches as a sheet over `presenter`.
+ (void)presentFromViewController:(UIViewController *)presenter;

/// Re-reads both values from Instagram. A row that is saving keeps its save.
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
