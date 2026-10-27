#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../InstagramHeaders.h"
#import "../../Utils.h"

// Hide saved recent searches and disable logging of new searches.
//
// The relevant classes were migrated Obj-C -> Swift around IG 434, so the
// plain class names (IGRecentSearchStore, IGSearchEntityRouter) no longer
// exist at runtime on newer builds — they're registered under their mangled
// Swift names instead, which made the old static hook on IGRecentSearchStore
// silently bind to nothing. We resolve each class by trying the legacy Obj-C name
// and the Swift-mangled name, and hook selectors that are stable across
// versions (addItem:, _processRecentlySelectedRecipients:, and the
// shouldAddToRecents init) via MSHookMessageEx.

static BOOL gSPKHideRecentSearchesActive = NO;

static BOOL SPKHideRecentSearchesPreferenceEnabled(void) {
    return [SPKUtils getBoolPref:@"general_hide_recent_searches"];
}

#pragma mark - IGSearchEntityRouter (gate recents at the source)

static id (*orig_searchRouterInit3)(id, SEL, id, id, BOOL) = NULL;
static id replaced_searchRouterInit3(id self, SEL _cmd, id session, id module, BOOL shouldAddToRecents) {
    if (gSPKHideRecentSearchesActive) {
        shouldAddToRecents = NO;
    }
    return orig_searchRouterInit3(self, _cmd, session, module, shouldAddToRecents);
}

static id (*orig_searchRouterInit4)(id, SEL, id, id, BOOL, long long) = NULL;
static id replaced_searchRouterInit4(id self, SEL _cmd, id session, id module, BOOL shouldAddToRecents, long long mode) {
    if (gSPKHideRecentSearchesActive) {
        shouldAddToRecents = NO;
    }
    return orig_searchRouterInit4(self, _cmd, session, module, shouldAddToRecents, mode);
}

#pragma mark - IGRecentSearchStore (most in-app search bars)

static BOOL (*orig_recentStoreAddItem)(id, SEL, id) = NULL;
static BOOL replaced_recentStoreAddItem(id self, SEL _cmd, id item) {
    if (gSPKHideRecentSearchesActive) {
        return NO;
    }
    return orig_recentStoreAddItem(self, _cmd, item);
}

// Hide already-saved recents (loaded from disk) without deleting them, so the
// list also disappears for users who enabled the toggle after searches were
// stored. These are the readonly getters the search UI reads; returning empty
// remains active for the process lifetime, matching the restart-required row.
static id (*orig_recentStoreRecentItems)(id, SEL) = NULL;
static id replaced_recentStoreRecentItems(id self, SEL _cmd) {
    if (gSPKHideRecentSearchesActive) {
        return @[];
    }
    return orig_recentStoreRecentItems(self, _cmd);
}

static id (*orig_recentStoreAllItems)(id, SEL) = NULL;
static id replaced_recentStoreAllItems(id self, SEL _cmd) {
    if (gSPKHideRecentSearchesActive) {
        return @[];
    }
    return orig_recentStoreAllItems(self, _cmd);
}

static id (*orig_recentStoreSetOfAllItems)(id, SEL) = NULL;
static id replaced_recentStoreSetOfAllItems(id self, SEL _cmd) {
    if (gSPKHideRecentSearchesActive) {
        return [NSMutableOrderedSet orderedSet];
    }
    return orig_recentStoreSetOfAllItems(self, _cmd);
}

#pragma mark - IGBlendedSearchRecentItemsOrderStore (main search null state)

// Newer Instagram versions build the visible main-search list from this
// blended store's cached ordering rather than reading each underlying
// IGRecentSearchStore directly. Hiding only the individual stores therefore
// leaves an already-populated Recent list on screen.
static id (*orig_blendedStoreRecentItems)(id, SEL) = NULL;
static id replaced_blendedStoreRecentItems(id self, SEL _cmd) {
    if (gSPKHideRecentSearchesActive) {
        return @[];
    }
    return orig_blendedStoreRecentItems(self, _cmd);
}

static id (*orig_blendedStoreRecentAudioItems)(id, SEL) = NULL;
static id replaced_blendedStoreRecentAudioItems(id self, SEL _cmd) {
    if (gSPKHideRecentSearchesActive) {
        return @[];
    }
    return orig_blendedStoreRecentAudioItems(self, _cmd);
}

#pragma mark - IGDirectRecipientRecentSearchStorage (DM recipient search bar)

static void (*orig_directProcessRecents)(id, SEL, id) = NULL;
static void replaced_directProcessRecents(id self, SEL _cmd, id recipients) {
    if (gSPKHideRecentSearchesActive) {
        return;
    }
    orig_directProcessRecents(self, _cmd, recipients);
}

