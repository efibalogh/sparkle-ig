#import "SPKDiagnostics.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

#import "../../App/SPKCore.h"
#import "../../App/SPKFlexLoader.h"
#import "../../App/SPKStabilityGuard.h"
#import "../../Tweak.h"
#import "../../Utils.h"

NSString *const kSPKPrefToolsDebugButton = @"tools_debug_button";

#if SPK_DEV
static uint32_t SPKDiagnosticsRGBA(UIColor *color, UIUserInterfaceStyle style);
static NSString *SPKDiagnosticsColorSource(UIColor *color);
// Defined by OLED Dark Mode.
NSString *SPKOLEDCensusReport(void);
#endif

// MARK: - Helpers

static NSString *SPKDiagnosticsRect(CGRect r) {
    return [NSString stringWithFormat:@"{%.1f,%.1f %.1fx%.1f}", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static NSString *SPKDiagnosticsRawText(UIView *view) {
    if ([view isKindOfClass:UILabel.class])
        return ((UILabel *)view).text;
    if ([view isKindOfClass:UITextView.class])
        return ((UITextView *)view).text;
    if ([view isKindOfClass:UITextField.class])
        return ((UITextField *)view).text;
    return nil;
}

static NSString *SPKDiagnosticsViewText(UIView *view, BOOL includeText) {
    NSString *text = SPKDiagnosticsRawText(view);
    if (!text.length)
        return @"";
    if (!includeText)
        return [NSString stringWithFormat:@" text=<%lu chars>", (unsigned long)text.length];
    NSString *flat = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    if (flat.length > 60)
        flat = [[flat substringToIndex:60] stringByAppendingString:@"..."];
    return [NSString stringWithFormat:@" text=\"%@\"", flat];
}

static NSString *SPKDiagnosticsAncestors(UIView *view, NSUInteger levels) {
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    UIView *v = view.superview;
    while (v && chain.count < levels) {
        [chain addObject:[NSString stringWithFormat:@"%@[%lu/%lu]", NSStringFromClass(v.class),
                                                    (unsigned long)[v.superview.subviews indexOfObjectIdenticalTo:v],
                                                    (unsigned long)v.superview.subviews.count]];
        v = v.superview;
    }
    return [chain componentsJoinedByString:@" < "];
}

static NSString *SPKDiagnosticsLayerFilters(CALayer *layer) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    void (^collect)(CALayer *, NSString *) = ^(CALayer *source, NSString *prefix) {
        for (id filter in source.filters ?: @[]) {
            id type = [filter respondsToSelector:@selector(type)] ? [filter valueForKey:@"type"] : nil;
            [names addObject:[NSString stringWithFormat:@"%@%@", prefix, type ?: NSStringFromClass([filter class])]];
        }
    };
    collect(layer, @"");
    for (CALayer *sub in layer.sublayers)
        collect(sub, [NSString stringWithFormat:@"sub:%@/", NSStringFromClass(sub.class)]);
    return names.count ? [names componentsJoinedByString:@","] : @"-";
}

static NSArray<UIWindow *> *SPKDiagnosticsInspectableWindows(void) {
    Class flexWindowClass = SPKFlexWindowClass();
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || SPKDebugButtonOwnsWindow(window) || (flexWindowClass && [window isKindOfClass:flexWindowClass]))
                continue;
            [windows addObject:window];
        }
    }
    [windows sortWithOptions:NSSortStable
             usingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
                 if (a.windowLevel == b.windowLevel)
                     return NSOrderedSame;
                 return a.windowLevel < b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
             }];
    return windows;
}

static BOOL SPKDiagnosticsViewIsVisible(UIView *view) {
    return !view.hidden && view.alpha >= 0.01;
}

