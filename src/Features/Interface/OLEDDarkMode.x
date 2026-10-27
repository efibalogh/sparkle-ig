#import <objc/runtime.h>
#import <os/lock.h>
#import <substrate.h>

#import "../../App/SPKStabilityGuard.h"
#import "../../InstagramHeaders.h"
#import "../../Utils.h"

// OLED dark mode: Instagram's dark grays become pure black, and its raised
// surfaces become darker neutral grays.
//
// Instagram builds nearly every color as a UIColor with a dynamic provider,
// one block that returns the light or dark value for a trait collection. Its
// dark palette is a handful of fixed slate grays (#0B1014 for the background,
// #24292F for raised surfaces, ...), shared by every surface. So instead of
// hooking each surface, every dynamic provider is wrapped and its dark result
// is swapped when it is one of those exact values. Matching on the value and
// not on IG's design-system enums keeps this working across IG versions, and
// an exact match leaves system colors, DM chat themes and Sparkle's own colors
// alone. A few backgrounds (the window, the story viewer) are fixed colors
// built from components, so component construction is matched the same way.

// UIKit's private placeholder returned by [UIColor alloc].
@interface UIPlaceholderColor : UIColor
@end

typedef UIColor * (^SPKOLEDColorProvider)(UITraitCollection *);

typedef struct {
    uint32_t from;
    uint32_t to;
} SPKOLEDMapping;

// 0xRRGGBB. Targets must never appear as sources, or a color would be mapped twice.
static const SPKOLEDMapping kSPKOLEDMappings[] = {
    // Primary background, and the root container under it.
    {0x0B1014, 0x000000},
    {0x101010, 0x000000},
    // Elevated sheets: comments, the DM composer.
    {0x181C1F, 0x000000},
    // IG 410's sheets (comments, map search) and the map buttons over them.
    {0x212328, 0x000000},
    // Raised surfaces: DM bubbles, the search bar, media placeholders.
    {0x24292F, 0x1A1A1A},
    // IG 410's search bar and raised surfaces.
    {0x25292E, 0x1A1A1A},
    {0x262626, 0x1A1A1A},
    // Chips and secondary buttons.
    {0x2A3037, 0x242424},
    {0x2B3036, 0x242424},
    // Separators, pressed rows and tertiary fills.
    {0x343B43, 0x333333},
    {0x333C45, 0x333333},
    {0x3A4048, 0x383838},
    // Inactive carousel page dots.
    {0x46505C, 0x4E4E4E},
    // Pills (IGDSSegmentedPillControl), e.g. the profile's Threads, channel
    // and music links. Too bright for the slate fallback.
    {0x55606C, 0x5E5E5E},
};

static inline uint32_t SPKOLEDChannel(CGFloat value) {
    return (uint32_t)lround(MIN(MAX(value, 0.0), 1.0) * 255.0);
}

// The palette value the last match on this thread came from. Dev builds tag
// each mapped color with it, so the Color Report can show the original.
static __thread uint32_t sSPKOLEDLastSource;

// Maps one palette value; kind is 1 for a table match, 2 for the fallback.
static int SPKOLEDMapRGB(uint32_t rgb, uint32_t *outRGB) {
    for (size_t i = 0; i < sizeof(kSPKOLEDMappings) / sizeof(kSPKOLEDMappings[0]); i++) {
        if (kSPKOLEDMappings[i].from == rgb) {
            *outRGB = kSPKOLEDMappings[i].to;
            return 1;
        }
    }
    // Instagram's dark grays all lean slightly blue (red <= green <= blue,
    // a small spread, nothing bright). One not listed above, such as a pressed
    // state, takes the neutral step closest to its brightness, so no tinted
    // gray is left between the remapped ones. Neutral targets have no spread,
    // so they never match here.
    // UIKit's light secondary label (#3C3C43) has the same lean and is left alone.
    uint32_t r8 = rgb >> 16, g8 = (rgb >> 8) & 0xFF, b8 = rgb & 0xFF;
    if (rgb == 0x3C3C43 || r8 > g8 || g8 > b8 || b8 > 0x48 || b8 - r8 < 3 || b8 - r8 > 0x14)
        return 0;
    uint32_t luma = (299 * r8 + 587 * g8 + 114 * b8) / 1000;
    *outRGB = luma < 0x15 ? 0x000000 : luma < 0x27 ? 0x1A1A1A : luma < 0x30 ? 0x242424 : 0x333333;
    return 2;
}

