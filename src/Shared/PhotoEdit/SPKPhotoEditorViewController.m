#import "SPKStrings.h"
#import "SPKPhotoEditorViewController.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../UI/SPKChipBar.h"
#import "../Crop/SPKCropControlsView.h"
#import "../MediaTrim/SPKTrimCrop.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKMediaEditorChrome.h"

#pragma mark - Configuration

@implementation SPKPhotoEditorDoneOption
+ (instancetype)optionWithTitle:(NSString *)title
                     identifier:(NSString *)identifier
                       iconName:(NSString *)iconName {
    SPKPhotoEditorDoneOption *o = [self new];
    o.title = title;
    o.identifier = identifier;
    o.iconName = iconName;
    return o;
}
@end

@implementation SPKPhotoEditorConfiguration

+ (instancetype)lockedSquareConfiguration {
    SPKPhotoEditorConfiguration *c = [SPKPhotoEditorConfiguration new];
    c.aspectMode = SPKCropAspectModeLocked;
    c.confirmButtonTitle = SPKL(@"PHOTO_EDIT_PHOTO_EDITOR_USE_TEXT");
    return c;
}

+ (instancetype)freeformConfiguration {
    SPKPhotoEditorConfiguration *c = [SPKPhotoEditorConfiguration new];
    c.aspectMode = SPKCropAspectModeFreeform;
    c.confirmButtonTitle = SPKL(@"SETTINGS_WHATS_NEW_DONE_TEXT");
    return c;
}

@end

// Width of the controls column when they sit beside the photo.
static const CGFloat kSPKEditorSideControlsWidth = 300.0;

#pragma mark - Image helpers

// Bakes a fine rotation into a bitmap of the same pixel size: the picture turns
// about its centre and is scaled by the cover factor, so it fills the frame with
// no empty corners. The crop is then taken from this straightened bitmap, which
// is exactly what the canvas showed.
static UIImage *SPKPhotoEditorStraightened(UIImage *image, CGFloat degrees) {
    if (!image.CGImage || fabs(degrees) < SPKTrimCropStraightenEpsilon)
        return image;
    CGSize size = image.size;
    CGFloat cover = SPKTrimCropStraightenCoverScale(size, degrees);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = image.scale;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *output = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef ctx = rendererContext.CGContext;
        CGContextTranslateCTM(ctx, size.width / 2.0, size.height / 2.0);
        CGContextRotateCTM(ctx, degrees * (CGFloat)M_PI / 180.0);
        CGContextScaleCTM(ctx, cover, cover);
        [image drawInRect:CGRectMake(-size.width / 2.0, -size.height / 2.0, size.width, size.height)];
    }];
    return output.CGImage ? output : image;
}

// Redraws to a straight (orientation-Up) bitmap so all crop math works in pixel
// space without worrying about EXIF orientation.
static UIImage *SPKPhotoEditorNormalized(UIImage *image) {
    if (!image || image.imageOrientation == UIImageOrientationUp)
        return image;
    UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
    [image drawInRect:(CGRect){CGPointZero, image.size}];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized ?: image;
}

// Bakes a 90° rotation (clockwise / counter-clockwise) into a fresh Up-oriented
// bitmap, keeping the crop pipeline rotation-agnostic.
static UIImage *SPKPhotoEditorRotated(UIImage *image, BOOL clockwise) {
    if (!image.CGImage)
        return image;
    CGSize size = image.size;
    CGSize rotated = CGSizeMake(size.height, size.width);
    UIGraphicsBeginImageContextWithOptions(rotated, NO, image.scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return image;
    }
    CGContextTranslateCTM(ctx, rotated.width / 2.0, rotated.height / 2.0);
    CGContextRotateCTM(ctx, clockwise ? (M_PI / 2.0) : (-M_PI / 2.0));
    [image drawInRect:CGRectMake(-size.width / 2.0, -size.height / 2.0, size.width, size.height)];
    UIImage *output = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return output ?: image;
}

