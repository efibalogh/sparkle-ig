#import "SPKTrimScrubberView.h"
#import "../../Utils.h"

static CGFloat const kSPKTrimHandleWidth = 18.0;
static CGFloat const kSPKTrimBorderThickness = 3.0;
static CGFloat const kSPKTrimGrabThreshold = 36.0;
static NSInteger const kSPKTrimThumbnailCount = 16;
static CGFloat const kSPKTrimCornerRadius = 8.0;
// Zoomed track spans this many times the longest allowed clip, so the selection
// fills a comfortable share of the width with context on either side.
static CGFloat const kSPKTrimZoomSpanFactor = 3.0;

typedef NS_ENUM(NSInteger, SPKTrimDragTarget) {
    SPKTrimDragTargetNone = 0,
    SPKTrimDragTargetLeftHandle,
    SPKTrimDragTargetRightHandle,
    SPKTrimDragTargetPlayhead,
    SPKTrimDragTargetScroll,    // pans the visible window on a zoomed track
};

// Fine scrubbing, the way Apple's media scrubbers work: dragging away from the
// track vertically scales the horizontal movement down. Even zoomed, one point
// of track is a meaningful slice of a long clip, so full-rate dragging alone
// cannot land on a given moment.
static CGFloat SPKTrimFineScrubRate(CGFloat verticalDistance) {
    if (verticalDistance <= 40.0)
        return 1.0;
    if (verticalDistance <= 90.0)
        return 0.5;
    if (verticalDistance <= 150.0)
        return 0.25;
    return 0.1;
}

// Sampled finely enough that a zoomed-in track still has detail; drawing groups
// the samples into bars a few points wide.
static NSInteger const kSPKTrimWaveformSamples = 720;
static CGFloat const kSPKTrimWaveformBarStep = 4.0;

#pragma mark - Waveform view

// Draws a vertically-centered bar waveform from normalized (0..1) peak samples.
// Lives inside the track container in place of the filmstrip for audio trims.
@interface SPKTrimWaveformView : UIView
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *samples;
/// The slice of the clip on screen, as fractions of its length.
@property (nonatomic, assign) CGFloat visibleStartFraction;
@property (nonatomic, assign) CGFloat visibleSpanFraction;
@end

@implementation SPKTrimWaveformView

- (void)setSamples:(NSArray<NSNumber *> *)samples {
    _samples = [samples copy];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    NSArray<NSNumber *> *samples = self.samples;
    if (samples.count == 0)
        return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx)
        return;
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.92 alpha:1.0].CGColor);

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    NSInteger total = (NSInteger)samples.count;
    CGFloat spanFraction = self.visibleSpanFraction > 0.0 ? self.visibleSpanFraction : 1.0;
    CGFloat startFraction = MAX(0.0, MIN(self.visibleStartFraction, 1.0 - spanFraction));
    NSInteger n = MAX((NSInteger)1, (NSInteger)floor(w / kSPKTrimWaveformBarStep));
    CGFloat step = w / (CGFloat)n;
    CGFloat barW = MAX(1.0, step - 1.5);
    CGFloat maxBarH = MAX(2.0, h - 6.0);

    for (NSInteger i = 0; i < n; i++) {
        // Each bar shows the loudest sample in its slice of the visible window.
        CGFloat from = (startFraction + spanFraction * (CGFloat)i / (CGFloat)n) * (CGFloat)total;
        CGFloat to = (startFraction + spanFraction * (CGFloat)(i + 1) / (CGFloat)n) * (CGFloat)total;
        NSInteger first = MAX((NSInteger)0, MIN(total - 1, (NSInteger)floor(from)));
        NSInteger last = MAX(first, MIN(total - 1, (NSInteger)ceil(to) - 1));
        double peak = 0.0;
        for (NSInteger k = first; k <= last; k++) {
            peak = MAX(peak, samples[k].doubleValue);
        }
        CGFloat amp = MAX(0.0, MIN(1.0, peak));
        CGFloat barH = MAX(2.0, amp * maxBarH);
        CGFloat x = i * step + (step - barW) / 2.0;
        CGFloat y = (h - barH) / 2.0;
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, barW, barH)
                                                        cornerRadius:barW / 2.0];
        [path fill];
    }
}

@end

