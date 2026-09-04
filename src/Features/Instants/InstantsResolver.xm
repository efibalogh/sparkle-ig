#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../App/SPKPerfMeter.h"
#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Shared/ActionButton/ActionButtonLookupUtils.h"
#import "../../Shared/Account/SPKAccountManager.h"
#import "../../Utils.h"
#import "InstantsResolver.h"

// MARK: - Model Implementations

@implementation SPKInstantsResolvedSnap
- (NSURL *)url {
    return self.sparkleMediaURL;
}
- (NSURL *)imageURL {
    return self.sparklePhotoURL ?: self.sparkleMediaURL;
}
- (NSURL *)videoURL {
    return self.sparkleVideoURL;
}
- (NSDate *)takenAt {
    return self.importPostedDate;
}
- (id)media {
    return self.backingMedia;
}
@end

@implementation SPKInstantsResolverResult
@end

// MARK: - Service Cache Module

static NSArray *sCachedTimeOrderedSnaps = nil;
static NSArray *sCachedPeekPreviewSnaps = nil;

/// The last service lists observed while the consumption viewer is active. Instagram
/// removes a snap from these lists when it becomes the displayed item, so the item that
/// disappeared between two updates is a much stronger active-media signal than the view
/// stack's static subview order.
static NSArray *sObservedTimeOrderedSnaps = nil;
static NSArray *sObservedPeekPreviewSnaps = nil;
static id sTrackedActiveMedia = nil;
/// Identity of the first still-queued snap after `sTrackedActiveMedia`. When the active
/// media was already removed before Sparkle could record the full queue, this preserves
/// its position relative to the surviving session order.
static NSString *sTrackedActiveSuccessorKey = nil;
static BOOL sConsumptionSessionActive = NO;

/// Canonically ordered media discovered during the current viewer session. Instagram
/// removes items from its live queue as they reach the screen, but Expand and bulk actions
/// should continue to offer everything from this viewer until it is closed.
static NSMutableArray *sSessionMedia = nil;
/// Resolution/metadata cache only. Its insertion order is deliberately not used for the
/// expanded viewer because auto-save or active-media resolution may populate it first.
static NSMutableArray<SPKInstantsResolvedSnap *> *sSessionResolvedSnaps = nil;
/// Set by the account-change notification and consumed by the next viewer appearance.
/// This second boundary clear rejects any late callback from the outgoing account's
/// QuickSnap service that arrived after the notification-driven reset.
static BOOL sAccountBoundaryPendingViewer = NO;

/// Live IGQuickSnapService instance, captured from the service hooks. Used at action
/// time to read the backing store's FULL snap list (see SPKInstantsStoreFullMediaList).
/// Held strongly: the service is a long-lived per-session object, and we must be able to
/// reach its store at action time even if IG isn't currently calling the getters.
static id sQuickSnapServiceInstance = nil;

/// Finds the live IGQuickSnapService from the current user session. Used both at hook
/// install time (to capture the service before its getters fire) and lazily at resolve
/// time if the hook-based capture missed it.
static id SPKInstantsLocateQuickSnapService(void) {
    @try {
        SEL sharedQSSel = NSSelectorFromString(@"sharedQuickSnapService");
        // Walk windows to find the user session (same pattern as SPKInstagramAPI)
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class])
                continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (![window respondsToSelector:@selector(userSession)])
                    continue;
                id session = [window valueForKey:@"userSession"];
                if (!session)
                    continue;
                if ([session respondsToSelector:sharedQSSel]) {
                    id service = ((id (*)(id, SEL))objc_msgSend)(session, sharedQSSel);
                    if (service)
                        return service;
                }
            }
        }
    } @catch (__unused NSException *e) {
    }
    return nil;
}

/// Forward declarations — defined after the generic object-access helpers below.
static NSArray *SPKInstantsStoreSnapshot(void);
static NSArray *SPKInstantsUnionMediaLists(NSArray *primary, NSArray *secondary);
static NSSet<NSString *> *SPKInstantsIdentityKeysForMedia(id media);
static void SPKInstantsRegisterMediaList(NSArray *mediaList);
static void SPKInstantsNoteActiveIdentityKey(NSString *key);
static NSString *SPKInstantsActiveSnapPKFromStackView(UIView *stackView);
static NSInteger SPKInstantsFindSnapIndexByPK(NSArray<SPKInstantsResolvedSnap *> *snaps, NSString *pk);
static id SPKInstantsBackingObjectFromView(UIView *view, NSInteger depth);
static NSInteger SPKInstantsVisualActiveIndex(UIView *stackView, NSArray *currentImages);
static NSString *SPKInstantsMediaPKForObject(id object, NSInteger depth);
static UIView *SPKInstantsActiveSnapViewInWindow(UIView *viewInHierarchy);

/// Extracts a stable primary key string from a media object for deduplication.
/// Tries `pk`, `mediaPk`, and `graphQLID` selectors in order.
/// Media identity used for deduplication.
///
/// This MUST stay the same accessor the resolved snaps carry in `sourceMediaPK`, otherwise
/// dedup and active-snap matching key on different fields and disagree whenever a media
/// object exposes one identifier but not the other — which produced duplicate entries.
/// `SPKInstantsMediaPKForObject` is that single accessor; this is a thin alias kept for
/// call-site readability.
static NSString *SPKInstantsCacheMediaPK(id media) {
    return SPKInstantsMediaPKForObject(media, 0);
}

static NSString *SPKInstantsServiceObservationKey(id media) {
    NSString *pk = SPKInstantsCacheMediaPK(media);
    if (pk.length > 0)
        return [@"pk:" stringByAppendingString:pk];

    NSArray<NSString *> *identityKeys = [SPKInstantsIdentityKeysForMedia(media).allObjects
        sortedArrayUsingSelector:@selector(compare:)];
    NSString *identityKey = identityKeys.firstObject;
    return identityKey.length > 0 ? [@"cdn:" stringByAppendingString:identityKey] : nil;
}

static void SPKInstantsAppendSessionMedia(NSArray *mediaList) {
    if (!sConsumptionSessionActive || mediaList.count == 0)
        return;
    if (!sSessionMedia)
        sSessionMedia = [NSMutableArray array];

    NSMutableSet<NSString *> *knownKeys = [NSMutableSet setWithCapacity:sSessionMedia.count];
    for (id existing in sSessionMedia) {
        NSString *key = SPKInstantsServiceObservationKey(existing);
        if (key.length > 0)
            [knownKeys addObject:key];
    }
    for (id media in mediaList) {
        NSString *key = SPKInstantsServiceObservationKey(media);
        if (key.length > 0 && [knownKeys containsObject:key])
            continue;
        if (key.length == 0 && [sSessionMedia containsObject:media])
            continue;
        [sSessionMedia addObject:media];
        if (key.length > 0)
            [knownKeys addObject:key];
    }
}

/// Adds media missing from the canonical order. A service-removal successor is the only
/// trustworthy position once Instagram has already consumed the active item; without one,
/// the active item belongs at the front of the remaining queue.
static void SPKInstantsInsertSessionMedia(id media, NSString *successorKey) {
    if (!sConsumptionSessionActive || !media)
        return;
    if (!sSessionMedia)
        sSessionMedia = [NSMutableArray array];

    NSString *mediaKey = SPKInstantsServiceObservationKey(media);
    for (id existing in sSessionMedia) {
        NSString *existingKey = SPKInstantsServiceObservationKey(existing);
        if ((mediaKey.length > 0 && [existingKey isEqualToString:mediaKey]) ||
            (mediaKey.length == 0 && existing == media)) {
            return;
        }
    }

    NSUInteger insertionIndex = 0;
    if (successorKey.length > 0) {
        for (NSUInteger i = 0; i < sSessionMedia.count; i++) {
            NSString *existingKey = SPKInstantsServiceObservationKey(sSessionMedia[i]);
            if ([existingKey isEqualToString:successorKey]) {
                insertionIndex = i;
                break;
            }
        }
    }
    [sSessionMedia insertObject:media atIndex:insertionIndex];
    SPKLog(@"Instants", @"session order inserted missing active at=%lu successor=%@",
           (unsigned long)insertionIndex, successorKey ?: @"(none)");
}

/// Tracks the media Instagram just removed from a service list. During consumption that
/// removal means the media became the displayed snap. This avoids relying on the
/// SingleSnapView z-order, which stays fixed and otherwise keeps resolving the first snap.
static BOOL SPKInstantsObserveServiceList(NSArray *newList,
                                          NSArray *__strong *observedList,
                                          NSString *source,
                                          BOOL shouldTrackRemoval) {
    if (!newList || !observedList)
        return NO;

    NSArray *previousList = *observedList;
    *observedList = [newList copy];
    if (!sConsumptionSessionActive || previousList.count == 0)
        return NO;

    // The removed active item only exists in the previous queue. Record that queue before
    // examining the removal so it cannot disappear from the canonical expanded order.
    SPKInstantsAppendSessionMedia(previousList);

    NSMutableSet<NSString *> *newKeys = [NSMutableSet setWithCapacity:newList.count];
    for (id media in newList) {
        NSString *key = SPKInstantsServiceObservationKey(media);
        if (key.length > 0)
            [newKeys addObject:key];
    }

    // If more than one update was coalesced, the last removed item in the old ordering is
    // the newest displayed one. The normal path removes exactly one item per tap.
    id removedMedia = nil;
    NSUInteger removedIndex = NSNotFound;
    NSUInteger removedCount = 0;
    for (NSUInteger i = 0; i < previousList.count; i++) {
        id media = previousList[i];
        NSString *key = SPKInstantsServiceObservationKey(media);
        if (key.length == 0 || [newKeys containsObject:key])
            continue;
        removedMedia = media;
        removedIndex = i;
        removedCount++;
    }
    if (!removedMedia)
        return NO;

    if (!shouldTrackRemoval)
        return YES;

    sTrackedActiveMedia = removedMedia;
    sTrackedActiveSuccessorKey = nil;
    if (removedIndex != NSNotFound) {
        for (NSUInteger i = removedIndex + 1; i < previousList.count; i++) {
            NSString *key = SPKInstantsServiceObservationKey(previousList[i]);
            if (key.length > 0 && [newKeys containsObject:key]) {
                sTrackedActiveSuccessorKey = [key copy];
                break;
            }
        }
    }
    NSString *activeIdentityKey = [SPKInstantsIdentityKeysForMedia(removedMedia).allObjects
        sortedArrayUsingSelector:@selector(compare:)].firstObject;
    SPKInstantsNoteActiveIdentityKey(activeIdentityKey);
    SPKLog(@"Instants", @"active media tracked from %@ removal pk=%@ successor=%@ removed=%lu old=%lu new=%lu",
           source ?: @"service", SPKInstantsCacheMediaPK(removedMedia) ?: @"(nil)",
           sTrackedActiveSuccessorKey ?: @"(none)",
           (unsigned long)removedCount, (unsigned long)previousList.count,
           (unsigned long)newList.count);
    return YES;
}

/// Stores non-empty arrays from service hooks into the cache.
/// Only overwrites when the incoming array has items — the service reports only
/// *unseen* snaps, so its count drops to 0 as the user views them. We retain the
/// last non-empty snapshot for the duration of the viewer session (Requirement 2.3)
/// rather than letting a later empty callback wipe the cache.
/// Does not perform any resolution, URL extraction, or metadata parsing.
void SPKInstantsCacheServiceSnaps(id timeOrdered, id peekPreview, NSString *source) {
    BOOL hadMedia = (sCachedTimeOrderedSnaps.count > 0 || sCachedPeekPreviewSnaps.count > 0);
    NSArray *timeOrderedArr = SPKArrayFromCollection(timeOrdered);
    NSArray *peekPreviewArr = SPKArrayFromCollection(peekPreview);
    // Empty arrays matter to active tracking (the final snap was removed), even though the
    // retained bulk cache deliberately ignores them below.
    BOOL trackedTimeOrderedRemoval = NO;
    if (timeOrdered != nil && timeOrderedArr) {
        trackedTimeOrderedRemoval = SPKInstantsObserveServiceList(timeOrderedArr,
                                                                  &sObservedTimeOrderedSnaps,
                                                                  source,
                                                                  YES);
    }
    if (peekPreview != nil && peekPreviewArr) {
        SPKInstantsObserveServiceList(peekPreviewArr,
                                      &sObservedPeekPreviewSnaps,
                                      source,
                                      !trackedTimeOrderedRemoval);
    }
    if (timeOrderedArr.count > 0) {
        sCachedTimeOrderedSnaps = timeOrderedArr;
        SPKInstantsRegisterMediaList(timeOrderedArr);
        SPKInstantsAppendSessionMedia(timeOrderedArr);
        SPKLog(@"Instants", @"cache updated timeOrdered=%lu source=%@",
               (unsigned long)timeOrderedArr.count, source ?: @"unknown");
    }
    if (peekPreviewArr.count > 0) {
        sCachedPeekPreviewSnaps = peekPreviewArr;
        SPKInstantsRegisterMediaList(peekPreviewArr);
        SPKInstantsAppendSessionMedia(peekPreviewArr);
        SPKLog(@"Instants", @"cache updated peekPreview=%lu source=%@",
               (unsigned long)peekPreviewArr.count, source ?: @"unknown");
    }

    // When the cache first gains media (after the header may already be on-screen with a
    // hidden/empty button), trigger a layout pass on any existing header view so
    // SPKInstantsPlaceButton re-runs and configures the button against the now-populated
    // cache. The notification alone isn't enough because SPKConfigureActionButton won't
    // store the context if the first configure returned empty.
    BOOL hasMedia = (sCachedTimeOrderedSnaps.count > 0 || sCachedPeekPreviewSnaps.count > 0);
    if (!hadMedia && hasMedia) {
        dispatch_async(dispatch_get_main_queue(), ^{
            Class headerClass = objc_getClass("_TtC45IGQuickSnapNavigationV3HeaderButtonController39IGQuickSnapNavigationV3HeaderButtonView");
            if (!headerClass)
                return;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class])
                    continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
                    NSUInteger idx = 0;
                    while (idx < queue.count) {
                        UIView *view = queue[idx++];
                        if ([view isKindOfClass:headerClass]) {
                            [view setNeedsLayout];
                            [view layoutIfNeeded];
                        }
                        for (UIView *sub in view.subviews)
                            [queue addObject:sub];
                    }
                }
            }
        });
    }
}

#pragma mark - Seen-Media Registry

/// Map of CDN identity key -> IGMedia for the *current* viewing session only.
///
/// Instants are consume-once, like Snapchat: Instagram removes a snap from the store the
/// moment it is consumed, and once the user taps past it (or leaves the viewer) it is gone
/// for good. But between those two moments the snap is still on screen and still
/// actionable — download, expand, auto-save — while existing in no service list at all.
/// This registry covers exactly that window, so the displayed snap keeps its full metadata
/// (PK, author, posted date) and full-resolution candidates instead of degrading to
/// whatever can be scraped off the view.
///
/// It must NOT outlive the consumption viewer. Entries intentionally remain available
/// after their snap is tapped away so Expand and bulk actions can still access every
/// Instant from the current viewing session; the whole registry is cleared on viewer exit.
static NSMutableDictionary<NSString *, id> *sMediaByIdentityKey = nil;
static const NSUInteger kSPKInstantsMediaRegistryLimit = 400;

/// CDN identity key of the snap currently on screen, used to detect tap-away.
static NSString *sActiveIdentityKey = nil;

/// CDN identity key -> media PK, for the whole app session.
///
/// Distinct from the media registry above and deliberately longer-lived. Once a snap has
/// been consumed it can still be on screen when the viewer is re-opened, and it then
/// resolves from the view with no PK. Downstream de-duplication keys on `pk:<PK>` when a
/// PK is present and `url:<...>` when it isn't (`SPKDuplicateKey`), so the same snap saved
/// once live and once from the view lands in two different key spaces and is written to
/// the Gallery twice.
///
/// This map holds identifiers only — no media objects, no URLs — so it cannot resurrect a
/// consumed snap for viewing or download. Its sole purpose is keeping a snap's identity
/// stable across resolver paths so it is recognised as already saved.
static NSMutableDictionary<NSString *, NSString *> *sPKByIdentityKey = nil;

