#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <UIKit/UIKit.h>

#import "../../Shared/ActionButton/ActionButtonLookupUtils.h"
#import "../../Shared/Instants/SPKInstantsManualSeenUsers.h"
#import "../../Utils.h"
#import "InstantsManualSeen.h"
#import "InstantsResolver.h"

// MARK: - Constants

/// The session-defaults key Instagram persists `IGQuickSnapStore.seenSnapPks` into.
/// Confirmed present in the 447 binary alongside `seenSnapPks`, `serverSyncedSeenSnapPks`
/// and `confirmableSeenSnapPks`, and confirmed on device to be the value
/// `refreshSeenStateFromSharedStorage` reloads from.
static NSString *const kSPKInstantsSeenStateDefaultsKey = @"kIGQuickSnapSeenStateKey";

/// Upper bound on the protected set. Instants expire server-side, so an unbounded set
/// would only accumulate PKs that can never come back.
static const NSUInteger kSPKInstantsManualSeenHeldLimit = 500;

/// Where the released PKs persist, per account.
///
/// A release has to outlive the process. Instagram is never told about it, because the seen
/// sync is suppressed, so nothing outside this device remembers it: after a relaunch the
/// service announced a released snap again, it was held once more, and its seen entry was
/// stripped straight back out, which brought it back into the tray.
static NSString *const kSPKInstantsManualSeenReleasedKey = @"instants_manual_seen_released";

/// Bound on the released list, evicting oldest first. Instants expire on Instagram's schedule,
/// so old entries can never resurface and only cost space.
static const NSUInteger kSPKInstantsManualSeenReleasedLimit = 500;

// MARK: - State

/// Media PKs held out of the persisted seen state, newest last.
static NSMutableOrderedSet<NSString *> *sProtectedPKs = nil;
/// PKs the user explicitly marked seen, oldest first, restored from preferences at startup.
/// Never re-protected, and re-asserted into the stored seen state on every pass, so a
/// released Instant stays released across launches and across refetches.
static NSMutableOrderedSet<NSString *> *sReleasedPKs = nil;
/// `refreshSeenStateFromSharedStorage` synchronously re-enters the service listener
/// callback, which is where `SPKInstantsManualSeenHoldUnseen` is called from. Without this
/// guard the feature calls itself forever.
static BOOL sRefreshing = NO;
/// Author pk per bare media id, filled from the service announcements. Only consulted when a
/// seen request carries ids without the `_<userPK>` suffix, so the author can still be told.
static NSMutableDictionary<NSString *, NSString *> *sAuthorPKByMediaId = nil;
/// Author pk per lowercased username, from the same announcements. Filled even while the
/// feature is off, since the action menu is how a first user gets added.
static NSMutableDictionary<NSString *, NSString *> *sAuthorPKByUsername = nil;
/// YES while the consumption viewer is on screen. Reloading the seen state under an open
/// viewer puts the snap that was just consumed back into the live list, so the viewer never
/// reaches its end and the same Instants cycle forever. While this is YES the feature only keeps
/// the stored value clean and waits for the session to end.
static BOOL sViewerOpen = NO;

BOOL SPKInstantsManualSeenIsEnabled(void) {
    // Off with Included Users listed still holds those users' Instants, the way the stories
    // list works, so the switch alone does not decide whether anything runs.
    return SPKInstantsManualSeenAllUsersMode() || SPKInstantsManualSeenUserCount() > 0;
}

/// A media PK is `<mediaId>_<userPK>`, so the author is whatever follows the last underscore.
/// Nil for a bare media id.
static NSString *SPKInstantsManualSeenAuthorPKFromMediaPK(NSString *pk) {
    if (![pk isKindOfClass:NSString.class])
        return nil;
    NSRange separator = [pk rangeOfString:@"_" options:NSBackwardsSearch];
    if (separator.location == NSNotFound || NSMaxRange(separator) >= pk.length)
        return nil;
    return [pk substringFromIndex:NSMaxRange(separator)];
}

static NSString *SPKInstantsManualSeenMediaIdFromMediaPK(NSString *pk) {
    NSRange separator = [pk rangeOfString:@"_" options:NSBackwardsSearch];
    return separator.location == NSNotFound ? pk : [pk substringToIndex:separator.location];
}

/// Drops held PKs whose author the list no longer covers, so taking a user off the list (or
/// flipping the switch) lets their Instants be marked seen on the next pass.
static void SPKInstantsManualSeenPruneProtected(SPKInstantsManualSeenAuthorTest applies) {
    if (sProtectedPKs.count == 0 || SPKInstantsManualSeenCoversEveryone())
        return;
    NSIndexSet *dropped = [sProtectedPKs indexesOfObjectsPassingTest:^BOOL(NSString *pk, NSUInteger idx, BOOL *stop) {
        NSString *author = SPKInstantsManualSeenAuthorPKFromMediaPK(pk);
        return author.length > 0 && !applies(author);
    }];
    if (dropped.count == 0)
        return;
    [sProtectedPKs removeObjectsAtIndexes:dropped];
    SPKLog(@"Instants", @"manual seen: stopped holding %lu instant(s) from unlisted authors",
           (unsigned long)dropped.count);
}

