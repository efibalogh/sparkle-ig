#import "SPKPlaybackPanel.h"

#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../UI/SPKChipGlass.h"
#import "../i18n/SPKStrings.h"
#import "../UI/SPKFont.h"

static CGFloat const kSPKPlaybackPanelWidth = 288.0;
static CGFloat const kSPKPlaybackSpeedRowHeight = 40.0;
static CGFloat const kSPKPlaybackTimeRowHeight = 28.0;
static CGFloat const kSPKPlaybackTransportRowHeight = 48.0;
static CGFloat const kSPKPlaybackPanelPadding = 8.0;
static CGFloat const kSPKPlaybackRowSpacing = 2.0;
static CGFloat const kSPKPlaybackPanelHeight = kSPKPlaybackPanelPadding * 2.0 + kSPKPlaybackSpeedRowHeight +
                                               kSPKPlaybackTimeRowHeight + kSPKPlaybackTransportRowHeight +
                                               kSPKPlaybackRowSpacing * 2.0;
static CGFloat const kSPKPlaybackPanelCornerRadius = 22.0;
static CGFloat const kSPKPlaybackPanelMargin = 12.0;
static double const kSPKPlaybackSkipInterval = 5.0;
// A seek whose completion never arrives must not lock the scrubber for good.
static NSTimeInterval const kSPKPlaybackSeekTimeout = 2.0;
// How long after landing a seek the video gets to buffer before it is nudged.
static NSTimeInterval const kSPKPlaybackSeekResumeGrace = 1.0;

@implementation SPKPlaybackTarget
@end

// MARK: - Palette

// The panel is Liquid Glass on iOS 26 and later, otherwise a system blur
// material. It follows the OS rather than the Liquid Glass toggle because it
// sits beside system context menus, which are glass on iOS 26 regardless of
// that toggle. Both adapt their own legibility, so content uses the dynamic
// system label colors either way.
typedef struct {
    BOOL glass;
} SPKPlaybackPanelStyle;

static SPKPlaybackPanelStyle SPKPlaybackPanelCurrentStyle(void) {
    SPKPlaybackPanelStyle style;
    style.glass = SPKChipGlassAvailable();
    return style;
}

static UIColor *SPKPlaybackPrimaryColor(__unused SPKPlaybackPanelStyle style) {
    return UIColor.labelColor;
}

static UIColor *SPKPlaybackSecondaryColor(__unused SPKPlaybackPanelStyle style) {
    return UIColor.secondaryLabelColor;
}

static UIColor *SPKPlaybackTrackColor(__unused SPKPlaybackPanelStyle style) {
    return [UIColor.labelColor colorWithAlphaComponent:0.18];
}

static UIImage *SPKPlaybackSymbol(NSString *name, CGFloat pointSize, UIImageSymbolWeight weight) {
    return [SPKAssetUtils resolvedImageNamed:name
                                   pointSize:pointSize
                                      weight:weight
                                      source:SPKResolvedImageSourceSystemSymbol
                               renderingMode:UIImageRenderingModeAlwaysTemplate];
}

/// Draws a template glyph a touch heavier by stamping it around a small ring.
/// Instagram's outline glyphs have one fixed stroke, which reads thin once they
/// are scaled below their native size.
static UIImage *SPKPlaybackEmboldenedGlyph(UIImage *image, CGFloat amount) {
    if (!image || amount <= 0.0)
        return image;
    CGSize size = CGSizeMake(image.size.width + amount * 2.0, image.size.height + amount * 2.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = image.scale;
    UIImage *template = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImage *bold = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [UIColor.blackColor setFill];
        for (NSInteger step = 0; step < 8; step++) {
            CGFloat angle = (CGFloat)step * M_PI_4;
            CGPoint origin = CGPointMake(amount + cos(angle) * amount, amount + sin(angle) * amount);
            [[template imageWithTintColor:UIColor.blackColor] drawAtPoint:origin];
        }
        [[template imageWithTintColor:UIColor.blackColor] drawAtPoint:CGPointMake(amount, amount)];
    }];
    return [bold imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static NSString *SPKPlaybackTimeString(double seconds) {
    if (!isfinite(seconds) || seconds < 0.0)
        seconds = 0.0;
    NSInteger total = (NSInteger)floor(seconds);
    NSInteger minutes = total / 60;
    NSInteger remainder = total % 60;
    NSString *secondsText = remainder < 10 ? [NSString stringWithFormat:@"0%ld", (long)remainder]
                                           : [NSString stringWithFormat:@"%ld", (long)remainder];
    return [NSString stringWithFormat:@"%ld:%@", (long)minutes, secondsText];
}

// MARK: - Scrubber

@interface SPKPlaybackScrubber : UIControl
@property (nonatomic, assign) double progress;
@property (nonatomic, assign, readonly, getter=isScrubbing) BOOL scrubbing;
@property (nonatomic, copy) void (^onScrub)(double progress, BOOL finished);
@property (nonatomic, copy) void (^onAccessibilityStep)(NSInteger direction);
- (void)applyStyle:(SPKPlaybackPanelStyle)style;
@end

@implementation SPKPlaybackScrubber {
    UIView *_track;
    UIView *_fill;
    UIView *_thumb;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    _track = [UIView new];
    _track.userInteractionEnabled = NO;
    _track.layer.cornerRadius = 2.0;
    [self addSubview:_track];

    _fill = [UIView new];
    _fill.userInteractionEnabled = NO;
    _fill.layer.cornerRadius = 2.0;
    [self addSubview:_fill];

    _thumb = [UIView new];
    _thumb.userInteractionEnabled = NO;
    _thumb.layer.cornerRadius = 6.0;
    [self addSubview:_thumb];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    self.accessibilityLabel = SPKL(@"PLAYBACK_PANEL_SCRUBBER_ACCESSIBILITY_LABEL");
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, 28.0);
}

- (void)applyStyle:(SPKPlaybackPanelStyle)style {
    _track.backgroundColor = SPKPlaybackTrackColor(style);
    _fill.backgroundColor = SPKPlaybackPrimaryColor(style);
    _thumb.backgroundColor = SPKPlaybackPrimaryColor(style);
}

- (void)setProgress:(double)progress {
    _progress = MIN(1.0, MAX(0.0, isfinite(progress) ? progress : 0.0));
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat thumbSize = _scrubbing ? 16.0 : 12.0;
    CGFloat trackHeight = _scrubbing ? 6.0 : 4.0;
    CGFloat inset = thumbSize / 2.0;
    CGFloat usable = MAX(0.0, CGRectGetWidth(bounds) - thumbSize);
    CGFloat midY = CGRectGetMidY(bounds);
    CGFloat x = inset + usable * _progress;

    _track.frame = CGRectMake(inset, midY - trackHeight / 2.0, usable, trackHeight);
    _track.layer.cornerRadius = trackHeight / 2.0;
    _fill.frame = CGRectMake(inset, midY - trackHeight / 2.0, x - inset, trackHeight);
    _fill.layer.cornerRadius = trackHeight / 2.0;
    _thumb.frame = CGRectMake(x - thumbSize / 2.0, midY - thumbSize / 2.0, thumbSize, thumbSize);
    _thumb.layer.cornerRadius = thumbSize / 2.0;
}

