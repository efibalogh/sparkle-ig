#import "SPKMediaChrome.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../../Settings/SPKPreferences.h"
#import <objc/message.h>
#import "SPKFont.h"

CGFloat const SPKMediaChromeTopBarContentHeight = 44.0;

static CGFloat const kSPKMediaChromeTopIconPointSize = 24.0;
static CGFloat const kSPKMediaChromeBottomIconPointSize = 24.0;

// iOS 18 and lower: solid, opaque background used for Sparkle's list/settings
// chrome (navigation bar + bottom toolbar). Matches the settings view's own
// background (the plain view background, not the cell colour) so the bars read
// as a seamless extension of the content instead of the default scroll-driven
// translucent material. The custom full-screen media preview opts out of this
// and keeps its transparent/material behaviour via
// SPKMediaChromeSetBarsMaterialActive. No-op on iOS 26+, where Liquid Glass
// manages the bar background itself.
static UIColor *SPKMediaChromeSolidBarColor(void) {
    return [SPKUtils SPKColor_InstagramGroupedBackground];
}

void SPKApplyMediaChromeNavigationBar(UINavigationBar *bar) {
    if (!bar) {
        return;
    }

    // Neutral, non-blue bar tint on every OS version (including iOS 26, where the
    // back chevron and any system-tinted items would otherwise use the accent).
    bar.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];

    // Sparkle's custom back chevron (the same glyph used to back out of a Gallery
    // folder), applied to every navigation state so the system blue chevron with
    // the previous screen's title never shows.
    UIImage *chevron = [SPKAssetUtils instagramIconNamed:@"chevron_left"
                                               pointSize:24.0
                                           renderingMode:UIImageRenderingModeAlwaysTemplate];

    if (@available(iOS 26.0, *)) {
        // iOS 26 Liquid Glass manages the bar background (and adapts on scroll) on
        // its own — don't reconfigure it, just swap the chevron on copies of the
        // existing appearances so the glass look is preserved.
        UINavigationBarAppearance *standard = [bar.standardAppearance copy] ?: [[UINavigationBarAppearance alloc] init];
        UINavigationBarAppearance *scrollEdge = [(bar.scrollEdgeAppearance ?: bar.standardAppearance) copy] ?: standard;
        UINavigationBarAppearance *compact = [(bar.compactAppearance ?: bar.standardAppearance) copy] ?: standard;
        if (chevron) {
            [standard setBackIndicatorImage:chevron transitionMaskImage:chevron];
            [scrollEdge setBackIndicatorImage:chevron transitionMaskImage:chevron];
            [compact setBackIndicatorImage:chevron transitionMaskImage:chevron];
        }
        bar.standardAppearance = standard;
        bar.scrollEdgeAppearance = scrollEdge;
        bar.compactAppearance = compact;
        return;
    }

    // iOS 18 and lower: a solid background matching the settings/list view
    // background in every state (standard/compact and at the scroll edge)
    // instead of the default scroll-driven translucent material, so the bar
    // reads as a seamless extension of the content. A neutral non-blue tint and
    // the custom chevron are applied in every state. (The full-screen media
    // preview uses its own plain navigation controller and drives its bars
    // through SPKMediaChromeSetBarsMaterialActive, so it is unaffected here.)
    UINavigationBarAppearance *solid = [[UINavigationBarAppearance alloc] init];
    [solid configureWithOpaqueBackground];
    solid.backgroundColor = SPKMediaChromeSolidBarColor();
    // Matching hairline separator, shown only once content scrolls behind the
    // bar (standard/compact); hidden at the scroll edge so the bar stays
    // seamless with the content when nothing is behind it.
    solid.shadowColor = [SPKUtils SPKColor_InstagramSeparator];
    if (chevron) {
        [solid setBackIndicatorImage:chevron transitionMaskImage:chevron];
    }

    UINavigationBarAppearance *solidScrollEdge = [solid copy];
    solidScrollEdge.shadowColor = UIColor.clearColor;

    bar.standardAppearance = solid;
    bar.compactAppearance = solid;
    bar.scrollEdgeAppearance = solidScrollEdge;
}

