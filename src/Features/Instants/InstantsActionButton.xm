#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../../App/SPKPerfMeter.h"
#import "../../Utils.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../AssetUtils.h"
#import "InstantsManualSeen.h"
#import "InstantsModeViews.h"
#import "InstantsResolver.h"
#import <objc/runtime.h>
#import <substrate.h>

static NSInteger const kSPKInstantsActionButtonTag = 921399;
static NSInteger const kSPKInstantsMarkSeenButtonTag = 921400;

// MARK: - Anchor Helpers

static UIView *SPKInstantsHeaderOwnedView(UIView *header, NSString *key) {
    if (!header || key.length == 0)
        return nil;
    id view = nil;
    @try {
        view = SPKKVCObject(header, key);
    } @catch (__unused NSException *e) {
    }
    if (![view isKindOfClass:UIView.class]) {
        Ivar ivar = class_getInstanceVariable(header.class, key.UTF8String);
        if (ivar)
            @try {
                view = object_getIvar(header, ivar);
            } @catch (__unused NSException *e) {
            }
    }
    return [view isKindOfClass:UIView.class] ? (UIView *)view : nil;
}

static UIView *SPKInstantsHeaderArchiveButton(UIView *header) {
    UIView *btn = SPKInstantsHeaderOwnedView(header, @"archiveButton");
    if (btn && btn.superview == header && !btn.hidden && btn.alpha >= 0.01)
        return btn;
    return nil;
}

static UIView *SPKInstantsFallbackRightAnchor(UIView *header, UIView *button) {
    CGFloat halfWidth = header.bounds.size.width / 2.0;
    UIView *anchor = nil;
    CGFloat minX = CGFLOAT_MAX;
    for (UIView *sub in header.subviews) {
        if (sub == button || sub.hidden || sub.alpha < 0.01)
            continue;
        if (sub.bounds.size.width < 4.0 || sub.bounds.size.height < 4.0)
            continue;
        if (CGRectGetMidX(sub.frame) < halfWidth)
            continue;
        if (CGRectGetMinX(sub.frame) < minX) {
            anchor = sub;
            minX = CGRectGetMinX(sub.frame);
        }
    }
    return anchor;
}

// MARK: - Header Visibility

static BOOL SPKInstantsHeaderIsVisible(UIView *header) {
    if (!header || header.hidden || header.alpha < 0.01 || !header.window)
        return NO;
    if (header.bounds.size.width < 10.0 || header.bounds.size.height < 10.0)
        return NO;
    return CGRectIntersectsRect([header convertRect:header.bounds toView:header.window], header.window.bounds);
}

/// YES when a snap is actually being consumed (viewed). The action button belongs only
/// on the consumption header, not on the creation/camera header (which hosts the gallery
/// upload button at the same anchor).
static BOOL SPKInstantsHeaderIsConsumption(UIView *header) {
    UIWindow *window = header.window;
    // Creation wins the slot: when the camera page is up, the gallery-upload button owns
    // this position, so the action button must stand down even if a snap view lingers.
    return SPKInstantsWindowShowsSnapView(window) && !SPKInstantsWindowShowsCreationView(window);
}

// MARK: - Action Context

