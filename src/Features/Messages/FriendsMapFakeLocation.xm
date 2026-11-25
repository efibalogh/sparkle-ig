// Fake location for the Friends Map (and the rest of Instagram's location stack).
//
// The spoof is scoped to Instagram's own managers rather than CLLocationManager as
// a whole: IGThreadedLocationManager owns the CLLocationManager and is its delegate,
// and IGLocationManager caches the fix on top of it. Replacing the fix at those
// layers covers every Instagram reader (Friends Map upload, location stickers,
// nearby places) while MapKit and system frameworks keep the real position, which
// is also what lets the picker show where the user actually is.

#import "../../AssetUtils.h"
#import "../../Shared/Location/SPKFakeLocation.h"
#import "../../Shared/Location/SPKFakeLocationPickerViewController.h"
#import "../../Shared/Location/SPKFakeLocationSettingsViewController.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"
#import <objc/runtime.h>

static Class SPKIGThreadedLocationManagerClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = NSClassFromString(@"IGThreadedLocationManager");
    });
    return cls;
}

static NSArray<CLLocation *> *SPKFakeLocationSubstitutedFixes(NSArray<CLLocation *> *locations) {
    CLLocation *fake = [SPKFakeLocation spoofedLocation];
    return fake ? @[ fake ] : locations;
}

#pragma mark - Location stack

%group SPKFakeLocationStackHooks

// IG's threaded manager also reads its CLLocationManager's `location` directly to
// seed its cache. Only managers IG owns are touched; every other client in the
// process (MapKit included) sees the real value.
%hook CLLocationManager
- (CLLocation *)location {
    CLLocation *fake = [SPKFakeLocation spoofedLocation];
    if (fake) {
        Class threaded = SPKIGThreadedLocationManagerClass();
        if (threaded && [self.delegate isKindOfClass:threaded])
            return fake;
    }
    return %orig;
}
%end

%hook IGThreadedLocationManager
- (CLLocation *)location {
    return [SPKFakeLocation spoofedLocation] ?: %orig;
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    %orig(manager, SPKFakeLocationSubstitutedFixes(locations));
}
%end

%hook IGLocationManager
- (CLLocation *)lastLocation {
    return [SPKFakeLocation spoofedLocation] ?: %orig;
}

- (void)locationManager:(id)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    %orig(manager, SPKFakeLocationSubstitutedFixes(locations));
}
%end

%end

extern "C" void SPKInstallFakeLocationHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Installed unconditionally: the switch is per account and read on every
        // fix, so an account switch never needs a restart. With the fake location
        // off the hooks cost one lock and fall through.
        [SPKFakeLocation reloadCache];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
                                                          [SPKFakeLocation reloadCache];
                                                      }];
        %init(SPKFakeLocationStackHooks);
        SPKLog(@"FakeLocation", @"[Sparkle] Location stack hooks installed (active=%@)", [SPKFakeLocation isActive] ? @"YES" : @"NO");
    });
}

#pragma mark - Friends Map button

static const NSInteger kSPKFakeLocationMapButtonTag = 0x5F4C4D42;
static const CGFloat kSPKFakeLocationMapButtonFallbackSize = 44.0;
static const CGFloat kSPKFakeLocationMapButtonFallbackSpacing = 12.0;
static const CGFloat kSPKFakeLocationMapButtonGlyphRatio = 0.5;
static const void *kSPKFakeLocationMapButtonSignatureKey = &kSPKFakeLocationMapButtonSignatureKey;

static NSHashTable<UIView *> *SPKFakeLocationMapStacks(void) {
    static NSHashTable *stacks;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stacks = [NSHashTable weakObjectsHashTable];
    });
    return stacks;
}

static void SPKFakeLocationPresentPicker(UIView *source, NSString *title, void (^completion)(SPKFakeLocationPlace *place)) {
    [SPKFakeLocationPickerViewController presentFromViewController:[SPKUtils nearestViewControllerForView:source]
                                                      initialPlace:[SPKFakeLocation currentPlace]
                                                             title:title
                                                        completion:completion];
}