/// Indexes every media in `mediaList` under all of its CDN identity keys.
static void SPKInstantsRegisterMediaList(NSArray *mediaList) {
    if (!mediaList.count)
        return;
    if (!sMediaByIdentityKey)
        sMediaByIdentityKey = [NSMutableDictionary dictionary];

    if (!sPKByIdentityKey)
        sPKByIdentityKey = [NSMutableDictionary dictionary];

    for (id media in mediaList) {
        NSString *pk = SPKInstantsMediaPKForObject(media, 0);
        for (NSString *key in SPKInstantsIdentityKeysForMedia(media)) {
            if (!sMediaByIdentityKey[key])
                sMediaByIdentityKey[key] = media;
            if (pk.length > 0 && !sPKByIdentityKey[key])
                sPKByIdentityKey[key] = pk;
        }
    }

    if (sPKByIdentityKey.count > kSPKInstantsMediaRegistryLimit * 4)
        [sPKByIdentityKey removeAllObjects];

    // Bound the registry. Instants churn, so dropping the whole map is simpler and cheaper
    // than tracking recency, and the next service update repopulates what is still live.
    if (sMediaByIdentityKey.count > kSPKInstantsMediaRegistryLimit) {
        SPKLog(@"Instants", @"media registry over limit (%lu) — cleared",
               (unsigned long)sMediaByIdentityKey.count);
        [sMediaByIdentityKey removeAllObjects];
    }
}

/// Media previously seen under this CDN identity key, or nil.
static id SPKInstantsMediaForIdentityKey(NSString *key) {
    return key.length > 0 ? sMediaByIdentityKey[key] : nil;
}

/// Media PK last seen for this CDN identity key, or nil. Survives the viewer closing so a
/// view-resolved snap keeps the identity it was originally saved under.
static NSString *SPKInstantsPKForIdentityKey(NSString *key) {
    return key.length > 0 ? sPKByIdentityKey[key] : nil;
}

/// Records which snap is on screen. Previous media remains registered until the viewer
/// closes because session-scoped Expand should include Instants already tapped away.
static void SPKInstantsNoteActiveIdentityKey(NSString *key) {
    if (key.length == 0)
        return;
    sActiveIdentityKey = [key copy];
}

/// Clears the registry at a viewer-session or Instagram-account boundary.
static void SPKInstantsResetMediaRegistry(NSString *reason) {
    NSUInteger count = sMediaByIdentityKey.count;
    [sMediaByIdentityKey removeAllObjects];
    sActiveIdentityKey = nil;
    if (count > 0)
        SPKLog(@"Instants", @"registry cleared (%@, %lu entries)",
               reason ?: @"unknown", (unsigned long)count);
}

/// Returns the merged, deduplicated media list from both cache arrays.
/// Time-ordered snaps come first, then peek preview snaps that aren't already present.
/// Deduplication is by media PK.
NSArray *SPKInstantsMergedMediaList(void) {
    NSArray *timeOrdered = sCachedTimeOrderedSnaps;
    NSArray *peekPreview = sCachedPeekPreviewSnaps;

    if (!timeOrdered.count && !peekPreview.count)
        return @[];
    if (!peekPreview.count)
        return timeOrdered ?: @[];
    if (!timeOrdered.count)
        return peekPreview ?: @[];

    // Deduplicate: time-ordered items take priority, peek preview adds new items
    NSMutableOrderedSet *seenPKs = [NSMutableOrderedSet orderedSet];
    NSMutableArray *merged = [NSMutableArray arrayWithCapacity:timeOrdered.count + peekPreview.count];

    for (id media in timeOrdered) {
        NSString *pk = SPKInstantsCacheMediaPK(media);
        if (pk.length > 0) {
            if ([seenPKs containsObject:pk])
                continue;
            [seenPKs addObject:pk];
        }
        [merged addObject:media];
    }

    for (id media in peekPreview) {
        NSString *pk = SPKInstantsCacheMediaPK(media);
        if (pk.length > 0) {
            if ([seenPKs containsObject:pk])
                continue;
            [seenPKs addObject:pk];
        }
        [merged addObject:media];
    }

    return [merged copy];
}

/// The service's current remaining queue. Unlike `SPKInstantsMergedMediaList`, this honors
/// empty updates: once the final queued snap reaches the screen, retaining the previous
/// non-empty cache would put that already-discarded snap back into Expand / Download All.
static NSArray *SPKInstantsCurrentServiceMediaList(void) {
    BOOL hasLiveObservation = (sObservedTimeOrderedSnaps != nil || sObservedPeekPreviewSnaps != nil);
    if (!hasLiveObservation)
        return SPKInstantsMergedMediaList();

    return SPKInstantsUnionMediaLists(sObservedTimeOrderedSnaps ?: @[],
                                      sObservedPeekPreviewSnaps ?: @[]);
}

#pragma mark - Media-to-Snap Conversion

/// Object value accessor that tries selector, KVC, Swift ivar (via SPKUtils), and ObjC ivar.
/// QuickSnap media objects are Swift fragment types whose data is reachable through
/// several access paths, so we try them all.
static id SPKInstantsObjectIvarValue(id target, NSString *key) {
    if (!target || key.length == 0)
        return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(target), key.UTF8String);
    if (!ivar && ![key hasPrefix:@"_"]) {
        NSString *underscored = [@"_" stringByAppendingString:key];
        ivar = class_getInstanceVariable(object_getClass(target), underscored.UTF8String);
    }
    if (!ivar)
        return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || (type[0] != '@' && type[0] != '#'))
        return nil;
    id value = nil;
    @try {
        value = object_getIvar(target, ivar);
    } @catch (__unused NSException *e) {
    }
    return value && ![value isKindOfClass:NSNull.class] ? value : nil;
}

static id SPKInstantsSwiftIvarValue(id target, NSString *key) {
    if (!target || key.length == 0)
        return nil;
    for (NSString *candidateKey in @[ key, [@"_" stringByAppendingString:key] ]) {
        id value = nil;
        @try {
            value = [SPKUtils getIvarForObj:target name:candidateKey.UTF8String];
        }
        @catch (__unused NSException *e) {
            value = nil;
        }
        if (value && ![value isKindOfClass:NSNull.class])
            return value;
    }
    return nil;
}

/// Reads a Swift `Int` (or any integer-typed) stored property via its raw ivar offset.
///
/// Swift NSObject subclasses emit their stored properties into the ObjC ivar list, but
/// non-object properties carry an integer type encoding, so neither KVC (the property is
/// not @objc, so `valueForKey:` throws) nor `object_getIvar` (which reinterprets the slot
/// as an `id`) can read them. Only an offset read is safe.
///
/// Returns `defaultValue` when the ivar is absent or isn't an integer type.
static NSInteger SPKInstantsIntegerIvarValue(id target, NSString *key, NSInteger defaultValue) {
    if (!target || key.length == 0)
        return defaultValue;

    Ivar ivar = class_getInstanceVariable(object_getClass(target), key.UTF8String);
    if (!ivar && ![key hasPrefix:@"_"]) {
        NSString *underscored = [@"_" stringByAppendingString:key];
        ivar = class_getInstanceVariable(object_getClass(target), underscored.UTF8String);
    }
    if (!ivar)
        return defaultValue;

    const char *type = ivar_getTypeEncoding(ivar);
    if (!type)
        return defaultValue;

    ptrdiff_t offset = ivar_getOffset(ivar);
    const void *slot = (const void *)((const uint8_t *)(__bridge const void *)target + offset);
    switch (type[0]) {
        case 'q':
        case 'l':
            return (NSInteger)*(const int64_t *)slot;
        case 'Q':
        case 'L':
            return (NSInteger)*(const uint64_t *)slot;
        case 'i':
            return (NSInteger)*(const int32_t *)slot;
        case 'I':
            return (NSInteger)*(const uint32_t *)slot;
        default:
            return defaultValue;
    }
}

static id SPKInstantsObjectValue(id target, NSArray<NSString *> *keys) {
    if (!target)
        return nil;
    for (NSString *key in keys) {
        id value = SPKObjectForSelector(target, key);
        if (!value)
            value = SPKKVCObject(target, key);
        if (!value)
            value = SPKInstantsSwiftIvarValue(target, key);
        if (!value)
            value = SPKInstantsObjectIvarValue(target, key);
        if (value && ![value isKindOfClass:NSNull.class])
            return value;
    }
    return nil;
}

static double SPKInstantsDoubleValue(id target, NSArray<NSString *> *keys) {
    id value = SPKInstantsObjectValue(target, keys);
    if ([value respondsToSelector:@selector(doubleValue)])
        return [value doubleValue];
    return 0.0;
}

static BOOL SPKInstantsURLLooksVideo(NSURL *url) {
    NSString *extension = url.pathExtension.lowercaseString ?: @"";
    return [@[ @"mp4", @"mov", @"m4v", @"webm", @"hevc", @"m3u8" ] containsObject:extension];
}

/// Selects the best (highest-width) URL from a candidates/versions array.
static NSURL *SPKInstantsBestCandidateURL(id candidates) {
    NSArray *items = SPKArrayFromCollection(candidates);
    NSURL *bestURL = nil;
    NSInteger bestWidth = 0;
    for (id item in items) {
        NSURL *url = nil;
        NSInteger width = 0;
        if ([item isKindOfClass:NSDictionary.class]) {
            url = SPKURLFromValue(((NSDictionary *)item)[@"url"] ?: ((NSDictionary *)item)[@"urlString"]);
            width = [((NSDictionary *)item)[@"width"] integerValue];
        } else {
            url = SPKURLFromValue(SPKInstantsObjectValue(item, @[ @"url", @"urlString", @"uri" ]));
            id widthValue = SPKInstantsObjectValue(item, @[ @"width" ]);
            if ([widthValue respondsToSelector:@selector(integerValue)])
                width = [widthValue integerValue];
        }
        if (url && (!bestURL || width > bestWidth)) {
            bestURL = url;
            bestWidth = width;
        }
    }
    return bestURL;
}

static NSArray<NSString *> *SPKInstantsNestedKeys(void) {
    return @[ @"asIGQuickSnapMedia", @"asQuickSnapMedia", @"asMSHQuickSnapMedia",
              @"media", @"item", @"model", @"viewModel", @"legacyViewModel",
              @"quickSnapInfo", @"snap", @"instantSnap",
              @"asIGQuickSnapPhotoFragment", @"asQuickSnapPhotoFragment",
              @"asIGQuickSnapVideoFragment", @"asQuickSnapVideoFragment" ];
}

static NSURL *SPKInstantsVideoURLForObject(id object);
static NSURL *SPKInstantsPhotoURLForObject(id object);

/// Recursively determines whether an object represents a video Instant.
static BOOL SPKInstantsObjectLooksVideo(id object) {
    if (!object)
        return NO;

    NSString *mediaType = SPKStringFromValue(SPKInstantsObjectValue(object, @[ @"computedMediaType", @"mediaType", @"productType", @"type" ])).lowercaseString;
    if ([mediaType containsString:@"video"])
        return YES;
    if ([mediaType isEqualToString:@"2"])
        return YES;
    if (SPKInstantsDoubleValue(object, @[ @"videoDuration", @"duration" ]) > 0.0)
        return YES;
    if (SPKInstantsObjectValue(object, @[ @"videoVersions", @"video_versions", @"videoVersionsFragment" ]))
        return YES;

    id videoFragment = SPKInstantsObjectValue(object, @[ @"asIGQuickSnapVideoFragment", @"asQuickSnapVideoFragment" ]);
    if (videoFragment && videoFragment != object) {
        if (SPKInstantsVideoURLForObject(videoFragment))
            return YES;
        if (SPKInstantsDoubleValue(videoFragment, @[ @"videoDuration", @"duration" ]) > 0.0)
            return YES;
        if (SPKInstantsObjectValue(videoFragment, @[ @"videoVersions", @"video_versions", @"videoVersionsFragment" ]))
            return YES;
    }
    return NO;
}

/// Recursively extracts the best video URL from a media object, walking nested fragments.
static NSURL *SPKInstantsVideoURLForObject(id object) {
    if (!object)
        return nil;

    NSURL *directURL = SPKURLFromValue(object);
    if (SPKInstantsURLLooksVideo(directURL))
        return directURL;

    NSURL *url = SPKURLFromValue(SPKInstantsObjectValue(object, @[ @"sparkleVideoURL", @"videoURL", @"videoUrl", @"video_url", @"playableURL", @"playableUrl", @"playable_url", @"dashManifestURL", @"dashManifestUrl" ]));
    if (url)
        return url;

    id videoVersions = SPKInstantsObjectValue(object, @[ @"videoVersions", @"video_versions", @"videoVersionsFragment" ]);
    url = SPKInstantsBestCandidateURL(videoVersions);
    if (url)
        return url;

    id videoFragment = SPKInstantsObjectValue(object, @[ @"asIGQuickSnapVideoFragment", @"asQuickSnapVideoFragment" ]);
    if (videoFragment && videoFragment != object) {
        url = SPKInstantsVideoURLForObject(videoFragment);
        if (url)
            return url;
    }

    id nested = SPKInstantsObjectValue(object, SPKInstantsNestedKeys());
    if (nested && nested != object)
        return SPKInstantsVideoURLForObject(nested);

    return nil;
}

/// Recursively extracts the best photo URL from a media object, walking nested fragments.
static NSURL *SPKInstantsPhotoURLForObject(id object) {
    if (!object)
        return nil;

    NSURL *directURL = SPKURLFromValue(object);
    if (directURL && !SPKInstantsURLLooksVideo(directURL))
        return directURL;

    NSURL *url = SPKURLFromValue(SPKInstantsObjectValue(object, @[ @"sparklePhotoURL", @"displayUri", @"displayURI", @"mediaURLString", @"previewURLString", @"url", @"imageURL", @"imageUrl", @"thumbnailURL", @"squareCrop", @"fullSizeImageURLString" ]));
    if (url && !SPKInstantsURLLooksVideo(url))
        return url;

    id imageVersions = SPKInstantsObjectValue(object, @[ @"imageVersions2", @"image_versions2", @"imageVersions", @"imageVersionsFragment" ]);
    id candidates = SPKInstantsObjectValue(imageVersions, @[ @"candidates" ]);
    url = SPKInstantsBestCandidateURL(candidates ?: imageVersions);
    if (url)
        return url;

    // Try original_* variants (some models store original images separately)
    id originalImages = SPKInstantsObjectValue(object, @[ @"originalImages", @"original_images" ]);
    url = SPKInstantsBestCandidateURL(originalImages);
    if (url)
        return url;

    id mediaFragment = SPKInstantsObjectValue(object, @[ @"asIGQuickSnapMedia", @"asMSHQuickSnapMedia" ]);
    if (mediaFragment && mediaFragment != object) {
        url = SPKInstantsPhotoURLForObject(mediaFragment);
        if (url)
            return url;
    }

    // Try photo fragment (some Swift models have asIGQuickSnapPhotoFragment)
    id photoFragment = SPKInstantsObjectValue(object, @[ @"asIGQuickSnapPhotoFragment", @"asQuickSnapPhotoFragment" ]);
    if (photoFragment && photoFragment != object) {
        url = SPKInstantsPhotoURLForObject(photoFragment);
        if (url)
            return url;
    }

    id nested = SPKInstantsObjectValue(object, SPKInstantsNestedKeys());
    if (nested && nested != object)
        return SPKInstantsPhotoURLForObject(nested);

    return nil;
}

