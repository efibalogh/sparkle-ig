#import "SPKStrings.h"
#import "SPKFullScreenImageViewController.h"
#import "SPKImageFormat.h"
#import "SPKMediaCacheManager.h"
#import "SPKMediaItem.h"
#import "SPKMediaUnavailableView.h"
#import "../../AssetUtils.h"
#import "../UI/SPKNotificationCenter.h"
#import "../../Utils.h"
#import <objc/message.h>
#import <objc/runtime.h>

static CGFloat const kMaxZoom = 5.0;
static CGFloat const kMinZoom = 1.0;
static CGFloat const kZoomEpsilon = 0.02;
// Matches the corner VisionKit's own Live Text button occupies, so replacing it
// doesn't move the control the user already reaches for.
static CGFloat const kLiveTextButtonSize = 40.0;
static CGFloat const kLiveTextButtonInset = 12.0;
static CGFloat const kLiveTextButtonSpacing = 10.0;

// Real Liquid Glass — material, touch response and the "jump" — comes only from the
// system's glass button configurations. A UIGlassEffect view behind a plain button
// renders flat and never sees the touches, so it cannot stand in for this (the same
// conclusion SPKGlassButton reached). iOS 26 SDK API, resolved at runtime because
// this project builds against 16.2; older systems fall back to a solid capsule.
BOOL SPKLiveTextIsSupported(void) {
    Class bridgeClass = NSClassFromString(@"SPKLiveTextBridge");
    if (!bridgeClass || ![bridgeClass respondsToSelector:@selector(supported)])
        return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(bridgeClass, @selector(supported));
}

static BOOL SPKLiveTextGlassAvailable(void) {
    Class configClass = NSClassFromString(@"UIButtonConfiguration");
    return configClass &&
           [configClass respondsToSelector:NSSelectorFromString(@"glassButtonConfiguration")];
}

static UIButtonConfiguration *SPKLiveTextButtonConfiguration(BOOL prominent) {
    Class configClass = NSClassFromString(@"UIButtonConfiguration");
    SEL selector = prominent ? NSSelectorFromString(@"prominentGlassButtonConfiguration")
                             : NSSelectorFromString(@"glassButtonConfiguration");
    UIButtonConfiguration *config = nil;
    if (configClass && [configClass respondsToSelector:selector]) {
        config = ((id (*)(id, SEL))[configClass methodForSelector:selector])(configClass,
                                                                            selector);
    }
    if (!config) {
        config = [UIButtonConfiguration plainButtonConfiguration];
    }
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    return config;
}

// Pre-iOS-26 the capsules paint their own fill straight onto the button's layer,
// which the configuration's highlight handling never touches, so a press produced
// no visible feedback at all. Glass buttons dim and bounce themselves, so this
// stands in only on the fallback path.
static const char kSPKLiveTextBaseFillKey = 0;

static UIColor *SPKLiveTextPressedFill(UIColor *fill) {
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![fill getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white = 0.0;
        if (![fill getWhite:&white alpha:&alpha])
            return fill;
        red = green = blue = white;
    }
    CGFloat const lift = 0.18;
    return [UIColor colorWithRed:red + (1.0 - red) * lift
                           green:green + (1.0 - green) * lift
                            blue:blue + (1.0 - blue) * lift
                           alpha:MIN(1.0, alpha + 0.08)];
}

static void SPKLiveTextSetFallbackFill(UIButton *button, UIColor *fill) {
    objc_setAssociatedObject(button, &kSPKLiveTextBaseFillKey, fill,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    button.backgroundColor = button.highlighted ? SPKLiveTextPressedFill(fill) : fill;
    if (button.configurationUpdateHandler)
        return;
    button.configurationUpdateHandler = ^(__kindof UIButton *updated) {
        UIColor *base = objc_getAssociatedObject(updated, &kSPKLiveTextBaseFillKey);
        BOOL pressed = updated.highlighted;
        updated.backgroundColor = (pressed && base) ? SPKLiveTextPressedFill(base) : base;
        // Down is quick and linear, release springs back, the way iOS 18's own
        // filled controls read under a finger.
        [UIView animateWithDuration:pressed ? 0.12 : 0.3
                              delay:0.0
             usingSpringWithDamping:pressed ? 1.0 : 0.55
              initialSpringVelocity:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             updated.transform = pressed ? CGAffineTransformMakeScale(0.94, 0.94)
                                                         : CGAffineTransformIdentity;
                         }
                         completion:nil];
    };
}