// Samples an asset's first audio track into `targetCount` normalized peak values
// on a background queue, delivering the result on the main queue (nil on
// failure). Peak-per-bucket keeps transients visible; the whole set is then
// normalized to the loudest bucket so quiet clips still fill the strip.
static void SPKTrimSampleWaveform(AVAsset *asset, NSInteger targetCount,
                                  void (^completion)(NSArray<NSNumber *> *_Nullable)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        void (^finish)(NSArray<NSNumber *> *) = ^(NSArray<NSNumber *> *result) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(result);
            });
        };

        AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (!track) {
            finish(nil);
            return;
        }

        NSError *error = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (!reader) {
            finish(nil);
            return;
        }

        NSDictionary *settings = @{
            AVFormatIDKey : @(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey : @16,
            AVLinearPCMIsBigEndianKey : @NO,
            AVLinearPCMIsFloatKey : @NO,
            AVLinearPCMIsNonInterleaved : @NO,
        };
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) {
            finish(nil);
            return;
        }
        [reader addOutput:output];
        if (![reader startReading]) {
            finish(nil);
            return;
        }

        // Estimate total interleaved int16 samples so we can bucket by position.
        double sampleRate = 44100.0;
        UInt32 channels = 1;
        CMFormatDescriptionRef fmt = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
        if (fmt) {
            const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
            if (asbd) {
                if (asbd->mSampleRate > 0)
                    sampleRate = asbd->mSampleRate;
                if (asbd->mChannelsPerFrame > 0)
                    channels = asbd->mChannelsPerFrame;
            }
        }
        double durationSeconds = CMTimeGetSeconds(asset.duration);
        if (!isfinite(durationSeconds) || durationSeconds <= 0)
            durationSeconds = CMTimeGetSeconds(track.timeRange.duration);
        int64_t estTotal = (int64_t)(MAX(0.0, durationSeconds) * sampleRate * channels);
        if (estTotal <= 0)
            estTotal = targetCount; // Avoid divide-by-zero; buckets clamp below.

        NSInteger count = MAX((NSInteger)1, targetCount);
        double *peaks = calloc((size_t)count, sizeof(double));
        if (!peaks) {
            finish(nil);
            return;
        }

        int64_t globalIndex = 0;
        double globalMax = 0.0;
        while (reader.status == AVAssetReaderStatusReading) {
            CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
            if (!sampleBuffer)
                break;
            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
            if (block) {
                size_t length = CMBlockBufferGetDataLength(block);
                size_t int16Count = length / sizeof(int16_t);
                if (int16Count > 0) {
                    int16_t *data = malloc(length);
                    if (data && CMBlockBufferCopyDataBytes(block, 0, length, data) == kCMBlockBufferNoErr) {
                        for (size_t s = 0; s < int16Count; s++) {
                            double amp = fabs((double)data[s]) / 32768.0;
                            NSInteger bucket = (NSInteger)((globalIndex * count) / estTotal);
                            if (bucket < 0)
                                bucket = 0;
                            if (bucket >= count)
                                bucket = count - 1;
                            if (amp > peaks[bucket])
                                peaks[bucket] = amp;
                            if (amp > globalMax)
                                globalMax = amp;
                            globalIndex++;
                        }
                    }
                    if (data)
                        free(data);
                }
            }
            CMSampleBufferInvalidate(sampleBuffer);
            CFRelease(sampleBuffer);
        }

        if (reader.status == AVAssetReaderStatusFailed || globalMax <= 0.0) {
            free(peaks);
            finish(nil);
            return;
        }

        NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
        for (NSInteger i = 0; i < count; i++) {
            // Slight gamma so mid-level detail is visible, then normalize.
            double norm = peaks[i] / globalMax;
            [result addObject:@(pow(norm, 0.8))];
        }
        free(peaks);
        finish(result);
    });
}

@interface SPKTrimScrubberView ()
@property (nonatomic, strong) UIView *filmstripContainer;
@property (nonatomic, strong) SPKTrimWaveformView *waveformView;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *thumbnailViews;
@property (nonatomic, strong) NSMutableArray<UIImage *> *thumbnailImages;

@property (nonatomic, strong) UIView *dimLeftView;
@property (nonatomic, strong) UIView *dimRightView;
@property (nonatomic, strong) UIView *selectionTopBorder;
@property (nonatomic, strong) UIView *selectionBottomBorder;
@property (nonatomic, strong) UIView *leftHandle;
@property (nonatomic, strong) UIView *rightHandle;
@property (nonatomic, strong) UIView *playheadView;
@property (nonatomic, strong) UIView *frameMarkerView;

@property (nonatomic, assign) NSTimeInterval startTime;
@property (nonatomic, assign) NSTimeInterval endTime;
@property (nonatomic, assign) SPKTrimDragTarget dragTarget;
@property (nonatomic, strong) AVAssetImageGenerator *imageGenerator;
@property (nonatomic, strong) AVAsset *thumbnailAsset; // kept so a scrolled window can regenerate
@property (nonatomic, assign) NSTimeInterval visibleStart;
@property (nonatomic, assign) NSTimeInterval visibleSpan; // 0 = whole asset
@property (nonatomic, assign) CGFloat scrollLastX;
// Drag bookkeeping. `dragAdjustedX` is the virtual finger position after fine
// scrubbing has scaled each movement, `dragOffsetTime` the grab point's distance
// from the thing being dragged (so it never snaps to the finger).
@property (nonatomic, assign) CGFloat dragLastX;
@property (nonatomic, assign) CGFloat dragAdjustedX;
@property (nonatomic, assign) CGFloat dragRate;
@property (nonatomic, assign) NSTimeInterval dragOffsetTime;
@property (nonatomic, assign) NSTimeInterval dragVisibleStart;
@property (nonatomic, strong) UISelectionFeedbackGenerator *rateFeedback;
// What a frame step moves: the last thing dragged.
@property (nonatomic, assign) SPKTrimDragTarget stepTarget;
// The exact time of the handle being moved, shown above it.
@property (nonatomic, strong) UIView *timeBubble;
@property (nonatomic, strong) UILabel *timeBubbleLabel;
@property (nonatomic, assign) NSTimeInterval pinchStartSpan;
@property (nonatomic, assign) NSTimeInterval pinchAnchorTime;
@property (nonatomic, assign) CGFloat pinchAnchorFraction;
@end

@implementation SPKTrimScrubberView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _minimumDuration = 0.3;
        _stepTarget = SPKTrimDragTargetPlayhead;
        _thumbnailViews = [NSMutableArray array];
        _thumbnailImages = [NSMutableArray array];
        [self setupViews];
        [self setupGestures];
    }
    return self;
}

