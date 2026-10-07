#import "SPKStrings.h"
#import "SPKTrimSaveCoordinator.h"
#import "../../Utils.h"
#import "../Downloads/SPKDownloadDestinationWriter.h"
#import "../Downloads/SPKDownloadHelpers.h"
#import "../Downloads/SPKDownloadService.h"
#import "../Gallery/SPKGalleryFile.h"
#import "../Gallery/SPKGallerySaveMetadata.h"
#import "../Gallery/SPKGalleryViewController.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKNotificationCenter.h"
#import "SPKTrimRenderer.h"
#import "SPKTrimResult.h"

#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Presents the system "Save Audio to Files" (document export) sheet and reports
// the outcome back through the store completion. Retains itself until the picker
// finishes, since UIDocumentPickerViewController holds its delegate weakly.
@interface SPKTrimFilesExporter : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^done)(BOOL, NSString *);
@property (nonatomic, strong) SPKTrimFilesExporter *selfRef;
@end

@implementation SPKTrimFilesExporter
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.done)
        self.done(YES, SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_SAVED_FILES_TEXT"));
    self.selfRef = nil;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (self.done)
        self.done(YES, nil); // no error, just nothing saved
    self.selfRef = nil;
}
@end

@interface SPKTrimSaveCoordinator ()
+ (void)extractFrameFromURLs:(NSArray<NSURL *> *)urls
                   atSeconds:(NSTimeInterval)seconds
                    basename:(NSString *)basename
                  completion:(void (^)(NSURL *_Nullable, NSError *_Nullable))completion;
@end

// Records a trim/crop/edit save in Download History. Gallery trims bypass the
// download pipeline (they save straight to the Gallery), so without this they
// never appear in history. Quiet record: no pill, no duplicate preflight.
static void SPKRecordTrimSaveToHistory(NSURL *_Nullable rendered,
                                       SPKDownloadDestination destination,
                                       SPKGallerySaveMetadata *_Nullable metadata,
                                       NSString *_Nullable finalPath) {
    NSString *ext = rendered.pathExtension.length > 0 ? rendered.pathExtension
                                                      : finalPath.pathExtension;
    SPKDownloadMediaKind kind = [SPKDownloadHelpers mediaKindForExtension:ext ?: @""];
    SPKDownloadSourceSurface surface =
        [SPKDownloadHelpers resolvedSourceSurface:SPKDownloadSourceSurfaceOther metadata:metadata];
    [[SPKDownloadService shared] recordCompletedFileAtURL:rendered
                                                mediaKind:kind
                                              destination:destination
                                                 metadata:metadata
                                            sourceSurface:surface
                                                finalPath:finalPath];
}

@implementation SPKTrimSaveCoordinator