#if SPK_DEV
// Palette census: every dark value Instagram builds or resolves while the
// feature is on, with how often it was seen and which views painted it, so the
// mapping table can be checked against the complete palette of a version.
static os_unfair_lock sSPKOLEDCensusLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber *, NSNumber *> *sSPKOLEDCensusCounts;
static NSMutableDictionary<NSNumber *, NSCountedSet<NSString *> *> *sSPKOLEDCensusViews;

static inline BOOL SPKOLEDCensusTracks(uint32_t rgb) {
    return MAX(rgb >> 16, MAX((rgb >> 8) & 0xFF, rgb & 0xFF)) <= 0x60;
}

static void SPKOLEDCensusRecord(uint32_t rgb, NSString *view) {
    if (!SPKOLEDCensusTracks(rgb))
        return;
    os_unfair_lock_lock(&sSPKOLEDCensusLock);
    if (!sSPKOLEDCensusCounts) {
        sSPKOLEDCensusCounts = [NSMutableDictionary dictionary];
        sSPKOLEDCensusViews = [NSMutableDictionary dictionary];
    }
    NSNumber *key = @(rgb);
    if (view) {
        NSCountedSet *views = sSPKOLEDCensusViews[key];
        if (!views)
            sSPKOLEDCensusViews[key] = views = [NSCountedSet set];
        [views addObject:view];
    } else {
        sSPKOLEDCensusCounts[key] = @(sSPKOLEDCensusCounts[key].unsignedIntegerValue + 1);
    }
    os_unfair_lock_unlock(&sSPKOLEDCensusLock);
}

NSString *SPKOLEDCensusReport(void) {
    os_unfair_lock_lock(&sSPKOLEDCensusLock);
    NSDictionary<NSNumber *, NSNumber *> *counts = [sSPKOLEDCensusCounts copy];
    NSMutableDictionary<NSNumber *, NSCountedSet *> *views = [NSMutableDictionary dictionary];
    [sSPKOLEDCensusViews enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSCountedSet *set, __unused BOOL *stop) {
        views[key] = [set copy];
    }];
    os_unfair_lock_unlock(&sSPKOLEDCensusLock);
    if (!counts.count && !views.count)
        return @"-\n";

    NSMutableSet<NSNumber *> *keys = [NSMutableSet setWithArray:counts.allKeys];
    [keys addObjectsFromArray:views.allKeys];
    NSArray<NSNumber *> *sorted = [keys.allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *out = [NSMutableString string];
    for (NSNumber *key in sorted) {
        uint32_t rgb = key.unsignedIntValue, mapped = 0;
        int kind = SPKOLEDMapRGB(rgb, &mapped);
        NSString *status = kind == 1 ? [NSString stringWithFormat:@"-> #%06X table   ", mapped]
                         : kind == 2 ? [NSString stringWithFormat:@"-> #%06X fallback", mapped]
                                     : @"   unmapped        ";
        NSCountedSet *set = views[key];
        NSArray *names = [set.allObjects sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            NSUInteger countA = [set countForObject:a], countB = [set countForObject:b];
            return countA == countB ? [a compare:b] : (countA > countB ? NSOrderedAscending : NSOrderedDescending);
        }];
        NSMutableArray<NSString *> *top = [NSMutableArray array];
        for (NSString *name in names) {
            if (top.count == 6)
                break;
            [top addObject:[NSString stringWithFormat:@"%@x%lu", name, (unsigned long)[set countForObject:name]]];
        }
        [out appendFormat:@"#%06X %@ %7lu built  %@\n", rgb, status, (unsigned long)counts[key].unsignedIntegerValue,
                          top.count ? [@"bg: " stringByAppendingString:[top componentsJoinedByString:@", "]] : @""];
    }
    return out;
}
#endif

