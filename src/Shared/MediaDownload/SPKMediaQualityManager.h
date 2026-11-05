#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "../Downloads/SPKDownloadTypes.h"

@class SPKGallerySaveMetadata;
@class SPKTrimSourcePlan;

NS_ASSUME_NONNULL_BEGIN

@interface SPKMediaQualityManager : NSObject

/// Resolves how to source a trim for `mediaObject`. When `qualityOverride` is
/// nil the user's `downloads_video_quality` setting is used (with `always_ask`
/// treated as best); pass `high` / `high_ignore_dash` / `medium` / `low` to
/// force a tier (used by the "Trim & Save" quality prompt). Returns nil when
/// the media isn't a video.
+ (nullable SPKTrimSourcePlan *)trimSourcePlanForMediaObject:(nullable id)mediaObject
                                                    photoURL:(nullable NSURL *)photoURL
                                                    videoURL:(nullable NSURL *)videoURL
                                             qualityOverride:(nullable NSString *)qualityOverride;

/// Presents the same quality picker the download flow uses (audio-only rows
/// excluded), reporting the chosen option as a trim plan, or nil if dismissed.
+ (void)presentTrimQualityPickerForMediaObject:(nullable id)mediaObject
                                      photoURL:(nullable NSURL *)photoURL
                                      videoURL:(nullable NSURL *)videoURL
                                          from:(UIViewController *)presenter
                                    completion:(void (^)(SPKTrimSourcePlan *_Nullable plan))completion;

+ (BOOL)handleDownloadDestination:(SPKDownloadDestination)destination
                       identifier:(NSString *)identifier
                        presenter:(nullable UIViewController *)presenter
                       sourceView:(nullable UIView *)sourceView
                      mediaObject:(nullable id)mediaObject
                         photoURL:(nullable NSURL *)photoURL
                         videoURL:(nullable NSURL *)videoURL
                  galleryMetadata:
                      (nullable SPKGallerySaveMetadata *)galleryMetadata
                     showProgress:(BOOL)showProgress
                    sourceSurface:(NSInteger)sourceSurface;

/// As above, but `qualityOverride` (`high` / `high_ignore_dash` / `medium` / `low`)
/// forces a tier instead of reading `downloads_video_quality` / `downloads_photo_quality`.
///
/// Auto-save needs this: the default video-quality preference is `always_ask`, which
/// would otherwise pop the quality picker mid-story. With an override this always
/// resolves to a concrete option, never presents a sheet, and needs no presenter.
/// Returns NO when the media yields no downloadable option.
+ (BOOL)handleDownloadDestination:(SPKDownloadDestination)destination
                       identifier:(NSString *)identifier
                        presenter:(nullable UIViewController *)presenter
                       sourceView:(nullable UIView *)sourceView
                      mediaObject:(nullable id)mediaObject
                         photoURL:(nullable NSURL *)photoURL
                         videoURL:(nullable NSURL *)videoURL
                  galleryMetadata:
                      (nullable SPKGallerySaveMetadata *)galleryMetadata
                     showProgress:(BOOL)showProgress
                    sourceSurface:(NSInteger)sourceSurface
                  qualityOverride:(nullable NSString *)qualityOverride;

+ (BOOL)handleCopyActionWithIdentifier:(NSString *)identifier
                             presenter:(nullable UIViewController *)presenter
                            sourceView:(nullable UIView *)sourceView
                           mediaObject:(nullable id)mediaObject
                              photoURL:(nullable NSURL *)photoURL
                              videoURL:(nullable NSURL *)videoURL
                       galleryMetadata:
                           (nullable SPKGallerySaveMetadata *)galleryMetadata
                          showProgress:(BOOL)showProgress
                         sourceSurface:(NSInteger)sourceSurface;

/// Cheap, context-agnostic "is this a video?" check (selector-probes the media
/// for a video duration / resolvable video URL — no DASH parse, no network).
/// Reliable where a resolved videoURL isn't available (feed-inline reels, DM
/// viewers) and correctly false for photos.
+ (BOOL)mediaObjectIsVideo:(nullable id)mediaObject;

