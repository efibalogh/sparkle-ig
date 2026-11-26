#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Crop-rectangle aspect behaviour.
typedef NS_ENUM(NSInteger, SPKCropAspectMode) {
    /// A single fixed ratio, no ratio picker (Instants positioning).
    SPKCropAspectModeLocked = 0,
    /// Freeform + ratio presets for general editing.
    SPKCropAspectModeFreeform = 1,
};

/// The ratio presets offered in freeform mode. `Original` derives its ratio from
/// the content, `Freeform` lets each corner move independently.
typedef NS_ENUM(NSInteger, SPKCropAspect) {
    SPKCropAspectOriginal = 0,
    SPKCropAspectFreeform,
    SPKCropAspectSquare,
    SPKCropAspectPortrait23,   // 2:3
    SPKCropAspectLandscape32,  // 3:2
    SPKCropAspectPortrait34,   // 3:4
    SPKCropAspectLandscape43,  // 4:3
    SPKCropAspectPortrait45,   // 4:5
    SPKCropAspectLandscape54,  // 5:4
    SPKCropAspectPortrait916,  // 9:16
    SPKCropAspectLandscape169, // 16:9
};

/// Chip-row helpers: the presets in display order, shared by every host so the
/// ratio picker looks and behaves the same everywhere.
FOUNDATION_EXPORT NSInteger SPKCropAspectPresetCount(void);
FOUNDATION_EXPORT SPKCropAspect SPKCropAspectPresetAtIndex(NSInteger index);
FOUNDATION_EXPORT NSString *SPKCropAspectTitle(SPKCropAspect aspect);
/// Ratio (width / height) for a fixed preset, or 0 for freeform / original
/// (which derive theirs from the content).
FOUNDATION_EXPORT CGFloat SPKCropAspectRatio(SPKCropAspect aspect);

/// Builds the rotate-left / flip / rotate-right control row shared by the photo
/// and video crop editors. The returned view is `translatesAutoresizingMaskIntoConstraints = NO`
/// and lays its three 44pt buttons out equally; the caller positions it.
FOUNDATION_EXPORT UIView *SPKCropMakeToolRow(id target, SEL rotateLeft, SEL flip, SEL rotateRight);

/// The same three tools as bar button items, for an editor's native toolbar
/// (Liquid Glass on iOS 26, moved into the side column on iPhone Duo).
FOUNDATION_EXPORT NSArray<UIBarButtonItem *> *SPKCropMakeToolBarItems(id target, SEL rotateLeft, SEL flip, SEL rotateRight);

/// The pan/zoom crop surface: a scroll view hosting arbitrary content, a dimming
/// overlay punched through by the crop rect, and corner grabbers. Content-agnostic
/// on purpose — `SPKPhotoEditorViewController` hosts a `UIImageView` in it and the
/// video cropper hosts an `AVPlayerLayer` view, so the crop geometry has exactly
/// one implementation.
///
/// The host owns the content and its orientation: on rotate/flip it re-points the
/// content (baking a new bitmap, or setting a layer transform) and calls
/// `-setContentSize:`, which re-fits the crop and zoom around the new dimensions.
@interface SPKCropCanvasView : UIView

/// Installs the croppable content. `contentSize` is its natural size in points
/// (image point size, or the video's oriented render size).
- (void)setContentView:(UIView *)contentView contentSize:(CGSize)contentSize;

/// Swaps in new content dimensions (a 90° rotation flips them) and re-fits.
- (void)setContentSize:(CGSize)contentSize;

@property (nonatomic, readonly) CGSize contentSize;

/// Freeform exposes every preset; Locked pins the crop to `lockedAspectRatio`
/// with no grabbers. Set before the first layout.
@property (nonatomic, assign) SPKCropAspectMode aspectMode;

/// The ratio enforced in `SPKCropAspectModeLocked`. Defaults to 1.0 (square).
@property (nonatomic, assign) CGFloat lockedAspectRatio;

/// The selected preset in freeform mode. Setting it re-fits the crop rect.
@property (nonatomic, assign) SPKCropAspect aspect;

/// The current selection as a rect in content coordinates, normalized to 0..1.
/// `CGRectZero` before the first layout pass.
@property (nonatomic, readonly) CGRect normalizedCropRect;

/// YES once the user has panned, zoomed or dragged a grabber; cleared by
/// `-resetCrop`. Lets the host tell an untouched crop from an edited one.
@property (nonatomic, readonly) BOOL userAdjusted;

/// Fades the rule-of-thirds guides in or out. The canvas shows them on its own
/// while a handle or the content is dragged; hosts show them while another
/// control (the straighten ruler) changes the framing.
- (void)setGridVisible:(BOOL)visible;

/// Re-fits the crop rect and zoom for the current aspect, discarding any pan.
- (void)resetCrop;

/// Restores a previously produced selection (reopening an editor) by re-deriving
/// the crop rect, zoom and pan from it. Applied on the first layout pass when the
/// canvas hasn't been laid out yet.
- (void)restoreNormalizedCropRect:(CGRect)normalizedRect;

@end

NS_ASSUME_NONNULL_END
