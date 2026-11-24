#import "ExternalShareOptionHiding.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "../../Utils.h"

NSString *SPKExternalShareOptionLoggingName(NSNumber *option) {
    static NSMutableDictionary<NSNumber *, NSString *> *cache;
    static Class helperClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
        helperClass = objc_getClass("_TtC22IGExternalShareOptions28IGExternalShareOptionsHelper");
    });
    if (![option isKindOfClass:NSNumber.class])
        return nil;
    NSString *cached = cache[option];
    if (cached)
        return cached.length ? cached : nil;

    SEL loggingSelector = NSSelectorFromString(@"externalShareOptionsLoggingString:");
    NSString *loggingName = nil;
    if ([helperClass respondsToSelector:loggingSelector]) {
        @try {
            id value = ((id (*)(id, SEL, long long))objc_msgSend)(helperClass, loggingSelector, option.longLongValue);
            loggingName = [value isKindOfClass:NSString.class] ? [(NSString *)value lowercaseString] : nil;
        } @catch (__unused NSException *exception) {
        }
    }
    cache[option] = loggingName ?: @"";
    return loggingName;
}

// Hides the button and slides the buttons after it (same container) left by
// one slot, so the row has no gap.
static void SPKCollapseExternalShareButton(UIView *button) {
    UIView *container = button.superview;
    if (!container)
        return;
    button.hidden = YES;

    UIView *next = nil;
    for (UIView *sibling in container.subviews) {
        if (sibling == button || sibling.hidden || CGRectGetMinX(sibling.frame) <= CGRectGetMinX(button.frame))
            continue;
        if (!next || CGRectGetMinX(sibling.frame) < CGRectGetMinX(next.frame))
            next = sibling;
    }
    CGFloat step = next ? CGRectGetMinX(next.frame) - CGRectGetMinX(button.frame) : 0;
    if (step <= 0)
        return;
    for (UIView *sibling in container.subviews) {
        if (sibling != button && CGRectGetMinX(sibling.frame) > CGRectGetMinX(button.frame))
            sibling.frame = CGRectOffset(sibling.frame, -step, 0);
    }
    if ([container isKindOfClass:UIScrollView.class]) {
        UIScrollView *scrollView = (UIScrollView *)container;
        CGSize size = scrollView.contentSize;
        size.width = MAX(CGRectGetWidth(scrollView.bounds), size.width - step);
        scrollView.contentSize = size;
    }
}

NSUInteger SPKExternalShareOptionsViewCollapseMatching(UIView *view, BOOL (^matches)(NSString *loggingName)) {
    SEL optionsSelector = NSSelectorFromString(@"shareOptions");
    if (!view || !matches || ![view respondsToSelector:optionsSelector])
        return 0;
    NSArray *options = ((id (*)(id, SEL))objc_msgSend)(view, optionsSelector);
    if (![options isKindOfClass:NSArray.class])
        return 0;
    NSIndexSet *matching = [options indexesOfObjectsPassingTest:^BOOL(id option, NSUInteger idx, BOOL *stop) {
        NSString *name = SPKExternalShareOptionLoggingName(option);
        return name.length > 0 && matches(name);
    }];
    if (matching.count == 0)
        return 0;

    // Swift [UIView] storage bridges as an NSArray. Only trust it when it lines
    // up one to one with the options, so a layout change can never hide the
    // wrong destination. The option list itself is left untouched: the buttons
    // are built once at init, and taps map back through that list.
    id buttons = [SPKUtils getIvarForObj:view name:"buttons"];
    if (![buttons isKindOfClass:NSArray.class] || [(NSArray *)buttons count] != options.count) {
        static dispatch_once_t mismatchToken;
        dispatch_once(&mismatchToken, ^{
            SPKLog(@"General", @"[Sparkle] Share sheet row: buttons %@ (%lu) do not match %lu options, skipping",
                   buttons ? NSStringFromClass([buttons class]) : @"nil",
                   [buttons respondsToSelector:@selector(count)] ? (unsigned long)[(NSArray *)buttons count] : 0UL,
                   (unsigned long)options.count);
        });
        return 0;
    }
    __block NSUInteger hidden = 0;
    [matching enumerateIndexesWithOptions:NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *stop) {
        UIView *button = [(NSArray *)buttons objectAtIndex:idx];
        if ([button isKindOfClass:UIView.class]) {
            SPKCollapseExternalShareButton(button);
            hidden++;
        }
    }];
    return hidden;
}
