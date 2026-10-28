#import "SPKBrandHeroView.h"
#import <QuartzCore/QuartzCore.h>
#import "SPKBrandLogoView.h"

@implementation SPKBrandHeroView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = NO;

        _glowView = [[UIView alloc] initWithFrame:self.bounds];
        _glowView.layer.cornerRadius = 26.0;  // at the paged sheets' 92pt; scaled in -layoutSubviews
        _glowView.layer.cornerCurve = kCACornerCurveContinuous;
        _glowView.clipsToBounds = YES;
        _glowView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_glowView];

        UIImageView *backgroundImageView = [[UIImageView alloc] initWithFrame:_glowView.bounds];
        backgroundImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        backgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
        backgroundImageView.clipsToBounds = YES;

        UIImage *bgImage = [UIImage imageNamed:@"Prod_Assets/Mask_group_02"];
        if (!bgImage) {
            NSString *frameworkPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks/FBSharedFramework.framework"];
            NSBundle *frameworkBundle = [NSBundle bundleWithPath:frameworkPath];
            bgImage = [UIImage imageNamed:@"ig-gradient-background" inBundle:frameworkBundle compatibleWithTraitCollection:nil];
            if (bgImage) {
                // Flip/mirror the fallback horizontally to match the IG icon gradient layout
                bgImage = [UIImage imageWithCGImage:bgImage.CGImage scale:bgImage.scale orientation:UIImageOrientationUpMirrored];
            }
        }

        backgroundImageView.image = bgImage;
        [_glowView addSubview:backgroundImageView];

        _logoView = [[SPKBrandLogoView alloc] initWithFrame:self.bounds];
        _logoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_logoView];

        [self updateShadowForStyle:self.traitCollection.userInterfaceStyle];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Keep the tile's proportions at any size, like an app icon.
    self.glowView.layer.cornerRadius = self.bounds.size.width * (26.0 / 92.0);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (self.traitCollection.userInterfaceStyle != previousTraitCollection.userInterfaceStyle) {
        [self updateShadowForStyle:self.traitCollection.userInterfaceStyle];
    }
}

- (void)updateShadowForStyle:(UIUserInterfaceStyle)style {
    if (style == UIUserInterfaceStyleDark) {
        self.layer.shadowColor = [UIColor colorWithRed:0.29 green:0.12 blue:0.62 alpha:0.45].CGColor;
        self.layer.shadowOpacity = 0.9;
        self.layer.shadowRadius = 20.0;
    } else {
        // Soft, elegant shadow for light mode
        self.layer.shadowColor = [UIColor colorWithRed:0.29 green:0.12 blue:0.62 alpha:0.25].CGColor;
        self.layer.shadowOpacity = 0.55;
        self.layer.shadowRadius = 14.0;
    }
}

- (void)setPageProgress:(CGFloat)progress {
    [self.logoView setScrollProgress:progress];

    // Page scale: dips to 0.82 at each boundary and eases back up.
    CGFloat scale;
    if (progress <= 1.0) {
        scale = 1.0 - progress * 0.18;
    } else {
        scale = 0.82 + (progress - 1.0) * 0.18;
    }
    self.transform = CGAffineTransformMakeScale(scale, scale);
}

@end
