#import <objc/runtime.h>
#import <substrate.h>

#import "../../Shared/MobileConfig/SPKMobileConfigOverrides.h"
#import "../../Utils.h"

// * Reels tab sort menu
// Instagram can show a chevron on a profile's Reels tab that sorts the reels by
// most viewed. Whether it appears is decided by one MobileConfig config,
// ig_ios_sort_profile_reels_by_views (config 78302), combined with a
// per-profile eligibility the server sends:
//   param 1 (bool) display_chevron_enabled, the chevron for profiles whose
//           eligibility defers to the viewer's experiment.
//   param 5 (bool) remove_profile_reels_sort_chevron, hides the chevron.
// The server flips these for an account over time, so the chevron comes and
// goes. The preference pins them:
//   On:  param 1 true, param 5 false, as an account inside the rollout sees.
//   Off: param 1 false, param 5 true, and the sort manager's display checks
//        answer NO, so the chevron is gone on every profile.
//   Default: Instagram's own values.
// A profile the server marks ineligible keeps no chevron even when On.
//
// The IDs are looked up by (config, index) at launch. Param 5 is missing on
// older builds (410.1.0), so each parameter is resolved on its own and a
// missing one is simply not overridden.

static NSString *const kSPKProfileReelsSortModeKey = @"profile_reels_sort_mode";
static NSString *const kSPKProfileReelsSortModeOn = @"on";
static NSString *const kSPKProfileReelsSortModeOff = @"off";

static uint32_t const kSPKProfileReelsSortConfig = 78302;

static BOOL SPKProfileReelsSortIsOff(void) {
    return [[SPKUtils getStringPref:kSPKProfileReelsSortModeKey] isEqualToString:kSPKProfileReelsSortModeOff];
}

static void SPKProfileReelsSortRegister(uint32_t index, BOOL onValue) {
    SPKMobileConfigParamSpec const spec = {index, SPKMobileConfigParamTypeBool};
    unsigned long long param = 0;
    if (!SPKMobileConfigResolveParams(kSPKProfileReelsSortConfig, &spec, 1, &param)) {
        SPKLog(@"ProfileReelsSort", @"Config %u param %u not resolved; leaving it to Instagram",
               kSPKProfileReelsSortConfig, index);
        return;
    }
    SPKMobileConfigOverrideBoolForMode(param, kSPKProfileReelsSortModeKey, kSPKProfileReelsSortModeOn, onValue);
    SPKMobileConfigOverrideBoolForMode(param, kSPKProfileReelsSortModeKey, kSPKProfileReelsSortModeOff, !onValue);
}

// MARK: - Sort manager display checks

// Off must hide the chevron even on profiles whose eligibility skips the
// MobileConfig params, so the manager's own checks answer NO as well.

static BOOL (*orig_shouldDisplayReelsTabChevron)(id, SEL);
static BOOL hook_shouldDisplayReelsTabChevron(id self, SEL _cmd) {
    if (SPKProfileReelsSortIsOff())
        return NO;
    return orig_shouldDisplayReelsTabChevron(self, _cmd);
}

static BOOL (*orig_shouldDisplayReelsSortingWithUser)(id, SEL, id, id);
static BOOL hook_shouldDisplayReelsSortingWithUser(id self, SEL _cmd, id user, id session) {
    if (SPKProfileReelsSortIsOff())
        return NO;
    return orig_shouldDisplayReelsSortingWithUser(self, _cmd, user, session);
}

static BOOL (*orig_shouldDisplayReelsSortingWithUserAccess)(id, SEL, id, id);
static BOOL hook_shouldDisplayReelsSortingWithUserAccess(id self, SEL _cmd, id access, id session) {
    if (SPKProfileReelsSortIsOff())
        return NO;
    return orig_shouldDisplayReelsSortingWithUserAccess(self, _cmd, access, session);
}

static void SPKProfileReelsSortHookManager(void) {
    Class cls = objc_getClass("_TtC18IGSortProfileReels25IGSortProfileReelsManager");
    if (!cls) {
        SPKLog(@"ProfileReelsSort", @"Sort manager not found; only MobileConfig overrides apply");
        return;
    }
    Class meta = object_getClass(cls);
    SEL chevron = @selector(shouldDisplayReelsTabChevron);
    SEL withUser = sel_registerName("shouldDisplayReelsSortingWithUser:userSession:");
    SEL withAccess = sel_registerName("shouldDisplayReelsSortingWithUserAccess:userSession:");
    if (class_getInstanceMethod(cls, chevron))
        MSHookMessageEx(cls, chevron, (IMP)hook_shouldDisplayReelsTabChevron, (IMP *)&orig_shouldDisplayReelsTabChevron);
    if (class_getInstanceMethod(meta, withUser))
        MSHookMessageEx(meta, withUser, (IMP)hook_shouldDisplayReelsSortingWithUser,
                        (IMP *)&orig_shouldDisplayReelsSortingWithUser);
    if (class_getInstanceMethod(meta, withAccess))
        MSHookMessageEx(meta, withAccess, (IMP)hook_shouldDisplayReelsSortingWithUserAccess,
                        (IMP *)&orig_shouldDisplayReelsSortingWithUserAccess);
}

void SPKInstallProfileReelsSortModeHooksIfNeeded(void) {
    // Installed regardless of the preference; every hook and override re-checks
    // it on each read, so a change applies to the next profile Instagram builds.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKProfileReelsSortRegister(1, YES);
        SPKProfileReelsSortRegister(5, NO);
        SPKProfileReelsSortHookManager();
    });
}
