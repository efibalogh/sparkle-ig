// Main-thread stall meter + hierarchy growth probe.
//
// "The app feels laggy after navigating deep" is not something a bisect can be
// driven from: judging each round by feel is unreliable and the rounds are not
// comparable. This turns the symptom into numbers.
//
// Two independent measurements, both opt-in:
//
//  1. Stall meter — a background timer pings the main queue and measures how
//     long the ping takes to run. That latency is main-thread blocked time, so
//     it captures exactly what "the UI is laggy" means, without a profiler and
//     without a debuggable build.
//
//  2. Hierarchy probe — counts the view controllers, views and gesture
//     recognizers currently alive in the key window. A leak of screens (nav
//     stack never popping, recognizers re-added per layout, overlays never
//     removed) shows up here as a number that climbs with navigation depth and
//     never comes back down, which is the signature of a slowdown that only
//     gets worse the more you browse.
//
// Both feed the on-screen HUD, so the numbers can be watched while navigating.

// Developer-only: compiled out unless SPK_DEV is defined (see Makefile).
// The no-op fallbacks at the bottom of this header keep every call site - the
// SPK_PERF_SCOPE lines scattered through src/Features in particular - compiling
// unchanged in a release build, emitting nothing.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#if SPK_DEV

/// Preference keys (registered as global keys, see SPKPrefIsGlobalKey).
FOUNDATION_EXPORT NSString *const kSPKPerfMeterEnabledKey;
FOUNDATION_EXPORT NSString *const kSPKPerfMeterHUDKey;

/// Starts/stops the sampler. Safe to call repeatedly and from any thread.
FOUNDATION_EXPORT void SPKPerfMeterSetEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL SPKPerfMeterIsEnabled(void);

/// Starts the meter and the HUD if their prefs are set. Called at launch.
FOUNDATION_EXPORT void SPKPerfMeterStartIfEnabled(void);

FOUNDATION_EXPORT void SPKPerfMeterSetHUDVisible(BOOL visible);
FOUNDATION_EXPORT BOOL SPKPerfMeterHUDIsVisible(void);

/// Clears every statistic and counter, and restarts the measurement window.
/// Do this immediately before a measured run so rounds are comparable.
FOUNDATION_EXPORT void SPKPerfMeterReset(void);

/// Snapshot of the current window:
///   elapsed, blockedMs, blockedPercent, worstMs, stalls, longStalls,
///   viewControllers, views, gestureRecognizers, deepestNavStack, counters.
FOUNDATION_EXPORT NSDictionary *SPKPerfMeterSnapshot(void);

/// One-line summary, e.g. "1.4s blocked over 52s (2.7%), worst 210ms".
FOUNDATION_EXPORT NSString *SPKPerfMeterSummary(void);

/// Writes the full snapshot to the log under the "Perf" category. The meter also
/// does this on its own every 15 seconds while running, so a navigation run
/// leaves a timeline behind without anything having to be tapped.
FOUNDATION_EXPORT void SPKPerfMeterLogSnapshot(NSString *label);

/// The single most expensive instrumented hook so far, e.g.
/// "ShareLongPress.layoutSubviews - 3.8s over 4201 calls". Empty when nothing
/// has been recorded yet.
FOUNDATION_EXPORT NSString *SPKPerfMeterWorstScopeSummary(void);

/// Complete, shareable diagnostic report for the current measurement window.
/// Contains build/device metadata, aggregate stalls, timed scopes, counters and
/// sampled main-thread freeze stacks. It intentionally contains no account or
/// media identifiers.
FOUNDATION_EXPORT NSString *SPKPerfMeterTextReport(void);

/// Ad-hoc counters, for when the stall meter says "something is slow" and the
/// question becomes "how often does this run". Thread-safe and cheap enough to
/// drop into a layout path while hunting; remove them once the hunt is over.
FOUNDATION_EXPORT void SPKPerfMeterCount(NSString *key);
FOUNDATION_EXPORT void SPKPerfMeterCountBy(NSString *key, NSInteger amount);

// MARK: - Scopes
//
// A counter says how often a hook ran; a scope says how much of the main thread
// it ate. That is the number that actually names a culprit, because a hook can
// run 40,000 times and cost nothing, or run twice and cost a second.
//
// Put SPK_PERF_SCOPE(@"Name") at the top of a hook body and the meter reports
// total time, call count and average per name, sorted with the worst first. The
// scope ends when the enclosing block does, %orig included.
//
//     - (void)layoutSubviews {
//         SPK_PERF_SCOPE(@"ShareLongPress.ufiBar");
//         %orig;
//         SPKInstallShareLongPressInContainer(...);
//     }
//
// Nested scopes with the same name (recursion) double-count, so name the entry
// point rather than the recursive step.

typedef struct {
    __unsafe_unretained NSString *_Nullable key;
    CFTimeInterval start;
} SPKPerfScope;

FOUNDATION_EXPORT SPKPerfScope SPKPerfScopeBegin(NSString *key);
FOUNDATION_EXPORT void SPKPerfScopeEnd(SPKPerfScope *scope);

/// Scoped timer that closes itself when the enclosing scope exits.
#define SPK_PERF_SCOPE(nameLiteral)                                                    \
    __attribute__((cleanup(SPKPerfScopeEnd))) SPKPerfScope _spk_perf_scope __attribute__((unused)) = \
        SPKPerfScopeBegin(nameLiteral)

#else // SPK_DEV

// Release build: no meter, no HUD, no sampler, no scopes.
#define SPK_PERF_SCOPE(nameLiteral) \
    do {                            \
    } while (0)

NS_INLINE void SPKPerfMeterStartIfEnabled(void) {
}
NS_INLINE void SPKPerfMeterCount(NSString *key) {
    (void)key;
}
NS_INLINE void SPKPerfMeterCountBy(NSString *key, NSInteger amount) {
    (void)key;
    (void)amount;
}
NS_INLINE void SPKPerfMeterLogSnapshot(NSString *label) {
    (void)label;
}

#endif // SPK_DEV

NS_ASSUME_NONNULL_END