static void SPKFakeLocationNotifyApplied(SPKFakeLocationPlace *place) {
    SPKNotify(kSPKNotificationFakeLocation, SPKL(@"MESSAGES_FAKE_LOCATION_TOAST_UPDATED"), place.name, @"location_filled", SPKNotificationToneSuccess);
}

static NSArray<UIMenuElement *> *SPKFakeLocationMapMenuElements(UIView *source) {
    __weak UIView *weakSource = source;
    BOOL active = [SPKFakeLocation isActive];
    SPKFakeLocationPlace *current = [SPKFakeLocation currentPlace];

    UIAction *toggle = [UIAction actionWithTitle:SPKL(@"MESSAGES_FAKE_LOCATION_ENABLED_TITLE")
                                           image:[SPKAssetUtils menuIconNamed:@"location"]
                                      identifier:nil
                                         handler:^(__unused UIAction *action) {
                                             if (active) {
                                                 [SPKFakeLocation setEnabled:NO];
                                                 SPKNotify(kSPKNotificationFakeLocation, SPKL(@"MESSAGES_FAKE_LOCATION_TOAST_OFF"), nil, @"location_filled", SPKNotificationToneInfo);
                                                 return;
                                             }
                                             if ([SPKFakeLocation setEnabled:YES]) {
                                                 SPKNotify(kSPKNotificationFakeLocation, SPKL(@"MESSAGES_FAKE_LOCATION_TOAST_ON"), [SPKFakeLocation currentPlace].name, @"location_filled", SPKNotificationToneSuccess);
                                                 return;
                                             }
                                             SPKFakeLocationPresentPicker(weakSource, SPKL(@"MESSAGES_FAKE_LOCATION_PICKER_TITLE"), ^(SPKFakeLocationPlace *place) {
                                                 [SPKFakeLocation applyPlace:place enable:YES];
                                                 SPKFakeLocationNotifyApplied(place);
                                             });
                                         }];
    toggle.state = active ? UIMenuElementStateOn : UIMenuElementStateOff;
    toggle.subtitle = current.name;

    UIAction *choose = [UIAction actionWithTitle:SPKL(@"MESSAGES_FAKE_LOCATION_PICKER_TITLE")
                                           image:[SPKAssetUtils menuIconNamed:@"map_pin"]
                                      identifier:nil
                                         handler:^(__unused UIAction *action) {
                                             SPKFakeLocationPresentPicker(weakSource, SPKL(@"MESSAGES_FAKE_LOCATION_PICKER_TITLE"), ^(SPKFakeLocationPlace *place) {
                                                 [SPKFakeLocation applyPlace:place enable:YES];
                                                 SPKFakeLocationNotifyApplied(place);
                                             });
                                         }];

    NSMutableArray<UIMenuElement *> *savedItems = [NSMutableArray array];
    BOOL currentIsSaved = NO;
    for (SPKFakeLocationPlace *place in [SPKFakeLocation savedPlaces]) {
        BOOL matches = [SPKFakeLocation savedPlaceMatchesCurrent:place];
        currentIsSaved = currentIsSaved || matches;
        UIAction *item = [UIAction actionWithTitle:place.name.length ? place.name : [place displaySubtitle]
                                             image:[SPKAssetUtils menuIconNamed:@"location"]
                                        identifier:nil
                                           handler:^(__unused UIAction *action) {
                                               [SPKFakeLocation applyPlace:place enable:YES];
                                               SPKFakeLocationNotifyApplied(place);
                                           }];
        item.state = (active && matches) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [savedItems addObject:item];
    }
    // Saved places collapse into a submenu so a long list never pushes the main
    // actions off the menu. Saving the active place lives there too, below the list.
    NSMutableArray<UIMenuElement *> *savedChildren = [NSMutableArray array];
    if (savedItems.count)
        [savedChildren addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:savedItems]];
    if (current && !currentIsSaved) {
        UIAction *saveCurrent = [UIAction actionWithTitle:SPKL(@"MESSAGES_FAKE_LOCATION_SAVE_CURRENT_TITLE")
                                                    image:[SPKAssetUtils menuIconNamed:@"location_add"]
                                               identifier:nil
                                                  handler:^(__unused UIAction *action) {
                                                      SPKFakeLocationPromptToSavePlace([SPKUtils nearestViewControllerForView:weakSource], [SPKFakeLocation currentPlace]);
                                                  }];
        [savedChildren addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ saveCurrent ]]];
    }
    UIMenu *saved = savedChildren.count
                        ? [UIMenu menuWithTitle:SPKL(@"MESSAGES_FAKE_LOCATION_SAVED_HEADER") image:[SPKAssetUtils menuIconNamed:@"save"] identifier:nil options:0 children:savedChildren]
                        : nil;

    UIAction *settings = [UIAction actionWithTitle:SPKL(@"MESSAGES_FAKE_LOCATION_MENU_SETTINGS_TITLE")
                                             image:[SPKAssetUtils menuIconNamed:@"settings"]
                                        identifier:nil
                                           handler:^(__unused UIAction *action) {
                                               [SPKUtils presentViewControllerInSheet:[SPKFakeLocationSettingsViewController new]];
                                           }];

    NSMutableArray<UIMenuElement *> *sections = [NSMutableArray array];
    [sections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ toggle, choose ]]];
    if (saved)
        [sections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ saved ]]];
    [sections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ settings ]]];
    return sections;
}