static void SPKInstantsManualSeenPersistReleased(void) {
    while (sReleasedPKs.count > kSPKInstantsManualSeenReleasedLimit)
        [sReleasedPKs removeObjectAtIndex:0];
    SPKPreferenceSetObject(sReleasedPKs.array, kSPKInstantsManualSeenReleasedKey);
}

static void SPKInstantsManualSeenEnsureState(void) {
    if (!sProtectedPKs)
        sProtectedPKs = [NSMutableOrderedSet orderedSet];
    if (sReleasedPKs)
        return;
    sReleasedPKs = [NSMutableOrderedSet orderedSet];
    id stored = SPKPreferenceObjectForKey(kSPKInstantsManualSeenReleasedKey);
    if (![stored isKindOfClass:NSArray.class])
        return;
    for (id pk in (NSArray *)stored) {
        if ([pk isKindOfClass:NSString.class] && ((NSString *)pk).length > 0)
            [sReleasedPKs addObject:pk];
    }
    if (sReleasedPKs.count > 0)
        SPKLog(@"Instants", @"manual seen: restored %lu released instant(s)",
               (unsigned long)sReleasedPKs.count);
}

// MARK: - Service Lookup

/// The live `IGQuickSnapService`, remembered from whichever call reached us first.
/// Falls back to the window -> userSession -> sharedQuickSnapService walk, the same route
/// `SPKInstantsLocateQuickSnapService` uses in InstantsResolver.xm.
static __weak id sCachedService = nil;

static id SPKInstantsManualSeenLocateService(void) {
    id cached = sCachedService;
    if (cached)
        return cached;
    @try {
        SEL sharedQSSel = NSSelectorFromString(@"sharedQuickSnapService");
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class])
                continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (![window respondsToSelector:@selector(userSession)])
                    continue;
                id session = SPKObjectForSelector(window, @"userSession");
                if (![session respondsToSelector:sharedQSSel])
                    continue;
                id service = ((id (*)(id, SEL))objc_msgSend)(session, sharedQSSel);
                if (service) {
                    sCachedService = service;
                    return service;
                }
            }
        }
    } @catch (__unused NSException *e) {
    }
    return nil;
}

// MARK: - Session Defaults Access

/// The session `IGUserDefaults` holding the seen state.
///
/// The service and the store expose the same object -- on device, filtering the key
/// through the service left the store with nothing to remove -- so one write is enough.
/// These are Swift stored properties, so they need an ivar read rather than KVC.
static id SPKInstantsManualSeenSessionDefaults(id service) {
    if (!service)
        return nil;
    id defaults = [SPKUtils getIvarForObj:service name:"sessionUserDefaults"];
    if (!defaults) {
        id store = [SPKUtils getIvarForObj:service name:"quickSnapStore"];
        if (store)
            defaults = [SPKUtils getIvarForObj:store name:"sessionUserDefaults"];
    }
    if (![defaults respondsToSelector:@selector(objectForKey:)] ||
        ![defaults respondsToSelector:@selector(setObject:forKey:)]) {
        return nil;
    }
    return defaults;
}

/// The persisted seen list as plain strings. Instagram stores an array; a set is accepted
/// too so a future representation change degrades instead of breaking.
static NSArray<NSString *> *SPKInstantsManualSeenStateList(id defaults) {
    id value = nil;
    @try {
        value = [defaults objectForKey:kSPKInstantsSeenStateDefaultsKey];
    } @catch (__unused NSException *e) {
        return nil;
    }
    if ([value isKindOfClass:NSArray.class])
        return (NSArray *)value;
    if ([value isKindOfClass:NSSet.class])
        return ((NSSet *)value).allObjects;
    if ([value isKindOfClass:NSOrderedSet.class])
        return ((NSOrderedSet *)value).array;
    return nil;
}

