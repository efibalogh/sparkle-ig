#import "SPKReplayedLongPressGesture.h"

@implementation SPKReplayedLongPressGesture
- (UIGestureRecognizerState)state {
    return self.spk_state;
}
- (UIView *)view {
    return self.spk_original.view;
}
- (CGPoint)locationInView:(UIView *)view {
    return self.spk_original ? [self.spk_original locationInView:view] : CGPointZero;
}
@end
