#import "HeaderActionButton.h"
#import "SPKStrings.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Shared/Account/SPKAccountManager.h"
#import "../../Shared/Downloads/SPKDownloadService.h"
#import "../../Shared/Navigation/SPKDestinations.h"
#import "../../Shared/Navigation/SPKTabConfiguration.h"
#import "../../Shared/Gallery/SPKGalleryViewController.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Shared/UI/SPKChromeGlassMirror.h"
#import "../../Shared/UI/SPKSideColumn.h"
#import "../../Utils.h"
#import "../Messages/DeletedMessagesLog/SPKDeletedMessagesViewController.h"
#import "../Profile/ProfileAnalyzer/SPKProfileAnalyzerViewController.h"
#import "../../App/SPKPerfMeter.h"

NSString *const kSPKHeaderButtonEnabledKey = @"feed_header_button";
NSString *const kSPKHeaderButtonDefaultActionKey = @"feed_header_button_default";
NSString *const kSPKHeaderButtonDefaultActionMenu = @"menu";

// Destination identifiers double as the suffix of their per-destination pref key.

// IG-bundle icon name for the button's "Open Menu" glyph (same one every other
// Sparkle action button uses for its menu default).
static NSString *const kSPKHeaderMenuIconName = @"action";

static NSString *SPKHeaderDestPrefKey(NSString *identifier) {
    return [NSString stringWithFormat:@"feed_header_button_dest_%@", identifier];
}

// Layout constants.
static const CGFloat kSPKHeaderButtonSide = 44.0;    // button footprint
static const CGFloat kSPKHeaderButtonGlyph = 24.0;   // glyph point size
static const CGFloat kSPKHeaderButtonSpacing = 8.0;
static const CGFloat kSPKHeaderButtonLeftInset = 16.0;

// This button lives in the Direct inbox header, so it is only offered when
// Messages is the one tab the configuration leaves standing.
static BOOL SPKIsMessagesOnlyMode(void) {
    return [SPKSingleVisibleTabIdentifierFromPreferences() isEqualToString:SPKTabIdentifierDirect];
}

static const void *kSPKInboxHeaderButtonAssocKey = &kSPKInboxHeaderButtonAssocKey;
static const void *kSPKInboxHeaderButtonLastFrameAssocKey = &kSPKInboxHeaderButtonLastFrameAssocKey;
static const void *kSPKInboxHeaderGlassViewKey = &kSPKInboxHeaderGlassViewKey;

static const void *kSPKHeaderButtonAssocKey = &kSPKHeaderButtonAssocKey;
static const void *kSPKHeaderButtonConfigSignatureAssocKey = &kSPKHeaderButtonConfigSignatureAssocKey;
static const void *kSPKHeaderButtonLastFrameAssocKey = &kSPKHeaderButtonLastFrameAssocKey;
static const void *kSPKHeaderGlassViewKey = &kSPKHeaderGlassViewKey;

#pragma mark - Destination model

@interface SPKHeaderDestination ()
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *iconName;   // IG-bundle icon name
@property (nonatomic, copy) NSString *prefKey;
@property (nonatomic, copy) void (^present)(UIWindow *_Nullable);
@end

@implementation SPKHeaderDestination
+ (instancetype)destinationWithIdentifier:(NSString *)identifier
                                    title:(NSString *)title
                                 iconName:(NSString *)iconName
                                  present:(void (^)(UIWindow *_Nullable))present {
    SPKHeaderDestination *destination = [SPKHeaderDestination new];
    destination.identifier = identifier;
    destination.title = title;
    destination.iconName = iconName;
    destination.prefKey = SPKHeaderDestPrefKey(identifier);
    destination.present = present;
    return destination;
}
@end

// The destinations come from the shared list that tab holds also use; the
// header keeps its own on/off switch for each.
NSArray<SPKHeaderDestination *> *SPKHeaderButtonAllDestinations(void) {
    static NSArray<SPKHeaderDestination *> *destinations;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<SPKHeaderDestination *> *built = [NSMutableArray array];
        for (SPKDestination *shared in SPKDestinationsForPlacement(SPKDestinationPlacementHeaderButton)) {
            [built addObject:[SPKHeaderDestination destinationWithIdentifier:shared.identifier
                                                                       title:shared.title
                                                                    iconName:shared.iconName
                                                                     present:^(UIWindow *window) {
                                                                         [shared openFromWindow:window];
                                                                     }]];
        }
        destinations = built;
    });
    return destinations;
}

NSArray<SPKHeaderDestination *> *SPKHeaderButtonEnabledDestinations(void) {
    NSMutableArray<SPKHeaderDestination *> *enabled = [NSMutableArray array];
    for (SPKHeaderDestination *destination in SPKHeaderButtonAllDestinations()) {
        if ([SPKUtils getBoolPref:destination.prefKey])
            [enabled addObject:destination];
    }
    return enabled;
}

static SPKHeaderDestination *SPKHeaderDestinationForIdentifier(NSString *identifier) {
    for (SPKHeaderDestination *destination in SPKHeaderButtonAllDestinations()) {
        if ([destination.identifier isEqualToString:identifier])
            return destination;
    }
    return nil;
}

NSString *SPKHeaderButtonResolvedDefaultActionIdentifier(void) {
    NSString *saved = [SPKUtils getStringPref:kSPKHeaderButtonDefaultActionKey];
    SPKHeaderDestination *destination = SPKHeaderDestinationForIdentifier(saved);
    if (destination && [SPKUtils getBoolPref:destination.prefKey])
        return destination.identifier;
    return kSPKHeaderButtonDefaultActionMenu;
}

NSString *SPKHeaderButtonDefaultActionTitle(void) {
    NSString *identifier = SPKHeaderButtonResolvedDefaultActionIdentifier();
    SPKHeaderDestination *destination = SPKHeaderDestinationForIdentifier(identifier);
    return destination ? destination.title : SPKL(@"FEED_HEADER_ACTION_BUTTON_OPEN_MENU_TEXT");
}

NSString *SPKHeaderButtonDefaultActionIconName(void) {
    NSString *identifier = SPKHeaderButtonResolvedDefaultActionIdentifier();
    SPKHeaderDestination *destination = SPKHeaderDestinationForIdentifier(identifier);
    return destination ? destination.iconName : kSPKHeaderMenuIconName;
}

#pragma mark - Header button view

// SPKChromeButton hosts the glyph in a secure canvas that morphs correctly with
// the iOS 26 menu-glass animation (same base every other Sparkle action button
// uses), so the button never vanishes mid-morph.
@interface SPKFeedHeaderActionButton : SPKChromeButton
@end

