#import <objc/runtime.h>
#import <substrate.h>

#import "../../InstagramHeaders.h"
#import "../../Settings/SPKSettingsViewController.h"
#import "../../App/SPKStabilityGuard.h"
#import "../../Shared/Navigation/SPKDestinations.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"
#import "../../Shared/Navigation/SPKTabConfiguration.h"
#import "../../Shared/i18n/SPKStrings.h"

static const void *kSPKTabHoldAssocKey = &kSPKTabHoldAssocKey;
static const void *kSPKTabHoldDisabledInstagramHoldKey = &kSPKTabHoldDisabledInstagramHoldKey;
static const void *kSPKProfileMoreSettingsLongPressAssocKey = &kSPKProfileMoreSettingsLongPressAssocKey;
static const NSTimeInterval kSPKTabHoldDuration = 0.5;
static const NSTimeInterval kSPKProfileMoreSettingsLongPressDuration = 0.5;
static NSInteger const kSPKProfileMoreShortcutMaxInstallAttempts = 6;

@interface IGTabBarButton (SPKTabHolds)
- (void)spk_setInstagramHoldsEnabled:(BOOL)enabled;
- (void)spk_addTabHold;
- (void)spk_removeTabHold;
- (void)spk_handleTabHold:(UILongPressGestureRecognizer *)sender;
@end

@interface SPKSettingsShortcutTarget : NSObject
+ (instancetype)sharedTarget;
- (void)handleProfileMoreLongPress:(UILongPressGestureRecognizer *)sender;
@end

// Light confirmation tap fired when a tab-bar shortcut activates. The global
// UIImpactFeedbackGenerator hook (DisableHaptics.x) already respects
// general_disable_haptics, so this stays silent when the user disabled haptics.
static void SPKFireShortcutHaptic(void) {
    if (![SPKUtils getBoolPref:@"tools_shortcut_haptics"])
        return;
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [generator prepare];
    [generator impactOccurred];
}

@implementation SPKSettingsShortcutTarget
+ (instancetype)sharedTarget {
    static SPKSettingsShortcutTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [SPKSettingsShortcutTarget new];
    });
    return target;
}

- (void)handleProfileMoreLongPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan)
        return;

    SPKLog(@"General", @"[Sparkle] Tweak settings gesture activated");
    SPKFireShortcutHaptic();
    [SPKUtils showSettingsVC:sender.view.window];
}
@end

static BOOL SPKIsProfileMoreButton(UIView *view) {
    return [view.accessibilityIdentifier isEqualToString:@"profile-more-button"];
}