// `frame` is undefined while a transform is applied, and the press feedback above
// scales the button, so the two controls are positioned through bounds/center.
static void SPKLiveTextPositionButton(UIButton *button, CGRect frame) {
    button.bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(frame), CGRectGetHeight(frame));
    button.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
}

@interface SPKFullScreenImageViewController () <UIScrollViewDelegate>

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, assign) UIEdgeInsets desiredContentInsets;
@property (nonatomic, assign) BOOL hasDesiredContentInsets;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UIView *errorView;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong, nullable) SPKMediaUnavailableView *unavailableView;
@property (nonatomic, strong) UITapGestureRecognizer *doubleTapGesture;
@property (nonatomic, assign) BOOL isLoadingImage;
@property (nonatomic, assign) BOOL lastReportedZoomState;
@property (nonatomic, strong) id liveTextBridge;
@property (nonatomic, strong, nullable) UIButton *liveTextButton;
@property (nonatomic, strong, nullable) UIButton *liveTextCopyButton;
@property (nonatomic, assign) CGFloat liveTextCopyButtonWidth;
@property (nonatomic, assign) CGFloat chromeBottomLimit;
@property (nonatomic, assign) BOOL hasChromeBottomLimit;
@property (nonatomic, assign) BOOL liveTextHighlighted;

@end

@implementation SPKFullScreenImageViewController

- (instancetype)initWithMediaItem:(SPKMediaItem *)item {
    self = [super init];
    if (self) {
        _mediaItem = item;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    [self setupScrollView];
    [self setupImageView];
    [self setupLoadingIndicator];
    [self setupErrorView];
    [self setupGestures];
    [self preloadContent];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateImageViewFrame];
    [self updateLiveTextButtonFrame];
}

- (void)applyMediaContentInsets:(UIEdgeInsets)insets {
    self.desiredContentInsets = insets;
    self.hasDesiredContentInsets = YES;
    // Insets only affect the min-zoom fit/centering. While zoomed the image
    // uses the full screen, so there's nothing to update (and nothing jumps);
    // the new insets take effect naturally when the user returns to min zoom.
    if (self.isZoomed)
        return;
    [self updateImageViewFrame];
}

- (void)applyChromeBottomLimit:(CGFloat)bottomLimit {
    if (self.hasChromeBottomLimit && ABS(bottomLimit - self.chromeBottomLimit) < 0.5)
        return;
    self.chromeBottomLimit = bottomLimit;
    self.hasChromeBottomLimit = YES;
    [self updateLiveTextButtonFrame];
}

- (UIEdgeInsets)effectiveMinZoomInsets {
    UIEdgeInsets insets = self.hasDesiredContentInsets ? self.desiredContentInsets : UIEdgeInsetsZero;
    if (UIEdgeInsetsEqualToEdgeInsets(insets, UIEdgeInsetsZero))
        return UIEdgeInsetsZero;

    UIImage *image = _imageView.image;
    CGSize boundsSize = _scrollView.bounds.size;
    if (!image || boundsSize.width <= 0 || boundsSize.height <= 0)
        return insets;

    CGSize imageSize = image.size;
    if (imageSize.width <= 0 || imageSize.height <= 0)
        return insets;

    CGFloat availW = MAX(1.0, boundsSize.width - insets.left - insets.right);
    CGFloat availH = MAX(1.0, boundsSize.height - insets.top - insets.bottom);
    CGFloat ratioFull = MIN(boundsSize.width / imageSize.width,
                            boundsSize.height / imageSize.height);
    CGFloat ratioAvail = MIN(availW / imageSize.width, availH / imageSize.height);

    // Only inset images the bars would actually cover. A width-constrained fit
    // (square/landscape photos) already sits clear of the top/bottom bars, so
    // the between-bars region doesn't shrink it any further (ratioAvail ==
    // ratioFull). Insetting those would just shift/resize them and make them
    // jump when the chrome toggles, so leave them full-bleed and centered.
    // Height-constrained fits (tall ~9:16 photos) would run under the bars, so
    // those do get inset.
    if (ratioAvail >= ratioFull - 0.0001)
        return UIEdgeInsetsZero;
    return insets;
}

#pragma mark - Setup