- (double)progressForTouch:(UITouch *)touch {
    CGFloat thumbSize = 16.0;
    CGFloat usable = MAX(1.0, CGRectGetWidth(self.bounds) - thumbSize);
    CGFloat x = [touch locationInView:self].x - thumbSize / 2.0;
    return MIN(1.0, MAX(0.0, x / usable));
}

- (void)setScrubbing:(BOOL)scrubbing {
    if (_scrubbing == scrubbing)
        return;
    _scrubbing = scrubbing;
    [UIView animateWithDuration:0.18
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         [self layoutSubviews];
                     }
                     completion:nil];
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self setScrubbing:YES];
    self.progress = [self progressForTouch:touch];
    if (self.onScrub)
        self.onScrub(self.progress, NO);
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    self.progress = [self progressForTouch:touch];
    if (self.onScrub)
        self.onScrub(self.progress, NO);
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    if (touch)
        self.progress = [self progressForTouch:touch];
    [self setScrubbing:NO];
    if (self.onScrub)
        self.onScrub(self.progress, YES);
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [self setScrubbing:NO];
    if (self.onScrub)
        self.onScrub(self.progress, YES);
}

- (void)accessibilityIncrement {
    if (self.onAccessibilityStep)
        self.onAccessibilityStep(1);
}

- (void)accessibilityDecrement {
    if (self.onAccessibilityStep)
        self.onAccessibilityStep(-1);
}
@end

// MARK: - Menu button

/// Reports when its menu opens and closes, so a tap that only dismisses the menu
/// is not also taken as a tap outside the panel.
@interface SPKPlaybackMenuButton : UIButton
@property (nonatomic, copy) void (^onMenuVisibilityChange)(BOOL visible);
@end

@implementation SPKPlaybackMenuButton
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration
                           animator:(id<UIContextMenuInteractionAnimating>)animator {
    if ([UIButton instancesRespondToSelector:_cmd])
        [super contextMenuInteraction:interaction willDisplayMenuForConfiguration:configuration animator:animator];
    if (self.onMenuVisibilityChange)
        self.onMenuVisibilityChange(YES);
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
       willEndForConfiguration:(UIContextMenuConfiguration *)configuration
                      animator:(id<UIContextMenuInteractionAnimating>)animator {
    if ([UIButton instancesRespondToSelector:_cmd])
        [super contextMenuInteraction:interaction willEndForConfiguration:configuration animator:animator];
    void (^handler)(BOOL) = self.onMenuVisibilityChange;
    if (!handler)
        return;
    if (animator) {
        [animator addCompletion:^{
            handler(NO);
        }];
    } else {
        handler(NO);
    }
}
@end

// MARK: - Panel view



@interface SPKPlaybackPanelView : UIView
@property (nonatomic, weak) UIView *anchor;
/// The view the panel grows out of and covers. Usually the anchor itself.
@property (nonatomic, weak) UIView *source;
@property (nonatomic, assign) SPKPlaybackSurface surface;
@property (nonatomic, strong) SPKPlaybackTarget *target;
@property (nonatomic, copy) void (^onDismissRequest)(void);
/// YES while one of the panel's menus is open or just closing.
@property (nonatomic, assign, readonly) BOOL menuActive;
- (instancetype)initWithSurface:(SPKPlaybackSurface)surface target:(SPKPlaybackTarget *)target;
- (void)refresh;
/// Grows the panel out of `sourceRect` (in the panel's own coordinates).
- (void)morphInFromRect:(CGRect)sourceRect;
/// Collapses the panel back into `targetRect` (in the panel's own coordinates).
/// `landing` runs as the shape reaches the button, the moment to show the button again.
- (void)morphOutToRect:(CGRect)targetRect landing:(void (^)(void))landing completion:(void (^)(void))completion;
@end

@implementation SPKPlaybackPanelView {
    SPKPlaybackPanelStyle _style;
    UIView *_contentHost;
    // The panel's shape. It is animated on its own, so the controls keep their
    // full-size layout while the shape morphs between the button and the panel.
    UIView *_backdropView;
    UIView *_contentMask;
    // Soft shadow around the material panel, hollow inside so it never darkens
    // what shows through the blur (glass casts its own).
    UIView *_shadowView;
    CAShapeLayer *_shadowCutout;
    NSArray<UIView *> *_rows;
    UIButton *_slowerButton;
    SPKPlaybackMenuButton *_speedButton;
    UIButton *_fasterButton;
    UIButton *_playButton;
    UILabel *_elapsedLabel;
    UILabel *_remainingLabel;
    SPKPlaybackScrubber *_scrubber;
    UIButton *_skipBackButton;
    UIButton *_skipForwardButton;
    double _renderedSpeed;
    NSInteger _renderedScope;
    NSInteger _renderedPlaying;
    BOOL _seekInFlight;
    BOOL _hasPendingSeek;
    double _pendingSeekTime;
    double _seekTargetTime;
    BOOL _playingBeforeSeek;
    NSUInteger _seekGeneration;
    CFTimeInterval _menuClosedAt;
    BOOL _morphing;
    NSMutableArray<UIViewPropertyAnimator *> *_morphAnimators;
    NSUInteger _morphGeneration;
    NSUInteger _blurGeneration;
    UISelectionFeedbackGenerator *_selectionFeedback;
    BOOL _menuVisible;
}

- (instancetype)initWithSurface:(SPKPlaybackSurface)surface target:(SPKPlaybackTarget *)target {
    self = [super initWithFrame:CGRectMake(0, 0, kSPKPlaybackPanelWidth, 10)];
    if (!self)
        return nil;

    _surface = surface;
    _target = target;
    _style = SPKPlaybackPanelCurrentStyle();
    _renderedSpeed = -1.0;
    _renderedScope = -1;
    _renderedPlaying = -1;
    _selectionFeedback = [UISelectionFeedbackGenerator new];

    self.accessibilityViewIsModal = YES;

    UIVisualEffect *effect = nil;
    if (_style.glass) {
        Class glassClass = NSClassFromString(@"UIGlassEffect");
        effect = glassClass ? [[glassClass alloc] init] : nil;
        if (![effect isKindOfClass:[UIVisualEffect class]]) {
            effect = nil;
            _style.glass = NO;
        }
    }

    // The same material UIKit's own menus are built on.
    if (!effect)
        effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    UIVisualEffectView *effectView = [[UIVisualEffectView alloc] initWithEffect:effect];
    effectView.clipsToBounds = YES;
    _backdropView = effectView;
    _backdropView.userInteractionEnabled = NO;
    _backdropView.layer.cornerRadius = kSPKPlaybackPanelCornerRadius;
    _backdropView.layer.cornerCurve = kCACornerCurveContinuous;
    _backdropView.frame = self.bounds;
    if (!_style.glass) {
        _shadowView = [[UIView alloc] initWithFrame:self.bounds];
        _shadowView.userInteractionEnabled = NO;
        _shadowView.layer.shadowColor = UIColor.blackColor.CGColor;
        _shadowView.layer.shadowOffset = CGSizeMake(0.0, 10.0);
        _shadowView.layer.shadowRadius = 30.0;
        _shadowCutout = [CAShapeLayer layer];
        _shadowCutout.fillRule = kCAFillRuleEvenOdd;
        _shadowView.layer.mask = _shadowCutout;
        [self addSubview:_shadowView];
    }
    [self addSubview:_backdropView];

    _contentHost = [[UIView alloc] initWithFrame:self.bounds];
    _contentHost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_contentHost];

    [self buildControls];
    [self refresh];
    return self;
}

