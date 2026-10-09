#import "SPKStrings.h"
#import "SPKStoryContext.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "../../Networking/SPKInstagramAPI.h"
#import "../../Shared/UI/SPKMediaChrome.h"
#import "../../Shared/UI/SPKUserListViewController.h"
#import "../../Tweak.h"
#import "../../Utils.h"
#import "../ActionButton/ActionButtonLookupUtils.h"
#import "../Messages/SPKDirectUserResolver.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKNotificationCenter.h"

static __weak UIView *SPKStoryActiveOverlayView;
static NSString *const kSPKStoryManualSeenUserNamesKey = @"stories_manual_seen_user_names";

@implementation SPKStoryContext
- (instancetype)init {
    if ((self = [super init])) {
        _currentIndex = 0;
    }
    return self;
}
@end

void SPKStorySetActiveOverlay(UIView *overlayView) {
    SPKStoryActiveOverlayView = overlayView;
}

UIView *SPKStoryActiveOverlay(void) {
    return SPKStoryActiveOverlayView;
}

static id SPKStoryFirstObjectForSelectors(id target, NSArray<NSString *> *selectors) {
    for (NSString *selectorName in selectors) {
        id value = SPKObjectForSelector(target, selectorName);
        if (!value)
            value = SPKKVCObject(target, selectorName);
        if (value)
            return value;
    }
    return nil;
}

static NSString *SPKStoryMediaID(id media);
static NSString *SPKStoryFullNameFromMediaObject(id media);

static UIViewController *SPKStoryViewerControllerFromController(UIViewController *controller, Class viewerClass) {
    for (UIViewController *walker = controller; walker; walker = walker.parentViewController) {
        if (!viewerClass || [walker isKindOfClass:viewerClass])
            return walker;
    }
    for (UIViewController *walker = controller.presentingViewController; walker; walker = walker.presentingViewController) {
        if (!viewerClass || [walker isKindOfClass:viewerClass])
            return walker;
    }
    return nil;
}

static UIViewController *SPKStoryViewerControllerFromOverlay(UIView *overlayView) {
    if (!overlayView)
        return nil;

    Class viewerClass = NSClassFromString(@"IGStoryViewerViewController");
    for (UIResponder *responder = overlayView; responder; responder = responder.nextResponder) {
        if (viewerClass && [responder isKindOfClass:viewerClass])
            return (UIViewController *)responder;
    }

    id ancestor = SPKObjectForSelector(overlayView, @"_viewControllerForAncestor");
    UIViewController *viewer = [ancestor isKindOfClass:[UIViewController class]]
                                   ? SPKStoryViewerControllerFromController(ancestor, viewerClass)
                                   : nil;
    if (viewer)
        return viewer;

    UIViewController *nearest = [SPKUtils nearestViewControllerForView:overlayView];
    viewer = SPKStoryViewerControllerFromController(nearest, viewerClass);
    return viewer ?: nearest;
}

static id SPKStorySectionControllerFromOverlay(UIView *overlayView, UIViewController *viewerController) {
    id sectionController = SPKStoryFirstObjectForSelectors(viewerController, @[ @"currentlyDisplayedSectionController", @"currentSectionController" ]);
    if (!sectionController)
        sectionController = [SPKUtils getIvarForObj:viewerController name:"_currentSectionController"];
    if (sectionController)
        return sectionController;

    if (!overlayView)
        return nil;
    NSArray<NSString *> *delegateSelectors = @[ @"mediaOverlayDelegate", @"retryDelegate", @"tappableOverlayDelegate", @"buttonDelegate" ];
    Class sectionControllerClass = NSClassFromString(@"IGStoryFullscreenSectionController");
    for (NSString *selectorName in delegateSelectors) {
        id delegate = SPKObjectForSelector(overlayView, selectorName);
        if (!delegate)
            delegate = SPKKVCObject(overlayView, selectorName);
        if (!delegate)
            continue;
        if (!sectionControllerClass || [delegate isKindOfClass:sectionControllerClass])
            return delegate;
    }
    return nil;
}

static id SPKStoryMediaFromAnyObject(id object) {
    if (!object)
        return nil;
    id candidate = SPKStoryFirstObjectForSelectors(object, @[ @"media", @"mediaItem", @"storyItem", @"item", @"model" ]);
    return candidate ?: object;
}

static NSArray *SPKStoryItemsFromCandidate(id candidate) {
    if (!candidate)
        return nil;
    for (NSString *selectorName in @[ @"items", @"storyItems", @"reelItems", @"mediaItems", @"allItems" ]) {
        NSArray *items = SPKArrayFromCollection(SPKStoryFirstObjectForSelectors(candidate, @[ selectorName ]));
        if (items.count > 0)
            return items;
    }
    SEL cachedSelector = NSSelectorFromString(@"allItemsForTrayUsingCachedValue:");
    if ([candidate respondsToSelector:cachedSelector]) {
        @try {
            NSArray *items = SPKArrayFromCollection(((id (*)(id, SEL, BOOL))objc_msgSend)(candidate, cachedSelector, YES));
            if (items.count > 0)
                return items;
        } @catch (__unused NSException *exception) {
        }
    }
    // Dynamic ivar fallback scanning
    for (Class cls = [candidate class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *typeEncoding = ivar_getTypeEncoding(ivars[i]);
            if (typeEncoding && typeEncoding[0] == '@') {
                const char *name = ivar_getName(ivars[i]);
                id value = [SPKUtils getIvarForObj:candidate name:name];
                if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSOrderedSet class]] || [value isKindOfClass:[NSSet class]]) {
                    NSArray *arr = SPKArrayFromCollection(value);
                    if (arr.count > 1) {
                        free(ivars);
                        return arr;
                    }
                }
            }
        }
        free(ivars);
    }
    return nil;
}

