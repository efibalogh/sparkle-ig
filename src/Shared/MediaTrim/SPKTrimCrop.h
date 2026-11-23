#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The smallest scale at which a `size` frame turned by `degrees` about its
/// centre still covers the unturned frame completely. 1 at 0 degrees.
FOUNDATION_EXPORT CGFloat SPKTrimCropStraightenCoverScale(CGSize size, CGFloat degrees);

/// Straighten angles smaller than this are treated as none.
FOUNDATION_EXPORT const CGFloat SPKTrimCropStraightenEpsilon;

/// A framing edit for a video: an optional quarter-turn rotation, an optional
/// horizontal mirror, and a crop rectangle.
///
/// Coordinate space: the source's *oriented* frame — what the viewer sees, i.e.
/// after the track's `preferredTransform` (or, for FFmpeg, after its automatic
/// display-matrix rotation). `rotationQuarters` and `mirrored` are applied first,
/// and `normalizedRect` is expressed in that rotated/mirrored space, so a crop is
/// always "the rectangle the user drew over the picture they were looking at".
@interface SPKTrimCrop : NSObject <NSCopying>

/// Crop rectangle, normalized 0..1 in the rotated/mirrored oriented frame.
@property (nonatomic, assign) CGRect normalizedRect;

/// Quarter turns clockwise (0-3) applied before the crop.
@property (nonatomic, assign) NSInteger rotationQuarters;

/// Horizontal mirror applied after the rotation, before the crop.
@property (nonatomic, assign) BOOL mirrored;

/// Fine rotation in degrees, clockwise, applied after the quarter turns and the
/// mirror (-45...45). The picture turns about its centre and is scaled up just
/// enough to cover the whole frame again (`SPKTrimCropStraightenCoverScale`), so
/// `normalizedRect` keeps describing the same rectangle size and never reaches
/// past the picture into empty corners.
@property (nonatomic, assign) CGFloat straightenDegrees;

/// YES when this describes the untouched full frame, so callers can drop it and
/// keep the plain (cheaper, byte-identical) render path.
@property (nonatomic, readonly) BOOL isIdentity;

+ (instancetype)cropWithNormalizedRect:(CGRect)normalizedRect
                      rotationQuarters:(NSInteger)rotationQuarters
                              mirrored:(BOOL)mirrored;

+ (instancetype)cropWithNormalizedRect:(CGRect)normalizedRect
                      rotationQuarters:(NSInteger)rotationQuarters
                              mirrored:(BOOL)mirrored
                     straightenDegrees:(CGFloat)straightenDegrees;

/// The frame size after the rotation but before the crop, for a source whose
/// oriented render size is `orientedSize` (odd quarter turns swap the axes).
- (CGSize)rotatedSizeForOrientedSize:(CGSize)orientedSize;

/// The crop rectangle in pixels within the rotated frame. Origin and size are
/// snapped to even numbers — H.264 encoders reject odd dimensions.
- (CGRect)pixelRectForOrientedSize:(CGSize)orientedSize;

/// The FFmpeg `-vf` fragment ("transpose=1,hflip,scale,rotate,crop=w:h:x:y") for a source with
/// this oriented size, or nil when there is nothing to do.
- (nullable NSString *)ffmpegFilterForOrientedSize:(CGSize)orientedSize;

@end

NS_ASSUME_NONNULL_END
