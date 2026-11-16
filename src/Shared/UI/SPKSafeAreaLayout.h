#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Width a collection view can lay items out in once its horizontal safe-area
/// insets are removed. A vertical tab bar or a clock column on a side edge
/// reports itself as a horizontal safe-area inset, and vertical-only scrolling
/// never folds those into the content inset, so items sized from the raw bounds
/// run underneath it.
FOUNDATION_EXPORT CGFloat SPKCollectionViewUsableWidth(UICollectionView *collectionView);

/// Points a flow layout's sections from the collection view's safe area, so the
/// section insets start inside a side bar instead of under it.
FOUNDATION_EXPORT void SPKFlowLayoutUseSafeArea(UICollectionViewFlowLayout *layout);

/// Scales a column count chosen for a phone-width screen to the width that is
/// actually available, keeping tiles near the size the user picked. Widths up
/// to a phone's keep the count unchanged.
FOUNDATION_EXPORT NSInteger SPKAdaptiveColumnCount(NSInteger compactColumns, CGFloat width);

NS_ASSUME_NONNULL_END
