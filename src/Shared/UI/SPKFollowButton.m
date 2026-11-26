#import "SPKFollowButton.h"

#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import "SPKStrings.h"

#import <objc/runtime.h>
#import "SPKFont.h"

// Instagram's own ordinals, device-verified identical on 410.1.0 and 444.0.0:
// 0 none, 1 loading, 2 follow, 3 following, 4 requested, 5 user not found,
// 6 follow back, 7 unblock. Class-dump output omits enumerations, so re-deriving
// them after an Instagram release means walking buttonState on a throwaway
// control and reading back its titleLabel. A wrong ordinal only mis-renders the
// control, so a shifted ladder shows the wrong label rather than misbehaving.
static long long const kSPKNativeStateLoading = 1;
static long long const kSPKNativeStateNotFollowing = 2;
static long long const kSPKNativeStateFollowing = 3;
static long long const kSPKNativeStateRequested = 4;
static long long const kSPKNativeStateFollowBack = 6;

static CGFloat const kSPKFollowButtonMinimumWidth = 88.0;
static CGFloat const kSPKFollowButtonHeight = 32.0;
static CGFloat const kSPKFollowButtonCornerRadius = 8.0;

static const void *kSPKFollowButtonIsNativeKey = &kSPKFollowButtonIsNativeKey;
static const void *kSPKFollowButtonStateKey = &kSPKFollowButtonStateKey;

// MARK: - Sparkle stand-in

/// Used when Instagram's control cannot be resolved. Owns its spinner so both
/// paths present an in-flight state the same way from the caller's side.
@interface SPKFollowButtonFallback : UIButton
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation SPKFollowButtonFallback

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleFootnote weight:UIFontWeightBold] to:self.titleLabel];
        self.layer.cornerRadius = kSPKFollowButtonCornerRadius;
        self.clipsToBounds = YES;

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.hidesWhenStopped = YES;
        _spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_spinner];

        [NSLayoutConstraint activateConstraints:@[
            [_spinner.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_spinner.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    // UIButtonTypeCustom does not dim on touch the way the system type does.
    self.alpha = highlighted ? 0.6 : 1.0;
}

- (CGSize)intrinsicContentSize {
    // Carries its own metrics so callers can drop it in wherever Instagram's
    // control goes, including cells that pin no explicit size.
    CGSize size = [super intrinsicContentSize];
    size.width = MAX(size.width + 28.0, kSPKFollowButtonMinimumWidth);
    size.height = MAX(size.height + 12.0, kSPKFollowButtonHeight);
    return size;
}

@end

// MARK: - Runtime resolution

static Class SPKNativeFollowButtonClass(void) {
    static Class buttonClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Plain Objective-C on older builds; a Swift class in its own module on
        // newer ones, where the runtime name is mangled.
        for (NSString *name in @[ @"IGFollowButton", @"_TtC14IGFollowButton14IGFollowButton" ]) {
            Class candidate = NSClassFromString(name);
            if (candidate && [candidate instancesRespondToSelector:@selector(setViewConfiguration:)]) {
                buttonClass = candidate;
                break;
            }
        }
    });
    return buttonClass;
}

