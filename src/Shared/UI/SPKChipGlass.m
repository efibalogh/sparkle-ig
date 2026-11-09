#import "SPKChipGlass.h"
#import "../../Utils.h"
#import <objc/runtime.h>

// The chips use the system glass button configuration rather than a
// UIGlassEffect view behind a plain button. Only the configurations carry the
// system touch response (the swell, the highlight that follows the finger and
// the stretch while dragging): an effect view behind a button has to stay
// untouchable so taps reach the button, so its interactive response never
// fires. The configurations also keep the label legible as the material adapts
// light/dark to the content behind it, because the title is hosted inside the
// glass and resolves dynamic colors against its adapted traits.
//
// The configuration ships in the iOS 26 SDK and this project builds against
// 16.2, so it is looked up by selector at runtime.

static SEL SPKGlassConfigSelector(void) {
    return NSSelectorFromString(@"glassButtonConfiguration");
}

static UIButtonConfiguration *SPKMakeGlassConfiguration(void) {
    Class configClass = [UIButtonConfiguration class];
    SEL sel = SPKGlassConfigSelector();
    if (![configClass respondsToSelector:sel])
        return nil;
    id config = ((id (*)(id, SEL))[configClass methodForSelector:sel])(configClass, sel);
    return [config isKindOfClass:configClass] ? config : nil;
}

// The chip's material: regular glass, tinted when selected. Both states use the
// plain glass configuration with this effect as its background, rather than the
// prominent configuration for the selected state: prominent glass with an
// achromatic tint (the primary text color) renders as a near-solid pill instead
// of tinted glass. `interactive` and `tintColor` are set via KVC because
// UIGlassEffect is not in the build SDK.
static UIVisualEffect *SPKMakeGlassEffect(BOOL selected, UIColor *selectedTint) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (!glassClass)
        return nil;
    id effect = [[glassClass alloc] init];
    if (![effect isKindOfClass:[UIVisualEffect class]])
        return nil;
    @try {
        [effect setValue:@YES forKey:@"interactive"];
    } @catch (__unused NSException *e) {
    }
    if (selected && selectedTint) {
        @try {
            [effect setValue:selectedTint forKey:@"tintColor"];
        } @catch (__unused NSException *e) {
        }
    }
    return effect;
}

BOOL SPKChipGlassAvailable(void) {
    if (@available(iOS 26.0, *)) {
        return NSClassFromString(@"UIGlassEffect") != nil &&
               [[UIButtonConfiguration class] respondsToSelector:SPKGlassConfigSelector()];
    }
    return NO;
}

static NSDirectionalEdgeInsets SPKDirectionalInsets(UIEdgeInsets insets) {
    return NSDirectionalEdgeInsetsMake(insets.top, insets.left, insets.bottom, insets.right);
}

// The chip's legacy content and title insets, captured the first time glass is
// applied. UIButton keeps honoring the legacy insets on top of a configuration's
// own, which doubled the padding, so they are zeroed once carried over and the
// captured values are reused on every later call.
static const char kSPKChipLegacyContentInsetsKey = 0;
static const char kSPKChipLegacyTitleInsetsKey = 0;

