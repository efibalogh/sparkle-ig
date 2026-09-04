#import "SPKStrings.h"
#import "../../App/SPKPerfMeter.h"
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../AssetUtils.h"
#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Settings/Topics/SPKInstantsSettingsProvider.h"
#import "../../Shared/Gallery/SPKGalleryFile.h"
#import "../../Shared/Gallery/SPKGalleryPickerViewController.h"
#import "../../Shared/Instants/SPKInstantsVideoConfirmation.h"
#import "../../Shared/Instants/SPKInstantsSavedUsersViewController.h"
#import "../../Shared/Instants/SPKInstantsVideoStreamer.h"
#import "../../Shared/MediaTrim/SPKTrimConfiguration.h"
#import "../../Shared/MediaTrim/SPKTrimEditorViewController.h"
#import "../../Shared/MediaTrim/SPKTrimResult.h"
#import "../../Shared/MediaTrim/SPKTrimSaveCoordinator.h"
#import "../../Shared/PhotoEdit/SPKPhotoEditorViewController.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Shared/UI/SPKIGAlertPresenter.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Utils.h"

// One Sparkle button for the whole Instants camera screen: uploading a photo from
// Photos/Gallery/Files, browsing what you have already saved, and the settings page all
// hang off its menu. It replaces the two separate injected buttons this file and
// InstantsBrowseSaved used to place, which competed for the same header slot.
static NSString *const kSPKInstantsCameraButtonPref = @"instants_camera_btn";

static BOOL SPKInstantsCameraButtonEnabled(void) {
    return [SPKUtils getBoolPref:kSPKInstantsCameraButtonPref];
}

static UIImage *sSPKInstantsPendingImage = nil;
static CVPixelBufferRef sSPKInstantsCachedPixelBuffer = NULL;
static __weak UIImage *sSPKInstantsCachedImage = nil;
static int32_t sSPKInstantsCachedWidth = 0;
static int32_t sSPKInstantsCachedHeight = 0;
static OSType sSPKInstantsCachedFormat = 0;

static const void *kSPKInstantsGalleryButtonKey = &kSPKInstantsGalleryButtonKey;
static const void *kSPKInstantsGalleryFrameKey = &kSPKInstantsGalleryFrameKey;
static const void *kSPKInstantsGalleryIconKey = &kSPKInstantsGalleryIconKey;
static const void *kSPKInstantsVideoInjectorKey = &kSPKInstantsVideoInjectorKey;
static NSInteger const kSPKInstantsGalleryButtonTag = 921401;
static __weak UIView *sSPKInstantsVisibleCreationView = nil;

static void SPKInstantsPinEdges(UIView *view, UIView *host) {
    if (!view || !host)
        return;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:host.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor]
    ]];
}

static void SPKInstantsClearFrameCache(void) {
    if (sSPKInstantsCachedPixelBuffer) {
        CVPixelBufferRelease(sSPKInstantsCachedPixelBuffer);
        sSPKInstantsCachedPixelBuffer = NULL;
    }
    sSPKInstantsCachedImage = nil;
    sSPKInstantsCachedWidth = 0;
    sSPKInstantsCachedHeight = 0;
    sSPKInstantsCachedFormat = 0;
}

static UIImage *SPKInstantsNormalizedImage(UIImage *image) {
    if (!image || image.imageOrientation == UIImageOrientationUp)
        return image;
    UIGraphicsBeginImageContextWithOptions(image.size, YES, image.scale);
    [image drawInRect:(CGRect){CGPointZero, image.size}];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized ?: image;
}

static void SPKInstantsSetPendingImage(UIImage *image) {
    sSPKInstantsPendingImage = SPKInstantsNormalizedImage(image);
    SPKInstantsClearFrameCache();
    UIImage *capturedImage = sSPKInstantsPendingImage;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sSPKInstantsPendingImage == capturedImage) {
            sSPKInstantsPendingImage = nil;
            SPKInstantsClearFrameCache();
        }
    });
}

static UIViewController *SPKInstantsTopPresenter(void) {
    UIViewController *presenter = topMostController();
    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }
    return presenter;
}

static UIWindow *SPKInstantsWindowForView(UIView *view) {
    if (view.window)
        return view.window;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow)
                return window;
        }
    }
    return nil;
}

static void SPKInstantsWalkViews(UIView *root, void (^visitor)(UIView *view, BOOL *stop)) {
    if (!root || !visitor)
        return;
    BOOL stop = NO;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0 && !stop) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visitor(view, &stop);
        if (stop)
            break;
        for (UIView *subview in view.subviews) {
            [queue addObject:subview];
        }
    }
}

static BOOL SPKInstantsViewIsVisible(UIView *view) {
    return view && view.window && !view.hidden && view.alpha >= 0.05 && view.bounds.size.width > 1.0 && view.bounds.size.height > 1.0;
}

static BOOL SPKInstantsHeaderHasVisibleCreationView(UIView *header) {
    if (SPKInstantsViewIsVisible(sSPKInstantsVisibleCreationView) &&
        SPKInstantsWindowForView(sSPKInstantsVisibleCreationView) == SPKInstantsWindowForView(header)) {
        return YES;
    }

    UIWindow *window = SPKInstantsWindowForView(header);
    if (!window)
        return NO;
    __block BOOL found = NO;
    SPKInstantsWalkViews(window, ^(UIView *view, BOOL *stop) {
        if (!SPKInstantsViewIsVisible(view))
            return;
        if ([NSStringFromClass(view.class) containsString:@"IGQuickSnapCreationView"]) {
            found = YES;
            *stop = YES;
        }
    });
    return found;
}

static BOOL SPKInstantsHeaderHasVisibleSnapView(UIView *header) {
    UIWindow *window = SPKInstantsWindowForView(header);
    if (!window)
        return NO;
    __block BOOL found = NO;
    SPKInstantsWalkViews(window, ^(UIView *view, BOOL *stop) {
        if (!SPKInstantsViewIsVisible(view))
            return;
        if ([NSStringFromClass(view.class) containsString:@"IGQuickSnapImmersiveViewerSingleSnapView"]) {
            found = YES;
            *stop = YES;
        }
    });
    return found;
}

static UIView *SPKInstantsHeaderOwnedView(UIView *header, NSString *key) {
    if (!header || key.length == 0)
        return nil;
    id view = nil;
    @try {
        view = [header valueForKey:key];
    } @catch (__unused NSException *exception) {
    }
    if (![view isKindOfClass:UIView.class]) {
        Ivar ivar = class_getInstanceVariable(header.class, key.UTF8String);
        if (ivar) {
            @try {
                view = object_getIvar(header, ivar);
            } @catch (__unused NSException *exception) {
            }
        }
    }
    return [view isKindOfClass:UIView.class] ? (UIView *)view : nil;
}