- (void)setupScrollView {
    _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.delegate = self;
    _scrollView.minimumZoomScale = kMinZoom;
    _scrollView.maximumZoomScale = kMaxZoom;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.bouncesZoom = YES;
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_scrollView];

    // The scroll view always spans the full screen so a zoomed image can pan
    // edge-to-edge with no black bars. The between-bars inset (pushed by the
    // host via applyMediaContentInsets:) is applied only to the min-zoom fit and
    // centering of the image, so toggling the chrome while zoomed changes
    // nothing visible.
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)setupImageView {
    Class animatedImageViewClass = NSClassFromString(@"FLAnimatedImageView");
    Class imageViewClass = animatedImageViewClass ?: UIImageView.class;
    _imageView = [[imageViewClass alloc] initWithFrame:CGRectZero];
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.clipsToBounds = YES;
    [_scrollView addSubview:_imageView];
}

// Sparkle's replacement for VisionKit's floating Live Text button, which the bridge
// suppresses. Sits in the same bottom-trailing corner of the displayed image, but
// uses our own glyph and IG's blue for the on state instead of the SF Symbol look.
// Lives in the view, not the scroll view, so zooming and panning never carry it off
// screen.
- (UIButton *)ensureLiveTextButton {
    if (_liveTextButton)
        return _liveTextButton;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0.0, 0.0, kLiveTextButtonSize, kLiveTextButtonSize);
    button.hidden = YES;
    button.accessibilityLabel = SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_IMAGE_SELECT_TEXT_BUTTON_ACCESSIBILITY_LABEL");
    [button addTarget:self
                  action:@selector(toggleLiveTextHighlight)
        forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    _liveTextButton = button;
    [self applyLiveTextButtonStyle];
    [self updateLiveTextButtonFrame];
    return button;
}

