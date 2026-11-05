#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../Shared/AutoSave/SPKAutoSave.h"
#import "../../Shared/Instants/SPKInstantsAutoSave.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Utils.h"
#import "InstantsManualSeen.h"
#import "InstantsResolver.h"

// These hooks are also the displayed-snap events for the Manually Mark Seen eye button, which
// needs the on-screen author for the same reason and at the same moments.
//
// Instants auto-save is driven by events, not by layout: the viewer shows the topmost
// snap when it opens, and each tap advances to the next one. Those are the only two
// moments the displayed snap changes, so those are the only two moments worth looking.
//
// Resolution starts from the live service-removal tracker and uses the view as the
// initial/fallback identity source. The snap store alone is not usable here: IG pops the
// displayed snap off it, so the store holds what's still queued and never what's on screen.

// Three things make the answer arrive late: the swap animation has to land before the new
// snap is frontmost, its image has to finish loading before it resolves, and the store
// match that upgrades it to full resolution needs that loaded image's URL. So a resolve
// that comes up empty, still shows the previous snap, or carries no backing media is
// retried rather than dropped. ~3s total covers a slow transition plus a slow fetch;
// retries stop the moment a new snap resolves with its media, so the common case costs
// one pass.
static const NSTimeInterval kSPKInstantsAutoSaveRetryDelay = 0.25;
static const NSUInteger kSPKInstantsAutoSaveMaxAttempts = 12;

// Bumped whenever a new snap is displayed (tap) or the viewer closes, so retries still
// chasing the previous snap bow out instead of saving something the user swiped past.
static NSUInteger sSPKInstantsAutoSaveGeneration = 0;

// Taps live on IGQuickSnapImmersiveViewerAnimatingSnapStackViewTapController -- a
// separate object owning the stack view's press recognizer -- NOT on the stack view
// itself, which exposes no tap method at all (verified against the 438 headers; device
// log confirmed the stack view has neither `handleTap` nor `didPressWithGestureRecognizer:`).
static NSString *const kSPKInstantsTapControllerClass =
    @"_TtC39IGQuickSnapImmersiveViewerSnapStackView61IGQuickSnapImmersiveViewerAnimatingSnapStackViewTapController";

typedef void (*SPKInstantsAutoSaveDidPressIMP)(id, SEL, id);
static SPKInstantsAutoSaveDidPressIMP orig_instantsAutoSaveDidPress = NULL;

typedef void (*SPKInstantsAutoSaveAppearIMP)(id, SEL, BOOL);
static SPKInstantsAutoSaveAppearIMP orig_instantsAutoSaveVCDidAppear = NULL;
static SPKInstantsAutoSaveAppearIMP orig_instantsAutoSaveVCDidDisappear = NULL;

static NSString *SPKInstantsAutoSaveSHA256OfData(NSData *data) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [output appendFormat:@"%02x", digest[i]];
    return output;
}

/// Stable identity for a displayed snap, used to dedupe taps and retries.
///
/// A view-resolved snap frequently has no media pk -- there's no backing model behind
/// the topmost view -- so this falls back to the media URL. When even that is absent,
/// the resolver renders the displayed image to a **UUID-named temp file**, whose URL is
/// different on every resolve and therefore useless as identity; hashing the bytes is
/// what makes the same snap look the same twice.
static NSString *SPKInstantsAutoSaveSnapKey(SPKInstantsResolvedSnap *snap) {
    if (snap.sourceMediaPK.length > 0)
        return snap.sourceMediaPK;

    NSURL *url = snap.sparkleMediaURL ?: snap.sparkleVideoURL ?: snap.sparklePhotoURL;
    if (!url)
        return nil;
    if (!url.isFileURL)
        return url.absoluteString;

    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    return data.length > 0 ? SPKInstantsAutoSaveSHA256OfData(data) : nil;
}

// The snap that was on screen last time this resolved. A tap means the displayed snap
// *must* change, so this is what "has the swap landed yet?" is measured against.
static NSString *sSPKInstantsAutoSaveLastKey = nil;

/// Short, greppable stand-in for a key that is usually a 700-character CDN URL.
static NSString *SPKInstantsAutoSaveLoggableKey(NSString *key) {
    if (key.length <= 24)
        return key ?: @"(none)";
    return [NSString stringWithFormat:@"…%@", [key substringFromIndex:key.length - 24]];
}

