#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// Profile suggestions ("similar accounts") sit behind a button in the profile
// action bar: action 3 in the action bar view model, on 410 and current builds.
// Instagram also opens the panel on its own, either from the user's
// autoExpandChaining flag or by selecting the button as the profile loads.
//
// Always Show Suggestions Button adds action 3 to every profile, your own included.
// Hide Profile Suggestions keeps the panel closed until that button is tapped.
// With the button off as well, action 3 is removed so nothing is left behind.

static NSString *const kSPKProfileSuggestionsButtonKey = @"profile_force_suggestions_button";
static NSString *const kSPKProfileSuggestionsHideKey = @"general_hide_suggested_users_profile";

// A tap on the button arrives as a toggle request right after it; anything older
// is Instagram expanding on its own, for example after a follow.
static const CFTimeInterval kSPKProfileSuggestionsTapWindow = 1.5;

static CFTimeInterval sSPKLastSuggestionsTap = 0;
static const void *kSPKProfileSuggestionsRevealedKey = &kSPKProfileSuggestionsRevealedKey;
static const void *kSPKProfileSuggestionsPanelVisibleKey = &kSPKProfileSuggestionsPanelVisibleKey;
static const void *kSPKProfileSuggestionsDismissedKey = &kSPKProfileSuggestionsDismissedKey;
static const void *kSPKProfileSuggestionsAdapterKey = &kSPKProfileSuggestionsAdapterKey;
static __weak UIView *sSPKLastTappedSuggestionsHeader;

static BOOL SPKProfileSuggestionsButtonEnabled(void) {
    return [SPKUtils getBoolPref:kSPKProfileSuggestionsButtonKey];
}

static BOOL SPKProfileSuggestionsHidden(void) {
    return [SPKUtils getBoolPref:kSPKProfileSuggestionsHideKey];
}

static BOOL SPKProfileSuggestionsRecentTap(void) {
    return sSPKLastSuggestionsTap > 0 && CACurrentMediaTime() - sSPKLastSuggestionsTap < kSPKProfileSuggestionsTapWindow;
}