static BOOL SPKOLEDLookup(CGFloat r, CGFloat g, CGFloat b, uint32_t *outRGB) {
    uint32_t rgb = SPKOLEDChannel(r) << 16 | SPKOLEDChannel(g) << 8 | SPKOLEDChannel(b);
#if SPK_DEV
    SPKOLEDCensusRecord(rgb, nil);
#endif
    if (!SPKOLEDMapRGB(rgb, outRGB))
        return NO;
    sSPKOLEDLastSource = rgb;
    return YES;
}

static inline void SPKOLEDTagSource(id color) {
#if SPK_DEV
    if (color)
        objc_setAssociatedObject(color, @selector(spk_oledSourceRGB), @(sSPKOLEDLastSource), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#endif
}

static inline CGFloat SPKOLEDComponent(uint32_t rgb, int shift) {
    return ((rgb >> shift) & 0xFF) / 255.0;
}

// Display P3 components are not sRGB, so the palette is matched on the sRGB
// equivalent of a throwaway color. Every target is a neutral gray, and a
// neutral gray has the same components in both spaces, so the mapped value can
// be passed to the P3 constructor as is. An initializer must return the object
// its original built: these hooks are not marked as returning a retained
// object, so handing back a different color over-releases it.
static BOOL SPKOLEDLookupDisplayP3(CGFloat r, CGFloat g, CGFloat b, uint32_t *outRGB);

// Set while a hooked constructor calls through, so the constructor it is built
// on (the class method on the initializer, a mapped color on its own
// components) passes straight through instead of being handled twice.
static __thread int sSPKOLEDDepth;

static UIColor *SPKOLEDMapResolvedColor(UIColor *color) {
    CGFloat r, g, b, a;
    uint32_t mapped;
    if (!color || ![color getRed:&r green:&g blue:&b alpha:&a] || !SPKOLEDLookup(r, g, b, &mapped))
        return color;
    sSPKOLEDDepth++;
    UIColor *result = [UIColor colorWithRed:SPKOLEDComponent(mapped, 16) green:SPKOLEDComponent(mapped, 8) blue:SPKOLEDComponent(mapped, 0) alpha:a];
    sSPKOLEDDepth--;
    SPKOLEDTagSource(result);
    return result;
}

static BOOL SPKOLEDLookupDisplayP3(CGFloat r, CGFloat g, CGFloat b, uint32_t *outRGB) {
    sSPKOLEDDepth++;
    UIColor *probe = [UIColor colorWithDisplayP3Red:r green:g blue:b alpha:1.0];
    sSPKOLEDDepth--;
    CGFloat sr, sg, sb, sa;
    return [probe getRed:&sr green:&sg blue:&sb alpha:&sa] && SPKOLEDLookup(sr, sg, sb, outRGB);
}

static SPKOLEDColorProvider SPKOLEDWrapProvider(SPKOLEDColorProvider provider) {
    if (!provider)
        return provider;
    return ^UIColor *(UITraitCollection *traits) {
        UIColor *color = provider(traits);
        if (traits.userInterfaceStyle != UIUserInterfaceStyleDark)
            return color;
        return SPKOLEDMapResolvedColor(color);
    };
}

%group SPKOLEDDarkModeHooks

%hook UIColor

+ (UIColor *)colorWithDynamicProvider:(SPKOLEDColorProvider)provider {
    if (sSPKOLEDDepth)
        return %orig;
    sSPKOLEDDepth++;
    UIColor *color = %orig(SPKOLEDWrapProvider(provider));
    sSPKOLEDDepth--;
    return color;
}

- (UIColor *)initWithDynamicProvider:(SPKOLEDColorProvider)provider {
    if (sSPKOLEDDepth)
        return %orig;
    sSPKOLEDDepth++;
    UIColor *color = %orig(SPKOLEDWrapProvider(provider));
    sSPKOLEDDepth--;
    return color;
}

// A fixed color has no trait collection to check. These values are IG's dark
// palette, so a fixed one only shows up where IG already resolved for dark (or
// as a near-black text tint, which reads the same once remapped).
+ (UIColor *)colorWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha {
    uint32_t mapped;
    if (sSPKOLEDDepth || !SPKOLEDLookup(red, green, blue, &mapped))
        return %orig;
    sSPKOLEDDepth++;
    UIColor *color = %orig(SPKOLEDComponent(mapped, 16), SPKOLEDComponent(mapped, 8), SPKOLEDComponent(mapped, 0), alpha);
    sSPKOLEDDepth--;
    SPKOLEDTagSource(color);
    return color;
}

- (UIColor *)initWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha {
    uint32_t mapped;
    if (sSPKOLEDDepth || !SPKOLEDLookup(red, green, blue, &mapped))
        return %orig;
    sSPKOLEDDepth++;
    UIColor *color = %orig(SPKOLEDComponent(mapped, 16), SPKOLEDComponent(mapped, 8), SPKOLEDComponent(mapped, 0), alpha);
    sSPKOLEDDepth--;
    SPKOLEDTagSource(color);
    return color;
}

+ (UIColor *)colorWithDisplayP3Red:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha {
    uint32_t mapped;
    if (sSPKOLEDDepth || !SPKOLEDLookupDisplayP3(red, green, blue, &mapped))
        return %orig;
    sSPKOLEDDepth++;
    UIColor *color = %orig(SPKOLEDComponent(mapped, 16), SPKOLEDComponent(mapped, 8), SPKOLEDComponent(mapped, 0), alpha);
    sSPKOLEDDepth--;
    SPKOLEDTagSource(color);
    return color;
}

- (UIColor *)initWithDisplayP3Red:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha {
    uint32_t mapped;
    if (sSPKOLEDDepth || !SPKOLEDLookupDisplayP3(red, green, blue, &mapped))
        return %orig;
    sSPKOLEDDepth++;
    UIColor *color = %orig(SPKOLEDComponent(mapped, 16), SPKOLEDComponent(mapped, 8), SPKOLEDComponent(mapped, 0), alpha);
    sSPKOLEDDepth--;
    SPKOLEDTagSource(color);
    return color;
}

%end

%end

// [UIColor alloc] returns a shared placeholder whose initializers build the
// concrete color, so Swift's UIColor(red:...) and UIColor(dynamicProvider:)
// never reach UIColor's own. Remapping is idempotent (no target is a source),
// so a path that crosses both hooks is still mapped once.
%group SPKOLEDPlaceholderHooks

%hook UIPlaceholderColor

- (UIColor *)initWithDynamicProvider:(SPKOLEDColorProvider)provider {
    if (sSPKOLEDDepth)
        return %orig;
    sSPKOLEDDepth++;
    UIColor *color = %orig(SPKOLEDWrapProvider(provider));
    sSPKOLEDDepth--;
    return color;
}

- (UIColor *)initWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha {
    uint32_t mapped;
    if (sSPKOLEDDepth || !SPKOLEDLookup(red, green, blue, &mapped))
        return %orig;
    sSPKOLEDDepth++;
    UIColor *color = %orig(SPKOLEDComponent(mapped, 16), SPKOLEDComponent(mapped, 8), SPKOLEDComponent(mapped, 0), alpha);
    sSPKOLEDDepth--;
    SPKOLEDTagSource(color);
    return color;
}

- (UIColor *)initWithDisplayP3Red:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha {
    uint32_t mapped;
    if (sSPKOLEDDepth || !SPKOLEDLookupDisplayP3(red, green, blue, &mapped))
        return %orig;
    sSPKOLEDDepth++;
    UIColor *color = %orig(SPKOLEDComponent(mapped, 16), SPKOLEDComponent(mapped, 8), SPKOLEDComponent(mapped, 0), alpha);
    sSPKOLEDDepth--;
    SPKOLEDTagSource(color);
    return color;
}

%end

%end

// UIDeviceRGBColor is the concrete class behind every color built from
// components. Fixed IG backgrounds (the window, the story viewer) arrive as
// UIDeviceRGBColor without passing the UIColor or placeholder initializers,
// so its own initializer is the one place they all go through.
static id (*orig_spkOLEDDeviceRGBInit)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
static id spk_OLEDDeviceRGBInit(id self, SEL _cmd, CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha) {
    uint32_t mapped;
    if (sSPKOLEDDepth || !SPKOLEDLookup(red, green, blue, &mapped))
        return orig_spkOLEDDeviceRGBInit(self, _cmd, red, green, blue, alpha);
    sSPKOLEDDepth++;
    id color = orig_spkOLEDDeviceRGBInit(self, _cmd, SPKOLEDComponent(mapped, 16), SPKOLEDComponent(mapped, 8), SPKOLEDComponent(mapped, 0), alpha);
    sSPKOLEDDepth--;
    SPKOLEDTagSource(color);
    return color;
}

static BOOL SPKOLEDClassOwnsMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL owns = NO;
    for (unsigned int i = 0; i < count && !owns; i++)
        owns = method_getName(methods[i]) == selector;
    free(methods);
    return owns;
}