// Match iOS 26's title-less back button on iOS 18 and lower (it already does this
// natively on iOS 26). The back button shown on a pushed controller is derived
// from the previous controller's navigation item, so applying it to every
// controller in the stack covers every transition, including back to the root.
static void SPKApplyMediaChromeBackButtonDisplayMode(UIViewController *viewController) {
    if (@available(iOS 26.0, *))
        return;
    viewController.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;
}

@implementation SPKChromeNavigationController

- (void)viewDidLoad {
    [super viewDidLoad];
    SPKApplyMediaChromeNavigationBar(self.navigationBar);
    for (UIViewController *viewController in self.viewControllers) {
        SPKApplyMediaChromeBackButtonDisplayMode(viewController);
    }
}

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    SPKApplyMediaChromeBackButtonDisplayMode(viewController);
    [super pushViewController:viewController animated:animated];
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated {
    for (UIViewController *viewController in viewControllers) {
        SPKApplyMediaChromeBackButtonDisplayMode(viewController);
    }
    [super setViewControllers:viewControllers animated:animated];
}

@end

UIImage *SPKMediaChromeTopIcon(NSString *resourceName) {
    return [SPKAssetUtils instagramIconNamed:(resourceName.length > 0 ? resourceName : @"more")
                                   pointSize:kSPKMediaChromeTopIconPointSize];
}

UIImage *SPKMediaChromeBottomIcon(NSString *resourceName) {
    return [SPKAssetUtils instagramIconNamed:(resourceName.length > 0 ? resourceName : @"more")
                                   pointSize:kSPKMediaChromeBottomIconPointSize];
}

static UIImage *SPKMediaChromeNormalizedTopIcon(NSString *resourceName) {
    UIImage *source = SPKMediaChromeTopIcon(resourceName);
    if (!source) {
        return nil;
    }

    CGSize canvasSize = CGSizeMake(kSPKMediaChromeTopIconPointSize, kSPKMediaChromeTopIconPointSize);
    CGSize sourceSize = source.size;
    if (sourceSize.width <= 0.0 || sourceSize.height <= 0.0) {
        return [source imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }

    CGFloat scale = MIN(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height);
    CGSize drawSize = CGSizeMake(sourceSize.width * scale, sourceSize.height * scale);
    CGRect drawRect = CGRectMake((canvasSize.width - drawSize.width) / 2.0,
                                 (canvasSize.height - drawSize.height) / 2.0,
                                 drawSize.width,
                                 drawSize.height);

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize];
    UIImage *normalized = [renderer imageWithActions:^(UIGraphicsImageRendererContext *_Nonnull context) {
        (void)context;
        [source drawInRect:CGRectIntegral(drawRect)];
    }];
    return [normalized imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

UIImage *SPKMediaChromeTopBarIcon(NSString *resourceName) {
    return SPKMediaChromeNormalizedTopIcon(resourceName);
}

UIBarButtonItem *SPKMediaChromeTopBarButtonItem(NSString *resourceName, id target, SEL action) {
    return SPKMediaChromeTopBarButtonItemWithStyle(resourceName,
                                                   target,
                                                   action,
                                                   UIBarButtonItemStylePlain,
                                                   [SPKUtils SPKColor_InstagramPrimaryText],
                                                   nil);
}

UIBarButtonItem *SPKMediaChromeTopBarButtonItemWithTint(NSString *resourceName, id target, SEL action, UIColor *tintColor, NSString *accessibilityLabel) {
    return SPKMediaChromeTopBarButtonItemWithStyle(resourceName, target, action, UIBarButtonItemStylePlain, tintColor, accessibilityLabel);
}

UIBarButtonItem *SPKMediaChromeTopBarButtonItemWithStyle(NSString *resourceName, id target, SEL action, UIBarButtonItemStyle style, UIColor *tintColor, NSString *accessibilityLabel) {
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:SPKMediaChromeTopBarIcon(resourceName)
                                                             style:style
                                                            target:target
                                                            action:action];
    item.tintColor = tintColor ?: [SPKUtils SPKColor_InstagramPrimaryText];
    item.accessibilityLabel = accessibilityLabel;
    return item;
}

UIBarButtonItem *SPKMediaChromeTopBarMenuButtonItem(NSString *resourceName, UIMenu *menu, NSString *accessibilityLabel) {
    return SPKMediaChromeTopBarMenuButtonItemWithTint(resourceName, menu, [SPKUtils SPKColor_InstagramPrimaryText], accessibilityLabel);
}

UIBarButtonItem *SPKMediaChromeTopBarMenuButtonItemWithTint(NSString *resourceName, UIMenu *menu, UIColor *tintColor, NSString *accessibilityLabel) {
    // A plain image item with a menu, not a custom-view button: UIKit only moves
    // real bar items into a vertical side bar (a folded or landscape foldable),
    // so a custom view stays stranded in the top bar next to its siblings that
    // moved. The menu opens on a single tap either way.
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:SPKMediaChromeTopBarIcon(resourceName) menu:menu];
    item.tintColor = tintColor ?: [SPKUtils SPKColor_InstagramPrimaryText];
    item.accessibilityLabel = accessibilityLabel;
    return item;
}