// Depth-first in subview order, which is the order views are drawn in. Hidden
// subtrees are skipped: nothing in them reaches the screen.
static void SPKDiagnosticsWalk(UIView *root, void (^block)(UIView *view, NSUInteger depth)) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:@[ root, @0 ]];
    while (stack.count) {
        NSArray *entry = stack.lastObject;
        [stack removeLastObject];
        UIView *view = entry[0];
        if (!SPKDiagnosticsViewIsVisible(view))
            continue;
        NSUInteger depth = [entry[1] unsignedIntegerValue];
        block(view, depth);
        for (UIView *sub in view.subviews.reverseObjectEnumerator)
            [stack addObject:@[ sub, @(depth + 1) ]];
    }
}

static NSArray<UIView *> *SPKDiagnosticsVisibleViewsInPaintOrder(void) {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    for (UIWindow *window in SPKDiagnosticsInspectableWindows()) {
        SPKDiagnosticsWalk(window, ^(UIView *view, __unused NSUInteger depth) {
            [views addObject:view];
        });
    }
    return views;
}

static NSString *SPKDiagnosticsDescribeView(UIView *view, BOOL includeText) {
    CGRect frame = [view convertRect:view.bounds toView:nil];
    NSMutableString *flags = [NSMutableString string];
    if (view.alpha < 1.0)
        [flags appendFormat:@" alpha=%.2f", view.alpha];
    if (!view.userInteractionEnabled)
        [flags appendString:@" noTouch"];
    if (view.clipsToBounds)
        [flags appendString:@" clips"];
    if (view.layer.mask || view.maskView)
        [flags appendString:@" masked"];
    return [NSString stringWithFormat:@"%@ %p %@%@%@", NSStringFromClass(view.class), view, SPKDiagnosticsRect(frame), flags,
                                      SPKDiagnosticsViewText(view, includeText)];
}

static NSString *SPKDiagnosticsInfoString(NSString *key) {
    id value = [NSBundle.mainBundle objectForInfoDictionaryKey:key];
    return value ? [NSString stringWithFormat:@"%@", value] : @"?";
}

static NSString *SPKDiagnosticsDeviceModel(void) {
    char model[64] = {0};
    size_t size = sizeof(model);
    if (sysctlbyname("hw.machine", model, &size, NULL, 0) != 0)
        return @"?";
    return [NSString stringWithUTF8String:model];
}

static NSString *SPKDiagnosticsTweakPath(void) {
    Dl_info info;
    if (dladdr((const void *)&SPKDiagnosticsTweakPath, &info) && info.dli_fname)
        return [NSString stringWithUTF8String:info.dli_fname];
    return @"?";
}

static NSString *SPKDiagnosticsHeader(NSString *title) {
    return [NSString stringWithFormat:@"# %@\nSparkle %@ | Instagram %@ (%@) | SDK %@ | iOS %@ | %@\n",
                                      title, SPKVersionString, SPKDiagnosticsInfoString(@"CFBundleShortVersionString"),
                                      SPKDiagnosticsInfoString(@"CFBundleVersion"), SPKDiagnosticsInfoString(@"DTSDKName"),
                                      UIDevice.currentDevice.systemVersion, SPKDiagnosticsDeviceModel()];
}

// MARK: - Screen report

static void SPKDiagnosticsAppendControllerTree(NSMutableString *out, UIViewController *controller, NSUInteger depth, NSString *role) {
    if (!controller || depth > 24)
        return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@%@%@ %p", indent, role.length ? [role stringByAppendingString:@" "] : @"",
                                                              NSStringFromClass(controller.class), controller];
    if (controller.isViewLoaded && controller.view.window)
        [line appendString:@" onscreen"];
    [out appendFormat:@"%@\n", line];

    UIViewController *selected = nil;
    if ([controller isKindOfClass:UITabBarController.class])
        selected = ((UITabBarController *)controller).selectedViewController;
    UIViewController *top = [controller isKindOfClass:UINavigationController.class] ? ((UINavigationController *)controller).topViewController : nil;
    for (UIViewController *child in controller.childViewControllers) {
        NSString *childRole = child == selected ? @"[selected]" : (child == top ? @"[top]" : @"");
        SPKDiagnosticsAppendControllerTree(out, child, depth + 1, childRole);
    }
    // Only the presentation made by this controller, not one it inherits.
    UIViewController *presented = controller.presentedViewController;
    if (presented && presented.presentingViewController == controller)
        SPKDiagnosticsAppendControllerTree(out, presented, depth + 1, @"[presented]");
}