static SPKActionButtonContext *SPKInstantsActionContext(UIView *header, UIButton *button) {
    SPKActionButtonContext *context = [[SPKActionButtonContext alloc] init];
    context.source = SPKActionButtonSourceInstants;
    context.view = button ?: header;
    context.controller = [SPKUtils viewControllerForAncestralView:header] ?: topMostController();
    context.settingsTitle = SPKActionButtonTopicTitleForSource(SPKActionButtonSourceInstants);
    context.supportedActions = SPKActionButtonSupportedActionsForSource(SPKActionButtonSourceInstants);
    __weak UIView *weakHeader = header;
    __block SPKInstantsResolverResult *resolvedResult = nil;
    __block BOOL clearScheduled = NO;
    void (^scheduleClear)(void) = ^{
        if (clearScheduled)
            return;
        clearScheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            resolvedResult = nil;
            clearScheduled = NO;
        });
    };
    SPKInstantsResolverResult * (^resolve)(NSString *) = ^SPKInstantsResolverResult *(NSString *reason) {
        if (!resolvedResult) {
            resolvedResult = SPKInstantsResolveForHeader(weakHeader, reason);
            scheduleClear();
        }
        return resolvedResult;
    };
    context.mediaResolver = ^id(__unused SPKActionButtonContext *ctx) {
        SPKInstantsResolverResult *r = resolve(@"media");
        if (!r)
            return nil;
        // Prefer the directly-resolved active snap (always the on-screen item).
        if (r.activeSnap)
            return r.activeSnap;
        if (r.snaps.count == 0)
            return nil;
        NSInteger idx = r.activeIndex;
        return (idx >= 0 && idx < (NSInteger)r.snaps.count) ? r.snaps[idx] : nil;
    };
    context.bulkMediaResolver = ^id(__unused SPKActionButtonContext *ctx) {
        return resolve(@"bulk").snaps ?: @[];
    };
    context.currentIndexResolver = ^NSInteger(__unused SPKActionButtonContext *ctx) {
        SPKInstantsResolverResult *r = resolve(@"index");
        return r ? r.activeIndex : 0;
    };
    return context;
}

// MARK: - Button Placement

/// Frame match used only for deciding whether to reposition. Does NOT consider
/// hidden/alpha — during the iOS 26 menu morph UIKit hides the real button and animates
/// a snapshot, and we must not treat that transient state as "needs replacing".
static BOOL SPKInstantsActionFrameMatches(UIButton *button, CGRect frame) {
    if (![button isKindOfClass:[UIButton class]] || !button.superview)
        return NO;
    return ABS(CGRectGetMinX(button.frame) - CGRectGetMinX(frame)) < 0.5 &&
           ABS(CGRectGetMinY(button.frame) - CGRectGetMinY(frame)) < 0.5 &&
           ABS(CGRectGetWidth(button.frame) - CGRectGetWidth(frame)) < 0.5 &&
           ABS(CGRectGetHeight(button.frame) - CGRectGetHeight(frame)) < 0.5;
}

static CGRect SPKInstantsButtonFrame(UIView *header, UIButton *button) {
    CGFloat side = 44.0;
    UIView *anchor = SPKInstantsHeaderArchiveButton(header) ?: SPKInstantsFallbackRightAnchor(header, button);
    if (anchor) {
        return CGRectMake(CGRectGetMinX(anchor.frame) - side,
                          CGRectGetMidY(anchor.frame) - side / 2.0, side, side);
    }
    return CGRectMake(header.bounds.size.width - side - 12.0,
                      (header.bounds.size.height - side) / 2.0, side, side);
}

