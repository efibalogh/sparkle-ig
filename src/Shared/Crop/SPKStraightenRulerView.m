#import "SPKStraightenRulerView.h"
#import "SPKStrings.h"

#import "../../Utils.h"
#import "../UI/SPKFont.h"

// One degree of rotation per this many points of finger travel.
static const CGFloat kSPKRulerPointsPerDegree = 7.0;
static const CGFloat kSPKRulerTickAreaHeight = 18.0;
static const CGFloat kSPKRulerLabelHeight = 18.0;
// Inside this many degrees of zero, lifting the finger settles on exactly zero.
static const CGFloat kSPKRulerZeroSnap = 0.4;

// Where a 1pt line centred near `x` draws crisply: its edges on whole device
// pixels. The needle and every tick go through this, so zero sits exactly under
// the needle on every screen scale (rounding them separately drifts them apart
// on a 2x display).
static CGFloat SPKRulerAlignedX(CGFloat x, CGFloat scale) {
    if (scale <= 0.0)
        scale = 1.0;
    return (round(x * scale - scale / 2.0) + scale / 2.0) / scale;
}

@implementation SPKStraightenRulerView {
    CAShapeLayer *_minorTicks;
    CAShapeLayer *_majorTicks;
    CALayer *_needle;
    CAGradientLayer *_fadeMask;
    UILabel *_valueLabel;
    UISelectionFeedbackGenerator *_feedback;
    CGFloat _dragStartValue;
    BOOL _dragging;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _maximumValue = 45.0;
        self.backgroundColor = UIColor.clearColor;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitAdjustable;
        self.accessibilityLabel = SPKL(@"CROP_STRAIGHTEN_RULER_ACCESSIBILITY_LABEL");

        _minorTicks = [CAShapeLayer layer];
        _minorTicks.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
        _minorTicks.lineWidth = 1.0;
        [self.layer addSublayer:_minorTicks];

        _majorTicks = [CAShapeLayer layer];
        _majorTicks.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.9].CGColor;
        _majorTicks.lineWidth = 1.0;
        [self.layer addSublayer:_majorTicks];

        // Ticks fade out toward both ends so the strip reads as a dial.
        _fadeMask = [CAGradientLayer layer];
        _fadeMask.startPoint = CGPointMake(0.0, 0.5);
        _fadeMask.endPoint = CGPointMake(1.0, 0.5);
        _fadeMask.colors = @[
            (id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor,
            (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor
        ];
        _fadeMask.locations = @[ @0.0, @0.25, @0.75, @1.0 ];

        _needle = [CALayer layer];
        _needle.backgroundColor = UIColor.whiteColor.CGColor;
        _needle.cornerRadius = 1.0;
        [self.layer addSublayer:_needle];

        _valueLabel = [[UILabel alloc] init];
        _valueLabel.textAlignment = NSTextAlignmentLeft;
        [SPKFont apply:[SPKFont monospacedDigitFontForStyle:SPKFontStyleFootnote weight:UIFontWeightSemibold] to:_valueLabel];
        _valueLabel.isAccessibilityElement = NO;
        [self addSubview:_valueLabel];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
        doubleTap.numberOfTapsRequired = 2;
        [self addGestureRecognizer:doubleTap];

        [self refreshValueLabel];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, kSPKRulerLabelHeight + 6.0 + kSPKRulerTickAreaHeight);
}

- (CGFloat)displayScale {
    CGFloat scale = self.traitCollection.displayScale;
    return scale > 0.0 ? scale : 2.0;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.displayScale != self.traitCollection.displayScale)
        [self setNeedsLayout];
}

- (BOOL)isDragging {
    return _dragging;
}

- (void)setValue:(CGFloat)value {
    CGFloat clamped = MAX(-_maximumValue, MIN(_maximumValue, value));
    if (fabs(clamped - _value) < 0.0001)
        return;
    _value = clamped;
    [self refreshValueLabel];
    [self layoutTicks];
}

- (void)refreshValueLabel {
    CGFloat rounded = round(_value * 10.0) / 10.0;
    if (fabs(rounded) < 0.05) {
        _valueLabel.text = @"0°";
        _valueLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText] ?: [UIColor lightGrayColor];
    } else {
        // A real minus sign, so the digits stay put as the sign flips.
        _valueLabel.text = [NSString stringWithFormat:@"%@%.1f°", rounded < 0.0 ? @"−" : @"", fabs(rounded)];
        _valueLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText] ?: [UIColor whiteColor];
    }
    self.accessibilityValue = _valueLabel.text;
    [self layoutValueLabel];
}

