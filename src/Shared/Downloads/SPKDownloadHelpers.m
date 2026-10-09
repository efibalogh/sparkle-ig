#import "SPKStrings.h"
#import "SPKDownloadHelpers.h"

#import "../../Shared/ActionButton/ActionButtonCore.h"
#import "../Gallery/SPKGallerySaveMetadata.h"
#import "../SPKStoragePaths.h"
#import "../UI/SPKNotificationCenter.h"
#import "SPKDownloadService.h"

static NSString *SPKDownloadDisplayUsername(NSString *username) {
    NSString *trimmed =
        [username stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || trimmed.length > 30)
        return nil;
    NSString *lower = trimmed.lowercaseString;
    NSSet<NSString *> *blocked = [NSSet setWithArray:@[
        @"more", @"options", @"menu", @"close", @"done", @"cancel", @"all",
        @"active", @"queued", @"failed", @"completed", @"clipboard", @"download",
        @"save", @"share", @"copy", @"gallery", @"photos", @"instants"
    ]];
    if ([blocked containsObject:lower])
        return nil;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
                                                   @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._"] invertedSet];
    return [trimmed rangeOfCharacterFromSet:invalid].location == NSNotFound ? trimmed : nil;
}

@implementation SPKDownloadHelpers

+ (SPKDownloadSourceSurface)sourceSurfaceForGallerySource:
    (SPKGallerySource)source {
    switch (source) {
    case SPKGallerySourceFeed:
        return SPKDownloadSourceSurfaceFeed;
    case SPKGallerySourceReels:
        return SPKDownloadSourceSurfaceReels;
    case SPKGallerySourceStories:
        return SPKDownloadSourceSurfaceStories;
    case SPKGallerySourceDMs:
        return SPKDownloadSourceSurfaceDirect;
    case SPKGallerySourceProfile:
        return SPKDownloadSourceSurfaceProfile;
    case SPKGallerySourceInstants:
        return SPKDownloadSourceSurfaceInstants;
    case SPKGallerySourceAudioPage:
        return SPKDownloadSourceSurfaceAudioPage;
    case SPKGallerySourceComments:
        return SPKDownloadSourceSurfaceComments;
    default:
        return SPKDownloadSourceSurfaceOther;
    }
}

+ (SPKDownloadSourceSurface)sourceSurfaceForActionButtonSource:
    (NSInteger)actionButtonSource {
    switch ((SPKActionButtonSource)actionButtonSource) {
    case SPKActionButtonSourceFeed:
        return SPKDownloadSourceSurfaceFeed;
    case SPKActionButtonSourceReels:
        return SPKDownloadSourceSurfaceReels;
    case SPKActionButtonSourceStories:
        return SPKDownloadSourceSurfaceStories;
    case SPKActionButtonSourceDirect:
        return SPKDownloadSourceSurfaceDirect;
    case SPKActionButtonSourceProfile:
        return SPKDownloadSourceSurfaceProfile;
    case SPKActionButtonSourceInstants:
        return SPKDownloadSourceSurfaceInstants;
    default:
        return SPKDownloadSourceSurfaceOther;
    }
}

+ (SPKDownloadSourceSurface)
    resolvedSourceSurface:(SPKDownloadSourceSurface)surface
                 metadata:(SPKGallerySaveMetadata *)metadata {
    if (surface != SPKDownloadSourceSurfaceOther)
        return surface;
    if (!metadata)
        return SPKDownloadSourceSurfaceOther;
    return [self sourceSurfaceForGallerySource:(SPKGallerySource)metadata.source];
}

