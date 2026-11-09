#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when running on iOS 26+ with Liquid Glass and the system glass button
/// configuration available. Chip bars use this to decide between glass capsules and the solid
/// fill fallback.
BOOL SPKChipGlassAvailable(void);

/// Turns a chip button into a system Liquid Glass button, with the system touch
/// response. Selected chips get glass tinted with `selectedTint`; unselected
/// chips get untinted glass. The title, image, font and insets are read
/// from the chip's legacy state, so set them (and the current glyph) before
/// calling; call again whenever the selection or glyph changes.
///
/// Returns YES when glass was applied: the glass owns the chip's background and
/// label colors, so the caller must not set them. Returns NO on pre-iOS-26, where
/// the caller applies its own solid fill and colors.
BOOL SPKChipApplyGlass(UIButton *chip, BOOL selected, CGFloat cornerRadius, UIColor *_Nullable selectedTint);

/// A static Liquid Glass capsule behind a button that is not a selection chip
/// (folder chips, floating buttons): no touch response, the button's own content
/// and colors are kept and only flipped light/dark with the material. Returns NO
/// on pre-iOS-26, where the caller keeps its existing fill.
BOOL SPKChipApplyStaticGlass(UIButton *button, CGFloat cornerRadius);

NS_ASSUME_NONNULL_END
