#import "SPKStrings.h"
#import "SPKDownloadTransfer.h"

#import "../../Utils.h"
#import <math.h>

@interface SPKDownloadTransfer () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *task;
@property (nonatomic, copy, nullable) SPKDownloadTransferProgressBlock progressBlock;
@property (nonatomic, copy, nullable) SPKDownloadTransferCompletionBlock completionBlock;
@property (nonatomic, copy) NSString *stagingDir;
@property (nonatomic, copy) NSString *itemID;
@property (nonatomic, copy, nullable) NSString *fileExtension;
@property (nonatomic, assign) SPKDownloadMediaKind mediaKind;
@property (nonatomic, assign) float lastReportedProgress;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong, nullable) NSURL *url;
@property (nonatomic, assign) NSUInteger throttleRetries;
@property (nonatomic, assign) BOOL retryPending;
@end

// Ready-to-play files are remuxed from the DASH segments on request. When the
// CDN can't build one it answers 429 or a 5xx, often for good, so retry once
// and then report SPKDownloadErrorServerUnavailable for the caller to fall back.
static NSUInteger const SPKDownloadThrottleMaxRetries = 1;

static BOOL SPKDownloadStatusIsServerSide(NSInteger status) {
    return status == 429 || status >= 500;
}

@implementation SPKDownloadTransfer