void SPKMediaChromeSetLeadingTopBarItems(UINavigationItem *navigationItem, NSArray<UIBarButtonItem *> *items) {
    if (!navigationItem) {
        return;
    }
    if (@available(iOS 16.0, *)) {
        navigationItem.leftBarButtonItems = nil;
        navigationItem.leftBarButtonItem = nil;
        navigationItem.leadingItemGroups = items.count > 0
                                               ? @[ [UIBarButtonItemGroup fixedGroupWithRepresentativeItem:nil items:items] ]
                                               : @[];
        return;
    }
    // `leftBarButtonItem` and `leftBarButtonItems` share the same backing storage
    // (the singular is a convenience for the first element), so clear the singular
    // *before* assigning the plural — doing it after would wipe what we just set,
    // leaving iOS 15 with no leading items. (The iOS 16 branch above already nils
    // both before setting the groups, which is why only iOS 15 was affected.)
    navigationItem.leftBarButtonItem = nil;
    navigationItem.leftBarButtonItems = items.count > 0 ? items : nil;
}

void SPKMediaChromeSetTrailingTopBarItems(UINavigationItem *navigationItem, NSArray<UIBarButtonItem *> *items) {
    if (!navigationItem) {
        return;
    }
    if (@available(iOS 16.0, *)) {
        navigationItem.rightBarButtonItems = nil;
        navigationItem.rightBarButtonItem = nil;
        navigationItem.trailingItemGroups = items.count > 0
                                                ? @[ [UIBarButtonItemGroup fixedGroupWithRepresentativeItem:nil items:items] ]
                                                : @[];
        return;
    }
    // See SPKMediaChromeSetLeadingTopBarItems: clear the singular before the plural
    // so the assignment isn't wiped on iOS 15.
    navigationItem.rightBarButtonItem = nil;
    navigationItem.rightBarButtonItems = items.count > 0 ? items : nil;
}