static void SPKOLEDInstallDeviceRGBHook(void) {
    Class cls = NSClassFromString(@"UIDeviceRGBColor");
    SEL selector = @selector(initWithRed:green:blue:alpha:);
    // Hooking an inherited method would add an override on top of UIColor's.
    if (!cls || !SPKOLEDClassOwnsMethod(cls, selector)) {
        SPKLog(@"OLED", @"UIDeviceRGBColor initializer not found");
        return;
    }
    MSHookMessageEx(cls, selector, (IMP)spk_OLEDDeviceRGBInit, (IMP *)&orig_spkOLEDDeviceRGBInit);
}

// Alerts share their color with surfaces that should be black, but a black
// alert over a black screen has no visible edge. Their own views get the
// raised gray wherever the color would otherwise resolve to opaque black.
static BOOL SPKOLEDIsAlertView(UIView *view) {
    static Class dialogClass, buttonClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dialogClass = NSClassFromString(@"IGDSAlertDialogView");
        buttonClass = NSClassFromString(@"IGDSAlertDialogActionButton");
    });
    return (dialogClass && [view isKindOfClass:dialogClass]) || (buttonClass && [view isKindOfClass:buttonClass]) ||
           objc_getAssociatedObject(view, @selector(spk_oledAlertSurface));
}

