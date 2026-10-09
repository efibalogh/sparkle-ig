#import "SPKStrings.h"
#import "SPKDownloadScheduler.h"

#import "../../Utils.h"
#import "../Audio/SPKAudioDownloadCoordinator.h"
#import "../Gallery/SPKGalleryFile.h"
#import "../Gallery/SPKGallerySaveMetadata.h"
#import "../MediaDownload/SPKMediaQualityManager.h"
#import "SPKDownloadDestinationWriter.h"
#import "SPKDownloadDuplicatePolicy.h"
#import "SPKDownloadHelpers.h"
#import "SPKDownloadPresenter.h"
#import "SPKDownloadStore.h"
#import "SPKDownloadBackgroundKeeper.h"
#import "SPKDownloadTransfer.h"

@interface SPKDownloadActiveTransfer : NSObject
@property (nonatomic, copy) NSString *jobID;
@property (nonatomic, copy) NSString *itemID;
@property (nonatomic, strong, nullable) SPKDownloadTransfer *transfer;
@property (nonatomic, copy, nullable) dispatch_block_t cancelHandler;
@end
@implementation SPKDownloadActiveTransfer
@end

@interface SPKDownloadScheduler ()
@property (nonatomic, strong) NSMutableArray<SPKDownloadJob *> *jobs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SPKDownloadActiveTransfer *> *activeTransfers;
@property (nonatomic, strong) SPKDownloadDuplicatePolicy *duplicatePolicy;
@property (nonatomic, strong) SPKDownloadDestinationWriter *destinationWriter;
@property (nonatomic, assign) NSInteger concurrencyLimit;
@end

static SPKGalleryMediaType SPKGalleryMediaTypeForDownloadKind(SPKDownloadMediaKind kind) {
    switch (kind) {
    case SPKDownloadMediaKindVideo:
        return SPKGalleryMediaTypeVideo;
    case SPKDownloadMediaKindAudio:
        return SPKGalleryMediaTypeAudio;
    default:
        return SPKGalleryMediaTypeImage;
    }
}

static BOOL SPKDownloadJobHasInFlightItems(SPKDownloadJob *job) {
    for (SPKDownloadItem *item in job.mutableItems) {
        switch (item.state) {
        case SPKDownloadStatePending:
        case SPKDownloadStateWaitingForPreflight:
        case SPKDownloadStateQueued:
        case SPKDownloadStateRunning:
        case SPKDownloadStateFinalizing:
            return YES;
        default:
            break;
        }
    }
    return NO;
}

// Delete a job's on-disk scratch (its staging directory + any staged source
// input files). Called when a job leaves history: the staged file backs the
// history entry's tap-to-preview, so it must live exactly as long as the entry.
static void SPKDeleteJobScratch(SPKDownloadJob *job) {
    if (!job)
        return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *staging = [SPKDownloadStore stagingDirectoryForJobID:job.jobID];
    if (staging.length)
        [fm removeItemAtPath:staging error:nil];
    for (SPKDownloadItem *item in job.mutableItems) {
        NSString *source = item.request.localSourcePath;
        if (source.length)
            [fm removeItemAtPath:source error:nil];
    }
}

static NSString *SPKPreferredExtensionForDownloadItem(NSString *stagedPath, NSURL *sourceURL, SPKDownloadItem *item) {
    NSString *extension = item.request.preferredFileExtension;
    if (extension.length == 0)
        extension = stagedPath.pathExtension;
    if (extension.length == 0)
        extension = sourceURL.pathExtension;
    if ([extension hasPrefix:@"."])
        extension = [extension substringFromIndex:1];
    extension = extension.lowercaseString;

    // Guard against an audio item inheriting a video/container extension (e.g. an
    // audio track extracted from an .mp4). The on-disk file is audio, so its name
    // must reflect that — otherwise it gets misclassified as video everywhere.
    if (item.mediaKind == SPKDownloadMediaKindAudio) {
        static NSSet<NSString *> *audioExts;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            audioExts = [NSSet setWithArray:@[ @"m4a", @"aac", @"mp3", @"wav", @"caf", @"aiff", @"flac", @"opus", @"ogg" ]];
        });
        if (![audioExts containsObject:extension])
            extension = @"m4a";
    }

    if (extension.length == 0) {
        switch (item.mediaKind) {
        case SPKDownloadMediaKindVideo:
            extension = @"mp4";
            break;
        case SPKDownloadMediaKindAudio:
            extension = @"m4a";
            break;
        default:
            extension = @"jpg";
            break;
        }
    }
    return extension.length > 0 ? extension : nil;
}