// Only switches, numbers and short option tokens are shown: other values can
// hold usernames, allow-lists or coordinates.
static NSString *SPKDiagnosticsPreferenceValue(NSString *key, id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        NSString *lowerKey = key.lowercaseString;
        for (NSString *fragment in @[ @"lat", @"lon", @"lng", @"coord", @"location" ]) {
            if ([lowerKey containsString:fragment])
                return @"<number>";
        }
        return [value description];
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *string = value;
        NSCharacterSet *token = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_-."];
        if (string.length <= 24 && [string rangeOfCharacterFromSet:token.invertedSet].location == NSNotFound)
            return string;
        return [NSString stringWithFormat:@"<%lu chars>", (unsigned long)string.length];
    }
    if ([value isKindOfClass:NSArray.class])
        return [NSString stringWithFormat:@"<%lu items>", (unsigned long)((NSArray *)value).count];
    if ([value isKindOfClass:NSDictionary.class])
        return [NSString stringWithFormat:@"<%lu entries>", (unsigned long)((NSDictionary *)value).count];
    return [NSString stringWithFormat:@"<%@>", NSStringFromClass([value class])];
}

NSString *SPKDiagnosticsScreenReport(__unused BOOL includeText) {
    NSMutableString *out = [NSMutableString stringWithString:SPKDiagnosticsHeader(@"Screen report")];
    UITraitCollection *traits = UIScreen.mainScreen.traitCollection;
    [out appendFormat:@"tweak=%@\nstyle=%@ language=%@ perAccount=%d safeMode=%d disableAll=%d\n", SPKDiagnosticsTweakPath(),
                      traits.userInterfaceStyle == UIUserInterfaceStyleDark ? @"dark" : @"light",
                      NSLocale.preferredLanguages.firstObject ?: @"?", SPKPerAccountModeActive(), SPKStabilityGuardIsSafeStartupMode(),
                      [SPKUtils getBoolPref:@"tools_disable_all"]];

    [out appendString:@"\n## View controllers\n"];
    for (UIWindow *window in SPKDiagnosticsInspectableWindows()) {
        [out appendFormat:@"window %@ %p level=%.0f key=%d %@\n", NSStringFromClass(window.class), window, window.windowLevel, window.isKeyWindow,
                          SPKDiagnosticsRect(window.frame)];
        SPKDiagnosticsAppendControllerTree(out, window.rootViewController, 1, @"[root]");
    }

    [out appendString:@"\n## Preferences changed from default\n"];
    NSDictionary<NSString *, id> *defaults = SPKCoreRegisteredDefaults();
    for (NSString *key in [defaults.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id value = SPKPreferenceObjectForKey(key);
        if (!value || [value isEqual:defaults[key]])
            continue;
        [out appendFormat:@"%@ = %@\n", key, SPKDiagnosticsPreferenceValue(key, value)];
    }
    return out;
}

// MARK: - Hierarchy report

NSString *SPKDiagnosticsHierarchyReport(BOOL includeText) {
    NSMutableString *out = [NSMutableString stringWithString:SPKDiagnosticsHeader(@"View hierarchy")];
    for (UIWindow *window in SPKDiagnosticsInspectableWindows()) {
        [out appendString:@"\n"];
        SPKDiagnosticsWalk(window, ^(UIView *view, NSUInteger depth) {
            NSString *indent = [@"" stringByPaddingToLength:MIN(depth, (NSUInteger)60) withString:@" " startingAtIndex:0];
            [out appendFormat:@"%@%@\n", indent, SPKDiagnosticsDescribeView(view, includeText)];
        });
    }
    return out;
}

// MARK: - Inspect report

// Whether a view puts anything on screen itself. Layout and touch containers
// (UIKit's passthrough, wrapper and transition views, most IG hosting views)
// draw nothing and sit above the content they hold, so picking the topmost
// view at a point would almost always land on one of them.
static BOOL SPKDiagnosticsViewDrawsContent(UIView *view) {
    if (view.backgroundColor && CGColorGetAlpha(view.backgroundColor.CGColor) > 0.01)
        return YES;
    if ([view isKindOfClass:UILabel.class])
        return ((UILabel *)view).text.length > 0 || ((UILabel *)view).attributedText.length > 0;
    if ([view isKindOfClass:UIImageView.class])
        return ((UIImageView *)view).image != nil;
    if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UITextView.class] || [view isKindOfClass:UIVisualEffectView.class])
        return YES;
    NSString *name = NSStringFromClass(view.class);
    for (NSString *fragment in @[ @"Backdrop", @"Blur", @"EdgeEffect", @"Glass", @"Video", @"Player" ]) {
        if ([name containsString:fragment])
            return YES;
    }
    CALayer *layer = view.layer;
    if (layer.contents || layer.filters.count || (layer.borderWidth > 0 && layer.borderColor && CGColorGetAlpha(layer.borderColor) > 0.01))
        return YES;
    // Shape, gradient, text, Metal and player layers draw without contents.
    return layer.class != CALayer.class;
}