- (UIButton *)iconButtonWithImage:(UIImage *)image accessibilityLabel:(NSString *)label action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:image forState:UIControlStateNormal];
    button.tintColor = SPKPlaybackPrimaryColor(_style);
    button.accessibilityLabel = label;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:40.0].active = YES;
    [button.heightAnchor constraintEqualToConstant:40.0].active = YES;
    if (action)
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UILabel *)timeLabel {
    UILabel *label = [UILabel new];
    [SPKFont apply:[SPKFont monospacedDigitFontForStyle:SPKFontStyleCaption1 weight:UIFontWeightMedium] to:label];
    label.textColor = SPKPlaybackSecondaryColor(_style);
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    label.text = @"0:00";
    return label;
}

- (void)buildControls {
    UIColor *primary = SPKPlaybackPrimaryColor(_style);

    _slowerButton = [self iconButtonWithImage:SPKPlaybackEmboldenedGlyph([SPKAssetUtils instagramIconNamed:@"subtract" pointSize:20.0], 0.45)
                           accessibilityLabel:SPKL(@"PLAYBACK_PANEL_SLOWER_ACCESSIBILITY_LABEL")
                                       action:@selector(slowerTapped)];
    _fasterButton = [self iconButtonWithImage:SPKPlaybackEmboldenedGlyph([SPKAssetUtils instagramIconNamed:@"add" pointSize:20.0], 0.45)
                           accessibilityLabel:SPKL(@"PLAYBACK_PANEL_FASTER_ACCESSIBILITY_LABEL")
                                       action:@selector(fasterTapped)];

    // A configuration-based button sizes title and indicator as one unit, so the
    // iOS 26 menu morph animates its real bounds instead of clipping the ends.
    _speedButton = [SPKPlaybackMenuButton buttonWithType:UIButtonTypeSystem];
    _speedButton.showsMenuAsPrimaryAction = YES;
    _speedButton.tintColor = primary;
    _speedButton.accessibilityLabel = SPKL(@"PLAYBACK_PANEL_SPEED_ACCESSIBILITY_LABEL");
    _speedButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_speedButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_speedButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_speedButton.heightAnchor constraintEqualToConstant:40.0].active = YES;
    // Fixed to the widest label so changing speed never shifts the - and + buttons.
    [self applySpeedTitle:SPKPlaybackSpeedLabel(1.0)];
    [_speedButton.widthAnchor constraintEqualToConstant:[self widestSpeedButtonWidth]].active = YES;
    __weak __typeof(self) weakSelf = self;
    _speedButton.onMenuVisibilityChange = ^(BOOL visible) {
        [weakSelf menuVisibilityChanged:visible];
    };

    UIStackView *speedCluster = [[UIStackView alloc] initWithArrangedSubviews:@[ _slowerButton, _speedButton, _fasterButton ]];
    speedCluster.axis = UILayoutConstraintAxisHorizontal;
    speedCluster.alignment = UIStackViewAlignmentCenter;
    speedCluster.spacing = 6.0;
    UIStackView *speedRow = [[UIStackView alloc] initWithArrangedSubviews:@[ speedCluster ]];
    speedRow.axis = UILayoutConstraintAxisVertical;
    speedRow.alignment = UIStackViewAlignmentCenter;

    _elapsedLabel = [self timeLabel];
    _remainingLabel = [self timeLabel];
    _remainingLabel.textAlignment = NSTextAlignmentRight;
    _scrubber = [[SPKPlaybackScrubber alloc] initWithFrame:CGRectZero];
    [_scrubber applyStyle:_style];
    _scrubber.onScrub = ^(double progress, BOOL finished) {
        [weakSelf scrubToProgress:progress finished:finished];
    };
    _scrubber.onAccessibilityStep = ^(NSInteger direction) {
        [weakSelf skipBy:kSPKPlaybackSkipInterval * direction];
    };

    UIStackView *timeRow = [[UIStackView alloc] initWithArrangedSubviews:@[ _elapsedLabel, _scrubber, _remainingLabel ]];
    timeRow.axis = UILayoutConstraintAxisHorizontal;
    timeRow.alignment = UIStackViewAlignmentCenter;
    timeRow.spacing = 8.0;
    timeRow.layoutMarginsRelativeArrangement = YES;
    timeRow.layoutMargins = UIEdgeInsetsMake(0, 8.0, 0, 8.0);

    UIImageSymbolConfiguration *skipConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightMedium];
    _skipBackButton = [self iconButtonWithImage:[UIImage systemImageNamed:@"gobackward.5" withConfiguration:skipConfiguration]
                             accessibilityLabel:SPKL(@"PLAYBACK_PANEL_SKIP_BACK_ACCESSIBILITY_LABEL")
                                         action:@selector(skipBackTapped)];
    _skipForwardButton = [self iconButtonWithImage:[UIImage systemImageNamed:@"goforward.5" withConfiguration:skipConfiguration]
                                accessibilityLabel:SPKL(@"PLAYBACK_PANEL_SKIP_FORWARD_ACCESSIBILITY_LABEL")
                                            action:@selector(skipForwardTapped)];
    _playButton = [self iconButtonWithImage:nil accessibilityLabel:nil action:@selector(playTapped)];
    for (NSLayoutConstraint *constraint in _playButton.constraints)
        constraint.constant = 48.0;

    UIStackView *transportCluster = [[UIStackView alloc] initWithArrangedSubviews:@[ _skipBackButton, _playButton, _skipForwardButton ]];
    transportCluster.axis = UILayoutConstraintAxisHorizontal;
    transportCluster.alignment = UIStackViewAlignmentCenter;
    transportCluster.spacing = 28.0;
    UIStackView *transportRow = [[UIStackView alloc] initWithArrangedSubviews:@[ transportCluster ]];
    transportRow.axis = UILayoutConstraintAxisVertical;
    transportRow.alignment = UIStackViewAlignmentCenter;

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[ speedRow, timeRow, transportRow ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = kSPKPlaybackRowSpacing;
    _rows = @[ speedRow, timeRow, transportRow ];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [_contentHost addSubview:column];

    [NSLayoutConstraint activateConstraints:@[
        [column.topAnchor constraintEqualToAnchor:_contentHost.topAnchor constant:kSPKPlaybackPanelPadding],
        [speedRow.heightAnchor constraintEqualToConstant:kSPKPlaybackSpeedRowHeight],
        [timeRow.heightAnchor constraintEqualToConstant:kSPKPlaybackTimeRowHeight],
        [transportRow.heightAnchor constraintEqualToConstant:kSPKPlaybackTransportRowHeight],
        [column.leadingAnchor constraintEqualToAnchor:_contentHost.leadingAnchor constant:10.0],
        [column.trailingAnchor constraintEqualToAnchor:_contentHost.trailingAnchor constant:-10.0],
        [_elapsedLabel.widthAnchor constraintGreaterThanOrEqualToConstant:34.0],
        [_remainingLabel.widthAnchor constraintGreaterThanOrEqualToConstant:40.0],
    ]];
}