+ (nullable NSString *)historyTitleForRequest:(SPKDownloadRequest *)request {
    if (request.items.count > 1) {
        NSMutableOrderedSet<NSString *> *usernames = [NSMutableOrderedSet orderedSet];
        for (SPKDownloadItemRequest *item in request.items) {
            NSString *username = SPKDownloadDisplayUsername(item.metadata.sourceUsername);
            if (username.length > 0)
                [usernames addObject:username];
        }
        if (usernames.count == 1)
            return usernames.firstObject;
        if (usernames.count > 1)
            return [NSString stringWithFormat:SPKL(@"DOWNLOADS_DOWNLOAD_HELPERS_VALUE_VALUE_MORE_FORMAT"), usernames.firstObject,
                                              (unsigned long)(usernames.count - 1)];
        return nil;
    }

    NSString *requestUsername = SPKDownloadDisplayUsername(request.metadata.sourceUsername);
    if (requestUsername.length > 0)
        return requestUsername;
    for (SPKDownloadItemRequest *item in request.items) {
        NSString *itemUsername = SPKDownloadDisplayUsername(item.metadata.sourceUsername);
        if (itemUsername.length > 0)
            return itemUsername;
    }
    return nil;
}

+ (SPKGalleryMediaType)galleryMediaTypeForKind:(SPKDownloadMediaKind)kind {
    switch (kind) {
    case SPKDownloadMediaKindVideo:
        return SPKGalleryMediaTypeVideo;
    case SPKDownloadMediaKindAudio:
        return SPKGalleryMediaTypeAudio;
    default:
        return SPKGalleryMediaTypeImage;
    }
}

+ (NSString *)preferredFilenameForURL:(NSURL *)url
                            mediaKind:(SPKDownloadMediaKind)kind
                             metadata:(SPKGallerySaveMetadata *)metadata {
    if (!url)
        return nil;
    return SPKFileNameForMedia(url, [self galleryMediaTypeForKind:kind],
                               metadata);
}

+ (SPKDownloadMediaKind)mediaKindForExtension:(NSString *)ext {
    NSString *lower = ext.lowercaseString;
    NSSet *audio = [NSSet setWithArray:@[
        @"m4a", @"aac", @"mp3", @"wav", @"caf", @"aiff", @"flac", @"opus", @"ogg"
    ]];
    NSSet *video = [NSSet setWithArray:@[
        @"mp4", @"mov", @"m4v", @"avi", @"webm", @"mkv", @"3gp"
    ]];
    if ([audio containsObject:lower])
        return SPKDownloadMediaKindAudio;
    if ([video containsObject:lower])
        return SPKDownloadMediaKindVideo;
    return SPKDownloadMediaKindImage;
}

