#import "SPKStrings.h"
#import "SPKGalleryOriginController.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "../../Utils.h"
#import "../ActionButton/ActionButtonLookupUtils.h"
#import "../Stories/SPKStoryContext.h"
#import "../Stories/SPKStoryOpener.h"
#import "../UI/SPKNotificationCenter.h"
#import "SPKGalleryCoreDataStack.h"
#import "SPKGalleryFile.h"
#import "SPKGallerySaveMetadata.h"

// Implemented by Features/General/OpenPostNativePush.xm.
FOUNDATION_EXPORT BOOL SPKOpenPostPushMediaURL(NSURL *url, UIViewController *presentingVC, void (^fallback)(void), void (^onDismiss)(void));

static NSString *SPKGalleryStringValue(id value) {
    if (!value || [value isKindOfClass:[NSNull class]])
        return nil;
    // KVC on a collection maps the key over its elements, so asking an array for
    // "pk" answers an array of pks. Its description is "(\n    123\n)", which used
    // to be stored as the pk itself. A single element is the value that was meant;
    // more than one is ambiguous, so it is no value at all.
    if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSOrderedSet class]] || [value isKindOfClass:[NSSet class]]) {
        NSArray *elements = [value isKindOfClass:[NSSet class]] ? [(NSSet *)value allObjects]
                            : [value isKindOfClass:[NSOrderedSet class]] ? [(NSOrderedSet *)value array]
                                                                           : (NSArray *)value;
        return elements.count == 1 ? SPKGalleryStringValue(elements.firstObject) : nil;
    }
    if ([value isKindOfClass:[NSDictionary class]])
        return nil;
    if ([value isKindOfClass:[NSString class]])
        return [(NSString *)value length] > 0 ? value : nil;
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *string = [value stringValue];
        return string.length > 0 ? string : nil;
    }
    if ([value respondsToSelector:@selector(description)]) {
        NSString *string = [value description];
        return string.length > 0 ? string : nil;
    }
    return nil;
}

static id SPKGalleryFieldCacheValue(id target, NSString *key) {
    if (!target || key.length == 0)
        return nil;
    if ([target isKindOfClass:[NSDictionary class]]) {
        id value = ((NSDictionary *)target)[key];
        return [value isKindOfClass:[NSNull class]] ? nil : value;
    }

    Ivar fieldCacheIvar = NULL;
    @try {
        for (Class cls = object_getClass(target); cls && !fieldCacheIvar; cls = class_getSuperclass(cls)) {
            fieldCacheIvar = class_getInstanceVariable(cls, "_fieldCache");
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (!fieldCacheIvar)
        return nil;

    id fieldCache = nil;
    @try {
        fieldCache = object_getIvar(target, fieldCacheIvar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (![fieldCache isKindOfClass:[NSDictionary class]])
        return nil;

    id value = ((NSDictionary *)fieldCache)[key];
    return [value isKindOfClass:[NSNull class]] ? nil : value;
}

static NSTimeInterval SPKGalleryTimestampFromValue(id value) {
    if (!value || [value isKindOfClass:[NSNull class]])
        return 0.0;
    if ([value isKindOfClass:[NSDate class]])
        return [(NSDate *)value timeIntervalSince1970];

    double raw = 0.0;
    if ([value respondsToSelector:@selector(doubleValue)]) {
        raw = [value doubleValue];
    }
    if (raw <= 0.0)
        return 0.0;
    if (raw > 1e15)
        raw /= 1000000.0;
    else if (raw > 1e12)
        raw /= 1000.0;
    return raw;
}

static NSDate *SPKGalleryDateFromTimestampValue(id value) {
    NSTimeInterval timestamp = SPKGalleryTimestampFromValue(value);
    if (timestamp <= 0.0)
        return nil;
    return [NSDate dateWithTimeIntervalSince1970:timestamp];
}

static NSString *SPKGalleryStringForSelector(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0)
        return nil;
    id value = SPKObjectForSelector(target, selectorName);
    if (!value)
        value = SPKKVCObject(target, selectorName);
    return SPKGalleryStringValue(value);
}

static NSURL *SPKGalleryURLForSelector(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0)
        return nil;
    id value = SPKObjectForSelector(target, selectorName);
    if (!value)
        value = SPKKVCObject(target, selectorName);
    if ([value isKindOfClass:[NSURL class]])
        return value;
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return [NSURL URLWithString:(NSString *)value];
    }
    return nil;
}

static id SPKGalleryNestedObjectForSelector(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0)
        return nil;
    id value = SPKObjectForSelector(target, selectorName);
    if (!value)
        value = SPKKVCObject(target, selectorName);
    if ([value isKindOfClass:[NSArray class]]) {
        return ((NSArray *)value).firstObject;
    }
    return value;
}