static void SPKAddProfileSettingsLongPressToView(UIView *view) {
    if (!view)
        return;
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if (![gesture isKindOfClass:[UILongPressGestureRecognizer class]])
            continue;
        if (objc_getAssociatedObject(gesture, kSPKProfileMoreSettingsLongPressAssocKey)) {
            return;
        }
    }

    SPKLog(@"General", @"[Sparkle] Adding tweak settings long press gesture recognizer to %@ id=%@ label=%@",
           NSStringFromClass(view.class),
           view.accessibilityIdentifier,
           view.accessibilityLabel);

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:[SPKSettingsShortcutTarget sharedTarget]
                                                                                            action:@selector(handleProfileMoreLongPress:)];
    longPress.minimumPressDuration = kSPKProfileMoreSettingsLongPressDuration;
    longPress.cancelsTouchesInView = YES;
    longPress.delaysTouchesBegan = YES;
    longPress.delaysTouchesEnded = YES;

    for (UIGestureRecognizer *existing in view.gestureRecognizers) {
        [existing requireGestureRecognizerToFail:longPress];
    }

    [view addGestureRecognizer:longPress];
    objc_setAssociatedObject(longPress, kSPKProfileMoreSettingsLongPressAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void (*orig_spkProfileMoreDidMoveToWindow)(id, SEL);
static void SPKHookedProfileMoreDidMoveToWindow(id self, SEL _cmd) {
    if (orig_spkProfileMoreDidMoveToWindow)
        orig_spkProfileMoreDidMoveToWindow(self, _cmd);
    if ([self isKindOfClass:[UIView class]] && SPKIsProfileMoreButton((UIView *)self)) {
        SPKAddProfileSettingsLongPressToView((UIView *)self);
    }
}

static void (*orig_spkProfileMoreLayoutSubviews)(id, SEL);
static void SPKHookedProfileMoreLayoutSubviews(id self, SEL _cmd) {
    if (orig_spkProfileMoreLayoutSubviews)
        orig_spkProfileMoreLayoutSubviews(self, _cmd);
    if ([self isKindOfClass:[UIView class]] && SPKIsProfileMoreButton((UIView *)self)) {
        SPKAddProfileSettingsLongPressToView((UIView *)self);
    }
}

static BOOL SPKProfileMoreShortcutHooksInstalled = NO;
static BOOL SPKProfileMoreShortcutRetryScheduled = NO;
static NSInteger SPKProfileMoreShortcutInstallAttempts = 0;

static void SPKInstallProfileMoreShortcutHooks(void) {
    if (SPKProfileMoreShortcutHooksInstalled)
        return;

    SPKProfileMoreShortcutInstallAttempts += 1;
    Class buttonClass = objc_getClass("IGProfileNavigation.IGBadgedNavigationButton");
    if (!buttonClass)
        buttonClass = objc_getClass("_TtC19IGProfileNavigation24IGBadgedNavigationButton");
    if (!buttonClass)
        buttonClass = objc_getClass("IGBadgedNavigationButton");
    if (!buttonClass) {
        SPKLog(@"General", @"[Sparkle] Profile more settings shortcut hook target unavailable attempt=%ld",
               (long)SPKProfileMoreShortcutInstallAttempts);
        if (!SPKProfileMoreShortcutRetryScheduled &&
            SPKProfileMoreShortcutInstallAttempts < kSPKProfileMoreShortcutMaxInstallAttempts) {
            SPKProfileMoreShortcutRetryScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SPKProfileMoreShortcutRetryScheduled = NO;
                SPKInstallProfileMoreShortcutHooks();
            });
        }
        return;
    }

    MSHookMessageEx(buttonClass, @selector(didMoveToWindow), (IMP)SPKHookedProfileMoreDidMoveToWindow, (IMP *)&orig_spkProfileMoreDidMoveToWindow);
    MSHookMessageEx(buttonClass, @selector(layoutSubviews), (IMP)SPKHookedProfileMoreLayoutSubviews, (IMP *)&orig_spkProfileMoreLayoutSubviews);
    SPKProfileMoreShortcutHooksInstalled = YES;
    SPKLog(@"General", @"[Sparkle] Profile more settings shortcut hooks class=%@", NSStringFromClass(buttonClass));
}

// MARK: - Tab holds

static NSString *SPKSparkleTabIdentifierForAccessibilityIdentifier(NSString *identifier) {
    if (identifier.length == 0)
        return nil;
    if ([identifier isEqualToString:@"mainfeed-tab"]) return SPKTabIdentifierFeed;
    if ([identifier isEqualToString:@"reels-tab"]) return SPKTabIdentifierClips;
    if ([identifier isEqualToString:@"direct-inbox-tab"]) return SPKTabIdentifierDirect;
    if ([identifier isEqualToString:@"camera-tab"]) return SPKTabIdentifierCreate;
    if ([identifier isEqualToString:@"explore-tab"]) return SPKTabIdentifierSearch;
    if ([identifier isEqualToString:@"profile-tab"]) return SPKTabIdentifierProfile;
    // Identifiers Instagram has used for the same tabs on other builds. Only the
    // identifier is compared: the accessibility label is localized.
    NSString *lowercase = identifier.lowercaseString;
    if ([lowercase containsString:@"mainfeed"] || [lowercase containsString:@"home"]) return SPKTabIdentifierFeed;
    if ([lowercase containsString:@"clips"] || [lowercase containsString:@"reels"]) return SPKTabIdentifierClips;
    if ([lowercase containsString:@"direct"] || [lowercase containsString:@"inbox"]) return SPKTabIdentifierDirect;
    if ([lowercase containsString:@"camera"] || [lowercase containsString:@"create"]) return SPKTabIdentifierCreate;
    if ([lowercase containsString:@"explore"] || [lowercase containsString:@"search"]) return SPKTabIdentifierSearch;
    if ([lowercase containsString:@"profile"]) return SPKTabIdentifierProfile;
    return nil;
}

