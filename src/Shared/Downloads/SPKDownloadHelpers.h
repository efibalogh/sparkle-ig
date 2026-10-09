/// Helpers for building download requests and mapping between legacy types.
/// Provides convenient wrappers around SPKDownloadService for common submission patterns.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "../Gallery/SPKGalleryFile.h"
#import "SPKDownloadRequest.h"
#import "SPKDownloadTypes.h"

@class SPKGallerySaveMetadata;

NS_ASSUME_NONNULL_BEGIN

@interface SPKDownloadHelpers : NSObject

+ (SPKDownloadSourceSurface)sourceSurfaceForGallerySource:
    (SPKGallerySource)source;
+ (SPKDownloadSourceSurface)sourceSurfaceForActionButtonSource:
    (NSInteger)actionButtonSource;
+ (SPKDownloadSourceSurface)
    resolvedSourceSurface:(SPKDownloadSourceSurface)surface
                 metadata:(nullable SPKGallerySaveMetadata *)metadata;

+ (nullable NSString *)historyTitleForRequest:(SPKDownloadRequest *)request;

+ (SPKDownloadMediaKind)mediaKindForExtension:(NSString *)ext;
+ (nullable NSString *)
    preferredFilenameForURL:(NSURL *)url
                  mediaKind:(SPKDownloadMediaKind)kind
                   metadata:(nullable SPKGallerySaveMetadata *)metadata;
+ (nullable NSString *)stageImageForDownload:(UIImage *)image;

+ (void)downloadURL:(NSURL *)url
          extension:(NSString *)extension
        destination:(SPKDownloadDestination)destination
           metadata:(nullable SPKGallerySaveMetadata *)metadata
     notificationID:(NSString *)notificationID
          presenter:(nullable UIViewController *)presenter
      sourceSurface:(SPKDownloadSourceSurface)sourceSurface;

+ (void)submitRemoteURL:(NSURL *)url
              extension:(NSString *)extension
            destination:(SPKDownloadDestination)destination
               metadata:(nullable SPKGallerySaveMetadata *)metadata
         notificationID:(NSString *)notificationID
              presenter:(nullable UIViewController *)presenter
             anchorView:(nullable UIView *)anchorView
          sourceSurface:(SPKDownloadSourceSurface)sourceSurface
           showProgress:(BOOL)showProgress;

/// Same as above; `configureItem` can adjust the item request before submission.
+ (void)submitRemoteURL:(NSURL *)url
              extension:(NSString *)extension
            destination:(SPKDownloadDestination)destination
               metadata:(nullable SPKGallerySaveMetadata *)metadata
         notificationID:(NSString *)notificationID
              presenter:(nullable UIViewController *)presenter
             anchorView:(nullable UIView *)anchorView
          sourceSurface:(SPKDownloadSourceSurface)sourceSurface
           showProgress:(BOOL)showProgress
          configureItem:(nullable void (^)(SPKDownloadItemRequest *item))configureItem;

+ (void)performBulkItems:(NSArray<SPKDownloadItemRequest *> *)items
               destination:(SPKDownloadDestination)destination
          actionIdentifier:(NSString *)identifier
                 presenter:(nullable UIViewController *)presenter
                anchorView:(nullable UIView *)anchorView
             sourceSurface:(SPKDownloadSourceSurface)sourceSurface
        finalizeBatchShare:(BOOL)batchShare
    finalizeBatchClipboard:(BOOL)batchClipboard;

/// Routes a bulk-download action identifier (Library / Share / Gallery /
/// Clipboard) to `performBulkItems:` with the correct destination and finalize
/// flags. Shared by the action-button menu and the media-preview toolbar so the
/// destination mapping lives in one place. Returns NO when `identifier` is not a
/// recognized bulk download/clipboard action (e.g. Copy Links), letting the
/// caller handle that case itself.
+ (BOOL)performBulkDownloadIdentifier:(NSString *)identifier
                                items:(NSArray<SPKDownloadItemRequest *> *)items
                            presenter:(nullable UIViewController *)presenter
                           anchorView:(nullable UIView *)anchorView
                        sourceSurface:(SPKDownloadSourceSurface)sourceSurface;

+ (void)
    submitDashDownloadWithPrimaryURL:(NSURL *)primaryURL
                        secondaryURL:(nullable NSURL *)secondaryURL
                          optionKind:(NSInteger)optionKind
                            basename:(NSString *)basename
                            duration:(double)duration
                               width:(NSInteger)width
                              height:(NSInteger)height
                       sourceBitrate:(NSInteger)bandwidth
                           extension:(NSString *)extension
                            metadata:(nullable SPKGallerySaveMetadata *)metadata
                         destination:(SPKDownloadDestination)destination
                      notificationID:(NSString *)notificationID
                           presenter:(nullable UIViewController *)presenter
                       sourceSurface:(SPKDownloadSourceSurface)sourceSurface
                        showProgress:(BOOL)showProgress;

+ (void)submitLocalFileURL:(NSURL *)fileURL
                 extension:(NSString *)extension
               destination:(SPKDownloadDestination)destination
                  metadata:(nullable SPKGallerySaveMetadata *)metadata
            notificationID:(NSString *)notificationID
                 presenter:(nullable UIViewController *)presenter
                anchorView:(nullable UIView *)anchorView
             sourceSurface:(SPKDownloadSourceSurface)sourceSurface;

@end

NS_ASSUME_NONNULL_END