static NSString *SPKGalleryRecursiveStringForSelectors(id target, NSArray<NSString *> *selectorNames, NSInteger depth) {
    if (!target || depth > 3)
        return nil;

    for (NSString *selectorName in selectorNames) {
        NSString *value = SPKGalleryStringForSelector(target, selectorName);
        if (value.length > 0)
            return value;
    }

    for (NSString *selectorName in @[ @"media", @"item", @"storyItem", @"visualMessage", @"explorePostInFeed", @"rootItem", @"clipsItem", @"clipsMedia", @"post" ]) {
        id nested = SPKGalleryNestedObjectForSelector(target, selectorName);
        if (!nested || nested == target)
            continue;
        NSString *value = SPKGalleryRecursiveStringForSelectors(nested, selectorNames, depth + 1);
        if (value.length > 0)
            return value;
    }

    return nil;
}

static NSDate *SPKGalleryRecursiveDateForKeys(id target, NSArray<NSString *> *keys, NSInteger depth) {
    if (!target || depth > 3)
        return nil;

    for (NSString *key in keys) {
        id value = SPKObjectForSelector(target, key);
        if (!value)
            value = SPKKVCObject(target, key);
        if (!value)
            value = SPKGalleryFieldCacheValue(target, key);
        NSDate *date = SPKGalleryDateFromTimestampValue(value);
        if (date)
            return date;
    }

    for (NSString *selectorName in @[ @"media", @"item", @"storyItem", @"visualMessage", @"explorePostInFeed", @"rootItem", @"clipsItem", @"clipsMedia", @"post" ]) {
        id nested = SPKGalleryNestedObjectForSelector(target, selectorName);
        if (!nested || nested == target)
            continue;
        NSDate *date = SPKGalleryRecursiveDateForKeys(nested, keys, depth + 1);
        if (date)
            return date;
    }

    return nil;
}

static NSURL *SPKGalleryRecursiveURLForSelectors(id target, NSArray<NSString *> *selectorNames, NSInteger depth) {
    if (!target || depth > 3)
        return nil;

    for (NSString *selectorName in selectorNames) {
        NSURL *value = SPKGalleryURLForSelector(target, selectorName);
        if (value)
            return value;
    }

    for (NSString *selectorName in @[ @"media", @"item", @"storyItem", @"visualMessage", @"explorePostInFeed", @"rootItem", @"clipsItem", @"clipsMedia", @"post" ]) {
        id nested = SPKGalleryNestedObjectForSelector(target, selectorName);
        if (!nested || nested == target)
            continue;
        NSURL *value = SPKGalleryRecursiveURLForSelectors(nested, selectorNames, depth + 1);
        if (value)
            return value;
    }

    return nil;
}

static id SPKGalleryUserFromMedia(id media) {
    if (!media)
        return nil;

    for (NSString *selectorName in @[ @"user", @"owner", @"author", @"creator", @"actor", @"profileUser" ]) {
        id user = SPKObjectForSelector(media, selectorName);
        if (!user)
            user = SPKKVCObject(media, selectorName);
        if (user)
            return user;
    }

    for (NSString *nestedSelector in @[ @"media", @"item", @"storyItem", @"visualMessage" ]) {
        id nested = SPKObjectForSelector(media, nestedSelector);
        if (!nested)
            nested = SPKKVCObject(media, nestedSelector);
        if (nested && nested != media) {
            id user = SPKGalleryUserFromMedia(nested);
            if (user)
                return user;
        }
    }

    return nil;
}

static NSString *SPKGalleryProfileURLStringForUsername(NSString *username) {
    NSString *encodedUsername = [username stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    return encodedUsername.length > 0 ? [NSString stringWithFormat:@"instagram://user?username=%@", encodedUsername] : nil;
}

static NSString *SPKGalleryMediaURLStringFromMetadata(SPKGallerySaveMetadata *metadata) {
    if (metadata.sourceMediaURLString.length > 0) {
        SPKLog(@"General", @"[Sparkle Gallery] Origin URL from stored metadata URL source=%d url=%@", metadata.source, metadata.sourceMediaURLString);
        return metadata.sourceMediaURLString;
    }

    // Stories don't have /p/ shortcodes — build the story permalink from username + media pk.
    if (metadata.source == SPKGallerySourceStories) {
        NSString *identifier = [metadata.sourceMediaPK componentsSeparatedByString:@"_"].firstObject ?: metadata.sourceMediaPK;
        if (metadata.sourceUsername.length > 0 && identifier.length > 0) {
            NSString *encodedUsername = [metadata.sourceUsername stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
            NSString *encodedIdentifier = [identifier stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
            if (encodedUsername.length > 0 && encodedIdentifier.length > 0) {
                NSString *urlString = [NSString stringWithFormat:@"https://www.instagram.com/stories/%@/%@/", encodedUsername, encodedIdentifier];
                SPKLog(@"General", @"[Sparkle Gallery] Origin URL generated story link username=%@ id=%@ url=%@", metadata.sourceUsername, identifier, urlString);
                return urlString;
            }
        }
        SPKLog(@"General", @"[Sparkle Gallery] Not generating story origin URL (missing username/pk) username=%@ mediaPK=%@", metadata.sourceUsername, metadata.sourceMediaPK);
        return nil;
    }

    NSString *pathComponent = nil;
    if (metadata.source == SPKGallerySourceReels) {
        pathComponent = @"reel";
    } else if (metadata.source == SPKGallerySourceFeed || metadata.source == SPKGallerySourceProfile || metadata.source == SPKGallerySourceOther) {
        pathComponent = @"p";
    }
    if (pathComponent.length == 0) {
        SPKLog(@"General", @"[Sparkle Gallery] Not generating origin URL for source=%d code=%@", metadata.source, metadata.sourceMediaCode);
        return nil;
    }

    NSString *code = metadata.sourceMediaCode;
    if (code.length == 0) {
        // Derive the shortcode from the numeric media pk so the link lands on the
        // canonical post page rather than the generic feed viewer.
        code = [SPKUtils instagramShortcodeForMediaPK:metadata.sourceMediaPK];
    }
    if (code.length == 0) {
        SPKLog(@"General", @"[Sparkle Gallery] No origin URL metadata available source=%d", metadata.source);
        return nil;
    }
    NSString *urlString = [NSString stringWithFormat:@"https://www.instagram.com/%@/%@/", pathComponent, code];
    SPKLog(@"General", @"[Sparkle Gallery] Origin URL generated source=%d code=%@ url=%@", metadata.source, code, urlString);
    return urlString;
}

/// True when `url` is an Instagram post/reel web link (`/p/`, `/reel/`). Used to reject post links that leak into story metadata.
// A story saved while browsing a highlight has to remember the highlight, since
// the live-story link stops resolving once the story expires. The media object
// carries no trace of the reel it was reached through, so the viewer on screen
// is consulted, and only trusted when it is showing this same story.
static NSURL *SPKGalleryHighlightURLForVisibleStory(NSString *mediaPK) {
    NSString *bareMediaPK = [mediaPK componentsSeparatedByString:@"_"].firstObject;
    if (bareMediaPK.length == 0 || !NSThread.isMainThread)
        return nil;
    SPKStoryContext *context = SPKStoryContextFromOverlay(SPKStoryActiveOverlay());
    if (![SPKStoryMediaIdentifierForContext(context) isEqualToString:bareMediaPK])
        return nil;
    return SPKStoryHighlightURLForReelPK(SPKStoryReelPKForContext(context), bareMediaPK);
}

static BOOL SPKGalleryURLIsPostOrReel(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    return [path containsString:@"/p/"] || [path containsString:@"/reel/"] || [path containsString:@"/reels/"];
}

@implementation SPKGalleryOriginController

+ (void)populateProfileMetadata:(SPKGallerySaveMetadata *)metadata username:(NSString *)username user:(id)user {
    if (!metadata)
        return;

    if (username.length > 0) {
        metadata.sourceUsername = username;
        if (metadata.sourceProfileURLString.length == 0) {
            metadata.sourceProfileURLString = SPKGalleryProfileURLStringForUsername(username);
        }
    }

    NSString *userPK = SPKGalleryStringForSelector(user, @"pk");
    if (userPK.length == 0)
        userPK = SPKGalleryStringForSelector(user, @"id");
    if (userPK.length > 0)
        metadata.sourceUserPK = userPK;

    if (metadata.sourceFullName.length == 0) {
        NSString *fullName = SPKGalleryStringForSelector(user, @"fullName");
        if (fullName.length == 0)
            fullName = SPKGalleryStringForSelector(user, @"full_name");
        if (fullName.length > 0)
            metadata.sourceFullName = fullName;
    }

    NSURL *profileURL = nil;
    for (NSString *selectorName in @[ @"profileURL", @"profileUrl", @"url" ]) {
        profileURL = SPKGalleryURLForSelector(user, selectorName);
        if (profileURL)
            break;
    }
    if (!profileURL && username.length > 0) {
        profileURL = [NSURL URLWithString:SPKGalleryProfileURLStringForUsername(username)];
    }
    if (profileURL)
        metadata.sourceProfileURLString = profileURL.absoluteString;
}

+ (void)populateMetadata:(SPKGallerySaveMetadata *)metadata fromMedia:(id)media {
    if (!metadata || !media)
        return;

    NSString *explicitUsername = SPKGalleryStringForSelector(media, @"sourceUsername");
    if (explicitUsername.length > 0) {
        metadata.sourceUsername = explicitUsername;
        if (metadata.sourceProfileURLString.length == 0) {
            metadata.sourceProfileURLString = SPKGalleryProfileURLStringForUsername(explicitUsername);
        }
    }

    NSString *explicitUserPK = SPKGalleryStringForSelector(media, @"sourceUserPK");
    if (explicitUserPK.length > 0)
        metadata.sourceUserPK = explicitUserPK;

    NSString *explicitMediaPK = SPKGalleryStringForSelector(media, @"sourceMediaPK");
    if (explicitMediaPK.length > 0)
        metadata.sourceMediaPK = explicitMediaPK;

    NSString *explicitMediaURL = SPKGalleryStringForSelector(media, @"sourceMediaURLString");
    if (explicitMediaURL.length > 0)
        metadata.sourceMediaURLString = explicitMediaURL;

    id explicitPostedDate = SPKObjectForSelector(media, @"importPostedDate") ?: SPKKVCObject(media, @"importPostedDate");
    NSDate *postedDateOverride = [explicitPostedDate isKindOfClass:NSDate.class] ? (NSDate *)explicitPostedDate : SPKGalleryDateFromTimestampValue(explicitPostedDate);
    if (postedDateOverride)
        metadata.importPostedDate = postedDateOverride;

    id backingMedia = SPKObjectForSelector(media, @"backingMedia") ?: SPKKVCObject(media, @"backingMedia");
    if (backingMedia)
        media = backingMedia;

    NSString *username = SPKUsernameFromMediaObject(media);
    if (username.length == 0)
        username = explicitUsername;
    id user = SPKGalleryUserFromMedia(media);
    [self populateProfileMetadata:metadata username:username user:user];

    NSString *mediaPK = SPKGalleryRecursiveStringForSelectors(media, @[ @"pk", @"id", @"mediaID", @"mediaId" ], 0);
    if (mediaPK.length > 0)
        metadata.sourceMediaPK = mediaPK;

    NSString *mediaCode = SPKGalleryRecursiveStringForSelectors(media, @[ @"code", @"shortCode", @"shortcode", @"mediaCode", @"mediaShortcode", @"shortCodeToken" ], 0);
    if (mediaCode.length > 0)
        metadata.sourceMediaCode = mediaCode;

    if (!metadata.importPostedDate) {
        NSDate *postedDate = SPKGalleryRecursiveDateForKeys(media, @[ @"taken_at", @"takenAt", @"takenAtDate", @"device_timestamp", @"deviceTimestamp", @"created_at", @"createdAt", @"upload_time", @"uploadTime", @"published_time", @"publishedTime" ], 0);
        // DM story replies / visual messages carry no post date, only a send time on
        // their envelope; SPKUtils knows how to dig that out (and how to reject the
        // non-date values those loosely-named keys also hold).
        if (!postedDate)
            postedDate = [SPKUtils postedDateFromMediaObject:media];
        if (postedDate)
            metadata.importPostedDate = postedDate;
    }

    NSURL *mediaURL = SPKGalleryRecursiveURLForSelectors(media, @[ @"permalink", @"permaLink", @"shareURL", @"shareUrl", @"canonicalURL", @"canonicalUrl", @"permalinkURL", @"instagramURL", @"instagramUrl", @"webURL", @"webUrl" ], 0);

    // A story's media object often exposes a generic post/reel permalink that routes
    // to the feed viewer, not the story tray. Reject it so we build a proper
    // /stories/<user>/<pk>/ link below instead.
    if (mediaURL && metadata.source == SPKGallerySourceStories && SPKGalleryURLIsPostOrReel(mediaURL)) {
        SPKLog(@"General", @"[Sparkle Gallery] Rejecting post/reel permalink for story source=%d url=%@", metadata.source, mediaURL.absoluteString);
        mediaURL = nil;
    }

    if (metadata.source == SPKGallerySourceStories && metadata.sourceMediaURLString.length == 0) {
        NSURL *highlightURL = SPKGalleryHighlightURLForVisibleStory(metadata.sourceMediaPK);
        if (highlightURL)
            mediaURL = highlightURL;
    }

    if (mediaURL) {
        SPKLog(@"General", @"[Sparkle Gallery] Populated origin URL from media object source=%d url=%@", metadata.source, mediaURL.absoluteString);
    }
    if (!mediaURL) {
        NSString *generatedURLString = SPKGalleryMediaURLStringFromMetadata(metadata);
        if (generatedURLString.length > 0) {
            mediaURL = [NSURL URLWithString:generatedURLString];
        }
    }
    if (mediaURL)
        metadata.sourceMediaURLString = mediaURL.absoluteString;
}

+ (BOOL)openOriginalPostForGalleryFile:(SPKGalleryFile *)file {
    NSURL *url = [file preferredOriginalMediaURL];
    return url ? [SPKUtils openInstagramMediaURL:url] : NO;
}

+ (BOOL)openOriginalPostForGalleryFile:(SPKGalleryFile *)file
                    fromViewController:(UIViewController *)presentingVC
                        legacyFallback:(void (^)(void))legacyFallback
                             onDismiss:(void (^)(void))onDismiss {
    NSURL *url = [file preferredOriginalMediaURL];
    if (!url)
        return NO;

    if (presentingVC && file.source == SPKGallerySourceStories &&
        [self spk_openStoryLink:[SPKStoryLink linkWithURL:url] forGalleryFile:file fromViewController:presentingVC])
        return YES;

    // Preferred: keep this screen up and redirect Instagram's push onto a host
    // stack over it, so closing the post comes straight back here. Only the
    // instagram://media route can be redirected; anything else takes the legacy
    // path, which reveals the post by tearing this screen down.
    if (presentingVC && SPKOpenPostPushMediaURL(url, presentingVC, legacyFallback, onDismiss))
        return YES;

    if (![SPKUtils openInstagramMediaURL:url])
        return NO;
    if (legacyFallback)
        legacyFallback();
    return YES;
}

// A saved story or highlight opens the way it is reached in Instagram: the
// account's profile first, pushed over this screen, then the viewer over the
// profile. Closing the viewer leaves the profile, and going back from there
// returns here, so nothing is torn down.
+ (BOOL)spk_openStoryLink:(SPKStoryLink *)link
           forGalleryFile:(SPKGalleryFile *)file
       fromViewController:(UIViewController *)presentingVC {
    if (!link)
        return NO;

    __weak UIViewController *weakPresenter = presentingVC;
    NSString *mediaPK = link.mediaPK ?: file.sourceMediaPK;

    // A live-story link whose story is past its 24 hours cannot open: the story
    // has left the account's reel. It may have been added to a highlight since,
    // so it is looked for there. The media PK dates the story exactly; the save
    // date is the fallback for an item stored without one.
    BOOL liveStoryExpired = NO;
    if (!link.isHighlight) {
        liveStoryExpired = SPKStoryPostedDateForMediaPK(mediaPK)
                               ? SPKStoryMediaIsPastLiveWindow(mediaPK)
                               : (file.dateAdded && -file.dateAdded.timeIntervalSinceNow > 24 * 60 * 60);
    }

    void (^openViewer)(NSTimeInterval) = ^(NSTimeInterval delay) {
        // A live story's reel is keyed by its owner's PK, which the profile
        // lookup has filled in by now for items saved without one.
        NSString *reelPK = link.reelPK ?: file.sourceUserPK;
        UIViewController *presenter = weakPresenter;
        if (reelPK.length == 0 || !presenter)
            return;
        if (liveStoryExpired && mediaPK.length > 0) {
            SPKStoryOpenExpiredStory(reelPK, mediaPK, presenter, ^(NSString *highlightPK) {
                // Remember the highlight so the next open is direct, and say so:
                // this open was slow and the rest will not be.
                NSURL *highlightURL = SPKStoryHighlightURLForReelPK(highlightPK, mediaPK);
                if (!highlightURL)
                    return;
                file.sourceMediaURLString = highlightURL.absoluteString;
                [[SPKGalleryCoreDataStack shared] saveContext];
                SPKLog(@"Gallery", @"relinked expired story media=%@ to %@", mediaPK, highlightPK);
                SPKNotify(kSPKNotificationGalleryOpenOriginal, SPKL(@"GALLERY_GALLERY_ORIGIN_HIGHLIGHT_LINKED_TEXT"),
                          SPKStoryTitleForReelPK(highlightPK), @"info_filled", SPKNotificationToneInfo);
            });
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *livePresenter = weakPresenter;
            if (livePresenter.view.window)
                SPKStoryOpenReel(reelPK, mediaPK, SPKStoryPresentationSourceOver(livePresenter));
        });
    };

    BOOL hasProfile = [SPKUtils sanitizedInstagramUsername:file.sourceUsername].length > 0 || file.sourceUserPK.length > 0;
    if (!hasProfile) {
        if (link.reelPK.length == 0)
            return NO;
        openViewer(0);
        return YES;
    }

    // The viewer is requested after the profile's push has finished. Instagram
    // presents it as soon as the reel is ready, which for a cached reel is
    // immediately, and presenting over a stack mid-push drops the presentation.
    BOOL profileStarted = [self spk_openProfileForGalleryFile:file
                                           fromViewController:presentingVC
                                                   completion:^(__unused BOOL success, __unused BOOL didLink) {
                                                       openViewer(0.5);
                                                   }];
    // With a reel in hand the viewer was requested even if the profile was not,
    // so the caller must not also run its own route.
    return profileStarted || (link.reelPK ?: file.sourceUserPK).length > 0;
}

+ (BOOL)openProfileForGalleryFile:(SPKGalleryFile *)file {
    return [self openProfileForGalleryFile:file fromViewController:nil];
}

+ (BOOL)openProfileForGalleryFile:(SPKGalleryFile *)file fromViewController:(UIViewController *)presentingVC {
    return [self spk_openProfileForGalleryFile:file fromViewController:presentingVC completion:nil];
}

+ (void)openProfileForGalleryFile:(SPKGalleryFile *)file
               fromViewController:(UIViewController *)presentingVC
                       completion:(void (^)(BOOL success, BOOL didLink))completion {
    [self spk_openProfileForGalleryFile:file fromViewController:presentingVC completion:completion];
}

// Single implementation behind both. The BOOL is "an open was started", which is
// all a fire-and-forget caller can use; `completion` carries the real outcome.
+ (BOOL)spk_openProfileForGalleryFile:(SPKGalleryFile *)file
                   fromViewController:(UIViewController *)presentingVC
                           completion:(void (^)(BOOL success, BOOL didLink))completion {
    NSString *cleanUsername = [SPKUtils sanitizedInstagramUsername:file.sourceUsername];

    // A user pk is all digits. Anything else (an older build stored a collection's
    // description here) opens a profile IG cannot load, so drop it and let the
    // username path below resolve and store the real one.
    NSString *storedPK = file.sourceUserPK;
    if (storedPK.length > 0 &&
        [storedPK rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) {
        SPKLog(@"Gallery", @"discarding malformed sourceUserPK for @%@", cleanUsername ?: @"");
        file.sourceUserPK = nil;
        [[SPKGalleryCoreDataStack shared] saveContext];
    }

    // Items saved from a source that carried no user object have a username but
    // no pk, so every open pays the username -> pk lookup again. Resolve it once
    // and write it back: sourceUserPK is an existing optional attribute, so this
    // is a plain field update and needs no schema migration.
    //
    // A pk observed at save time is the person who actually posted the media,
    // while one resolved now is whoever holds that handle today. If the original
    // owner renamed and somebody else took the handle, this binds the wrong
    // person permanently -- so say so rather than doing it silently. The handle
    // is named in the toast, which is the only way the user can catch a link that
    // looks wrong to them and clear it from the file's details. The display name
    // is left out: the toast is one line and the handle is what was linked.
    //
    // There is no stored display name to compare against (the entity keeps a
    // username and a pk, not a name), so the tweak cannot detect the recycled
    // handle itself. Telling the user what was linked is the honest substitute.
    if (cleanUsername.length > 0 && file.sourceUserPK.length == 0) {
        [SPKUtils resolvePKForUsername:cleanUsername
                            completion:^(NSString *resolvedPK, __unused NSString *currentName) {
                                BOOL didLink = NO;
                                if (resolvedPK.length > 0 && file.sourceUserPK.length == 0) {
                                    didLink = YES;
                                    file.sourceUserPK = resolvedPK;
                                    [[SPKGalleryCoreDataStack shared] saveContext];
                                    SPKLog(@"Gallery", @"backfilled sourceUserPK=%@ for @%@", resolvedPK, cleanUsername);

                                    NSString *who = [NSString stringWithFormat:@"@%@", cleanUsername];
                                    SPKNotify(kSPKNotificationGalleryOpenProfile,
                                              SPKL(@"GALLERY_GALLERY_ORIGIN_ACCOUNT_LINKED_TEXT"),
                                              [NSString stringWithFormat:SPKL(@"GALLERY_GALLERY_ORIGIN_VALUE_SAVED_ITEM_SO_OPENS_INSTANTLY_NOW_FORMAT"), who],
                                              @"info_filled",
                                              SPKNotificationToneInfo);
                                }
                                BOOL opened = [SPKUtils openInstagramProfileForUser:nil
                                                                                pk:resolvedPK
                                                                          username:cleanUsername
                                                                fromViewController:presentingVC];
                                if (completion)
                                    completion(opened, didLink);
                            }];
        return YES;
    }

    if (cleanUsername.length > 0) {
        if ([SPKUtils openInstagramProfileForUser:nil pk:file.sourceUserPK username:cleanUsername fromViewController:presentingVC]) {
            if (completion)
                completion(YES, NO);
            return YES;
        }
    }
    if (file.sourceUserPK.length > 0) {
        if ([SPKUtils openInstagramProfileForUser:nil pk:file.sourceUserPK username:nil fromViewController:presentingVC]) {
            if (completion)
                completion(YES, NO);
            return YES;
        }
    }
    NSURL *url = [file preferredProfileURL];
    if (url) {
        NSString *urlStr = url.absoluteString;
        NSRange userRange = [urlStr rangeOfString:@"username="];
        if (userRange.location != NSNotFound) {
            NSString *extracted = [urlStr substringFromIndex:userRange.location + userRange.length];
            NSRange ampRange = [extracted rangeOfString:@"&"];
            if (ampRange.location != NSNotFound) {
                extracted = [extracted substringToIndex:ampRange.location];
            }
            extracted = [SPKUtils sanitizedInstagramUsername:extracted];
            if (extracted.length > 0) {
                BOOL opened = [SPKUtils openInstagramProfileForUsername:extracted fromViewController:presentingVC];
                if (completion)
                    completion(opened, NO);
                return opened;
            }
        }
    }
    if (completion)
        completion(NO, NO);
    return NO;
}

@end
