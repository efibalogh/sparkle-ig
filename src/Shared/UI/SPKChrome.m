#import "SPKChrome.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import <objc/message.h>
#import <objc/runtime.h>

NSNotificationName const SPKHideUIOnCapturePreferenceDidChangeNotification = @"SPKHideUIOnCapturePreferenceDidChangeNotification";

static char kSPKChromeOwnedSecureFieldKey;

static void spkEnableExtendedDynamicRangeLayer(CALayer *layer) {
    if (!layer)
        return;

    // The iOS 16.2 SDK used by Sparkle does not declare this newer CALayer
    // property, so use the runtime selector when the installed OS supports it.
    SEL selector = NSSelectorFromString(@"setWantsExtendedDynamicRangeContent:");
    if ([layer respondsToSelector:selector])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, selector, YES);
}

void SPKChromeEnableExtendedDynamicRangeContent(UIView *view) {
    if (!view)
        return;

    spkEnableExtendedDynamicRangeLayer(view.layer);

    // SPKChromeButton keeps its icon outside UIButton's normal imageView path.
    // Handle both forms so this helper also remains useful for regular UIButtons.
    UIImageView *imageView = nil;
    if ([view isKindOfClass:[SPKChromeButton class]]) {
        imageView = ((SPKChromeButton *)view).iconView;
    } else if ([view isKindOfClass:[UIButton class]]) {
        imageView = ((UIButton *)view).imageView;
    } else if ([view isKindOfClass:[UIImageView class]]) {
        imageView = (UIImageView *)view;
    }

    if (!imageView)
        return;

    spkEnableExtendedDynamicRangeLayer(imageView.layer);
    UIView *ancestor = imageView.superview;
    for (NSInteger depth = 0; ancestor && depth < 4; depth++) {
        spkEnableExtendedDynamicRangeLayer(ancestor.layer);
        ancestor = ancestor.superview;
    }
}

void SPKChromeMarkSecureFieldOwned(UITextField *field) {
    if (field)
        objc_setAssociatedObject(field, &kSPKChromeOwnedSecureFieldKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL SPKChromeCanvasOwnsSecureField(UITextField *field) {
    if (!field)
        return NO;
    return objc_getAssociatedObject(field, &kSPKChromeOwnedSecureFieldKey) != nil;
}

static void spkPinEdges(UIView *view, UIView *host) {
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:host.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor]
    ]];
}

static UIView *spkFindCanvasDeep(UIView *root, NSInteger depth) {
    if (!root || depth > 4)
        return nil;

    for (UIView *subview in root.subviews) {
        if ([NSStringFromClass(subview.class) containsString:@"CanvasView"])
            return subview;

        UIView *found = spkFindCanvasDeep(subview, depth + 1);
        if (found)
            return found;
    }

    return nil;
}

@interface SPKChromeCanvas ()
@property (nonatomic, strong) UITextField *secureField;
@property (nonatomic, strong, nullable) UIView *canvas;
@end

@implementation SPKChromeCanvas

+ (NSHashTable<SPKChromeCanvas *> *)instances {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

+ (void)ensureObserverInstalled {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKHideUIOnCapturePreferenceDidChangeNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(__unused NSNotification *note) {
                                                          for (SPKChromeCanvas *canvas in [SPKChromeCanvas instances]) {
                                                              [canvas applyPref];
                                                          }
                                                      }];
    });
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self) {
        [SPKChromeCanvas ensureObserverInstalled];

        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.clipsToBounds = NO;

        _secureField = [UITextField new];
        // Tag so the Instants screenshot bypass leaves our own redaction alone.
        SPKChromeMarkSecureFieldOwned(_secureField);
        _secureField.userInteractionEnabled = NO;
        _secureField.alpha = 1.0;
        _secureField.translatesAutoresizingMaskIntoConstraints = NO;
        _secureField.autocorrectionType = UITextAutocorrectionTypeNo;
        _secureField.spellCheckingType = UITextSpellCheckingTypeNo;
        _secureField.smartDashesType = UITextSmartDashesTypeNo;
        _secureField.smartQuotesType = UITextSmartQuotesTypeNo;
        _secureField.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
        _secureField.autocapitalizationType = UITextAutocapitalizationTypeNone;

        [self applyPref];
        [[SPKChromeCanvas instances] addObject:self];
        [self attachCanvasIfPossible];
    }

    return self;
}

- (UIView *)contentContainer {
    return _canvas ?: self;
}