- (void)setupViews {
    self.backgroundColor = [UIColor clearColor];
    self.clipsToBounds = NO;

    _filmstripContainer = [[UIView alloc] init];
    _filmstripContainer.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    _filmstripContainer.clipsToBounds = YES;
    _filmstripContainer.layer.cornerRadius = kSPKTrimCornerRadius;
    _filmstripContainer.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_filmstripContainer];

    // Waveform for audio trims; hidden until loadWaveformForAsset: switches modes.
    _waveformView = [[SPKTrimWaveformView alloc] init];
    _waveformView.backgroundColor = [UIColor clearColor];
    _waveformView.userInteractionEnabled = NO;
    _waveformView.hidden = YES;
    [_filmstripContainer addSubview:_waveformView];

    UIColor *dimColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    _dimLeftView = [[UIView alloc] init];
    _dimLeftView.backgroundColor = dimColor;
    _dimLeftView.userInteractionEnabled = NO;
    [self addSubview:_dimLeftView];

    _dimRightView = [[UIView alloc] init];
    _dimRightView.backgroundColor = dimColor;
    _dimRightView.userInteractionEnabled = NO;
    [self addSubview:_dimRightView];

    // Two-tone: white selection chrome over the darkened filmstrip, with dark
    // detail lines on the handles/marker. Avoids the blue accent except where IG
    // itself uses it.
    UIColor *accent = [UIColor whiteColor];

    _selectionTopBorder = [[UIView alloc] init];
    _selectionTopBorder.backgroundColor = accent;
    _selectionTopBorder.userInteractionEnabled = NO;
    [self addSubview:_selectionTopBorder];

    _selectionBottomBorder = [[UIView alloc] init];
    _selectionBottomBorder.backgroundColor = accent;
    _selectionBottomBorder.userInteractionEnabled = NO;
    [self addSubview:_selectionBottomBorder];

    _leftHandle = [self makeHandleWithAccent:accent];
    [self addSubview:_leftHandle];
    _rightHandle = [self makeHandleWithAccent:accent];
    [self addSubview:_rightHandle];

    _playheadView = [[UIView alloc] init];
    _playheadView.backgroundColor = [UIColor whiteColor];
    _playheadView.userInteractionEnabled = NO;
    _playheadView.layer.cornerRadius = 1.5;
    _playheadView.layer.shadowColor = [UIColor blackColor].CGColor;
    _playheadView.layer.shadowOpacity = 0.4;
    _playheadView.layer.shadowRadius = 2.0;
    _playheadView.layer.shadowOffset = CGSizeZero;
    [self addSubview:_playheadView];

    // Single-frame marker: a rounded pill with a vertical line. Hidden until
    // single-frame mode is enabled.
    _frameMarkerView = [[UIView alloc] init];
    _frameMarkerView.backgroundColor = accent;
    _frameMarkerView.userInteractionEnabled = NO;
    _frameMarkerView.layer.cornerRadius = 5.0;
    _frameMarkerView.hidden = YES;
    UIView *markerLine = [[UIView alloc] init];
    markerLine.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
    markerLine.tag = 7001;
    [_frameMarkerView addSubview:markerLine];
    [self addSubview:_frameMarkerView];

    _timeBubble = [[UIView alloc] init];
    _timeBubble.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    _timeBubble.layer.cornerCurve = kCACornerCurveContinuous;
    _timeBubble.userInteractionEnabled = NO;
    _timeBubble.alpha = 0.0;
    _timeBubbleLabel = [[UILabel alloc] init];
    _timeBubbleLabel.textColor = [UIColor whiteColor];
    _timeBubbleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
    _timeBubbleLabel.textAlignment = NSTextAlignmentCenter;
    [_timeBubble addSubview:_timeBubbleLabel];
    [self addSubview:_timeBubble];
}

- (UIView *)makeHandleWithAccent:(UIColor *)accent {
    UIView *handle = [[UIView alloc] init];
    handle.backgroundColor = accent;
    handle.layer.cornerRadius = kSPKTrimCornerRadius;
    handle.layer.cornerCurve = kCACornerCurveContinuous;
    // A short dark grip line centered in the (white) handle.
    UIView *grip = [[UIView alloc] init];
    grip.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
    grip.layer.cornerRadius = 1.0;
    grip.tag = 7002;
    [handle addSubview:grip];
    return handle;
}

- (void)setupGestures {
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    // Two fingers belong to the pinch.
    pan.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:pan];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    [self addGestureRecognizer:pinch];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [self addGestureRecognizer:tap];
}

#pragma mark - Public

- (void)setDuration:(NSTimeInterval)duration {
    _duration = MAX(duration, 0.0);
    if (_endTime <= 0.0 || _endTime > _duration) {
        _startTime = 0.0;
        _endTime = _duration;
    }
    [self updateVisibleWindow];
    [self setNeedsLayout];
}

- (void)setMaximumDuration:(NSTimeInterval)maximumDuration {
    _maximumDuration = MAX(0.0, maximumDuration);
    [self updateVisibleWindow];
    [self setNeedsLayout];
}

- (void)setStartTime:(NSTimeInterval)start endTime:(NSTimeInterval)end {
    _startTime = MAX(0.0, MIN(start, _duration));
    _endTime = MAX(_startTime, MIN(end, _duration));
    [self scrollVisibleWindowToTime:_startTime centered:NO];
    [self setNeedsLayout];
}

- (NSTimeInterval)frameTime {
    return _playheadTime;
}

- (void)setPlayheadTime:(NSTimeInterval)playheadTime {
    _playheadTime = MAX(0.0, MIN(playheadTime, _duration));
    [self layoutPlayhead];
}

- (void)setFrameOnlyMode:(BOOL)frameOnlyMode {
    if (_frameOnlyMode == frameOnlyMode)
        return;
    _frameOnlyMode = frameOnlyMode;
    if (frameOnlyMode) {
        // Snap the frame marker into the current selection if outside it.
        if (_playheadTime < _startTime || _playheadTime > _endTime) {
            _playheadTime = _startTime;
        }
    }
    [self updateControlVisibility];
    [self setNeedsLayout];
}

