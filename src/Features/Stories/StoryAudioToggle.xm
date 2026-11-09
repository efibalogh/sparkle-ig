#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "../../App/SPKPerfMeter.h"
#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Shared/Stories/SPKStoryButtonPlacement.h"
#import "../../Shared/Stories/SPKStoryDynamicRange.h"
#import "../../Shared/UI/SPKChrome.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"
#import "StoryAudioToggle.h"

NSNotificationName const SPKStoryAudioTogglePreferenceDidChangeNotification = @"SPKStoryAudioTogglePreferenceDidChangeNotification";

static NSString *const kSPKStoryAudioTogglePreferenceKey = @"stories_audio_toggle";
static NSInteger const kSPKStoryAudioButtonTag = 926004;
static CGFloat const kSPKStoryAudioButtonSize = 44.0;
static void *kSPKStoryAudioFooterObserverContext = &kSPKStoryAudioFooterObserverContext;
static const void *kSPKStoryAudioObservedFooterAssocKey = &kSPKStoryAudioObservedFooterAssocKey;
static const void *kSPKStoryAudioHasFooterObserverAssocKey = &kSPKStoryAudioHasFooterObserverAssocKey;
static const void *kSPKStoryAudioLastIconStateAssocKey = &kSPKStoryAudioLastIconStateAssocKey;
static const void *kSPKStoryAudioAvailabilityAssocKey = &kSPKStoryAudioAvailabilityAssocKey;
static void *kSPKStoryAudioVolumeObserverContext = &kSPKStoryAudioVolumeObserverContext;
static long long const kSPKStoryAudioUserToggleReason = 1;
static long long const kSPKStoryAudioAnnouncerBroadcastReason = 0;

extern "C" void MSHookMessageEx(Class cls, SEL sel, IMP replacement, IMP *result);

typedef NS_ENUM(NSInteger, SPKStoryAudioAvailability) {
    SPKStoryAudioAvailabilityUnknown = 0,
    SPKStoryAudioAvailabilityUnavailable,
    SPKStoryAudioAvailabilityAvailable,
};

typedef NS_ENUM(NSInteger, SPKStoryAudioIconState) {
    SPKStoryAudioIconStatePlaying = 0,
    SPKStoryAudioIconStateMuted,
    SPKStoryAudioIconStateNoVolume,
};

static void SPKStoryAudioRefreshAllOverlays(void);
static void SPKStoryAudioInstallButton(UIView *overlayView);
static BOOL SPKStoryAudioSystemVolumeIsZero(void);
static BOOL SPKStoryAudioReadEnabled(UIView *overlayView);

static __weak UIViewController *sSPKStoryAudioActiveViewer = nil;
static __weak id sSPKStoryAudioScopedAnnouncer = nil;
static BOOL sSPKStoryAudioHasCapturedGlobalState = NO;
static BOOL sSPKStoryAudioCapturedGlobalEnabled = NO;
static BOOL sSPKStoryAudioHasCapturedStickyState = NO;
static long long sSPKStoryAudioCapturedStickyState = 0;
static BOOL sSPKStoryAudioDidOverrideGlobalState = NO;

static BOOL SPKStoryAudioReadBoolIvar(id object, const char *name, BOOL *value) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    if (!ivar || !value)
        return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    *value = *(BOOL *)((uint8_t *)(__bridge void *)object + offset);
    return YES;
}

static BOOL SPKStoryAudioWriteBoolIvar(id object, const char *name, BOOL value) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    if (!ivar)
        return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    *(BOOL *)((uint8_t *)(__bridge void *)object + offset) = value;
    return YES;
}

static BOOL SPKStoryAudioReadIntegerIvar(id object, const char *name, long long *value) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    if (!ivar || !value)
        return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    *value = *(long long *)((uint8_t *)(__bridge void *)object + offset);
    return YES;
}

static BOOL SPKStoryAudioWriteIntegerIvar(id object, const char *name, long long value) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    if (!ivar)
        return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    *(long long *)((uint8_t *)(__bridge void *)object + offset) = value;
    return YES;
}

