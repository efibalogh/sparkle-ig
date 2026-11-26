#import "SPKCropControlsView.h"
#import "SPKCropCanvasView.h"
#import "SPKStrings.h"

#import "../UI/SPKMediaChrome.h"

// The ruler's height; the chips are centred in the same slot.
static const CGFloat kSPKCropControlsHeight = 44.0;
// How far a panel travels as it fades in or out.
static const CGFloat kSPKCropControlsSlide = 8.0;

// Instagram's size glyph (a double arrow between two bars) turned a quarter
// counter-clockwise, so the arrow runs level between two uprights: a level line.
static UIImage *SPKCropControlsStraightenIcon(void) {
    UIImage *source = SPKMediaChromeBottomBarIcon(@"ig_icon_size_info_outline_24");
    if (!source || source.size.width <= 0.0 || source.size.height <= 0.0)
        return source;
    CGSize size = CGSizeMake(source.size.height, source.size.width);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIImage *turned = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        CGContextTranslateCTM(ctx, size.width / 2.0, size.height / 2.0);
        CGContextRotateCTM(ctx, -M_PI_2);
        [source drawInRect:CGRectMake(-source.size.width / 2.0, -source.size.height / 2.0, source.size.width, source.size.height)];
    }];
    return [turned imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] ?: source;
}

// Swaps the switch's glyph. Instagram's glyphs are bitmaps, so there is no
// symbol effect to morph them; the panel below carries the transition.
static void SPKCropControlsSetItemImage(UIBarButtonItem *item, UIImage *image) {
    if (item && image)
        item.image = image;
}

@implementation SPKCropControlsView {
    UIImage *_aspectIcon;
    UIImage *_straightenIcon;
}

- (instancetype)initWithAspectChips:(BOOL)showsAspectChips {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _ruler = [[SPKStraightenRulerView alloc] init];
        _ruler.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_ruler];
        [NSLayoutConstraint activateConstraints:@[
            [_ruler.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_ruler.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_ruler.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_ruler.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];

        if (showsAspectChips) {
            _aspectChips = [[SPKChipBar alloc] init];
            _aspectChips.translatesAutoresizingMaskIntoConstraints = NO;
            // Content-sized (scrolling) rather than fill-equally: the fill-equally
            // mode shrinks the wider "Original" chip's font to fit its share,
            // leaving the shorter chips at full size.
            _aspectChips.distributesToFit = NO;
            NSInteger count = SPKCropAspectPresetCount();
            NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
            for (NSInteger i = 0; i < count; i++) {
                [titles addObject:SPKCropAspectTitle(SPKCropAspectPresetAtIndex(i))];
            }
            [_aspectChips setItems:titles symbols:@[]];
            _aspectChips.selectedIndex = 0; // Free (first)
            [self addSubview:_aspectChips];
            [NSLayoutConstraint activateConstraints:@[
                [_aspectChips.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
                [_aspectChips.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
                [_aspectChips.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            ]];

            _straightenIcon = SPKCropControlsStraightenIcon();
            _aspectIcon = SPKMediaChromeBottomBarIcon(@"ig_icon_crop_square_outline_24");
            _switchItem = SPKMediaChromeBottomBarButtonItem(@"crop", @"", self, @selector(switchItemTapped));
        } else {
            _panel = SPKCropControlsPanelStraighten;
        }
        [self applyPanelAnimated:NO];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, kSPKCropControlsHeight);
}

- (void)setPanel:(SPKCropControlsPanel)panel {
    if (!_aspectChips)
        panel = SPKCropControlsPanelStraighten;
    if (panel == _panel)
        return;
    _panel = panel;
    [self applyPanelAnimated:YES];
}

- (void)applyPanelAnimated:(BOOL)animated {
    BOOL straighten = (_panel == SPKCropControlsPanelStraighten);
    // The button shows the tool it switches to, so it reads as that tool's
    // button: straighten while the chips are up, aspect ratio while the ruler
    // is.
    SPKCropControlsSetItemImage(_switchItem, straighten ? _aspectIcon : _straightenIcon);
    _switchItem.accessibilityLabel = straighten ? SPKL(@"CROP_ASPECT_RATIO_TOOL_ACCESSIBILITY_LABEL")
                                                : SPKL(@"CROP_STRAIGHTEN_RULER_ACCESSIBILITY_LABEL");
    // Hidden as well as transparent, so the panel out of view takes no touches
    // and VoiceOver skips it.
    UIView *incoming = straighten ? _ruler : _aspectChips;
    UIView *outgoing = straighten ? _aspectChips : _ruler;
    if (!animated) {
        incoming.hidden = NO;
        incoming.alpha = 1.0;
        incoming.transform = CGAffineTransformIdentity;
        outgoing.alpha = 0.0;
        outgoing.hidden = YES;
        return;
    }
    // The incoming panel rises into place as the outgoing one lifts away.
    if (incoming.hidden || incoming.alpha <= 0.01)
        incoming.transform = CGAffineTransformMakeTranslation(0.0, kSPKCropControlsSlide);
    incoming.hidden = NO;
    [UIView animateWithDuration:0.32
        delay:0.0
        usingSpringWithDamping:0.9
        initialSpringVelocity:0.0
        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
        animations:^{
            incoming.alpha = 1.0;
            incoming.transform = CGAffineTransformIdentity;
            outgoing.alpha = 0.0;
            outgoing.transform = CGAffineTransformMakeTranslation(0.0, -kSPKCropControlsSlide);
        }
        completion:^(BOOL finished) {
            if (finished && outgoing.alpha <= 0.01) {
                outgoing.hidden = YES;
                outgoing.transform = CGAffineTransformIdentity;
            }
        }];
}

- (void)switchItemTapped {
    [self selectPanel:(_panel == SPKCropControlsPanelAspect ? SPKCropControlsPanelStraighten : SPKCropControlsPanelAspect)];
}

- (void)selectPanel:(SPKCropControlsPanel)panel {
    if (panel == _panel)
        return;
    self.panel = panel;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
}

@end
