#import "SPKStrings.h"
#import "SPKAudioDMUploadCoordinator.h"

#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "../../Utils.h"
#import "../Gallery/SPKGalleryFile.h"
#import "../Gallery/SPKGalleryPickerViewController.h"
#import "../MediaTrim/SPKTrimConfiguration.h"
#import "../MediaTrim/SPKTrimEditorViewController.h"
#import "../MediaTrim/SPKTrimRenderer.h"
#import "../MediaTrim/SPKTrimResult.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKNotificationCenter.h"

@interface SPKAudioDMUploadCoordinator () <UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) id senderTarget;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, strong) SPKNotificationPillView *progressView;
// Set by the progress pill's cancel. The conversion is stopped, and every later
// step checks this before going on, so nothing is sent.
@property (nonatomic) BOOL cancelled;
@property (nonatomic, strong) AVAssetExportSession *exportSession;
- (void)sendConvertedURL:(NSURL *)url duration:(NSTimeInterval)duration waveform:(id)waveform;
@end

static SPKAudioDMUploadCoordinator *sSPKAudioActiveDMUploadCoordinator;

extern void SPKDMConfirmVoiceMessageIfNeeded(void (^confirmBlock)(void), void (^cancelBlock)(void));

static SEL SPKAudioDMSendSelector(void) {
    return NSSelectorFromString(@"sendAudioWithURL:waveform:duration:entryPoint:aiVoiceEffectApplied:aiVoiceEffectType:messageID:quotedPublishedMessage:");
}

static SEL SPKAudioDMSendLegacySelector(void) {
    return NSSelectorFromString(@"sendAudioWithURL:waveform:duration:entryPoint:messageID:quotedPublishedMessage:");
}

static SEL SPKAudioDMVoiceSelector(void) {
    return NSSelectorFromString(@"voiceRecordViewController:didRecordAudioClipWithURL:waveform:duration:entryPoint:aiVoiceEffectApplied:aiVoiceEffectType:sendButtonTypeTapped:");
}

static SEL SPKAudioDMVoiceLegacySelector(void) {
    return NSSelectorFromString(@"voiceRecordViewController:didRecordAudioClipWithURL:waveform:duration:entryPoint:sendButtonTypeTapped:");
}

static NSURL *SPKAudioDMTemporaryURL(NSString *extension) {
    NSString *name = [NSString stringWithFormat:@"sparkle-dm-audio-%@.%@",
                                                NSUUID.UUID.UUIDString,
                                                extension.length ? extension : @"m4a"];
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
}

static id SPKAudioDMCreateWaveformWithSamples(NSArray<NSNumber *> *averageVolume, NSTimeInterval duration) {
    Class waveformClass = NSClassFromString(@"IGDirectAudioWaveform");
    SEL initializer = NSSelectorFromString(@"initWithVolumeRecordingInterval:averageVolume:");
    if (averageVolume.count == 0 || !waveformClass || ![waveformClass instancesRespondToSelector:initializer])
        return nil;

    double interval = (isfinite(duration) && duration > 0.0) ? MAX(duration / (double)averageVolume.count, 0.02) : 0.1;
    id waveform = ((id (*)(id, SEL, double, id))objc_msgSend)([waveformClass alloc],
                                                              initializer,
                                                              interval,
                                                              averageVolume);
    return [waveform respondsToSelector:@selector(averageVolume)] ? waveform : nil;
}

