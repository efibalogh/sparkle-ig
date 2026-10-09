#import "SPKStrings.h"
#import "SPKDownloadTypes.h"

NSErrorDomain const SPKDownloadErrorDomain = @"com.sparkle.download";

NSInteger const SPKDownloadStoreSchemaVersion = 2;

NSString *const kSPKDownloadMaxConcurrentKey = @"downloads_max_concurrent";
NSString *const kSPKDownloadHistoryLimitKey = @"downloads_history_limit";
NSString *const kSPKDownloadDetectDuplicatesKey = @"downloads_detect_duplicates";
NSString *const kSPKDownloadBackgroundKey = @"downloads_background";
NSString *const kSPKDownloadBackgroundNotificationKey = @"downloads_background_notification";

NSNotificationName const SPKDownloadServiceDidChangeNotification = @"SPKDownloadServiceDidChangeNotification";
NSNotificationName const SPKDownloadJobDidChangeNotification = @"SPKDownloadJobDidChangeNotification";

NSString *const SPKDownloadNotificationJobIDKey = @"jobID";
NSString *const SPKDownloadNotificationItemIDKey = @"itemID";
NSString *const SPKDownloadNotificationSnapshotKey = @"snapshot";

NSError *SPKDownloadError(SPKDownloadErrorCode code, NSString *description, NSString *recovery) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (description.length > 0)
        info[NSLocalizedDescriptionKey] = description;
    if (recovery.length > 0)
        info[NSLocalizedRecoverySuggestionErrorKey] = recovery;
    return [NSError errorWithDomain:SPKDownloadErrorDomain code:code userInfo:info];
}

NSString *SPKDownloadErrorDisplayDescription(NSError *error) {
    if (!error)
        return nil;

    NSString *liveDescription = error.userInfo[NSLocalizedDescriptionKey];
    if (liveDescription.length > 0)
        return liveDescription;

    if ([error.domain isEqualToString:SPKDownloadErrorDomain]) {
        switch ((SPKDownloadErrorCode)error.code) {
        case SPKDownloadErrorInvalidURL:
            return SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_INVALID_DOWNLOAD_URL_TEXT");
        case SPKDownloadErrorUnsupportedScheme:
            return SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_ONLY_HTTP_HTTPS_URLS_SUPPORTED_TEXT");
        case SPKDownloadErrorExpiredURL:
            return SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_MEDIA_URL_EXPIRED_REFRESH_TRY_AGAIN_TEXT");
        case SPKDownloadErrorHTTPFailure:
            return SPKL(@"DOWNLOADS_DOWNLOAD_SCHEDULER_DOWNLOAD_FAILED_TEXT");
        case SPKDownloadErrorEmptyFile:
            return SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_DOWNLOADED_FILE_EMPTY_TEXT");
        case SPKDownloadErrorInvalidContentType:
            return SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_INSTAGRAM_RETURNED_UNEXPECTED_RESPONSE_TEXT");
        case SPKDownloadErrorFileMoveFailed:
        case SPKDownloadErrorDiskFull:
            return SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_COULD_NOT_STORE_DOWNLOADED_FILE_TEXT");
        case SPKDownloadErrorPhotosPermissionDenied:
        case SPKDownloadErrorPhotosSaveFailed:
            return SPKL(@"DOWNLOADS_DOWNLOAD_DESTINATION_WRITER_COULD_NOT_SAVE_PHOTOS_CHECK_PHOTO_LIBRARY_PERMISSION_TEXT");
        case SPKDownloadErrorGallerySaveFailed:
            return SPKL(@"DOWNLOADS_DOWNLOAD_DESTINATION_WRITER_COULD_NOT_SAVE_GALLERY_TEXT");
        case SPKDownloadErrorSharePresentationFailed:
            return SPKL(@"DOWNLOADS_DOWNLOAD_DESTINATION_WRITER_COULD_NOT_PRESENT_SHARE_SHEET_TEXT");
        case SPKDownloadErrorClipboardTooLarge:
            return SPKL(@"DOWNLOADS_DOWNLOAD_DESTINATION_WRITER_FILE_TOO_LARGE_COPY_CLIPBOARD_TEXT");
        case SPKDownloadErrorDuplicateSkipped:
            return SPKL(@"DOWNLOADS_DOWNLOAD_SCHEDULER_SKIPPED_DUPLICATE_TEXT");
        case SPKDownloadErrorCancelled:
            return SPKL(@"DOWNLOADS_SCHEDULER_DOWNLOAD_CANCELLED_ERROR");
        case SPKDownloadErrorInterrupted:
            return SPKL(@"DOWNLOADS_DOWNLOAD_JOB_INTERRUPTED_INSTAGRAM_EXITED_TEXT");
        case SPKDownloadErrorAudioPhotosUnsupported:
            return SPKL(@"DOWNLOADS_DOWNLOAD_DESTINATION_WRITER_AUDIO_CANNOT_SAVED_PHOTOS_TEXT");
        case SPKDownloadErrorServerUnavailable:
            return SPKL(@"DOWNLOADS_DOWNLOAD_TRANSFER_INSTAGRAM_THROTTLED_TEXT");
        }
    }

    return SPKL(@"DOWNLOADS_DOWNLOADS_HISTORY_UNKNOWN_ERROR_OCCURRED_TEXT");
}

BOOL SPKDownloadStateIsTerminal(SPKDownloadState state) {
    switch (state) {
    case SPKDownloadStateSucceeded:
    case SPKDownloadStateFailed:
    case SPKDownloadStateCancelled:
    case SPKDownloadStateInterrupted:
        return YES;
    default:
        return NO;
    }
}