// Report the recipient store as empty so the recent-recipients section is also
// hidden for previously-saved entries.
static BOOL (*orig_directIsEmpty)(id, SEL) = NULL;
static BOOL replaced_directIsEmpty(id self, SEL _cmd) {
    if (gSPKHideRecentSearchesActive) {
        return YES;
    }
    return orig_directIsEmpty(self, _cmd);
}

#pragma mark - Installation

static Class SPKResolveClass(NSArray<NSString *> *candidateNames) {
    for (NSString *name in candidateNames) {
        Class cls = NSClassFromString(name);
        if (cls)
            return cls;
    }
    return Nil;
}

static void SPKHookIfPresent(Class cls, NSString *selectorName, IMP replacement, void *origStore) {
    if (!cls)
        return;
    SEL selector = NSSelectorFromString(selectorName);
    if (!class_getInstanceMethod(cls, selector))
        return;
    MSHookMessageEx(cls, selector, replacement, (IMP *)origStore);
}

void SPKInstallHideRecentSearchesHooksIfEnabled(void) {
    if (!SPKHideRecentSearchesPreferenceEnabled())
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gSPKHideRecentSearchesActive = YES;
        // IGSearchEntityRouter — force shouldAddToRecents off in every init variant.
        Class routerClass = SPKResolveClass(@[
            @"IGSearchEntityRouter",
            @"IGSearchEntityRouter.IGSearchEntityRouter",
            @"_TtC20IGSearchEntityRouter20IGSearchEntityRouter",
        ]);
        SPKHookIfPresent(routerClass,
                         @"initWithUserSession:analyticsModule:shouldAddToRecents:",
                         (IMP)replaced_searchRouterInit3, &orig_searchRouterInit3);
        SPKHookIfPresent(routerClass,
                         @"initWithUserSession:analyticsModule:shouldAddToRecents:mode:",
                         (IMP)replaced_searchRouterInit4, &orig_searchRouterInit4);

        // IGRecentSearchStore — block new entries from being recorded.
        Class recentStoreClass = SPKResolveClass(@[
            @"IGRecentSearchStore",
            @"IGRecentSearchStore.IGRecentSearchStore",
            @"_TtC19IGRecentSearchStore19IGRecentSearchStore",
        ]);
        SPKHookIfPresent(recentStoreClass, @"addItem:",
                         (IMP)replaced_recentStoreAddItem, &orig_recentStoreAddItem);
        SPKHookIfPresent(recentStoreClass, @"recentItems",
                         (IMP)replaced_recentStoreRecentItems, &orig_recentStoreRecentItems);
        SPKHookIfPresent(recentStoreClass, @"allItems",
                         (IMP)replaced_recentStoreAllItems, &orig_recentStoreAllItems);
        SPKHookIfPresent(recentStoreClass, @"setOfAllItems",
                         (IMP)replaced_recentStoreSetOfAllItems, &orig_recentStoreSetOfAllItems);

        // IGBlendedSearchRecentItemsOrderStore — hide the cached list used by
        // the main search null state on current Instagram versions.
        Class blendedStoreClass = SPKResolveClass(@[
            @"_TtC20IGRecentSearchStores36IGBlendedSearchRecentItemsOrderStore",
            @"IGRecentSearchStores.IGBlendedSearchRecentItemsOrderStore",
        ]);
        SPKHookIfPresent(blendedStoreClass, @"recentItems",
                         (IMP)replaced_blendedStoreRecentItems, &orig_blendedStoreRecentItems);
        SPKHookIfPresent(blendedStoreClass, @"recentAudioItems",
                         (IMP)replaced_blendedStoreRecentAudioItems, &orig_blendedStoreRecentAudioItems);

        // IGDirectRecipientRecentSearchStorage — block recent DM recipients.
        // (Still a plain Obj-C class on both 410 and 435.)
        Class directStorageClass = SPKResolveClass(@[
            @"IGDirectRecipientRecentSearchStorage",
        ]);
        SPKHookIfPresent(directStorageClass, @"_processRecentlySelectedRecipients:",
                         (IMP)replaced_directProcessRecents, &orig_directProcessRecents);
        SPKHookIfPresent(directStorageClass, @"isEmpty",
                         (IMP)replaced_directIsEmpty, &orig_directIsEmpty);

        SPKLog(@"General", @"[Sparkle HideRecentSearches] hooks installed router=%@ recentStore=%@ blendedStore=%@ directStore=%@",
               routerClass ? NSStringFromClass(routerClass) : @"missing",
               recentStoreClass ? NSStringFromClass(recentStoreClass) : @"missing",
               blendedStoreClass ? NSStringFromClass(blendedStoreClass) : @"missing",
               directStorageClass ? NSStringFromClass(directStorageClass) : @"missing");
    });
}