static void SPKChipTakeLegacyInsets(UIButton *chip, UIEdgeInsets *content, UIEdgeInsets *title) {
    NSValue *storedContent = objc_getAssociatedObject(chip, &kSPKChipLegacyContentInsetsKey);
    NSValue *storedTitle = objc_getAssociatedObject(chip, &kSPKChipLegacyTitleInsetsKey);
    if (!storedContent || !storedTitle) {
        storedContent = [NSValue valueWithUIEdgeInsets:chip.contentEdgeInsets];
        storedTitle = [NSValue valueWithUIEdgeInsets:chip.titleEdgeInsets];
        objc_setAssociatedObject(chip, &kSPKChipLegacyContentInsetsKey, storedContent, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(chip, &kSPKChipLegacyTitleInsetsKey, storedTitle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    chip.contentEdgeInsets = UIEdgeInsetsZero;
    chip.titleEdgeInsets = UIEdgeInsetsZero;
    *content = storedContent.UIEdgeInsetsValue;
    *title = storedTitle.UIEdgeInsetsValue;
}

// A legacy state image takes precedence over the configuration's image, and is
// drawn without the configuration's foreground color. So the glyph the chip bar
// set is moved into the configuration: taken off the legacy state and kept on
// the chip for calls where the bar did not set a new one.
static const char kSPKChipLegacyImageKey = 0;

static UIImage *SPKChipTakeLegacyImage(UIButton *chip) {
    UIImage *image = [chip imageForState:UIControlStateNormal];
    if (image) {
        objc_setAssociatedObject(chip, &kSPKChipLegacyImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [chip setImage:nil forState:UIControlStateNormal];
        return image;
    }
    return objc_getAssociatedObject(chip, &kSPKChipLegacyImageKey);
}

static UIImage *SPKChipFlattenedGlyph(UIImage *source, UIColor *color) {
    UIImageAsset *asset = [UIImageAsset new];
    UIImage *result = nil;
    for (NSNumber *style in @[ @(UIUserInterfaceStyleLight), @(UIUserInterfaceStyleDark) ]) {
        UITraitCollection *traits = [UITraitCollection traitCollectionWithUserInterfaceStyle:style.integerValue];
        UIImage *glyph = [source imageWithTintColor:[color resolvedColorWithTraitCollection:traits]
                                      renderingMode:UIImageRenderingModeAlwaysOriginal];
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = glyph.scale;
        format.opaque = NO;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:glyph.size format:format];
        UIImage *flat = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
            [glyph drawInRect:(CGRect){CGPointZero, glyph.size}];
        }];
        // The scale must be part of the registration, or the asset treats the
        // bitmap as 1x and the glyph comes back three times its size.
        UITraitCollection *registered = [UITraitCollection traitCollectionWithTraitsFromCollections:@[
            traits, [UITraitCollection traitCollectionWithDisplayScale:flat.scale]
        ]];
        [asset registerImage:flat withTraitCollection:registered];
        if (!result)
            result = flat;
    }
    return [asset imageWithTraitCollection:[UITraitCollection currentTraitCollection]] ?: result;
}

BOOL SPKChipApplyGlass(UIButton *chip, BOOL selected, CGFloat cornerRadius, UIColor *selectedTint) {
    if (!chip || !SPKChipGlassAvailable())
        return NO;
    UIButtonConfiguration *config = SPKMakeGlassConfiguration();
    UIVisualEffect *effect = SPKMakeGlassEffect(selected, selectedTint);
    if (!config || !effect)
        return NO;
    config.background.visualEffect = effect;

    // Content comes from the chip's legacy state, which the chip bars set when
    // they build the chip (title, glyph, font, insets), and is moved into the
    // configuration: the title inset becomes the image padding and the content
    // insets keep the chip's existing size.
    UIFont *font = chip.titleLabel.font;
    config.title = chip.currentTitle;
    config.image = SPKChipTakeLegacyImage(chip);
    UIEdgeInsets content, title;
    SPKChipTakeLegacyInsets(chip, &content, &title);
    BOOL hasImageAndTitle = config.image && chip.currentTitle.length;
    config.imagePadding = hasImageAndTitle ? MAX(title.left, 0.0) : 0.0;
    if (hasImageAndTitle) {
        // The legacy layout sized the chip to both content insets plus the title
        // shift, then centered image, gap and title in it, so each side got the
        // mean of the two insets. Matching that keeps the chips' size.
        CGFloat side = (content.left + content.right) / 2.0;
        content.left = side;
        content.right = side;
    }
    config.contentInsets = SPKDirectionalInsets(content);
    if (font) {
        config.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
            NSMutableDictionary *attributes = [incoming mutableCopy] ?: [NSMutableDictionary dictionary];
            attributes[NSFontAttributeName] = font;
            return attributes;
        };
    }
    if (selected) {
        config.baseForegroundColor = [SPKUtils SPKColor_InstagramBackground];
    } else {
        // Dynamic, so it resolves against the glass's adapted light/dark style.
        config.baseForegroundColor = [SPKUtils SPKColor_InstagramPrimaryText];
    }
    // Glass content gets a monochromatic vibrant treatment that recolors template
    // and symbol glyphs to its own foreground and ignores the tint, so the glyph
    // vanished on the bright selected capsule. Flattened bitmaps in the label
    // color are drawn as is; one per appearance, so it still follows light/dark
    // (chips are often built before they are in a window).
    if (config.image && selected) {
        config.image = SPKChipFlattenedGlyph(config.image, config.baseForegroundColor);
    }
    // One line, truncating, like the legacy chips. Set via KVC: the property is
    // iOS 16+ and missing from the build SDK's headers.
    @try {
        [config setValue:@(NSLineBreakByTruncatingTail) forKey:@"titleLineBreakMode"];
    } @catch (__unused NSException *e) {
    }
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;

    BOOL shrinks = chip.titleLabel.adjustsFontSizeToFitWidth;
    CGFloat minimumScale = chip.titleLabel.minimumScaleFactor;
    chip.configuration = config;
    // Keep the button tint on the label color too, so nothing that falls back to
    // the inherited tint draws in the window's accent.
    chip.tintColor = config.baseForegroundColor;
    chip.backgroundColor = [UIColor clearColor];
    chip.layer.cornerRadius = cornerRadius;
    // Fill-mode chip bars let a long label shrink instead of truncating; the
    // configuration does not manage these, so they survive on the label.
    chip.titleLabel.adjustsFontSizeToFitWidth = shrinks;
    chip.titleLabel.minimumScaleFactor = minimumScale;
    return YES;
}

