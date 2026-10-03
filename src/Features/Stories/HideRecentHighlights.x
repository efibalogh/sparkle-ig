#import "../../InstagramHeaders.h"
#import "../../Utils.h"

#import <objc/runtime.h>
#import <substrate.h>

// Hide resurfaced highlights.
//
// Once every unseen story has been watched, Instagram refills the story tray
// with stories that accounts you follow have recently added to a highlight.
//
// These entries have to be removed at the tray *data source*, not at the tray
// adapter, because two different consumers read them:
//
//   - IGStoryTrayListAdapterDataSource wraps an id<IGStoryTrayDataSource> and
//     turns allItemsForTrayUsingCachedValue: into the rendered tray objects.
//   - IGStoryViewerViewController holds the same id<IGStoryTrayDataSource> as
//     _trayDataSource and walks it for advancePastLastItemWithNavigationAction:,
//     which is what fires when you tap forward past the last story.
//
// Filtering the adapter only hides the rings: the viewer still reaches the
// highlights on tap, because it never consults the adapter. Filtering the data
// source covers both, and keeps the tray layout consistent (a post-hoc trim of
// the rendered list leaves the tray sizing itself from the unfiltered count,
// which is what leaves the last ring clipped).
//
// Note that IGHighlightsStoryTrayDataSource is deliberately NOT hooked. That is
// the real highlights tray on a profile, and filtering it would empty the
// highlights someone is deliberately trying to open.
//
// A resurfaced highlight is identified by two independent signals, either of
// which is enough:
//
//   - the view model's "type" value is 11. IGStoryTrayViewModel is an
//     IGDevirtualizedValueObject, so "type" is not a real property and has to be
//     read through KVC (the same way the existing suggested-story filter reads
//     types 8 and 9).
//   - the diffIdentifier is prefixed with "highlightRewind:", which is the
//     identifier namespace Instagram uses for these entries.
//
// Anything ambiguous is kept, so a change upstream degrades into showing the
// highlight rather than eating a real story. Every hook self-gates on the pref
// at call time, so the toggle takes effect without a restart.

static NSString *const kSPKHighlightRewindPrefix = @"highlightRewind:";
static NSInteger const kSPKHighlightTrayViewModelType = 11;

static BOOL SPKIsResurfacedHighlightTrayItem(id obj) {
    Class trayViewModelClass = objc_getClass("IGStoryTrayViewModel");
    if (trayViewModelClass == nil || ![obj isKindOfClass:trayViewModelClass])
        return NO;

    @try {
        NSNumber *type = [obj valueForKey:@"type"];
        if ([type isKindOfClass:[NSNumber class]] &&
            [type isEqual:@(kSPKHighlightTrayViewModelType)])
            return YES;
    } @catch (__unused NSException *exception) {
        // "type" is resolved dynamically, so an Instagram-side rename throws
        // rather than returning nil. Fall through to the identifier check.
    }

    @try {
        if (![obj respondsToSelector:@selector(diffIdentifier)])
            return NO;

        NSString *identifier = [[obj diffIdentifier] description];
        if ([identifier isKindOfClass:[NSString class]] &&
            [identifier hasPrefix:kSPKHighlightRewindPrefix])
            return YES;
    } @catch (__unused NSException *exception) {
    }

    return NO;
}

// The tray rebuilds often and most rebuilds contain no highlights at all, so
// scan before allocating and hand back the original array unchanged when there
// is nothing to strip.
static id SPKTrayItemsWithoutHighlights(id items) {
    if (![SPKUtils getBoolPref:@"stories_hide_recent_highlights"] ||
        ![items isKindOfClass:[NSArray class]])
        return items;

    NSArray *objects = (NSArray *)items;

    BOOL hasHighlight = NO;
    for (id obj in objects) {
        if (SPKIsResurfacedHighlightTrayItem(obj)) {
            hasHighlight = YES;
            break;
        }
    }
    if (!hasHighlight)
        return objects;

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:objects.count];
    for (id obj in objects) {
        if (!SPKIsResurfacedHighlightTrayItem(obj))
            [filtered addObject:obj];
    }

    SPKLog(@"Stories", @"[Sparkle] Removed %lu resurfaced highlights from the story tray",
           (unsigned long)(objects.count - filtered.count));

    return [filtered copy];
}

%group SPKHideRecentHighlightsInFeedHooks

%hook IGInFeedStoryTrayDataSource

- (id)allItemsForTrayUsingCachedValue:(BOOL)cached {
    return SPKTrayItemsWithoutHighlights(%orig(cached));
}