// Replaces VisionKit's "Copy All" quick action, which disappears along with the
// supplementary interface we suppress. A capsule sitting on the same line as the
// OCR button, just inside it, shown only while text is actually highlighted.
- (UIButton *)ensureLiveTextCopyButton {
    if (_liveTextCopyButton)
        return _liveTextCopyButton;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = SPKLiveTextButtonConfiguration(NO);
    config.image = [SPKAssetUtils resolvedImageNamed:@"copy"
                                 fallbackSystemName:@"doc.on.doc"
                                          pointSize:18.0
                                             weight:UIImageSymbolWeightSemibold
                                             source:SPKResolvedImageSourceAutomatic
                                      renderingMode:UIImageRenderingModeAlwaysTemplate];
    config.title = SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_IMAGE_COPY_ALL_BUTTON_TITLE");
    config.imagePadding = 6.0;
    config.titleTextAttributesTransformer =
        ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
            NSMutableDictionary *attributes = [incoming mutableCopy] ?: [NSMutableDictionary dictionary];
            attributes[NSFontAttributeName] =
                [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
            return attributes;
        };
    if (!SPKLiveTextGlassAvailable()) {
        // Glass brings its own padding, background and content contrast; the plain
        // fallback has to spell all three out.
        config.contentInsets = NSDirectionalEdgeInsetsMake(0.0, 14.0, 0.0, 16.0);
        config.baseForegroundColor = [UIColor whiteColor];
        button.tintColor = [UIColor whiteColor];
        button.layer.cornerRadius = kLiveTextButtonSize / 2.0;
        button.clipsToBounds = YES;
        SPKLiveTextSetFallbackFill(button, [UIColor colorWithWhite:0.0 alpha:0.55]);
    }
    button.configuration = config;
    button.hidden = YES;
    button.accessibilityLabel = config.title;
    [button addTarget:self
                  action:@selector(copyLiveTextTranscript)
        forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    _liveTextCopyButton = button;
    _liveTextCopyButtonWidth =
        [button sizeThatFits:CGSizeMake(CGFLOAT_MAX, kLiveTextButtonSize)].width;
    return button;
}

- (void)updateLiveTextCopyButtonVisibility {
    BOOL shouldShow = self.liveTextHighlighted && !self.liveTextButton.hidden;
    if (!shouldShow) {
        if (!_liveTextCopyButton || _liveTextCopyButton.hidden)
            return;
        UIButton *button = _liveTextCopyButton;
        [UIView animateWithDuration:0.15
            animations:^{ button.alpha = 0.0; }
            completion:^(__unused BOOL finished) { button.hidden = YES; }];
        return;
    }

    UIButton *button = [self ensureLiveTextCopyButton];
    if (!button.hidden)
        return;
    // Show first, then lay out: the frame pass skips hidden buttons, so doing it
    // the other way round left the capsule parked at the origin.
    button.hidden = NO;
    // A press that was interrupted by the hide leaves the capsule scaled down.
    button.transform = CGAffineTransformIdentity;
    [self updateLiveTextButtonFrame];
    button.alpha = 0.0;
    [UIView animateWithDuration:0.2 animations:^{ button.alpha = 1.0; }];
}

- (void)copyLiveTextTranscript {
    NSString *transcript = nil;
    if (self.liveTextBridge) {
        transcript = ((id (*)(id, SEL))objc_msgSend)(self.liveTextBridge,
                                                     NSSelectorFromString(@"transcript"));
    }
    if (![transcript isKindOfClass:[NSString class]] || transcript.length == 0)
        return;

    [UIPasteboard generalPasteboard].string = transcript;
    SPKNotify(kSPKNotificationMediaPreviewCopy,
              SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_IMAGE_TEXT_COPIED_TEXT"), nil, @"copy_filled",
              SPKNotificationToneForIconResource(@"copy_filled"));
}

- (void)applyLiveTextButtonStyle {
    UIButton *button = _liveTextButton;
    if (!button)
        return;

    BOOL selected = self.liveTextHighlighted;
    UIButtonConfiguration *config = SPKLiveTextButtonConfiguration(selected);
    // Apple's Live Text glyph: the catalog has nothing equivalent, and this is the
    // shape people already read as "select the text in this photo".
    config.image = [SPKAssetUtils resolvedImageNamed:@"text.viewfinder"
                                           pointSize:17.0
                                              weight:UIImageSymbolWeightSemibold
                                              source:SPKResolvedImageSourceSystemSymbol
                                       renderingMode:UIImageRenderingModeAlwaysTemplate];

    if (SPKLiveTextGlassAvailable()) {
        // Glass contrasts its own content against whatever the photo puts behind it,
        // so the foreground is left to the system. Selection reads as a filled
        // capsule; that tint must be chromatic or the material renders flat.
        //
        // Prominent glass fills itself from the tint, so the tint is set BEFORE the
        // configuration and also baked into it: assigning the configuration first
        // let the new material resolve against the old inherited tint, flashing the
        // system accent for the length of the morph animation.
        UIColor *tint = selected ? [SPKUtils SPKColor_InstagramBlue] : nil;
        button.tintColor = tint;
        config.baseBackgroundColor = tint;
        button.configuration = config;
        return;
    }

    config.baseForegroundColor = [UIColor whiteColor];
    button.configuration = config;
    button.tintColor = [UIColor whiteColor];
    button.layer.cornerRadius = kLiveTextButtonSize / 2.0;
    button.clipsToBounds = YES;
    SPKLiveTextSetFallbackFill(button, selected ? [SPKUtils SPKColor_InstagramBlue]
                                                : [UIColor colorWithWhite:0.0 alpha:0.55]);
}

- (void)updateLiveTextButtonFrame {
    UIButton *button = _liveTextButton;
    if (!button || button.hidden)
        return;

    // Anchor to the displayed image where it is actually on screen: the image rect
    // alone runs off screen once zoomed, and the safe area alone would float the
    // button beside a letterboxed photo instead of over it.
    UIEdgeInsets insets = self.view.safeAreaInsets;
    // The safe area's bottom grows and shrinks with the toolbar, which dragged the
    // button up and down on every chrome toggle. The host's frozen measurement is
    // taken once with the chrome visible, so the button holds its place.
    if (self.hasChromeBottomLimit)
        insets.bottom = self.chromeBottomLimit;
    CGRect safeArea = UIEdgeInsetsInsetRect(self.view.bounds, insets);
    CGRect imageFrameInView = [self.view convertRect:_imageView.frame fromView:_scrollView];
    CGRect area = CGRectIntersection(safeArea, imageFrameInView);
    if (CGRectIsNull(area) || CGRectIsEmpty(area))
        area = safeArea;

    CGFloat x = CGRectGetMaxX(area) - kLiveTextButtonInset - kLiveTextButtonSize;
    CGFloat y = CGRectGetMaxY(area) - kLiveTextButtonInset - kLiveTextButtonSize;
    SPKLiveTextPositionButton(button, CGRectMake(x, y, kLiveTextButtonSize, kLiveTextButtonSize));
    if (_liveTextCopyButton && !_liveTextCopyButton.hidden) {
        // Pinned to the opposite edge of the same line, so the two controls sit at
        // the far ends of the image rather than bunched in one corner.
        CGFloat width = MAX(kLiveTextButtonSize, _liveTextCopyButtonWidth);
        CGFloat maxWidth = MAX(kLiveTextButtonSize,
                               x - kLiveTextButtonSpacing - CGRectGetMinX(area) -
                                   kLiveTextButtonInset);
        width = MIN(width, maxWidth);
        SPKLiveTextPositionButton(_liveTextCopyButton,
                                  CGRectMake(CGRectGetMinX(area) + kLiveTextButtonInset, y,
                                             width, kLiveTextButtonSize));
    }
}

- (void)setLiveTextButtonAvailable:(BOOL)available {
    if (!available) {
        _liveTextButton.hidden = YES;
        [self updateLiveTextCopyButtonVisibility];
        return;
    }
    UIButton *button = [self ensureLiveTextButton];
    if (!button.hidden)
        return;
    button.hidden = NO;
    [self applyLiveTextButtonStyle];
    [self updateLiveTextButtonFrame];
    button.alpha = 0.0;
    [UIView animateWithDuration:0.2 animations:^{ button.alpha = 1.0; }];
}

- (void)toggleLiveTextHighlight {
    if (!self.liveTextBridge)
        return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self.liveTextBridge,
                                            NSSelectorFromString(@"setHighlighted:"),
                                            !self.liveTextHighlighted);
    UIImpactFeedbackGenerator *haptic =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)setupLoadingIndicator {
    _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingIndicator.color = [UIColor whiteColor];
    _loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:_loadingIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [_loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

- (void)setupErrorView {
    _errorView = [[UIView alloc] initWithFrame:CGRectZero];
    _errorView.translatesAutoresizingMaskIntoConstraints = NO;
    _errorView.hidden = YES;
    [self.view addSubview:_errorView];

    _errorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    _errorLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    _errorLabel.numberOfLines = 0;
    [_errorView addSubview:_errorLabel];

    _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_retryButton setTitle:SPKL(@"ALERT_ACTION_RETRY") forState:UIControlStateNormal];
    [_retryButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _retryButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _retryButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    _retryButton.layer.cornerRadius = 18;
    [_retryButton addTarget:self action:@selector(retryLoading) forControlEvents:UIControlEventTouchUpInside];
    [_errorView addSubview:_retryButton];

    [NSLayoutConstraint activateConstraints:@[
        [_errorView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_errorView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_errorView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor
                                                              constant:40],

        [_errorLabel.topAnchor constraintEqualToAnchor:_errorView.topAnchor],
        [_errorLabel.leadingAnchor constraintEqualToAnchor:_errorView.leadingAnchor],
        [_errorLabel.trailingAnchor constraintEqualToAnchor:_errorView.trailingAnchor],

        [_retryButton.topAnchor constraintEqualToAnchor:_errorLabel.bottomAnchor
                                               constant:16],
        [_retryButton.centerXAnchor constraintEqualToAnchor:_errorView.centerXAnchor],
        [_retryButton.widthAnchor constraintEqualToConstant:100],
        [_retryButton.heightAnchor constraintEqualToConstant:36],
        [_retryButton.bottomAnchor constraintEqualToAnchor:_errorView.bottomAnchor],
    ]];
}

- (void)setupGestures {
    _doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    _doubleTapGesture.numberOfTapsRequired = 2;
    [_scrollView addGestureRecognizer:_doubleTapGesture];

    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)];
    singleTap.numberOfTapsRequired = 1;
    [singleTap requireGestureRecognizerToFail:_doubleTapGesture];
    [_scrollView addGestureRecognizer:singleTap];
}