static BOOL SPKInstantsManualSeenWriteStateList(id defaults, NSArray<NSString *> *list) {
    @try {
        [defaults setObject:list forKey:kSPKInstantsSeenStateDefaultsKey];
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

/// Instagram 448 no longer exports `refreshSeenStateFromSharedStorage`, and nothing else
/// rebuilds `seenSnapPks` from the stored key: a forced refetch leaves it untouched, and
/// `clearCache` empties both it and the stored key (device-confirmed). So the set is
/// rewritten directly, through Swift, to exactly what the old reload produced: the stored
/// list.
///
/// The ivar is only written when it holds native `Set<String>` storage. Anything else means the
/// property changed type or representation, and writing a `Set<String>` over it would corrupt
/// Instagram's memory.
static BOOL SPKInstantsManualSeenRewriteMemorySet(id service, NSArray<NSString *> *list) {
    Class bridge = NSClassFromString(@"SPKInstantsSeenStateBridge");
    id store = [SPKUtils getIvarForObj:service name:"quickSnapStore"];
    if (!bridge || !store)
        return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(store), "seenSnapPks");
    if (!ivar)
        return NO;
    void *address = (uint8_t *)(__bridge void *)store + ivar_getOffset(ivar);

    // Bit 62 marks a non-native (Objective-C) backing, bit 63 a tagged pointer.
    uintptr_t word = *(uintptr_t *)address;
    if (word == 0 || (word >> 62) != 0)
        return NO;
    // `_TtGCs11_SetStorageSS_` is `_SetStorage<String>` (IG 448 reports it with a trailing `$`),
    // so a set of any other element type is refused. The empty singleton is shared by every
    // element type and holds nothing, so replacing it cannot misread existing contents.
    NSString *storageClass = NSStringFromClass(object_getClass((__bridge id)(void *)word));
    if (![storageClass hasPrefix:@"_TtGCs11_SetStorageSS_"] &&
        [storageClass rangeOfString:@"EmptySetSingleton"].location == NSNotFound) {
        SPKLog(@"Instants", @"manual seen: seen set not rewritten, unexpected storage %@", storageClass);
        return NO;
    }

    NSMutableArray<NSString *> *values = [NSMutableArray arrayWithCapacity:list.count];
    for (id pk in list) {
        if ([pk isKindOfClass:NSString.class])
            [values addObject:pk];
    }
    ((void (*)(id, SEL, void *, NSArray *))objc_msgSend)(bridge, @selector(replaceStringSetAtAddress:with:),
                                                           address, values);
    return YES;
}

/// Asks Instagram to rebuild `seenSnapPks` from the value we just wrote, then to tell its
/// UI. The reload selector exists up to IG 447; later builds rewrite the set directly.
/// `didReceiveNewSnaps` is what Instagram's own tray treats as "this list is worth
/// re-rendering". `NO` reloads the state but leaves the tray showing what it already drew,
/// so the restored Instants only appeared after the user refreshed the inbox by hand.
static void SPKInstantsManualSeenReloadState(id service, BOOL announceAsNew) {
    if (sRefreshing)
        return;
    sRefreshing = YES;
    SEL refresh = @selector(refreshSeenStateFromSharedStorage);
    SEL announce = @selector(announceSnapStateUpdateWithDidReceiveNewSnaps:);
    @try {
        if ([service respondsToSelector:refresh]) {
            ((void (*)(id, SEL))objc_msgSend)(service, refresh);
        } else {
            // Without the defaults there is no stored list to mirror, and rewriting the set
            // to empty would release every Instant the user has seen.
            id defaults = SPKInstantsManualSeenSessionDefaults(service);
            NSArray<NSString *> *stored = defaults ? (SPKInstantsManualSeenStateList(defaults) ?: @[]) : nil;
            if (!stored || !SPKInstantsManualSeenRewriteMemorySet(service, stored))
                SPKLog(@"Instants", @"manual seen: in-memory seen set unreachable, held instants return after a relaunch");
        }
        if ([service respondsToSelector:announce])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(service, announce, announceAsNew);
    } @catch (__unused NSException *e) {
    }
    sRefreshing = NO;
}

/// Refetches the snap list from the server, which is what actually brings the Instants back.
///
/// Clearing the stored seen state is necessary but not sufficient: Instagram purges the
/// media out of `timeOrderedQuicksnaps` entirely once the viewer closes, so by then there is
/// nothing left for an un-see to un-filter (device-confirmed: `availableTimeOrderedSnaps`
/// reads 0 immediately after a successful strip and reload). The snaps have to come back
/// from the server, and they come back unseen because the seen sync never leaves the device.
///
/// `forceRefetch` matters. The service throttles on `timeSinceLastFetch`, so the unforced
/// entry point often did nothing and the tray only updated once something else happened to
/// trigger a fetch.
static void SPKInstantsManualSeenRefetchSnaps(id service) {
    SEL forced = @selector(fetchQuickSnapsOnSuccess:onFailure:forceRefetch:);
    if ([service respondsToSelector:forced]) {
        @try {
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(service, forced, nil, nil, YES);
            return;
        } @catch (__unused NSException *e) {
        }
    }
    SEL initial = @selector(fetchInitialQuickSnaps);
    if ([service respondsToSelector:initial]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(service, initial);
        } @catch (__unused NSException *e) {
        }
        return;
    }
    SPKLog(@"Instants", @"manual seen: refetch unavailable (no fetch selector)");
}

// MARK: - Public