/// Recursively extracts the media PK string, walking nested fragments.
static NSString *SPKInstantsMediaPKForObject(id object, NSInteger depth) {
    if (!object || depth > 3)
        return nil;
    for (NSString *key in @[ @"graphQLID", @"mediaId", @"mediaID", @"pk", @"mediaPk", @"id" ]) {
        NSString *value = SPKStringFromValue(SPKInstantsObjectValue(object, @[ key ]));
        if (value.length > 0)
            return value;
    }
    id nested = SPKInstantsObjectValue(object, SPKInstantsNestedKeys());
    if (nested && nested != object)
        return SPKInstantsMediaPKForObject(nested, depth + 1);
    return nil;
}

/// Recursively extracts the posted date, walking nested fragments.
static NSDate *SPKInstantsPostedDateForObject(id object, NSInteger depth) {
    if (!object || depth > 3)
        return nil;
    for (NSString *key in @[ @"takenAt", @"taken_at", @"takenAtDate", @"device_timestamp", @"deviceTimestamp", @"created_at", @"createdAt", @"upload_time", @"uploadTime", @"published_time", @"publishedTime" ]) {
        id value = SPKInstantsObjectValue(object, @[ key ]);
        if (!value)
            continue;
        if ([value isKindOfClass:NSDate.class])
            return value;
        if ([value respondsToSelector:@selector(doubleValue)]) {
            double raw = [value doubleValue];
            if (raw > 1e15)
                raw /= 1000000.0;
            else if (raw > 1e12)
                raw /= 1000.0;
            if (raw > 0.0)
                return [NSDate dateWithTimeIntervalSince1970:raw];
        }
    }
    id nested = SPKInstantsObjectValue(object, SPKInstantsNestedKeys());
    if (nested && nested != object)
        return SPKInstantsPostedDateForObject(nested, depth + 1);
    return nil;
}

/// Converts an IGMedia (or compatible QuickSnap fragment) object into a fully populated
/// SPKInstantsResolvedSnap. Returns nil if no usable media URL can be extracted.
static SPKInstantsResolvedSnap *SPKInstantsResolvedSnapFromMedia(id media) {
    if (!media)
        return nil;

    NSString *username = SPKUsernameFromMediaObject(media);
    NSString *pk = SPKInstantsMediaPKForObject(media, 0);
    NSDate *postedDate = SPKInstantsPostedDateForObject(media, 0);

    NSURL *videoURL = SPKInstantsVideoURLForObject(media);
    NSURL *photoURL = SPKInstantsPhotoURLForObject(media);
    BOOL looksVideo = SPKInstantsObjectLooksVideo(media);
    BOOL isVideo = looksVideo && videoURL != nil;

    NSURL *mediaURL = isVideo ? videoURL : (photoURL ?: videoURL);

    if (!mediaURL) {
        // Enhanced diagnostic: dump class name and a few key ivars to understand the structure
        NSString *className = NSStringFromClass([media class]);
        // Try to enumerate ivars that might contain URL data
        NSMutableArray *ivarNames = [NSMutableArray array];
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(object_getClass(media), &ivarCount);
        for (unsigned int i = 0; ivars && i < ivarCount && i < 20; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (name && type) {
                NSString *ivarName = [NSString stringWithUTF8String:name];
                // Only log object-type ivars that might contain URLs/versions
                if (type[0] == '@' &&
                    ([ivarName containsString:@"image"] || [ivarName containsString:@"Image"] ||
                     [ivarName containsString:@"video"] || [ivarName containsString:@"Video"] ||
                     [ivarName containsString:@"url"] || [ivarName containsString:@"URL"] ||
                     [ivarName containsString:@"version"] || [ivarName containsString:@"Version"] ||
                     [ivarName containsString:@"media"] || [ivarName containsString:@"Media"] ||
                     [ivarName containsString:@"fragment"] || [ivarName containsString:@"Fragment"])) {
                    id ivarValue = nil;
                    @try {
                        ivarValue = object_getIvar(media, ivars[i]);
                    } @catch (__unused NSException *e) {
                    }
                    [ivarNames addObject:[NSString stringWithFormat:@"%@(%@)=%@",
                                                                    ivarName, [NSString stringWithUTF8String:type],
                                                                    ivarValue ? NSStringFromClass([ivarValue class]) : @"nil"]];
                }
            }
        }
        if (ivars)
            free(ivars);

        SPKLog(@"Instants", @"resolvedSnapFromMedia: no usable URL for media pk=%@ username=%@ class=%@ ivars=[%@]",
               pk ?: @"(nil)", username ?: @"(nil)", className,
               [ivarNames componentsJoinedByString:@", "]);
        return nil;
    }

    SPKInstantsResolvedSnap *snap = [[SPKInstantsResolvedSnap alloc] init];
    snap.sourceUsername = username;
    snap.sourceMediaPK = pk;
    snap.importPostedDate = postedDate;
    snap.sparkleIsVideo = isVideo;
    snap.sparkleMediaURL = mediaURL;
    snap.sparklePhotoURL = photoURL;
    snap.sparkleVideoURL = isVideo ? videoURL : nil;
    snap.sourceMediaURLString = mediaURL.absoluteString;
    snap.backingMedia = media;
    snap.resolverPath = @"service";

    return snap;
}

#pragma mark - Active Index Detection (Hook-Based Tracker)

/// Tracked active index — updated by hooking handleTap on the AnimatingSnapStackView.
/// This avoids reading the Swift `state` ivar (which crashes/returns nil after tap-through).
/// Reset to 0 when the consumption VC disappears.
static NSInteger sTrackedActiveIndex = 0;
/// The total count of snaps in the display list at the time tracking started.
/// Used to clamp the tracked index and detect stale values.
static NSUInteger sTrackedDisplayCount = 0;
/// Whether the hook-based tracker has been initialized this consumption session.
static BOOL sTrackedIndexValid = NO;

/// Initializes tracking from the stack view's current state. Called lazily on first resolve.
/// Reads the currentImages array directly from the stack view (not from state — the view
/// has its own copy of this ivar that's safe to access via ObjC runtime).
static void SPKInstantsInitTracking(UIView *stackView) {
    if (sTrackedIndexValid)
        return;
    if (!stackView)
        return;

    // The AnimatingSnapStackView has a 'currentImages' ivar directly on it (not just on state).
    // This is a Swift Array bridged to NSArray of SingleSnapView instances.
    NSArray *currentImages = nil;
    @try {
        currentImages = SPKArrayFromCollection([stackView valueForKey:@"currentImages"]);
    } @catch (__unused NSException *e) {
    }
    if (!currentImages.count) {
        // Try the ivar directly (it's listed in the header as a direct ivar on the view)
        currentImages = SPKArrayFromCollection(SPKInstantsObjectIvarValue(stackView, @"currentImages"));
    }
    // Last resort: reconstruct from subviews
    if (!currentImages.count) {
        Class singleSnapClass = NSClassFromString(@"_TtC40IGQuickSnapImmersiveViewerSingleSnapView40IGQuickSnapImmersiveViewerSingleSnapView");
        if (!singleSnapClass)
            singleSnapClass = NSClassFromString(@"IGQuickSnapImmersiveViewerSingleSnapView");
        if (singleSnapClass) {
            NSMutableArray *snapViews = [NSMutableArray array];
            for (UIView *sub in stackView.subviews) {
                if ([sub isKindOfClass:singleSnapClass])
                    [snapViews addObject:sub];
            }
            if (snapViews.count > 0)
                currentImages = [snapViews copy];
        }
    }

    sTrackedDisplayCount = currentImages.count;

    // Try to read the initial index from state (may work on first open before tap-through).
    // If it fails, determine active by visual inspection of the subviews.
    NSInteger initialIndex = 0;
    id state = SPKInstantsObjectValue(stackView, @[ @"state" ]);
    if (state && [state isKindOfClass:NSObject.class]) {
        @try {
            id val = [state valueForKey:@"currentlyDisplayingQuickSnapIndex"];
            if ([val respondsToSelector:@selector(integerValue)]) {
                initialIndex = [val integerValue];
            }
        } @catch (__unused NSException *e) {
        }
    }

    // Validate: if index is 0 or state was nil, try the visual approach
    if (initialIndex == 0 || !state) {
        NSInteger visualIndex = SPKInstantsVisualActiveIndex(stackView, currentImages);
        if (visualIndex >= 0) {
            initialIndex = visualIndex;
        }
    }

    sTrackedActiveIndex = initialIndex;
    sTrackedIndexValid = YES;
    SPKLog(@"Instants", @"tracking initialized: index=%ld displayCount=%lu",
           (long)sTrackedActiveIndex, (unsigned long)sTrackedDisplayCount);
}

/// Resets tracking state (called when consumption VC disappears).
static void SPKInstantsResetTracking(void) {
    sTrackedActiveIndex = 0;
    sTrackedDisplayCount = 0;
    sTrackedIndexValid = NO;
}

/// Updates the display count for the tracker. Called from the main resolve function
/// once we know the actual display list size, so handleTap clamping works correctly.
static void SPKInstantsUpdateTrackingCount(NSUInteger count) {
    if (count > 0 && sTrackedDisplayCount != count) {
        sTrackedDisplayCount = count;
    }
}

/// Determines the active snap index by visual inspection of the stack view's subviews.
/// The active (topmost displayed) SingleSnapView is typically:
///   - The frontmost visible subview (last in subviews array) that matches SingleSnapView class
///   - NOT hidden, alpha > 0, and has a non-transformed (identity) state OR is the highest z-position
/// Returns -1 if not determinable.
static NSInteger SPKInstantsVisualActiveIndex(UIView *stackView, NSArray *currentImages) {
    if (!stackView || !currentImages.count)
        return -1;

    Class singleSnapClass = NSClassFromString(@"_TtC40IGQuickSnapImmersiveViewerSingleSnapView40IGQuickSnapImmersiveViewerSingleSnapView");
    if (!singleSnapClass)
        singleSnapClass = NSClassFromString(@"IGQuickSnapImmersiveViewerSingleSnapView");

    // Walk subviews in REVERSE order (frontmost = last). The first visible SingleSnapView
    // that isn't being animated away (transform ~ identity, full alpha) is the active one.
    NSArray<UIView *> *subviews = stackView.subviews;
    UIView *activeView = nil;

    SPKLog(@"Instants", @"visual: stackView has %lu subviews, currentImages has %lu items",
           (unsigned long)subviews.count, (unsigned long)currentImages.count);

    for (NSInteger i = (NSInteger)subviews.count - 1; i >= 0; i--) {
        UIView *sub = subviews[i];
        if (sub.hidden || sub.alpha < 0.3)
            continue;
        if (sub.bounds.size.width < 20 || sub.bounds.size.height < 20)
            continue;

        BOOL isSnapView = NO;
        if (singleSnapClass && [sub isKindOfClass:singleSnapClass]) {
            isSnapView = YES;
        } else {
            // Fallback: check class name string
            NSString *cn = NSStringFromClass(sub.class);
            if ([cn containsString:@"SingleSnapView"])
                isSnapView = YES;
        }
        if (!isSnapView)
            continue;

        // Check if this view is in a "normal" display state (not being swept away).
        // An animating-away view typically has a non-identity transform (scaled down / rotated).
        CGAffineTransform t = sub.transform;
        BOOL isIdentityish = (fabs(t.a - 1.0) < 0.15 && fabs(t.d - 1.0) < 0.15 &&
                              fabs(t.b) < 0.15 && fabs(t.c) < 0.15);

        SPKLog(@"Instants", @"visual: subview[%ld] alpha=%.2f transform=[%.2f,%.2f,%.2f,%.2f] identity=%d class=%@",
               (long)i, sub.alpha, t.a, t.b, t.c, t.d, isIdentityish,
               NSStringFromClass(sub.class));

        if (isIdentityish) {
            activeView = sub;
            break;
        }
    }

    if (!activeView) {
        // All views might be mid-animation; pick the last visible one
        for (NSInteger i = (NSInteger)subviews.count - 1; i >= 0; i--) {
            UIView *sub = subviews[i];
            if (sub.hidden || sub.alpha < 0.1)
                continue;
            BOOL isSnapView = NO;
            if (singleSnapClass && [sub isKindOfClass:singleSnapClass])
                isSnapView = YES;
            else if ([NSStringFromClass(sub.class) containsString:@"SingleSnapView"])
                isSnapView = YES;
            if (isSnapView) {
                activeView = sub;
                break;
            }
        }
    }

    if (!activeView) {
        SPKLog(@"Instants", @"visual: no active view found");
        return -1;
    }

    // Find this view's index in currentImages by pointer equality
    for (NSUInteger i = 0; i < currentImages.count; i++) {
        if (currentImages[i] == activeView) {
            SPKLog(@"Instants", @"visual: matched activeView at index %lu (pointer)", (unsigned long)i);
            return (NSInteger)i;
        }
    }

    SPKLog(@"Instants", @"visual: activeView %@ not found in currentImages by pointer, trying PK match",
           activeView);

    // If not found by pointer, try matching by identity (view might be recreated but
    // backing the same media). Match by extracting PK from both.
    NSString *activePK = nil;
    id backingMedia = SPKInstantsBackingObjectFromView(activeView, 0);
    if (backingMedia)
        activePK = SPKInstantsMediaPKForObject(backingMedia, 0);
    if (activePK.length > 0) {
        for (NSUInteger i = 0; i < currentImages.count; i++) {
            id item = currentImages[i];
            if (![item isKindOfClass:UIView.class])
                continue;
            id itemMedia = SPKInstantsBackingObjectFromView((UIView *)item, 0);
            if (itemMedia) {
                NSString *itemPK = SPKInstantsMediaPKForObject(itemMedia, 0);
                if ([activePK isEqualToString:itemPK])
                    return (NSInteger)i;
            }
        }
    }

    // Last resort: if currentImages was reconstructed from subviews in the same order,
    // the active view's position in subviews relative to other SingleSnapViews IS its index.
    // Find which SingleSnapView index this is among all SingleSnapViews in subviews.
    NSUInteger snapViewIndex = 0;
    for (UIView *sub in subviews) {
        BOOL isSnapView = NO;
        if (singleSnapClass && [sub isKindOfClass:singleSnapClass])
            isSnapView = YES;
        else if ([NSStringFromClass(sub.class) containsString:@"SingleSnapView"])
            isSnapView = YES;
        if (!isSnapView)
            continue;
        if (sub == activeView) {
            SPKLog(@"Instants", @"visual: matched activeView at subview snap index %lu", (unsigned long)snapViewIndex);
            return (NSInteger)snapViewIndex < (NSInteger)currentImages.count ? (NSInteger)snapViewIndex : -1;
        }
        snapViewIndex++;
    }

    SPKLog(@"Instants", @"visual: could not determine index");
    return -1;
}

/// Returns the best-known active index for the stack view.
/// Uses visual detection as primary (most reliable after tap-through), with the
/// hook-tracked index as fallback when visual detection can't determine the answer.
static NSInteger SPKInstantsActiveIndex(UIView *stackView) {
    // Initialize tracking if needed
    SPKInstantsInitTracking(stackView);

    // Primary: visual detection (always works if views are on screen)
    NSArray *currentImages = nil;
    @try {
        currentImages = SPKArrayFromCollection([stackView valueForKey:@"currentImages"]);
    } @catch (__unused NSException *e) {
    }
    if (!currentImages.count) {
        currentImages = SPKArrayFromCollection(SPKInstantsObjectIvarValue(stackView, @"currentImages"));
    }
    if (!currentImages.count) {
        // Reconstruct from subviews
        Class singleSnapClass = NSClassFromString(@"_TtC40IGQuickSnapImmersiveViewerSingleSnapView40IGQuickSnapImmersiveViewerSingleSnapView");
        if (!singleSnapClass)
            singleSnapClass = NSClassFromString(@"IGQuickSnapImmersiveViewerSingleSnapView");
        if (singleSnapClass) {
            NSMutableArray *snapViews = [NSMutableArray array];
            for (UIView *sub in stackView.subviews) {
                if ([sub isKindOfClass:singleSnapClass])
                    [snapViews addObject:sub];
            }
            if (snapViews.count > 0)
                currentImages = [snapViews copy];
        }
    }

    NSInteger visual = SPKInstantsVisualActiveIndex(stackView, currentImages);
    if (visual >= 0)
        return visual;

    // Fallback: hook-tracked index (if valid and in range)
    if (sTrackedIndexValid && sTrackedDisplayCount > 0) {
        NSInteger clamped = sTrackedActiveIndex;
        if (clamped >= (NSInteger)sTrackedDisplayCount)
            clamped = (NSInteger)sTrackedDisplayCount - 1;
        if (clamped < 0)
            clamped = 0;
        return clamped;
    }

    return 0;
}

