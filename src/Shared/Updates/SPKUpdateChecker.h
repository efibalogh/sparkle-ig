//  SPKUpdateChecker.h
//  Tells the user when a newer Sparkle has been released.
//
//  The release feed is `latest.json` on the jailbreak repo (gh-pages), written by the release
//  tooling next to `changelog.html`. A repo without it still answers through its `Packages` index,
//  which every release has always published, so the check works against the repo as it stands.
//
//  The last answer is kept, so the prompt appears on every launch while an update is waiting,
//  without waiting on the network, until the user updates or skips that version. The feed itself
//  is refreshed every few hours. Nothing is downloaded or installed: the update action hands off
//  to the package manager on jailbroken devices and to the release channel on sideloaded ones.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main thread whenever the known latest version or the checking state changes.
FOUNDATION_EXPORT NSNotificationName const SPKUpdateCheckerStateDidChangeNotification;

@interface SPKUpdateChecker : NSObject

/// Call once per launch. A little after launch it refreshes the feed when due, then offers the
/// update sheet if a version newer than this one is waiting and has not been skipped.
+ (void)scheduleLaunchCheck;

/// For an explicit tap: shows the update sheet when an update is known (skipped or not), and
/// otherwise checks right away and shows the sheet if one turns up. The outcome of a check is
/// reported through the state notification, not an alert.
+ (void)checkNowFromViewController:(nullable UIViewController *)presenter;

/// YES while a request is in flight.
+ (BOOL)isChecking;

/// YES when the most recent explicit check could not reach the feed.
+ (BOOL)lastCheckFailed;

/// The newest version the feed has reported, without a leading "v", or nil before any check.
+ (nullable NSString *)latestKnownVersion;

/// YES when the newest version the feed has reported is newer than the installed one.
+ (BOOL)updateAvailable;

/// The installed version the comparison uses. Dev builds can override it to test the prompt.
+ (NSString *)installedVersion;

/// "v1.5.2" for "1.5.2" or "v1.5.2".
+ (NSString *)displayVersion:(NSString *)version;

/// YES when Sparkle was installed as a jailbreak package rather than injected into the app.
+ (BOOL)isJailbreakInstall;

/// Never offers `latestKnownVersion` on launch again; a newer one is offered as usual.
+ (void)skipLatestVersion;

/// The public changelog page.
+ (NSURL *)changelogURL;

/// Hands off to wherever this install gets its updates: the package manager on a jailbroken
/// device, the release channel on a sideloaded one.
+ (void)openUpdateDestination;

/// Orders dotted versions numerically ("1.5.10" after "1.5.9"). A leading "v" and anything after
/// the numeric components ("-beta") are ignored; missing components count as zero.
+ (NSComparisonResult)compareVersion:(NSString *)lhs toVersion:(NSString *)rhs;

#if SPK_DEV
/// Forgets every check, skip and cached result, so the next launch behaves like a first check.
+ (void)resetState;
#endif

@end

NS_ASSUME_NONNULL_END