// The hold belongs to what the slot shows, so the tab Saved borrows answers
// with Saved's hold.
static NSString *SPKHoldTabIdentifierForButtonIdentifier(NSString *identifier) {
    NSString *tab = SPKSparkleTabIdentifierForAccessibilityIdentifier(identifier);
    if (!tab)
        return nil;
    if ([tab isEqualToString:SPKEffectiveSavedCarrier()])
        return SPKTabIdentifierSaved;
    return tab;
}

// With Disable All on (or in safe mode) only a Settings hold stays, so the way
// back into Sparkle is never lost. Every tab on the bar that holds Settings
// keeps it. The bar then may not be the one the holds were set for: Disable
// All reads the layout, hidden tabs and Saved as their defaults, so a Settings
// hold kept on Saved or on a tab no longer shown would be out of reach. Only
// then does one tab take it: the slot Saved showed in, else the first tab.
static NSArray<NSString *> *SPKBarTabsInOrder(void) {
    return @[ SPKTabIdentifierFeed, SPKTabIdentifierClips, SPKTabIdentifierDirect,
              SPKTabIdentifierCreate, SPKTabIdentifierSearch, SPKTabIdentifierProfile ];
}

static BOOL SPKTabShownOnBar(NSString *tab, NSString *layout, NSString *carrier) {
    if (!SPKTabOccupiesBarSlot(tab, layout))
        return NO;
    if ([tab isEqualToString:carrier])
        return YES;
    NSString *hideKey = SPKTabHidePreferenceKey(tab);
    return hideKey.length == 0 || ![SPKUtils getBoolPref:hideKey];
}

static BOOL SPKTabHoldsSettings(NSString *tab, NSString *carrier) {
    NSString *holdTab = [tab isEqualToString:carrier] ? SPKTabIdentifierSaved : tab;
    return [SPKTabHoldValue(holdTab) isEqualToString:SPKDestinationSettings];
}

static NSString *SPKRestrictedSettingsFallbackTab(NSString *layout, NSString *carrier) {
    BOOL wanted = NO;
    for (NSString *identifier in SPKTabHoldableIdentifiers()) {
        if ([SPKTabHoldValue(identifier) isEqualToString:SPKDestinationSettings]) {
            wanted = YES;
            break;
        }
    }
    if (!wanted)
        return nil;

    NSString *first = nil;
    for (NSString *tab in SPKBarTabsInOrder()) {
        if (!SPKTabShownOnBar(tab, layout, carrier))
            continue;
        if (SPKTabHoldsSettings(tab, carrier))
            return nil;
        if (!first)
            first = tab;
    }
    if ([SPKTabHoldValue(SPKTabIdentifierSaved) isEqualToString:SPKDestinationSettings]) {
        // Disable All reads the carrier as none, so the stored one is read past the overlay.
        NSString *storedCarrier = SPKNormalizedSavedCarrier(SPKPreferenceObjectForKey(SPKPrefSavedTabCarrier));
        if (![storedCarrier isEqualToString:SPKTabSavedCarrierNone] && SPKTabOccupiesBarSlot(storedCarrier, layout))
            return storedCarrier;
    }
    return first;
}

static NSString *SPKResolvedHoldForButtonIdentifier(NSString *identifier) {
    if (SPKStabilityGuardIsSafeStartupMode() || [SPKUtils getBoolPref:@"tools_disable_all"]) {
        NSString *buttonTab = SPKSparkleTabIdentifierForAccessibilityIdentifier(identifier);
        if (!buttonTab)
            return SPKTabHoldInstagramDefault;
        NSString *layout = SPKEffectiveTabLayout();
        NSString *carrier = SPKEffectiveSavedCarrier();
        if (SPKTabHoldsSettings(buttonTab, carrier) ||
            [buttonTab isEqualToString:SPKRestrictedSettingsFallbackTab(layout, carrier)])
            return SPKDestinationSettings;
        return SPKTabHoldInstagramDefault;
    }
    NSString *tab = SPKHoldTabIdentifierForButtonIdentifier(identifier);
    if (!tab)
        return SPKTabHoldInstagramDefault;
    NSString *hold = SPKTabHoldValue(tab);
    // The Search tab's clipboard holds ride on Instagram's own search hold
    // (OpenLinkFromClipboard.xm), so a clipboard with nothing to open still
    // opens search there instead of saying there was nothing.
    if ([tab isEqualToString:SPKTabIdentifierSearch] && SPKSearchTabClipboardHold())
        return SPKTabHoldInstagramDefault;
    return hold;
}

