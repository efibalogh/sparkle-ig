#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class SPKGallerySaveMetadata;

NS_ASSUME_NONNULL_BEGIN

/// Orchestrates the action-button / long-press "Edit & Save" flow for a still
/// photo: picks the source by the photo quality preference (asking when it is
/// Always Ask), fetches it to a temp file, presents the shared photo editor with a destination
/// menu (Photos / Gallery / Share / Copy), then routes the edited image through
/// `SPKTrimSaveCoordinator`.
@interface SPKPhotoEditEntry : NSObject

+ (void)beginEditAndSaveForMediaObject:(nullable id)mediaObject
                              photoURL:(nullable NSURL *)photoURL
                              metadata:(nullable SPKGallerySaveMetadata *)metadata
                             presenter:(UIViewController *)presenter;

/// As above, but `displayedImage` (the bitmap already decoded from `photoURL`) is
/// used instead of a refetch when the quality choice resolves to that same URL.
+ (void)beginEditAndSaveForMediaObject:(nullable id)mediaObject
                              photoURL:(nullable NSURL *)photoURL
                        displayedImage:(nullable UIImage *)displayedImage
                              metadata:(nullable SPKGallerySaveMetadata *)metadata
                             presenter:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
