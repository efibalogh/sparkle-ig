#import <objc/message.h>
#import <objc/runtime.h>

#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../../Shared/Stories/SPKStoryButtonPlacement.h"
#import "../../Shared/Stories/SPKStoryContext.h"
#import "../../Shared/Stories/SPKStoryDynamicRange.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"

static NSInteger const kSPKStoriesActionButtonTag = 921343;

static id SPKStorySectionControllerFromOverlay(UIView *overlayView) {
    SPKStoryContext *sharedContext = SPKStoryContextFromOverlay(overlayView);
    if (sharedContext.sectionController)
        return sharedContext.sectionController;
    NSArray<NSString *> *delegateSelectors = @[ @"mediaOverlayDelegate", @"retryDelegate", @"tappableOverlayDelegate", @"buttonDelegate" ];
    Class sectionControllerClass = SPKStoryFullscreenSectionControllerClass();

    for (NSString *selectorName in delegateSelectors) {
        id delegate = SPKObjectForSelector(overlayView, selectorName);
        if (!delegate)
            continue;
        if (!sectionControllerClass || [delegate isKindOfClass:sectionControllerClass])
            return delegate;
    }

    return nil;
}

static id SPKStoryMediaFromOverlay(UIView *overlayView) {
    SPKStoryContext *sharedContext = SPKStoryContextFromOverlay(overlayView);
    if (sharedContext.media)
        return sharedContext.media;
    id sectionController = SPKStorySectionControllerFromOverlay(overlayView);
    id media = SPKObjectForSelector(sectionController, @"currentStoryItem");
    if (media)
        return media;

    UIViewController *ancestorController = [SPKUtils viewControllerForAncestralView:overlayView];
    media = SPKObjectForSelector(ancestorController, @"currentStoryItem");
    return media;
}

static UIViewController *SPKStoryControllerFromOverlay(UIView *overlayView) {
    SPKStoryContext *sharedContext = SPKStoryContextFromOverlay(overlayView);
    if (sharedContext.viewerController)
        return sharedContext.viewerController;
    if (!overlayView)
        return nil;

    id ancestorController = SPKObjectForSelector(overlayView, @"_viewControllerForAncestor");
    if ([ancestorController isKindOfClass:[UIViewController class]]) {
        return (UIViewController *)ancestorController;
    }

    return [SPKUtils nearestViewControllerForView:overlayView];
}