#pragma mark - Image Loading

- (void)preloadContent {
    if (self.mediaItem.image) {
        if (self.isViewLoaded) {
            [self displayImage:self.mediaItem.image];
        }
        return;
    }

    NSURL *url = self.mediaItem.fileURL;
    if (!url) {
        if (self.isViewLoaded) {
            [self showError:SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_IMAGE_NO_IMAGE_URL_TEXT")];
        }
        return;
    }

    if (self.isLoadingImage) {
        if (self.isViewLoaded) {
            [_loadingIndicator startAnimating];
            _errorView.hidden = YES;
        }
        return;
    }

    self.isLoadingImage = YES;
    if (self.isViewLoaded) {
        [_loadingIndicator startAnimating];
        _errorView.hidden = YES;
    }

    __weak typeof(self) weakSelf = self;
    [[SPKMediaCacheManager sharedManager] loadImageForItem:self.mediaItem
                                                completion:^(UIImage *_Nullable image, NSError *_Nullable error) {
                                                    __strong typeof(weakSelf) strongSelf = weakSelf;
                                                    if (!strongSelf)
                                                        return;

                                                    [strongSelf.loadingIndicator stopAnimating];
                                                    strongSelf.isLoadingImage = NO;

                                                    if (image) {
                                                        if (strongSelf.isViewLoaded) {
                                                            [strongSelf displayImage:image];
                                                        }
                                                        return;
                                                    }

                                                    if (strongSelf.isViewLoaded && SPKMediaCacheErrorIsLocalFileMissing(error)) {
                                                        [strongSelf showUnavailableWithMessage:error.localizedDescription];
                                                        return;
                                                    }
                                                    if (strongSelf.isViewLoaded) {
                                                        [strongSelf showError:error.localizedDescription.length > 0 ? error.localizedDescription : SPKL(@"MEDIA_PREVIEW_FULL_SCREEN_IMAGE_FAILED_LOAD_IMAGE_TEXT")];
                                                    }
                                                }];
}

- (void)retryLoading {
    self.isLoadingImage = NO;
    [self preloadContent];
}

- (void)displayImage:(UIImage *)image {
    _imageView.image = image;
    [self displayAnimatedImageIfAvailable];
    [self configureLiveTextForImage:image];
    _scrollView.hidden = NO;
    _errorView.hidden = YES;
    _unavailableView.hidden = YES;
    [_scrollView setZoomScale:kMinZoom animated:NO];
    [self updateImageViewFrame];
}

- (void)configureLiveTextForImage:(UIImage *)image {
    [self.liveTextBridge cleanup];
    self.liveTextBridge = nil;
    self.liveTextHighlighted = NO;
    [self setLiveTextButtonAvailable:NO];
    [self applyLiveTextButtonStyle];
    if (!SPKLiveTextIsSupported())
        return;
    if (![SPKUtils getBoolPref:@"general_preview_live_text"])
        return;
    NSURL *localURL = [[SPKMediaCacheManager sharedManager] bestAvailableFileURLForItem:self.mediaItem];
    SPKImageFormat format = SPKImageFormatForFileURL(localURL);
    if (format == SPKImageFormatGIF || format == SPKImageFormatWebP)
        return;

    Class bridgeClass = NSClassFromString(@"SPKLiveTextBridge");
    id bridge = ((id (*)(id, SEL, UIImageView *))objc_msgSend)([bridgeClass alloc], NSSelectorFromString(@"initWithImageView:"), _imageView);
    if (!bridge)
        return;
    self.liveTextBridge = bridge;

    // VisionKit's "Copy All" chip is system UI with no styling API; the only lever
    // we hold over it is the inherited tint.
    _imageView.tintColor = [SPKUtils SPKColor_InstagramBlue];

    __weak typeof(self) weakSelf = self;
    void (^highlightChanged)(BOOL) = ^(BOOL highlighted) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;
        strongSelf.liveTextHighlighted = highlighted;
        [strongSelf applyLiveTextButtonStyle];
        [strongSelf updateLiveTextCopyButtonVisibility];
        if ([strongSelf.delegate
                respondsToSelector:@selector(mediaContent:didChangeLiveTextHighlight:)]) {
            [strongSelf.delegate mediaContent:strongSelf
                   didChangeLiveTextHighlight:highlighted];
        }
    };
    ((void (*)(id, SEL, id))objc_msgSend)(bridge, NSSelectorFromString(@"setOnHighlightChange:"), highlightChanged);

    void (^availabilityChanged)(BOOL) = ^(BOOL available) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf setLiveTextButtonAvailable:available];
    };
    ((void (*)(id, SEL, id))objc_msgSend)(bridge, NSSelectorFromString(@"setOnTextAvailabilityChange:"), availabilityChanged);

    ((void (*)(id, SEL, UIImage *))objc_msgSend)(bridge, NSSelectorFromString(@"analyzeImage:"), image);
}

