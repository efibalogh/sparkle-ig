#import "SPKStrings.h"
#import "SPKStoryOpener.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "../../Utils.h"
#import "../UI/SPKNotificationCenter.h"

static NSString *const kSPKStoryHighlightReelPrefix = @"highlight:";

// The entry point Instagram itself uses when a viewer is launched from a link.
static const long long kSPKStoryViewerEntryPointPermalink = 27;

@interface SPKStoryLink ()
@property (nonatomic, copy, readwrite, nullable) NSString *reelPK;
@property (nonatomic, copy, readwrite, nullable) NSString *username;
@property (nonatomic, copy, readwrite, nullable) NSString *mediaPK;
@end

static BOOL SPKStoryLinkStringIsNumeric(NSString *string) {
    return string.length > 0 &&
           [string rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
}

// The /s/ token is base64, but links in the wild drop the padding and may use
// the URL-safe alphabet.
static NSString *SPKStoryLinkDecodedToken(NSString *token) {
    if (token.length == 0)
        return nil;
    NSString *normalized = [[token stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (normalized.length % 4 != 0)
        normalized = [normalized stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:normalized options:0];
    return data.length > 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

@implementation SPKStoryLink

+ (instancetype)linkWithURL:(NSURL *)url {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])
        return nil;

    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    for (NSString *component in url.pathComponents) {
        if (component.length > 0 && ![component isEqualToString:@"/"])
            [segments addObject:component];
    }
    if (segments.count < 2)
        return nil;

    SPKStoryLink *link = [SPKStoryLink new];
    NSString *first = segments[0].lowercaseString;
    if ([first isEqualToString:@"s"]) {
        NSString *reelPK = SPKStoryLinkDecodedToken(segments[1]);
        if (![reelPK hasPrefix:kSPKStoryHighlightReelPrefix] ||
            !SPKStoryLinkStringIsNumeric([reelPK substringFromIndex:kSPKStoryHighlightReelPrefix.length]))
            return nil;
        link.reelPK = reelPK;
        for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
            if ([item.name.lowercaseString isEqualToString:@"story_media_id"]) {
                NSString *mediaPK = [item.value componentsSeparatedByString:@"_"].firstObject;
                if (SPKStoryLinkStringIsNumeric(mediaPK))
                    link.mediaPK = mediaPK;
            }
        }
        return link;
    }

    if (![first isEqualToString:@"stories"])
        return nil;

    if ([segments[1].lowercaseString isEqualToString:@"highlights"]) {
        if (segments.count < 3 || !SPKStoryLinkStringIsNumeric(segments[2]))
            return nil;
        link.reelPK = [kSPKStoryHighlightReelPrefix stringByAppendingString:segments[2]];
        return link;
    }

    NSString *username = [SPKUtils sanitizedInstagramUsername:segments[1]];
    if (username.length == 0)
        return nil;
    link.username = username;
    if (segments.count >= 3 && SPKStoryLinkStringIsNumeric(segments[2]))
        link.mediaPK = segments[2];
    return link;
}

- (BOOL)isHighlight {
    return [self.reelPK hasPrefix:kSPKStoryHighlightReelPrefix];
}

@end

static id SPKStoryOpenerObject(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector])
        return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

// Newer builds vend the controller from the session; older ones only have the
// direct initializer.
static id SPKStoryOpenerPresentationController(id session) {
    id provider = SPKStoryOpenerObject(session, @"storyViewerPresentationControllerProvider");
    SEL make = NSSelectorFromString(@"makeWithEntryPoint:");
    if ([provider respondsToSelector:make])
        return ((id (*)(id, SEL, long long))objc_msgSend)(provider, make, kSPKStoryViewerEntryPointPermalink);

    Class controllerClass = NSClassFromString(@"IGStoryViewerPresentationController");
    SEL init = NSSelectorFromString(@"initWithUserSession_DEPRECATED:entryPoint:storyChainingDataController:");
    if (![controllerClass instancesRespondToSelector:init])
        return nil;
    return ((id (*)(id, SEL, id, long long, id))objc_msgSend)([controllerClass alloc], init, session, kSPKStoryViewerEntryPointPermalink, nil);
}

// The controller is the viewer's delegate and nothing else owns it, so it has to
// outlive the call that made it. One viewer is up at a time, so one slot does.
static id spk_activeStoryPresentationController;