// Inside an alert or a sheet, black becomes the surface gray, and a pressed
// button and IG's raised grays (row separators, pressed fills) take the step
// above it, since the raised grays already map to the surface gray. The
// original color rides on the result, so repainting a view never wraps twice.
static UIColor *SPKOLEDAlertColor(UIColor *color, BOOL pressed) {
    UIColor *original = color ? objc_getAssociatedObject(color, @selector(spk_oledAlertOriginal)) : nil;
    if (original)
        color = original;
    if (!color)
        return color;
    sSPKOLEDDepth++;
    UIColor *result = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        UIColor *resolved = [color resolvedColorWithTraitCollection:traits];
        CGFloat r, g, b, a;
        if (traits.userInterfaceStyle != UIUserInterfaceStyleDark || ![resolved getRed:&r green:&g blue:&b alpha:&a] || a < 1.0)
            return resolved;
        uint32_t brightest = MAX(SPKOLEDChannel(r), MAX(SPKOLEDChannel(g), SPKOLEDChannel(b)));
        CGFloat level = (!brightest && !pressed) ? 0x1A : brightest <= 0x2B ? 0x33 : 0;
        if (!level)
            return resolved;
        return [UIColor colorWithRed:level / 255.0 green:level / 255.0 blue:level / 255.0 alpha:1.0];
    }];
    sSPKOLEDDepth--;
    objc_setAssociatedObject(result, @selector(spk_oledAlertOriginal), color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

// Repaints a view with its own color so the alert gray is applied. This goes
// through UIView's setter: IGTapButton overrides setBackgroundColor: to record
// the color as its normal state, so repainting a highlighted button through it
// would make the pressed color stick after the finger leaves.
static void SPKOLEDRepaintBackground(UIView *view) {
    static void (*viewSetter)(id, SEL, UIColor *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        viewSetter = (void (*)(id, SEL, UIColor *))class_getMethodImplementation(UIView.class, @selector(setBackgroundColor:));
    });
    viewSetter(view, @selector(setBackgroundColor:), view.backgroundColor);
}

