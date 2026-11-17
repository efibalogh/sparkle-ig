#import "../../Shared/MobileConfig/SPKMobileConfigOverrides.h"
#import "../../Utils.h"

// * Reorder highlights
// Instagram ships drag-to-reorder for the highlights tray on your own profile
// (hold a highlight, then drag it), gated by one MobileConfig config,
// igios_highlight_reordering (config 130739):
//   param 0 (bool) context_menu_redesign_enabled, the redesigned highlight menu.
//   param 1 (bool) is_long_press_reorder_enabled, the long-press reorder mode.
// The profile only enters reorder mode when both are on, so with the
// preference on Sparkle answers true for both reads, as an account inside the
// rollout sees. The new order is saved by Instagram's own mutation.
//
// The IDs are looked up by (config, index) at launch; on builds without the
// config (410.1.0) nothing is registered and Instagram stays stock.

static NSString *const kSPKHighlightReorderPrefKey = @"profile_highlight_reorder";

static uint32_t const kSPKHighlightReorderConfig = 130739;

// The table is scanned once; settings ask for availability before the
// Profile installer may have run.
static unsigned long long sSPKHighlightReorderParams[2];
static BOOL sSPKHighlightReorderResolved;

static void SPKHighlightReorderResolveOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKMobileConfigParamSpec const specs[] = {
            {0, SPKMobileConfigParamTypeBool},
            {1, SPKMobileConfigParamTypeBool},
        };
        sSPKHighlightReorderResolved =
            SPKMobileConfigResolveParams(kSPKHighlightReorderConfig, specs, 2, sSPKHighlightReorderParams);
        if (!sSPKHighlightReorderResolved)
            SPKLog(@"HighlightReorder", @"Config %u not resolved; keeping Instagram's highlights tray",
                   kSPKHighlightReorderConfig);
    });
}

BOOL SPKHighlightReorderIsAvailable(void) {
    SPKHighlightReorderResolveOnce();
    return sSPKHighlightReorderResolved;
}

void SPKInstallProfileHighlightReorderHooksIfNeeded(void) {
    // Registered regardless of the preference; the getters re-check it on every
    // read, so the toggle applies to the next profile Instagram builds.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!SPKHighlightReorderIsAvailable())
            return;
        SPKMobileConfigOverrideBool(sSPKHighlightReorderParams[0], kSPKHighlightReorderPrefKey, YES);
        SPKMobileConfigOverrideBool(sSPKHighlightReorderParams[1], kSPKHighlightReorderPrefKey, YES);
    });
}
