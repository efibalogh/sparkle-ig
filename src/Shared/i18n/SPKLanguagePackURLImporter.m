//  SPKLanguagePackURLImporter.m

#import "SPKLanguagePackURLImporter.h"
#import "SPKLanguagePack.h"
#import "SPKStrings.h"
#import "../../Utils.h"

#import <CommonCrypto/CommonDigest.h>

NSString *const SPKLanguagePackURLImportErrorDomain = @"SPKLanguagePackURLImportErrorDomain";

static const long long kSPKMaxPackBytes = 8LL * 1024 * 1024;  // 8 MB
static NSMutableSet<SPKLanguagePackURLImporter *> *sSPKActiveImporters;  // keep-alive; guarded by @synchronized([SPKLanguagePackURLImporter class])

// Where a host resolves is deliberately not checked. The user pastes the URL themselves, nothing
// downloaded is ever shown back to whoever wrote the link, and any web page can already reach the
// same addresses. Checking broke every VPN that answers DNS with a fake-IP range. What protects the
// user is https, the size cap, the sha256 pin, the unzip limits and the string sanitizer.

#pragma mark -

@interface SPKLanguagePackURLImporter () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDownloadTask *task;
@property (nonatomic, copy, nullable) NSString *expectedSHA256;
@property (nonatomic, copy, nullable) void (^progressBlock)(double);
@property (nonatomic, copy) void (^completionBlock)(SPKLanguagePack *_Nullable, NSError *_Nullable);
@property (atomic, assign) BOOL cancelled;
@property (atomic, assign) BOOL finished;
// Checksum + install wait for didCompleteWithError: so a transport error reported after the file
// landed still wins over installing it.
@property (nonatomic, copy, nullable) NSString *pendingZipPath;
@property (nonatomic, copy, nullable) NSString *pendingTempDir;
@end

@implementation SPKLanguagePackURLImporter

+ (long long)maximumPackBytes { return kSPKMaxPackBytes; }

+ (NSError *)errorWithCode:(SPKLanguagePackURLImportErrorCode)code message:(NSString *)message underlying:(nullable NSError *)underlying {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (message.length) info[NSLocalizedDescriptionKey] = message;
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:SPKLanguagePackURLImportErrorDomain code:code userInfo:info];
}

+ (instancetype)importFromURL:(NSURL *)url
               expectedSHA256:(nullable NSString *)expectedSHA256
                     progress:(nullable void (^)(double))progress
                   completion:(void (^)(SPKLanguagePack *_Nullable, NSError *_Nullable))completion {
    NSParameterAssert(completion);
    SPKLanguagePackURLImporter *importer = [SPKLanguagePackURLImporter new];
    importer.url = url;
    importer.expectedSHA256 = expectedSHA256.lowercaseString;
    importer.progressBlock = progress;
    importer.completionBlock = completion;
    @synchronized([SPKLanguagePackURLImporter class]) {  // same lock object as the removal site (this is a class method)
        if (!sSPKActiveImporters) sSPKActiveImporters = [NSMutableSet set];
        [sSPKActiveImporters addObject:importer];
    }
    // The checksum and install run off-main.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [importer start]; });
    return importer;
}

- (void)start {
    if (self.cancelled) { [self failWithCode:SPKLanguagePackURLImportErrorCancelled message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil]; return; }
    if (![self.url isKindOfClass:[NSURL class]] || self.url.host.length == 0) {
        [self failWithCode:SPKLanguagePackURLImportErrorInvalidURL message:SPKL(@"LANGUAGE_PACK_URL_INVALID") underlying:nil]; return;
    }
    if (![self.url.scheme.lowercaseString isEqualToString:@"https"]) {
        [self failWithCode:SPKLanguagePackURLImportErrorInsecureScheme message:SPKL(@"LANGUAGE_PACK_URL_INSECURE") underlying:nil]; return;
    }
    if (self.url.user.length || self.url.password.length) {
        [self failWithCode:SPKLanguagePackURLImportErrorDisallowedHost message:SPKL(@"LANGUAGE_PACK_URL_BLOCKED") underlying:nil]; return;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 30.0;
    cfg.timeoutIntervalForResource = 120.0;
    cfg.HTTPMaximumConnectionsPerHost = 1;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.url];
    request.HTTPMethod = @"GET";
    [request setValue:@"Sparkle-LanguagePack/1.0" forHTTPHeaderField:@"User-Agent"];
    // Create AND resume the task atomically with -cancel's check: -cancel runs on the caller's
    // (main) thread while this runs on a background queue, both touch self.task. Under one lock,
    // either -cancel wins (sets cancelled, we skip resume → deterministic Cancelled) or we win
    // (task created + resumed, so a later -cancel hits a live, resumed task and its cancel is honoured
    // — cancelling a not-yet-resumed task is the case where didCompleteWithError: may never fire).
    BOOL cancelledFirst = NO;
    @synchronized(self) {
        if (self.cancelled) {
            cancelledFirst = YES;
        } else {
            self.task = [self.session downloadTaskWithRequest:request];
            [self.task resume];
        }
    }
    if (cancelledFirst) { [self failWithCode:SPKLanguagePackURLImportErrorCancelled message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil]; return; }
    SPKLog(@"i18n", @"[LangPackURL] downloading %@", self.url.absoluteString);
}

