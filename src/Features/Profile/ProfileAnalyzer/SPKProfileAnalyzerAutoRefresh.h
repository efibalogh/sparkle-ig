#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Per-account interval, in hours, between automatic scans. 0 turns auto refresh off.
FOUNDATION_EXPORT NSString *const kSPKPrefProfileAnalyzerAutoRefreshHours;

// Re-scans the active account in the background once its last scan is older than the
// chosen interval. Checked shortly after launch, on every return to the foreground and
// after an account switch, so the dashboard is current by the time it is opened. Only
// accounts that already have a scan are refreshed: the first scan stays a manual choice.
// Runs quietly and only reports a refresh that found changes.
@interface SPKProfileAnalyzerAutoRefresh : NSObject

// The interval choices offered in the dashboard, in hours (0 = off).
+ (NSArray<NSNumber *> *)intervalChoices;
+ (NSString *)titleForIntervalHours:(NSInteger)hours;
+ (NSInteger)intervalHours;
+ (void)setIntervalHours:(NSInteger)hours;

// Starts a refresh now if one is due. Cheap to over-call.
+ (void)checkIfDue;

@end

FOUNDATION_EXPORT void SPKInstallProfileAnalyzerAutoRefreshIfNeeded(void);

NS_ASSUME_NONNULL_END