%end

%end // group SPKHideRecentHighlightsInFeedHooks

%group SPKHideRecentHighlightsMainHooks

// Swift class on modern Instagram, so the runtime name is the mangled _TtC form.
%hook _TtC25IGMainStoryTrayDataSource25IGMainStoryTrayDataSource

- (id)allItemsForTrayUsingCachedValue:(BOOL)cached {
    return SPKTrayItemsWithoutHighlights(%orig(cached));
}

%end

%end // group SPKHideRecentHighlightsMainHooks

%group SPKHideRecentHighlightsLegacyMainHooks

// Pre-Swift name for the same data source, still present on older Instagram.
%hook IGMainStoryTrayDataSource

- (id)allItemsForTrayUsingCachedValue:(BOOL)cached {
    return SPKTrayItemsWithoutHighlights(%orig(cached));
}

%end

%end // group SPKHideRecentHighlightsLegacyMainHooks

%group SPKHideRecentHighlightsFollowingHooks

%hook IGFollowingStoryTrayDataSource

- (id)allItemsForTrayUsingCachedValue:(BOOL)cached {
    return SPKTrayItemsWithoutHighlights(%orig(cached));
}

%end

%end // group SPKHideRecentHighlightsFollowingHooks

#pragma mark - Story viewer

// The viewer does NOT build its reel list from the tray data source. Device
// traces show the tray handing back 67 items containing a single highlight
// while the viewer's own modelItems held 80 items with 15 highlights appended
// at the end, all present from the first setModelItems: call rather than
// appended later. Filtering the tray therefore removes the ring but leaves the
// tap-forward-past-the-last-story path completely intact, which is what
// advancePastLastItemWithNavigationAction: walks into.
//
// Resurfaced entries are matched on the reelPK prefix alone. "highlightRewind:"
// is specific to this resurfacing feature, so a highlight opened deliberately
// from a profile (a different reelPK namespace) can never match. Matching on
// type == 5 instead would be wrong: that value covers highlights generally.
static NSString *const kSPKHighlightRewindReelPrefix = @"highlightRewind:";

static BOOL SPKStringHasRewindPrefix(id value) {
    return [value isKindOfClass:[NSString class]] &&
           [(NSString *)value hasPrefix:kSPKHighlightRewindReelPrefix];
}

static BOOL SPKIsResurfacedHighlightViewModel(id model) {
    @try {
        if ([model respondsToSelector:@selector(reelPK)] &&
            SPKStringHasRewindPrefix([model reelPK]))
            return YES;

        // Fallback for older Instagram, where the reel identifier may not be
        // exposed as reelPK. The diffIdentifier carries the same namespace.
        if ([model respondsToSelector:@selector(diffIdentifier)] &&
            SPKStringHasRewindPrefix([[model diffIdentifier] description]))
            return YES;
    } @catch (__unused NSException *exception) {
    }

    return NO;
}

// `logging` is off for the getter: it is read constantly, and one line per read
// would bury everything else in the log.
static id SPKViewerItemsWithoutHighlightsLogging(id items, BOOL logging) {
    if (![SPKUtils getBoolPref:@"stories_hide_recent_highlights"] ||
        ![items isKindOfClass:[NSArray class]])
        return items;

    NSArray *models = (NSArray *)items;

    BOOL hasHighlight = NO;
    for (id model in models) {
        if (SPKIsResurfacedHighlightViewModel(model)) {
            hasHighlight = YES;
            break;
        }
    }
    if (!hasHighlight)
        return models;

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:models.count];
    for (id model in models) {
        if (!SPKIsResurfacedHighlightViewModel(model))
            [filtered addObject:model];
    }

    // Never hand the viewer an empty list. If every reel matched, this is a
    // session that opened on the highlights themselves, so leave it alone
    // rather than presenting an empty viewer.
    if (filtered.count == 0) {
        if (logging)
            SPKLog(@"Stories",
                   @"[Sparkle] All reels are resurfaced highlights, leaving viewer intact");
        return models;
    }

    if (logging)
        SPKLog(@"Stories", @"[Sparkle] Removed %lu resurfaced highlights from the story viewer",
               (unsigned long)(models.count - filtered.count));

    return [filtered copy];
}

static id SPKViewerItemsWithoutHighlights(id items) {
    return SPKViewerItemsWithoutHighlightsLogging(items, YES);
}

%group SPKHideRecentHighlightsViewerHooks

%hook IGStoryViewerViewController

- (void)applyModelItems:(id)items animated:(BOOL)animated completion:(id)completion {
    %orig(SPKViewerItemsWithoutHighlights(items), animated, completion);
}