static UIImage *SPKPhotoEditorFlipped(UIImage *image) {
    if (!image.CGImage)
        return image;
    CGSize size = image.size;
    UIGraphicsBeginImageContextWithOptions(size, NO, image.scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return image;
    }
    CGContextTranslateCTM(ctx, size.width, 0.0);
    CGContextScaleCTM(ctx, -1.0, 1.0);
    [image drawInRect:(CGRect){CGPointZero, size}];
    UIImage *output = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return output ?: image;
}

#pragma mark - Controller

@interface SPKPhotoEditorViewController () <SPKChipBarDelegate>
@end

@implementation SPKPhotoEditorViewController {
    UIImage *_workingImage;          // normalized + baked rotations/flips
    CGFloat _straightenDegrees;      // fine rotation, applied on output
    SPKCropCanvasView *_canvas;      // shared pan/zoom crop surface
    UIView *_contentHost;            // the canvas content; clips the turned photo
    UIImageView *_imageView;         // the photo, turned by the straighten angle
    SPKCropControlsView *_controls;  // aspect chips or straighten ruler
    SPKChipBar *_aspectChips;        // freeform only
    SPKStraightenRulerView *_ruler;
    NSArray<NSLayoutConstraint *> *_bottomLayout;
    NSArray<NSLayoutConstraint *> *_sideLayout;
    BOOL _usesSideLayout;
    UIBarButtonItem *_cancelItem;
    BOOL _orientationEdited;         // rotated or flipped since opening (or the last Reset)
}

+ (instancetype)editorWithSourceImage:(UIImage *)image configuration:(SPKPhotoEditorConfiguration *)configuration {
    SPKPhotoEditorViewController *editor = [[self alloc] init];
    editor.configuration = configuration ?: [SPKPhotoEditorConfiguration freeformConfiguration];
    editor.sourceImage = image;
    return editor;
}

+ (void)presentWithSourceImage:(UIImage *)image
                 configuration:(SPKPhotoEditorConfiguration *)configuration
                          from:(UIViewController *)presenter
                    completion:(void (^)(UIImage *))completion {
    if (!image || !presenter)
        return;
    SPKPhotoEditorViewController *editor = [self editorWithSourceImage:image configuration:configuration];
    editor.completion = completion;
    SPKMediaEditorPresent(editor, presenter);
}

+ (void)openFromEditor:(UIViewController *)host
           sourceImage:(UIImage *)image
         configuration:(SPKPhotoEditorConfiguration *)configuration
            completion:(void (^)(UIImage *))completion {
    if (!image || !host)
        return;
    SPKPhotoEditorViewController *editor = [self editorWithSourceImage:image configuration:configuration];
    editor.completion = completion;
    SPKMediaEditorOpenFromEditor(editor, host);
}

+ (void)presentWithSourceImage:(UIImage *)image
                 configuration:(SPKPhotoEditorConfiguration *)configuration
                          from:(UIViewController *)presenter
         destinationCompletion:(void (^)(UIImage *, NSString *))destinationCompletion {
    if (!image || !presenter)
        return;
    SPKPhotoEditorViewController *editor = [self editorWithSourceImage:image configuration:configuration];
    editor.destinationCompletion = destinationCompletion;
    SPKMediaEditorPresent(editor, presenter);
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.configuration) {
        self.configuration = [SPKPhotoEditorConfiguration freeformConfiguration];
    }
    self.title = SPKL(@"ALERT_ACTION_EDIT");
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground] ?: [UIColor blackColor];

    _workingImage = SPKPhotoEditorNormalized(self.sourceImage);

    [self setupChrome];
    [self setupCanvas];
    [self setupControls];
    [self setupLayouts];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Rotate, flip and Reset live in the native toolbar: Liquid Glass on iOS 26,
    // and on iPhone Duo the system moves it into the side column.
    [self.navigationController setToolbarHidden:NO animated:NO];
    SPKMediaEditorConfigureCancelItem(_cancelItem, self);
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [self applyLayoutForSize:self.view.bounds.size];
}

#pragma mark - Chrome

