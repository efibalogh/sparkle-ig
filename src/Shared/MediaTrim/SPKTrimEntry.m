#import "SPKStrings.h"
#import "SPKTrimEntry.h"
#import "SPKTrimConfiguration.h"
#import "SPKTrimEditorViewController.h"
#import "SPKTrimResult.h"
#import "SPKTrimSaveCoordinator.h"
#import "SPKTrimSourcePlan.h"

#import "../../Utils.h"
#import "../Downloads/SPKDownloadDestinationWriter.h"
#import "../Gallery/SPKGalleryFile.h"
#import "../Gallery/SPKGallerySaveMetadata.h"
#import "../Gallery/SPKGalleryViewController.h"
#import "../MediaDownload/SPKMediaQualityManager.h"
#import "../UI/SPKNotificationCenter.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface SPKTrimEntry () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDownloadTask *task;
@property (nonatomic, strong) SPKNotificationPillView *prepPill;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, strong, nullable) SPKGallerySaveMetadata *metadata;
@property (nonatomic, strong, nullable) id mediaObject;
@property (nonatomic, copy, nullable) NSURL *photoURL;
@property (nonatomic, copy, nullable) NSURL *videoURL;
@property (nonatomic, copy, nullable) NSURL *localFileURL;
@property (nonatomic, copy, nullable) NSURL *localSourceURL;
@property (nonatomic, strong) SPKTrimSourcePlan *plan;
@property (nonatomic, strong) NSMutableArray<NSString *> *tempPaths;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong, nullable) SPKTrimEntry *selfRetain;

// Sequential download queue state.
@property (nonatomic, strong) NSMutableArray<NSURL *> *pendingURLs;
@property (nonatomic, strong) NSMutableArray<NSURL *> *downloadedURLs;
@property (nonatomic, assign) BOOL ownsPrepPill;
@property (nonatomic, copy, nullable) void (^queueCompletion)(NSArray<NSURL *> *_Nullable localURLs);
@end

@implementation SPKTrimEntry

+ (void)beginTrimAndSaveForMediaObject:(id)mediaObject
                              photoURL:(NSURL *)photoURL
                              videoURL:(NSURL *)videoURL
                              metadata:(SPKGallerySaveMetadata *)metadata
                             presenter:(UIViewController *)presenter {
    [self beginTrimAndSaveForMediaObject:mediaObject
                                photoURL:photoURL
                                videoURL:videoURL
                            localFileURL:nil
                          localSourceURL:nil
                                metadata:metadata
                               presenter:presenter];
}