void SPKMediaChromeSetTrailingTopBarItemGroups(UINavigationItem *navigationItem, NSArray<NSArray<UIBarButtonItem *> *> *groups) {
    if (!navigationItem) {
        return;
    }
    if (@available(iOS 16.0, *)) {
        NSMutableArray<UIBarButtonItemGroup *> *itemGroups = [NSMutableArray arrayWithCapacity:groups.count];
        for (NSArray<UIBarButtonItem *> *items in groups) {
            if (items.count == 0)
                continue;
            // On iOS 26, adjacent UIBarButtonItemGroups are still allowed to
            // share one Liquid Glass background. UIKit's zero-width fixed-space
            // group is the explicit separator that prevents that coalescing.
            // Call it dynamically because Sparkle still builds with the iOS
            // 16.2 SDK for iOS 15 compatibility.
            if (itemGroups.count > 0) {
                SEL fixedSpaceSelector = NSSelectorFromString(@"groupWithFixedSpace");
                if ([UIBarButtonItemGroup respondsToSelector:fixedSpaceSelector]) {
                    UIBarButtonItemGroup *separator = ((UIBarButtonItemGroup *(*)(id, SEL))objc_msgSend)(UIBarButtonItemGroup.class, fixedSpaceSelector);
                    if (separator)
                        [itemGroups addObject:separator];
                }
            }
            [itemGroups addObject:[UIBarButtonItemGroup fixedGroupWithRepresentativeItem:nil items:items]];
        }
        navigationItem.rightBarButtonItems = nil;
        navigationItem.rightBarButtonItem = nil;
        navigationItem.trailingItemGroups = itemGroups;
        return;
    }
    // Pre-16 has no item groups; fall back to one flat list (see the singular/plural
    // ordering note in SPKMediaChromeSetLeadingTopBarItems). `rightBarButtonItems`
    // runs trailing-to-leading, the opposite of the visual order the groups are
    // given in, so the flattened list is reversed to keep the same arrangement.
    NSMutableArray<UIBarButtonItem *> *flat = [NSMutableArray array];
    for (NSArray<UIBarButtonItem *> *items in groups) {
        [flat addObjectsFromArray:items];
    }
    flat = [[[flat reverseObjectEnumerator] allObjects] mutableCopy];
    navigationItem.rightBarButtonItem = nil;
    navigationItem.rightBarButtonItems = flat.count > 0 ? flat : nil;
}

#pragma mark - Bottom Toolbar

UIImage *SPKMediaChromeBottomBarIcon(NSString *resourceName) {
    UIImage *icon = SPKMediaChromeBottomIcon(resourceName);
    return [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

UIBarButtonItem *SPKMediaChromeBottomBarButtonItem(NSString *resourceName, NSString *accessibilityLabel, id target, SEL action) {
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:SPKMediaChromeBottomBarIcon(resourceName)
                                                             style:UIBarButtonItemStylePlain
                                                            target:target
                                                            action:action];
    item.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    item.accessibilityLabel = accessibilityLabel;
    return item;
}

static UIBarButtonItem *SPKMediaChromeFlexibleSpace(void) {
    return [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
}

static UIBarButtonItem *SPKMediaChromeFixedSpace(CGFloat width) {
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    space.width = width;
    return space;
}

NSArray<UIBarButtonItem *> *SPKMediaChromeBottomToolbarItems(NSArray<UIBarButtonItem *> *contentItems) {
    if (contentItems.count == 0) {
        return @[];
    }

    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];

    if (@available(iOS 26.0, *)) {
        // Keep the content items adjacent so they share a single Liquid Glass
        // capsule, and center the capsule with a flexible spacer on each end.
        [items addObject:SPKMediaChromeFlexibleSpace()];
        [items addObjectsFromArray:contentItems];
        [items addObject:SPKMediaChromeFlexibleSpace()];
        return items;
    }

    // Legacy: distribute evenly across a standard full-width bottom bar.
    [items addObject:SPKMediaChromeFlexibleSpace()];
    for (UIBarButtonItem *item in contentItems) {
        [items addObject:item];
        [items addObject:SPKMediaChromeFlexibleSpace()];
    }
    return items;
}

NSArray<UIBarButtonItem *> *SPKMediaChromeBottomToolbarItemsWithTrailingGroup(NSArray<UIBarButtonItem *> *primaryItems, NSArray<UIBarButtonItem *> *trailingItems) {
    return SPKMediaChromeBottomToolbarItemsWithGroups(@[ primaryItems ?: @[], trailingItems ?: @[] ]);
}

NSArray<UIBarButtonItem *> *SPKMediaChromeBottomToolbarItemsWithGroups(NSArray<NSArray<UIBarButtonItem *> *> *groups) {
    NSMutableArray<NSArray<UIBarButtonItem *> *> *nonEmpty = [NSMutableArray array];
    for (NSArray<UIBarButtonItem *> *group in groups) {
        if (group.count > 0)
            [nonEmpty addObject:group];
    }
    if (nonEmpty.count <= 1) {
        return SPKMediaChromeBottomToolbarItems(nonEmpty.firstObject ?: @[]);
    }

    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];

    if (@available(iOS 26.0, *)) {
        // Every group stays centered (flexible spacers on the outer ends) while a
        // fixed gap between neighbors splits the glass into separate capsules.
        [items addObject:SPKMediaChromeFlexibleSpace()];
        [nonEmpty enumerateObjectsUsingBlock:^(NSArray<UIBarButtonItem *> *group, NSUInteger idx, BOOL *stop) {
            if (idx > 0)
                [items addObject:SPKMediaChromeFixedSpace(8.0)];
            [items addObjectsFromArray:group];
        }];
        [items addObject:SPKMediaChromeFlexibleSpace()];
        return items;
    }

    // Legacy: a single evenly-distributed bar containing every item.
    NSMutableArray<UIBarButtonItem *> *combined = [NSMutableArray array];
    for (NSArray<UIBarButtonItem *> *group in nonEmpty)
        [combined addObjectsFromArray:group];
    return SPKMediaChromeBottomToolbarItems(combined);
}

