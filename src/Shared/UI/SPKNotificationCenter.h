#import "SPKNotificationPillView.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const kSPKNotificationDownloadLibrary;
FOUNDATION_EXPORT NSString *const kSPKNotificationDownloadShare;
FOUNDATION_EXPORT NSString *const kSPKNotificationCopyDownloadLink;
FOUNDATION_EXPORT NSString *const kSPKNotificationCopyMedia;
FOUNDATION_EXPORT NSString *const kSPKNotificationDownloadGallery;
FOUNDATION_EXPORT NSString *const kSPKNotificationDownloadAllLibrary;
FOUNDATION_EXPORT NSString *const kSPKNotificationDownloadAllShare;
FOUNDATION_EXPORT NSString *const kSPKNotificationDownloadAllGallery;
FOUNDATION_EXPORT NSString *const kSPKNotificationDownloadAllClipboard;
FOUNDATION_EXPORT NSString *const kSPKNotificationDownloadAllLinks;
FOUNDATION_EXPORT NSString *const kSPKNotificationDownloadQueueFinished;
FOUNDATION_EXPORT NSString *const kSPKNotificationQueuedDownloadFailed;
FOUNDATION_EXPORT NSString *const kSPKNotificationExpand;
FOUNDATION_EXPORT NSString *const kSPKNotificationViewThumbnail;
FOUNDATION_EXPORT NSString *const kSPKNotificationCopyCaption;
FOUNDATION_EXPORT NSString *const kSPKNotificationOpenTopicSettings;
FOUNDATION_EXPORT NSString *const kSPKNotificationRepost;

FOUNDATION_EXPORT NSString *const kSPKNotificationDownloadAudio;
FOUNDATION_EXPORT NSString *const kSPKNotificationDownloadAudioShare;
FOUNDATION_EXPORT NSString *const kSPKNotificationDownloadAudioGallery;
FOUNDATION_EXPORT NSString *const kSPKNotificationPlayAudio;
FOUNDATION_EXPORT NSString *const kSPKNotificationCopyAudioURL;

FOUNDATION_EXPORT NSString *const kSPKNotificationStoryMarkSeen;
FOUNDATION_EXPORT NSString *const kSPKNotificationStorySeenUserRule;
FOUNDATION_EXPORT NSString *const kSPKNotificationStoryMentionsSheet;
FOUNDATION_EXPORT NSString *const kSPKNotificationStoryAutoSave;
FOUNDATION_EXPORT NSString *const kSPKNotificationStoryAutoSaveUserRule;
FOUNDATION_EXPORT NSString *const kSPKNotificationAutoSaveSummary;
FOUNDATION_EXPORT NSString *const kSPKNotificationAutoSavePending;
FOUNDATION_EXPORT NSString *const kSPKNotificationDirectVisualMarkSeen;
FOUNDATION_EXPORT NSString *const kSPKNotificationThreadMessagesMarkSeen;
FOUNDATION_EXPORT NSString *const kSPKNotificationDirectThreadSeenRule;
FOUNDATION_EXPORT NSString *const kSPKNotificationDirectHiddenChat;
FOUNDATION_EXPORT NSString *const kSPKNotificationDirectAutoSave;
FOUNDATION_EXPORT NSString *const kSPKNotificationDirectAutoSaveThreadRule;
FOUNDATION_EXPORT NSString *const kSPKNotificationUnsentMessage;
FOUNDATION_EXPORT NSString *const kSPKNotificationUnsentReaction;
FOUNDATION_EXPORT NSString *const kSPKNotificationPresenceOnline;
FOUNDATION_EXPORT NSString *const kSPKNotificationPresenceOffline;
FOUNDATION_EXPORT NSString *const kSPKNotificationPresenceTyping;
FOUNDATION_EXPORT NSString *const kSPKNotificationPresenceRead;
FOUNDATION_EXPORT NSString *const kSPKNotificationPresenceUserRule;
FOUNDATION_EXPORT NSString *const kSPKNotificationInstantsCaptureBlocked;
FOUNDATION_EXPORT NSString *const kSPKNotificationInstantsUpload;
FOUNDATION_EXPORT NSString *const kSPKNotificationInstantsAutoSave;
FOUNDATION_EXPORT NSString *const kSPKNotificationInstantsAutoSaveUserRule;

FOUNDATION_EXPORT NSString *const kSPKNotificationProfileCopyInfo;
FOUNDATION_EXPORT NSString *const kSPKNotificationProfileAnalyzerComplete;
FOUNDATION_EXPORT NSString *const kSPKNotificationProfileStorySeenUserRule;
FOUNDATION_EXPORT NSString *const kSPKNotificationProfileMessagesSeenUserRule;

FOUNDATION_EXPORT NSString *const kSPKNotificationMediaPreviewSavePhotos;
FOUNDATION_EXPORT NSString *const kSPKNotificationMediaPreviewSaveGallery;
FOUNDATION_EXPORT NSString *const kSPKNotificationMediaPreviewShare;
FOUNDATION_EXPORT NSString *const kSPKNotificationMediaPreviewCopy;
FOUNDATION_EXPORT NSString *const kSPKNotificationMediaPreviewDeleteGallery;
FOUNDATION_EXPORT NSString *const kSPKNotificationMediaPreviewOpenGallery;