NSString *SPKInstantsManualSeenAuthorPKForUsername(NSString *username) {
    NSString *key = username.lowercaseString;
    return key.length > 0 ? sAuthorPKByUsername[key] : nil;
}

static void SPKInstantsManualSeenNoteAuthors(NSArray *mediaList) {
    if (!sAuthorPKByUsername)
        sAuthorPKByUsername = [NSMutableDictionary dictionary];
    for (id media in mediaList) {
        id user = SPKObjectForSelector(media, @"user");
        NSString *username = SPKStringFromValue(SPKObjectForSelector(user, @"username")).lowercaseString;
        NSString *pk = SPKStringFromValue(SPKObjectForSelector(user, @"pk"));
        if (pk.length == 0)
            pk = SPKInstantsManualSeenAuthorPKFromMediaPK(SPKStringFromValue(SPKObjectForSelector(media, @"pk")));
        if (username.length > 0 && pk.length > 0)
            sAuthorPKByUsername[username] = pk;
    }
    if (sAuthorPKByUsername.count > 1000)
        [sAuthorPKByUsername removeAllObjects];
}

void SPKInstantsManualSeenNoteServiceMedia(NSArray *mediaList) {
    if (mediaList.count == 0)
        return;
    SPKInstantsManualSeenNoteAuthors(mediaList);
    if (!SPKInstantsManualSeenIsEnabled())
        return;
    SPKInstantsManualSeenEnsureState();
    if (!sAuthorPKByMediaId)
        sAuthorPKByMediaId = [NSMutableDictionary dictionary];

    BOOL everyone = SPKInstantsManualSeenCoversEveryone();
    SPKInstantsManualSeenAuthorTest applies = SPKInstantsManualSeenMakeAuthorTest();
    NSUInteger skipped = 0;
    for (id media in mediaList) {
        NSString *pk = SPKStringFromValue(SPKObjectForSelector(media, @"pk"));
        if (pk.length == 0)
            pk = SPKStringFromValue(SPKObjectForSelector(media, @"graphQLID"));
        if (pk.length == 0 || [sReleasedPKs containsObject:pk])
            continue;
        NSString *author = SPKInstantsManualSeenAuthorPKFromMediaPK(pk);
        if (author.length > 0)
            sAuthorPKByMediaId[SPKInstantsManualSeenMediaIdFromMediaPK(pk)] = author;
        // Unlisted authors keep Instagram's own behaviour: never held, so viewing them marks
        // them seen as usual.
        if (!everyone && !applies(author)) {
            [sProtectedPKs removeObject:pk];
            skipped++;
            continue;
        }
        // Re-adding moves it to the end, so the bound below evicts the oldest PKs.
        [sProtectedPKs removeObject:pk];
        [sProtectedPKs addObject:pk];
    }

    while (sProtectedPKs.count > kSPKInstantsManualSeenHeldLimit)
        [sProtectedPKs removeObjectAtIndex:0];
    if (sAuthorPKByMediaId.count > kSPKInstantsManualSeenHeldLimit * 2)
        [sAuthorPKByMediaId removeAllObjects];
    if (skipped > 0)
        SPKLog(@"Instants", @"manual seen: %lu announced instant(s) not held, author not covered",
               (unsigned long)skipped);
}

static void SPKInstantsManualSeenReloadStateUnlessViewing(id service);

void SPKInstantsManualSeenHoldUnseen(id service) {
    if (sRefreshing || !SPKInstantsManualSeenIsEnabled())
        return;
    SPKInstantsManualSeenEnsureState();
    SPKInstantsManualSeenPruneProtected(SPKInstantsManualSeenMakeAuthorTest());
    // Releases alone are reason enough to run: after a relaunch nothing is held yet, and the
    // releases still have to be put back into a seen list Instagram has refetched without them.
    if (sProtectedPKs.count == 0 && sReleasedPKs.count == 0)
        return;

    if (service)
        sCachedService = service;
    id defaults = SPKInstantsManualSeenSessionDefaults(service);
    if (!defaults)
        return;

    NSArray<NSString *> *seen = SPKInstantsManualSeenStateList(defaults) ?: @[];
    if (seen.count == 0 && sReleasedPKs.count == 0)
        return;

    NSMutableArray<NSString *> *kept = [NSMutableArray arrayWithCapacity:seen.count];
    NSUInteger removed = 0;
    for (NSString *pk in seen) {
        if ([pk isKindOfClass:NSString.class] && [sProtectedPKs containsObject:pk]) {
            removed++;
            continue;
        }
        [kept addObject:pk];
    }

    // Re-assert the releases. Instagram refetches the whole list and knows nothing about
    // them, so without this a released Instant returns as unseen on the next fetch.
    NSUInteger reasserted = 0;
    for (NSString *pk in sReleasedPKs) {
        if (![kept containsObject:pk]) {
            [kept addObject:pk];
            reasserted++;
        }
    }
    if (removed == 0 && reasserted == 0)
        return;

    if (!SPKInstantsManualSeenWriteStateList(defaults, kept))
        return;
    SPKLog(@"Instants", @"manual seen: held %lu unseen, re-asserted %lu released "
                        @"(seen list %lu -> %lu, viewer=%@)",
           (unsigned long)removed, (unsigned long)reasserted,
           (unsigned long)seen.count, (unsigned long)kept.count,
           sViewerOpen ? @"open" : @"closed");
    SPKInstantsManualSeenReloadStateUnlessViewing(service);
}