// Instagram records waveform levels at roughly 10 Hz. Decode the final file we
// hand to its sender so imported and trimmed clips describe their real audio
// instead of using a decorative pattern unrelated to the sound.
static void SPKAudioDMSampleWaveform(NSURL *audioURL, NSTimeInterval duration,
                                     void (^completion)(NSArray<NSNumber *> *samples)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:audioURL options:nil];
            AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
            if (!track) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
                return;
            }

            NSTimeInterval resolvedDuration = duration;
            if (!isfinite(resolvedDuration) || resolvedDuration <= 0.0)
                resolvedDuration = CMTimeGetSeconds(asset.duration);
            if (!isfinite(resolvedDuration) || resolvedDuration <= 0.0)
                resolvedDuration = CMTimeGetSeconds(track.timeRange.duration);

            NSInteger bucketCount = MAX((NSInteger)10, MIN((NSInteger)ceil(MAX(resolvedDuration, 1.0) * 10.0), (NSInteger)300));
            double *sumSquares = calloc((size_t)bucketCount, sizeof(double));
            uint64_t *valueCounts = calloc((size_t)bucketCount, sizeof(uint64_t));
            if (!sumSquares || !valueCounts) {
                free(sumSquares);
                free(valueCounts);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
                return;
            }

            NSError *readerError = nil;
            AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
            NSDictionary *settings = @{
                AVFormatIDKey : @(kAudioFormatLinearPCM),
                AVLinearPCMBitDepthKey : @16,
                AVLinearPCMIsBigEndianKey : @NO,
                AVLinearPCMIsFloatKey : @NO,
                AVLinearPCMIsNonInterleaved : @NO,
            };
            AVAssetReaderTrackOutput *output = reader ? [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings] : nil;
            output.alwaysCopiesSampleData = NO;
            if (!reader || !output || ![reader canAddOutput:output]) {
                free(sumSquares);
                free(valueCounts);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
                return;
            }
            [reader addOutput:output];
            if (![reader startReading]) {
                free(sumSquares);
                free(valueCounts);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
                return;
            }

            double sampleRate = 44100.0;
            UInt32 channelCount = 1;
            CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
            if (format) {
                const AudioStreamBasicDescription *description = CMAudioFormatDescriptionGetStreamBasicDescription(format);
                if (description) {
                    if (description->mSampleRate > 0.0)
                        sampleRate = description->mSampleRate;
                    if (description->mChannelsPerFrame > 0)
                        channelCount = description->mChannelsPerFrame;
                }
            }

            int64_t estimatedValueCount = (int64_t)(MAX(resolvedDuration, 0.0) * sampleRate * channelCount);
            if (estimatedValueCount <= 0)
                estimatedValueCount = bucketCount;

            int64_t valueIndex = 0;
            while (reader.status == AVAssetReaderStatusReading) {
                CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
                if (!sampleBuffer)
                    break;
                CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
                if (block) {
                    size_t byteLength = CMBlockBufferGetDataLength(block);
                    size_t valueCount = byteLength / sizeof(int16_t);
                    int16_t *values = valueCount > 0 ? malloc(byteLength) : NULL;
                    if (values && CMBlockBufferCopyDataBytes(block, 0, byteLength, values) == kCMBlockBufferNoErr) {
                        for (size_t i = 0; i < valueCount; i++) {
                            NSInteger bucket = (NSInteger)((valueIndex * bucketCount) / estimatedValueCount);
                            bucket = MAX((NSInteger)0, MIN(bucket, bucketCount - 1));
                            double amplitude = (double)values[i] / 32768.0;
                            sumSquares[bucket] += amplitude * amplitude;
                            valueCounts[bucket]++;
                            valueIndex++;
                        }
                    }
                    free(values);
                }
                CMSampleBufferInvalidate(sampleBuffer);
                CFRelease(sampleBuffer);
            }

            BOOL readSucceeded = reader.status == AVAssetReaderStatusCompleted && valueIndex > 0;
            NSMutableArray<NSNumber *> *samples = readSucceeded ? [NSMutableArray arrayWithCapacity:(NSUInteger)bucketCount] : nil;
            double maximum = 0.0;
            if (readSucceeded) {
                for (NSInteger i = 0; i < bucketCount; i++) {
                    double rms = valueCounts[i] > 0 ? sqrt(sumSquares[i] / (double)valueCounts[i]) : 0.0;
                    [samples addObject:@(rms)];
                    maximum = MAX(maximum, rms);
                }
                if (maximum > 0.0) {
                    for (NSInteger i = 0; i < bucketCount; i++) {
                        // Normalize each clip while retaining its real dynamics;
                        // light gamma keeps quieter details visible in the bubble.
                        double normalized = pow(samples[i].doubleValue / maximum, 0.65);
                        samples[i] = @(normalized);
                    }
                }
            }
            free(sumSquares);
            free(valueCounts);

            dispatch_async(dispatch_get_main_queue(), ^{ completion(samples); });
        }
    });
}

static NSArray<NSNumber *> *SPKAudioDMFallbackWaveformSamples(NSTimeInterval duration) {
    NSInteger count = MAX((NSInteger)10, MIN((NSInteger)ceil(MAX(duration, 1.0) * 10.0), (NSInteger)300));
    NSMutableArray<NSNumber *> *samples = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (NSInteger i = 0; i < count; i++)
        [samples addObject:@(0.12)];
    return samples;
}

