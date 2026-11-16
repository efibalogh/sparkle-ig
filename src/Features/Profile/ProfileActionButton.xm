#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../InstagramHeaders.h"
#import "../../Utils.h"

#import "../../AssetUtils.h"
#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../../Shared/Gallery/SPKGalleryFile.h"
#import "../../Shared/Gallery/SPKGalleryOriginController.h"
#import "../../Shared/Gallery/SPKGallerySaveMetadata.h"
#import "../../Shared/MediaPreview/SPKFullScreenMediaPlayer.h"
#import "../../Shared/UI/SPKChromeGlassMirror.h"
#import "../../Shared/UI/SPKSideColumn.h"
#import "../../App/SPKPerfMeter.h"

static CGFloat const kSPKProfileActionButtonWidth = 44.0;
static CGFloat const kSPKProfileActionButtonHeight = 44.0;
static CGFloat const kSPKProfileActionIconPointSize = 24.0;
static const void *kSPKProfileHeaderActionButtonAssocKey = &kSPKProfileHeaderActionButtonAssocKey;
static const void *kSPKProfileHeaderTitleViewKey = &kSPKProfileHeaderTitleViewKey;
static const void *kSPKProfileLastExpectedFrameKey = &kSPKProfileLastExpectedFrameKey;
static const void *kSPKProfileTitleIsCenteredKey = &kSPKProfileTitleIsCenteredKey;
static NSInteger const kSPKProfileActionButtonMaxInstallAttempts = 6;

