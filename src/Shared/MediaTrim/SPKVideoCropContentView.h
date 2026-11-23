#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A view that renders a video under a quarter-turn rotation and optional
/// horizontal mirror, scaled to fill its own bounds. Keeping the orientation on
/// the layer (rather than re-encoding) is what lets rotate and flip stay free
/// until the final render.
///
/// Two users: the crop editor hosts it inside `SPKCropCanvasView` as the
/// croppable content, and the trim editor hosts it (clipped, offset) to preview
/// what a confirmed crop will produce.
///
/// Note that an `AVPlayer` only drives one `AVPlayerLayer` at a time, so a host
/// swapping between this view and its own player layer must hand the player over
/// explicitly rather than leaving it attached to both.
@interface SPKVideoCropContentView : UIView

- (instancetype)initWithPlayer:(nullable AVPlayer *)player orientedSize:(CGSize)orientedSize;

/// The video's size as the viewer sees it (after the track's display transform),
/// before any rotation applied here.
@property (nonatomic, assign, readonly) CGSize orientedSize;

/// Quarter turns clockwise (0-3). Odd values swap the picture's axes.
@property (nonatomic, assign) NSInteger rotationQuarters;

/// Horizontal mirror, applied in the rotated frame so a flip always reads as
/// horizontal on screen.
@property (nonatomic, assign) BOOL mirrored;

/// Fine rotation in degrees, clockwise, applied after the quarter turns and
/// mirror. The picture is scaled up by the cover factor so it still fills this
/// view; the view clips the overflow.
@property (nonatomic, assign) CGFloat straightenDegrees;

@property (nonatomic, strong, readonly) AVPlayerLayer *playerLayer;

/// The picture's size after `rotationQuarters` — the size this view should be
/// given to show the whole frame undistorted.
- (CGSize)rotatedSize;

@end

NS_ASSUME_NONNULL_END
