#import "SPKStrings.h"
#import "SPKTabConfiguration.h"

#import "../../Utils.h"

NSString *const SPKTabLayoutDefault = @"default";
NSString *const SPKTabLayoutCustom = @"custom";
NSString *const SPKTabLayoutClassic = @"classic";

NSString *const SPKTabIdentifierFeed = @"feed";
NSString *const SPKTabIdentifierClips = @"clips";
NSString *const SPKTabIdentifierDirect = @"direct";
NSString *const SPKTabIdentifierSearch = @"search";
NSString *const SPKTabIdentifierProfile = @"profile";
NSString *const SPKTabIdentifierCreate = @"create";
NSString *const SPKTabIdentifierSaved = @"saved";

NSString *const SPKTabSavedCarrierNone = @"none";

NSString *const SPKPrefTabLayout = @"interface_nav_order";
NSString *const SPKPrefCustomTabOrder = @"interface_custom_tab_order";
NSString *const SPKPrefSavedTabCarrier = @"interface_saved_tab_carrier";
NSString *const SPKPrefHideTabBarWhenSingle = @"interface_hide_tab_bar_in_messages_only";
NSString *const SPKPrefInboxHeaderShortcut = @"interface_show_header_button_in_messages_only";

NSArray<NSString *> *SPKCanonicalTabIdentifiers(void) {
    static NSArray<NSString *> *identifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifiers = @[ SPKTabIdentifierFeed, SPKTabIdentifierClips, SPKTabIdentifierDirect,
                         SPKTabIdentifierSearch, SPKTabIdentifierProfile ];
    });
    return identifiers;
}

NSArray<NSString *> *SPKTabEditableIdentifiers(void) {
    static NSArray<NSString *> *identifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifiers = [SPKCanonicalTabIdentifiers() arrayByAddingObject:SPKTabIdentifierCreate];
    });
    return identifiers;
}

NSArray<NSString *> *SPKTabOrderableIdentifiers(void) {
    static NSArray<NSString *> *identifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifiers = [SPKCanonicalTabIdentifiers() arrayByAddingObject:SPKTabIdentifierSaved];
    });
    return identifiers;
}

// Custom only: Default and Classic are Instagram's own topologies, which it
// rearranges between releases, so a slot borrowed there has to be re-proved every
// version. Custom is built from Sparkle's own order.
NSArray<NSString *> *SPKTabSavedCarrierPreferenceForLayout(NSString *layout) {
    if (![SPKNormalizedTabLayout(layout) isEqualToString:SPKTabLayoutCustom])
        return @[];

    static NSArray<NSString *> *identifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifiers = @[ SPKTabIdentifierClips, SPKTabIdentifierSearch, SPKTabIdentifierProfile,
                         SPKTabIdentifierDirect, SPKTabIdentifierFeed ];
    });
    return identifiers;
}

NSArray<NSString *> *SPKTabSavedCarrierPreference(void) {
    return SPKTabSavedCarrierPreferenceForLayout(SPKTabLayoutCustom);
}

BOOL SPKTabOccupiesBarSlot(NSString *identifier, NSString *layout) {
    BOOL classic = [SPKNormalizedTabLayout(layout) isEqualToString:SPKTabLayoutClassic];
    if ([identifier isEqualToString:SPKTabIdentifierCreate])
        return classic;
    if ([identifier isEqualToString:SPKTabIdentifierDirect])
        return !classic;
    return [SPKCanonicalTabIdentifiers() containsObject:identifier] ||
           [identifier isEqualToString:SPKTabIdentifierSaved];
}

NSArray<NSString *> *SPKNormalizeTabOrder(id value) {
    NSArray *input = [value isKindOfClass:[NSArray class]] ? value : @[];
    NSSet *known = [NSSet setWithArray:SPKTabOrderableIdentifiers()];
    NSMutableOrderedSet<NSString *> *normalized = [NSMutableOrderedSet orderedSet];
    for (id candidate in input) {
        if ([candidate isKindOfClass:[NSString class]] && [known containsObject:candidate])
            [normalized addObject:candidate];
    }
    for (NSString *identifier in SPKTabOrderableIdentifiers())
        [normalized addObject:identifier];
    return normalized.array;
}