%end

%end // group SPKHideRecentHighlightsViewerHooks

#pragma mark - Viewer paging store

// There are two ways to leave the current person's story: tapping forward past
// the last item, and swiping horizontally to the next person. They do not read
// the same list.
//
// Tap-forward walks the view controller's own modelItems, which is what the
// accessor hooks below cover. Horizontal paging is driven by the list adapter,
// whose sections come from IGStoryAndLiveViewerDataSource -objectsForListAdapter:,
// and that data source keeps its reels in a separate IGStoryViewerDataStore.
// Filtering only the view controller therefore leaves the swipe path intact, and
// worse, leaves the two lists disagreeing: the adapter still builds a page for a
// resurfaced highlight while the reel behind it can no longer be resolved, so the
// swipe lands on a blank story from a blank author that spins forever.
//
// Filtering the store makes both sides agree. The store is a plain Objective-C
// class with the same name and shape on 442 and 410 (the maxCount variant is
// newer, so it is bound only where it exists), and every read goes through
// -modelItems, so the adapter, the section controllers and the dedupe set all see
// the same trimmed list.

%group SPKHideRecentHighlightsViewerStoreHooks

%hook IGStoryViewerDataStore

- (void)replaceModelItems:(id)items {
    %orig(SPKViewerItemsWithoutHighlights(items));
}

- (id)modelItems {
    return SPKViewerItemsWithoutHighlightsLogging(%orig, NO);
}

%end

%end // group SPKHideRecentHighlightsViewerStoreHooks

%group SPKHideRecentHighlightsViewerStoreMaxCountHooks

%hook IGStoryViewerDataStore

- (void)replaceModelItems:(id)items maxCount:(long long)count {
    %orig(SPKViewerItemsWithoutHighlights(items), count);
}

%end

%end // group SPKHideRecentHighlightsViewerStoreMaxCountHooks

#pragma mark - Model item accessor discovery

// The selectors that read and write the viewer's reel list are not stable across
// Instagram versions: modern builds expose setModelItems: (plus
// applyModelItems:animated:completion:), while 410 has neither and uses the
// private _setModelItems: / _getModelItems pair. Rather than keep chasing
// renames, find them on the live class by shape.
//
// Both sides are filtered. Filtering only the setter is not enough: on 410 the
// list is written through the private setter and still navigates into
// highlights, which means something reads the reels back by a route that never
// passed through it. Filtering the getter as well means every reader sees the
// trimmed list no matter how it got there. Doing both is consistent rather than
// redundant - the same predicate runs on the way in and on the way out, so
// indices computed from a read match the list that was stored.

typedef void (*SPKModelItemsSetter)(id, SEL, id);
typedef id (*SPKModelItemsGetter)(id, SEL);

static NSMutableDictionary<NSString *, NSValue *> *SPKModelItemsOriginals(void) {
    static NSMutableDictionary<NSString *, NSValue *> *originals;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        originals = [NSMutableDictionary dictionary];
    });
    return originals;
}

static void SPKModelItemsSetterReplacement(id self, SEL _cmd, id items) {
    NSValue *boxed = SPKModelItemsOriginals()[NSStringFromSelector(_cmd)];
    SPKModelItemsSetter original = (SPKModelItemsSetter)[boxed pointerValue];
    if (original == NULL)
        return;

    original(self, _cmd, SPKViewerItemsWithoutHighlights(items));
}

static id SPKModelItemsGetterReplacement(id self, SEL _cmd) {
    NSValue *boxed = SPKModelItemsOriginals()[NSStringFromSelector(_cmd)];
    SPKModelItemsGetter original = (SPKModelItemsGetter)[boxed pointerValue];
    if (original == NULL)
        return nil;

    return SPKViewerItemsWithoutHighlightsLogging(original(self, _cmd), NO);
}