- (void)updateControlVisibility {
    BOOL frameOnly = _frameOnlyMode;
    _dimLeftView.hidden = frameOnly;
    _dimRightView.hidden = frameOnly;
    _selectionTopBorder.hidden = frameOnly;
    _selectionBottomBorder.hidden = frameOnly;
    _leftHandle.hidden = frameOnly;
    _rightHandle.hidden = frameOnly;
    _playheadView.hidden = frameOnly;
    _frameMarkerView.hidden = !frameOnly;
}

#pragma mark - Waveform

- (void)setWaveformMode:(BOOL)waveformMode {
    if (_waveformMode == waveformMode)
        return;
    _waveformMode = waveformMode;
    _waveformView.hidden = !waveformMode;
    for (UIImageView *iv in self.thumbnailViews) {
        iv.hidden = waveformMode;
    }
    [self setNeedsLayout];
}

- (void)loadWaveformForAsset:(AVAsset *)asset {
    if (!asset)
        return;
    self.waveformMode = YES;
    __weak typeof(self) weakSelf = self;
    SPKTrimSampleWaveform(asset, kSPKTrimWaveformSamples, ^(NSArray<NSNumber *> *samples) {
        weakSelf.waveformView.samples = samples;
    });
}

#pragma mark - Thumbnails

- (void)loadThumbnailsForAsset:(AVAsset *)asset {
    self.thumbnailAsset = asset;
    [self reloadThumbnailsForVisibleWindow];
}

/// Regenerates the filmstrip for whatever slice of the timeline is on screen.
/// On an unzoomed track that is the whole asset, exactly as before.
- (void)reloadThumbnailsForVisibleWindow {
    AVAsset *asset = self.thumbnailAsset;
    if (!asset)
        return;
    [self.imageGenerator cancelAllCGImageGeneration];
    [self.thumbnailImages removeAllObjects];

    AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.requestedTimeToleranceBefore = kCMTimePositiveInfinity;
    generator.requestedTimeToleranceAfter = kCMTimePositiveInfinity;
    CGFloat scale = UIScreen.mainScreen.scale;
    generator.maximumSize = CGSizeMake(120.0 * scale, 120.0 * scale);
    self.imageGenerator = generator;

    CMTime assetDuration = asset.duration;
    NSTimeInterval total = CMTimeGetSeconds(assetDuration);
    if (total <= 0.0 || !isfinite(total))
        return;

    // Thumbnails span the visible window, not the whole asset.
    NSTimeInterval windowStart = _visibleStart;
    NSTimeInterval windowSpan = [self visibleSpan];
    if (windowSpan <= 0.0)
        windowSpan = total;

    NSMutableArray<NSValue *> *times = [NSMutableArray array];
    for (NSInteger i = 0; i < kSPKTrimThumbnailCount; i++) {
        NSTimeInterval t = windowStart + (windowSpan * (i + 0.5)) / kSPKTrimThumbnailCount;
        [times addObject:[NSValue valueWithCMTime:CMTimeMakeWithSeconds(t, 600)]];
        [self.thumbnailImages addObject:(id)[NSNull null]];
    }

    __weak typeof(self) weakSelf = self;
    [generator generateCGImagesAsynchronouslyForTimes:times
                                    completionHandler:^(CMTime requestedTime, CGImageRef _Nullable image,
                                                        CMTime actualTime, AVAssetImageGeneratorResult result,
                                                        NSError *_Nullable error) {
                                        if (result != AVAssetImageGeneratorSucceeded || !image)
                                            return;
                                        // Derive the slot from the requested time — the generator does not
                                        // guarantee completion order, so we can't rely on a running counter.
                                        NSTimeInterval requested = CMTimeGetSeconds(requestedTime);
                                        NSInteger slot = (NSInteger)floor(((requested - windowStart) * kSPKTrimThumbnailCount) / windowSpan);
                                        slot = MAX(0, MIN(slot, kSPKTrimThumbnailCount - 1));
                                        UIImage *uiImage = [UIImage imageWithCGImage:image];
                                        dispatch_async(dispatch_get_main_queue(), ^{
                                            __strong typeof(weakSelf) strongSelf = weakSelf;
                                            if (!strongSelf || slot >= strongSelf.thumbnailImages.count)
                                                return;
                                            strongSelf.thumbnailImages[slot] = uiImage;
                                            [strongSelf applyThumbnailImageAtSlot:slot image:uiImage];
                                        });
                                    }];
}

- (void)applyThumbnailImageAtSlot:(NSInteger)slot image:(UIImage *)image {
    if (slot < self.thumbnailViews.count) {
        UIImageView *iv = self.thumbnailViews[slot];
        iv.image = image;
        iv.alpha = 0.0;
        [UIView animateWithDuration:0.2
                         animations:^{
                             iv.alpha = 1.0;
                         }];
    }
}

- (void)ensureThumbnailViews {
    NSInteger count = self.thumbnailImages.count > 0 ? self.thumbnailImages.count : 0;
    while (self.thumbnailViews.count < count) {
        UIImageView *iv = [[UIImageView alloc] init];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.userInteractionEnabled = NO;
        id existing = self.thumbnailImages[self.thumbnailViews.count];
        if ([existing isKindOfClass:[UIImage class]]) {
            iv.image = existing;
        }
        [self.filmstripContainer addSubview:iv];
        [self.thumbnailViews addObject:iv];
    }
}

#pragma mark - Layout

// The filmstrip is inset by one handle-width on each side so the drag handles
// live in the side gutters (outside the video frames), not overlapping them.
// All time<->x math runs through this content rect, so the playhead stays within
// the selection and never merges with a handle's edge.
- (CGFloat)contentOriginX {
    return kSPKTrimHandleWidth;
}

- (CGFloat)contentWidth {
    return MAX(0.0, self.bounds.size.width - 2.0 * kSPKTrimHandleWidth);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    _filmstripContainer.frame = CGRectMake([self contentOriginX], 0, [self contentWidth], h);

    if (_waveformMode) {
        // Fills the track container's local space (0..contentWidth).
        _waveformView.frame = _filmstripContainer.bounds;
        [self updateWaveformWindow];
    } else {
        [self ensureThumbnailViews];
        NSInteger count = self.thumbnailViews.count;
        if (count > 0) {
            // Thumbnails are children of the filmstrip container, so they lay out
            // in its local space (0..contentWidth).
            CGFloat slotWidth = [self contentWidth] / count;
            for (NSInteger i = 0; i < count; i++) {
                self.thumbnailViews[i].frame = CGRectMake(floor(i * slotWidth), 0,
                                                          ceil(slotWidth) + 1.0, h);
            }
        }
    }

    [self layoutSelection];
    [self layoutPlayhead];
}

#pragma mark - Visible window

- (void)updateWaveformWindow {
    if (!_waveformMode || _duration <= 0.0)
        return;
    CGFloat start = (CGFloat)(_visibleStart / _duration);
    CGFloat span = (CGFloat)([self visibleSpan] / _duration);
    if (fabs(start - _waveformView.visibleStartFraction) > 0.0001 ||
        fabs(span - _waveformView.visibleSpanFraction) > 0.0001) {
        _waveformView.visibleStartFraction = start;
        _waveformView.visibleSpanFraction = span;
        [_waveformView setNeedsDisplay];
    }
}

// On a long source with a short ceiling (a 6s Instant cut from a 5 minute clip)
// the selection is a couple of percent of the track and impossible to place. The
// track then shows a zoomed window of the timeline that the user pans, instead of
// the whole asset squeezed into one screen width.

/// Seconds currently spanned by the track.
- (NSTimeInterval)visibleSpan {
    return (_visibleSpan > 0.0 && _visibleSpan < _duration) ? _visibleSpan : _duration;
}

- (BOOL)isZoomed {
    return [self visibleSpan] < _duration - 0.001;
}

/// Picks the zoom level: show a few times the longest allowed clip, so the
/// selection is a comfortable fraction of the track with context either side.
- (void)updateVisibleWindow {
    NSTimeInterval span = 0.0;
    if (_maximumDuration > 0.0 && _duration > _maximumDuration * kSPKTrimZoomSpanFactor) {
        span = _maximumDuration * kSPKTrimZoomSpanFactor;
    }
    if (fabs(span - _visibleSpan) > 0.001) {
        _visibleSpan = span;
        [self scrollVisibleWindowToTime:_startTime centered:NO];
        [self reloadThumbnailsForVisibleWindow];
    }
    [self clampVisibleStart];
}

- (void)clampVisibleStart {
    NSTimeInterval span = [self visibleSpan];
    _visibleStart = MAX(0.0, MIN(_visibleStart, _duration - span));
}

/// Keeps `time` on screen, scrolling only as far as needed (or centring it).
- (void)scrollVisibleWindowToTime:(NSTimeInterval)time centered:(BOOL)centered {
    if (![self isZoomed])
        return;
    NSTimeInterval span = [self visibleSpan];
    if (centered) {
        _visibleStart = time - span / 2.0;
    } else {
        NSTimeInterval margin = span * 0.1;
        if (time < _visibleStart + margin) {
            _visibleStart = time - margin;
        } else if (time > _visibleStart + span - margin) {
            _visibleStart = time - span + margin;
        }
    }
    [self clampVisibleStart];
}

- (CGFloat)xForTime:(NSTimeInterval)t {
    NSTimeInterval span = [self visibleSpan];
    if (span <= 0.0)
        return [self contentOriginX];
    return [self contentOriginX] + ((t - _visibleStart) / span) * [self contentWidth];
}

- (NSTimeInterval)timeForX:(CGFloat)x {
    CGFloat w = [self contentWidth];
    if (w <= 0.0)
        return 0.0;
    CGFloat clamped = MAX(0.0, MIN(x - [self contentOriginX], w));
    NSTimeInterval t = _visibleStart + (clamped / w) * [self visibleSpan];
    return MAX(0.0, MIN(t, _duration));
}

- (void)layoutSelection {
    CGFloat h = self.bounds.size.height;
    CGFloat startX = [self xForTime:_startTime];
    CGFloat endX = [self xForTime:_endTime];
    CGFloat contentLeft = [self contentOriginX];
    CGFloat contentRight = contentLeft + [self contentWidth];

    // Dim only the trimmed-away parts of the filmstrip (between the content edge
    // and the selection), never the gutters.
    _dimLeftView.frame = CGRectMake(contentLeft, 0, MAX(0, startX - contentLeft), h);
    _dimRightView.frame = CGRectMake(endX, 0, MAX(0, contentRight - endX), h);

    _selectionTopBorder.frame = CGRectMake(startX, 0, MAX(0, endX - startX), kSPKTrimBorderThickness);
    _selectionBottomBorder.frame = CGRectMake(startX, h - kSPKTrimBorderThickness, MAX(0, endX - startX), kSPKTrimBorderThickness);

    // Handles sit just outside the selection, in the gutters at full extent.
    _leftHandle.frame = CGRectMake(startX - kSPKTrimHandleWidth, 0, kSPKTrimHandleWidth, h);
    _rightHandle.frame = CGRectMake(endX, 0, kSPKTrimHandleWidth, h);

    [self layoutGripInHandle:_leftHandle];
    [self layoutGripInHandle:_rightHandle];
}

- (void)layoutGripInHandle:(UIView *)handle {
    UIView *grip = [handle viewWithTag:7002];
    CGFloat gripH = handle.bounds.size.height * 0.34;
    grip.frame = CGRectMake((handle.bounds.size.width - 2.0) / 2.0,
                            (handle.bounds.size.height - gripH) / 2.0, 2.0, gripH);
}

