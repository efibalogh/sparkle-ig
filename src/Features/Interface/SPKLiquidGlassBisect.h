#import <UIKit/UIKit.h>

#if SPK_DEV

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Guided search for the forced Liquid Glass value behind a visual problem.
/// Each step hands half of the remaining suspects back to Instagram and closes
/// the app; after reopening, the user answers whether the problem is still
/// there from the Debug Button, until one value is left.
BOOL SPKLiquidGlassBisectIsActive(void);
/// Explains the test, then starts it from the values Sparkle changed this launch.
void SPKLiquidGlassBisectStart(void);
/// Debug Button menu section: the start action, or the answers while a test runs.
NSArray<UIMenuElement *> *SPKLiquidGlassBisectMenuElements(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif
