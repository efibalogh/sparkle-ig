#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "../../Shared/UI/SPKChrome.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"

// ─── Constants & Types ──────────────────────────────────────────────

static const char kSPKCellSectionControllerAssocKey = 0;
static const char kSPKOverlayPollViewsAssocKey = 0;

// Register a poll sticker against its enclosing overlay so the overlay's
// layoutSubviews can re-apply vote badges to just that view, instead of
// walking the entire overlay subtree on every layout pass (the overwhelmingly
// common case is a story with no poll at all).
static void SPKRegisterPollViewWithOverlay(UIView *pollView) {
    Class overlayClass = NSClassFromString(@"IGStoryFullscreenOverlayView");
    if (!overlayClass)
        return;
    for (UIView *view = pollView.superview; view; view = view.superview) {
        if (![view isKindOfClass:overlayClass])
            continue;
        NSHashTable *pollViews = objc_getAssociatedObject(view, &kSPKOverlayPollViewsAssocKey);
        if (!pollViews) {
            pollViews = [NSHashTable weakObjectsHashTable];
            objc_setAssociatedObject(view, &kSPKOverlayPollViewsAssocKey, pollViews, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (![pollViews containsObject:pollView])
            [pollViews addObject:pollView];
        return;
    }
}

// ─── Customization ──────────────────────────────────────────────────
// Adjust these values to customize the badge position and size.
#define kSPKPollBadgePaddingHorizontal 12.0
#define kSPKPollBadgePaddingVertical 6.0
#define kSPKPollBadgeMarginRight -6.0
// Set to 0.0 to center vertically, or a positive/negative value to offset from the center
#define kSPKPollBadgeCenterYOffset -18.0

// ─── Badge View ─────────────────────────────────────────────────────

// The vote badge is Sparkle UI, so it honours "Hide UI on Capture" like every
// other injected overlay: both the pill and its text live inside an
// SPKChromeCanvas, whose content is excluded from screenshots and recordings.
// Nothing is drawn on the container itself — that sits outside the secure
// canvas and would survive the redaction.
@interface SPKStoryPollVoteBadge : UIView
@property (nonatomic, strong, readonly) UILabel *label;
@property (nonatomic, strong, readonly) UIView *pill;
- (instancetype)initWithFont:(UIFont *)font textColor:(UIColor *)textColor pillColor:(UIColor *)pillColor;
@end

@implementation SPKStoryPollVoteBadge {
    SPKChromeCanvas *_canvas;
}

- (instancetype)initWithFont:(UIFont *)font textColor:(UIColor *)textColor pillColor:(UIColor *)pillColor {
    self = [super initWithFrame:CGRectZero];
    if (!self)
        return nil;

    // Frame-positioned from the outside (the poll sticker lays out by frame);
    // all Auto Layout stays inside the container.
    self.translatesAutoresizingMaskIntoConstraints = YES;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = NO;

    _canvas = [SPKChromeCanvas new];
    _canvas.userInteractionEnabled = NO;
    [self addSubview:_canvas];

    // Content goes into the canvas now (before it materialises its secure
    // canvas) but is constrained to `_canvas` itself — its identity is stable,
    // whereas `contentContainer` swaps to the stolen CanvasView once attached,
    // migrating these subviews along with it.
    UIView *host = _canvas.contentContainer;

    _pill = [[UIView alloc] init];
    _pill.translatesAutoresizingMaskIntoConstraints = NO;
    _pill.userInteractionEnabled = NO;
    _pill.backgroundColor = pillColor;
    _pill.layer.masksToBounds = YES;
    [host addSubview:_pill];

    _label = [[UILabel alloc] init];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.font = font;
    _label.textColor = textColor;
    _label.textAlignment = NSTextAlignmentCenter;
    [host addSubview:_label];

    [NSLayoutConstraint activateConstraints:@[
        [_canvas.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_canvas.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_canvas.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_canvas.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_pill.leadingAnchor constraintEqualToAnchor:_canvas.leadingAnchor],
        [_pill.trailingAnchor constraintEqualToAnchor:_canvas.trailingAnchor],
        [_pill.topAnchor constraintEqualToAnchor:_canvas.topAnchor],
        [_pill.bottomAnchor constraintEqualToAnchor:_canvas.bottomAnchor],
        [_label.centerXAnchor constraintEqualToAnchor:_canvas.centerXAnchor],
        [_label.centerYAnchor constraintEqualToAnchor:_canvas.centerYAnchor],
    ]];

    return self;
}

@end

// ─── Utilities ──────────────────────────────────────────────────────

static id SPKCallMaybe(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0)
        return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector])
        return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id SPKKVCMaybe(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray *SPKArrayIvar(id object, const char *name) {
    if (!object || !name)
        return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (!ivar)
            continue;
        @try {
            id value = object_getIvar(object, ivar);
            return [value isKindOfClass:[NSArray class]] ? value : nil;
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

// ─── Label & String Handling ────────────────────────────────────────

static BOOL SPKStoryPollStickerIsEditing(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        NSString *className = NSStringFromClass([responder class]);
        if ([className containsString:@"StoryPostCaptureEditing"] ||
            [className containsString:@"StoryMediaCompositionEditing"] ||
            [className containsString:@"StoryStickerTray"]) {
            return YES;
        }
    }
    return NO;
}

// ─── Data Extraction ────────────────────────────────────────────────

static NSInteger SPKStoryPollTallyCount(id tally) {
    if ([tally respondsToSelector:@selector(integerValue)])
        return [tally integerValue];
    for (NSString *selectorName in @[ @"totalCount", @"count", @"countValue", @"voteCount", @"pollVotersCount" ]) {
        id value = SPKCallMaybe(tally, selectorName) ?: SPKKVCMaybe(tally, selectorName);
        if ([value respondsToSelector:@selector(integerValue)]) {
            return [value integerValue];
        }
    }
    return 0;
}

// Returns the IGAPIStoryPollTappableObject -> IGAPIPollSticker -> tallies
static id SPKStoryPollAuthoritativeSticker(id media, id viewModel) {
    NSArray *storyPolls = SPKCallMaybe(media, @"_private_storyPolls") ?: SPKKVCMaybe(media, @"_private_storyPolls");
    if (![storyPolls isKindOfClass:[NSArray class]] || storyPolls.count == 0) {
        storyPolls = SPKCallMaybe(media, @"storyPolls") ?: SPKKVCMaybe(media, @"storyPolls");
    }
    if (![storyPolls isKindOfClass:[NSArray class]] || storyPolls.count == 0)
        return nil;

    id viewPollValue = SPKCallMaybe(viewModel, @"pollId") ?: SPKKVCMaybe(viewModel, @"pollId");
    NSString *viewPollID = [viewPollValue description];

    for (id storyPoll in storyPolls) {
        id sticker = SPKCallMaybe(storyPoll, @"pollSticker") ?: SPKKVCMaybe(storyPoll, @"pollSticker");
        if (!sticker)
            continue;
        if (viewPollID.length == 0)
            return sticker;
        id stickerPollValue = SPKCallMaybe(sticker, @"pollId") ?: SPKKVCMaybe(sticker, @"pollId");
        NSString *stickerPollID = [stickerPollValue description];
        if ([stickerPollID isEqualToString:viewPollID])
            return sticker;
    }

    id first = storyPolls.firstObject;
    return SPKCallMaybe(first, @"pollSticker") ?: SPKKVCMaybe(first, @"pollSticker");
}

static id SPKFindMediaForPollView(UIView *pollView) {
    // Check if any parent cell has an associated section controller.
    UICollectionViewCell *parentCell = nil;
    UIView *current = pollView;
    while (current != nil) {
        if ([current isKindOfClass:[UICollectionViewCell class]]) {
            parentCell = (UICollectionViewCell *)current;
            break;
        }
        current = current.superview;
    }

    if (parentCell) {
        id sectionController = objc_getAssociatedObject(parentCell, &kSPKCellSectionControllerAssocKey);
        if (sectionController) {
            id media = SPKCallMaybe(sectionController, @"currentStoryItem") ?: SPKCallMaybe(sectionController, @"model");
            if (media)
                return media;
        }
    }

    // 2. Fallback: traverse responder chain
    for (UIResponder *responder = pollView; responder; responder = responder.nextResponder) {
        for (NSString *selectorName in @[ @"media", @"igMedia", @"storyMedia", @"storyItem", @"item", @"feedItem" ]) {
            id media = SPKCallMaybe(responder, selectorName) ?: SPKKVCMaybe(responder, selectorName);
            if (media && media != responder)
                return media;
        }
    }

    return nil;
}

static void SPKApplyStoryPollVoteCounts(UIView *pollView, NSArray<UIView *> *optionViews) {
    if (![SPKUtils getBoolPref:@"stories_poll_vote_counts"])
        return;
    if (!pollView.window || SPKStoryPollStickerIsEditing(pollView)) {
        for (UIView *subview in pollView.subviews) {
            if (subview.tag >= 998800 && subview.tag < 998900)
                subview.hidden = YES;
        }
        return;
    }

    id media = SPKFindMediaForPollView(pollView);
    if (!media)
        return;

    id viewModel = SPKCallMaybe(pollView, @"pollSticker") ?: SPKCallMaybe(pollView, @"igapiStickerModel") ?
                                                                                                          : SPKCallMaybe(pollView, @"exportModel");
    id model = SPKStoryPollAuthoritativeSticker(media, viewModel) ?: viewModel;

    NSArray *tallies = SPKCallMaybe(model, @"tallies") ?: SPKKVCMaybe(model, @"tallies");
    if (![tallies isKindOfClass:[NSArray class]] || tallies.count == 0) {
        for (UIView *subview in pollView.subviews) {
            if (subview.tag >= 998800 && subview.tag < 998900)
                subview.hidden = YES;
        }
        return;
    }

    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;

    NSUInteger count = MIN(optionViews.count, tallies.count);
    for (NSUInteger index = 0; index < count; index++) {
        UIView *optionView = optionViews[index];

        NSInteger votes = SPKStoryPollTallyCount(tallies[index]);
        NSString *formattedVotes = [formatter stringFromNumber:@(votes)] ?: [NSString stringWithFormat:@"%td", votes];

        // Use a unique tag for each option view's badge
        NSInteger badgeTag = 998800 + index;
        UIView *existing = [pollView viewWithTag:badgeTag];
        SPKStoryPollVoteBadge *badge = [existing isKindOfClass:[SPKStoryPollVoteBadge class]] ? (SPKStoryPollVoteBadge *)existing : nil;
        if (!badge) {
            [existing removeFromSuperview];
            // Poll stickers always render on a light card, so pin the badge to the
            // dark-mode variant (dark pill + light text) regardless of the user's
            // system appearance — otherwise it's low-contrast in dark mode.
            UITraitCollection *darkTraits = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
            badge = [[SPKStoryPollVoteBadge alloc]
                initWithFont:[UIFont boldSystemFontOfSize:12]
                   textColor:[[SPKUtils SPKColor_InstagramPrimaryText] resolvedColorWithTraitCollection:darkTraits]
                   pillColor:[[SPKUtils SPKColor_InstagramTertiaryBackground] resolvedColorWithTraitCollection:darkTraits]];
            badge.tag = badgeTag;
            [pollView addSubview:badge];
        }

        badge.hidden = NO;
        badge.label.text = formattedVotes;

        CGSize badgeSize = [badge.label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        badgeSize.width = ceil(badgeSize.width) + kSPKPollBadgePaddingHorizontal;
        badgeSize.height = ceil(badgeSize.height) + kSPKPollBadgePaddingVertical;

        // Enforce perfect circle if the width is smaller than the height (e.g. for single digits)
        badgeSize.width = MAX(badgeSize.width, badgeSize.height);

        // Convert optionView bounds to pollView coordinate space so we aren't clipped by the optionView
        CGRect optionFrame = [optionView convertRect:optionView.bounds toView:pollView];

        CGFloat badgeX = CGRectGetMaxX(optionFrame) - badgeSize.width - kSPKPollBadgeMarginRight;
        CGFloat badgeY = CGRectGetMidY(optionFrame) - (badgeSize.height / 2.0) + kSPKPollBadgeCenterYOffset;

        badge.frame = CGRectMake(badgeX, badgeY, badgeSize.width, badgeSize.height);
        // Rounding goes on the pill INSIDE the secure canvas, never on the
        // container — anything drawn there would outlive "Hide UI on Capture".
        badge.pill.layer.cornerRadius = badgeSize.height / 2.0;

        // Poll stickers are displayed with an upscaling transform, so a label
        // rasterized at the screen scale gets magnified by the parent and looks
        // blurry. Re-rasterize the text at the badge's true on-screen scale
        // (measured through the live transform chain) so it stays crisp.
        UIWindow *window = pollView.window;
        CGFloat onScreenScale = 1.0;
        if (window) {
            CGPoint origin = [pollView convertPoint:CGPointZero toView:window];
            CGPoint unit = [pollView convertPoint:CGPointMake(1.0, 0.0) toView:window];
            onScreenScale = hypot(unit.x - origin.x, unit.y - origin.y);
        }
        CGFloat targetContentsScale = UIScreen.mainScreen.scale * MAX(1.0, onScreenScale);
        if (fabs(badge.label.layer.contentsScale - targetContentsScale) > 0.01) {
            badge.label.layer.contentsScale = targetContentsScale;
            [badge.label setNeedsDisplay];
        }

        [pollView bringSubviewToFront:badge];
    }

    // Hide any phantom badges that were created from previous logic or if options count shrank
    for (UIView *subview in pollView.subviews) {
        if (subview.tag >= 998800 + count && subview.tag < 998900) {
            subview.hidden = YES;
        }
    }
}

// ─── Hooks ──────────────────────────────────────────────────────────

%group SPKStoryPollVoteCountsHooks

// Bind section controller to cell so child views can easily access the current story item.
%hook IGStoryFullscreenSectionController
- (id)cellForItemAtIndex:(NSInteger)index {
    UICollectionViewCell *cell = %orig;
    if (cell)
        objc_setAssociatedObject(cell, &kSPKCellSectionControllerAssocKey, self, OBJC_ASSOCIATION_ASSIGN);
    return cell;
}
%end

%hook IGStorySectionController
- (id)cellForItemAtIndex:(NSInteger)index {
    UICollectionViewCell *cell = %orig;
    if (cell)
        objc_setAssociatedObject(cell, &kSPKCellSectionControllerAssocKey, self, OBJC_ASSOCIATION_ASSIGN);
    return cell;
}
%end

// Modern poll sticker
%hook IGPollStickerV2View
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"StoryPollVoteCounts.layoutSubviews");
    NSArray *options = SPKArrayIvar(self, "_optionViews");
    if (options.count > 0) {
        SPKApplyStoryPollVoteCounts((UIView *)self, options);
        SPKRegisterPollViewWithOverlay((UIView *)self);
    }
}
%end

// Legacy poll sticker
%hook IGPollStickerView
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"StoryPollVoteCounts.layoutSubviews2");
    NSArray *options = SPKArrayIvar(self, "_optionViews") ?: SPKArrayIvar(self, "_voteOptionViews") ?
                                                                                                    : SPKArrayIvar(self, "_options");
    if (options.count > 0) {
        SPKApplyStoryPollVoteCounts((UIView *)self, options);
        SPKRegisterPollViewWithOverlay((UIView *)self);
    }
}
%end

// Overlay view constantly lays out (e.g. progress bar), so re-applying here
// guarantees our text isn't overwritten by Instagram's asynchronous poll result
// fetches. We only touch poll stickers the sticker hooks above have registered,
// so a story with no poll (the common case) costs a single associated-object
// lookup rather than a full subtree walk on every layout pass.
%hook IGStoryFullscreenOverlayView
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"StoryPollVoteCounts.layoutSubviews3");
    NSHashTable *pollViews = objc_getAssociatedObject(self, &kSPKOverlayPollViewsAssocKey);
    if (pollViews.count == 0)
        return;

    for (UIView *pollView in pollViews.allObjects) {
        if (!pollView.superview)
            continue;
        NSArray *options = SPKArrayIvar(pollView, "_optionViews") ?: SPKArrayIvar(pollView, "_voteOptionViews") ?
                                                                                                                : SPKArrayIvar(pollView, "_options");
        if (options.count > 0)
            SPKApplyStoryPollVoteCounts(pollView, options);
    }
}
%end

%end // group SPKStoryPollVoteCountsHooks

#pragma mark - Entry Point

extern "C" void SPKInstallStoryPollVoteCountsHooksIfEnabled(void) {
    if (![SPKUtils getBoolPref:@"stories_poll_vote_counts"])
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKStoryPollVoteCountsHooks, IGStoryFullscreenSectionController = SPKStoryFullscreenSectionControllerClass());
    });
}