NSString *SPKNormalizedTabLayout(id value) {
    if ([value isEqual:SPKTabLayoutCustom] || [value isEqual:SPKTabLayoutClassic])
        return value;
    return SPKTabLayoutDefault;
}

// The carrier is whichever bar slot Saved is currently borrowing, or "none" when
// Saved is off. Every identifier that owns a slot in some layout is valid here;
// whether it owns one in the *current* layout is a separate question that
// SPKTabOccupiesBarSlot answers.
NSString *SPKNormalizedSavedCarrier(id value) {
    if ([value isKindOfClass:[NSString class]] && [SPKTabSavedCarrierPreference() containsObject:value])
        return value;
    return SPKTabSavedCarrierNone;
}

// Resolved once and reused until a preference changes. This runs from the tab
// bar's -layoutSubviews, where three NSUserDefaults reads per button per pass is
// enough to hold up the main thread on its own.
static NSString *spk_cachedSavedCarrier = nil;

static void SPKInvalidateSavedCarrierCache(void) {
    @synchronized (SPKTabSavedCarrierNone) {
        spk_cachedSavedCarrier = nil;
    }
}

static NSString *SPKResolveSavedCarrier(void) {
    NSString *carrier = SPKNormalizedSavedCarrier(SPKPreferenceObjectForKey(SPKPrefSavedTabCarrier));
    if ([carrier isEqualToString:SPKTabSavedCarrierNone])
        return carrier;
    NSString *layout = SPKNormalizedTabLayout([SPKUtils getStringPref:SPKPrefTabLayout]);
    if (![layout isEqualToString:SPKTabLayoutCustom] || !SPKTabOccupiesBarSlot(carrier, layout))
        return SPKTabSavedCarrierNone;
    // The carrier's hidden slot is what Saved draws in, so a carrier whose tab is
    // visible again would paint Saved over a tab the user can see.
    NSString *hideKey = SPKTabHidePreferenceKey(carrier);
    if (hideKey.length == 0 || ![SPKUtils getBoolPref:hideKey])
        return SPKTabSavedCarrierNone;
    return carrier;
}

NSString *SPKEffectiveSavedCarrier(void) {
    static dispatch_once_t observerOnce;
    dispatch_once(&observerOnce, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                        object:nil
                                                         queue:nil
                                                    usingBlock:^(NSNotification *note) {
                                                        SPKInvalidateSavedCarrierCache();
                                                    }];
    });

    @synchronized (SPKTabSavedCarrierNone) {
        if (spk_cachedSavedCarrier)
            return spk_cachedSavedCarrier;
    }
    NSString *resolved = SPKResolveSavedCarrier();
    @synchronized (SPKTabSavedCarrierNone) {
        spk_cachedSavedCarrier = resolved;
    }
    return resolved;
}

NSString *SPKSingleVisibleTabIdentifier(NSString *layout, NSSet<NSString *> *hidden, NSString *savedCarrier) {
    NSString *carrier = SPKNormalizedSavedCarrier(savedCarrier);
    BOOL savedEnabled = ![carrier isEqualToString:SPKTabSavedCarrierNone] &&
                        [SPKNormalizedTabLayout(layout) isEqualToString:SPKTabLayoutCustom] &&
                        SPKTabOccupiesBarSlot(carrier, layout);

    // Create draws a button without being anywhere you can navigate, so a bar
    // that still shows it is not down to a single tab even if it is the only
    // other item.
    if (SPKTabOccupiesBarSlot(SPKTabIdentifierCreate, layout) &&
        ![hidden containsObject:SPKTabIdentifierCreate])
        return nil;

    NSString *single = savedEnabled ? SPKTabIdentifierSaved : nil;
    for (NSString *identifier in SPKCanonicalTabIdentifiers()) {
        if (![hidden containsObject:identifier] && SPKTabOccupiesBarSlot(identifier, layout)) {
            if (single)
                return nil;
            single = identifier;
        }
    }
    return single;
}

