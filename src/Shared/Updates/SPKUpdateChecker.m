//  SPKUpdateChecker.m

#import "SPKUpdateChecker.h"
#import <dlfcn.h>

#import "SPKStrings.h"
#import "SPKUpdateSheetViewController.h"
#import "../../Settings/SPKSetting.h"
#import "../../Tweak.h"
#import "../../Utils.h"

NSNotificationName const SPKUpdateCheckerStateDidChangeNotification = @"SPKUpdateCheckerStateDidChangeNotification";

static NSString *const kSPKLastCheckKey = @"app_update_last_check";
// Separate from the last SUCCESSFUL check, so a device with no network tries once an hour rather
// than on every launch, while a good check waits the full interval.
static NSString *const kSPKLastAttemptKey = @"app_update_last_attempt";
static NSString *const kSPKLatestVersionKey = @"app_update_latest_version";
// The release links the last `latest.json` named, for the update action between requests.
static NSString *const kSPKLatestFeedKey = @"app_update_latest_feed";
static NSString *const kSPKSkippedVersionKey = @"app_update_skipped_version";
#if SPK_DEV
static NSString *const kSPKDevInstalledVersionKey = @"app_update_dev_installed_version";
static NSString *const kSPKDevFeedURLKey = @"app_update_dev_feed_url";
#endif

static NSString *const kSPKRepoBaseURL = @"https://efibalogh.github.io/sparkle-ig/";
static NSString *const kSPKPackageIdentifier = @"com.sparkle.sparkle";
static NSString *const kSPKSideloadUpdateURL = @"https://t.me/sparkle_ig";

static const NSTimeInterval kSPKCheckInterval = 6 * 60 * 60;
static const NSTimeInterval kSPKRetryInterval = 60 * 60;
// Held off the first moments of launch: nothing about this is urgent, and a sheet over a feed
// that is still loading reads as part of the launch going wrong.
static const NSTimeInterval kSPKLaunchDelay = 4.0;
// While something else is presented (a story, a share sheet, What's New), the prompt waits for
// it to close, polling this often, and gives up for this launch after the last attempt.
static const NSTimeInterval kSPKPromptRetryInterval = 5.0;
static const NSInteger kSPKPromptMaxAttempts = 24;
static const NSUInteger kSPKMaxFeedBytes = 64 * 1024;

typedef void (^SPKUpdateFetchCompletion)(NSString *_Nullable latestVersion, NSDictionary *_Nullable feed);

// Main-thread only. Callers that arrive while a request is in flight wait for its answer.
static BOOL sSPKChecking = NO;
static BOOL sSPKLastCheckFailed = NO;
static BOOL sSPKPromptedThisLaunch = NO;
static NSMutableArray<void (^)(BOOL)> *sSPKPendingCompletions = nil;

@implementation SPKUpdateChecker

#pragma mark - Versions

+ (NSArray<NSNumber *> *)componentsOfVersion:(NSString *)version {
    NSString *trimmed = [version ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trimmed hasPrefix:@"v"] || [trimmed hasPrefix:@"V"])
        trimmed = [trimmed substringFromIndex:1];
    NSMutableArray<NSNumber *> *components = [NSMutableArray array];
    for (NSString *part in [trimmed componentsSeparatedByString:@"."]) {
        NSScanner *scanner = [NSScanner scannerWithString:part];
        NSInteger value = 0;
        if (![scanner scanInteger:&value] || value < 0)
            break;
        [components addObject:@(value)];
        if (!scanner.isAtEnd)
            break;  // "2-beta": the numeric part counts, the rest ends the version
    }
    return components;
}

