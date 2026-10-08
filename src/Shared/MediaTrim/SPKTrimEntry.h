#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class SPKGallerySaveMetadata;

NS_ASSUME_NONNULL_BEGIN

/// Orchestrates the action-button "Trim & Save" flow: resolves the trim source
/// from the media object (honoring the user's quality setting), fetches a
/// preview to a temp file, presents the trim editor, then a destination picker
/// (Photos / Gallery / Share) and renders + finalizes in the background.
@interface SPKTrimEntry : NSObject

+ (void)beginTrimAndSaveForMediaObject:(nullable id)mediaObject
                              photoURL:(nullable NSURL *)photoURL
                              videoURL:(nullable NSURL *)videoURL
                              metadata:(nullable SPKGallerySaveMetadata *)metadata
                             presenter:(UIViewController *)presenter;

/// Same flow, for callers that already hold the media on disk (the expanded
/// preview). `localFileURL` is a local copy of the remote `localSourceURL`: it
/// is scrubbed in the editor instead of downloading the preview again, and is
/// used as the final source too when the chosen quality is that same file. The
/// final render still comes from the quality the user's setting selects.
+ (void)beginTrimAndSaveForMediaObject:(nullable id)mediaObject
                              photoURL:(nullable NSURL *)photoURL
                              videoURL:(nullable NSURL *)videoURL
                          localFileURL:(nullable NSURL *)localFileURL
                        localSourceURL:(nullable NSURL *)localSourceURL
                              metadata:(nullable SPKGallerySaveMetadata *)metadata
                             presenter:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
