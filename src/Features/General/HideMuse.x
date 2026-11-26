#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../Utils.h"
#import "ExternalShareOptionHiding.h"
#import "HideMuse.h"

// Muse is Instagram's AI app (internally "Hatch"). It is region gated and its
// surfaces are Swift classes, so every hook here binds by runtime class name and
// does nothing on builds (410) or regions without it. Toggles are read at call
// time, so they apply without a restart.

static NSString *const kSPKHideMuseShareSheetKey = @"general_hide_muse_share_sheet";
static NSString *const kSPKHideMuseProfileButtonKey = @"general_hide_muse_profile_button";

static Class SPKHideMuseShareGridTargetClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = SPKResolveIGClass(@"IGExternalShareOptions.IGExternalShareHatchGridTarget", nil);
    });
    return cls;
}

static Class SPKHideMuseShareOptionsViewClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = SPKResolveIGClass(@"IGExternalShareOptions.IGExternalShareOptionsView", nil);
    });
    return cls;
}

static Class SPKHideMuseProfileItemsControllerClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = SPKResolveIGClass(@"IGProfileNavigation.IGProfileNavigationItemsController", nil);
    });
    return cls;
}

static Class SPKHideMuseBadgedButtonClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = SPKResolveIGClass(@"IGProfileNavigation.IGBadgedNavigationButton", nil);
    });
    return cls;
}

BOOL SPKHideMuseShareSheetIsAvailable(void) {
    return SPKHideMuseShareGridTargetClass() != Nil;
}

BOOL SPKHideMuseProfileButtonIsAvailable(void) {
    return SPKHideMuseProfileItemsControllerClass() != Nil &&
           [SPKHideMuseProfileItemsControllerClass() instancesRespondToSelector:NSSelectorFromString(@"onMuseButtonTapped")];
}

static BOOL SPKHideMuseShareSheetEnabled(void) {
    return [SPKUtils getBoolPref:kSPKHideMuseShareSheetKey];
}

static BOOL SPKHideMuseProfileButtonEnabled(void) {
    return [SPKUtils getBoolPref:kSPKHideMuseProfileButtonKey];
}

#pragma mark - Share sheet

// The share sheet's Muse destination. The sheet hosts it as a custom grid target
// through an ObjC protocol, so the recipient list asks it whether it belongs in
// the default list and whether it matches a search.
static BOOL (*orig_museGridTargetIsHidden)(id, SEL) = NULL;
static BOOL replaced_museGridTargetIsHidden(id self, SEL _cmd) {
    if (SPKHideMuseShareSheetEnabled()) {
        static dispatch_once_t logToken;
        dispatch_once(&logToken, ^{
            SPKLog(@"General", @"[Sparkle] Hiding muse: share sheet grid target");
        });
        return YES;
    }
    return orig_museGridTargetIsHidden(self, _cmd);
}

static BOOL (*orig_museGridTargetMatchesSearch)(id, SEL, id) = NULL;
static BOOL replaced_museGridTargetMatchesSearch(id self, SEL _cmd, id query) {
    if (SPKHideMuseShareSheetEnabled())
        return NO;
    return orig_museGridTargetMatchesSearch(self, _cmd, query);
}

// The external share row (Add to story, Muse, WhatsApp, ...). Destinations are
// matched by the analytics name Instagram logs for them, never by the label.
static BOOL SPKHideMuseIsMuseShareOption(NSString *loggingName) {
    return [loggingName isEqualToString:@"muse"] || [loggingName isEqualToString:@"hatch"] ||
           [loggingName hasPrefix:@"muse_"] || [loggingName hasPrefix:@"hatch_"];
}

static void (*orig_shareOptionsViewLayoutSubviews)(UIView *, SEL) = NULL;
static void replaced_shareOptionsViewLayoutSubviews(UIView *self, SEL _cmd) {
    orig_shareOptionsViewLayoutSubviews(self, _cmd);
    if (!SPKHideMuseShareSheetEnabled())
        return;
    NSUInteger hidden = SPKExternalShareOptionsViewCollapseMatching(self, ^BOOL(NSString *loggingName) {
        return SPKHideMuseIsMuseShareOption(loggingName);
    });
    static dispatch_once_t logToken;
    dispatch_once(&logToken, ^{
        // One line per launch with every destination name, so a report from a
        // region with Muse shows what the row actually holds.
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        SEL optionsSelector = NSSelectorFromString(@"shareOptions");
        NSArray *options = [self respondsToSelector:optionsSelector] ? ((id (*)(id, SEL))objc_msgSend)(self, optionsSelector) : nil;
        if ([options isKindOfClass:NSArray.class]) {
            for (id option in options) {
                NSString *name = SPKExternalShareOptionLoggingName(option);
                [names addObject:[NSString stringWithFormat:@"%@=%@", option, name ?: @"?"]];
            }
        }
        SPKLog(@"General", @"[Sparkle] Hiding muse: share row options [%@], hid %lu",
               [names componentsJoinedByString:@", "], (unsigned long)hidden);
    });
}

#pragma mark - Profile navigation bar