// `currentIndex` is only ever used to index `allMedia`, so locating the displayed item in
// that array beats asking IG for a number: IG's `currentIndex` & friends count the
// viewer's own item list, while `allMedia` is filtered to the current user below, so a
// single foreign item ahead of the displayed one shifts IG's number out of range. Which of
// those four selectors answers at all also varies with the story type, which is what made
// the mismatch look random rather than systematic. The reported index stays as the
// fallback for when the displayed media isn't in the list.
static NSInteger SPKStoryCurrentIndexFromControllerOrSection(id sectionController, UIViewController *controller, id currentMedia, NSArray *allMedia) {
    if (currentMedia && allMedia.count > 0) {
        NSUInteger idx = [allMedia indexOfObjectIdenticalTo:currentMedia];
        if (idx != NSNotFound)
            return (NSInteger)idx;
        NSString *currentID = SPKStoryMediaID(currentMedia);
        if (currentID.length > 0) {
            for (NSUInteger i = 0; i < allMedia.count; i++) {
                NSString *candidateID = SPKStoryMediaID(allMedia[i]);
                if ([candidateID isEqualToString:currentID])
                    return (NSInteger)i;
            }
        }
    }
    for (id target in @[ sectionController ?: (id)NSNull.null, controller ?: (id)NSNull.null ]) {
        if (target == (id)NSNull.null)
            continue;
        for (NSString *selectorName in @[ @"currentIndex", @"currentItemIndex", @"itemIndex", @"currentPage" ]) {
            NSNumber *number = [SPKUtils numericValueForObj:target selectorName:selectorName];
            if (number && number.integerValue >= 0)
                return number.integerValue;
            id value = SPKKVCObject(target, selectorName);
            if ([value respondsToSelector:@selector(integerValue)] && [value integerValue] >= 0)
                return [value integerValue];
        }
    }
    return 0;
}

static NSString *SPKStoryMediaID(id media) {
    for (NSString *selectorName in @[ @"pk", @"id", @"mediaID", @"mediaId", @"mediaIdentifier" ]) {
        NSString *identifier = SPKStringFromValue(SPKObjectForSelector(media, selectorName));
        if (identifier.length == 0)
            identifier = SPKStringFromValue(SPKKVCObject(media, selectorName));
        if (identifier.length > 0)
            return [identifier componentsSeparatedByString:@"_"].firstObject ?: identifier;
    }
    return nil;
}