- (void)setUserInteractionEnabled:(BOOL)userInteractionEnabled {
    [super setUserInteractionEnabled:userInteractionEnabled];
    _canvas.userInteractionEnabled = userInteractionEnabled;
}

- (void)applyPref {
    BOOL enabled = [SPKUtils getBoolPref:@"interface_hide_ui_on_capture"];
    if (_secureField.secureTextEntry != enabled) {
        _secureField.secureTextEntry = enabled;
        [self setNeedsLayout];
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self attachCanvasIfPossible];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self attachCanvasIfPossible];
}

- (void)attachCanvasIfPossible {
    if (_canvas.superview == self)
        return;

    // Force the secure field to lay out so iOS materialises the CanvasView.
    [_secureField layoutIfNeeded];

    UIView *canvas = spkFindCanvasDeep(_secureField, 0);
    if (!canvas)
        return;

    NSMutableArray<UIView *> *stashedViews = [NSMutableArray array];
    for (UIView *subview in self.subviews) {
        if (subview != canvas)
            [stashedViews addObject:subview];
    }

    // Steal the CanvasView from the text field and pin it edge-to-edge.
    [canvas removeFromSuperview];
    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    canvas.userInteractionEnabled = self.userInteractionEnabled;
    canvas.clipsToBounds = NO;
    [self insertSubview:canvas atIndex:0];
    spkPinEdges(canvas, self);

    _canvas = canvas;

    for (UIView *view in stashedViews) {
        [view removeFromSuperview];
        [canvas addSubview:view];
    }
}

@end

@interface SPKChromeButton () {
    NSLayoutConstraint *_widthConstraint;
    NSLayoutConstraint *_heightConstraint;
    NSLayoutConstraint *_centerXConstraint;
    NSLayoutConstraint *_centerYConstraint;
    CGSize _customSize;
    UIOffset _iconOffset;
}
@property (nonatomic, strong) SPKChromeCanvas *chromeCanvas;
@property (nonatomic, strong) UIView *bubbleView;
@property (nonatomic, strong) UIVisualEffectView *bubbleEffectView;
@property (nonatomic, strong, readwrite) UIImageView *iconView;
@end

@implementation SPKChromeButton

- (instancetype)initWithSymbol:(NSString *)symbol pointSize:(CGFloat)pointSize diameter:(CGFloat)diameter {
    self = [super initWithFrame:CGRectMake(0.0, 0.0, diameter, diameter)];

    if (self) {
        _diameter = diameter;
        _symbolName = symbol.copy;
        _symbolPointSize = pointSize;
        _iconTint = UIColor.whiteColor;
        _bubbleColor = [UIColor colorWithWhite:0.0 alpha:0.4];

        [self buildChrome];
    }

    return self;
}

- (void)buildChrome {
    self.adjustsImageWhenHighlighted = NO;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _chromeCanvas = [SPKChromeCanvas new];
    _chromeCanvas.userInteractionEnabled = NO;
    [self addSubview:_chromeCanvas];
    spkPinEdges(_chromeCanvas, self);

    _bubbleView = [UIView new];
    _bubbleView.userInteractionEnabled = NO;
    _bubbleView.translatesAutoresizingMaskIntoConstraints = NO;
    _bubbleView.backgroundColor = _bubbleColor;
    _bubbleView.layer.cornerRadius = _diameter / 2.0;
    _bubbleView.clipsToBounds = YES;

    _iconView = [UIImageView new];
    _iconView.userInteractionEnabled = NO;
    _iconView.contentMode = UIViewContentModeCenter;
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.tintColor = _iconTint;

    [self reloadIcon];

    UIView *host = _chromeCanvas.contentContainer;
    [host addSubview:_bubbleView];
    [host addSubview:_iconView];

    spkPinEdges(_bubbleView, host);

    _widthConstraint = [self.widthAnchor constraintEqualToConstant:_diameter];
    _heightConstraint = [self.heightAnchor constraintEqualToConstant:_diameter];
    _centerXConstraint = [_iconView.centerXAnchor constraintEqualToAnchor:host.centerXAnchor constant:_iconOffset.horizontal];
    _centerYConstraint = [_iconView.centerYAnchor constraintEqualToAnchor:host.centerYAnchor constant:_iconOffset.vertical];

    [NSLayoutConstraint activateConstraints:@[
        _widthConstraint,
        _heightConstraint,
        _centerXConstraint,
        _centerYConstraint
    ]];
}

- (CGSize)intrinsicContentSize {
    if (_customSize.width > 0.0 && _customSize.height > 0.0) {
        return _customSize;
    }
    return CGSizeMake(_diameter, _diameter);
}