+ (void)saveResult:(SPKTrimResult *)result
        originFile:(SPKGalleryFile *)originFile
    fallbackSource:(SPKGallerySource)fallbackSource
        folderPath:(NSString *)folderPath
         presenter:(UIViewController *)presenter
        completion:(void (^)(BOOL))completion {
    SPKGalleryMediaType mediaType = SPKGalleryMediaTypeVideo;
    if (result.mode == SPKTrimResultModeFrameOnly) {
        mediaType = SPKGalleryMediaTypeImage;
    } else if (result.mode == SPKTrimResultModeTrimmedAudio) {
        mediaType = SPKGalleryMediaTypeAudio;
    }

    SPKTrimStoreBlock copyStore = ^(NSURL *rendered, void (^done)(BOOL, NSString *)) {
        SPKGallerySource source = originFile ? (SPKGallerySource)originFile.source : fallbackSource;
        NSString *folder = originFile ? originFile.folderPath : folderPath;
        // Carry the original's origin metadata onto the copy so its filename and
        // Open Profile/Post links match (otherwise it falls back to media_other_...).
        SPKGallerySaveMetadata *metadata = originFile ? [originFile saveMetadata] : nil;
        NSError *error = nil;
        SPKGalleryFile *saved = [SPKGalleryFile saveFileToGallery:rendered
                                                           source:source
                                                        mediaType:mediaType
                                                       folderPath:folder
                                                         metadata:metadata
                                                            error:&error];
        if (saved) {
            // The copy inherits the original's date via saveMetadata (for
            // filename/attribution), but should sort as the newest item — the
            // edit happened just now.
            [saved markAddedNow];
            SPKRecordTrimSaveToHistory(rendered, SPKDownloadDestinationGallery, metadata, saved.filePath);
            done(YES, (mediaType == SPKGalleryMediaTypeImage) ? SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_FRAME_SAVED_GALLERY_TEXT") : (mediaType == SPKGalleryMediaTypeAudio) ? SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_AUDIO_SAVED_GALLERY_TEXT")
                                                                                                                                    : SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_TRIMMED_CLIP_SAVED_GALLERY_TEXT"));
        } else {
            done(NO, error.localizedDescription ?: SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_COULD_NOT_SAVE_TRIMMED_FILE_TEXT"));
        }
    };

    BOOL shouldPrompt = (originFile != nil) && [SPKUtils getBoolPref:@"trim_gallery_prompt_replace"];
    if (!shouldPrompt) {
        [self renderResult:result
             progressTitle:nil
              existingPill:nil
                     store:copyStore
              onSuccessTap:^{
                  [SPKGalleryViewController presentGallery];
              }
                completion:completion];
        return;
    }

    SPKTrimStoreBlock replaceStore = ^(NSURL *rendered, void (^done)(BOOL, NSString *)) {
        NSError *error = nil;
        BOOL ok = [originFile replaceMediaWithFileURL:rendered mediaType:mediaType error:&error];
        if (ok) {
            // No staged preview copy: the replaced Gallery file itself backs
            // preview (and the Gallery fallback once it is gone).
            SPKGallerySaveMetadata *replacedMetadata = [originFile saveMetadata];
            SPKRecordTrimSaveToHistory(nil, SPKDownloadDestinationGallery, replacedMetadata, originFile.filePath);
        }
        done(ok, ok ? SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_ORIGINAL_REPLACED_TEXT") : (error.localizedDescription ?: SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_COULD_NOT_REPLACE_ORIGINAL_TEXT")));
    };

    NSString *title = (result.mode == SPKTrimResultModeFrameOnly) ? SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_SAVE_PHOTO_TEXT") : (result.mode == SPKTrimResultModeTrimmedAudio) ? SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_SAVE_AUDIO_TEXT")
                                                                                                                                   : SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_SAVE_TRIMMED_CLIP_TEXT");
    SPKIGAlertAction *copy = [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_SAVE_COPY")
                                                         style:SPKIGAlertActionStyleDefault
                                                       handler:^{
                                                           [self renderResult:result
                                                                progressTitle:nil
                                                                 existingPill:nil
                                                                        store:copyStore
                                                                 onSuccessTap:^{
                                                                     [SPKGalleryViewController presentGallery];
                                                                 }
                                                                   completion:completion];
                                                       }];
    SPKIGAlertAction *replace = [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_REPLACE_ORIGINAL")
                                                            style:SPKIGAlertActionStyleDestructive
                                                          handler:^{
                                                              [self renderResult:result
                                                                   progressTitle:nil
                                                                    existingPill:nil
                                                                           store:replaceStore
                                                                    onSuccessTap:^{
                                                                        [SPKGalleryViewController presentGallery];
                                                                    }
                                                                      completion:completion];
                                                          }];
    SPKIGAlertAction *cancel = [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                           style:SPKIGAlertActionStyleCancel
                                                         handler:^{
                                                             if (completion)
                                                                 completion(NO);
                                                         }];

    BOOL presented = [SPKIGAlertPresenter presentActionSheetFromViewController:presenter
                                                                         title:title
                                                                       message:SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_REPLACE_ORIGINAL_FILE_SAVE_COPY_CONFIRMATION_MESSAGE")
                                                                       actions:@[ replace, copy, cancel ]];
    if (!presented) {
        [self renderResult:result
             progressTitle:nil
              existingPill:nil
                     store:copyStore
              onSuccessTap:^{
                  [SPKGalleryViewController presentGallery];
              }
                completion:completion];
    }
}