BOOL SPKStoryOpenReel(NSString *reelPK, NSString *mediaPK, UIViewController *source) {
    if (reelPK.length == 0 || !source)
        return NO;

    id session = [SPKUtils activeUserSession];
    // The story map returns the canonical reel for a PK, creating an empty one
    // when it was never loaded. Instagram fills it in before presenting.
    id storyMap = SPKStoryOpenerObject(session, @"storyMap");
    SEL reelSelector = NSSelectorFromString(@"storyReelWithPK:");
    if (![storyMap respondsToSelector:reelSelector]) {
        SPKLog(@"Stories", @"[Sparkle StoryOpen] No story map for reel=%@", reelPK);
        return NO;
    }

    @try {
        id story = ((id (*)(id, SEL, id))objc_msgSend)(storyMap, reelSelector, reelPK);
        id controller = story ? SPKStoryOpenerPresentationController(session) : nil;
        if (!controller) {
            SPKLog(@"Stories", @"[Sparkle StoryOpen] No %@ for reel=%@", story ? @"presentation controller" : @"reel", reelPK);
            return NO;
        }

        spk_activeStoryPresentationController = controller;

        NSString *focusedMediaPK = [mediaPK componentsSeparatedByString:@"_"].firstObject;
        SEL focused = NSSelectorFromString(@"fetchAndPresentStory:focusedMediaID:sourceViewController:fromViewForAnimation:");
        SEL focusedLegacy = NSSelectorFromString(@"fetchAndPresentStoryViewerForReels:focusedReelPK:sourceViewController:fromViewForAnimation:"
                                                 @"trayDataSource:storyChainingProtocol:highlightsMainGridChainingProtocol:focusedMediaID:");
        SEL plain = NSSelectorFromString(@"fetchAndPresentStory:sourceViewController:storyEntryView:");
        if (focusedMediaPK.length > 0 && [controller respondsToSelector:focused]) {
            ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(controller, focused, story, focusedMediaPK, source, nil);
        } else if (focusedMediaPK.length > 0 && [controller respondsToSelector:focusedLegacy]) {
            ((void (*)(id, SEL, id, id, id, id, id, id, id, id))objc_msgSend)(controller, focusedLegacy, @[ story ], reelPK, source, nil, nil, nil, nil, focusedMediaPK);
        } else if ([controller respondsToSelector:plain]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(controller, plain, story, source, nil);
        } else {
            SPKLog(@"Stories", @"[Sparkle StoryOpen] Presentation controller has no known entry point for reel=%@", reelPK);
            return NO;
        }
    } @catch (NSException *exception) {
        SPKLog(@"Stories", @"[Sparkle StoryOpen] Opening reel=%@ threw: %@", reelPK, exception.reason);
        return NO;
    }

    SPKLog(@"Stories", @"[Sparkle StoryOpen] Requested reel=%@ media=%@ over %@", reelPK, mediaPK, NSStringFromClass(source.class));
    return YES;
}

#pragma mark - Highlight lookup

// The search sends nothing of its own. The profile, once on screen, has made
// Instagram load the account's highlight list into the story map, and Instagram's
// own data controller is asked to load the highlights that are still empty, with
// the same arguments the profile uses for its first three. A loaded reel lists
// the ID of every story in it even though only the first page of full stories
// comes down, so one load per highlight is enough to know what it holds.
static const NSUInteger kSPKStoryHighlightSearchLimit = 24;
static const NSUInteger kSPKStoryHighlightSearchBatchSize = 3;
static const NSTimeInterval kSPKStoryHighlightPollInterval = 0.4;
static const NSUInteger kSPKStoryHighlightListPolls = 15;
static const NSUInteger kSPKStoryHighlightBatchPolls = 20;
static const NSUInteger kSPKStoryHighlightProfileLoadPolls = 3;

// Bumped by every new search and by cancelling one. Each step of a search
// carries the generation it started under and stops once that is no longer the
// current one, so a cancelled search loads nothing further and never completes.
static NSUInteger spk_highlightSearchGeneration;

static BOOL SPKStoryHighlightSearchIsCurrent(NSUInteger generation) {
    return generation == spk_highlightSearchGeneration;
}

static NSString *SPKStoryBareMediaPK(id value) {
    NSString *string = [value isKindOfClass:NSString.class] ? value : ([value respondsToSelector:@selector(stringValue)] ? [value stringValue] : nil);
    return [string componentsSeparatedByString:@"_"].firstObject;
}

