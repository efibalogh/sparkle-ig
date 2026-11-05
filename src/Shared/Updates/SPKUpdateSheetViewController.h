#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The "new version available" sheet: the latest version against the installed one, a link to the
/// full changelog, and a button that hands off to this install's update channel. Not Now (or a
/// swipe down from the compact height) closes it until the next launch; Skip silences that version for good. The sheet is
/// only as tall as its content.
@interface SPKUpdateSheetViewController : UIViewController

/// Presents the sheet from `presenter`, or the top controller when nil. Does nothing while that
/// controller is already presenting something.
+ (void)presentFromViewController:(nullable UIViewController *)presenter;

/// Same, and with `announce` the sheet lands with a haptic: for the launch prompt, which arrives
/// unasked, rather than a tap on the version row.
+ (void)presentFromViewController:(nullable UIViewController *)presenter announce:(BOOL)announce;

@end

NS_ASSUME_NONNULL_END