- (void)downloadURL:(NSURL *)url
          mediaKind:(SPKDownloadMediaKind)mediaKind
      fileExtension:(NSString *)fileExtension
         stagingDir:(NSString *)stagingDir
             itemID:(NSString *)itemID
           progress:(SPKDownloadTransferProgressBlock)progress
         completion:(SPKDownloadTransferCompletionBlock)completion {
    self.progressBlock = progress;
    self.completionBlock = completion;
    self.stagingDir = stagingDir;
    self.itemID = itemID;
    self.fileExtension = fileExtension;
    self.mediaKind = mediaKind;
    self.lastReportedProgress = 0;
    self.finished = NO;
    self.url = url;
    self.throttleRetries = 0;
    self.retryPending = NO;

    if (!url) {
        completion(nil, SPKDownloadError(SPKDownloadErrorInvalidURL, SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_INVALID_DOWNLOAD_URL_TEXT"), nil));
        return;
    }
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        completion(nil, SPKDownloadError(SPKDownloadErrorUnsupportedScheme, SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_ONLY_HTTP_HTTPS_URLS_SUPPORTED_TEXT"), nil));
        return;
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:stagingDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    self.task = [self.session downloadTaskWithURL:url];
    [self.task resume];
}

- (void)cancel {
    if (self.retryPending) {
        [self finishWithPath:nil error:SPKDownloadError(SPKDownloadErrorCancelled, SPKL(@"DOWNLOADS_SCHEDULER_DOWNLOAD_CANCELLED_ERROR"), nil)];
        return;
    }
    [self.task cancel];
    [self.session invalidateAndCancel];
    self.task = nil;
    self.session = nil;
}

- (float)normalizedProgressForTotal:(int64_t)total expected:(int64_t)expected {
    if (expected > 0) {
        float p = (float)total / (float)expected;
        return isfinite(p) ? fminf(1.0f, fmaxf(0.0f, p)) : self.lastReportedProgress;
    }
    return fminf(0.95f, self.lastReportedProgress + 0.02f);
}

- (BOOL)validateHTTPResponse:(NSURLResponse *)response error:(NSError **)error {
    if (![response isKindOfClass:NSHTTPURLResponse.class])
        return YES;
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    if (status >= 200 && status < 300)
        return YES;
    if (SPKDownloadStatusIsServerSide(status)) {
        if (error)
            *error = SPKDownloadError(SPKDownloadErrorServerUnavailable, SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_INSTAGRAM_THROTTLED_TEXT"), nil);
        return NO;
    }
    if (status == 403 || status == 404 || status == 410) {
        if (error)
            *error = SPKDownloadError(SPKDownloadErrorExpiredURL, SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_MEDIA_URL_EXPIRED_REFRESH_TRY_AGAIN_TEXT"), nil);
        return NO;
    }
    if (error)
        *error = SPKDownloadError(SPKDownloadErrorHTTPFailure, SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_INSTAGRAM_RETURNED_MISSING_MEDIA_RESPONSE_TEXT"), nil);
    return NO;
}

- (BOOL)validateContentType:(NSString *)mime mediaKind:(SPKDownloadMediaKind)kind {
    if (mime.length == 0 || kind == SPKDownloadMediaKindUnknown)
        return YES;
    NSString *lower = mime.lowercaseString;
    if ([lower containsString:@"text/html"] || [lower containsString:@"application/json"] || [lower hasPrefix:@"text/"]) {
        return NO;
    }
    return YES;
}

- (NSString *)resolvedExtensionForMIME:(NSString *)mime url:(NSURL *)url fallback:(NSString *)fallback {
    if (fallback.length >= 2)
        return fallback;
    NSString *lower = mime.lowercaseString;
    if ([lower containsString:@"jpeg"] || [lower containsString:@"jpg"])
        return @"jpg";
    if ([lower containsString:@"png"])
        return @"png";
    if ([lower containsString:@"mp4"] || [lower containsString:@"video"])
        return @"mp4";
    if ([lower containsString:@"audio"] || [lower containsString:@"mpeg"])
        return @"m4a";
    NSString *ext = url.pathExtension;
    if (ext.length >= 2)
        return ext;
    return fallback.length ? fallback : @"bin";
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    (void)session;
    (void)bytesWritten;
    int64_t expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : downloadTask.countOfBytesExpectedToReceive;
    float progress = [self normalizedProgressForTotal:totalBytesWritten expected:expected];
    self.lastReportedProgress = progress;
    if (self.progressBlock)
        self.progressBlock(totalBytesWritten, expected, progress);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    (void)session;
    if (self.finished)
        return;
    NSError *httpError = nil;
    if (![self validateHTTPResponse:downloadTask.response error:&httpError]) {
        NSInteger status = [downloadTask.response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)downloadTask.response).statusCode : 0;
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:location error:nil];
        NSData *body = [handle readDataUpToLength:300 error:nil];
        [handle closeAndReturnError:nil];
        NSString *snippet = body.length ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : nil;
        SPKLog(@"Downloads", @"transfer rejected with HTTP %ld for %@ (body: %@)", (long)status, downloadTask.originalRequest.URL.absoluteString, snippet ?: @"<none>");
        if (SPKDownloadStatusIsServerSide(status) && self.throttleRetries < SPKDownloadThrottleMaxRetries) {
            [self scheduleThrottleRetryForResponse:(NSHTTPURLResponse *)downloadTask.response];
            return;
        }
        [self finishWithPath:nil error:httpError];
        return;
    }
    NSString *mime = nil;
    if ([downloadTask.response isKindOfClass:NSHTTPURLResponse.class]) {
        mime = ((NSHTTPURLResponse *)downloadTask.response).MIMEType;
    }
    if (![self validateContentType:mime mediaKind:self.mediaKind]) {
        [self finishWithPath:nil error:SPKDownloadError(SPKDownloadErrorInvalidContentType, SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_INSTAGRAM_RETURNED_UNEXPECTED_RESPONSE_TEXT"), SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_REFRESH_TRY_AGAIN_TEXT"))];
        return;
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:nil];
    if ([attrs[NSFileSize] longLongValue] <= 0) {
        [self finishWithPath:nil error:SPKDownloadError(SPKDownloadErrorEmptyFile, SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_DOWNLOADED_FILE_EMPTY_TEXT"), nil)];
        return;
    }
    NSString *ext = [self resolvedExtensionForMIME:mime url:downloadTask.originalRequest.URL fallback:self.fileExtension ?: @""];
    NSString *dest = [[self.stagingDir stringByAppendingPathComponent:self.itemID] stringByAppendingPathExtension:ext];
    NSError *moveError = nil;
    [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
    if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:dest] error:&moveError]) {
        [self finishWithPath:nil error:SPKDownloadError(SPKDownloadErrorFileMoveFailed, SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_COULD_NOT_STORE_DOWNLOADED_FILE_TEXT"), moveError.localizedDescription)];
        return;
    }
    [self finishWithPath:dest error:nil];
}

- (void)scheduleThrottleRetryForResponse:(NSHTTPURLResponse *)response {
    self.throttleRetries += 1;
    self.retryPending = YES;
    NSTimeInterval delay = pow(2.0, (double)self.throttleRetries);
    NSString *retryAfter = [response valueForHTTPHeaderField:@"Retry-After"];
    if (retryAfter.doubleValue > 0)
        delay = fmin(10.0, retryAfter.doubleValue);
    SPKLog(@"Downloads", @"throttled, retry %lu of %lu in %.1fs", (unsigned long)self.throttleRetries, (unsigned long)SPKDownloadThrottleMaxRetries, delay);
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSOperationQueue *queue = weakSelf.session.delegateQueue;
        [queue addOperationWithBlock:^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.finished || !strongSelf.session)
                return;
            strongSelf.retryPending = NO;
            strongSelf.lastReportedProgress = 0;
            strongSelf.task = [strongSelf.session downloadTaskWithURL:strongSelf.url];
            [strongSelf.task resume];
        }];
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session;
    if (self.finished)
        return;
    if (error) {
        if (error.code == NSURLErrorCancelled) {
            [self finishWithPath:nil error:SPKDownloadError(SPKDownloadErrorCancelled, SPKL(@"DOWNLOADS_SCHEDULER_DOWNLOAD_CANCELLED_ERROR"), nil)];
        } else {
            [self finishWithPath:nil error:error];
        }
    }
}

- (void)finishWithPath:(NSString *)path error:(NSError *)error {
    if (self.finished)
        return;
    self.finished = YES;
    [self.session invalidateAndCancel];
    self.session = nil;
    self.task = nil;
    SPKDownloadTransferCompletionBlock completion = self.completionBlock;
    self.completionBlock = nil;
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(path, error);
        });
    }
}

@end