- (void)layoutPlayhead {
    CGFloat h = self.bounds.size.height;
    if (_frameOnlyMode) {
        CGFloat x = [self xForTime:_playheadTime];
        CGFloat markerW = 12.0;
        _frameMarkerView.frame = CGRectMake(x - markerW / 2.0, -3.0, markerW, h + 6.0);
        UIView *line = [_frameMarkerView viewWithTag:7001];
        line.frame = CGRectMake((markerW - 2.0) / 2.0, 6.0, 2.0, h - 6.0);
        return;
    }
    CGFloat x = [self xForTime:_playheadTime];
    _playheadView.frame = CGRectMake(x - 1.0, -2.0, 2.0, h + 4.0);
}

#pragma mark - Gestures

- (void)handleTap:(UITapGestureRecognizer *)tap {
    CGPoint p = [tap locationInView:self];
    NSTimeInterval t = [self timeForX:p.x];
    if (!_frameOnlyMode) {
        t = MAX(_startTime, MIN(t, _endTime));
    }
    self.playheadTime = t;
    _stepTarget = SPKTrimDragTargetPlayhead;
    if ([self.delegate respondsToSelector:@selector(trimScrubber:didScrubToTime:)]) {
        [self.delegate trimScrubber:self didScrubToTime:t];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint p = [pan locationInView:self];

    if (pan.state == UIGestureRecognizerStateBegan) {
        _dragTarget = [self dragTargetForPoint:p];
        _dragLastX = p.x;
        _dragAdjustedX = p.x;
        _dragRate = 1.0;
        _dragOffsetTime = [self grabOffsetTimeForPoint:p];
        _dragVisibleStart = _visibleStart;
        _scrollLastX = p.x;
        if (!_rateFeedback) {
            _rateFeedback = [[UISelectionFeedbackGenerator alloc] init];
        }
        [_rateFeedback prepare];
        if ([self.delegate respondsToSelector:@selector(trimScrubberDidBeginInteraction:)]) {
            [self.delegate trimScrubberDidBeginInteraction:self];
        }
    }

    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        [self updateAdjustedPositionForPoint:p];
        [self applyDrag];
        if (_dragTarget == SPKTrimDragTargetLeftHandle || _dragTarget == SPKTrimDragTargetRightHandle ||
            _dragTarget == SPKTrimDragTargetPlayhead) {
            _stepTarget = _dragTarget;
            [self showTimeBubbleForTarget:_dragTarget];
        }
    }

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {
        // Regenerating mid-drag would thrash the generator, so the filmstrip
        // catches up with the new window once the finger lifts.
        if (fabs(_visibleStart - _dragVisibleStart) > 0.001) {
            [self reloadThumbnailsForVisibleWindow];
        }
        _dragTarget = SPKTrimDragTargetNone;
        [self scheduleTimeBubbleHide];
        if ([self.delegate respondsToSelector:@selector(trimScrubberDidEndInteraction:)]) {
            [self.delegate trimScrubberDidEndInteraction:self];
        }
    }
}

- (SPKTrimDragTarget)dragTargetForPoint:(CGPoint)p {
    if (_frameOnlyMode) {
        return SPKTrimDragTargetPlayhead;
    }
    CGFloat startX = [self xForTime:_startTime];
    CGFloat endX = [self xForTime:_endTime];
    CGFloat distLeft = fabs(p.x - startX);
    CGFloat distRight = fabs(p.x - endX);

    if (distLeft <= kSPKTrimGrabThreshold || distRight <= kSPKTrimGrabThreshold) {
        return (distLeft <= distRight) ? SPKTrimDragTargetLeftHandle : SPKTrimDragTargetRightHandle;
    }
    if (p.x > startX && p.x < endX) {
        // Inside the selection a drag scrubs: the playhead jumps to the finger
        // and follows it. (Under a duration ceiling the selection still moves
        // along the clip, by dragging a handle: the other one follows.)
        return SPKTrimDragTargetPlayhead;
    }
    // Outside the selection on a zoomed track, dragging pans the timeline: the
    // rest of the clip is off screen and reaching it matters more than extending
    // a selection that is already at its ceiling.
    if ([self isZoomed]) {
        return SPKTrimDragTargetScroll;
    }
    // Outside selection: grab the nearer handle so it extends toward the touch.
    return (p.x <= startX) ? SPKTrimDragTargetLeftHandle : SPKTrimDragTargetRightHandle;
}

/// Distance the grabbed thing sits from the touch, so it stays under the finger
/// rather than jumping to it. Zero when the touch is not on the thing already
/// (grabbing outside the selection is meant to pull a handle over to the touch).
- (NSTimeInterval)grabOffsetTimeForPoint:(CGPoint)p {
    NSTimeInterval t = [self timeForX:p.x];
    switch (_dragTarget) {
    case SPKTrimDragTargetLeftHandle:
        return (fabs(p.x - [self xForTime:_startTime]) <= kSPKTrimGrabThreshold) ? t - _startTime : 0.0;
    case SPKTrimDragTargetRightHandle:
        return (fabs(p.x - [self xForTime:_endTime]) <= kSPKTrimGrabThreshold) ? t - _endTime : 0.0;
    default:
        return 0.0;
    }
}