- (void)menuVisibilityChanged:(BOOL)visible {
    _menuVisible = visible;
    if (!visible)
        _menuClosedAt = CACurrentMediaTime();
}

- (BOOL)menuActive {
    // The tap that dismisses a menu can reach the window a moment after the
    // menu reports it is closing.
    return _menuVisible || CACurrentMediaTime() - _menuClosedAt < 0.4;
}

- (CGFloat)widestSpeedButtonWidth {
    CGFloat widest = 0.0;
    for (double speed = SPKPlaybackSpeedMinimum; speed <= SPKPlaybackSpeedMaximum + 0.001; speed += SPKPlaybackSpeedStep) {
        [self applySpeedTitle:SPKPlaybackSpeedLabel(speed)];
        widest = MAX(widest, [_speedButton systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].width);
    }
    return ceil(widest);
}

- (void)applySpeedTitle:(NSString *)title {
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.baseForegroundColor = SPKPlaybackPrimaryColor(_style);
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(4.0, 10.0, 4.0, 8.0);
    configuration.image = SPKPlaybackSymbol(@"chevron.up.chevron.down", 11.0, UIImageSymbolWeightSemibold);
    configuration.imagePlacement = NSDirectionalRectEdgeTrailing;
    configuration.imagePadding = 5.0;
    NSDictionary *attributes = @{NSFontAttributeName : [SPKFont monospacedDigitFontForStyle:SPKFontStyleTitle3 weight:UIFontWeightSemibold]};
    configuration.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:attributes];
    _speedButton.configuration = configuration;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!_morphing) {
        _backdropView.frame = self.bounds;
        _contentMask.frame = self.bounds;
    }
    [self layoutShadow];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self layoutShadow];
}

/// The shadow is laid out for the settled panel only; during a morph it is faded
/// out, since a static path could not follow the moving shape.
- (void)layoutShadow {
    if (!_shadowView)
        return;
    CGRect bounds = self.bounds;
    _shadowView.frame = bounds;
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:kSPKPlaybackPanelCornerRadius];
    _shadowView.layer.shadowPath = shape.CGPath;
    // Darker in dark mode, where a light shadow would disappear into the video.
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    _shadowView.layer.shadowOpacity = dark ? 0.38 : 0.14;

    // Everything around the panel, minus the panel itself.
    static CGFloat const spread = 150.0;
    UIBezierPath *cutout = [UIBezierPath bezierPathWithRect:CGRectInset(bounds, -spread, -spread)];
    [cutout appendPath:shape];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shadowCutout.frame = _shadowView.layer.bounds;
    _shadowCutout.path = cutout.CGPath;
    [CATransaction commit];
}

// MARK: Morph

// Motion runs on Core Animation's render server through property animators, so
// a busy main thread (Reels decoding, feed layout) can't drop frames. Opening and
// closing never overlap: closing first freezes every running opening animation
// at its on-screen value, and each blur cleanup is tied to the run that started it.

static CGFloat const kSPKPlaybackMorphBlur = 8.0;
static NSString *const kSPKPlaybackBlurKeyPath = @"filters.gaussianBlur.inputRadius";

/// The shape a button has before it becomes the panel: its own frame, as a capsule.
static CGRect SPKPlaybackMorphSourceRect(CGRect rect) {
    CGFloat side = MAX(36.0, MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)));
    CGPoint center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGFloat width = MAX(side, CGRectGetWidth(rect));
    return CGRectMake(center.x - width / 2.0, center.y - side / 2.0, width, side);
}

static UIViewPropertyAnimator *SPKPlaybackSpringAnimator(NSTimeInterval duration, CGFloat damping, void (^animations)(void)) {
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithDampingRatio:damping];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:timing];
    [animator addAnimations:animations];
    animator.interruptible = YES;
    return animator;
}

- (void)ensureContentMask {
    if (_contentMask)
        return;
    _contentMask = [[UIView alloc] initWithFrame:self.bounds];
    _contentMask.backgroundColor = UIColor.blackColor;
    _contentMask.layer.cornerRadius = kSPKPlaybackPanelCornerRadius;
    _contentMask.layer.cornerCurve = kCACornerCurveContinuous;
    _contentHost.maskView = _contentMask;
}

/// +1 when the button sits below the panel's middle, -1 when above. Motion
/// travels away from the button, so the panel reads as coming out of it.
- (CGFloat)directionFromRect:(CGRect)rect {
    return CGRectGetMidY(rect) >= CGRectGetMidY(self.bounds) ? 1.0 : -1.0;
}

- (void)setShapeFrame:(CGRect)frame radius:(CGFloat)radius {
    _backdropView.frame = frame;
    _backdropView.layer.cornerRadius = radius;
    _contentMask.frame = frame;
    _contentMask.layer.cornerRadius = radius;
}

- (void)runAnimator:(UIViewPropertyAnimator *)animator afterDelay:(NSTimeInterval)delay {
    [_morphAnimators addObject:animator];
    if (delay > 0.0)
        [animator startAnimationAfterDelay:delay];
    else
        [animator startAnimation];
}

/// Stops every running animation where it currently is on screen.
- (void)freezeMorph {
    for (UIViewPropertyAnimator *animator in _morphAnimators) {
        if (animator.state == UIViewAnimatingStateActive)
            [animator stopAnimation:YES];
    }
    [_morphAnimators removeAllObjects];
}

- (CGFloat)presentedBlur {
    CALayer *presentation = _contentHost.layer.presentationLayer;
    id value = nil;
    @try {
        value = [presentation valueForKeyPath:kSPKPlaybackBlurKeyPath];
    } @catch (__unused NSException *exception) {
    }
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
}

/// Animates the content's gaussian blur. The filter is dropped once a run that
/// ends at zero finishes, unless a newer run has started since.
- (void)animateBlurFrom:(CGFloat)from to:(CGFloat)to duration:(CFTimeInterval)duration {
    CALayer *layer = _contentHost.layer;
    Class filterClass = NSClassFromString(@"CAFilter");
    SEL filterWithType = NSSelectorFromString(@"filterWithType:");
    NSUInteger generation = ++_blurGeneration;
    [layer removeAnimationForKey:@"spk_blur"];
    if (![filterClass respondsToSelector:filterWithType] || (from <= 0.0 && to <= 0.0)) {
        layer.filters = nil;
        return;
    }
    @try {
        id filter = ((id (*)(id, SEL, NSString *))objc_msgSend)(filterClass, filterWithType, @"gaussianBlur");
        [filter setValue:@"gaussianBlur" forKey:@"name"];
        [filter setValue:@(to) forKey:@"inputRadius"];
        layer.filters = @[ filter ];

        __weak __typeof(self) weakSelf = self;
        [CATransaction begin];
        [CATransaction setCompletionBlock:^{
            __typeof(self) strongSelf = weakSelf;
            if (strongSelf && to <= 0.0 && strongSelf->_blurGeneration == generation)
                layer.filters = nil;
        }];
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:kSPKPlaybackBlurKeyPath];
        animation.fromValue = @(from);
        animation.toValue = @(to);
        animation.duration = duration;
        animation.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.0 :0.0 :1.0];
        [layer addAnimation:animation forKey:@"spk_blur"];
        [CATransaction commit];
    } @catch (__unused NSException *exception) {
        layer.filters = nil;
    }
}