static UIView *SPKInstantsHeaderArchiveButton(UIView *header) {
    UIView *archiveButton = SPKInstantsHeaderOwnedView(header, @"archiveButton");
    if (archiveButton && archiveButton.superview == header && !archiveButton.hidden && archiveButton.alpha >= 0.01) {
        return archiveButton;
    }
    return nil;
}

static UIView *SPKInstantsHeaderInWindow(UIWindow *window) {
    if (!window)
        return nil;
    __block UIView *header = nil;
    SPKInstantsWalkViews(window, ^(UIView *view, BOOL *stop) {
        if (!SPKInstantsViewIsVisible(view))
            return;
        if ([NSStringFromClass(view.class) containsString:@"IGQuickSnapNavigationV3HeaderButtonView"]) {
            header = view;
            *stop = YES;
        }
    });
    return header;
}

static NSString *SPKInstantsControlText(UIView *view) {
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        return [button titleForState:UIControlStateNormal] ?: button.accessibilityLabel;
    }
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        return label.text ?: label.accessibilityLabel;
    }
    return view.accessibilityLabel;
}

static BOOL SPKInstantsCreationViewIsPostCapture(UIView *creationView) {
    if (!creationView)
        return NO;
    __block BOOL foundUndo = NO;
    SPKInstantsWalkViews(creationView, ^(UIView *view, BOOL *stop) {
        if (!SPKInstantsViewIsVisible(view))
            return;

        // Instagram's visible text follows Instagram's language, which may differ
        // from Sparkle's override. Use stable action and icon signals only.
        if ([view isKindOfClass:UIControl.class] &&
            [SPKUtils control:(UIControl *)view
                hasTapActionContaining:@"undo"]) {
            foundUndo = YES;
            *stop = YES;
            return;
        }
        if ([view isKindOfClass:UIButton.class]) {
            NSString *iconName = [SPKUtils igImageNameForImage:((UIButton *)view).currentImage];
            if ([iconName rangeOfString:@"undo" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                foundUndo = YES;
                *stop = YES;
                return;
            }
        }
    });
    return foundUndo;
}

static void SPKInstantsClearPendingVideo(void);
static void SPKInstantsPresentVideoForPositioning(NSURL *videoURL);

static NSString *const kSPKInstantsImportPrefix = @"SPKInstantImport-";

/// UIImagePickerController hands back a URL inside the Photos picker extension's
/// own container. AVFoundation reads it through the sandbox extension granted
/// with the pick, but FFmpeg's plain open() cannot ("Operation not permitted"),
/// so the render failed only after the user had finished trimming. Copy the file
/// into our own container while the grant is still live. Only one import is kept
/// around: the previous one is purged on each pick.
static NSURL *SPKInstantsImportPickedVideo(NSURL *sourceURL) {
    if (!sourceURL)
        return nil;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *temporaryPath = NSTemporaryDirectory();
    for (NSString *name in [manager contentsOfDirectoryAtPath:temporaryPath error:nil] ?: @[]) {
        if ([name hasPrefix:kSPKInstantsImportPrefix]) {
            [manager removeItemAtPath:[temporaryPath stringByAppendingPathComponent:name] error:nil];
        }
    }

    NSString *extension = sourceURL.pathExtension.length > 0 ? sourceURL.pathExtension : @"mov";
    NSString *fileName = [NSString stringWithFormat:@"%@%@.%@", kSPKInstantsImportPrefix,
                                                    NSUUID.UUID.UUIDString, extension];
    NSURL *destination = [NSURL fileURLWithPath:[temporaryPath stringByAppendingPathComponent:fileName]];

    BOOL scoped = [sourceURL startAccessingSecurityScopedResource];
    NSError *error = nil;
    BOOL ok = [manager copyItemAtURL:sourceURL toURL:destination error:&error];
    if (scoped) {
        [sourceURL stopAccessingSecurityScopedResource];
    }
    if (!ok) {
        SPKLog(@"Instants", @"[Sparkle] could not import picked video: %@", error.localizedDescription);
        return nil;
    }
    return destination;
}

/// The picked file is the untouched original, which for a long 4K clip is large
/// enough that copying it on the main thread would visibly hang. Copy on a work
/// queue behind a progress pill and hand back the local URL on the main thread.
static void SPKInstantsImportPickedVideoAsync(NSURL *sourceURL, void (^completion)(NSURL *_Nullable)) {
    SPKNotificationPillView *pill = SPKNotifyProgress(kSPKNotificationInstantsUpload, SPKL(@"INSTANTS_INSTANTS_GALLERY_UPLOAD_IMPORTING_VIDEO_TEXT"), nil);
    [pill setProgressIndeterminate:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *localURL = SPKInstantsImportPickedVideo(sourceURL);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (localURL) {
                [pill dismiss];
            } else {
                [pill showErrorWithTitle:SPKL(@"INSTANTS_INSTANTS_GALLERY_UPLOAD_COULD_NOT_OPEN_VIDEO_TEXT")
                                subtitle:SPKL(@"INSTANTS_INSTANTS_GALLERY_UPLOAD_PICKED_FILE_COULD_NOT_READ_TEXT")
                                    icon:nil];
            }
            completion(localURL);
        });
    });
}

static void SPKInstantsClearPendingImageForCreationView(UIView *creationView) {
    (void)creationView;
    sSPKInstantsPendingImage = nil;
    SPKInstantsClearFrameCache();
    SPKInstantsClearPendingVideo();
}

static void SPKInstantsPresentImageForPositioning(UIImage *image) {
    if (!image)
        return;
    [SPKPhotoEditorViewController presentWithSourceImage:SPKInstantsNormalizedImage(image)
                                           configuration:[SPKPhotoEditorConfiguration lockedSquareConfiguration]
                                                    from:SPKInstantsTopPresenter()
                                              completion:^(UIImage *croppedImage) {
                                                  SPKInstantsSetPendingImage(croppedImage);
                                              }];
}

static CVPixelBufferRef SPKInstantsRenderImageToPixelBuffer(UIImage *image,
                                                            int32_t width,
                                                            int32_t height,
                                                            OSType format) CF_RETURNS_RETAINED;