static NSArray *SPKStoryItemsFromCandidate(id candidate) {
    if (!candidate)
        return nil;

    for (NSString *selectorName in @[ @"items", @"storyItems", @"reelItems", @"mediaItems", @"allItems" ]) {
        id value = SPKObjectForSelector(candidate, selectorName);
        if (!value)
            value = SPKKVCObject(candidate, selectorName);
        NSArray *items = SPKArrayFromCollection(value);
        if (items.count > 1)
            return items;
    }

    SEL cachedSelector = NSSelectorFromString(@"allItemsForTrayUsingCachedValue:");
    if ([candidate respondsToSelector:cachedSelector]) {
        @try {
            id value = ((id (*)(id, SEL, BOOL))objc_msgSend)(candidate, cachedSelector, YES);
            NSArray *items = SPKArrayFromCollection(value);
            if (items.count > 1)
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

static id SPKStoryMediaObjectFromCandidate(id candidate) {
    if (!candidate)
        return nil;
    for (NSString *selectorName in @[ @"media", @"storyItem", @"item", @"mediaItem", @"currentStoryItem" ]) {
        id value = SPKObjectForSelector(candidate, selectorName);
        if (!value)
            value = SPKKVCObject(candidate, selectorName);
        if (value && value != candidate)
            return value;
    }
    return candidate;
}

static id SPKStoryBulkMediaFromOverlay(UIView *overlayView) {
    SPKStoryContext *sharedContext = SPKStoryContextFromOverlay(overlayView);
    if (sharedContext.allMedia.count > 1)
        return sharedContext.allMedia;
    id current = SPKStoryMediaFromOverlay(overlayView);
    id sectionController = SPKStorySectionControllerFromOverlay(overlayView);
    UIViewController *controller = SPKStoryControllerFromOverlay(overlayView);
    id currentViewModel = SPKObjectForSelector(controller, @"currentViewModel") ?: SPKKVCObject(controller, @"currentViewModel");

    NSString *currentUserPK = SPKStoryUserPKFromMediaObject(current);

    for (id candidate in @[ sectionController ?: (id)NSNull.null, currentViewModel ?: (id)NSNull.null, controller ?: (id)NSNull.null ]) {
        if (!candidate || candidate == (id)NSNull.null)
            continue;
        NSArray *items = SPKStoryItemsFromCandidate(candidate);
        if (items.count <= 1)
            continue;

        NSMutableArray *resolvedMedia = [NSMutableArray array];
        for (id item in items) {
            id media = SPKStoryMediaObjectFromCandidate(item);
            if (media) {
                if (currentUserPK) {
                    NSString *itemUserPK = SPKStoryUserPKFromMediaObject(media);
                    if ([itemUserPK isEqualToString:currentUserPK]) {
                        [resolvedMedia addObject:media];
                    }
                } else {
                    [resolvedMedia addObject:media];
                }
            }
        }
        if (resolvedMedia.count > 1) {
            return [resolvedMedia copy];
        }
    }

    return current;
}

static SPKActionButtonContext *SPKStoriesActionContext(UIView *overlayView) {
    SPKActionButtonContext *context = [[SPKActionButtonContext alloc] init];
    context.source = SPKActionButtonSourceStories;
    context.view = overlayView;
    context.controller = SPKStoryControllerFromOverlay(overlayView);
    context.settingsTitle = SPKActionButtonTopicTitleForSource(SPKActionButtonSourceStories);
    context.supportedActions = SPKActionButtonSupportedActionsForSource(SPKActionButtonSourceStories);
    context.mediaResolver = ^id(SPKActionButtonContext *resolvedContext) {
        return SPKStoryMediaFromOverlay(resolvedContext.view);
    };
    context.bulkMediaResolver = ^id(SPKActionButtonContext *resolvedContext) {
        return SPKStoryBulkMediaFromOverlay(resolvedContext.view);
    };
    context.currentIndexResolver = ^NSInteger(SPKActionButtonContext *resolvedContext) {
        SPKStoryContext *sharedContext = SPKStoryContextFromOverlay(resolvedContext.view);
        return sharedContext ? sharedContext.currentIndex : 0;
    };
    return context;
}

static BOOL SPKStoriesActionFrameMatches(UIButton *button, CGRect frame) {
    if (![button isKindOfClass:[UIButton class]] || button.hidden || !button.superview)
        return NO;
    return ABS(CGRectGetMinX(button.frame) - CGRectGetMinX(frame)) < 0.5 &&
           ABS(CGRectGetMinY(button.frame) - CGRectGetMinY(frame)) < 0.5 &&
           ABS(CGRectGetWidth(button.frame) - CGRectGetWidth(frame)) < 0.5 &&
           ABS(CGRectGetHeight(button.frame) - CGRectGetHeight(frame)) < 0.5;
}

static const void *kSPKStoriesActionButtonMediaKey = &kSPKStoriesActionButtonMediaKey;

static void SPKInstallStoriesActionButton(UIView *overlayView) {
    if (!overlayView)
        return;

    if (SPKIsDirectVisualViewerAncestor(overlayView)) {
        UIButton *existing = (UIButton *)[overlayView viewWithTag:kSPKStoriesActionButtonTag];
        [existing removeFromSuperview];
        return;
    }

    UIButton *button = (UIButton *)[overlayView viewWithTag:kSPKStoriesActionButtonTag];
    if (![SPKUtils getBoolPref:@"stories_action_btn"]) {
        [button removeFromSuperview];
        return;
    }

    CGFloat size = 44.0;
    CGRect expectedFrame = SPKStoryFloatingButtonFrame(overlayView, size);
    if (CGRectIsEmpty(expectedFrame)) {
        [button removeFromSuperview];
        return;
    }

    id currentMedia = SPKStoryMediaFromOverlay(overlayView);
    id lastMedia = button ? objc_getAssociatedObject(button, kSPKStoriesActionButtonMediaKey) : nil;

    if (SPKStoriesActionFrameMatches(button, expectedFrame) && lastMedia == currentMedia)
        return;

    button = SPKActionButtonWithTag(overlayView, kSPKStoriesActionButtonTag);
    button.translatesAutoresizingMaskIntoConstraints = YES;
    SPKConfigureActionButton(button, SPKStoriesActionContext(overlayView));
    objc_setAssociatedObject(button, kSPKStoriesActionButtonMediaKey, currentMedia, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (button.hidden)
        return;

    button.frame = expectedFrame;
    SPKApplyButtonStyle(button, SPKActionButtonSourceStories);
    SPKStoryApplyDynamicRangeToButton(button);
}

%group SPKStoriesActionButtonHooks

%hook IGStoryFullscreenOverlayView
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"StoriesActionButton.layoutSubviews");
    SPKStorySetActiveOverlay((UIView *)self);
    SPKInstallStoriesActionButton((UIView *)self);
}
%end

%hook IGStoryFullscreenHeaderView
- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"StoriesActionButton.layoutSubviews2");
    UIView *overlay = [(UIView *)self superview];
    if ([NSStringFromClass(overlay.class) containsString:@"IGStoryFullscreenOverlayView"]) {
        SPKInstallStoriesActionButton(overlay);
    }
}
%end

%hook IGTapButton
- (void)setEDR:(_Bool)edr {
    %orig;
    if (edr) {
        for (UIView *w = (UIView *)self; w; w = w.superview) {
            if ([NSStringFromClass(w.class) containsString:@"IGStoryFullscreenOverlayView"]) {
                SPKInstallStoriesActionButton(w);
                break;
            }
        }
    }
}
%end

%end

extern "C" void SPKInstallStoriesActionButtonHooksIfEnabled(void) {
    if (![SPKUtils getBoolPref:@"stories_action_btn"])
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKStoriesActionButtonHooks);
    });
}
