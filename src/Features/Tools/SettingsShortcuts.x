#import <objc/runtime.h>
#import <substrate.h>

#import "../../InstagramHeaders.h"
#import "../../Settings/SPKSettingsViewController.h"
#import "../../Shared/Gallery/SPKGalleryViewController.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"
#import "../../Shared/Navigation/SPKTabConfiguration.h"
#import "../../Shared/i18n/SPKStrings.h"

static const void *kSPKHomeTabSettingsLongPressAssocKey = &kSPKHomeTabSettingsLongPressAssocKey;
static const void *kSPKGalleryTabLongPressAssocKey = &kSPKGalleryTabLongPressAssocKey;
static const void *kSPKProfileMoreSettingsLongPressAssocKey = &kSPKProfileMoreSettingsLongPressAssocKey;
static const NSTimeInterval kSPKHomeTabLongPressDuration = 0.5;
static const NSTimeInterval kSPKGalleryTabLongPressDuration = 0.65;
static const NSTimeInterval kSPKProfileMoreSettingsLongPressDuration = 0.5;
static NSInteger const kSPKProfileMoreShortcutMaxInstallAttempts = 6;
static NSString *const kSPKGalleryQuickAccessDisabledValue = @"none";

@interface IGTabBarButton (SPKQuickActions)
- (void)spk_addLongPressWithAction:(SEL)action marker:(const void *)marker minimumDuration:(NSTimeInterval)minimumDuration;
- (void)spk_removeProfileAccountPickerLongPressIfNeeded;
- (void)spk_removeGalleryLongPressIfNeeded;
- (void)spk_removeSettingsLongPressIfNeeded;
- (void)handleHomeTabLongPress:(UILongPressGestureRecognizer *)sender;
- (void)handleDirectInboxTabLongPress:(UILongPressGestureRecognizer *)sender;
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

static NSString *SPKGalleryShortcutTabIdentifier(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *identifier = [defaults stringForKey:@"gallery_quick_access_tab"];
    if (identifier.length == 0) {
        identifier = kSPKGalleryQuickAccessDisabledValue;
    }
    if ([identifier isEqualToString:kSPKGalleryQuickAccessDisabledValue])
        return identifier;

    NSString *target = identifier;
    BOOL usesClassicTabOrdering = [[[NSUserDefaults standardUserDefaults] stringForKey:@"interface_nav_order"] isEqualToString:@"classic"];
    if (usesClassicTabOrdering && [target isEqualToString:@"direct-inbox-tab"])
        return @"camera-tab";
    if (!usesClassicTabOrdering && [target isEqualToString:@"camera-tab"])
        return @"direct-inbox-tab";
    return target;
}

static BOOL SPKTabButtonMatchesTarget(NSString *identifier, NSString *label, NSString *target) {
    if (target.length == 0 || [target isEqualToString:kSPKGalleryQuickAccessDisabledValue])
        return NO;

    NSString *candidate = [NSString stringWithFormat:@"%@ %@", identifier ?: @"", label ?: @""].lowercaseString;
    if ([identifier isEqualToString:target])
        return YES;
    if ([target isEqualToString:@"mainfeed-tab"] && ([candidate containsString:@"mainfeed"] || [candidate containsString:@"home"]))
        return YES;
    if ([target isEqualToString:@"reels-tab"] && ([candidate containsString:@"clips"] || [candidate containsString:@"reels"]))
        return YES;
    if ([target isEqualToString:@"camera-tab"] && [candidate containsString:@"create"])
        return YES;
    if ([target isEqualToString:@"explore-tab"] && ([candidate containsString:@"explore"] || [candidate containsString:@"search"]))
        return YES;
    if ([target isEqualToString:@"direct-inbox-tab"] && ([candidate containsString:@"direct"] ||
                                                         [candidate containsString:@"inbox"] ||
                                                         [candidate containsString:@"message"]))
        return YES;
    if ([target isEqualToString:@"profile-tab"] && ([candidate containsString:@"profile"] ||
                                                    [candidate containsString:@"tab_avatar"]))
        return YES;
    return NO;
}

static BOOL SPKIsMessagesOnlyMode(void) {
    return [SPKSingleVisibleTabIdentifierFromPreferences() isEqualToString:SPKTabIdentifierDirect];
}

static NSString *SPKSparkleTabIdentifierForAccessibilityIdentifier(NSString *identifier) {
    if ([identifier isEqualToString:@"mainfeed-tab"]) return SPKTabIdentifierFeed;
    if ([identifier isEqualToString:@"reels-tab"]) return SPKTabIdentifierClips;
    if ([identifier isEqualToString:@"direct-inbox-tab"]) return SPKTabIdentifierDirect;
    if ([identifier isEqualToString:@"camera-tab"]) return SPKTabIdentifierCreate;
    if ([identifier isEqualToString:@"explore-tab"]) return SPKTabIdentifierSearch;
    if ([identifier isEqualToString:@"profile-tab"]) return SPKTabIdentifierProfile;
    return nil;
}

