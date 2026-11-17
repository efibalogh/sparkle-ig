#import "../../Shared/MobileConfig/SPKMobileConfigOverrides.h"
#import "../../Utils.h"

// * Hold to pause reels
// Instagram is rolling out a long-press menu on reels from its servers: on
// accounts that have it, holding a reel opens the playback sheet from the more
// menu instead of pausing, after a longer press. Both are driven by one
// MobileConfig config, ig_reels_long_press_overflow_menu (config 121815):
//   param 0 (bool)   gates the menu in the reel's long-press handler.
//   param 2 (double) the press duration. When it is not positive, the reel cell
//                    takes its classic branch: a 0.15s hold and untouched tap
//                    timeouts, so a hold is instant and never reads as a tap.
// With the preference on Sparkle answers false and 0 for those two reads, which
// is exactly what an account outside the rollout sees, so the classic hold
// (pause, 2x on the sides, scrubbing) runs as Instagram's own code.
//
// Parameter IDs are reassigned on every build, but the config number and the
// parameter index are stable. Instagram ships a table that maps each pair to
// the build's ID (it uses it to migrate stored values across app updates), so
// the IDs are looked up there at launch. When the config or either parameter
// is missing or ambiguous nothing is hooked and Instagram stays stock.

static NSString *const kSPKReelsHoldPausePrefKey = @"reels_hold_to_pause";

static uint32_t const kSPKReelsHoldConfig = 121815;
static uint32_t const kSPKReelsHoldMenuGateIndex = 0;
static uint32_t const kSPKReelsHoldPressDurationIndex = 2;

extern "C" void SPKInstallReelsHoldToPauseHooksIfNeeded(void) {
    // Registered regardless of the preference; the getters re-check it on every
    // read of the two parameters, so the toggle applies to reels opened after it.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKMobileConfigParamSpec const specs[] = {
            {kSPKReelsHoldMenuGateIndex, SPKMobileConfigParamTypeBool},
            {kSPKReelsHoldPressDurationIndex, SPKMobileConfigParamTypeDouble},
        };
        unsigned long long params[2] = {};
        if (!SPKMobileConfigResolveParams(kSPKReelsHoldConfig, specs, 2, params)) {
            SPKLog(@"ReelsHold", @"Config %u not resolved; keeping Instagram's hold", kSPKReelsHoldConfig);
            return;
        }
        SPKMobileConfigOverrideBool(params[0], kSPKReelsHoldPausePrefKey, NO);
        SPKMobileConfigOverrideDouble(params[1], kSPKReelsHoldPausePrefKey, 0);
    });
}