/// Find the key window for a given view, falling back to the first key window.
static UIWindow *SPKInstantsWindowForHeader(UIView *header) {
    if (header.window)
        return header.window;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow)
                return window;
        }
    }
    return nil;
}

/// Finds the AnimatingSnapStackView that owns the currently visible snap.
///
/// Instagram can retain an older, empty stack in the same window. Returning the first
/// class match made the initial/topmost Instant resolve from its rendered view even while
/// the live stack still held a full `viewModel.snaps` entry with its PK, posted date, and
/// original-resolution candidates.
static UIView *SPKInstantsSnapStackViewForHeader(UIView *header) {
    UIWindow *window = SPKInstantsWindowForHeader(header);
    if (!window)
        return nil;

    UIView *activeSnapView = SPKInstantsActiveSnapViewInWindow(header);
    for (UIView *ancestor = activeSnapView.superview; ancestor; ancestor = ancestor.superview) {
        NSString *className = NSStringFromClass(ancestor.class);
        if ([className containsString:@"IGQuickSnapImmersiveViewerAnimatingSnapStackView"] &&
            ![className containsString:@"PanHandler"] &&
            ![className containsString:@"State"]) {
            return ancestor;
        }
    }

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    UIView *fallback = nil;
    NSUInteger idx = 0;
    while (idx < queue.count) {
        UIView *view = queue[idx++];
        NSString *className = NSStringFromClass(view.class);
        if ([className containsString:@"IGQuickSnapImmersiveViewerAnimatingSnapStackView"] &&
            ![className containsString:@"PanHandler"] &&
            ![className containsString:@"State"]) {
            // Prefer a live visible stack. Keep the first match only as a compatibility
            // fallback for versions whose stack does not expose a useful visibility state.
            if (!view.hidden && view.alpha > 0.05 && view.window == window &&
                view.bounds.size.width >= 20.0 && view.bounds.size.height >= 20.0) {
                return view;
            }
            if (!fallback)
                fallback = view;
        }
        for (UIView *sub in view.subviews) {
            [queue addObject:sub];
        }
    }
    return fallback;
}

/// Returns the current active index using the hook-based tracker.
/// Falls back to visual detection if tracking hasn't been initialized.
static NSInteger SPKInstantsRawActiveIndexFromStackView(UIView *stackView) {
    if (!stackView)
        return 0;
    return SPKInstantsActiveIndex(stackView);
}

#pragma mark - View-Based Fallback (for active/seen snaps not in service cache)

/// Checks whether a view or any of its ancestors up to rootSnapView is a prompt, CTA,
/// sticker, avatar, badge, button, or other non-media overlay view.
static BOOL SPKInstantsIsOverlayOrPromptView(UIView *view, UIView *rootSnapView) {
    if (!view || view == rootSnapView)
        return NO;

    UIView *curr = view;
    while (curr && curr != rootSnapView) {
        if ([curr isKindOfClass:UIButton.class] || [curr isKindOfClass:UIControl.class])
            return YES;

        NSString *className = NSStringFromClass(curr.class);
        if (className.length > 0) {
            if ([className containsString:@"Prompt"] ||
                [className containsString:@"AddYours"] ||
                [className containsString:@"CTA"] ||
                [className containsString:@"Sticker"] ||
                [className containsString:@"Avatar"] ||
                [className containsString:@"Badge"] ||
                [className containsString:@"ProfilePicture"] ||
                [className containsString:@"IconButton"] ||
                [className containsString:@"AuthorText"] ||
                [className containsString:@"HeaderButton"]) {
                return YES;
            }
        }
        curr = curr.superview;
    }
    return NO;
}

/// Walks a view tree to find an IGImageView/UIImageView that has loaded content.
/// Prunes prompt/CTA/sticker subtrees and prioritizes the largest image view by area.
static UIImageView *SPKInstantsImageViewInSnap(UIView *snap) {
    if (!snap)
        return nil;
    Class igImageViewClass = NSClassFromString(@"IGImageView");
    UIImageView *bestImageView = nil;
    CGFloat maxArea = 0.0;
    UIImageView *fallbackImageView = nil;
    CGFloat fallbackMaxArea = 0.0;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:snap];
    NSUInteger idx = 0;
    while (idx < queue.count) {
        UIView *view = queue[idx++];
        if (view.hidden || view.alpha < 0.05)
            continue;

        if (SPKInstantsIsOverlayOrPromptView(view, snap))
            continue;

        CGFloat width = view.bounds.size.width;
        CGFloat height = view.bounds.size.height;
        CGFloat area = width * height;

        BOOL isImageView = [view isKindOfClass:UIImageView.class] ||
                           (igImageViewClass && [view isKindOfClass:igImageViewClass]);
        if (isImageView) {
            UIImageView *imageView = (UIImageView *)view;
            BOOL hasImage = (imageView.image != nil);
            NSURL *specURL = nil;
            if (!hasImage) {
                id spec = nil;
                @try {
                    spec = [imageView valueForKey:@"imageSpecifier"];
                } @catch (__unused NSException *e) {
                }
                specURL = SPKURLFromValue(SPKObjectForSelector(spec, @"url") ?: SPKKVCObject(spec, @"url"));
            }

            if (hasImage || specURL) {
                if (width >= 80.0 && height >= 80.0 && area > maxArea) {
                    maxArea = area;
                    bestImageView = imageView;
                } else if (area > fallbackMaxArea) {
                    fallbackMaxArea = area;
                    fallbackImageView = imageView;
                }
            }
        }

        for (UIView *s in view.subviews) {
            [queue addObject:s];
        }
    }
    return bestImageView ?: fallbackImageView;
}

/// Extracts the real CDN URL an IGImageView loaded, via its `imageSpecifier`.
///
/// `IGImageSpecifier` is an `FBIvarBasedEqualityObject` tagged union: it has **no** `url`
/// property, only a `_subtype` discriminator plus one `IGImageURL` ivar per case. Asking it
/// for `url` always fails, which is what previously forced the caller down to re-encoding
/// the on-screen render (a screen-sized, ~750px image). We read the case ivars instead and
/// unwrap the `IGImageURL`, which does expose `url` (plus `width`/`height`).
static NSURL *SPKInstantsURLForImageView(UIImageView *imageView) {
    if (!imageView)
        return nil;

    id spec = SPKInstantsObjectValue(imageView, @[ @"imageSpecifier" ]);
    if (spec) {
        // Ordered by usefulness: the plain remote image is the common case for snaps.
        for (NSString *key in @[ @"_remoteImage_imageURL",
                                 @"_prefetchedAdaptiveRemoteImageDEPRECATED_imageURL",
                                 @"_externalImage_imageURL",
                                 @"_userInterfaceStyleDependentRemoteImage_lightURL",
                                 @"_userInterfaceStyleDependentRemoteImage_darkURL" ]) {
            id imageURL = SPKInstantsObjectIvarValue(spec, key);
            if (!imageURL)
                continue;
            // IGImageURL wraps the NSURL; older shapes may already be an NSURL.
            NSURL *url = SPKURLFromValue(SPKInstantsObjectValue(imageURL, @[ @"url" ]) ?: imageURL);
            if (url)
                return url;
        }
    }

    return SPKURLFromValue(SPKObjectForSelector(imageView, @"url") ?: SPKKVCObject(imageView, @"url"));
}

/// Identity key for a CDN media URL: the filename, stripped of query parameters.
///
/// The same underlying media is served at several resolutions from URLs that differ in
/// their size segment and signing query, but IG keeps a stable `<id>_<n>_<n>_n.jpg`-style
/// filename across candidates. Comparing whole URL strings therefore fails to recognise
/// that the 750px image on screen and the full-res candidate in the store are one snap.
static NSString *SPKInstantsURLIdentityKey(NSURL *url) {
    NSString *filename = url.lastPathComponent;
    if (filename.length == 0)
        return nil;
    // Drop a trailing extension so ".jpg" vs ".heic" re-encodes still match.
    NSString *stem = filename.stringByDeletingPathExtension;
    return stem.length > 0 ? stem : filename;
}

/// All identity keys a media object can be recognised by: every image candidate, every
/// video version, and any single top-level URL. Used to match the on-screen snap back to
/// its full-resolution entry in the store list.
static NSSet<NSString *> *SPKInstantsIdentityKeysForMedia(id media) {
    if (!media)
        return nil;
    NSMutableSet<NSString *> *keys = [NSMutableSet set];

    void (^addURL)(NSURL *) = ^(NSURL *url) {
        NSString *key = SPKInstantsURLIdentityKey(url);
        if (key)
            [keys addObject:key];
    };

    id imageVersions = SPKInstantsObjectValue(media, @[ @"imageVersions2", @"image_versions2", @"imageVersions", @"imageVersionsFragment" ]);
    id candidates = SPKInstantsObjectValue(imageVersions, @[ @"candidates" ]);
    for (id candidate in SPKArrayFromCollection(candidates ?: imageVersions)) {
        if ([candidate isKindOfClass:NSDictionary.class])
            addURL(SPKURLFromValue(((NSDictionary *)candidate)[@"url"] ?: ((NSDictionary *)candidate)[@"urlString"]));
        else
            addURL(SPKURLFromValue(SPKInstantsObjectValue(candidate, @[ @"url", @"urlString", @"uri" ])));
    }

    for (id version in SPKArrayFromCollection(SPKInstantsObjectValue(media, @[ @"videoVersions", @"video_versions" ]))) {
        if ([version isKindOfClass:NSDictionary.class])
            addURL(SPKURLFromValue(((NSDictionary *)version)[@"url"] ?: ((NSDictionary *)version)[@"urlString"]));
        else
            addURL(SPKURLFromValue(SPKInstantsObjectValue(version, @[ @"url", @"urlString", @"uri" ])));
    }

    addURL(SPKInstantsPhotoURLForObject(media));
    addURL(SPKInstantsVideoURLForObject(media));

    return keys.count > 0 ? [keys copy] : nil;
}

static NSSet<NSString *> *SPKInstantsIdentityKeysForResolvedSnap(SPKInstantsResolvedSnap *snap) {
    if (!snap)
        return nil;
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    [keys unionSet:SPKInstantsIdentityKeysForMedia(snap.backingMedia) ?: [NSSet set]];
    void (^addURL)(NSURL *) = ^(NSURL *url) {
        NSString *key = SPKInstantsURLIdentityKey(url);
        if (key.length > 0)
            [keys addObject:key];
    };
    addURL(snap.sparkleMediaURL);
    addURL(snap.sparklePhotoURL);
    addURL(snap.sparkleVideoURL);
    return keys.count > 0 ? [keys copy] : nil;
}

static BOOL SPKInstantsResolvedSnapsMatch(SPKInstantsResolvedSnap *left,
                                          SPKInstantsResolvedSnap *right) {
    if (!left || !right)
        return NO;
    if (left.sourceMediaPK.length > 0 &&
        [left.sourceMediaPK isEqualToString:right.sourceMediaPK]) {
        return YES;
    }
    NSSet<NSString *> *leftKeys = SPKInstantsIdentityKeysForResolvedSnap(left);
    NSSet<NSString *> *rightKeys = SPKInstantsIdentityKeysForResolvedSnap(right);
    return leftKeys.count > 0 && rightKeys.count > 0 && [leftKeys intersectsSet:rightKeys];
}

/// Adds or upgrades one entry in the viewer-session resolution cache. Ordering comes only
/// from `sSessionMedia`; an active view fallback may reach this cache before the store or
/// service queue without rotating the expanded viewer around that active item.
static void SPKInstantsRememberResolvedSnap(SPKInstantsResolvedSnap *snap) {
    if (!sConsumptionSessionActive || !snap || !snap.sparkleMediaURL)
        return;
    if (!sSessionResolvedSnaps)
        sSessionResolvedSnaps = [NSMutableArray array];

    for (NSUInteger i = 0; i < sSessionResolvedSnaps.count; i++) {
        SPKInstantsResolvedSnap *existing = sSessionResolvedSnaps[i];
        if (!SPKInstantsResolvedSnapsMatch(existing, snap))
            continue;
        if (!existing.backingMedia && snap.backingMedia) {
            if (!snap.sourceUsername.length)
                snap.sourceUsername = existing.sourceUsername;
            sSessionResolvedSnaps[i] = snap;
        } else if (!existing.sourceUsername.length && snap.sourceUsername.length) {
            existing.sourceUsername = snap.sourceUsername;
            existing.authorResolverPath = snap.authorResolverPath;
        }
        return;
    }
    [sSessionResolvedSnaps addObject:snap];
}

static NSString *SPKInstantsObservationKeyForResolvedSnap(SPKInstantsResolvedSnap *snap) {
    if (!snap)
        return nil;
    if (snap.sourceMediaPK.length > 0)
        return [@"pk:" stringByAppendingString:snap.sourceMediaPK];

    NSArray<NSString *> *identityKeys = [SPKInstantsIdentityKeysForResolvedSnap(snap).allObjects
        sortedArrayUsingSelector:@selector(compare:)];
    NSString *identityKey = identityKeys.firstObject;
    return identityKey.length > 0 ? [@"cdn:" stringByAppendingString:identityKey] : nil;
}

static BOOL SPKInstantsResolvedSnapMatchesMedia(SPKInstantsResolvedSnap *snap, id media) {
    if (!snap || !media)
        return NO;
    NSString *mediaPK = SPKInstantsCacheMediaPK(media);
    if (snap.sourceMediaPK.length > 0 &&
        [snap.sourceMediaPK isEqualToString:mediaPK]) {
        return YES;
    }
    NSSet<NSString *> *snapKeys = SPKInstantsIdentityKeysForResolvedSnap(snap);
    NSSet<NSString *> *mediaKeys = SPKInstantsIdentityKeysForMedia(media);
    return snapKeys.count > 0 && mediaKeys.count > 0 && [snapKeys intersectsSet:mediaKeys];
}

static NSUInteger SPKInstantsInsertionIndexBeforeSuccessor(NSArray<SPKInstantsResolvedSnap *> *snaps,
                                                            NSString *successorKey) {
    if (successorKey.length > 0) {
        for (NSUInteger i = 0; i < snaps.count; i++) {
            NSString *key = SPKInstantsObservationKeyForResolvedSnap(snaps[i]);
            if ([key isEqualToString:successorKey])
                return i;
        }
    }
    return 0;
}