static BOOL SPKProfileSuggestionsActionBarSelected(id view) {
    @try {
        return [[view valueForKey:@"chainingSelected"] boolValue];
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

// The chaining model carries no usable profile identity, so the revealed state
// lives on the profile header view that hosts both the button and the panel.
static UIView *SPKProfileSuggestionsHeaderForView(UIView *view) {
    Class headerClass = SPKResolveIGClass(@"IGProfileHeader.IGProfileHeaderView", @"IGProfileHeaderView");
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if (headerClass && [candidate isKindOfClass:headerClass])
            return candidate;
    }
    return nil;
}

// Opening marks the header as revealed; closing clears it, so a later automatic
// expansion on the same profile is collapsed again.
static void SPKProfileSuggestionsRecordTap(id view) {
    UIView *header = [view isKindOfClass:[UIView class]] ? SPKProfileSuggestionsHeaderForView(view) : nil;
    // Instagram can open the panel before an added button exists, leaving the
    // button unselected over an open panel, so its tap would ask to open again.
    // Mark it selected first so the tap closes the panel instead.
    BOOL panelVisible = header && [objc_getAssociatedObject(header, kSPKProfileSuggestionsPanelVisibleKey) boolValue];
    if (panelVisible && !SPKProfileSuggestionsActionBarSelected(view)) {
        @try {
            [view setValue:@YES forKey:@"chainingSelected"];
        } @catch (__unused NSException *exception) {
        }
    }
    BOOL closing = SPKProfileSuggestionsActionBarSelected(view);
    sSPKLastSuggestionsTap = closing ? 0 : CACurrentMediaTime();
    sSPKLastTappedSuggestionsHeader = header;
    if (header) {
        objc_setAssociatedObject(header, kSPKProfileSuggestionsRevealedKey, closing ? nil : @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!closing)
            objc_setAssociatedObject(header, kSPKProfileSuggestionsDismissedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Instagram only closes a panel it opened through its own toggle. A panel that
// arrived already expanded ignores the close request, so it is removed here.
static void SPKProfileSuggestionsDismissPanel(UIView *header) {
    if (!header || ![objc_getAssociatedObject(header, kSPKProfileSuggestionsPanelVisibleKey) boolValue])
        return;
    objc_setAssociatedObject(header, kSPKProfileSuggestionsDismissedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id adapter = objc_getAssociatedObject(header, kSPKProfileSuggestionsAdapterKey);
    if ([adapter respondsToSelector:@selector(performUpdatesAnimated:completion:)])
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(adapter, @selector(performUpdatesAnimated:completion:), NO, nil);
}

// Called from the profile header filter, which is where the panel is actually
// kept closed: Instagram builds the chaining model whenever it decides to expand.
FOUNDATION_EXPORT BOOL SPKProfileSuggestionsShouldDropChainingModel(id header, id model) {
    if (!SPKProfileSuggestionsHidden())
        return NO;
    if (!SPKProfileSuggestionsButtonEnabled())
        return YES;

    // Only suggestions opened from the button survive; Instagram's own expansion
    // does not always mark the model as auto-expanded.
    BOOL revealed = header && [objc_getAssociatedObject(header, kSPKProfileSuggestionsRevealedKey) boolValue];
    return !revealed && !SPKProfileSuggestionsRecentTap();
}

#pragma mark - Panel tracking

static void (*orig_ActionBarController_setChainingSelected)(id, SEL, BOOL, id, long long);

static UIView *SPKProfileSuggestionsFindActionBar(UIView *root, Class actionBarClass) {
    if ([root isKindOfClass:actionBarClass])
        return root;
    for (UIView *subview in root.subviews) {
        UIView *found = SPKProfileSuggestionsFindActionBar(subview, actionBarClass);
        if (found)
            return found;
    }
    return nil;
}

// A panel that arrives already expanded leaves the button unselected, so its icon
// stays outlined. Select it to match what is on screen. The action bar cell can
// be laid out after the header objects, so one late retry covers that.
static void SPKProfileSuggestionsSyncButton(UIView *header, NSInteger attempt) {
    Class actionBarClass = SPKResolveIGClass(@"IGProfileActionBar.IGProfileActionBarView", @"IGProfileActionBarView");
    if (!header || !actionBarClass || ![objc_getAssociatedObject(header, kSPKProfileSuggestionsPanelVisibleKey) boolValue])
        return;
    UIView *actionBar = SPKProfileSuggestionsFindActionBar(header, actionBarClass);
    if (!actionBar) {
        if (attempt == 0) {
            __weak UIView *weakHeader = header;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SPKProfileSuggestionsSyncButton(weakHeader, 1);
            });
        }
        return;
    }
    if (SPKProfileSuggestionsActionBarSelected(actionBar))
        return;
    // The icon only follows the controller's selection path; setting the view's
    // property stores the state without redrawing it.
    id controller = nil;
    @try {
        controller = [actionBar valueForKey:@"delegate"];
    } @catch (__unused NSException *exception) {
    }
    if (orig_ActionBarController_setChainingSelected && [controller respondsToSelector:@selector(setChainingSelected:forActionBarView:fromUserAction:)])
        orig_ActionBarController_setChainingSelected(controller, @selector(setChainingSelected:forActionBarView:fromUserAction:), YES, actionBar, 6);
}

// Records whether the header is currently showing the suggestions panel. Runs
// outside the hide filter, so it sees what is actually displayed.
static id (*orig_ProfileHeader_objectsForListAdapter)(id, SEL, id);
static id hook_ProfileHeader_objectsForListAdapter(id self, SEL _cmd, id adapter) {
    id objects = orig_ProfileHeader_objectsForListAdapter(self, _cmd, adapter);
    if (adapter)
        objc_setAssociatedObject(self, kSPKProfileSuggestionsAdapterKey, adapter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Class chainingClass = objc_getClass("IGProfileChainingModel");
    BOOL dismissed = [objc_getAssociatedObject(self, kSPKProfileSuggestionsDismissedKey) boolValue];
    BOOL visible = NO;
    if (chainingClass && [objects isKindOfClass:[NSArray class]]) {
        NSMutableArray *kept = dismissed ? [NSMutableArray arrayWithCapacity:[objects count]] : nil;
        for (id object in (NSArray *)objects) {
            if ([object isKindOfClass:chainingClass]) {
                if (dismissed)
                    continue;
                visible = YES;
            }
            [kept addObject:object];
        }
        if (dismissed)
            objects = [kept copy];
    }
    BOOL wasVisible = [objc_getAssociatedObject(self, kSPKProfileSuggestionsPanelVisibleKey) boolValue];
    objc_setAssociatedObject(self, kSPKProfileSuggestionsPanelVisibleKey, visible ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (visible && !wasVisible && [self isKindOfClass:[UIView class]]) {
        __weak UIView *weakHeader = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKProfileSuggestionsSyncButton(weakHeader, 0);
        });
    }
    return objects;
}

#pragma mark - User flags

// Builds without the action bar view model edit (410) show the button from
// hasChaining, and treat any set value of these flags as server data, so an unset
// flag has to stay unset unless the button is meant to change.
static id (*orig_IGBaseUser_hasChaining)(id, SEL);
static id hook_IGBaseUser_hasChaining(id self, SEL _cmd) {
    id original = orig_IGBaseUser_hasChaining(self, _cmd);
    if (SPKProfileSuggestionsButtonEnabled())
        return @YES;
    if (SPKProfileSuggestionsHidden())
        return @NO;
    return original;
}

static id (*orig_IGBaseUser_autoExpandChaining)(id, SEL);
static id hook_IGBaseUser_autoExpandChaining(id self, SEL _cmd) {
    id original = orig_IGBaseUser_autoExpandChaining(self, _cmd);
    if (SPKProfileSuggestionsHidden() && [original respondsToSelector:@selector(boolValue)] && [original boolValue])
        return @NO;
    return original;
}

#pragma mark - Button taps

static void (*orig_ActionBarView_didTapSuggestedUsers)(id, SEL);
static void hook_ActionBarView_didTapSuggestedUsers(id self, SEL _cmd) {
    SPKProfileSuggestionsRecordTap(self);
    orig_ActionBarView_didTapSuggestedUsers(self, _cmd);
}

static void (*orig_ActionBarView_didTapSuggestedUsersLegacy)(id, SEL, id);
static void hook_ActionBarView_didTapSuggestedUsersLegacy(id self, SEL _cmd, id sender) {
    SPKProfileSuggestionsRecordTap(self);
    orig_ActionBarView_didTapSuggestedUsersLegacy(self, _cmd, sender);
}

#pragma mark - Expansion requests

static void hook_ActionBarController_setChainingSelected(id self, SEL _cmd, BOOL selected, id view, long long action) {
    if (selected && SPKProfileSuggestionsHidden() && !SPKProfileSuggestionsRecentTap()) {
        SPKLog(@"ProfileSuggestions", @"Blocked automatic chaining select (action %lld)", action);
        return;
    }
    orig_ActionBarController_setChainingSelected(self, _cmd, selected, view, action);
}

static void (*orig_ProfileVC_wantsToggleUserChaining)(id, SEL, id, BOOL, long long);
static void hook_ProfileVC_wantsToggleUserChaining(id self, SEL _cmd, id controller, BOOL chaining, long long action) {
    if (chaining && SPKProfileSuggestionsHidden() && !SPKProfileSuggestionsRecentTap()) {
        SPKLog(@"ProfileSuggestions", @"Blocked automatic chaining expand (action %lld)", action);
        return;
    }
    orig_ProfileVC_wantsToggleUserChaining(self, _cmd, controller, chaining, action);
    if (!chaining && SPKProfileSuggestionsRecentTap() == NO) {
        UIView *header = sSPKLastTappedSuggestionsHeader;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKProfileSuggestionsDismissPanel(header);
        });
    }
}

#pragma mark - Action bar

static NSNumber *SPKProfileSuggestionsAction(void) {
    return @3;
}

static NSOrderedSet *SPKProfileSuggestionsWithoutAction(NSOrderedSet *set) {
    if (![set isKindOfClass:[NSOrderedSet class]] || ![set containsObject:SPKProfileSuggestionsAction()])
        return set;
    NSMutableOrderedSet *copy = [set mutableCopy];
    [copy removeObject:SPKProfileSuggestionsAction()];
    return [copy copy];
}

static NSOrderedSet *SPKProfileSuggestionsWithAction(NSOrderedSet *set) {
    if (![set isKindOfClass:[NSOrderedSet class]] || [set containsObject:SPKProfileSuggestionsAction()])
        return set;
    NSMutableOrderedSet *copy = [set mutableCopy];
    [copy addObject:SPKProfileSuggestionsAction()];
    return [copy copy];
}

// Rewrites the action bar inputs in place. Instagram lays the suggestions button
// out as a trailing icon, so it is appended to the last row.
static void SPKProfileSuggestionsAdjustActions(id *rows, id *all, id *overflow, id user) {
    BOOL show = SPKProfileSuggestionsButtonEnabled();
    BOOL removeAll = !show && SPKProfileSuggestionsHidden();
    if (!show && !removeAll)
        return;
    if (![*rows isKindOfClass:[NSArray class]] || ![*all isKindOfClass:[NSOrderedSet class]])
        return;

    if (removeAll) {
        NSMutableArray *newRows = [NSMutableArray arrayWithCapacity:[*rows count]];
        for (id row in *rows)
            [newRows addObject:SPKProfileSuggestionsWithoutAction(row)];
        *rows = [newRows copy];
        *all = SPKProfileSuggestionsWithoutAction(*all);
        *overflow = SPKProfileSuggestionsWithoutAction(*overflow);
        return;
    }

    if ([*all containsObject:SPKProfileSuggestionsAction()] || [*overflow containsObject:SPKProfileSuggestionsAction()])
        return;
    if (![*rows count])
        return;
    NSMutableArray *newRows = [*rows mutableCopy];
    newRows[newRows.count - 1] = SPKProfileSuggestionsWithAction(newRows.lastObject);
    *rows = [newRows copy];
    *all = SPKProfileSuggestionsWithAction(*all);
}

static id (*orig_ABVM_init454)(id, SEL, id, id, id, id, id, id, id, id, id, id, id, BOOL);
static id hook_ABVM_init454(id self, SEL _cmd, id ident, id rows, id all, id overflow, id badges, id biz, id bizOverflow, id contact, id user, id sponsored, id color, BOOL tools) {
    SPKProfileSuggestionsAdjustActions(&rows, &all, &overflow, user);
    return orig_ABVM_init454(self, _cmd, ident, rows, all, overflow, badges, biz, bizOverflow, contact, user, sponsored, color, tools);
}

static id (*orig_ABVM_init453)(id, SEL, id, id, id, id, id, id, id, id, id, id, id, long long);
static id hook_ABVM_init453(id self, SEL _cmd, id ident, id rows, id all, id overflow, id badges, id biz, id bizOverflow, id contact, id user, id sponsored, id color, long long variant) {
    SPKProfileSuggestionsAdjustActions(&rows, &all, &overflow, user);
    return orig_ABVM_init453(self, _cmd, ident, rows, all, overflow, badges, biz, bizOverflow, contact, user, sponsored, color, variant);
}

static id (*orig_ABVM_init410)(id, SEL, id, id, id, id, id, id, id, id, id, id, id, id);
static id hook_ABVM_init410(id self, SEL _cmd, id ident, id rows, id all, id overflow, id badges, id biz, id bizOverflow, id contact, id user, id fanClubText, id sponsored, id color) {
    SPKProfileSuggestionsAdjustActions(&rows, &all, &overflow, user);
    return orig_ABVM_init410(self, _cmd, ident, rows, all, overflow, badges, biz, bizOverflow, contact, user, fanClubText, sponsored, color);
}

#pragma mark - Install

static void SPKProfileSuggestionsHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !class_getInstanceMethod(cls, selector)) {
        SPKLog(@"ProfileSuggestions", @"Missing -[%@ %@]", cls ? NSStringFromClass(cls) : @"(nil)", NSStringFromSelector(selector));
        return;
    }
    MSHookMessageEx(cls, selector, replacement, original);
}

