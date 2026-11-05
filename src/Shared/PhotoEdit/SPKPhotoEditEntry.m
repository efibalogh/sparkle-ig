#import "SPKStrings.h"
#import "SPKPhotoEditEntry.h"
#import "../../Utils.h"
#import "../Gallery/SPKGallerySaveMetadata.h"
#import "../MediaDownload/SPKMediaQualityManager.h"
#import "../MediaTrim/SPKTrimSaveCoordinator.h"
#import "../UI/SPKNotificationCenter.h"
#import "SPKPhotoEditorViewController.h"

@interface SPKPhotoEditEntry () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *task;
@property (nonatomic, strong, nullable) SPKNotificationPillView *prepPill;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, strong, nullable) SPKGallerySaveMetadata *metadata;
@property (nonatomic, copy, nullable) NSString *tempPath;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong, nullable) SPKPhotoEditEntry *selfRetain;
@end

@implementation SPKPhotoEditEntry

+ (void)beginEditAndSaveForMediaObject:(id)mediaObject
                              photoURL:(NSURL *)photoURL
                              metadata:(SPKGallerySaveMetadata *)metadata
                             presenter:(UIViewController *)presenter {
    [self beginEditAndSaveForMediaObject:mediaObject
                                photoURL:photoURL
                          displayedImage:nil
                                metadata:metadata
                               presenter:presenter];
}

+ (void)beginEditAndSaveForMediaObject:(id)mediaObject
                              photoURL:(NSURL *)photoURL
                        displayedImage:(UIImage *)displayedImage
                              metadata:(SPKGallerySaveMetadata *)metadata
                             presenter:(UIViewController *)presenter {
    // A "Fetching 4K candidates" pill that ran ahead of this has done its job.
    [[SPKNotificationCenter shared] dismissTransientProgressPill];
    if (!presenter)
        return;
    if (!photoURL) {
        SPKNotify(@"spk.photoedit.entry", SPKL(@"PHOTO_EDIT_PHOTO_EDIT_ENTRY_NO_PHOTO_EDIT_TEXT"), nil, @"error_filled",
                  SPKNotificationToneError);
        return;
    }

    SPKPhotoEditEntry *entry = [[self alloc] init];
    entry.presenter = presenter;
    entry.metadata = metadata;
    entry.selfRetain = entry; // keep alive across the async flow

    // A local file (e.g. gallery / already-downloaded) needs no fetch.
    if (photoURL.isFileURL) {
        UIImage *image = displayedImage ?: [UIImage imageWithContentsOfFile:photoURL.path];
        if (!image) {
            SPKNotify(@"spk.photoedit.entry", SPKL(@"GALLERY_GALLERY_CANNOT_EDIT_TEXT"),
                      SPKL(@"PHOTO_EDIT_PHOTO_EDIT_ENTRY_IMAGE_UNAVAILABLE_TEXT"), @"error_filled", SPKNotificationToneError);
            [entry finish];
            return;
        }
        [entry presentEditorWithImage:image];
        return;
    }

    [SPKMediaQualityManager resolveEditPhotoURLForMediaObject:mediaObject
                                                     photoURL:photoURL
                                                    presenter:presenter
                                                   completion:^(NSURL *url) {
                                                       if (!url) {
                                                           [entry finish];
                                                           return;
                                                       } // dismissed
                                                       // The bitmap already on screen is this exact file; skip the refetch.
                                                       if (displayedImage && [url isEqual:photoURL]) {
                                                           [entry presentEditorWithImage:displayedImage];
                                                           return;
                                                       }
                                                       [entry downloadPhotoURL:url];
                                                   }];
}

#pragma mark - Download

