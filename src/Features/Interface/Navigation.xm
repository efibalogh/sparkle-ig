#import "../../Utils.h"
#import "SPKStrings.h"
#import "../../App/SPKStabilityGuard.h"
#import "../../AssetUtils.h"
#import "../../Shared/Account/SPKAccountManager.h"
#import "../../Shared/Navigation/SPKTabConfiguration.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import "../../App/SPKPerfMeter.h"

static const void *kSPKSavedTabIntentPendingKey = &kSPKSavedTabIntentPendingKey;
static const void *kSPKSavedTabFallbackHostKey = &kSPKSavedTabFallbackHostKey;
static const void *kSPKSavedTabButtonKey = &kSPKSavedTabButtonKey;
static const void *kSPKSavedTabButtonIdentityKey = &kSPKSavedTabButtonIdentityKey;
static const void *kSPKSavedTabOriginalImagesKey = &kSPKSavedTabOriginalImagesKey;
static const void *kSPKSavedTabOriginalLabelKey = &kSPKSavedTabOriginalLabelKey;
static const void *kSPKSavedTabSuppressedOverlaysKey = &kSPKSavedTabSuppressedOverlaysKey;

static NSUInteger spk_savedTabRoutingBypassGeneration = 0;
static NSTimeInterval spk_savedTabRoutingBypassDeadline = 0;

static BOOL SPKSavedTabRoutingBypassActive(void) {
    return spk_savedTabRoutingBypassDeadline > NSDate.timeIntervalSinceReferenceDate;
}

extern "C" void SPKBeginSavedTabRoutingBypass(void) {
    NSUInteger generation = ++spk_savedTabRoutingBypassGeneration;
    spk_savedTabRoutingBypassDeadline = NSDate.timeIntervalSinceReferenceDate + 2.5;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (spk_savedTabRoutingBypassGeneration == generation) {
            spk_savedTabRoutingBypassDeadline = 0;
        }
    });
}

extern "C" void SPKEndSavedTabRoutingBypass(void) {
    ++spk_savedTabRoutingBypassGeneration;
    spk_savedTabRoutingBypassDeadline = 0;
}

static NSString *SPKSavedCarrierIdentifier(void) {
    if (SPKStabilityGuardIsSafeStartupMode())
        return SPKTabSavedCarrierNone;
    return SPKEffectiveSavedCarrier();
}

// Classic draws Messages in the feed header instead of the bar and the Tab
// Editor does not offer a toggle for it there, so a hide flag left behind by
// another layout must not quietly remove the header link (or the swipe) that is
// then the only way into the inbox.
static BOOL SPKMessagesTabHidden(void) {
    if (SPKStabilityGuardIsSafeStartupMode())
        return NO;
    NSString *layout = SPKNormalizedTabLayout([SPKUtils getStringPref:SPKPrefTabLayout]);
    if (!SPKTabOccupiesBarSlot(SPKTabIdentifierDirect, layout))
        return NO;
    return [SPKUtils getBoolPref:SPKTabHidePreferenceKey(SPKTabIdentifierDirect)];
}

