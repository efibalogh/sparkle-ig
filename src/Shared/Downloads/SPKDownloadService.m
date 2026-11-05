#import "SPKStrings.h"
#import "SPKDownloadService.h"

#import "../../Utils.h"
#import "../Account/SPKAccountManager.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKMediaChrome.h"
#import "../UI/SPKNotificationCenter.h"
#import "SPKDownloadPresenter.h"
#import "SPKDownloadScheduler.h"
#import "SPKDownloadsHistoryViewController.h"

@interface SPKDownloadService ()
@property (nonatomic, strong) SPKDownloadScheduler *scheduler;
@property (nonatomic, strong) SPKDownloadPresenter *presenter;
@end

@implementation SPKDownloadService

+ (instancetype)shared {
    static SPKDownloadService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [SPKDownloadService new];
    });
    return service;
}

- (instancetype)init {
    if (!(self = [super init]))
        return nil;
    _scheduler = [SPKDownloadScheduler new];
    _presenter = [SPKDownloadPresenter new];
    _scheduler.presenter = _presenter;
    _presenter.cancelAllActiveHandler = ^{
        [SPKDownloadService confirmCancelAllActive];
    };
    __weak typeof(self) weakSelf = self;
    _presenter.cancelHandlerForActiveJob = ^(NSString *jobID) {
        [weakSelf confirmCancelForJobID:jobID];
    };
    _presenter.openHistoryForJobID = ^(NSString *jobID) {
        (void)jobID;
        [SPKDownloadService presentDownloadsHistorySheet];
    };
    return self;
}

+ (void)presentDownloadsHistorySheet {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = topMostController();
        if ([presenter isKindOfClass:UINavigationController.class] &&
            [((UINavigationController *)presenter).topViewController isKindOfClass:SPKDownloadsHistoryViewController.class]) {
            return;
        }
        SPKDownloadsHistoryViewController *vc = [SPKDownloadsHistoryViewController new];
        UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.prefersGrabberVisible = YES;
        sheet.detents = @[
            UISheetPresentationControllerDetent.mediumDetent,
            UISheetPresentationControllerDetent.largeDetent
        ];
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
        [presenter presentViewController:nav animated:YES completion:nil];
    });
}

+ (void)confirmCancelAllActive {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = topMostController();
        if (!presenter)
            return;
        [SPKIGAlertPresenter presentAlertFromViewController:presenter
                                                      title:SPKL(@"DOWNLOADS_DOWNLOAD_SERVICE_CANCEL_PENDING_DOWNLOADS_TEXT")
                                                    message:SPKL(@"DOWNLOADS_DOWNLOAD_SERVICE_STOPS_QUEUED_WORK_ANY_ACTIVE_DOWNLOADS_CAN_STILL_CANCELLED_TEXT")
                                                    actions:@[
                                                        [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_KEEP")
                                                                                    style:SPKIGAlertActionStyleCancel
                                                                                  handler:nil],
                                                        [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL_ALL")
                                                                                    style:SPKIGAlertActionStyleDestructive
                                                                                  handler:^{
                                                                                      [[SPKDownloadService shared] cancelAllActive];
                                                                                  }],
                                                    ]];
    });
}

- (void)cancelAllActive {
    for (SPKDownloadJob *job in [self.scheduler allJobs]) {
        if (job.state == SPKDownloadStateRunning || job.state == SPKDownloadStateQueued || job.state == SPKDownloadStatePending) {
            [self.scheduler cancelJobID:job.jobID];
        }
    }
}

- (void)submitRequest:(SPKDownloadRequest *)request completion:(SPKDownloadSubmissionCompletion)completion {
    if (request.presentationMode != SPKDownloadPresentationModeQuiet) {
        request.notificationIdentifier = request.notificationIdentifier ?: kSPKNotificationDownloadLibrary;
        [self.presenter prepareForNewJobSubmission];
    }
    [self.scheduler submitRequest:request completion:completion];
}

- (nullable NSString *)recordCompletedFileAtURL:(nullable NSURL *)fileURL
                                      mediaKind:(SPKDownloadMediaKind)kind
                                    destination:(SPKDownloadDestination)destination
                                       metadata:(nullable SPKGallerySaveMetadata *)metadata
                                  sourceSurface:(SPKDownloadSourceSurface)surface
                                      finalPath:(nullable NSString *)finalPath {
    return [self.scheduler recordCompletedFileAtURL:fileURL
                                          mediaKind:kind
                                        destination:destination
                                           metadata:metadata
                                      sourceSurface:surface
                                          finalPath:finalPath];
}