static id SPKProfileSafeValue(id target, NSString *key) {
    if (!target || key.length == 0)
        return nil;
    @try {
        return [target valueForKey:key];
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static NSString *SPKProfileStringValue(id value) {
    if (!value)
        return nil;
    if ([value isKindOfClass:[NSString class]])
        return [(NSString *)value length] > 0 ? value : nil;
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *stringValue = [value stringValue];
        return stringValue.length > 0 ? stringValue : nil;
    }
    return nil;
}

static NSNumber *SPKProfileNumberValue(id value) {
    if (!value)
        return nil;
    if ([value isKindOfClass:[NSNumber class]])
        return value;
    if ([value respondsToSelector:@selector(integerValue)])
        return @([value integerValue]);
    return nil;
}

static id SPKProfileResolvedUserFromObject(id object, NSInteger depth) {
    if (!object || depth > 3)
        return nil;

    for (NSString *key in @[ @"userGQL", @"profileUser", @"profileController.userGQL", @"profileController.profileUser", @"profileController.user", @"user" ]) {
        id value = nil;
        if ([key containsString:@"."]) {
            id current = object;
            for (NSString *part in [key componentsSeparatedByString:@"."]) {
                current = SPKProfileSafeValue(current, part);
                if (!current)
                    break;
            }
            value = current;
        } else {
            value = SPKProfileSafeValue(object, key);
        }
        if (value)
            return value;
    }

    for (NSString *key in @[ @"delegate", @"viewController", @"_viewController", @"nextResponder" ]) {
        id nested = SPKProfileSafeValue(object, key);
        if (nested && nested != object) {
            id resolved = SPKProfileResolvedUserFromObject(nested, depth + 1);
            if (resolved)
                return resolved;
        }
    }

    if ([object isKindOfClass:[UIView class]]) {
        UIViewController *controller = [SPKUtils nearestViewControllerForView:(UIView *)object];
        if (controller && controller != object) {
            id resolved = SPKProfileResolvedUserFromObject(controller, depth + 1);
            if (resolved)
                return resolved;
        }
    }

    return nil;
}

static NSString *SPKProfileUsername(id user) {
    return SPKProfileStringValue(SPKProfileSafeValue(user, @"username"));
}

static NSString *SPKProfileUserPK(id user) {
    NSString *pk = SPKProfileStringValue(SPKProfileSafeValue(user, @"pk"));
    if (pk.length == 0)
        pk = SPKProfileStringValue(SPKProfileSafeValue(user, @"id"));
    if (pk.length == 0)
        pk = [SPKUtils pkFromIGUser:user];
    return pk;
}

static NSString *SPKProfileFullName(id user) {
    NSString *name = SPKProfileStringValue(SPKProfileSafeValue(user, @"fullName"));
    if (name.length == 0)
        name = SPKProfileStringValue(SPKProfileSafeValue(user, @"full_name"));
    if (name.length == 0)
        name = SPKProfileStringValue(SPKProfileSafeValue(user, @"name"));
    return name;
}

static NSString *SPKProfileBiography(id user) {
    NSString *bio = SPKProfileStringValue(SPKProfileSafeValue(user, @"biography"));
    if (bio.length == 0)
        bio = SPKProfileStringValue(SPKProfileSafeValue(user, @"bio"));
    return bio;
}

static NSURL *SPKProfileURL(id user) {
    NSString *username = SPKProfileUsername(user);
    if (username.length == 0)
        return nil;
    NSString *encoded = [username stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    if (encoded.length == 0)
        return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://www.instagram.com/%@/", encoded]];
}

static UIViewController *SPKProfileSourceController(id sourceObject, UIView *sourceView) {
    if ([sourceObject isKindOfClass:[UIViewController class]]) {
        return (UIViewController *)sourceObject;
    }
    UIViewController *controller = nil;
    id value = SPKProfileSafeValue(sourceObject, @"viewController");
    if ([value isKindOfClass:[UIViewController class]]) {
        controller = (UIViewController *)value;
    }
    if (!controller) {
        value = SPKProfileSafeValue(sourceObject, @"_viewController");
        if ([value isKindOfClass:[UIViewController class]]) {
            controller = (UIViewController *)value;
        }
    }
    if (!controller && sourceView) {
        controller = [SPKUtils nearestViewControllerForView:sourceView];
    }
    return controller;
}

@interface SPKProfileHeaderActionButton : SPKActionMenuButton
@property (nonatomic, weak) id sourceObject;
@property (nonatomic, assign) BOOL spkDidConfigure;
@property (nonatomic, assign) BOOL fallbackToCurrentUser;
@property (nonatomic, strong) UIView *spkGlassView;
@property (nonatomic, assign) BOOL spkGlassUnavailable;
@end

static void SPKConfigureProfileActionButton(SPKProfileHeaderActionButton *button);
static void SPKProfileUpdateGlass(SPKProfileHeaderActionButton *button, UIView *headerView);

@implementation SPKProfileHeaderActionButton

- (CGSize)sizeThatFits:(CGSize)size {
    (void)size;
    return CGSizeMake(kSPKProfileActionButtonWidth, kSPKProfileActionButtonHeight);
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(kSPKProfileActionButtonWidth, kSPKProfileActionButtonHeight);
}

// IG's header resizes its buttons, so the size is pinned; only the side column
// size is let through, for the button docked there.
static CGSize SPKProfileActionButtonPinnedSize(CGSize size) {
    if (size.width == SPKSideColumnButtonSide && size.height == SPKSideColumnButtonSide)
        return size;
    return CGSizeMake(kSPKProfileActionButtonWidth, kSPKProfileActionButtonHeight);
}

- (void)setFrame:(CGRect)frame {
    frame.size = SPKProfileActionButtonPinnedSize(frame.size);
    [super setFrame:frame];
}

- (void)setBounds:(CGRect)bounds {
    bounds.size = SPKProfileActionButtonPinnedSize(bounds.size);
    [super setBounds:bounds];
}

- (void)didMoveToWindow {
    SPK_PERF_SCOPE(@"ProfileActionButton.didMoveToWindow");
    [super didMoveToWindow];
    if (self.window && !self.spkDidConfigure) {
        self.spkDidConfigure = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKConfigureProfileActionButton(self);
        });
    }
    // The bubble stays in sync without polling: SPKChromeGlassMirror hooks setAlpha:
    // on IG's own bubbles, so the header is marked for layout whenever IG fades one
    // (the scroll-collapse doesn't otherwise re-run its layoutSubviews).
}

- (void)setSourceObject:(id)sourceObject {
    _sourceObject = sourceObject;
    _spkDidConfigure = NO;
    if (self.window) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKConfigureProfileActionButton(self);
        });
    }
}

- (void)setMenu:(UIMenu *)menu {
    [super setMenu:menu];
    self.spkDidConfigure = YES;
}

@end

static SPKActionButtonContext *SPKProfileActionContext(SPKProfileHeaderActionButton *button) {
    SPKActionButtonContext *context = [[SPKActionButtonContext alloc] init];
    __weak SPKProfileHeaderActionButton *weakButton = button;
    context.source = SPKActionButtonSourceProfile;
    context.view = button;
    context.controller = SPKProfileSourceController(button.sourceObject ?: button, button);
    context.settingsTitle = SPKActionButtonTopicTitleForSource(SPKActionButtonSourceProfile);
    context.supportedActions = SPKActionButtonSupportedActionsForSource(SPKActionButtonSourceProfile);
    context.mediaResolver = ^id(__unused SPKActionButtonContext *resolvedContext) {
        SPKProfileHeaderActionButton *strongButton = weakButton;
        id user = SPKProfileResolvedUserFromObject(strongButton.sourceObject ?: strongButton, 0);
        if (!user && strongButton.fallbackToCurrentUser) {
            user = SPKProfileSafeValue([SPKUtils activeUserSession], @"user");
        }
        return user;
    };
    context.visibilityResolver = ^BOOL(__unused SPKActionButtonContext *resolvedContext,
                                       NSString *identifier,
                                       __unused id media,
                                       NSArray *entries,
                                       __unused NSInteger currentIndex) {
        if ([identifier isEqualToString:kSPKActionProfileCopyInfo])
            return YES;
        if ([identifier isEqualToString:kSPKActionOpenTopicSettings])
            return YES;
        return entries.count > 0;
    };
    return context;
}