// Centres the digits over the needle, with the minus sign and the degree sign
// hanging outside them: centring the whole string would push "0" off centre by
// half a degree sign, and make the number shift when the sign appears.
- (void)layoutValueLabel {
    NSString *text = _valueLabel.text ?: @"";
    UIFont *font = _valueLabel.font;
    if (!font || text.length == 0)
        return;
    NSDictionary *attributes = @{NSFontAttributeName : font};
    NSString *sign = [text hasPrefix:@"−"] ? @"−" : @"";
    CGFloat signWidth = sign.length > 0 ? ceil([sign sizeWithAttributes:attributes].width) : 0.0;
    CGFloat degreeWidth = [text hasSuffix:@"°"] ? ceil([@"°" sizeWithAttributes:attributes].width) : 0.0;
    CGFloat fullWidth = ceil([text sizeWithAttributes:attributes].width);
    CGFloat digitsWidth = fullWidth - signWidth - degreeWidth;
    CGFloat digitsLeft = round(CGRectGetMidX(self.bounds) - digitsWidth / 2.0);
    _valueLabel.frame = CGRectMake(digitsLeft - signWidth, 0.0, fullWidth, kSPKRulerLabelHeight);
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    [self layoutValueLabel];
    CGFloat tickTop = b.size.height - kSPKRulerTickAreaHeight;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _minorTicks.frame = b;
    _majorTicks.frame = b;
    _fadeMask.frame = b;
    // One mask per layer: a layer can only be the mask of a single parent, so the
    // major ticks get a copy.
    _minorTicks.mask = _fadeMask;
    CAGradientLayer *majorMask = [CAGradientLayer layer];
    majorMask.startPoint = _fadeMask.startPoint;
    majorMask.endPoint = _fadeMask.endPoint;
    majorMask.colors = _fadeMask.colors;
    majorMask.locations = _fadeMask.locations;
    majorMask.frame = b;
    _majorTicks.mask = majorMask;
    CGFloat needleX = SPKRulerAlignedX(CGRectGetMidX(b), [self displayScale]);
    _needle.frame = CGRectMake(needleX - 1.0, tickTop - 3.0, 2.0, kSPKRulerTickAreaHeight + 3.0);
    [CATransaction commit];
    [self layoutTicks];
}

- (void)layoutTicks {
    CGRect b = self.bounds;
    if (b.size.width <= 0.0)
        return;
    CGFloat tickBottom = b.size.height;
    CGFloat tickTop = b.size.height - kSPKRulerTickAreaHeight;
    CGFloat scale = [self displayScale];
    CGFloat centerX = CGRectGetMidX(b);
    UIBezierPath *minor = [UIBezierPath bezierPath];
    UIBezierPath *major = [UIBezierPath bezierPath];
    NSInteger maxDeg = (NSInteger)ceil(_maximumValue);
    for (NSInteger deg = -maxDeg; deg <= maxDeg; deg++) {
        // The ruler slides left as the angle grows, so the needle reads the
        // value off ticks laid out in increasing order left to right.
        CGFloat x = centerX + ((CGFloat)deg - _value) * kSPKRulerPointsPerDegree;
        if (x < -2.0 || x > b.size.width + 2.0)
            continue;
        BOOL isMajor = (deg % 5 == 0);
        CGFloat top = isMajor ? tickTop + 2.0 : tickTop + 8.0;
        UIBezierPath *path = isMajor ? major : minor;
        CGFloat lineX = SPKRulerAlignedX(x, scale);
        [path moveToPoint:CGPointMake(lineX, top)];
        [path addLineToPoint:CGPointMake(lineX, tickBottom - 2.0)];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _minorTicks.path = minor.CGPath;
    _majorTicks.path = major.CGPath;
    [CATransaction commit];
}

#pragma mark - Interaction

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    switch (pan.state) {
    case UIGestureRecognizerStateBegan:
        _dragging = YES;
        _dragStartValue = _value;
        if (!_feedback)
            _feedback = [[UISelectionFeedbackGenerator alloc] init];
        [_feedback prepare];
        [self sendActionsForControlEvents:UIControlEventEditingDidBegin];
        break;
    case UIGestureRecognizerStateChanged: {
        CGFloat dx = [pan translationInView:self].x;
        CGFloat previous = _value;
        self.value = _dragStartValue - dx / kSPKRulerPointsPerDegree;
        // A tick on every whole five degrees, zero and the ends included, so the
        // dial can be felt as it moves.
        if (floor(previous / 5.0) != floor(_value / 5.0) || (previous != _value && fabs(_value) >= _maximumValue)) {
            [_feedback selectionChanged];
            [_feedback prepare];
        }
        [self sendActionsForControlEvents:UIControlEventValueChanged];
        break;
    }
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        _dragging = NO;
        if (fabs(_value) < kSPKRulerZeroSnap && _value != 0.0) {
            self.value = 0.0;
            [self sendActionsForControlEvents:UIControlEventValueChanged];
        }
        [self sendActionsForControlEvents:UIControlEventEditingDidEnd];
        break;
    default:
        break;
    }
}

- (void)handleDoubleTap:(__unused UITapGestureRecognizer *)tap {
    if (_value == 0.0)
        return;
    self.value = 0.0;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    [self sendActionsForControlEvents:UIControlEventEditingDidEnd];
}

- (void)accessibilityIncrement {
    self.value = round(_value) + 1.0;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    [self sendActionsForControlEvents:UIControlEventEditingDidEnd];
}

- (void)accessibilityDecrement {
    self.value = round(_value) - 1.0;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    [self sendActionsForControlEvents:UIControlEventEditingDidEnd];
}

@end
