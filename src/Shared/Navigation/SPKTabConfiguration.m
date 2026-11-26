#import "SPKStrings.h"
#import "SPKTabConfiguration.h"
#import "SPKDestinations.h"
#import "../../Features/Interface/SPKNativeTabBar.h"

#import "../../Utils.h"

#import <objc/message.h>
#import <sys/sysctl.h>

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

// Instagram's own foldable check comes first: it knows the device even where
// the model identifier is new to Sparkle. The identifier is the fallback for
// builds without it.
static BOOL SPKDeviceIsFoldable(void) {
    static BOOL foldable = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class presentation = NSClassFromString(@"_TtC22IGAdaptivePresentation22IGAdaptivePresentation");
        SEL isFoldable = NSSelectorFromString(@"isFoldable");
        if (presentation && [presentation respondsToSelector:isFoldable] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(presentation, isFoldable)) {
            foldable = YES;
            return;
        }
        char machine[64] = {0};
        size_t size = sizeof(machine);
        if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0)
            foldable = strcmp(machine, "iPhone19,4") == 0;
    });
    return foldable;
}

BOOL SPKTabClassicLayoutAvailable(void) {
    return !SPKDeviceIsFoldable() && !SPKSystemTabBarRunsAsColumn();
}

NSString *SPKEffectiveTabLayout(void) {
    NSString *layout = SPKNormalizedTabLayout([SPKUtils getStringPref:SPKPrefTabLayout]);
    if ([layout isEqualToString:SPKTabLayoutClassic] && !SPKTabClassicLayoutAvailable())
        return SPKTabLayoutDefault;
    return layout;
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
    NSString *layout = SPKEffectiveTabLayout();
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
    return SPKSingleVisibleTabIdentifier(SPKEffectiveTabLayout(),
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
    NSString *layout = SPKEffectiveTabLayout();
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

NSString *const SPKTabHoldInstagramDefault = @"default";
NSString *const SPKTabHoldNone = @"none";

NSArray<NSString *> *SPKTabHoldableIdentifiers(void) {
    static NSArray<NSString *> *identifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifiers = @[ SPKTabIdentifierFeed, SPKTabIdentifierClips, SPKTabIdentifierDirect,
                         SPKTabIdentifierCreate, SPKTabIdentifierSearch, SPKTabIdentifierProfile,
                         SPKTabIdentifierSaved ];
    });
    return identifiers;
}

NSString *SPKTabHoldPreferenceKey(NSString *identifier) {
    if (![SPKTabHoldableIdentifiers() containsObject:identifier])
        return @"";
    return [@"interface_tab_hold_" stringByAppendingString:identifier];
}

NSString *SPKTabHoldValue(NSString *identifier) {
    NSString *key = SPKTabHoldPreferenceKey(identifier);
    if (key.length == 0)
        return SPKTabHoldInstagramDefault;
    NSString *value = [SPKUtils getStringPref:key];
    if ([value isEqualToString:SPKTabHoldNone])
        return SPKTabHoldNone;
    SPKDestination *destination = SPKDestinationForIdentifier(value);
    if (destination && (destination.placements & SPKDestinationPlacementHold))
        return destination.identifier;
    return SPKTabHoldInstagramDefault;
}

NSString *SPKSearchTabClipboardHold(void) {
    // Saved borrowing the Search slot takes its button, and its hold with it.
    if ([SPKEffectiveSavedCarrier() isEqualToString:SPKTabIdentifierSearch])
        return nil;
    NSString *hold = SPKTabHoldValue(SPKTabIdentifierSearch);
    if ([hold isEqualToString:SPKDestinationClipboardLink] || [hold isEqualToString:SPKDestinationClipboardLinkOrUsername])
        return hold;
    return nil;
}

BOOL SPKTabHasInstagramHold(NSString *identifier) {
    return [identifier isEqualToString:SPKTabIdentifierFeed] ||
           [identifier isEqualToString:SPKTabIdentifierSearch] ||
           [identifier isEqualToString:SPKTabIdentifierProfile];
}