static void SPKConfigureProfileActionButton(SPKProfileHeaderActionButton *button) {
    if (!button)
        return;

    id user = SPKProfileResolvedUserFromObject(button.sourceObject ?: button, 0);
    if (!user && button.fallbackToCurrentUser) {
        user = SPKProfileSafeValue([SPKUtils activeUserSession], @"user");
    }
    if (!user) {
        button.hidden = YES;
        return;
    }

    button.hidden = NO;
    SPKApplyButtonStyle(button, SPKActionButtonSourceProfile);
    SPKConfigureActionButton(button, SPKProfileActionContext(button));
}

static SPKProfileHeaderActionButton *SPKProfileBuildHeaderActionButton(id sourceObject) {
    SPKProfileHeaderActionButton *button = [[SPKProfileHeaderActionButton alloc] initWithSymbol:@""
                                                                                      pointSize:kSPKProfileActionIconPointSize
                                                                                       diameter:kSPKProfileActionButtonWidth];
    button.accessibilityIdentifier = @"sparkle-profile-action-button";
    button.translatesAutoresizingMaskIntoConstraints = YES;
    button.frame = CGRectMake(0.0, 0.0, kSPKProfileActionButtonWidth, kSPKProfileActionButtonHeight);
    button.bounds = CGRectMake(0.0, 0.0, kSPKProfileActionButtonWidth, kSPKProfileActionButtonHeight);
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    button.contentEdgeInsets = UIEdgeInsetsZero;
    button.imageEdgeInsets = UIEdgeInsetsZero;
    button.tintColor = [UIColor labelColor];
    SPKApplyButtonStyle(button, SPKActionButtonSourceProfile);
    button.sourceObject = sourceObject;
    return button;
}

