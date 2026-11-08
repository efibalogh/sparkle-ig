#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// List of recorded Instagram requests (see SPKNetworkInterceptor.h),
/// with search, kind filters, a record toggle and a per-request detail page.
@interface SPKNetworkInterceptorViewController : UIViewController
/// Shows the list in a sheet with a close button, or brings an open one forward.
+ (void)present;
/// Starts or stops recording with a notification; `clearFirst` empties the list
/// before a fresh capture.
+ (void)setRecording:(BOOL)recording clearFirst:(BOOL)clearFirst;
@end

NS_ASSUME_NONNULL_END
