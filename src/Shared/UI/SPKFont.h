#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Sparkle's type scale. Each style has Apple's point size at the default text
// size (Large) and scales on that text style's Dynamic Type curve, stopping at
// xxxLarge, the largest size the Display & Text Size slider offers. The
// accessibility sizes beyond it are deliberately not followed.
typedef NS_ENUM(NSInteger, SPKFontStyle) {
    SPKFontStyleLargeTitle,  // 34
    SPKFontStyleTitle1,      // 28
    SPKFontStyleTitle2,      // 22
    SPKFontStyleTitle3,      // 20
    SPKFontStyleBody,        // 17
    SPKFontStyleCallout,     // 16
    SPKFontStyleSubheadline, // 15
    SPKFontStyleFootnote,    // 13
    SPKFontStyleCaption1,    // 12
    SPKFontStyleCaption2,    // 11
    // Sparkle's own size for small pills and badges (a source tag, a folder chip):
    // one point under Caption 2 on the same curve, so a pill beside caption text
    // reads as a tag rather than as more text.
    SPKFontStyleBadge,       // 10
};

// The only place Sparkle UI should get a font from. Every font is built on the
// system font entry points, so the custom font feature still swaps the face,
// and is scaled with UIFontMetrics, so a view that sets
// adjustsFontForContentSizeCategory follows text size changes live (use
// +apply:to: for that).
@interface SPKFont : NSObject

+ (UIFont *)fontForStyle:(SPKFontStyle)style;
+ (UIFont *)fontForStyle:(SPKFontStyle)style weight:(UIFontWeight)weight;
+ (UIFont *)italicFontForStyle:(SPKFontStyle)style;

// Tabular digits for counters, timers and sizes that must not jitter.
+ (UIFont *)monospacedDigitFontForStyle:(SPKFontStyle)style weight:(UIFontWeight)weight;
// Fully monospaced, for logs and diagnostics.
+ (UIFont *)monospacedFontForStyle:(SPKFontStyle)style weight:(UIFontWeight)weight;

// Scales an already-built font (a symbolic-trait variant, a rounded design) on
// the style's curve with the same cap. The font keeps its own point size as the
// base.
+ (UIFont *)scaledFont:(UIFont *)font forStyle:(SPKFontStyle)style;

// Unscaled point size of a style at the default text size, for layout math that
// needs the design value rather than the user's current size.
+ (CGFloat)basePointSizeForStyle:(SPKFontStyle)style;

// Scales a layout value (a row height, an icon size beside text) on the style's
// curve with the same cap, so geometry grows with the text it holds.
+ (CGFloat)scaledValue:(CGFloat)value forStyle:(SPKFontStyle)style;

// How much taller one line of the style is at the user's text size than at the
// default. Add it to a fixed row height once per stacked line so the row grows
// by exactly what its text grew. Zero at the default size and below.
+ (CGFloat)lineGrowthForStyle:(SPKFontStyle)style;

// Sets the font and turns on live text size updates. Accepts UILabel,
// UITextField, UITextView and UIButton (its titleLabel); anything else only gets
// the font when it responds to -setFont:.
+ (void)apply:(UIFont *)font to:(nullable id)view;

@end

NS_ASSUME_NONNULL_END