/// Materializes the expanded list in Instagram's session order. Resolved snaps are looked
/// up from the cache by identity, but the cache's own insertion order is never consulted.
/// The only expected cache-only entry is a view fallback whose backing media disappeared
/// before the queue was observed; position that active item from its recorded successor.
static NSMutableArray<SPKInstantsResolvedSnap *> *SPKInstantsOrderedSessionSnaps(
    SPKInstantsResolvedSnap *activeSnap,
    NSString *activeSuccessorKey) {
    NSArray<SPKInstantsResolvedSnap *> *cachedSnaps = [sSessionResolvedSnaps copy] ?: @[];
    NSMutableIndexSet *usedCacheIndexes = [NSMutableIndexSet indexSet];
    NSMutableArray<SPKInstantsResolvedSnap *> *ordered = [NSMutableArray array];

    for (id media in [sSessionMedia copy]) {
        SPKInstantsResolvedSnap *probe = SPKInstantsResolvedSnapFromMedia(media);
        if (!probe)
            continue;

        SPKInstantsResolvedSnap *resolved = probe;
        for (NSUInteger i = 0; i < cachedSnaps.count; i++) {
            if ([usedCacheIndexes containsIndex:i])
                continue;
            SPKInstantsResolvedSnap *cached = cachedSnaps[i];
            if (!SPKInstantsResolvedSnapsMatch(cached, probe))
                continue;
            resolved = cached;
            [usedCacheIndexes addIndex:i];
            break;
        }

        BOOL duplicate = NO;
        for (SPKInstantsResolvedSnap *existing in ordered) {
            if (SPKInstantsResolvedSnapsMatch(existing, resolved)) {
                duplicate = YES;
                break;
            }
        }
        if (!duplicate)
            [ordered addObject:resolved];
    }

    for (NSUInteger i = 0; i < cachedSnaps.count; i++) {
        if ([usedCacheIndexes containsIndex:i])
            continue;
        SPKInstantsResolvedSnap *cached = cachedSnaps[i];

        BOOL duplicate = NO;
        for (SPKInstantsResolvedSnap *existing in ordered) {
            if (SPKInstantsResolvedSnapsMatch(existing, cached)) {
                duplicate = YES;
                break;
            }
        }
        if (duplicate)
            continue;

        if (activeSnap && SPKInstantsResolvedSnapsMatch(cached, activeSnap)) {
            NSUInteger insertionIndex = SPKInstantsInsertionIndexBeforeSuccessor(ordered,
                                                                                 activeSuccessorKey);
            [ordered insertObject:cached atIndex:insertionIndex];
        } else {
            // No ordering evidence exists for a non-active cache-only fallback. Retaining
            // it is preferable to dropping a consumed Instant; later service observations
            // will place its backing media in the canonical ledger.
            [ordered addObject:cached];
        }
    }

    return ordered;
}

/// Finds a video player view inside a snap view.
static UIView *SPKInstantsVideoViewInSnap(UIView *snap) {
    if (!snap)
        return nil;
    id direct = SPKInstantsObjectValue(snap, @[ @"videoView", @"_videoView" ]);
    if ([direct isKindOfClass:UIView.class])
        return (UIView *)direct;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:snap];
    NSUInteger idx = 0;
    while (idx < queue.count) {
        UIView *view = queue[idx++];
        if (view.hidden || view.alpha < 0.05)
            continue;

        if (SPKInstantsIsOverlayOrPromptView(view, snap))
            continue;

        NSString *className = NSStringFromClass(view.class);
        if ([className containsString:@"IGAssetPlayerView"] || [className containsString:@"Video"])
            return view;

        for (UIView *s in view.subviews)
            [queue addObject:s];
    }
    return nil;
}

/// Extracts a video URL from an AVPlayer-like hierarchy.
static NSURL *SPKInstantsVideoURLFromPlayerLike(id playerLike, NSInteger depth) {
    if (!playerLike || depth > 4)
        return nil;
    NSURL *url = SPKURLFromValue(playerLike);
    if (url)
        return url;

    id currentItem = SPKObjectForSelector(playerLike, @"currentItem") ?: SPKKVCObject(playerLike, @"currentItem");
    if (currentItem && currentItem != playerLike) {
        id asset = SPKObjectForSelector(currentItem, @"asset") ?: SPKKVCObject(currentItem, @"asset");
        if ([asset isKindOfClass:[AVURLAsset class]])
            return ((AVURLAsset *)asset).URL;
        NSURL *assetURL = SPKURLFromValue(SPKObjectForSelector(asset, @"URL") ?: SPKKVCObject(asset, @"URL"));
        if (assetURL)
            return assetURL;
    }

    id asset = SPKObjectForSelector(playerLike, @"asset") ?: SPKKVCObject(playerLike, @"asset");
    if ([asset isKindOfClass:[AVURLAsset class]])
        return ((AVURLAsset *)asset).URL;
    NSURL *assetURL = SPKURLFromValue(SPKObjectForSelector(asset, @"URL") ?: SPKKVCObject(asset, @"URL"));
    if (assetURL)
        return assetURL;

    for (NSString *key in @[ @"player", @"avPlayer", @"queuePlayer", @"currentPlayer", @"playerController", @"playbackController", @"videoPlayer" ]) {
        id nested = SPKInstantsObjectValue(playerLike, @[ key ]);
        if (!nested || nested == playerLike)
            continue;
        url = SPKInstantsVideoURLFromPlayerLike(nested, depth + 1);
        if (url)
            return url;
    }
    return nil;
}

/// Extracts a video URL from a snap's playback hierarchy.
static NSURL *SPKInstantsVideoURLFromSnapPlayback(UIView *snap) {
    UIView *videoView = SPKInstantsVideoViewInSnap(snap);
    if (!videoView)
        return nil;
    NSURL *url = SPKInstantsVideoURLFromPlayerLike(videoView, 0);
    if (url)
        return url;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:videoView];
    NSUInteger idx = 0;
    while (idx < queue.count) {
        UIView *view = queue[idx++];
        url = SPKInstantsVideoURLFromPlayerLike(view, 0);
        if (url)
            return url;
        for (UIView *s in view.subviews)
            [queue addObject:s];
    }
    return nil;
}

/// Extracts a backing model object from a snap view (the model carries PK/username/URLs).
static id SPKInstantsBackingObjectFromView(UIView *view, NSInteger depth) {
    if (!view || depth > 3)
        return nil;
    if (SPKInstantsIsOverlayOrPromptView(view, nil))
        return nil;

    for (NSString *key in @[ @"media", @"item", @"model", @"viewModel", @"legacyViewModel", @"quickSnapInfo", @"snap", @"instantSnap" ]) {
        id value = SPKObjectForSelector(view, key);
        if (!value)
            value = SPKKVCObject(view, key);
        if (value) {
            if (SPKInstantsMediaPKForObject(value, 0).length > 0 ||
                SPKInstantsPhotoURLForObject(value) != nil ||
                SPKInstantsVideoURLForObject(value) != nil) {
                return value;
            }
        }
    }
    if (depth < 2) {
        for (UIView *subview in view.subviews) {
            if (SPKInstantsIsOverlayOrPromptView(subview, nil))
                continue;
            id result = SPKInstantsBackingObjectFromView(subview, depth + 1);
            if (result)
                return result;
        }
    }
    return nil;
}

/// Writes a UIImage to a temp file and returns a file:// URL.
static NSURL *SPKInstantsTempURLForImage(UIImage *image) {
    if (!image)
        return nil;
    NSData *data = UIImageJPEGRepresentation(image, 1.0);
    if (!data)
        return nil;
    NSString *name = [NSString stringWithFormat:@"sparkle-instant-%@.jpg", NSUUID.UUID.UUIDString];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    if (![data writeToURL:url options:NSDataWritingAtomic error:nil])
        return nil;
    return url;
}

/// Resolves a snap from a live snap view (UIView from the stack's currentImages).
/// This is the fallback path for snaps that have been removed from the service cache.
static SPKInstantsResolvedSnap *SPKInstantsResolvedSnapFromView(UIView *snap);
static NSString *SPKInstantsCurrentAuthorUsername(UIView *header);

/// The snap being displayed, found purely by looking at the view hierarchy.
///
/// Deliberately store-free: IG *pops* the displayed snap off the snap store, so the
/// store holds the ones still queued and never the one on screen. Anything that maps a
/// tracked index into the store list therefore can't see the item auto-save exists to
/// capture.
///
/// Frontmost wins. Newer viewers nest SingleSnapView below stack-owned containers, so the
/// search must cover descendants rather than only the stack's direct subviews.
static UIView *SPKInstantsFindFrontmostSnapView(UIView *container, Class singleSnapClass, UIView **fallback) {
    NSArray<UIView *> *subviews = container.subviews;
    for (NSInteger i = (NSInteger)subviews.count - 1; i >= 0; i--) {
        UIView *sub = subviews[(NSUInteger)i];
        if (sub.hidden || sub.alpha < 0.3)
            continue;

        BOOL isSnapView = (singleSnapClass && [sub isKindOfClass:singleSnapClass]) ||
                          [NSStringFromClass(sub.class) containsString:@"IGQuickSnapImmersiveViewerSingleSnapView"];
        if (isSnapView && sub.bounds.size.width >= 20 && sub.bounds.size.height >= 20) {
            CGAffineTransform t = sub.transform;
            BOOL isIdentityish = (fabs(t.a - 1.0) < 0.15 && fabs(t.d - 1.0) < 0.15 &&
                                  fabs(t.b) < 0.15 && fabs(t.c) < 0.15);
            if (isIdentityish)
                return sub;
            if (fallback && !*fallback)
                *fallback = sub;
        }

        UIView *nested = SPKInstantsFindFrontmostSnapView(sub, singleSnapClass, fallback);
        if (nested)
            return nested;
    }
    return nil;
}

static UIView *SPKInstantsActiveSnapViewInWindow(UIView *viewInHierarchy) {
    // Do not scope this to the first AnimatingSnapStackView found in the window. Instagram
    // can retain an older, empty stack alongside the live consumption viewer; the header's
    // eligibility scan still sees the real visible SingleSnapView, while resolving through
    // that stale stack yields no active media and causes the action button to hide.
    UIWindow *window = SPKInstantsWindowForHeader(viewInHierarchy);
    if (!window)
        return nil;

    Class singleSnapClass = NSClassFromString(@"_TtC40IGQuickSnapImmersiveViewerSingleSnapView40IGQuickSnapImmersiveViewerSingleSnapView");
    if (!singleSnapClass)
        singleSnapClass = NSClassFromString(@"IGQuickSnapImmersiveViewerSingleSnapView");

    UIView *fallback = nil;
    return SPKInstantsFindFrontmostSnapView(window, singleSnapClass, &fallback) ?: fallback;
}

/// Finds the store/cache media whose CDN identity matches `key` and resolves it.
///
/// The image on screen is a screen-sized candidate; its full-resolution sibling lives in
/// the store under the same filename stem. Resolving through the store therefore upgrades
/// the quality of anything identified from the view.
static SPKInstantsResolvedSnap *SPKInstantsStoreSnapMatchingIdentityKey(NSString *key) {
    if (key.length == 0)
        return nil;

    NSArray *storeMedia = SPKInstantsStoreSnapshot();
    NSArray *cacheMedia = SPKInstantsMergedMediaList();
    NSArray *fullMedia = storeMedia.count > 0 ? SPKInstantsUnionMediaLists(storeMedia, cacheMedia) : cacheMedia;

    for (id media in fullMedia) {
        NSSet<NSString *> *keys = SPKInstantsIdentityKeysForMedia(media);
        if (![keys containsObject:key])
            continue;
        SPKInstantsResolvedSnap *resolved = SPKInstantsResolvedSnapFromMedia(media);
        if (resolved) {
            resolved.resolverPath = @"window.active.store";
            return resolved;
        }
    }

    // Consumed snaps are gone from the live lists but remain in the seen-registry, which is
    // what keeps auto-save working on a re-opened viewer.
    id registryMedia = SPKInstantsMediaForIdentityKey(key);
    if (registryMedia) {
        SPKInstantsResolvedSnap *resolved = SPKInstantsResolvedSnapFromMedia(registryMedia);
        if (resolved) {
            resolved.resolverPath = @"window.active.registry";
            return resolved;
        }
    }
    return nil;
}

SPKInstantsResolvedSnap *SPKInstantsResolveActiveSnapInView(UIView *viewInHierarchy) {
    SPK_PERF_SCOPE(@"InstantsResolver.resolveActiveSnap");
    sConsumptionSessionActive = YES;
    UIView *activeView = SPKInstantsActiveSnapViewInWindow(viewInHierarchy);
    NSString *visualIdentityKey = activeView
                                      ? SPKInstantsURLIdentityKey(SPKInstantsURLForImageView(SPKInstantsImageViewInSnap(activeView)))
                                      : nil;

    // Service-list removal tracks the displayed media directly. Prefer it once available;
    // the view stack keeps its original z-order after taps, so its visually-frontmost view
    // can still be the first snap even though a later one is on screen.
    BOOL trackedMatchesView = !sTrackedActiveMedia || visualIdentityKey.length == 0 ||
                              [SPKInstantsIdentityKeysForMedia(sTrackedActiveMedia) containsObject:visualIdentityKey];
    SPKInstantsResolvedSnap *snap = (sTrackedActiveMedia && trackedMatchesView)
                                        ? SPKInstantsResolvedSnapFromMedia(sTrackedActiveMedia)
                                        : nil;
    if (sTrackedActiveMedia && !trackedMatchesView) {
        SPKLog(@"Instants", @"ignored stale removal tracker; visible key=%@ trackedPK=%@",
               visualIdentityKey, SPKInstantsCacheMediaPK(sTrackedActiveMedia) ?: @"(nil)");
    }
    if (snap)
        snap.resolverPath = @"window.active.service-removal";

    if (!activeView && !snap)
        return nil;

    // Prefer the store entry for the snap on screen: it carries the full-resolution
    // candidate list, whereas resolving from the view yields at best the displayed
    // candidate and at worst a re-encode of the render.
    if (!snap)
        snap = SPKInstantsStoreSnapMatchingIdentityKey(visualIdentityKey);
    if (!snap && activeView) {
        snap = SPKInstantsResolvedSnapFromView(activeView);
        if (snap)
            snap.resolverPath = @"window.active.view";
    }
    if (!snap)
        return nil;

    if (snap.backingMedia)
        sTrackedActiveMedia = snap.backingMedia;
    NSSet<NSString *> *mediaIdentityKeys = SPKInstantsIdentityKeysForMedia(snap.backingMedia);
    NSString *resolvedIdentityKey = [mediaIdentityKeys containsObject:visualIdentityKey]
                                        ? visualIdentityKey
                                        : [mediaIdentityKeys.allObjects sortedArrayUsingSelector:@selector(compare:)].firstObject;
    SPKInstantsNoteActiveIdentityKey(resolvedIdentityKey ?: visualIdentityKey);
    SPKLog(@"Instants", @"active-in-view resolved path=%@ key=%@",
           snap.resolverPath, (resolvedIdentityKey ?: visualIdentityKey) ?: @"(nil)");

    if (!snap.sourceUsername.length) {
        NSString *author = SPKInstantsCurrentAuthorUsername(activeView);
        if (author.length > 0) {
            snap.sourceUsername = author;
            snap.authorResolverPath = @"window.author";
        }
    }
    SPKInstantsRememberResolvedSnap(snap);
    return snap;
}