static CVPixelBufferRef SPKInstantsRenderImageToPixelBuffer(UIImage *image,
                                                            int32_t width,
                                                            int32_t height,
                                                            OSType format) {
    if (!image.CGImage || width <= 0 || height <= 0)
        return NULL;
    NSDictionary *attributes = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
        (NSString *)kCVPixelBufferOpenGLESCompatibilityKey : @YES
    };

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          width,
                                          height,
                                          format,
                                          (__bridge CFDictionaryRef)attributes,
                                          &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer)
        return NULL;

    CGFloat visibleSide = MIN((CGFloat)width, (CGFloat)height);
    CGRect drawRect = CGRectMake(((CGFloat)width - visibleSide) / 2.0,
                                 ((CGFloat)height - visibleSide) / 2.0,
                                 visibleSide,
                                 visibleSide);
    BOOL rendered = NO;

    if (format == kCVPixelFormatType_32BGRA) {
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(base,
                                                     width,
                                                     height,
                                                     8,
                                                     bytesPerRow,
                                                     colorSpace,
                                                     kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        if (context) {
            CGContextSetFillColorWithColor(context, UIColor.blackColor.CGColor);
            CGContextFillRect(context, CGRectMake(0.0, 0.0, width, height));
            CGContextDrawImage(context, drawRect, image.CGImage);
            CGContextRelease(context);
            rendered = YES;
        }
        CGColorSpaceRelease(colorSpace);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    } else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
               format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        size_t bgraBytesPerRow = ((width * 4 + 63) / 64) * 64;
        void *bgra = calloc(bgraBytesPerRow * height, 1);
        if (bgra) {
            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
            CGContextRef context = CGBitmapContextCreate(bgra,
                                                         width,
                                                         height,
                                                         8,
                                                         bgraBytesPerRow,
                                                         colorSpace,
                                                         kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
            if (context) {
                CGContextSetFillColorWithColor(context, UIColor.blackColor.CGColor);
                CGContextFillRect(context, CGRectMake(0.0, 0.0, width, height));
                CGContextDrawImage(context, drawRect, image.CGImage);
                CGContextRelease(context);

                if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) == kCVReturnSuccess) {
                    void *yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
                    void *cbcrBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
                    if (yBase && cbcrBase) {
                        vImage_Buffer src = {bgra, (vImagePixelCount)height, (vImagePixelCount)width, bgraBytesPerRow};
                        vImage_Buffer yPlane = {
                            yBase,
                            CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                            CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                            CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)};
                        vImage_Buffer cbcrPlane = {
                            cbcrBase,
                            CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                            CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                            CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)};
                        BOOL fullRange = (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
                        vImage_YpCbCrPixelRange range = fullRange
                                                            ? (vImage_YpCbCrPixelRange){0, 128, 255, 255, 255, 1, 255, 0}
                                                            : (vImage_YpCbCrPixelRange){16, 128, 235, 240, 235, 16, 240, 16};
                        vImage_ARGBToYpCbCr conversion;
                        if (vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4,
                                                                          &range,
                                                                          &conversion,
                                                                          kvImageARGB8888,
                                                                          kvImage420Yp8_CbCr8,
                                                                          kvImageNoFlags) == kvImageNoError) {
                            const uint8_t permuteMap[4] = {3, 2, 1, 0};
                            rendered = (vImageConvert_ARGB8888To420Yp8_CbCr8(&src,
                                                                             &yPlane,
                                                                             &cbcrPlane,
                                                                             &conversion,
                                                                             permuteMap,
                                                                             kvImageNoFlags) == kvImageNoError);
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                }
            }
            CGColorSpaceRelease(colorSpace);
            free(bgra);
        }
    }

    if (!rendered) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    return pixelBuffer;
}

// Wrap an existing pixel buffer (a snapshotted live frame) into a fresh sample
// buffer that carries the template's timing/format, so it can be replayed
// downstream as if it were the current camera frame.
static CMSampleBufferRef SPKInstantsSampleBufferForPixelBuffer(CVPixelBufferRef pixelBuffer,
                                                               CMSampleBufferRef templateBuffer) CF_RETURNS_RETAINED;
static CMSampleBufferRef SPKInstantsSampleBufferForPixelBuffer(CVPixelBufferRef pixelBuffer,
                                                               CMSampleBufferRef templateBuffer) {
    if (!pixelBuffer || !templateBuffer)
        return NULL;

    CMVideoFormatDescriptionRef formatDescription = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                     pixelBuffer,
                                                     &formatDescription) != noErr ||
        !formatDescription) {
        return NULL;
    }

    CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeZero, kCMTimeInvalid};
    CMSampleBufferGetSampleTimingInfo(templateBuffer, 0, &timing);

    CMSampleBufferRef output = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                       pixelBuffer,
                                       true,
                                       NULL,
                                       NULL,
                                       formatDescription,
                                       &timing,
                                       &output);
    CFRelease(formatDescription);
    return output;
}

static CMSampleBufferRef SPKInstantsSampleBufferForImage(UIImage *image,
                                                         CMSampleBufferRef templateBuffer) CF_RETURNS_RETAINED;
static CMSampleBufferRef SPKInstantsSampleBufferForImage(UIImage *image,
                                                         CMSampleBufferRef templateBuffer) {
    if (!image.CGImage || !templateBuffer)
        return NULL;
    CMFormatDescriptionRef templateFormat = CMSampleBufferGetFormatDescription(templateBuffer);
    if (!templateFormat)
        return NULL;

    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(templateFormat);
    OSType format = CMFormatDescriptionGetMediaSubType(templateFormat);
    if (!sSPKInstantsCachedPixelBuffer ||
        sSPKInstantsCachedImage != image ||
        sSPKInstantsCachedWidth != dimensions.width ||
        sSPKInstantsCachedHeight != dimensions.height ||
        sSPKInstantsCachedFormat != format) {
        SPKInstantsClearFrameCache();
        sSPKInstantsCachedPixelBuffer = SPKInstantsRenderImageToPixelBuffer(image, dimensions.width, dimensions.height, format);
        sSPKInstantsCachedImage = image;
        sSPKInstantsCachedWidth = dimensions.width;
        sSPKInstantsCachedHeight = dimensions.height;
        sSPKInstantsCachedFormat = format;
    }
    if (!sSPKInstantsCachedPixelBuffer)
        return NULL;

    CMVideoFormatDescriptionRef formatDescription = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                     sSPKInstantsCachedPixelBuffer,
                                                     &formatDescription) != noErr ||
        !formatDescription) {
        return NULL;
    }

    CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeZero, kCMTimeInvalid};
    CMSampleBufferGetSampleTimingInfo(templateBuffer, 0, &timing);

    CMSampleBufferRef output = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                       sSPKInstantsCachedPixelBuffer,
                                       true,
                                       NULL,
                                       NULL,
                                       formatDescription,
                                       &timing,
                                       &output);
    CFRelease(formatDescription);
    return output;
}