- (CGSize)customSize {
    return _customSize;
}

- (void)setCustomSize:(CGSize)customSize {
    _customSize = customSize;
    if (_widthConstraint) {
        _widthConstraint.constant = customSize.width;
    }
    if (_heightConstraint) {
        _heightConstraint.constant = customSize.height;
    }
    [self invalidateIntrinsicContentSize];
}

- (UIOffset)iconOffset {
    return _iconOffset;
}

- (void)setIconOffset:(UIOffset)iconOffset {
    _iconOffset = iconOffset;
    if (_centerXConstraint) {
        _centerXConstraint.constant = iconOffset.horizontal;
    }
    if (_centerYConstraint) {
        _centerYConstraint.constant = iconOffset.vertical;
    }
    [self setNeedsLayout];
}

- (void)setSymbolName:(NSString *)symbolName {
    _symbolName = symbolName.copy;
    [self reloadIcon];
}

- (void)setSymbolPointSize:(CGFloat)symbolPointSize {
    _symbolPointSize = symbolPointSize;
    [self reloadIcon];
}

- (void)setIconTint:(UIColor *)iconTint {
    _iconTint = iconTint;
    _iconView.tintColor = iconTint;
}

// UIButton is the delegate of its own built-in context-menu interaction, so
// overriding this in the subclass is called when the long-press menu displays.
// Forwards to super, then runs the optional hook (nil for every other user).
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
     willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration
                            animator:(id<UIContextMenuInteractionAnimating>)animator {
    if ([UIButton instancesRespondToSelector:_cmd]) {
        [super contextMenuInteraction:interaction
      willDisplayMenuForConfiguration:configuration
                             animator:animator];
    }
    if (_menuWillDisplayHandler)
        _menuWillDisplayHandler();
}

- (void)setBubbleColor:(UIColor *)bubbleColor {
    _bubbleColor = bubbleColor;
    _bubbleView.backgroundColor = bubbleColor;
}

- (void)setBubbleEffect:(UIVisualEffect *)bubbleEffect {
    _bubbleEffect = bubbleEffect;
    if (!bubbleEffect) {
        [_bubbleEffectView removeFromSuperview];
        _bubbleEffectView = nil;
        return;
    }
    if (!_bubbleEffectView) {
        // Lives inside _bubbleView (which clips to the circle and sits inside the
        // secure canvas) and below the icon, so it redacts on capture and morphs
        // with the button.
        _bubbleEffectView = [[UIVisualEffectView alloc] initWithEffect:bubbleEffect];
        _bubbleEffectView.userInteractionEnabled = NO;
        _bubbleEffectView.translatesAutoresizingMaskIntoConstraints = NO;
        _bubbleEffectView.clipsToBounds = YES;
        [_bubbleView addSubview:_bubbleEffectView];
        spkPinEdges(_bubbleEffectView, _bubbleView);
    }
    _bubbleEffectView.effect = bubbleEffect;
}

- (void)reloadIcon {
    // Empty symbolName → leave iconView.image alone (caller may have set a
    // direct image via setIconResource:).
    if (!_symbolName.length)
        return;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:_symbolPointSize weight:UIImageSymbolWeightSemibold];
    _iconView.image = [UIImage systemImageNamed:_symbolName withConfiguration:config];
}

- (void)setIconResource:(NSString *)resourceName pointSize:(CGFloat)pointSize {
    _symbolName = nil;
    _iconView.image = resourceName.length
                          ? [SPKAssetUtils instagramIconNamed:resourceName pointSize:pointSize renderingMode:UIImageRenderingModeAlwaysTemplate]
                          : nil;
}

- (UIView *)chromeAnchorView {
    return _chromeCanvas;
}

- (void)addChromeSubview:(UIView *)view {
    if (!view)
        return;
    [_chromeCanvas.contentContainer addSubview:view];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat radius = MIN(self.bounds.size.width, self.bounds.size.height) / 2.0;
    if (_bubbleView.layer.cornerRadius != radius)
        _bubbleView.layer.cornerRadius = radius;

    UIView *host = _chromeCanvas.contentContainer;
    if (host.layer.shadowOpacity > 0.0) {
        host.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:host.bounds cornerRadius:host.layer.cornerRadius].CGPath;
    } else {
        host.layer.shadowPath = nil;
    }

    if (self.layer.shadowOpacity > 0.0) {
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:self.layer.cornerRadius].CGPath;
    } else {
        self.layer.shadowPath = nil;
    }
}

@end