FOUNDATION_EXPORT NSString *const kSPKNotificationGalleryOpenOriginal;
FOUNDATION_EXPORT NSString *const kSPKNotificationGalleryOpenProfile;
FOUNDATION_EXPORT NSString *const kSPKNotificationGalleryDeleteFile;
FOUNDATION_EXPORT NSString *const kSPKNotificationGalleryDeleteSelected;
FOUNDATION_EXPORT NSString *const kSPKNotificationGalleryBulkDelete;
FOUNDATION_EXPORT NSString *const kSPKNotificationGalleryImport;

FOUNDATION_EXPORT NSString *const kSPKNotificationSettingsExport;
FOUNDATION_EXPORT NSString *const kSPKNotificationSettingsImport;
FOUNDATION_EXPORT NSString *const kSPKNotificationSettingsClearCache;
FOUNDATION_EXPORT NSString *const kSPKNotificationCopyDescription;
FOUNDATION_EXPORT NSString *const kSPKNotificationCopyNoteText;
FOUNDATION_EXPORT NSString *const kSPKNotificationShareLongPressCopyLink;
FOUNDATION_EXPORT NSString *const kSPKNotificationCopyComment;
FOUNDATION_EXPORT NSString *const kSPKNotificationCopyGIFLink;
FOUNDATION_EXPORT NSString *const kSPKNotificationCopyGIFTitle;
FOUNDATION_EXPORT NSString *const kSPKNotificationMediaEncodingLogs;
FOUNDATION_EXPORT NSString *const kSPKNotificationFlexUnavailable;
FOUNDATION_EXPORT NSString *const kSPKNotificationPillDurationKey;
FOUNDATION_EXPORT NSString *const kSPKNotificationPillGlowEnabledKey;
FOUNDATION_EXPORT NSString *const kSPKNotificationPillLiquidGlassEnabledKey;
FOUNDATION_EXPORT NSString *const kSPKNotificationProgressSubtitleStyleKey;
FOUNDATION_EXPORT NSString *const kSPKNotificationPillPositionKey;

#ifdef __cplusplus
extern "C" {
#endif

NSString *SPKNotificationDefaultsKey(NSString *identifier);
NSString *SPKNotificationHapticDefaultsKey(NSString *identifier);
NSArray<NSDictionary *> *SPKNotificationPreferenceSections(void);
NSDictionary<NSString *, id> *SPKNotificationDefaultPreferences(void);
BOOL SPKNotificationIsEnabled(NSString *identifier);
NSTimeInterval SPKNotificationPillDuration(void);
void SPKNotificationTriggerHaptic(NSString *identifier, SPKNotificationTone tone);
SPKNotificationTone SPKNotificationToneForIconResource(NSString *_Nullable iconResource);

void SPKNotify(NSString *identifier,
               NSString *title,
               NSString *_Nullable subtitle,
               NSString *_Nullable iconResource,
               SPKNotificationTone tone);

// As SPKNotify, but the pill runs `onTap` when tapped (then dismisses). Used to
// jump from a toast to a relevant screen (e.g. the deleted-messages log).
void SPKNotifyTappable(NSString *identifier,
                       NSString *title,
                       NSString *_Nullable subtitle,
                       NSString *_Nullable iconResource,
                       SPKNotificationTone tone,
                       void (^_Nullable onTap)(void));

SPKNotificationPillView *_Nullable SPKNotifyProgress(NSString *identifier,
                                                     NSString *_Nullable title,
                                                     void (^_Nullable onCancel)(void));

#ifdef __cplusplus
}
#endif

@interface SPKNotificationCenter : NSObject
+ (instancetype)shared;
- (void)notifyIdentifier:(NSString *)identifier
                   title:(NSString *)title
                subtitle:(nullable NSString *)subtitle
            iconResource:(nullable NSString *)iconResource
                    tone:(SPKNotificationTone)tone;
- (nullable SPKNotificationPillView *)beginProgressForIdentifier:(NSString *)identifier
                                                           title:(nullable NSString *)title
                                                        onCancel:(nullable void (^)(void))onCancel;
- (SPKNotificationPillView *)beginUnmanagedProgressWithTitle:(nullable NSString *)title
                                                    onCancel:(nullable void (^)(void))onCancel;
// As above, but marks the pill as transient: it covers preparatory work that runs
// before the real flow starts (e.g. the 4K candidate fetch). It morphs into the real
// progress pill if a download picks it up, and -dismissTransientProgressPill clears it
// if the flow instead stops to ask the user something or bails.
- (SPKNotificationPillView *)beginTransientProgressWithTitle:(nullable NSString *)title
                                                    onCancel:(nullable void (^)(void))onCancel;
- (void)dismissTransientProgressPill;
@end

NS_ASSUME_NONNULL_END
