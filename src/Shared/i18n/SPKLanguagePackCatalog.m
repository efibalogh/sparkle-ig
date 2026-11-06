//  SPKLanguagePackCatalog.m

#import "SPKLanguagePackCatalog.h"
#import "SPKLanguagePack.h"
#import "SPKStrings.h"
#import "../../Utils.h"

NSString *const SPKLanguageCatalogDefaultURL = @"https://raw.githubusercontent.com/efibalogh/sparkle-ig/main/catalog.json";
NSString *const SPKLanguageCatalogErrorDomain = @"SPKLanguageCatalogErrorDomain";

static NSString *const kSPKCatalogURLPref = @"langpack_catalog_url";
static const NSUInteger kSPKMaxCatalogBytes = 512 * 1024;  // an index of ~50 langs is a few KB
// A hard deadline on the whole fetch. The session's own timeouts only start once it has a host to
// connect to, and the DNS lookup ahead of it can sit for the better part of a minute with no network
// before it gives up, which leaves a screen saying "Loading languages" long past the point anyone
// would call it loading. Whatever happens, the caller hears back within this.
static const NSTimeInterval kSPKCatalogDeadline = 20.0;

@implementation SPKLanguageCatalogEntry
- (NSString *)displayName {
    if (self.endonym.length) return self.endonym;
    if (self.name.length) return self.name;
    return self.code ?: @"";
}
@end

#pragma mark - Bounded JSON fetcher

@interface SPKCatalogFetcher : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy) void (^completion)(NSData *_Nullable, NSError *_Nullable);
@property (atomic, assign) BOOL finished;
@end

static NSMutableSet<SPKCatalogFetcher *> *sSPKActiveFetchers;

@implementation SPKCatalogFetcher