@interface SPKChromeLabel () {
    SPKChromeCanvas *_chromeCanvas;
    UIImageView *_iconView;
    UILabel *_label;
    CGSize _measuredSize;
}
@end

@implementation SPKChromeLabel

static const CGFloat kSPKChromeLabelIconTextGap = 4.0;

- (instancetype)initWithText:(NSString *)text icon:(UIImage *)icon font:(UIFont *)font color:(UIColor *)color {
    self = [super initWithFrame:CGRectZero];

    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.userInteractionEnabled = NO;

        _chromeCanvas = [SPKChromeCanvas new];
        _chromeCanvas.userInteractionEnabled = NO;
        [self addSubview:_chromeCanvas];
        spkPinEdges(_chromeCanvas, self);

        // Add content to the canvas now (before it materialises its secure
        // canvas) but constrain it to `_chromeCanvas` itself — its identity is
        // stable, whereas `contentContainer` swaps from self to the stolen
        // CanvasView once attached, migrating these subviews along with it.
        UIView *host = _chromeCanvas.contentContainer;
        NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];

        CGFloat iconWidth = 0.0;
        CGFloat iconHeight = 0.0;
        if (icon) {
            _iconView = [[UIImageView alloc] initWithImage:icon];
            _iconView.translatesAutoresizingMaskIntoConstraints = NO;
            _iconView.contentMode = UIViewContentModeScaleAspectFit;
            _iconView.tintColor = color;
            [host addSubview:_iconView];
            iconWidth = icon.size.width;
            iconHeight = icon.size.height;
            [constraints addObjectsFromArray:@[
                [_iconView.leadingAnchor constraintEqualToAnchor:_chromeCanvas.leadingAnchor],
                [_iconView.centerYAnchor constraintEqualToAnchor:_chromeCanvas.centerYAnchor],
                [_iconView.widthAnchor constraintEqualToConstant:iconWidth],
                [_iconView.heightAnchor constraintEqualToConstant:iconHeight]
            ]];
        }

        CGSize labelSize = CGSizeZero;
        if (text.length) {
            _label = [[UILabel alloc] init];
            _label.translatesAutoresizingMaskIntoConstraints = NO;
            _label.text = text;
            _label.font = font;
            _label.textColor = color;
            [host addSubview:_label];
            labelSize = [_label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
            NSLayoutXAxisAnchor *labelLeading = _iconView ? _iconView.trailingAnchor : _chromeCanvas.leadingAnchor;
            CGFloat leadingGap = _iconView ? kSPKChromeLabelIconTextGap : 0.0;
            [constraints addObjectsFromArray:@[
                [_label.leadingAnchor constraintEqualToAnchor:labelLeading constant:leadingGap],
                [_label.centerYAnchor constraintEqualToAnchor:_chromeCanvas.centerYAnchor]
            ]];
        }

        CGFloat gap = (iconWidth > 0.0 && labelSize.width > 0.0) ? kSPKChromeLabelIconTextGap : 0.0;
        _measuredSize = CGSizeMake(iconWidth + gap + labelSize.width, MAX(iconHeight, labelSize.height));

        // Pin the label's own size explicitly rather than trusting only
        // `intrinsicContentSize` to win the layout negotiation. When the label
        // is placed with just two edge constraints (e.g. leading + bottom to a
        // host container), an intrinsic size can be overridden or left ambiguous
        // by the host's own layout, which showed up as the badge sometimes not
        // appearing. Explicit width/height make the size deterministic; hugging
        // and compression resistance are maxed as a belt-and-suspenders.
        if (_measuredSize.width > 0.0 && _measuredSize.height > 0.0) {
            [constraints addObjectsFromArray:@[
                [self.widthAnchor constraintEqualToConstant:_measuredSize.width],
                [self.heightAnchor constraintEqualToConstant:_measuredSize.height]
            ]];
        }
        [self setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
        [self setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];

        [NSLayoutConstraint activateConstraints:constraints];
    }

    return self;
}

- (CGSize)intrinsicContentSize {
    return _measuredSize;
}

@end

UIBarButtonItem *SPKChromeBarButtonItem(NSString *symbol, CGFloat pointSize, id target, SEL action, SPKChromeButton **outButton) {
    SPKChromeButton *button = [[SPKChromeButton alloc] initWithSymbol:symbol pointSize:pointSize diameter:44.0];
    button.iconOffset = UIOffsetMake(-2.0, 0.0);
    button.bubbleColor = UIColor.clearColor;

    if (target && action) {
        [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    }

    if (outButton)
        *outButton = button;
    return [[UIBarButtonItem alloc] initWithCustomView:button];
}