#pragma mark - Edited image

+ (void)saveEditedImage:(UIImage *)image
             originFile:(SPKGalleryFile *)originFile
         fallbackSource:(SPKGallerySource)fallbackSource
             folderPath:(NSString *)folderPath
              presenter:(UIViewController *)presenter
             completion:(void (^)(BOOL))completion {
    NSURL *tempURL = [self writeEditedImageToTemp:image];
    if (!tempURL) {
        SPKNotify(@"spk.photoedit.save", SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_COULDN_T_SAVE_TEXT"),
                  SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_EDITED_IMAGE_COULD_NOT_ENCODED_TEXT"), @"error_filled",
                  SPKNotificationToneError);
        if (completion)
            completion(NO);
        return;
    }
    // Route through the shared trim save path: a frame-only result with its output
    // already rendered (renderResult: short-circuits on a pre-filled outputURL), so
    // the Replace/Save-as-Copy prompt, the progress→success pill, and cleanup are
    // all identical to a trimmed frame's save.
    SPKTrimResult *result = [SPKTrimResult requestWithMode:SPKTrimResultModeFrameOnly
                                                 sourceURL:tempURL
                                              startSeconds:0.0
                                           durationSeconds:0.0];
    result.outputURL = tempURL;
    [self saveResult:result
            originFile:originFile
        fallbackSource:fallbackSource
            folderPath:folderPath
             presenter:presenter
            completion:completion];
}

+ (void)routeEditedImage:(UIImage *)image
           toDestination:(NSString *)destination
                metadata:(SPKGallerySaveMetadata *)metadata
               presenter:(UIViewController *)presenter
              completion:(void (^)(BOOL))completion {
    NSURL *tempURL = [self writeEditedImageToTemp:image];
    if (!tempURL) {
        SPKNotify(@"spk.photoedit.save", SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_COULDN_T_SAVE_TEXT"),
                  SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_EDITED_IMAGE_COULD_NOT_ENCODED_TEXT"), @"error_filled",
                  SPKNotificationToneError);
        if (completion)
            completion(NO);
        return;
    }
    // Frame-only result with its output already rendered (renderResult:
    // short-circuits on a pre-filled outputURL), so the destination routing +
    // progress/success pill are identical to a trimmed frame's save.
    SPKTrimResult *result = [SPKTrimResult requestWithMode:SPKTrimResultModeFrameOnly
                                                 sourceURL:tempURL
                                              startSeconds:0.0
                                           durationSeconds:0.0];
    result.outputURL = tempURL;
    [self routeResult:result
        toDestination:destination
             metadata:metadata
            presenter:presenter
         existingPill:nil
           completion:completion];
}

// Encodes an edited image to a unique temp JPEG. Returns nil on failure.
+ (NSURL *)writeEditedImageToTemp:(UIImage *)image {
    NSData *data = image ? UIImageJPEGRepresentation(image, 0.85) : nil;
    if (!data)
        return nil;
    NSString *name = [[[NSProcessInfo processInfo] globallyUniqueString] stringByAppendingPathExtension:@"jpg"];
    NSURL *tempURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
    if (![data writeToURL:tempURL options:NSDataWritingAtomic error:NULL])
        return nil;
    return tempURL;
}

#pragma mark - Destination routing