- (void)setupChrome {
    UIBarButtonItem *cancelItem = SPKMediaChromeTopBarButtonItem(@"close", self, @selector(cancelTapped));
    cancelItem.accessibilityLabel = SPKL(@"ALERT_ACTION_CANCEL");
    _cancelItem = cancelItem;
    // When the caller supplies destinations, Done is a menu (pick where to save
    // without dismissing first); otherwise it's a plain confirm that just returns
    // the edited image to the caller.
    UIBarButtonItem *doneItem;
    if (self.configuration.doneOptions.count > 0) {
        doneItem = SPKMediaChromeTopBarMenuButtonItem(
            @"check", [self buildDoneMenu], self.configuration.confirmButtonTitle ?: SPKL(@"SETTINGS_WHATS_NEW_DONE_TEXT"));
    } else {
        // An intermediate confirm is a plain, untinted button: only the final Done
        // of a flow gets the emphasized capsule and the blue glyph.
        BOOL intermediate = self.configuration.intermediateConfirm;
        doneItem = SPKMediaChromeTopBarButtonItemWithStyle(
            @"check", self, @selector(confirmTapped),
            intermediate ? UIBarButtonItemStylePlain : UIBarButtonItemStyleDone,
            intermediate ? nil : [SPKUtils SPKColor_InstagramBlue],
            self.configuration.confirmButtonTitle ?: SPKL(@"SETTINGS_WHATS_NEW_DONE_TEXT"));
    }
    self.navigationItem.hidesBackButton = YES;
    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ cancelItem ]);
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ doneItem ]);
}

- (void)setupCanvas {
    _canvas = [[SPKCropCanvasView alloc] initWithFrame:CGRectZero];
    _canvas.translatesAutoresizingMaskIntoConstraints = NO;
    _canvas.aspectMode = self.configuration.aspectMode;
    _canvas.lockedAspectRatio = 1.0;
    _canvas.aspect = SPKCropAspectFreeform;
    [self.view addSubview:_canvas];

    // The canvas zooms and pans its content view by its own transform, so the
    // straighten turn goes on a child: the host keeps the photo's size and
    // clips the turned photo to it.
    _contentHost = [[UIView alloc] initWithFrame:(CGRect){CGPointZero, _workingImage.size}];
    _contentHost.clipsToBounds = YES;
    _contentHost.backgroundColor = [UIColor blackColor];
    _imageView = [[UIImageView alloc] initWithImage:_workingImage];
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    [_contentHost addSubview:_imageView];
    [self layoutStraightenedImage];
    [_canvas setContentView:_contentHost contentSize:_workingImage.size];
}

- (void)setupControls {
    _controls = [[SPKCropControlsView alloc] initWithAspectChips:(self.configuration.aspectMode == SPKCropAspectModeFreeform)];
    _controls.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_controls];
    _aspectChips = _controls.aspectChips;
    _aspectChips.delegate = self;
    _ruler = _controls.ruler;
    [_ruler addTarget:self action:@selector(rulerChanged) forControlEvents:UIControlEventValueChanged];
    [_ruler addTarget:self action:@selector(rulerBegan) forControlEvents:UIControlEventEditingDidBegin];
    [_ruler addTarget:self action:@selector(rulerEnded) forControlEvents:UIControlEventEditingDidEnd];

    // Every tool is a glyph in the native toolbar: on iPhone Duo the toolbar
    // becomes a vertical column, which only lays out icon items.
    NSArray<UIBarButtonItem *> *tools = SPKCropMakeToolBarItems(self, @selector(rotateLeftTapped), @selector(flipTapped),
                                                                 @selector(rotateRightTapped));
    UIBarButtonItem *reset = SPKMediaChromeBottomBarButtonItem(@"arrow_ccw", SPKL(@"ALERT_ACTION_RESET"), self, @selector(resetTapped));
    NSMutableArray<NSArray<UIBarButtonItem *> *> *groups = [NSMutableArray array];
    if (_controls.switchItem)
        [groups addObject:@[ _controls.switchItem ]];
    [groups addObject:tools];
    [groups addObject:@[ reset ]];
    self.toolbarItems = SPKMediaChromeBottomToolbarItemsWithGroups(groups);
}