@interface SPKInstantsVideoBufferInjector : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id realDelegate;
@end

@implementation SPKInstantsVideoBufferInjector
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.realDelegate respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    return self.realDelegate;
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
    id realDelegate = self.realDelegate;
    if (!realDelegate)
        return;

    // A pending video outranks everything for the same reason a pending image does:
    // it is the content the user chose to send. Frames come pre-rendered to the
    // camera's exact geometry and pixel format, so they drop straight in.
    if (SPKInstantsCameraButtonEnabled() && [SPKInstantsVideoStreamer isArmed]) {
        CMFormatDescriptionRef templateFormat = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (templateFormat) {
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(templateFormat);
            CVPixelBufferRef streamed =
                [SPKInstantsVideoStreamer copyPixelBufferForCameraTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                                                                 width:dimensions.width
                                                                height:dimensions.height
                                                                format:CMFormatDescriptionGetMediaSubType(templateFormat)];
            if (streamed) {
                CMSampleBufferRef replacement = SPKInstantsSampleBufferForPixelBuffer(streamed, sampleBuffer);
                CVPixelBufferRelease(streamed);
                if (replacement) {
                    [(id<AVCaptureVideoDataOutputSampleBufferDelegate>)realDelegate captureOutput:output
                                                                            didOutputSampleBuffer:replacement
                                                                                   fromConnection:connection];
                    CFRelease(replacement);
                    return;
                }
            }
        }
    }

    // Gallery/files upload: when the user has positioned and cropped an image to
    // send, this pending image is the user's intended content.
    UIImage *pendingImage = SPKInstantsCameraButtonEnabled() ? sSPKInstantsPendingImage : nil;
    if (pendingImage) {
        CMSampleBufferRef replacement = SPKInstantsSampleBufferForImage(pendingImage, sampleBuffer);
        if (replacement) {
            [(id<AVCaptureVideoDataOutputSampleBufferDelegate>)realDelegate captureOutput:output
                                                                    didOutputSampleBuffer:replacement
                                                                           fromConnection:connection];
            CFRelease(replacement);
            return;
        }
    }

    if ([realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [(id<AVCaptureVideoDataOutputSampleBufferDelegate>)realDelegate captureOutput:output
                                                                didOutputSampleBuffer:sampleBuffer
                                                                       fromConnection:connection];
    }
}
@end

@interface SPKInstantsImagePickerDelegate : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end

@implementation SPKInstantsImagePickerDelegate
+ (instancetype)shared {
    static SPKInstantsImagePickerDelegate *delegate;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        delegate = [[SPKInstantsImagePickerDelegate alloc] init];
    });
    return delegate;
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    NSURL *pickedURL = info[UIImagePickerControllerMediaURL];
    [picker dismissViewControllerAnimated:YES
                               completion:^{
                                   if (pickedURL) {
                                       SPKInstantsImportPickedVideoAsync(pickedURL, ^(NSURL *localURL) {
                                           if (localURL) {
                                               SPKInstantsPresentVideoForPositioning(localURL);
                                           }
                                       });
                                   } else if (image) {
                                       SPKInstantsPresentImageForPositioning(image);
                                   }
                               }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
@end

@interface SPKInstantsDocumentPickerDelegate : NSObject <UIDocumentPickerDelegate>
@end

@implementation SPKInstantsDocumentPickerDelegate
+ (instancetype)shared {
    static SPKInstantsDocumentPickerDelegate *delegate;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        delegate = [[SPKInstantsDocumentPickerDelegate alloc] init];
    });
    return delegate;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url)
        return;
    // `asCopy:YES` already vends a local copy, so a video can be handed to the
    // trim editor by URL; only an image needs reading into memory here.
    BOOL scoped = [url startAccessingSecurityScopedResource];
    UIImage *image = nil;
    BOOL isVideo = NO;
    NSString *type = nil;
    if ([url getResourceValue:&type forKey:NSURLTypeIdentifierKey error:nil] && type) {
        isVideo = [[UTType typeWithIdentifier:type] conformsToType:UTTypeMovie];
    }
    if (!isVideo) {
        NSData *data = [NSData dataWithContentsOfURL:url];
        image = data ? [UIImage imageWithData:data] : nil;
    }
    if (scoped)
        [url stopAccessingSecurityScopedResource];
    [controller dismissViewControllerAnimated:YES
                                   completion:^{
                                       if (isVideo) {
                                           SPKInstantsPresentVideoForPositioning(url);
                                       } else if (image) {
                                           SPKInstantsPresentImageForPositioning(image);
                                       }
                                   }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [self documentPicker:controller didPickDocumentsAtURLs:(url ? @[ url ] : @[])];
}
@end

@interface SPKInstantsGalleryButtonTarget : NSObject
+ (instancetype)shared;
- (void)buttonTapped:(UIButton *)sender;
@end

/// Plain UIButton plus the menu-open haptic every other Sparkle menu button has
/// (SPKChromeButton gets it from `menuWillDisplayHandler`; the action button
/// from its own interaction delegate). UIButton is the delegate of its built-in
/// context-menu interaction, so this fires for the primary-action tap too.
@interface SPKInstantsGalleryButton : UIButton
@end

@implementation SPKInstantsGalleryButton
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration
                           animator:(id<UIContextMenuInteractionAnimating>)animator {
    if ([UIButton instancesRespondToSelector:_cmd]) {
        [super contextMenuInteraction:interaction
      willDisplayMenuForConfiguration:configuration
                             animator:animator];
    }
    if (![SPKUtils getBoolPref:@"general_disable_haptics"]) {
        UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
        [feedback selectionChanged];
    }
}
@end

/// Longest clip we let the user select. IG caps a recorded Instant at 6 seconds
/// (observed; the cap is not readable statically because `videoCaptureMaxDuration`
/// is a Swift lazy).
static NSTimeInterval const kSPKInstantsMaxVideoSeconds = 6.0;

static NSURL *SPKInstantsPendingVideoURL(void) {
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"SPKInstantVideo.mp4"]];
}

static void SPKInstantsClearPendingVideo(void) {
    [SPKInstantsVideoStreamer stop];
    [[NSFileManager defaultManager] removeItemAtURL:SPKInstantsPendingVideoURL() error:nil];
}