- (void)downloadPhotoURL:(NSURL *)url {
    __weak typeof(self) weakSelf = self;
    self.prepPill = [[SPKNotificationCenter shared] beginUnmanagedProgressWithTitle:SPKL(@"PHOTO_EDIT_PHOTO_EDIT_ENTRY_PREPARING_PHOTO_TEXT")
                                                                           onCancel:^{
                                                                               [SPKTrimSaveCoordinator confirmCancelThen:^{
                                                                                   __strong typeof(weakSelf) self = weakSelf;
                                                                                   self.cancelled = YES;
                                                                                   [self.task cancel];
                                                                                   [self.prepPill dismiss];
                                                                                   self.prepPill = nil;
                                                                                   [self cleanupAndFinish];
                                                                               }];
                                                                           }];

    self.session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                 delegate:self
                                            delegateQueue:nil];
    self.task = [self.session downloadTaskWithURL:url];
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
                                                 [NSString stringWithFormat:@"SPKEditSrc-%@.jpg", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
    if ([[NSFileManager defaultManager] moveItemAtPath:location.path toPath:dest error:nil]) {
        self.tempPath = dest;
    }
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.cancelled)
            return;
        UIImage *image = self.tempPath ? [UIImage imageWithContentsOfFile:self.tempPath] : nil;
        if (error || !image) {
            [self.prepPill showError:error.localizedDescription ?: SPKL(@"PHOTO_EDIT_PHOTO_EDIT_ENTRY_COULD_NOT_DOWNLOAD_PHOTO_TEXT")];
            self.prepPill = nil;
            [self cleanupAndFinish];
            return;
        }
        [self.prepPill dismiss];
        self.prepPill = nil;
        [self presentEditorWithImage:image];
    });
}

#pragma mark - Editor

- (void)presentEditorWithImage:(UIImage *)image {
    UIViewController *presenter = self.presenter;
    if (!presenter) {
        [self cleanupAndFinish];
        return;
    }
    SPKPhotoEditorConfiguration *config = [SPKPhotoEditorConfiguration freeformConfiguration];
    config.doneOptions = @[
        [SPKPhotoEditorDoneOption optionWithTitle:SPKL(@"FEED_COMMENT_ACTIONS_SAVE_PHOTOS_TEXT")
                                       identifier:@"photos"
                                         iconName:@"download"],
        [SPKPhotoEditorDoneOption optionWithTitle:SPKL(@"ALERT_ACTION_SHARE")
                                       identifier:@"share"
                                         iconName:@"share"],
        [SPKPhotoEditorDoneOption optionWithTitle:SPKL(@"FEED_COMMENT_ACTIONS_COPY_TEXT")
                                       identifier:@"clipboard"
                                         iconName:@"copy"],
        [SPKPhotoEditorDoneOption optionWithTitle:SPKL(@"FEED_COMMENT_ACTIONS_SAVE_GALLERY_TEXT")
                                       identifier:@"gallery"
                                         iconName:@"sparkle_gallery"],
    ];
    __weak typeof(self) weakSelf = self;
    [SPKPhotoEditorViewController presentWithSourceImage:image
                                           configuration:config
                                                    from:presenter
                                   destinationCompletion:^(UIImage *edited, NSString *destinationTag) {
                                       __strong typeof(weakSelf) self = weakSelf;
                                       if (!self)
                                           return;
                                       // Cancel is signalled as a nil image (destination mode), so the entry is
                                       // always released whether the user saves or backs out.
                                       if (!edited) {
                                           [self cleanupAndFinish];
                                           return;
                                       }
                                       [SPKTrimSaveCoordinator routeEditedImage:edited
                                                                  toDestination:(destinationTag ?: @"gallery")
                                                                                metadata:self.metadata
                                                                      presenter:self.presenter
                                                                     completion:^(BOOL ok) {
                                                                         [self cleanupAndFinish];
                                                                     }];
                                   }];
}

#pragma mark - Lifecycle

- (void)cleanupAndFinish {
    if (self.tempPath) {
        [[NSFileManager defaultManager] removeItemAtPath:self.tempPath error:nil];
        self.tempPath = nil;
    }
    [self finish];
}

- (void)finish {
    [self.session finishTasksAndInvalidate];
    self.session = nil;
    self.selfRetain = nil; // allow deallocation
}

@end