static SPKInstantsResolvedSnap *SPKInstantsResolvedSnapFromView(UIView *snap) {
    if (!snap)
        return nil;
    UIImageView *imageView = SPKInstantsImageViewInSnap(snap);
    id backingMedia = SPKInstantsBackingObjectFromView(snap, 0);
    if (!backingMedia)
        backingMedia = SPKInstantsBackingObjectFromView(imageView, 0);

    // Try model-based URL extraction first (handles most cases)
    NSURL *videoURL = SPKInstantsVideoURLForObject(backingMedia);
    NSURL *photoURL = SPKInstantsPhotoURLForObject(backingMedia);

    // Fallback: extract from live playback / imageSpecifier
    if (!videoURL)
        videoURL = SPKInstantsVideoURLFromSnapPlayback(snap);
    if (!photoURL)
        photoURL = SPKInstantsURLForImageView(imageView);
    if (!photoURL && imageView.image)
        photoURL = SPKInstantsTempURLForImage(imageView.image);

    BOOL looksVideo = NO;
    if (backingMedia)
        looksVideo = SPKInstantsObjectLooksVideo(backingMedia);
    if (!looksVideo)
        looksVideo = (SPKInstantsVideoViewInSnap(snap) != nil);
    BOOL isVideo = looksVideo && videoURL != nil;

    NSURL *mediaURL = isVideo ? videoURL : (photoURL ?: videoURL);
    if (!mediaURL)
        return nil;

    NSString *username = backingMedia ? SPKUsernameFromMediaObject(backingMedia) : nil;
    NSString *pk = backingMedia ? SPKInstantsMediaPKForObject(backingMedia, 0) : nil;
    NSDate *postedDate = backingMedia ? SPKInstantsPostedDateForObject(backingMedia, 0) : nil;

    // A snap view has no backing media, so this path normally yields no PK — which would
    // make de-duplication key this snap by URL while the live resolve keyed it by PK, and
    // the Gallery would take a second copy. Recover the PK by CDN identity when we have seen
    // this snap earlier in the app session.
    if (pk.length == 0) {
        NSString *identityKey = SPKInstantsURLIdentityKey(photoURL ?: videoURL);
        pk = SPKInstantsPKForIdentityKey(identityKey);
        if (pk.length > 0)
            SPKLog(@"Instants", @"view snap adopted pk=%@ from identity %@", pk, identityKey);
    }

    SPKInstantsResolvedSnap *resolved = [[SPKInstantsResolvedSnap alloc] init];
    resolved.sourceUsername = username;
    resolved.sourceMediaPK = pk;
    resolved.importPostedDate = postedDate;
    resolved.sparkleIsVideo = isVideo;
    resolved.sparkleMediaURL = mediaURL;
    resolved.sparklePhotoURL = photoURL;
    resolved.sparkleVideoURL = isVideo ? videoURL : nil;
    resolved.sourceMediaURLString = mediaURL.absoluteString;
    resolved.backingMedia = backingMedia;
    resolved.resolverPath = @"view";
    return resolved;
}

/// Resolves snaps from the live stack view's currentImages array.
/// This is the fallback when the service cache is empty (all snaps have been "seen").
static NSArray<SPKInstantsResolvedSnap *> *SPKInstantsResolveFromStackView(UIView *header, NSInteger *activeIndexOut) {
    UIView *stackView = SPKInstantsSnapStackViewForHeader(header);
    if (!stackView)
        return nil;

    // Read currentImages directly from the stack view (it has its own copy, separate from state)
    NSArray *currentImages = nil;
    @try {
        currentImages = SPKArrayFromCollection([stackView valueForKey:@"currentImages"]);
    } @catch (__unused NSException *e) {
    }
    if (!currentImages.count) {
        currentImages = SPKArrayFromCollection(SPKInstantsObjectIvarValue(stackView, @"currentImages"));
    }
    if (currentImages.count == 0)
        return nil;

    // Use the hook-based tracker for active index
    NSInteger rawIndex = SPKInstantsActiveIndex(stackView);
    if (activeIndexOut)
        *activeIndexOut = rawIndex;

    // Try to get viewModel items from the state if still accessible (may work early in session)
    NSArray *modelItems = nil;
    id state = SPKInstantsObjectValue(stackView, @[ @"state" ]);
    if (state && [state isKindOfClass:NSObject.class]) {
        id viewModel = SPKInstantsObjectValue(state, @[ @"viewModel" ]);
        modelItems = SPKArrayFromCollection(viewModel);
        if (!modelItems.count) {
            modelItems = SPKArrayFromCollection(SPKInstantsObjectValue(viewModel,
                                                                       @[ @"items", @"medias", @"media", @"snaps", @"quickSnaps", @"timeOrderedQuicksnaps", @"viewModels", @"children" ]));
        }
    }

    // Try model items first (they carry proper URLs/metadata)
    if (modelItems.count > 0) {
        NSMutableArray<SPKInstantsResolvedSnap *> *snaps = [NSMutableArray arrayWithCapacity:modelItems.count];
        for (id item in modelItems) {
            SPKInstantsResolvedSnap *snap = SPKInstantsResolvedSnapFromMedia(item);
            if (snap) {
                snap.resolverPath = @"stack.model";
                [snaps addObject:snap];
            }
        }
        if (snaps.count > 0) {
            SPKLog(@"Instants", @"stack model fallback: %lu snaps from viewModel", (unsigned long)snaps.count);
            return snaps;
        }
    }

    // Fallback: resolve from the view layer (currentImages are UIViews)
    NSMutableArray<SPKInstantsResolvedSnap *> *snaps = [NSMutableArray arrayWithCapacity:currentImages.count];
    for (id image in currentImages) {
        SPKInstantsResolvedSnap *resolved = nil;
        if ([image isKindOfClass:UIView.class]) {
            resolved = SPKInstantsResolvedSnapFromView((UIView *)image);
        }
        if (!resolved) {
            // The item might itself be a media model object, not a view
            resolved = SPKInstantsResolvedSnapFromMedia(image);
            if (resolved)
                resolved.resolverPath = @"stack.image.model";
        }
        if (resolved)
            [snaps addObject:resolved];
    }

    if (snaps.count > 0) {
        SPKLog(@"Instants", @"stack view fallback: %lu snaps from currentImages", (unsigned long)snaps.count);
    }
    return snaps.count > 0 ? snaps : nil;
}

/// Returns the username of the currently-visible author from the consumption author text view.
static NSString *SPKInstantsCurrentAuthorUsername(UIView *header) {
    UIWindow *window = SPKInstantsWindowForHeader(header);
    if (!window)
        return nil;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    NSUInteger idx = 0;
    while (idx < queue.count) {
        UIView *view = queue[idx++];
        if (view.hidden || view.alpha < 0.05) {
            for (UIView *s in view.subviews)
                [queue addObject:s];
            continue;
        }
        NSString *className = NSStringFromClass(view.class);
        if ([className containsString:@"IGQuickSnapConsumptionAuthorTextView"]) {
            // Try currentUsername selector/KVC
            id currentUsername = SPKObjectForSelector(view, @"currentUsername") ?: SPKKVCObject(view, @"currentUsername");
            NSString *username = SPKStringFromValue(currentUsername);
            if (username.length > 0 && username.length <= 30)
                return username;
            // Try usernameLabel
            id label = SPKObjectForSelector(view, @"usernameLabel") ?: SPKKVCObject(view, @"usernameLabel");
            if (!label)
                label = [SPKUtils getIvarForObj:view name:"usernameLabel"];
            if ([label isKindOfClass:UILabel.class]) {
                username = ((UILabel *)label).text;
                if ([username hasPrefix:@"@"])
                    username = [username substringFromIndex:1];
                if (username.length > 0 && username.length <= 30)
                    return username;
            }
        }
        for (UIView *s in view.subviews)
            [queue addObject:s];
    }
    return nil;
}

NSString *SPKInstantsResolveCurrentAuthorUsername(UIView *viewInHierarchy) {
    return SPKInstantsCurrentAuthorUsername(viewInHierarchy);
}

#pragma mark - Store-Backed Full List

/// Snapshot of the store's time-ordered list, captured on first resolve during a
/// consumption session. The live store mutates (removes snaps as they're marked seen),
/// so we freeze it once to guarantee the topmost snap stays available throughout viewing.
static NSArray *sStoreSnapshot = nil;
/// Reset token — cleared when the viewer disappears so a fresh snapshot is taken next time.
static BOOL sStoreSnapshotTaken = NO;

/// Captures a snapshot of the store's full list if we haven't already this session.
/// Returns the snapshot (immutable) or nil if the store isn't reachable.
static NSArray *SPKInstantsStoreSnapshot(void) {
    if (sStoreSnapshotTaken && sStoreSnapshot)
        return sStoreSnapshot;

    id service = sQuickSnapServiceInstance;
    if (!service) {
        service = SPKInstantsLocateQuickSnapService();
        if (service)
            sQuickSnapServiceInstance = service;
    }
    if (!service) {
        SPKLog(@"Instants", @"store: no service instance (hooks not fired & session lookup failed)");
        return sStoreSnapshot; // may be nil
    }

    id store = [SPKUtils getIvarForObj:service name:"quickSnapStore"];
    if (!store)
        store = SPKInstantsSwiftIvarValue(service, @"quickSnapStore");
    if (!store) {
        SPKLog(@"Instants", @"store: quickSnapStore ivar nil on service=%@", NSStringFromClass([service class]));
        return sStoreSnapshot;
    }

    id timeOrdered = [SPKUtils getIvarForObj:store name:"timeOrderedQuicksnaps"];
    if (!timeOrdered)
        timeOrdered = SPKInstantsSwiftIvarValue(store, @"timeOrderedQuicksnaps");
    NSArray *full = SPKArrayFromCollection(timeOrdered);

    if (full.count > 0) {
        // Index everything the store still holds, so these snaps stay resolvable after IG
        // drops them on consumption.
        SPKInstantsRegisterMediaList(full);
        // Take the snapshot: copy the array so mutations to the store don't affect us.
        if (!sStoreSnapshotTaken) {
            sStoreSnapshot = [full copy];
            sStoreSnapshotTaken = YES;
            SPKLog(@"Instants", @"store snapshot taken count=%lu", (unsigned long)sStoreSnapshot.count);
        } else if (full.count > sStoreSnapshot.count) {
            // Store grew (new snaps arrived during viewing) — expand our snapshot
            sStoreSnapshot = [full copy];
            SPKLog(@"Instants", @"store snapshot expanded count=%lu", (unsigned long)sStoreSnapshot.count);
        }
    }

    return sStoreSnapshot;
}

/// Resets the snapshot so the next consumption session takes a fresh one.
void SPKInstantsResetStoreSnapshot(void) {
    sStoreSnapshot = nil;
    sStoreSnapshotTaken = NO;
}

/// Returns `primary` plus any items of `secondary` whose media PK isn't already present.
/// Order: primary first (store's full time-ordered list), then new peek-preview items.
static NSArray *SPKInstantsUnionMediaLists(NSArray *primary, NSArray *secondary) {
    if (!primary.count)
        return secondary ?: @[];
    if (!secondary.count)
        return primary;

    NSMutableOrderedSet *seenPKs = [NSMutableOrderedSet orderedSet];
    NSMutableArray *merged = [NSMutableArray arrayWithCapacity:primary.count + secondary.count];
    for (id media in primary) {
        NSString *pk = SPKInstantsCacheMediaPK(media);
        if (pk.length > 0)
            [seenPKs addObject:pk];
        [merged addObject:media];
    }
    for (id media in secondary) {
        NSString *pk = SPKInstantsCacheMediaPK(media);
        if (pk.length > 0 && [seenPKs containsObject:pk])
            continue;
        if (pk.length > 0)
            [seenPKs addObject:pk];
        [merged addObject:media];
    }
    return [merged copy];
}

/// Determines the active snap's PK by reading the stack view's currently-displayed view
/// and extracting its backing model PK. Uses the hook-based tracker for the active index.
static NSString *SPKInstantsActiveSnapPKFromStackView(UIView *stackView) {
    if (!stackView)
        return nil;

    NSInteger displayIndex = SPKInstantsActiveIndex(stackView);

    // Read currentImages from the stack view directly
    NSArray *currentImages = nil;
    @try {
        currentImages = SPKArrayFromCollection([stackView valueForKey:@"currentImages"]);
    } @catch (__unused NSException *e) {
    }
    if (!currentImages.count) {
        currentImages = SPKArrayFromCollection(SPKInstantsObjectIvarValue(stackView, @"currentImages"));
    }

    if (displayIndex < 0 || displayIndex >= (NSInteger)currentImages.count) {
        // Try visual fallback
        NSInteger visualIdx = SPKInstantsVisualActiveIndex(stackView, currentImages);
        if (visualIdx >= 0)
            displayIndex = visualIdx;
    }

    if (displayIndex < 0 || displayIndex >= (NSInteger)currentImages.count)
        return nil;
    id activeView = currentImages[(NSUInteger)displayIndex];

    // Extract the backing media PK from the active view
    if ([activeView isKindOfClass:UIView.class]) {
        id backingMedia = SPKInstantsBackingObjectFromView((UIView *)activeView, 0);
        if (backingMedia) {
            NSString *pk = SPKInstantsMediaPKForObject(backingMedia, 0);
            if (pk.length > 0)
                return pk;
        }
    }

    // Fallback: try the state's viewModel items array at the same index (may work early)
    id state = nil;
    @try {
        state = [stackView valueForKey:@"state"];
    } @catch (__unused NSException *e) {
    }
    if (state && [state isKindOfClass:NSObject.class]) {
        id viewModel = nil;
        @try {
            viewModel = [state valueForKey:@"viewModel"];
        } @catch (__unused NSException *e) {
        }
        if (!viewModel) {
            @try {
                viewModel = [state valueForKey:@"_viewModel"];
            } @catch (__unused NSException *e) {
            }
        }
        NSArray *modelItems = SPKArrayFromCollection(viewModel);
        if (!modelItems.count) {
            modelItems = SPKArrayFromCollection(SPKInstantsObjectValue(viewModel,
                                                                       @[ @"items", @"medias", @"media", @"snaps", @"quickSnaps", @"timeOrderedQuicksnaps", @"viewModels", @"children" ]));
        }
        if (displayIndex < (NSInteger)modelItems.count) {
            NSString *pk = SPKInstantsMediaPKForObject(modelItems[(NSUInteger)displayIndex], 0);
            if (pk.length > 0)
                return pk;
        }
    }

    return nil;
}

/// Finds the index of a snap with the given PK in the resolved snaps array.
/// Returns -1 if not found.
static NSInteger SPKInstantsFindSnapIndexByPK(NSArray<SPKInstantsResolvedSnap *> *snaps, NSString *pk) {
    if (!pk.length || !snaps.count)
        return -1;
    for (NSUInteger i = 0; i < snaps.count; i++) {
        if ([snaps[i].sourceMediaPK isEqualToString:pk])
            return (NSInteger)i;
    }
    return -1;
}

#pragma mark - Main Resolution Entry Point