static id SPKAudioDMIvarValue(id object, const char *name) {
    if (!object || !name)
        return nil;
    @try {
        for (Class cls = [object class]; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
            Ivar ivar = class_getInstanceVariable(cls, name);
            if (!ivar)
                continue;
            const char *encoding = ivar_getTypeEncoding(ivar);
            if (encoding && encoding[0] == '@')
                return object_getIvar(object, ivar);
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static id SPKAudioDMCall(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector])
        return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id SPKAudioDMThreadContextFromTarget(id target) {
    return SPKAudioDMCall(target, @"threadViewControllerContext") ?: SPKAudioDMIvarValue(target, "_threadViewControllerContext");
}

static id SPKAudioDMVoiceControllerFromTarget(id target) {
    id voiceController = SPKAudioDMCall(target, @"voiceController") ?: SPKAudioDMIvarValue(target, "_voiceController");
    if (voiceController)
        return voiceController;

    id threadContext = SPKAudioDMThreadContextFromTarget(target);
    voiceController = SPKAudioDMCall(threadContext, @"voiceController") ?: SPKAudioDMIvarValue(threadContext, "_voiceController");
    if (voiceController)
        return voiceController;

    id featureDelegate = SPKAudioDMCall(target, @"featureDelegate") ?: SPKAudioDMIvarValue(target, "_featureDelegate");
    voiceController = SPKAudioDMCall(featureDelegate, @"voiceController") ?: SPKAudioDMIvarValue(featureDelegate, "_voiceController");
    if (voiceController)
        return voiceController;

    id composerTapHandler = SPKAudioDMCall(featureDelegate, @"composerTapHandler") ?: SPKAudioDMIvarValue(featureDelegate, "_composerTapHandler");
    return SPKAudioDMCall(composerTapHandler, @"voiceController") ?: SPKAudioDMIvarValue(composerTapHandler, "_voiceController");
}

static id SPKAudioDMMessageSenderFromTarget(id target) {
    id sender = SPKAudioDMCall(target, @"messageSenderFeatureController") ?: SPKAudioDMIvarValue(target, "_messageSenderFeatureController");
    if (sender)
        return sender;

    id threadContext = SPKAudioDMThreadContextFromTarget(target);
    sender = SPKAudioDMCall(threadContext, @"messageSenderFeatureController") ?: SPKAudioDMIvarValue(threadContext, "_messageSenderFeatureController");
    if (sender)
        return sender;

    id featureDelegate = SPKAudioDMCall(target, @"featureDelegate") ?: SPKAudioDMIvarValue(target, "_featureDelegate");
    return SPKAudioDMCall(featureDelegate, @"messageSenderFeatureController") ?: SPKAudioDMIvarValue(featureDelegate, "_messageSenderFeatureController");
}

static void SPKAudioDMNotify(NSString *title, NSString *message, BOOL success) {
    SPKNotify(kSPKNotificationDownloadShare,
              title,
              message,
              success ? @"checkmark_circle" : @"error_filled",
              success ? SPKNotificationToneSuccess : SPKNotificationToneError);
}

@implementation SPKAudioDMUploadCoordinator

+ (BOOL)senderTargetSupportsAudioUpload:(id)senderTarget {
    id voiceController = SPKAudioDMVoiceControllerFromTarget(senderTarget);
    SEL voiceSelector = SPKAudioDMVoiceSelector();
    SEL voiceLegacySelector = SPKAudioDMVoiceLegacySelector();
    if (voiceController && ([voiceController respondsToSelector:voiceSelector] || [voiceController respondsToSelector:voiceLegacySelector]))
        return YES;

    id sender = SPKAudioDMMessageSenderFromTarget(senderTarget) ?: senderTarget;
    return sender && ([sender respondsToSelector:SPKAudioDMSendSelector()] || [sender respondsToSelector:SPKAudioDMSendLegacySelector()]);
}

// Shared setup for both entry points: returns the retained coordinator, or nil
// when this build has no reachable audio sender.
+ (SPKAudioDMUploadCoordinator *)coordinatorForSenderTarget:(id)senderTarget
                                                  presenter:(UIViewController *)presenter
                                                 sourceView:(UIView *)sourceView {
    if (![self senderTargetSupportsAudioUpload:senderTarget] || !presenter) {
        SPKAudioDMNotify(SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_UPLOAD_UNAVAILABLE_TEXT"), SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_INSTAGRAM_BUILD_NOT_EXPOSE_DIRECT_AUDIO_SENDER_TEXT"), NO);
        SPKWarnLog(@"AudioUpload", @"Missing direct audio sender on target: %@", senderTarget);
        return nil;
    }

    SPKAudioDMUploadCoordinator *coordinator = [[SPKAudioDMUploadCoordinator alloc] init];
    coordinator.senderTarget = senderTarget;
    coordinator.presenter = presenter;
    coordinator.sourceView = sourceView ?: presenter.view;
    sSPKAudioActiveDMUploadCoordinator = coordinator;
    return coordinator;
}

+ (void)presentUploadPickerForSource:(SPKAudioDMUploadSource)source
                        senderTarget:(id)senderTarget
                           presenter:(UIViewController *)presenter
                          sourceView:(UIView *)sourceView {
    SPKAudioDMUploadCoordinator *coordinator = [self coordinatorForSenderTarget:senderTarget
                                                                      presenter:presenter
                                                                     sourceView:sourceView];
    if (!coordinator)
        return;

    switch (source) {
        case SPKAudioDMUploadSourcePhotos:
            [coordinator presentLibraryPicker];
            break;
        case SPKAudioDMUploadSourceGallery:
            [coordinator presentGalleryPicker];
            break;
        case SPKAudioDMUploadSourceFiles:
            [coordinator presentFilesPicker];
            break;
    }
}

+ (void)presentUploadPickerForSenderTarget:(id)senderTarget
                                 presenter:(UIViewController *)presenter
                                sourceView:(UIView *)sourceView {
    SPKAudioDMUploadCoordinator *coordinator = [self coordinatorForSenderTarget:senderTarget
                                                                      presenter:presenter
                                                                     sourceView:sourceView];
    if (!coordinator)
        return;

    [SPKIGAlertPresenter presentActionSheetFromViewController:presenter
                                                        title:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_SEND_AUDIO_MESSAGE")
                                                      message:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_CHOOSE_AUDIO_VIDEO_FILE_CONVERT_SEND_VOICE_NOTE_TEXT")
                                                      actions:@[
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_SELECT_PHOTOS")
                                                                                      style:SPKIGAlertActionStyleDefault
                                                                                    handler:^{
                                                                                        [coordinator presentLibraryPicker];
                                                                                    }],
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_SELECT_GALLERY")
                                                                                      style:SPKIGAlertActionStyleDefault
                                                                                    handler:^{
                                                                                        [coordinator presentGalleryPicker];
                                                                                    }],
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_SELECT_FILES")
                                                                                      style:SPKIGAlertActionStyleDefault
                                                                                    handler:^{
                                                                                        [coordinator presentFilesPicker];
                                                                                    }],
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                      style:SPKIGAlertActionStyleCancel
                                                                                    handler:^{
                                                                                        if (sSPKAudioActiveDMUploadCoordinator == coordinator)
                                                                                            sSPKAudioActiveDMUploadCoordinator = nil;
                                                                                    }]
                                                      ]];
}

