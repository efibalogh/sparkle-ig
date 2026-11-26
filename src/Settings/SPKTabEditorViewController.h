#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// NEW badge item for the per-tab hold shortcuts drawn on this page.
FOUNDATION_EXPORT NSString *const SPKTabEditorNewItemHolds;
/// NEW badge item for the System Tab Bar switch drawn on this page.
FOUNDATION_EXPORT NSString *const SPKTabEditorNewItemSystemTabBar;

/// Whether Instagram runs the system tab bar by itself (the foldable iPhone),
/// where the appearance and swipe rows cannot apply and are left off the page.
FOUNDATION_EXPORT BOOL SPKTabEditorInstagramOwnsSystemTabBar(void);

@interface SPKTabEditorViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
