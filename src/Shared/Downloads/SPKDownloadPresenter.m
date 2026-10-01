#import "SPKStrings.h"
#import "SPKDownloadPresenter.h"
#import "SPKDownloadService.h"

#import "../../Utils.h"
#import "../Gallery/SPKGalleryViewController.h"
#import "../UI/SPKNotificationCenter.h"
#import "SPKDownloadJob.h"
#import "SPKDownloadTypes.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static UIViewController *SPKDownloadPresenterHost(SPKDownloadJob *job) {
    return job.request.presenter ?: topMostController();
}

static NSArray<NSURL *> *SPKDownloadSucceededFileURLsForJob(SPKDownloadJob *job) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (SPKDownloadItem *item in job.items) {
        if (item.state != SPKDownloadStateSucceeded)
            continue;
        NSString *path = item.finalPath ?: item.stagedPath;
        if (path.length && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [urls addObject:[NSURL fileURLWithPath:path]];
        }
    }
    return urls;
}

@interface SPKDownloadPresenter ()
@property (nonatomic, strong, nullable) SPKNotificationPillView *activePill;
@property (nonatomic, copy, nullable) NSString *activeJobID;
@property (nonatomic, assign) NSTimeInterval lastProgressUpdate;
@property (nonatomic, assign) BOOL terminalShownForActiveJob;
@property (nonatomic, assign) BOOL pillDismissedByUser;
@end

@implementation SPKDownloadPresenter

- (BOOL)itemIsInFlight:(SPKDownloadItem *)item {
    switch (item.state) {
    case SPKDownloadStatePending:
    case SPKDownloadStateWaitingForPreflight:
    case SPKDownloadStateQueued:
    case SPKDownloadStateRunning:
    case SPKDownloadStateFinalizing:
        return YES;
    default:
        return NO;
    }
}

- (BOOL)jobIsActive:(SPKDownloadJob *)job {
    if (job.state == SPKDownloadStateRunning || job.state == SPKDownloadStateQueued || job.state == SPKDownloadStateFinalizing) {
        return YES;
    }
    for (SPKDownloadItem *item in job.items) {
        if ([self itemIsInFlight:item])
            return YES;
    }
    return NO;
}

- (NSUInteger)completedItemCount:(SPKDownloadJob *)job {
    NSUInteger count = 0;
    for (SPKDownloadItem *item in job.items) {
        if (item.state == SPKDownloadStateSucceeded)
            count++;
    }
    return count;
}