// A point outside an ancestor that clips is not visible in the view, even
// though it lies inside the view's own bounds.
static BOOL SPKDiagnosticsViewShowsPoint(UIView *view, CGPoint point, id<UICoordinateSpace> screen) {
    for (UIView *v = view; v; v = v.superview) {
        if (v != view && !v.clipsToBounds)
            continue;
        if (!CGRectContainsPoint(v.bounds, [v convertPoint:point fromCoordinateSpace:screen]))
            return NO;
    }
    return YES;
}

NSString *SPKDiagnosticsInspectReport(CGPoint point, BOOL includeText, UIView **selectedView) {
    NSArray<UIView *> *views = SPKDiagnosticsVisibleViewsInPaintOrder();
    NSMutableArray<UIView *> *underPoint = [NSMutableArray array];
    for (UIView *view in views.reverseObjectEnumerator) {
        id<UICoordinateSpace> screen = view.window.windowScene.coordinateSpace ?: view.window.screen.coordinateSpace;
        if (SPKDiagnosticsViewShowsPoint(view, point, screen))
            [underPoint addObject:view];
    }

    NSMutableString *out = [NSMutableString stringWithString:SPKDiagnosticsHeader(@"Inspect element")];
    [out appendFormat:@"point=%.1f,%.1f\n", point.x, point.y];

    // What a touch at this point is delivered to.
    for (UIWindow *window in SPKDiagnosticsInspectableWindows().reverseObjectEnumerator) {
        CGPoint local = [window convertPoint:point fromCoordinateSpace:window.windowScene.coordinateSpace];
        UIView *hit = [window hitTest:local withEvent:nil];
        if (hit) {
            [out appendFormat:@"touch target=%@\n", SPKDiagnosticsDescribeView(hit, includeText)];
            break;
        }
    }

    // The topmost view that draws something, falling back to the topmost view
    // when everything under the point is a container.
    UIView *selected = underPoint.firstObject;
    for (UIView *view in underPoint) {
        if (SPKDiagnosticsViewDrawsContent(view)) {
            selected = view;
            break;
        }
    }
    if (selectedView)
        *selectedView = selected;
    if (!selected) {
        [out appendString:@"\nNothing visible under this point.\n"];
        return out;
    }

    [out appendFormat:@"\n## Selected\n%@\n", SPKDiagnosticsDescribeView(selected, includeText)];
    UIViewController *owner = [SPKUtils nearestViewControllerForView:selected];
    [out appendFormat:@"controller=%@ %p\nfilters=%@\nbackground=%@\ngestures=", owner ? NSStringFromClass(owner.class) : @"-", owner,
                      SPKDiagnosticsLayerFilters(selected.layer), selected.backgroundColor ?: @"-"];
#if SPK_DEV
    if (selected.backgroundColor) {
        UIUserInterfaceStyle style = selected.traitCollection.userInterfaceStyle;
        [out appendFormat:@"backgroundResolved=#%08X %@\n", SPKDiagnosticsRGBA(selected.backgroundColor, style),
                          SPKDiagnosticsColorSource(selected.backgroundColor)];
    }
#endif
    NSMutableArray<NSString *> *gestures = [NSMutableArray array];
    for (UIGestureRecognizer *recognizer in selected.gestureRecognizers)
        [gestures addObject:NSStringFromClass(recognizer.class)];
    [out appendFormat:@"%@\nancestors=%@\n", gestures.count ? [gestures componentsJoinedByString:@","] : @"-", SPKDiagnosticsAncestors(selected, 40)];

    [out appendString:@"\n## Under this point, topmost first\n"];
    for (NSUInteger i = 0; i < underPoint.count && i < 40; i++) {
        UIView *view = underPoint[i];
        NSString *tag = view == selected ? @"> " : (SPKDiagnosticsViewDrawsContent(view) ? @"  " : @"  (container) ");
        [out appendFormat:@"%@%@\n", tag, SPKDiagnosticsDescribeView(view, includeText)];
    }

    // Everything drawn over the selected view: overlays, blurs and edge effects.
    [out appendString:@"\n## Drawn above the selected view\n"];
    CGRect selectedFrame = [selected convertRect:selected.bounds toView:nil];
    NSUInteger listed = 0;
    NSUInteger start = [views indexOfObjectIdenticalTo:selected];
    for (NSUInteger i = start == NSNotFound ? views.count : start + 1; i < views.count && listed < 40; i++) {
        UIView *view = views[i];
        if ([view isDescendantOfView:selected])
            continue;
        CGRect frame = [view convertRect:view.bounds toView:nil];
        if (view.window != selected.window || !CGRectIntersectsRect(frame, selectedFrame) || frame.size.width < 1 || frame.size.height < 1)
            continue;
        [out appendFormat:@"%@ filters=%@\n", SPKDiagnosticsDescribeView(view, includeText), SPKDiagnosticsLayerFilters(view.layer)];
        listed++;
    }
    if (listed == 0)
        [out appendString:@"-\n"];
    return out;
}

