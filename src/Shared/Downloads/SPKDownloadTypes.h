#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const SPKDownloadErrorDomain;

typedef NS_ERROR_ENUM(SPKDownloadErrorDomain, SPKDownloadErrorCode){
    SPKDownloadErrorInvalidURL = 1,
    SPKDownloadErrorUnsupportedScheme,
    SPKDownloadErrorExpiredURL,
    SPKDownloadErrorHTTPFailure,
    SPKDownloadErrorEmptyFile,
    SPKDownloadErrorInvalidContentType,
    SPKDownloadErrorFileMoveFailed,
    SPKDownloadErrorDiskFull,
    SPKDownloadErrorPhotosPermissionDenied,
    SPKDownloadErrorPhotosSaveFailed,
    SPKDownloadErrorGallerySaveFailed,
    SPKDownloadErrorSharePresentationFailed,
    SPKDownloadErrorClipboardTooLarge,
    SPKDownloadErrorDuplicateSkipped,
    SPKDownloadErrorCancelled,
    SPKDownloadErrorInterrupted,
    SPKDownloadErrorAudioPhotosUnsupported,
    SPKDownloadErrorServerUnavailable,
};

typedef NS_ENUM(NSInteger, SPKDownloadState) {
    SPKDownloadStatePending = 0,
    SPKDownloadStateWaitingForPreflight,
    SPKDownloadStateQueued,
    SPKDownloadStateRunning,
    SPKDownloadStateFinalizing,
    SPKDownloadStateSucceeded,
    SPKDownloadStatePartial,
    SPKDownloadStateFailed,
    SPKDownloadStateCancelled,
    SPKDownloadStateInterrupted,
};

typedef NS_ENUM(NSInteger, SPKDownloadSourceSurface) {
    SPKDownloadSourceSurfaceOther = 0,
    SPKDownloadSourceSurfaceFeed,
    SPKDownloadSourceSurfaceReels,
    SPKDownloadSourceSurfaceStories,
    SPKDownloadSourceSurfaceDirect,
    SPKDownloadSourceSurfaceAudioPage,
    SPKDownloadSourceSurfaceMediaPreview,
    SPKDownloadSourceSurfaceGallery,
    SPKDownloadSourceSurfaceProfile,
    SPKDownloadSourceSurfaceInstants,
    SPKDownloadSourceSurfaceComments,
};

typedef NS_ENUM(NSInteger, SPKDownloadDestination) {
    SPKDownloadDestinationPhotos = 0,
    SPKDownloadDestinationGallery,
    SPKDownloadDestinationShare,
    SPKDownloadDestinationClipboard,
    SPKDownloadDestinationCacheOnly,
};

typedef NS_ENUM(NSInteger, SPKDownloadPresentationMode) {
    SPKDownloadPresentationModeQueuePill = 0,
    SPKDownloadPresentationModeQuiet,
    SPKDownloadPresentationModeImmediateShare,
};

typedef NS_ENUM(NSInteger, SPKDownloadDuplicatePolicyMode) {
    SPKDownloadDuplicatePolicyAsk = 0,
    SPKDownloadDuplicatePolicyAlwaysDownload,
    SPKDownloadDuplicatePolicyReplaceExisting,
    SPKDownloadDuplicatePolicySkipExisting,
};

typedef NS_ENUM(NSInteger, SPKDownloadQualityPolicy) {
    SPKDownloadQualityPolicyDefault = 0,
    SPKDownloadQualityPolicyBestAvailable,
    SPKDownloadQualityPolicyUserSetting,
};

typedef NS_ENUM(NSInteger, SPKDownloadMediaKind) {
    SPKDownloadMediaKindUnknown = 0,
    SPKDownloadMediaKindImage,
    SPKDownloadMediaKindVideo,
    SPKDownloadMediaKindAudio,
};

typedef NS_ENUM(NSInteger, SPKDownloadHistoryFilter) {
    SPKDownloadHistoryFilterAll = 0,
    SPKDownloadHistoryFilterActive,
    SPKDownloadHistoryFilterQueued,
    SPKDownloadHistoryFilterFailed,
    SPKDownloadHistoryFilterRecent,
};

FOUNDATION_EXPORT NSInteger const SPKDownloadStoreSchemaVersion;

FOUNDATION_EXPORT NSString *const kSPKDownloadMaxConcurrentKey;
FOUNDATION_EXPORT NSString *const kSPKDownloadHistoryLimitKey;
FOUNDATION_EXPORT NSString *const kSPKDownloadDetectDuplicatesKey;
FOUNDATION_EXPORT NSString *const kSPKDownloadBackgroundKey;
FOUNDATION_EXPORT NSString *const kSPKDownloadBackgroundNotificationKey;

FOUNDATION_EXPORT NSNotificationName const SPKDownloadServiceDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const SPKDownloadJobDidChangeNotification;

FOUNDATION_EXPORT NSString *const SPKDownloadNotificationJobIDKey;
FOUNDATION_EXPORT NSString *const SPKDownloadNotificationItemIDKey;
FOUNDATION_EXPORT NSString *const SPKDownloadNotificationSnapshotKey;

FOUNDATION_EXPORT NSError *SPKDownloadError(SPKDownloadErrorCode code, NSString *description, NSString *_Nullable recovery);
/// Returns a current-locale description without relying on localized text stored in history.
FOUNDATION_EXPORT NSString *_Nullable SPKDownloadErrorDisplayDescription(NSError *_Nullable error);
FOUNDATION_EXPORT BOOL SPKDownloadStateIsTerminal(SPKDownloadState state);
FOUNDATION_EXPORT BOOL SPKDownloadStateAllowsTransition(SPKDownloadState from, SPKDownloadState to);
FOUNDATION_EXPORT SPKDownloadState SPKDownloadDerivedJobState(NSArray<NSNumber *> *itemStates);
FOUNDATION_EXPORT NSString *SPKDownloadDestinationDisplayName(SPKDownloadDestination destination);
FOUNDATION_EXPORT NSString *SPKDownloadSourceSurfaceDisplayName(SPKDownloadSourceSurface surface);

NS_ASSUME_NONNULL_END
