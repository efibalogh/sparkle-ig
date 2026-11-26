#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A horizontal tick ruler for fine rotation. The ticks slide under a fixed
/// centre needle as the finger drags, the current angle sits above the needle,
/// and a double tap returns to zero. Sends `UIControlEventValueChanged`
/// continuously while dragging, and `UIControlEventEditingDidEnd` when the
/// finger lifts.
@interface SPKStraightenRulerView : UIControl

/// Degrees, clockwise positive, clamped to `-maximumValue...maximumValue`.
@property (nonatomic, assign) CGFloat value;

/// Defaults to 45.
@property (nonatomic, assign) CGFloat maximumValue;

/// YES while a finger is on the ruler.
@property (nonatomic, readonly, getter=isDragging) BOOL dragging;

@end

NS_ASSUME_NONNULL_END