static BOOL SPKHideMuseControlTargetsMuse(UIControl *control) {
    for (id target in control.allTargets) {
        NSArray<NSString *> *actions = [control actionsForTarget:target forControlEvent:control.allControlEvents];
        for (NSString *action in actions) {
            if ([action isEqualToString:@"onMuseButtonTapped"])
                return YES;
        }
    }
    return NO;
}

// The Muse button is built with the controller's onMuseButtonTapped action, so
// it is recognized by that wiring rather than by its icon or label.
static BOOL SPKHideMuseViewIsMuseButton(UIView *view, NSUInteger depth) {
    if (!view || depth > 3)
        return NO;
    if ([view isKindOfClass:UIControl.class] && SPKHideMuseControlTargetsMuse((UIControl *)view))
        return YES;
    for (UIView *subview in view.subviews) {
        if (SPKHideMuseViewIsMuseButton(subview, depth + 1))
            return YES;
    }
    return NO;
}

static BOOL SPKHideMuseBarItemIsMuse(id item) {
    if (![item isKindOfClass:UIBarButtonItem.class])
        return NO;
    UIBarButtonItem *barItem = item;
    if (barItem.action && [NSStringFromSelector(barItem.action) isEqualToString:@"onMuseButtonTapped"])
        return YES;
    return SPKHideMuseViewIsMuseButton(barItem.customView, 0);
}

static id (*orig_profileNavGenerateBarButtonItems)(id, SEL, id, long long) = NULL;
static id replaced_profileNavGenerateBarButtonItems(id self, SEL _cmd, id items, long long placement) {
    id result = orig_profileNavGenerateBarButtonItems(self, _cmd, items, placement);
    if (!SPKHideMuseProfileButtonEnabled() || ![result isKindOfClass:NSArray.class])
        return result;
    NSArray *list = result;
    NSIndexSet *muse = [list indexesOfObjectsPassingTest:^BOOL(id item, NSUInteger idx, BOOL *stop) {
        return SPKHideMuseBarItemIsMuse(item);
    }];
    if (muse.count == 0)
        return result;
    SPKLog(@"General", @"[Sparkle] Hiding muse: profile nav button (placement %lld)", placement);
    NSMutableArray *filtered = [list mutableCopy];
    [filtered removeObjectsAtIndexes:muse];
    return [filtered copy];
}

// Fallback for a Muse button placed outside generateBarButtonItems:placement:
// (Instagram reveals it after a delay on some accounts): keep it hidden in place.
static const void *kSPKHideMuseButtonStateKey = &kSPKHideMuseButtonStateKey;

static void (*orig_badgedButtonLayoutSubviews)(UIView *, SEL) = NULL;
static void replaced_badgedButtonLayoutSubviews(UIView *self, SEL _cmd) {
    orig_badgedButtonLayoutSubviews(self, _cmd);
    NSNumber *state = objc_getAssociatedObject(self, kSPKHideMuseButtonStateKey);
    if (!SPKHideMuseProfileButtonEnabled()) {
        // Turned off while the button was hidden here: give it back.
        if (state.boolValue && self.hidden)
            self.hidden = NO;
        return;
    }
    if (!state) {
        state = @(SPKHideMuseViewIsMuseButton(self, 0));
        // Only cache once the button is wired, so an early layout pass before
        // its target is attached does not stick as "not Muse".
        BOOL wired = NO;
        for (UIView *subview in self.subviews) {
            if ([subview isKindOfClass:UIControl.class] && ((UIControl *)subview).allTargets.count > 0)
                wired = YES;
        }
        if (wired || state.boolValue)
            objc_setAssociatedObject(self, kSPKHideMuseButtonStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (state.boolValue && !self.hidden) {
        SPKLog(@"General", @"[Sparkle] Hiding muse: profile nav button view (fallback)");
        self.hidden = YES;
    }
}

#pragma mark - Install

static void SPKHideMuseHook(Class cls, NSString *selectorName, void *replacement, void **original) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!cls || !class_getInstanceMethod(cls, selector))
        return;
    MSHookMessageEx(cls, selector, (IMP)replacement, (IMP *)original);
}

void SPKInstallHideMuseHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class gridTarget = SPKHideMuseShareGridTargetClass();
        if (gridTarget) {
            SPKHideMuseHook(gridTarget, @"isHiddenFromDefaultList", (void *)replaced_museGridTargetIsHidden, (void **)&orig_museGridTargetIsHidden);
            SPKHideMuseHook(gridTarget, @"matchesSearchQuery:", (void *)replaced_museGridTargetMatchesSearch, (void **)&orig_museGridTargetMatchesSearch);
            SPKHideMuseHook(SPKHideMuseShareOptionsViewClass(), @"layoutSubviews", (void *)replaced_shareOptionsViewLayoutSubviews, (void **)&orig_shareOptionsViewLayoutSubviews);
        }
        if (SPKHideMuseProfileButtonIsAvailable()) {
            SPKHideMuseHook(SPKHideMuseProfileItemsControllerClass(), @"generateBarButtonItems:placement:", (void *)replaced_profileNavGenerateBarButtonItems, (void **)&orig_profileNavGenerateBarButtonItems);
            SPKHideMuseHook(SPKHideMuseBadgedButtonClass(), @"layoutSubviews", (void *)replaced_badgedButtonLayoutSubviews, (void **)&orig_badgedButtonLayoutSubviews);
        }
    });
}