- (void)presentFilesPicker {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.audio", @"public.movie", @"public.mpeg-4" ]
                                                                                                    inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    picker.popoverPresentationController.sourceView = self.sourceView ?: self.presenter.view;
    picker.popoverPresentationController.sourceRect = self.sourceView ? self.sourceView.bounds : self.presenter.view.bounds;
    [self.presenter presentViewController:picker animated:YES completion:nil];
}

- (void)presentLibraryPicker {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
        SPKAudioDMNotify(SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_LIBRARY_UNAVAILABLE_TEXT"), SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_PHOTO_LIBRARY_NOT_AVAILABLE_DEVICE_TEXT"), NO);
        if (sSPKAudioActiveDMUploadCoordinator == self)
            sSPKAudioActiveDMUploadCoordinator = nil;
        return;
    }
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[ @"public.movie" ];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    picker.popoverPresentationController.sourceView = self.sourceView ?: self.presenter.view;
    picker.popoverPresentationController.sourceRect = self.sourceView ? self.sourceView.bounds : self.presenter.view.bounds;
    [self.presenter presentViewController:picker animated:YES completion:nil];
}

- (void)presentGalleryPicker {
    __weak typeof(self) weakSelf = self;
    NSSet<NSNumber *> *mediaTypes = [NSSet setWithArray:@[ @(SPKGalleryMediaTypeAudio), @(SPKGalleryMediaTypeVideo) ]];
    if (![SPKGalleryPickerViewController hasSelectableFilesForAllowedMediaTypes:mediaTypes]) {
        SPKAudioDMNotify(SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_NO_GALLERY_AUDIO_TEXT"), SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_SAVE_AUDIO_VIDEO_GALLERY_FIRST_TEXT"), NO);
        if (sSPKAudioActiveDMUploadCoordinator == self)
            sSPKAudioActiveDMUploadCoordinator = nil;
        return;
    }

    [SPKGalleryPickerViewController presentFromViewController:self.presenter
                                                        title:SPKL(@"DATA_GENERAL_GALLERY_TITLE")
                                            allowedMediaTypes:mediaTypes
                                      allowsMultipleSelection:NO
                                                   completion:^(NSArray<SPKGalleryFile *> *selectedFiles) {
                                                       SPKGalleryFile *file = selectedFiles.firstObject;
                                                       NSURL *fileURL = [file fileURL];
                                                       if (!file || ![file fileExists] || !fileURL) {
                                                           SPKAudioDMNotify(SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_NO_GALLERY_AUDIO_TEXT"), SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_SAVE_AUDIO_VIDEO_GALLERY_FIRST_TEXT"), NO);
                                                           if (sSPKAudioActiveDMUploadCoordinator == weakSelf)
                                                               sSPKAudioActiveDMUploadCoordinator = nil;
                                                           return;
                                                       }
                                                       [weakSelf convertAndSendURL:fileURL];
                                                   }];
}