static BOOL SPKTabHiddenForIdentifier(NSString *identifier) {
    BOOL usesClassic = [[SPKUtils getStringPref:@"interface_nav_order"] isEqualToString:@"classic"];

    // A hidden tab that Saved is borrowing still has its button on the bar, so
    // the shortcut stays on it instead of moving to the next tab along.
    NSString *sparkleIdentifier = SPKSparkleTabIdentifierForAccessibilityIdentifier(identifier);
    if (sparkleIdentifier && [sparkleIdentifier isEqualToString:SPKEffectiveSavedCarrier()])
        return NO;

    if ([identifier isEqualToString:@"mainfeed-tab"])
        return [SPKUtils getBoolPref:@"interface_hide_feed_tab"];
    if ([identifier isEqualToString:@"reels-tab"])
        return [SPKUtils getBoolPref:@"interface_hide_reels_tab"];
    if ([identifier isEqualToString:@"direct-inbox-tab"])
        return usesClassic || [SPKUtils getBoolPref:@"interface_hide_msgs_tab"];
    if ([identifier isEqualToString:@"camera-tab"])
        return !usesClassic || [SPKUtils getBoolPref:@"interface_hide_create_tab"];
    if ([identifier isEqualToString:@"explore-tab"])
        return [SPKUtils getBoolPref:@"interface_hide_explore_tab"];
    if ([identifier isEqualToString:@"profile-tab"])
        return [SPKUtils getBoolPref:@"interface_hide_profile_tab"];
    return NO;
}

static NSString *SPKResolvedSettingsShortcutTabIdentifier(void) {
    if (![SPKUtils getBoolPref:@"tools_settings_shortcut"])
        return nil;

    NSArray<NSString *> *priority = @[ @"mainfeed-tab", @"reels-tab", @"direct-inbox-tab", @"camera-tab", @"explore-tab", @"profile-tab" ];
    for (NSString *identifier in priority) {
        if (SPKTabHiddenForIdentifier(identifier))
            continue;
        return identifier;
    }
    return nil;
}

static NSString *SPKResolvedGalleryShortcutTabIdentifier(void) {
    NSString *preferred = SPKGalleryShortcutTabIdentifier();
    if (preferred.length == 0 || [preferred isEqualToString:kSPKGalleryQuickAccessDisabledValue])
        return nil;

    NSString *settingsHost = SPKResolvedSettingsShortcutTabIdentifier();
    if (![preferred isEqualToString:settingsHost]) {
        return preferred;
    }

    // Clash! Settings wins on the preferred tab.
    // Gallery falls back to the next available visible tab that isn't settingsHost.
    NSArray<NSString *> *priority = @[ @"mainfeed-tab", @"reels-tab", @"direct-inbox-tab", @"camera-tab", @"explore-tab", @"profile-tab" ];
    for (NSString *identifier in priority) {
        if (SPKTabHiddenForIdentifier(identifier))
            continue;
        if ([identifier isEqualToString:settingsHost])
            continue;
        return identifier;
    }

    return nil;
}

static BOOL SPKTabIdentifierMatchesGalleryShortcut(NSString *identifier, NSString *label) {
    return SPKTabButtonMatchesTarget(identifier, label, SPKResolvedGalleryShortcutTabIdentifier());
}

// The accessibility label is localized, so it can never be compared against an
// English string. Identity comes from the identifier match alone.
static BOOL SPKShouldReplaceProfileTabLongPress(NSString *identifier, NSString *label) {
    return [SPKResolvedGalleryShortcutTabIdentifier() isEqualToString:@"profile-tab"] &&
           SPKTabButtonMatchesTarget(identifier, label, @"profile-tab");
}

// Show Sparkle tweak settings by holding on the settings/more icon under profile for ~1 second
%group SPKSettingsShortcutsHooks

// Quick access to tweak settings by holding on home tab button
%hook IGTabBarButton

- (void)setAccessibilityIdentifier:(NSString *)identifier {
    %orig;
    [self setNeedsLayout];
}