- (void)cancel {
    @synchronized(self) {
        self.cancelled = YES;
        [self.task cancel];  // task (if any) was resumed under this same lock → didCompleteWithError(Cancelled) fires
    }
}

#pragma mark - Completion plumbing (one-shot)

- (void)finishWithPack:(nullable SPKLanguagePack *)pack error:(nullable NSError *)error {
    @synchronized(self) {
        if (self.finished) return;
        self.finished = YES;
    }
    NSString *temp = self.pendingTempDir;   // every terminal path funnels here → single cleanup site
    if (temp.length) {
        [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
        self.pendingTempDir = nil; self.pendingZipPath = nil;
    }
    void (^completion)(SPKLanguagePack *, NSError *) = self.completionBlock;
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(pack, error); });
    [self.session finishTasksAndInvalidate];  // releases the session's retain on us
    @synchronized([SPKLanguagePackURLImporter class]) { [sSPKActiveImporters removeObject:self]; }
}

- (void)failWithCode:(SPKLanguagePackURLImportErrorCode)code message:(NSString *)message underlying:(nullable NSError *)underlying {
    [self.task cancel];
    [self finishWithPack:nil error:[[self class] errorWithCode:code message:message underlying:underlying]];
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
              didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
 totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (self.finished) return;
    if ((totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > kSPKMaxPackBytes) || totalBytesWritten > kSPKMaxPackBytes) {
        [self failWithCode:SPKLanguagePackURLImportErrorTooLarge message:SPKL(@"LANGUAGE_PACK_TOO_LARGE") underlying:nil];
        return;
    }
    void (^progress)(double) = self.progressBlock;
    if (progress && totalBytesExpectedToWrite > 0) {
        double fraction = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
        dispatch_async(dispatch_get_main_queue(), ^{ progress(MIN(1.0, MAX(0.0, fraction))); });
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didFinishDownloadingToURL:(NSURL *)location {
    if (self.finished) return;
    NSHTTPURLResponse *response = [downloadTask.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)downloadTask.response : nil;
    if (response && (response.statusCode < 200 || response.statusCode >= 300)) {
        [self failWithCode:SPKLanguagePackURLImportErrorHTTPStatus message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSNumber *sizeValue = nil;
    if ([location getResourceValue:&sizeValue forKey:NSURLFileSizeKey error:NULL] && sizeValue.longLongValue > kSPKMaxPackBytes) {
        [self failWithCode:SPKLanguagePackURLImportErrorTooLarge message:SPKL(@"LANGUAGE_PACK_TOO_LARGE") underlying:nil];
        return;
    }
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"SparkleLangURL-%@", NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *zipPath = [tempDir stringByAppendingPathComponent:@"pack.zip"];
    NSError *moveError = nil;
    if (![fm moveItemAtPath:location.path toPath:zipPath error:&moveError]) {
        [fm removeItemAtPath:tempDir error:nil];
        [self failWithCode:SPKLanguagePackURLImportErrorDownloadFailed message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:moveError];
        return;
    }
    // Checksum + import run from didCompleteWithError: once the task has finished cleanly.
    self.pendingTempDir = tempDir;
    self.pendingZipPath = zipPath;
}

// Runs once, from a clean didCompleteWithError:. Checksums, then imports.
- (void)finalizeDownload {
    if (self.finished) return;
    if (self.cancelled) {  // -cancel landed after the download finished; the terminal task's
        // [task cancel] was a no-op, so honour the cancel here before we install. (Header contract: the
        // completion fires once with a Cancelled error.)
        [self failWithCode:SPKLanguagePackURLImportErrorCancelled message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
        return;
    }
    NSString *zipPath = self.pendingZipPath;
    if (zipPath.length == 0) {  // task succeeded but produced no file — treat as a failed download
        [self failWithCode:SPKLanguagePackURLImportErrorDownloadFailed message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
        return;
    }
    if (self.expectedSHA256.length) {
        NSString *actual = [[self class] sha256HexOfFileAtPath:zipPath];
        if (actual == nil) {  // couldn't read the temp file to hash it — that's a local I/O failure,
            // NOT a checksum mismatch; report it as such so the user isn't told the pack was tampered.
            [self failWithCode:SPKLanguagePackURLImportErrorDownloadFailed message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
            return;
        }
        if (![actual isEqualToString:self.expectedSHA256]) {
            [self failWithCode:SPKLanguagePackURLImportErrorChecksumMismatch message:SPKL(@"LANGUAGE_PACK_CHECKSUM_MISMATCH") underlying:nil];
            return;
        }
    }
    // Serialize the actual on-disk install across ALL importer instances: SPKLanguagePackManager
    // importPackAtURL: does an unlocked removeItemAtPath:+copyItemAtPath: to <code>.lproj, so two
    // concurrent installs of the same code (e.g. a catalog tap racing a paste-URL import) could interleave
    // filesystem ops on the same directory. One shared serial queue makes the install step atomic.
    static dispatch_queue_t installQ;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ installQ = dispatch_queue_create("com.sparkle.langpack.install", DISPATCH_QUEUE_SERIAL); });
    if (self.cancelled) {  // -cancel may have landed during the checksum hash — honour it before installing
        [self failWithCode:SPKLanguagePackURLImportErrorCancelled message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
        return;
    }
    __block NSError *importError = nil;
    __block SPKLanguagePack *pack = nil;
    dispatch_sync(installQ, ^{ pack = [SPKLanguagePackManager importPackAtURL:[NSURL fileURLWithPath:zipPath] error:&importError]; });
    if (!pack) {
        [self finishWithPack:nil error:importError ?: [[self class] errorWithCode:SPKLanguagePackURLImportErrorDownloadFailed message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil]];
        return;
    }
    if (self.cancelled) {  // -cancel landed during/just after the install — roll it back so the header's
        // "completion fires with a Cancelled error" contract holds end-to-end (don't leave a pack the user cancelled).
        [SPKLanguagePackManager removePack:pack error:NULL];
        [self failWithCode:SPKLanguagePackURLImportErrorCancelled message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:nil];
        return;
    }
    // Record where this pack came from so the updater can tell a later release apart from this one.
    SPKLanguagePackRecordProvenance(pack.code, self.url.absoluteString, self.expectedSHA256);
    SPKLog(@"i18n", @"[LangPackURL] installed %@ (%lu strings)", pack.code, (unsigned long)pack.stringCount);
    [self finishWithPack:pack error:nil];  // finishWithPack removes pendingTempDir
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(nullable NSError *)error {
    if (self.finished) return;
    if (error) {
        BOOL wasCancel = self.cancelled || (error.code == NSURLErrorCancelled && [error.domain isEqualToString:NSURLErrorDomain]);
        [self finishWithPack:nil error:[[self class] errorWithCode:(wasCancel ? SPKLanguagePackURLImportErrorCancelled : SPKLanguagePackURLImportErrorDownloadFailed)
                                                        message:SPKL(@"LANGUAGE_PACK_DOWNLOAD_FAILED") underlying:error]];
        return;
    }
    [self finalizeDownload];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {
    // GitHub releases redirect to their asset CDN; a hop only has to stay on https without userinfo.
    NSURL *next = request.URL;
    BOOL safe = [next.scheme.lowercaseString isEqualToString:@"https"] && next.host.length &&
                !next.user.length && !next.password.length;
    if (!safe) SPKLog(@"i18n", @"[LangPackURL] refusing redirect to %@", next.host);
    if (safe) {
        completionHandler(request);
    } else {
        completionHandler(nil);
        [self failWithCode:SPKLanguagePackURLImportErrorDisallowedHost message:SPKL(@"LANGUAGE_PACK_URL_BLOCKED") underlying:nil];
    }
}

#pragma mark - SHA-256

+ (nullable NSString *)sha256HexOfFileAtPath:(NSString *)path {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    if (!stream) return nil;
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    [stream open];
    uint8_t buffer[65536];
    NSInteger read;
    while ((read = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&ctx, buffer, (CC_LONG)read);
    [stream close];
    if (read < 0) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return [hex copy];
}

@end