- (void)beginUploadProgressWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    if (!SPKNotificationIsEnabled(kSPKNotificationDownloadShare))
        return;
    if (!self.progressView) {
        __weak typeof(self) weakSelf = self;
        self.progressView = SPKNotifyProgress(kSPKNotificationDownloadShare, title ?: SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_PREPARING_AUDIO_TEXT"), ^{
            [weakSelf cancelUpload];
        });
    }
    [self.progressView updateProgressTitle:title ?: SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_PREPARING_AUDIO_TEXT") subtitle:subtitle];
    [self.progressView setProgress:0.05f animated:NO];
}

- (void)updateUploadProgress:(float)progress title:(NSString *)title subtitle:(NSString *)subtitle {
    if (!self.progressView)
        return;
    [self.progressView updateProgressTitle:title subtitle:subtitle];
    [self.progressView setProgress:progress animated:YES];
}

- (void)finishUploadProgressWithSuccess {
    if (self.progressView) {
        [self.progressView showSuccessWithTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_SENT_TEXT")
                                       subtitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_UPLOADED_SELECTED_FILE_VOICE_NOTE_TEXT")
                                           icon:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SPKNotificationPillDuration() * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.progressView dismiss];
            self.progressView = nil;
        });
    } else {
        SPKAudioDMNotify(SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_SENT_TEXT"), SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_UPLOADED_SELECTED_FILE_VOICE_NOTE_TEXT"), YES);
    }
}

- (void)finishUploadProgressWithErrorTitle:(NSString *)title subtitle:(NSString *)subtitle {
    if (self.progressView) {
        [self.progressView showErrorWithTitle:title ?: SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_UPLOAD_FAILED_TEXT") subtitle:subtitle icon:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SPKNotificationPillDuration() * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.progressView dismiss];
            self.progressView = nil;
        });
    } else {
        SPKAudioDMNotify(title ?: SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_UPLOAD_FAILED_TEXT"), subtitle, NO);
    }
}

- (void)cancelUpload {
    self.cancelled = YES;
    [self.exportSession cancelExport];
    [self finishUploadProgressWithCancel];
    if (sSPKAudioActiveDMUploadCoordinator == self)
        sSPKAudioActiveDMUploadCoordinator = nil;
}

- (void)finishUploadProgressWithCancel {
    if (self.progressView) {
        [self.progressView dismiss];
        self.progressView = nil;
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (sSPKAudioActiveDMUploadCoordinator == self)
        sSPKAudioActiveDMUploadCoordinator = nil;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) {
        if (sSPKAudioActiveDMUploadCoordinator == self)
            sSPKAudioActiveDMUploadCoordinator = nil;
        return;
    }

    [self convertAndSendURL:url];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (sSPKAudioActiveDMUploadCoordinator == self)
        sSPKAudioActiveDMUploadCoordinator = nil;
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    NSURL *url = info[UIImagePickerControllerMediaURL];
    [picker dismissViewControllerAnimated:YES
                               completion:^{
                                   if (url) {
                                       [self convertAndSendURL:url];
                                   } else if (sSPKAudioActiveDMUploadCoordinator == self) {
                                       sSPKAudioActiveDMUploadCoordinator = nil;
                                   }
                               }];
}

