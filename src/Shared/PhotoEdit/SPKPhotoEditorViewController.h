#import <UIKit/UIKit.h>

#import "../Crop/SPKCropCanvasView.h"

NS_ASSUME_NONNULL_BEGIN

/// One destination choice in the editor's Done menu (mirrors the trim editor's
/// `SPKTrimDoneOption`). When a configuration carries `doneOptions`, the Done
/// button becomes a menu and the chosen `identifier` is handed to the
/// destination completion instead of the plain image completion.
@interface SPKPhotoEditorDoneOption : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *identifier; // e.g. "photos", "gallery", "share", "clipboard"
@property (nonatomic, copy, nullable) NSString *iconName;
+ (instancetype)optionWithTitle:(NSString *)title
                     identifier:(NSString *)identifier
                       iconName:(nullable NSString *)iconName;
@end

/// Configures a photo editor instance. Instants uses `lockedSquareConfiguration`;
/// the Gallery uses `freeformConfiguration`.
@interface SPKPhotoEditorConfiguration : NSObject
@property (nonatomic, assign) SPKCropAspectMode aspectMode;
/// Title of the confirm button (e.g. "Use" for Instants, "Done" for Gallery).
@property (nonatomic, copy) NSString *confirmButtonTitle;
/// When non-empty, Done becomes a destination menu (Photos / Gallery / Share /
/// Copy ...). The chosen id is delivered via the destination completion. Empty =
/// a plain confirm that returns just the image (gallery/instants flows).
@property (nonatomic, copy, nullable) NSArray<SPKPhotoEditorDoneOption *> *doneOptions;
/// YES when confirming hands the result back to another editor rather than
/// committing it (the trim editor's Frame Only pass). Only the final Done in a
/// flow is prominent, so an intermediate one stays a plain button.
@property (nonatomic, assign) BOOL intermediateConfirm;

+ (instancetype)lockedSquareConfiguration; // confirm = "Use"
+ (instancetype)freeformConfiguration;     // confirm = "Done"
@end

/// A self-contained, full-screen photo editor: pan/zoom crop with a selectable
/// aspect (freeform + ratio presets), fine straightening, 90° rotate and
/// horizontal flip.
/// Generalized from the original Instants square cropper so it can be reused by
/// the Gallery and the trim editor's Frame Only output.
@interface SPKPhotoEditorViewController : UIViewController
@property (nonatomic, strong) UIImage *sourceImage;
@property (nonatomic, strong) SPKPhotoEditorConfiguration *configuration;
/// Called with the edited image when the user confirms (plain-confirm mode, no
/// `doneOptions`). Not called on cancel.
@property (nonatomic, copy, nullable) void (^completion)(UIImage *image);
/// Called with the edited image and the chosen destination id when the
/// configuration carries `doneOptions`. Not called on cancel.
@property (nonatomic, copy, nullable) void (^destinationCompletion)(UIImage *image, NSString *destinationTag);

/// Presents the editor wrapped in a dark, full-screen navigation controller
/// (matching the trim editor's chrome — native top bar renders as Liquid Glass on
/// iOS 26). `completion` runs only when the user confirms.
+ (void)presentWithSourceImage:(UIImage *)image
                 configuration:(nullable SPKPhotoEditorConfiguration *)configuration
                          from:(UIViewController *)presenter
                    completion:(void (^)(UIImage *image))completion;

/// Opens the editor from inside another editor (the trimmer's Edit Frame): it
/// replaces the host's content in the same editor stack rather than stacking a
/// second full-screen modal. `completion` runs only when the user confirms.
+ (void)openFromEditor:(UIViewController *)host
           sourceImage:(UIImage *)image
         configuration:(nullable SPKPhotoEditorConfiguration *)configuration
            completion:(void (^)(UIImage *image))completion;

/// Destination-menu variant: `configuration.doneOptions` drives a Done menu and
/// the chosen destination id is delivered alongside the edited image.
+ (void)presentWithSourceImage:(UIImage *)image
                 configuration:(SPKPhotoEditorConfiguration *)configuration
                          from:(UIViewController *)presenter
         destinationCompletion:(void (^)(UIImage *image, NSString *destinationTag))destinationCompletion;
@end

NS_ASSUME_NONNULL_END
