#pragma once

#import "../UI/SPKChrome.h"
#import "ActionButtonLookupUtils.h"
#import <UIKit/UIKit.h>

@class SPKGallerySaveMetadata;

typedef NS_ENUM(NSInteger, SPKActionButtonSource) {
    SPKActionButtonSourceFeed = 1,
    SPKActionButtonSourceReels = 2,
    SPKActionButtonSourceStories = 3,
    SPKActionButtonSourceDirect = 4,
    SPKActionButtonSourceProfile = 5,
    SPKActionButtonSourceInstants = 6
};

FOUNDATION_EXPORT NSString *const kSPKActionNone;
FOUNDATION_EXPORT NSString *const kSPKActionDownloadLibrary;
FOUNDATION_EXPORT NSString *const kSPKActionDownloadShare;
FOUNDATION_EXPORT NSString *const kSPKActionCopyDownloadLink;
FOUNDATION_EXPORT NSString *const kSPKActionCopyMedia;
FOUNDATION_EXPORT NSString *const kSPKActionDownloadGallery;
FOUNDATION_EXPORT NSString *const kSPKActionTrimSave;
FOUNDATION_EXPORT NSString *const kSPKActionEditSave;
FOUNDATION_EXPORT NSString *const kSPKActionDownloadAudio;
FOUNDATION_EXPORT NSString *const kSPKActionDownloadAudioShare;
FOUNDATION_EXPORT NSString *const kSPKActionDownloadAudioGallery;
FOUNDATION_EXPORT NSString *const kSPKActionPlayAudio;
FOUNDATION_EXPORT NSString *const kSPKActionCopyAudioURL;
FOUNDATION_EXPORT NSString *const kSPKActionDownloadAll;
FOUNDATION_EXPORT NSString *const kSPKActionDownloadAllLibrary;
FOUNDATION_EXPORT NSString *const kSPKActionDownloadAllShare;
FOUNDATION_EXPORT NSString *const kSPKActionDownloadAllGallery;
FOUNDATION_EXPORT NSString *const kSPKActionDownloadAllClipboard;
FOUNDATION_EXPORT NSString *const kSPKActionDownloadAllLinks;
FOUNDATION_EXPORT NSString *const kSPKActionExpand;
FOUNDATION_EXPORT NSString *const kSPKActionViewThumbnail;
FOUNDATION_EXPORT NSString *const kSPKActionCopyCaption;
FOUNDATION_EXPORT NSString *const kSPKActionOpenTopicSettings;
FOUNDATION_EXPORT NSString *const kSPKActionDeletedMessagesLog;
FOUNDATION_EXPORT NSString *const kSPKActionRepost;
FOUNDATION_EXPORT NSString *const kSPKActionToggleStorySeenUserRule;
FOUNDATION_EXPORT NSString *const kSPKActionToggleStoryAutoSaveUserRule;
FOUNDATION_EXPORT NSString *const kSPKActionToggleDirectAutoSaveThreadRule;
FOUNDATION_EXPORT NSString *const kSPKActionToggleInstantsAutoSaveUserRule;
FOUNDATION_EXPORT NSString *const kSPKActionInstantsMarkSeen;
FOUNDATION_EXPORT NSString *const kSPKActionToggleInstantsManualSeenUserRule;
FOUNDATION_EXPORT NSString *const kSPKActionToggleProfileStorySeenUserRule;
FOUNDATION_EXPORT NSString *const kSPKActionToggleProfileMessagesSeenUserRule;
FOUNDATION_EXPORT NSString *const kSPKActionStoryMentionsSheet;
FOUNDATION_EXPORT NSString *const kSPKActionProfileCopyInfo;
FOUNDATION_EXPORT NSString *const kSPKActionProfileCopyID;
FOUNDATION_EXPORT NSString *const kSPKActionProfileCopyUsername;
FOUNDATION_EXPORT NSString *const kSPKActionProfileCopyName;
FOUNDATION_EXPORT NSString *const kSPKActionProfileCopyBio;
FOUNDATION_EXPORT NSString *const kSPKActionProfileCopyLink;
FOUNDATION_EXPORT NSString *const SPKActionButtonConfigurationDidChangeNotification;

@interface SPKActionMenuButton : SPKChromeButton
/// When set, the button's alpha always mirrors this view's effective visibility,
/// whoever writes it. Hosts that fade their subviews wholesale cannot strand it.
@property (nonatomic, weak, nullable) UIView *spk_alphaSource;
@end