static NSString *SPKStoryReelPKOf(id reel) {
    id pk = SPKStoryOpenerObject(reel, @"pk");
    return [pk isKindOfClass:NSString.class] ? pk : nil;
}

static NSArray *SPKStoryReelMediaIDs(id reel) {
    id mediaIDs = SPKStoryOpenerObject(reel, @"mediaIds");
    return [mediaIDs isKindOfClass:NSArray.class] ? mediaIDs : @[];
}

static BOOL SPKStoryReelContainsMedia(id reel, NSString *mediaPK) {
    for (id identifier in SPKStoryReelMediaIDs(reel)) {
        if ([SPKStoryBareMediaPK(identifier) isEqualToString:mediaPK])
            return YES;
    }
    return NO;
}

// The account's highlights as Instagram currently holds them.
static NSArray *SPKStoryKnownHighlightsForUser(id storyMap, NSString *userPK) {
    NSMutableArray *highlights = [NSMutableArray array];
    id reels = SPKStoryOpenerObject(storyMap, @"allObjects");
    if (![reels isKindOfClass:NSArray.class])
        return highlights;
    for (id reel in reels) {
        if (![SPKStoryReelPKOf(reel) hasPrefix:kSPKStoryHighlightReelPrefix])
            continue;
        id ownerPK = SPKStoryOpenerObject(SPKStoryOpenerObject(reel, @"owner"), @"pk");
        if ([ownerPK isKindOfClass:NSString.class] && [ownerPK isEqualToString:userPK])
            [highlights addObject:reel];
    }
    return highlights;
}

// `firstPageOnly` is how the profile loads highlights: every story ID, but only
// the first page of full stories. Without it the whole highlight comes down.
static BOOL SPKStoryRequestHighlightLoad(id session, NSArray<NSString *> *reelPKs, BOOL firstPageOnly) {
    id controller = SPKStoryOpenerObject(session, @"storyDataController");
    NSString *module = @"profile";
    NSDictionary *params = firstPageOnly ? @{@"initial_story_media_fetch" : @1} : nil;
    const long long reason = 2;
    SEL fetch = NSSelectorFromString(@"fetchItemsForReelsWithReelPKs:containerModule:mediaID:injectMediaAtBeginning:reason:extraParams:sendRequestInBackground:");
    SEL legacyFetch = NSSelectorFromString(@"_fetchStoryMediaWithReelPKs:trimmedReelPKs:containerModule:mediaID:injectMediaAtBeginning:reason:extraParams:");
    @try {
        if ([controller respondsToSelector:fetch]) {
            ((void (*)(id, SEL, id, id, id, BOOL, long long, id, BOOL))objc_msgSend)(controller, fetch, reelPKs, module, nil, NO, reason, params, NO);
            return YES;
        }
        if ([controller respondsToSelector:legacyFetch]) {
            ((void (*)(id, SEL, id, id, id, id, BOOL, long long, id))objc_msgSend)(controller, legacyFetch, reelPKs, [reelPKs mutableCopy], module, nil, NO, reason, params);
            return YES;
        }
    } @catch (NSException *exception) {
        SPKLog(@"Stories", @"[Sparkle StoryOpen] Highlight load threw: %@", exception.reason);
    }
    return NO;
}

static void SPKStorySearchHighlights(id session, NSArray *highlights, NSString *mediaPK, NSUInteger generation,
                                     void (^completion)(NSString *reelPK, BOOL searched));

// Waits for the reels of one batch to fill in, then looks again.
static void SPKStoryAwaitHighlightBatch(id session, NSArray *highlights, NSArray *batch, NSUInteger pollsLeft, NSString *mediaPK,
                                        NSUInteger generation, void (^completion)(NSString *reelPK, BOOL searched)) {
    if (!SPKStoryHighlightSearchIsCurrent(generation))
        return;
    NSUInteger loaded = 0;
    for (id reel in batch) {
        if (SPKStoryReelMediaIDs(reel).count > 0)
            loaded++;
    }
    if (loaded == batch.count) {
        SPKStorySearchHighlights(session, highlights, mediaPK, generation, completion);
        return;
    }
    if (pollsLeft == 0) {
        // A batch that never arrives says nothing about what it holds.
        SPKLog(@"Stories", @"[Sparkle StoryOpen] Highlight batch did not load (%lu of %lu)", (unsigned long)loaded, (unsigned long)batch.count);
        completion(nil, NO);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKStoryHighlightPollInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKStoryAwaitHighlightBatch(session, highlights, batch, pollsLeft - 1, mediaPK, generation, completion);
    });
}