// Two arrangements, picked from the size classes: under the photo on a tall
// display, in a column beside it on a short or wide one (landscape, iPhone Duo).
- (void)setupLayouts {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_canvas.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_canvas.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    ]];
    _bottomLayout = @[
        [_canvas.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_canvas.bottomAnchor constraintEqualToAnchor:_controls.topAnchor constant:-8.0],
        [_controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_controls.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0],
    ];
    _sideLayout = @[
        [_canvas.trailingAnchor constraintEqualToAnchor:_controls.leadingAnchor constant:-12.0],
        [_canvas.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [_controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [_controls.widthAnchor constraintEqualToConstant:kSPKEditorSideControlsWidth],
        [_controls.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
    ];
    _usesSideLayout = SPKMediaEditorPrefersSideControls(self.traitCollection, self.view.bounds.size);
    [NSLayoutConstraint activateConstraints:_usesSideLayout ? _sideLayout : _bottomLayout];
}

- (void)applyLayoutForSize:(CGSize)size {
    BOOL side = SPKMediaEditorPrefersSideControls(self.traitCollection, size);
    if (side == _usesSideLayout)
        return;
    _usesSideLayout = side;
    [NSLayoutConstraint deactivateConstraints:side ? _bottomLayout : _sideLayout];
    [NSLayoutConstraint activateConstraints:side ? _sideLayout : _bottomLayout];
}

#pragma mark - SPKChipBarDelegate (aspect)

- (void)chipBar:(__unused SPKChipBar *)bar didSelectIndex:(NSInteger)index {
    if (index < 0 || index >= SPKCropAspectPresetCount())
        return;
    _canvas.aspect = SPKCropAspectPresetAtIndex(index);
}

#pragma mark - Straighten

- (void)layoutStraightenedImage {
    CGSize size = _workingImage.size;
    _contentHost.bounds = (CGRect){CGPointZero, size};
    _imageView.transform = CGAffineTransformIdentity;
    _imageView.bounds = (CGRect){CGPointZero, size};
    _imageView.center = CGPointMake(size.width / 2.0, size.height / 2.0);
    CGFloat cover = SPKTrimCropStraightenCoverScale(size, _straightenDegrees);
    CGAffineTransform t = CGAffineTransformMakeRotation(_straightenDegrees * (CGFloat)M_PI / 180.0);
    _imageView.transform = CGAffineTransformScale(t, cover, cover);
}

- (void)rulerBegan {
    [_canvas setGridVisible:YES];
}

- (void)rulerChanged {
    _straightenDegrees = _ruler.value;
    [self layoutStraightenedImage];
}

- (void)rulerEnded {
    [_canvas setGridVisible:NO];
}

#pragma mark - Rotate / flip / reset

- (void)rotateLeftTapped {
    [self applyTransform:^{
        self->_workingImage = SPKPhotoEditorRotated(self->_workingImage, NO);
    }];
}
- (void)rotateRightTapped {
    [self applyTransform:^{
        self->_workingImage = SPKPhotoEditorRotated(self->_workingImage, YES);
    }];
}
- (void)flipTapped {
    [self applyTransform:^{
        self->_workingImage = SPKPhotoEditorFlipped(self->_workingImage);
    }];
}

// Rotate/flip re-bake the bitmap, so the canvas is handed the new dimensions and
// re-fits its crop around them. The straighten angle carries over.
- (void)applyTransform:(void (^)(void))mutate {
    mutate();
    _orientationEdited = YES;
    _imageView.image = _workingImage;
    [self layoutStraightenedImage];
    [_canvas setContentSize:_workingImage.size];
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
}

- (void)resetTapped {
    _orientationEdited = NO;
    _workingImage = SPKPhotoEditorNormalized(self.sourceImage);
    _straightenDegrees = 0.0;
    _ruler.value = 0.0;
    _imageView.image = _workingImage;
    [self layoutStraightenedImage];
    if (_aspectChips) {
        _aspectChips.selectedIndex = 0;
        _canvas.aspect = SPKCropAspectFreeform;
    }
    [_canvas setContentSize:_workingImage.size];
    [_canvas resetCrop];
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
}

#pragma mark - Output

- (UIImage *)editedImage {
    UIImage *source = SPKPhotoEditorStraightened(_workingImage, _straightenDegrees);
    if (!source.CGImage)
        return source;
    CGRect normalizedCrop = _canvas.normalizedCropRect;
    if (CGRectIsEmpty(normalizedCrop) || CGRectIsNull(normalizedCrop))
        return source;

    UIImage *normalized = source;
    if (source.imageOrientation != UIImageOrientationUp) {
        UIGraphicsBeginImageContextWithOptions(source.size, YES, source.scale);
        [source drawInRect:(CGRect){CGPointZero, source.size}];
        normalized = UIGraphicsGetImageFromCurrentImageContext() ?: source;
        UIGraphicsEndImageContext();
    }
    if (!normalized.CGImage)
        return source;

    CGFloat pixelWidth = (CGFloat)CGImageGetWidth(normalized.CGImage);
    CGFloat pixelHeight = (CGFloat)CGImageGetHeight(normalized.CGImage);
    CGRect pixelRect = CGRectMake(normalizedCrop.origin.x * pixelWidth,
                                  normalizedCrop.origin.y * pixelHeight,
                                  normalizedCrop.size.width * pixelWidth,
                                  normalizedCrop.size.height * pixelHeight);
    CGRect pixelBounds = CGRectMake(0.0, 0.0, pixelWidth, pixelHeight);
    pixelRect = CGRectIntersection(CGRectIntegral(pixelRect), pixelBounds);
    if (CGRectIsEmpty(pixelRect) || CGRectIsNull(pixelRect))
        return normalized;

    CGImageRef cropped = CGImageCreateWithImageInRect(normalized.CGImage, pixelRect);
    if (!cropped)
        return normalized;
    UIImage *output = [UIImage imageWithCGImage:cropped scale:normalized.scale orientation:UIImageOrientationUp];
    CGImageRelease(cropped);
    return output.CGImage ? output : normalized;
}

#pragma mark - Confirm / cancel

- (BOOL)hasChanges {
    return _orientationEdited || fabs(_straightenDegrees) >= SPKTrimCropStraightenEpsilon || _canvas.userAdjusted ||
           (_aspectChips && _canvas.aspect != SPKCropAspectFreeform);
}

- (void)cancelTapped {
    __weak typeof(self) weakSelf = self;
    SPKMediaEditorConfirmDiscard(self, [self hasChanges], ^{
        [weakSelf closeWithoutSaving];
    });
}

- (void)closeWithoutSaving {
    // In destination-menu mode, signal the cancel as a nil image so the caller
    // (which retains itself across the async flow) can release. Plain-confirm
    // callers documented that `completion` is not called on cancel, so leave it.
    void (^destinationCompletion)(UIImage *, NSString *) = [self.destinationCompletion copy];
    SPKMediaEditorClose(self, ^{
        if (destinationCompletion)
            destinationCompletion(nil, nil);
    });
}

- (void)confirmTapped {
    UIImage *image = [self editedImage];
    void (^completion)(UIImage *) = [self.completion copy];
    SPKMediaEditorClose(self, ^{
        if (completion && image)
            completion(image);
    });
}

- (UIMenu *)buildDoneMenu {
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (SPKPhotoEditorDoneOption *option in self.configuration.doneOptions) {
        NSString *identifier = option.identifier;
        UIImage *image = option.iconName.length > 0
                             ? [SPKAssetUtils menuIconNamed:option.iconName]
                             : nil;
        UIAction *action = [UIAction actionWithTitle:option.title
                                               image:image
                                          identifier:nil
                                             handler:^(__unused UIAction *a) {
                                                 [weakSelf finishWithDestinationTag:identifier];
                                             }];
        [children addObject:action];
    }
    return [UIMenu menuWithTitle:@"" children:children];
}

- (void)finishWithDestinationTag:(NSString *)destinationTag {
    UIImage *image = [self editedImage];
    void (^completion)(UIImage *, NSString *) = [self.destinationCompletion copy];
    SPKMediaEditorClose(self, ^{
        if (completion && image)
            completion(image, destinationTag);
    });
}

@end
