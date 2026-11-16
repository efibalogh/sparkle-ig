#import "SPKStrings.h"
#import "SPKPhotoEditorViewController.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../UI/SPKChipBar.h"
#import "../UI/SPKMediaChrome.h"

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

static const CGFloat kSPKEditorControlsRow = 56.0;

#pragma mark - Image helpers

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
    UIImage *_workingImage;      // normalized + baked rotations/flips
    SPKCropCanvasView *_canvas;  // shared pan/zoom crop surface
    UIImageView *_imageView;     // the canvas content
    UIView *_bottomControls;     // rotate / flip row
    SPKChipBar *_aspectChips;    // freeform only
}

+ (void)presentWithSourceImage:(UIImage *)image
                 configuration:(SPKPhotoEditorConfiguration *)configuration
                          from:(UIViewController *)presenter
                    completion:(void (^)(UIImage *))completion {
    if (!image || !presenter)
        return;
    SPKPhotoEditorViewController *editor = [[self alloc] init];
    editor.configuration = configuration ?: [SPKPhotoEditorConfiguration freeformConfiguration];
    editor.sourceImage = image;
    editor.completion = completion;
    // Hosted in a navigation controller so the top bar is a native component —
    // Liquid Glass on iOS 26, standard translucent bar earlier. Always dark (like
    // Photos / the trim editor) so black canvas + light controls read correctly.
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [presenter presentViewController:nav animated:YES completion:nil];
}

+ (void)presentWithSourceImage:(UIImage *)image
                 configuration:(SPKPhotoEditorConfiguration *)configuration
                          from:(UIViewController *)presenter
         destinationCompletion:(void (^)(UIImage *, NSString *))destinationCompletion {
    if (!image || !presenter)
        return;
    SPKPhotoEditorViewController *editor = [[self alloc] init];
    editor.configuration = configuration ?: [SPKPhotoEditorConfiguration freeformConfiguration];
    editor.sourceImage = image;
    editor.destinationCompletion = destinationCompletion;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [presenter presentViewController:nav animated:YES completion:nil];
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
    [self setupCropContainer];
    [self setupBottomControls];
    [self setupAspectChipsIfNeeded];
}

#pragma mark - Chrome

- (void)setupChrome {
    UIBarButtonItem *cancelItem = SPKMediaChromeTopBarButtonItem(@"close", self, @selector(cancelTapped));
    cancelItem.accessibilityLabel = SPKL(@"ALERT_ACTION_CANCEL");
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
    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ cancelItem ]);
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ doneItem ]);
}

- (void)setupCropContainer {
    _canvas = [[SPKCropCanvasView alloc] initWithFrame:CGRectZero];
    _canvas.translatesAutoresizingMaskIntoConstraints = NO;
    _canvas.aspectMode = self.configuration.aspectMode;
    _canvas.lockedAspectRatio = 1.0;
    _canvas.aspect = SPKCropAspectOriginal;
    [self.view addSubview:_canvas];
    [NSLayoutConstraint activateConstraints:@[
        [_canvas.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_canvas.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [_canvas.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
    ]];

    _imageView = [[UIImageView alloc] initWithImage:_workingImage];
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    [_canvas setContentView:_imageView contentSize:_workingImage.size];
}

- (void)setupBottomControls {
    _bottomControls = SPKCropMakeToolRow(self, @selector(rotateLeftTapped), @selector(flipTapped), @selector(rotateRightTapped));
    [self.view addSubview:_bottomControls];

    [NSLayoutConstraint activateConstraints:@[
        [_bottomControls.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor
                                                      constant:48.0],
        [_bottomControls.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor
                                                       constant:-48.0],
        [_bottomControls.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                     constant:-8.0],
        [_bottomControls.heightAnchor constraintEqualToConstant:kSPKEditorControlsRow],
    ]];
}

- (void)setupAspectChipsIfNeeded {
    if (self.configuration.aspectMode != SPKCropAspectModeFreeform) {
        // No chip row: the crop pane pins directly above the controls.
        [_canvas.bottomAnchor constraintEqualToAnchor:_bottomControls.topAnchor constant:-8.0].active = YES;
        return;
    }

    _aspectChips = [[SPKChipBar alloc] init];
    _aspectChips.translatesAutoresizingMaskIntoConstraints = NO;
    _aspectChips.delegate = self;
    // Content-sized (scrolling) rather than fill-equally: the fill-equally mode
    // shrinks the wider "Original" chip's font to fit its share, leaving the
    // shorter chips at full size. Content sizing keeps every chip's font uniform.
    _aspectChips.distributesToFit = NO;
    NSInteger aspectCount = SPKCropAspectPresetCount();
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:(NSUInteger)aspectCount];
    for (NSInteger i = 0; i < aspectCount; i++) {
        [titles addObject:SPKCropAspectTitle(SPKCropAspectPresetAtIndex(i))];
    }
    [_aspectChips setItems:titles symbols:@[]];
    _aspectChips.selectedIndex = 0; // Original (first)
    [self.view addSubview:_aspectChips];

    [NSLayoutConstraint activateConstraints:@[
        [_aspectChips.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [_aspectChips.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [_aspectChips.bottomAnchor constraintEqualToAnchor:_bottomControls.topAnchor
                                                  constant:-4.0],
        [_canvas.bottomAnchor constraintEqualToAnchor:_aspectChips.topAnchor
                                             constant:-4.0],
    ]];
}

#pragma mark - SPKChipBarDelegate (aspect)

- (void)chipBar:(__unused SPKChipBar *)bar didSelectIndex:(NSInteger)index {
    if (index < 0 || index >= SPKCropAspectPresetCount())
        return;
    _canvas.aspect = SPKCropAspectPresetAtIndex(index);
}

#pragma mark - Rotate / flip

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
// re-fits its crop around them.
- (void)applyTransform:(void (^)(void))mutate {
    mutate();
    _imageView.image = _workingImage;
    [_canvas setContentSize:_workingImage.size];
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
}

#pragma mark - Output

- (UIImage *)editedImage {
    UIImage *source = _workingImage;
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

- (void)cancelTapped {
    // In destination-menu mode, signal the cancel as a nil image so the caller
    // (which retains itself across the async flow) can release. Plain-confirm
    // callers documented that `completion` is not called on cancel, so leave it.
    void (^destinationCompletion)(UIImage *, NSString *) = [self.destinationCompletion copy];
    [self dismissViewControllerAnimated:YES
                             completion:^{
                                 if (destinationCompletion)
                                     destinationCompletion(nil, nil);
                             }];
}

- (void)confirmTapped {
    UIImage *image = [self editedImage];
    void (^completion)(UIImage *) = [self.completion copy];
    [self dismissViewControllerAnimated:YES
                             completion:^{
                                 if (completion && image)
                                     completion(image);
                             }];
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
    [self dismissViewControllerAnimated:YES
                             completion:^{
                                 if (completion && image)
                                     completion(image, destinationTag);
                             }];
}

@end