/// Purely diagnostic: what Instagram now believes is available, so a log can show whether
/// the model was restored and only the tray lagged behind. IG 448 no longer exports the
/// accessor, which reads as `n/a`.
static NSString *SPKInstantsManualSeenAvailableSnapCount(id service) {
    SEL available = @selector(availableTimeOrderedSnaps);
    if (![service respondsToSelector:available])
        return @"n/a";
    @try {
        id list = ((id (*)(id, SEL))objc_msgSend)(service, available);
        if ([list respondsToSelector:@selector(count)])
            return [NSString stringWithFormat:@"%lu", (unsigned long)[list count]];
    } @catch (__unused NSException *e) {
    }
    return @"0";
}

/// Reloads the seen state, but never while the viewer is on screen.
///
/// The stored value holds only the snap Instagram consumed most recently, because every held
/// PK is stripped out of it as it appears. Instagram's in-memory set, by contrast, accumulates
/// everything watched this session. Reloading replaces that set with the stored one, so a
/// reload mid-session releases every snap watched so far back into the live list, not just the
/// one being marked seen, and the viewer starts over. Writing the stored value is enough on its
/// own: the snap being released is already seen in memory, since Instagram marked it when it
/// displayed it, so both agree without a reload, and the end of the session reloads from the
/// stored value anyway.
static void SPKInstantsManualSeenReloadStateUnlessViewing(id service) {
    if (sViewerOpen)
        return;
    SPKInstantsManualSeenReloadState(service, NO);
}

void SPKInstantsManualSeenSetViewerOpen(BOOL open) {
    sViewerOpen = open;
}

void SPKInstantsManualSeenEndViewerSession(id service) {
    sViewerOpen = NO;
    if (!SPKInstantsManualSeenIsEnabled())
        return;
    SPKInstantsManualSeenEnsureState();
    if (sProtectedPKs.count == 0)
        return;

    // Strip anything Instagram wrote while the viewer was closing, then reload
    // unconditionally: the stored value can already be clean while Instagram's in-memory
    // seen set still holds every snap from this session, and only the reload replaces that
    // set with what we stored.
    SPKInstantsManualSeenHoldUnseen(service);

    // Deferred past the dismissal. Announcing while the viewer is still tearing down left
    // the inbox drawing the tray from the list it already held, which is why the Instants
    // only came back after a manual refresh.
    __weak id weakService = service ?: SPKInstantsManualSeenLocateService();
    NSUInteger restored = sProtectedPKs.count;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id liveService = weakService ?: SPKInstantsManualSeenLocateService();
        if (!liveService)
            return;
        if (sViewerOpen) {
            // A new viewing session started inside the delay. Reloading now would push this
            // session's consumed snaps back into the live list underneath it, which is the
            // cycling this feature exists to avoid; that session's own end will restore them.
            SPKLog(@"Instants", @"manual seen: session end skipped, a new viewer opened");
            return;
        }
        SPKInstantsManualSeenReloadState(liveService, YES);
        SPKInstantsManualSeenRefetchSnaps(liveService);
        SPKLog(@"Instants", @"manual seen: session ended, %lu instant(s) held unseen, refetching "
                            @"(available=%@ before the response)",
               (unsigned long)restored,
               SPKInstantsManualSeenAvailableSnapCount(liveService));

        // The fetch is asynchronous, so the count above is always the pre-response one. This
        // second reading says whether the refetch actually restored the tray.
        __weak id weakLive = liveService;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id afterService = weakLive;
            if (!afterService)
                return;
            SPKLog(@"Instants", @"manual seen: refetch settled (available=%@)",
                   SPKInstantsManualSeenAvailableSnapCount(afterService));
        });
    });
}