static void SPKInstantsPlaceButton(UIView *header) {
    SPK_PERF_SCOPE(@"InstantsActionButton.placeButton");
    if (!header)
        return;

    UIButton *existing = (UIButton *)[header viewWithTag:kSPKInstantsActionButtonTag];

    // Eligibility is checked BEFORE the menu-morph early-return below. These decide whether
    // the button belongs on this header at all, and an already-placed button used to take
    // the early-return forever — so when the header switched from consumption to the
    // creation ("New instant") page, it was never removed and sat on top of the
    // gallery-upload button, which owns that slot during creation.
    if (![SPKUtils getBoolPref:@"instants_action_btn"]) {
        [existing removeFromSuperview];
        return;
    }
    if (!SPKInstantsHeaderIsVisible(header)) {
        [existing removeFromSuperview];
        return;
    }

    // The action button should appear whenever we're in the consumption viewer.
    // Even if the service cache is empty (all snaps "seen"), the view fallback in
    // the resolver will extract media from the live stack view.
    // Only skip if we're not actually consuming (e.g. creation/camera header).
    if (!SPKInstantsHeaderIsConsumption(header)) {
        [existing removeFromSuperview];
        return;
    }

    // CRITICAL (iOS 26 menu morph): if the button already exists, has a menu, is in the
    // header, and is correctly positioned, return immediately and touch NOTHING. During the
    // menu open/close animation UIKit temporarily hides the real button and animates a
    // snapshot; any frame/hidden/alpha write here fights that animation and makes the button
    // flash or disappear. Every other action button (Feed/Profile/Stories/Reels/Audio) uses
    // this same early-return. We must NOT gate this on button.hidden/alpha — those belong to
    // the animation, not us.
    //
    // Safe to run after the eligibility checks above: a menu morph only happens while the
    // snap viewer is up, where those checks all pass anyway.
    if (existing && existing.menu != nil && existing.superview == header) {
        CGRect expectedFrame = SPKInstantsButtonFrame(header, existing);
        if (SPKInstantsActionFrameMatches(existing, expectedFrame)) {
            return; // Placed and configured — leave it entirely alone.
        }
    }

    UIButton *button = existing;
    BOOL isNew = (button == nil);
    if (isNew) {
        button = SPKActionButtonWithTag(header, kSPKInstantsActionButtonTag);
        button.translatesAutoresizingMaskIntoConstraints = YES;
        [header addSubview:button];
        SPKApplyButtonStyle(button, SPKActionButtonSourceInstants);
    }

    // Configure the menu only once per button lifecycle (when created or when the menu is
    // still nil from a prior failed resolve). Do NOT reconfigure on count changes.
    if (button.menu == nil) {
        SPKConfigureActionButton(button, SPKInstantsActionContext(header, button));

        // If configure resulted in no menu (resolver returned nil because the stack view
        // isn't populated yet), schedule a single retry after a short delay.
        if (!button.menu) {
            __weak UIView *weakHeader = header;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIView *strongHeader = weakHeader;
                if (!strongHeader || !strongHeader.window)
                    return;
                UIButton *retryButton = (UIButton *)[strongHeader viewWithTag:kSPKInstantsActionButtonTag];
                if (retryButton && !retryButton.menu) {
                    SPKConfigureActionButton(retryButton, SPKInstantsActionContext(strongHeader, retryButton));
                    retryButton.hidden = NO;
                    retryButton.alpha = 1.0;
                }
            });
        }
    }

    CGRect expectedFrame = SPKInstantsButtonFrame(header, button);
    if (!SPKInstantsActionFrameMatches(button, expectedFrame))
        button.frame = expectedFrame;
    button.hidden = NO;
    button.alpha = 1.0;
    [header bringSubviewToFront:button];
}

// MARK: - Mark as Seen Button

/// Sits one slot left of the action button, in the same header and behind the same
/// eligibility checks, so it can never outlive the viewer or appear over the creation page.
/// It is a plain button rather than a menu row because releasing one Instant is a single
/// deliberate act, and the menu is built once per button lifecycle: a row there could not
/// track the snap currently on screen.
@interface SPKInstantsMarkSeenButtonTarget : NSObject
@end

@implementation SPKInstantsMarkSeenButtonTarget

+ (instancetype)shared {
    static SPKInstantsMarkSeenButtonTarget *sShared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sShared = [[SPKInstantsMarkSeenButtonTarget alloc] init];
    });
    return sShared;
}

- (void)buttonTapped:(UIButton *)sender {
    UIView *header = sender.superview;
    if (!header)
        return;
    SPKExecuteActionIdentifier(kSPKActionInstantsMarkSeen,
                              SPKInstantsActionContext(header, sender), NO);
}

@end

static CGRect SPKInstantsMarkSeenButtonFrame(UIView *header, UIView *button) {
    CGFloat side = 44.0;
    // Measured from the action button's live frame, which the same layout pass has already
    // set, so the two stay adjacent whatever anchor the header turns out to offer. Reading
    // the placed frame also keeps the fallback anchor search from picking the action button
    // itself and pushing this one a slot too far left.
    UIButton *actionButton = (UIButton *)[header viewWithTag:kSPKInstantsActionButtonTag];
    if (![actionButton isKindOfClass:UIButton.class] || actionButton.superview != header) {
        // No action button on this header, so take its slot rather than leaving a gap.
        return SPKInstantsButtonFrame(header, (UIButton *)button);
    }
    CGRect actionFrame = actionButton.frame;
    return CGRectMake(CGRectGetMinX(actionFrame) - side, CGRectGetMinY(actionFrame),
                      side, CGRectGetHeight(actionFrame));
}