+ (NSComparisonResult)compareVersion:(NSString *)lhs toVersion:(NSString *)rhs {
    NSArray<NSNumber *> *a = [self componentsOfVersion:lhs];
    NSArray<NSNumber *> *b = [self componentsOfVersion:rhs];
    NSUInteger count = MAX(a.count, b.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger x = i < a.count ? a[i].integerValue : 0;
        NSInteger y = i < b.count ? b[i].integerValue : 0;
        if (x != y)
            return x < y ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}

+ (NSString *)normalizedVersion:(NSString *)version {
    NSArray<NSNumber *> *components = [self componentsOfVersion:version];
    return components.count ? [components componentsJoinedByString:@"."] : nil;
}

+ (NSString *)displayVersion:(NSString *)version {
    NSString *normalized = [self normalizedVersion:version];
    return normalized ? [@"v" stringByAppendingString:normalized] : (version ?: @"");
}

+ (NSString *)installedVersion {
#if SPK_DEV
    NSString *fake = [SPKUtils getStringPref:kSPKDevInstalledVersionKey];
    if ([self normalizedVersion:fake])
        return fake;
#endif
    return SPKVersionString;
}

+ (nullable NSString *)latestKnownVersion {
    NSString *latest = [NSUserDefaults.standardUserDefaults stringForKey:kSPKLatestVersionKey];
    return latest.length ? latest : nil;
}

+ (BOOL)updateAvailable {
    NSString *latest = [self latestKnownVersion];
    return latest && [self compareVersion:latest toVersion:[self installedVersion]] == NSOrderedDescending;
}

+ (BOOL)isChecking {
    return sSPKChecking;
}

+ (BOOL)lastCheckFailed {
    return sSPKLastCheckFailed;
}

+ (BOOL)latestIsSkipped {
    NSString *latest = [self latestKnownVersion];
    NSString *skipped = [NSUserDefaults.standardUserDefaults stringForKey:kSPKSkippedVersionKey];
    return latest && skipped && [self compareVersion:skipped toVersion:latest] == NSOrderedSame;
}

+ (void)skipLatestVersion {
    NSString *latest = [self latestKnownVersion];
    if (latest)
        [NSUserDefaults.standardUserDefaults setObject:latest forKey:kSPKSkippedVersionKey];
}

+ (NSURL *)changelogURL {
    return [NSURL URLWithString:[kSPKRepoBaseURL stringByAppendingString:@"changelog.html"]];
}

#pragma mark - Feed

+ (NSArray<NSURL *> *)feedURLs {
#if SPK_DEV
    NSString *override = [SPKUtils getStringPref:kSPKDevFeedURLKey];
    NSURL *overrideURL = override.length ? [NSURL URLWithString:override] : nil;
    if (overrideURL.host.length && ([overrideURL.scheme isEqualToString:@"https"] || [overrideURL.scheme isEqualToString:@"http"]))
        return @[ overrideURL ];
#endif
    return @[
        [NSURL URLWithString:[kSPKRepoBaseURL stringByAppendingString:@"latest.json"]],
        [NSURL URLWithString:[kSPKRepoBaseURL stringByAppendingString:@"Packages"]],
    ];
}

/// `latest.json` is `{"version": "1.5.2", ...}`; a `Packages` index carries one `Version:` line per
/// architecture, of which the highest wins.
+ (nullable NSString *)versionFromFeedData:(NSData *)data feed:(NSDictionary **)feedOut {
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if ([root isKindOfClass:[NSDictionary class]]) {
        id version = ((NSDictionary *)root)[@"version"];
        NSString *normalized = [version isKindOfClass:[NSString class]] ? [self normalizedVersion:version] : nil;
        if (normalized && feedOut)
            *feedOut = root;
        return normalized;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *best = nil;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (![line hasPrefix:@"Version:"])
            continue;
        NSString *candidate = [self normalizedVersion:[line substringFromIndex:8]];
        if (candidate && (!best || [self compareVersion:candidate toVersion:best] == NSOrderedDescending))
            best = candidate;
    }
    return best;
}

/// Keeps only what the update action reads, with the types it expects, so a malformed feed cannot
/// break the stored defaults.
+ (NSDictionary *)storableFeedFromFeed:(NSDictionary *)feed {
    NSMutableDictionary *stored = [NSMutableDictionary dictionary];
    for (NSString *key in @[ @"jailbreakURL", @"sideloadURL" ]) {
        if ([feed[key] isKindOfClass:[NSString class]])
            stored[key] = feed[key];
    }
    return stored;
}

+ (NSDictionary *)storedFeed {
    id feed = [NSUserDefaults.standardUserDefaults objectForKey:kSPKLatestFeedKey];
    return [feed isKindOfClass:[NSDictionary class]] ? feed : @{};
}

+ (void)fetchURLs:(NSArray<NSURL *> *)urls session:(NSURLSession *)session completion:(SPKUpdateFetchCompletion)completion {
    if (urls.count == 0) {
        completion(nil, nil);
        return;
    }
    NSURL *url = urls.firstObject;
    NSArray<NSURL *> *rest = [urls subarrayWithRange:NSMakeRange(1, urls.count - 1)];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:[NSString stringWithFormat:@"Sparkle/%@", SPKVersionString] forHTTPHeaderField:@"User-Agent"];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        BOOL ok = !error && data.length > 0 && data.length <= kSPKMaxFeedBytes && (!http || (http.statusCode >= 200 && http.statusCode < 300));
        NSDictionary *feed = nil;
        NSString *version = ok ? [self versionFromFeedData:data feed:&feed] : nil;
        if (version) {
            completion(version, feed);
            return;
        }
        SPKLog(@"Update", @"No version from %@ (%@)", url.lastPathComponent, error.localizedDescription ?: @(http.statusCode));
        [self fetchURLs:rest session:session completion:completion];
    }] resume];
}