- (void)convertAndSendURL:(NSURL *)url {
    BOOL securityScoped = [url startAccessingSecurityScopedResource];
    NSURL *inputURL = url;
    NSURL *copiedURL = SPKAudioDMTemporaryURL(url.pathExtension.length ? url.pathExtension : @"input");
    NSError *copyError = nil;
    [[NSFileManager defaultManager] removeItemAtURL:copiedURL error:nil];
    if ([[NSFileManager defaultManager] copyItemAtURL:url toURL:copiedURL error:&copyError]) {
        inputURL = copiedURL;
    }
    if (securityScoped)
        [url stopAccessingSecurityScopedResource];

    if (copyError && ![inputURL isFileURL]) {
        SPKAudioDMNotify(SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_UPLOAD_FAILED_TEXT"), copyError.localizedDescription ?: SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_COULD_NOT_IMPORT_SELECTED_FILE_TEXT"), NO);
        if (sSPKAudioActiveDMUploadCoordinator == self)
            sSPKAudioActiveDMUploadCoordinator = nil;
        return;
    }

    [self beginUploadProgressWithTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_PREPARING_AUDIO_TEXT") subtitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_PREPARING_VOICE_NOTE_COMPATIBLE_FILE_TEXT")];

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:inputURL options:nil];
    NSArray<NSString *> *compatiblePresets = [AVAssetExportSession exportPresetsCompatibleWithAsset:asset];
    NSString *preset = [compatiblePresets containsObject:AVAssetExportPresetAppleM4A] ? AVAssetExportPresetAppleM4A : AVAssetExportPresetPassthrough;
    AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];
    if (!session) {
        [self finishUploadProgressWithErrorTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_UPLOAD_FAILED_TEXT") subtitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_COULD_NOT_CREATE_AUDIO_CONVERSION_SESSION_TEXT")];
        if (sSPKAudioActiveDMUploadCoordinator == self)
            sSPKAudioActiveDMUploadCoordinator = nil;
        return;
    }

    NSURL *outputURL = SPKAudioDMTemporaryURL(@"m4a");
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    session.outputURL = outputURL;
    session.outputFileType = AVFileTypeAppleM4A;
    self.exportSession = session;
    [self updateUploadProgress:0.15f title:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_CONVERTING_AUDIO_TEXT") subtitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_PREPARING_VOICE_NOTE_COMPATIBLE_FILE_TEXT")];

    [session exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            self.exportSession = nil;
            if (self.cancelled)
                return;
            if (session.status != AVAssetExportSessionStatusCompleted || ![[NSFileManager defaultManager] fileExistsAtPath:outputURL.path]) {
                NSString *message = session.error.localizedDescription ?: SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_INSTAGRAM_MAY_NOT_SUPPORT_MEDIA_FORMAT");
                [self finishUploadProgressWithErrorTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_CONVERSION_FAILED_TEXT") subtitle:message];
                if (sSPKAudioActiveDMUploadCoordinator == self)
                    sSPKAudioActiveDMUploadCoordinator = nil;
                return;
            }

            [self offerTrimThenSendURL:outputURL duration:CMTimeGetSeconds(asset.duration)];
        });
    }];
}

#pragma mark - Trim before send

// After the file is converted to a voice-note-compatible m4a, optionally let the
// user trim it first (pref-gated so it can be turned off). "Send" uses the file
// as-is; "Trim & Send" opens the audio trim editor and sends the rendered cut.
- (void)offerTrimThenSendURL:(NSURL *)url duration:(NSTimeInterval)duration {
    if (![SPKUtils getBoolPref:@"msgs_audio_upload_trim"]) {
        [self updateUploadProgress:0.85f title:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_SENDING_AUDIO_TEXT") subtitle:nil];
        [self sendConvertedURL:url duration:duration];
        return;
    }

    UIViewController *presenter = self.presenter;
    if (!presenter) {
        [self updateUploadProgress:0.85f title:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_SENDING_AUDIO_TEXT") subtitle:nil];
        [self sendConvertedURL:url duration:duration];
        return;
    }

    // Drop the progress pill while the choice / editor is up.
    [self finishUploadProgressWithCancel];

    __weak typeof(self) weakSelf = self;
    [SPKIGAlertPresenter presentActionSheetFromViewController:presenter
                                                        title:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_SEND_VOICE_NOTE_TEXT")
                                                      message:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_SEND_NOW_TRIM_AUDIO_FIRST_TEXT")
                                                      actions:@[
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_SEND")
                                                                                      style:SPKIGAlertActionStyleDefault
                                                                                    handler:^{
                                                                                        [weakSelf beginUploadProgressWithTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_SENDING_AUDIO_TEXT") subtitle:nil];
                                                                                        [weakSelf sendConvertedURL:url duration:duration];
                                                                                    }],
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_TRIM_SEND")
                                                                                      style:SPKIGAlertActionStyleDefault
                                                                                    handler:^{
                                                                                        [weakSelf presentAudioTrimForURL:url];
                                                                                    }],
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                      style:SPKIGAlertActionStyleCancel
                                                                                    handler:^{
                                                                                        if (sSPKAudioActiveDMUploadCoordinator == weakSelf)
                                                                                            sSPKAudioActiveDMUploadCoordinator = nil;
                                                                                    }]
                                                      ]];
}