static void SPKInstantsPlaceMarkSeenButton(UIView *header) {
    if (!header)
        return;

    UIButton *existing = (UIButton *)[header viewWithTag:kSPKInstantsMarkSeenButtonTag];
    if (!SPKInstantsHeaderIsVisible(header) || !SPKInstantsHeaderIsConsumption(header)) {
        [existing removeFromSuperview];
        return;
    }
    SPKInstantsManualSeenRegisterEyeButtonHost(header);
    // Cached per displayed Instant, so only authors being held get the button.
    if (!SPKInstantsManualSeenShouldShowEyeButton()) {
        [existing removeFromSuperview];
        return;
    }

    UIButton *button = existing;
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = kSPKInstantsMarkSeenButtonTag;
        button.translatesAutoresizingMaskIntoConstraints = YES;
        button.tintColor = UIColor.whiteColor;
        button.adjustsImageWhenHighlighted = YES;
        button.accessibilityLabel = SPKL(@"INSTANTS_MARK_SEEN_TITLE");
        [button setImage:[SPKAssetUtils instagramIconNamed:@"eye"
                                                pointSize:24.0
                                            renderingMode:UIImageRenderingModeAlwaysTemplate]
                forState:UIControlStateNormal];
        [button addTarget:[SPKInstantsMarkSeenButtonTarget shared]
                      action:@selector(buttonTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [header addSubview:button];
        SPKApplyButtonStyle(button, SPKActionButtonSourceInstants);
    }

    CGRect expectedFrame = SPKInstantsMarkSeenButtonFrame(header, button);
    if (!SPKInstantsActionFrameMatches(button, expectedFrame))
        button.frame = expectedFrame;
    button.hidden = NO;
    button.alpha = 1.0;
    [header bringSubviewToFront:button];
}

// MARK: - Hook

typedef void (*SPKInstantsHeaderLayoutIMP)(id, SEL);
static SPKInstantsHeaderLayoutIMP orig_instantsHeaderLayoutSubviews = NULL;

static void replaced_instantsHeaderLayoutSubviews(id self, SEL _cmd) {
    SPK_PERF_SCOPE(@"InstantsActionButton.headerLayout");
    if (orig_instantsHeaderLayoutSubviews)
        orig_instantsHeaderLayoutSubviews(self, _cmd);
    SPKInstantsPlaceButton((UIView *)self);
    SPKInstantsPlaceMarkSeenButton((UIView *)self);
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

// MARK: - Retry & Installation

static BOOL sSPKInstantsActionButtonHooksInstalled = NO;
static BOOL sSPKInstantsActionButtonRetryScheduled = NO;

static void SPKInstallInstantsActionButtonHooksAttempt(NSUInteger attempt) {
    if (sSPKInstantsActionButtonHooksInstalled)
        return;

    Class headerClass = objc_getClass("_TtC45IGQuickSnapNavigationV3HeaderButtonController39IGQuickSnapNavigationV3HeaderButtonView");
    if (!headerClass) {
        if (attempt == 0 || attempt == 5 || attempt == 15 || attempt == 30) {
            SPKLog(@"Instants", @"QuickSnap header class missing; retry attempt=%lu", (unsigned long)attempt);
        }
        if (attempt >= 60) {
            SPKLog(@"Instants", @"QuickSnap header class still missing after retries; Instants action button inactive");
            return;
        }
        if (!sSPKInstantsActionButtonRetryScheduled) {
            sSPKInstantsActionButtonRetryScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                sSPKInstantsActionButtonRetryScheduled = NO;
                SPKInstallInstantsActionButtonHooksAttempt(attempt + 1);
            });
        }
        return;
    }

    SPKHookInstanceMethod("_TtC45IGQuickSnapNavigationV3HeaderButtonController39IGQuickSnapNavigationV3HeaderButtonView",
                          @selector(layoutSubviews),
                          (IMP)replaced_instantsHeaderLayoutSubviews,
                          (IMP *)&orig_instantsHeaderLayoutSubviews);
    SPKInstallInstantsModeViewHooks();
    SPKInstallInstantsResolverHooks();
    sSPKInstantsActionButtonHooksInstalled = YES;
    SPKLog(@"Instants", @"[Sparkle] Instants action button hooks installed");
}

extern "C" void SPKInstallInstantsActionButtonHooksIfEnabled(void) {
    SPKInstallInstantsActionButtonHooksAttempt(0);
}