/// Primary resolution entry point. Called at action execution time only.
/// Builds the viewer-session snap list, determines the active index,
/// and returns a complete SPKInstantsResolverResult.
/// When no service media is available, falls back to the live stack view.
SPKInstantsResolverResult *SPKInstantsResolveForHeader(UIView *header, NSString *reason) {
    SPK_PERF_SCOPE(@"InstantsResolver.resolveForHeader");
    sConsumptionSessionActive = YES;
    // Seed the session from whatever Instagram exposed before/while opening the viewer,
    // then keep appending later service updates. These arrays are cleared on genuine exit.
    SPKInstantsAppendSessionMedia(SPKInstantsStoreSnapshot());
    SPKInstantsAppendSessionMedia(SPKInstantsMergedMediaList());
    SPKInstantsAppendSessionMedia(SPKInstantsCurrentServiceMediaList());
    // Architecture:
    //   - The BULK list accumulates the displayed snap and every service item discovered
    //     during this viewer session, including items already tapped away.
    //   - The ACTIVE snap comes from the media removed by the latest live service update.
    //     The visible SingleSnapView is only the initial/fallback identity source because
    //     Instagram keeps the first view frontmost in the static subview ordering.
    //   - We map the active media into the bulk list by PK so the active index is accurate;
    //     if that fails we still return the active snap via `activeSnap`.
    UIView *stackView = SPKInstantsSnapStackViewForHeader(header);

    // --- A. Build the display list (bounded view window) for active-snap resolution ---
    id state = stackView ? SPKInstantsObjectValue(stackView, @[ @"state" ]) : nil;
    if (state && ![state isKindOfClass:NSObject.class])
        state = nil;

    NSArray *currentImages = nil;
    NSArray *modelItems = nil;

    if (stackView) {
        @try {
            currentImages = SPKArrayFromCollection([stackView valueForKey:@"currentImages"]);
        } @catch (__unused NSException *e) {
        }
        if (!currentImages.count) {
            currentImages = SPKArrayFromCollection(SPKInstantsObjectIvarValue(stackView, @"currentImages"));
        }
        if (!currentImages.count) {
            Class singleSnapClass = NSClassFromString(@"_TtC40IGQuickSnapImmersiveViewerSingleSnapView40IGQuickSnapImmersiveViewerSingleSnapView");
            if (!singleSnapClass)
                singleSnapClass = NSClassFromString(@"IGQuickSnapImmersiveViewerSingleSnapView");
            if (singleSnapClass) {
                NSMutableArray *snapViews = [NSMutableArray array];
                for (UIView *sub in stackView.subviews) {
                    if ([sub isKindOfClass:singleSnapClass])
                        [snapViews addObject:sub];
                }
                if (snapViews.count > 0) {
                    currentImages = [snapViews copy];
                    SPKLog(@"Instants", @"currentImages reconstructed from subviews: %lu", (unsigned long)currentImages.count);
                }
            }
        }
    }

    if (state) {
        id viewModel = SPKInstantsObjectValue(state, @[ @"viewModel" ]);
        modelItems = SPKArrayFromCollection(viewModel);
        if (!modelItems.count) {
            modelItems = SPKArrayFromCollection(SPKInstantsObjectValue(viewModel,
                                                                       @[ @"items", @"medias", @"media", @"snaps", @"quickSnaps", @"timeOrderedQuicksnaps", @"viewModels", @"children" ]));
        }
    }

    // Determine which display-list slot is active (topmost visible view).
    if (stackView && !sTrackedIndexValid)
        SPKInstantsInitTracking(stackView);
    NSInteger displayIndex = stackView ? SPKInstantsActiveIndex(stackView) : 0;

    // The snap stack's own notion of the active slot. This is the authoritative value, but
    // it lives in a Swift `Int` stored property that neither KVC nor object_getIvar can
    // read, so it needs an offset read. Logged next to the derived indices below so a
    // single device session settles which list it indexes (the full snap list, or the
    // recycled `currentImages` view window).
    NSInteger stateIndex = state ? SPKInstantsIntegerIvarValue(state, @"currentlyDisplayingQuickSnapIndex", NSNotFound) : NSNotFound;

    // Identity of the snap actually on screen, taken from the real CDN URL its image view
    // loaded. This is what lets the active snap be matched back to its full-resolution
    // entry in the store list instead of being resolved (and downloaded) from the view.
    UIView *activeSnapView = nil;
    if (displayIndex >= 0 && displayIndex < (NSInteger)currentImages.count) {
        id candidate = currentImages[(NSUInteger)displayIndex];
        if ([candidate isKindOfClass:UIView.class])
            activeSnapView = (UIView *)candidate;
    }
    if (!activeSnapView)
        activeSnapView = SPKInstantsActiveSnapViewInWindow(header);

    NSString *activeViewURLKey = nil;
    if (activeSnapView) {
        UIImageView *activeImageView = SPKInstantsImageViewInSnap(activeSnapView);
        activeViewURLKey = SPKInstantsURLIdentityKey(SPKInstantsURLForImageView(activeImageView));
    }

    // Resolve the active media from signals that share identity with the visible view.
    // `displayIndex` addresses the recycled view window, not necessarily `modelItems`: the
    // device log showed 4 currentImages and 9 modelItems, where using slot 3 against the
    // model list selected item 3 even though the visible CDN identity belonged to item 0.
    SPKInstantsResolvedSnap *activeSnap = nil;
    NSString *activePK = nil;
    BOOL trackedMatchesView = !sTrackedActiveMedia || activeViewURLKey.length == 0 ||
                              [SPKInstantsIdentityKeysForMedia(sTrackedActiveMedia) containsObject:activeViewURLKey];
    if (sTrackedActiveMedia && trackedMatchesView) {
        activeSnap = SPKInstantsResolvedSnapFromMedia(sTrackedActiveMedia);
        if (activeSnap) {
            activeSnap.resolverPath = @"active.service-removal";
            activePK = activeSnap.sourceMediaPK;
        }
    }
    if (sTrackedActiveMedia && !trackedMatchesView) {
        SPKLog(@"Instants", @"ignored stale removal tracker; visible key=%@ trackedPK=%@",
               activeViewURLKey, SPKInstantsCacheMediaPK(sTrackedActiveMedia) ?: @"(nil)");
    }

    // The visible CDN identity maps directly into the full store/session list and remains
    // valid even when the view window and model list have different sizes.
    if (!activeSnap && activeViewURLKey.length > 0) {
        activeSnap = SPKInstantsStoreSnapMatchingIdentityKey(activeViewURLKey);
        if (activeSnap)
            activePK = activeSnap.sourceMediaPK;
    }

    // Positional model lookup is safe only when both arrays describe the same slots.
    BOOL modelSharesDisplayIndexSpace = modelItems.count > 0 &&
                                        modelItems.count == currentImages.count;
    if (!activeSnap && modelSharesDisplayIndexSpace &&
        displayIndex >= 0 && displayIndex < (NSInteger)modelItems.count) {
        activeSnap = SPKInstantsResolvedSnapFromMedia(modelItems[(NSUInteger)displayIndex]);
        if (activeSnap) {
            activeSnap.resolverPath = @"active.model";
            activePK = activeSnap.sourceMediaPK;
        }
    }
    if (!activeSnap && activeSnapView) {
        activeSnap = SPKInstantsResolvedSnapFromView(activeSnapView);
        if (activeSnap)
            activeSnap.resolverPath = @"active.view";
        if (activeSnap)
            activePK = activeSnap.sourceMediaPK;
    }

    SPKLog(@"Instants", @"active-index probe: visual=%ld state=%@ tracked=%ld(valid=%d) "
                        @"modelItems=%lu currentImages=%lu activeView=%@ viewURLKey=%@",
           (long)displayIndex,
           stateIndex == NSNotFound ? @"(unreadable)" : @(stateIndex).stringValue,
           (long)sTrackedActiveIndex, (int)sTrackedIndexValid,
           (unsigned long)modelItems.count, (unsigned long)currentImages.count,
           activeSnapView ? NSStringFromClass(activeSnapView.class) : @"(nil)",
           activeViewURLKey ?: @"(nil)");

    // --- B. Build the BULK list from this viewer session ---
    // The media ledger owns order. The active snap only supplies selection and may upgrade
    // a matching cached entry; resolving it first must never rotate the expanded list.
    BOOL activeMatchesTrackedOrder = activeSnap && sTrackedActiveMedia &&
                                     SPKInstantsResolvedSnapMatchesMedia(activeSnap,
                                                                        sTrackedActiveMedia);
    NSString *activeOrderSuccessorKey = activeMatchesTrackedOrder
                                            ? sTrackedActiveSuccessorKey
                                            : nil;
    if (activeSnap.backingMedia) {
        SPKInstantsInsertSessionMedia(activeSnap.backingMedia,
                                      activeOrderSuccessorKey);
    }
    for (id media in [sSessionMedia copy]) {
        SPKInstantsResolvedSnap *snap = SPKInstantsResolvedSnapFromMedia(media);
        if (snap) {
            snap.resolverPath = @"session.service";
            SPKInstantsRememberResolvedSnap(snap);
        }
    }
    SPKInstantsRememberResolvedSnap(activeSnap);

    NSMutableArray<SPKInstantsResolvedSnap *> *snaps =
        SPKInstantsOrderedSessionSnaps(activeSnap, activeOrderSuccessorKey);
    NSMutableArray *snapIdentityKeys = [NSMutableArray arrayWithCapacity:snaps.count];
    for (SPKInstantsResolvedSnap *snap in snaps) {
        NSSet<NSString *> *keys = SPKInstantsIdentityKeysForResolvedSnap(snap);
        [snapIdentityKeys addObject:keys ?: (id)NSNull.null];
    }

    // --- C. Map active snap into the bulk list and finalize ---
    if (snaps.count > 0 || activeSnap) {
        NSInteger activeIndex = -1;

        // The active VIEW frequently exposes no PK on the first interaction (its backing
        // media isn't wired up yet, and the resolved URL is a temp/derived one that won't
        // match the store's CDN URL). The model object at the same display slot does carry
        // a PK, so use it to map the active snap into the store list reliably.
        NSString *activeModelPK = nil;
        if (displayIndex >= 0 && displayIndex < (NSInteger)modelItems.count) {
            activeModelPK = SPKInstantsMediaPKForObject(modelItems[(NSUInteger)displayIndex], 0);
        }

        // Try PK match first (most reliable) — active PK, then model PK.
        if (activePK.length > 0) {
            activeIndex = SPKInstantsFindSnapIndexByPK(snaps, activePK);
        }
        if (activeIndex < 0 && activeModelPK.length > 0) {
            activeIndex = SPKInstantsFindSnapIndexByPK(snaps, activeModelPK);
        }

        NSString *matchPath = activeIndex >= 0 ? @"pk" : nil;

        // PK match failed — on IG 439 it always does, because the snap view carries no
        // backing media at all and the model list is unreadable. Match instead on the CDN
        // identity of the image actually on screen: the displayed (screen-sized) candidate
        // and the full-resolution candidate share a filename stem, so this recognises the
        // active snap as an entry that is *already in the list* rather than a new item.
        if (activeIndex < 0 && activeViewURLKey.length > 0) {
            for (NSUInteger i = 0; i < snaps.count; i++) {
                id keys = snapIdentityKeys[i];
                if (keys == (id)NSNull.null)
                    continue;
                if ([(NSSet *)keys containsObject:activeViewURLKey]) {
                    activeIndex = (NSInteger)i;
                    matchPath = @"cdn-identity";
                    break;
                }
            }
        }

        // No match. The snap on screen has been consumed and dropped from every service
        // list, so it is genuinely absent from the bulk list rather than misindexed.
        //
        // Positional fallbacks are NOT valid here: `displayIndex` addresses the recycled
        // view window (4 slots) and `stateIndex` the stack's own list, neither of which is
        // the store list. Mapping one onto the other silently selects an unrelated snap.
        // Instead, recover the media from the seen-registry (full metadata and resolution)
        // and fall back to the view only if even that misses.
        if (activeIndex < 0) {
            SPKInstantsResolvedSnap *recovered = activeSnap;
            if (recovered)
                matchPath = recovered.resolverPath ?: @"active-direct";

            id registryMedia = recovered.backingMedia ?: SPKInstantsMediaForIdentityKey(activeViewURLKey);
            if (!recovered && registryMedia) {
                recovered = SPKInstantsResolvedSnapFromMedia(registryMedia);
                if (recovered) {
                    recovered.resolverPath = @"active.registry";
                    matchPath = @"seen-registry";
                }
            }

            if (!recovered && activeSnapView) {
                recovered = SPKInstantsResolvedSnapFromView(activeSnapView);
                if (recovered) {
                    recovered.resolverPath = @"active.view";
                    matchPath = @"view-fallback";
                }
            }

            // This is only a last-resort recovery; normal active snaps were already added
            // to the ordered session list above.
            if (recovered && recovered.sparkleMediaURL) {
                if (recovered.backingMedia) {
                    SPKInstantsInsertSessionMedia(recovered.backingMedia,
                                                  activeOrderSuccessorKey);
                }
                NSUInteger insertionIndex = SPKInstantsInsertionIndexBeforeSuccessor(
                    snaps,
                    activeOrderSuccessorKey);
                [snaps insertObject:recovered atIndex:insertionIndex];
                [snapIdentityKeys insertObject:SPKInstantsIdentityKeysForResolvedSnap(recovered) ?: (id)NSNull.null
                                       atIndex:insertionIndex];
                activeIndex = (NSInteger)insertionIndex;
                activeSnap = recovered;
                SPKInstantsRememberResolvedSnap(recovered);
            }
        }

        if (activeIndex < 0) {
            SPKLog(@"Instants", @"resolve reason=%@ active media unavailable; refusing index-0 fallback",
                   reason ?: @"unknown");
            return nil;
        }
        if (activeIndex >= (NSInteger)snaps.count)
            activeIndex = (NSInteger)snaps.count - 1;

        // Adopt the matched session entry as the active snap. When a full media model is
        // available it carries the complete resolution candidates.
        if (activeIndex < (NSInteger)snaps.count) {
            SPKInstantsResolvedSnap *sessionSnap = snaps[(NSUInteger)activeIndex];
            if (sessionSnap && sessionSnap.sparkleMediaURL) {
                if (!sessionSnap.sourceUsername.length && activeSnap.sourceUsername.length) {
                    sessionSnap.sourceUsername = activeSnap.sourceUsername;
                }
                activeSnap = sessionSnap;
            }
        }

        if (activeSnap.backingMedia)
            sTrackedActiveMedia = activeSnap.backingMedia;
        NSSet<NSString *> *activeIdentityKeys = SPKInstantsIdentityKeysForMedia(activeSnap.backingMedia);
        NSString *resolvedIdentityKey = [activeIdentityKeys containsObject:activeViewURLKey]
                                            ? activeViewURLKey
                                            : [activeIdentityKeys.allObjects sortedArrayUsingSelector:@selector(compare:)].firstObject;
        SPKInstantsNoteActiveIdentityKey(resolvedIdentityKey ?: activeViewURLKey);

        // Fill the username from the visible author label if the model had none.
        if (activeSnap && !activeSnap.sourceUsername.length) {
            NSString *visibleAuthor = SPKInstantsCurrentAuthorUsername(header);
            if (visibleAuthor.length > 0) {
                activeSnap.sourceUsername = visibleAuthor;
                activeSnap.authorResolverPath = @"authorTextView";
            }
        }

        SPKLog(@"Instants", @"active match=%@ index=%ld viewURLKey=%@",
               matchPath ?: @"(none)", (long)activeIndex, activeViewURLKey ?: @"(nil)");

        SPKInstantsResolverResult *result = [[SPKInstantsResolverResult alloc] init];
        result.snaps = [snaps copy];
        result.activeIndex = activeIndex;
        result.activeSnap = activeSnap;
        result.path = @"session+active";

        SPKLog(@"Instants", @"resolve reason=%@ path=session+active order=session-media count=%lu activeIndex=%ld activePK=%@ displayIdx=%ld",
               reason ?: @"unknown", (unsigned long)snaps.count, (long)activeIndex,
               activePK ?: @"(nil)", (long)displayIndex);
        for (NSUInteger i = 0; i < snaps.count; i++) {
            SPKInstantsResolvedSnap *s = snaps[i];
            SPKLog(@"Instants", @"  [%lu]%@ %@ user=%@ pk=%@ posted=%@ url=%@",
                   (unsigned long)i, (NSInteger)i == activeIndex ? @"*" : @" ",
                   s.sparkleIsVideo ? @"video" : @"photo",
                   s.sourceUsername ?: @"(nil)", s.sourceMediaPK ?: @"(nil)",
                   s.importPostedDate ? @"YES" : @"NO",
                   s.sparkleMediaURL ? @"YES" : @"NO");
        }
        return result;
    }

    // --- D. Store empty — fall back to the display list alone ---
    NSUInteger displayCount = modelItems.count > 0 ? modelItems.count : currentImages.count;
    if (displayCount > 0) {
        NSMutableArray<SPKInstantsResolvedSnap *> *displaySnaps = [NSMutableArray arrayWithCapacity:displayCount];
        for (NSUInteger i = 0; i < displayCount; i++) {
            SPKInstantsResolvedSnap *resolved = nil;
            if (i < modelItems.count) {
                resolved = SPKInstantsResolvedSnapFromMedia(modelItems[i]);
                if (resolved)
                    resolved.resolverPath = @"display.model";
            }
            if (!resolved && i < currentImages.count) {
                id imageItem = currentImages[i];
                if ([imageItem isKindOfClass:UIView.class]) {
                    resolved = SPKInstantsResolvedSnapFromView((UIView *)imageItem);
                }
                if (!resolved) {
                    resolved = SPKInstantsResolvedSnapFromMedia(imageItem);
                    if (resolved)
                        resolved.resolverPath = @"display.image.model";
                }
            }
            if (resolved)
                [displaySnaps addObject:resolved];
        }
        if (displaySnaps.count > 0) {
            NSInteger activeIndex = displayIndex;
            if (activeIndex >= (NSInteger)displaySnaps.count)
                activeIndex = (NSInteger)displaySnaps.count - 1;
            if (activeIndex < 0)
                activeIndex = 0;
            SPKInstantsResolvedSnap *displayActive = activeSnap ?: displaySnaps[(NSUInteger)activeIndex];

            if (displayActive.backingMedia)
                sTrackedActiveMedia = displayActive.backingMedia;
            NSSet<NSString *> *displayIdentityKeys = SPKInstantsIdentityKeysForMedia(displayActive.backingMedia);
            NSString *resolvedIdentityKey = [displayIdentityKeys containsObject:activeViewURLKey]
                                                ? activeViewURLKey
                                                : [displayIdentityKeys.allObjects sortedArrayUsingSelector:@selector(compare:)].firstObject;
            SPKInstantsNoteActiveIdentityKey(resolvedIdentityKey ?: activeViewURLKey);

            // This branch resolves entirely from views, so there is no model to carry an
            // author. Without the visible author label the snap has no username and the
            // download filename degrades to a bare "media_instants_...". The store path
            // does this too — it must happen here as well, not only there.
            if (displayActive && !displayActive.sourceUsername.length) {
                NSString *visibleAuthor = SPKInstantsCurrentAuthorUsername(header);
                if (visibleAuthor.length > 0) {
                    displayActive.sourceUsername = visibleAuthor;
                    displayActive.authorResolverPath = @"authorTextView";
                }
            }

            SPKInstantsResolverResult *result = [[SPKInstantsResolverResult alloc] init];
            result.snaps = [displaySnaps copy];
            result.activeIndex = activeIndex;
            result.activeSnap = displayActive;
            result.path = @"display-only";
            SPKLog(@"Instants", @"resolve reason=%@ path=display-only count=%lu activeIndex=%ld user=%@ pk=%@",
                   reason ?: @"unknown", (unsigned long)displaySnaps.count, (long)activeIndex,
                   displayActive.sourceUsername ?: @"(nil)", displayActive.sourceMediaPK ?: @"(nil)");
            return result;
        }
    }

    // --- E. All paths failed ---
    SPKLog(@"Instants", @"resolve reason=%@ path=NONE count=0", reason ?: @"unknown");
    return nil;
}