#pragma mark - Glass Title

// A soft top edge fades out over the media instead of backing the bar, and Off
// has no edge at all, so a plain title can land on a bright frame. The capsule
// gives it its own glass.
static BOOL SPKMediaChromeWantsGlassTitle(void) {
    if (@available(iOS 26.0, *)) {
        if (!NSClassFromString(@"UIGlassEffect"))
            return NO;
        NSString *style = [SPKUtils getStringPref:kSPKPrefInterfaceScrollEdgeStyle];
        if ([style isEqualToString:@"soft"] || [style isEqualToString:@"off"])
            return YES;
        // Default follows iOS, which is soft on iOS 26 and hard from iOS 27.
        if ([style isEqualToString:@"default"])
            return ![NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){27, 0, 0}];
    }
    return NO;
}

@interface SPKMediaChromeGlassTitleView : UIView
@property (nonatomic, strong, readonly) UILabel *label;
@end

@implementation SPKMediaChromeGlassTitleView {
    UIVisualEffectView *_glassView;
}

static CGFloat const kSPKGlassTitleHorizontalPadding = 14.0;
static CGFloat const kSPKGlassTitleHeight = 36.0;

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        UIVisualEffect *effect = nil;
        Class glassClass = NSClassFromString(@"UIGlassEffect");
        if (glassClass)
            effect = [[glassClass alloc] init];
        // Interactive glass gives the system press response under a finger, the
        // same as Liquid Glass buttons.
        if ([effect respondsToSelector:@selector(setInteractive:)])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, @selector(setInteractive:), YES);
        if (![effect isKindOfClass:[UIVisualEffect class]])
            effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        _glassView = [[UIVisualEffectView alloc] initWithEffect:effect];
        _glassView.layer.cornerRadius = kSPKGlassTitleHeight / 2.0;
        _glassView.layer.cornerCurve = kCACornerCurveContinuous;
        _glassView.clipsToBounds = YES;
        [self addSubview:_glassView];

        _label = [[UILabel alloc] init];
        _label.font = [SPKFont fontForStyle:SPKFontStyleBody weight:UIFontWeightSemibold];
        _label.adjustsFontForContentSizeCategory = YES;
        _label.textColor = [UIColor labelColor];
        _label.textAlignment = NSTextAlignmentCenter;
        [_glassView.contentView addSubview:_label];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    CGSize text = [_label intrinsicContentSize];
    return CGSizeMake(ceil(text.width) + 2.0 * kSPKGlassTitleHorizontalPadding,
                      MAX(kSPKGlassTitleHeight, ceil(text.height) + 12.0));
}

- (CGSize)sizeThatFits:(CGSize)size {
    return [self intrinsicContentSize];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _glassView.frame = self.bounds;
    _glassView.layer.cornerRadius = CGRectGetHeight(self.bounds) / 2.0;
    _label.frame = CGRectInset(_glassView.contentView.bounds, kSPKGlassTitleHorizontalPadding, 0.0);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.preferredContentSizeCategory != self.traitCollection.preferredContentSizeCategory)
        [self invalidateIntrinsicContentSize];
}

@end