void SPKInstantsManualSeenMarkMediaPK(NSString *mediaPK) {
    if (mediaPK.length == 0)
        return;
    SPKInstantsManualSeenEnsureState();

    // Stop protecting it first, so the next service update does not undo this write.
    [sProtectedPKs removeObject:mediaPK];
    [sReleasedPKs removeObject:mediaPK];
    [sReleasedPKs addObject:mediaPK];
    SPKInstantsManualSeenPersistReleased();

    id service = SPKInstantsManualSeenLocateService();
    id defaults = SPKInstantsManualSeenSessionDefaults(service);
    if (!defaults) {
        SPKLog(@"Instants", @"manual seen: mark %@ failed, session defaults unreachable", mediaPK);
        return;
    }

    NSArray<NSString *> *seen = SPKInstantsManualSeenStateList(defaults) ?: @[];
    if ([seen containsObject:mediaPK]) {
        // It had not been stripped yet, so dropping the hold above is enough.
        SPKInstantsManualSeenReloadStateUnlessViewing(service);
        return;
    }
    NSMutableArray<NSString *> *next = [seen mutableCopy];
    [next addObject:mediaPK];
    if (!SPKInstantsManualSeenWriteStateList(defaults, next))
        return;
    SPKLog(@"Instants", @"manual seen: released %@ (seen list now %lu, viewer=%@)",
           mediaPK, (unsigned long)next.count, sViewerOpen ? @"open" : @"closed");
    SPKInstantsManualSeenReloadStateUnlessViewing(service);
}

// MARK: - Eye Button Decision

/// Whether the eye button shows for the Instant on screen. Unknown until the first resolve of
/// a viewing session lands; a tap keeps the previous answer until the next one lands, so a run
/// of one author's Instants does not flicker the button.
typedef NS_ENUM(NSInteger, SPKInstantsEyeDecision) {
    SPKInstantsEyeDecisionUnknown = 0,
    SPKInstantsEyeDecisionShow,
    SPKInstantsEyeDecisionHide,
};

static SPKInstantsEyeDecision sEyeDecision = SPKInstantsEyeDecisionUnknown;
/// Media PK of the snap the decision was made for. A tap must resolve a different one, or
/// the swap has not landed yet.
static NSString *sDisplayedPK = nil;
/// Bumped per event and on viewer close, so a retry chasing an older snap bows out.
static NSUInteger sDisplayedGeneration = 0;
static __weak UIView *sEyeButtonHost = nil;

/// The resolve needs the swap animation to land and the image to load, the same race the
/// Instants auto-save pass handles; ~2s covers a slow transition.
static const NSTimeInterval kSPKInstantsEyeRetryDelay = 0.2;
static const NSUInteger kSPKInstantsEyeMaxAttempts = 10;

static void SPKInstantsManualSeenSetEyeDecision(SPKInstantsEyeDecision decision) {
    if (sEyeDecision == decision)
        return;
    sEyeDecision = decision;
    [sEyeButtonHost setNeedsLayout];
}

BOOL SPKInstantsManualSeenShouldShowEyeButton(void) {
    switch (sEyeDecision) {
    case SPKInstantsEyeDecisionShow:
        return YES;
    case SPKInstantsEyeDecisionHide:
        return NO;
    case SPKInstantsEyeDecisionUnknown:
        // Nothing resolved yet: only the every-author case can answer without knowing whose
        // Instant this is.
        return SPKInstantsManualSeenAllUsersMode() && SPKInstantsManualSeenCoversEveryone();
    }
    return NO;
}

void SPKInstantsManualSeenRegisterEyeButtonHost(UIView *header) {
    sEyeButtonHost = header;
}

static void SPKInstantsManualSeenResolveDisplayedSnap(UIView *view, NSUInteger attempt, NSUInteger generation,
                                                      NSString *previousPK) {
    if (generation != sDisplayedGeneration || !view.window)
        return;

    SPKInstantsResolvedSnap *snap = SPKInstantsResolveActiveSnapInView(view);
    NSString *pk = snap.sourceMediaPK;
    NSString *author = SPKInstantsManualSeenAuthorPKFromMediaPK(pk);
    if (author.length == 0 && snap.backingMedia)
        author = SPKStringFromValue(SPKObjectForSelector(SPKObjectForSelector(snap.backingMedia, @"user"), @"pk"));
    BOOL stale = previousPK.length > 0 && [pk isEqualToString:previousPK];

    if (author.length > 0 && !stale) {
        sDisplayedPK = pk;
        BOOL held = SPKInstantsManualSeenAppliesToAuthorPK(author);
        SPKInstantsManualSeenSetEyeDecision(held ? SPKInstantsEyeDecisionShow : SPKInstantsEyeDecisionHide);
        SPKLog(@"Instants", @"manual seen: eye button %@ for author %@ (attempt %lu)",
               held ? @"shown" : @"hidden", author, (unsigned long)(attempt + 1));
        return;
    }

    if (attempt + 1 >= kSPKInstantsEyeMaxAttempts) {
        // Fail open: a stray eye button costs nothing, a missing one strands a held Instant.
        sDisplayedPK = nil;
        SPKInstantsManualSeenSetEyeDecision(SPKInstantsEyeDecisionShow);
        SPKLog(@"Instants", @"manual seen: eye button shown, author unresolved (%@)",
               stale ? @"displayed snap never changed" : @"nothing resolved");
        return;
    }
    __weak UIView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKInstantsEyeRetryDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *strongView = weakView;
        if (strongView)
            SPKInstantsManualSeenResolveDisplayedSnap(strongView, attempt + 1, generation, previousPK);
    });
}