#pragma mark - Hook Installation

typedef void (*SPKInstantsServiceUpdateIMP)(id, SEL, id, id, BOOL);
static SPKInstantsServiceUpdateIMP orig_instantsServiceListenerUpdate = NULL;
static SPKInstantsServiceUpdateIMP orig_instantsBadgeManagerServiceUpdate = NULL;

typedef id (*SPKInstantsServiceSnapsIMP)(id, SEL);
static SPKInstantsServiceSnapsIMP orig_instantsServiceAvailableTimeOrderedSnaps = NULL;
static SPKInstantsServiceSnapsIMP orig_instantsServiceSidePeekPreviewMedias = NULL;

static void replaced_instantsServiceListenerUpdate(id self, SEL _cmd, id timeOrdered, id peekPreview, BOOL didReceive) {
    if (orig_instantsServiceListenerUpdate)
        orig_instantsServiceListenerUpdate(self, _cmd, timeOrdered, peekPreview, didReceive);
    SPKInstantsCacheServiceSnaps(timeOrdered, peekPreview, @"listener");
}

static void replaced_instantsBadgeManagerServiceUpdate(id self, SEL _cmd, id timeOrdered, id peekPreview, BOOL didReceive) {
    if (orig_instantsBadgeManagerServiceUpdate)
        orig_instantsBadgeManagerServiceUpdate(self, _cmd, timeOrdered, peekPreview, didReceive);
    SPKInstantsCacheServiceSnaps(timeOrdered, peekPreview, @"badgeManager");
}

static id replaced_instantsServiceAvailableTimeOrderedSnaps(id self, SEL _cmd) {
    sQuickSnapServiceInstance = self;
    id result = orig_instantsServiceAvailableTimeOrderedSnaps ? orig_instantsServiceAvailableTimeOrderedSnaps(self, _cmd) : nil;
    SPKInstantsCacheServiceSnaps(result, nil, @"service.timeOrdered");
    return result;
}

static id replaced_instantsServiceSidePeekPreviewMedias(id self, SEL _cmd) {
    sQuickSnapServiceInstance = self;
    id result = orig_instantsServiceSidePeekPreviewMedias ? orig_instantsServiceSidePeekPreviewMedias(self, _cmd) : nil;
    SPKInstantsCacheServiceSnaps(nil, result, @"service.peekPreview");
    return result;
}

static void SPKInstantsHookInstanceMethod(const char *className, SEL selector, IMP replacement, IMP *original) {
    Class cls = objc_getClass(className);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!cls || !method) {
        SPKLog(@"Instants", @"Missing hook target %s %@", className, NSStringFromSelector(selector));
        return;
    }
    MSHookMessageEx(cls, selector, replacement, original);
}

// Consumption VC lifecycle hooks. Capture before Instagram marks the initial snap seen,
// then clear only when the viewer genuinely closes.
typedef void (*SPKInstantsVCLifecycleIMP)(id, SEL, BOOL);
static SPKInstantsVCLifecycleIMP orig_consumptionVCViewWillAppear = NULL;
typedef SPKInstantsVCLifecycleIMP SPKInstantsVCDisappearIMP;
static SPKInstantsVCDisappearIMP orig_consumptionVCViewDidDisappear = NULL;

/// Clears every resolver structure whose contents belong to one consumption session.
/// The identity-to-PK map and retained service intentionally survive an ordinary viewer
/// close, but both are account-owned and must be discarded when Instagram switches users.
static void SPKInstantsResetResolverState(BOOL accountBoundary, NSString *reason) {
    SPKInstantsResetStoreSnapshot();
    SPKInstantsResetTracking();
    SPKInstantsResetMediaRegistry(reason);
    sCachedTimeOrderedSnaps = nil;
    sCachedPeekPreviewSnaps = nil;
    sObservedTimeOrderedSnaps = nil;
    sObservedPeekPreviewSnaps = nil;
    sTrackedActiveMedia = nil;
    sTrackedActiveSuccessorKey = nil;
    sSessionMedia = nil;
    sSessionResolvedSnaps = nil;
    sConsumptionSessionActive = NO;

    if (accountBoundary) {
        sQuickSnapServiceInstance = nil;
        [sPKByIdentityKey removeAllObjects];
        sPKByIdentityKey = nil;
    }

    SPKLog(@"Instants", @"resolver state reset boundary=%@ reason=%@",
           accountBoundary ? @"account" : @"viewer", reason ?: @"unknown");
}

// Tap tracking. IG 439 has no `handleTap` on the stack view — the class exposes only
// willMoveToWindow:/layoutSubviews/sizeThatFits:/quick_flexibilityFor:/initWithFrame: to
// ObjC — so the tap is taken on the TapController, which does expose
// didPressWithGestureRecognizer: and holds a `state` back-reference.
//
// Rather than incrementing (the press fires for several gesture phases, and the viewer may
// wrap or dismiss), the tracked index is re-synced from the state after the original runs.
typedef void (*SPKInstantsDidPressIMP)(id, SEL, id);
static SPKInstantsDidPressIMP orig_tapControllerDidPress = NULL;

static void replaced_tapControllerDidPress(id self, SEL _cmd, id recognizer) {
    if (orig_tapControllerDidPress)
        orig_tapControllerDidPress(self, _cmd, recognizer);

    id state = SPKInstantsObjectValue(self, @[ @"state" ]);
    if (state) {
        NSInteger index = SPKInstantsIntegerIvarValue(state, @"currentlyDisplayingQuickSnapIndex", NSNotFound);
        if (index != NSNotFound && index >= 0) {
            sTrackedActiveIndex = index;
            sTrackedIndexValid = YES;
        }
    }

    // The service-list observer owns active-media changes. Re-reading the view hierarchy
    // here used to select its permanently-frontmost first subview again and overwrite the
    // newly tracked snap with the one that had just been tapped away.
}

static void replaced_consumptionVCViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (sAccountBoundaryPendingViewer) {
        SPKInstantsResetResolverState(YES, @"first viewer after account change");
        sAccountBoundaryPendingViewer = NO;
    }

    // The topmost Instant can be removed from the service/store before the header action
    // first resolves. Snapshot it before the viewer's appearance work performs that pop,
    // preserving the IGMedia model with its PK, timestamp, and full candidate list.
    if (!sConsumptionSessionActive) {
        sConsumptionSessionActive = YES;
        NSArray *snapshot = SPKInstantsStoreSnapshot();
        SPKInstantsAppendSessionMedia(snapshot);
        SPKLog(@"Instants", @"viewer pre-appearance snapshot count=%lu",
               (unsigned long)snapshot.count);
    }

    if (orig_consumptionVCViewWillAppear)
        orig_consumptionVCViewWillAppear(self, _cmd, animated);
}

static void replaced_consumptionVCViewDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (orig_consumptionVCViewDidDisappear)
        orig_consumptionVCViewDidDisappear(self, _cmd, animated);

    // `viewDidDisappear:` also fires when the viewer is merely COVERED — Sparkle's
    // full-screen preview presents with UIModalPresentationFullScreen (deliberately, so
    // IG pauses the snap timer behind it), which tears the viewer's view out of the
    // window exactly as a real exit does. Treating that as "left the viewer" wiped the
    // store snapshot and the registry mid-session, so returning from an expand left the
    // snap resolvable only from the view: no backing media, and the download sheet
    // collapsed to the single "Fallback source" row.
    //
    // A genuine exit sets one of these; being covered sets neither.
    UIViewController *viewController = [self isKindOfClass:UIViewController.class] ? (UIViewController *)self : nil;
    if (viewController) {
        BOOL leaving = viewController.isBeingDismissed || viewController.isMovingFromParentViewController;
        // Safety net for a teardown that sets neither flag: fully detached from the
        // hierarchy. Being covered keeps the parent/presenting links intact, so this
        // cannot fire for a presentation.
        BOOL detached = viewController.presentingViewController == nil &&
                        viewController.parentViewController == nil &&
                        viewController.viewIfLoaded.window == nil;
        if (!leaving && !detached) {
            SPKLog(@"Instants", @"consumption VC covered (not exiting) — keeping snapshot, registry & cache");
            return;
        }
    }

    SPKInstantsResetResolverState(NO, @"consumption VC disappeared");
}

void SPKInstallInstantsResolverHooks(void) {
    static BOOL sInstalled = NO;
    if (sInstalled)
        return;
    sInstalled = YES;

    Class listenerClass = objc_getClass("_TtC30IGQuickSnapServiceListenerImpl30IGQuickSnapServiceListenerImpl");
    Class badgeClass = objc_getClass("IGBadgeManager");
    Class serviceClass = objc_getClass("_TtC18IGQuickSnapService18IGQuickSnapService");

    if (!listenerClass && !badgeClass && !serviceClass) {
        SPKLog(@"Instants", @"Instants hooks skipped: no QuickSnap classes found (IG 410 compat)");
        return;
    }

    SPKLog(@"Instants", @"Installing Instants resolver hooks (listener=%@, badge=%@, service=%@)",
           listenerClass ? @"YES" : @"NO",
           badgeClass ? @"YES" : @"NO",
           serviceClass ? @"YES" : @"NO");

    // All resolver caches are process-global because the QuickSnap hooks are process-wide,
    // while Instagram's service/store belongs to the active user session. An account switch
    // is therefore a hard ownership boundary even if the old viewer remains covered and
    // never emits a genuine viewDidDisappear exit.
    [[NSNotificationCenter defaultCenter] addObserverForName:SPKAccountDidChangeNotification
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *note) {
                                                      NSString *accountPK = [note.userInfo[@"pk"] isKindOfClass:NSString.class]
                                                                                ? note.userInfo[@"pk"]
                                                                                : nil;
                                                      SPKInstantsResetResolverState(
                                                          YES,
                                                          accountPK.length > 0
                                                              ? [NSString stringWithFormat:@"account changed to %@", accountPK]
                                                              : @"account changed");
                                                      sAccountBoundaryPendingViewer = YES;
                                                  }];

    SPKInstantsHookInstanceMethod("_TtC30IGQuickSnapServiceListenerImpl30IGQuickSnapServiceListenerImpl",
                                  @selector(quickSnapServiceDidUpdateSnapsWithTimeOrderedQuicksnaps:peekPreviewSnaps:didReceiveNewSnaps:),
                                  (IMP)replaced_instantsServiceListenerUpdate,
                                  (IMP *)&orig_instantsServiceListenerUpdate);
    SPKInstantsHookInstanceMethod("IGBadgeManager",
                                  @selector(quickSnapServiceDidUpdateSnapsWithTimeOrderedQuicksnaps:peekPreviewSnaps:didReceiveNewSnaps:),
                                  (IMP)replaced_instantsBadgeManagerServiceUpdate,
                                  (IMP *)&orig_instantsBadgeManagerServiceUpdate);
    SPKInstantsHookInstanceMethod("_TtC18IGQuickSnapService18IGQuickSnapService",
                                  @selector(availableTimeOrderedSnaps),
                                  (IMP)replaced_instantsServiceAvailableTimeOrderedSnaps,
                                  (IMP *)&orig_instantsServiceAvailableTimeOrderedSnaps);
    SPKInstantsHookInstanceMethod("_TtC18IGQuickSnapService18IGQuickSnapService",
                                  @selector(sidePeekPreviewMedias),
                                  (IMP)replaced_instantsServiceSidePeekPreviewMedias,
                                  (IMP *)&orig_instantsServiceSidePeekPreviewMedias);

    // Eagerly capture the service instance so the store read works even if IG never
    // calls availableTimeOrderedSnaps again during this consumption session.
    if (!sQuickSnapServiceInstance) {
        id service = SPKInstantsLocateQuickSnapService();
        if (service) {
            sQuickSnapServiceInstance = service;
            SPKLog(@"Instants", @"captured service at hook-install time via session lookup");
        }
    }

    // Capture the queue before the initial snap is consumed, and reset the snapshot after
    // the user genuinely leaves so the next viewer session starts fresh.
    SPKInstantsHookInstanceMethod("_TtC26IGQuickSnapConsumptionCore36IGQuickSnapConsumptionViewController",
                                  @selector(viewWillAppear:),
                                  (IMP)replaced_consumptionVCViewWillAppear,
                                  (IMP *)&orig_consumptionVCViewWillAppear);
    SPKInstantsHookInstanceMethod("_TtC26IGQuickSnapConsumptionCore36IGQuickSnapConsumptionViewController",
                                  @selector(viewDidDisappear:),
                                  (IMP)replaced_consumptionVCViewDidDisappear,
                                  (IMP *)&orig_consumptionVCViewDidDisappear);

    // Track the active index via the tap controller. Older builds carried `handleTap` on
    // the stack view itself; 439 does not, so the controller is tried first and the legacy
    // selector is kept as a fallback for the versions that still have it.
    static const char *kTapControllerClass =
        "_TtC39IGQuickSnapImmersiveViewerSnapStackView61IGQuickSnapImmersiveViewerAnimatingSnapStackViewTapController";
    Class tapControllerClass = objc_getClass(kTapControllerClass);
    if (tapControllerClass && class_getInstanceMethod(tapControllerClass, @selector(didPressWithGestureRecognizer:))) {
        SPKInstantsHookInstanceMethod(kTapControllerClass,
                                      @selector(didPressWithGestureRecognizer:),
                                      (IMP)replaced_tapControllerDidPress,
                                      (IMP *)&orig_tapControllerDidPress);
        SPKLog(@"Instants", @"didPressWithGestureRecognizer: hook installed on TapController");
    } else {
        SPKLog(@"Instants", @"WARNING: TapController didPress not found (class=%@) — "
                            @"active index falls back to visual detection",
               tapControllerClass ? @"YES" : @"NO");
    }

    SPKLog(@"Instants", @"Instants resolver hooks installed");
}