- (void)setAccessibilityLabel:(NSString *)label {
    %orig;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"SettingsShortcuts.layoutSubviews");

    NSString *identifier = self.accessibilityIdentifier ?: @"";
    NSString *label = self.accessibilityLabel ?: @"";

    NSString *settingsHost = SPKResolvedSettingsShortcutTabIdentifier();
    BOOL hostsSettings = settingsHost && SPKTabButtonMatchesTarget(identifier, label, settingsHost);
    BOOL matchesGallery = SPKTabIdentifierMatchesGalleryShortcut(identifier, label);

    if (hostsSettings) {
        [self spk_removeGalleryLongPressIfNeeded];
        [self spk_addLongPressWithAction:@selector(handleHomeTabLongPress:) marker:kSPKHomeTabSettingsLongPressAssocKey minimumDuration:kSPKHomeTabLongPressDuration];

        // Remove Instagram's native long press(es) that compete with ours.
        // Both have 0.5s duration, and requireGestureRecognizerToFail is
        // unreliable when durations match — sometimes IG's fires instead.
        for (UIGestureRecognizer *g in [self.gestureRecognizers copy]) {
            if (![g isKindOfClass:[UILongPressGestureRecognizer class]])
                continue;
            if (objc_getAssociatedObject(g, kSPKHomeTabSettingsLongPressAssocKey))
                continue;
            if (objc_getAssociatedObject(g, kSPKGalleryTabLongPressAssocKey))
                continue;
            [self removeGestureRecognizer:g];
        }
    } else {
        [self spk_removeSettingsLongPressIfNeeded];
    }

    if (matchesGallery && !hostsSettings) {
        if (SPKShouldReplaceProfileTabLongPress(identifier, label)) {
            [self spk_removeProfileAccountPickerLongPressIfNeeded];
        }
        [self spk_addLongPressWithAction:@selector(handleDirectInboxTabLongPress:) marker:kSPKGalleryTabLongPressAssocKey minimumDuration:kSPKGalleryTabLongPressDuration];
    } else {
        [self spk_removeGalleryLongPressIfNeeded];
    }
}

%new - (void)spk_addLongPressWithAction:(SEL)action marker:(const void *)marker minimumDuration:(NSTimeInterval)minimumDuration {
for (UIGestureRecognizer *gesture in self.gestureRecognizers) {
    if (![gesture isKindOfClass:[UILongPressGestureRecognizer class]])
        continue;
    if (objc_getAssociatedObject(gesture, marker)) {
        return;
    }
}

UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:action];
longPress.minimumPressDuration = minimumDuration;
BOOL shouldCancel = (marker == kSPKGalleryTabLongPressAssocKey || marker == kSPKHomeTabSettingsLongPressAssocKey);
longPress.cancelsTouchesInView = shouldCancel;
longPress.delaysTouchesBegan = shouldCancel;
longPress.delaysTouchesEnded = shouldCancel;

for (UIGestureRecognizer *existing in self.gestureRecognizers) {
    [existing requireGestureRecognizerToFail:longPress];
}

[self addGestureRecognizer:longPress];
objc_setAssociatedObject(longPress, marker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new - (void)spk_removeProfileAccountPickerLongPressIfNeeded {
for (UIGestureRecognizer *gesture in [self.gestureRecognizers copy]) {
    if (![gesture isKindOfClass:[UILongPressGestureRecognizer class]])
        continue;
    if (objc_getAssociatedObject(gesture, kSPKGalleryTabLongPressAssocKey))
        continue;

    UILongPressGestureRecognizer *longPress = (UILongPressGestureRecognizer *)gesture;
    if (fabs(longPress.minimumPressDuration - 0.5) > 0.01)
        continue;

    [self removeGestureRecognizer:gesture];
}
}

%new - (void)spk_removeGalleryLongPressIfNeeded {
for (UIGestureRecognizer *gesture in [self.gestureRecognizers copy]) {
    if (![gesture isKindOfClass:[UILongPressGestureRecognizer class]])
        continue;
    if (objc_getAssociatedObject(gesture, kSPKGalleryTabLongPressAssocKey)) {
        [self removeGestureRecognizer:gesture];
    }
}
}

%new - (void)spk_removeSettingsLongPressIfNeeded {
for (UIGestureRecognizer *gesture in [self.gestureRecognizers copy]) {
    if (![gesture isKindOfClass:[UILongPressGestureRecognizer class]])
        continue;
    if (objc_getAssociatedObject(gesture, kSPKHomeTabSettingsLongPressAssocKey)) {
        [self removeGestureRecognizer:gesture];
    }
}
}

%new - (void)handleHomeTabLongPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan)
        return;

    SPKFireShortcutHaptic();
    [SPKUtils showSettingsVC:[self window]];
}

