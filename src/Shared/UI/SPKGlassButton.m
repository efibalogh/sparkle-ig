#import "SPKGlassButton.h"
#import "../../Utils.h"
#import "SPKFont.h"

// The glass look AND its interactive "bounce" both come from the system's
// prominentGlass button configuration — a UIGlassEffect behind a plain button was
// tried and is NOT equivalent (it renders flat and has no touch response, since the
// effect view can't take the touches). So the configuration stays.
//
// The tint must be CHROMATIC. Glass tints its material with tintColor, and an
// achromatic tint (Sparkle's black/white primary-text colour) leaves the material no
// light to bend, so it renders as a flat pill — at every alpha; opacity is not the
// variable, hue is. IG blue is what the trim/photo editor's Done-style Save checkmark
// tints its bar item with, and that reads as proper glass, so this matches it.
@interface SPKGlassButton () {
    BOOL _isGlass;
}
@end

@implementation SPKGlassButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        Class configClass = NSClassFromString(@"UIButtonConfiguration");
        SEL prominentGlassSel = NSSelectorFromString(@"prominentGlassButtonConfiguration");
        SEL filledSel = NSSelectorFromString(@"filledButtonConfiguration");

        id titleTransformer = ^(NSDictionary *incoming) {
            NSMutableDictionary *mut = [incoming mutableCopy] ?: [NSMutableDictionary dictionary];
            mut[NSFontAttributeName] = [SPKFont fontForStyle:SPKFontStyleSubheadline weight:UIFontWeightSemibold];
            return mut;
        };

        if (configClass && [configClass respondsToSelector:prominentGlassSel]) {
            _isGlass = YES;
            id config = ((id (*)(id, SEL))[configClass methodForSelector:prominentGlassSel])(configClass, prominentGlassSel);
            [config setValue:titleTransformer forKey:@"titleTextAttributesTransformer"];
            self.configuration = config;
        } else if (configClass && [configClass respondsToSelector:filledSel]) {
            _isGlass = NO;
            id config = ((id (*)(id, SEL))[configClass methodForSelector:filledSel])(configClass, filledSel);
            [config setValue:titleTransformer forKey:@"titleTextAttributesTransformer"];
            
            id backgroundConfig = [config valueForKey:@"background"];
            if (backgroundConfig) {
                [backgroundConfig setValue:@(25.0) forKey:@"cornerRadius"];
            }
            self.configuration = config;
        }
        
        [self applyColors];
    }
    return self;
}

- (void)applyColors {
    UIColor *baseColor = [SPKUtils SPKColor_InstagramPrimaryText];
    UIColor *textColor = [SPKUtils SPKColor_InstagramBackground];

    // Chromatic tint only (see class comment) — matches the editors' Save checkmark
    // rather than the system accent. The label colour is left to the configuration,
    // which contrasts itself against the tint.
    if (_isGlass) {
        self.tintColor = [SPKUtils SPKColor_InstagramBlue];
        return;
    }

    self.tintColor = baseColor;

    if (self.configuration) {
        id config = self.configuration;
        [config setValue:baseColor forKey:@"baseBackgroundColor"];
        [config setValue:textColor forKey:@"baseForegroundColor"];
        self.configuration = config;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self applyColors];
}

- (void)layoutSubviews {
    [super layoutSubviews];
}

- (void)setText:(NSString *)text {
    if (self.configuration) {
        id config = self.configuration;
        [config setValue:text forKey:@"title"];
        self.configuration = config;
    } else {
        [self setTitle:text forState:UIControlStateNormal];
    }
}

- (void)setTextAnimated:(NSString *)text {
    NSString *currentTitle = nil;
    if (self.configuration) {
        currentTitle = [self.configuration valueForKey:@"title"];
    } else {
        currentTitle = [self titleForState:UIControlStateNormal];
    }
    
    if ([currentTitle isEqualToString:text])
        return;
    
    if (!currentTitle.length) {
        [self setText:text];
        return;
    }
    
    [UIView transitionWithView:self
                      duration:0.25
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
                        [self setText:text];
                    }
                    completion:nil];
}

@end
