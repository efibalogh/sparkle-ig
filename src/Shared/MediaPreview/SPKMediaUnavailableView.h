#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Centered icon, title and explanation shown in place of media that cannot be
/// loaded and will not load on retry (e.g. a Gallery item whose file is gone).
/// Sized by its own content; the host pins its center.
@interface SPKMediaUnavailableView : UIView

- (void)setTitle:(NSString *)title message:(nullable NSString *)message;

@end

NS_ASSUME_NONNULL_END