- (void)morphInFromRect:(CGRect)sourceRect {
    if (!_morphAnimators)
        _morphAnimators = [NSMutableArray array];
    [self freezeMorph];
    NSUInteger generation = ++_morphGeneration;

    if (UIAccessibilityIsReduceMotionEnabled()) {
        self.alpha = 0.0;
        [self runAnimator:[[UIViewPropertyAnimator alloc] initWithDuration:0.18 curve:UIViewAnimationCurveEaseOut animations:^{
                  self.alpha = 1.0;
              }]
               afterDelay:0.0];
        return;
    }

    CGRect bounds = self.bounds;
    CGRect start = SPKPlaybackMorphSourceRect(sourceRect);
    CGFloat direction = [self directionFromRect:start];
    [self ensureContentMask];
    _morphing = YES;

    // Starting state, committed before any animation begins.
    [UIView performWithoutAnimation:^{
        [self setShapeFrame:start radius:CGRectGetHeight(start) / 2.0];
        self->_backdropView.alpha = 0.0;
        self->_shadowView.alpha = 0.0;
        self->_contentHost.alpha = 0.0;
        self->_contentHost.transform = CGAffineTransformMakeScale(0.92, 0.92);
    }];

    // Shape: out of the button on a firm spring, fading up over the first frames.
    UIViewPropertyAnimator *shape = SPKPlaybackSpringAnimator(0.34, 0.88, ^{
        [self setShapeFrame:bounds radius:kSPKPlaybackPanelCornerRadius];
        self->_contentHost.transform = CGAffineTransformIdentity;
    });
    __weak __typeof(self) weakSelf = self;
    [shape addCompletion:^(UIViewAnimatingPosition position) {
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || position != UIViewAnimatingPositionEnd || strongSelf->_morphGeneration != generation)
            return;
        strongSelf->_morphing = NO;
        [strongSelf setNeedsLayout];
    }];
    [self runAnimator:shape afterDelay:0.0];
    [self runAnimator:[[UIViewPropertyAnimator alloc] initWithDuration:0.07 curve:UIViewAnimationCurveEaseOut animations:^{
              self->_backdropView.alpha = 1.0;
          }]
           afterDelay:0.0];

    // The shadow settles in as the shape reaches its final size.
    if (_shadowView) {
        [self runAnimator:[[UIViewPropertyAnimator alloc] initWithDuration:0.2 curve:UIViewAnimationCurveEaseOut animations:^{
                  self->_shadowView.alpha = 1.0;
              }]
               afterDelay:0.14];
    }

    // Controls: quick fade and a short sharpen as the shape opens.
    [self runAnimator:[[UIViewPropertyAnimator alloc] initWithDuration:0.16 curve:UIViewAnimationCurveEaseOut animations:^{
              self->_contentHost.alpha = 1.0;
          }]
           afterDelay:0.03];
    [self animateBlurFrom:kSPKPlaybackMorphBlur to:0.0 duration:0.22];

    // Rows ripple out of the button, nearest first.
    NSArray<UIView *> *rows = direction > 0 ? _rows.reverseObjectEnumerator.allObjects : _rows;
    [rows enumerateObjectsUsingBlock:^(UIView *row, NSUInteger index, __unused BOOL *stop) {
        [UIView performWithoutAnimation:^{
            row.alpha = 0.0;
            row.transform = CGAffineTransformMakeTranslation(0.0, 8.0 * direction);
        }];
        [self runAnimator:SPKPlaybackSpringAnimator(0.32, 0.9, ^{
                  row.alpha = 1.0;
                  row.transform = CGAffineTransformIdentity;
              })
               afterDelay:0.03 + 0.025 * index];
    }];
}

- (void)morphOutToRect:(CGRect)targetRect landing:(void (^)(void))landing completion:(void (^)(void))completion {
    if (!_morphAnimators)
        _morphAnimators = [NSMutableArray array];
    CGFloat blur = [self presentedBlur];
    [self freezeMorph];
    NSUInteger generation = ++_morphGeneration;
    _morphing = YES;

    if (UIAccessibilityIsReduceMotionEnabled()) {
        if (landing)
            landing();
        UIViewPropertyAnimator *fade = [[UIViewPropertyAnimator alloc] initWithDuration:0.15 curve:UIViewAnimationCurveEaseIn animations:^{
            self.alpha = 0.0;
        }];
        [fade addCompletion:^(__unused UIViewAnimatingPosition position) {
            if (completion)
                completion();
        }];
        [self runAnimator:fade afterDelay:0.0];
        return;
    }

    CGRect end = SPKPlaybackMorphSourceRect(targetRect);
    CGFloat direction = [self directionFromRect:end];
    [self ensureContentMask];
    for (UIView *row in _rows) {
        // Rows still mid-ripple join the content's exit instead of popping.
        row.transform = CGAffineTransformIdentity;
    }

    // Controls and shadow leave first, then the shape drains back into the button.
    [self animateBlurFrom:blur to:kSPKPlaybackMorphBlur duration:0.1];
    [self runAnimator:[[UIViewPropertyAnimator alloc] initWithDuration:0.09 curve:UIViewAnimationCurveEaseIn animations:^{
              self->_shadowView.alpha = 0.0;
              self->_contentHost.alpha = 0.0;
              self->_contentHost.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(0.0, 4.0 * direction), 0.96, 0.96);
          }]
           afterDelay:0.0];

    static NSTimeInterval const collapseDuration = 0.22;
    static CGFloat const landingFactor = 0.5;
    UIViewPropertyAnimator *collapse = [[UIViewPropertyAnimator alloc] initWithDuration:collapseDuration
                                                                         controlPoint1:CGPointMake(0.3, 0.0)
                                                                         controlPoint2:CGPointMake(0.1, 1.0)
                                                                            animations:^{
                                                                                [self setShapeFrame:end radius:CGRectGetHeight(end) / 2.0];
                                                                            }];
    [collapse addAnimations:^{
        self->_backdropView.alpha = 0.0;
    } delayFactor:landingFactor];
    __block BOOL landed = NO;
    __weak __typeof(self) weakSelf = self;
    void (^land)(void) = ^{
        if (landed)
            return;
        landed = YES;
        if (landing)
            landing();
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(collapseDuration * landingFactor * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_morphGeneration == generation)
            land();
    });
    [collapse addCompletion:^(__unused UIViewAnimatingPosition position) {
        land();
        if (completion)
            completion();
    }];
    [self runAnimator:collapse afterDelay:0.0];
}