+ (void)beginTrimAndSaveForMediaObject:(id)mediaObject
                              photoURL:(NSURL *)photoURL
                              videoURL:(NSURL *)videoURL
                          localFileURL:(NSURL *)localFileURL
                        localSourceURL:(NSURL *)localSourceURL
                              metadata:(SPKGallerySaveMetadata *)metadata
                             presenter:(UIViewController *)presenter {
    if (!presenter) {
        return;
    }
    SPKTrimEntry *entry = [[self alloc] init];
    entry.presenter = presenter;
    entry.metadata = metadata;
    entry.mediaObject = mediaObject;
    entry.photoURL = photoURL;
    entry.videoURL = videoURL;
    if (localFileURL.isFileURL && [[NSFileManager defaultManager] fileExistsAtPath:localFileURL.path]) {
        entry.localFileURL = localFileURL;
        entry.localSourceURL = localSourceURL;
    }
    entry.tempPaths = [NSMutableArray array];
    entry.selfRetain = entry; // keep alive across the async flow

    NSString *quality = [SPKUtils getStringPref:@"downloads_video_quality"];
    if ([quality isEqualToString:@"always_ask"]) {
        // Reuse the download flow's own quality picker (audio-only rows hidden).
        [SPKMediaQualityManager presentTrimQualityPickerForMediaObject:mediaObject
                                                              photoURL:photoURL
                                                              videoURL:videoURL
                                                                  from:presenter
                                                            completion:^(SPKTrimSourcePlan *plan) {
                                                                if (!plan) {
                                                                    [entry finish];
                                                                    return;
                                                                } // dismissed
                                                                entry.plan = plan;
                                                                [entry startWithPlan];
                                                            }];
        return;
    }

    SPKTrimSourcePlan *plan = [SPKMediaQualityManager trimSourcePlanForMediaObject:mediaObject
                                                                          photoURL:photoURL
                                                                          videoURL:videoURL
                                                                   qualityOverride:nil];
    if (!plan) {
        SPKNotify(@"spk.trim.entry", SPKL(@"MEDIA_TRIM_TRIM_ENTRY_NO_VIDEO_TRIM_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        [entry finish];
        return;
    }
    entry.plan = plan;
    [entry startWithPlan];
}

#pragma mark - Start

- (void)startWithPlan {
    // Scrub on a small muxed preview (has audio — important for cutting to
    // music). For progressive quality the chosen file is the final, so edit and
    // final are the same download.
    NSURL *editURL = self.plan.needsHighQualityFetch ? self.plan.editURL : self.plan.finalVideoURL;
    // A caller-supplied local copy stands in for the scrub preview, but only
    // stands in for the final source when it is that exact file; otherwise the
    // chosen quality is still fetched before rendering.
    if (self.localFileURL &&
        (self.plan.needsHighQualityFetch || [self.plan.finalVideoURL isEqual:self.localSourceURL])) {
        editURL = self.localFileURL;
    }
    if (editURL.isFileURL) {
        [self presentEditorForLocalURL:editURL];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self downloadURLs:@[ editURL ]
                 title:SPKL(@"MEDIA_TRIM_TRIM_ENTRY_PREPARING_VIDEO_TEXT")
                  pill:nil
            completion:^(NSArray<NSURL *> *locals) {
                if (locals.count > 0) {
                    [weakSelf presentEditorForLocalURL:locals[0]];
                }
            }];
}

#pragma mark - Download queue

// When `pill` is non-nil the queue continues that pill (a stage hand-off) and
// does not dismiss it on completion — the next stage finalizes it. Otherwise a
// fresh pill is created and dismissed when the queue finishes.
- (void)downloadURLs:(NSArray<NSURL *> *)urls
               title:(NSString *)title
                pill:(SPKNotificationPillView *)pill
          completion:(void (^)(NSArray<NSURL *> *_Nullable))completion {
    self.pendingURLs = [urls mutableCopy];
    self.downloadedURLs = [NSMutableArray array];
    self.queueCompletion = completion;

    __weak typeof(self) weakSelf = self;
    void (^onCancel)(void) = ^{
        // Confirm first (mirrors the download cancel); the pill's close button
        // calls onCancel without dismissing.
        [SPKTrimSaveCoordinator confirmCancelThen:^{
            __strong typeof(weakSelf) self = weakSelf;
            self.cancelled = YES;
            [self.task cancel];
            [self.prepPill dismiss];
            self.prepPill = nil;
            [self cleanupAndFinish];
        }];
    };
    if (pill) {
        self.prepPill = pill;
        self.ownsPrepPill = NO;
        [pill updateProgressTitle:title subtitle:nil];
        [pill setProgress:0.0f animated:NO];
        pill.onCancel = onCancel;
    } else {
        self.ownsPrepPill = YES;
        self.prepPill = [[SPKNotificationCenter shared] beginUnmanagedProgressWithTitle:title
                                                                               onCancel:onCancel];
    }

    if (!self.session) {
        self.session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                     delegate:self
                                                delegateQueue:nil];
    }
    [self startNextDownload];
}

- (void)startNextDownload {
    if (self.cancelled)
        return;
    if (self.pendingURLs.count == 0) {
        // Only dismiss a pill we own; a handed-off pill continues into the next
        // stage (which finalizes it).
        if (self.ownsPrepPill) {
            [self.prepPill dismiss];
        }
        self.prepPill = nil;
        void (^completion)(NSArray<NSURL *> *) = self.queueCompletion;
        self.queueCompletion = nil;
        if (completion)
            completion([self.downloadedURLs copy]);
        return;
    }
    NSURL *next = self.pendingURLs.firstObject;
    [self.pendingURLs removeObjectAtIndex:0];
    self.task = [self.session downloadTaskWithURL:next];
    [self.task resume];
}

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)downloadTask
                 didWriteData:(int64_t)bytesWritten
            totalBytesWritten:(int64_t)totalBytesWritten
    totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite <= 0)
        return;
    float p = (float)totalBytesWritten / (float)totalBytesExpectedToWrite;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.prepPill setProgress:MAX(0.0f, MIN(1.0f, p)) animated:YES];
    });
}

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)downloadTask
    didFinishDownloadingToURL:(NSURL *)location {
    NSString *dest = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                 [NSString stringWithFormat:@"SPKTrimSrc-%@.mp4", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
    if ([[NSFileManager defaultManager] moveItemAtPath:location.path toPath:dest error:nil]) {
        @synchronized(self) {
            [self.downloadedURLs addObject:[NSURL fileURLWithPath:dest]];
            [self.tempPaths addObject:dest];
        }
    }
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.cancelled)
            return;
        BOOL gotFile = self.downloadedURLs.count > 0 &&
                       [[NSFileManager defaultManager] fileExistsAtPath:self.downloadedURLs.lastObject.path];
        if (error || !gotFile) {
            [self.prepPill showError:error.localizedDescription ?: SPKL(@"MEDIA_TRIM_TRIM_ENTRY_COULD_NOT_DOWNLOAD_VIDEO_TEXT")];
            self.prepPill = nil;
            [self cleanupAndFinish];
            return;
        }
        [self startNextDownload];
    });
}