static BOOL SPKHoldOpensDestination(NSString *hold) {
    return ![hold isEqualToString:SPKTabHoldInstagramDefault] && ![hold isEqualToString:SPKTabHoldNone];
}

static void SPKOpenHoldDestination(NSString *hold, UIWindow *window) {
    SPKDestination *destination = SPKDestinationForIdentifier(hold);
    if (!destination)
        return;
    // The clipboard holds tap once something actually opens, so an empty
    // clipboard does not confirm a press that did nothing.
    if (destination.group != SPKDestinationGroupAction)
        SPKFireShortcutHaptic();
    [destination openFromWindow:window];
}

static BOOL SPKIsMessagesOnlyMode(void) {
    return [SPKSingleVisibleTabIdentifierFromPreferences() isEqualToString:SPKTabIdentifierDirect];
}

%group SPKSettingsShortcutsHooks

%hook IGTabBarButton

- (void)setAccessibilityIdentifier:(NSString *)identifier {
    %orig;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"SettingsShortcuts.layoutSubviews");

    NSString *hold = SPKResolvedHoldForButtonIdentifier(self.accessibilityIdentifier);
    // Instagram's own holds (the account switcher on Profile) are switched off
    // rather than removed while Sparkle owns the press, so going back to
    // Instagram Default brings them back. Two holds of the same duration on one
    // button do not reliably defer to each other, so leaving it enabled is not
    // an option.
    [self spk_setInstagramHoldsEnabled:[hold isEqualToString:SPKTabHoldInstagramDefault]];
    if (SPKHoldOpensDestination(hold))
        [self spk_addTabHold];
    else
        [self spk_removeTabHold];
}