// The Create launcher carries no tab string, so it is identified by its surface
// subtype. Instagram reuses 3 for the camera entry on every supported build.
static BOOL SPKIsCreateSurface(IGMainAppSurfaceIntent *surface) {
    if (!surface)
        return NO;
    @try {
        return [(NSNumber *)[surface valueForKey:@"_subtype"] unsignedIntegerValue] == 3;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL SPKHasSavedTabDestination(void) {
    return ![SPKSavedCarrierIdentifier() isEqualToString:SPKTabSavedCarrierNone];
}

static BOOL SPKSavedTabPreferenceMayEnable(void) {
    NSString *baseKey = SPKPrefSavedTabCarrier;
    NSDictionary<NSString *, id> *preferences = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    for (NSString *key in preferences) {
        if (([key isEqualToString:baseKey] || [key hasSuffix:[@"_" stringByAppendingString:baseKey]]) &&
            ![SPKNormalizedSavedCarrier(preferences[key]) isEqualToString:SPKTabSavedCarrierNone]) {
            return YES;
        }
    }
    return NO;
}

static NSString *SPKTabIdentifierForSurface(IGMainAppSurfaceIntent *surface) {
    if (![surface isKindOfClass:%c(IGMainAppSurfaceIntent)]) return nil;
    NSString *tab = [surface tabStringFromSurfaceIntent];
    if ([tab isEqualToString:@"FEED"]) return SPKTabIdentifierFeed;
    if ([tab isEqualToString:@"CLIPS"]) return SPKTabIdentifierClips;
    if ([tab isEqualToString:@"DIRECT"]) return SPKTabIdentifierDirect;
    if ([tab isEqualToString:@"SEARCH"]) return SPKTabIdentifierSearch;
    if ([tab isEqualToString:@"PROFILE"]) return SPKTabIdentifierProfile;
    return nil;
}

static BOOL SPKIsSavedCarrierSurface(IGMainAppSurfaceIntent *surface) {
    NSString *carrier = SPKSavedCarrierIdentifier();
    if ([carrier isEqualToString:SPKTabSavedCarrierNone])
        return NO;
    NSString *identifier = SPKTabIdentifierForSurface(surface);
    return identifier && [identifier isEqualToString:carrier];
}

static BOOL SPKIsSavedViewController(UIViewController *controller) {
    NSString *className = NSStringFromClass(controller.class);
    return [className containsString:@"SavedMediaCollectionsViewController"] ||
           [className containsString:@"IGSavedMediaViewController"];
}

static UINavigationController *SPKNativeSavedNavigationController(IGTabBarController *controller) {
    id manager = [SPKUtils getIvarForObj:controller name:"_viewControllerManager"];
    SEL selector = NSSelectorFromString(@"savedCollectionsNavigationController");
    if (!manager || ![manager respondsToSelector:selector])
        return nil;

    id candidate = ((id (*)(id, SEL))objc_msgSend)(manager, selector);
    return [candidate isKindOfClass:[UINavigationController class]] ? candidate : nil;
}

// Called from -layoutSubviews of every tab bar button, so the identifier match
// (which allocates a lowercased copy) is resolved once and cached. A button with
// no identifier yet is not cached: the answer is not knowable until Instagram
// sets one, and the tab bar controller tags the real button by ivar anyway.
static NSString *SPKTabIdentifierForButton(IGTabBarButton *button) {
    id cachedIdentity = objc_getAssociatedObject(button, kSPKSavedTabButtonIdentityKey);
    if ([cachedIdentity isKindOfClass:[NSString class]])
        return cachedIdentity;
    if ([cachedIdentity isKindOfClass:[NSNull class]])
        return nil;

    NSString *identifier = button.accessibilityIdentifier;
    if (identifier.length == 0)
        return nil;

    NSString *normalized = identifier.lowercaseString;
    NSString *resolved = nil;
    if ([normalized containsString:@"reels"] || [normalized containsString:@"clips"])
        resolved = SPKTabIdentifierClips;
    else if ([normalized containsString:@"direct"] || [normalized containsString:@"inbox"])
        resolved = SPKTabIdentifierDirect;
    else if ([normalized containsString:@"explore"] || [normalized containsString:@"search"])
        resolved = SPKTabIdentifierSearch;
    else if ([normalized containsString:@"profile"])
        resolved = SPKTabIdentifierProfile;
    else if ([normalized containsString:@"feed"] || [normalized containsString:@"timeline"] ||
             [normalized containsString:@"home"])
        resolved = SPKTabIdentifierFeed;
    else if ([normalized containsString:@"camera"] || [normalized containsString:@"create"])
        resolved = SPKTabIdentifierCreate;

    // A resolved "none" is cached too: without it every layout pass of the
    // camera/activity buttons re-lowercases their identifier forever.
    objc_setAssociatedObject(button, kSPKSavedTabButtonIdentityKey, resolved ?: (id)[NSNull null],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return resolved;
}

static UIImage *SPKSavedTabImage(BOOL filledImage) {
    static UIImage *outline;
    static UIImage *filled;
    if (filledImage) {
        if (!filled) {
            filled = [[SPKAssetUtils instagramIconNamed:@"save_filled" pointSize:24.0]
                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        return filled;
    }

    if (!outline) {
        outline = [[SPKAssetUtils instagramIconNamed:@"save" pointSize:24.0]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return outline;
}

static void SPKRememberOriginalTabImage(UIButton *button, UIControlState state, UIImage *image) {
    if (!image || image == SPKSavedTabImage(NO) || image == SPKSavedTabImage(YES))
        return;

    NSMutableDictionary<NSNumber *, UIImage *> *originalImages = objc_getAssociatedObject(button, kSPKSavedTabOriginalImagesKey);
    if (!originalImages) {
        originalImages = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(button, kSPKSavedTabOriginalImagesKey, originalImages, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    originalImages[@(state)] = image;
}

// The label Sparkle writes is localized, so it can never be compared against the
// English word. Resolved once because the language preference is restart-only,
// which also keeps the bundle lookup off the layout path.
static NSString *SPKSavedTabAccessibilityLabel(void) {
    static NSString *label = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ label = SPKL(@"TAB_SAVED"); });
    return label;
}

static void SPKConfigureSavedTabButtonInstance(UIButton *button) {
    if (![button isKindOfClass:[UIButton class]])
        return;

    NSString *identifier = SPKTabIdentifierForButton((IGTabBarButton *)button);
    BOOL shouldDisplaySaved = identifier && [identifier isEqualToString:SPKSavedCarrierIdentifier()];

    UIControlState states[] = {
        UIControlStateNormal,
        UIControlStateHighlighted,
        UIControlStateSelected,
        UIControlStateSelected | UIControlStateHighlighted,
    };

    // The profile button draws the account's avatar over the button's own image,
    // so setting that image is not enough to show the Saved glyph: whatever is on
    // top has to go. Instagram uses a couple of different holders for it (a custom
    // button view, an overlay, or a plain image view added as a subview), and it
    // rebuilds them on layout, so every candidate is swept on every pass. The
    // button's own imageView is what draws the Saved glyph and is left alone.
    NSHashTable<UIView *> *suppressed = objc_getAssociatedObject(button, kSPKSavedTabSuppressedOverlaysKey);
    if (shouldDisplaySaved) {
        if (!suppressed) {
            suppressed = [NSHashTable weakObjectsHashTable];
            objc_setAssociatedObject(button, kSPKSavedTabSuppressedOverlaysKey, suppressed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSMutableArray<UIView *> *candidates = [NSMutableArray array];
        for (NSString *ivar in @[ @"_customView", @"_customOverlayView" ]) {
            UIView *overlay = [SPKUtils getIvarForObj:button name:ivar.UTF8String];
            if ([overlay isKindOfClass:[UIView class]])
                [candidates addObject:overlay];
        }
        // The profile slot draws the account's avatar in a view of its own that is
        // not an image view, and on a multi-account install it is the picture, not
        // a glyph, so nothing but the button's own image may remain. Every other
        // slot only ever draws over its glyph with an image view, and its dots and
        // badges are left alone.
        BOOL drawsAvatar = [identifier isEqualToString:SPKTabIdentifierProfile];
        for (UIView *subview in button.subviews) {
            if (subview == button.imageView || subview == button.titleLabel)
                continue;
            if (drawsAvatar || [subview isKindOfClass:[UIImageView class]])
                [candidates addObject:subview];
        }
        // Only views this hid are remembered, so a view Instagram had already
        // hidden for its own reasons is never revealed later.
        for (UIView *view in candidates) {
            if (view.hidden)
                continue;
            view.hidden = YES;
            [suppressed addObject:view];
        }
        // A slot that drew everything through a custom view may have had no use
        // for its own image view; it is what carries the Saved glyph now.
        if (button.imageView.hidden)
            button.imageView.hidden = NO;
    } else if (suppressed) {
        for (UIView *view in suppressed.allObjects)
            view.hidden = NO;
        objc_setAssociatedObject(button, kSPKSavedTabSuppressedOverlaysKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!shouldDisplaySaved) {
        NSDictionary<NSNumber *, UIImage *> *originalImages = objc_getAssociatedObject(button, kSPKSavedTabOriginalImagesKey);
        for (NSUInteger index = 0; index < sizeof(states) / sizeof(states[0]); index++) {
            UIControlState state = states[index];
            UIImage *originalImage = originalImages[@(state)];
            if (originalImage && [button imageForState:state] != originalImage) {
                [button setImage:originalImage forState:state];
            }
        }
        NSString *originalLabel = objc_getAssociatedObject(button, kSPKSavedTabOriginalLabelKey);
        if (originalLabel && [button.accessibilityLabel isEqualToString:SPKSavedTabAccessibilityLabel()]) {
            button.accessibilityLabel = originalLabel;
        }
        return;
    }

    objc_setAssociatedObject(button, kSPKSavedTabButtonKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, kSPKSavedTabButtonIdentityKey, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);

    if (!objc_getAssociatedObject(button, kSPKSavedTabOriginalLabelKey) &&
        button.accessibilityLabel.length > 0 &&
        ![button.accessibilityLabel isEqualToString:SPKSavedTabAccessibilityLabel()]) {
        objc_setAssociatedObject(button, kSPKSavedTabOriginalLabelKey, button.accessibilityLabel, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }

    for (NSUInteger index = 0; index < sizeof(states) / sizeof(states[0]); index++) {
        UIControlState state = states[index];
        SPKRememberOriginalTabImage(button, state, [button imageForState:state]);
    }

    UIImage *outline = SPKSavedTabImage(NO);
    UIImage *filled = SPKSavedTabImage(YES);

    if (outline && [button imageForState:UIControlStateNormal] != outline) {
        [button setImage:outline forState:UIControlStateNormal];
    }
    if (outline && [button imageForState:UIControlStateHighlighted] != outline) {
        [button setImage:outline forState:UIControlStateHighlighted];
    }
    if (filled && [button imageForState:UIControlStateSelected] != filled) {
        [button setImage:filled forState:UIControlStateSelected];
    }
    if (filled && [button imageForState:UIControlStateSelected | UIControlStateHighlighted] != filled) {
        [button setImage:filled forState:UIControlStateSelected | UIControlStateHighlighted];
    }
    // Writing this unconditionally would loop: the settings-shortcut hook calls
    // -setNeedsLayout from -setAccessibilityLabel:, so every write schedules the
    // pass that writes again.
    if (![button.accessibilityLabel isEqualToString:SPKSavedTabAccessibilityLabel()]) {
        button.accessibilityLabel = SPKSavedTabAccessibilityLabel();
    }
}

// The button the bar is actually showing for an identifier. Going through
// -_buttonForTabBarSurface: rather than the controller's ivars keeps this
// working when Instagram stores a slot somewhere other than the ivar its name
// suggests, which is the case for the camera slot on current builds.
static UIButton *SPKBarButtonForIdentifier(IGTabBarController *controller, NSString *identifier) {
    if (!identifier || [identifier isEqualToString:SPKTabSavedCarrierNone] ||
        ![controller respondsToSelector:@selector(_buttonForTabBarSurface:)])
        return nil;
    NSArray *surfaces = [SPKUtils getIvarForObj:controller name:"_tabBarSurfaces"];
    if (![surfaces isKindOfClass:[NSArray class]])
        return nil;
    for (IGMainAppSurfaceIntent *surface in surfaces) {
        if (![identifier isEqualToString:SPKTabIdentifierForSurface(surface)])
            continue;
        id button = [controller _buttonForTabBarSurface:surface];
        return [button isKindOfClass:[UIButton class]] ? button : nil;
    }
    return nil;
}

// Stamps every tab bar button the controller owns with its Sparkle identifier.
// The ivars are authoritative: accessibility identifiers are only a fallback for
// buttons reached through -layoutSubviews before the controller is available.
static void SPKStampTabButtonIdentities(IGTabBarController *controller) {
    NSDictionary<NSString *, NSString *> *identifiersByIvar = @{
        @"_timelineButton" : SPKTabIdentifierFeed,
        @"_discoverVideoButton" : SPKTabIdentifierClips,
        @"_directInboxButton" : SPKTabIdentifierDirect,
        @"_exploreButton" : SPKTabIdentifierSearch,
        @"_profileButton" : SPKTabIdentifierProfile,
        @"_cameraButton" : SPKTabIdentifierCreate,
    };
    for (NSString *ivar in identifiersByIvar) {
        UIButton *button = [SPKUtils getIvarForObj:controller name:ivar.UTF8String];
        if (button)
            objc_setAssociatedObject(button, kSPKSavedTabButtonIdentityKey, identifiersByIvar[ivar], OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

// Any bar button can be the carrier, so all of them are reconciled: the carrier
// picks up the Saved glyph and every other button gets its original artwork put
// back if it used to be the carrier.
static void SPKConfigureSavedTabButton(IGTabBarController *controller) {
    SPKStampTabButtonIdentities(controller);
    for (NSString *ivar in @[ @"_timelineButton", @"_discoverVideoButton", @"_directInboxButton",
                              @"_exploreButton", @"_profileButton", @"_cameraButton" ])
        SPKConfigureSavedTabButtonInstance([SPKUtils getIvarForObj:controller name:ivar.UTF8String]);

    // The ivars do not always hold the button that is actually on the bar, so
    // the surface map is the authority: it is the same lookup the bar itself
    // uses to place buttons.
    NSString *carrier = SPKSavedCarrierIdentifier();
    UIButton *carrierButton = SPKBarButtonForIdentifier(controller, carrier);
    if (carrierButton) {
        objc_setAssociatedObject(carrierButton, kSPKSavedTabButtonIdentityKey, carrier, OBJC_ASSOCIATION_COPY_NONATOMIC);
        SPKConfigureSavedTabButtonInstance(carrierButton);
    }
}

// Containment only. -presentedViewController resolves through the ancestor chain,
// so every child would re-walk the same presented subtree and the sweep would cost
// exponential time on a deep hierarchy. The tab bar controller is never inside a
// presentation, so there is nothing down there to find anyway.
static IGTabBarController *SPKFindTabBarController(UIViewController *controller) {
    if (!controller)
        return nil;
    if ([controller isKindOfClass:%c(IGTabBarController)])
        return (IGTabBarController *)controller;

    for (UIViewController *child in controller.childViewControllers) {
        IGTabBarController *childMatch = SPKFindTabBarController(child);
        if (childMatch)
            return childMatch;
    }
    return nil;
}

static void SPKConfigureExistingSavedTabButton(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            IGTabBarController *controller = SPKFindTabBarController(window.rootViewController);
            if (controller) {
                SPKConfigureSavedTabButton(controller);
                return;
            }
        }
    }

    IGTabBarController *controller = SPKFindTabBarController(UIApplication.sharedApplication.keyWindow.rootViewController);
    SPKConfigureSavedTabButton(controller);
}

static void SPKScheduleSavedTabButtonReconciliation(void) {
    SPKConfigureExistingSavedTabButton();
    for (NSNumber *delay in @[ @0.25, @1.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SPKConfigureExistingSavedTabButton();
        });
    }
}

static void SPKFinishSavedTabIntent(UINavigationController *navigationController, NSUInteger attempt) {
    UIViewController *top = navigationController.topViewController;
    if (SPKIsSavedViewController(top)) {
        if (objc_getAssociatedObject(navigationController, kSPKSavedTabFallbackHostKey) &&
            navigationController.viewControllers.count != 1) {
            [navigationController setViewControllers:@[ top ] animated:NO];
        }
        objc_setAssociatedObject(navigationController, kSPKSavedTabIntentPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (attempt >= 12) {
        SPKLog(@"TabBar", @"[Sparkle] Timed out waiting for Instagram's Saved controller");
        objc_setAssociatedObject(navigationController, kSPKSavedTabIntentPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKFinishSavedTabIntent(navigationController, attempt + 1);
    });
}

// Instagram's own "open the Saved home" intent. The two-argument initializer is
// the current one; older builds only take the entry module.
static id SPKMakeSavedIntentTarget(void) {
    id target = [NSClassFromString(@"IGSaveHomeIntentTarget") alloc];
    SEL currentInitializer = NSSelectorFromString(@"initWithEntryModule:selectedTab:");
    if ([target respondsToSelector:currentInitializer])
        return ((id (*)(id, SEL, id, id))objc_msgSend)(target, currentInitializer, @"tab_bar", nil);
    SEL legacyInitializer = NSSelectorFromString(@"initWithEntryModule:");
    if ([target respondsToSelector:legacyInitializer])
        return ((id (*)(id, SEL, id))objc_msgSend)(target, legacyInitializer, @"tab_bar");
    return nil;
}

static void SPKOpenSavedInFallbackNavigationController(IGTabBarController *tabBarController,
                                                        UINavigationController *navigationController) {
    if (!navigationController || SPKIsSavedViewController(navigationController.topViewController))
        return;
    if (objc_getAssociatedObject(navigationController, kSPKSavedTabIntentPendingKey))
        return;

    // -fb_intentHandler is a stored per-controller association rather than
    // something every controller carries, so it answers nil unless something
    // installed a handler on that exact object. Newer builds set one on the tab's
    // navigation controller; IG 410 sets none anywhere reachable from this stack
    // (its -fb_fallbackIntentHandlingAncestorVC chain and the tab bar controller
    // were both checked on device and came back empty), so the URL route below is
    // the only way in there. That is expected, not a failure worth a line per tap.
    id<FBIntentHandler> handler = [navigationController respondsToSelector:@selector(fb_intentHandler)]
                                      ? [navigationController fb_intentHandler]
                                      : nil;
    if (![handler respondsToSelector:@selector(handleIntent:)]) {
        static dispatch_once_t noticeToken;
        dispatch_once(&noticeToken, ^{
            SPKLog(@"TabBar", @"[Sparkle] Saved intent handler unavailable; using instagram://saved for this session");
        });
        id userSession = [SPKUtils getIvarForObj:tabBarController name:"_userSession"];
        Class urlHandlerClass = NSClassFromString(@"IGURLHandler");
        SEL openSelector = NSSelectorFromString(@"openInternalURL:presentationConfig:controller:animated:userSession:annotation:");
        if ([urlHandlerClass respondsToSelector:openSelector]) {
            BOOL opened = ((BOOL (*)(id, SEL, id, id, id, BOOL, id, id))objc_msgSend)(urlHandlerClass,
                                                                                       openSelector,
                                                                                       [NSURL URLWithString:@"instagram://saved"],
                                                                                       nil,
                                                                                       navigationController,
                                                                                       NO,
                                                                                       userSession,
                                                                                       nil);
            if (opened) {
                objc_setAssociatedObject(navigationController, kSPKSavedTabIntentPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(navigationController, kSPKSavedTabFallbackHostKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                SPKFinishSavedTabIntent(navigationController, 0);
            }
        }
        return;
    }

    id target = SPKMakeSavedIntentTarget();
    if (!target) {
        SPKLog(@"TabBar", @"[Sparkle] Unable to construct Instagram's Saved intent target");
        return;
    }

    objc_setAssociatedObject(navigationController, kSPKSavedTabIntentPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navigationController, kSPKSavedTabFallbackHostKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(handler, @selector(handleIntent:), target);
    SPKFinishSavedTabIntent(navigationController, 0);
}

static void SPKEnsureSavedTabDestination(IGTabBarController *controller) {
    if (!SPKHasSavedTabDestination())
        return;

    UINavigationController *nativeSavedNavigationController = SPKNativeSavedNavigationController(controller);
    if (nativeSavedNavigationController)
        return;

    UIViewController *selected = controller.selectedViewController;
    UINavigationController *navigationController = [selected isKindOfClass:[UINavigationController class]]
                                                       ? (UINavigationController *)selected
                                                       : nil;
    // Only Reels has a dedicated accessor worth falling back to; for any other
    // carrier the selected controller is the one being redirected.
    if (!navigationController && [SPKSavedCarrierIdentifier() isEqualToString:SPKTabIdentifierClips])
        navigationController = [controller discoverVideoNavigationController];
    SPKOpenSavedInFallbackNavigationController(controller, navigationController);
}

// Shared bookkeeping for the -_setSelectedTabBarSurface: overloads. The shorter
// one forwards to the longer on newer builds, so the work is keyed to the
// outermost call and runs exactly once per selection.
typedef struct {
    BOOL bypassesSaved;
    BOOL selectsSaved;
    BOOL isOutermost;
} SPKSavedTabSelection;

static NSUInteger spk_savedTabSelectionDepth = 0;

static SPKSavedTabSelection SPKBeginSavedTabSelection(IGMainAppSurfaceIntent *surface) {
    BOOL isSavedCarrier = SPKIsSavedCarrierSurface(surface);
    BOOL bypassesSaved = isSavedCarrier && SPKSavedTabRoutingBypassActive();
    SPKSavedTabSelection selection = {
        .bypassesSaved = bypassesSaved,
        .selectsSaved = isSavedCarrier && !bypassesSaved,
        .isOutermost = (spk_savedTabSelectionDepth == 0),
    };
    spk_savedTabSelectionDepth++;
    return selection;
}

static void SPKFinishSavedTabSelection(IGTabBarController *controller, SPKSavedTabSelection selection) {
    if (spk_savedTabSelectionDepth > 0) {
        spk_savedTabSelectionDepth--;
    }
    if (!selection.isOutermost)
        return;

    if (selection.bypassesSaved) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SPKEndSavedTabRoutingBypass();
        });
    }
    if (selection.selectsSaved) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKConfigureSavedTabButton(controller);
            SPKEnsureSavedTabDestination(controller);
        });
    }
}

static BOOL SPKHandleSavedCarrierButtonPress(IGTabBarController *controller, NSString *identifier) {
    if (!identifier || ![SPKSavedCarrierIdentifier() isEqualToString:identifier])
        return NO;
    NSArray *surfaces = [SPKUtils getIvarForObj:controller name:"_tabBarSurfaces"];
    for (IGMainAppSurfaceIntent *surface in surfaces) {
        NSString *surfaceIdentifier = SPKTabIdentifierForSurface(surface);
        if (surfaceIdentifier && [surfaceIdentifier isEqualToString:identifier]) {
            [controller setSelectedTabBarSurface:surface animated:YES];
            SPKConfigureSavedTabButton(controller);
            dispatch_async(dispatch_get_main_queue(), ^{ SPKEnsureSavedTabDestination(controller); });
            return YES;
        }
    }
    return NO;
}

static NSString *SPKSelectorForLaunchTabPreference(NSString *preference) {
    if ([preference isEqualToString:@"feed"])
        return @"_timelineButtonPressed";
    if ([preference isEqualToString:@"reels"])
        return @"_discoverVideoButtonPressed";
    if ([preference isEqualToString:@"inbox"])
        return @"_directInboxButtonPressed";
    if ([preference isEqualToString:@"explore"])
        return @"_exploreButtonPressed";
    if ([preference isEqualToString:@"profile"])
        return @"_profileButtonPressed";
    return nil;
}

static NSString *SPKSelectorForSurfaceIntent(IGMainAppSurfaceIntent *surface) {
    if (!surface || ![surface isKindOfClass:%c(IGMainAppSurfaceIntent)])
        return nil;
    NSString *tab = [surface tabStringFromSurfaceIntent];
    if ([tab isEqualToString:@"FEED"])
        return @"_timelineButtonPressed";
    if ([tab isEqualToString:@"CLIPS"])
        return @"_discoverVideoButtonPressed";
    if ([tab isEqualToString:@"DIRECT"])
        return @"_directInboxButtonPressed";
    if ([tab isEqualToString:@"SEARCH"])
        return @"_exploreButtonPressed";
    if ([tab isEqualToString:@"PROFILE"])
        return @"_profileButtonPressed";
    return nil;
}

BOOL isSurfaceShown(IGMainAppSurfaceIntent *surface) {
    if (SPKStabilityGuardIsSafeStartupMode()) {
        return YES;
    }
    NSString *identifier = SPKTabIdentifierForSurface(surface);
    NSString *carrier = SPKSavedCarrierIdentifier();
    // The Saved carrier is a hidden slot that Sparkle draws as Saved, so its hide
    // flag must not remove it: hiding it is exactly what freed the slot.
    if (identifier && [identifier isEqualToString:carrier])
        return YES;
    NSString *hideKey = identifier ? SPKTabHidePreferenceKey(identifier) : nil;
    if (hideKey.length > 0 && [SPKUtils getBoolPref:hideKey])
        return NO;
    if (SPKIsCreateSurface(surface) && [SPKUtils getBoolPref:@"interface_hide_create_tab"])
        return NO;
    return YES;
}

NSArray *filterSurfacesArray(NSArray *surfaces) {
    if (![surfaces isKindOfClass:[NSArray class]] || SPKStabilityGuardIsSafeStartupMode())
        return surfaces ?: @[];

    NSMutableDictionary<NSString *, id> *knownSurfaces = [NSMutableDictionary dictionary];
    NSMutableArray *unknownSurfaces = [NSMutableArray array];
    for (id surface in surfaces) {
        NSString *identifier = SPKTabIdentifierForSurface(surface);
        if (identifier.length > 0 && !knownSurfaces[identifier])
            knownSurfaces[identifier] = surface;
        else if (!identifier)
            [unknownSurfaces addObject:surface];
    }

    NSString *layout = SPKNormalizedTabLayout([SPKUtils getStringPref:SPKPrefTabLayout]);
    if ([layout isEqualToString:SPKTabLayoutClassic]) {
        NSMutableArray *classic = [NSMutableArray array];
        for (id surface in surfaces) {
            if (isSurfaceShown(surface)) [classic addObject:surface];
        }
        BOOL hasDestination = NO;
        for (id surface in classic) {
            if (SPKTabIdentifierForSurface(surface)) { hasDestination = YES; break; }
        }
        if (!hasDestination) {
            id fallback = knownSurfaces[SPKTabIdentifierFeed];
            if (!fallback) {
                for (NSString *identifier in SPKCanonicalTabIdentifiers()) {
                    if (knownSurfaces[identifier]) { fallback = knownSurfaces[identifier]; break; }
                }
            }
            if (fallback) [classic insertObject:fallback atIndex:0];
        }
        return classic;
    }

    NSString *savedCarrier = SPKSavedCarrierIdentifier();
    BOOL usesCustomOrder = [layout isEqualToString:SPKTabLayoutCustom];
    NSArray<NSString *> *order = usesCustomOrder
                                     ? SPKNormalizeTabOrder([NSUserDefaults.standardUserDefaults objectForKey:SPKPrefCustomTabOrder])
                                     : SPKCanonicalTabIdentifiers();
    NSMutableArray *transformed = [NSMutableArray array];
    for (NSString *identifier in order) {
        // Saved has no surface of its own: it is drawn by the carrier, which is
        // why the carrier is skipped where its own identifier appears. Outside a
        // custom order there is no Saved entry, so the carrier keeps its native
        // position and simply renders as Saved.
        BOOL isSavedEntry = [identifier isEqualToString:SPKTabIdentifierSaved];
        if (isSavedEntry && !SPKHasSavedTabDestination())
            continue;
        if (usesCustomOrder && !isSavedEntry && [identifier isEqualToString:savedCarrier])
            continue;
        id surface = knownSurfaces[isSavedEntry ? savedCarrier : identifier];
        if (surface && isSurfaceShown(surface)) [transformed addObject:surface];
    }
    // Keep Instagram surfaces Sparkle does not know about, in their native
    // relative order, so a future app update does not silently delete them.
    for (id surface in unknownSurfaces) {
        if (isSurfaceShown(surface)) [transformed addObject:surface];
    }

    BOOL hasDestination = NO;
    for (id surface in transformed) {
        if (SPKTabIdentifierForSurface(surface)) { hasDestination = YES; break; }
    }
    if (!hasDestination) {
        id fallback = knownSurfaces[SPKTabIdentifierFeed];
        if (!fallback) {
            for (NSString *identifier in SPKCanonicalTabIdentifiers()) {
                if (knownSurfaces[identifier]) { fallback = knownSurfaces[identifier]; break; }
            }
        }
        if (fallback) [transformed insertObject:fallback atIndex:0];
    }
    return transformed;
}

// Instagram assembles the tab bar from its own fixed button list and only uses
// the surface array to decide which buttons survive, so reordering
// _tabBarSurfaces changes the index each surface maps to without moving a single
// glyph. The visual order is decided exclusively by the order buttons are handed
// to the bar, which is what this re-applies. Both arrays end up in the same
// order, which is also what keeps the selection indicator on the right button.
static void SPKApplyCustomTabButtonOrder(IGTabBarController *controller) {
    if (SPKStabilityGuardIsSafeStartupMode())
        return;
    if (![SPKNormalizedTabLayout([SPKUtils getStringPref:SPKPrefTabLayout]) isEqualToString:SPKTabLayoutCustom])
        return;

    id<SPKTabBarViewRepresentable> bar = (id<SPKTabBarViewRepresentable>)controller.tabBar;
    if (![bar respondsToSelector:@selector(addTabButton:)] ||
        ![bar respondsToSelector:@selector(clearTabButtons)] ||
        ![bar respondsToSelector:@selector(buttons)] ||
        ![controller respondsToSelector:@selector(_buttonForTabBarSurface:)])
        return;

    NSArray *surfaces = [SPKUtils getIvarForObj:controller name:"_tabBarSurfaces"];
    if (![surfaces isKindOfClass:[NSArray class]] || surfaces.count == 0)
        return;

    id selectedSurface = [controller respondsToSelector:@selector(selectedTabBarSurface)]
                             ? [controller selectedTabBarSurface]
                             : nil;
    NSMutableArray<UIView *> *desired = [NSMutableArray array];
    NSInteger selectedIndex = NSNotFound;
    for (id surface in surfaces) {
        id button = [controller _buttonForTabBarSurface:surface];
        if (![button isKindOfClass:[UIView class]])
            continue;
        if (selectedSurface && surface == selectedSurface)
            selectedIndex = (NSInteger)desired.count;
        [desired addObject:button];
    }
    if (desired.count == 0)
        return;

    NSArray *current = bar.buttons;
    if ([current isKindOfClass:[NSArray class]] && [current isEqualToArray:desired])
        return;

    [bar clearTabButtons];
    for (UIView *button in desired)
        [bar addTabButton:button];
    if (selectedIndex != NSNotFound && [bar respondsToSelector:@selector(setSelectedTabBarItemIndex:)])
        [bar setSelectedTabBarItemIndex:selectedIndex];
    [controller.tabBar setNeedsLayout];
}

// Instagram rewrites _tabBarSurfaces with its own unfiltered list whenever it
// repopulates the bar, and derives the selected button index from that ivar. A
// selection made in that window lands on the index the surface has in the full
// list, so with Feed hidden, picking Reels lights up the button after it.
static void SPKFilterTabBarSurfacesIvar(IGTabBarController *controller) {
    NSArray *surfaces = [SPKUtils getIvarForObj:controller name:"_tabBarSurfaces"];
    if ([surfaces isKindOfClass:[NSArray class]])
        [SPKUtils setIvarForObj:controller name:"_tabBarSurfaces" value:filterSurfacesArray(surfaces)];
}

static void SPKSyncTabBarSelectionIndex(IGTabBarController *controller) {
    if (SPKStabilityGuardIsSafeStartupMode())
        return;
    id<SPKTabBarViewRepresentable> bar = (id<SPKTabBarViewRepresentable>)controller.tabBar;
    if (![bar respondsToSelector:@selector(setSelectedTabBarItemIndex:)] ||
        ![controller respondsToSelector:@selector(selectedTabBarSurface)])
        return;
    id selectedSurface = [controller selectedTabBarSurface];
    NSArray *surfaces = [SPKUtils getIvarForObj:controller name:"_tabBarSurfaces"];
    if (!selectedSurface || ![surfaces isKindOfClass:[NSArray class]])
        return;
    NSUInteger index = [surfaces indexOfObject:selectedSurface];
    if (index != NSNotFound)
        [bar setSelectedTabBarItemIndex:(NSInteger)index];
}

// Should the tab bar be taken away entirely? Only when the configuration leaves
// exactly one tab, and only for a tab that keeps a way back into Sparkle
// Settings without the tab bar long-press.
static BOOL SPKShouldHideTabBarForSingleTab(void) {
    if (![SPKUtils getBoolPref:@"interface_hide_tab_bar_in_messages_only"])
        return NO;
    NSString *single = SPKSingleVisibleTabIdentifierFromPreferences();
    return single != nil && SPKSingleTabAllowsHidingTabBar(single);
}

///////////////////////////////////////////////

// Installed separately from the rest of the navigation hooks: this one runs on
// every layout pass of every tab bar button, so users who only reordered or hid
// tabs should not pay for it.
//
// -layoutSubviews is the only re-entry point worth hooking here. The obvious
// alternatives, -setImage:forState: and -setAccessibilityIdentifier:, are
// inherited from UIButton/UIView rather than implemented by IGTabBarButton, and
// hooking a method a class only inherits does not reliably bind. Re-applying the
// icon on the next layout pass covers the same ground: whenever Instagram puts
// its own image back, the pass that follows swaps it out again.
%group SPKSavedTabButtonHooks

%hook IGTabBarButton
- (void)layoutSubviews {
    %orig;
    SPKConfigureSavedTabButtonInstance(self);
}
%end

%end

%group SPKNavigationHooks

%hook IGTabBarControllerSwipeCoordinator
- (id)initWithSurfaces:(id)surfaces parentViewController:(id)controller enableHaptics:(_Bool)haptics launcherSet:(id)set {
    // Removes the surface from the main swipeable app collection view
    NSArray *filtered = filterSurfacesArray(surfaces);
    return %orig(filtered, controller, haptics, set);
}

// Instagram rebuilds its own surface list whenever it repopulates the tab bar
// and, on finding it differs from the filtered one, hands the fresh list to the
// coordinator here. Left unfiltered, hidden tabs come back in the swipe while
// staying out of the bar.
- (void)updateSurfaces:(id)surfaces {
    %orig(filterSurfacesArray(surfaces));
}
%end

%hook IGTabBarController
- (void)viewDidLoad {
    %orig;
    NSArray *surfaces = [SPKUtils getIvarForObj:self name:"_tabBarSurfaces"];
    if (surfaces) {
        [SPKUtils setIvarForObj:self name:"_tabBarSurfaces" value:filterSurfacesArray(surfaces)];
    }
    SPKConfigureSavedTabButton(self);
}

- (void)_createAndConfigureReelsButtonIfNeeded {
    %orig;
    SPKConfigureSavedTabButton(self);
}

- (id)navigationViewControllerForAppSurfaceIntent:(IGMainAppSurfaceIntent *)surface {
    if (SPKHasSavedTabDestination() &&
        !SPKSavedTabRoutingBypassActive() &&
        SPKIsSavedCarrierSurface(surface)) {
        UINavigationController *savedNavigationController = SPKNativeSavedNavigationController(self);
        if (savedNavigationController)
            return savedNavigationController;
    }
    return %orig;
}

// Each of these runs %orig untouched unless that exact tab is the Saved carrier.
- (void)_timelineButtonPressed {
    if (!SPKHandleSavedCarrierButtonPress(self, SPKTabIdentifierFeed)) %orig;
}

- (void)_discoverVideoButtonPressed {
    if (!SPKHandleSavedCarrierButtonPress(self, SPKTabIdentifierClips)) %orig;
}

- (void)_directInboxButtonPressed {
    if (!SPKHandleSavedCarrierButtonPress(self, SPKTabIdentifierDirect)) %orig;
}

- (void)_exploreButtonPressed {
    if (!SPKHandleSavedCarrierButtonPress(self, SPKTabIdentifierSearch)) %orig;
}

- (void)_profileButtonPressed {
    if (!SPKHandleSavedCarrierButtonPress(self, SPKTabIdentifierProfile)) %orig;
}

- (void)_setSelectedTabBarSurface:(IGMainAppSurfaceIntent *)surface
                   isTabBarAction:(BOOL)isTabBarAction
                         animated:(BOOL)animated
                 navigationAction:(NSUInteger)navigationAction
                skipMainFeedFetch:(BOOL)skipMainFeedFetch {
    SPKFilterTabBarSurfacesIvar(self);
    SPKSavedTabSelection selection = SPKBeginSavedTabSelection(surface);
    %orig;
    SPKFinishSavedTabSelection(self, selection);
}

// IG added a second overload carrying a trailing animateIndicator:, and call
// sites use whichever they were written against. Both have to do the same
// bookkeeping or the routing bypass is never torn down on the newer path.
- (void)_setSelectedTabBarSurface:(IGMainAppSurfaceIntent *)surface
                   isTabBarAction:(BOOL)isTabBarAction
                         animated:(BOOL)animated
                 navigationAction:(NSUInteger)navigationAction
                skipMainFeedFetch:(BOOL)skipMainFeedFetch
                  animateIndicator:(BOOL)animateIndicator {
    SPKFilterTabBarSurfacesIvar(self);
    SPKSavedTabSelection selection = SPKBeginSavedTabSelection(surface);
    %orig;
    SPKFinishSavedTabSelection(self, selection);
}

- (void)viewDidLayoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"Navigation.viewDidLayoutSubviews");
    if (SPKStabilityGuardIsSafeStartupMode()) {
        return;
    }
    if (SPKShouldHideTabBarForSingleTab()) {
        self.tabBar.hidden = YES;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (SPKStabilityGuardIsSafeStartupMode())
        return;

    static BOOL appliedLaunchTab = NO;
    if (appliedLaunchTab)
        return;
    appliedLaunchTab = YES;

    NSString *launchPref = [SPKUtils getStringPref:@"interface_launch_tab"];
    NSString *selectorName = SPKSelectorForLaunchTabPreference(launchPref);

    NSArray *rawSurfaces = [SPKUtils getIvarForObj:self name:"_tabBarSurfaces"];
    NSArray *enabledSurfaces = filterSurfacesArray(rawSurfaces);

    BOOL feedHidden = [SPKUtils getBoolPref:@"interface_hide_feed_tab"];

    BOOL usesCustomOrder = [SPKNormalizedTabLayout([SPKUtils getStringPref:SPKPrefTabLayout])
        isEqualToString:SPKTabLayoutCustom];

    if ([launchPref isEqualToString:@"default"]) {
        BOOL feedIsEnabled = NO;
        for (IGMainAppSurfaceIntent *s in enabledSurfaces) {
            if ([[s tabStringFromSurfaceIntent] isEqualToString:@"FEED"]) {
                feedIsEnabled = YES;
                break;
            }
        }
        if (usesCustomOrder && enabledSurfaces.count > 0) {
            // Instagram always opens on Feed regardless of where Feed sits in the
            // bar, which leaves a custom layout showing the feed under a first tab
            // that is drawn selected. "Default" in a custom layout means the first
            // tab the user arranged.
            selectorName = SPKSelectorForSurfaceIntent(enabledSurfaces.firstObject);
        } else if ((!feedIsEnabled || feedHidden) && enabledSurfaces.count > 0) {
            selectorName = SPKSelectorForSurfaceIntent(enabledSurfaces.firstObject);
        } else if (feedHidden) {
            // Fallback preference check if surface array is unavailable
            if (![SPKUtils getBoolPref:@"interface_hide_msgs_tab"]) {
                selectorName = @"_directInboxButtonPressed";
            } else if (![SPKUtils getBoolPref:@"interface_hide_reels_tab"]) {
                selectorName = @"_discoverVideoButtonPressed";
            } else if (![SPKUtils getBoolPref:@"interface_hide_explore_tab"]) {
                selectorName = @"_exploreButtonPressed";
            } else if (![SPKUtils getBoolPref:@"interface_hide_profile_tab"]) {
                selectorName = @"_profileButtonPressed";
            }
        }
    } else if (selectorName.length > 0) {
        BOOL chosenIsEnabled = NO;
        for (IGMainAppSurfaceIntent *s in enabledSurfaces) {
            NSString *sel = SPKSelectorForSurfaceIntent(s);
            if ([sel isEqualToString:selectorName]) {
                chosenIsEnabled = YES;
                break;
            }
        }
        if (!chosenIsEnabled && enabledSurfaces.count > 0) {
            selectorName = SPKSelectorForSurfaceIntent(enabledSurfaces.firstObject);
        }
    }

    SEL selector = selectorName.length > 0 ? NSSelectorFromString(selectorName) : nil;
    if (selector && [self respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(self, selector);
        SPKFilterTabBarSurfacesIvar(self);
        SPKSyncTabBarSelectionIndex(self);
    }

    if (!SPKStabilityGuardIsSafeStartupMode()) {
        if ([self respondsToSelector:@selector(_updateTabBarVisibilityForController:)] && self.selectedViewController) {
            [self _updateTabBarVisibilityForController:self.selectedViewController];
        }
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SPKConfigureSavedTabButton(self);
    if (SPKStabilityGuardIsSafeStartupMode()) {
        return;
    }
    if (SPKShouldHideTabBarForSingleTab()) {
        if ([self respondsToSelector:@selector(_updateTabBarVisibilityForController:)] && self.selectedViewController) {
            [self _updateTabBarVisibilityForController:self.selectedViewController];
        }
    }
}

- (void)_layoutTabBar {
    // Prevents the wrong icon from being shown as selected because of mismatched surface array indexes
    NSArray *_tabBarSurfaces = [SPKUtils getIvarForObj:self name:"_tabBarSurfaces"];

    [SPKUtils setIvarForObj:self name:"_tabBarSurfaces" value:filterSurfacesArray(_tabBarSurfaces)];

    %orig;
    SPKConfigureSavedTabButton(self);
    SPKApplyCustomTabButtonOrder(self);
}

- (id)_buttonForTabBarSurface:(id)surface {
    // Prevents the button from being added to the tab bar
    id button = %orig(surface);

    if (!isSurfaceShown(surface)) {
        return nil;
    }

    return button;
}

- (BOOL)_shouldTabBarBeHiddenForController:(id)controller {
    if (SPKStabilityGuardIsSafeStartupMode()) {
        return %orig;
    }
    if (SPKShouldHideTabBarForSingleTab()) {
        return YES;
    }
    return %orig;
}
%end

// Demangled name: IGNavConfiguration.IGNavConfiguration
%hook _TtC18IGNavConfiguration18IGNavConfiguration
- (NSInteger)tabOrdering {
    if (SPKStabilityGuardIsSafeStartupMode())
        return %orig;
    NSString *layout = SPKNormalizedTabLayout([SPKUtils getStringPref:SPKPrefTabLayout]);
    if ([layout isEqualToString:SPKTabLayoutClassic])
        return 0;
    // Both Default and Custom use Instagram's standard five-carrier topology.
    // Custom only changes the shared transformed ordering of those carriers.
    return 1;
}
- (void)setTabOrdering:(NSInteger)arg1 {
    if (SPKStabilityGuardIsSafeStartupMode()) {
        %orig;
    }
}

- (BOOL)isTabSwipingEnabled {
    if (SPKStabilityGuardIsSafeStartupMode())
        return %orig;

    if ([[SPKUtils getStringPref:@"interface_swipe_tabs"] isEqualToString:@"enabled"])
        return YES;
    else if ([[SPKUtils getStringPref:@"interface_swipe_tabs"] isEqualToString:@"disabled"])
        return NO;

    return %orig;
}
- (void)setIsTabSwipingEnabled:(BOOL)arg1 {
    if (SPKStabilityGuardIsSafeStartupMode() ||
        [[SPKUtils getStringPref:@"interface_swipe_tabs"] isEqualToString:@"default"]) {
        %orig;
    }
}
%end

%hook IGHomeFeedHeaderView
- (void)didMoveToWindow {
    %orig;
    SPK_PERF_SCOPE(@"Navigation.didMoveToWindow");

    if (SPKStabilityGuardIsSafeStartupMode())
        return;

    if (SPKMessagesTabHidden()) {
        // IG 436+ is a Swift class: the DM button is the `directButton` @property
        // (KVC-safe). `rightButton` is a bare Swift ivar on 436 (KVC throws) but the
        // KVC key on older ObjC builds — resolve via selector first, guard the rest.
        UIView *msgsButton = nil;
        for (NSString *key in @[ @"directButton", @"rightButton" ]) {
            SEL getter = NSSelectorFromString(key);
            if (![self respondsToSelector:getter])
                continue;
            id candidate = ((id (*)(id, SEL))objc_msgSend)(self, getter);
            if ([candidate isKindOfClass:[UIView class]]) {
                msgsButton = candidate;
                break;
            }
        }
        if (msgsButton) {
            SPKLog(@"General", @"[Sparkle] Hiding messages tab (on feed)");

            [msgsButton removeFromSuperview];
        }
    }
}
%end

%hook IGMainAppScrollingContainerViewController
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (SPKStabilityGuardIsSafeStartupMode())
        return %orig;
    if (![gesture isKindOfClass:[UIPanGestureRecognizer class]])
        return %orig;

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gesture;
    CGPoint velocity = [pan velocityInView:pan.view];
    CGPoint translation = [pan translationInView:pan.view];
    UIViewController *activeVC = [SPKUtils getIvarForObj:self name:"_activeViewController"];

    // Dragging right reveals the camera that sits to the left of the tabs.
    if ([SPKUtils getBoolPref:@"interface_hide_feed_tab"] && (velocity.x > 0 || translation.x > 0)) {
        UIViewController *creationVC = [SPKUtils getIvarForObj:self name:"_creationViewController"];
        if (activeVC && creationVC && activeVC != creationVC)
            return NO;
    }

    // Dragging left reveals the inbox that sits to the right of them. Without
    // this, hiding the Messages tab would only remove the way in that you can
    // see while the swipe kept working.
    if (SPKMessagesTabHidden() && (velocity.x < 0 || translation.x < 0)) {
        UIViewController *inboxVC = [SPKUtils getIvarForObj:self name:"_directInboxNavController"];
        if (activeVC && inboxVC && activeVC != inboxVC)
            return NO;
    }
    return %orig;
}
%end

%end

extern "C" void SPKInstallNavigationHooksIfNeeded(void) {
    SPKMigrateTabConfigurationIfNeeded();

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKNavigationHooks,
                       IGHomeFeedHeaderView = SPKResolveIGClass(@"IGHomeFeedHeader.IGHomeFeedHeaderView", @"IGHomeFeedHeaderView"));
        if (SPKSavedTabPreferenceMayEnable()) {
            %init(SPKSavedTabButtonHooks);
            [[NSNotificationCenter defaultCenter] addObserverForName:SPKAccountDidChangeNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(__unused NSNotification *notification) {
                SPKScheduleSavedTabButtonReconciliation();
            }];
            dispatch_async(dispatch_get_main_queue(), ^{
                SPKScheduleSavedTabButtonReconciliation();
            });
        }
    });
}
