#import <UIKit/UIKit.h>

#import "../UI/SPKChipBar.h"
#import "SPKStraightenRulerView.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPKCropControlsPanel) {
    SPKCropControlsPanelAspect = 0,
    SPKCropControlsPanelStraighten = 1,
};

/// The strip under (or beside) a crop canvas: the aspect chips and the
/// straighten ruler share one fixed-height slot and take turns in it, swapped
/// with one toolbar button that shows the tool it switches to. A fixed height
/// keeps the canvas from resizing, and so the crop from refitting, when the
/// panel switches.
///
/// Without aspect chips (a locked ratio) the ruler is the only panel and there
/// is nothing to switch.
@interface SPKCropControlsView : UIView

- (instancetype)initWithAspectChips:(BOOL)showsAspectChips NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// nil with a locked ratio. Its delegate belongs to the owner.
@property (nonatomic, strong, readonly, nullable) SPKChipBar *aspectChips;
@property (nonatomic, strong, readonly) SPKStraightenRulerView *ruler;

/// The Crop / Straighten toggle, for the owner's toolbar. nil without aspect
/// chips.
@property (nonatomic, strong, readonly, nullable) UIBarButtonItem *switchItem;

@property (nonatomic, assign) SPKCropControlsPanel panel;

@end

NS_ASSUME_NONNULL_END