static id SPKStoryAudioGlobalAnnouncer(void) {
    Class announcerClass = NSClassFromString(@"IGAudioStatusAnnouncer");
    SEL sharedSelector = @selector(sharedInstance);
    if (![announcerClass respondsToSelector:sharedSelector])
        return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(announcerClass, sharedSelector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL SPKStoryAudioGlobalEnabled(id announcer, BOOL *enabled) {
    // Snapshot the same backing state that the scoped override mutates. The
    // sound-behavior query can report a computed default that differs from the
    // currently mounted feed/story players, which would restore the wrong state.
    if (SPKStoryAudioReadBoolIvar(announcer, "_audioEnabled", enabled))
        return YES;

    SEL selector = @selector(isAudioEnabledForSoundBehavior:);
    if ([announcer respondsToSelector:selector]) {
        @try {
            *enabled = ((BOOL (*)(id, SEL, long long))objc_msgSend)(announcer, selector, 1);
            return YES;
        } @catch (__unused NSException *exception) {
        }
    }
    return NO;
}

static void SPKStoryAudioBroadcastGlobalState(id announcer, BOOL enabled) {
    SEL selector = @selector(audioStatusDidChangeIsAudioEnabled:forReason:);
    for (const char *ivarName : { "_announcerForDefaultBehaviors", "_announcerForIgnoreUserPreferenceAndMatchDeviceState" }) {
        id subAnnouncer = [SPKUtils getIvarForObj:announcer name:ivarName];
        if (![subAnnouncer respondsToSelector:selector])
            continue;
        @try {
            ((void (*)(id, SEL, BOOL, long long))objc_msgSend)(subAnnouncer,
                                                              selector,
                                                              enabled,
                                                              kSPKStoryAudioAnnouncerBroadcastReason);
        } @catch (__unused NSException *exception) {
        }
    }
}

static void SPKStoryAudioEndScopedSession(UIViewController *viewerController);

static void SPKStoryAudioBeginScopedSession(UIViewController *viewerController) {
    if (!viewerController || ![SPKUtils getBoolPref:kSPKStoryAudioTogglePreferenceKey])
        return;
    if (sSPKStoryAudioHasCapturedGlobalState && sSPKStoryAudioActiveViewer == viewerController)
        return;
    if (sSPKStoryAudioHasCapturedGlobalState)
        SPKStoryAudioEndScopedSession(sSPKStoryAudioActiveViewer);

    id announcer = SPKStoryAudioGlobalAnnouncer();
    BOOL enabled = NO;
    if (!announcer || !SPKStoryAudioGlobalEnabled(announcer, &enabled))
        return;

    sSPKStoryAudioActiveViewer = viewerController;
    sSPKStoryAudioScopedAnnouncer = announcer;
    sSPKStoryAudioHasCapturedGlobalState = YES;
    sSPKStoryAudioCapturedGlobalEnabled = enabled;
    sSPKStoryAudioHasCapturedStickyState = SPKStoryAudioReadIntegerIvar(announcer,
                                                                        "_stickySoundState",
                                                                        &sSPKStoryAudioCapturedStickyState);
    sSPKStoryAudioDidOverrideGlobalState = NO;
}

static BOOL SPKStoryAudioSetScopedGlobalState(UIView *overlayView, BOOL enabled) {
    if (!sSPKStoryAudioHasCapturedGlobalState) {
        UIViewController *viewerController = [SPKUtils nearestViewControllerForView:overlayView];
        SPKStoryAudioBeginScopedSession(viewerController);
    }
    if (!sSPKStoryAudioHasCapturedGlobalState)
        return NO;

    id announcer = sSPKStoryAudioScopedAnnouncer;
    if (!announcer || !SPKStoryAudioWriteBoolIvar(announcer, "_audioEnabled", enabled))
        return NO;

    SPKStoryAudioWriteIntegerIvar(announcer, "_stickySoundState", enabled ? 2 : 1);
    sSPKStoryAudioDidOverrideGlobalState = YES;
    SPKStoryAudioBroadcastGlobalState(announcer, enabled);
    return SPKStoryAudioReadEnabled(overlayView) == enabled;
}

static void SPKStoryAudioEndScopedSession(UIViewController *viewerController) {
    if (!sSPKStoryAudioHasCapturedGlobalState ||
        (viewerController && sSPKStoryAudioActiveViewer && viewerController != sSPKStoryAudioActiveViewer)) {
        return;
    }

    id announcer = sSPKStoryAudioScopedAnnouncer;
    if (sSPKStoryAudioDidOverrideGlobalState && announcer) {
        BOOL wroteEnabled = SPKStoryAudioWriteBoolIvar(announcer,
                                                       "_audioEnabled",
                                                       sSPKStoryAudioCapturedGlobalEnabled);
        if (sSPKStoryAudioHasCapturedStickyState) {
            SPKStoryAudioWriteIntegerIvar(announcer,
                                          "_stickySoundState",
                                          sSPKStoryAudioCapturedStickyState);
        }
        if (wroteEnabled)
            SPKStoryAudioBroadcastGlobalState(announcer, sSPKStoryAudioCapturedGlobalEnabled);
    }

    sSPKStoryAudioActiveViewer = nil;
    sSPKStoryAudioScopedAnnouncer = nil;
    sSPKStoryAudioHasCapturedGlobalState = NO;
    sSPKStoryAudioHasCapturedStickyState = NO;
    sSPKStoryAudioDidOverrideGlobalState = NO;
}

static void SPKStoryAudioUpdateCapturedGlobalStateForExternalChange(id announcer) {
    if (!sSPKStoryAudioHasCapturedGlobalState || !sSPKStoryAudioDidOverrideGlobalState ||
        !announcer || announcer != sSPKStoryAudioScopedAnnouncer) {
        return;
    }

    BOOL enabled = NO;
    if (!SPKStoryAudioGlobalEnabled(announcer, &enabled))
        return;
    sSPKStoryAudioCapturedGlobalEnabled = enabled;
    sSPKStoryAudioHasCapturedStickyState = SPKStoryAudioReadIntegerIvar(announcer,
                                                                        "_stickySoundState",
                                                                        &sSPKStoryAudioCapturedStickyState);
}

static NSHashTable<UIView *> *SPKStoryAudioLiveOverlays(void) {
    static NSHashTable<UIView *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static id SPKStoryAudioObjectForSelector(id target, NSString *selectorName) {
    if (!target || !selectorName.length)
        return nil;

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return nil;

    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSNumber *SPKStoryAudioBoolForSelector(id target, NSString *selectorName) {
    if (!target || !selectorName.length)
        return nil;

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return nil;

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    const char *returnType = signature.methodReturnType;
    if (!returnType || !returnType[0])
        return nil;

    @try {
        switch (returnType[0]) {
            case '@': {
                id value = ((id (*)(id, SEL))objc_msgSend)(target, selector);
                if (!value)
                    return nil;
                if ([value respondsToSelector:@selector(boolValue)])
                    return @([value boolValue]);

                id number = SPKStoryAudioObjectForSelector(value, @"asNumber");
                if ([number respondsToSelector:@selector(boolValue)])
                    return @([number boolValue]);
                return nil;
            }
            case 'B':
            case 'c':
                return @(((BOOL (*)(id, SEL))objc_msgSend)(target, selector));
            case 'C':
                return @(((unsigned char (*)(id, SEL))objc_msgSend)(target, selector) != 0);
            default:
                return nil;
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UIView *SPKStoryAudioActiveMediaView(UIView *overlayView) {
    if (!overlayView)
        return nil;

    id mediaView = [SPKUtils getIvarForObj:overlayView name:"_mediaView"];
    if ([mediaView isKindOfClass:[UIView class]])
        return (UIView *)mediaView;

    id sectionController = SPKStoryAudioObjectForSelector(overlayView, @"mediaOverlayDelegate");
    mediaView = SPKStoryAudioObjectForSelector(sectionController, @"mediaView");
    return [mediaView isKindOfClass:[UIView class]] ? (UIView *)mediaView : nil;
}

static id SPKStoryAudioSectionContextForOverlay(UIView *overlayView) {
    if (!overlayView)
        return nil;

    id context = SPKStoryAudioObjectForSelector(overlayView, @"currentSectionContext");
    if (!context)
        context = SPKStoryAudioObjectForSelector(overlayView, @"sectionContext");
    return context;
}

static id SPKStoryAudioSectionControllerForOverlay(UIView *overlayView) {
    if (!overlayView)
        return nil;

    id sectionController = SPKStoryAudioObjectForSelector(overlayView, @"mediaOverlayDelegate");
    if ([sectionController respondsToSelector:@selector(audioEnabled)] ||
        [sectionController respondsToSelector:@selector(setAudioEnabled:reason:)]) {
        return sectionController;
    }

    id context = SPKStoryAudioSectionContextForOverlay(overlayView);
    id mediaController = SPKStoryAudioObjectForSelector(context, @"mediaController");
    if ([mediaController respondsToSelector:@selector(audioEnabled)] ||
        [mediaController respondsToSelector:@selector(setAudioEnabled:reason:)]) {
        return mediaController;
    }

    return nil;
}

static id SPKStoryAudioCoordinatorForOverlay(UIView *overlayView) {
    id context = SPKStoryAudioSectionContextForOverlay(overlayView);
    id coordinator = SPKStoryAudioObjectForSelector(context, @"audioCoordinator");
    if ([coordinator respondsToSelector:@selector(audioEnabled)] ||
        [coordinator respondsToSelector:@selector(setAudioEnabled:reason:mediaView:)]) {
        return coordinator;
    }
    return nil;
}

static id SPKStoryAudioViewerAudioStateForOverlay(UIView *overlayView) {
    id context = SPKStoryAudioSectionContextForOverlay(overlayView);
    id viewerContext = SPKStoryAudioObjectForSelector(context, @"viewerContext");
    id audioState = SPKStoryAudioObjectForSelector(viewerContext, @"audioState");
    return [audioState respondsToSelector:@selector(audioEnabled)] ? audioState : nil;
}

static SPKStoryAudioAvailability SPKStoryAudioAvailabilityForMediaView(UIView *mediaView, NSUInteger depth) {
    if (!mediaView)
        return SPKStoryAudioAvailabilityUnknown;

    NSNumber *audioAvailable = SPKStoryAudioBoolForSelector(mediaView, @"isAudioAvailable");
    if (audioAvailable)
        return audioAvailable.boolValue ? SPKStoryAudioAvailabilityAvailable : SPKStoryAudioAvailabilityUnavailable;

    NSString *className = NSStringFromClass(mediaView.class);
    if ([className containsString:@"PhotoWithMusic"])
        return SPKStoryAudioAvailabilityAvailable;
    if ([className containsString:@"StoryPhotoView"])
        return SPKStoryAudioAvailabilityUnavailable;

    if (depth < 3) {
        for (UIView *subview in mediaView.subviews) {
            SPKStoryAudioAvailability availability = SPKStoryAudioAvailabilityForMediaView(subview, depth + 1);
            if (availability != SPKStoryAudioAvailabilityUnknown)
                return availability;
        }
    }

    return SPKStoryAudioAvailabilityUnknown;
}

static id SPKStoryAudioCurrentStoryItem(UIView *overlayView, UIView *mediaView) {
    id storyItem = SPKStoryAudioObjectForSelector(overlayView, @"currentStoryItem");
    if (storyItem)
        return storyItem;

    id itemContext = SPKStoryAudioObjectForSelector(overlayView, @"currentStoryItemContext");
    storyItem = SPKStoryAudioObjectForSelector(itemContext, @"storyItem");
    if (storyItem)
        return storyItem;

    id sectionController = SPKStoryAudioObjectForSelector(overlayView, @"mediaOverlayDelegate");
    storyItem = SPKStoryAudioObjectForSelector(sectionController, @"currentStoryItem");
    if (storyItem)
        return storyItem;

    return SPKStoryAudioObjectForSelector(mediaView, @"item");
}

static SPKStoryAudioAvailability SPKStoryAudioAvailabilityForStoryItem(id storyItem) {
    if (!storyItem)
        return SPKStoryAudioAvailabilityUnknown;

    id media = SPKStoryAudioObjectForSelector(storyItem, @"media");
    NSArray *candidates = media && media != storyItem ? @[ storyItem, media ] : @[ storyItem ];
    for (id candidate in candidates) {
        NSNumber *hasAudio = SPKStoryAudioBoolForSelector(candidate, @"hasAudio");
        if (hasAudio)
            return hasAudio.boolValue ? SPKStoryAudioAvailabilityAvailable : SPKStoryAudioAvailabilityUnavailable;

        id video = SPKStoryAudioObjectForSelector(candidate, @"video");
        hasAudio = SPKStoryAudioBoolForSelector(video, @"hasAudio");
        if (!hasAudio)
            hasAudio = SPKStoryAudioBoolForSelector(video, @"audioDetected");
        if (!hasAudio)
            hasAudio = SPKStoryAudioBoolForSelector(candidate, @"audioDetected");
        if (hasAudio)
            return hasAudio.boolValue ? SPKStoryAudioAvailabilityAvailable : SPKStoryAudioAvailabilityUnavailable;

        id photo = SPKStoryAudioObjectForSelector(candidate, @"photo");
        if (photo) {
            for (NSString *selectorName in @[ @"audio", @"sundialMusicAsset", @"sundialOriginalAudioAsset", @"musicMetadata" ]) {
                if (SPKStoryAudioObjectForSelector(candidate, selectorName))
                    return SPKStoryAudioAvailabilityAvailable;
            }
            return SPKStoryAudioAvailabilityUnavailable;
        }
    }

    return SPKStoryAudioAvailabilityUnknown;
}

static BOOL SPKStoryAudioShouldHideForOverlay(UIView *overlayView) {
    NSNumber *nativeAvailability = objc_getAssociatedObject(overlayView, kSPKStoryAudioAvailabilityAssocKey);
    if (nativeAvailability)
        return !nativeAvailability.boolValue;

    id coordinator = SPKStoryAudioCoordinatorForOverlay(overlayView);
    NSNumber *forceMuted = SPKStoryAudioBoolForSelector(coordinator, @"isForceMuted");
    if (forceMuted.boolValue)
        return YES;

    UIView *mediaView = SPKStoryAudioActiveMediaView(overlayView);
    SPKStoryAudioAvailability availability = SPKStoryAudioAvailabilityForMediaView(mediaView, 0);
    if (availability == SPKStoryAudioAvailabilityUnavailable)
        return YES;
    if (availability == SPKStoryAudioAvailabilityAvailable)
        return NO;

    availability = SPKStoryAudioAvailabilityForStoryItem(SPKStoryAudioCurrentStoryItem(overlayView, mediaView));
    return availability != SPKStoryAudioAvailabilityAvailable;
}

static BOOL SPKStoryAudioReadEnabled(UIView *overlayView) {
    id coordinator = SPKStoryAudioCoordinatorForOverlay(overlayView);
    NSNumber *enabled = SPKStoryAudioBoolForSelector(coordinator, @"audioEnabled");
    if (enabled)
        return enabled.boolValue;

    id sectionController = SPKStoryAudioSectionControllerForOverlay(overlayView);
    enabled = SPKStoryAudioBoolForSelector(sectionController, @"audioEnabled");
    if (enabled)
        return enabled.boolValue;

    id viewerAudioState = SPKStoryAudioViewerAudioStateForOverlay(overlayView);
    enabled = SPKStoryAudioBoolForSelector(viewerAudioState, @"audioEnabled");
    if (enabled)
        return enabled.boolValue;

    UIView *mediaView = SPKStoryAudioActiveMediaView(overlayView);
    enabled = SPKStoryAudioBoolForSelector(mediaView, @"audioEnabled");
    return enabled.boolValue;
}

static void SPKStoryAudioSetViewerAudioState(UIView *overlayView, BOOL enabled) {
    id viewerAudioState = SPKStoryAudioViewerAudioStateForOverlay(overlayView);
    SEL setter = @selector(setAudioEnabled:);
    if (![viewerAudioState respondsToSelector:setter])
        return;

    @try {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(viewerAudioState, setter, enabled);
    } @catch (__unused NSException *exception) {
    }
}

static BOOL SPKStoryAudioWriteEnabled(UIView *overlayView, BOOL enabled) {
    if (!overlayView)
        return NO;

    id coordinator = SPKStoryAudioCoordinatorForOverlay(overlayView);
    UIView *mediaView = SPKStoryAudioActiveMediaView(overlayView);
    SEL coordinatorSetter = @selector(setAudioEnabled:reason:mediaView:);
    if ([coordinator respondsToSelector:coordinatorSetter]) {
        @try {
            ((BOOL (*)(id, SEL, BOOL, long long, id))objc_msgSend)(coordinator,
                                                                  coordinatorSetter,
                                                                  enabled,
                                                                  kSPKStoryAudioUserToggleReason,
                                                                  mediaView);
            BOOL resolvedAfter = SPKStoryAudioReadEnabled(overlayView);
            BOOL applied = resolvedAfter == enabled;
            if (applied)
                SPKStoryAudioSetViewerAudioState(overlayView, enabled);

            // Every Story section builds its own audio coordinator and seeds it
            // from the global announcer state, so a coordinator-only write is
            // forgotten on the next snap. Mirror both directions into the scoped
            // global state so the rest of the viewer session inherits the choice.
            // The viewer restores the captured value on close, so Feed and Reels
            // stay isolated either way.
            BOOL mirrored = SPKStoryAudioSetScopedGlobalState(overlayView, enabled);
            return applied ?: mirrored;
        } @catch (__unused NSException *exception) {
        }
    }

    id softMuteController = [SPKUtils getIvarForObj:overlayView name:"_softMuteController"];
    SEL softMuteSelector = NSSelectorFromString(@"_didTapSoftMuteButton");
    if ([softMuteController respondsToSelector:softMuteSelector]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(softMuteController, softMuteSelector);
            return YES;
        } @catch (__unused NSException *exception) {
        }
    }

    id sectionController = SPKStoryAudioSectionControllerForOverlay(overlayView);
    SEL sectionSetter = @selector(setAudioEnabled:reason:);
    if ([sectionController respondsToSelector:sectionSetter]) {
        BOOL usesLegacyAudioPath = coordinator == nil;
        @try {
            ((void (*)(id, SEL, BOOL, long long))objc_msgSend)(sectionController,
                                                               sectionSetter,
                                                               enabled,
                                                               kSPKStoryAudioUserToggleReason);
            SPKStoryAudioSetViewerAudioState(overlayView, enabled);

            // Legacy Story playback has no section audio coordinator. Its
            // section setter can update the Story model without updating the
            // active player/device-audio path while the ringer is silent.
            if (usesLegacyAudioPath && [mediaView respondsToSelector:sectionSetter]) {
                ((void (*)(id, SEL, BOOL, long long))objc_msgSend)(mediaView,
                                                                   sectionSetter,
                                                                   enabled,
                                                                   kSPKStoryAudioUserToggleReason);
            }

            if (usesLegacyAudioPath)
                SPKStoryAudioSetScopedGlobalState(overlayView, enabled);

            BOOL resolvedAfter = SPKStoryAudioReadEnabled(overlayView);
            return resolvedAfter == enabled;
        } @catch (__unused NSException *exception) {
        }
    }

    SEL mediaSetter = @selector(setAudioEnabled:reason:);
    if ([mediaView respondsToSelector:mediaSetter]) {
        @try {
            ((void (*)(id, SEL, BOOL, long long))objc_msgSend)(mediaView,
                                                               mediaSetter,
                                                               enabled,
                                                               kSPKStoryAudioUserToggleReason);
            SPKStoryAudioSetViewerAudioState(overlayView, enabled);
            return YES;
        } @catch (__unused NSException *exception) {
        }
    }

    return NO;
}

static BOOL SPKStoryAudioSystemVolumeIsZero(void) {
    return [AVAudioSession sharedInstance].outputVolume <= 0.0f;
}

static SPKStoryAudioIconState SPKStoryAudioCurrentIconState(UIView *overlayView) {
    if (SPKStoryAudioSystemVolumeIsZero())
        return SPKStoryAudioIconStateNoVolume;
    return SPKStoryAudioReadEnabled(overlayView) ? SPKStoryAudioIconStatePlaying : SPKStoryAudioIconStateMuted;
}

static UIView *SPKStoryAudioFooterContainer(UIView *overlayView) {
    UIView *footerContainer = [SPKUtils getIvarForObj:overlayView name:"_footerContainerView"];
    return [footerContainer isKindOfClass:[UIView class]] ? footerContainer : nil;
}

static void SPKStoryAudioUpdateButtonAlpha(UIView *overlayView, CGFloat alpha) {
    for (UIView *subview in overlayView.subviews) {
        if (subview.tag == kSPKStoryAudioButtonTag) {
            subview.alpha = alpha;
            return;
        }
    }
}

static void SPKStoryAudioRemoveFooterObserver(UIView *overlayView) {
    UIView *footerContainer = objc_getAssociatedObject(overlayView, kSPKStoryAudioObservedFooterAssocKey);
    BOOL hasObserver = [objc_getAssociatedObject(overlayView, kSPKStoryAudioHasFooterObserverAssocKey) boolValue];
    if (footerContainer && hasObserver) {
        @try {
            [footerContainer removeObserver:overlayView forKeyPath:@"alpha" context:kSPKStoryAudioFooterObserverContext];
        } @catch (__unused NSException *exception) {
        }
    }

    objc_setAssociatedObject(overlayView, kSPKStoryAudioObservedFooterAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlayView, kSPKStoryAudioHasFooterObserverAssocKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SPKStoryAudioEnsureFooterObserver(UIView *overlayView) {
    UIView *footerContainer = SPKStoryAudioFooterContainer(overlayView);
    UIView *observedFooter = objc_getAssociatedObject(overlayView, kSPKStoryAudioObservedFooterAssocKey);
    BOOL hasObserver = [objc_getAssociatedObject(overlayView, kSPKStoryAudioHasFooterObserverAssocKey) boolValue];

    if (observedFooter && observedFooter != footerContainer && hasObserver) {
        @try {
            [observedFooter removeObserver:overlayView forKeyPath:@"alpha" context:kSPKStoryAudioFooterObserverContext];
        } @catch (__unused NSException *exception) {
        }
        hasObserver = NO;
        objc_setAssociatedObject(overlayView, kSPKStoryAudioHasFooterObserverAssocKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (observedFooter != footerContainer) {
        objc_setAssociatedObject(overlayView, kSPKStoryAudioObservedFooterAssocKey, footerContainer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (footerContainer && !hasObserver) {
        @try {
            [footerContainer addObserver:overlayView
                              forKeyPath:@"alpha"
                                 options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                 context:kSPKStoryAudioFooterObserverContext];
            objc_setAssociatedObject(overlayView, kSPKStoryAudioHasFooterObserverAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } @catch (__unused NSException *exception) {
        }
    }
}

static CGRect SPKStoryAudioButtonFrame(UIView *overlayView) {
    CGRect trailingFrame = SPKStoryFloatingButtonFrame(overlayView, kSPKStoryAudioButtonSize);
    if (CGRectGetWidth(trailingFrame) <= 0.0 || CGRectGetHeight(trailingFrame) <= 0.0)
        return CGRectZero;

    CGFloat leadingInset = MAX(6.0, overlayView.safeAreaInsets.left + 6.0);
    return CGRectMake(leadingInset, CGRectGetMinY(trailingFrame), kSPKStoryAudioButtonSize, kSPKStoryAudioButtonSize);
}

static void SPKStoryAudioRemoveButton(UIView *overlayView) {
    [[overlayView viewWithTag:kSPKStoryAudioButtonTag] removeFromSuperview];
    SPKStoryAudioRemoveFooterObserver(overlayView);
}

static NSString *SPKStoryAudioIconResourceName(SPKStoryAudioIconState state) {
    switch (state) {
        case SPKStoryAudioIconStateNoVolume:
            return @"volume_none";
        case SPKStoryAudioIconStateMuted:
            return @"volume_off";
        case SPKStoryAudioIconStatePlaying:
        default:
            return @"volume";
    }
}

static void SPKStoryAudioSetButtonIcon(SPKChromeButton *button, SPKStoryAudioIconState state) {
    if (!button)
        return;

    NSString *resourceName = SPKStoryAudioIconResourceName(state);
    NSNumber *lastIconState = objc_getAssociatedObject(button, kSPKStoryAudioLastIconStateAssocKey);
    BOOL shouldAnimate = lastIconState && lastIconState.integerValue != state;
    objc_setAssociatedObject(button, kSPKStoryAudioLastIconStateAssocKey, @(state), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!shouldAnimate || !button.iconView) {
        [button setIconResource:resourceName pointSize:24.0];
        return;
    }

    UIImageView *iconView = button.iconView;
    iconView.transform = CGAffineTransformMakeScale(0.78, 0.78);
    iconView.alpha = 0.65;
    [UIView transitionWithView:iconView
                      duration:0.16
                       options:UIViewAnimationOptionTransitionCrossDissolve |
                               UIViewAnimationOptionBeginFromCurrentState |
                               UIViewAnimationOptionAllowAnimatedContent
                    animations:^{
                        [button setIconResource:resourceName pointSize:24.0];
                    }
                    completion:nil];
    [UIView animateWithDuration:0.34
                          delay:0.0
         usingSpringWithDamping:0.70
          initialSpringVelocity:0.55
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         iconView.transform = CGAffineTransformIdentity;
                         iconView.alpha = 1.0;
                     }
                     completion:nil];
}

static void SPKStoryAudioAnimateUnavailableTap(SPKChromeButton *button) {
    CALayer *iconLayer = button.iconView.layer;
    if (!iconLayer)
        return;

    NSArray<NSNumber *> *keyTimes = @[ @(0), @(0.18), @(0.38), @(0.58), @(0.78), @(1) ];

    CAKeyframeAnimation *wobble = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    wobble.keyTimes = keyTimes;
    wobble.values = @[ @(0), @(-5.0), @(5.0), @(-2.5), @(2.5), @(0) ];

    CAAnimationGroup *animation = [CAAnimationGroup animation];
    animation.animations = @[ wobble ];
    animation.duration = 0.34;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [iconLayer removeAnimationForKey:@"spk_storyAudioUnavailable"];
    [iconLayer addAnimation:animation forKey:@"spk_storyAudioUnavailable"];
}

static void SPKStoryAudioInstallButton(UIView *overlayView) {
    if (!overlayView)
        return;

    [SPKStoryAudioLiveOverlays() addObject:overlayView];
    SPKChromeButton *button = (SPKChromeButton *)[overlayView viewWithTag:kSPKStoryAudioButtonTag];
    BOOL directVisual = SPKIsDirectVisualViewerAncestor(overlayView);
    if (![SPKUtils getBoolPref:kSPKStoryAudioTogglePreferenceKey] || directVisual || SPKStoryAudioShouldHideForOverlay(overlayView)) {
        SPKStoryAudioRemoveButton(overlayView);
        return;
    }

    CGRect frame = SPKStoryAudioButtonFrame(overlayView);
    if (CGRectIsEmpty(frame))
        return;

    if (![button isKindOfClass:[SPKChromeButton class]]) {
        [button removeFromSuperview];
        button = [[SPKChromeButton alloc] initWithSymbol:@"" pointSize:24.0 diameter:kSPKStoryAudioButtonSize];
        button.tag = kSPKStoryAudioButtonTag;
        button.adjustsImageWhenHighlighted = YES;
        button.showsMenuAsPrimaryAction = NO;
        button.clipsToBounds = NO;
        button.accessibilityLabel = SPKL(@"STORIES_PLAYBACK_AUDIO_TOGGLE_ACCESSIBILITY_LABEL");
        [button addTarget:overlayView action:@selector(spk_storyAudioButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [overlayView addSubview:button];
    }

    button.translatesAutoresizingMaskIntoConstraints = YES;
    button.frame = frame;
    SPKStoryAudioSetButtonIcon(button, SPKStoryAudioCurrentIconState(overlayView));
    button.accessibilityLabel = SPKL(@"STORIES_PLAYBACK_AUDIO_TOGGLE_ACCESSIBILITY_LABEL");
    SPKApplyButtonStyle(button, SPKActionButtonSourceDirect);
    SPKStoryApplyDynamicRangeToButton(button);
    [overlayView bringSubviewToFront:button];

    SPKStoryAudioEnsureFooterObserver(overlayView);
    UIView *footerContainer = SPKStoryAudioFooterContainer(overlayView);
    SPKStoryAudioUpdateButtonAlpha(overlayView, footerContainer ? footerContainer.alpha : 1.0);
}

static void SPKStoryAudioRefreshSectionOverlay(id sectionController) {
    UIView *overlayView = (UIView *)SPKStoryAudioObjectForSelector(sectionController, @"overlayView");
    if (![overlayView isKindOfClass:[UIView class]])
        return;

    dispatch_async(dispatch_get_main_queue(), ^{
        SPKStoryAudioInstallButton(overlayView);
        [overlayView setNeedsLayout];
    });
}

static void SPKStoryAudioRefreshAllOverlays(void) {
    void (^refresh)(void) = ^{
        for (UIView *overlayView in SPKStoryAudioLiveOverlays().allObjects) {
            if (!overlayView)
                continue;
            SPKStoryAudioInstallButton(overlayView);
            [overlayView setNeedsLayout];
        }
    };

    if ([NSThread isMainThread]) {
        refresh();
    } else {
        dispatch_async(dispatch_get_main_queue(), refresh);
    }
}

@interface SPKStoryAudioSystemVolumeObserver : NSObject
@end

@implementation SPKStoryAudioSystemVolumeObserver
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    (void)object;
    (void)change;
    if (context == kSPKStoryAudioVolumeObserverContext && [keyPath isEqualToString:@"outputVolume"]) {
        SPKStoryAudioRefreshAllOverlays();
    }
}
@end

static SPKStoryAudioSystemVolumeObserver *sSPKStoryAudioSystemVolumeObserver = nil;

static void SPKStoryAudioRingerStateDidChange(CFNotificationCenterRef center,
                                               void *observer,
                                               CFNotificationName name,
                                               const void *object,
                                               CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    SPKStoryAudioRefreshAllOverlays();
}

static void SPKStoryAudioRegisterSystemAudioObservers(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sSPKStoryAudioSystemVolumeObserver = [SPKStoryAudioSystemVolumeObserver new];
        @try {
            [[AVAudioSession sharedInstance] addObserver:sSPKStoryAudioSystemVolumeObserver
                                              forKeyPath:@"outputVolume"
                                                 options:NSKeyValueObservingOptionNew
                                                 context:kSPKStoryAudioVolumeObserverContext];
        } @catch (__unused NSException *exception) {
        }

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                         NULL,
                                         SPKStoryAudioRingerStateDidChange,
                                         CFSTR("com.apple.springboard.ringerstate"),
                                         NULL,
                                         CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

static void (*orig_SPKStoryAudioUpdateMuteButton)(id, SEL, BOOL, BOOL) = NULL;
static void SPKStoryAudioUpdateMuteButton(id self, SEL selector, BOOL assetHasAudio, BOOL forceMuted) {
    if (orig_SPKStoryAudioUpdateMuteButton)
        orig_SPKStoryAudioUpdateMuteButton(self, selector, assetHasAudio, forceMuted);

    UIView *overlayView = [self isKindOfClass:[UIView class]] ? (UIView *)self : nil;
    if (!overlayView)
        return;

    objc_setAssociatedObject(overlayView,
                             kSPKStoryAudioAvailabilityAssocKey,
                             @(assetHasAudio && !forceMuted),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPKStoryAudioInstallButton(overlayView);
}

static void SPKStoryAudioInstallNativeAvailabilityHook(void) {
    Class overlayClass = NSClassFromString(@"IGStoryFullscreenOverlayView");
    SEL selector = NSSelectorFromString(@"updateMuteButtonForPlayerAssetHasAudio:isForceMuted:");
    if (!overlayClass || !class_getInstanceMethod(overlayClass, selector)) {
        return;
    }

    MSHookMessageEx(overlayClass,
                    selector,
                    (IMP)SPKStoryAudioUpdateMuteButton,
                    (IMP *)&orig_SPKStoryAudioUpdateMuteButton);
}

%group SPKStoryAudioToggleHooks

%hook IGAudioStatusAnnouncer
- (void)_announceForDeviceStateChangesIfNeededForAudioEnabled:(BOOL)enabled reason:(long long)reason {
    %orig(enabled, reason);
    SPKStoryAudioUpdateCapturedGlobalStateForExternalChange(self);
}
%end

%hook IGStoryViewerViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    SPKStoryAudioBeginScopedSession((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig(animated);
    SPKStoryAudioEndScopedSession((UIViewController *)self);
}
%end

%hook IGStoryFullscreenOverlayView
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"StoryAudioToggle.layoutSubviews");
    SPKStoryAudioInstallButton((UIView *)self);
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context == kSPKStoryAudioFooterObserverContext && [keyPath isEqualToString:@"alpha"]) {
        CGFloat alpha = 1.0;
        id newAlphaValue = change[NSKeyValueChangeNewKey];
        if ([newAlphaValue respondsToSelector:@selector(floatValue)])
            alpha = [newAlphaValue floatValue];
        else if ([object isKindOfClass:[UIView class]])
            alpha = ((UIView *)object).alpha;
        SPKStoryAudioUpdateButtonAlpha((UIView *)self, alpha);
        return;
    }

    %orig(keyPath, object, change, context);
}

- (void)dealloc {
    SPKStoryAudioRemoveFooterObserver((UIView *)self);
    %orig;
}

%new - (void)spk_storyAudioButtonTapped:(UIButton *)sender {
    if (![SPKUtils getBoolPref:kSPKStoryAudioTogglePreferenceKey])
        return;

    UIView *overlayView = (UIView *)self;
    if (SPKStoryAudioSystemVolumeIsZero()) {
        if ([sender isKindOfClass:[SPKChromeButton class]])
            SPKStoryAudioAnimateUnavailableTap((SPKChromeButton *)sender);
        UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
        [feedback selectionChanged];
        return;
    }

    BOOL storyAudioEnabled = SPKStoryAudioReadEnabled(overlayView);
    BOOL wanted = !storyAudioEnabled;
    BOOL applied = SPKStoryAudioWriteEnabled(overlayView, wanted);
    SPKStoryAudioRefreshAllOverlays();
    if (!applied)
        return;

    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
}
%end

%hook IGStoryFullscreenSectionController
- (void)setAudioEnabled:(BOOL)enabled reason:(long long)reason {
    %orig(enabled, reason);
    SPKStoryAudioRefreshSectionOverlay(self);
}

- (void)didUpdateToObject:(id)object {
    UIView *overlayView = (UIView *)SPKStoryAudioObjectForSelector(self, @"overlayView");
    objc_setAssociatedObject(overlayView, kSPKStoryAudioAvailabilityAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(object);
    SPKStoryAudioRefreshSectionOverlay(self);
}

- (void)didSelectItemAtIndex:(long long)index {
    UIView *overlayView = (UIView *)SPKStoryAudioObjectForSelector(self, @"overlayView");
    objc_setAssociatedObject(overlayView, kSPKStoryAudioAvailabilityAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(index);
    SPKStoryAudioRefreshSectionOverlay(self);
}
%end

%end

void SPKInstallStoryAudioToggleHooksIfEnabled(void) {
    // Install independently of the preference because Stories preferences may
    // be account-scoped and can be toggled while an overlay is already alive.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKStoryAudioRegisterSystemAudioObservers();
        SPKStoryAudioInstallNativeAvailabilityHook();
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKStoryAudioTogglePreferenceDidChangeNotification
                                                            object:nil
                                                             queue:[NSOperationQueue mainQueue]
                                                        usingBlock:^(__unused NSNotification *notification) {
                                                            if (![SPKUtils getBoolPref:kSPKStoryAudioTogglePreferenceKey])
                                                                SPKStoryAudioEndScopedSession(nil);
                                                            SPKStoryAudioRefreshAllOverlays();
                                                        }];
        %init(SPKStoryAudioToggleHooks, IGStoryFullscreenSectionController = SPKStoryFullscreenSectionControllerClass());
    });
}
