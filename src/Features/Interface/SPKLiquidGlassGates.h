#import <Foundation/Foundation.h>

#if SPK_DEV

NS_ASSUME_NONNULL_BEGIN

// Snapshot keys. Values are NSNumber except the group and name strings;
// recorded values are -1 until the gate was first read.
static NSString *const SPKLiquidGlassGateGroupKey = @"group";
static NSString *const SPKLiquidGlassGateNameKey = @"name";
static NSString *const SPKLiquidGlassGateInstalledKey = @"installed";
static NSString *const SPKLiquidGlassGateSkippedThisLaunchKey = @"skippedNow";
static NSString *const SPKLiquidGlassGateSkippedNextLaunchKey = @"skippedNext";
static NSString *const SPKLiquidGlassGateInstagramValueKey = @"instagram";
static NSString *const SPKLiquidGlassGateReturnedValueKey = @"returned";
static NSString *const SPKLiquidGlassGateReadsKey = @"reads";

#ifdef __cplusplus
extern "C" {
#endif

/// Every gate forced Liquid Glass writes or answers, in registry order.
NSArray<NSDictionary *> *SPKLiquidGlassGateSnapshot(void);
/// Leaves one gate to Instagram from the next launch on.
void SPKLiquidGlassGateSetSkippedNextLaunch(NSString *name, BOOL skipped);
void SPKLiquidGlassGateSetAllSkippedNextLaunch(BOOL skipped);
/// Plain-text table of the snapshot, for sharing.
NSString *SPKLiquidGlassGateReport(void);
/// Readable name; a stored value and the getter reading it back share one.
NSString *SPKLiquidGlassGateDisplayName(NSString *symbol);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif
