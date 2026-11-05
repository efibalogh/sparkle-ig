#import "SPKStrings.h"
#import <objc/runtime.h>

#import "../../Shared/ActionButton/ActionButtonLookupUtils.h"
#import "../../Shared/Stories/SPKStoryContext.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"

static const void *kSPKShareCopyLongPressAssocKey = &kSPKShareCopyLongPressAssocKey;
static NSHashTable<UIGestureRecognizer *> *SPKShareCopyLongPressRecognizers(void) {
    static NSHashTable<UIGestureRecognizer *> *recognizers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        recognizers = [NSHashTable weakObjectsHashTable];
    });
    return recognizers;
}

static inline BOOL SPKShareLongPressCopyEnabled(void) {
    return [SPKUtils getBoolPref:@"general_hold_send_copy_link"];
}

static NSString *SPKShareDebugViewName(UIView *view) {
    return view ? [NSString stringWithFormat:@"%@<%p>", NSStringFromClass(view.class), view] : @"nil";
}

static NSString *SPKShareStringValue(id value) {
    NSString *string = SPKStringFromValue(value);
    return string.length > 0 ? string : nil;
}

static NSString *SPKShareStringForSelectorOrIvar(id object, NSString *name) {
    NSString *value = SPKShareStringValue(SPKObjectForSelector(object, name));
    if (value.length > 0)
        return value;

    value = SPKShareStringValue(SPKKVCObject(object, name));
    if (value.length > 0)
        return value;

    NSString *ivarName = [NSString stringWithFormat:@"_%@", name];
    return SPKShareStringValue([SPKUtils getIvarForObj:object name:ivarName.UTF8String]);
}

static NSString *SPKShareURLPathForObject(id object) {
    NSString *className = NSStringFromClass([object class]).lowercaseString ?: @"";
    if ([className containsString:@"reel"] || [className containsString:@"clips"] || [className containsString:@"sundial"]) {
        return @"reel";
    }

    for (NSString *selectorName in @[ @"productType", @"mediaType", @"mediaSource", @"inventorySource" ]) {
        NSString *value = SPKShareStringForSelectorOrIvar(object, selectorName).lowercaseString;
        if ([value containsString:@"reel"] || [value containsString:@"clips"]) {
            return @"reel";
        }
    }
    return @"p";
}

static NSURL *SPKInstagramPostURLForCode(NSString *code, id object) {
    if (code.length == 0)
        return nil;
    NSString *path = SPKShareURLPathForObject(object);
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://www.instagram.com/%@/%@/", path, code]];
}

static BOOL SPKShareObjectCanExposeMediaPK(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0)
        return NO;
    NSString *className = NSStringFromClass([object class]).lowercaseString ?: @"";
    if ([className containsString:@"user"] || [className containsString:@"session"] || [className containsString:@"account"])
        return NO;
    if ([selectorName isEqualToString:@"currentMediaPK"])
        return YES;
    if ([className containsString:@"media"] || [className containsString:@"feed"] || [className containsString:@"ufi"] ||
        [className containsString:@"reel"] || [className containsString:@"sundial"] || [className containsString:@"clips"] ||
        [className containsString:@"post"]) {
        return YES;
    }
    return NO;
}

static NSString *SPKInstagramShortcodeForMediaPK(NSString *mediaPK) {
    return [SPKUtils instagramShortcodeForMediaPK:mediaPK];
}

static NSURL *SPKInstagramPostURLForMediaPK(NSString *mediaPK, id object, NSString *selectorName) {
    if (!SPKShareObjectCanExposeMediaPK(object, selectorName))
        return nil;
    NSString *code = SPKInstagramShortcodeForMediaPK(mediaPK);
    NSURL *url = SPKInstagramPostURLForCode(code, object);
    if (url) {
        SPKLog(@"General", @"[Sparkle ShareCopy] Using media PK fallback class=%@ selector=%@ mediaPK=%@ code=%@ url=%@",
               NSStringFromClass([object class]), selectorName, mediaPK, code, url.absoluteString);
    }
    return url;
}

static NSString *SPKShareMediaIDFromObject(id object) {
    for (NSString *selectorName in @[ @"pk", @"id", @"mediaID", @"mediaId", @"mediaIdentifier" ]) {
        NSString *identifier = SPKShareStringForSelectorOrIvar(object, selectorName);
        if (identifier.length > 0) {
            NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@"_"];
            NSString *mediaID = parts.firstObject ?: identifier;
            return mediaID.length > 0 ? mediaID : identifier;
        }
    }
    return nil;
}

static NSURL *SPKInstagramStoryURLForMedia(id media) {
    NSString *username = SPKUsernameFromMediaObject(media);
    NSString *identifier = SPKShareMediaIDFromObject(media);
    if (username.length == 0 || identifier.length == 0)
        return nil;

    NSString *encodedUsername = [username stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSString *encodedIdentifier = [identifier stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    if (encodedUsername.length == 0 || encodedIdentifier.length == 0)
        return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://www.instagram.com/stories/%@/%@/", encodedUsername, encodedIdentifier]];
}

static BOOL SPKShareURLIsStoryURL(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    return [path containsString:@"/stories/"] || [path hasPrefix:@"/s/"];
}

static BOOL SPKShareURLIsPostOrReelURL(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    return [path containsString:@"/p/"] || [path containsString:@"/reel/"] || [path containsString:@"/reels/"];
}

static BOOL SPKShareObjectLooksStoryLike(id object) {
    if (!object)
        return NO;
    NSString *className = NSStringFromClass([object class]).lowercaseString ?: @"";
    if ([className containsString:@"story"])
        return YES;

    for (NSString *selectorName in @[ @"productType", @"mediaType", @"mediaSource", @"inventorySource", @"mediaSubtype" ]) {
        NSString *lower = SPKShareStringForSelectorOrIvar(object, selectorName).lowercaseString;
        if ([lower containsString:@"story"])
            return YES;
    }
    return NO;
}

static BOOL SPKShareViewGraphLooksStoryLike(UIView *view) {
    for (UIView *walker = view; walker; walker = walker.superview) {
        if (SPKShareObjectLooksStoryLike(walker))
            return YES;

        id delegate = SPKObjectForSelector(walker, @"delegate");
        if (SPKShareObjectLooksStoryLike(delegate))
            return YES;

        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(walker.class, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@')
                continue;
            id value = nil;
            @try {
                value = object_getIvar(walker, ivars[i]);
            } @catch (__unused NSException *exception) {
            }
            if (SPKShareObjectLooksStoryLike(value)) {
                if (ivars)
                    free(ivars);
                return YES;
            }
        }
        if (ivars)
            free(ivars);
    }

    UIViewController *controller = [SPKUtils nearestViewControllerForView:view];
    return SPKShareObjectLooksStoryLike(controller);
}

static NSURL *SPKShareCanonicalPostOrReelURLFromObjectAtDepth(id object, NSInteger depth) {
    if (!object || depth > 3)
        return nil;

    for (NSString *selectorName in @[ @"permalink", @"permaLink", @"shareURL", @"shareUrl", @"canonicalURL", @"canonicalUrl", @"permalinkURL", @"instagramURL", @"instagramUrl", @"webURL", @"webUrl", @"url" ]) {
        NSURL *url = SPKURLFromValue(SPKObjectForSelector(object, selectorName));
        if (!url)
            url = SPKURLFromValue(SPKKVCObject(object, selectorName));
        if (SPKShareURLIsPostOrReelURL(url))
            return url;
    }

    for (NSString *selectorName in @[ @"code", @"shortCode", @"shortcode", @"mediaCode", @"mediaShortcode", @"shortCodeToken" ]) {
        if (SPKShareObjectLooksStoryLike(object))
            break;
        NSString *code = SPKShareStringForSelectorOrIvar(object, selectorName);
        NSURL *url = SPKInstagramPostURLForCode(code, object);
        if (url)
            return url;
    }

    for (NSString *selectorName in @[ @"currentMediaPK", @"mediaPK", @"mediaPk", @"mediaID", @"mediaId", @"mediaIdentifier", @"pk" ]) {
        if (SPKShareObjectLooksStoryLike(object))
            break;
        NSString *mediaPK = SPKShareStringForSelectorOrIvar(object, selectorName);
        NSURL *url = SPKInstagramPostURLForMediaPK(mediaPK, object, selectorName);
        if (url)
            return url;
    }

    for (NSString *selectorName in @[ @"media", @"post", @"story", @"storyItem", @"storyMedia", @"mediaItem", @"reelMediaItem", @"item", @"currentStoryItem", @"visualMessage", @"model" ]) {
        id nested = SPKObjectForSelector(object, selectorName);
        if (!nested)
            nested = SPKKVCObject(object, selectorName);
        NSURL *url = SPKShareCanonicalPostOrReelURLFromObjectAtDepth(nested, depth + 1);
        if (url)
            return url;
    }

    return nil;
}

static NSURL *SPKShareURLFromObjectAtDepth(id object, NSInteger depth) {
    if (!object || depth > 3)
        return nil;

    for (NSString *selectorName in @[ @"permalink", @"permaLink", @"shareURL", @"shareUrl", @"canonicalURL", @"canonicalUrl", @"permalinkURL", @"instagramURL", @"instagramUrl", @"webURL", @"webUrl", @"url" ]) {
        NSURL *url = SPKURLFromValue(SPKObjectForSelector(object, selectorName));
        if (url)
            return url;
        url = SPKURLFromValue(SPKKVCObject(object, selectorName));
        if (url)
            return url;
    }

    for (NSString *selectorName in @[ @"code", @"shortCode", @"shortcode", @"mediaCode", @"mediaShortcode", @"shortCodeToken" ]) {
        if (SPKShareObjectLooksStoryLike(object))
            break;
        NSString *code = SPKShareStringForSelectorOrIvar(object, selectorName);
        NSURL *url = SPKInstagramPostURLForCode(code, object);
        if (url)
            return url;
    }

    for (NSString *selectorName in @[ @"currentMediaPK", @"mediaPK", @"mediaPk", @"mediaID", @"mediaId", @"mediaIdentifier", @"pk" ]) {
        if (SPKShareObjectLooksStoryLike(object))
            break;
        NSString *mediaPK = SPKShareStringForSelectorOrIvar(object, selectorName);
        NSURL *url = SPKInstagramPostURLForMediaPK(mediaPK, object, selectorName);
        if (url)
            return url;
    }

    for (NSString *selectorName in @[ @"media", @"post", @"story", @"storyItem", @"storyMedia", @"mediaItem", @"reelMediaItem", @"item", @"currentStoryItem", @"visualMessage", @"model" ]) {
        id nested = SPKObjectForSelector(object, selectorName);
        if (!nested)
            nested = SPKKVCObject(object, selectorName);
        NSURL *url = SPKShareURLFromObjectAtDepth(nested, depth + 1);
        if (url)
            return url;
    }

    return nil;
}

static id SPKShareStorySectionControllerFromOverlay(UIView *overlayView) {
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

static id SPKShareStoryMediaFromAnyObject(id object) {
    if (!object)
        return nil;
    for (NSString *selectorName in @[ @"media", @"mediaItem", @"storyItem", @"item", @"model" ]) {
        id candidate = SPKObjectForSelector(object, selectorName);
        if (!candidate)
            candidate = SPKKVCObject(object, selectorName);
        if (candidate && candidate != object)
            return candidate;
    }
    return object;
}

static id SPKShareStoryMediaFromOverlay(UIView *overlayView) {
    if (!overlayView)
        return nil;

    id sectionController = SPKShareStorySectionControllerFromOverlay(overlayView);
    UIViewController *viewerController = [SPKUtils nearestViewControllerForView:overlayView];
    if (!sectionController) {
        sectionController = SPKObjectForSelector(viewerController, @"currentSectionController");
        if (!sectionController)
            sectionController = SPKKVCObject(viewerController, @"currentSectionController");
        if (!sectionController)
            sectionController = [SPKUtils getIvarForObj:viewerController name:"_currentSectionController"];
    }

    for (id object in @[ sectionController ?: (id)NSNull.null, viewerController ?: (id)NSNull.null ]) {
        if (object == (id)NSNull.null)
            continue;
        for (NSString *selectorName in @[ @"currentStoryItem", @"currentItem", @"item" ]) {
            id media = SPKObjectForSelector(object, selectorName);
            if (!media)
                media = SPKKVCObject(object, selectorName);
            media = SPKShareStoryMediaFromAnyObject(media);
            if (media)
                return media;
        }
    }
    return nil;
}

static NSURL *SPKShareStoryURLFromOverlay(UIView *overlayView) {
    SPKStoryContext *context = SPKStoryContextFromOverlay(overlayView);
    id media = SPKShareStoryMediaFromOverlay(overlayView);
    NSURL *canonicalURL = SPKShareCanonicalPostOrReelURLFromObjectAtDepth(context.media ?: media, 0);
    if (canonicalURL)
        return canonicalURL;
    NSURL *sharedURL = SPKStoryURLForContext(context);
    if (sharedURL)
        return sharedURL;
    NSURL *url = SPKInstagramStoryURLForMedia(media);
    if (url)
        return url;
    return SPKShareURLFromObjectAtDepth(media, 0);
}

static UIView *SPKShareStoryOverlayAncestorForView(UIView *view) {
    for (UIView *walker = view; walker; walker = walker.superview) {
        if ([NSStringFromClass(walker.class) containsString:@"IGStoryFullscreenOverlayView"])
            return walker;
    }
    return nil;
}

static UIView *SPKShareStoryOverlayForView(UIView *view) {
    UIView *overlay = SPKShareStoryOverlayAncestorForView(view);
    if (overlay)
        return overlay;

    UIView *activeOverlay = SPKStoryActiveOverlay();
    if (!activeOverlay || !activeOverlay.window || activeOverlay.window != view.window)
        return nil;
    if (!SPKShareViewGraphLooksStoryLike(view))
        return nil;

    SPKLog(@"General", @"[Sparkle ShareCopy] Using active story overlay for detached story control view=%@ overlay=%@", SPKShareDebugViewName(view), SPKShareDebugViewName(activeOverlay));
    return activeOverlay;
}

static NSURL *SPKShareURLFromViewHierarchy(UIView *view, BOOL canonicalOnly) {
    UIView *walker = view;
    for (NSInteger depth = 0; walker && depth < 24; depth++, walker = walker.superview) {
        NSURL *url = canonicalOnly ? SPKShareCanonicalPostOrReelURLFromObjectAtDepth(walker, 0) : SPKShareURLFromObjectAtDepth(walker, 0);
        if (url)
            return url;

        id delegate = SPKObjectForSelector(walker, @"delegate");
        url = canonicalOnly ? SPKShareCanonicalPostOrReelURLFromObjectAtDepth(delegate, 0) : SPKShareURLFromObjectAtDepth(delegate, 0);
        if (url)
            return url;

        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(walker.class, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@')
                continue;
            id value = nil;
            @try {
                value = object_getIvar(walker, ivars[i]);
            } @catch (__unused NSException *exception) {
            }
            url = canonicalOnly ? SPKShareCanonicalPostOrReelURLFromObjectAtDepth(value, 0) : SPKShareURLFromObjectAtDepth(value, 0);
            if (url) {
                if (ivars)
                    free(ivars);
                return url;
            }
        }
        if (ivars)
            free(ivars);
    }

    UIViewController *controller = [SPKUtils nearestViewControllerForView:view];
    return canonicalOnly ? SPKShareCanonicalPostOrReelURLFromObjectAtDepth(controller, 0) : SPKShareURLFromObjectAtDepth(controller, 0);
}

static NSURL *SPKShareURLFromView(UIView *view) {
    UIView *storyOverlay = SPKShareStoryOverlayForView(view);
    SPKLog(@"General", @"[Sparkle ShareCopy] Resolving link for view=%@ storyOverlay=%@", SPKShareDebugViewName(view), SPKShareDebugViewName(storyOverlay));

    if (storyOverlay) {
        NSURL *storyURL = SPKShareStoryURLFromOverlay(storyOverlay);
        if (storyURL) {
            SPKLog(@"General", @"[Sparkle ShareCopy] Using story-overlay URL: %@", storyURL.absoluteString);
            return storyURL;
        }
        SPKLog(@"General", @"[Sparkle ShareCopy] Story overlay present but no story URL resolved");
    }

    NSURL *canonicalURL = SPKShareURLFromViewHierarchy(view, YES);
    if (canonicalURL) {
        SPKLog(@"General", @"[Sparkle ShareCopy] Using canonical post/reel URL: %@", canonicalURL.absoluteString);
        return canonicalURL;
    }

    NSURL *url = SPKShareURLFromViewHierarchy(view, NO);
    if (url && storyOverlay == nil && SPKShareURLIsStoryURL(url)) {
        SPKLog(@"General", @"[Sparkle ShareCopy] Rejected story URL outside story overlay: %@", url.absoluteString);
        return nil;
    }
    if (url) {
        SPKLog(@"General", @"[Sparkle ShareCopy] Using generic hierarchy URL: %@", url.absoluteString);
    } else {
        SPKLog(@"General", @"[Sparkle ShareCopy] No URL resolved for view=%@", SPKShareDebugViewName(view));
    }
    return url;
}

static NSString *SPKCopiedShareLinkTitleForURL(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    if (SPKShareURLIsStoryURL(url))
        return SPKL(@"GENERAL_SHARE_LONG_PRESS_COPY_COPIED_STORY_LINK_TEXT");
    if ([path containsString:@"/reel/"] || [path containsString:@"/reels/"])
        return SPKL(@"GENERAL_SHARE_LONG_PRESS_COPY_COPIED_REEL_LINK_TEXT");
    if ([path containsString:@"/p/"])
        return SPKL(@"GENERAL_SHARE_LONG_PRESS_COPY_COPIED_POST_LINK_TEXT");
    return SPKL(@"GENERAL_SHARE_LONG_PRESS_COPY_COPIED_LINK_TEXT");
}

static void SPKCopyShareURLForView(UIView *view) {
    if (!SPKShareLongPressCopyEnabled())
        return;
    NSURL *url = SPKShareURLFromView(view);
    if ([SPKUtils getBoolPref:@"general_strip_share_link_tracking"]) {
        NSURL *sanitized = [SPKUtils sanitizedInstagramShareURL:url];
        if (sanitized && ![sanitized.absoluteString isEqualToString:url.absoluteString]) {
            SPKLog(@"General", @"[Sparkle ShareCopy] Sanitized URL from %@ to %@", url.absoluteString, sanitized.absoluteString);
        }
        url = sanitized ?: url;
    }
    if (url.absoluteString.length == 0) {
        SPKLog(@"General", @"[Sparkle ShareCopy] Copy failed: no link found for view=%@", SPKShareDebugViewName(view));
        SPKNotify(kSPKNotificationShareLongPressCopyLink, SPKL(@"GENERAL_SHARE_LONG_PRESS_COPY_NO_LINK_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return;
    }
    UIPasteboard.generalPasteboard.string = url.absoluteString;
    SPKLog(@"General", @"[Sparkle ShareCopy] Copied URL title=\"%@\" url=%@", SPKCopiedShareLinkTitleForURL(url), url.absoluteString);
    SPKNotify(kSPKNotificationShareLongPressCopyLink, SPKCopiedShareLinkTitleForURL(url), nil, @"copy_filled", SPKNotificationToneSuccess);
}

static void SPKUpdateShareLongPressRecognizerStates(void) {
    BOOL enabled = SPKShareLongPressCopyEnabled();
    for (UIGestureRecognizer *gesture in SPKShareCopyLongPressRecognizers()) {
        gesture.enabled = enabled;
    }
}

static BOOL SPKShareViewLooksLikeSendControl(UIView *view) {
    // accessibilityIdentifier, the tap target-action, and the icon asset name are
    // all code symbols (not localized) — check them first. accessibilityLabel is
    // localized, so it's only a last resort. (The old code did `label ?: identifier`,
    // which preferred the localized label and broke detection on non-English.)
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    if ([identifier containsString:@"send"] || [identifier containsString:@"share"] ||
        [identifier containsString:@"paper"] || [identifier containsString:@"airplane"] ||
        [identifier containsString:@"direct"]) {
        return YES;
    }

    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        if ([SPKUtils control:control hasTapActionContaining:@"send"] ||
            [SPKUtils control:control
                hasTapActionContaining:@"share"]) {
            return YES;
        }
    }

    if ([view isKindOfClass:UIButton.class]) {
        NSString *iconName = [SPKUtils igImageNameForImage:((UIButton *)view).currentImage].lowercaseString;
        if ([iconName containsString:@"send"] || [iconName containsString:@"paper_plane"] ||
            [iconName containsString:@"paperplane"] || [iconName containsString:@"direct_share"]) {
            return YES;
        }
    }

    // Localized last resort (English only).
    NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
    return ([label containsString:@"send"] || [label containsString:@"share"]);
}

static NSArray<UIView *> *SPKShareCandidateSubviews(UIView *root, NSInteger maxDepth) {
    if (!root || maxDepth < 0)
        return @[];
    NSMutableArray<UIView *> *matches = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *queue = [NSMutableArray arrayWithObject:@{@"view" : root,
                                                                              @"depth" : @0}];
    while (queue.count > 0) {
        NSDictionary *entry = queue.firstObject;
        [queue removeObjectAtIndex:0];
        UIView *view = entry[@"view"];
        NSInteger depth = [entry[@"depth"] integerValue];
        if (view != root && view.userInteractionEnabled && SPKShareViewLooksLikeSendControl(view)) {
            // Outermost match only. The send glyph and label inside a matched
            // control must stay untouched, or they start swallowing its taps.
            [matches addObject:view];
            continue;
        }
        if (depth >= maxDepth)
            continue;
        for (UIView *subview in view.subviews) {
            [queue addObject:@{@"view" : subview,
                               @"depth" : @(depth + 1)}];
        }
    }
    return matches;
}

static UIView *SPKShareViewForSelectorOrIvar(id container, NSString *name) {
    id candidate = SPKObjectForSelector(container, name);
    if (![candidate isKindOfClass:[UIView class]]) {
        NSString *ivarName = [NSString stringWithFormat:@"_%@", name];
        candidate = [SPKUtils getIvarForObj:container name:ivarName.UTF8String];
    }
    return [candidate isKindOfClass:[UIView class]] ? (UIView *)candidate : nil;
}

static void SPKInstallShareLongPressOnView(UIView *view) {
    if (!view)
        return;
    UIGestureRecognizer *existingRecognizer = objc_getAssociatedObject(view, kSPKShareCopyLongPressAssocKey);
    if (existingRecognizer) {
        existingRecognizer.enabled = SPKShareLongPressCopyEnabled();
        [SPKShareCopyLongPressRecognizers() addObject:existingRecognizer];
        return;
    }
    // Never force userInteractionEnabled: enabling it on a decorative subview of
    // the send button makes that subview the hit-test target and the button's
    // center stops receiving taps, even with the recognizer disabled.
    if (!view.userInteractionEnabled)
        return;
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:view action:@selector(spk_copyShareLinkLongPressed:)];
    gesture.minimumPressDuration = 0.3;
    gesture.cancelsTouchesInView = YES;
    // Delaying touches holds the button's tap back until the long press fails,
    // which drops quick taps on the send button.
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;
    gesture.enabled = SPKShareLongPressCopyEnabled();
    for (UIGestureRecognizer *existing in view.gestureRecognizers.copy) {
        if ([existing isKindOfClass:UILongPressGestureRecognizer.class] && existing != gesture) {
            [existing requireGestureRecognizerToFail:gesture];
        }
    }
    [view addGestureRecognizer:gesture];
    objc_setAssociatedObject(view, kSPKShareCopyLongPressAssocKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [SPKShareCopyLongPressRecognizers() addObject:gesture];
}

static void SPKInstallShareLongPressOnNativeRecognizerHosts(UIView *view, UIView *container) {
    for (UIView *walker = view.superview; walker && walker != container.superview; walker = walker.superview) {
        BOOL hasNativeLongPress = NO;
        for (UIGestureRecognizer *gesture in walker.gestureRecognizers) {
            if ([gesture isKindOfClass:UILongPressGestureRecognizer.class] &&
                !objc_getAssociatedObject(gesture, kSPKShareCopyLongPressAssocKey)) {
                hasNativeLongPress = YES;
                break;
            }
        }
        if (hasNativeLongPress) {
            SPKInstallShareLongPressOnView(walker);
        }
        if (walker == container)
            break;
    }
}

static void SPKInstallShareLongPressInContainer(UIView *container, NSArray<NSString *> *preferredNames, BOOL includeNativeHosts) {
    if (!container)
        return;
    for (NSString *name in preferredNames) {
        UIView *view = SPKShareViewForSelectorOrIvar(container, name);
        if (view) {
            SPKInstallShareLongPressOnView(view);
            if (includeNativeHosts)
                SPKInstallShareLongPressOnNativeRecognizerHosts(view, container);
        }
    }
    for (UIView *candidate in SPKShareCandidateSubviews(container, 4)) {
        SPKInstallShareLongPressOnView(candidate);
        if (includeNativeHosts)
            SPKInstallShareLongPressOnNativeRecognizerHosts(candidate, container);
    }
}

%group SPKShareLongPressCopyHooks

%hook UIView
%new - (void)spk_copyShareLinkLongPressed:(UILongPressGestureRecognizer *)gesture {
if (gesture.state != UIGestureRecognizerStateBegan)
    return;
SPKCopyShareURLForView((UIView *)self);
}
%end

%hook IGUFIButtonBarView
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"ShareLongPressCopy.layoutSubviews");
    SPKInstallShareLongPressInContainer((UIView *)self, @[ @"sendButton", @"shareButton", @"reshareButton" ], YES);
}
%end

%hook IGUFIInteractionCountsView
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"ShareLongPressCopy.layoutSubviews2");
    SPKInstallShareLongPressInContainer((UIView *)self, @[ @"sendButton", @"shareButton", @"reshareButton" ], YES);
}
%end

%hook IGSundialViewerVerticalUFI
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"ShareLongPressCopy.layoutSubviews3");
    SPKInstallShareLongPressInContainer((UIView *)self, @[ @"sendButton", @"shareButton", @"reshareButton" ], YES);
}
%end

%hook IGStoryFullscreenOverlayView
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"ShareLongPressCopy.layoutSubviews4");
    SPKStorySetActiveOverlay((UIView *)self);
    SPKInstallShareLongPressInContainer((UIView *)self, @[ @"sendButton", @"shareButton", @"reshareButton" ], NO);
}
%end

%hook IGDirectVisualMessageViewerController
- (void)viewDidLayoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"ShareLongPressCopy.viewDidLayoutSubviews");
    SPKInstallShareLongPressInContainer(((UIViewController *)self).view, @[ @"sendButton", @"shareButton" ], NO);
}
%end

%end

extern "C" void SPKInstallShareLongPressCopyHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKShareLongPressCopyHooks, IGSundialViewerVerticalUFI = SPKReelsVerticalUFIClass());
        [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(__unused NSNotification *notification) {
                                                          dispatch_async(dispatch_get_main_queue(), ^{
                                                              SPKUpdateShareLongPressRecognizerStates();
                                                          });
                                                      }];
    });
}