static NSString *SPKRenameStagedPath(NSString *stagedPath, SPKDownloadItem *item, SPKDownloadJob *job) {
    if (!stagedPath.length)
        return stagedPath;
    SPKGallerySaveMetadata *metadata = item.request.metadata ?: job.request.metadata;
    NSURL *sourceURL = item.request.remoteURLString.length ? [NSURL URLWithString:item.request.remoteURLString] : [NSURL fileURLWithPath:stagedPath];
    NSString *preferred = nil;
    NSString *expectedStem = item.request.expectedFilenameStem;
    if (expectedStem.length > 0) {
        NSString *extension = SPKPreferredExtensionForDownloadItem(stagedPath, sourceURL, item);
        preferred = extension.length > 0 ? [expectedStem stringByAppendingPathExtension:extension] : expectedStem;
    }
    if (preferred.length == 0) {
        preferred = SPKFileNameForMedia(sourceURL, SPKGalleryMediaTypeForDownloadKind(item.mediaKind), metadata);
    }
    if (!preferred.length)
        return stagedPath;
    NSString *directory = stagedPath.stringByDeletingLastPathComponent;
    NSString *destination = [directory stringByAppendingPathComponent:preferred];
    if ([destination isEqualToString:stagedPath])
        return stagedPath;
    [[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
    NSError *moveError = nil;
    if ([[NSFileManager defaultManager] moveItemAtPath:stagedPath toPath:destination error:&moveError]) {
        return destination;
    }
    return stagedPath;
}

static int64_t SPKFileSizeAtPath(NSString *path) {
    if (!path.length)
        return 0;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    int64_t size = [attrs[NSFileSize] longLongValue];
    return size > 0 ? size : 0;
}

@implementation SPKDownloadScheduler

- (instancetype)init {
    if (!(self = [super init]))
        return nil;
    _store = [SPKDownloadStore new];
    _jobs = [[self.store loadJobsMarkingInterrupted:YES] mutableCopy];
    _activeTransfers = [NSMutableDictionary dictionary];
    _duplicatePolicy = [SPKDownloadDuplicatePolicy new];
    _destinationWriter = [SPKDownloadDestinationWriter new];
    [self refreshConcurrencyLimit];
    [self sweepOrphanedScratch];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(defaultsChanged) name:NSUserDefaultsDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Reclaim staged scratch that no longer belongs to a history entry — interrupted
// downloads, crash leftovers, or backlog from builds that didn't clean up on
// history removal. Loaded jobs are all in history (active items were marked
// interrupted on load), so anything on disk without a matching job is an orphan.
- (void)sweepOrphanedScratch {
    NSMutableSet<NSString *> *jobIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *sourcePaths = [NSMutableSet set];
    for (SPKDownloadJob *job in self.jobs) {
        if (job.jobID)
            [jobIDs addObject:job.jobID];
        for (SPKDownloadItem *item in job.mutableItems) {
            NSString *source = item.request.localSourcePath;
            if (source.length)
                [sourcePaths addObject:source];
        }
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [SPKDownloadStore purgeTransientCacheKeepingJobIDs:jobIDs sourcePaths:sourcePaths];
    });
}

- (void)defaultsChanged {
    [self refreshConcurrencyLimit];
    [self trimHistory];
}

- (NSArray<SPKDownloadJob *> *)allJobs {
    @synchronized(self) {
        return [[NSArray alloc] initWithArray:self.jobs copyItems:YES];
    }
}

- (SPKDownloadJob *)jobWithID:(NSString *)jobID {
    @synchronized(self) {
        for (SPKDownloadJob *job in self.jobs) {
            if ([job.jobID isEqualToString:jobID])
                return [job copy];
        }
    }
    return nil;
}

- (NSInteger)historyLimit {
    NSInteger value = [[NSUserDefaults standardUserDefaults] integerForKey:kSPKDownloadHistoryLimitKey];
    if (value <= 0)
        value = 300;
    return MAX(50, MIN(1000, value));
}

- (void)refreshConcurrencyLimit {
    NSInteger value = [[NSUserDefaults standardUserDefaults] integerForKey:kSPKDownloadMaxConcurrentKey];
    self.concurrencyLimit = MAX(1, MIN(4, value > 0 ? value : 2));
}

- (void)notifyJob:(SPKDownloadJob *)job itemID:(NSString *)itemID {
    SPKDownloadJob *snapshot = [job copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SPKDownloadJobDidChangeNotification
                                                            object:self
                                                          userInfo:@{
                                                              SPKDownloadNotificationJobIDKey : job.jobID ?: @"",
                                                              SPKDownloadNotificationItemIDKey : itemID ?: @"",
                                                              SPKDownloadNotificationSnapshotKey : snapshot,
                                                          }];
        [[NSNotificationCenter defaultCenter] postNotificationName:SPKDownloadServiceDidChangeNotification object:self];
        [self.presenter handleJobSnapshot:snapshot];
        [self updateBackgroundKeepAliveForJob:snapshot];
    });
}

// Every item mutation funnels through notifyJob:, so this is the one place that
// has to tell the keeper whether anything is still running. The notified job
// answers the question on its own whenever it still has work, which is the case
// for every progress tick; only a job that just went quiet costs a full scan.
- (void)updateBackgroundKeepAliveForJob:(SPKDownloadJob *)snapshot {
    if (snapshot && SPKDownloadJobHasInFlightItems(snapshot)) {
        [SPKDownloadBackgroundKeeper.shared setHasActiveWork:YES];
        return;
    }
    [SPKDownloadBackgroundKeeper.shared setHasActiveWork:[self hasInFlightWork]];
}

- (BOOL)hasInFlightWork {
    @synchronized(self) {
        for (SPKDownloadJob *job in self.jobs) {
            if (SPKDownloadJobHasInFlightItems(job))
                return YES;
        }
    }
    return NO;
}

- (void)reportItemProgressForJobID:(NSString *)jobID
                            itemID:(NSString *)itemID
                             block:(void (^)(SPKDownloadItem *))block {
    if (!block)
        return;
    @synchronized(self) {
        for (SPKDownloadJob *job in self.jobs) {
            if (![job.jobID isEqualToString:jobID])
                continue;
            SPKDownloadItem *item = [job itemWithIdentifier:itemID];
            if (!item || SPKDownloadStateIsTerminal(item.state))
                return;
            block(item);
            job.updatedAt = NSDate.date.timeIntervalSince1970;
            [job recomputeDerivedState];
            [self notifyJob:job itemID:itemID];
            return;
        }
    }
}

- (void)persist {
    @synchronized(self) {
        BOOL hasActive = NO;
        for (SPKDownloadJob *job in self.jobs) {
            for (SPKDownloadItem *item in job.items) {
                if (!SPKDownloadStateIsTerminal(item.state)) {
                    hasActive = YES;
                    break;
                }
            }
        }
        if (hasActive) {
            [self.store debouncedPersistJobs:[self allJobs]];
        } else {
            [self.store persistJobs:[self allJobs] immediately:YES];
        }
    }
}