// MARK: - Color report

#if SPK_DEV

// 0xRRGGBBAA for a color resolved under the given style.
static uint32_t SPKDiagnosticsRGBA(UIColor *color, UIUserInterfaceStyle style) {
    UIColor *resolved = [color resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:style]];
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![resolved getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat white = 0;
        if (![resolved getWhite:&white alpha:&a])
            return 0;
        r = g = b = white;
    }
    uint32_t (^channel)(CGFloat) = ^uint32_t(CGFloat value) {
        return (uint32_t)lround(MIN(MAX(value, 0.0), 1.0) * 255.0);
    };
    return channel(r) << 24 | channel(g) << 16 | channel(b) << 8 | channel(a);
}

// The color's kind: its name for system and asset colors, otherwise its class
// (a dynamic provider color, or a fixed one built from components).
static NSString *SPKDiagnosticsColorSource(UIColor *color) {
    NSString *description = color.description;
    NSRange name = [description rangeOfString:@"name = "];
    if (name.location != NSNotFound) {
        NSString *rest = [description substringFromIndex:NSMaxRange(name)];
        NSRange end = [rest rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@";>"]];
        return [NSString stringWithFormat:@"%@(%@)", NSStringFromClass(color.class), end.location == NSNotFound ? rest : [rest substringToIndex:end.location]];
    }
    return NSStringFromClass(color.class);
}

// OLED Dark Mode tags each color it remaps with the palette value it replaced.
static NSString *SPKDiagnosticsOLEDOrigin(UIColor *color, UIUserInterfaceStyle style) {
    UIColor *resolved = [color resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:style]];
    NSNumber *source = objc_getAssociatedObject(resolved, @selector(spk_oledSourceRGB));
    return source ? [NSString stringWithFormat:@" from #%06X", source.unsignedIntValue] : @"";
}