+ (nullable NSURL *)resolvedURLForMediaObject:(nullable id)mediaObject
                                     photoURL:(nullable NSURL *)photoURL
                                     videoURL:(nullable NSURL *)videoURL
                              qualityOverride:(nullable NSString *)qualityOverride
                                  destination:(SPKDownloadDestination)destination;

/// The URL a "copy download link" action hands out, chosen by the same photo and video
/// quality preferences as a download. A link must be one playable file, so videos pick
/// among progressive variants only (DASH streams are video-only or need an FFmpeg merge).
/// `photoQualityOverride` (`max` / `high` / `medium` / `low`) replaces the photo
/// preference, which is how a batch quality prompt applies its choice. With no override
/// and no picker available, Always Ask resolves to the best tier. Falls back to
/// `videoURL` / `photoURL` when the media yields no option.
+ (nullable NSURL *)downloadLinkURLForMediaObject:(nullable id)mediaObject
                                         photoURL:(nullable NSURL *)photoURL
                                         videoURL:(nullable NSURL *)videoURL
                             photoQualityOverride:(nullable NSString *)photoQualityOverride;

/// Single-item copy-link flow: resolves like the method above, but when the relevant
/// quality preference is Always Ask it presents the quality sheet, limited to options
/// that are one playable file. `completion` runs with the chosen URL on the main queue,
/// and does not run when the sheet is dismissed without a choice.
+ (void)resolveDownloadLinkForMediaObject:(nullable id)mediaObject
                                 photoURL:(nullable NSURL *)photoURL
                                 videoURL:(nullable NSURL *)videoURL
                                presenter:(nullable UIViewController *)presenter
                               sourceView:(nullable UIView *)sourceView
                               completion:(void (^)(NSURL *_Nullable url))completion;

/// Picks the photo an "Edit & Save" opens, by `downloads_photo_quality`. When that is
/// Always Ask and the media has more than one candidate, presents the quality sheet.
/// `completion` runs on the main queue with the chosen URL, or nil if the sheet is
/// dismissed without a choice.
+ (void)resolveEditPhotoURLForMediaObject:(nullable id)mediaObject
                                 photoURL:(nullable NSURL *)photoURL
                                presenter:(nullable UIViewController *)presenter
                               completion:(void (^)(NSURL *_Nullable url))completion;

+ (UIViewController *)encodingSettingsViewController;
+ (NSArray *)encodingSettingsSearchSections;

/// DASH / FFmpeg pipeline (download + merge). `optionKind` uses
/// SPKMediaOptionKind values from SPKMediaQualityManager.m.
+ (void)
    runDashDownloadWithPrimaryURL:(NSURL *)primaryURL
                     secondaryURL:(nullable NSURL *)secondaryURL
                       optionKind:(NSInteger)optionKind
                         basename:(NSString *)basename
                         duration:(double)duration
                            width:(NSInteger)width
                           height:(NSInteger)height
                    sourceBitrate:(NSInteger)bandwidth
                        extension:(NSString *)extension
                         progress:(void (^)(float progress,
                                            NSString *_Nullable stageTitle,
                                            int64_t bytesWritten,
                                            int64_t totalBytesExpected))progress
                          failure:(void (^)(NSString *title,
                                            NSString *message))failure
                          success:(void (^)(NSURL *outputURL))success
                        cancelOut:
                            (void (^)(dispatch_block_t _Nullable cancelBlock))
                                cancelOut;

+ (BOOL)hasWebPhotoCandidatesFetchedForPK:(NSString *)pk;
+ (void)markWebPhotoCandidatesFetchedForPK:(NSString *)pk;
+ (nullable NSArray<NSDictionary *> *)webPhotoCandidatesForPK:(NSString *)pk;
+ (void)cacheWebCandidatesFromResponse:(NSDictionary *)response;

@end

NS_ASSUME_NONNULL_END
