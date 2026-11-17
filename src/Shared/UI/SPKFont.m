#import "SPKFont.h"

static CGFloat SPKFontBaseSize(SPKFontStyle style) {
    switch (style) {
    case SPKFontStyleLargeTitle: return 34.0;
    case SPKFontStyleTitle1: return 28.0;
    case SPKFontStyleTitle2: return 22.0;
    case SPKFontStyleTitle3: return 20.0;
    case SPKFontStyleBody: return 17.0;
    case SPKFontStyleCallout: return 16.0;
    case SPKFontStyleSubheadline: return 15.0;
    case SPKFontStyleFootnote: return 13.0;
    case SPKFontStyleCaption1: return 12.0;
    case SPKFontStyleCaption2: return 11.0;
    case SPKFontStyleBadge: return 10.0;
    }
    return 17.0;
}

static UIFontTextStyle SPKFontTextStyle(SPKFontStyle style) {
    switch (style) {
    case SPKFontStyleLargeTitle: return UIFontTextStyleLargeTitle;
    case SPKFontStyleTitle1: return UIFontTextStyleTitle1;
    case SPKFontStyleTitle2: return UIFontTextStyleTitle2;
    case SPKFontStyleTitle3: return UIFontTextStyleTitle3;
    case SPKFontStyleBody: return UIFontTextStyleBody;
    case SPKFontStyleCallout: return UIFontTextStyleCallout;
    case SPKFontStyleSubheadline: return UIFontTextStyleSubheadline;
    case SPKFontStyleFootnote: return UIFontTextStyleFootnote;
    case SPKFontStyleCaption1: return UIFontTextStyleCaption1;
    case SPKFontStyleCaption2:
    case SPKFontStyleBadge: return UIFontTextStyleCaption2;
    }
    return UIFontTextStyleBody;
}

static UIFontMetrics *SPKFontMetrics(SPKFontStyle style) {
    return [UIFontMetrics metricsForTextStyle:SPKFontTextStyle(style)];
}

// The cap is what `value` scales to at xxxLarge on this style's curve. Fonts
// carry it as maximumPointSize, so it holds across live updates too.
static CGFloat SPKFontCappedValue(SPKFontStyle style, CGFloat value) {
    static UITraitCollection *capTraits;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        capTraits = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryExtraExtraExtraLarge];
    });
    return [SPKFontMetrics(style) scaledValueForValue:value compatibleWithTraitCollection:capTraits];
}

@implementation SPKFont

+ (UIFont *)scaledFont:(UIFont *)font forStyle:(SPKFontStyle)style {
    if (!font)
        font = [UIFont systemFontOfSize:SPKFontBaseSize(style)];
    CGFloat cap = SPKFontCappedValue(style, font.pointSize);
    return [SPKFontMetrics(style) scaledFontForFont:font maximumPointSize:cap];
}

+ (UIFont *)fontForStyle:(SPKFontStyle)style {
    return [self fontForStyle:style weight:UIFontWeightRegular];
}

+ (UIFont *)fontForStyle:(SPKFontStyle)style weight:(UIFontWeight)weight {
    return [self scaledFont:[UIFont systemFontOfSize:SPKFontBaseSize(style) weight:weight] forStyle:style];
}

+ (UIFont *)italicFontForStyle:(SPKFontStyle)style {
    return [self scaledFont:[UIFont italicSystemFontOfSize:SPKFontBaseSize(style)] forStyle:style];
}

+ (UIFont *)monospacedDigitFontForStyle:(SPKFontStyle)style weight:(UIFontWeight)weight {
    return [self scaledFont:[UIFont monospacedDigitSystemFontOfSize:SPKFontBaseSize(style) weight:weight] forStyle:style];
}

+ (UIFont *)monospacedFontForStyle:(SPKFontStyle)style weight:(UIFontWeight)weight {
    return [self scaledFont:[UIFont monospacedSystemFontOfSize:SPKFontBaseSize(style) weight:weight] forStyle:style];
}

+ (CGFloat)basePointSizeForStyle:(SPKFontStyle)style {
    return SPKFontBaseSize(style);
}

+ (CGFloat)scaledValue:(CGFloat)value forStyle:(SPKFontStyle)style {
    CGFloat scaled = [SPKFontMetrics(style) scaledValueForValue:value];
    return MIN(scaled, SPKFontCappedValue(style, value));
}

+ (CGFloat)lineGrowthForStyle:(SPKFontStyle)style {
    UIFont *font = [self fontForStyle:style];
    if (font.pointSize <= 0.0)
        return 0.0;
    // Line height is proportional to point size within one face, so the default
    // line height is the current one scaled back to the base size.
    CGFloat baseLineHeight = font.lineHeight * (SPKFontBaseSize(style) / font.pointSize);
    return MAX(0.0, ceil(font.lineHeight - baseLineHeight));
}

+ (void)apply:(UIFont *)font to:(id)view {
    if (!view || !font)
        return;
    if ([view isKindOfClass:[UIButton class]]) {
        UILabel *label = ((UIButton *)view).titleLabel;
        label.font = font;
        label.adjustsFontForContentSizeCategory = YES;
        return;
    }
    if ([view respondsToSelector:@selector(setFont:)])
        [view setFont:font];
    if ([view conformsToProtocol:@protocol(UIContentSizeCategoryAdjusting)])
        ((id<UIContentSizeCategoryAdjusting>)view).adjustsFontForContentSizeCategory = YES;
}

@end