// A plain UIView says nothing on its own, so it is named after the closest
// ancestor of a more specific class (the sheet or cell it belongs to).
static NSString *SPKDiagnosticsViewName(UIView *view) {
    if (view.class != UIView.class && view.class != UIImageView.class)
        return NSStringFromClass(view.class);
    for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        if (ancestor.class != UIView.class && ancestor.class != UIImageView.class)
            return [NSString stringWithFormat:@"%@ in %@", NSStringFromClass(view.class), NSStringFromClass(ancestor.class)];
    }
    return NSStringFromClass(view.class);
}

static BOOL SPKDiagnosticsIsNearBlack(uint32_t rgba) {
    uint32_t r = rgba >> 24, g = (rgba >> 16) & 0xFF, b = (rgba >> 8) & 0xFF, a = rgba & 0xFF;
    return a >= 0xF0 && MAX(r, MAX(g, b)) <= 0x30 && (r | g | b) != 0;
}

static BOOL SPKDiagnosticsIsKeyboardWindow(UIWindow *window) {
    NSString *name = NSStringFromClass(window.class);
    return [name containsString:@"Keyboard"] || [name containsString:@"TextEffects"];
}

NSString *SPKDiagnosticsColorReport(void) {
    NSMutableString *out = [NSMutableString stringWithString:SPKDiagnosticsHeader(@"Color report")];
    UIUserInterfaceStyle screenStyle = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    [out appendFormat:@"style=%@ oled=%d\n", screenStyle == UIUserInterfaceStyleDark ? @"dark" : @"light",
                      [NSUserDefaults.standardUserDefaults boolForKey:@"interface_oled_dark_mode"]];

    // Backgrounds on screen, grouped by resolved value and source, weighted by
    // the area they cover so the colors that dominate the screen come first.
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *materials = [NSMutableArray array];
    NSMutableString *keyboard = [NSMutableString string];
    NSMutableString *responders = [NSMutableString string];
    for (UIWindow *window in SPKDiagnosticsInspectableWindows()) {
        BOOL keyboardWindow = SPKDiagnosticsIsKeyboardWindow(window);
        CGRect screenBounds = window.bounds;
        if (keyboardWindow)
            [keyboard appendFormat:@"window %@ %p level=%.0f\n", NSStringFromClass(window.class), window, window.windowLevel];
        SPKDiagnosticsWalk(window, ^(UIView *view, NSUInteger depth) {
            if (view.isFirstResponder && [view conformsToProtocol:@protocol(UITextInputTraits)]) {
                UIKeyboardAppearance appearance = [(id<UITextInputTraits>)view respondsToSelector:@selector(keyboardAppearance)]
                                                      ? ((id<UITextInputTraits>)view).keyboardAppearance
                                                      : UIKeyboardAppearanceDefault;
                [responders appendFormat:@"%@ %p keyboardAppearance=%ld\n", NSStringFromClass(view.class), view, (long)appearance];
            }
            UIUserInterfaceStyle style = view.traitCollection.userInterfaceStyle;
            UIColor *color = view.backgroundColor;
            CGColorRef layerColor = color ? NULL : view.layer.backgroundColor;
            if ([view isKindOfClass:UIVisualEffectView.class]) {
                UIVisualEffect *effect = ((UIVisualEffectView *)view).effect;
                [materials addObject:[NSString stringWithFormat:@"%@ effect=%@ %@", NSStringFromClass(view.class),
                                                                effect ? NSStringFromClass(effect.class) : @"-",
                                                                SPKDiagnosticsRect([view convertRect:view.bounds toView:nil])]];
            }
            if (keyboardWindow) {
                NSString *indent = [@"" stringByPaddingToLength:MIN(depth, (NSUInteger)40) withString:@" " startingAtIndex:0];
                NSString *background = color ? [NSString stringWithFormat:@" bg=#%08X", SPKDiagnosticsRGBA(color, style)]
                                             : (layerColor ? [NSString stringWithFormat:@" layerBg=#%08X", SPKDiagnosticsRGBA([UIColor colorWithCGColor:layerColor], style)] : @"");
                [keyboard appendFormat:@"%@%@ %p %@%@ filters=%@\n", indent, NSStringFromClass(view.class), view,
                                       SPKDiagnosticsRect([view convertRect:view.bounds toView:nil]), background, SPKDiagnosticsLayerFilters(view.layer)];
            }
            if (!color && layerColor)
                color = [UIColor colorWithCGColor:layerColor];
            if (!color)
                return;
            uint32_t rgba = SPKDiagnosticsRGBA(color, style);
            if ((rgba & 0xFF) < 0x03)
                return;
            CGRect frame = CGRectIntersection([view convertRect:view.bounds toView:nil], screenBounds);
            CGFloat area = CGRectIsNull(frame) ? 0 : frame.size.width * frame.size.height;
            NSString *source = layerColor ? @"CALayer" : [SPKDiagnosticsColorSource(color) stringByAppendingString:SPKDiagnosticsOLEDOrigin(color, style)];
            NSString *key = [NSString stringWithFormat:@"#%08X %@%@", rgba, source, keyboardWindow ? @" [keyboard]" : @""];
            NSMutableDictionary *group = groups[key];
            if (!group) {
                group = [@{ @"rgba" : @(rgba), @"area" : @0, @"count" : @0, @"classes" : [NSCountedSet set] } mutableCopy];
                groups[key] = group;
            }
            group[@"area"] = @([group[@"area"] doubleValue] + area);
            group[@"count"] = @([group[@"count"] unsignedIntegerValue] + 1);
            [group[@"classes"] addObject:SPKDiagnosticsViewName(view)];
        });
    }

    NSArray<NSString *> *keys = [groups.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        double areaA = [groups[a][@"area"] doubleValue], areaB = [groups[b][@"area"] doubleValue];
        if (areaA != areaB)
            return areaA > areaB ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
    NSString * (^describe)(NSString *) = ^NSString *(NSString *key) {
        NSDictionary *group = groups[key];
        NSCountedSet *classes = group[@"classes"];
        NSArray *sorted = [classes.allObjects sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            NSUInteger countA = [classes countForObject:a], countB = [classes countForObject:b];
            return countA == countB ? NSOrderedSame : (countA > countB ? NSOrderedAscending : NSOrderedDescending);
        }];
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *name in sorted) {
            if (names.count == 5)
                break;
            [names addObject:[NSString stringWithFormat:@"%@x%lu", name, (unsigned long)[classes countForObject:name]]];
        }
        return [NSString stringWithFormat:@"%8.0fpt2 %4lu views  %@  <- %@\n", [group[@"area"] doubleValue], (unsigned long)[group[@"count"] unsignedIntegerValue],
                                          key, [names componentsJoinedByString:@", "]];
    };

    [out appendString:@"\n## Near-black backgrounds (OLED candidates)\n"];
    NSUInteger nearBlack = 0;
    for (NSString *key in keys) {
        if (!SPKDiagnosticsIsNearBlack([groups[key][@"rgba"] unsignedIntValue]))
            continue;
        [out appendString:describe(key)];
        nearBlack++;
    }
    if (!nearBlack)
        [out appendString:@"-\n"];

    [out appendString:@"\n## All backgrounds on screen, by area\n"];
    for (NSString *key in keys)
        [out appendString:describe(key)];

    [out appendString:@"\n## Materials\n"];
    [out appendString:materials.count ? [[materials componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] : @"-\n"];

    [out appendString:@"\n## Palette census since launch (dark values, darkest first)\n"];
    [out appendString:SPKOLEDCensusReport()];

    [out appendString:@"\n## Keyboard\n"];
    [out appendString:responders.length ? responders : @"first responder: -\n"];
    [out appendString:keyboard.length ? keyboard : @"no keyboard window on screen\n"];
    return out;
}

#endif
