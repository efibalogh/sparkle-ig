#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// When a window is narrow beside a vertical tab bar, UIKit moves navigation bar
// items into a side column, and Instagram hands its header buttons to that column
// as bar items. Sparkle's own header buttons then join the column as separate
// glass circles under Instagram's groups. Everything here is measured from the
// live views, so a horizontal layout (no column) simply finds nothing.

/// The container Instagram wraps around a header item it hands to the side
/// column, found among `view`'s ancestors, or nil while `view` is not in it.
UIView *_Nullable SPKSideColumnItemContainer(UIView *_Nullable view);

/// Frame in `host` of the column glass group holding `container`, or CGRectNull
/// when the group is hidden. `alpha` receives the group's effective opacity.
CGRect SPKSideColumnGroupFrame(UIView *container, UIView *host, CGFloat *_Nullable alpha);

/// The lowest column group among `navigationItem`'s bar items, in `host`, or
/// CGRectNull when none of them is in the column.
CGRect SPKSideColumnLowestGroup(UINavigationItem *_Nullable navigationItem, UIView *host, CGFloat *_Nullable alpha);

/// Whether Instagram handed any of `navigationItem`'s bar items to the side
/// column, attached to a window yet or not (they attach after a push settles).
BOOL SPKSideColumnHoldsItems(UINavigationItem *_Nullable navigationItem);

/// The lowest visible glass group of navigation items in the column, whoever
/// owns it, in `host`; CGRectNull when the column holds none.
CGRect SPKSideColumnLowestVisibleGroup(UIView *host, CGFloat *_Nullable alpha);

/// The nearest view holding both `view` and the column's navigation items, for
/// screens with no tab bar controller of their own (a split view's detail);
/// nil without a column.
UIView *_Nullable SPKSideColumnHostForView(UIView *view);

/// Side of a Sparkle button docked in the column, matching the column's groups.
extern const CGFloat SPKSideColumnButtonSide;

/// The vertical tab group under `root`, or nil when the tab bar is horizontal.
UIView *_Nullable SPKSideColumnTabPlatter(UIView *_Nullable root);

/// Places `button` (with `glassView`, a bubble from SPKChromeGlassMirrorMakeBubble,
/// behind its icon) as its own glass circle under `group` in `host`. Returns NO
/// when there is no room above the tab group or the bottom safe area; the caller
/// then hides the button.
BOOL SPKSideColumnDockButton(UIButton *button, UIView *_Nullable glassView, UIView *host, CGRect group, CGFloat alpha);

/// Places `button` at `frame` in `host` with the column's glass behind it.
/// Write-guarded, so it can run on every layout pass.
void SPKSideColumnPlaceButton(UIButton *button, UIView *_Nullable glassView, UIView *host, CGRect frame, CGFloat alpha);

/// Sizes a Sparkle chrome button for where it sits: the column's side when
/// docked, its own again back in a header row.
void SPKSideColumnSizeButton(UIButton *button, CGFloat side);

/// Forgets the docked frame, so the next dock repositions the button.
void SPKSideColumnResetDock(UIButton *button);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