/// Trim + crop the chosen video to the Instants square, then arm the streamer so
/// the camera feed becomes those frames. Rendering first (rather than cropping
/// live per frame) keeps the capture callback free of per-frame work and reuses
/// the same single-pass trim+crop render as everything else.
static void SPKInstantsPresentVideoForPositioning(NSURL *videoURL) {
    if (!videoURL)
        return;
    SPKTrimConfiguration *configuration = [SPKTrimConfiguration configurationWithVideoURL:videoURL];
    configuration.title = SPKL(@"INSTANTS_INSTANTS_GALLERY_UPLOAD_TRIM_INSTANT_TEXT");
    configuration.allowsFrameOnly = NO;
    configuration.allowsAudioOnly = NO;
    configuration.allowsCrop = YES;
    configuration.lockedCropAspectRatio = 1.0;
    configuration.maximumDuration = kSPKInstantsMaxVideoSeconds;

    [SPKTrimEditorViewController presentWithConfiguration:configuration
                                                    from:SPKInstantsTopPresenter()
                                              completion:^(SPKTrimResult *result) {
                                                  if (!result)
                                                      return;
                                                  [SPKTrimSaveCoordinator renderResult:result
                                                      progressTitle:SPKL(@"INSTANTS_INSTANTS_GALLERY_UPLOAD_PREPARING_INSTANT_TEXT")
                                                       existingPill:nil
                                                              store:^(NSURL *renderedURL, SPKTrimStoreCompletion done) {
                                                                  NSURL *destination = SPKInstantsPendingVideoURL();
                                                                  NSFileManager *manager = [NSFileManager defaultManager];
                                                                  [manager removeItemAtURL:destination error:nil];
                                                                  NSError *error = nil;
                                                                  // The coordinator cleans up its temp file after this
                                                                  // block, so keep our own copy for the streamer.
                                                                  BOOL ok = [manager copyItemAtURL:renderedURL toURL:destination error:&error];
                                                                  if (ok) {
                                                                      [SPKInstantsVideoStreamer startWithVideoURL:destination];
                                                                  } else {
                                                                      SPKLog(@"Instants", @"[Sparkle] instant video copy failed: %@",
                                                                             error.localizedDescription);
                                                                  }
                                                                  done(ok, ok ? SPKL(@"INSTANTS_INSTANTS_GALLERY_UPLOAD_PRESS_HOLD_RECORD_TEXT") : SPKL(@"INSTANTS_INSTANTS_GALLERY_UPLOAD_COULD_NOT_PREPARE_VIDEO_TEXT"));
                                                              }
                                                       onSuccessTap:nil
                                                         completion:nil];
                                              }];
}

static void SPKInstantsPickFromPhotos(void) {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[ @"public.image", @"public.movie" ];
    // Hand us the untouched file: the trim editor does its own trimming, and
    // UIImagePickerController would otherwise transcode to its own preset.
    picker.videoExportPreset = AVAssetExportPresetPassthrough;
    picker.delegate = [SPKInstantsImagePickerDelegate shared];
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    [SPKInstantsTopPresenter() presentViewController:picker animated:YES completion:nil];
}

static NSSet<NSNumber *> *SPKInstantsUploadableMediaTypes(void) {
    return [NSSet setWithObjects:@(SPKGalleryMediaTypeImage), @(SPKGalleryMediaTypeVideo), nil];
}

static void SPKInstantsPickFromGallery(void) {
    [SPKGalleryPickerViewController presentFromViewController:SPKInstantsTopPresenter()
                                                        title:SPKL(@"INSTANTS_INSTANTS_GALLERY_UPLOAD_CHOOSE_MEDIA_TEXT")
                                            allowedMediaTypes:SPKInstantsUploadableMediaTypes()
                                      allowsMultipleSelection:NO
                                                   completion:^(NSArray<SPKGalleryFile *> *selectedFiles) {
                                                       SPKGalleryFile *file = selectedFiles.firstObject;
                                                       if (!file.filePath)
                                                           return;
                                                       if (file.mediaType == SPKGalleryMediaTypeVideo) {
                                                           SPKInstantsPresentVideoForPositioning([NSURL fileURLWithPath:file.filePath]);
                                                           return;
                                                       }
                                                       UIImage *image = [UIImage imageWithContentsOfFile:file.filePath];
                                                       if (image)
                                                           SPKInstantsPresentImageForPositioning(image);
                                                   }];
}

static void SPKInstantsPickFromFiles(void) {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeImage, UTTypeMovie ] asCopy:YES];
    picker.allowsMultipleSelection = NO;
    picker.delegate = [SPKInstantsDocumentPickerDelegate shared];
    [SPKInstantsTopPresenter() presentViewController:picker animated:YES completion:nil];
}

/// The camera button's menu content: upload sources, then browsing what is already saved,
/// then settings -- each its own inline group, so the three concerns read as separate.
static NSArray<UIMenuElement *> *SPKInstantsCameraButtonMenuGroups(void) {
    NSMutableArray<UIAction *> *sourceActions = [NSMutableArray array];
    [sourceActions addObject:[UIAction actionWithTitle:SPKL(@"ALERT_ACTION_SELECT_PHOTOS")
                                                 image:[SPKAssetUtils menuIconNamed:@"photo_gallery"]
                                            identifier:nil
                                               handler:^(__unused UIAction *action) {
                                                   SPKInstantsPickFromPhotos();
                                               }]];
    if ([SPKGalleryPickerViewController hasSelectableFilesForAllowedMediaTypes:SPKInstantsUploadableMediaTypes()]) {
        [sourceActions addObject:[UIAction actionWithTitle:SPKL(@"ALERT_ACTION_SELECT_GALLERY")
                                                     image:[SPKAssetUtils menuIconNamed:@"sparkle_gallery"]
                                                identifier:nil
                                                   handler:^(__unused UIAction *action) {
                                                       SPKInstantsPickFromGallery();
                                                   }]];
    }
    [sourceActions addObject:[UIAction actionWithTitle:SPKL(@"ALERT_ACTION_SELECT_FILES")
                                                 image:[SPKAssetUtils menuIconNamed:@"folder"]
                                            identifier:nil
                                               handler:^(__unused UIAction *action) {
                                                   SPKInstantsPickFromFiles();
                                               }]];

    UIAction *browseAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_BROWSE_SAVED")
                                                 image:[SPKAssetUtils menuIconNamed:@"instants"]
                                            identifier:nil
                                               handler:^(__unused UIAction *action) {
                                                   [SPKInstantsSavedUsersViewController presentFromViewController:SPKInstantsTopPresenter()];
                                               }];

    UIAction *settingsAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_INSTANTS_SETTINGS")
                                                   image:[SPKAssetUtils menuIconNamed:@"settings"]
                                              identifier:nil
                                                 handler:^(__unused UIAction *action) {
                                                     [SPKUtils showSettingsForTopicTitle:@"Instants"];
                                                 }];

    return @[
        [UIMenu menuWithTitle:SPKL(@"MENU_UPLOAD") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:sourceActions],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ browseAction ]],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ settingsAction ]],
    ];
}