- (NSString *)progressTitleForJob:(SPKDownloadJob *)job {
    if (job.items.count > 1) {
        NSUInteger current = MIN(job.items.count, [self completedItemCount:job] + 1);
        return [NSString stringWithFormat:SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_DOWNLOADS_VALUE_VALUE_FORMAT"), (unsigned long)current, (unsigned long)job.items.count];
    }
    SPKDownloadItem *item = job.items.firstObject;
    if (item.state == SPKDownloadStateFinalizing) {
        return [NSString stringWithFormat:SPKL(@"AUTO_SAVE_AUTO_SAVE_SAVING_VALUE_FORMAT"), SPKDownloadDestinationDisplayName(job.request.destination)];
    }
    // Detail is already localized at the point where the current progress
    // stage is reported. Never use English text matching as a stage signal.
    if (item.detail.length > 0)
        return item.detail;
    switch (item.mediaKind) {
    case SPKDownloadMediaKindVideo:
        return SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_DOWNLOADING_VIDEO_TEXT");
    case SPKDownloadMediaKindAudio:
        return SPKL(@"AUDIO_AUDIO_DOWNLOAD_COORDINATOR_DOWNLOADING_AUDIO_TEXT");
    case SPKDownloadMediaKindImage:
        return SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_DOWNLOADING_IMAGE_TEXT");
    default:
        return SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_DOWNLOADING_TEXT");
    }
}

- (float)displayProgressForJob:(SPKDownloadJob *)job {
    float progress = (float)job.aggregateProgress;
    SPKDownloadItem *item = job.items.firstObject;
    if (item.state == SPKDownloadStateFinalizing) {
        return fmaxf(progress, 0.97f);
    }
    return progress;
}

- (NSArray<SPKDownloadJob *> *)activeJobsSortedByCreationTime {
    NSArray<SPKDownloadJob *> *allJobs = [[SPKDownloadService shared] jobsMatchingFilter:SPKDownloadHistoryFilterAll];
    NSMutableArray<SPKDownloadJob *> *activeJobs = [NSMutableArray array];
    for (SPKDownloadJob *job in allJobs) {
        if ([self jobIsActive:job]) {
            [activeJobs addObject:job];
        }
    }
    [activeJobs sortUsingComparator:^NSComparisonResult(SPKDownloadJob *a, SPKDownloadJob *b) {
        if (a.createdAt == b.createdAt)
            return NSOrderedSame;
        return a.createdAt < b.createdAt ? NSOrderedAscending : NSOrderedDescending;
    }];
    return activeJobs;
}

- (NSString *)progressSubtitleForJob:(SPKDownloadJob *)job activeJobsCount:(NSUInteger)activeCount activeJobIndex:(NSUInteger)activeIndex {
    float progress = [self displayProgressForJob:job];
    NSInteger percent = (NSInteger)lroundf(progress * 100.0f);
    percent = MAX(0, MIN(100, percent));
    NSString *percentString = [NSString stringWithFormat:@"%ld%%", (long)percent];

    // Check style
    NSString *style = [SPKUtils getStringPref:kSPKNotificationProgressSubtitleStyleKey];
    if (style.length == 0)
        style = @"both";
    if ([style isEqualToString:@"off"]) {
        return nil;
    }

    SPKDownloadItem *primary = job.items.firstObject;
    int64_t bytesWritten = primary.bytesWritten;
    int64_t totalBytesExpected = primary.totalBytesExpected;

    BOOL hasByteTotals = (bytesWritten > 0 && totalBytesExpected > 0);
    NSString *bytesString = nil;
    if (hasByteTotals) {
        NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
        formatter.countStyle = NSByteCountFormatterCountStyleFile;
        formatter.allowedUnits = NSByteCountFormatterUseKB | NSByteCountFormatterUseMB | NSByteCountFormatterUseGB;
        formatter.includesUnit = YES;
        formatter.includesCount = YES;
        formatter.zeroPadsFractionDigits = NO;
        bytesString = [NSString stringWithFormat:SPKL(@"DOWNLOADS_PROGRESS_BYTES_OF_TOTAL_FORMAT"),
                                                 [formatter stringFromByteCount:bytesWritten],
                                                 [formatter stringFromByteCount:totalBytesExpected]];
    }

    NSMutableArray *parts = [NSMutableArray array];
    if ([style isEqualToString:@"percent"]) {
        [parts addObject:percentString];
    } else if ([style isEqualToString:@"bytes"]) {
        if (bytesString)
            [parts addObject:bytesString];
        else
            [parts addObject:percentString];
    } else { // @"both" or default
        [parts addObject:percentString];
        if (bytesString)
            [parts addObject:bytesString];
    }

    if (activeCount > 1) {
        [parts addObject:[NSString stringWithFormat:SPKL(@"COMMON_PROGRESS_FORMAT"), (unsigned long)activeIndex, (unsigned long)activeCount]];
    }

    return [parts componentsJoinedByString:@" • "];
}

- (void)handleJobSnapshot:(SPKDownloadJob *)job {
    if (job.request.presentationMode == SPKDownloadPresentationModeQuiet)
        return;

    NSArray<SPKDownloadJob *> *activeJobs = [self activeJobsSortedByCreationTime];

    if (activeJobs.count > 0) {
        SPKDownloadJob *focusedJob = activeJobs.firstObject;

        if (![focusedJob.jobID isEqualToString:self.activeJobID]) {
            self.activeJobID = focusedJob.jobID;
            self.terminalShownForActiveJob = NO;
        }

        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        BOOL throttle = (now - self.lastProgressUpdate < 0.066) && self.activePill;
        if (!throttle)
            self.lastProgressUpdate = now;

        if (!self.activePill && !self.pillDismissedByUser) {
            __weak typeof(self) weakSelf = self;
            NSString *identifier = focusedJob.request.notificationIdentifier ?: kSPKNotificationDownloadLibrary;
            self.activePill = SPKNotifyProgress(identifier, [self progressTitleForJob:focusedJob], ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf && strongSelf.cancelHandlerForActiveJob) {
                    strongSelf.cancelHandlerForActiveJob(strongSelf.activeJobID);
                } else if (weakSelf.cancelAllActiveHandler) {
                    weakSelf.cancelAllActiveHandler();
                }
            });
            self.activePill.onTapWhenProgress = ^{
                if (weakSelf.openHistoryForJobID)
                    weakSelf.openHistoryForJobID(focusedJob.jobID);
            };
            void (^previousDismiss)(void) = [self.activePill.onDidDismiss copy];
            __weak SPKNotificationPillView *weakPill = self.activePill;
            self.activePill.onDidDismiss = ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf) {
                    if (strongSelf.activePill == weakPill) {
                        if (!strongSelf.terminalShownForActiveJob) {
                            strongSelf.pillDismissedByUser = YES;
                        }
                        strongSelf.activePill = nil;
                    }
                }
                if (previousDismiss) {
                    previousDismiss();
                }
            };
            throttle = NO;
        }

        if (self.activePill && !throttle) {
            NSUInteger activeIndex = [activeJobs indexOfObject:focusedJob] + 1;
            NSString *title = [self progressTitleForJob:focusedJob];
            NSString *subtitle = [self progressSubtitleForJob:focusedJob activeJobsCount:activeJobs.count activeJobIndex:activeIndex];

            [self.activePill updateProgressTitle:title subtitle:subtitle];

            float progress = [self displayProgressForJob:focusedJob];
            SPKDownloadItem *primary = focusedJob.items.firstObject;
            if (primary.totalBytesExpected > 0 && primary.bytesWritten > 0) {
                [self.activePill setProgress:progress
                                bytesWritten:primary.bytesWritten
                          totalBytesExpected:primary.totalBytesExpected
                                    animated:YES];
            } else {
                [self.activePill setProgress:progress
                                bytesWritten:0
                          totalBytesExpected:0
                                    animated:YES];
            }
        }
    } else {
        if ([job.jobID isEqualToString:self.activeJobID] && self.activePill && !self.terminalShownForActiveJob) {
            [self showTerminalOnActivePillForJob:job];
            self.terminalShownForActiveJob = YES;
        }
    }
}

