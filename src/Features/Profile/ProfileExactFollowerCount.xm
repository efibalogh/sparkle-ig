#import "../../Utils.h"
#import <objc/runtime.h>

// Replaces Instagram's abbreviated follower count on the profile header
// ("20.5K") with the exact value ("20,574"). The stat container is a Swift view
// that hands its buttons already formatted counts, so the exact value is written
// into the followers button's count label.

static BOOL SPKExactFollowerCountEnabled(void) {
    return [SPKUtils getBoolPref:@"profile_exact_follower_count"];
}

static id SPKExactCountIvarObject(id object, const char *name) {
    if (!object)
        return nil;
    Ivar ivar = NULL;
    for (Class cls = object_getClass(object); cls && !ivar; cls = class_getSuperclass(cls))
        ivar = class_getInstanceVariable(cls, name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static NSNumber *SPKExactCountNumber(id value) {
    if ([value isKindOfClass:[NSNumber class]])
        return value;
    if ([value respondsToSelector:@selector(longLongValue)] && ![value isKindOfClass:[NSString class]])
        return @([value longLongValue]);
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0)
        return @([(NSString *)value longLongValue]);
    return nil;
}

// The typed property can be unset on a partially hydrated user, while the raw
// API dictionary still carries the count.
static NSNumber *SPKExactFollowerCountForUser(id user) {
    if (!user)
        return nil;
    NSNumber *count = nil;
    @try {
        count = SPKExactCountNumber([user valueForKey:@"followerCount"]);
    } @catch (__unused NSException *exception) {
    }
    if (!count) {
        NSDictionary *fieldCache = SPKExactCountIvarObject(user, "_fieldCache");
        if ([fieldCache isKindOfClass:[NSDictionary class]])
            count = SPKExactCountNumber(fieldCache[@"follower_count"]);
    }
    return count.longLongValue >= 0 ? count : nil;
}

static NSString *SPKExactCountText(NSNumber *count) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSNumberFormatter new];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.usesGroupingSeparator = YES;
    });
    formatter.locale = [NSLocale autoupdatingCurrentLocale];
    return count ? [formatter stringFromNumber:count] : nil;
}

static Class SPKStatContainerClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = objc_getClass("_TtC23IGProfileHeaderIdentity38IGProfileHeaderStatButtonContainerView");
    });
    return cls;
}

// Writes the exact count into the followers label. Returns YES when the text
// changed, so the caller can get the buttons re-measured against it.
static BOOL SPKApplyExactFollowerCount(UIView *container) {
    if (!SPKExactFollowerCountEnabled())
        return NO;
    UIViewController *controller = [SPKUtils nearestViewControllerForView:container];
    if (![controller isKindOfClass:NSClassFromString(@"IGProfileViewController")])
        return NO;

    UIView *button = SPKExactCountIvarObject(container, "$__lazy_storage_$_followersButton");
    UILabel *label = SPKExactCountIvarObject(button, "_countLabel");
    if (![label isKindOfClass:[UILabel class]])
        return NO;
    // Loading and hidden placeholders carry no digits; leave those to Instagram.
    if ([label.text rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location == NSNotFound)
        return NO;

    NSString *text = SPKExactCountText(SPKExactFollowerCountForUser([(IGProfileViewController *)controller user]));
    if (text.length == 0 || [label.text isEqualToString:text])
        return NO;

    label.text = text;
    [button invalidateIntrinsicContentSize];
    return YES;
}

static UIView *SPKStatContainerForButton(UIView *button) {
    Class containerClass = SPKStatContainerClass();
    UIView *view = button.superview;
    for (NSUInteger depth = 0; view && depth < 3; depth++, view = view.superview) {
        if ([view isKindOfClass:containerClass])
            return view;
    }
    return nil;
}

%group SPKProfileExactFollowerCountHooks

// The container sizes each button from its label text, so the exact count has
// to be in place before it measures. A late swap leaves the long number in a
// frame sized for "286M", and the label shrinks its font to fit.
%hook IGStatButton
- (void)setCount:(id)count {
    %orig;
    if (!SPKExactFollowerCountEnabled())
        return;
    UIView *container = SPKStatContainerForButton((UIView *)self);
    if (container && SPKApplyExactFollowerCount(container))
        [container setNeedsLayout];
}
%end

// Fallback for counts set before the header joined the profile hierarchy: the
// swap happens here, then one more pass measures the buttons against it.
%hook _TtC23IGProfileHeaderIdentity38IGProfileHeaderStatButtonContainerView
- (void)layoutSubviews {
    %orig;
    if (SPKApplyExactFollowerCount((UIView *)self))
        [(UIView *)self setNeedsLayout];
}
%end

%end

extern "C" void SPKInstallProfileExactFollowerCountHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!SPKStatContainerClass() || !objc_getClass("IGStatButton"))
            return;
        %init(SPKProfileExactFollowerCountHooks);
    });
}
