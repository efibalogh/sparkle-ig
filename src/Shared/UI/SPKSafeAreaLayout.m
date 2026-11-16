#import "SPKSafeAreaLayout.h"

// Widest portrait phone the compact column counts were tuned for.
static CGFloat const kSPKCompactReferenceWidth = 440.0;

CGFloat SPKCollectionViewUsableWidth(UICollectionView *collectionView) {
    UIEdgeInsets safe = collectionView.safeAreaInsets;
    return MAX(0.0, CGRectGetWidth(collectionView.bounds) - safe.left - safe.right);
}

void SPKFlowLayoutUseSafeArea(UICollectionViewFlowLayout *layout) {
    layout.sectionInsetReference = UICollectionViewFlowLayoutSectionInsetFromSafeArea;
}

NSInteger SPKAdaptiveColumnCount(NSInteger compactColumns, CGFloat width) {
    if (compactColumns < 1)
        compactColumns = 1;
    if (width <= kSPKCompactReferenceWidth)
        return compactColumns;
    // Tile width the user picked on a phone, applied to the wider space.
    CGFloat tile = 390.0 / (CGFloat)compactColumns;
    NSInteger scaled = (NSInteger)floor(width / tile);
    return MAX(compactColumns, scaled);
}