/// Built through an uncached deferred element so the contents are rebuilt on every open:
/// "Select from Gallery" only belongs there while the Gallery holds a photo, and that
/// changes underneath a menu assembled once at button creation.
static UIMenu *SPKInstantsCameraButtonMenu(void) {
    UIDeferredMenuElement *deferred =
        [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
            completion(SPKInstantsCameraButtonMenuGroups());
        }];
    return [UIMenu menuWithTitle:@"" children:@[ deferred ]];
}

@implementation SPKInstantsGalleryButtonTarget
+ (instancetype)shared {
    static SPKInstantsGalleryButtonTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [[SPKInstantsGalleryButtonTarget alloc] init];
    });
    return target;
}

- (void)buttonTapped:(UIButton *)sender {
    // Only reached on systems where the menu didn't take (it is the primary action
    // otherwise); rebuilding it here keeps the button from being a dead tap.
    sender.menu = SPKInstantsCameraButtonMenu();
}
@end

static BOOL SPKInstantsGalleryFrameMatches(UIView *view, CGRect frame) {
    if (![view isKindOfClass:UIView.class] || view.hidden || !view.superview)
        return NO;
    return ABS(CGRectGetMinX(view.frame) - CGRectGetMinX(frame)) < 0.5 &&
           ABS(CGRectGetMinY(view.frame) - CGRectGetMinY(frame)) < 0.5 &&
           ABS(CGRectGetWidth(view.frame) - CGRectGetWidth(frame)) < 0.5 &&
           ABS(CGRectGetHeight(view.frame) - CGRectGetHeight(frame)) < 0.5;
}

static UIView *SPKInstantsGalleryFallbackRightAnchor(UIView *header, UIView *host) {
    CGFloat halfWidth = header.bounds.size.width / 2.0;
    UIView *anchor = nil;
    CGFloat minX = CGFLOAT_MAX;

    for (UIView *subview in header.subviews) {
        if (subview == host || subview.hidden || subview.alpha < 0.01)
            continue;
        if (subview.bounds.size.width < 4.0 || subview.bounds.size.height < 4.0)
            continue;
        if (CGRectGetMidX(subview.frame) < halfWidth)
            continue;
        if (CGRectGetMinX(subview.frame) < minX) {
            anchor = subview;
            minX = CGRectGetMinX(subview.frame);
        }
    }
    return anchor;
}

static CGRect SPKInstantsGalleryButtonFrame(UIView *header, UIView *host) {
    CGFloat side = 44.0;
    CGFloat gap = 0.0;
    UIView *anchor = SPKInstantsHeaderArchiveButton(header) ?: SPKInstantsGalleryFallbackRightAnchor(header, host);

    if (anchor) {
        return CGRectMake(CGRectGetMinX(anchor.frame) - side - gap,
                          CGRectGetMidY(anchor.frame) - side / 2.0,
                          side,
                          side);
    }

    return CGRectMake(header.bounds.size.width - side - 12.0,
                      (header.bounds.size.height - side) / 2.0,
                      side,
                      side);
}

static NSString *SPKInstantsGalleryFrameKey(UIView *header, UIView *anchor, CGRect frame) {
    return [NSString stringWithFormat:@"%p|%@|%@",
                                      anchor ?: header,
                                      NSStringFromCGRect(anchor ? anchor.frame : CGRectZero),
                                      NSStringFromCGRect(frame)];
}

static void SPKRemoveInstantsGalleryButton(UIView *header) {
    UIView *host = [header viewWithTag:kSPKInstantsGalleryButtonTag];
    [host removeFromSuperview];
}