// One round: check everything loaded so far, then load the next few that are
// still empty. What is empty is worked out afresh each round, so a highlight
// Instagram loaded by itself in the meantime is never asked for again.
static void SPKStorySearchHighlights(id session, NSArray *highlights, NSString *mediaPK, NSUInteger generation,
                                     void (^completion)(NSString *reelPK, BOOL searched)) {
    if (!SPKStoryHighlightSearchIsCurrent(generation))
        return;
    NSMutableArray *batch = [NSMutableArray array];
    NSMutableArray<NSString *> *reelPKs = [NSMutableArray array];
    for (id reel in highlights) {
        if (SPKStoryReelContainsMedia(reel, mediaPK)) {
            completion(SPKStoryReelPKOf(reel), YES);
            return;
        }
        if (SPKStoryReelMediaIDs(reel).count == 0 && batch.count < kSPKStoryHighlightSearchBatchSize) {
            [batch addObject:reel];
            [reelPKs addObject:SPKStoryReelPKOf(reel)];
        }
    }
    if (batch.count == 0) {
        completion(nil, YES);
        return;
    }
    if (!SPKStoryRequestHighlightLoad(session, reelPKs, YES)) {
        completion(nil, NO);
        return;
    }
    SPKLog(@"Stories", @"[Sparkle StoryOpen] Loading %lu highlight(s)", (unsigned long)batch.count);
    SPKStoryAwaitHighlightBatch(session, highlights, batch, kSPKStoryHighlightBatchPolls, mediaPK, generation, completion);
}

// The profile loads its first few highlights by itself right after the list
// arrives. Starting the search before that lands would ask for the same
// highlights a second time, so it gets a short head start.
static void SPKStoryAwaitProfileLoad(NSArray *highlights, NSUInteger pollsLeft, NSUInteger generation, void (^ready)(void)) {
    if (!SPKStoryHighlightSearchIsCurrent(generation))
        return;
    BOOL anyLoaded = NO;
    for (id reel in highlights) {
        if (SPKStoryReelMediaIDs(reel).count > 0) {
            anyLoaded = YES;
            break;
        }
    }
    if (anyLoaded || pollsLeft == 0) {
        ready();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKStoryHighlightPollInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKStoryAwaitProfileLoad(highlights, pollsLeft - 1, generation, ready);
    });
}

// Implemented by SPKStoryHighlightTrays.x.
FOUNDATION_EXPORT NSArray *SPKStoryHighlightTraysForUser(NSString *userPK);

static BOOL SPKStoryOpenerFlag(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return [target respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
}

// Resolves the account's highlight list once the open profile has finished
// loading it. `authoritative` is YES when the list is the profile's own, in which
// case an empty list means the account has no highlights. Without a tracked
// profile list (feature hooks off) the story map stands in, and since that can be
// a stale fragment, nothing found there is treated as a real "no".
static void SPKStoryAwaitHighlightList(id session, NSString *userPK, NSUInteger pollsLeft, NSInteger previousCount, NSUInteger generation,
                                       void (^ready)(NSArray *highlights, BOOL authoritative)) {
    if (!SPKStoryHighlightSearchIsCurrent(generation))
        return;
    NSArray *trays = SPKStoryHighlightTraysForUser(userPK);
    NSArray *reels = nil;
    BOOL settled = trays.count > 0;
    for (id tray in trays) {
        if (!SPKStoryOpenerFlag(tray, @"hasInitiatedFetch") || SPKStoryOpenerFlag(tray, @"isFetching"))
            settled = NO;
        id trayReels = SPKStoryOpenerObject(tray, @"reels");
        if ([trayReels isKindOfClass:NSArray.class] && [trayReels count] > reels.count)
            reels = trayReels;
    }

    // Settled and unchanged since the last look: this is the profile's list.
    if (settled && (NSInteger)reels.count == previousCount) {
        ready(reels ?: @[], YES);
        return;
    }
    if (pollsLeft == 0) {
        if (trays.count > 0 && reels.count > 0) {
            ready(reels, YES);
        } else if (trays.count > 0) {
            ready(nil, NO);
        } else {
            ready(SPKStoryKnownHighlightsForUser(SPKStoryOpenerObject(session, @"storyMap"), userPK), NO);
        }
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKStoryHighlightPollInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKStoryAwaitHighlightList(session, userPK, pollsLeft - 1, settled ? (NSInteger)reels.count : -1, generation, ready);
    });
}