void SPKInstantsManualSeenDisplayedSnapMayHaveChanged(UIView *viewInHierarchy, BOOL expectsChange) {
    sDisplayedGeneration++;
    if (!viewInHierarchy || !SPKInstantsManualSeenIsEnabled()) {
        SPKInstantsManualSeenSetEyeDecision(SPKInstantsEyeDecisionHide);
        return;
    }
    // Every author held: the answer is the same for every Instant, so skip the resolve.
    if (SPKInstantsManualSeenCoversEveryone()) {
        SPKInstantsManualSeenSetEyeDecision(SPKInstantsEyeDecisionShow);
        return;
    }
    if (!expectsChange) {
        sDisplayedPK = nil;
        SPKInstantsManualSeenSetEyeDecision(SPKInstantsEyeDecisionUnknown);
    }
    NSUInteger generation = sDisplayedGeneration;
    NSString *previousPK = expectsChange ? sDisplayedPK : nil;
    __weak UIView *weakView = viewInHierarchy;
    // Next runloop turn: after a tap the new snap is only frontmost once Instagram's own
    // handler has advanced the stack.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongView = weakView;
        if (strongView)
            SPKInstantsManualSeenResolveDisplayedSnap(strongView, 0, generation, previousPK);
    });
}

void SPKInstantsManualSeenDisplayedSnapSessionEnded(void) {
    sDisplayedGeneration++;
    sDisplayedPK = nil;
    SPKInstantsManualSeenSetEyeDecision(SPKInstantsEyeDecisionUnknown);
}

// MARK: - Seen Sync Block

/// Instagram pushes its local seen state to the server, and a later tray fetch trusts that
/// server state. Without this, an Instant held locally unseen still disappears the
/// next time the tray is refetched, because the server already considers it seen.
typedef void (*SPKInstantsSyncSeenIMP)(id, SEL, id, id, id);
static SPKInstantsSyncSeenIMP orig_instantsSyncSeenSnaps = NULL;

static void replaced_instantsSyncSeenSnaps(id self, SEL _cmd, id sessionId, id onSuccess, id onFailure) {
    // With only some authors held the sync has to run, or nobody else's Instants would ever
    // be marked seen on the server. The held ones are taken out of the request it builds
    // instead (seen-request filter below).
    if (SPKInstantsManualSeenIsEnabled() && !SPKInstantsManualSeenCoversEveryone()) {
        sCachedService = self;
        SPKLog(@"Instants", @"manual seen: seen sync allowed (per-user), %lu held",
               (unsigned long)sProtectedPKs.count);
    } else if (SPKInstantsManualSeenIsEnabled()) {
        sCachedService = self;
        // Neither completion is invoked. Their argument lists are not declared in the
        // interface, so calling one blind would be a guess; leaving the request pending only
        // defers Instagram's own retry, which this feature suppresses again anyway.
        SPKLog(@"Instants", @"manual seen: suppressed seen sync to the server");
        return;
    }
    if (orig_instantsSyncSeenSnaps)
        orig_instantsSyncSeenSnaps(self, _cmd, sessionId, onSuccess, onFailure);
}

// MARK: - Seen Request Filter

/// The sync above is not the only way a seen state reaches the server. Instagram also builds
/// `IGXDTMarkQuickSnapSeenRequest` from another caller, batching every snap in its local
/// history (device-confirmed: twelve ids, including one just held unseen, sent right after a
/// camera switch with the sync still blocked). Every seen mutation is built from this input
/// object, so emptying its id list here covers callers the sync hook never sees. The request
/// still goes out, with nothing to mark, so no caller is left waiting on a missing reply.
typedef id (*SPKInstantsSeenRequestInitIMP)(id, SEL, id);
typedef void (*SPKInstantsSeenRequestSetIMP)(id, SEL, id);
static SPKInstantsSeenRequestInitIMP orig_seenRequestInitWithMediaIds = NULL;
static SPKInstantsSeenRequestSetIMP orig_seenRequestSetMediaIds = NULL;

/// Diagnostic: the first few ids exactly as Instagram passed them, so a log shows whether the
/// request carries `<mediaId>_<userPK>` or bare media ids.
static NSString *SPKInstantsManualSeenIdSample(NSArray *ids) {
    NSArray *head = ids.count > 3 ? [ids subarrayWithRange:NSMakeRange(0, 3)] : ids;
    return [head componentsJoinedByString:@", "];
}