typedef id _Nullable (^SPKActionButtonMediaResolver)(id context);
typedef NSInteger (^SPKActionButtonIndexResolver)(id context);
typedef NSString *_Nullable (^SPKActionButtonCaptionResolver)(id context, id _Nullable media, NSArray *entries, NSInteger currentIndex);
typedef BOOL (^SPKActionButtonRepostHandler)(id context);
typedef BOOL (^SPKActionButtonVisibilityResolver)(id context, NSString *identifier, id _Nullable media, NSArray *entries, NSInteger currentIndex);

@interface SPKActionButtonContext : NSObject
@property (nonatomic, assign) SPKActionButtonSource source;
@property (nonatomic, weak, nullable) UIView *view;
@property (nonatomic, weak, nullable) UIViewController *controller;
@property (nonatomic, assign) NSInteger currentIndexOverride;
@property (nonatomic, strong, nullable) id mediaOverride;
@property (nonatomic, copy, nullable) NSString *settingsTitle;
@property (nonatomic, copy, nullable) NSArray<NSString *> *supportedActions;
@property (nonatomic, copy, nullable) SPKActionButtonMediaResolver mediaResolver;
@property (nonatomic, copy, nullable) SPKActionButtonMediaResolver bulkMediaResolver;
@property (nonatomic, copy, nullable) SPKActionButtonIndexResolver currentIndexResolver;
@property (nonatomic, copy, nullable) SPKActionButtonCaptionResolver captionResolver;
@property (nonatomic, copy, nullable) SPKActionButtonRepostHandler repostHandler;
@property (nonatomic, copy, nullable) SPKActionButtonVisibilityResolver visibilityResolver;
@end

#ifdef __cplusplus
extern "C" {
#endif
UIButton *SPKActionButtonWithTag(UIView *container, NSInteger tag);
void SPKApplyButtonStyle(UIButton *button, SPKActionButtonSource source);
BOOL SPKIsDirectVisualViewerAncestor(UIView *view);
void SPKConfigureActionButton(UIButton *button, SPKActionButtonContext *context);
SPKActionButtonContext *SPKActionButtonContextFromButton(UIButton *button);
NSString *SPKActionButtonTitleForIdentifier(NSString *identifier);
UIImage *SPKActionButtonMenuIconForIdentifier(NSString *identifier, CGFloat size);
// Glyph name shown on the action button when its default tap action is "Open
// Menu" (kSPKActionNone). User-configurable; defaults to "action".
NSString *SPKActionButtonOpenMenuIconName(void);
BOOL SPKExecuteActionIdentifier(NSString *identifier, SPKActionButtonContext *context, BOOL isDefaultTap);
/// Whether the "Fetching 4K candidates" pill shows ahead of `identifier`. Edit & Save
/// has no notification toggle and its own progress pills always show, so this one does too.
BOOL SPKActionShowsCandidateFetchPill(NSString *identifier);
/// Resolves `media` down to the photo/video URLs and gallery metadata a manual save
/// would produce. Lets non-action-button callers (auto-save) reuse the action button's
/// own resolution instead of duplicating it, so their files carry identical metadata
/// and the quality manager sees exactly what it sees on a manual save.
///
/// Either URL may come back nil (a photo has no videoURL, and vice versa). Returns NO
/// when neither resolves.
BOOL SPKResolveGalleryDownloadForMedia(id _Nullable media,
                                       SPKActionButtonSource source,
                                       NSString *_Nullable fallbackUsername,
                                       NSURL *_Nullable *_Nullable outPhotoURL,
                                       NSURL *_Nullable *_Nullable outVideoURL,
                                       SPKGallerySaveMetadata *_Nullable *_Nullable outMetadata);
NSArray<NSString *> *SPKConfiguredBulkActionIdentifiersForSource(SPKActionButtonSource source);
NSArray *SPKActionButtonCarouselChildren(id _Nullable media);
void SPKArmPendingRepostFeedback(SPKActionButtonContext *context);
NSDictionary<NSString *, NSString *> *_Nullable SPKConsumePendingRepostFeedback(SPKActionButtonSource source);
void SPKPauseStoryPlaybackFromOverlaySubview(UIView *overlayView);
void SPKResumeStoryPlaybackFromOverlaySubview(UIView *overlayView);
#ifdef __cplusplus
}
#endif