void SPKStoryFindHighlightContainingMedia(NSString *userPK, NSString *mediaPK, void (^completion)(NSString *reelPK, BOOL searched)) {
    if (!completion)
        return;
    NSString *bareMediaPK = SPKStoryBareMediaPK(mediaPK);
    id session = [SPKUtils activeUserSession];
    if (!session || !SPKStoryLinkStringIsNumeric(userPK) || !SPKStoryLinkStringIsNumeric(bareMediaPK)) {
        completion(nil, NO);
        return;
    }

    NSUInteger generation = ++spk_highlightSearchGeneration;
    SPKStoryAwaitHighlightList(session, userPK, kSPKStoryHighlightListPolls, -1, generation, ^(NSArray *highlights, BOOL authoritative) {
        if (highlights.count == 0) {
            // The profile's own empty list is an account without highlights. Any
            // other empty list only means it never arrived.
            SPKLog(@"Stories", @"[Sparkle StoryOpen] No highlights %@ for user=%@ (media=%@)", authoritative ? @"on the profile" : @"known", userPK, bareMediaPK);
            completion(nil, authoritative);
            return;
        }

        if (highlights.count > kSPKStoryHighlightSearchLimit)
            highlights = [highlights subarrayWithRange:NSMakeRange(0, kSPKStoryHighlightSearchLimit)];
        SPKStoryAwaitProfileLoad(highlights, kSPKStoryHighlightProfileLoadPolls, generation, ^{
            NSUInteger loaded = 0;
            for (id reel in highlights)
                loaded += SPKStoryReelMediaIDs(reel).count > 0 ? 1 : 0;
            SPKLog(@"Stories", @"[Sparkle StoryOpen] Searching user=%@ for media=%@: %lu highlight(s) %@, %lu already loaded",
                   userPK, bareMediaPK, (unsigned long)highlights.count, authoritative ? @"on the profile" : @"in the story map", (unsigned long)loaded);
            SPKStorySearchHighlights(session, highlights, bareMediaPK, generation, ^(NSString *reelPK, BOOL searched) {
                // A fragment of the list cannot prove the story is nowhere.
                searched = searched && (reelPK || authoritative);
                SPKLog(@"Stories", @"[Sparkle StoryOpen] media=%@ %@", bareMediaPK,
                       reelPK ? [@"is in " stringByAppendingString:reelPK] : (searched ? @"is in no highlight" : @"search did not finish"));
                completion(reelPK, searched);
            });
        });
    });
}

NSString *SPKStoryTitleForReelPK(NSString *reelPK) {
    id storyMap = SPKStoryOpenerObject([SPKUtils activeUserSession], @"storyMap");
    SEL stored = NSSelectorFromString(@"storedStoryReelWithPK:");
    if (reelPK.length == 0 || ![storyMap respondsToSelector:stored])
        return nil;
    id title = SPKStoryOpenerObject(((id (*)(id, SEL, id))objc_msgSend)(storyMap, stored, reelPK), @"title");
    return [title isKindOfClass:NSString.class] && [title length] > 0 ? title : nil;
}

#pragma mark - Expired stories

static BOOL SPKStoryReelHasLoadedItem(id reel, NSString *mediaPK) {
    id items = SPKStoryOpenerObject(reel, @"sortedItems");
    if (![items isKindOfClass:NSArray.class])
        return NO;
    for (id item in items) {
        if ([SPKStoryBareMediaPK(SPKStoryOpenerObject(item, @"pk")) isEqualToString:mediaPK])
            return YES;
    }
    return NO;
}

static void SPKStoryAwaitLoadedItem(id reel, NSString *mediaPK, NSUInteger pollsLeft, NSUInteger generation, void (^ready)(void)) {
    if (!SPKStoryHighlightSearchIsCurrent(generation))
        return;
    if (pollsLeft == 0 || SPKStoryReelHasLoadedItem(reel, mediaPK)) {
        ready();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKStoryHighlightPollInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPKStoryAwaitLoadedItem(reel, mediaPK, pollsLeft - 1, generation, ready);
    });
}

