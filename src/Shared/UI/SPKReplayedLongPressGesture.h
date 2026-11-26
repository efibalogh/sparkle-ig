#import <UIKit/UIKit.h>

// A stand-in long press for calling an Instagram gesture handler without a live
// recognizer: a lookup that comes back after the real press ended, or a press
// the system tab bar reports through a delegate instead of a recognizer. It
// answers with a state chosen by the caller, and takes its view and location
// from the original recognizer when there is one.
@interface SPKReplayedLongPressGesture : UILongPressGestureRecognizer
@property (nonatomic, weak) UIGestureRecognizer *spk_original;
@property (nonatomic) UIGestureRecognizerState spk_state;
@end
