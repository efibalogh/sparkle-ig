#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// The analytics name Instagram logs for a share sheet destination in the
/// external share row (for example "meta_ai"), lowercased. Stable across
/// languages, so it is the signal to match a destination by, never its label.
/// Nil when the build has no helper for it.
NSString *_Nullable SPKExternalShareOptionLoggingName(NSNumber *option);

/// Hides every button in an `IGExternalShareOptionsView` whose destination
/// matches, sliding the buttons after it left so the row keeps no gap. Call
/// after the view's own layout pass, which resets the frames, so the shift
/// never accumulates. Returns the number of buttons hidden.
NSUInteger SPKExternalShareOptionsViewCollapseMatching(UIView *view, BOOL (^matches)(NSString *loggingName));

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