/// @param previousKey When non-nil, the snap known to be on screen *before* the event
/// that triggered this. Resolving that same key means the swap animation hasn't landed
/// yet, so it's a reason to retry rather than an answer -- the tap's whole point is
/// that a different snap is coming.
static void SPKInstantsAutoSaveConsiderDisplayedSnap(UIView *viewInHierarchy, NSUInteger attempt, NSUInteger generation, NSString *previousKey) {
    if (generation != sSPKInstantsAutoSaveGeneration)
        return;
    if (![SPKUtils getBoolPref:@"instants_auto_save"])
        return;
    if (!viewInHierarchy.window)
        return;

    SPKInstantsResolvedSnap *snap = SPKInstantsResolveActiveSnapInView(viewInHierarchy);
    NSString *snapKey = SPKInstantsAutoSaveSnapKey(snap);
    BOOL resolved = (snap && snapKey.length > 0);
    BOOL stale = (resolved && previousKey.length > 0 && [snapKey isEqualToString:previousKey]);
    BOOL lastAttempt = (attempt + 1 >= kSPKInstantsAutoSaveMaxAttempts);
    // No backing media means the snap resolved off the view alone, so the pipeline has no
    // candidate list to pick a quality from and saves the on-screen render (~750x750)
    // instead of the full-resolution candidate (~1440x1440) the action button gets. That
    // is a race, not a dead end: the store/registry match needs the displayed image (and
    // its specifier) to have loaded, which on viewer open it usually has not. So a
    // fallback-quality resolve is a reason to look again, and only accepted once the
    // budget is spent -- saving something is still better than dropping the snap.
    BOOL degraded = (resolved && snap.backingMedia == nil);

    if (resolved && !stale && (!degraded || lastAttempt)) {
        if (degraded) {
            SPKLog(@"Instants", @"[Sparkle AutoSave] Accepting fallback-quality snap after %lu attempts key=%@ path=%@",
                   (unsigned long)(attempt + 1), SPKInstantsAutoSaveLoggableKey(snapKey), snap.resolverPath ?: @"(none)");
        }
        sSPKInstantsAutoSaveLastKey = snapKey;
        // The snap object goes to the pipeline as-is: it's duck-typed via its
        // `sparkle*URL` properties, exactly as the action button's path does.
        SPKInstantsAutoSaveConsiderSnap(snap, snap.sourceUsername, snapKey);
        return;
    }

    if (lastAttempt) {
        SPKLog(@"Instants", @"[Sparkle AutoSave] Gave up after %lu attempts (%@) key=%@",
               (unsigned long)kSPKInstantsAutoSaveMaxAttempts,
               stale ? @"displayed snap never changed" : @"nothing resolved",
               SPKInstantsAutoSaveLoggableKey(snapKey));
        return;
    }
    __weak UIView *weakView = viewInHierarchy;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKInstantsAutoSaveRetryDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       UIView *strongView = weakView;
                       if (strongView)
                           SPKInstantsAutoSaveConsiderDisplayedSnap(strongView, attempt + 1, generation, previousKey);
                   });
}

/// @param expectsChange YES for a tap (a different snap is on its way), NO when the
/// viewer just opened and whatever is on screen is the answer.
static void SPKInstantsAutoSaveScheduleConsider(UIView *viewInHierarchy, BOOL expectsChange) {
    if (![SPKUtils getBoolPref:@"instants_auto_save"])
        return;
    sSPKInstantsAutoSaveGeneration++;
    NSUInteger generation = sSPKInstantsAutoSaveGeneration;
    NSString *previousKey = expectsChange ? sSPKInstantsAutoSaveLastKey : nil;
    __weak UIView *weakView = viewInHierarchy;
    // Next runloop turn: on a tap, the new snap only becomes topmost after IG's own
    // handler has advanced the stack.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongView = weakView;
        if (strongView)
            SPKInstantsAutoSaveConsiderDisplayedSnap(strongView, 0, generation, previousKey);
    });
}

// Re-considers the instant already on screen, for callers outside this file that just
// changed the rule for its author (the action menu's auto-save toggle). `expectsChange`
// is NO: no tap happened, so the displayed snap is meant to stay the same one.
void SPKInstantsAutoSaveConsiderCurrentSnapInView(UIView *viewInHierarchy) {
    if (!viewInHierarchy)
        return;
    SPKInstantsAutoSaveScheduleConsider(viewInHierarchy, NO);
}

/// The tap controller's own "this press was a hold, not a tap" flag -- a Swift Bool
/// ivar, so it has to be read at its offset rather than via KVC. Defaults to NO when
/// absent, which just means a hold costs a few wasted resolves.
static BOOL SPKInstantsAutoSaveDidTriggerLongPress(id tapController) {
    Ivar ivar = class_getInstanceVariable([tapController class], "didTriggerLongPress");
    if (!ivar)
        return NO;
    return *(BOOL *)((char *)(__bridge void *)tapController + ivar_getOffset(ivar));
}

static void replaced_instantsAutoSaveDidPress(id self, SEL _cmd, id recognizer) {
    if (orig_instantsAutoSaveDidPress)
        orig_instantsAutoSaveDidPress(self, _cmd, recognizer);

    // It's a long-press recognizer driving both "hold to pause" and "tap to advance",
    // so it fires through began/changed/ended for one press. Only the lift can have
    // advanced the snap; acting on began would just re-resolve the current one.
    if ([recognizer isKindOfClass:UIGestureRecognizer.class] &&
        ((UIGestureRecognizer *)recognizer).state != UIGestureRecognizerStateEnded)
        return;

    // A hold pauses rather than advances, so waiting for a snap that isn't coming would
    // just burn the whole retry budget.
    if (SPKInstantsAutoSaveDidTriggerLongPress(self))
        return;

    // `view` is the stack view the recognizer is attached to; the tap controller holds
    // it weakly under the same name as a fallback.
    UIView *view = [recognizer isKindOfClass:UIGestureRecognizer.class] ? ((UIGestureRecognizer *)recognizer).view : nil;
    if (!view)
        view = [SPKUtils getIvarForObj:self name:"view"];
    if (![view isKindOfClass:UIView.class])
        return;

    SPKInstantsManualSeenDisplayedSnapMayHaveChanged(view, YES);
    if (![SPKUtils getBoolPref:@"instants_auto_save"])
        return;
    SPKLog(@"Instants", @"[Sparkle AutoSave] Tap: waiting for the next snap (previous=%@)",
           SPKInstantsAutoSaveLoggableKey(sSPKInstantsAutoSaveLastKey));
    SPKInstantsAutoSaveScheduleConsider(view, YES);
}