- (void)finishWithData:(NSData *)data error:(NSError *)error {
    @synchronized(self) { if (self.finished) return; self.finished = YES; }
    void (^completion)(NSData *, NSError *) = self.completion;
    if (completion) completion(data, error);
    [self.session finishTasksAndInvalidate];
    @synchronized([SPKCatalogFetcher class]) { [sSPKActiveFetchers removeObject:self]; }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (self.finished) return;
    if (!self.buffer) self.buffer = [NSMutableData data];
    if (self.buffer.length + data.length > kSPKMaxCatalogBytes) {
        [dataTask cancel];
        [self finishWithData:nil error:[NSError errorWithDomain:SPKLanguageCatalogErrorDomain code:2 userInfo:nil]];
        return;
    }
    [self.buffer appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (self.finished) return;
    if (error) { [self finishWithData:nil error:error]; return; }
    NSHTTPURLResponse *http = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)task.response : nil;
    if (http && (http.statusCode < 200 || http.statusCode >= 300)) {
        [self finishWithData:nil error:[NSError errorWithDomain:SPKLanguageCatalogErrorDomain code:3 userInfo:nil]];
        return;
    }
    [self finishWithData:self.buffer error:nil];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {
    // A hop only has to stay on https without userinfo.
    NSURL *next = request.URL;
    if ([next.scheme.lowercaseString isEqualToString:@"https"] && next.host.length && !next.user.length && !next.password.length) {
        completionHandler(request);
    } else {
        completionHandler(nil);
        [self finishWithData:nil error:[NSError errorWithDomain:SPKLanguageCatalogErrorDomain code:4 userInfo:nil]];
    }
}

@end

#pragma mark -

@implementation SPKLanguagePackCatalog

+ (NSURL *)catalogURL {
    NSString *override = [SPKUtils getStringPref:kSPKCatalogURLPref];
    NSURL *url = override.length ? [NSURL URLWithString:override] : nil;
    if (url && [url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length) return url;
    return [NSURL URLWithString:SPKLanguageCatalogDefaultURL];
}

+ (NSError *)catalogError { return [NSError errorWithDomain:SPKLanguageCatalogErrorDomain code:1
                                                  userInfo:@{ NSLocalizedDescriptionKey: SPKL(@"LANGUAGE_PACK_CATALOG_ERROR") }]; }

+ (nullable SPKLanguageCatalogEntry *)entryFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSString *code = dict[@"code"];
    NSString *urlString = dict[@"url"];
    if (![code isKindOfClass:[NSString class]] || !SPKLanguageCodeIsWellFormed(code)) return nil;
    if (![urlString isKindOfClass:[NSString class]]) return nil;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"] || url.host.length == 0) return nil;
    SPKLanguageCatalogEntry *entry = [SPKLanguageCatalogEntry new];
    entry.code = code;  // preserved verbatim (last-resort displayName fallback + install code)
    entry.name = [dict[@"name"] isKindOfClass:[NSString class]] ? dict[@"name"] : code;
    entry.endonym = [dict[@"endonym"] isKindOfClass:[NSString class]] ? dict[@"endonym"] : nil;
    entry.url = url;
    entry.sha256 = [dict[@"sha256"] isKindOfClass:[NSString class]] ? [dict[@"sha256"] lowercaseString] : nil;
    entry.bytes = [dict[@"bytes"] isKindOfClass:[NSNumber class]] ? [dict[@"bytes"] longLongValue] : 0;
    NSInteger coverage = [dict[@"coverage"] isKindOfClass:[NSNumber class]] ? [dict[@"coverage"] integerValue] : 0;
    entry.coverage = MIN(100, MAX(0, coverage));
    return entry;
}

+ (NSArray<SPKLanguageCatalogEntry *> *)parseEntries:(NSData *)data {
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSArray *packs = [root isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)root)[@"packs"] : nil;
    if (![packs isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray<SPKLanguageCatalogEntry *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in packs) {
        SPKLanguageCatalogEntry *entry = [self entryFromDictionary:item];
        NSString *key = entry.code.lowercaseString;  // case-insensitive dedup
        if (entry && key.length && ![seen containsObject:key]) { [seen addObject:key]; [entries addObject:entry]; }
    }
    // A feed that listed packs but where EVERY row failed validation (e.g. a server-side schema change)
    // is a broken catalog, not an empty one — return nil so the UI shows an error, not "no new languages".
    if (packs.count > 0 && entries.count == 0) return nil;
    [entries sortUsingComparator:^NSComparisonResult(SPKLanguageCatalogEntry *a, SPKLanguageCatalogEntry *b) {
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];
    return [entries copy];
}

+ (void)fetchEntriesWithCompletion:(void (^)(NSArray<SPKLanguageCatalogEntry *> *_Nullable, NSError *_Nullable))completion {
    NSParameterAssert(completion);
    // One-shot: the deadline below races the real result, and whichever arrives first is the answer.
    __block BOOL delivered = NO;
    NSObject *deliveryLock = [NSObject new];
    void (^done)(NSArray *, NSError *) = ^(NSArray *entries, NSError *error) {
        @synchronized(deliveryLock) {
            if (delivered) return;
            delivered = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(entries, error); });
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKCatalogDeadline * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!delivered)
            SPKLog(@"i18n", @"[LangPackCatalog] giving up after %.0fs", kSPKCatalogDeadline);
        done(nil, [self catalogError]);  // no-op if the fetch already answered
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURL *catalogURL = [self catalogURL];
        SPKCatalogFetcher *fetcher = [SPKCatalogFetcher new];
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 12.0;
        cfg.timeoutIntervalForResource = 20.0;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        fetcher.session = [NSURLSession sessionWithConfiguration:cfg delegate:fetcher delegateQueue:nil];
        fetcher.completion = ^(NSData *data, NSError *error) {
            if (error || data.length == 0) { done(nil, [self catalogError]); return; }
            NSArray *entries = [self parseEntries:data];
            if (!entries) { done(nil, [self catalogError]); return; }
            SPKLog(@"i18n", @"[LangPackCatalog] fetched %lu entries", (unsigned long)entries.count);
            done(entries, nil);
        };
        @synchronized([SPKCatalogFetcher class]) {
            if (!sSPKActiveFetchers) sSPKActiveFetchers = [NSMutableSet set];
            [sSPKActiveFetchers addObject:fetcher];
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:catalogURL];
        [request setValue:@"Sparkle-LanguagePack/1.0" forHTTPHeaderField:@"User-Agent"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [[fetcher.session dataTaskWithRequest:request] resume];
    });
}

@end