// Only recognizers Sparkle switched off are switched back on, so one Instagram
// (or anything else) disabled on purpose stays disabled.
%new - (void)spk_setInstagramHoldsEnabled:(BOOL)enabled {
    for (UIGestureRecognizer *gesture in self.gestureRecognizers) {
        if (![gesture isKindOfClass:[UILongPressGestureRecognizer class]])
            continue;
        if (objc_getAssociatedObject(gesture, kSPKTabHoldAssocKey))
            continue;
        BOOL disabledBySparkle = objc_getAssociatedObject(gesture, kSPKTabHoldDisabledInstagramHoldKey) != nil;
        if (enabled) {
            if (!disabledBySparkle)
                continue;
            objc_setAssociatedObject(gesture, kSPKTabHoldDisabledInstagramHoldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!gesture.enabled)
                gesture.enabled = YES;
        } else if (gesture.enabled) {
            gesture.enabled = NO;
            objc_setAssociatedObject(gesture, kSPKTabHoldDisabledInstagramHoldKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

%new - (void)spk_addTabHold {
    for (UIGestureRecognizer *gesture in self.gestureRecognizers) {
        if (objc_getAssociatedObject(gesture, kSPKTabHoldAssocKey))
            return;
    }

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(spk_handleTabHold:)];
    longPress.minimumPressDuration = kSPKTabHoldDuration;
    longPress.cancelsTouchesInView = YES;
    longPress.delaysTouchesBegan = YES;
    longPress.delaysTouchesEnded = YES;
    for (UIGestureRecognizer *existing in self.gestureRecognizers)
        [existing requireGestureRecognizerToFail:longPress];
    [self addGestureRecognizer:longPress];
    objc_setAssociatedObject(longPress, kSPKTabHoldAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new - (void)spk_removeTabHold {
    for (UIGestureRecognizer *gesture in [self.gestureRecognizers copy]) {
        if (objc_getAssociatedObject(gesture, kSPKTabHoldAssocKey))
            [self removeGestureRecognizer:gesture];
    }
}

%new - (void)spk_handleTabHold:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan)
        return;
    // Read again at the press: the hold may have changed since the last layout.
    NSString *hold = SPKResolvedHoldForButtonIdentifier(self.accessibilityIdentifier);
    SPKLog(@"General", @"[Sparkle] Tab hold %@ -> %@", self.accessibilityIdentifier, hold);
    if (SPKHoldOpensDestination(hold))
        SPKOpenHoldDestination(hold, self.window);
}
%end

%hook IGDirectInboxNavigationHeaderView
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"SettingsShortcuts.layoutSubviews2");

    UIButton *btn = nil;
    if ([self respondsToSelector:@selector(messageButton)]) {
        btn = [self valueForKey:@"messageButton"];
    }
    if (btn) {
        BOOL shouldAdd = SPKIsMessagesOnlyMode();
        if (shouldAdd) {
            UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:[SPKSettingsShortcutTarget sharedTarget]
                                                                                                     action:@selector(handleProfileMoreLongPress:)];
            longPress.minimumPressDuration = kSPKProfileMoreSettingsLongPressDuration;
            longPress.cancelsTouchesInView = YES;
            longPress.delaysTouchesBegan = YES;
            longPress.delaysTouchesEnded = YES;

            for (UIGestureRecognizer *gesture in [btn.gestureRecognizers copy]) {
                if ([gesture isKindOfClass:[UILongPressGestureRecognizer class]] &&
                    objc_getAssociatedObject(gesture, kSPKProfileMoreSettingsLongPressAssocKey)) {
                    [btn removeGestureRecognizer:gesture];
                }
            }

            for (UIGestureRecognizer *existing in btn.gestureRecognizers) {
                [existing requireGestureRecognizerToFail:longPress];
            }

            [btn addGestureRecognizer:longPress];
            objc_setAssociatedObject(longPress, kSPKProfileMoreSettingsLongPressAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            // Clean up gesture if it shouldn't be here
            for (UIGestureRecognizer *gesture in [btn.gestureRecognizers copy]) {
                if ([gesture isKindOfClass:[UILongPressGestureRecognizer class]] &&
                    objc_getAssociatedObject(gesture, kSPKProfileMoreSettingsLongPressAssocKey)) {
                    [btn removeGestureRecognizer:gesture];
                }
            }
        }
    }
}
%end

%end

// The native UITabBarController tab bar (foldables, or System Tab Bar) draws
// system tabs, so the IGTabBarButton gestures above never see a touch.
// Instagram instead routes a held tab through its coordinator delegate, which
// NativeTabBar.xm hooks once for every Sparkle hold. The tab is identified
// through the same IGTabBarButton the native descriptor is built from, so the
// hold resolves exactly as it does on the custom bar.
NSString *SPKNativeTabHoldForSurface(id controller, id surface) {
    if (!surface || ![controller respondsToSelector:@selector(_buttonForTabBarSurface:)])
        return SPKTabHoldInstagramDefault;
    UIView *button = [(IGTabBarController *)controller _buttonForTabBarSurface:surface];
    if (![button isKindOfClass:[UIView class]])
        return SPKTabHoldInstagramDefault;
    return SPKResolvedHoldForButtonIdentifier(button.accessibilityIdentifier);
}

// Naming an action is what gives a tab the hold, and it gives VoiceOver a
// named action that does the same thing.
NSString *SPKNativeTabHoldActionName(NSString *hold) {
    return SPKDestinationForIdentifier(hold).title;
}

void SPKPerformNativeTabHold(id controller, NSString *hold) {
    if (SPKHoldOpensDestination(hold))
        SPKOpenHoldDestination(hold, ((UIViewController *)controller).view.window);
}

// A tab button only takes its hold on its next layout pass, so a hold applied
// in the Tab Bar page would keep the old behavior until Instagram happened to
// lay that button out again. Asking every tab button for a layout makes it
// take the new hold straight away.
void SPKRefreshTabHolds(void) {
    Class buttonClass = NSClassFromString(@"IGTabBarButton");
    if (!buttonClass)
        return;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
        for (NSUInteger i = 0; i < queue.count && i < 4000; i++) {
            UIView *view = queue[i];
            if ([view isKindOfClass:buttonClass]) {
                [view setNeedsLayout];
                continue;
            }
            [queue addObjectsFromArray:view.subviews];
        }
    }
}

void SPKInstallSettingsShortcutsHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKSettingsShortcutsHooks,
              IGDirectInboxNavigationHeaderView = SPKResolveIGClass(@"IGDirectInboxNavigationHeaderView.IGDirectInboxNavigationHeaderView",
                                                                    @"IGDirectInboxNavigationHeaderView"));
        SPKInstallProfileMoreShortcutHooks();
    });
}