// The bottom action sheet floats over the page like an alert, so it gets the
// alert's gray. Its surfaces are plain views and buttons with no class of
// their own, so each one inside the sheet is flagged once laid out. The flag
// keeps the gray when IG repaints a button for its highlighted state, which it
// does after the state flips, so the pressed step is picked up there.
static void SPKOLEDFlagAlertSurfaces(UIView *view, UIView *skip, NSUInteger depth) {
    if (view == skip || depth > 8)
        return;
    if (!objc_getAssociatedObject(view, @selector(spk_oledAlertSurface))) {
        objc_setAssociatedObject(view, @selector(spk_oledAlertSurface), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (view.backgroundColor)
            SPKOLEDRepaintBackground(view);
    }
    for (UIView *subview in view.subviews)
        SPKOLEDFlagAlertSurfaces(subview, skip, depth + 1);
}

%group SPKOLEDActionSheetHooks

%hook IGActionSheetController

- (void)viewDidLayoutSubviews {
    %orig;
    IGActionSheetController *sheet = (IGActionSheetController *)self;
    SPKOLEDFlagAlertSurfaces(sheet.contentContainerView, sheet.overlayView, 0);
}

%end

%end

// Last line of defense for backgrounds: a fixed palette color that reached a
// view without passing any constructor above (one created before this dylib
// loaded, say) is still remapped as it is set. Dev builds log who set it, so
// the constructor that was missed can be found and hooked instead.
%group SPKOLEDBackgroundHooks

%hook UIView

- (void)setBackgroundColor:(UIColor *)color {
    if (SPKOLEDIsAlertView(self)) {
        %orig(SPKOLEDAlertColor(color, [self isKindOfClass:UIControl.class] && ((UIControl *)self).highlighted));
        return;
    }
    CGFloat r, g, b, a;
    uint32_t mapped;
    UIColor *dark = [color resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]];
#if SPK_DEV
    if (dark && [dark getRed:&r green:&g blue:&b alpha:&a] && a > 0.01) {
        NSNumber *source = objc_getAssociatedObject(dark, @selector(spk_oledSourceRGB));
        SPKOLEDCensusRecord(source ? source.unsignedIntValue : SPKOLEDChannel(r) << 16 | SPKOLEDChannel(g) << 8 | SPKOLEDChannel(b),
                            NSStringFromClass(self.class));
    }
#endif
    // A fixed color resolves to itself; dynamic ones are already wrapped.
    if (!color || dark != color ||
        ![color getRed:&r green:&g blue:&b alpha:&a] || !SPKOLEDLookup(r, g, b, &mapped)) {
        %orig;
        return;
    }
#if SPK_DEV
    static int logged;
    if (logged < 8) {
        logged++;
        NSArray<NSString *> *stack = NSThread.callStackSymbols;
        SPKLog(@"OLED", @"Unmapped fixed %@ set on %@:\n%@", color, NSStringFromClass(self.class),
               [[stack subarrayWithRange:NSMakeRange(1, MIN((NSUInteger)8, stack.count - 1))] componentsJoinedByString:@"\n"]);
    }
#endif
    %orig(SPKOLEDMapResolvedColor(color));
}

%end

%end

// Installed from %ctor rather than the staged registry: Instagram creates its
// palette while building the first screen, and a view keeps the color object
// it was handed. Installed only when enabled (restart), so the hooks cost
// nothing for everyone else. The key is device-global, read directly.
%ctor {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:@"tools_disable_all"] || SPKStabilityGuardIsSafeStartupMode())
        return;
    if (![defaults boolForKey:@"interface_oled_dark_mode"])
        return;
    %init(SPKOLEDDarkModeHooks);
    if (NSClassFromString(@"UIPlaceholderColor"))
        %init(SPKOLEDPlaceholderHooks);
    SPKOLEDInstallDeviceRGBHook();
    %init(SPKOLEDBackgroundHooks);
}

// Most hooks install in %ctor. The action sheet lives in FBSharedFramework,
// which may not be loaded that early, so its hook is installed here.
void SPKInstallOLEDDarkModeHooksIfEnabled(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (![NSUserDefaults.standardUserDefaults boolForKey:@"interface_oled_dark_mode"])
            return;
        Class sheetClass = NSClassFromString(@"IGActionSheetController");
        if (sheetClass)
            %init(SPKOLEDActionSheetHooks, IGActionSheetController = sheetClass);
    });
}