// The search leaves a highlight knowing all of its story IDs but holding only its
// first page of stories. The viewer can only start on a story it holds, and it
// does not fetch a reel that already has some, so a story further in would open
// the highlight from the beginning. The rest of that one highlight is loaded
// first when the wanted story is not among the ones in hand.
static void SPKStoryEnsureStoryLoaded(NSString *reelPK, NSString *mediaPK, NSUInteger generation, void (^ready)(void)) {
    id session = [SPKUtils activeUserSession];
    id storyMap = SPKStoryOpenerObject(session, @"storyMap");
    SEL stored = NSSelectorFromString(@"storedStoryReelWithPK:");
    id reel = [storyMap respondsToSelector:stored] ? ((id (*)(id, SEL, id))objc_msgSend)(storyMap, stored, reelPK) : nil;
    NSString *bareMediaPK = SPKStoryBareMediaPK(mediaPK);
    if (!reel || bareMediaPK.length == 0 || SPKStoryReelHasLoadedItem(reel, bareMediaPK) ||
        !SPKStoryRequestHighlightLoad(session, @[ reelPK ], NO)) {
        ready();
        return;
    }
    SPKLog(@"Stories", @"[Sparkle StoryOpen] media=%@ is past the first page of %@, loading the rest", bareMediaPK, reelPK);
    SPKStoryAwaitLoadedItem(reel, bareMediaPK, kSPKStoryHighlightBatchPolls, generation, ready);
}

// Instagram media PKs carry their creation time: the bits above the low 23 are
// milliseconds since this epoch.
static const unsigned long long kSPKInstagramMediaEpochMilliseconds = 1314220021721ULL;
static const NSTimeInterval kSPKStoryLiveWindow = 24 * 60 * 60;

NSDate *SPKStoryPostedDateForMediaPK(NSString *mediaPK) {
    NSString *bare = SPKStoryBareMediaPK(mediaPK);
    if (!SPKStoryLinkStringIsNumeric(bare))
        return nil;
    unsigned long long value = strtoull(bare.UTF8String, NULL, 10);
    if (value >> 23 == 0)
        return nil;
    return [NSDate dateWithTimeIntervalSince1970:((value >> 23) + kSPKInstagramMediaEpochMilliseconds) / 1000.0];
}

BOOL SPKStoryMediaIsPastLiveWindow(NSString *mediaPK) {
    NSDate *posted = SPKStoryPostedDateForMediaPK(mediaPK);
    return posted && -posted.timeIntervalSinceNow > kSPKStoryLiveWindow;
}

// The profile stack Sparkle pushes over a screen is rooted in this host.
static NSString *const kSPKStoryProfileHostClassName = @"SPKProfilePushHostViewController";

static void SPKStoryCollectProfileHosts(UIViewController *controller, NSMutableArray<UINavigationController *> *found, int depth) {
    if (!controller || depth > 30)
        return;
    if ([controller isKindOfClass:UINavigationController.class]) {
        UINavigationController *navigation = (UINavigationController *)controller;
        if ([NSStringFromClass(navigation.viewControllers.firstObject.class) isEqualToString:kSPKStoryProfileHostClassName] &&
            navigation.viewControllers.count > 1 && !navigation.isBeingDismissed)
            [found addObject:navigation];
    }
    for (UIViewController *child in controller.childViewControllers)
        SPKStoryCollectProfileHosts(child, found, depth + 1);
    SPKStoryCollectProfileHosts(controller.presentedViewController, found, depth + 1);
}

UIViewController *SPKStoryPresentationSourceOver(UIViewController *presenter) {
    // The pushed profile is looked for by what it is, not by following the
    // presenter's own chain: with a search controller active on the presenter,
    // that chain does not lead to the profile, and a viewer requested from the
    // presenter itself is silently dropped because something is already
    // presented over it.
    NSMutableArray<UINavigationController *> *hosts = [NSMutableArray array];
    SPKStoryCollectProfileHosts(presenter.view.window.rootViewController, hosts, 0);
    if (hosts.lastObject.topViewController)
        return hosts.lastObject.topViewController;

    UIViewController *top = presenter;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed)
        top = top.presentedViewController;
    if ([top isKindOfClass:UINavigationController.class])
        top = ((UINavigationController *)top).topViewController ?: top;
    return top;
}