// Does this method name refer to the viewer's reel list? Covers both the
// "ModelItems" spelling used by the setters and the bare "modelItems" getter.
static BOOL SPKNameRefersToModelItems(NSString *name) {
    return [name rangeOfString:@"modelitems"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL SPKIsModelItemsSetter(Method method) {
    if (!SPKNameRefersToModelItems(NSStringFromSelector(method_getName(method))))
        return NO;

    // self, _cmd, and exactly one argument.
    if (method_getNumberOfArguments(method) != 3)
        return NO;

    char *returnType = method_copyReturnType(method);
    BOOL returnsVoid = returnType != NULL && strcmp(returnType, @encode(void)) == 0;
    free(returnType);
    if (!returnsVoid)
        return NO;

    char *argumentType = method_copyArgumentType(method, 2);
    BOOL takesObject = argumentType != NULL && strcmp(argumentType, @encode(id)) == 0;
    free(argumentType);

    return takesObject;
}

static BOOL SPKIsModelItemsGetter(Method method) {
    if (!SPKNameRefersToModelItems(NSStringFromSelector(method_getName(method))))
        return NO;

    // self and _cmd only.
    if (method_getNumberOfArguments(method) != 2)
        return NO;

    char *returnType = method_copyReturnType(method);
    BOOL returnsObject = returnType != NULL && strcmp(returnType, @encode(id)) == 0;
    free(returnType);

    return returnsObject;
}

static void SPKInstallModelItemsAccessorHooks(Class viewerClass) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(viewerClass, &count);
    if (methods == NULL)
        return;

    NSUInteger hooked = 0;
    for (unsigned int i = 0; i < count; i++) {
        BOOL isSetter = SPKIsModelItemsSetter(methods[i]);
        BOOL isGetter = !isSetter && SPKIsModelItemsGetter(methods[i]);
        if (!isSetter && !isGetter)
            continue;

        SEL selector = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(selector);

        IMP replacement = isSetter ? (IMP)SPKModelItemsSetterReplacement
                                   : (IMP)SPKModelItemsGetterReplacement;
        IMP original = NULL;
        MSHookMessageEx(viewerClass, selector, replacement, &original);

        if (original == NULL) {
            // Log the miss rather than skipping silently: a candidate that
            // matched but failed to bind is exactly the kind of gap that looks
            // like "the fix does nothing" on device.
            SPKLog(@"Stories", @"[Sparkle] Failed to hook story viewer -%@", name);
            continue;
        }

        SPKModelItemsOriginals()[name] = [NSValue valueWithPointer:original];
        hooked++;
        SPKLog(@"Stories", @"[Sparkle] Hooked story viewer list %@ -%@",
               isSetter ? @"setter" : @"getter", name);
    }
    free(methods);

    if (hooked == 0)
        SPKLog(@"Stories", @"[Sparkle] Found no story viewer list accessor to hook");
}

void SPKInstallHideRecentHighlightsHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        BOOL installedAny = NO;

        // Swift class from 448, where only the mangled name is guaranteed.
        Class inFeedDataSource = objc_getClass("IGInFeedStoryTrayDataSource") ?: objc_getClass("_TtC27IGInFeedStoryTrayDataSource27IGInFeedStoryTrayDataSource");
        if (inFeedDataSource != nil) {
            %init(SPKHideRecentHighlightsInFeedHooks, IGInFeedStoryTrayDataSource = inFeedDataSource);
            installedAny = YES;
        }
        if (objc_getClass("_TtC25IGMainStoryTrayDataSource25IGMainStoryTrayDataSource") != nil) {
            %init(SPKHideRecentHighlightsMainHooks);
            installedAny = YES;
        }
        if (objc_getClass("IGMainStoryTrayDataSource") != nil) {
            %init(SPKHideRecentHighlightsLegacyMainHooks);
            installedAny = YES;
        }
        if (objc_getClass("IGFollowingStoryTrayDataSource") != nil) {
            %init(SPKHideRecentHighlightsFollowingHooks);
            installedAny = YES;
        }

        if (!installedAny)
            SPKLog(@"Stories", @"[Sparkle] No story tray data source found, skipping tray hooks");

        // The paging store is what stops the swipe to the next person.
        Class storeClass = objc_getClass("IGStoryViewerDataStore");
        if (storeClass != nil) {
            %init(SPKHideRecentHighlightsViewerStoreHooks);

            if (class_getInstanceMethod(storeClass,
                                        @selector(replaceModelItems:maxCount:)) != NULL)
                %init(SPKHideRecentHighlightsViewerStoreMaxCountHooks);
        } else {
            SPKLog(@"Stories", @"[Sparkle] No story viewer data store found, skipping swipe hooks");
        }

        // The viewer hooks are the ones that stop the tap-forward.
        Class viewerClass = objc_getClass("IGStoryViewerViewController");
        if (viewerClass != nil) {
            SPKInstallModelItemsAccessorHooks(viewerClass);

            // applyModelItems:animated:completion: has a different shape, so it
            // is bound by name and only where it exists.
            if (class_getInstanceMethod(
                    viewerClass, @selector(applyModelItems:animated:completion:)) != NULL)
                %init(SPKHideRecentHighlightsViewerHooks);
        }
    });
}
