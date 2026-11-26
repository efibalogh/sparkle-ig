#import <UIKit/UIKit.h>

#if SPK_DEV

NS_ASSUME_NONNULL_BEGIN

/// Dev sheet listing every value forced Liquid Glass changes, what Instagram
/// would have used instead, and a switch per value to hand it back to Instagram
/// on the next launch. Reachable from the Debug Button and Tools > Diagnostics.
@interface SPKLiquidGlassGatesViewController : UITableViewController
/// Presents the sheet over whatever is on screen, or brings an open one back.
+ (void)present;
@end

NS_ASSUME_NONNULL_END

#endif