@implementation SPKFeedHeaderActionButton
- (void)spk_primaryTapped {
    NSString *defaultAction = [SPKUtils getStringPref:kSPKHeaderButtonDefaultActionKey];
    SPKHeaderDestination *destination = SPKHeaderDestinationForIdentifier(defaultAction);
    if (!destination || ![SPKUtils getBoolPref:destination.prefKey]) {
        SPKLog(@"HeaderButton", @"[Sparkle] Primary tap fired with no valid destination (default=%@)", defaultAction);
        return;
    }
    SPKLog(@"HeaderButton", @"[Sparkle] Primary tap → %@", destination.identifier);
    if (destination.present)
        destination.present(self.window);
}
@end

static void SPKHeaderFireShortcutHaptic(void) {
    if (![SPKUtils getBoolPref:@"tools_shortcut_haptics"])
        return;
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
}

// Resolve one of a set of KVC-safe getters to a UIView (Swift ivars throw on KVC,
// so we go through selectors and type-check — same pattern as Navigation.xm).
static UIView *SPKHeaderSubview(id header, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        SEL getter = NSSelectorFromString(key);
        if (![header respondsToSelector:getter])
            continue;
        id candidate = ((id (*)(id, SEL))objc_msgSend)(header, getter);
        if ([candidate isKindOfClass:[UIView class]])
            return candidate;
    }
    return nil;
}

// The logo / feed picker by class: the Swift header does not expose logoButton to
// the runtime. Only used for the button's height and fade, never its x position.
static UIView *SPKHeaderLogoView(UIView *header) {
    Class cls = NSClassFromString(@"IGImageWithAccessoryButton");
    if (!cls)
        return nil;
    NSMutableArray<UIView *> *queue = [header.subviews mutableCopy];
    for (NSUInteger i = 0; i < queue.count && i < 64; i++) {
        if ([queue[i] isKindOfClass:cls])
            return queue[i];
        [queue addObjectsFromArray:queue[i].subviews];
    }
    return nil;
}

static const CGFloat kSPKHeaderColumnGap = 10.0;
static const CGFloat kSPKHeaderColumnSlot = 48.0; // a vertical bar item's footprint
static const CGFloat kSPKHeaderColumnEdgeInset = 24.0; // vertical bar items' gap to the display edge

// The glass group holding the tabs when the tab bar runs vertically down a side
// column; nil (horizontal bar, older iOS, renamed class) keeps the button in the
// header.
static UIView *SPKVerticalTabPlatter(UIView *header) {
    return SPKSideColumnTabPlatter([SPKUtils nearestViewControllerForView:header].tabBarController.view);
}

// Bottom edge, in `view`'s space, of the system-reserved area (status items and
// camera) at the top of the side column, or NAN when the system reserves none
// there. The vertical bar starts its first item right below it.
static CGFloat SPKColumnOcclusionMaxY(UIView *view, CGRect columnFrame) {
    Class kindClass = NSClassFromString(@"UIViewReservedRegionKind");
    SEL kindSel = NSSelectorFromString(@"occlusionRegionKind");
    SEL regionsSel = NSSelectorFromString(@"reservedRegionsOfKind:");
    if (!kindClass || ![kindClass respondsToSelector:kindSel] || ![view respondsToSelector:regionsSel])
        return NAN;
    id kind = ((id (*)(id, SEL))objc_msgSend)(kindClass, kindSel);
    NSArray *regions = kind ? ((id (*)(id, SEL, id))objc_msgSend)(view, regionsSel, kind) : nil;
    if (![regions isKindOfClass:[NSArray class]])
        return NAN;
    CGFloat maxY = NAN;
    for (id region in regions) {
        @try {
            if (![[region valueForKey:@"active"] boolValue])
                continue;
            CGRect frame = [[region valueForKey:@"frame"] CGRectValue];
            if (CGRectGetMidX(frame) < CGRectGetMinX(columnFrame) || CGRectGetMidX(frame) > CGRectGetMaxX(columnFrame))
                continue;
            if (CGRectGetMinY(frame) > CGRectGetMinY(columnFrame))
                continue;
            maxY = isnan(maxY) ? CGRectGetMaxY(frame) : MAX(maxY, CGRectGetMaxY(frame));
        } @catch (__unused NSException *e) {
        }
    }
    return maxY;
}

// The system-reserved region (status items) at the top of a side column that
// starts at or past `minX` in `view`'s space, or CGRectNull when there is none.
static CGRect SPKColumnStatusRegion(UIView *view, CGFloat minX) {
    Class kindClass = NSClassFromString(@"UIViewReservedRegionKind");
    SEL kindSel = NSSelectorFromString(@"occlusionRegionKind");
    SEL regionsSel = NSSelectorFromString(@"reservedRegionsOfKind:");
    if (!kindClass || ![kindClass respondsToSelector:kindSel] || ![view respondsToSelector:regionsSel])
        return CGRectNull;
    id kind = ((id (*)(id, SEL))objc_msgSend)(kindClass, kindSel);
    NSArray *regions = kind ? ((id (*)(id, SEL, id))objc_msgSend)(view, regionsSel, kind) : nil;
    if (![regions isKindOfClass:[NSArray class]])
        return CGRectNull;
    CGRect best = CGRectNull;
    for (id region in regions) {
        @try {
            if (![[region valueForKey:@"active"] boolValue])
                continue;
            CGRect frame = [[region valueForKey:@"frame"] CGRectValue];
            if (CGRectGetMinX(frame) < minX - 1.0 || CGRectGetMinY(frame) > 1.0)
                continue;
            best = CGRectIsNull(best) ? frame : CGRectUnion(best, frame);
        } @catch (__unused NSException *e) {
        }
    }
    return best;
}

@interface UIView (SPKHeaderButton)
- (SPKFeedHeaderActionButton *)spk_headerActionButton;
- (void)spk_installHeaderActionButtonIfNeeded;
- (void)spk_layoutHeaderActionButton;
- (BOOL)spk_layoutHeaderActionButton:(SPKFeedHeaderActionButton *)button inColumnAbovePlatter:(UIView *)platter;
- (BOOL)spk_layoutHeaderActionButton:(SPKFeedHeaderActionButton *)button belowColumnItem:(UIView *)item;
- (UIView *)spk_headerColumnGlassForButton:(SPKFeedHeaderActionButton *)button;
- (void)spk_configureHeaderActionButton:(SPKFeedHeaderActionButton *)button;
- (void)spk_updateHeaderGlass:(SPKFeedHeaderActionButton *)button;
@end

@implementation UIView (SPKHeaderButton)