static void replaced_instantsAutoSaveVCDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_instantsAutoSaveVCDidAppear)
        orig_instantsAutoSaveVCDidAppear(self, _cmd, animated);
    // The topmost snap: shown on open without any tap, so nothing else would catch it.
    sSPKInstantsAutoSaveLastKey = nil;
    if ([self isKindOfClass:UIViewController.class]) {
        SPKInstantsManualSeenDisplayedSnapMayHaveChanged(((UIViewController *)self).view, NO);
        SPKInstantsAutoSaveScheduleConsider(((UIViewController *)self).view, NO);
    }
}

static void replaced_instantsAutoSaveVCDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (orig_instantsAutoSaveVCDidDisappear)
        orig_instantsAutoSaveVCDidDisappear(self, _cmd, animated);
    // Ends the session and strands any in-flight retry. The summary may land later,
    // since downloads outlive the viewer.
    sSPKInstantsAutoSaveGeneration++;
    sSPKInstantsAutoSaveLastKey = nil;
    SPKAutoSaveSessionDidEnd();
    SPKInstantsAutoSaveViewerSessionDidEnd();
    SPKInstantsManualSeenDisplayedSnapSessionEnded();
}

// The QuickSnap classes are Swift and register late, so this mirrors the action
// button's retry loop rather than assuming they exist at install time.
static BOOL sSPKInstantsAutoSaveInstalled = NO;
static BOOL sSPKInstantsAutoSaveRetryScheduled = NO;

static void SPKInstantsAutoSaveHookInstanceMethod(const char *className, SEL selector, IMP replacement, IMP *original) {
    Class cls = objc_getClass(className);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!cls || !method) {
        SPKLog(@"Instants", @"[Sparkle AutoSave] Missing hook target %s %@", className, NSStringFromSelector(selector));
        return;
    }
    MSHookMessageEx(cls, selector, replacement, original);
}

static void SPKInstallInstantsAutoSaveHooksAttempt(NSUInteger attempt) {
    if (sSPKInstantsAutoSaveInstalled)
        return;

    Class tapControllerClass = objc_getClass(kSPKInstantsTapControllerClass.UTF8String);
    if (!tapControllerClass) {
        if (attempt >= 60) {
            SPKLog(@"Instants", @"[Sparkle AutoSave] QuickSnap tap controller class missing after retries; Instants auto-save inactive");
            return;
        }
        if (!sSPKInstantsAutoSaveRetryScheduled) {
            sSPKInstantsAutoSaveRetryScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                sSPKInstantsAutoSaveRetryScheduled = NO;
                SPKInstallInstantsAutoSaveHooksAttempt(attempt + 1);
            });
        }
        return;
    }

    SPKInstantsAutoSaveHookInstanceMethod(kSPKInstantsTapControllerClass.UTF8String,
                                          @selector(didPressWithGestureRecognizer:),
                                          (IMP)replaced_instantsAutoSaveDidPress,
                                          (IMP *)&orig_instantsAutoSaveDidPress);
    SPKInstantsAutoSaveHookInstanceMethod("_TtC26IGQuickSnapConsumptionCore36IGQuickSnapConsumptionViewController",
                                          @selector(viewDidAppear:),
                                          (IMP)replaced_instantsAutoSaveVCDidAppear,
                                          (IMP *)&orig_instantsAutoSaveVCDidAppear);
    SPKInstantsAutoSaveHookInstanceMethod("_TtC26IGQuickSnapConsumptionCore36IGQuickSnapConsumptionViewController",
                                          @selector(viewDidDisappear:),
                                          (IMP)replaced_instantsAutoSaveVCDidDisappear,
                                          (IMP *)&orig_instantsAutoSaveVCDidDisappear);
    SPKAutoSaveRegisterNotificationIdentifier(kSPKNotificationInstantsAutoSave);
    SPKAutoSaveStartWatching();
    sSPKInstantsAutoSaveInstalled = YES;
    SPKLog(@"Instants", @"[Sparkle AutoSave] Instants auto-save hooks installed");
}

// Installed unconditionally: the consider path re-reads the pref on every call, so
// gating install on it would mean toggling the feature on requires a restart.
extern "C" void SPKInstallInstantsAutoSaveHooksIfEnabled(void) {
    SPKInstallInstantsAutoSaveHooksAttempt(0);
}