// MARK: - Static glass

// For glass surfaces that are not selection chips (the Gallery folder chips, the
// debug button): a plain glass capsule behind the button with no touch
// response. The glass view stays untouchable so taps reach the button.
static const char kSPKChipStaticGlassViewKey = 0;

// Liquid Glass adapts its material light/dark to the content scrolling behind it.
// A dark capsule would leave the button's (statically dark) label unreadable, so
// the label has to flip with the glass. UIKit propagates the glass's adapted
// appearance to its contentView's trait collection, so a zero-size probe placed
// in the contentView reports the live style. That style is mirrored onto the
// button's title/image via overrideUserInterfaceStyle, never the whole button,
// since the glass is a descendant of the button and would otherwise be pinned to
// a fixed style (feedback loop).
@interface SPKGlassLegibilityProbe : UIView
@property (nonatomic, copy) void (^onStyleChange)(UIUserInterfaceStyle style);
@end

@implementation SPKGlassLegibilityProbe
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle && self.onStyleChange) {
        self.onStyleChange(self.traitCollection.userInterfaceStyle);
    }
}
@end

static void SPKApplyLegibilityStyle(UIButton *button, UIUserInterfaceStyle style) {
    button.titleLabel.overrideUserInterfaceStyle = style;
    button.imageView.overrideUserInterfaceStyle = style;
}

BOOL SPKChipApplyStaticGlass(UIButton *button, CGFloat cornerRadius) {
    if (!button || !SPKChipGlassAvailable())
        return NO;
    UIVisualEffect *effect = SPKMakeGlassEffect(NO, nil);
    if (!effect)
        return NO;

    UIVisualEffectView *glass = objc_getAssociatedObject(button, &kSPKChipStaticGlassViewKey);
    if (!glass) {
        glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        glass.userInteractionEnabled = NO;
        glass.clipsToBounds = YES;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        [button insertSubview:glass atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [glass.leadingAnchor constraintEqualToAnchor:button.leadingAnchor],
            [glass.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
            [glass.topAnchor constraintEqualToAnchor:button.topAnchor],
            [glass.bottomAnchor constraintEqualToAnchor:button.bottomAnchor],
        ]];
        objc_setAssociatedObject(button, &kSPKChipStaticGlassViewKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        SPKGlassLegibilityProbe *probe = [SPKGlassLegibilityProbe new];
        probe.userInteractionEnabled = NO;
        probe.hidden = YES;
        probe.translatesAutoresizingMaskIntoConstraints = NO;
        [glass.contentView addSubview:probe];
        [NSLayoutConstraint activateConstraints:@[
            [probe.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor],
            [probe.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor],
            [probe.widthAnchor constraintEqualToConstant:0.0],
            [probe.heightAnchor constraintEqualToConstant:0.0],
        ]];
        __weak UIButton *weakButton = button;
        probe.onStyleChange = ^(UIUserInterfaceStyle style) {
            SPKApplyLegibilityStyle(weakButton, style);
        };
        SPKApplyLegibilityStyle(button, probe.traitCollection.userInterfaceStyle);
    } else {
        glass.effect = effect;
    }
    // Always re-sink it: a button's title/image views can be created after the
    // glass is inserted, which would leave the material sitting over the content
    // as a translucent film until something else reordered the subviews.
    [button sendSubviewToBack:glass];
    glass.layer.cornerRadius = cornerRadius;
    button.backgroundColor = [UIColor clearColor];
    return YES;
}