static void SPKInstantsInstallGalleryButton(UIView *header) {
    SPK_PERF_SCOPE(@"InstantsGalleryUpload.placeButton");
    if (!header)
        return;
    UIView *host = [header viewWithTag:kSPKInstantsGalleryButtonTag];
    UIButton *button = [host isKindOfClass:UIView.class] ? objc_getAssociatedObject(host, kSPKInstantsGalleryButtonKey) : nil;
    if (!SPKInstantsCameraButtonEnabled()) {
        SPKRemoveInstantsGalleryButton(header);
        return;
    }

    if (!SPKInstantsHeaderHasVisibleCreationView(header) || SPKInstantsHeaderHasVisibleSnapView(header)) {
        SPKRemoveInstantsGalleryButton(header);
        return;
    }

    if (![button isKindOfClass:SPKInstantsGalleryButton.class]) {
        [host removeFromSuperview];
        host = [[UIView alloc] init];
        host.tag = kSPKInstantsGalleryButtonTag;
        host.translatesAutoresizingMaskIntoConstraints = YES;
        host.clipsToBounds = NO;

        SPKChromeCanvas *canvas = [[SPKChromeCanvas alloc] init];
        canvas.userInteractionEnabled = YES;
        [host addSubview:canvas];
        SPKInstantsPinEdges(canvas, host);

        button = [SPKInstantsGalleryButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        // The whole point of the merged button is its menu, so the menu *is* the tap.
        button.showsMenuAsPrimaryAction = YES;
        button.menu = SPKInstantsCameraButtonMenu();
        button.adjustsImageWhenHighlighted = YES;
        button.tintColor = [UIColor whiteColor];
        button.accessibilityLabel = SPKL(@"ABOUT_INFORMATION_SPARKLE_TITLE");
        [button addTarget:[SPKInstantsGalleryButtonTarget shared]
                      action:@selector(buttonTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [canvas.contentContainer addSubview:button];
        SPKInstantsPinEdges(button, canvas.contentContainer);
        objc_setAssociatedObject(host, kSPKInstantsGalleryButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [header addSubview:host];
    }

    // The glyph follows the global "Open Menu Icon" choice, like every other Sparkle
    // button whose tap opens a menu. Re-applied whenever that choice changes, so the
    // setting takes effect without recreating the button (or restarting).
    NSString *iconName = SPKActionButtonOpenMenuIconName();
    NSString *appliedIconName = objc_getAssociatedObject(button, kSPKInstantsGalleryIconKey);
    if (![appliedIconName isEqualToString:iconName]) {
        UIImage *image = [SPKAssetUtils instagramIconNamed:iconName
                                                 pointSize:24.0
                                             renderingMode:UIImageRenderingModeAlwaysTemplate];
        [button setImage:image forState:UIControlStateNormal];
        objc_setAssociatedObject(button, kSPKInstantsGalleryIconKey, iconName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }

    UIView *anchor = SPKInstantsHeaderArchiveButton(header) ?: SPKInstantsGalleryFallbackRightAnchor(header, host);
    CGRect frame = SPKInstantsGalleryButtonFrame(header, host);
    NSString *frameKey = SPKInstantsGalleryFrameKey(header, anchor, frame);
    NSString *previousFrameKey = objc_getAssociatedObject(host, kSPKInstantsGalleryFrameKey);
    if ([previousFrameKey isEqualToString:frameKey] && SPKInstantsGalleryFrameMatches(host, frame)) {
        return;
    }

    if (!SPKInstantsGalleryFrameMatches(host, frame)) {
        host.frame = frame;
    }
    objc_setAssociatedObject(host, kSPKInstantsGalleryFrameKey, frameKey, OBJC_ASSOCIATION_COPY_NONATOMIC);

    host.hidden = NO;
    host.alpha = 1.0;
    [header bringSubviewToFront:host];
}

typedef void (*SPKInstantsCreationViewLayoutIMP)(id, SEL);
typedef void (*SPKInstantsCreationViewMoveIMP)(id, SEL, id);
typedef void (*SPKInstantsHeaderLayoutIMP)(id, SEL);
typedef void (*SPKInstantsSetSampleDelegateIMP)(id, SEL, id, dispatch_queue_t);

static SPKInstantsCreationViewLayoutIMP orig_creationViewLayoutSubviews = NULL;
static SPKInstantsCreationViewMoveIMP orig_creationViewWillMoveToWindow = NULL;
static SPKInstantsHeaderLayoutIMP orig_headerLayoutSubviews = NULL;
static SPKInstantsSetSampleDelegateIMP orig_setSampleBufferDelegate = NULL;

static void replaced_creationViewLayoutSubviews(id self, SEL _cmd) {
    if (orig_creationViewLayoutSubviews)
        orig_creationViewLayoutSubviews(self, _cmd);
    UIView *creationView = (UIView *)self;
    if (SPKInstantsViewIsVisible(creationView)) {
        sSPKInstantsVisibleCreationView = creationView;
        if (sSPKInstantsPendingImage && SPKInstantsCreationViewIsPostCapture(creationView)) {
            SPKInstantsClearPendingImageForCreationView(creationView);
            return;
        }
        UIView *header = SPKInstantsHeaderInWindow(SPKInstantsWindowForView(creationView));
        if (header)
            SPKInstantsInstallGalleryButton(header);
    }
}

static void replaced_creationViewWillMoveToWindow(id self, SEL _cmd, id window) {
    if (!window && (sSPKInstantsPendingImage || [SPKInstantsVideoStreamer isArmed])) {
        SPKInstantsClearPendingImageForCreationView((UIView *)self);
    }
    if (!window && sSPKInstantsVisibleCreationView == (UIView *)self) {
        sSPKInstantsVisibleCreationView = nil;
    }
    if (orig_creationViewWillMoveToWindow)
        orig_creationViewWillMoveToWindow(self, _cmd, window);
}

static void replaced_headerLayoutSubviews(id self, SEL _cmd) {
    if (orig_headerLayoutSubviews)
        orig_headerLayoutSubviews(self, _cmd);
    SPKInstantsInstallGalleryButton((UIView *)self);
}

static void replaced_setSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    if (delegate && SPKInstantsCameraButtonEnabled() && ![delegate isKindOfClass:SPKInstantsVideoBufferInjector.class]) {
        SPKInstantsVideoBufferInjector *injector = [[SPKInstantsVideoBufferInjector alloc] init];
        injector.realDelegate = delegate;
        objc_setAssociatedObject(self, kSPKInstantsVideoInjectorKey, injector, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (orig_setSampleBufferDelegate)
            orig_setSampleBufferDelegate(self, _cmd, injector, queue);
        return;
    }
    if (orig_setSampleBufferDelegate)
        orig_setSampleBufferDelegate(self, _cmd, delegate, queue);
}

// An injected video is held on its first frame until IG actually starts
// recording, because IG records from the instant the shutter is pressed: a
// preview that was already playing would start the take mid-clip.
//
// Two independent signals are hooked because it is not obvious which one the
// QuickSnap path drives. FBCaptureCoordinator is Optic's own recorder (the
// processor controller owns one), while didStart/StopRecording is the delegate
// notification. `play`/`pause` are idempotent, so whichever fires first wins and
// the other is a no-op rather than a rewind mid-take.
static void SPKInstantsHandleRecordingStart(const char *signal) {
    BOOL armed = [SPKInstantsVideoStreamer isArmed];
    SPKLog(@"Instants", @"[Sparkle] record start via %s (armed=%d)", signal, armed);
    if (SPKInstantsCameraButtonEnabled() && armed) {
        [SPKInstantsVideoStreamer play];
    }
}

static void SPKInstantsHandleRecordingEnd(const char *signal) {
    BOOL armed = [SPKInstantsVideoStreamer isArmed];
    SPKLog(@"Instants", @"[Sparkle] record end via %s (armed=%d)", signal, armed);
    if (SPKInstantsCameraButtonEnabled() && armed) {
        [SPKInstantsVideoStreamer pause];
    }
}

static void (*orig_didStartRecording)(id, SEL) = NULL;
static void replaced_didStartRecording(id self, SEL _cmd) {
    SPKInstantsHandleRecordingStart("IGCameraOptic.didStartRecording");
    if (orig_didStartRecording)
        orig_didStartRecording(self, _cmd);
}

static void (*orig_didStopRecording)(id, SEL) = NULL;
static void replaced_didStopRecording(id self, SEL _cmd) {
    SPKInstantsHandleRecordingEnd("IGCameraOptic.didStopRecording");
    if (orig_didStopRecording)
        orig_didStopRecording(self, _cmd);
}

static void (*orig_startRecordingWithCompletion)(id, SEL, id, BOOL) = NULL;
static void replaced_startRecordingWithCompletion(id self, SEL _cmd, id completion, BOOL echoCancellation) {
    SPKInstantsHandleRecordingStart("FBCaptureCoordinator.startRecording");
    if (orig_startRecordingWithCompletion)
        orig_startRecordingWithCompletion(self, _cmd, completion, echoCancellation);
}

static void (*orig_stopRecordingWithCompletion)(id, SEL, id, id) = NULL;
static void replaced_stopRecordingWithCompletion(id self, SEL _cmd, id completion, id queue) {
    SPKInstantsHandleRecordingEnd("FBCaptureCoordinator.stopRecording");
    if (orig_stopRecordingWithCompletion)
        orig_stopRecordingWithCompletion(self, _cmd, completion, queue);
}

static void (*orig_cancelRecordingIfAny)(id, SEL) = NULL;
static void replaced_cancelRecordingIfAny(id self, SEL _cmd) {
    SPKInstantsHandleRecordingEnd("FBCaptureCoordinator.cancelRecording");
    if (orig_cancelRecordingIfAny)
        orig_cancelRecordingIfAny(self, _cmd);
}

// The shutter's own long-press handler. IGQuickSnapCameraManager drives
// recording from Swift (its `recordingState` is a Swift stored property with no
// ObjC entry point), so the button is the closest hookable point to the actual
// start of a take -- and being a gesture handler it is necessarily @objc.
static void (*orig_captureButtonLongPress)(id, SEL, id) = NULL;
static void replaced_captureButtonLongPress(id self, SEL _cmd, id gesture) {
    if ([self isKindOfClass:UIView.class] && [gesture isKindOfClass:UIGestureRecognizer.class]) {
        SPKInstantsVideoConfirmationHandleLongPress((UIView *)self, (UIGestureRecognizer *)gesture);
    }
    UIGestureRecognizerState state = [(UIGestureRecognizer *)gesture state];
    if (state == UIGestureRecognizerStateBegan) {
        SPKInstantsHandleRecordingStart("IGCameraCaptureButton.longPress");
    } else if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled ||
               state == UIGestureRecognizerStateFailed) {
        SPKInstantsHandleRecordingEnd("IGCameraCaptureButton.longPress");
    }
    if (orig_captureButtonLongPress)
        orig_captureButtonLongPress(self, _cmd, gesture);
}

// AVCaptureMovieFileOutput provides a stable recording signal even though Optic
// owns the surrounding pipeline. Hooking AVFoundation avoids Instagram class
// churn while the handler remains gated by an armed injected video.
static void (*orig_startRecordingToOutputFileURL)(id, SEL, id, id) = NULL;
static void replaced_startRecordingToOutputFileURL(id self, SEL _cmd, id fileURL, id delegate) {
    SPKInstantsHandleRecordingStart("AVCaptureMovieFileOutput.startRecording");
    if (orig_startRecordingToOutputFileURL)
        orig_startRecordingToOutputFileURL(self, _cmd, fileURL, delegate);
}

static void (*orig_movieOutputStopRecording)(id, SEL) = NULL;
static void replaced_movieOutputStopRecording(id self, SEL _cmd) {
    SPKInstantsHandleRecordingEnd("AVCaptureMovieFileOutput.stopRecording");
    if (orig_movieOutputStopRecording)
        orig_movieOutputStopRecording(self, _cmd);
}

static void SPKHookInstanceMethod(const char *className, SEL selector, IMP replacement, IMP *original) {
    Class cls = objc_getClass(className);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!cls || !method) {
        SPKLog(@"Instants", @"[Sparkle] Missing hook target %s %@", className, NSStringFromSelector(selector));
        return;
    }
    MSHookMessageEx(cls, selector, replacement, original);
}

extern "C" void SPKInstallInstantsGalleryUploadHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKHookInstanceMethod("_TtC29IGQuickSnapCreationController23IGQuickSnapCreationView",
                              @selector(layoutSubviews),
                              (IMP)replaced_creationViewLayoutSubviews,
                              (IMP *)&orig_creationViewLayoutSubviews);
        SPKHookInstanceMethod("_TtC29IGQuickSnapCreationController23IGQuickSnapCreationView",
                              @selector(willMoveToWindow:),
                              (IMP)replaced_creationViewWillMoveToWindow,
                              (IMP *)&orig_creationViewWillMoveToWindow);
        SPKHookInstanceMethod("_TtC45IGQuickSnapNavigationV3HeaderButtonController39IGQuickSnapNavigationV3HeaderButtonView",
                              @selector(layoutSubviews),
                              (IMP)replaced_headerLayoutSubviews,
                              (IMP *)&orig_headerLayoutSubviews);
        SPKHookInstanceMethod("AVCaptureVideoDataOutput",
                              @selector(setSampleBufferDelegate:queue:),
                              (IMP)replaced_setSampleBufferDelegate,
                              (IMP *)&orig_setSampleBufferDelegate);
        SPKHookInstanceMethod("IGCameraOpticVideoProcessorController",
                              @selector(didStartRecording),
                              (IMP)replaced_didStartRecording,
                              (IMP *)&orig_didStartRecording);
        SPKHookInstanceMethod("IGCameraOpticVideoProcessorController",
                              @selector(didStopRecording),
                              (IMP)replaced_didStopRecording,
                              (IMP *)&orig_didStopRecording);
        SPKHookInstanceMethod("FBCaptureCoordinator",
                              @selector(startRecordingWithCompletion:enableEchoCancellation:),
                              (IMP)replaced_startRecordingWithCompletion,
                              (IMP *)&orig_startRecordingWithCompletion);
        SPKHookInstanceMethod("FBCaptureCoordinator",
                              @selector(stopRecordingWithCompletion:callbackQueue:),
                              (IMP)replaced_stopRecordingWithCompletion,
                              (IMP *)&orig_stopRecordingWithCompletion);
        SPKHookInstanceMethod("FBCaptureCoordinator",
                              @selector(cancelRecordingIfAny),
                              (IMP)replaced_cancelRecordingIfAny,
                              (IMP *)&orig_cancelRecordingIfAny);
        SPKHookInstanceMethod("IGCameraCaptureButton",
                              @selector(_longPress:),
                              (IMP)replaced_captureButtonLongPress,
                              (IMP *)&orig_captureButtonLongPress);
        SPKHookInstanceMethod("AVCaptureMovieFileOutput",
                              @selector(startRecordingToOutputFileURL:recordingDelegate:),
                              (IMP)replaced_startRecordingToOutputFileURL,
                              (IMP *)&orig_startRecordingToOutputFileURL);
        SPKHookInstanceMethod("AVCaptureMovieFileOutput",
                              @selector(stopRecording),
                              (IMP)replaced_movieOutputStopRecording,
                              (IMP *)&orig_movieOutputStopRecording);
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKInstantsVideoSendConfirmedNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(__unused NSNotification *note) {
                                                          if ([SPKInstantsVideoStreamer isArmed]) {
                                                              SPKInstantsClearPendingImageForCreationView(
                                                                  sSPKInstantsVisibleCreationView);
                                                          }
                                                      }];
        SPKLog(@"Instants", @"[Sparkle] Instants gallery upload hooks installed");
    });
}