- (void)trimHistory {
    @synchronized(self) {
        NSInteger limit = [self historyLimit];
        NSMutableArray *finished = [NSMutableArray array];
        NSMutableArray *active = [NSMutableArray array];
        for (SPKDownloadJob *job in self.jobs) {
            if (SPKDownloadStateIsTerminal(job.state))
                [finished addObject:job];
            else
                [active addObject:job];
        }
        [finished sortUsingComparator:^NSComparisonResult(SPKDownloadJob *a, SPKDownloadJob *b) {
            return a.updatedAt < b.updatedAt ? NSOrderedDescending : NSOrderedAscending;
        }];
        if (finished.count > limit) {
            NSRange trim = NSMakeRange(limit, finished.count - limit);
            for (SPKDownloadJob *job in [finished subarrayWithRange:trim])
                SPKDeleteJobScratch(job);
            [finished removeObjectsInRange:trim];
        }
        self.jobs = [[active arrayByAddingObjectsFromArray:finished] mutableCopy];
        [self.store persistJobs:[self allJobs] immediately:YES];
    }
}

- (void)submitRequest:(SPKDownloadRequest *)request completion:(void (^)(NSString *, NSError *))completion {
    NSString *jobID = NSUUID.UUID.UUIDString;
    SPKDownloadJob *job = [[SPKDownloadJob alloc] initWithRequest:request jobID:jobID];
    @synchronized(self) {
        [self.jobs insertObject:job atIndex:0];
    }
    [self.store persistJobs:[self allJobs] immediately:YES];
    __weak typeof(self) weakSelf = self;
    [self.duplicatePolicy runPreflightForRequest:request
                                       presenter:request.presenter
                                      completion:^(SPKDownloadPreflightResult result) {
                                          __strong typeof(weakSelf) strongSelf = weakSelf;
                                          if (!strongSelf)
                                              return;
                                          if (result == SPKDownloadPreflightCancelled) {
                                              [strongSelf cancelJobID:jobID];
                                              SPKDownloadJob *cancelled = [strongSelf jobWithID:jobID];
                                              if (cancelled)
                                                  [strongSelf notifyJob:cancelled itemID:nil];
                                              if (completion)
                                                  completion(nil, SPKDownloadError(SPKDownloadErrorCancelled, SPKL(@"DOWNLOADS_SCHEDULER_DOWNLOAD_CANCELLED_ERROR"), nil));
                                              return;
                                          }
                                          if (result == SPKDownloadPreflightSkipSucceeded) {
                                              SPKDownloadDuplicateDestination duplicateDest = SPKDownloadDuplicateDestinationGallery;
                                              BOOL checksDuplicates = [strongSelf.duplicatePolicy duplicateDestinationFor:request.destination outValue:&duplicateDest];
                                              NSUInteger queuedCount = 0;
                                              for (NSUInteger index = 0; index < job.mutableItems.count; index++) {
                                                  SPKDownloadItem *item = job.mutableItems[index];
                                                  SPKDownloadItemRequest *itemRequest = request.items[index];
                                                  BOOL isDuplicate = checksDuplicates && [SPKDownloadDuplicatePolicy hasDuplicateForDestination:duplicateDest
                                                                                                                                       metadata:itemRequest.metadata ?: request.metadata
                                                                                                                                      mediaType:[strongSelf.duplicatePolicy mediaTypeForKind:item.mediaKind]];
                                                  if (isDuplicate) {
                                                      item.state = SPKDownloadStateSucceeded;
                                                      item.progress = 1.0;
                                                      item.detail = SPKL(@"DOWNLOADS_DOWNLOAD_SCHEDULER_SKIPPED_DUPLICATE_TEXT");
                                                  } else {
                                                      [strongSelf transitionItemID:item.itemID jobID:jobID from:SPKDownloadStatePending to:SPKDownloadStateQueued update:nil];
                                                      queuedCount++;
                                                  }
                                              }
                                              [job recomputeDerivedState];
                                              [strongSelf notifyJob:job itemID:nil];
                                              [strongSelf persist];
                                              if (queuedCount > 0) {
                                                  [strongSelf pumpQueue];
                                              }
                                              if (completion)
                                                  completion(jobID, nil);
                                              return;
                                          }
                                          for (SPKDownloadItem *item in job.mutableItems) {
                                              [strongSelf transitionItemID:item.itemID jobID:jobID from:SPKDownloadStatePending to:SPKDownloadStateQueued update:nil];
                                          }
                                          [strongSelf notifyJob:job itemID:nil];
                                          [strongSelf pumpQueue];
                                          if (completion)
                                              completion(jobID, nil);
                                      }];
}

- (BOOL)transitionItemID:(NSString *)itemID
                   jobID:(NSString *)jobID
                    from:(SPKDownloadState)expectedState
                      to:(SPKDownloadState)newState
                  update:(void (^)(SPKDownloadMutableItemSnapshot *))update {
    @synchronized(self) {
        SPKDownloadJob *job = nil;
        for (SPKDownloadJob *candidate in self.jobs) {
            if ([candidate.jobID isEqualToString:jobID]) {
                job = candidate;
                break;
            }
        }
        if (!job)
            return NO;
        SPKDownloadItem *item = [job itemWithIdentifier:itemID];
        if (!item)
            return NO;
        if (SPKDownloadStateIsTerminal(item.state))
            return NO;
        if (item.state != expectedState)
            return NO;
        if (!SPKDownloadStateAllowsTransition(item.state, newState))
            return NO;
        item.state = newState;
        if (update)
            update((SPKDownloadMutableItemSnapshot *)item);
        job.updatedAt = NSDate.date.timeIntervalSince1970;
        [job recomputeDerivedState];
        [self notifyJob:job itemID:itemID];
        if (SPKDownloadStateIsTerminal(newState)) {
            // Cancelled and interrupted items are deliberately not tallied: the
            // finish notification reports work that ran to a conclusion, and a
            // cancellation is already the user's own doing.
            if (newState == SPKDownloadStateSucceeded || newState == SPKDownloadStateFailed) {
                [SPKDownloadBackgroundKeeper.shared noteItemFinishedWithSuccess:(newState == SPKDownloadStateSucceeded)
                                                                    destination:job.request.destination];
            }
            [self.store persistJobs:[self allJobs] immediately:YES];
        } else {
            [self persist];
        }
        return YES;
    }
}