/// Advances the virtual finger by this event's movement, scaled by how far the
/// touch has strayed above or below the track. A rate change ticks the selection
/// haptic, which is the only cue that the slowdown happened.
- (void)updateAdjustedPositionForPoint:(CGPoint)p {
    CGFloat distance = 0.0;
    if (p.y < 0.0) {
        distance = -p.y;
    } else if (p.y > self.bounds.size.height) {
        distance = p.y - self.bounds.size.height;
    }
    CGFloat rate = SPKTrimFineScrubRate(distance);
    if (fabs(rate - _dragRate) > 0.001) {
        _dragRate = rate;
        [_rateFeedback selectionChanged];
        [_rateFeedback prepare];
    }
    _dragAdjustedX += (p.x - _dragLastX) * rate;
    _dragLastX = p.x;
    // Panning must keep accumulating past the edges; everything else stays
    // pinned to the track so no invisible slack builds up when reversing.
    if (_dragTarget != SPKTrimDragTargetScroll) {
        CGFloat left = [self contentOriginX];
        _dragAdjustedX = MAX(left, MIN(_dragAdjustedX, left + [self contentWidth]));
    }
}

- (void)applyDrag {
    NSTimeInterval t = [self timeForX:_dragAdjustedX] - _dragOffsetTime;
    // The grab offset can push the result past the edge of a zoomed track (by up
    // to the selection's own width), which would drag the selection off screen.
    // Panning is how you reach the rest of the clip.
    if ([self isZoomed]) {
        t = MAX(_visibleStart, MIN(t, _visibleStart + [self visibleSpan]));
    }
    switch (_dragTarget) {
    case SPKTrimDragTargetLeftHandle: {
        NSTimeInterval maxStart = MAX(0.0, _endTime - _minimumDuration);
        _startTime = MAX(0.0, MIN(t, maxStart));
        // Under a duration ceiling the out point follows the in point, so the
        // selection slides at its maximum width instead of refusing to move.
        if (_maximumDuration > 0.0 && (_endTime - _startTime) > _maximumDuration) {
            _endTime = MIN(_duration, _startTime + _maximumDuration);
            if ([self.delegate respondsToSelector:@selector(trimScrubber:didChangeEndTime:)]) {
                [self.delegate trimScrubber:self didChangeEndTime:_endTime];
            }
        }
        _playheadTime = _startTime;
        [self layoutSelection];
        [self layoutPlayhead];
        if ([self.delegate respondsToSelector:@selector(trimScrubber:didChangeStartTime:)]) {
            [self.delegate trimScrubber:self didChangeStartTime:_startTime];
        }
        break;
    }
    case SPKTrimDragTargetRightHandle: {
        NSTimeInterval minEnd = MIN(_duration, _startTime + _minimumDuration);
        _endTime = MIN(_duration, MAX(t, minEnd));
        if (_maximumDuration > 0.0 && (_endTime - _startTime) > _maximumDuration) {
            _startTime = MAX(0.0, _endTime - _maximumDuration);
            if ([self.delegate respondsToSelector:@selector(trimScrubber:didChangeStartTime:)]) {
                [self.delegate trimScrubber:self didChangeStartTime:_startTime];
            }
        }
        _playheadTime = _endTime;
        [self layoutSelection];
        [self layoutPlayhead];
        if ([self.delegate respondsToSelector:@selector(trimScrubber:didChangeEndTime:)]) {
            [self.delegate trimScrubber:self didChangeEndTime:_endTime];
        }
        break;
    }
    case SPKTrimDragTargetPlayhead: {
        if (!_frameOnlyMode) {
            t = MAX(_startTime, MIN(t, _endTime));
        }
        self.playheadTime = t;
        if ([self.delegate respondsToSelector:@selector(trimScrubber:didScrubToTime:)]) {
            [self.delegate trimScrubber:self didScrubToTime:t];
        }
        break;
    }
    case SPKTrimDragTargetScroll: {
        CGFloat w = [self contentWidth];
        if (w <= 0.0)
            break;
        // Drag right moves the timeline right, i.e. earlier content into view.
        NSTimeInterval delta = ((_dragAdjustedX - _scrollLastX) / w) * [self visibleSpan];
        _scrollLastX = _dragAdjustedX;
        _visibleStart -= delta;
        [self clampVisibleStart];
        [self setNeedsLayout];
        [self layoutSelection];
        [self layoutPlayhead];
        break;
    }
    case SPKTrimDragTargetNone:
        break;
    }
}

#pragma mark - Time bubble

static NSString *SPKTrimBubbleTime(NSTimeInterval seconds) {
    if (seconds < 0.0 || !isfinite(seconds))
        seconds = 0.0;
    NSInteger tenths = (NSInteger)llround(seconds * 10.0);
    return [NSString stringWithFormat:@"%ld:%02ld.%ld", (long)(tenths / 600), (long)((tenths / 10) % 60), (long)(tenths % 10)];
}

/// Shows the exact time of `target` above it while it moves.
- (void)showTimeBubbleForTarget:(SPKTrimDragTarget)target {
    NSTimeInterval t;
    switch (target) {
    case SPKTrimDragTargetLeftHandle:
        t = _startTime;
        break;
    case SPKTrimDragTargetRightHandle:
        t = _endTime;
        break;
    case SPKTrimDragTargetPlayhead:
        t = _playheadTime;
        break;
    default:
        return;
    }
    _timeBubbleLabel.text = SPKTrimBubbleTime(t);
    CGSize textSize = [_timeBubbleLabel sizeThatFits:CGSizeMake(200.0, 30.0)];
    CGFloat w = ceil(textSize.width) + 16.0;
    CGFloat h = 22.0;
    CGFloat x = [self xForTime:t];
    // The handles sit outside the selection, so their bubbles centre on the
    // handle itself rather than on the selection edge.
    if (target == SPKTrimDragTargetLeftHandle)
        x -= kSPKTrimHandleWidth / 2.0;
    else if (target == SPKTrimDragTargetRightHandle)
        x += kSPKTrimHandleWidth / 2.0;
    x = MAX(w / 2.0, MIN(x, self.bounds.size.width - w / 2.0));
    _timeBubble.frame = CGRectMake(round(x - w / 2.0), -h - 8.0, w, h);
    _timeBubble.layer.cornerRadius = h / 2.0;
    _timeBubbleLabel.frame = _timeBubble.bounds;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideTimeBubble) object:nil];
    if (_timeBubble.alpha < 1.0) {
        [UIView animateWithDuration:0.12
                         animations:^{
                             self.timeBubble.alpha = 1.0;
                         }];
    }
}