- (CGSize)sizeThatFits:(CGSize)size {
    // Every row has a fixed height, so the panel's size is known up front. Auto
    // layout fitting ran before the glass content view had laid out on first
    // presentation and returned an inflated height.
    return CGSizeMake(kSPKPlaybackPanelWidth, kSPKPlaybackPanelHeight);
}

// MARK: State

- (id)speedItem {
    return self.target.speedItem ? self.target.speedItem() : nil;
}

- (double)currentSpeed {
    return SPKPlaybackSpeedEffective(self.surface, [self speedItem]);
}

- (double)duration {
    double duration = self.target.duration ? self.target.duration() : 0.0;
    return isfinite(duration) && duration > 0.0 ? duration : 0.0;
}

- (BOOL)targetAvailable {
    return self.target.isAvailable ? self.target.isAvailable() : NO;
}

- (void)refresh {
    if (![self targetAvailable]) {
        if (self.onDismissRequest)
            self.onDismissRequest();
        return;
    }

    double speed = [self currentSpeed];
    if (fabs(speed - _renderedSpeed) > 0.001) {
        _renderedSpeed = speed;
        NSString *label = SPKPlaybackSpeedLabel(speed);
        [UIView performWithoutAnimation:^{
            [self applySpeedTitle:label];
            [self->_speedButton layoutIfNeeded];
        }];
        _speedButton.accessibilityValue = label;
        _slowerButton.enabled = speed > SPKPlaybackSpeedMinimum + 0.001;
        _fasterButton.enabled = speed < SPKPlaybackSpeedMaximum - 0.001;
        _renderedScope = -1;
    }

    SPKPlaybackSpeedScope scope = SPKPlaybackSpeedCurrentScope(self.surface);
    if (scope != _renderedScope) {
        _renderedScope = scope;
        _speedButton.menu = [self speedMenuForSpeed:speed];
    }

    BOOL playing = self.target.isPlaying ? self.target.isPlaying() : NO;
    if ((NSInteger)playing != _renderedPlaying) {
        _renderedPlaying = playing;
        UIImage *glyph = playing ? [SPKAssetUtils instagramIconNamed:@"video_pause" pointSize:36.0]
                                 : [SPKAssetUtils instagramIconNamed:@"video_play" pointSize:36.0];
        [_playButton setImage:glyph forState:UIControlStateNormal];
        _playButton.accessibilityLabel = playing ? SPKL(@"PLAYBACK_PANEL_PAUSE_ACCESSIBILITY_LABEL")
                                                 : SPKL(@"PLAYBACK_PANEL_PLAY_ACCESSIBILITY_LABEL");
    }

    double duration = [self duration];
    // While a seek is landing the player still reports the old time; holding the
    // thumb avoids a jump back to it.
    if (!_scrubber.isScrubbing && ![self isSeeking]) {
        double current = self.target.currentTime ? self.target.currentTime() : 0.0;
        current = isfinite(current) ? MIN(MAX(current, 0.0), duration) : 0.0;
        _scrubber.progress = duration > 0.0 ? current / duration : 0.0;
        [self updateTimeLabelsWithCurrent:current duration:duration];
    }
    _scrubber.enabled = duration > 0.0;
    _skipBackButton.enabled = duration > 0.0;
    _skipForwardButton.enabled = duration > 0.0;
}

- (void)updateTimeLabelsWithCurrent:(double)current duration:(double)duration {
    _elapsedLabel.text = SPKPlaybackTimeString(current);
    _remainingLabel.text = [@"-" stringByAppendingString:SPKPlaybackTimeString(MAX(0.0, duration - current))];
    _scrubber.accessibilityValue = [NSString stringWithFormat:@"%@ / %@", SPKPlaybackTimeString(current), SPKPlaybackTimeString(duration)];
}

// MARK: Menus

- (UIMenu *)speedMenuForSpeed:(double)speed {
    NSMutableArray<UIMenuElement *> *presets = [NSMutableArray array];
    __weak __typeof(self) weakSelf = self;
    // Fastest first, so the list reads top to bottom like a dial above the button.
    for (NSNumber *preset in SPKPlaybackSpeedPresets().reverseObjectEnumerator) {
        double value = preset.doubleValue;
        UIAction *action = [UIAction actionWithTitle:SPKPlaybackSpeedLabel(value)
                                               image:nil
                                          identifier:nil
                                             handler:^(__unused UIAction *a) {
                                                 [weakSelf setSpeed:value];
                                             }];
        action.state = fabs(value - speed) < 0.001 ? UIMenuElementStateOn : UIMenuElementStateOff;
        [presets addObject:action];
    }

    SPKPlaybackSpeedScope scope = SPKPlaybackSpeedCurrentScope(self.surface);
    NSMutableArray<UIMenuElement *> *scopes = [NSMutableArray array];
    for (NSNumber *value in @[ @(SPKPlaybackSpeedScopeVideo), @(SPKPlaybackSpeedScopeSession), @(SPKPlaybackSpeedScopeAlways) ]) {
        SPKPlaybackSpeedScope option = (SPKPlaybackSpeedScope)value.integerValue;
        UIAction *action = [UIAction actionWithTitle:SPKPlaybackSpeedScopeTitle(option)
                                               image:nil
                                          identifier:nil
                                             handler:^(__unused UIAction *a) {
                                                 [weakSelf selectScope:option];
                                             }];
        action.state = option == scope ? UIMenuElementStateOn : UIMenuElementStateOff;
        [scopes addObject:action];
    }
    UIMenu *scopeMenu = [UIMenu menuWithTitle:SPKL(@"PLAYBACK_PANEL_KEEP_SPEED_TITLE")
                                        image:nil
                                   identifier:nil
                                      options:0
                                     children:scopes];
    scopeMenu.subtitle = SPKPlaybackSpeedScopeTitle(scope);

    UIMenu *presetSection = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:presets];
    return [UIMenu menuWithTitle:SPKL(@"PLAYBACK_PANEL_SPEED_MENU_TITLE") children:@[ presetSection, scopeMenu ]];
}

// MARK: Actions

- (void)setSpeed:(double)speed {
    speed = SPKPlaybackSpeedClamp(speed);
    id item = [self speedItem];
    SPKPlaybackSpeedSetForItem(self.surface, speed, item);
    if (self.target.applySpeed)
        self.target.applySpeed(SPKPlaybackSpeedEffective(self.surface, item));
    [_selectionFeedback selectionChanged];
    [self refresh];
}

- (void)slowerTapped {
    [self setSpeed:[self currentSpeed] - SPKPlaybackSpeedStep];
}

- (void)fasterTapped {
    [self setSpeed:[self currentSpeed] + SPKPlaybackSpeedStep];
}

- (void)selectScope:(SPKPlaybackSpeedScope)scope {
    SPKPlaybackSpeedSetScope(self.surface, scope, [self speedItem]);
    [_selectionFeedback selectionChanged];
    [self refresh];
}