+ (void)routeResult:(SPKTrimResult *)result
      toDestination:(NSString *)destination
           metadata:(SPKGallerySaveMetadata *)metadata
          presenter:(UIViewController *)presenter
       existingPill:(SPKNotificationPillView *)existingPill
         completion:(void (^)(BOOL))completion {
    SPKGalleryMediaType mediaType = SPKGalleryMediaTypeVideo;
    if (result.mode == SPKTrimResultModeFrameOnly) {
        mediaType = SPKGalleryMediaTypeImage;
    } else if (result.mode == SPKTrimResultModeTrimmedAudio) {
        mediaType = SPKGalleryMediaTypeAudio;
    }

    SPKTrimStoreBlock store;
    if ([destination isEqualToString:@"photos"]) {
        store = ^(NSURL *rendered, SPKTrimStoreCompletion done) {
            [SPKDownloadDestinationWriter saveFileURLToPhotos:rendered
                                                     metadata:metadata
                                                   completion:^(BOOL ok, NSError *error) {
                                                       dispatch_async(dispatch_get_main_queue(), ^{
                                                           if (ok)
                                                               SPKRecordTrimSaveToHistory(rendered, SPKDownloadDestinationPhotos, metadata, nil);
                                                           done(ok, ok ? SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_SAVED_PHOTOS_TEXT") : (error.localizedDescription ?: SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_COULD_NOT_SAVE_PHOTOS_TEXT")));
                                                       });
                                                   }];
        };
    } else if ([destination isEqualToString:@"clipboard"]) {
        store = ^(NSURL *rendered, SPKTrimStoreCompletion done) {
            NSString *ext = rendered.pathExtension.lowercaseString;
            BOOL isVideo = [ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"];
            BOOL isAudio = [ext isEqualToString:@"m4a"] || [ext isEqualToString:@"mp3"] || [ext isEqualToString:@"wav"] || [ext isEqualToString:@"aac"];
            if (isVideo) {
                NSData *data = [NSData dataWithContentsOfURL:rendered options:NSDataReadingMappedIfSafe error:nil];
                if (data) {
                    [UIPasteboard generalPasteboard].items = @[ @{UTTypeMovie.identifier : data} ];
                    done(YES, SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_COPIED_CLIP_CLIPBOARD_TEXT"));
                } else {
                    done(NO, SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_COULD_NOT_COPY_CLIP_TEXT"));
                }
            } else if (isAudio) {
                NSData *data = [NSData dataWithContentsOfURL:rendered options:NSDataReadingMappedIfSafe error:nil];
                if (data) {
                    [UIPasteboard generalPasteboard].items = @[ @{UTTypeAudio.identifier : data} ];
                    done(YES, SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_COPIED_AUDIO_CLIPBOARD_TEXT"));
                } else {
                    done(NO, SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_COULD_NOT_COPY_AUDIO_TEXT"));
                }
            } else {
                UIImage *image = [UIImage imageWithContentsOfFile:rendered.path];
                if (image) {
                    [[UIPasteboard generalPasteboard] setImage:image];
                    done(YES, SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_COPIED_FRAME_CLIPBOARD_TEXT"));
                } else {
                    done(NO, SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_COULD_NOT_COPY_FRAME_TEXT"));
                }
            }
        };
    } else if ([destination isEqualToString:@"files"]) {
        store = ^(NSURL *rendered, SPKTrimStoreCompletion done) {
            UIViewController *host = presenter ?: topMostController();
            if (!host) {
                done(NO, SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_COULD_NOT_PRESENT_FILES_PICKER_TEXT"));
                return;
            }
            SPKTrimFilesExporter *exporter = [SPKTrimFilesExporter new];
            exporter.done = done;
            exporter.selfRef = exporter;
            // asCopy:YES so the picker copies our temp file; the temp is cleaned up
            // by renderResult once `done` fires (after the export completes).
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                initForExportingURLs:@[ rendered ]
                              asCopy:YES];
            picker.delegate = exporter;
            picker.shouldShowFileExtensions = YES;
            if (picker.popoverPresentationController) {
                picker.popoverPresentationController.sourceView = host.view;
                picker.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(host.view.bounds),
                                                                             CGRectGetMidY(host.view.bounds), 1, 1);
                picker.popoverPresentationController.permittedArrowDirections = 0;
            }
            [host presentViewController:picker animated:YES completion:nil];
        };
    } else if ([destination isEqualToString:@"share"]) {
        store = ^(NSURL *rendered, SPKTrimStoreCompletion done) {
            UIViewController *host = presenter ?: topMostController();
            if (!host) {
                done(NO, SPKL(@"DOWNLOADS_DOWNLOAD_DESTINATION_WRITER_COULD_NOT_PRESENT_SHARE_SHEET_TEXT"));
                return;
            }
            UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[ rendered ]
                                                                             applicationActivities:nil];
            vc.completionWithItemsHandler = ^(UIActivityType _Nullable type, BOOL completed,
                                              NSArray *_Nullable items, NSError *_Nullable err) {
                done(YES, completed ? SPKL(@"DOWNLOADS_DOWNLOAD_PRESENTER_SHARED_TEXT") : nil);
            };
            if (vc.popoverPresentationController) {
                vc.popoverPresentationController.sourceView = host.view;
                vc.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(host.view.bounds),
                                                                         CGRectGetMidY(host.view.bounds), 1, 1);
                vc.popoverPresentationController.permittedArrowDirections = 0;
            }
            [host presentViewController:vc animated:YES completion:nil];
        };
    } else {
        store = ^(NSURL *rendered, SPKTrimStoreCompletion done) {
            SPKGallerySource source = metadata ? (SPKGallerySource)metadata.source : SPKGallerySourceOther;
            NSError *error = nil;
            SPKGalleryFile *saved = [SPKGalleryFile saveFileToGallery:rendered
                                                               source:source
                                                            mediaType:mediaType
                                                           folderPath:nil
                                                             metadata:metadata
                                                                error:&error];
            if (saved) {
                SPKRecordTrimSaveToHistory(rendered, SPKDownloadDestinationGallery, metadata, saved.filePath);
                done(YES, (mediaType == SPKGalleryMediaTypeImage) ? SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_FRAME_SAVED_GALLERY_TEXT") : (mediaType == SPKGalleryMediaTypeAudio) ? SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_AUDIO_SAVED_GALLERY_TEXT")
                                                                                                                                        : SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_TRIMMED_CLIP_SAVED_GALLERY_TEXT"));
            } else
                done(NO, error.localizedDescription ?: SPKL(@"DOWNLOADS_DOWNLOAD_DESTINATION_WRITER_COULD_NOT_SAVE_GALLERY_TEXT"));
        };
    }

    void (^onSuccessTap)(void) = nil;
    if ([destination isEqualToString:@"gallery"]) {
        onSuccessTap = ^{
            [SPKGalleryViewController presentGallery];
        };
    } else if ([destination isEqualToString:@"photos"]) {
        onSuccessTap = ^{
            [SPKUtils openPhotosApp];
        };
    }

    // Name the render with the standard scheme so Save Audio to Files / Share Audio carry
    // a proper filename instead of the temp UUID (Gallery renames on import anyway).
    if (!result.preferredBasename.length) {
        result.preferredBasename = [SPKFileNameForMedia(result.sourceURL, mediaType, metadata) stringByDeletingPathExtension];
    }

    [self renderResult:result
         progressTitle:nil
          existingPill:existingPill
                 store:store
          onSuccessTap:onSuccessTap
            completion:completion];
}

#pragma mark - Background render

// Renders in the background behind a progress pill (cancellable), then stores
// the output. The app stays usable throughout.
+ (void)renderResult:(SPKTrimResult *)result
       progressTitle:(NSString *)progressTitle
        existingPill:(SPKNotificationPillView *)existingPill
               store:(SPKTrimStoreBlock)store
        onSuccessTap:(void (^)(void))onSuccessTap
          completion:(void (^)(BOOL))completion {
    BOOL isFrameOnly = (result.mode == SPKTrimResultModeFrameOnly);
    BOOL isAudio = (result.mode == SPKTrimResultModeTrimmedAudio);
    // Prefer the caller-supplied name (epoch_user_source_date) so Files/Share
    // exports don't leak the temp UUID; fall back to a unique temp name.
    NSString *basename = result.preferredBasename.length
                             ? result.preferredBasename
                             : [NSString stringWithFormat:@"SPKTrim-%@", NSUUID.UUID.UUIDString];
    NSString *title = progressTitle.length > 0 ? progressTitle
                                               : (isFrameOnly ? SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_EXTRACTING_FRAME_TEXT") : (isAudio ? SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_TRIMMING_AUDIO_TEXT") : SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_TRIMMING_TEXT")));

    // Continue an in-flight pill (e.g. from a preceding download) instead of
    // stacking a second notification.
    SPKNotificationPillView *pill = existingPill;
    if (pill) {
        [pill updateProgressTitle:title subtitle:nil];
        [pill setProgress:0.0f animated:NO];
    } else {
        pill = [[SPKNotificationCenter shared] beginUnmanagedProgressWithTitle:title onCancel:nil];
    }

    __block dispatch_block_t cancelRender = nil;
    __block BOOL cancelled = NO;
    __weak SPKNotificationPillView *weakPill = pill;
    pill.onCancel = ^{
        // Confirm first (mirrors the download cancel). The pill's close button
        // calls onCancel without dismissing, so dismiss on confirm.
        [SPKTrimSaveCoordinator confirmCancelThen:^{
            cancelled = YES;
            if (cancelRender)
                cancelRender();
            [weakPill dismiss];
        }];
    };

    void (^onRendered)(NSURL *, NSError *) = ^(NSURL *renderedURL, NSError *error) {
        if (cancelled) {
            if (renderedURL)
                [[NSFileManager defaultManager] removeItemAtURL:renderedURL error:nil];
            if (completion)
                completion(NO);
            return;
        }
        if (!renderedURL) {
            // The reason goes in the subtitle so the pill always leads with what
            // failed; an encoder message is too long to read as a title.
            [pill showErrorWithTitle:SPKL(@"MEDIA_TRIM_TRIM_EDITOR_TRIM_FAILED_TEXT") subtitle:error.localizedDescription icon:nil];
            if (completion)
                completion(NO);
            return;
        }
        store(renderedURL, ^(BOOL ok, NSString *message) {
            [[NSFileManager defaultManager] removeItemAtURL:renderedURL error:nil];
            if (ok) {
                [pill showSuccessWithTitle:message subtitle:(onSuccessTap ? SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_TAP_VIEW_TEXT") : nil)icon:nil];
                if (onSuccessTap)
                    pill.onTapWhenCompleted = onSuccessTap;
            } else {
                [pill showError:message ?: SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_SAVE_FAILED_TEXT")];
            }
            if (completion)
                completion(ok);
        });
    };

    void (^progressToPill)(double) = ^(double p) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [pill setProgress:(float)MAX(0.0, MIN(1.0, p)) animated:YES];
        });
    };

    // Pre-rendered output (e.g. a frame the user edited in the photo editor):
    // skip extraction/encoding and hand the existing file straight to `store`, so
    // the whole save/route pipeline (Gallery copy/replace, destination menu, the
    // progress pill) runs unchanged.
    if (result.outputURL && [[NSFileManager defaultManager] fileExistsAtPath:result.outputURL.path]) {
        onRendered(result.outputURL, nil);
        return;
    }

    if (isFrameOnly) {
        // Extract from the chosen-quality video when overridden, else the edit
        // file. The chosen-quality DASH source is often AV1, which AVFoundation
        // can't decode on most devices, so the renderer retries it with FFmpeg.
        // The muxed edit file the user scrubbed (lower resolution) is the last
        // resort, used only when both decoders fail on the full-quality file.
        NSMutableArray<NSURL *> *frameSources = [NSMutableArray array];
        if (result.renderVideoURL)
            [frameSources addObject:result.renderVideoURL];
        if (result.sourceURL && ![result.sourceURL isEqual:result.renderVideoURL]) {
            [frameSources addObject:result.sourceURL];
        }
        [self extractFrameFromURLs:frameSources
                         atSeconds:result.startSeconds
                          basename:basename
                        completion:onRendered];
    } else if (isAudio) {
        // Audio-only trim → native AAC .m4a via AVAssetExportSession.
        [SPKTrimRenderer renderTrimAudioForSourceURL:(result.renderAudioURL ?: result.sourceURL)
                                               asset:nil
                                        startSeconds:result.startSeconds
                                     durationSeconds:result.durationSeconds
                                            basename:basename
                                          completion:onRendered];
    } else if (result.renderAudioURL) {
        // DASH: merge the chosen-quality video + audio over the selected range.
        [SPKTrimRenderer renderTrimMergeForVideoURL:result.renderVideoURL
                                           audioURL:result.renderAudioURL
                                       startSeconds:result.startSeconds
                                    durationSeconds:result.durationSeconds
                                               crop:result.crop
                                              width:result.width
                                             height:result.height
                                           basename:basename
                                           progress:progressToPill
                                         completion:onRendered
                                          cancelOut:^(dispatch_block_t cancel) {
                                              cancelRender = cancel;
                                          }];
    } else {
        [SPKTrimRenderer renderTrimForSourceURL:(result.renderVideoURL ?: result.sourceURL)
                                          asset:nil
                                   startSeconds:result.startSeconds
                                durationSeconds:result.durationSeconds
                                           crop:result.crop
                                       basename:basename
                                       progress:progressToPill
                                     completion:onRendered
                                      cancelOut:^(dispatch_block_t cancel) {
                                          cancelRender = cancel;
                                      }];
    }
}

#pragma mark - Frame extraction (with source fallback)

// Tries each candidate URL in order, returning the first frame that decodes.
// Lets us prefer the chosen-quality video but fall back to the muxed edit file
// when neither AVFoundation nor FFmpeg can pull a still from it.
+ (void)extractFrameFromURLs:(NSArray<NSURL *> *)urls
                   atSeconds:(NSTimeInterval)seconds
                    basename:(NSString *)basename
                  completion:(void (^)(NSURL *_Nullable, NSError *_Nullable))completion {
    if (urls.count == 0) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"Sparkle.TrimSave"
                                                code:1
                                            userInfo:@{NSLocalizedDescriptionKey : SPKL(@"MEDIA_TRIM_TRIM_RENDERER_COULD_NOT_EXTRACT_SELECTED_FRAME_TEXT")}]);
        }
        return;
    }
    [SPKTrimRenderer renderFrameForVideoURL:urls.firstObject
                                  atSeconds:seconds
                                   basename:basename
                                 completion:^(NSURL *output, NSError *error) {
                                     if (output) {
                                         if (completion)
                                             completion(output, nil);
                                         return;
                                     }
                                     if (urls.count <= 1) {
                                         if (completion)
                                             completion(nil, error);
                                         return;
                                     }
                                     [self extractFrameFromURLs:[urls subarrayWithRange:NSMakeRange(1, urls.count - 1)]
                                                      atSeconds:seconds
                                                       basename:basename
                                                     completion:completion];
                                 }];
}

#pragma mark - Cancel confirmation

+ (void)confirmCancelThen:(void (^)(void))onConfirm {
    UIViewController *host = topMostController();
    if (!host) {
        if (onConfirm)
            onConfirm();
        return;
    }
    SPKIGAlertAction *keep = [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CONTINUE")
                                                         style:SPKIGAlertActionStyleCancel
                                                       handler:nil];
    SPKIGAlertAction *stop = [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_STOP")
                                                         style:SPKIGAlertActionStyleDestructive
                                                       handler:^{
                                                           if (onConfirm)
                                                               onConfirm();
                                                       }];
    [SPKIGAlertPresenter presentAlertFromViewController:host
                                                  title:SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_CANCEL_TRIM_TEXT")
                                                message:SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_STOP_TRIMMING_DISCARD_PROGRESS_QUESTION")
                                                actions:@[ keep, stop ]];
}

@end