- (void)presentBatchShareForJob:(SPKDownloadJob *)job {
    NSArray<NSURL *> *urls = SPKDownloadSucceededFileURLsForJob(job);
    if (urls.count == 0)
        return;
    UIViewController *host = SPKDownloadPresenterHost(job);
    if (!host)
        return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UIView *source = job.request.anchorView ?: host.view;
        activity.popoverPresentationController.sourceView = source;
        activity.popoverPresentationController.sourceRect = source.bounds;
    }
    [host presentViewController:activity animated:YES completion:nil];
}

- (void)copyBatchToClipboardForJob:(SPKDownloadJob *)job {
    NSArray<NSURL *> *urls = SPKDownloadSucceededFileURLsForJob(job);
    if (urls.count == 0)
        return;
    NSMutableArray *items = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSData *data = [NSData dataWithContentsOfURL:url];
        UTType *type = [UTType typeWithFilenameExtension:url.pathExtension];
        if (data && type.identifier)
            [items addObject:@{type.identifier : data}];
    }
    if (items.count > 0)
        UIPasteboard.generalPasteboard.items = items;
}

- (void)showTerminalOnActivePillForJob:(SPKDownloadJob *)job {
    if (!self.activePill)
        return;
    __weak typeof(self) weakSelf = self;
    NSString *title = nil;
    NSString *subtitle = nil;
    void (^openHistory)(void) = ^{
        if (weakSelf.openHistoryForJobID)
            weakSelf.openHistoryForJobID(nil);
    };

    if (job.request.finalizeAsBatchShare && job.state == SPKDownloadStateSucceeded) {
        [self presentBatchShareForJob:job];
    } else if (job.request.finalizeAsBatchClipboard && job.state == SPKDownloadStateSucceeded) {
        [self copyBatchToClipboardForJob:job];
    }

    if (job.state == SPKDownloadStateFailed || job.state == SPKDownloadStatePartial) {
        NSString *message = SPKDownloadErrorDisplayDescription(job.items.firstObject.error) ?: SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_DOWNLOAD_FAILED_TEXT");
        [self.activePill showErrorWithTitle:job.state == SPKDownloadStatePartial ? SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_SOME_DOWNLOADS_FAILED_TEXT") : SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_DOWNLOAD_FAILED_TEXT")
                                   subtitle:message
                                       icon:nil];
        self.activePill.onTapWhenCompleted = openHistory;
        return;
    }
    if (job.state == SPKDownloadStateCancelled) {
        [self.activePill showInfoWithTitle:SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_DOWNLOAD_CANCELLED_TEXT") subtitle:SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_TAP_OPEN_DOWNLOADS_TEXT") icon:nil];
        self.activePill.onTapWhenCompleted = openHistory;
        return;
    }

    // Determine terminal title/subtitle/action based on destination
    switch (job.request.destination) {
    case SPKDownloadDestinationPhotos:
        title = SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_SAVED_PHOTOS_TEXT");
        subtitle = SPKL(@"AUTO_SAVE_AUTO_SAVE_TAP_OPEN_PHOTOS_TEXT");
        self.activePill.onTapWhenCompleted = ^{
            [SPKUtils openPhotosApp];
        };
        break;
    case SPKDownloadDestinationGallery:
        title = SPKL(@"SETTINGS_NOTIFICATION_SAVED_GALLERY_TEXT");
        subtitle = SPKL(@"AUTO_SAVE_AUTO_SAVE_TAP_OPEN_GALLERY_TEXT");
        self.activePill.onTapWhenCompleted = ^{
            [SPKGalleryViewController presentGallery];
        };
        break;
    case SPKDownloadDestinationShare:
        if (job.request.finalizeAsBatchShare) {
            NSUInteger count = [self completedItemCount:job];
            title = count > 1
                        ? [NSString stringWithFormat:SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_SHARED_VALUE_ITEMS_FORMAT"), (unsigned long)count]
                        : SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_SHARED_TEXT");
            subtitle = SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_TAP_OPEN_DOWNLOADS_TEXT");
            self.activePill.onTapWhenCompleted = openHistory;
        } else {
            title = SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_READY_SHARE_TEXT");
            subtitle = nil;
            self.activePill.onTapWhenCompleted = nil;
        }
        break;
    case SPKDownloadDestinationClipboard:
        if (job.request.finalizeAsBatchClipboard) {
            NSUInteger count = [self completedItemCount:job];
            title = count > 1
                        ? [NSString stringWithFormat:SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_COPIED_VALUE_ITEMS_CLIPBOARD_FORMAT"), (unsigned long)count]
                        : SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_COPIED_CLIPBOARD_TEXT");
        } else {
            SPKDownloadItem *first = job.items.firstObject;
            switch (first.mediaKind) {
            case SPKDownloadMediaKindVideo:
                title = SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPIED_VIDEO_CLIPBOARD_TEXT");
                break;
            case SPKDownloadMediaKindAudio:
                title = SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_COPIED_AUDIO_CLIPBOARD_TEXT");
                break;
            case SPKDownloadMediaKindImage:
                title = SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPIED_PHOTO_CLIPBOARD_TEXT");
                break;
            default:
                title = SPKL(@"MESSAGES_DELETED_MESSAGES_USER_DETAIL_COPIED_CLIPBOARD_TEXT");
                break;
            }
        }
        subtitle = nil;
        self.activePill.onTapWhenCompleted = nil;
        break;
    case SPKDownloadDestinationCacheOnly:
    default:
        if (job.items.count > 1) {
            NSUInteger count = [self completedItemCount:job];
            title = [NSString stringWithFormat:SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_VALUE_ITEMS_SAVED_FORMAT"), (unsigned long)count];
            subtitle = SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_TAP_OPEN_DOWNLOADS_TEXT");
            self.activePill.onTapWhenCompleted = openHistory;
        } else {
            title = SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_DOWNLOAD_COMPLETE_TEXT");
            subtitle = SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_TAP_OPEN_DOWNLOADS_TEXT");
            self.activePill.onTapWhenCompleted = openHistory;
        }
        break;
    }

    [self.activePill showSuccessWithTitle:title subtitle:subtitle icon:nil];
}

- (void)dismissProgress {
    SPKNotificationPillView *oldPill = self.activePill;
    self.activePill = nil;
    [oldPill dismiss];
    self.activeJobID = nil;
    self.terminalShownForActiveJob = NO;
    self.pillDismissedByUser = NO;
}

- (void)prepareForNewJobSubmission {
    self.pillDismissedByUser = NO;
    self.terminalShownForActiveJob = NO;
}

- (BOOL)hasActiveJobWithoutPillForJobID:(NSString *)jobID {
    if ([self.activeJobID isEqualToString:jobID] && self.activePill == nil) {
        return YES;
    }
    if (self.activeJobID == nil && self.activePill == nil) {
        return YES;
    }
    return NO;
}

- (void)reshowPillForJob:(SPKDownloadJob *)job {
    self.activeJobID = job.jobID;
    self.pillDismissedByUser = NO;
    [self handleJobSnapshot:job];
}

@end