- (void)playTapped {
    if (self.target.togglePlayback)
        self.target.togglePlayback();
    [_selectionFeedback selectionChanged];
    // Players report the new state a beat later; force a re-render then.
    _renderedPlaying = -1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_renderedPlaying = -1;
        [self refresh];
    });
}

- (void)skipBy:(double)delta {
    double duration = [self duration];
    if (duration <= 0.0 || !self.target.seek)
        return;
    // Repeated taps build on the position already requested, not the stale clock.
    double current = [self isSeeking] ? (_hasPendingSeek ? _pendingSeekTime : _seekTargetTime)
                                      : (self.target.currentTime ? self.target.currentTime() : 0.0);
    double time = MIN(MAX(current + delta, 0.0), MAX(0.0, duration - 0.1));
    [self requestSeekToTime:time];
    _scrubber.progress = time / duration;
    [self updateTimeLabelsWithCurrent:time duration:duration];
}

- (void)skipBackTapped {
    [self skipBy:-kSPKPlaybackSkipInterval];
    [_selectionFeedback selectionChanged];
}

- (void)skipForwardTapped {
    [self skipBy:kSPKPlaybackSkipInterval];
    [_selectionFeedback selectionChanged];
}

- (void)scrubToProgress:(double)progress finished:(BOOL)finished {
    double duration = [self duration];
    if (duration <= 0.0 || !self.target.seek)
        return;
    double time = MIN(progress * duration, MAX(0.0, duration - 0.1));
    [self updateTimeLabelsWithCurrent:time duration:duration];
    // Dragging only previews the position; the player seeks once on release.
    if (finished)
        [self requestSeekToTime:time];
}

// MARK: Seeking

- (BOOL)isSeeking {
    return _seekInFlight || _hasPendingSeek;
}

- (void)requestSeekToTime:(double)time {
    if (_seekInFlight) {
        _hasPendingSeek = YES;
        _pendingSeekTime = time;
        return;
    }
    _playingBeforeSeek = self.target.isPlaying ? self.target.isPlaying() : NO;
    [self performSeekToTime:time];
}

- (void)performSeekToTime:(double)time {
    _seekInFlight = YES;
    _seekTargetTime = time;
    NSUInteger generation = ++_seekGeneration;
    __weak __typeof(self) weakSelf = self;
    void (^landed)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf seekDidLandForGeneration:generation];
        });
    };
    self.target.seek(time, landed);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKPlaybackSeekTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), landed);
}

- (void)seekDidLandForGeneration:(NSUInteger)generation {
    // Ignores the timeout of a seek that already landed, and vice versa.
    if (!_seekInFlight || generation != _seekGeneration)
        return;
    _seekInFlight = NO;
    if (_hasPendingSeek) {
        _hasPendingSeek = NO;
        [self performSeekToTime:_pendingSeekTime];
        return;
    }
    if (!_playingBeforeSeek || !self.target.resumeAfterSeek)
        return;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKPlaybackSeekResumeGrace * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_seekGeneration || [strongSelf isSeeking] || strongSelf->_scrubber.isScrubbing)
            return;
        SPKPlaybackTarget *target = strongSelf.target;
        BOOL available = target.isAvailable ? target.isAvailable() : NO;
        BOOL playing = target.isPlaying ? target.isPlaying() : NO;
        if (available && !playing)
            target.resumeAfterSeek();
    });
}
@end

// MARK: - Presentation

@interface SPKPlaybackPanelWindow : UIWindow
@property (nonatomic, weak) SPKPlaybackPanelView *panel;
@end

@implementation SPKPlaybackPanelWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit && hit != self && hit != self.rootViewController.view)
        return hit; // the panel, or a menu UIKit presented from it

    // A touch outside the panel closes it and is consumed, so it can't also
    // pause, skip or scroll the content underneath. While a menu is open that
    // touch only closes the menu.
    if (event.type == UIEventTypeTouches && !self.panel.menuActive) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKPlaybackPanelDismiss(YES);
        });
    }
    return self.rootViewController.view;
}

- (BOOL)canBecomeKeyWindow {
    return NO;
}
@end

@interface SPKPlaybackPanelRootViewController : UIViewController
@end

@implementation SPKPlaybackPanelRootViewController
- (void)loadView {
    UIView *view = [UIView new];
    view.backgroundColor = UIColor.clearColor;
    self.view = view;
}
@end

@interface SPKPlaybackPanelPresenter : NSObject
@property (nonatomic, strong) SPKPlaybackPanelWindow *window;
@property (nonatomic, strong) SPKPlaybackPanelView *panel;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL dismissing;
@property (nonatomic, strong) CALayer *concealMask;
@property (nonatomic, weak) UIView *concealedAnchor;
@property (nonatomic, strong) CALayer *previousAnchorMask;
+ (instancetype)shared;
@end

@implementation SPKPlaybackPanelPresenter

+ (instancetype)shared {
    static SPKPlaybackPanelPresenter *presenter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        presenter = [SPKPlaybackPanelPresenter new];
        [[NSNotificationCenter defaultCenter] addObserver:presenter
                                                 selector:@selector(applicationWillResignActive)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];
    });
    return presenter;
}

- (void)applicationWillResignActive {
    [self dismissAnimated:NO];
}

- (CGRect)anchorFrameInWindow:(UIView *)anchor {
    CGRect anchorFrame = [anchor convertRect:anchor.bounds toView:nil];
    if (anchor.window && self.window && anchor.window != (UIWindow *)self.window) {
        anchorFrame = [anchor.window convertRect:anchorFrame toCoordinateSpace:anchor.window.screen.coordinateSpace];
        anchorFrame = [self.window convertRect:anchorFrame fromCoordinateSpace:self.window.screen.coordinateSpace];
    }
    return anchorFrame;
}

- (CGRect)anchorRectInPanel:(SPKPlaybackPanelView *)panel anchor:(UIView *)anchor {
    UIView *host = panel.superview;
    CGRect rect = [self anchorFrameInWindow:anchor];
    return host ? [panel convertRect:rect fromView:host] : rect;
}

/// Places the panel over the button, the way a system menu opens on top of its
/// source: the panel's corner nearest the button lines up with the button's
/// corner, so the button is covered and the panel reads as the button expanding.
- (CGRect)panelFrameForSize:(CGSize)size anchor:(UIView *)anchor {
    CGRect bounds = self.window.bounds;
    UIEdgeInsets safe = self.window.safeAreaInsets;
    // A little past the button, so the panel's rounded corner still covers it.
    static CGFloat const outset = 6.0;
    CGRect anchorFrame = CGRectInset([self anchorFrameInWindow:anchor], -outset, -outset);

    CGFloat minX = MAX(kSPKPlaybackPanelMargin, safe.left + kSPKPlaybackPanelMargin);
    CGFloat maxX = CGRectGetWidth(bounds) - MAX(kSPKPlaybackPanelMargin, safe.right + kSPKPlaybackPanelMargin) - size.width;
    BOOL anchorOnTrailingSide = CGRectGetMidX(anchorFrame) >= CGRectGetMidX(bounds);
    CGFloat x = anchorOnTrailingSide ? CGRectGetMaxX(anchorFrame) - size.width : CGRectGetMinX(anchorFrame);
    x = MIN(MAX(x, minX), MAX(minX, maxX));

    CGFloat minY = safe.top + kSPKPlaybackPanelMargin;
    CGFloat maxY = CGRectGetHeight(bounds) - safe.bottom - kSPKPlaybackPanelMargin - size.height;
    // Grow upward from the button when there's room, otherwise downward.
    CGFloat y = CGRectGetMaxY(anchorFrame) - size.height;
    if (y < minY)
        y = CGRectGetMinY(anchorFrame);
    y = MIN(MAX(y, minY), MAX(minY, maxY));
    return CGRectMake(x, y, size.width, size.height);
}