BOOL SPKDownloadStateAllowsTransition(SPKDownloadState from, SPKDownloadState to) {
    if (from == to)
        return YES;
    if (SPKDownloadStateIsTerminal(from))
        return NO;
    switch (from) {
    case SPKDownloadStatePending:
        return to == SPKDownloadStateWaitingForPreflight || to == SPKDownloadStateQueued || to == SPKDownloadStateCancelled;
    case SPKDownloadStateWaitingForPreflight:
        return to == SPKDownloadStateQueued || to == SPKDownloadStateCancelled;
    case SPKDownloadStateQueued:
        return to == SPKDownloadStateRunning || to == SPKDownloadStateCancelled;
    case SPKDownloadStateRunning:
        return to == SPKDownloadStateFinalizing || to == SPKDownloadStateFailed || to == SPKDownloadStateCancelled || to == SPKDownloadStateInterrupted;
    case SPKDownloadStateFinalizing:
        return to == SPKDownloadStateSucceeded || to == SPKDownloadStateFailed || to == SPKDownloadStateCancelled;
    case SPKDownloadStateFailed:
    case SPKDownloadStateCancelled:
    case SPKDownloadStateInterrupted:
        return to == SPKDownloadStateQueued;
    default:
        return NO;
    }
}

SPKDownloadState SPKDownloadDerivedJobState(NSArray<NSNumber *> *itemStates) {
    if (itemStates.count == 0)
        return SPKDownloadStatePending;
    BOOL anyRunning = NO;
    BOOL anyFinalizing = NO;
    BOOL anyQueuedLike = NO;
    NSUInteger succeeded = 0;
    NSUInteger failed = 0;
    NSUInteger cancelled = 0;
    NSUInteger interrupted = 0;
    for (NSNumber *n in itemStates) {
        SPKDownloadState s = (SPKDownloadState)n.integerValue;
        if (s == SPKDownloadStateRunning)
            anyRunning = YES;
        if (s == SPKDownloadStateFinalizing)
            anyFinalizing = YES;
        if (s == SPKDownloadStatePending || s == SPKDownloadStateWaitingForPreflight || s == SPKDownloadStateQueued)
            anyQueuedLike = YES;
        if (s == SPKDownloadStateSucceeded)
            succeeded++;
        else if (s == SPKDownloadStateFailed)
            failed++;
        else if (s == SPKDownloadStateCancelled)
            cancelled++;
        else if (s == SPKDownloadStateInterrupted)
            interrupted++;
    }
    if (anyRunning || anyFinalizing)
        return SPKDownloadStateRunning;
    if (anyQueuedLike)
        return SPKDownloadStateQueued;
    NSUInteger total = itemStates.count;
    if (succeeded == total)
        return SPKDownloadStateSucceeded;
    if (failed == total)
        return SPKDownloadStateFailed;
    if (cancelled == total)
        return SPKDownloadStateCancelled;
    if (interrupted == total)
        return SPKDownloadStateInterrupted;
    if (succeeded > 0 && (failed + cancelled + interrupted) > 0)
        return SPKDownloadStatePartial;
    if (failed > 0 && succeeded == 0 && cancelled == 0 && interrupted == 0)
        return SPKDownloadStateFailed;
    if (cancelled > 0 && succeeded == 0)
        return SPKDownloadStateCancelled;
    if (interrupted > 0 && succeeded == 0)
        return SPKDownloadStateInterrupted;
    return SPKDownloadStatePartial;
}

NSString *SPKDownloadDestinationDisplayName(SPKDownloadDestination destination) {
    switch (destination) {
    case SPKDownloadDestinationPhotos:
        return SPKL(@"DOWNLOADS_DOWNLOAD_DUPLICATE_POLICY_PHOTOS_TEXT");
    case SPKDownloadDestinationGallery:
        return SPKL(@"GALLERY_TITLE");
    case SPKDownloadDestinationShare:
        return SPKL(@"ALERT_ACTION_SHARE");
    case SPKDownloadDestinationClipboard:
        return SPKL(@"DOWNLOADS_DOWNLOAD_TYPES_CLIPBOARD_TEXT");
    case SPKDownloadDestinationCacheOnly:
        return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CONFIGURATION_DOWNLOAD_TEXT");
    }
    return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CONFIGURATION_DOWNLOAD_TEXT");
}

NSString *SPKDownloadSourceSurfaceDisplayName(SPKDownloadSourceSurface surface) {
    switch (surface) {
    case SPKDownloadSourceSurfaceFeed:
        return SPKL(@"FEED_TITLE");
    case SPKDownloadSourceSurfaceReels:
        return SPKL(@"REELS_TITLE");
    case SPKDownloadSourceSurfaceStories:
        return SPKL(@"STORIES_OTHER_STORIES_TITLE");
    case SPKDownloadSourceSurfaceDirect:
        return SPKL(@"GALLERY_FILTER_MESSAGES_LABEL");
    case SPKDownloadSourceSurfaceAudioPage:
        return SPKL(@"GALLERY_GALLERY_FILE_AUDIO_PAGE_TEXT");
    case SPKDownloadSourceSurfaceMediaPreview:
        return SPKL(@"NOTIFICATION_PREVIEW_HEADER");
    case SPKDownloadSourceSurfaceGallery:
        return SPKL(@"GALLERY_TITLE");
    case SPKDownloadSourceSurfaceProfile:
        return SPKL(@"PROFILE_TITLE");
    case SPKDownloadSourceSurfaceInstants:
        return SPKL(@"INSTANTS_CONFIRMATION_INSTANTS_TITLE");
    case SPKDownloadSourceSurfaceComments:
        return SPKL(@"GENERAL_COMMENTS_HEADER");
    default:
        return SPKL(@"STORIES_OTHER_HEADER");
    }
}
