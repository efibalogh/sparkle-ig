#import <UIKit/UIKit.h>

#import "SPKTrimCrop.h"

NS_ASSUME_NONNULL_BEGIN

/// Full-screen video framing editor: pan/zoom crop over a preview of the clip
/// (paused until tapped, looping the trimmed range), plus fine straightening, 90° rotate and horizontal flip. Shares its crop surface with the
/// photo editor (`SPKCropCanvasView`), so the geometry behaves identically.
///
/// It produces an `SPKTrimCrop` — a description, not a render. The trim editor
/// carries it on the `SPKTrimResult` and `SPKTrimRenderer` applies it in one pass
/// with the trim, so cropping never costs an extra encode.
@interface SPKVideoCropViewController : UIViewController

/// `lockedAspectRatio` > 0 pins the crop to that ratio and hides the ratio picker
/// (Instants pass 1.0); 0 offers the full freeform picker. `initialCrop` reopens
/// on a previous selection. `completion` gets nil when the user cancels.
/// Opened from another editor (the trimmer), it replaces that editor's content
/// in the same stack instead of stacking a second modal.
+ (void)presentForVideoURL:(NSURL *)videoURL
         lockedAspectRatio:(CGFloat)lockedAspectRatio
               initialCrop:(nullable SPKTrimCrop *)initialCrop
                     title:(nullable NSString *)title
                      from:(UIViewController *)presenter
                completion:(void (^)(SPKTrimCrop *_Nullable crop))completion;

/// As above, previewing only `startSeconds`...`endSeconds` (the trim being
/// framed): it opens paused on the first frame of that range and loops within
/// it. An end at or before the start previews the whole clip.
+ (void)presentForVideoURL:(NSURL *)videoURL
              startSeconds:(NSTimeInterval)startSeconds
                endSeconds:(NSTimeInterval)endSeconds
         lockedAspectRatio:(CGFloat)lockedAspectRatio
               initialCrop:(nullable SPKTrimCrop *)initialCrop
                     title:(nullable NSString *)title
                      from:(UIViewController *)presenter
                completion:(void (^)(SPKTrimCrop *_Nullable crop))completion;

@end

NS_ASSUME_NONNULL_END