%new - (void)handleDirectInboxTabLongPress:(UILongPressGestureRecognizer *)sender {
if (sender.state != UIGestureRecognizerStateBegan)
    return;

SPKFireShortcutHaptic();
[SPKGalleryViewController presentGallery];
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

// The native UITabBarController tab bar (folded iPhone Duo, or Native Tab Bar)
// draws system tabs, so the IGTabBarButton gestures above never see a touch.
// Instagram instead routes a held tab through its coordinator delegate. The tab
// is identified through the same IGTabBarButton the native descriptor is built
// from, so the host resolves exactly as it does on the custom bar.
typedef NS_ENUM(NSInteger, SPKNativeTabShortcut) {
    SPKNativeTabShortcutNone = 0,
    SPKNativeTabShortcutSettings,
    SPKNativeTabShortcutGallery,
};

// Phase 0 is the press being recognized, where Instagram fires its own hold
// actions. Later phases (changed, ended, cancelled) belong to the same press.
static NSInteger const kSPKNativeLongPressPhaseBegan = 0;

static SPKNativeTabShortcut SPKNativeTabShortcutForSurface(IGTabBarController *controller, id surface) {
    if (!surface || ![controller respondsToSelector:@selector(_buttonForTabBarSurface:)])
        return SPKNativeTabShortcutNone;
    UIView *button = [controller _buttonForTabBarSurface:surface];
    if (![button isKindOfClass:[UIView class]])
        return SPKNativeTabShortcutNone;

    NSString *buttonIdentifier = button.accessibilityIdentifier ?: @"";
    NSString *label = button.accessibilityLabel ?: @"";
    NSString *settingsHost = SPKResolvedSettingsShortcutTabIdentifier();
    if (settingsHost && SPKTabButtonMatchesTarget(buttonIdentifier, label, settingsHost))
        return SPKNativeTabShortcutSettings;
    if (SPKTabIdentifierMatchesGalleryShortcut(buttonIdentifier, label))
        return SPKNativeTabShortcutGallery;
    return SPKNativeTabShortcutNone;
}

static SPKNativeTabShortcut SPKNativeTabShortcutForIdentifier(IGTabBarController *controller, id identifier) {
    if (!identifier || ![controller respondsToSelector:@selector(_surfaceForNativeIdentifier:)])
        return SPKNativeTabShortcutNone;
    return SPKNativeTabShortcutForSurface(controller, [controller _surfaceForNativeIdentifier:identifier]);
}

%group SPKNativeTabBarShortcutHooks

%hook IGTabBarController
- (BOOL)nativeTabBarControllerCoordinator:(id)coordinator canLongPressIdentifier:(id)identifier {
    if (SPKNativeTabShortcutForIdentifier(self, identifier) != SPKNativeTabShortcutNone)
        return YES;
    return %orig;
}

// The coordinator only attaches a hold to tabs whose descriptor carries a
// long-press accessibility action, and only Home and Profile have one of their
// own. Naming an action for the shortcut hosts gives them the hold, and gives
// VoiceOver a named action that does the same thing.
- (NSString *)_nativeLongPressAccessibilityActionNameForSurface:(id)surface {
    switch (SPKNativeTabShortcutForSurface(self, surface)) {
    case SPKNativeTabShortcutSettings:
        return SPKL(@"TOOLS_SHORTCUT_TAB_SETTINGS_ACCESSIBILITY_ACTION");
    case SPKNativeTabShortcutGallery:
        return SPKL(@"TOOLS_SHORTCUT_TAB_GALLERY_ACCESSIBILITY_ACTION");
    case SPKNativeTabShortcutNone:
        break;
    }
    return %orig;
}

- (void)nativeTabBarControllerCoordinator:(id)coordinator didUpdateLongPressIdentifier:(id)identifier phase:(NSInteger)phase {
    SPKNativeTabShortcut shortcut = SPKNativeTabShortcutForIdentifier(self, identifier);
    if (shortcut == SPKNativeTabShortcutNone) {
        %orig;
        return;
    }
    // The press belongs to Sparkle, so the tab's own hold action (the account
    // switcher on Profile) never sees any of its phases.
    if (phase != kSPKNativeLongPressPhaseBegan)
        return;

    SPKFireShortcutHaptic();
    if (shortcut == SPKNativeTabShortcutSettings)
        [SPKUtils showSettingsVC:self.view.window];
    else
        [SPKGalleryViewController presentGallery];
}
%end

%end

void SPKInstallSettingsShortcutsHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKSettingsShortcutsHooks,
              IGDirectInboxNavigationHeaderView = SPKResolveIGClass(@"IGDirectInboxNavigationHeaderView.IGDirectInboxNavigationHeaderView",
                                                                    @"IGDirectInboxNavigationHeaderView"));
        Class tabBarControllerClass = objc_getClass("IGTabBarController");
        if ([tabBarControllerClass instancesRespondToSelector:@selector(nativeTabBarControllerCoordinator:canLongPressIdentifier:)] &&
            [tabBarControllerClass instancesRespondToSelector:@selector(nativeTabBarControllerCoordinator:didUpdateLongPressIdentifier:phase:)] &&
            [tabBarControllerClass instancesRespondToSelector:@selector(_surfaceForNativeIdentifier:)] &&
            [tabBarControllerClass instancesRespondToSelector:@selector(_nativeLongPressAccessibilityActionNameForSurface:)]) {
            %init(SPKNativeTabBarShortcutHooks);
        }
        SPKInstallProfileMoreShortcutHooks();
    });
}