NSString *SPKSingleVisibleTabIdentifierFromPreferences(void) {
    NSMutableSet<NSString *> *hidden = [NSMutableSet set];
    for (NSString *identifier in SPKTabEditableIdentifiers()) {
        if ([SPKUtils getBoolPref:SPKTabHidePreferenceKey(identifier)])
            [hidden addObject:identifier];
    }
    return SPKSingleVisibleTabIdentifier(SPKNormalizedTabLayout([SPKUtils getStringPref:SPKPrefTabLayout]),
                                         hidden,
                                         SPKNormalizedSavedCarrier(SPKPreferenceObjectForKey(SPKPrefSavedTabCarrier)));
}

BOOL SPKSingleTabAllowsHidingTabBar(NSString *identifier) {
    // Messages always qualifies: Sparkle installs the long-press on the new
    // message button whenever it is the last tab standing.
    if ([identifier isEqualToString:SPKTabIdentifierDirect] ||
        [identifier isEqualToString:SPKTabIdentifierProfile])
        return YES;
    // Feed only qualifies while its header shortcut button is switched on, since
    // that button is then the only remaining way into Sparkle Settings.
    if ([identifier isEqualToString:SPKTabIdentifierFeed])
        return [SPKUtils getBoolPref:@"feed_header_button"];
    // Everywhere else the tab bar long-press is the only way in, so taking the
    // bar away would lock the user out of Sparkle entirely.
    return NO;
}

NSString *SPKTabTitle(NSString *identifier) {
    if ([identifier isEqualToString:SPKTabIdentifierFeed]) return SPKL(@"FEED_TITLE");
    if ([identifier isEqualToString:SPKTabIdentifierClips]) return SPKL(@"REELS_TITLE");
    if ([identifier isEqualToString:SPKTabIdentifierDirect]) return SPKL(@"MESSAGES_CONFIRMATION_MESSAGES_TITLE");
    if ([identifier isEqualToString:SPKTabIdentifierSearch]) return SPKL(@"TAB_EXPLORE");
    if ([identifier isEqualToString:SPKTabIdentifierProfile]) return SPKL(@"PROFILE_TITLE");
    if ([identifier isEqualToString:SPKTabIdentifierCreate]) return SPKL(@"TAB_CREATE");
    if ([identifier isEqualToString:SPKTabIdentifierSaved]) return SPKL(@"TAB_SAVED");
    return identifier ?: SPKL(@"NAVIGATION_TAB_CONFIGURATION_TAB_TEXT");
}

NSString *SPKTabIconName(NSString *identifier) {
    if ([identifier isEqualToString:SPKTabIdentifierFeed]) return @"home";
    if ([identifier isEqualToString:SPKTabIdentifierClips]) return @"reels";
    if ([identifier isEqualToString:SPKTabIdentifierDirect]) return @"messages";
    if ([identifier isEqualToString:SPKTabIdentifierSearch]) return @"search";
    if ([identifier isEqualToString:SPKTabIdentifierProfile]) return @"user_circle";
    if ([identifier isEqualToString:SPKTabIdentifierCreate]) return @"plus";
    if ([identifier isEqualToString:SPKTabIdentifierSaved]) return @"save";
    return @"circle";
}

NSString *SPKTabHidePreferenceKey(NSString *identifier) {
    if ([identifier isEqualToString:SPKTabIdentifierFeed]) return @"interface_hide_feed_tab";
    if ([identifier isEqualToString:SPKTabIdentifierClips]) return @"interface_hide_reels_tab";
    if ([identifier isEqualToString:SPKTabIdentifierDirect]) return @"interface_hide_msgs_tab";
    if ([identifier isEqualToString:SPKTabIdentifierSearch]) return @"interface_hide_explore_tab";
    if ([identifier isEqualToString:SPKTabIdentifierProfile]) return @"interface_hide_profile_tab";
    if ([identifier isEqualToString:SPKTabIdentifierCreate]) return @"interface_hide_create_tab";
    return @"";
}