- (NSUInteger)runningTransferCount {
    return self.activeTransfers.count;
}

- (void)pumpQueue {
    @synchronized(self) {
        if ([self runningTransferCount] >= self.concurrencyLimit)
            return;
        NSArray *sortedJobs = [self.jobs sortedArrayUsingComparator:^NSComparisonResult(SPKDownloadJob *a, SPKDownloadJob *b) {
            return a.createdAt < b.createdAt ? NSOrderedAscending : NSOrderedDescending;
        }];
        for (SPKDownloadJob *job in sortedJobs) {
            NSArray *sortedItems = [job.mutableItems sortedArrayUsingComparator:^NSComparisonResult(SPKDownloadItem *a, SPKDownloadItem *b) {
                return a.index > b.index ? NSOrderedDescending : NSOrderedAscending;
            }];
            for (SPKDownloadItem *item in sortedItems) {
                if (item.state != SPKDownloadStateQueued)
                    continue;
                if ([self runningTransferCount] >= self.concurrencyLimit)
                    return;
                [self startItem:item job:job];
                if ([self runningTransferCount] >= self.concurrencyLimit)
                    return;
            }
        }
    }
}

- (void)startItem:(SPKDownloadItem *)item job:(SPKDownloadJob *)job {
    SPKDownloadItemRequest *req = item.request;
    if (req.requiresDashMerge && req.remoteURLString.length > 0) {
        [self startDashMergeItem:item job:job];
        return;
    }
    if (req.requiresAudioConversion && req.remoteURLString.length > 0) {
        [self startAudioConversionItem:item job:job];
        return;
    }
    if (req.localSourcePath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:req.localSourcePath]) {
        [self transitionItemID:item.itemID
                         jobID:job.jobID
                          from:SPKDownloadStateQueued
                            to:SPKDownloadStateRunning
                        update:^(SPKDownloadMutableItemSnapshot *snap) {
                            snap.detail = SPKL(@"DOWNLOADS_DOWNLOAD_SCHEDULER_PREPARING_LOCAL_FILE_TEXT");
                            snap.progress = 0.5;
                        }];
        NSString *renamed = SPKRenameStagedPath(req.localSourcePath, item, job);
        [self finalizeItem:item job:job stagedPath:renamed];
        return;
    }
    NSURL *url = req.remoteURLString.length ? [NSURL URLWithString:req.remoteURLString] : nil;
    [self transitionItemID:item.itemID
                     jobID:job.jobID
                      from:SPKDownloadStateQueued
                        to:SPKDownloadStateRunning
                    update:^(SPKDownloadMutableItemSnapshot *snap) {
                        snap.detail = SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_DOWNLOADING_TEXT");
                        snap.progress = 0.05;
                    }];
    NSString *staging = [SPKDownloadStore stagingDirectoryForJobID:job.jobID];
    SPKDownloadTransfer *transfer = [SPKDownloadTransfer new];
    SPKDownloadActiveTransfer *active = [SPKDownloadActiveTransfer new];
    active.jobID = job.jobID;
    active.itemID = item.itemID;
    active.transfer = transfer;
    self.activeTransfers[item.itemID] = active;
    __weak typeof(self) weakSelf = self;
    [transfer downloadURL:url
        mediaKind:item.mediaKind
        fileExtension:req.preferredFileExtension
        stagingDir:staging
        itemID:item.itemID
        progress:^(int64_t written, int64_t expected, double progress) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf)
                return;
            [strongSelf reportItemProgressForJobID:job.jobID
                                            itemID:item.itemID
                                             block:^(SPKDownloadItem *snap) {
                                                 snap.bytesWritten = written;
                                                 snap.totalBytesExpected = expected;
                                                 snap.progress = progress;
                                                 snap.detail = SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_DOWNLOADING_TEXT");
                                             }];
        }
        completion:^(NSString *stagedPath, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf)
                return;
            [strongSelf.activeTransfers removeObjectForKey:item.itemID];
            if ([error.domain isEqualToString:SPKDownloadErrorDomain] && error.code == SPKDownloadErrorServerUnavailable &&
                req.dashFallbackURLString.length > 0) {
                SPKLog(@"Downloads", @"ready-to-play file unavailable, falling back to DASH %ldx%ld", (long)req.dashWidth, (long)req.dashHeight);
                req.remoteURLString = req.dashFallbackURLString;
                req.dashFallbackURLString = nil;
                req.requiresDashMerge = YES;
                req.preferredFileExtension = @"mp4";
                [strongSelf startDashMergeItem:item job:job fromState:SPKDownloadStateRunning];
                return;
            }
            if (!stagedPath || error) {
                [strongSelf transitionItemID:item.itemID
                                       jobID:job.jobID
                                        from:SPKDownloadStateRunning
                                          to:SPKDownloadStateFailed
                                      update:^(SPKDownloadMutableItemSnapshot *snap) {
                                          snap.error = error ?: SPKDownloadError(SPKDownloadErrorHTTPFailure, SPKL(@"DOWNLOADS_DOWNLOAD_SCHEDULER_DOWNLOAD_FAILED_TEXT"), nil);
                                          snap.progress = 1.0;
                                      }];
                [strongSelf pumpQueue];
                return;
            }
            NSString *renamed = SPKRenameStagedPath(stagedPath, item, job);
            [strongSelf finalizeItem:item job:job stagedPath:renamed];
        }];
}

- (void)startDashMergeItem:(SPKDownloadItem *)item job:(SPKDownloadJob *)job {
    [self startDashMergeItem:item job:job fromState:SPKDownloadStateQueued];
}