static SPKProfileHeaderActionButton *SPKProfileGetOrCreateActionButton(UIView *headerView) {
    SPKProfileHeaderActionButton *button = objc_getAssociatedObject(headerView, kSPKProfileHeaderActionButtonAssocKey);
    if (![button isKindOfClass:[SPKProfileHeaderActionButton class]]) {
        button = SPKProfileBuildHeaderActionButton(headerView);
        objc_setAssociatedObject(headerView,
                                 kSPKProfileHeaderActionButtonAssocKey,
                                 button,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (button.sourceObject != headerView) {
        button.sourceObject = headerView;
    }
    return button;
}

static void SPKProfileCollectTrailingControls(UIView *view, UIView *headerView, NSMutableArray<NSValue *> *out) {
    if (!view || !headerView)
        return;
    if ([view.accessibilityIdentifier isEqualToString:@"sparkle-profile-action-button"])
        return;
    if (view.hidden)
        return;

    UIView *titleView = objc_getAssociatedObject(headerView, kSPKProfileHeaderTitleViewKey);
    if (titleView && (view == titleView || [view isDescendantOfView:titleView])) {
        return;
    }

    // We anchor only to real controls (the More / Follow / bell buttons). Bare
    // labels (the username) and image views (the verified badge) are intentionally
    // ignored so they can never become the anchor.
    BOOL isControl = ([view isKindOfClass:[UIControl class]] ||
                      [view isKindOfClass:[UIButton class]]) &&
                     ![view isKindOfClass:[UILabel class]];

    if (isControl && view != headerView) {
        CGFloat w = CGRectGetWidth(headerView.bounds);

        // Prefer the control's tight wrapper (its superview) as the slot. On iOS 26
        // the More and Follow buttons live as alpha-crossfaded siblings inside an
        // IGNavigationBarButtonView wrapper, and IG animates THAT wrapper's frame to
        // match whichever button is active. The buttons' own alpha is unreliable
        // mid-crossfade, so anchoring to the wrapper avoids the dead-zone where no
        // button reads as visible and the action button freezes / overlaps Follow.
        UIView *slot = view;
        UIView *superview = view.superview;
        if (superview && superview != headerView) {
            CGRect superRect = [superview convertRect:superview.bounds toView:headerView];
            if (superRect.size.width > 2.0 && superRect.size.width < w * 0.40) {
                slot = superview; // tight per-button wrapper
            }
        }

        // If we couldn't fall back to a stable wrapper, ignore a control that is
        // currently invisible (the inactive crossfade button in an un-wrapped layout).
        if (slot == view && view.alpha <= 0.01) {
            return;
        }

        CGRect rect = [slot convertRect:slot.bounds toView:headerView];
        if (rect.size.width > 2.0 && rect.size.height > 2.0 &&
            CGRectIntersectsRect(headerView.bounds, rect) &&
            rect.origin.x >= (w * 0.5 + 10.0)) {
            [out addObject:[NSValue valueWithCGRect:rect]];
        }
        return; // don't descend into a control's internals
    }

    for (UIView *subview in view.subviews) {
        SPKProfileCollectTrailingControls(subview, headerView, out);
    }
}

// Resolve the anchor we place the action button to the left of: the leftmost
// control belonging to the far-right nav cluster. Controls far to the left of
// the rightmost edge (the verified badge sitting next to the username, a
// re-centered title, etc.) are rejected so the button always tracks the real
// "..." / bell trailing buttons.
static CGRect SPKProfileGetTrailingAnchorFrame(UIView *headerView) {
    if (!headerView)
        return CGRectZero;

    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    SPKProfileCollectTrailingControls(headerView, headerView, frames);
    if (frames.count == 0)
        return CGRectZero;

    CGFloat trailingEdge = -CGFLOAT_MAX;
    for (NSValue *value in frames) {
        trailingEdge = MAX(trailingEdge, CGRectGetMaxX(value.CGRectValue));
    }

    CGFloat const clusterWidth = 140.0; // room for ~3 icon buttons next to "..."
    CGRect anchor = CGRectZero;
    for (NSValue *value in frames) {
        CGRect rect = value.CGRectValue;
        if (CGRectGetMaxX(rect) < trailingEdge - clusterWidth)
            continue;
        if (CGRectIsEmpty(anchor) || rect.origin.x < anchor.origin.x) {
            anchor = rect;
        }
    }
    return anchor;
}

static CGRect SPKProfileGetAnyButtonFrame(UIView *view, UIView *headerView, CGRect currentFrame) {
    if (!view || !headerView)
        return currentFrame;
    if ([view.accessibilityIdentifier isEqualToString:@"sparkle-profile-action-button"])
        return currentFrame;
    if (view.hidden || view.alpha <= 0.01)
        return currentFrame;

    UIView *titleView = objc_getAssociatedObject(headerView, kSPKProfileHeaderTitleViewKey);
    if (titleView && (view == titleView || [view isDescendantOfView:titleView])) {
        return currentFrame;
    }

    BOOL isLeafOrControl = (view.subviews.count == 0) ||
                           [view isKindOfClass:[UIControl class]] ||
                           [view isKindOfClass:[UIButton class]] ||
                           [view isKindOfClass:[UILabel class]] ||
                           [view isKindOfClass:[UIImageView class]];

    if (isLeafOrControl && view != headerView) {
        CGRect rect = [view convertRect:view.bounds toView:headerView];
        if (rect.size.width > 2.0 && rect.size.height > 2.0 && CGRectIntersectsRect(headerView.bounds, rect)) {
            return rect;
        }
    }

    for (UIView *subview in view.subviews) {
        CGRect found = SPKProfileGetAnyButtonFrame(subview, headerView, currentFrame);
        if (!CGRectIsEmpty(found))
            return found;
    }
    return currentFrame;
}

static BOOL SPKProfileIsOwnProfile(id headerView) {
    id user = SPKProfileResolvedUserFromObject(headerView, 0);
    if (!user)
        return NO;
    NSString *profilePK = SPKProfileUserPK(user);
    NSString *currentUserPK = [SPKUtils currentUserPK];
    if (profilePK.length > 0 && currentUserPK.length > 0 && [profilePK isEqualToString:currentUserPK]) {
        return YES;
    }
    return NO;
}

// MARK: - Liquid glass background (iOS 26)

// The bubble itself, and the mirroring of IG's neighbouring one, are shared with
// the feed / inbox header buttons — see SPKChromeGlassMirror.

static void SPKProfileUpdateGlass(SPKProfileHeaderActionButton *button, UIView *headerView) {
    if (!button || button.spkGlassUnavailable)
        return;

    UIView *glassView = button.spkGlassView;
    if (!glassView) {
        glassView = SPKChromeGlassMirrorMakeBubble(@"sparkle-profile-action-glass");
        if (!glassView) {
            button.spkGlassUnavailable = YES; // iOS < 26: don't retry every layout
            return;
        }
        button.spkGlassView = glassView;
    }

    SPKChromeGlassMirrorAttach(glassView, button);

    // Adopt the bell / more bubble's own effect + ring, and fade with it.
    SPKChromeGlassMirrorSync(glassView, headerView);
}

// MARK: - Long-username overlap

static UIView *SPKProfileFindTitleView(UIView *view) {
    if ([view.accessibilityIdentifier isEqualToString:@"sparkle-profile-action-button"])
        return nil;
    if ([NSStringFromClass([view class]) containsString:@"TitleView"]) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIView *found = SPKProfileFindTitleView(subview);
        if (found)
            return found;
    }
    return nil;
}

static UILabel *SPKProfileFindUsernameLabel(UIView *view) {
    if ([view isKindOfClass:[UILabel class]] && [(UILabel *)view text].length > 0) {
        return (UILabel *)view;
    }
    for (UIView *subview in view.subviews) {
        UILabel *found = SPKProfileFindUsernameLabel(subview);
        if (found)
            return found;
    }
    return nil;
}

// Because our button is an overlay (not in IG's rightButtons array), IG sizes the
// username with no knowledge of it, so a long name runs under the button. We clamp
// the title view (and its label) so it ends before us and truncates with "...",
// mirroring IG's native behaviour when a trailing button is present. Runs after
// IG's own layout each pass, so short names are left untouched / auto-reset.
static void SPKProfileClampTitleToButton(UIView *headerView, CGFloat buttonMinX) {
    if (!headerView || buttonMinX <= 1.0)
        return;                            // no button / not positioned yet
    CGFloat limitX = buttonMinX - 8.0;     // clean gap before our button

    UIView *titleView = SPKProfileFindTitleView(headerView);
    if (!titleView)
        return;

    CGRect titleInHeader = [titleView convertRect:titleView.bounds toView:headerView];
    CGFloat titleOverflow = CGRectGetMaxX(titleInHeader) - limitX;
    if (titleOverflow > 0.0) {
        CGRect frame = titleView.frame;
        frame.size.width = MAX(0.0, frame.size.width - titleOverflow);
        titleView.frame = frame;
        titleView.clipsToBounds = YES;
    }

    UILabel *label = SPKProfileFindUsernameLabel(titleView);
    if (label) {
        CGRect labelInHeader = [label convertRect:label.bounds toView:headerView];
        CGFloat labelOverflow = CGRectGetMaxX(labelInHeader) - limitX;
        if (labelOverflow > 0.0) {
            CGRect frame = label.frame;
            frame.size.width = MAX(0.0, frame.size.width - labelOverflow);
            label.frame = frame;
            label.lineBreakMode = NSLineBreakByTruncatingTail;
        }
    }
}

// MARK: - Side column

// When the profile's navigation items sit in a side column (a narrow window
// beside a vertical tab bar), the header row has no trailing controls to sit
// beside, so the button joins the column as its own glass circle under the
// lowest of the profile's groups (the ••• menu). Returns NO when the profile's
// items are in the header row.
static const void *kSPKProfileColumnRetryKey = &kSPKProfileColumnRetryKey;

static BOOL SPKProfileDockActionButtonInColumn(UIView *headerView, SPKProfileHeaderActionButton *button) {
    UIViewController *controller = [SPKUtils nearestViewControllerForView:headerView];
    UIView *host = controller.tabBarController.view;
    if (!host || !headerView.window || host.window != headerView.window)
        return NO;
    UIViewController *owner = nil;
    for (UIViewController *current = controller; current && !owner; current = current.parentViewController) {
        if (SPKSideColumnHoldsItems(current.navigationItem))
            owner = current;
    }
    if (!owner)
        return NO;

    CGFloat alpha = 1.0;
    CGRect group = SPKSideColumnLowestGroup(owner.navigationItem, host, &alpha);
    if (CGRectIsNull(group)) {
        // The items attach to the column once a push settles, after the header's
        // last layout pass; look again then.
        [button removeFromSuperview];
        SPKSideColumnResetDock(button);
        NSInteger attempts = [objc_getAssociatedObject(headerView, kSPKProfileColumnRetryKey) integerValue];
        if (attempts >= 0 && attempts < 6) {
            // Negative marks a pending look, so layout passes in between add none.
            objc_setAssociatedObject(headerView, kSPKProfileColumnRetryKey, @(-(attempts + 1)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak UIView *weakHeader = headerView;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIView *header = weakHeader;
                if (!header)
                    return;
                objc_setAssociatedObject(header, kSPKProfileColumnRetryKey, @(attempts + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (header.window)
                    [header setNeedsLayout];
            });
        }
        return YES;
    }
    objc_setAssociatedObject(headerView, kSPKProfileColumnRetryKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!button.spkGlassView && !button.spkGlassUnavailable) {
        button.spkGlassView = SPKChromeGlassMirrorMakeBubble(@"sparkle-profile-action-glass");
        button.spkGlassUnavailable = button.spkGlassView == nil;
    }
    objc_setAssociatedObject(button, kSPKProfileLastExpectedFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!SPKSideColumnDockButton(button, button.spkGlassView, host, group, alpha)) {
        [button removeFromSuperview];
        SPKSideColumnResetDock(button);
    }
    return YES;
}

static void SPKProfilePlaceActionButton(UIView *headerView, BOOL titleIsCentered, BOOL reconfigure) {
    if (![SPKUtils getBoolPref:@"profile_action_btn"]) {
        SPKProfileHeaderActionButton *button = objc_getAssociatedObject(headerView, kSPKProfileHeaderActionButtonAssocKey);
        if (button) {
            button.hidden = YES;
            [button removeFromSuperview];
            objc_setAssociatedObject(button, kSPKProfileLastExpectedFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    BOOL ownProfile = titleIsCentered || SPKProfileIsOwnProfile(headerView);

    // Completely remove the action button from the own profile
    if (ownProfile) {
        SPKProfileHeaderActionButton *button = objc_getAssociatedObject(headerView, kSPKProfileHeaderActionButtonAssocKey);
        if (button) {
            button.hidden = YES;
            [button removeFromSuperview];
            objc_setAssociatedObject(button, kSPKProfileLastExpectedFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    // For other profiles: manual positioning on the right side
    SPKProfileHeaderActionButton *button = SPKProfileGetOrCreateActionButton(headerView);
    button.fallbackToCurrentUser = NO;

    // Rebuilding the menu/context is expensive; only do it when explicitly asked
    // (initial configure / source change) or before the button has ever been set
    // up. High-frequency triggers (layout, scroll-collapse) just reposition.
    if (reconfigure || !button.spkDidConfigure) {
        SPKConfigureProfileActionButton(button);
    }

    if (button.hidden) {
        [button removeFromSuperview];
        objc_setAssociatedObject(button, kSPKProfileLastExpectedFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (SPKProfileDockActionButtonInColumn(headerView, button))
        return;
    SPKSideColumnResetDock(button);

    if (button.superview != headerView) {
        [headerView addSubview:button];
    }

    // Keep the Liquid Glass bubble in sync with IG's buttons every layout pass.
    // Done before any early-return below so the bubble still fades while our
    // position is stable (the glass alpha changes with scroll, our frame may not).
    SPKProfileUpdateGlass(button, headerView);

    CGFloat w = CGRectGetWidth(headerView.bounds);
    CGFloat h = CGRectGetHeight(headerView.bounds);
    if (w < 60.0 || h < 20.0)
        return;

    CGFloat btnW = kSPKProfileActionButtonWidth;
    CGFloat btnH = kSPKProfileActionButtonHeight;

    CGFloat x;
    CGFloat centerY;

    // Other profiles: place on RIGHT side relative to existing buttons
    CGRect anchorFrame = SPKProfileGetTrailingAnchorFrame(headerView);
    BOOL placedFromAnchor = NO;

    if (!CGRectIsEmpty(anchorFrame)) {
        // Sit a clean 10pt gap to the left of the anchor's visual left edge. This
        // gives the same edge-to-edge spacing IG uses between its own 44pt nav
        // buttons, for both icon anchors (More/bell) and wide text anchors (Follow).
        CGFloat spacing = 10.0;
        x = anchorFrame.origin.x - spacing - btnW;
        centerY = CGRectGetMidY(anchorFrame);

        // Guard: a non-own profile's action button always belongs on the right side.
        // If the resolved anchor would drag the button into the left/center half
        // (e.g. the username re-centered in the nav bar during a scroll), reject it
        // and fall back to a clean right-edge placement instead of jumping to center.
        placedFromAnchor = (x >= w * 0.5);
    }

    NSValue *lastVal = objc_getAssociatedObject(button, kSPKProfileLastExpectedFrameKey);
    CGRect lastFrame = lastVal ? [lastVal CGRectValue] : CGRectZero;

    if (!placedFromAnchor) {
        // No trailing control resolved on the right this pass. This happens during
        // the scroll/collapse animation where the "..." button momentarily leaves
        // the header's bounds. If we've already placed the button against a real
        // anchor, keep that good frame — otherwise a transient miss would snap it
        // to the top-right fallback and stick there once layout stops firing.
        if (lastVal) {
            // Keep the good frame, but still re-clamp the title against it: IG
            // re-expands the username every layout pass, so without this the name
            // would run back under the button once we stop repositioning.
            SPKProfileClampTitleToButton(headerView, CGRectGetMinX(lastFrame));
            return;
        }
        // Beside a side column the header row has no trailing controls of its
        // own; the button waits for the column instead of taking the corner,
        // which sits under the camera there.
        UIEdgeInsets windowInsets = headerView.window.safeAreaInsets;
        if (windowInsets.right > 20.0 || windowInsets.left > 20.0) {
            [button removeFromSuperview];
            return;
        }
        CGRect anyBtnFrame = SPKProfileGetAnyButtonFrame(headerView, headerView, CGRectZero);
        if (!CGRectIsEmpty(anyBtnFrame) && CGRectGetMidX(anyBtnFrame) >= w * 0.5) {
            centerY = CGRectGetMidY(anyBtnFrame);
        } else {
            centerY = h - 22.0;
        }
        x = w - btnW - 12.0;
    }

    CGFloat y = centerY - btnH * 0.5;
    CGRect expectedFrame = CGRectMake(floor(x), floor(y), btnW, btnH);

    // Stop long usernames from running under the button (IG can't reserve space
    // for an overlay). Clamp against the button's freshly-computed target frame —
    // not its stale live frame — so truncation tracks the button in the SAME pass
    // it moves (e.g. when More morphs into the wider Follow button and back). Runs
    // before the early-return since IG re-expands the title every layout pass.
    SPKProfileClampTitleToButton(headerView, CGRectGetMinX(expectedFrame));

    if (button.superview == headerView && CGRectEqualToRect(expectedFrame, lastFrame)) {
        return; // Avoid layout churn and layout resetting mid-animation
    }

    SPKSideColumnSizeButton(button, btnW);
    button.frame = expectedFrame;
    objc_setAssociatedObject(button, kSPKProfileLastExpectedFrameKey, [NSValue valueWithCGRect:expectedFrame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [headerView bringSubviewToFront:button];
}

static void (*orig_profileHeaderConfigure)(id, SEL, id, id, id, BOOL);

static void hooked_configureProfileHeaderView(id self, SEL _cmd, id titleView, id leftButtons, id rightButtons, BOOL titleIsCentered) {
    // For own profile, inject our button into leftButtons array
    BOOL ownProfile = titleIsCentered || SPKProfileIsOwnProfile(self);

    if (ownProfile && [SPKUtils getBoolPref:@"profile_action_btn"]) {
        // Create our button as a proper UIBarButtonItem or view for injection
        SPKProfileHeaderActionButton *button = SPKProfileGetOrCreateActionButton((UIView *)self);
        button.fallbackToCurrentUser = YES;
        SPKConfigureProfileActionButton(button);

        if (!button.hidden) {
            // Inject into leftButtons array (after the + button)
            if ([leftButtons isKindOfClass:[NSArray class]]) {
                NSMutableArray *modifiedLeftButtons = [leftButtons mutableCopy];
                [modifiedLeftButtons addObject:button];
                leftButtons = [modifiedLeftButtons copy];
            } else if (leftButtons == nil) {
                leftButtons = @[ button ];
            }
        }
    }

    orig_profileHeaderConfigure(self, _cmd, titleView, leftButtons, rightButtons, titleIsCentered);

    // Save titleView so our layout scanner can ignore it and its subviews
    objc_setAssociatedObject(self, kSPKProfileHeaderTitleViewKey, titleView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Save titleIsCentered state for use in layoutSubviews
    objc_setAssociatedObject(self, kSPKProfileTitleIsCenteredKey, @(titleIsCentered), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *header = (UIView *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SPKProfilePlaceActionButton(header, titleIsCentered, YES);
    });
}

static void SPKProfileReplaceActionButtonFromHeader(id headerSelf) {
    if (![headerSelf isKindOfClass:[UIView class]])
        return;
    // Use saved titleIsCentered state from configure hook
    NSNumber *savedTitleIsCentered = objc_getAssociatedObject(headerSelf, kSPKProfileTitleIsCenteredKey);
    BOOL titleIsCentered = savedTitleIsCentered ? savedTitleIsCentered.boolValue : NO;
    SPKProfilePlaceActionButton((UIView *)headerSelf, titleIsCentered, NO);
}

static void (*orig_profileHeaderLayoutSubviews)(id, SEL);

static void hooked_profileHeaderLayoutSubviews(id self, SEL _cmd) {
    if (orig_profileHeaderLayoutSubviews)
        orig_profileHeaderLayoutSubviews(self, _cmd);
    SPKProfileReplaceActionButtonFromHeader(self);
}

// Docked in the side column the button lives outside the header, so it leaves
// with the header here and comes back on the header's next layout.
static void (*orig_profileHeaderDidMoveToWindow)(id, SEL);

static void hooked_profileHeaderDidMoveToWindow(id self, SEL _cmd) {
    if (orig_profileHeaderDidMoveToWindow)
        orig_profileHeaderDidMoveToWindow(self, _cmd);
    if ([(UIView *)self window])
        return;
    SPKProfileHeaderActionButton *button = objc_getAssociatedObject(self, kSPKProfileHeaderActionButtonAssocKey);
    if (button && button.superview && ![button isDescendantOfView:(UIView *)self]) {
        [button removeFromSuperview];
        SPKSideColumnResetDock(button);
    }
}

// The profile's items reach the side column once the screen settles, which can
// be after the header's last layout pass; place the button again then.
static Class sSPKProfileHeaderClass;
static void (*orig_profileViewDidAppear)(id, SEL, BOOL);

static void hooked_profileViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_profileViewDidAppear)
        orig_profileViewDidAppear(self, _cmd, animated);
    if (!sSPKProfileHeaderClass || ![SPKUtils getBoolPref:@"profile_action_btn"] || ![self isKindOfClass:[UIViewController class]])
        return;
    UIViewController *controller = (UIViewController *)self;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:controller.view];
    for (NSUInteger i = 0; i < queue.count && i < 200; i++) {
        if ([queue[i] isKindOfClass:sSPKProfileHeaderClass]) {
            SPKProfileReplaceActionButtonFromHeader(queue[i]);
            return;
        }
        [queue addObjectsFromArray:queue[i].subviews];
    }
}

static BOOL hooksInstalled = NO;
static BOOL retryScheduled = NO;
static NSInteger installAttempts = 0;

extern "C" void SPKInstallProfileActionButtonHooksIfEnabled(void) {
    if (![SPKUtils getBoolPref:@"profile_action_btn"])
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (hooksInstalled)
            return;

        installAttempts += 1;
        Class headerClass = objc_getClass("IGProfileNavigationSwift.IGProfileNavigationHeaderView");
        if (!headerClass)
            headerClass = objc_getClass("_TtC24IGProfileNavigationSwift29IGProfileNavigationHeaderView");
        if (!headerClass)
            headerClass = objc_getClass("IGProfileNavigationHeaderView");
        if (!headerClass) {
            SPKLog(@"ProfileBtn", @"Install target unavailable attempt=%ld", (long)installAttempts);
            if (!retryScheduled && installAttempts < kSPKProfileActionButtonMaxInstallAttempts) {
                retryScheduled = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                   @synchronized([SPKProfileHeaderActionButton class]) {
                                       retryScheduled = NO;
                                   }
                                   SPKInstallProfileActionButtonHooksIfEnabled();
                               });
            }
            return;
        }

        BOOL configureHooked = NO;
        BOOL layoutHooked = NO;
        SEL configureSelector = @selector(configureWithTitleView:leftButtons:rightButtons:titleIsCentered:);
        if ([headerClass instancesRespondToSelector:configureSelector]) {
            MSHookMessageEx(headerClass, configureSelector, (IMP)hooked_configureProfileHeaderView, (IMP *)&orig_profileHeaderConfigure);
            configureHooked = YES;
        }

        SEL layoutSelector = @selector(layoutSubviews);
        if ([headerClass instancesRespondToSelector:layoutSelector]) {
            MSHookMessageEx(headerClass, layoutSelector, (IMP)hooked_profileHeaderLayoutSubviews, (IMP *)&orig_profileHeaderLayoutSubviews);
            layoutHooked = YES;
        }

        SEL windowSelector = @selector(didMoveToWindow);
        if ([headerClass instancesRespondToSelector:windowSelector])
            MSHookMessageEx(headerClass, windowSelector, (IMP)hooked_profileHeaderDidMoveToWindow, (IMP *)&orig_profileHeaderDidMoveToWindow);

        sSPKProfileHeaderClass = headerClass;
        Class profileClass = NSClassFromString(@"IGProfileViewController");
        if (profileClass && [profileClass instancesRespondToSelector:@selector(viewDidAppear:)])
            MSHookMessageEx(profileClass, @selector(viewDidAppear:), (IMP)hooked_profileViewDidAppear, (IMP *)&orig_profileViewDidAppear);

        hooksInstalled = configureHooked || layoutHooked;
        SPKLog(@"ProfileBtn", @"Install class=%@ configure=%@ layout=%@ installed=%@",
               NSStringFromClass(headerClass),
               configureHooked ? @"YES" : @"NO",
               layoutHooked ? @"YES" : @"NO",
               hooksInstalled ? @"YES" : @"NO");
    });
}