- (void)presentAudioTrimForURL:(NSURL *)url {
    UIViewController *presenter = self.presenter;
    if (!presenter) {
        if (sSPKAudioActiveDMUploadCoordinator == self)
            sSPKAudioActiveDMUploadCoordinator = nil;
        return;
    }
    SPKTrimConfiguration *config = [SPKTrimConfiguration configurationWithAudioURL:url];
    __weak typeof(self) weakSelf = self;
    [SPKTrimEditorViewController presentWithConfiguration:config
                                                     from:presenter
                                               completion:^(SPKTrimResult *result) {
                                                   __strong typeof(weakSelf) strongSelf = weakSelf;
                                                   if (!strongSelf)
                                                       return;
                                                   if (!result) {
                                                       // Cancelled the editor → abort the whole send.
                                                       if (sSPKAudioActiveDMUploadCoordinator == strongSelf)
                                                           sSPKAudioActiveDMUploadCoordinator = nil;
                                                       return;
                                                   }
                                                   [strongSelf renderTrimResultThenSend:result];
                                               }];
}

- (void)renderTrimResultThenSend:(SPKTrimResult *)result {
    [self beginUploadProgressWithTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_TRIMMING_AUDIO_TEXT") subtitle:nil];
    NSString *basename = [NSString stringWithFormat:@"sparkle-dm-audio-trim-%@", NSUUID.UUID.UUIDString];
    __weak typeof(self) weakSelf = self;
    [SPKTrimRenderer renderTrimAudioForSourceURL:result.sourceURL
                                           asset:nil
                                    startSeconds:result.startSeconds
                                 durationSeconds:result.durationSeconds
                                        basename:basename
                                      completion:^(NSURL *outputURL, NSError *error) {
                                          __strong typeof(weakSelf) strongSelf = weakSelf;
                                          if (!strongSelf || strongSelf.cancelled)
                                              return;
                                          if (!outputURL) {
                                              [strongSelf finishUploadProgressWithErrorTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_TRIM_FAILED_TEXT")
                                                                                    subtitle:error.localizedDescription ?: SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_COULD_NOT_TRIM_AUDIO_TEXT")];
                                              if (sSPKAudioActiveDMUploadCoordinator == strongSelf)
                                                  sSPKAudioActiveDMUploadCoordinator = nil;
                                              return;
                                          }
                                          [strongSelf updateUploadProgress:0.85f title:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_SENDING_AUDIO_TEXT") subtitle:nil];
                                          [strongSelf sendConvertedURL:outputURL duration:result.durationSeconds];
                                      }];
}

- (void)sendConvertedURL:(NSURL *)url duration:(NSTimeInterval)duration {
    if (self.cancelled)
        return;
    if (![SPKAudioDMUploadCoordinator senderTargetSupportsAudioUpload:self.senderTarget]) {
        [self finishUploadProgressWithErrorTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_UPLOAD_UNAVAILABLE_TEXT") subtitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_DIRECT_AUDIO_SENDER_DISAPPEARED_BEFORE_SENDING_TEXT")];
        if (sSPKAudioActiveDMUploadCoordinator == self)
            sSPKAudioActiveDMUploadCoordinator = nil;
        return;
    }

    NSTimeInterval safeDuration = isfinite(duration) && duration > 0 ? duration : 0;
    __weak typeof(self) weakSelf = self;
    SPKAudioDMSampleWaveform(url, safeDuration, ^(NSArray<NSNumber *> *samples) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.cancelled)
            return;
        if (samples.count == 0) {
            SPKWarnLog(@"AudioUpload", @"Could not decode waveform samples for %@; using flat fallback", url.lastPathComponent);
            samples = SPKAudioDMFallbackWaveformSamples(safeDuration);
        }
        id waveform = SPKAudioDMCreateWaveformWithSamples(samples, safeDuration);
        if (!waveform) {
            [strongSelf finishUploadProgressWithErrorTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_UPLOAD_UNAVAILABLE_TEXT") subtitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_COULD_NOT_CREATE_INSTAGRAM_AUDIO_WAVEFORM_TEXT")];
            if (sSPKAudioActiveDMUploadCoordinator == strongSelf)
                sSPKAudioActiveDMUploadCoordinator = nil;
            return;
        }
        [strongSelf sendConvertedURL:url duration:safeDuration waveform:waveform];
    });
}

