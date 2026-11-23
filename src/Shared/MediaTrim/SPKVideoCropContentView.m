#import "SPKVideoCropContentView.h"
#import "SPKTrimCrop.h"

@implementation SPKVideoCropContentView

- (instancetype)initWithPlayer:(AVPlayer *)player orientedSize:(CGSize)orientedSize {
    self = [super initWithFrame:CGRectMake(0.0, 0.0, orientedSize.width, orientedSize.height)];
    if (self) {
        _orientedSize = orientedSize;
        self.backgroundColor = [UIColor blackColor];
        self.clipsToBounds = YES;
        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
        // This view is always given the picture's exact (rotated) aspect, so the
        // video fills it edge to edge with no letterboxing to reason about.
        _playerLayer.videoGravity = AVLayerVideoGravityResize;
        [self.layer addSublayer:_playerLayer];
    }
    return self;
}

- (CGSize)rotatedSize {
    if (self.rotationQuarters % 2 == 1)
        return CGSizeMake(_orientedSize.height, _orientedSize.width);
    return _orientedSize;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_orientedSize.width <= 0.0 || _orientedSize.height <= 0.0)
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // Derive the scale from our own bounds: the crop canvas zooms us by a
    // transform (scale 1), while the trim preview sizes us outright.
    CGSize rotated = [self rotatedSize];
    CGFloat scale = rotated.width > 0.0 ? (self.bounds.size.width / rotated.width) : 1.0;
    _playerLayer.bounds = CGRectMake(0.0, 0.0, _orientedSize.width * scale, _orientedSize.height * scale);
    _playerLayer.position = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));

    CGAffineTransform t = CGAffineTransformMakeRotation((CGFloat)self.rotationQuarters * (CGFloat)M_PI_2);
    if (self.mirrored) {
        t = CGAffineTransformConcat(t, CGAffineTransformMakeScale(-1.0, 1.0));
    }
    if (fabs(self.straightenDegrees) >= SPKTrimCropStraightenEpsilon) {
        CGFloat cover = SPKTrimCropStraightenCoverScale(rotated, self.straightenDegrees);
        t = CGAffineTransformConcat(t, CGAffineTransformMakeRotation(self.straightenDegrees * (CGFloat)M_PI / 180.0));
        t = CGAffineTransformConcat(t, CGAffineTransformMakeScale(cover, cover));
    }
    _playerLayer.affineTransform = t;
    [CATransaction commit];
}

- (void)setRotationQuarters:(NSInteger)rotationQuarters {
    _rotationQuarters = ((rotationQuarters % 4) + 4) % 4;
    [self setNeedsLayout];
}

- (void)setStraightenDegrees:(CGFloat)straightenDegrees {
    _straightenDegrees = straightenDegrees;
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (void)setMirrored:(BOOL)mirrored {
    _mirrored = mirrored;
    [self setNeedsLayout];
}

@end