/// Hides the button under the panel without touching its alpha or hidden state,
/// which Instagram drives (and which the panel watches to close itself).
- (void)setAnchor:(UIView *)anchor concealed:(BOOL)concealed {
    CALayer *layer = anchor.layer;
    if (concealed) {
        if (!layer || self.concealMask)
            return;
        self.concealMask = [CALayer layer];
        self.concealedAnchor = anchor;
        self.previousAnchorMask = layer.mask;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.mask = self.concealMask;
        [CATransaction commit];
        return;
    }
    if (!self.concealMask)
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (layer.mask == self.concealMask)
        layer.mask = self.previousAnchorMask;
    [CATransaction commit];
    self.concealMask = nil;
    self.concealedAnchor = nil;
    self.previousAnchorMask = nil;
}

- (void)presentFromAnchor:(UIView *)anchor source:(UIView *)source surface:(SPKPlaybackSurface)surface target:(SPKPlaybackTarget *)target {
    UIWindowScene *scene = anchor.window.windowScene;
    if (!scene)
        return;

    [self dismissAnimated:NO];
    self.dismissing = NO;

    SPKPlaybackPanelWindow *window = [[SPKPlaybackPanelWindow alloc] initWithWindowScene:scene];
    window.rootViewController = [SPKPlaybackPanelRootViewController new];
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.windowLevel = UIWindowLevelStatusBar - 1.0;
    window.frame = scene.coordinateSpace.bounds;
    // Follow the button's own appearance rather than its window's: Instagram keeps
    // some surfaces (Reels) dark regardless of the app theme, and the panel and its
    // menus should match the surface they open over.
    window.overrideUserInterfaceStyle = anchor.traitCollection.userInterfaceStyle;
    window.hidden = NO;
    self.window = window;

    SPKPlaybackPanelView *panel = [[SPKPlaybackPanelView alloc] initWithSurface:surface target:target];
    panel.anchor = anchor;
    panel.source = source;
    panel.onDismissRequest = ^{
        SPKPlaybackPanelDismiss(YES);
    };
    window.panel = panel;
    self.panel = panel;

    UIView *host = window.rootViewController.view;
    host.frame = window.bounds;
    [host addSubview:panel];
    [host layoutIfNeeded];
    CGSize size = [panel sizeThatFits:CGSizeMake(kSPKPlaybackPanelWidth, CGFLOAT_MAX)];
    CGRect frame = [self panelFrameForSize:size anchor:source];
    panel.frame = frame;
    [panel layoutIfNeeded];

    [panel morphInFromRect:[self anchorRectInPanel:panel anchor:source]];
    // A panel still collapsing from a previous button hands that button back first.
    [self setAnchor:self.concealedAnchor concealed:NO];
    [self setAnchor:source concealed:YES];

    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, panel);

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    self.displayLink.preferredFramesPerSecond = 12;
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)tick {
    SPKPlaybackPanelView *panel = self.panel;
    UIView *anchor = panel.anchor;
    if (!panel || !anchor || !anchor.window || anchor.hidden || anchor.alpha < 0.01) {
        [self dismissAnimated:YES];
        return;
    }
    [panel refresh];
}

- (void)dismissAnimated:(BOOL)animated {
    [self.displayLink invalidate];
    self.displayLink = nil;

    SPKPlaybackPanelWindow *window = self.window;
    SPKPlaybackPanelView *panel = self.panel;
    self.window = nil;
    self.panel = nil;
    if (!window)
        return;

    __weak __typeof(self) weakSelf = self;
    UIView *concealedAnchor = self.concealedAnchor;
    CALayer *concealMask = self.concealMask;
    void (^reveal)(void) = ^{
        // A newer panel may already have concealed a button of its own.
        if (weakSelf.concealMask == concealMask)
            [weakSelf setAnchor:concealedAnchor concealed:NO];
    };
    void (^teardown)(void) = ^{
        reveal();
        window.hidden = YES;
        window.rootViewController = nil;
    };

    if (!animated || !panel) {
        teardown();
        return;
    }

    window.userInteractionEnabled = NO;
    // Collapse into the view the panel came from while it's still showing, else
    // into the anchor (a source like a speed label can go away at normal speed).
    UIView *home = panel.source;
    if (!home.window || home.hidden)
        home = panel.anchor;
    // A home that has left the screen has nowhere to collapse into; shrink in place.
    CGRect targetRect = home.window ? [self anchorRectInPanel:panel anchor:home]
                                    : CGRectInset(panel.bounds, CGRectGetWidth(panel.bounds) * 0.3, CGRectGetHeight(panel.bounds) * 0.3);
    [panel morphOutToRect:targetRect landing:reveal completion:teardown];
}
@end

void SPKPlaybackPanelPresent(UIView *anchor, SPKPlaybackSurface surface, SPKPlaybackTarget *target) {
    if (!anchor || !target)
        return;
    SPKPlaybackPanelPresentFromSource(anchor, anchor, surface, target);
}

void SPKPlaybackPanelPresentFromSource(UIView *anchor, UIView *source, SPKPlaybackSurface surface, SPKPlaybackTarget *target) {
    if (!anchor || !target)
        return;
    [[SPKPlaybackPanelPresenter shared] presentFromAnchor:anchor source:source.window ? source : anchor surface:surface target:target];
}

void SPKPlaybackPanelDismiss(BOOL animated) {
    [[SPKPlaybackPanelPresenter shared] dismissAnimated:animated];
}

void SPKPlaybackPanelAdoptSource(UIView *anchor, UIView *source) {
    SPKPlaybackPanelPresenter *presenter = [SPKPlaybackPanelPresenter shared];
    SPKPlaybackPanelView *panel = presenter.panel;
    if (!panel || !source || panel.anchor != anchor || panel.source == source)
        return;
    // Only replaces a source that went away. A panel growing out of the anchor
    // itself keeps covering the anchor.
    UIView *current = panel.source;
    if (current == anchor || (current.window && !current.hidden))
        return;
    [presenter setAnchor:current concealed:NO];
    panel.source = source;
    [presenter setAnchor:source concealed:YES];
}

BOOL SPKPlaybackPanelIsPresentedForAnchor(UIView *anchor) {
    SPKPlaybackPanelPresenter *presenter = [SPKPlaybackPanelPresenter shared];
    if (!presenter.panel)
        return NO;
    return anchor == nil || presenter.panel.anchor == anchor;
}