+ (void)fetchFeedWithSession:(NSURLSession *)session completion:(SPKUpdateFetchCompletion)completion {
#if SPK_DEV
    // The dev feed field also takes the feed itself, pasted as JSON, so the sheet can be tried
    // without hosting a file anywhere.
    NSString *override = [[SPKUtils getStringPref:kSPKDevFeedURLKey] ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([override hasPrefix:@"{"]) {
        // Smart punctuation turns typed quotes curly, which JSON rejects.
        for (NSString *curly in @[ @"\u201C", @"\u201D", @"\u201E" ])
            override = [override stringByReplacingOccurrencesOfString:curly withString:@"\""];
        NSDictionary *feed = nil;
        NSString *version = [self versionFromFeedData:[override dataUsingEncoding:NSUTF8StringEncoding] feed:&feed];
        if (!version)
            SPKLog(@"Update", @"Dev feed JSON has no usable version");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            completion(version, feed);
        });
        return;
    }
#endif
    [self fetchURLs:[self feedURLs] session:session completion:completion];
}

+ (void)fetchLatestWithCompletion:(void (^)(BOOL success))completion {
    if (!sSPKPendingCompletions)
        sSPKPendingCompletions = [NSMutableArray array];
    [sSPKPendingCompletions addObject:[completion copy]];
    if (sSPKChecking)
        return;
    sSPKChecking = YES;
    [self postStateChange];
    [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970 forKey:kSPKLastAttemptKey];

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 12.0;
    configuration.timeoutIntervalForResource = 20.0;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    [self fetchFeedWithSession:session completion:^(NSString *version, NSDictionary *feed) {
        [session finishTasksAndInvalidate];
        dispatch_async(dispatch_get_main_queue(), ^{
            sSPKChecking = NO;
            sSPKLastCheckFailed = (version == nil);
            if (version) {
                NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                [defaults setObject:version forKey:kSPKLatestVersionKey];
                [defaults setDouble:NSDate.date.timeIntervalSince1970 forKey:kSPKLastCheckKey];
                // A Packages answer has no feed; drop the previous release's links with it.
                [defaults setObject:[self storableFeedFromFeed:feed ?: @{}] forKey:kSPKLatestFeedKey];
                SPKLog(@"Update", @"Latest %@, installed %@", version, [self installedVersion]);
            }
            [self postStateChange];
            NSArray<void (^)(BOOL)> *completions = [sSPKPendingCompletions copy];
            [sSPKPendingCompletions removeAllObjects];
            for (void (^pending)(BOOL) in completions)
                pending(version != nil);
        });
    }];
}

+ (void)postStateChange {
    dispatch_block_t post = ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SPKUpdateCheckerStateDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter postNotificationName:SPKSettingAccessoryTextDidChangeNotification object:nil];
    };
    if (NSThread.isMainThread)
        post();
    else
        dispatch_async(dispatch_get_main_queue(), post);
}

#pragma mark - Checks

+ (BOOL)fetchIsDue {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval lastCheck = [defaults doubleForKey:kSPKLastCheckKey];
    NSTimeInterval lastAttempt = [defaults doubleForKey:kSPKLastAttemptKey];
    if (lastCheck > 0 && now - lastCheck < kSPKCheckInterval)
        return NO;
    if (lastAttempt > 0 && now - lastAttempt < kSPKRetryInterval)
        return NO;
    return YES;
}