- (SPKFeedHeaderActionButton *)spk_headerActionButton {
    return objc_getAssociatedObject(self, kSPKHeaderButtonAssocKey);
}

- (void)spk_installHeaderActionButtonIfNeeded {
    if ([self spk_headerActionButton])
        return;

    SPKFeedHeaderActionButton *button = [[SPKFeedHeaderActionButton alloc] initWithSymbol:@""
                                                                                pointSize:kSPKHeaderButtonGlyph
                                                                                 diameter:kSPKHeaderButtonSide];
    button.accessibilityIdentifier = @"spk-header-action-button";
    button.accessibilityLabel = SPKL(@"ABOUT_INFORMATION_SPARKLE_TITLE");
    button.translatesAutoresizingMaskIntoConstraints = YES;
    button.bubbleColor = UIColor.clearColor;

    UIView *heart = SPKHeaderSubview(self, @[ @"activityButton" ]);
    button.iconTint = heart.tintColor ?: [UIColor labelColor];

    __weak SPKFeedHeaderActionButton *weakButton = button;
    button.menuWillDisplayHandler = ^{
        (void)weakButton;
        SPKHeaderFireShortcutHaptic();
    };
    [button addTarget:button action:@selector(spk_primaryTapped) forControlEvents:UIControlEventTouchUpInside];

    objc_setAssociatedObject(self, kSPKHeaderButtonAssocKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addSubview:button];
    SPKLog(@"HeaderButton", @"[Sparkle] Installed header action button into %@", NSStringFromClass(self.class));

    [self spk_configureHeaderActionButton:button];
}

// Signature of everything the button's menu / glyph depend on, so we only rebuild
// them when the user actually changes prefs — never during a layout/menu morph.
// (IG writes NSUserDefaults nearly every scroll frame, so a defaults-change
// observer is useless here — it would fire constantly; a value compare is what
// actually gates the work.)
static NSString *SPKHeaderButtonConfigSignature(NSArray<SPKHeaderDestination *> *enabled, NSString *defaultAction) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (SPKHeaderDestination *destination in enabled)
        [ids addObject:destination.identifier];
    NSString *menuIcon = [SPKUtils getStringPref:@"general_action_btn_default_menu_icon"];
    return [NSString stringWithFormat:@"%@|%@|%@", [ids componentsJoinedByString:@","], defaultAction ?: @"", menuIcon ?: @""];
}

- (void)spk_configureHeaderActionButton:(SPKFeedHeaderActionButton *)button {
    NSArray<SPKHeaderDestination *> *enabled = SPKHeaderButtonEnabledDestinations();
    NSString *defaultAction = [SPKUtils getStringPref:kSPKHeaderButtonDefaultActionKey];

    if (enabled.count == 0) {
        button.hidden = YES;
        objc_setAssociatedObject(button, kSPKHeaderButtonConfigSignatureAssocKey,
                                 SPKHeaderButtonConfigSignature(enabled, defaultAction), OBJC_ASSOCIATION_COPY_NONATOMIC);
        SPKLog(@"HeaderButton", @"[Sparkle] No enabled destinations — hiding header button");
        return;
    }
    button.hidden = NO;

    // Build the long-press / tap-to-open menu from the enabled destinations.
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    for (SPKHeaderDestination *destination in enabled) {
        UIImage *image = [SPKAssetUtils menuIconNamed:destination.iconName];
        __weak SPKFeedHeaderActionButton *weakButton = button;
        UIAction *action = [UIAction actionWithTitle:destination.title
                                               image:image
                                          identifier:nil
                                             handler:^(__unused UIAction *unusedAction) {
                                                 SPKLog(@"HeaderButton", @"[Sparkle] Menu → %@", destination.identifier);
                                                 if (destination.present)
                                                     destination.present(weakButton.window);
                                             }];
        [actions addObject:action];
    }
    button.menu = [UIMenu menuWithChildren:actions];

    // Resolve the configured default tap action.
    SPKHeaderDestination *defaultDestination = SPKHeaderDestinationForIdentifier(defaultAction);
    BOOL defaultIsValid = defaultDestination && [enabled containsObject:defaultDestination];

    if (defaultIsValid) {
        // Tap = the chosen destination, long-press = menu. Glyph mirrors the destination.
        button.showsMenuAsPrimaryAction = NO;
        [button setIconResource:defaultDestination.iconName pointSize:kSPKHeaderButtonGlyph];
    } else {
        // Tap = open menu, glyph = the Sparkle menu icon.
        button.showsMenuAsPrimaryAction = YES;
        NSString *menuIcon = [SPKUtils getStringPref:@"general_action_btn_default_menu_icon"];
        if (menuIcon.length == 0) menuIcon = kSPKHeaderMenuIconName;
        [button setIconResource:menuIcon pointSize:kSPKHeaderButtonGlyph];
    }

    objc_setAssociatedObject(button, kSPKHeaderButtonConfigSignatureAssocKey,
                             SPKHeaderButtonConfigSignature(enabled, defaultAction), OBJC_ASSOCIATION_COPY_NONATOMIC);
    // Force one reposition after a reconfigure (glyph swap can change intrinsic state).
    objc_setAssociatedObject(button, kSPKHeaderButtonLastFrameAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPKSideColumnResetDock(button);

    SPKLog(@"HeaderButton", @"[Sparkle] Configured header button: enabled=%lu default=%@ primaryIsMenu=%@",
           (unsigned long)enabled.count, defaultAction, button.showsMenuAsPrimaryAction ? @"YES" : @"NO");
}

- (void)spk_layoutHeaderActionButton {
    SPKFeedHeaderActionButton *button = [self spk_headerActionButton];
    if (!button)
        return;

    // Off-window layout passes (a pushed screen covers the feed) must not bring
    // back a button docked outside the header, which the header hid as it left.
    if (!self.window) {
        if (button.superview != self)
            button.hidden = YES;
        return;
    }

    // Respect the per-account master toggle at layout time (not just at install):
    // after a live account switch the hooks stay installed, so re-read the toggle
    // for the current account and hide the button on accounts that disabled it.
    if (![SPKUtils getBoolPref:kSPKHeaderButtonEnabledKey]) {
        button.hidden = YES;
        return;
    }

    // Reconfigure the menu/glyph ONLY when the config signature actually changes —
    // a cheap value compare, not a rebuild. This is what keeps the expensive menu
    // rebuild off the per-frame path (and out of the menu morph). The pref reads
    // for the signature are trivial next to what layoutSubviews already does.
    NSArray<SPKHeaderDestination *> *enabled = SPKHeaderButtonEnabledDestinations();
    NSString *defaultAction = [SPKUtils getStringPref:kSPKHeaderButtonDefaultActionKey];
    NSString *signature = SPKHeaderButtonConfigSignature(enabled, defaultAction);
    NSString *storedSignature = objc_getAssociatedObject(button, kSPKHeaderButtonConfigSignatureAssocKey);
    if (![signature isEqualToString:storedSignature]) {
        [self spk_configureHeaderActionButton:button];
    }
    // No destinations enabled at all → stay hidden regardless of layout.
    if (enabled.count == 0) {
        button.hidden = YES;
        return;
    }

    UIView *heart = SPKHeaderSubview(self, @[ @"activityButton" ]);
    UIView *messages = SPKHeaderSubview(self, @[ @"directButton" ]);

    // The header's bar items can move out of the header into a side column (a
    // narrow window beside a vertical tab bar); the button then follows them.
    UIView *columnItem = SPKSideColumnItemContainer(heart) ?: SPKSideColumnItemContainer(SPKHeaderSubview(self, @[ @"createButton" ]));
    if (columnItem) {
        if (![self spk_layoutHeaderActionButton:button belowColumnItem:columnItem])
            button.hidden = YES;
        return;
    }

    // Convert an anchor's bounds into this header's coordinate space so the math
    // holds whether IG parents these buttons directly on the header or nests them
    // in a cluster container. Returns CGRectNull for a missing/detached anchor.
    CGRect (^frameInHeader)(UIView *) = ^CGRect(UIView *anchor) {
        if (!anchor || !anchor.window)
            return CGRectNull;
        return [self convertRect:anchor.bounds fromView:anchor];
    };

    // IG keeps buttons it moved elsewhere (the side tab bar in a regular-width
    // layout) in the header, hidden; a scroll collapse only fades them. Hidden ones
    // are not anchors, faded ones are (the button fades with them below).
    BOOL (^isShown)(UIView *) = ^BOOL(UIView *view) {
        for (UIView *v = view; v && v != self; v = v.superview) {
            if (v.hidden)
                return NO;
        }
        return YES;
    };
    CGFloat (^effectiveAlphaOf)(UIView *) = ^CGFloat(UIView *view) {
        CGFloat alpha = 1.0;
        for (UIView *v = view; v && v != self; v = v.superview) {
            if (v.hidden)
                return 0.0;
            alpha *= v.alpha;
        }
        return alpha;
    };

    CGRect heartFrame = frameInHeader(heart);
    BOOL haveHeart = !CGRectIsNull(heartFrame) && heartFrame.size.width > 1.0 && isShown(heart);
    CGRect messagesFrame = frameInHeader(messages);
    BOOL haveMessages = !CGRectIsNull(messagesFrame) && messagesFrame.size.width > 1.0 && isShown(messages);

    // The leftmost button of the right-hand cluster. Which buttons sit there depends
    // on the layout: next to a vertical side bar (folded foldable) the create button
    // moves beside the heart, so anchoring to the heart alone would cover it.
    CGFloat clusterMinX = CGFLOAT_MAX;
    for (NSString *key in @[ @"activityButton", @"createButton", @"directButton", @"friendsMapButton", @"rightButton", @"secondaryRightButton" ]) {
        UIView *candidate = SPKHeaderSubview(self, @[ key ]);
        if (!isShown(candidate))
            continue;
        CGRect frame = frameInHeader(candidate);
        if (CGRectIsNull(frame) || frame.size.width <= 1.0 || CGRectGetMidX(frame) <= CGRectGetMidX(self.bounds))
            continue;
        clusterMinX = MIN(clusterMinX, CGRectGetMinX(frame));
    }
    BOOL haveCluster = clusterMinX < CGFLOAT_MAX;

    // When IG turned the heart and create button into tabs of a vertical side tab
    // bar, the button moves into that column too, as a glass circle at its top,
    // instead of sitting alone in an otherwise empty header row.
    if (!haveMessages && !haveCluster) {
        UIView *platter = SPKVerticalTabPlatter(self);
        if (platter && [self spk_layoutHeaderActionButton:button inColumnAbovePlatter:platter])
            return;
    }

    // Tie our button's lifecycle to IG's own nav buttons. When the header collapses
    // on scroll — or uses an immersive/transparent variant — IG fades those buttons
    // out. It does this by animating an ANCESTOR accessory container's alpha (the
    // heart's own alpha stays 1), so reading heart.alpha alone never sees the fade
    // and we'd linger in the status-bar sliver the collapsed header leaves behind.
    // Compute the anchor's effective opacity relative to the header by walking up
    // the superview chain multiplying alphas / honouring hidden, and mirror it.
    // In a regular-width layout IG moves the heart and create button into the side
    // tab bar, leaving the header with only the logo; the logo then carries the fade.
    UIView *logo = SPKHeaderSubview(self, @[ @"logoButton" ]) ?: SPKHeaderLogoView(self);
    UIView *visAnchor = haveHeart ? heart : (haveMessages ? messages : logo);
    if (!visAnchor || !visAnchor.window) {
        button.hidden = YES;
        return;
    }
    CGFloat effectiveAlpha = effectiveAlphaOf(visAnchor);
    if (effectiveAlpha <= 0.01) {
        button.hidden = YES;
        return;
    }
    button.hidden = NO;
    button.alpha = effectiveAlpha;

    CGFloat side = kSPKHeaderButtonSide;
    CGFloat centerY = haveHeart ? CGRectGetMidY(heartFrame) : (haveMessages ? CGRectGetMidY(messagesFrame) : CGRectGetMidY([self convertRect:logo.bounds fromView:logo]));

    // Classic order puts messages next to the heart; when the right side is that
    // crowded, dock on the far left at a FIXED inset, never the logo (the logo morphs
    // between the wordmark and the "For you" picker, which used to drag the button
    // around, including to the center when the menu opened). Otherwise sit left of
    // the right-hand cluster, or take the trailing slot when the cluster moved out
    // of the header.
    CGFloat x;
    if (haveMessages)
        x = self.safeAreaInsets.left + kSPKHeaderButtonLeftInset;
    else if (haveCluster)
        x = clusterMinX - kSPKHeaderButtonSpacing - side;
    else
        x = CGRectGetWidth(self.bounds) - self.safeAreaInsets.right - kSPKHeaderButtonLeftInset - side;

    CGRect expectedFrame = CGRectMake(floor(x), floor(centerY - side / 2.0), side, side);

    // Frame-equality guard: if we're already parented here at the right frame, do
    // nothing. This is what stops the layout churn / mid-animation reset that makes
    // injected buttons blink out during the iOS 26 menu morph.
    NSValue *lastVal = objc_getAssociatedObject(button, kSPKHeaderButtonLastFrameAssocKey);
    CGRect lastFrame = lastVal ? [lastVal CGRectValue] : CGRectNull;
    if (button.superview == self && !CGRectIsNull(lastFrame) && CGRectEqualToRect(expectedFrame, lastFrame)) {
        [self spk_updateHeaderGlass:button];
        return;
    }

    if (button.superview != self)
        [self addSubview:button];
    SPKSideColumnSizeButton(button, side);
    button.frame = expectedFrame;
    objc_setAssociatedObject(button, kSPKHeaderButtonLastFrameAssocKey, [NSValue valueWithCGRect:expectedFrame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self bringSubviewToFront:button];
    SPKLog(@"HeaderButton", @"[Sparkle] Laid out header button haveHeart=%@ haveMessages=%@ alpha=%.2f heart=%@ frame=%@",
           haveHeart ? @"YES" : @"NO", haveMessages ? @"YES" : @"NO", effectiveAlpha,
           NSStringFromCGRect(heartFrame), NSStringFromCGRect(expectedFrame));
    [self spk_updateHeaderGlass:button];
}

// Hosted by the tab bar controller's view, above its content and below anything
// presented over it. Stays put while the feed scrolls, like the tabs beside it;
// the header hides it again when it leaves the window (another tab, a push).
- (BOOL)spk_layoutHeaderActionButton:(SPKFeedHeaderActionButton *)button inColumnAbovePlatter:(UIView *)platter {
    UIView *host = [SPKUtils nearestViewControllerForView:self].tabBarController.view;
    if (!host || host.window != platter.window)
        return NO;

    CGRect platterFrame = [host convertRect:platter.bounds fromView:platter];
    CGFloat side = SPKSideColumnButtonSide;
    CGFloat x = floor(CGRectGetMidX(platterFrame) - side / 2.0);

    // Top of the column, right under the status items, where the vertical bar puts
    // a screen's first bar item (centered on the same 48pt slot). Without a
    // reserved region to measure, sit just above the tab group instead.
    CGRect columnFrame = CGRectMake(CGRectGetMinX(platterFrame) - 24.0, 0.0,
                                    CGRectGetWidth(platterFrame) + 48.0, CGRectGetHeight(host.bounds));
    CGFloat occlusionMaxY = SPKColumnOcclusionMaxY(host, columnFrame);
    CGFloat y = isnan(occlusionMaxY) ? CGRectGetMinY(platterFrame) - kSPKHeaderColumnGap - side
                                     : occlusionMaxY + (kSPKHeaderColumnSlot - side) / 2.0;
    CGRect expectedFrame = CGRectMake(x, floor(y), side, side);
    if (CGRectGetMinY(expectedFrame) < host.safeAreaInsets.top ||
        CGRectGetMaxY(expectedFrame) > CGRectGetMinY(platterFrame) - kSPKHeaderColumnGap)
        return NO;

    SPKSideColumnPlaceButton(button, [self spk_headerColumnGlassForButton:button], host, expectedFrame, 1.0);
    return YES;
}

// When the side column carries the header's create and heart buttons as bar
// items, the button gets its own glass circle right under their group, so it
// reads as one more column control and hides from captures as a whole.
- (BOOL)spk_layoutHeaderActionButton:(SPKFeedHeaderActionButton *)button belowColumnItem:(UIView *)item {
    UIView *host = [SPKUtils nearestViewControllerForView:self].tabBarController.view;
    if (!host)
        return NO;
    CGFloat alpha = 1.0;
    CGRect group = SPKSideColumnGroupFrame(item, host, &alpha);
    return SPKSideColumnDockButton(button, [self spk_headerColumnGlassForButton:button], host, group, alpha);
}

- (UIView *)spk_headerColumnGlassForButton:(SPKFeedHeaderActionButton *)button {
    UIView *glassView = objc_getAssociatedObject(button, kSPKHeaderGlassViewKey);
    if (!glassView) {
        glassView = SPKChromeGlassMirrorMakeBubble(@"sparkle-header-action-glass");
        if (glassView)
            objc_setAssociatedObject(button, kSPKHeaderGlassViewKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return glassView;
}

- (void)spk_updateHeaderGlass:(SPKFeedHeaderActionButton *)button {
    UIView *glassView = objc_getAssociatedObject(button, kSPKHeaderGlassViewKey);
    if (!glassView) {
        glassView = SPKChromeGlassMirrorMakeBubble(@"sparkle-header-action-glass");
        if (!glassView) {
            return;
        }
        objc_setAssociatedObject(button, kSPKHeaderGlassViewKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    SPKChromeGlassMirrorAttach(glassView, button);

    // Adopt the neighbouring IG nav bubble's own effect + ring, and fade with it.
    SPKChromeGlassMirrorSync(glassView, self);
}

@end



@interface UIView (SPKInboxHeaderButton)
- (SPKFeedHeaderActionButton *)spk_inboxHeaderButton;
- (void)spk_installInboxHeaderActionButtonIfNeeded;
- (void)spk_layoutInboxHeaderActionButton;
- (void)spk_updateInboxHeaderGlass:(SPKFeedHeaderActionButton *)button;
- (BOOL)spk_layoutInboxHeaderButtonInColumn:(SPKFeedHeaderActionButton *)button;
@end

// Instagram adds header controls by account type (a business inbox carries a
// menu button), and one can sit where the mirrored slot is. The button then
// steps toward the middle past it. Returns CGRectNull when that runs into
// another control or out of the safe content width: the row has no room.
static BOOL SPKInboxHeaderControlIsVisible(UIView *view, UIView *header) {
    for (UIView *current = view; current && current != header; current = current.superview) {
        if (current.hidden || current.alpha < 0.01)
            return NO;
    }
    return YES;
}

static CGRect SPKInboxHeaderFrameAvoidingControls(UIView *header, UIView *button, CGRect frame) {
    NSMutableArray<NSValue *> *occupied = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:header];
    for (NSUInteger i = 0; i < queue.count && i < 200; i++) {
        UIView *view = queue[i];
        if (view == button)
            continue;
        if (view != header && [view isKindOfClass:UIControl.class]) {
            CGRect controlFrame = [view convertRect:view.bounds toView:header];
            if (SPKInboxHeaderControlIsVisible(view, header) && CGRectGetWidth(controlFrame) > 1.0 && CGRectGetHeight(controlFrame) > 1.0)
                [occupied addObject:[NSValue valueWithCGRect:controlFrame]];
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }

    CGRect content = UIEdgeInsetsInsetRect(header.bounds, header.safeAreaInsets);
    BOOL trailingHalf = CGRectGetMidX(frame) > CGRectGetMidX(content);
    for (NSUInteger pass = 0; pass <= occupied.count; pass++) {
        CGRect blocker = CGRectNull;
        for (NSValue *value in occupied) {
            if (CGRectIntersectsRect(CGRectInset(frame, -kSPKHeaderButtonSpacing / 2.0, 0.0), value.CGRectValue)) {
                blocker = value.CGRectValue;
                break;
            }
        }
        if (CGRectIsNull(blocker))
            return CGRectGetMinX(frame) >= CGRectGetMinX(content) && CGRectGetMaxX(frame) <= CGRectGetMaxX(content) ? frame : CGRectNull;
        // Stepping past a wide control (the account title) would leave the row's
        // own side, so only button-sized controls are stepped past.
        if (CGRectGetWidth(blocker) > CGRectGetWidth(frame) * 2.0)
            return CGRectNull;
        frame.origin.x = floor(trailingHalf ? CGRectGetMinX(blocker) - kSPKHeaderButtonSpacing - CGRectGetWidth(frame)
                                            : CGRectGetMaxX(blocker) + kSPKHeaderButtonSpacing);
    }
    return CGRectNull;
}

@implementation UIView (SPKInboxHeaderButton)

- (SPKFeedHeaderActionButton *)spk_inboxHeaderButton {
    return objc_getAssociatedObject(self, kSPKInboxHeaderButtonAssocKey);
}

- (void)spk_installInboxHeaderActionButtonIfNeeded {
    BOOL messagesOnly = [SPKUtils getBoolPref:@"interface_show_header_button_in_messages_only"] &&
                         SPKIsMessagesOnlyMode();
    if (!messagesOnly) {
        SPKFeedHeaderActionButton *button = [self spk_inboxHeaderButton];
        if (button) {
            button.hidden = YES;
            [button removeFromSuperview];
            objc_setAssociatedObject(self, kSPKInboxHeaderButtonAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kSPKInboxHeaderButtonLastFrameAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    if ([self spk_inboxHeaderButton])
        return;

    SPKFeedHeaderActionButton *button = [[SPKFeedHeaderActionButton alloc] initWithSymbol:@""
                                                                                pointSize:kSPKHeaderButtonGlyph
                                                                                 diameter:kSPKHeaderButtonSide];
    button.accessibilityIdentifier = @"spk-inbox-header-action-button";
    button.accessibilityLabel = SPKL(@"ABOUT_INFORMATION_SPARKLE_TITLE");
    button.translatesAutoresizingMaskIntoConstraints = YES;
    button.bubbleColor = UIColor.clearColor;

    UIButton *composer = nil;
    if ([self respondsToSelector:@selector(messageButton)]) {
        composer = [self valueForKey:@"messageButton"];
    }
    button.iconTint = composer.tintColor ?: [UIColor labelColor];

    __weak SPKFeedHeaderActionButton *weakButton = button;
    button.menuWillDisplayHandler = ^{
        (void)weakButton;
        SPKHeaderFireShortcutHaptic();
    };
    [button addTarget:button action:@selector(spk_primaryTapped) forControlEvents:UIControlEventTouchUpInside];

    objc_setAssociatedObject(self, kSPKInboxHeaderButtonAssocKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // v410's IGCustomHeaderView keeps its real content (title, buttons, search
    // bar) inside a dedicated contentView, not as direct subviews of self —
    // self typically only has 1-2 direct children. Host our button there too,
    // so it's a true sibling of the native controls instead of sitting outside
    // whatever compositing/backing contentView itself uses.
    UIView *host = SPKHeaderSubview(self, @[ @"contentView" ]) ?: self;
    [host addSubview:button];
    SPKLog(@"HeaderButton", @"[Sparkle] Installed inbox header action button into %@ (host=%@)", NSStringFromClass(self.class), NSStringFromClass(host.class));

    [self spk_configureHeaderActionButton:button];
}

- (void)spk_layoutInboxHeaderActionButton {
    SPKFeedHeaderActionButton *button = [self spk_inboxHeaderButton];
    if (!button)
        return;
    if (!self.window) {
        if (![button isDescendantOfView:self])
            button.hidden = YES;
        return;
    }

    BOOL messagesOnly = [SPKUtils getBoolPref:@"interface_show_header_button_in_messages_only"] &&
                         SPKIsMessagesOnlyMode();
    if (!messagesOnly) {
        button.hidden = YES;
        return;
    }

    NSArray<SPKHeaderDestination *> *enabled = SPKHeaderButtonEnabledDestinations();
    NSString *defaultAction = [SPKUtils getStringPref:kSPKHeaderButtonDefaultActionKey];
    NSString *signature = SPKHeaderButtonConfigSignature(enabled, defaultAction);
    NSString *storedSignature = objc_getAssociatedObject(button, kSPKHeaderButtonConfigSignatureAssocKey);
    if (![signature isEqualToString:storedSignature]) {
        [self spk_configureHeaderActionButton:button];
    }
    if (enabled.count == 0) {
        button.hidden = YES;
        return;
    }

    UIButton *composer = nil;
    if ([self respondsToSelector:@selector(messageButton)]) {
        composer = [self valueForKey:@"messageButton"];
    }

    CGRect composerFrame = CGRectNull;
    if (composer && composer.window) {
        composerFrame = [self convertRect:composer.bounds fromView:composer];
    }

    CGFloat side = kSPKHeaderButtonSide;
    CGRect expectedFrame;
    if (!CGRectIsNull(composerFrame) && composerFrame.size.width > 1.0) {
        // Mirror the compose button across the safe content width, not the
        // header's full width: the header runs under a side column on wide or
        // foldable layouts, and a mirror of a leading compose button would land
        // in that column.
        CGRect content = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
        CGFloat mirroredX = CGRectGetMinX(content) + (CGRectGetMaxX(content) - CGRectGetMaxX(composerFrame));
        CGFloat centerY = CGRectGetMidY(composerFrame);
        expectedFrame = CGRectMake(floor(mirroredX), floor(centerY - side / 2.0), side, side);
    } else {
        CGFloat leftX = self.safeAreaInsets.left + kSPKHeaderButtonLeftInset;
        expectedFrame = CGRectMake(floor(leftX), floor(CGRectGetHeight(self.bounds) / 2.0 - side / 2.0), side, side);
    }
    expectedFrame = SPKInboxHeaderFrameAvoidingControls(self, button, expectedFrame);
    if (CGRectIsNull(expectedFrame)) {
        // No room in the row. With a side column beside the header, the button
        // docks at its top under the status items, where a vertical bar puts a
        // screen's first item; without one it stays out of the way.
        if (![self spk_layoutInboxHeaderButtonInColumn:button])
            button.hidden = YES;
        return;
    }

    // v410's inbox header is the legacy Obj-C IGCustomHeaderView subclass,
    // which exposes cameraButton alongside messageButton and never fades or
    // hides those buttons on this screen — unlike v439's Swift header, which
    // can collapse behind a scroll-driven glass effect (that's what the
    // ancestor alpha/hidden walk below exists for). Skip that walk on the
    // legacy header: mirroring it there did nothing but risk hiding Sparkle's
    // button if some transient ancestor state briefly reported hidden/alpha 0.
    BOOL legacyHeader = [self respondsToSelector:@selector(cameraButton)];
    CGFloat effectiveAlpha = 1.0;
    if (!legacyHeader && composer && composer.window) {
        BOOL anyHidden = NO;
        for (UIView *v = composer; v && v != self; v = v.superview) {
            effectiveAlpha *= v.alpha;
            if (v.hidden)
                anyHidden = YES;
        }
        if (anyHidden) {
            button.hidden = YES;
            return;
        }
    }
    button.hidden = NO;
    button.alpha = effectiveAlpha;

    // Mirror the install-time host choice: reparent onto contentView (when the
    // header exposes one) so we're a true sibling of the native controls
    // rather than sitting outside whatever compositing contentView itself
    // uses — the frame math above stays in self's coordinate space and gets
    // converted only for the final assignment.
    UIView *host = SPKHeaderSubview(self, @[ @"contentView" ]) ?: self;
    if (button.superview != host) {
        [host addSubview:button];
    }
    CGRect hostFrame = (host == self) ? expectedFrame : [self convertRect:expectedFrame toView:host];

    NSValue *lastVal = objc_getAssociatedObject(button, kSPKInboxHeaderButtonLastFrameAssocKey);
    CGRect lastFrame = lastVal ? [lastVal CGRectValue] : CGRectNull;
    if (button.superview == host && !CGRectIsNull(lastFrame) && CGRectEqualToRect(expectedFrame, lastFrame)) {
        // Frame is unchanged, but the native header may have re-inserted its
        // own subviews above ours on this pass (list reload, scroll-driven
        // relayout, etc.) without ever changing our frame. Always re-assert
        // z-order — cheap no-op if we're already frontmost — so Sparkle's
        // button can't silently end up buried behind native chrome.
        [host bringSubviewToFront:button];
        [self spk_updateInboxHeaderGlass:button];
        return;
    }

    SPKSideColumnSizeButton(button, kSPKHeaderButtonSide);
    button.frame = hostFrame;
    objc_setAssociatedObject(button, kSPKInboxHeaderButtonLastFrameAssocKey, [NSValue valueWithCGRect:expectedFrame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host bringSubviewToFront:button];
    SPKLog(@"HeaderButton", @"[Sparkle] Laid out inbox header button legacy=%@ frame=%@ host=%@ hostFrame=%@ siblingCount=%lu iconImage=%@ iconHidden=%@",
           legacyHeader ? @"YES" : @"NO", NSStringFromCGRect(expectedFrame), NSStringFromClass(host.class),
           NSStringFromCGRect(hostFrame), (unsigned long)host.subviews.count,
           button.iconView.image ? @"YES" : @"NO", button.iconView.hidden ? @"YES" : @"NO");

    [self spk_updateInboxHeaderGlass:button];
}

- (BOOL)spk_layoutInboxHeaderButtonInColumn:(SPKFeedHeaderActionButton *)button {
    UIView *host = [SPKUtils nearestViewControllerForView:self].tabBarController.view;
    if (!host || host.window != self.window)
        return NO;

    // The status items' reserved region at the top of a side column, found
    // beside the header rather than above it: past the header's safe content
    // when the header runs under the column (folded), or past the header
    // entirely when it sits in a narrower pane (unfolded). A phone's camera
    // region sits above the header's content, so it never qualifies.
    CGRect content = [host convertRect:UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets) fromView:self];
    CGRect status = SPKColumnStatusRegion(host, CGRectGetMaxX(content));
    if (CGRectIsNull(status))
        return NO;

    // Same placement as the feed button in the column: on the vertical bar's item
    // axis, in the 48pt slot right under the status items. The tab group gives
    // the axis when it is up; with the bar hidden (single-tab mode) the axis is
    // where the bar centers its items, one slot plus its edge inset in from the
    // column's trailing edge, which is also where the status items sit.
    CGFloat side = SPKSideColumnButtonSide;
    UIView *platter = SPKVerticalTabPlatter(self);
    CGFloat axis = platter && platter.window == host.window
                       ? CGRectGetMidX([host convertRect:platter.bounds fromView:platter])
                       : CGRectGetMaxX(status) - kSPKHeaderColumnEdgeInset - kSPKHeaderColumnSlot / 2.0;
    CGRect expectedFrame = CGRectMake(floor(axis - side / 2.0),
                                      floor(CGRectGetMaxY(status) + (kSPKHeaderColumnSlot - side) / 2.0), side, side);
    if (CGRectGetMinX(expectedFrame) < CGRectGetMinX(status) || CGRectGetMaxX(expectedFrame) > CGRectGetMaxX(host.bounds))
        return NO;

    // System glass, like the feed button and the tab group in the column; there
    // is no IG bubble out here to mirror. Back in the header row the mirror
    // adopts IG's effect again.
    UIView *glassView = objc_getAssociatedObject(button, kSPKInboxHeaderGlassViewKey);
    if (!glassView) {
        glassView = SPKChromeGlassMirrorMakeBubble(@"sparkle-inbox-action-glass");
        if (glassView)
            objc_setAssociatedObject(button, kSPKInboxHeaderGlassViewKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    SPKSideColumnPlaceButton(button, glassView, host, expectedFrame, 1.0);
    objc_setAssociatedObject(button, kSPKInboxHeaderButtonLastFrameAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

- (void)spk_updateInboxHeaderGlass:(SPKFeedHeaderActionButton *)button {
    UIView *glassView = objc_getAssociatedObject(button, kSPKInboxHeaderGlassViewKey);
    if (!glassView) {
        glassView = SPKChromeGlassMirrorMakeBubble(@"sparkle-inbox-action-glass");
        if (!glassView) {
            return;
        }
        objc_setAssociatedObject(button, kSPKInboxHeaderGlassViewKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    SPKChromeGlassMirrorAttach(glassView, button);

    // Adopt the neighbouring IG nav bubble's own effect + ring, and fade with it.
    SPKChromeGlassMirrorSync(glassView, self);
}

@end

#pragma mark - Hooks

%group SPKInboxHeaderActionButtonHooks

%hook IGDirectInboxNavigationHeaderView

- (void)didMoveToWindow {
    %orig;
    SPK_PERF_SCOPE(@"HeaderActionButton.didMoveToWindow");
    if ([(UIView *)self window]) {
        [self spk_installInboxHeaderActionButtonIfNeeded];
        return;
    }
    // Docked in the side column the button lives outside the header, so it is
    // hidden here until the header's next layout places it again.
    SPKFeedHeaderActionButton *button = [self spk_inboxHeaderButton];
    if (button && ![button isDescendantOfView:(UIView *)self])
        button.hidden = YES;
}

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"HeaderActionButton.layoutSubviews");
    if ([(UIView *)self window])
        [self spk_installInboxHeaderActionButtonIfNeeded];
    [self spk_layoutInboxHeaderActionButton];
}

%end

%end

%group SPKHeaderActionButtonHooks

%hook IGHomeFeedHeaderView

- (void)didMoveToWindow {
    %orig;
    SPK_PERF_SCOPE(@"HeaderActionButton.didMoveToWindow2");
    if ([(UIView *)self window]) {
        [self spk_installHeaderActionButtonIfNeeded];
        return;
    }
    // A button docked in the side tab column lives outside the header, so it does
    // not leave with it; hide it until the header's next layout places it again.
    SPKFeedHeaderActionButton *button = [self spk_headerActionButton];
    if (button && button.superview != (UIView *)self)
        button.hidden = YES;
}

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"HeaderActionButton.layoutSubviews2");
    // Install here too: the feed header is usually created before our delayed
    // Feed-surface hooks land, so its first didMoveToWindow already fired. Every
    // relayout gives us a reliable, idempotent chance to inject the button.
    if ([(UIView *)self window])
        [self spk_installHeaderActionButtonIfNeeded];
    [self spk_layoutHeaderActionButton];
}

%end

%end

// Depth-first search for the first live view of `cls` under `root`.
static UIView *SPKFindViewOfClass(UIView *root, Class cls) {
    if (!root)
        return nil;
    if ([root isKindOfClass:cls])
        return root;
    for (UIView *subview in root.subviews) {
        UIView *match = SPKFindViewOfClass(subview, cls);
        if (match)
            return match;
    }
    return nil;
}

// Kick any header that's already on screen when the hooks install, so the button
// appears without waiting for the next relayout / tab switch.
static void SPKKickExistingHeader(Class headerClass) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            UIView *header = SPKFindViewOfClass(window, headerClass);
            if (!header)
                continue;
            SPKLog(@"HeaderButton", @"[Sparkle] Kicking existing header %@", NSStringFromClass(header.class));
            [header spk_installHeaderActionButtonIfNeeded];
            [header setNeedsLayout];
            [header spk_layoutHeaderActionButton];
            return;
        }
        SPKLog(@"HeaderButton", @"[Sparkle] No existing header on screen to kick");
    });
}

static void SPKKickExistingInboxHeader(Class headerClass) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            UIView *header = SPKFindViewOfClass(window, headerClass);
            if (!header)
                continue;
            SPKLog(@"HeaderButton", @"[Sparkle] Kicking existing inbox header %@", NSStringFromClass(header.class));
            [header spk_installInboxHeaderActionButtonIfNeeded];
            [header setNeedsLayout];
            [header spk_layoutInboxHeaderActionButton];
            return;
        }
    });
}

void SPKInstallHeaderActionButtonHooksIfEnabled(void) {
    // Register the account-change observer once, BEFORE the master-toggle gate, so
    // it fires even when the launch account had the button disabled. On a live
    // account switch it (a) re-runs this installer — installing the hooks if the
    // new account has the button enabled — and (b) kicks the on-screen header so it
    // re-reads the new account's per-account prefs (enabled/destinations/default).
    static dispatch_once_t observerOnce;
    dispatch_once(&observerOnce, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKAccountDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
                                                          SPKInstallHeaderActionButtonHooksIfEnabled();
                                                          Class headerClass = SPKResolveIGClass(@"IGHomeFeedHeader.IGHomeFeedHeaderView", @"IGHomeFeedHeaderView");
                                                          if (headerClass)
                                                              SPKKickExistingHeader(headerClass);
                                                          Class inboxHeaderClass = SPKResolveIGClass(@"IGDirectInboxNavigationHeaderView.IGDirectInboxNavigationHeaderView", @"IGDirectInboxNavigationHeaderView");
                                                          if (inboxHeaderClass)
                                                              SPKKickExistingInboxHeader(inboxHeaderClass);
                                                      }];
    });

    BOOL feedEnabled = [SPKUtils getBoolPref:kSPKHeaderButtonEnabledKey];
    BOOL inboxEnabled = [SPKUtils getBoolPref:@"interface_show_header_button_in_messages_only"] &&
                        SPKIsMessagesOnlyMode();

    if (!feedEnabled && !inboxEnabled) {
        SPKLog(@"HeaderButton", @"[Sparkle] Header action button disabled — skipping install");
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class headerClass = SPKResolveIGClass(@"IGHomeFeedHeader.IGHomeFeedHeaderView", @"IGHomeFeedHeaderView");
        if (headerClass) {
            %init(SPKHeaderActionButtonHooks, IGHomeFeedHeaderView = headerClass);
            SPKLog(@"HeaderButton", @"[Sparkle] Installed header action button hooks class=%@", NSStringFromClass(headerClass));
            SPKKickExistingHeader(headerClass);
        } else {
            SPKLog(@"HeaderButton", @"[Sparkle] Could not resolve IGHomeFeedHeaderView");
        }

        Class inboxHeaderClass = SPKResolveIGClass(@"IGDirectInboxNavigationHeaderView.IGDirectInboxNavigationHeaderView", @"IGDirectInboxNavigationHeaderView");
        if (inboxHeaderClass) {
            %init(SPKInboxHeaderActionButtonHooks, IGDirectInboxNavigationHeaderView = inboxHeaderClass);
            SPKLog(@"HeaderButton", @"[Sparkle] Installed inbox header action button hooks class=%@", NSStringFromClass(inboxHeaderClass));
            SPKKickExistingInboxHeader(inboxHeaderClass);
        } else {
            SPKLog(@"HeaderButton", @"[Sparkle] Could not resolve IGDirectInboxNavigationHeaderView");
        }
    });
}