- (NSArray<SPKDownloadJob *> *)jobsMatchingFilter:(SPKDownloadHistoryFilter)filter {
    NSArray<SPKDownloadJob *> *jobs = [self.scheduler allJobs];
    NSArray *filtered = [jobs filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPKDownloadJob *job, NSDictionary *bindings) {
                                  (void)bindings;
                                  switch (filter) {
                                  case SPKDownloadHistoryFilterActive:
                                      return job.state == SPKDownloadStateRunning || job.state == SPKDownloadStateFinalizing;
                                  case SPKDownloadHistoryFilterQueued:
                                      return job.state == SPKDownloadStateQueued || job.state == SPKDownloadStatePending;
                                  case SPKDownloadHistoryFilterFailed:
                                      return job.state == SPKDownloadStateFailed || job.state == SPKDownloadStatePartial || job.state == SPKDownloadStateInterrupted;
                                  case SPKDownloadHistoryFilterRecent:
                                      return job.state == SPKDownloadStateSucceeded || job.state == SPKDownloadStateCancelled;
                                  default:
                                      return YES;
                                  }
                              }]];
    return [filtered sortedArrayUsingComparator:^NSComparisonResult(SPKDownloadJob *a, SPKDownloadJob *b) {
        if (a.updatedAt == b.updatedAt)
            return NSOrderedSame;
        return a.updatedAt < b.updatedAt ? NSOrderedDescending : NSOrderedAscending;
    }];
}

- (SPKDownloadJob *)jobWithID:(NSString *)jobID {
    return [self.scheduler jobWithID:jobID];
}

- (void)cancelJobID:(NSString *)jobID {
    [self.scheduler cancelJobID:jobID];
}
- (void)cancelItemID:(NSString *)itemID inJobID:(NSString *)jobID {
    [self.scheduler cancelItemID:itemID inJobID:jobID];
}
// A retry keeps its job ID, so the presenter must treat it as a new run: otherwise the
// terminal it already showed for the first attempt suppresses this attempt's outcome.
- (void)retryJobID:(NSString *)jobID {
    [self.presenter prepareForNewJobSubmission];
    [self.scheduler retryJobID:jobID];
}
- (void)retryItemID:(NSString *)itemID inJobID:(NSString *)jobID {
    [self.presenter prepareForNewJobSubmission];
    [self.scheduler retryItemID:itemID inJobID:jobID];
}
- (void)clearFinishedHistory {
    NSString *accountPK = SPKPerAccountModeActive() ? [SPKAccountManager currentAccountPK] : nil;
    [self.scheduler clearFinishedHistoryForAccountPK:accountPK];
}
- (void)removeJobID:(NSString *)jobID {
    [self.scheduler removeJobID:jobID];
}

- (BOOL)hasActiveJobWithHiddenPill {
    for (SPKDownloadJob *job in [self.scheduler allJobs]) {
        if ([self.presenter jobIsActive:job]) {
            if ([self.presenter hasActiveJobWithoutPillForJobID:job.jobID]) {
                return YES;
            }
        }
    }
    return NO;
}

- (void)reshowProgressPill {
    for (SPKDownloadJob *job in [self.scheduler allJobs]) {
        if ([self.presenter jobIsActive:job]) {
            if ([self.presenter hasActiveJobWithoutPillForJobID:job.jobID]) {
                [self.presenter reshowPillForJob:job];
                break;
            }
        }
    }
}

- (void)confirmCancelForJobID:(NSString *)jobID {
    dispatch_async(dispatch_get_main_queue(), ^{
        // The pill can outlive its job (it ended while the tap was on its way): there
        // is nothing left to cancel, so the tap just clears the pill.
        SPKDownloadJob *target = nil;
        for (SPKDownloadJob *job in [self.scheduler allJobs]) {
            if ([job.jobID isEqualToString:jobID])
                target = job;
        }
        if (!target || ![self.presenter jobIsActive:target]) {
            [self.presenter dismissProgress];
            return;
        }

        UIViewController *presenterHost = topMostController();
        if (!presenterHost)
            return;

        NSUInteger activeCount = 0;
        for (SPKDownloadJob *job in [self.scheduler allJobs]) {
            if ([self.presenter jobIsActive:job]) {
                activeCount++;
            }
        }

        NSMutableArray<SPKIGAlertAction *> *actions = [NSMutableArray array];

        // Keep at the top, blue bold font
        [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_KEEP") style:SPKIGAlertActionStyleCancel handler:nil]];

        if (activeCount > 1) {
            // Cancel current, still blue but not bold
            [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL_CURRENT")
                                                           style:SPKIGAlertActionStyleDefault
                                                         handler:^{
                                                             [self cancelJobID:jobID];
                                                         }]];
            // Cancel all, red, not bold
            [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL_ALL")
                                                           style:SPKIGAlertActionStyleDestructive
                                                         handler:^{
                                                             [self cancelAllActive];
                                                         }]];
        } else {
            // Cancel, red not bold
            [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                           style:SPKIGAlertActionStyleDestructive
                                                         handler:^{
                                                             [self cancelJobID:jobID];
                                                         }]];
        }

        [SPKIGAlertPresenter presentAlertFromViewController:presenterHost
                                                      title:SPKL(@"DOWNLOADS_DOWNLOAD_SERVICE_CANCEL_DOWNLOAD_TEXT")
                                                    message:activeCount > 1 ? SPKL(@"DOWNLOADS_DOWNLOAD_SERVICE_CANCEL_CURRENT_DOWNLOAD_ACTIVE_DOWNLOADS_CONFIRMATION_MESSAGE") : SPKL(@"DOWNLOADS_DOWNLOAD_SERVICE_CANCEL_DOWNLOAD_CONFIRMATION_MESSAGE")
                                                    actions:actions];
    });
}

@end