- (void)scheduleTimeBubbleHide {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideTimeBubble) object:nil];
    [self performSelector:@selector(hideTimeBubble) withObject:nil afterDelay:0.9];
}

- (void)hideTimeBubble {
    [UIView animateWithDuration:0.25
                     animations:^{
                         self.timeBubble.alpha = 0.0;
                     }];
}

#pragma mark - Frame step

- (void)stepActiveTargetBy:(NSTimeInterval)delta {
    if (_duration <= 0.0)
        return;
    NSTimeInterval previousVisibleStart = _visibleStart;
    SPKTrimDragTarget target = _frameOnlyMode ? SPKTrimDragTargetPlayhead : _stepTarget;
    switch (target) {
    case SPKTrimDragTargetLeftHandle: {
        NSTimeInterval maxStart = MAX(0.0, _endTime - _minimumDuration);
        _startTime = MAX(0.0, MIN(_startTime + delta, maxStart));
        if (_maximumDuration > 0.0 && (_endTime - _startTime) > _maximumDuration) {
            _endTime = MIN(_duration, _startTime + _maximumDuration);
            if ([self.delegate respondsToSelector:@selector(trimScrubber:didChangeEndTime:)])
                [self.delegate trimScrubber:self didChangeEndTime:_endTime];
        }
        _playheadTime = _startTime;
        [self scrollVisibleWindowToTime:_startTime centered:NO];
        if ([self.delegate respondsToSelector:@selector(trimScrubber:didChangeStartTime:)])
            [self.delegate trimScrubber:self didChangeStartTime:_startTime];
        break;
    }
    case SPKTrimDragTargetRightHandle: {
        NSTimeInterval minEnd = MIN(_duration, _startTime + _minimumDuration);
        _endTime = MIN(_duration, MAX(_endTime + delta, minEnd));
        if (_maximumDuration > 0.0 && (_endTime - _startTime) > _maximumDuration) {
            _startTime = MAX(0.0, _endTime - _maximumDuration);
            if ([self.delegate respondsToSelector:@selector(trimScrubber:didChangeStartTime:)])
                [self.delegate trimScrubber:self didChangeStartTime:_startTime];
        }
        _playheadTime = _endTime;
        [self scrollVisibleWindowToTime:_endTime centered:NO];
        if ([self.delegate respondsToSelector:@selector(trimScrubber:didChangeEndTime:)])
            [self.delegate trimScrubber:self didChangeEndTime:_endTime];
        break;
    }
    default: {
        NSTimeInterval t = _playheadTime + delta;
        t = _frameOnlyMode ? MAX(0.0, MIN(t, _duration)) : MAX(_startTime, MIN(t, _endTime));
        _playheadTime = t;
        [self scrollVisibleWindowToTime:t centered:NO];
        if ([self.delegate respondsToSelector:@selector(trimScrubber:didScrubToTime:)])
            [self.delegate trimScrubber:self didScrubToTime:t];
        target = SPKTrimDragTargetPlayhead;
        break;
    }
    }
    [self setNeedsLayout];
    [self layoutIfNeeded];
    if (fabs(_visibleStart - previousVisibleStart) > 0.001)
        [self reloadThumbnailsForVisibleWindow];
    [self showTimeBubbleForTarget:target];
    [self scheduleTimeBubbleHide];
}

#pragma mark - Pinch zoom

/// The closest the track zooms in: a second of clip across the whole width, or
/// less for clips that are themselves very short.
- (NSTimeInterval)minimumVisibleSpan {
    return MIN(_duration, MAX(1.0, _minimumDuration * 2.0));
}

- (void)handlePinch:(UIPinchGestureRecognizer *)pinch {
    if (_duration <= 0.0)
        return;
    CGFloat width = [self contentWidth];
    if (width <= 0.0)
        return;
    switch (pinch.state) {
    case UIGestureRecognizerStateBegan: {
        _pinchStartSpan = [self visibleSpan];
        CGFloat x = [pinch locationInView:self].x;
        _pinchAnchorFraction = MAX(0.0, MIN(1.0, (x - [self contentOriginX]) / width));
        _pinchAnchorTime = _visibleStart + _pinchAnchorFraction * _pinchStartSpan;
        if ([self.delegate respondsToSelector:@selector(trimScrubberDidBeginInteraction:)])
            [self.delegate trimScrubberDidBeginInteraction:self];
        break;
    }
    case UIGestureRecognizerStateChanged: {
        NSTimeInterval span = _pinchStartSpan / MAX(pinch.scale, 0.01);
        span = MAX([self minimumVisibleSpan], MIN(span, _duration));
        // A whole-clip span is stored as 0, which the window treats as unzoomed.
        _visibleSpan = (span >= _duration - 0.001) ? 0.0 : span;
        // Keep the moment under the fingers where it was.
        _visibleStart = _pinchAnchorTime - _pinchAnchorFraction * [self visibleSpan];
        [self clampVisibleStart];
        [self setNeedsLayout];
        [self layoutIfNeeded];
        break;
    }
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        [self reloadThumbnailsForVisibleWindow];
        if ([self.delegate respondsToSelector:@selector(trimScrubberDidEndInteraction:)])
            [self.delegate trimScrubberDidEndInteraction:self];
        break;
    default:
        break;
    }
}

@end