- (void)displayAnimatedImageIfAvailable {
    NSURL *localURL = [[SPKMediaCacheManager sharedManager] bestAvailableFileURLForItem:self.mediaItem];
    SPKImageFormat format = SPKImageFormatForFileURL(localURL);
    if (format != SPKImageFormatGIF && format != SPKImageFormatWebP)
        return;

    Class factory = NSClassFromString(@"FLAnimatedImageFactory");
    SEL setAnimatedImage = NSSelectorFromString(@"setAnimatedImage:");
    if (!factory || ![_imageView respondsToSelector:setAnimatedImage])
        return;

    NSData *data = [NSData dataWithContentsOfURL:localURL options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length)
        return;

    BOOL isGIF = format == SPKImageFormatGIF;
    CGSize size = _imageView.image.size;

    // IG <=435 took a trailing `flAnimatedFrameCacheOOMFixEnabled:` BOOL; IG 436+
    // dropped it. Prefer the 4-arg variant, fall back to the 3-arg one.
    SEL decode4 = NSSelectorFromString(isGIF
                                           ? @"animatedImageWithGIFData:size:targetQueueForFrameCache:flAnimatedFrameCacheOOMFixEnabled:"
                                           : @"animatedImageWithWebPData:size:targetQueueForFrameCache:flAnimatedFrameCacheOOMFixEnabled:");
    SEL decode3 = NSSelectorFromString(isGIF
                                           ? @"animatedImageWithGIFData:size:targetQueueForFrameCache:"
                                           : @"animatedImageWithWebPData:size:targetQueueForFrameCache:");

    id animatedImage = nil;
    if ([factory respondsToSelector:decode4]) {
        animatedImage = ((id (*)(id, SEL, NSData *, CGSize, id, BOOL))objc_msgSend)(
            factory, decode4, data, size, nil, YES);
    } else if ([factory respondsToSelector:decode3]) {
        animatedImage = ((id (*)(id, SEL, NSData *, CGSize, id))objc_msgSend)(
            factory, decode3, data, size, nil);
    }
    if (!animatedImage)
        return;
    ((void (*)(id, SEL, id))objc_msgSend)(_imageView, setAnimatedImage, animatedImage);
    SEL play = NSSelectorFromString(@"play");
    if ([_imageView respondsToSelector:play])
        ((void (*)(id, SEL))objc_msgSend)(_imageView, play);
}