NSString *SPKTabLaunchPreferenceValue(NSString *identifier) {
    if ([identifier isEqualToString:SPKTabIdentifierClips]) return @"reels";
    if ([identifier isEqualToString:SPKTabIdentifierDirect]) return @"inbox";
    if ([identifier isEqualToString:SPKTabIdentifierSearch]) return @"explore";
    return identifier ?: @"default";
}

NSString *SPKTabIdentifierForLaunchPreference(NSString *value) {
    if ([value isEqualToString:@"feed"]) return SPKTabIdentifierFeed;
    if ([value isEqualToString:@"reels"]) return SPKTabIdentifierClips;
    if ([value isEqualToString:@"inbox"]) return SPKTabIdentifierDirect;
    if ([value isEqualToString:@"explore"]) return SPKTabIdentifierSearch;
    if ([value isEqualToString:@"profile"]) return SPKTabIdentifierProfile;
    return nil;
}

NSString *SPKEffectiveLaunchTabIdentifierFromPreferences(void) {
    NSString *layout = SPKNormalizedTabLayout([SPKUtils getStringPref:SPKPrefTabLayout]);
    BOOL custom = [layout isEqualToString:SPKTabLayoutCustom];
    NSString *carrier = SPKEffectiveSavedCarrier();
    BOOL savedEnabled = ![carrier isEqualToString:SPKTabSavedCarrierNone];

    NSArray<NSString *> *order = custom ? SPKNormalizeTabOrder(SPKPreferenceObjectForKey(SPKPrefCustomTabOrder))
                                        : SPKCanonicalTabIdentifiers();
    NSMutableArray<NSString *> *visible = [NSMutableArray array];
    for (NSString *identifier in order) {
        if ([identifier isEqualToString:SPKTabIdentifierSaved]) {
            if (savedEnabled)
                [visible addObject:identifier];
            continue;
        }
        if (!SPKTabOccupiesBarSlot(identifier, layout))
            continue;
        if ([SPKUtils getBoolPref:SPKTabHidePreferenceKey(identifier)])
            continue;
        [visible addObject:identifier];
    }
    if (visible.count == 0)
        return nil;

    NSString *chosen = SPKTabIdentifierForLaunchPreference([SPKUtils getStringPref:@"interface_launch_tab"]);
    if (chosen)
        return [visible containsObject:chosen] ? chosen : visible.firstObject;
    if (!custom && [visible containsObject:SPKTabIdentifierFeed])
        return SPKTabIdentifierFeed;
    return visible.firstObject;
}

void SPKMigrateTabConfigurationIfNeeded(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id storedLayout = [defaults objectForKey:SPKPrefTabLayout];
    NSArray *legacyOrder = nil;
    if ([storedLayout isEqual:@"standard"]) {
        legacyOrder = SPKCanonicalTabIdentifiers();
    } else if ([storedLayout isEqual:@"alternate"]) {
        legacyOrder = @[ SPKTabIdentifierClips, SPKTabIdentifierFeed, SPKTabIdentifierDirect,
                         SPKTabIdentifierSearch, SPKTabIdentifierProfile ];
    }
    if (legacyOrder) {
        [defaults setObject:legacyOrder forKey:SPKPrefCustomTabOrder];
        [defaults setObject:SPKTabLayoutCustom forKey:SPKPrefTabLayout];
    } else {
        NSString *layout = SPKNormalizedTabLayout(storedLayout);
        if (storedLayout && ![storedLayout isEqual:layout])
            [defaults setObject:layout forKey:SPKPrefTabLayout];
    }

    NSArray *normalized = SPKNormalizeTabOrder([defaults objectForKey:SPKPrefCustomTabOrder]);
    id storedOrder = [defaults objectForKey:SPKPrefCustomTabOrder];
    if (![storedOrder isKindOfClass:[NSArray class]] || ![(NSArray *)storedOrder isEqualToArray:normalized])
        [defaults setObject:normalized forKey:SPKPrefCustomTabOrder];
}