static id SPKNativeFollowButtonConfiguration(void) {
    Class configurationClass = NSClassFromString(@"IGFollowButtonViewConfiguration");
    if (![configurationClass respondsToSelector:@selector(defaultButtonConfiguration)])
        return nil;
    @try {
        return [configurationClass defaultButtonConfiguration];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// MARK: - State mapping

static long long SPKNativeStateForState(SPKFollowButtonState state) {
    switch (state) {
        case SPKFollowButtonStateFollowing:
            return kSPKNativeStateFollowing;
        case SPKFollowButtonStateRequested:
            return kSPKNativeStateRequested;
        case SPKFollowButtonStateFollowBack:
            return kSPKNativeStateFollowBack;
        case SPKFollowButtonStateNotFollowing:
            break;
    }
    return kSPKNativeStateNotFollowing;
}

static NSString *SPKFallbackTitleForState(SPKFollowButtonState state) {
    switch (state) {
        case SPKFollowButtonStateFollowing:
            return SPKL(@"MENU_FOLLOWING");
        case SPKFollowButtonStateRequested:
            return SPKL(@"COMMON_FOLLOW_BUTTON_REQUESTED");
        case SPKFollowButtonStateFollowBack:
            return SPKL(@"COMMON_FOLLOW_BUTTON_FOLLOW_BACK");
        case SPKFollowButtonStateNotFollowing:
            break;
    }
    return SPKL(@"VC_BTN_FOLLOW");
}

// MARK: - Public API

@implementation SPKFollowButton

+ (UIControl *)button {
    Class buttonClass = SPKNativeFollowButtonClass();
    id configuration = buttonClass ? SPKNativeFollowButtonConfiguration() : nil;

    if (buttonClass && configuration) {
        UIControl *native = nil;
        @try {
            native = (UIControl *)[(id<SPKIGFollowButtonConforming>)[buttonClass alloc] initWithViewConfiguration:configuration];
        } @catch (__unused NSException *exception) {
            native = nil;
        }

        if ([native isKindOfClass:UIControl.class]) {
            native.translatesAutoresizingMaskIntoConstraints = NO;
            id<SPKIGFollowButtonConforming> conforming = (id<SPKIGFollowButtonConforming>)native;
            if ([native respondsToSelector:@selector(setMinimumWidth:)])
                conforming.minimumWidth = kSPKFollowButtonMinimumWidth;
            objc_setAssociatedObject(native, kSPKFollowButtonIsNativeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return native;
        }
    }

    SPKFollowButtonFallback *fallback = [[SPKFollowButtonFallback alloc] initWithFrame:CGRectZero];
    fallback.translatesAutoresizingMaskIntoConstraints = NO;
    return fallback;
}

+ (BOOL)isNativeButton:(UIControl *)button {
    return [objc_getAssociatedObject(button, kSPKFollowButtonIsNativeKey) boolValue];
}

+ (void)applyState:(SPKFollowButtonState)state toButton:(UIControl *)button {
    if (!button)
        return;

    objc_setAssociatedObject(button, kSPKFollowButtonStateKey, @(state), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([self isNativeButton:button]) {
        id<SPKIGFollowButtonConforming> native = (id<SPKIGFollowButtonConforming>)button;
        native.buttonState = SPKNativeStateForState(state);
        return;
    }

    if (![button isKindOfClass:SPKFollowButtonFallback.class])
        return;
    SPKFollowButtonFallback *fallback = (SPKFollowButtonFallback *)button;

    // Following and Requested are both settled relationships, so they take the
    // quiet treatment; the two calls to action stay prominent.
    BOOL prominent = (state == SPKFollowButtonStateNotFollowing || state == SPKFollowButtonStateFollowBack);
    [fallback setTitle:SPKFallbackTitleForState(state) forState:UIControlStateNormal];
    [fallback setTitleColor:prominent ? UIColor.whiteColor : [SPKUtils SPKColor_InstagramPrimaryText]
                  forState:UIControlStateNormal];
    fallback.backgroundColor = prominent ? ([SPKUtils SPKColor_InstagramBlue] ?: UIColor.systemBlueColor)
                                         : [SPKUtils SPKColor_InstagramSecondaryBackground];
    fallback.layer.borderWidth = 0.0;
    [fallback invalidateIntrinsicContentSize];
}

+ (SPKFollowButtonState)stateForFriendshipStatus:(NSDictionary *)status {
    if (![status isKindOfClass:NSDictionary.class])
        return SPKFollowButtonStateNotFollowing;
    if ([status[@"following"] boolValue])
        return SPKFollowButtonStateFollowing;
    if ([status[@"outgoing_request"] boolValue])
        return SPKFollowButtonStateRequested;
    if ([status[@"followed_by"] boolValue])
        return SPKFollowButtonStateFollowBack;
    return SPKFollowButtonStateNotFollowing;
}

+ (BOOL)tapUnfollowsFromState:(SPKFollowButtonState)state {
    return state == SPKFollowButtonStateFollowing || state == SPKFollowButtonStateRequested;
}

+ (void)setLoading:(BOOL)loading forButton:(UIControl *)button {
    if (!button)
        return;

    button.userInteractionEnabled = !loading;

    if (!loading) {
        // Both paths come back the same way: repaint the resting state that
        // applyState: recorded, so nothing has to stash a title of its own.
        if ([button isKindOfClass:SPKFollowButtonFallback.class])
            [((SPKFollowButtonFallback *)button).spinner stopAnimating];
        NSNumber *resting = objc_getAssociatedObject(button, kSPKFollowButtonStateKey);
        [self applyState:(SPKFollowButtonState)resting.integerValue toButton:button];
        return;
    }

    if ([self isNativeButton:button]) {
        // Instagram models the in-flight request as a button state of its own, so
        // use that rather than layering a spinner over its title.
        ((id<SPKIGFollowButtonConforming>)button).buttonState = kSPKNativeStateLoading;
        return;
    }

    if (![button isKindOfClass:SPKFollowButtonFallback.class])
        return;
    SPKFollowButtonFallback *fallback = (SPKFollowButtonFallback *)button;
    [fallback setTitle:@"" forState:UIControlStateNormal];
    [fallback.spinner startAnimating];
}

@end