// A missing local file will not come back on retry, so this replaces the error
// view and its Retry button with an explanation.
- (void)showUnavailableWithMessage:(NSString *)message {
    if (!_unavailableView) {
        _unavailableView = [[SPKMediaUnavailableView alloc] initWithFrame:CGRectZero];
        _unavailableView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:_unavailableView];
        [NSLayoutConstraint activateConstraints:@[
            [_unavailableView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [_unavailableView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
            [_unavailableView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:40],
        ]];
    }
    [_unavailableView setTitle:SPKL(@"MEDIA_PREVIEW_FILE_MISSING_TITLE") message:message];
    _unavailableView.hidden = NO;
    _errorView.hidden = YES;
    _scrollView.hidden = YES;
}

- (void)showError:(NSString *)message {
    _errorLabel.text = message;
    _errorView.hidden = NO;
    _scrollView.hidden = YES;

    if ([self.delegate respondsToSelector:@selector(mediaContent:didFailWithError:)]) {
        NSError *error = [NSError errorWithDomain:@"SPKFullScreenImageViewController" code:-1 userInfo:@{NSLocalizedDescriptionKey : message}];
        [self.delegate mediaContent:self didFailWithError:error];
    }
}

#pragma mark - Frame Management

/// Centers the image inside the scroll view using frame origin (stable with
/// `UIScrollView` zoom). At minimum zoom the image is centered within the
/// between-bars region; when zoomed it centers/pans across the full screen.
- (void)spk_recenterZoomedImage {
    CGSize boundsSize = _scrollView.bounds.size;
    CGSize contentSize = _scrollView.contentSize;
    BOOL atMinimumZoom = (_scrollView.zoomScale <= kMinZoom + kZoomEpsilon);

    if (atMinimumZoom) {
        UIEdgeInsets insets = [self effectiveMinZoomInsets];
        CGFloat availW = MAX(1.0, boundsSize.width - insets.left - insets.right);
        CGFloat availH = MAX(1.0, boundsSize.height - insets.top - insets.bottom);
        _imageView.center = CGPointMake(insets.left + availW * 0.5,
                                        insets.top + availH * 0.5);
        return;
    }

    CGFloat offsetX = (boundsSize.width > contentSize.width) ? (boundsSize.width - contentSize.width) * 0.5 : 0.0;
    CGFloat offsetY = (boundsSize.height > contentSize.height) ? (boundsSize.height - contentSize.height) * 0.5 : 0.0;

    _imageView.center = CGPointMake(contentSize.width * 0.5 + offsetX, contentSize.height * 0.5 + offsetY);
}

- (void)updateImageViewFrame {
    UIImage *image = _imageView.image;
    if (!image)
        return;

    CGSize boundsSize = _scrollView.bounds.size;
    if (boundsSize.width <= 0 || boundsSize.height <= 0)
        return;

    BOOL atMinimumZoom = (_scrollView.zoomScale <= kMinZoom + kZoomEpsilon);

    if (atMinimumZoom) {
        // Fit into the between-bars region so the un-zoomed image never sits
        // under the top/bottom chrome.
        UIEdgeInsets insets = [self effectiveMinZoomInsets];
        CGFloat availW = MAX(1.0, boundsSize.width - insets.left - insets.right);
        CGFloat availH = MAX(1.0, boundsSize.height - insets.top - insets.bottom);

        CGSize imageSize = image.size;
        CGFloat ratio = MIN(availW / imageSize.width, availH / imageSize.height);

        CGFloat newWidth = imageSize.width * ratio;
        CGFloat newHeight = imageSize.height * ratio;

        _imageView.frame = CGRectMake(0, 0, newWidth, newHeight);
        _scrollView.contentSize = CGSizeMake(newWidth, newHeight);
        [self spk_recenterZoomedImage];
    } else {
        [self spk_recenterZoomedImage];
    }
    [self updateLiveTextButtonFrame];
}

#pragma mark - UIScrollViewDelegate

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _imageView;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    [self spk_recenterZoomedImage];
    [self updateLiveTextButtonFrame];
    [self notifyZoomStateIfChanged];
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView withView:(UIView *)view atScale:(CGFloat)scale {
    // Back at minimum zoom: re-fit into the current between-bars region (the
    // insets may have changed via a chrome toggle while the image was zoomed).
    if (!self.isZoomed) {
        [self updateImageViewFrame];
    }
    [self notifyZoomStateIfChanged];
}

/// Notifies the delegate when the zoomed/unzoomed state flips so the host can
/// adapt its chrome (material backing behind the bars when zoomed in).
- (void)notifyZoomStateIfChanged {
    BOOL zoomed = self.isZoomed;
    if (zoomed == _lastReportedZoomState)
        return;
    _lastReportedZoomState = zoomed;
    if ([self.delegate respondsToSelector:@selector(mediaContent:didChangeZoomState:)]) {
        [self.delegate mediaContent:self didChangeZoomState:zoomed];
    }
}

#pragma mark - Gestures

- (BOOL)isZoomed {
    return _scrollView.zoomScale > kMinZoom + kZoomEpsilon;
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)recognizer {
    if (self.isZoomed) {
        [_scrollView setZoomScale:kMinZoom animated:YES];
    } else {
        CGPoint point = [recognizer locationInView:_imageView];
        CGFloat newZoom = kMaxZoom / 2.0;
        CGSize scrollSize = _scrollView.bounds.size;
        CGFloat w = scrollSize.width / newZoom;
        CGFloat h = scrollSize.height / newZoom;
        CGRect zoomRect = CGRectMake(point.x - w / 2.0, point.y - h / 2.0, w, h);
        [_scrollView zoomToRect:zoomRect animated:YES];
    }
}

- (void)handleSingleTap:(UITapGestureRecognizer *)recognizer {
    if ([self.delegate respondsToSelector:@selector(mediaContentDidTap:)]) {
        [self.delegate mediaContentDidTap:self];
    }
}

- (void)resetZoomIfNeeded {
    if (!self.isZoomed) {
        [_scrollView setZoomScale:kMinZoom animated:NO];
        [self updateImageViewFrame];
    }
    [self notifyZoomStateIfChanged];
}

#pragma mark - Cleanup

- (void)cleanup {
    [self.liveTextBridge cleanup];
    self.liveTextBridge = nil;
    self.liveTextHighlighted = NO;
    [self setLiveTextButtonAvailable:NO];
    SEL setAnimatedImage = NSSelectorFromString(@"setAnimatedImage:");
    if ([_imageView respondsToSelector:setAnimatedImage]) {
        ((void (*)(id, SEL, id))objc_msgSend)(_imageView, setAnimatedImage, nil);
    }
    _imageView.image = nil;
    // The item outlives this page, so clearing only the image view left the
    // full-size image alive on the item -- browsing a long run of photos kept
    // every one of them in memory. Drop it whenever it can be reloaded from disk
    // (an item made straight from a UIImage has no file to reload from, so it
    // keeps its copy); the shared image cache still serves the way back.
    if (self.mediaItem.fileURL || self.mediaItem.resolvedFileURL) {
        self.mediaItem.image = nil;
    }
}

@end