/// YES when the id belongs to a held Instant: a held PK itself, a bare media id of one, or any
/// id whose author the list covers. Released PKs pass, since releasing is marking seen.
static BOOL SPKInstantsManualSeenRequestIdIsHeld(NSString *mediaId, SPKInstantsManualSeenAuthorTest applies) {
    if (![mediaId isKindOfClass:NSString.class] || mediaId.length == 0)
        return NO;
    if ([sReleasedPKs containsObject:mediaId])
        return NO;
    if ([sProtectedPKs containsObject:mediaId])
        return YES;
    NSString *author = SPKInstantsManualSeenAuthorPKFromMediaPK(mediaId);
    if (author.length == 0) {
        // Bare media id: match it to a held PK, else to an author seen in an announcement.
        NSString *prefix = [mediaId stringByAppendingString:@"_"];
        for (NSString *pk in sProtectedPKs) {
            if ([pk hasPrefix:prefix])
                return YES;
        }
        for (NSString *pk in sReleasedPKs) {
            if ([pk hasPrefix:prefix])
                return NO;
        }
        author = sAuthorPKByMediaId[mediaId];
        // An author that cannot be told is held, failing closed rather than leaking a view.
        if (author.length == 0)
            return YES;
    }
    return applies(author);
}

static id SPKInstantsManualSeenFilteredMediaIds(id ids) {
    if (!SPKInstantsManualSeenIsEnabled() || ![ids isKindOfClass:NSArray.class] || [(NSArray *)ids count] == 0)
        return ids;
    NSArray *list = (NSArray *)ids;
    if (SPKInstantsManualSeenCoversEveryone()) {
        SPKLog(@"Instants", @"manual seen: stripped %lu id(s) from a seen request (sample: %@)",
               (unsigned long)list.count, SPKInstantsManualSeenIdSample(list));
        return @[];
    }

    SPKInstantsManualSeenEnsureState();
    SPKInstantsManualSeenAuthorTest applies = SPKInstantsManualSeenMakeAuthorTest();
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:list.count];
    for (id mediaId in list) {
        if (!SPKInstantsManualSeenRequestIdIsHeld(mediaId, applies))
            [kept addObject:mediaId];
    }
    SPKLog(@"Instants", @"manual seen: seen request kept %lu of %lu id(s) (sample: %@)",
           (unsigned long)kept.count, (unsigned long)list.count, SPKInstantsManualSeenIdSample(list));
    return kept.count == list.count ? ids : kept.copy;
}

static id replaced_seenRequestInitWithMediaIds(id self, SEL _cmd, id ids) {
    return orig_seenRequestInitWithMediaIds(self, _cmd, SPKInstantsManualSeenFilteredMediaIds(ids));
}

static void replaced_seenRequestSetMediaIds(id self, SEL _cmd, id ids) {
    orig_seenRequestSetMediaIds(self, _cmd, SPKInstantsManualSeenFilteredMediaIds(ids));
}

static void SPKInstallInstantsSeenRequestFilter(void) {
    Class requestClass = objc_getClass("IGXDTMarkQuickSnapSeenRequest");
    if (!requestClass) {
        SPKLog(@"Instants", @"manual seen: seen-request filter skipped, class unavailable");
        return;
    }
    if (class_getInstanceMethod(requestClass, @selector(initWithMediaIds:)))
        MSHookMessageEx(requestClass, @selector(initWithMediaIds:), (IMP)replaced_seenRequestInitWithMediaIds,
                        (IMP *)&orig_seenRequestInitWithMediaIds);
    if (class_getInstanceMethod(requestClass, @selector(setMediaIds:)))
        MSHookMessageEx(requestClass, @selector(setMediaIds:), (IMP)replaced_seenRequestSetMediaIds,
                        (IMP *)&orig_seenRequestSetMediaIds);
    SPKLog(@"Instants", @"manual seen: seen-request filter installed (init=%@ set=%@)",
           orig_seenRequestInitWithMediaIds ? @"YES" : @"NO", orig_seenRequestSetMediaIds ? @"YES" : @"NO");
}

void SPKInstallInstantsManualSeenHooksIfEnabled(void) {
    static BOOL sInstalled = NO;
    if (sInstalled)
        return;
    sInstalled = YES;

    // Installed regardless of the pref: the hooks re-read it at call time, so the toggle
    // works without a restart.
    SPKInstallInstantsSeenRequestFilter();
    Class serviceClass = objc_getClass("_TtC18IGQuickSnapService18IGQuickSnapService");
    SEL sel = @selector(syncSeenSnapsWithServerWithDirectSessionId:onSuccess:onFailure:);
    if (!serviceClass || !class_getInstanceMethod(serviceClass, sel)) {
        SPKLog(@"Instants", @"manual seen: seen-sync hook skipped, selector unavailable");
        return;
    }
    MSHookMessageEx(serviceClass, sel, (IMP)replaced_instantsSyncSeenSnaps,
                    (IMP *)&orig_instantsSyncSeenSnaps);
    SPKLog(@"Instants", @"manual seen: seen-sync hook installed");
}