+ (nullable NSString *)stageImageForDownload:(UIImage *)image {
    NSData *data = UIImagePNGRepresentation(image);
    if (!data)
        return nil;
    NSString *directory = [[SPKStoragePaths downloadsDirectory]
        stringByAppendingPathComponent:@"v2/sources"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *path = [directory
        stringByAppendingPathComponent:
            [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"png"]];
    return [data writeToFile:path atomically:YES] ? path : nil;
}

+ (void)submitRemoteURL:(NSURL *)url
              extension:(NSString *)extension
            destination:(SPKDownloadDestination)destination
               metadata:(SPKGallerySaveMetadata *)metadata
         notificationID:(NSString *)notificationID
              presenter:(UIViewController *)presenter
             anchorView:(UIView *)anchorView
          sourceSurface:(SPKDownloadSourceSurface)sourceSurface
           showProgress:(BOOL)showProgress {
    [self submitRemoteURL:url
                extension:extension
              destination:destination
                 metadata:metadata
           notificationID:notificationID
                presenter:presenter
               anchorView:anchorView
            sourceSurface:sourceSurface
             showProgress:showProgress
            configureItem:nil];
}

+ (void)submitRemoteURL:(NSURL *)url
              extension:(NSString *)extension
            destination:(SPKDownloadDestination)destination
               metadata:(SPKGallerySaveMetadata *)metadata
         notificationID:(NSString *)notificationID
              presenter:(UIViewController *)presenter
             anchorView:(UIView *)anchorView
          sourceSurface:(SPKDownloadSourceSurface)sourceSurface
           showProgress:(BOOL)showProgress
          configureItem:(void (^)(SPKDownloadItemRequest *item))configureItem {
    SPKDownloadMediaKind kind = [self mediaKindForExtension:extension];
    SPKDownloadItemRequest *item =
        [SPKDownloadItemRequest itemWithRemoteURL:url
                                        mediaKind:kind];
    item.preferredFileExtension = extension;
    item.metadata = metadata;
    item.expectedFilenameStem =
        [[self preferredFilenameForURL:url
                             mediaKind:kind
                              metadata:metadata] stringByDeletingPathExtension];
    if (configureItem)
        configureItem(item);
    SPKDownloadRequest *request =
        [SPKDownloadRequest requestWithItems:@[ item ]
                                 destination:destination];
    request.metadata = metadata;
    request.notificationIdentifier = notificationID;
    request.presenter = presenter;
    request.anchorView = anchorView;
    request.sourceSurface = [self resolvedSourceSurface:sourceSurface
                                               metadata:metadata];
    request.presentationMode = showProgress ? SPKDownloadPresentationModeQueuePill
                                            : SPKDownloadPresentationModeQuiet;
    [[SPKDownloadService shared] submitRequest:request completion:nil];
}

+ (void)downloadURL:(NSURL *)url
          extension:(NSString *)extension
        destination:(SPKDownloadDestination)destination
           metadata:(SPKGallerySaveMetadata *)metadata
     notificationID:(NSString *)notificationID
          presenter:(UIViewController *)presenter
      sourceSurface:(SPKDownloadSourceSurface)sourceSurface {
    [self submitRemoteURL:url
                extension:extension
              destination:destination
                 metadata:metadata
           notificationID:notificationID
                presenter:presenter
               anchorView:nil
            sourceSurface:sourceSurface
             showProgress:SPKNotificationIsEnabled(notificationID)];
}

+ (void)performBulkItems:(NSArray<SPKDownloadItemRequest *> *)items
               destination:(SPKDownloadDestination)destination
          actionIdentifier:(NSString *)identifier
                 presenter:(UIViewController *)presenter
                anchorView:(UIView *)anchorView
             sourceSurface:(SPKDownloadSourceSurface)sourceSurface
        finalizeBatchShare:(BOOL)batchShare
    finalizeBatchClipboard:(BOOL)batchClipboard {
    if (items.count == 0) {
        SPKNotify(identifier ?: kSPKNotificationDownloadAllLibrary,
                  SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_DOWNLOADABLE_MEDIA_TEXT"), nil, @"error_filled",
                  SPKNotificationToneError);
        return;
    }

    SPKDownloadItemRequest *firstItem = items.firstObject;
    SPKDownloadRequest *request =
        [SPKDownloadRequest requestWithItems:items
                                 destination:destination];
    request.metadata = firstItem.metadata;
    request.notificationIdentifier = identifier;
    request.presenter = presenter;
    request.anchorView = anchorView;
    request.finalizeAsBatchShare = batchShare;
    request.finalizeAsBatchClipboard = batchClipboard;
    request.sourceSurface = sourceSurface;
    request.presentationMode = SPKNotificationIsEnabled(identifier)
                                   ? SPKDownloadPresentationModeQueuePill
                                   : SPKDownloadPresentationModeQuiet;
    [[SPKDownloadService shared] submitRequest:request completion:nil];
}

+ (BOOL)performBulkDownloadIdentifier:(NSString *)identifier
                                items:(NSArray<SPKDownloadItemRequest *> *)items
                            presenter:(UIViewController *)presenter
                           anchorView:(UIView *)anchorView
                        sourceSurface:(SPKDownloadSourceSurface)sourceSurface {
    SPKDownloadDestination destination;
    BOOL batchShare = NO;
    BOOL batchClipboard = NO;

    if ([identifier isEqualToString:kSPKActionDownloadAllLibrary]) {
        destination = SPKDownloadDestinationPhotos;
    } else if ([identifier isEqualToString:kSPKActionDownloadAllShare]) {
        destination = SPKDownloadDestinationCacheOnly;
        batchShare = YES;
    } else if ([identifier isEqualToString:kSPKActionDownloadAllGallery]) {
        destination = SPKDownloadDestinationGallery;
    } else if ([identifier isEqualToString:kSPKActionDownloadAllClipboard]) {
        destination = SPKDownloadDestinationCacheOnly;
        batchClipboard = YES;
    } else {
        return NO;
    }

    [self performBulkItems:items
                   destination:destination
              actionIdentifier:identifier
                     presenter:presenter
                    anchorView:anchorView
                 sourceSurface:sourceSurface
            finalizeBatchShare:batchShare
        finalizeBatchClipboard:batchClipboard];
    return YES;
}

+ (void)submitDashDownloadWithPrimaryURL:(NSURL *)primaryURL
                            secondaryURL:(NSURL *)secondaryURL
                              optionKind:(NSInteger)optionKind
                                basename:(NSString *)basename
                                duration:(double)duration
                                   width:(NSInteger)width
                                  height:(NSInteger)height
                           sourceBitrate:(NSInteger)bandwidth
                               extension:(NSString *)extension
                                metadata:(SPKGallerySaveMetadata *)metadata
                             destination:(SPKDownloadDestination)destination
                          notificationID:(NSString *)notificationID
                               presenter:(UIViewController *)presenter
                           sourceSurface:(SPKDownloadSourceSurface)sourceSurface
                            showProgress:(BOOL)showProgress {
    SPKDownloadMediaKind kind = SPKDownloadMediaKindVideo;
    if (optionKind == 3)
        kind = SPKDownloadMediaKindAudio;
    SPKDownloadItemRequest *item =
        [SPKDownloadItemRequest itemWithRemoteURL:primaryURL
                                        mediaKind:kind];
    item.preferredFileExtension = extension;
    item.metadata = metadata;
    item.requiresDashMerge = YES;
    item.dashSecondaryURLString = secondaryURL.absoluteString;
    item.dashOptionKind = optionKind;
    item.dashDuration = duration;
    item.dashWidth = width;
    item.dashHeight = height;
    item.dashBandwidth = bandwidth;
    NSString *preferred = metadata ? [self preferredFilenameForURL:primaryURL
                                                         mediaKind:kind
                                                          metadata:metadata]
                                   : nil;
    item.expectedFilenameStem =
        preferred.length ? preferred.stringByDeletingPathExtension : basename;
    SPKDownloadRequest *request =
        [SPKDownloadRequest requestWithItems:@[ item ]
                                 destination:destination];
    request.metadata = metadata;
    request.notificationIdentifier = notificationID;
    request.presenter = presenter;
    request.sourceSurface = [self resolvedSourceSurface:sourceSurface
                                               metadata:metadata];
    request.presentationMode = (showProgress && SPKNotificationIsEnabled(notificationID))
                                   ? SPKDownloadPresentationModeQueuePill
                                   : SPKDownloadPresentationModeQuiet;
    [[SPKDownloadService shared] submitRequest:request completion:nil];
}

+ (void)submitLocalFileURL:(NSURL *)fileURL
                 extension:(NSString *)extension
               destination:(SPKDownloadDestination)destination
                  metadata:(SPKGallerySaveMetadata *)metadata
            notificationID:(NSString *)notificationID
                 presenter:(UIViewController *)presenter
                anchorView:(UIView *)anchorView
             sourceSurface:(SPKDownloadSourceSurface)sourceSurface {
    SPKDownloadMediaKind kind = [self mediaKindForExtension:extension];
    SPKDownloadItemRequest *item =
        [SPKDownloadItemRequest itemWithLocalPath:fileURL.path
                                        mediaKind:kind];
    item.preferredFileExtension = extension;
    item.metadata = metadata;
    item.expectedFilenameStem =
        [[self preferredFilenameForURL:fileURL
                             mediaKind:kind
                              metadata:metadata] stringByDeletingPathExtension];
    SPKDownloadRequest *request =
        [SPKDownloadRequest requestWithItems:@[ item ]
                                 destination:destination];
    request.metadata = metadata;
    request.notificationIdentifier = notificationID;
    request.presenter = presenter;
    request.anchorView = anchorView;
    request.sourceSurface = [self resolvedSourceSurface:sourceSurface
                                               metadata:metadata];
    request.presentationMode = SPKNotificationIsEnabled(notificationID)
                                   ? SPKDownloadPresentationModeQueuePill
                                   : SPKDownloadPresentationModeQuiet;
    [[SPKDownloadService shared] submitRequest:request completion:nil];
}

@end