#pragma mark - Editor

- (void)presentEditorForLocalURL:(NSURL *)localURL {
    UIViewController *presenter = self.presenter;
    if (!presenter) {
        [self cleanupAndFinish];
        return;
    }
    SPKTrimConfiguration *config = [SPKTrimConfiguration configurationWithVideoURL:localURL];
    // A video-only DASH pick has no audio track — don't offer "Audio Only" in the
    // editor even though the progressive preview (editURL) may contain one.
    if (self.plan.sourceIsSilent) {
        config.allowsAudioOnly = NO;
    }
    // Done becomes a menu of destinations (chosen without dismissing first).
    config.doneOptions = @[
        [SPKTrimDoneOption optionWithTitle:SPKL(@"FEED_COMMENT_ACTIONS_SAVE_PHOTOS_TEXT")
                                identifier:@"photos"
                                  iconName:@"download"],
        [SPKTrimDoneOption optionWithTitle:SPKL(@"ALERT_ACTION_SHARE")
                                identifier:@"share"
                                  iconName:@"share"],
        [SPKTrimDoneOption optionWithTitle:SPKL(@"FEED_COMMENT_ACTIONS_COPY_TEXT")
                                identifier:@"clipboard"
                                  iconName:@"copy"],
        [SPKTrimDoneOption optionWithTitle:SPKL(@"FEED_COMMENT_ACTIONS_SAVE_GALLERY_TEXT")
                                identifier:@"gallery"
                                  iconName:@"sparkle_gallery"],
    ];
    __weak typeof(self) weakSelf = self;
    [SPKTrimEditorViewController presentWithConfiguration:config
                                                     from:presenter
                                               completion:^(SPKTrimResult *result) {
                                                   __strong typeof(weakSelf) self = weakSelf;
                                                   if (!self)
                                                       return;
                                                   if (!result) {
                                                       [self cleanupAndFinish]; // cancelled
                                                       return;
                                                   }
                                                   [self renderResult:result toDestination:(result.destinationTag ?: @"gallery")];
                                               }];
}

#pragma mark - Render

// DASH needs its high-res video + audio fetched to local files first — the
// bundled FFmpeg has no TLS, so it can't read the https stream URLs directly.
- (void)renderResult:(SPKTrimResult *)result toDestination:(NSString *)destination {
    if (self.plan.needsHighQualityFetch && !result.renderVideoURL) {
        // The editor scrubbed a progressive preview; render the final cut from
        // the chosen DASH rep(s) instead. Merged picks fetch video + audio;
        // video-only fetches just the silent video. (Bundled FFmpeg has no TLS,
        // so it can't read the https stream URLs directly.)
        NSMutableArray<NSURL *> *sources =
            [NSMutableArray arrayWithObject:self.plan.finalVideoURL];
        if (self.plan.finalAudioURL) {
            [sources addObject:self.plan.finalAudioURL];
        }
        // One continuous pill spans the high-quality download and the render —
        // hand it off rather than stacking a second notification.
        SPKNotificationPillView *pill =
            [[SPKNotificationCenter shared] beginUnmanagedProgressWithTitle:SPKL(@"MEDIA_TRIM_TRIM_ENTRY_DOWNLOADING_TEXT")
                                                                   onCancel:nil];
        __weak typeof(self) weakSelf = self;
        [self downloadURLs:sources
                     title:SPKL(@"MEDIA_TRIM_TRIM_ENTRY_DOWNLOADING_HIGH_QUALITY_TEXT")
                      pill:pill
                completion:^(NSArray<NSURL *> *locals) {
                    __strong typeof(weakSelf) self = weakSelf;
                    if (locals.count < sources.count) {
                        [self cleanupAndFinish];
                        return;
                    }
                    result.renderVideoURL = locals[0];
                    result.renderAudioURL = (locals.count > 1) ? locals[1] : nil;
                    result.width = self.plan.width;
                    result.height = self.plan.height;
                    [self performRenderResult:result toDestination:destination pill:pill];
                }];
        return;
    }
    [self performRenderResult:result toDestination:destination pill:nil];
}

- (void)performRenderResult:(SPKTrimResult *)result toDestination:(NSString *)destination pill:(SPKNotificationPillView *)pill {
    __weak typeof(self) weakSelf = self;
    [SPKTrimSaveCoordinator routeResult:result
                          toDestination:destination
                               metadata:self.metadata
                              presenter:self.presenter
                           existingPill:pill
                             completion:^(BOOL ok) {
                                 [weakSelf cleanupAndFinish];
                             }];
}

#pragma mark - Lifecycle

- (void)cleanupAndFinish {
    for (NSString *path in self.tempPaths) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    [self.tempPaths removeAllObjects];
    [self finish];
}

- (void)finish {
    [self.session finishTasksAndInvalidate];
    self.session = nil;
    self.selfRetain = nil; // allow deallocation
}

@end