// Built once per button: the deferred element is re-evaluated each time the menu
// opens, so the menu never has to be rebuilt from layout (which would reset it
// mid-morph on iOS 26).
static UIMenu *SPKFakeLocationMapMenu(UIView *source) {
    __weak UIView *weakSource = source;
    UIDeferredMenuElement *deferred = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion(SPKFakeLocationMapMenuElements(weakSource));
    }];
    return [UIMenu menuWithTitle:@"" children:@[ deferred ]];
}

// Friends Map chrome, measured from IG's own chrome buttons on device: a solid
// circle (no blur), a tinted soft shadow and a template glyph. The light/dark pairs
// are IG's resolved values for each appearance.
static UIColor *SPKFakeLocationDynamicColor(CGFloat lightR, CGFloat lightG, CGFloat lightB, CGFloat darkR, CGFloat darkG, CGFloat darkB) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [UIColor colorWithRed:darkR green:darkG blue:darkB alpha:1.0];
        return [UIColor colorWithRed:lightR green:lightG blue:lightB alpha:1.0];
    }];
}

static UIColor *SPKFakeLocationMapButtonFill(void) {
    return SPKFakeLocationDynamicColor(1.0, 1.0, 1.0, 0.0952, 0.1103, 0.1229);
}

static UIColor *SPKFakeLocationMapButtonGlyphColor(void) {
    return SPKFakeLocationDynamicColor(0.0430, 0.0633, 0.0801, 0.9717, 0.9766, 0.9765);
}

static const void *kSPKFakeLocationHolderButtonKey = &kSPKFakeLocationHolderButtonKey;

// The button is a plain UIButton drawn like IG's: fill, round corners and shadow
// all on its own layer. That layer is what the menu's open and close animation
// lifts, so the shadow stays with the button through it. The button sits inside
// a capture-hidden canvas rather than the other way round, so Hide UI on Capture
// removes the shadow from screenshots along with the button.
static UIButton *SPKFakeLocationMakeMapButton(CGFloat diameter) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(0.0, 0.0, diameter, diameter);
    button.adjustsImageWhenHighlighted = NO;
    button.accessibilityLabel = SPKL(@"MESSAGES_FAKE_LOCATION_TITLE");
    button.showsMenuAsPrimaryAction = YES;
    button.menu = SPKFakeLocationMapMenu(button);
    button.backgroundColor = SPKFakeLocationMapButtonFill();

    CALayer *layer = button.layer;
    layer.cornerRadius = diameter / 2.0;
    layer.cornerCurve = kCACornerCurveCircular;
    layer.masksToBounds = NO;
    layer.shadowColor = [UIColor colorWithRed:0.0430 green:0.0633 blue:0.0801 alpha:1.0].CGColor;
    layer.shadowOpacity = 0.15;
    layer.shadowOffset = CGSizeMake(0.0, 2.0);
    layer.shadowRadius = 5.0;
    layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:button.bounds].CGPath;
    return button;
}