- (void)sendConvertedURL:(NSURL *)url duration:(NSTimeInterval)safeDuration waveform:(id)waveform {
    if (self.cancelled)
        return;
    if (![SPKAudioDMUploadCoordinator senderTargetSupportsAudioUpload:self.senderTarget]) {
        [self finishUploadProgressWithErrorTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_UPLOAD_UNAVAILABLE_TEXT") subtitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_DIRECT_AUDIO_SENDER_DISAPPEARED_BEFORE_SENDING_TEXT")];
        if (sSPKAudioActiveDMUploadCoordinator == self)
            sSPKAudioActiveDMUploadCoordinator = nil;
        return;
    }
    if (!waveform) {
        [self finishUploadProgressWithErrorTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_UPLOAD_UNAVAILABLE_TEXT") subtitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_COULD_NOT_CREATE_INSTAGRAM_AUDIO_WAVEFORM_TEXT")];
        if (sSPKAudioActiveDMUploadCoordinator == self)
            sSPKAudioActiveDMUploadCoordinator = nil;
        return;
    }

    id voiceController = SPKAudioDMVoiceControllerFromTarget(self.senderTarget);
    SEL voiceSelector = SPKAudioDMVoiceSelector();
    SEL voiceLegacySelector = SPKAudioDMVoiceLegacySelector();
    if (voiceController && ([voiceController respondsToSelector:voiceSelector] || [voiceController respondsToSelector:voiceLegacySelector])) {
        SPKDMConfirmVoiceMessageIfNeeded(^{
            if (self.cancelled)
                return;
            if ([voiceController respondsToSelector:voiceSelector]) {
                void (*sendVoice)(id, SEL, id, id, id, double, long long, id, id, long long) = (void (*)(id, SEL, id, id, id, double, long long, id, id, long long))objc_msgSend;
                sendVoice(voiceController, voiceSelector, nil, url, waveform, safeDuration, 0, nil, nil, 0);
            } else {
                void (*sendVoiceLegacy)(id, SEL, id, id, id, double, long long, long long) = (void (*)(id, SEL, id, id, id, double, long long, long long))objc_msgSend;
                sendVoiceLegacy(voiceController, voiceLegacySelector, nil, url, waveform, safeDuration, 0, 0);
            }
            [self updateUploadProgress:1.0f title:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_SENT_TEXT") subtitle:nil];
            [self finishUploadProgressWithSuccess];
            if (sSPKAudioActiveDMUploadCoordinator == self)
                sSPKAudioActiveDMUploadCoordinator = nil;
        },
                                         ^{
                                             [self finishUploadProgressWithCancel];
                                             if (sSPKAudioActiveDMUploadCoordinator == self)
                                                 sSPKAudioActiveDMUploadCoordinator = nil;
                                         });
        return;
    }

    id sender = SPKAudioDMMessageSenderFromTarget(self.senderTarget) ?: self.senderTarget;
    if (![sender respondsToSelector:SPKAudioDMSendSelector()] && ![sender respondsToSelector:SPKAudioDMSendLegacySelector()]) {
        [self finishUploadProgressWithErrorTitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_UPLOAD_UNAVAILABLE_TEXT") subtitle:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_DIRECT_AUDIO_SENDER_DISAPPEARED_BEFORE_SENDING_TEXT")];
        if (sSPKAudioActiveDMUploadCoordinator == self)
            sSPKAudioActiveDMUploadCoordinator = nil;
        return;
    }

    SPKDMConfirmVoiceMessageIfNeeded(^{
        if (self.cancelled)
            return;
        if ([sender respondsToSelector:SPKAudioDMSendSelector()]) {
            void (*sendAudio)(id, SEL, id, id, double, long long, id, id, id, id) = (void (*)(id, SEL, id, id, double, long long, id, id, id, id))objc_msgSend;
            sendAudio(sender,
                      SPKAudioDMSendSelector(),
                      url,
                      waveform,
                      safeDuration,
                      0,
                      nil,
                      nil,
                      nil,
                      nil);
        } else {
            SEL legacySelector = SPKAudioDMSendLegacySelector();
            void (*sendAudioLegacy)(id, SEL, id, id, double, long long, id, id) = (void (*)(id, SEL, id, id, double, long long, id, id))objc_msgSend;
            sendAudioLegacy(sender,
                            legacySelector,
                            url,
                            waveform,
                            safeDuration,
                            0,
                            nil,
                            nil);
        }
        [self updateUploadProgress:1.0f title:SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_SENT_TEXT") subtitle:nil];
        [self finishUploadProgressWithSuccess];
        if (sSPKAudioActiveDMUploadCoordinator == self)
            sSPKAudioActiveDMUploadCoordinator = nil;
    },
                                     ^{
                                         [self finishUploadProgressWithCancel];
                                         if (sSPKAudioActiveDMUploadCoordinator == self)
                                             sSPKAudioActiveDMUploadCoordinator = nil;
                                     });
}

@end