// The Settings and Gallery shortcuts used to be two settings that each picked a
// tab at runtime: Settings took the first visible tab, Gallery a chosen one
// (moving along when Settings already had it, and swapping Messages for Create
// in Classic). They are now ordinary per-tab holds, so the tabs they resolved to
// under the stored configuration are written out once and nobody's holds move.
static NSString *const SPKTabHoldsMigratedKey = @"interface_tab_holds_migrated";

static NSString *SPKTabIdentifierForLegacyAccessibilityIdentifier(NSString *identifier) {
    if ([identifier isEqualToString:@"mainfeed-tab"]) return SPKTabIdentifierFeed;
    if ([identifier isEqualToString:@"reels-tab"]) return SPKTabIdentifierClips;
    if ([identifier isEqualToString:@"direct-inbox-tab"]) return SPKTabIdentifierDirect;
    if ([identifier isEqualToString:@"camera-tab"]) return SPKTabIdentifierCreate;
    if ([identifier isEqualToString:@"explore-tab"]) return SPKTabIdentifierSearch;
    if ([identifier isEqualToString:@"profile-tab"]) return SPKTabIdentifierProfile;
    return nil;
}

static void SPKMigrateTabHoldsIfNeeded(NSUserDefaults *defaults) {
    if ([defaults boolForKey:SPKTabHoldsMigratedKey])
        return;

    NSString *layout = SPKNormalizedTabLayout([defaults objectForKey:SPKPrefTabLayout]);
    NSString *carrier = SPKNormalizedSavedCarrier([defaults objectForKey:SPKPrefSavedTabCarrier]);
    if (![layout isEqualToString:SPKTabLayoutCustom] || ![defaults boolForKey:SPKTabHidePreferenceKey(carrier)])
        carrier = SPKTabSavedCarrierNone;

    // The slot a tab's button sits in, keyed by what that slot now shows.
    NSString * (^holdKeyForSlot)(NSString *) = ^NSString *(NSString *identifier) {
        return [identifier isEqualToString:carrier] ? SPKTabIdentifierSaved : identifier;
    };
    BOOL (^visible)(NSString *) = ^BOOL(NSString *identifier) {
        if (!SPKTabOccupiesBarSlot(identifier, layout))
            return NO;
        if ([identifier isEqualToString:carrier])
            return YES;
        return ![defaults boolForKey:SPKTabHidePreferenceKey(identifier)];
    };
    NSArray<NSString *> *priority = @[ SPKTabIdentifierFeed, SPKTabIdentifierClips, SPKTabIdentifierDirect,
                                       SPKTabIdentifierCreate, SPKTabIdentifierSearch, SPKTabIdentifierProfile ];

    NSMutableDictionary<NSString *, NSString *> *holds = [NSMutableDictionary dictionary];
    NSString *settingsHost = nil;
    // The old settings registered their defaults (Settings on, Gallery on
    // Messages), which no longer exist, so an untouched value reads as them.
    id settingsShortcut = [defaults objectForKey:@"tools_settings_shortcut"];
    if (![settingsShortcut respondsToSelector:@selector(boolValue)] || [settingsShortcut boolValue]) {
        for (NSString *identifier in priority) {
            if (visible(identifier)) {
                settingsHost = identifier;
                break;
            }
        }
        if (settingsHost)
            holds[holdKeyForSlot(settingsHost)] = SPKDestinationSettings;
    }

    NSString *galleryTab = SPKTabIdentifierForLegacyAccessibilityIdentifier([defaults stringForKey:@"gallery_quick_access_tab"] ?: @"direct-inbox-tab");
    if (galleryTab) {
        BOOL messagesOwnsSlot = SPKTabOccupiesBarSlot(SPKTabIdentifierDirect, layout);
        if (!messagesOwnsSlot && [galleryTab isEqualToString:SPKTabIdentifierDirect])
            galleryTab = SPKTabIdentifierCreate;
        else if (messagesOwnsSlot && [galleryTab isEqualToString:SPKTabIdentifierCreate])
            galleryTab = SPKTabIdentifierDirect;
        if (settingsHost && [galleryTab isEqualToString:settingsHost]) {
            galleryTab = nil;
            for (NSString *identifier in priority) {
                if (visible(identifier) && ![identifier isEqualToString:settingsHost]) {
                    galleryTab = identifier;
                    break;
                }
            }
        }
        if (galleryTab && visible(galleryTab)) {
            holds[holdKeyForSlot(galleryTab)] = SPKDestinationGallery;
            // Outside Custom, Messages and Create share one slot and the old
            // shortcut followed it, so both get the Gallery and switching
            // between Default and Classic keeps it on the slot.
            NSString *twin = [galleryTab isEqualToString:SPKTabIdentifierDirect]   ? SPKTabIdentifierCreate
                             : [galleryTab isEqualToString:SPKTabIdentifierCreate] ? SPKTabIdentifierDirect
                                                                                    : nil;
            if (twin && ![layout isEqualToString:SPKTabLayoutCustom] && !holds[twin])
                holds[twin] = SPKDestinationGallery;
        }
    }

    // Every tab is written, so a tab left on Instagram's hold stays there even
    // if a later default changes.
    for (NSString *identifier in SPKTabHoldableIdentifiers())
        [defaults setObject:holds[identifier] ?: SPKTabHoldInstagramDefault forKey:SPKTabHoldPreferenceKey(identifier)];
    [defaults removeObjectForKey:@"tools_settings_shortcut"];
    [defaults removeObjectForKey:@"gallery_quick_access_tab"];
    [defaults setBool:YES forKey:SPKTabHoldsMigratedKey];
    SPKLog(@"TabBar", @"[Sparkle] Migrated tab shortcuts to per-tab holds: %@", holds);
}