static SPKChromeCanvas *SPKFakeLocationMakeMapHolder(CGFloat diameter) {
    SPKChromeCanvas *holder = [[SPKChromeCanvas alloc] initWithFrame:CGRectMake(0.0, 0.0, diameter, diameter)];
    // Placed by frame inside a manually laid out view. Left with constraint-based
    // layout, the stack's layout pass resets it to the origin, on top of IG's
    // topmost button.
    holder.translatesAutoresizingMaskIntoConstraints = YES;
    holder.tag = kSPKFakeLocationMapButtonTag;
    UIButton *button = SPKFakeLocationMakeMapButton(diameter);
    [holder.contentContainer addSubview:button];
    objc_setAssociatedObject(holder, kSPKFakeLocationHolderButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return holder;
}

static UIButton *SPKFakeLocationHolderButton(UIView *holder) {
    return holder ? objc_getAssociatedObject(holder, kSPKFakeLocationHolderButtonKey) : nil;
}

static void SPKFakeLocationConfigureGlyph(UIButton *button) {
    BOOL active = [SPKFakeLocation isActive];
    NSString *signature = active ? @"on" : @"off";
    if (!button || [signature isEqualToString:objc_getAssociatedObject(button, kSPKFakeLocationMapButtonSignatureKey)])
        return;
    CGFloat glyph = CGRectGetWidth(button.bounds) * kSPKFakeLocationMapButtonGlyphRatio;
    [button setImage:[SPKAssetUtils instagramIconNamed:active ? @"location_filled" : @"location"
                                             pointSize:glyph
                                         renderingMode:UIImageRenderingModeAlwaysTemplate]
            forState:UIControlStateNormal];
    button.tintColor = active ? [SPKUtils SPKColor_InstagramBlue] : SPKFakeLocationMapButtonGlyphColor();
    button.accessibilityValue = active ? SPKL(@"MENU_ON") : SPKL(@"MENU_OFF");
    objc_setAssociatedObject(button, kSPKFakeLocationMapButtonSignatureKey, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static UIView *SPKFakeLocationExistingMapHolder(UIView *stack) {
    for (UIView *subview in stack.subviews) {
        if (subview.tag == kSPKFakeLocationMapButtonTag && [subview isKindOfClass:[SPKChromeCanvas class]])
            return subview;
    }
    return nil;
}

// Stacks the button below the stack's last item, at the size of IG's buttons and
// with the gap IG leaves between them. Geometry comes from the stack's direct
// children, whose frames are final once the stack has laid out.
static void SPKFakeLocationLayoutMapButton(UIView *stack) {
    [SPKFakeLocationMapStacks() addObject:stack];
    UIView *holder = SPKFakeLocationExistingMapHolder(stack);
    if (![SPKUtils getBoolPref:kSPKFakeLocationMapButtonKey]) {
        holder.hidden = YES;
        return;
    }

    NSMutableArray<UIView *> *items = [NSMutableArray array];
    for (UIView *subview in stack.subviews) {
        if (subview.tag == kSPKFakeLocationMapButtonTag || subview.hidden || subview.alpha < 0.01)
            continue;
        if (CGRectGetWidth(subview.frame) < 1.0 || CGRectGetHeight(subview.frame) < 1.0)
            continue;
        [items addObject:subview];
    }
    if (items.count == 0) {
        holder.hidden = YES;
        return;
    }

    // Below IG's last item: the stack spans the height of the map, so the space
    // under its buttons is free, while the space above them is the status bar.
    UIView *bottomItem = items.firstObject;
    for (UIView *item in items) {
        if (CGRectGetMaxY(item.frame) > CGRectGetMaxY(bottomItem.frame))
            bottomItem = item;
    }
    CGFloat spacing = kSPKFakeLocationMapButtonFallbackSpacing;
    CGFloat nearestAbove = -CGFLOAT_MAX;
    for (UIView *item in items) {
        CGFloat maxY = CGRectGetMaxY(item.frame);
        if (item != bottomItem && maxY <= CGRectGetMinY(bottomItem.frame) && maxY > nearestAbove)
            nearestAbove = maxY;
    }
    if (nearestAbove != -CGFLOAT_MAX)
        spacing = MAX(4.0, CGRectGetMinY(bottomItem.frame) - nearestAbove);

    // IG's items are its own buttons, so the button takes their size.
    CGFloat diameter = MIN(CGRectGetWidth(bottomItem.frame), CGRectGetHeight(bottomItem.frame));
    if (diameter < 1.0)
        diameter = kSPKFakeLocationMapButtonFallbackSize;

    if (!holder) {
        holder = SPKFakeLocationMakeMapHolder(diameter);
        [stack addSubview:holder];
    }
    SPKFakeLocationConfigureGlyph(SPKFakeLocationHolderButton(holder));

    // The canvas's own content view starts out empty and is resized when it
    // attaches, so the button is sized explicitly rather than by autoresizing.
    UIButton *button = SPKFakeLocationHolderButton(holder);
    CGRect buttonFrame = CGRectMake(0.0, 0.0, diameter, diameter);
    if (!CGRectEqualToRect(button.frame, buttonFrame)) {
        button.frame = buttonFrame;
        button.layer.cornerRadius = diameter / 2.0;
        button.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:buttonFrame].CGPath;
    }

    CGRect expected = CGRectMake(CGRectGetMidX(bottomItem.frame) - diameter / 2.0,
                                 CGRectGetMaxY(bottomItem.frame) + spacing,
                                 diameter, diameter);
    // Frame guard: an unchanged frame means nothing to do. Re-assigning it on every
    // pass is what makes injected menu buttons blink out during the iOS 26 morph.
    // The live frame is compared, so anything else moving the button is corrected.
    if (!holder.hidden && CGRectEqualToRect(holder.frame, expected))
        return;
    holder.hidden = NO;
    holder.frame = expected;
}

%group SPKFakeLocationMapButtonHooks

%hook IGFriendsMapSecondaryButtonsStackView
- (void)layoutSubviews {
    %orig;
    SPKFakeLocationLayoutMapButton(self);
}

// The button can fall outside the stack's bounds when IG sizes the stack to its
// own buttons; the stack then has to claim those touches or they reach the map.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (%orig)
        return YES;
    UIView *holder = SPKFakeLocationExistingMapHolder(self);
    return holder && !holder.hidden && holder.alpha > 0.01 && CGRectContainsPoint(holder.frame, point);
}
%end

%end

extern "C" void SPKInstallFriendsMapFakeLocationButtonHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class stackClass = SPKResolveIGClass(@"IGFriendsMapSecondaryButtonsStackController.IGFriendsMapSecondaryButtonsStackView", nil);
        if (!stackClass) {
            SPKLog(@"FakeLocation", @"[Sparkle] Friends Map button stack not found; map button unavailable");
            return;
        }
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKFakeLocationDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
                                                          for (UIView *stack in SPKFakeLocationMapStacks().allObjects) {
                                                              SPKFakeLocationConfigureGlyph(SPKFakeLocationHolderButton(SPKFakeLocationExistingMapHolder(stack)));
                                                              [stack setNeedsLayout];
                                                          }
                                                      }];
        %init(SPKFakeLocationMapButtonHooks, IGFriendsMapSecondaryButtonsStackView = stackClass);
    });
}