- (void)startDashMergeItem:(SPKDownloadItem *)item job:(SPKDownloadJob *)job fromState:(SPKDownloadState)fromState {
    SPKDownloadItemRequest *req = item.request;
    NSURL *primary = [NSURL URLWithString:req.remoteURLString];
    NSURL *secondary = req.dashSecondaryURLString.length ? [NSURL URLWithString:req.dashSecondaryURLString] : nil;
    if (!primary) {
        [self transitionItemID:item.itemID
                         jobID:job.jobID
                          from:fromState
                            to:SPKDownloadStateFailed
                        update:^(SPKDownloadMutableItemSnapshot *snap) {
                            snap.error = SPKDownloadError(SPKDownloadErrorInvalidURL, SPKL(@"DOWNLOADS_DOWNLOAD_SCHEDULER_INVALID_MEDIA_URL_TEXT"), nil);
                            snap.progress = 1.0;
                        }];
        [self pumpQueue];
        return;
    }
    [self transitionItemID:item.itemID
                     jobID:job.jobID
                      from:fromState
                        to:SPKDownloadStateRunning
                    update:^(SPKDownloadMutableItemSnapshot *snap) {
                        snap.progress = 0.05;
                        snap.detail = SPKL(@"DOWNLOADS_DOWNLOAD_SCHEDULER_PREPARING_MEDIA_TEXT");
                        snap.bytesWritten = 0;
                        snap.totalBytesExpected = 0;
                    }];
    NSString *basename = req.expectedFilenameStem.length > 0 ? req.expectedFilenameStem : NSUUID.UUID.UUIDString;
    SPKDownloadActiveTransfer *active = [SPKDownloadActiveTransfer new];
    active.jobID = job.jobID;
    active.itemID = item.itemID;
    self.activeTransfers[item.itemID] = active;

    __weak typeof(self) weakSelf = self;
    NSString *jobID = job.jobID;
    NSString *itemID = item.itemID;
    [SPKMediaQualityManager runDashDownloadWithPrimaryURL:primary
        secondaryURL:secondary
        optionKind:req.dashOptionKind
        basename:basename
        duration:req.dashDuration
        width:req.dashWidth
        height:req.dashHeight
        sourceBitrate:req.dashBandwidth
        extension:req.preferredFileExtension ?: @"mp4"
        progress:^(float progress, NSString *stageTitle, int64_t bytesWritten, int64_t totalBytesExpected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf reportItemProgressForJobID:jobID
                                              itemID:itemID
                                               block:^(SPKDownloadItem *snap) {
                                                   snap.progress = progress;
                                                   snap.detail = stageTitle;
                                                   // Merge/transcode stages report (0, 0) — keep the
                                                   // last known download byte counts so history and
                                                   // the progress pill don't lose the size. The final
                                                   // merged file size is stamped in finalizeItem.
                                                   // Written and expected move together, so an
                                                   // unknown-length track never pairs its bytes with
                                                   // the previous track's total.
                                                   if (bytesWritten > 0) {
                                                       snap.bytesWritten = bytesWritten;
                                                       snap.totalBytesExpected = MAX(totalBytesExpected, 0);
                                                   }
                                               }];
            });
        }
        failure:^(NSString *title, NSString *message) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.activeTransfers removeObjectForKey:itemID];
                [weakSelf transitionItemID:itemID
                                     jobID:jobID
                                      from:SPKDownloadStateRunning
                                        to:SPKDownloadStateFailed
                                    update:^(SPKDownloadMutableItemSnapshot *snap) {
                                        snap.error = SPKDownloadError(SPKDownloadErrorHTTPFailure, message ?: title, nil);
                                        snap.progress = 1.0;
                                        snap.detail = title;
                                    }];
                [weakSelf pumpQueue];
            });
        }
        success:^(NSURL *outputURL) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.activeTransfers removeObjectForKey:itemID];
                SPKDownloadJob *liveJob = nil;
                SPKDownloadItem *liveItem = nil;
                @synchronized(weakSelf) {
                    for (SPKDownloadJob *j in weakSelf.jobs) {
                        if ([j.jobID isEqualToString:jobID]) {
                            liveJob = j;
                            liveItem = [j itemWithIdentifier:itemID];
                            break;
                        }
                    }
                }
                if (liveJob && liveItem) {
                    if (SPKDownloadStateIsTerminal(liveItem.state)) {
                        [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
                        [weakSelf pumpQueue];
                        return;
                    }
                    NSString *renamed = SPKRenameStagedPath(outputURL.path, liveItem, liveJob);
                    [weakSelf finalizeItem:liveItem job:liveJob stagedPath:renamed];
                } else
                    [weakSelf pumpQueue];
            });
        }
        cancelOut:^(dispatch_block_t cancelBlock) {
            active.cancelHandler = cancelBlock;
        }];
}