// Stories found in no highlight, by media PK, with the time of the search. A
// story that is not in a highlight today rarely is tomorrow, and every search
// makes Instagram load highlights on the user's account, so a miss cannot be
// retried until it is a week old. Kept per account, since which highlights are
// visible depends on who is looking.
static NSString *const kSPKStoryHighlightMissesKey = @"stories_highlight_search_misses";
static const NSTimeInterval kSPKStoryHighlightMissLifetime = 7 * 24 * 60 * 60;

static NSDictionary<NSString *, NSNumber *> *SPKStoryLiveHighlightMisses(void) {
    NSDictionary *stored = SPKPreferenceObjectForKey(kSPKStoryHighlightMissesKey);
    if (![stored isKindOfClass:NSDictionary.class])
        return @{};
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSMutableDictionary *live = [NSMutableDictionary dictionary];
    [stored enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
        if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSNumber.class] &&
            now - [value doubleValue] < kSPKStoryHighlightMissLifetime)
            live[key] = value;
    }];
    return live;
}

static void SPKStoryNotifyNotInHighlight(void) {
    SPKNotify(kSPKNotificationGalleryOpenOriginal, SPKL(@"GALLERY_UNABLE_OPEN_ORIGINAL_STORY_TOAST"),
              SPKL(@"STORIES_STORY_OPENER_NOT_IN_HIGHLIGHT_TEXT"), @"error_filled", SPKNotificationToneError);
}

void SPKStoryOpenExpiredStory(NSString *userPK, NSString *mediaPK, UIViewController *presenter, void (^completion)(NSString *highlightPK)) {
    NSString *missKey = SPKStoryBareMediaPK(mediaPK);
    if (missKey.length > 0 && SPKStoryLiveHighlightMisses()[missKey]) {
        SPKLog(@"Stories", @"[Sparkle StoryOpen] media=%@ was in no highlight within the last week, not searching again", missKey);
        SPKStoryNotifyNotInHighlight();
        if (completion)
            completion(nil);
        return;
    }

    // The profile is already on screen and nothing else moves until the search
    // lands, which is a load per three highlights.
    // A pill with a cancel handler leaves dismissing itself to that handler.
    // Cancelling ends the search where it is: nothing more is loaded, no viewer
    // opens, and no miss is remembered.
    [[SPKNotificationCenter shared] beginTransientProgressWithTitle:SPKL(@"STORIES_STORY_OPENER_SEARCHING_HIGHLIGHTS_TEXT")
                                                           onCancel:^{
                                                               spk_highlightSearchGeneration++;
                                                               SPKLog(@"Stories", @"[Sparkle StoryOpen] Highlight search for media=%@ cancelled", missKey);
                                                               [[SPKNotificationCenter shared] dismissTransientProgressPill];
                                                           }];
    __weak UIViewController *weakPresenter = presenter;
    SPKStoryFindHighlightContainingMedia(userPK, mediaPK, ^(NSString *highlightPK, BOOL searched) {
        if (highlightPK.length > 0) {
            // The pill stays up until the viewer is actually requested.
            SPKStoryEnsureStoryLoaded(highlightPK, mediaPK, spk_highlightSearchGeneration, ^{
                [[SPKNotificationCenter shared] dismissTransientProgressPill];
                UIViewController *livePresenter = weakPresenter;
                if (livePresenter.view.window)
                    SPKStoryOpenReel(highlightPK, mediaPK, SPKStoryPresentationSourceOver(livePresenter));
                if (completion)
                    completion(highlightPK);
            });
            return;
        }
        [[SPKNotificationCenter shared] dismissTransientProgressPill];
        if (searched) {
            // Only a search that ran to the end is a real "no": one that never
            // finished must not lock the story out for a week.
            NSMutableDictionary *misses = [SPKStoryLiveHighlightMisses() mutableCopy];
            misses[missKey] = @(NSDate.date.timeIntervalSince1970);
            SPKPreferenceSetObject(misses.copy, kSPKStoryHighlightMissesKey);
            SPKStoryNotifyNotInHighlight();
        } else {
            SPKNotify(kSPKNotificationGalleryOpenOriginal, SPKL(@"GALLERY_UNABLE_OPEN_ORIGINAL_STORY_TOAST"),
                      SPKL(@"COMMON_ORIGINAL_CONTENT_UNAVAILABLE_TOAST"), @"error_filled", SPKNotificationToneError);
        }
        if (completion)
            completion(nil);
    });
}