+ (void)scheduleLaunchCheck {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKLaunchDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![self fetchIsDue]) {
            [self promptOnLaunchAttempt:0];
            return;
        }
        // A failed refresh still prompts for the update already known.
        [self fetchLatestWithCompletion:^(__unused BOOL success) {
            [self promptOnLaunchAttempt:0];
        }];
    });
}

+ (void)promptOnLaunchAttempt:(NSInteger)attempt {
    if (sSPKPromptedThisLaunch || ![self updateAvailable] || [self latestIsSkipped])
        return;
    UIViewController *top = topMostController();
    BOOL busy = UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !top || top.presentingViewController != nil;
    if (busy) {
        if (attempt + 1 >= kSPKPromptMaxAttempts)
            return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKPromptRetryInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self promptOnLaunchAttempt:attempt + 1];
        });
        return;
    }
    sSPKPromptedThisLaunch = YES;
    [SPKUpdateSheetViewController presentFromViewController:top announce:YES];
}

+ (void)checkNowFromViewController:(nullable UIViewController *)presenter {
    if ([self updateAvailable]) {
        [SPKUpdateSheetViewController presentFromViewController:presenter];
        return;
    }
    __weak UIViewController *weakPresenter = presenter;
    [self fetchLatestWithCompletion:^(BOOL success) {
        if (success && [self updateAvailable])
            [SPKUpdateSheetViewController presentFromViewController:weakPresenter];
    }];
}

#pragma mark - Update destination

/// A tweak dylib loaded from the package manager's tweak directories, rather than from inside the
/// app bundle or a LiveContainer folder, means the install is a jailbreak package.
+ (BOOL)isJailbreakInstall {
    static BOOL jailbreak = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Dl_info info;
        if (!dladdr((const void *)&SPKUpdateCheckerStateDidChangeNotification, &info) || !info.dli_fname)
            return;
        NSString *path = [NSString stringWithUTF8String:info.dli_fname];
        if ([path hasPrefix:NSBundle.mainBundle.bundlePath])
            return;
        for (NSString *marker in @[ @"/Library/MobileSubstrate/DynamicLibraries/", @"/usr/lib/TweakInject/", @"/var/jb/" ]) {
            if ([path containsString:marker]) {
                jailbreak = YES;
                return;
            }
        }
    });
    return jailbreak;
}

+ (nullable NSURL *)feedURLForKey:(NSString *)key {
    id value = [self storedFeed][key];
    NSURL *url = [value isKindOfClass:[NSString class]] ? [NSURL URLWithString:value] : nil;
    return url.scheme.length ? url : nil;
}

+ (void)openURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0)
        return;
    NSArray<NSURL *> *rest = [urls subarrayWithRange:NSMakeRange(1, urls.count - 1)];
    [UIApplication.sharedApplication openURL:urls.firstObject
                                     options:@{}
                           completionHandler:^(BOOL success) {
                               if (!success)
                                   [self openURLs:rest];
                           }];
}

+ (void)openUpdateDestination {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    if ([self isJailbreakInstall]) {
        NSURL *custom = [self feedURLForKey:@"jailbreakURL"];
        if (custom)
            [urls addObject:custom];
        // Whichever package manager is installed opens on the package; the repo page is the last resort.
        [urls addObject:[NSURL URLWithString:[@"sileo://package/" stringByAppendingString:kSPKPackageIdentifier]]];
        [urls addObject:[NSURL URLWithString:[@"zbra://packages/" stringByAppendingString:kSPKPackageIdentifier]]];
        [urls addObject:[NSURL URLWithString:[@"cydia://package/" stringByAppendingString:kSPKPackageIdentifier]]];
        [urls addObject:[NSURL URLWithString:kSPKRepoBaseURL]];
    } else {
        NSURL *custom = [self feedURLForKey:@"sideloadURL"];
        if (custom)
            [urls addObject:custom];
        [urls addObject:[NSURL URLWithString:kSPKSideloadUpdateURL]];
    }
    [self openURLs:urls];
}

#if SPK_DEV
+ (void)resetState {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in @[ kSPKLastCheckKey, kSPKLastAttemptKey, kSPKLatestVersionKey, kSPKLatestFeedKey, kSPKSkippedVersionKey ])
        [defaults removeObjectForKey:key];
    sSPKPromptedThisLaunch = NO;
    sSPKLastCheckFailed = NO;
    [self postStateChange];
}
#endif

@end
