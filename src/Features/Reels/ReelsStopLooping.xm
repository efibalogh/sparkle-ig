#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import "ReelsAutoScrollDefault.h"
#import <objc/message.h>
#import <objc/runtime.h>

// * Stop looping reels
// Looping lives in the video player, not the reels cell. The cell's play reaches
// the player synchronously, so a play that starts inside the cell's play belongs
// to a reel and every other video in the app keeps looping. 448 turns looping off
// with the player's isLoopingOverride; 410 has no override, so the wrapped player's
// own looping flag (or a loop controller's max loop count) is lowered instead. With looping off the player stops on the last
// frame and reports completion to the cell, which then shows Instagram's own
// paused state. The next play of an ended reel rewinds it first, whether it comes
// from the play button, a tap, or scrolling back to the reel.

static NSString *const kSPKReelsStopLoopingPrefKey = @"reels_stop_looping";

static const void *kSPKReelsStopLoopingPlayerAssocKey = &kSPKReelsStopLoopingPlayerAssocKey;
static const void *kSPKReelsStopLoopingEndedAssocKey = &kSPKReelsStopLoopingEndedAssocKey;
static const void *kSPKReelsStopLoopingAppliedAssocKey = &kSPKReelsStopLoopingAppliedAssocKey;
static const void *kSPKReelsStopLoopingMaxLoopAssocKey = &kSPKReelsStopLoopingMaxLoopAssocKey;

// Main thread only, like every reels playback call.
static NSInteger sSPKReelsStopLoopingCellPlayDepth = 0;
static __weak UIView *sSPKReelsStopLoopingPlayingCell = nil;
static BOOL sSPKReelsStopLoopingSyntheticTap = NO;
static BOOL sSPKReelsStopLoopingInRealTap = NO;
static BOOL sSPKReelsStopLoopingTapToggledPlayback = NO;
// -1 unknown, 0 a tap does something else (mute), 1 a tap pauses.
static NSInteger sSPKReelsStopLoopingObservedTapPauses = -1;

@interface SPKReelsStopLoopingWeakPlayer : NSObject
@property (nonatomic, weak) id player;
@end

@implementation SPKReelsStopLoopingWeakPlayer
@end

// Auto Scroll in force wins: an ended reel has to keep going for Instagram to
// advance, so the saved Stop Looping choice is left alone but not acted on.
static BOOL SPKReelsStopLoopingEnabled(void) {
    if ([SPKReelsAutoScrollEffectiveMode() isEqualToString:@"on"])
        return NO;
    return [SPKUtils getBoolPref:kSPKReelsStopLoopingPrefKey];
}

static id SPKReelsStopLoopingPlayerForCell(UIView *cell) {
    SPKReelsStopLoopingWeakPlayer *box = objc_getAssociatedObject(cell, kSPKReelsStopLoopingPlayerAssocKey);
    return box.player;
}

static BOOL SPKReelsStopLoopingCellEnded(UIView *cell) {
    return [objc_getAssociatedObject(cell, kSPKReelsStopLoopingEndedAssocKey) boolValue];
}