void SPKMediaChromeSetGlassTitle(UIViewController *viewController, NSString *_Nullable title) {
    if (!viewController)
        return;
    UINavigationItem *navigationItem = viewController.navigationItem;
    if (title.length == 0 || !SPKMediaChromeWantsGlassTitle()) {
        if ([navigationItem.titleView isKindOfClass:[SPKMediaChromeGlassTitleView class]])
            navigationItem.titleView = nil;
        viewController.title = title;
        return;
    }

    SPKMediaChromeGlassTitleView *titleView = (SPKMediaChromeGlassTitleView *)navigationItem.titleView;
    if (![titleView isKindOfClass:[SPKMediaChromeGlassTitleView class]]) {
        titleView = [[SPKMediaChromeGlassTitleView alloc] initWithFrame:CGRectZero];
        navigationItem.titleView = titleView;
    }
    // Keep the plain title too: it names the screen for VoiceOver and the back menu.
    viewController.title = title;
    if ([titleView.label.text isEqualToString:title])
        return;
    titleView.label.text = title;
    [titleView invalidateIntrinsicContentSize];
    titleView.bounds = (CGRect){CGPointZero, [titleView intrinsicContentSize]};
    [titleView setNeedsLayout];
}

void SPKMediaChromeConfigureBottomToolbar(UIToolbar *toolbar) {
    if (!toolbar) {
        return;
    }
    toolbar.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    toolbar.translucent = YES;

    // iOS 26+ Liquid Glass renders its own capsule background; don't touch it.
    if (@available(iOS 26.0, *)) {
        return;
    }

    // iOS 18 and lower: a solid background matching the settings/list view
    // background in every state, mirroring the navigation bar so the top and
    // bottom chrome share one flat colour instead of the default translucent
    // material. The full-screen media preview calls this and then immediately
    // overrides it back to transparent/material via
    // SPKMediaChromeSetBarsMaterialActive, so the preview is unaffected.
    UIToolbarAppearance *solid = [[UIToolbarAppearance alloc] init];
    [solid configureWithOpaqueBackground];
    solid.backgroundColor = SPKMediaChromeSolidBarColor();
    // Matching hairline separator along the toolbar's top edge, shown only once
    // content scrolls behind it; hidden at the scroll edge so it stays seamless.
    solid.shadowColor = [SPKUtils SPKColor_InstagramSeparator];

    UIToolbarAppearance *solidScrollEdge = [solid copy];
    solidScrollEdge.shadowColor = UIColor.clearColor;

    toolbar.standardAppearance = solid;
    toolbar.compactAppearance = solid;
    toolbar.scrollEdgeAppearance = solidScrollEdge;
}

void SPKMediaChromeSetBarsMaterialActive(UINavigationController *navigationController, BOOL active) {
    if (!navigationController) {
        return;
    }
    // iOS 26+ Liquid Glass adapts on its own; leave the system appearance alone.
    if (@available(iOS 26.0, *)) {
        return;
    }

    UIColor *tint = [SPKUtils SPKColor_InstagramPrimaryText];

    UINavigationBarAppearance *navAppearance = [[UINavigationBarAppearance alloc] init];
    if (active) {
        [navAppearance configureWithDefaultBackground];
        navAppearance.shadowColor = [SPKUtils SPKColor_InstagramSeparator];
    } else {
        [navAppearance configureWithTransparentBackground];
    }
    UINavigationBar *navBar = navigationController.navigationBar;
    navBar.standardAppearance = navAppearance;
    navBar.scrollEdgeAppearance = navAppearance;
    navBar.compactAppearance = navAppearance;
    navBar.tintColor = tint;

    UIToolbarAppearance *toolbarAppearance = [[UIToolbarAppearance alloc] init];
    if (active) {
        [toolbarAppearance configureWithDefaultBackground];
        toolbarAppearance.shadowColor = [SPKUtils SPKColor_InstagramSeparator];
    } else {
        [toolbarAppearance configureWithTransparentBackground];
    }
    UIToolbar *toolbar = navigationController.toolbar;
    toolbar.standardAppearance = toolbarAppearance;
    toolbar.scrollEdgeAppearance = toolbarAppearance;
    toolbar.compactAppearance = toolbarAppearance;
    toolbar.tintColor = tint;
}