void SPKInstallProfileSuggestionsButtonHooksIfEnabled(void) {
    if (!SPKProfileSuggestionsButtonEnabled() && !SPKProfileSuggestionsHidden())
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKProfileSuggestionsHook(objc_getClass("IGBaseUser"), @selector(hasChaining), (IMP)hook_IGBaseUser_hasChaining, (IMP *)&orig_IGBaseUser_hasChaining);
        SPKProfileSuggestionsHook(objc_getClass("IGBaseUser"), @selector(autoExpandChaining), (IMP)hook_IGBaseUser_autoExpandChaining, (IMP *)&orig_IGBaseUser_autoExpandChaining);

        SPKProfileSuggestionsHook(SPKResolveIGClass(@"IGProfileHeader.IGProfileHeaderView", @"IGProfileHeaderView"), @selector(objectsForListAdapter:),
                                  (IMP)hook_ProfileHeader_objectsForListAdapter, (IMP *)&orig_ProfileHeader_objectsForListAdapter);

        Class actionBarView = SPKResolveIGClass(@"IGProfileActionBar.IGProfileActionBarView", @"IGProfileActionBarView");
        if (class_getInstanceMethod(actionBarView, @selector(didTapSuggestedUsers)))
            SPKProfileSuggestionsHook(actionBarView, @selector(didTapSuggestedUsers), (IMP)hook_ActionBarView_didTapSuggestedUsers, (IMP *)&orig_ActionBarView_didTapSuggestedUsers);
        else
            SPKProfileSuggestionsHook(actionBarView, @selector(_didTapSuggestedUsers:), (IMP)hook_ActionBarView_didTapSuggestedUsersLegacy, (IMP *)&orig_ActionBarView_didTapSuggestedUsersLegacy);

        Class actionBarController = SPKResolveIGClass(@"IGProfileActionBar.IGProfileActionBarController", @"IGProfileActionBarController");
        SPKProfileSuggestionsHook(actionBarController, @selector(setChainingSelected:forActionBarView:fromUserAction:),
                                  (IMP)hook_ActionBarController_setChainingSelected, (IMP *)&orig_ActionBarController_setChainingSelected);

        Class abvm = objc_getClass("IGProfileActionBarViewModel");
        SEL init454 = NSSelectorFromString(@"initWithIdentifier:rows:allActionsToDisplay:overflowActions:actionToBadgeInfoMap:allBusinessActions:overflowBusinessActions:contactSheetActions:user:sponsoredInfoProvider:profileBackgroundColor:isYourToolsEnabled:");
        SEL init453 = NSSelectorFromString(@"initWithIdentifier:rows:allActionsToDisplay:overflowActions:actionToBadgeInfoMap:allBusinessActions:overflowBusinessActions:contactSheetActions:user:sponsoredInfoProvider:profileBackgroundColor:buttonSwapVariant:");
        SEL init410 = NSSelectorFromString(@"initWithIdentifier:rows:allActionsToDisplay:overflowActions:actionToBadgeInfoMap:allBusinessActions:overflowBusinessActions:contactSheetActions:user:fanClubProfileButtonText:sponsoredInfoProvider:profileBackgroundColor:");
        if (class_getInstanceMethod(abvm, init454))
            SPKProfileSuggestionsHook(abvm, init454, (IMP)hook_ABVM_init454, (IMP *)&orig_ABVM_init454);
        else if (class_getInstanceMethod(abvm, init453))
            SPKProfileSuggestionsHook(abvm, init453, (IMP)hook_ABVM_init453, (IMP *)&orig_ABVM_init453);
        else
            SPKProfileSuggestionsHook(abvm, init410, (IMP)hook_ABVM_init410, (IMP *)&orig_ABVM_init410);

        SPKProfileSuggestionsHook(objc_getClass("IGProfileViewController"), @selector(profileActionBarController:wantsToggleUserChaining:fromUserAction:),
                                  (IMP)hook_ProfileVC_wantsToggleUserChaining, (IMP *)&orig_ProfileVC_wantsToggleUserChaining);
    });
}