- (void)startAudioConversionItem:(SPKDownloadItem *)item job:(SPKDownloadJob *)job {
    SPKDownloadItemRequest *req = item.request;
    NSURL *url = [NSURL URLWithString:req.remoteURLString];
    if (!url) {
        [self transitionItemID:item.itemID
                         jobID:job.jobID
                          from:SPKDownloadStateQueued
                            to:SPKDownloadStateFailed
                        update:^(SPKDownloadMutableItemSnapshot *snap) {
                            snap.error = SPKDownloadError(SPKDownloadErrorInvalidURL, SPKL(@"DOWNLOADS_DOWNLOAD_SCHEDULER_INVALID_AUDIO_URL_TEXT"), nil);
                            snap.progress = 1.0;
                        }];
        [self pumpQueue];
        return;
    }
    [self transitionItemID:item.itemID
                     jobID:job.jobID
                      from:SPKDownloadStateQueued
                        to:SPKDownloadStateRunning
                    update:^(SPKDownloadMutableItemSnapshot *snap) {
                        snap.progress = 0.05;
                        snap.detail = SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_DOWNLOADING_AUDIO_TEXT");
                    }];
    NSString *basename = req.audioProcessingBasename.length > 0 ? req.audioProcessingBasename : NSUUID.UUID.UUIDString;
    NSString *staging = [SPKDownloadStore stagingDirectoryForJobID:job.jobID];
    [[NSFileManager defaultManager] createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:nil];

    SPKDownloadActiveTransfer *active = [SPKDownloadActiveTransfer new];
    active.jobID = job.jobID;
    active.itemID = item.itemID;
    __block NSURLSessionDownloadTask *task = nil;
    __block NSURLSession *session = nil;
    active.cancelHandler = ^{
        [task cancel];
        [session invalidateAndCancel];
    };
    self.activeTransfers[item.itemID] = active;

    __weak typeof(self) weakSelf = self;
    NSString *jobID = job.jobID;
    NSString *itemID = item.itemID;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    session = [NSURLSession sessionWithConfiguration:config];
    task = [session downloadTaskWithURL:url
                      completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                          (void)response;
                          __block NSURL *rawURL = nil;
                          if (location && !error) {
                              NSString *ext = url.pathExtension.length > 0 ? url.pathExtension : @"m4a";
                              rawURL = [NSURL fileURLWithPath:[staging stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-raw.%@", itemID, ext]]];
                              [[NSFileManager defaultManager] removeItemAtURL:rawURL error:nil];
                              if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:rawURL error:nil]) {
                                  rawURL = nil;
                              }
                          }
                          dispatch_async(dispatch_get_main_queue(), ^{
                              __strong typeof(weakSelf) strongSelf = weakSelf;
                              if (!strongSelf)
                                  return;
                              if (error || !rawURL) {
                                  [strongSelf.activeTransfers removeObjectForKey:itemID];
                                  [strongSelf transitionItemID:itemID
                                                         jobID:jobID
                                                          from:SPKDownloadStateRunning
                                                            to:SPKDownloadStateFailed
                                                        update:^(SPKDownloadMutableItemSnapshot *snap) {
                                                            snap.error = error ?: SPKDownloadError(SPKDownloadErrorHTTPFailure, SPKL(@"DOWNLOADS_DOWNLOAD_SCHEDULER_AUDIO_DOWNLOAD_FAILED_TEXT"), nil);
                                                            snap.progress = 1.0;
                                                        }];
                                  [strongSelf pumpQueue];
                                  return;
                              }
                              [strongSelf reportItemProgressForJobID:jobID
                                                              itemID:itemID
                                                               block:^(SPKDownloadItem *snap) {
                                                                   snap.progress = 0.72;
                                                                   snap.detail = SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_CONVERTING_AUDIO_TEXT");
                                                                   // Keep the downloaded raw size visible during
                                                                   // conversion; the converted size is stamped in
                                                                   // finalizeItem.
                                                                   int64_t rawSize = SPKFileSizeAtPath(rawURL.path);
                                                                   if (rawSize > 0) {
                                                                       snap.bytesWritten = rawSize;
                                                                       snap.totalBytesExpected = rawSize;
                                                                   }
                                                               }];
                              [SPKAudioDownloadCoordinator convertAudioAtURL:rawURL
                                  basename:basename
                                  progress:^(float convertProgress, NSString *title) {
                                      [strongSelf reportItemProgressForJobID:jobID
                                                                      itemID:itemID
                                                                       block:^(SPKDownloadItem *snap) {
                                                                           snap.progress = 0.72 + (convertProgress * 0.23);
                                                                           snap.detail = title.length > 0 ? title : SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_CONVERTING_AUDIO_TEXT");
                                                                       }];
                                  }
                                  completion:^(NSURL *outputURL, NSError *convertError) {
                                      dispatch_async(dispatch_get_main_queue(), ^{
                                          [strongSelf.activeTransfers removeObjectForKey:itemID];
                                          if (!outputURL || convertError) {
                                              [strongSelf transitionItemID:itemID
                                                                     jobID:jobID
                                                                      from:SPKDownloadStateRunning
                                                                        to:SPKDownloadStateFailed
                                                                    update:^(SPKDownloadMutableItemSnapshot *snap) {
                                                                        snap.error = convertError ?: SPKDownloadError(SPKDownloadErrorHTTPFailure, SPKL(@"DOWNLOADS_DOWNLOAD_SCHEDULER_AUDIO_CONVERSION_FAILED_TEXT"), nil);
                                                                        snap.progress = 1.0;
                                                                    }];
                                              [strongSelf pumpQueue];
                                              return;
                                          }
                                          NSString *dest = [staging stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", itemID]];
                                          [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
                                          NSError *moveError = nil;
                                          if (![[NSFileManager defaultManager] moveItemAtURL:outputURL toURL:[NSURL fileURLWithPath:dest] error:&moveError]) {
                                              dest = outputURL.path;
                                          }
                                          SPKDownloadJob *liveJob = nil;
                                          SPKDownloadItem *liveItem = nil;
                                          @synchronized(strongSelf) {
                                              for (SPKDownloadJob *j in strongSelf.jobs) {
                                                  if ([j.jobID isEqualToString:jobID]) {
                                                      liveJob = j;
                                                      liveItem = [j itemWithIdentifier:itemID];
                                                      break;
                                                  }
                                              }
                                          }
                                          if (liveJob && liveItem) {
                                              if (SPKDownloadStateIsTerminal(liveItem.state)) {
                                                  [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
                                                  [strongSelf pumpQueue];
                                                  return;
                                              }
                                              NSString *renamed = SPKRenameStagedPath(dest, liveItem, liveJob);
                                              [strongSelf finalizeItem:liveItem job:liveJob stagedPath:renamed];
                                          } else
                                              [strongSelf pumpQueue];
                                      });
                                  }];
                          });
                      }];
    [task resume];
}

- (void)finalizeItem:(SPKDownloadItem *)item job:(SPKDownloadJob *)job stagedPath:(NSString *)stagedPath {
    // Stamp the on-disk size: merged/transcoded outputs and local-source files
    // never reported meaningful byte counts, so without this history shows no
    // size for them. For plain downloads this matches the transferred bytes.
    int64_t stagedSize = SPKFileSizeAtPath(stagedPath);
    [self transitionItemID:item.itemID
                     jobID:job.jobID
                      from:item.state
                        to:SPKDownloadStateFinalizing
                    update:^(SPKDownloadMutableItemSnapshot *snap) {
                        snap.stagedPath = stagedPath;
                        snap.progress = 0.97;
                        snap.detail = [NSString stringWithFormat:SPKL(@"AUTO_SAVE_AUTO_SAVE_SAVING_VALUE_FORMAT"), SPKDownloadDestinationDisplayName(job.request.destination)];
                        if (stagedSize > 0) {
                            snap.bytesWritten = stagedSize;
                            snap.totalBytesExpected = stagedSize;
                        }
                    }];
    __weak typeof(self) weakSelf = self;
    [self.destinationWriter finalizeFileAtPath:stagedPath
                                       request:job.request
                                   itemRequest:item.request
                                     presenter:job.request.presenter
                                    anchorView:job.request.anchorView
                                    completion:^(NSString *finalPath, NSString *photosAssetID, NSError *error) {
                                        dispatch_async(dispatch_get_main_queue(), ^{
                                            __strong typeof(weakSelf) strongSelf = weakSelf;
                                            if (!strongSelf)
                                                return;
                                            if (error) {
                                                [strongSelf transitionItemID:item.itemID
                                                                       jobID:job.jobID
                                                                        from:SPKDownloadStateFinalizing
                                                                          to:SPKDownloadStateFailed
                                                                      update:^(SPKDownloadMutableItemSnapshot *snap) {
                                                                          snap.error = error;
                                                                          snap.progress = 1.0;
                                                                      }];
                                            } else {
                                                // Re-stamp from the final path in case the
                                                // destination writer produced a different file
                                                // (e.g. Gallery copy). Falls back to the staged
                                                // size stamped on finalize entry.
                                                int64_t finalSize = SPKFileSizeAtPath(finalPath);
                                                if (finalSize <= 0)
                                                    finalSize = stagedSize;
                                                [strongSelf transitionItemID:item.itemID
                                                                       jobID:job.jobID
                                                                        from:SPKDownloadStateFinalizing
                                                                          to:SPKDownloadStateSucceeded
                                                                      update:^(SPKDownloadMutableItemSnapshot *snap) {
                                                                          snap.finalPath = finalPath;
                                                                          snap.photosAssetIdentifier = photosAssetID;
                                                                          snap.progress = 1.0;
                                                                          snap.detail = SPKL(@"DOWNLOADS_DOWNLOAD_SCHEDULER_COMPLETED_TEXT");
                                                                          if (finalSize > 0) {
                                                                              snap.bytesWritten = finalSize;
                                                                              snap.totalBytesExpected = finalSize;
                                                                          }
                                                                      }];
                                            }
                                            [strongSelf pumpQueue];
                                            [strongSelf trimHistory];
                                        });
                                    }];
}

- (nullable NSString *)recordCompletedFileAtURL:(nullable NSURL *)fileURL
                                      mediaKind:(SPKDownloadMediaKind)kind
                                    destination:(SPKDownloadDestination)destination
                                       metadata:(nullable SPKGallerySaveMetadata *)metadata
                                  sourceSurface:(SPKDownloadSourceSurface)surface
                                      finalPath:(nullable NSString *)finalPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL sourceExists = fileURL.isFileURL && [fm fileExistsAtPath:fileURL.path];
    BOOL finalExists = finalPath.length > 0 && [fm fileExistsAtPath:finalPath];
    if (!sourceExists && !finalExists)
        return nil;

    NSString *jobID = NSUUID.UUID.UUIDString;
    NSString *staging = [SPKDownloadStore stagingDirectoryForJobID:jobID];
    [fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:nil];

    // Staged copy backs tap-to-preview, mirroring pipeline downloads. Never
    // point the item's localSourcePath at the gallery/final file:
    // SPKDeleteJobScratch deletes it when the entry leaves history.
    NSString *stagedPath = nil;
    if (sourceExists) {
        NSString *ext = fileURL.pathExtension.length > 0 ? fileURL.pathExtension.lowercaseString : nil;
        if (ext.length == 0) {
            switch (kind) {
            case SPKDownloadMediaKindVideo:
                ext = @"mp4";
                break;
            case SPKDownloadMediaKindAudio:
                ext = @"m4a";
                break;
            default:
                ext = @"jpg";
                break;
            }
        }
        stagedPath = [staging stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:ext]];
        if (![fm copyItemAtPath:fileURL.path toPath:stagedPath error:nil])
            stagedPath = nil;
    }
    int64_t fileSize = SPKFileSizeAtPath(stagedPath);
    if (fileSize <= 0)
        fileSize = SPKFileSizeAtPath(finalPath);
    if (fileSize <= 0)
        fileSize = SPKFileSizeAtPath(fileURL.path);

    SPKDownloadItemRequest *itemRequest = [SPKDownloadItemRequest itemWithLocalPath:stagedPath ?: @"" mediaKind:kind];
    if (stagedPath.length == 0)
        itemRequest.localSourcePath = nil;
    NSString *preferredExt = stagedPath.pathExtension.length > 0 ? stagedPath.pathExtension.lowercaseString
                             : fileURL.pathExtension.length > 0 ? fileURL.pathExtension.lowercaseString
                                                                : finalPath.pathExtension.lowercaseString;
    if (preferredExt.length > 0)
        itemRequest.preferredFileExtension = preferredExt;
    itemRequest.metadata = metadata;
    SPKDownloadRequest *request = [SPKDownloadRequest requestWithItems:@[ itemRequest ] destination:destination];
    request.metadata = metadata;
    request.sourceSurface = surface;
    request.presentationMode = SPKDownloadPresentationModeQuiet;
    request.duplicatePolicy = SPKDownloadDuplicatePolicyAlwaysDownload; // post-hoc record; never preflighted

    SPKDownloadJob *job = [[SPKDownloadJob alloc] initWithRequest:request jobID:jobID];
    @synchronized(self) {
        for (SPKDownloadItem *item in job.mutableItems) {
            item.state = SPKDownloadStateSucceeded;
            item.progress = 1.0;
            item.bytesWritten = fileSize;
            item.totalBytesExpected = fileSize;
            item.stagedPath = stagedPath;
            item.finalPath = finalPath;
            item.detail = SPKL(@"DOWNLOADS_DOWNLOAD_SCHEDULER_COMPLETED_TEXT");
        }
        job.updatedAt = NSDate.date.timeIntervalSince1970;
        [job recomputeDerivedState];
        [self.jobs insertObject:job atIndex:0];
    }
    [self trimHistory]; // also persists
    SPKDownloadJob *snapshot = [self jobWithID:jobID];
    if (snapshot)
        [self notifyJob:snapshot itemID:nil];
    return jobID;
}

