#import "SPKProgressPillButton.h"

#import "../../Utils.h"
#import "SPKFont.h"

@interface SPKProgressPillButton ()
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) CALayer *fillLayer;
@end

@implementation SPKProgressPillButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return self;
    self.clipsToBounds = YES;

    _fillLayer = [CALayer layer];
    _fillLayer.anchorPoint = CGPointMake(0, 0);
    [self.layer addSublayer:_fillLayer];

    _label = [UILabel new];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleSubheadline weight:UIFontWeightSemibold] to:_label];
    _label.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_label];
    [NSLayoutConstraint activateConstraints:@[
        [_label.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_label.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:16.0],
        [_label.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16.0],
    ]];

    [self applyColors];
    return self;
}

// "Light in dark mode and vice versa": the pill fill tracks the primary-text color (white-ish in
// dark, black-ish in light); the title is the inverse. The progress fill is the same hue at full
// opacity over a dimmed track, so the pill visually "fills up" while busy without a
// contrast-breaking accent color.
- (void)applyColors {
    UIColor *base = [SPKUtils SPKColor_InstagramPrimaryText];
    UIColor *text = [SPKUtils SPKColor_InstagramBackground];
    self.label.textColor = text;
    if (self.busy) {
        self.backgroundColor = [base colorWithAlphaComponent:0.30];
        self.fillLayer.backgroundColor = base.CGColor;
        self.fillLayer.hidden = NO;
    } else {
        self.backgroundColor = base;
        self.fillLayer.hidden = YES;
    }
    self.alpha = self.enabled ? 1.0 : 0.5;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.height / 2.0; // pill
    [self updateFillFrameAnimated:NO];
    [self applyColors]; // re-resolve CGColor for the current trait collection
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self applyColors];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self applyColors];
}

- (void)updateFillFrameAnimated:(BOOL)animated {
    CGFloat w = self.bounds.size.width * MAX(0.0, MIN(1.0, self.progress));
    CGRect target = CGRectMake(0, 0, w, self.bounds.size.height);
    if (!animated) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.fillLayer.frame = target;
        [CATransaction commit];
    } else {
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.25];
        self.fillLayer.frame = target;
        [CATransaction commit];
    }
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    if (!busy) {
        _progress = 0;
    }
    [self applyColors];
    [self updateFillFrameAnimated:NO];
}

- (void)setProgress:(double)progress animated:(BOOL)animated {
    _progress = MAX(0.0, MIN(1.0, progress));
    [self updateFillFrameAnimated:animated];
}

- (void)setText:(NSString *)text {
    self.label.text = text;
}

- (void)setTextAnimated:(NSString *)text {
    if ([self.label.text isEqualToString:text])
        return;
    if (!self.label.text.length) {
        self.label.text = text;
        return;
    }
    [UIView transitionWithView:self.label
                      duration:0.25
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
                        self.label.text = text;
                    }
                    completion:nil];
}

@end