static void SPKReelsStopLoopingSetCellEnded(UIView *cell, BOOL ended) {
    objc_setAssociatedObject(cell, kSPKReelsStopLoopingEndedAssocKey, ended ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static const void *kSPKReelsStopLoopingHandlesLoopingAssocKey = &kSPKReelsStopLoopingHandlesLoopingAssocKey;

// 410 reels players are built without their own loop controller; the wrapped
// IGFNFVideoPlayer rewinds at the end itself while its _shouldHandleLooping is set.
static id SPKReelsStopLoopingInnerPlayer(id player) {
    SEL inner = NSSelectorFromString(@"videoPlayer");
    return [player respondsToSelector:inner] ? ((id (*)(id, SEL))objc_msgSend)(player, inner) : nil;
}

static BOOL *SPKReelsStopLoopingHandlesLoopingSlot(id player) {
    id inner = SPKReelsStopLoopingInnerPlayer(player);
    Ivar ivar = inner ? class_getInstanceVariable(object_getClass(inner), "_shouldHandleLooping") : NULL;
    if (!ivar)
        return NULL;
    return (BOOL *)((uint8_t *)(__bridge void *)inner + ivar_getOffset(ivar));
}

// Other 410 players: IGStatefulVideoLoopController keeps the limit in a plain ivar.
static long long *SPKReelsStopLoopingMaxLoopSlot(id player) {
    id loopController = [SPKUtils getIvarForObj:player name:"_loopController"];
    Ivar ivar = loopController ? class_getInstanceVariable(object_getClass(loopController), "_maxLoopCount") : NULL;
    if (!ivar)
        return NULL;
    return (long long *)((uint8_t *)(__bridge void *)loopController + ivar_getOffset(ivar));
}

static void SPKReelsStopLoopingApplyToPlayer(id player) {
    SEL overrideSetter = NSSelectorFromString(@"setIsLoopingOverride:");
    if ([player respondsToSelector:overrideSetter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(player, overrideSetter, @NO);
    } else if (SPKReelsStopLoopingMaxLoopSlot(player) == NULL && SPKReelsStopLoopingHandlesLoopingSlot(player)) {
        BOOL *handlesLooping = SPKReelsStopLoopingHandlesLoopingSlot(player);
        if (!objc_getAssociatedObject(player, kSPKReelsStopLoopingHandlesLoopingAssocKey))
            objc_setAssociatedObject(player, kSPKReelsStopLoopingHandlesLoopingAssocKey, @(*handlesLooping), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        *handlesLooping = NO;
    } else {
        long long *slot = SPKReelsStopLoopingMaxLoopSlot(player);
        if (!slot) {
            SPKLog(@"StopLooping", @"apply FAILED no loop slot player=%@ loopController=%@ inner=%@", NSStringFromClass([player class]),
                   [SPKUtils getIvarForObj:player name:"_loopController"], SPKReelsStopLoopingInnerPlayer(player));
            return;
        }
        if (!objc_getAssociatedObject(player, kSPKReelsStopLoopingMaxLoopAssocKey))
            objc_setAssociatedObject(player, kSPKReelsStopLoopingMaxLoopAssocKey, @(*slot), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        *slot = 1;
    }
    objc_setAssociatedObject(player, kSPKReelsStopLoopingAppliedAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SPKReelsStopLoopingRestorePlayer(id player) {
    SEL overrideSetter = NSSelectorFromString(@"setIsLoopingOverride:");
    if ([player respondsToSelector:overrideSetter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(player, overrideSetter, nil);
    } else if (objc_getAssociatedObject(player, kSPKReelsStopLoopingHandlesLoopingAssocKey)) {
        NSNumber *original = objc_getAssociatedObject(player, kSPKReelsStopLoopingHandlesLoopingAssocKey);
        BOOL *handlesLooping = SPKReelsStopLoopingHandlesLoopingSlot(player);
        if (handlesLooping)
            *handlesLooping = original.boolValue;
        objc_setAssociatedObject(player, kSPKReelsStopLoopingHandlesLoopingAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        NSNumber *original = objc_getAssociatedObject(player, kSPKReelsStopLoopingMaxLoopAssocKey);
        long long *slot = SPKReelsStopLoopingMaxLoopSlot(player);
        if (slot && original)
            *slot = original.longLongValue;
        objc_setAssociatedObject(player, kSPKReelsStopLoopingMaxLoopAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(player, kSPKReelsStopLoopingAppliedAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SPKReelsStopLoopingWillPlayPlayer(id player) {
    if (!player)
        return;
    BOOL applied = [objc_getAssociatedObject(player, kSPKReelsStopLoopingAppliedAssocKey) boolValue];
    if (!SPKReelsStopLoopingEnabled()) {
        if (applied)
            SPKReelsStopLoopingRestorePlayer(player);
        return;
    }
    UIView *cell = sSPKReelsStopLoopingPlayingCell;
    if (sSPKReelsStopLoopingCellPlayDepth <= 0 || !cell)
        return;

    SPKReelsStopLoopingApplyToPlayer(player);
    SPKReelsStopLoopingWeakPlayer *box = [SPKReelsStopLoopingWeakPlayer new];
    box.player = player;
    objc_setAssociatedObject(cell, kSPKReelsStopLoopingPlayerAssocKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Only a tap that pauses may be replayed: with tap set to mute it would toggle sound.
static BOOL SPKReelsStopLoopingTapPauses(UIView *cell) {
    NSString *tapControl = [SPKUtils getStringPref:@"reels_tap_control"];
    if ([tapControl isEqualToString:@"pause"])
        return YES;
    if ([tapControl isEqualToString:@"mute"])
        return NO;

    id sectionController = [cell respondsToSelector:@selector(delegate)] ? ((id (*)(id, SEL))objc_msgSend)(cell, @selector(delegate)) : nil;
    id configuration = nil;
    if (sectionController) {
        configuration = [SPKUtils getIvarForObj:sectionController name:"playbackControlsTestConfiguration"]
                            ?: [SPKUtils getIvarForObj:sectionController name:"_playbackControlsTestConfiguration"];
    }
    SEL tapToPause = NSSelectorFromString(@"tapToPauseEnabled");
    if ([configuration respondsToSelector:tapToPause])
        return ((BOOL (*)(id, SEL))objc_msgSend)(configuration, tapToPause);
    return sSPKReelsStopLoopingObservedTapPauses == 1;
}

// Replays Instagram's own single tap so the reel enters its native paused state,
// play button included, exactly as if the viewer had tapped to pause.
static void SPKReelsStopLoopingShowPausedState(UIView *cell) {
    if (!cell.window || !SPKReelsStopLoopingCellEnded(cell) || !SPKReelsStopLoopingTapPauses(cell))
        return;
    SEL singleTap = @selector(gestureController:didObserveSingleTap:);
    if (![cell respondsToSelector:singleTap])
        return;
    id gestureController = [SPKUtils getIvarForObj:cell name:"_gestureController"];
    if (!gestureController)
        return;
    id tap = [SPKUtils getIvarForObj:gestureController name:"singleTapRecognizer"]
                 ?: [SPKUtils getIvarForObj:gestureController name:"_singleTapRecognizer"];
    if (![tap isKindOfClass:[UIGestureRecognizer class]])
        return;

    sSPKReelsStopLoopingSyntheticTap = YES;
    ((void (*)(id, SEL, id, id))objc_msgSend)(cell, singleTap, gestureController, tap);
    sSPKReelsStopLoopingSyntheticTap = NO;
}

%group SPKReelsStopLoopingCellHooks

%hook IGSundialViewerVideoCell
- (void)playWithReason:(long long)reason {
    if (sSPKReelsStopLoopingInRealTap)
        sSPKReelsStopLoopingTapToggledPlayback = YES;

    UIView *cell = (UIView *)self;
    if (SPKReelsStopLoopingCellEnded(cell)) {
        SPKReelsStopLoopingSetCellEnded(cell, NO);
        id player = SPKReelsStopLoopingPlayerForCell(cell);
        if (SPKReelsStopLoopingEnabled() && [player respondsToSelector:@selector(seekToTime:preciseTime:)])
            [(IGStatefulVideoPlayer *)player seekToTime:0 preciseTime:YES];
    }

    sSPKReelsStopLoopingCellPlayDepth++;
    sSPKReelsStopLoopingPlayingCell = cell;
    %orig(reason);
    sSPKReelsStopLoopingCellPlayDepth--;
}

- (void)pauseWithReason:(long long)reason {
    if (sSPKReelsStopLoopingInRealTap)
        sSPKReelsStopLoopingTapToggledPlayback = YES;
    %orig(reason);
}

- (void)gestureController:(id)controller didObserveSingleTap:(id)tap {
    if (sSPKReelsStopLoopingSyntheticTap) {
        %orig(controller, tap);
        return;
    }
    // Learn what a tap does, for builds where the tap configuration is unreachable.
    sSPKReelsStopLoopingInRealTap = YES;
    sSPKReelsStopLoopingTapToggledPlayback = NO;
    %orig(controller, tap);
    sSPKReelsStopLoopingInRealTap = NO;
    sSPKReelsStopLoopingObservedTapPauses = sSPKReelsStopLoopingTapToggledPlayback ? 1 : 0;
}

- (void)videoViewDidPlayThroughToCompletion:(id)videoView {
    %orig(videoView);
    UIView *cell = (UIView *)self;
    id player = SPKReelsStopLoopingPlayerForCell(cell);
    if (!player || ![objc_getAssociatedObject(player, kSPKReelsStopLoopingAppliedAssocKey) boolValue] || !SPKReelsStopLoopingEnabled())
        return;

    SPKReelsStopLoopingSetCellEnded(cell, YES);
    __weak UIView *weakCell = cell;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongCell = weakCell;
        if (strongCell)
            SPKReelsStopLoopingShowPausedState(strongCell);
    });
}
%end

%end

%group SPKReelsStopLoopingSwiftPlayerHooks

%hook _TtC21IGVideoPlayerKitSwift13IGVideoPlayer
- (void)playWithReason:(long long)reason callsiteContext:(id)context {
    SPKReelsStopLoopingWillPlayPlayer(self);
    %orig(reason, context);
}
%end

%end

%group SPKReelsStopLoopingStatefulPlayerHooks

%hook IGStatefulVideoPlayer
- (void)playWithReason:(long long)reason callsiteContext:(id)context {
    SPKReelsStopLoopingWillPlayPlayer(self);
    %orig(reason, context);
}
%end

%end

extern "C" void SPKInstallReelsStopLoopingHooksIfNeeded(void) {
    // Installed regardless of the preference so it applies to the next reel when
    // toggled; every hook re-checks the preference at call time.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!NSClassFromString(@"IGSundialViewerVideoCell"))
            return;
        %init(SPKReelsStopLoopingCellHooks);
        BOOL swiftPlayer = objc_getClass("_TtC21IGVideoPlayerKitSwift13IGVideoPlayer") != Nil;
        BOOL statefulPlayer = NSClassFromString(@"IGStatefulVideoPlayer") != Nil;
        if (swiftPlayer)
            %init(SPKReelsStopLoopingSwiftPlayerHooks);
        if (statefulPlayer)
            %init(SPKReelsStopLoopingStatefulPlayerHooks);
        SPKLog(@"StopLooping", @"installed swiftPlayer=%d statefulPlayer=%d", swiftPlayer, statefulPlayer);
    });
}