// Open Clipboard Link and Open Clipboard Username were two switches on the
// Explore & Search page that took over the Search tab's hold. They are now the
// Search tab's hold itself. A Search hold the previous migration already gave
// Settings or Gallery stays: that is where those shortcuts were.
static NSString *const SPKClipboardHoldMigratedKey = @"interface_clipboard_hold_migrated";

static id SPKStoredAccountPreference(NSUserDefaults *defaults, NSString *key) {
    return [defaults objectForKey:SPKEffectivePreferenceKey(key)] ?: [defaults objectForKey:key];
}

static void SPKRemovePreferenceInEveryAccount(NSUserDefaults *defaults, NSString *key) {
    NSString *suffix = [@"_" stringByAppendingString:key];
    for (NSString *stored in defaults.dictionaryRepresentation.allKeys) {
        if ([stored isEqualToString:key] || ([stored hasPrefix:@"u_"] && [stored hasSuffix:suffix]))
            [defaults removeObjectForKey:stored];
    }
}

static void SPKMigrateClipboardHoldIfNeeded(NSUserDefaults *defaults) {
    if ([defaults boolForKey:SPKClipboardHoldMigratedKey])
        return;
    NSString *searchKey = SPKTabHoldPreferenceKey(SPKTabIdentifierSearch);
    NSString *current = [defaults stringForKey:searchKey];
    if (current.length == 0 || [current isEqualToString:SPKTabHoldInstagramDefault]) {
        // The link switch was on out of the box, the username one off.
        id link = SPKStoredAccountPreference(defaults, @"interface_open_clipboard_link");
        id username = SPKStoredAccountPreference(defaults, @"interface_open_clipboard_username");
        BOOL linkOn = ![link respondsToSelector:@selector(boolValue)] || [link boolValue];
        BOOL usernameOn = [username respondsToSelector:@selector(boolValue)] && [username boolValue];
        NSString *hold = !linkOn ? SPKTabHoldInstagramDefault
                       : usernameOn ? SPKDestinationClipboardLinkOrUsername : SPKDestinationClipboardLink;
        [defaults setObject:hold forKey:searchKey];
        SPKLog(@"TabBar", @"[Sparkle] Migrated the clipboard shortcuts to the Search hold: %@", hold);
    }
    SPKRemovePreferenceInEveryAccount(defaults, @"interface_open_clipboard_link");
    SPKRemovePreferenceInEveryAccount(defaults, @"interface_open_clipboard_username");
    [defaults setBool:YES forKey:SPKClipboardHoldMigratedKey];
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

    SPKMigrateTabHoldsIfNeeded(defaults);
    SPKMigrateClipboardHoldIfNeeded(defaults);
}