- (void)cancelJobID:(NSString *)jobID {
    @synchronized(self) {
        for (SPKDownloadJob *job in self.jobs) {
            if (![job.jobID isEqualToString:jobID])
                continue;
            for (SPKDownloadItem *item in job.mutableItems) {
                [self cancelItemInternal:item job:job];
            }
            [job recomputeDerivedState];
        }
    }
    [self pumpQueue];
    SPKDownloadJob *snapshot = [self jobWithID:jobID];
    if (snapshot)
        [self notifyJob:snapshot itemID:nil];
}

- (void)cancelItemID:(NSString *)itemID inJobID:(NSString *)jobID {
    @synchronized(self) {
        for (SPKDownloadJob *job in self.jobs) {
            if (![job.jobID isEqualToString:jobID])
                continue;
            SPKDownloadItem *item = [job itemWithIdentifier:itemID];
            if (item)
                [self cancelItemInternal:item job:job];
        }
    }
    [self pumpQueue];
}

- (void)cancelItemInternal:(SPKDownloadItem *)item job:(SPKDownloadJob *)job {
    if (SPKDownloadStateIsTerminal(item.state))
        return;
    SPKDownloadActiveTransfer *active = self.activeTransfers[item.itemID];
    if (active) {
        [active.transfer cancel];
        if (active.cancelHandler)
            active.cancelHandler();
        [self.activeTransfers removeObjectForKey:item.itemID];
    }
    SPKDownloadState from = item.state;
    if (![self transitionItemID:item.itemID
                          jobID:job.jobID
                           from:from
                             to:SPKDownloadStateCancelled
                         update:^(SPKDownloadMutableItemSnapshot *snap) {
                             snap.error = SPKDownloadError(SPKDownloadErrorCancelled, SPKL(@"DOWNLOADS_SCHEDULER_DOWNLOAD_CANCELLED_ERROR"), nil);
                             snap.progress = 1.0;
                             snap.detail = SPKL(@"DOWNLOADS_SCHEDULER_CANCELLED_LABEL");
                         }]) {
        item.state = SPKDownloadStateCancelled;
        item.error = SPKDownloadError(SPKDownloadErrorCancelled, SPKL(@"DOWNLOADS_SCHEDULER_DOWNLOAD_CANCELLED_ERROR"), nil);
        item.progress = 1.0;
        item.detail = @"Cancelled";
        [job recomputeDerivedState];
        [self notifyJob:job itemID:item.itemID];
        [self persist];
    }
}