static NSURL *SPKStoryURLForMedia(id media) {
    NSString *username = SPKUsernameFromMediaObject(media);
    NSString *identifier = SPKStoryMediaID(media);
    if (username.length == 0 || identifier.length == 0)
        return nil;
    NSString *encodedUsername = [username stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSString *encodedIdentifier = [identifier stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    if (encodedUsername.length == 0 || encodedIdentifier.length == 0)
        return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://www.instagram.com/stories/%@/%@/", encodedUsername, encodedIdentifier]];
}

// Cache the last fully-built context on the overlay, keyed by the resolved
// media object. `IGStoryFullscreenOverlayView -layoutSubviews` fires many
// times per displayed item (and repeatedly during user-to-user transitions),
// but the cheap responder/selector probes below resolve the same `media`
// pointer each time. The expensive part — the O(items) allMedia loop plus
// username/full-name/URL resolution — only needs to run once per item, so we
// memoize it and reuse it while the displayed media is unchanged.
// SPKStoryContext.overlayView is weak, so retaining the context as an
// associated object on the overlay does not create a retain cycle.
static const void *kSPKStoryContextCacheKey = &kSPKStoryContextCacheKey;

SPKStoryContext *SPKStoryContextFromOverlay(UIView *overlayView) {
    if (!overlayView)
        return nil;
    SPKStoryContext *context = [[SPKStoryContext alloc] init];
    context.overlayView = overlayView;
    context.viewerController = SPKStoryViewerControllerFromOverlay(overlayView);
    context.sectionController = SPKStorySectionControllerFromOverlay(overlayView, context.viewerController);

    SEL markSelector = NSSelectorFromString(@"fullscreenSectionController:didMarkItemAsSeen:");
    id sectionDelegate = SPKObjectForSelector(context.sectionController, @"delegate");
    if ([sectionDelegate respondsToSelector:markSelector]) {
        context.markSeenTarget = sectionDelegate;
    } else if ([context.viewerController respondsToSelector:markSelector]) {
        context.markSeenTarget = context.viewerController;
    } else {
        id ancestor = SPKObjectForSelector(overlayView, @"_viewControllerForAncestor");
        if ([ancestor respondsToSelector:markSelector])
            context.markSeenTarget = ancestor;
    }

    if (!context.sectionController && context.markSeenTarget) {
        context.sectionController = SPKStoryFirstObjectForSelectors(context.markSeenTarget, @[ @"currentlyDisplayedSectionController", @"currentSectionController" ]) ?: [SPKUtils getIvarForObj:context.markSeenTarget name:"_currentSectionController"];
    }

    id media = SPKStoryFirstObjectForSelectors(context.sectionController, @[ @"currentStoryItem", @"currentItem", @"item" ]);
    if (!media)
        media = SPKStoryFirstObjectForSelectors(context.viewerController, @[ @"currentStoryItem", @"currentItem", @"item" ]);
    id currentViewModel = SPKStoryFirstObjectForSelectors(context.viewerController, @[ @"currentViewModel" ]);
    if (!media && currentViewModel) {
        SEL currentItemSelector = NSSelectorFromString(@"currentStoryItemForViewModel:");
        if ([context.viewerController respondsToSelector:currentItemSelector]) {
            @try {
                media = ((id (*)(id, SEL, id))objc_msgSend)(context.viewerController, currentItemSelector, currentViewModel);
            } @catch (__unused NSException *exception) {
            }
        }
    }
    if (!media) {
        id itemContext = SPKStoryFirstObjectForSelectors(overlayView, @[ @"currentStoryItemContext", @"_currentStoryItemContext" ]);
        media = SPKStoryFirstObjectForSelectors(itemContext, @[ @"storyItem", @"item", @"media" ]);
    }
    if (!media)
        media = SPKStoryFirstObjectForSelectors(overlayView, @[ @"currentStoryItem", @"currentItem", @"item" ]);
    if (!media)
        media = SPKStoryFirstObjectForSelectors(context.markSeenTarget, @[ @"currentStoryItem", @"currentItem", @"item" ]);
    context.media = SPKStoryMediaFromAnyObject(media);

    if (!context.media) {
        objc_setAssociatedObject(overlayView, kSPKStoryContextCacheKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return nil;
    }

    // Fast path: same media as last build → reuse the expensive fields and skip
    // the allMedia item loop and username/full-name/URL resolution entirely.
    SPKStoryContext *cached = objc_getAssociatedObject(overlayView, kSPKStoryContextCacheKey);
    if (cached && cached.media == context.media) {
        context.allMedia = cached.allMedia;
        context.currentIndex = cached.currentIndex;
        context.username = cached.username;
        context.fullName = cached.fullName;
        context.storyURL = cached.storyURL;
        return context;
    }

    NSMutableArray *resolved = [NSMutableArray array];
    NSString *currentUserPK = SPKStoryUserPKFromMediaObject(context.media);
    for (id candidate in @[ context.sectionController ?: (id)NSNull.null, currentViewModel ?: (id)NSNull.null, context.viewerController ?: (id)NSNull.null ]) {
        if (candidate == (id)NSNull.null)
            continue;
        NSArray *items = SPKStoryItemsFromCandidate(candidate);
        if (items.count == 0)
            continue;
        for (id item in items) {
            id itemMedia = SPKStoryMediaFromAnyObject(item);
            if (itemMedia) {
                if (currentUserPK) {
                    NSString *itemUserPK = SPKStoryUserPKFromMediaObject(itemMedia);
                    if ([itemUserPK isEqualToString:currentUserPK]) {
                        [resolved addObject:itemMedia];
                    }
                } else {
                    [resolved addObject:itemMedia];
                }
            }
        }
        if (resolved.count > 0)
            break;
    }
    context.allMedia = resolved.count > 0 ? resolved.copy : (context.media ? @[ context.media ] : @[]);
    context.currentIndex = SPKStoryCurrentIndexFromControllerOrSection(context.sectionController, context.viewerController, context.media, context.allMedia);
    context.username = SPKUsernameFromMediaObject(context.media);
    context.fullName = SPKStoryFullNameFromMediaObject(context.media);
    context.storyURL = SPKStoryURLForMedia(context.media);
    objc_setAssociatedObject(overlayView, kSPKStoryContextCacheKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return context;
}

SPKStoryContext *SPKStoryContextFromView(UIView *view) {
    for (UIView *walker = view; walker; walker = walker.superview) {
        if ([NSStringFromClass(walker.class) containsString:@"IGStoryFullscreenOverlayView"]) {
            return SPKStoryContextFromOverlay(walker);
        }
    }
    return SPKStoryContextFromOverlay(SPKStoryActiveOverlay());
}

SPKStoryContext *SPKStoryContextFromMedia(id media) {
    if (!media)
        return nil;
    SPKStoryContext *context = [[SPKStoryContext alloc] init];
    context.media = media;
    context.username = SPKUsernameFromMediaObject(media);
    context.fullName = SPKStoryFullNameFromMediaObject(media);
    context.storyURL = SPKStoryURLForMedia(media);
    return context;
}

BOOL SPKStoryMarkContextAsSeen(SPKStoryContext *context) {
    SEL markSelector = NSSelectorFromString(@"fullscreenSectionController:didMarkItemAsSeen:");
    if (!context.markSeenTarget || !context.sectionController || !context.media || ![context.markSeenTarget respondsToSelector:markSelector]) {
        SPKLog(@"Stories",
               @"[Sparkle StorySeen] Unable to mark seen viewer=%@ section=%@ target=%@ media=%@ targetResponds=%d",
               context.viewerController ? NSStringFromClass(context.viewerController.class) : @"nil",
               context.sectionController ? NSStringFromClass([context.sectionController class]) : @"nil",
               context.markSeenTarget ? NSStringFromClass([context.markSeenTarget class]) : @"nil",
               context.media ? NSStringFromClass([context.media class]) : @"nil",
               context.markSeenTarget ? [context.markSeenTarget respondsToSelector:markSelector] : NO);
        return NO;
    }
    // IG reports each story separately, so marking only the displayed one leaves
    // the earlier stories of the reel unreported to the owner. Mark every story up
    // to the displayed one, oldest first, so the reel's seen date only moves forward.
    NSMutableArray *itemsToMark = [NSMutableArray array];
    NSString *currentID = SPKStoryMediaID(context.media);
    NSInteger currentIndex = context.currentIndex;
    if (currentID.length > 0 && currentIndex > 0 && currentIndex < (NSInteger)context.allMedia.count &&
        [SPKStoryMediaID(context.allMedia[currentIndex]) isEqualToString:currentID]) {
        [itemsToMark addObjectsFromArray:[context.allMedia subarrayWithRange:NSMakeRange(0, currentIndex)]];
    }
    [itemsToMark addObject:context.media];

    // Earlier stories were usually reported by a previous tap; skip them so they
    // are not reported again. Keyed by account because accounts share story ids.
    static NSMutableSet<NSString *> *markedKeys;
    static dispatch_once_t markedOnceToken;
    dispatch_once(&markedOnceToken, ^{
        markedKeys = [NSMutableSet set];
    });
    NSString *accountPK = [SPKUtils currentUserPK] ?: @"";

    for (id item in itemsToMark) {
        NSString *itemID = SPKStoryMediaID(item);
        NSString *markedKey = itemID.length > 0 ? [NSString stringWithFormat:@"%@|%@", accountPK, itemID] : nil;
        if (item != context.media && markedKey && [markedKeys containsObject:markedKey])
            continue;
        if (markedKey)
            [markedKeys addObject:markedKey];
        SPKForcedStorySeenMediaPK = [SPKStoryMediaIdentifier(item) copy];
        SPKForceMarkStoryAsSeen = YES;
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(context.markSeenTarget, markSelector, context.sectionController, item);
        } @catch (NSException *exception) {
            SPKLog(@"Stories", @"[Sparkle StorySeen] Marking an earlier story failed: %@", exception.reason);
        } @finally {
            SPKForceMarkStoryAsSeen = NO;
            SPKForcedStorySeenMediaPK = nil;
        }
    }
    SPKLog(@"Stories", @"[Sparkle StorySeen] Marked %lu stories up to index %ld", (unsigned long)itemsToMark.count, (long)currentIndex);
    return YES;
}

void SPKStoryAdvanceContextIfNeeded(SPKStoryContext *context, NSString *advancePrefKey) {
    if (!context || advancePrefKey.length == 0 || ![SPKUtils getBoolPref:advancePrefKey])
        return;
    id sectionController = context.sectionController;
    if (!sectionController)
        return;
    SPKForceStoryAutoAdvance = YES;
    SEL advanceSelector = NSSelectorFromString(@"advanceToNextItemWithNavigationAction:");
    if ([sectionController respondsToSelector:advanceSelector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(sectionController, advanceSelector, 1);
    } else {
        SEL endSelector = NSSelectorFromString(@"storyPlayerMediaViewDidPlayToEnd:");
        if ([sectionController respondsToSelector:endSelector]) {
            id mediaView = [SPKUtils getIvarForObj:sectionController name:"_mediaView"] ?: [SPKUtils getIvarForObj:context.overlayView name:"_mediaView"];
            ((void (*)(id, SEL, id))objc_msgSend)(sectionController, endSelector, mediaView);
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        SPKForceStoryAutoAdvance = NO;
    });
}

NSString *SPKStoryUsernameForContext(SPKStoryContext *context) {
    return context.username ?: SPKUsernameFromMediaObject(context.media);
}

NSString *SPKStoryFullNameForContext(SPKStoryContext *context) {
    return context.fullName ?: SPKStoryFullNameFromMediaObject(context.media);
}

NSURL *SPKStoryURLForContext(SPKStoryContext *context) {
    return context.storyURL ?: SPKStoryURLForMedia(context.media);
}

NSString *SPKStoryMediaIdentifierForContext(SPKStoryContext *context) {
    return SPKStoryMediaID(context.media);
}

static NSString *SPKStoryManualSeenListKey(BOOL manualSeenEnabled) {
    // Separate lists per mode: ON → Excluded (users using default seen),
    // OFF → Included (users requiring manual seen).
    return manualSeenEnabled ? @"stories_manual_seen_excluded" : @"stories_manual_seen_included";
}

static NSString *SPKStoryNormalizeUsername(NSString *username);

static NSString *SPKStoryCleanDisplayName(NSString *name, NSString *username) {
    NSString *cleanName = [SPKStringFromValue(name) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *cleanUsername = SPKStoryNormalizeUsername(username);
    if (cleanName.length == 0)
        return nil;
    if ([SPKStoryNormalizeUsername(cleanName) isEqualToString:cleanUsername])
        return nil;
    if ([[cleanName stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"@"]] caseInsensitiveCompare:cleanUsername] == NSOrderedSame)
        return nil;
    return cleanName;
}

static NSDictionary<NSString *, NSString *> *SPKStoryManualSeenUserNameCache(void) {
    id storedValue = SPKPreferenceObjectForKey(kSPKStoryManualSeenUserNamesKey);
    NSDictionary *stored = [storedValue isKindOfClass:[NSDictionary class]] ? storedValue : nil;
    return [stored isKindOfClass:[NSDictionary class]] ? stored : @{};
}

static NSString *SPKStoryCachedManualSeenUserName(NSString *username) {
    NSString *normalized = SPKStoryNormalizeUsername(username);
    if (normalized.length == 0)
        return nil;
    return SPKStoryCleanDisplayName(SPKStoryManualSeenUserNameCache()[normalized], normalized);
}

static void SPKStoryRememberManualSeenUserName(NSString *username, NSString *fullName) {
    NSString *normalized = SPKStoryNormalizeUsername(username);
    NSString *cleanName = SPKStoryCleanDisplayName(fullName, normalized);
    if (normalized.length == 0 || cleanName.length == 0)
        return;

    NSMutableDictionary *names = [SPKStoryManualSeenUserNameCache() mutableCopy];
    names[normalized] = cleanName;
    SPKPreferenceSetObject(names.copy, kSPKStoryManualSeenUserNamesKey);
}

static void SPKStoryResolveAndRememberManualSeenUserName(NSString *username, void (^completion)(void)) {
    NSString *normalized = SPKStoryNormalizeUsername(username);
    if (normalized.length == 0) {
        if (completion)
            completion();
        return;
    }
    if (SPKStoryCachedManualSeenUserName(normalized).length > 0) {
        if (completion)
            completion();
        return;
    }

    NSString *encodedUsername = [normalized stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    if (encodedUsername.length == 0) {
        if (completion)
            completion();
        return;
    }

    [SPKInstagramAPI sendRequestWithMethod:@"GET"
                                      path:[NSString stringWithFormat:@"users/web_profile_info/?username=%@", encodedUsername]
                                      body:nil
                                completion:^(NSDictionary *response, NSError *error) {
                                    NSDictionary *user = response[@"data"][@"user"];
                                    if (![user isKindOfClass:[NSDictionary class]])
                                        user = response[@"user"];
                                    if ([user isKindOfClass:[NSDictionary class]] && !error) {
                                        NSString *resolvedUsername = SPKStringFromValue(user[@"username"]) ?: normalized;
                                        NSString *fullName = SPKStringFromValue(user[@"full_name"] ?: user[@"fullName"]);
                                        SPKStoryRememberManualSeenUserName(resolvedUsername, fullName);
                                    } else {
                                        SPKLog(@"Stories", @"[Sparkle StorySeen] User display-name lookup failed username=%@ error=%@", normalized, error);
                                    }
                                    if (completion)
                                        completion();
                                }];
}

static NSString *SPKStoryFullNameFromUserObject(id user) {
    if (!user)
        return nil;
    for (NSString *selectorName in @[ @"fullName", @"full_name", @"displayName", @"name" ]) {
        NSString *name = SPKStringFromValue(SPKStoryFirstObjectForSelectors(user, @[ selectorName ]));
        if (name.length > 0)
            return name;
    }
    return nil;
}

static NSString *SPKStoryFullNameFromMediaObject(id media) {
    if (!media)
        return nil;

    NSString *name = SPKStoryFullNameFromUserObject(media);
    if (name.length > 0)
        return name;

    for (NSString *userSelector in @[ @"user", @"owner", @"author", @"sender", @"fromUser", @"userObject" ]) {
        id user = SPKStoryFirstObjectForSelectors(media, @[ userSelector ]);
        name = SPKStoryFullNameFromUserObject(user);
        if (name.length > 0)
            return name;
    }

    for (NSString *nestedSelector in @[ @"media", @"item", @"storyItem", @"reelShare", @"currentStoryItem", @"currentItem" ]) {
        id nested = SPKStoryFirstObjectForSelectors(media, @[ nestedSelector ]);
        if (!nested || nested == media)
            continue;
        name = SPKStoryFullNameFromMediaObject(nested);
        if (name.length > 0)
            return name;
    }

    return nil;
}

static id SPKStoryUserFromMediaObject(id media) {
    if (!media)
        return nil;
    Class userClass = NSClassFromString(@"IGUser");
    if (userClass && [media isKindOfClass:userClass]) {
        return media;
    }
    for (NSString *userSelector in @[ @"user", @"owner", @"author", @"sender", @"fromUser", @"userObject" ]) {
        id user = SPKStoryFirstObjectForSelectors(media, @[ userSelector ]);
        if (user)
            return user;
    }
    for (NSString *nestedSelector in @[ @"media", @"item", @"storyItem", @"reelShare", @"currentStoryItem", @"currentItem" ]) {
        id nested = SPKStoryFirstObjectForSelectors(media, @[ nestedSelector ]);
        if (!nested || nested == media)
            continue;
        id user = SPKStoryUserFromMediaObject(nested);
        if (user)
            return user;
    }
    return nil;
}

NSString *SPKStoryUserPKFromMediaObject(id media) {
    id user = SPKStoryUserFromMediaObject(media);
    return user ? [SPKUtils pkFromIGUser:user] : nil;
}

static NSString *SPKStoryNormalizeUsername(NSString *username) {
    NSString *trimmed = [[username ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if ([trimmed hasPrefix:@"@"])
        trimmed = [trimmed substringFromIndex:1];
    return trimmed;
}

static NSArray<NSDictionary *> *SPKStoryManualSeenUserListFromRawValue(id rawStored) {
    if (![rawStored isKindOfClass:[NSArray class]])
        return @[];

    NSMutableArray<NSDictionary *> *users = [NSMutableArray array];
    NSMutableSet<NSString *> *seenPks = [NSMutableSet set];

    for (id value in (NSArray *)rawStored) {
        if ([value isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)value;
            NSString *pk = SPKStringFromValue(dict[@"pk"]);
            NSString *username = SPKStoryNormalizeUsername(dict[@"username"]);

            if (pk.length > 0) {
                if ([seenPks containsObject:pk])
                    continue;
                [seenPks addObject:pk];
            } else {
                continue;
            }

            NSMutableDictionary *entry = [dict mutableCopy];
            if (username.length > 0)
                entry[@"username"] = username;
            if (!entry[@"fullName"])
                entry[@"fullName"] = @"";
            [users addObject:entry.copy];
        }
    }
    return users.copy;
}

NSArray *SPKStoryManualSeenUserList(BOOL manualSeenEnabled) {
    NSString *key = SPKStoryManualSeenListKey(manualSeenEnabled);
    id rawStored = SPKPreferenceObjectForKey(key);
    return SPKStoryManualSeenUserListFromRawValue(rawStored);
}

void SPKStorySetManualSeenUserList(NSArray *users, BOOL manualSeenEnabled) {
    (void)manualSeenEnabled;
    NSArray *normalized = SPKStoryManualSeenUserListFromRawValue(users);
    SPKPreferenceSetObject(normalized, SPKStoryManualSeenListKey(manualSeenEnabled));
}

BOOL SPKStoryManualSeenListContainsUser(NSString *pk, BOOL manualSeenEnabled) {
    if (pk.length == 0)
        return NO;
    NSArray<NSDictionary *> *users = SPKStoryManualSeenUserList(manualSeenEnabled);
    for (NSDictionary *user in users) {
        NSString *userPk = user[@"pk"];
        if (userPk.length > 0 && [pk isEqualToString:userPk]) {
            return YES;
        }
    }
    return NO;
}

BOOL SPKStoryManualSeenAppliesToContext(SPKStoryContext *context) {
    BOOL manualSeenEnabled = SPKStoryManualSeenEnabled();
    NSString *pk = SPKStoryUserPKFromMediaObject(context.media);
    BOOL listed = SPKStoryManualSeenListContainsUser(pk, manualSeenEnabled);
    return manualSeenEnabled ? !listed : listed;
}

// Deliberately not persisted and scoped to one story viewer: leaving stories
// (or a relaunch) always returns to blocking seen receipts, so a forgotten
// toggle cannot keep sending receipts. The weak reference also ends the
// session if the viewer is deallocated without a disappearance callback.
static __weak UIViewController *SPKStorySeenReceiptsSessionViewer = nil;

BOOL SPKStoryManualSeenEnabled(void) {
    NSString *mode = [SPKUtils getStringPref:@"stories_manual_seen_mode"];
    return [mode isEqualToString:@"tap"] || [mode isEqualToString:@"toggle"];
}

BOOL SPKStoryEyeButtonTogglesSeenReceipts(void) {
    return [[SPKUtils getStringPref:@"stories_manual_seen_mode"] isEqualToString:@"toggle"];
}

BOOL SPKStorySeenReceiptsSessionEnabled(void) {
    return SPKStorySeenReceiptsSessionViewer != nil && SPKStoryEyeButtonTogglesSeenReceipts();
}

void SPKStorySetSeenReceiptsSessionViewer(UIViewController *viewer) {
    SPKStorySeenReceiptsSessionViewer = viewer;
}

void SPKStoryEndSeenReceiptsSessionForViewer(UIViewController *viewer) {
    if (viewer && SPKStorySeenReceiptsSessionViewer == viewer)
        SPKStorySeenReceiptsSessionViewer = nil;
}

static void SPKStoryEnrichManualSeenUserEntryIfNeeded(NSDictionary *entry, BOOL manualSeenEnabled) {
    NSString *pk = SPKStringFromValue(entry[@"pk"]);
    NSString *username = SPKStringFromValue(entry[@"username"]);
    NSString *profilePicUrl = SPKStringFromValue(entry[@"profilePicUrl"]);
    if (pk.length == 0 || username.length == 0)
        return;
    if (profilePicUrl.length > 0)
        return; // already fully enriched!

    NSString *encodedUsername = [username stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    if (encodedUsername.length == 0)
        return;

    [SPKInstagramAPI sendRequestWithMethod:@"GET"
                                      path:[NSString stringWithFormat:@"users/web_profile_info/?username=%@", encodedUsername]
                                      body:nil
                                completion:^(NSDictionary *response, NSError *error) {
                                    NSDictionary *resolvedUser = response[@"data"][@"user"];
                                    if (![resolvedUser isKindOfClass:[NSDictionary class]])
                                        resolvedUser = response[@"user"];
                                    if (![resolvedUser isKindOfClass:[NSDictionary class]] || error) {
                                        return;
                                    }

                                    NSString *resolvedUsername = SPKStringFromValue(resolvedUser[@"username"]) ?: username;
                                    NSString *fullName = SPKStoryCleanDisplayName(SPKStringFromValue(resolvedUser[@"full_name"] ?: resolvedUser[@"fullName"]), resolvedUsername) ?: SPKStringFromValue(entry[@"fullName"]) ?
                                                                                                                                                                                                                           : @"";
                                    NSString *profilePic = SPKStringFromValue(resolvedUser[@"profile_pic_url"] ?: resolvedUser[@"profile_pic_url_hd"]);
                                    if (profilePic.length == 0)
                                        return;

                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        NSArray *users = SPKStoryManualSeenUserList(manualSeenEnabled);
                                        NSMutableArray *newUsers = [users mutableCopy];
                                        for (NSUInteger i = 0; i < newUsers.count; i++) {
                                            NSDictionary *u = newUsers[i];
                                            if ([u[@"pk"] isEqualToString:pk]) {
                                                NSMutableDictionary *mutU = [u mutableCopy];
                                                mutU[@"username"] = resolvedUsername;
                                                mutU[@"fullName"] = fullName;
                                                mutU[@"profilePicUrl"] = profilePic;
                                                newUsers[i] = mutU.copy;
                                                break;
                                            }
                                        }
                                        SPKStorySetManualSeenUserList(newUsers.copy, manualSeenEnabled);
                                    });
                                }];
}

void SPKStoryToggleUserForCurrentManualSeenMode(NSString *pk, NSString *username, NSString *fullName, NSString *profilePicUrl) {
    if (pk.length == 0)
        return;
    BOOL manualSeenEnabled = SPKStoryManualSeenEnabled();
    NSString *normalized = SPKStoryNormalizeUsername(username);

    NSArray<NSDictionary *> *users = SPKStoryManualSeenUserList(manualSeenEnabled);
    NSMutableArray<NSDictionary *> *newUsers = [users mutableCopy];

    NSInteger existingIndex = -1;
    for (NSInteger idx = 0; idx < (NSInteger)newUsers.count; idx++) {
        NSDictionary *user = newUsers[idx];
        NSString *userPk = user[@"pk"];
        if (userPk.length > 0 && [pk isEqualToString:userPk]) {
            existingIndex = idx;
            break;
        }
    }

    if (existingIndex >= 0) {
        [newUsers removeObjectAtIndex:existingIndex];
    } else {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"pk"] = pk;
        if (username.length > 0)
            entry[@"username"] = normalized;
        entry[@"fullName"] = fullName ?: @"";
        if (profilePicUrl.length > 0)
            entry[@"profilePicUrl"] = profilePicUrl;
        entry[@"addedAt"] = @([[NSDate date] timeIntervalSince1970]);
        [newUsers addObject:entry.copy];
        [newUsers sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSString *aName = a[@"username"] ?: @"";
            NSString *bName = b[@"username"] ?: @"";
            return [aName localizedCaseInsensitiveCompare:bName];
        }];
        SPKStoryEnrichManualSeenUserEntryIfNeeded(entry.copy, manualSeenEnabled);
    }
    SPKStorySetManualSeenUserList(newUsers.copy, manualSeenEnabled);
}

NSString *SPKStoryManualSeenListTitle(BOOL manualSeenEnabled) {
    return manualSeenEnabled ? SPKL(@"STORIES_STORY_CONTEXT_EXCLUDED_USERS_TEXT") : SPKL(@"STORIES_STORY_CONTEXT_INCLUDED_USERS_TEXT");
}

static NSString *SPKStoryManualSeenListModeTitle(BOOL manualSeenEnabled) {
    return manualSeenEnabled ? @"Excluded" : @"Included";
}

static NSString *SPKStoryManualSeenListHelpText(BOOL manualSeenEnabled) {
    return manualSeenEnabled
               ? SPKL(@"STORIES_STORY_CONTEXT_MANUALLY_MARK_SEEN_ENABLED_USERS_LIST_USE_INSTAGRAM_S_TEXT")
               : SPKL(@"STORIES_STORY_CONTEXT_MANUALLY_MARK_SEEN_DISABLED_ONLY_USERS_LIST_REQUIRE_EYE_TEXT");
}

#pragma mark - Manual-seen users list

@interface SPKStoryManualSeenUsersViewController : SPKUserListViewController
@property (nonatomic, assign) BOOL manualSeenEnabled;
@end

@implementation SPKStoryManualSeenUsersViewController

- (instancetype)init {
    if ((self = [super init])) {
        _manualSeenEnabled = SPKStoryManualSeenEnabled();
        self.title = SPKStoryManualSeenListTitle(_manualSeenEnabled);
        self.showsAddButton = YES;
        self.infoText = SPKStoryManualSeenListHelpText(_manualSeenEnabled);
        self.emptyTitle = SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_NO_USERS_YET_TEXT");
        self.emptySubtitle = _manualSeenEnabled
                                 ? SPKL(@"STORIES_STORY_CONTEXT_ADD_USERS_WHOSE_STORIES_SHOULD_KEEP_INSTAGRAM_S_NORMAL_TEXT")
                                 : SPKL(@"STORIES_STORY_CONTEXT_ADD_USERS_WHOSE_STORIES_REQUIRE_EYE_BUTTON_MARK_SEEN_TEXT");
    }
    return self;
}

- (NSArray<SPKUserListItem *> *)buildItems {
    NSArray<NSDictionary *> *users = SPKStoryManualSeenUserList(self.manualSeenEnabled);
    NSMutableArray<SPKUserListItem *> *items = [NSMutableArray array];
    for (NSDictionary *entry in users) {
        NSString *username = entry[@"username"];
        NSString *fullName = entry[@"fullName"];
        if (fullName.length == 0)
            fullName = SPKStoryCachedManualSeenUserName(username);

        NSString *pk = [entry[@"pk"] isKindOfClass:[NSString class]] ? entry[@"pk"] : nil;
        NSString *profilePicUrl = entry[@"profilePicUrl"];
        if (profilePicUrl.length == 0 && pk.length)
            profilePicUrl = spkDirectUserResolverProfilePicURLStringForPK(pk);

        SPKUserListItem *item = [SPKUserListItem new];
        item.pk = pk;
        item.title = username.length ? [@"@" stringByAppendingString:username] : SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_UNKNOWN_USER_TEXT");
        item.subtitle = fullName.length ? fullName : nil;
        item.avatarURLString = profilePicUrl;
        item.representedObject = entry;
        [items addObject:item];
    }
    return items;
}

- (void)listDidUpdateItemCount:(NSUInteger)count {
    self.title = [NSString stringWithFormat:@"%lu %@", (unsigned long)count, SPKStoryManualSeenListModeTitle(self.manualSeenEnabled)];
}

- (void)didDeleteItem:(SPKUserListItem *)item {
    NSDictionary *entry = item.representedObject;
    NSString *pk = [entry[@"pk"] isKindOfClass:[NSString class]] ? entry[@"pk"] : nil;
    if (pk.length == 0)
        return;
    NSString *username = entry[@"username"];

    NSMutableArray<NSDictionary *> *users = [SPKStoryManualSeenUserList(self.manualSeenEnabled) mutableCopy];
    for (NSUInteger idx = 0; idx < users.count; idx++) {
        if ([users[idx][@"pk"] isEqualToString:pk]) {
            [users removeObjectAtIndex:idx];
            break;
        }
    }
    SPKStorySetManualSeenUserList(users, self.manualSeenEnabled);
    SPKNotify(kSPKNotificationStorySeenUserRule,
              [NSString stringWithFormat:SPKL(@"STORIES_STORY_CONTEXT_REMOVED_VALUE_FORMAT"), username],
              SPKStoryManualSeenListTitle(self.manualSeenEnabled),
              @"circle_check_filled",
              SPKNotificationToneSuccess);
    [self reloadItems];
}

- (void)presentError:(NSString *)message {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_UNABLE_ADD_USER_TEXT")
                                                message:message
                                                actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK") style:SPKIGAlertActionStyleCancel handler:nil] ]];
}

- (void)didTapAdd {
    __weak typeof(self) weakSelf = self;
    [SPKIGAlertPresenter presentTextInputAlertFromViewController:self
                                                           title:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_ADD_USER_TEXT")
                                                         message:SPKL(@"STORIES_STORY_CONTEXT_ENTER_INSTAGRAM_USERNAME_ADD_TEXT")
                                                     placeholder:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_USERNAME_TEXT")
                                                     initialText:nil
                                                 autocapitalized:NO
                                                    confirmTitle:SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_SEARCH_TEXT")
                                                     cancelTitle:SPKL(@"VC_BTN_CANCEL")
                                                    confirmStyle:SPKIGAlertActionStyleDefault
                                                    confirmBlock:^(NSString *text) {
                                                        [weakSelf lookupUsername:text];
                                                    }
                                                     cancelBlock:nil];
}

- (void)lookupUsername:(NSString *)rawUsername {
    NSString *username = [SPKUtils sanitizedInstagramUsername:rawUsername];
    if (username.length == 0)
        return;

    __weak typeof(self) weakSelf = self;
    [SPKInstagramAPI resolveUserForUsername:username
                                  completion:^(NSDictionary *user, NSError *error) {
                                      __strong typeof(weakSelf) strongSelf = weakSelf;
                                      if (!strongSelf)
                                          return;
                                      if (![user isKindOfClass:[NSDictionary class]] || error) {
                                          [strongSelf presentError:[NSString stringWithFormat:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_USER_VALUE_NOT_FOUND_FORMAT"), username]];
                                          return;
                                      }
                                      NSString *pk = SPKStringFromValue(user[@"pk"] ?: user[@"id"]);
                                      NSString *resolvedUsername = SPKStringFromValue(user[@"username"]) ?: username;
                                      NSString *fullName = SPKStringFromValue(user[@"full_name"] ?: user[@"fullName"]) ?: @"";
                                      NSString *profilePicUrl = SPKStringFromValue(user[@"profile_pic_url"] ?: user[@"profile_pic_url_hd"]);
                                      if (pk.length == 0) {
                                          [strongSelf presentError:SPKL(@"MESSAGES_DIRECT_AUTO_SAVE_COULD_NOT_RESOLVE_USER_S_INSTAGRAM_ID_TEXT")];
                                          return;
                                      }

                                      NSString *message = fullName.length > 0
                                                              ? [NSString stringWithFormat:@"@%@ (%@)", resolvedUsername, fullName]
                                                              : [@"@" stringByAppendingString:resolvedUsername];

                                      [SPKIGAlertPresenter presentAlertFromViewController:strongSelf
                                                                                    title:SPKL(@"MESSAGES_DIRECT_SEEN_CONTEXT_ADD_LIST_QUESTION")
                                                                                  message:message
                                                                                  actions:@[
                                                                                      [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                                                  style:SPKIGAlertActionStyleCancel
                                                                                                                handler:nil],
                                                                                      [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_ADD")
                                                                                                                  style:SPKIGAlertActionStyleDefault
                                                                                                                handler:^{
                                                                                                                    [strongSelf addResolvedUserPK:pk username:resolvedUsername fullName:fullName profilePicUrl:profilePicUrl];
                                                                                                                }],
                                                                                  ]];
                                  }];
}

- (void)addResolvedUserPK:(NSString *)pk username:(NSString *)username fullName:(NSString *)fullName profilePicUrl:(NSString *)profilePicUrl {
    NSMutableArray<NSDictionary *> *users = [SPKStoryManualSeenUserList(self.manualSeenEnabled) mutableCopy];
    for (NSDictionary *u in users) {
        if ([u[@"pk"] isEqualToString:pk] || [u[@"username"] isEqualToString:username])
            return; // already listed
    }
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"pk"] = pk;
    entry[@"username"] = username;
    entry[@"fullName"] = fullName ?: @"";
    if (profilePicUrl.length > 0)
        entry[@"profilePicUrl"] = profilePicUrl;
    entry[@"addedAt"] = @([[NSDate date] timeIntervalSince1970]);
    [users addObject:entry.copy];
    [users sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(a[@"username"] ?: @"") localizedCaseInsensitiveCompare:(b[@"username"] ?: @"")];
    }];
    SPKStorySetManualSeenUserList(users, self.manualSeenEnabled);
    SPKNotify(kSPKNotificationStorySeenUserRule,
              [NSString stringWithFormat:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_ADDED_VALUE_FORMAT"), username],
              SPKStoryManualSeenListTitle(self.manualSeenEnabled),
              @"circle_check_filled",
              SPKNotificationToneSuccess);
    [self reloadItems];
}

@end

UIViewController *SPKStoryManualSeenListViewController(void) {
    return [[SPKStoryManualSeenUsersViewController alloc] init];
}

static BOOL SPKStoryCurrentUserRuleState(SPKStoryContext *context, NSString **outUsername, NSString **outListTitle, BOOL *outListed, BOOL *outManualSeenEnabled) {
    NSString *username = SPKStoryUsernameForContext(context);
    if (username.length == 0)
        return NO;

    BOOL manualSeenEnabled = SPKStoryManualSeenEnabled();
    NSString *pk = SPKStoryUserPKFromMediaObject(context.media);
    BOOL listed = SPKStoryManualSeenListContainsUser(pk, manualSeenEnabled);
    NSString *listTitle = SPKStoryManualSeenListTitle(manualSeenEnabled);

    if (outUsername)
        *outUsername = username;
    if (outListTitle)
        *outListTitle = listTitle;
    if (outListed)
        *outListed = listed;
    if (outManualSeenEnabled)
        *outManualSeenEnabled = manualSeenEnabled;
    return YES;
}

NSString *SPKStoryCurrentUserRuleActionTitle(SPKStoryContext *context) {
    NSString *username = nil;
    if (!SPKStoryCurrentUserRuleState(context, &username, NULL, NULL, NULL))
        return nil;
    BOOL applies = SPKStoryManualSeenAppliesToContext(context);
    return applies ? SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_START_MARKING_STORIES_SEEN_TEXT") : SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_STOP_MARKING_STORIES_SEEN_TEXT");
}

NSString *SPKStoryCurrentUserRuleConfirmationTitle(SPKStoryContext *context) {
    NSString *username = nil;
    if (!SPKStoryCurrentUserRuleState(context, &username, NULL, NULL, NULL))
        return nil;
    BOOL applies = SPKStoryManualSeenAppliesToContext(context);
    return applies ? SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_START_MARKING_STORIES_SEEN_TEXT") : SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_STOP_MARKING_STORIES_SEEN_TEXT");
}

NSString *SPKStoryCurrentUserRuleConfirmationMessage(SPKStoryContext *context) {
    NSString *username = nil;
    if (!SPKStoryCurrentUserRuleState(context, &username, NULL, NULL, NULL))
        return nil;
    BOOL applies = SPKStoryManualSeenAppliesToContext(context);
    return applies
               ? [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_START_MARKING_STORIES_VALUE_SEEN_FORMAT"), username]
               : [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_STOP_MARKING_STORIES_VALUE_SEEN_FORMAT"), username];
}

void SPKStoryToggleUserRuleForPK(NSString *pk, NSString *username, NSString *fullName, NSString *profilePicUrl) {
    if (pk.length == 0)
        return;
    BOOL manualSeenEnabled = SPKStoryManualSeenEnabled();
    BOOL listed = SPKStoryManualSeenListContainsUser(pk, manualSeenEnabled);
    SPKStoryToggleUserForCurrentManualSeenMode(pk, username, fullName, profilePicUrl);
    if (!listed) {
        if (username.length > 0 && fullName.length > 0) {
            SPKStoryRememberManualSeenUserName(username, fullName);
        }
        if (username.length > 0 && SPKStoryCleanDisplayName(fullName, username).length == 0) {
            SPKStoryResolveAndRememberManualSeenUserName(username, nil);
        }
    }
}

BOOL SPKStoryToggleCurrentUserRule(SPKStoryContext *context, NSString **notificationTitle, NSString **notificationSubtitle) {
    NSString *username = nil;
    NSString *listTitle = nil;
    BOOL listed = NO;
    BOOL manualSeenEnabled = NO;
    if (!SPKStoryCurrentUserRuleState(context, &username, &listTitle, &listed, &manualSeenEnabled))
        return NO;

    BOOL applies = SPKStoryManualSeenAppliesToContext(context);

    id user = SPKStoryUserFromMediaObject(context.media);
    NSString *pk = SPKStoryUserPKFromMediaObject(context.media);
    if (pk.length == 0) {
        pk = spkDirectUserResolverPKFromUser(user);
    }
    NSString *fullName = SPKStoryFullNameForContext(context);

    NSString *profilePicUrl = spkDirectUserResolverProfilePicURLStringForPK(pk);
    if (profilePicUrl.length == 0) {
        profilePicUrl = spkDirectUserResolverProfilePicURLStringFromUser(user);
    }

    SPKStoryToggleUserRuleForPK(pk, username, fullName, profilePicUrl);

    if (notificationTitle) {
        *notificationTitle = applies
                                 ? [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_STORIES_SEEN_ON_FORMAT"), username]
                                 : [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_STORIES_SEEN_OFF_FORMAT"), username];
    }
    if (notificationSubtitle)
        *notificationSubtitle = listTitle;
    return YES;
}