- (void)retryJobID:(NSString *)jobID {
    @synchronized(self) {
        for (SPKDownloadJob *job in self.jobs) {
            if (![job.jobID isEqualToString:jobID])
                continue;
            for (SPKDownloadItem *item in job.mutableItems) {
                if (item.state == SPKDownloadStateFailed || item.state == SPKDownloadStateCancelled || item.state == SPKDownloadStateInterrupted) {
                    item.state = SPKDownloadStateQueued;
                    item.progress = 0;
                    item.error = nil;
                    item.stagedPath = nil;
                }
            }
            [job recomputeDerivedState];
            [self notifyJob:job itemID:nil];
        }
    }
    [self pumpQueue];
}

- (void)retryItemID:(NSString *)itemID inJobID:(NSString *)jobID {
    @synchronized(self) {
        for (SPKDownloadJob *job in self.jobs) {
            if (![job.jobID isEqualToString:jobID])
                continue;
            SPKDownloadItem *item = [job itemWithIdentifier:itemID];
            if (!item)
                continue;
            item.state = SPKDownloadStateQueued;
            item.progress = 0;
            item.error = nil;
            item.stagedPath = nil;
            [job recomputeDerivedState];
            [self notifyJob:job itemID:itemID];
        }
    }
    [self pumpQueue];
}

- (void)clearFinishedHistory {
    [self clearFinishedHistoryForAccountPK:nil];
}

- (void)clearFinishedHistoryForAccountPK:(NSString *)accountPK {
    @synchronized(self) {
        NSMutableArray *remaining = [NSMutableArray array];
        for (SPKDownloadJob *job in self.jobs) {
            BOOL belongsToScope = accountPK.length == 0 ||
                                  job.ownerAccountPK.length == 0 ||
                                  [job.ownerAccountPK isEqualToString:accountPK];
            if (SPKDownloadJobHasInFlightItems(job) || !belongsToScope) {
                [remaining addObject:job];
            } else {
                SPKDeleteJobScratch(job);
            }
        }
        self.jobs = remaining;
    }
    [self.store persistJobs:[self allJobs] immediately:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:SPKDownloadServiceDidChangeNotification object:self];
}

- (void)removeJobID:(NSString *)jobID {
    @synchronized(self) {
        NSIndexSet *indexes = [self.jobs indexesOfObjectsPassingTest:^BOOL(SPKDownloadJob *obj, NSUInteger idx, BOOL *stop) {
            (void)idx;
            return [obj.jobID isEqualToString:jobID];
        }];
        if (indexes.count) {
            for (SPKDownloadJob *job in [self.jobs objectsAtIndexes:indexes])
                SPKDeleteJobScratch(job);
            [self.jobs removeObjectsAtIndexes:indexes];
        }
    }
    [self.store persistJobs:[self allJobs] immediately:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:SPKDownloadServiceDidChangeNotification object:self];
}

@end
