#import "SPKStrings.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "../../AssetUtils.h"
#import "../../Features/Messages/DeletedMessagesLog/SPKDeletedMessagesViewController.h"
#import "../../InstagramHeaders.h"
#import "../../Networking/SPKInstagramAPI.h"
#import "../../Settings/SPKPreferences.h"
#import "../../Utils.h"
#import "../Audio/SPKAudioDownloadCoordinator.h"
#import "../Audio/SPKAudioItem.h"
#import "../Downloads/SPKDownloadHelpers.h"
#import "../Gallery/SPKGalleryFile.h"
#import "../Gallery/SPKGalleryOriginController.h"
#import "../Gallery/SPKGallerySaveMetadata.h"
#import "../MediaDownload/SPKMediaQualityManager.h"
#import "../MediaPreview/SPKFullScreenMediaPlayer.h"
#import "../MediaPreview/SPKMediaItem.h"
#import "../../Features/Instants/InstantsResolver.h"
#import "../Instants/SPKInstantsAutoSave.h"
#import "../MediaTrim/SPKTrimEntry.h"
#import "../Messages/SPKDirectAutoSave.h"
#import "../Messages/SPKDirectSeenContext.h"
#import "../Messages/SPKDirectUserResolver.h"
#import "../PhotoEdit/SPKPhotoEditEntry.h"
#import "../Stories/SPKStoryAutoSave.h"
#import "../Stories/SPKStoryContext.h"
#import "../Stories/SPKStoryDynamicRange.h"
#import "../UI/SPKChrome.h"
#import "../UI/SPKIGAlertPresenter.h"
#import "../UI/SPKNotificationCenter.h"
#import "../../Features/Instants/InstantsAdvance.h"
#import "../../Features/Instants/InstantsManualSeen.h"
#import "ActionButtonCore.h"
#import "SPKActionButtonConfiguration.h"
#import "SPKActionDescriptor.h"
#import "SPKBulkMediaSelectionViewController.h"

NSString *const kSPKActionNone = @"none";
NSString *const kSPKActionDownloadLibrary = @"download_library";
NSString *const kSPKActionDownloadShare = @"download_share";
NSString *const kSPKActionCopyDownloadLink = @"copy_download_link";
NSString *const kSPKActionCopyMedia = @"copy_media";
NSString *const kSPKActionDownloadGallery = @"download_gallery";
NSString *const kSPKActionTrimSave = @"trim_save";
NSString *const kSPKActionEditSave = @"edit_save";
NSString *const kSPKActionDownloadAudio = @"download_audio";
NSString *const kSPKActionDownloadAudioShare = @"download_audio_share";
NSString *const kSPKActionDownloadAudioGallery = @"download_audio_gallery";
NSString *const kSPKActionPlayAudio = @"play_audio";
NSString *const kSPKActionCopyAudioURL = @"copy_audio_url";
NSString *const kSPKActionDownloadAll = @"download_all";
NSString *const kSPKActionDownloadAllLibrary = @"download_all_library";
NSString *const kSPKActionDownloadAllShare = @"download_all_share";
NSString *const kSPKActionDownloadAllGallery = @"download_all_gallery";
NSString *const kSPKActionDownloadAllClipboard = @"download_all_clipboard";
NSString *const kSPKActionDownloadAllLinks = @"download_all_links";
NSString *const kSPKActionExpand = @"expand";
NSString *const kSPKActionViewThumbnail = @"view_thumbnail";
NSString *const kSPKActionCopyCaption = @"copy_caption";
NSString *const kSPKActionOpenTopicSettings = @"open_topic_settings";
NSString *const kSPKActionDeletedMessagesLog = @"deleted_messages_log";
NSString *const kSPKActionRepost = @"repost";
NSString *const kSPKActionToggleStorySeenUserRule = @"toggle_story_seen_user_rule";
NSString *const kSPKActionToggleStoryAutoSaveUserRule = @"toggle_story_auto_save_user_rule";
NSString *const kSPKActionToggleDirectAutoSaveThreadRule = @"toggle_direct_auto_save_thread_rule";
NSString *const kSPKActionToggleInstantsAutoSaveUserRule = @"toggle_instants_auto_save_user_rule";
NSString *const kSPKActionInstantsMarkSeen = @"instants_mark_seen";

/// Defined further down, next to the other Instants executors, but needed by the
/// action-availability switch above it.
static NSString *SPKInstantsMarkSeenMediaPKForContext(SPKActionButtonContext *context);
NSString *const kSPKActionToggleProfileStorySeenUserRule = @"toggle_profile_story_seen_user_rule";
NSString *const kSPKActionToggleProfileMessagesSeenUserRule = @"toggle_profile_messages_seen_user_rule";
NSString *const kSPKActionStoryMentionsSheet = @"story_mentions_sheet";
NSString *const kSPKActionProfileCopyInfo = @"profile_copy_info";
NSString *const kSPKActionProfileCopyID = @"profile_copy_id";
NSString *const kSPKActionProfileCopyUsername = @"profile_copy_username";
NSString *const kSPKActionProfileCopyName = @"profile_copy_name";
NSString *const kSPKActionProfileCopyBio = @"profile_copy_bio";
NSString *const kSPKActionProfileCopyLink = @"profile_copy_link";
NSString *const SPKActionButtonConfigurationDidChangeNotification = @"SPKActionButtonConfigurationDidChangeNotification";

static const void *kSPKActionButtonContextAssocKey = &kSPKActionButtonContextAssocKey;
static const void *kSPKActionButtonTapActionAssocKey = &kSPKActionButtonTapActionAssocKey;
static const void *kSPKActionButtonHapticActionAssocKey = &kSPKActionButtonHapticActionAssocKey;
static const void *kSPKActionButtonIconImageViewAssocKey = &kSPKActionButtonIconImageViewAssocKey;
static const void *kSPKActionButtonIconWidthConstraintAssocKey = &kSPKActionButtonIconWidthConstraintAssocKey;
static const void *kSPKActionButtonIconHeightConstraintAssocKey = &kSPKActionButtonIconHeightConstraintAssocKey;
static const void *kSPKActionButtonMenuSignatureAssocKey = &kSPKActionButtonMenuSignatureAssocKey;
static const void *kSPKActionButtonLastMenuActionAssocKey = &kSPKActionButtonLastMenuActionAssocKey;
static const void *kSPKActionButtonConfigurationObserverAssocKey = &kSPKActionButtonConfigurationObserverAssocKey;
static NSDictionary<NSString *, NSString *> *SPKPendingRepostFeedback = nil;

@interface SPKResolvedMediaEntry : NSObject
@property (nonatomic, strong, nullable) id mediaObject;
@property (nonatomic, strong, nullable) id metadataObject;
@property (nonatomic, strong, nullable) NSURL *photoURL;
@property (nonatomic, strong, nullable) NSURL *videoURL;
@property (nonatomic, copy, nullable) NSString *sourceUsername;
@property (nonatomic, copy, nullable) NSString *sourceMediaPK;
@property (nonatomic, copy, nullable) NSString *sourceMediaURLString;
@property (nonatomic, strong, nullable) NSDate *importPostedDate;
@end

static void SPKPauseDirectPlaybackFromController(UIViewController *controller);
static void SPKResumeDirectPlaybackFromController(UIViewController *controller);
static BOOL SPKActionIdentifierOpensPreview(NSString *identifier);
static id SPKResolveMediaForContext(SPKActionButtonContext *context);
static NSString *SPKActionMenuDateTitle(SPKActionButtonContext *context);
static UIViewController *SPKActionContextPresenter(SPKActionButtonContext *context);
static UIView *SPKActionContextAnchorView(SPKActionButtonContext *context);
static UIColor *SPKActionButtonTintForSource(SPKActionButtonSource source);
void SPKPauseStoryPlaybackFromOverlaySubview(UIView *overlayView);
void SPKResumeStoryPlaybackFromOverlaySubview(UIView *overlayView);
SPKActionButtonContext *SPKActionButtonContextFromButton(UIButton *button);

#ifdef __cplusplus
extern "C" {
#endif
void SPKPresentStoryMentionsSheet(UIView *overlayView);
#ifdef __cplusplus
}
#endif

static BOOL SPKActionMenuButtonIsReels(UIButton *button) {
    SPKActionButtonContext *context = SPKActionButtonContextFromButton(button);
    return context.source == SPKActionButtonSourceReels;
}

static BOOL SPKActionMenuButtonIsStories(UIButton *button) {
    SPKActionButtonContext *context = SPKActionButtonContextFromButton(button);
    return context.source == SPKActionButtonSourceStories;
}

// Reapply the story header's EDR tint around a context-menu transition: UIKit resets
// layer compositing while it animates, so the button would drop out of extended
// dynamic range and stop matching IG's native header buttons.
static void SPKReapplyStoriesActionButtonDynamicRange(UIButton *button) {
    if (!SPKActionMenuButtonIsStories(button))
        return;

    SPKStoryApplyDynamicRangeToButton(button);
}

static UITargetedPreview *SPKActionMenuButtonMenuPreview(UIButton *button) {
    if (!SPKActionMenuButtonIsReels(button) || CGRectIsEmpty(button.bounds))
        return [[UITargetedPreview alloc] initWithView:button];

    // Reels floats the bare glyph over the video. The default preview parameters
    // paint an SDR platter behind the preview, which read as a dim square around
    // the EDR glyph on HDR reels during the highlight and the menu morph.
    UIPreviewParameters *parameters = [[UIPreviewParameters alloc] init];
    parameters.backgroundColor = UIColor.clearColor;
    parameters.visiblePath = [UIBezierPath bezierPathWithOvalInRect:button.bounds];
    return [[UITargetedPreview alloc] initWithView:button parameters:parameters];
}

@implementation SPKResolvedMediaEntry
@end

@implementation SPKActionMenuButton

- (void)setAlpha:(CGFloat)alpha {
    UIView *source = self.spk_alphaSource;
    if (source)
        alpha = source.hidden ? 0.0 : source.alpha;
    [super setAlpha:alpha];
}

// The Instants button keeps one menu while the snap under it changes, so the posted
// date in its title is read again for the snap on screen, before UIKit builds the menu.
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location {
    SPKActionButtonContext *context = SPKActionButtonContextFromButton(self);
    UIMenu *menu = self.menu;
    if (menu && context.source == SPKActionButtonSourceInstants) {
        NSString *title = SPKActionMenuDateTitle(context);
        if (![title isEqualToString:menu.title])
            self.menu = [UIMenu menuWithTitle:title image:menu.image identifier:menu.identifier options:menu.options children:menu.children];
    }
    return [super contextMenuInteraction:interaction configurationForMenuAtLocation:location];
}

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    previewForHighlightingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    (void)interaction;
    (void)configuration;
    return SPKActionMenuButtonMenuPreview(self);
}

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    previewForDismissingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    (void)interaction;
    (void)configuration;
    return SPKActionMenuButtonMenuPreview(self);
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    willDisplayMenuForConfiguration:(id)configuration
                           animator:(id<UIContextMenuInteractionAnimating>)animator {
    [super contextMenuInteraction:interaction willDisplayMenuForConfiguration:configuration animator:animator];
    (void)interaction;
    (void)configuration;
    (void)animator;

    // Menu-open haptic (long-press, or tap when the button opens the menu as its primary
    // action). Lives here rather than on touch-down so it fires only when the menu actually
    // appears — a touch-down tick stacked a second haptic on top of the action's own
    // completion feedback for plain action taps.
    if (![SPKUtils getBoolPref:@"general_disable_haptics"]) {
        UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
        [feedback selectionChanged];
    }

    SPKActionButtonContext *context = SPKActionButtonContextFromButton(self);
    if (!context)
        return;

    SPKReapplyStoriesActionButtonDynamicRange(self);
    [animator addAnimations:^{
        SPKReapplyStoriesActionButtonDynamicRange(self);
    }];

    objc_setAssociatedObject(self, kSPKActionButtonLastMenuActionAssocKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (context.source == SPKActionButtonSourceStories) {
        SPKPauseStoryPlaybackFromOverlaySubview(context.view);
    } else if (context.source == SPKActionButtonSourceDirect) {
        SPKPauseDirectPlaybackFromController(context.controller);
    }
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
       willEndForConfiguration:(id)configuration
                      animator:(id<UIContextMenuInteractionAnimating>)animator {
    [super contextMenuInteraction:interaction willEndForConfiguration:configuration animator:animator];
    (void)interaction;
    (void)configuration;

    SPKReapplyStoriesActionButtonDynamicRange(self);
    [animator addAnimations:^{
        SPKReapplyStoriesActionButtonDynamicRange(self);
    }];

    [animator addCompletion:^{
        SPKActionMenuButton *strongSelf = self;
        if (!strongSelf)
            return;
        SPKReapplyStoriesActionButtonDynamicRange(strongSelf);

        SPKActionButtonContext *context = SPKActionButtonContextFromButton(strongSelf);
        NSString *lastAction = objc_getAssociatedObject(strongSelf, kSPKActionButtonLastMenuActionAssocKey);
        objc_setAssociatedObject(strongSelf, kSPKActionButtonLastMenuActionAssocKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        if (!context)
            return;
        if ([lastAction isEqualToString:kSPKActionOpenTopicSettings])
            return;
        if (SPKActionIdentifierOpensPreview(lastAction))
            return;

        if (context.source == SPKActionButtonSourceStories) {
            SPKResumeStoryPlaybackFromOverlaySubview(context.view);
        } else if (context.source == SPKActionButtonSourceDirect) {
            SPKResumeDirectPlaybackFromController(context.controller);
        }
    }];
}

@end

@implementation SPKActionButtonContext
- (instancetype)init {
    if ((self = [super init])) {
        _currentIndexOverride = -1;
    }
    return self;
}
@end

static BOOL SPKIsVideoExtension(NSString *ext) {
    if (ext.length == 0)
        return NO;

    static NSSet<NSString *> *videoExts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoExts = [NSSet setWithArray:@[ @"mp4", @"mov", @"m4v", @"avi", @"webm", @"hevc", @"m3u8" ]];
    });

    return [videoExts containsObject:ext.lowercaseString];
}

static NSString *SPKExtensionForURL(NSURL *url, BOOL isVideo) {
    NSString *ext = url.pathExtension;
    if (ext.length > 0)
        return ext;
    return isVideo ? @"mp4" : @"jpg";
}

static UIViewController *SPKViewControllerForAncestorView(UIView *view) {
    if (!view)
        return nil;

    id candidate = SPKObjectForSelector(view, @"_viewControllerForAncestor");
    if ([candidate isKindOfClass:[UIViewController class]]) {
        return (UIViewController *)candidate;
    }

    return [SPKUtils viewControllerForAncestralView:view];
}

static UIColor *SPKActionButtonTintForSource(SPKActionButtonSource source) {
    switch (source) {
    case SPKActionButtonSourceFeed:
    case SPKActionButtonSourceProfile:
        return [UIColor labelColor];
    case SPKActionButtonSourceReels:
    case SPKActionButtonSourceStories:
    case SPKActionButtonSourceDirect:
    case SPKActionButtonSourceInstants:
    default:
        return [UIColor whiteColor];
    }
}

static NSString *SPKDefaultActionPrefKeyForSource(SPKActionButtonSource source) {
    return SPKPrefActionButtonDefaultActionKey(SPKActionButtonTopicKeyForSource(source));
}

static SPKGallerySource SPKGallerySourceForActionSource(SPKActionButtonSource source) {
    switch (source) {
    case SPKActionButtonSourceFeed:
        return SPKGallerySourceFeed;
    case SPKActionButtonSourceReels:
        return SPKGallerySourceReels;
    case SPKActionButtonSourceStories:
        return SPKGallerySourceStories;
    case SPKActionButtonSourceDirect:
        return SPKGallerySourceDMs;
    case SPKActionButtonSourceProfile:
        return SPKGallerySourceProfile;
    case SPKActionButtonSourceInstants:
        return SPKGallerySourceInstants;
    default:
        return SPKGallerySourceOther;
    }
}

static SPKAudioSource SPKAudioSourceForActionSource(SPKActionButtonSource source) {
    switch (source) {
    case SPKActionButtonSourceFeed:
        return SPKAudioSourceFeed;
    case SPKActionButtonSourceReels:
        return SPKAudioSourceReels;
    case SPKActionButtonSourceStories:
        return SPKAudioSourceStories;
    case SPKActionButtonSourceDirect:
        return SPKAudioSourceDMs;
    case SPKActionButtonSourceProfile:
    case SPKActionButtonSourceInstants:
    default:
        return SPKAudioSourceOther;
    }
}

static NSString *SPKDownloadURLNounForActionSource(SPKActionButtonSource source) {
    switch (source) {
    case SPKActionButtonSourceStories:
        return SPKL(@"COMMON_MEDIA_TYPE_STORY");
    case SPKActionButtonSourceReels:
        return SPKL(@"COMMON_MEDIA_TYPE_REEL");
    case SPKActionButtonSourceFeed:
        return SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_POST_TEXT");
    case SPKActionButtonSourceInstants:
        return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_INSTANT_TEXT");
    case SPKActionButtonSourceDirect:
    default:
        return SPKL(@"FEED_MEDIA_HEADER");
    }
}

static NSString *SPKCopiedDownloadURLTitleForSource(SPKActionButtonSource source, BOOL plural) {
    NSString *urlWord = plural ? SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_URLS_TEXT") : SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_URL_TEXT");
    // Sources whose noun is the generic "Media" read as a redundant "Media download
    // URL copied", so they use the short form. Decided on the source, never by
    // comparing the resolved noun, which is localized.
    switch (source) {
    case SPKActionButtonSourceStories:
    case SPKActionButtonSourceReels:
    case SPKActionButtonSourceFeed:
    case SPKActionButtonSourceInstants:
        return [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_SOURCE_DOWNLOAD_URL_COPIED_FORMAT"), SPKDownloadURLNounForActionSource(source), urlWord];
    default:
        return [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_DOWNLOAD_URL_COPIED_FORMAT"), urlWord];
    }
}

static NSString *SPKProfileStringValue(id value) {
    if (!value)
        return nil;
    if ([value isKindOfClass:[NSString class]])
        return [(NSString *)value length] > 0 ? value : nil;
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *stringValue = [value stringValue];
        return stringValue.length > 0 ? stringValue : nil;
    }
    return nil;
}

static NSString *SPKProfileUserPK(id user) {
    NSString *pk = SPKProfileStringValue(SPKKVCObject(user, @"pk"));
    if (pk.length == 0)
        pk = SPKProfileStringValue(SPKKVCObject(user, @"id"));
    return pk;
}

static NSString *SPKProfileUsername(id user) {
    return SPKProfileStringValue(SPKKVCObject(user, @"username"));
}

static NSString *SPKProfileFullName(id user) {
    for (NSString *key in @[ @"fullName", @"full_name", @"name" ]) {
        NSString *name = SPKProfileStringValue(SPKKVCObject(user, key));
        if (name.length > 0)
            return name;
    }
    return nil;
}

static NSString *SPKProfileBiography(id user) {
    for (NSString *key in @[ @"biography", @"bio" ]) {
        NSString *bio = SPKProfileStringValue(SPKKVCObject(user, key));
        if (bio.length > 0)
            return bio;
    }
    return nil;
}

static NSURL *SPKProfileURL(id user) {
    NSString *username = SPKProfileUsername(user);
    if (username.length == 0)
        return nil;
    NSString *encoded = [username stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    if (encoded.length == 0)
        return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://www.instagram.com/%@/", encoded]];
}

static NSNumber *SPKProfileNumberValue(id value) {
    if (!value)
        return nil;
    if ([value isKindOfClass:[NSNumber class]])
        return value;
    if ([value respondsToSelector:@selector(integerValue)])
        return @([value integerValue]);
    for (NSString *key in @[ @"value", @"number", @"count" ]) {
        id nested = SPKKVCObject(value, key);
        if (nested && nested != value) {
            NSNumber *number = SPKProfileNumberValue(nested);
            if (number)
                return number;
        }
    }
    return nil;
}

static NSNumber *SPKProfileNumericSelectorValue(id target, SEL selector) {
    if (!target || !selector || ![target respondsToSelector:selector])
        return nil;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2)
        return nil;

    const char *type = signature.methodReturnType;
    while (type && (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' || *type == 'O' || *type == 'R' || *type == 'V')) {
        type++;
    }
    if (!type)
        return nil;

    switch (type[0]) {
    case '@':
        return SPKProfileNumberValue(((id (*)(id, SEL))objc_msgSend)(target, selector));
    case 'q':
        return @(((long long (*)(id, SEL))objc_msgSend)(target, selector));
    case 'Q':
        return @(((unsigned long long (*)(id, SEL))objc_msgSend)(target, selector));
    case 'i':
        return @(((int (*)(id, SEL))objc_msgSend)(target, selector));
    case 'I':
        return @(((unsigned int (*)(id, SEL))objc_msgSend)(target, selector));
    case 'l':
        return @(((long (*)(id, SEL))objc_msgSend)(target, selector));
    case 'L':
        return @(((unsigned long (*)(id, SEL))objc_msgSend)(target, selector));
    case 's':
        return @(((short (*)(id, SEL))objc_msgSend)(target, selector));
    case 'S':
        return @(((unsigned short (*)(id, SEL))objc_msgSend)(target, selector));
    default:
        return nil;
    }
}

static BOOL SPKProfileNameMatchesCountKind(NSString *name, BOOL followers) {
    NSString *lower = name.lowercaseString;
    if (![lower containsString:@"count"])
        return NO;
    if (followers) {
        return ([lower containsString:@"follower"] ||
                [lower containsString:@"followedby"] ||
                [lower containsString:@"followed_by"]) &&
               ![lower containsString:@"following"];
    }
    return [lower containsString:@"following"] ||
           [lower containsString:@"followings"] ||
           [lower containsString:@"edgefollow"];
}

static NSNumber *SPKProfileIvarNumberValue(id object, Ivar ivar) {
    if (!object || !ivar)
        return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type)
        return nil;
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' || *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    if (type[0] == '@') {
        @try {
            return SPKProfileNumberValue(object_getIvar(object, ivar));
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }

    ptrdiff_t offset = ivar_getOffset(ivar);
    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)object;
    const void *slot = bytes + offset;
    switch (type[0]) {
    case 'q':
        return @(*(const long long *)slot);
    case 'Q':
        return @(*(const unsigned long long *)slot);
    case 'i':
        return @(*(const int *)slot);
    case 'I':
        return @(*(const unsigned int *)slot);
    case 'l':
        return @(*(const long *)slot);
    case 'L':
        return @(*(const unsigned long *)slot);
    case 's':
        return @(*(const short *)slot);
    case 'S':
        return @(*(const unsigned short *)slot);
    default:
        return nil;
    }
}

static NSString *SPKProfileInfoString(NSNumber *value) {
    if (!value)
        return nil;
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    return [formatter stringFromNumber:value];
}

static NSString *SPKProfilePrivacyText(id user) {
    NSNumber *privacyStatus = SPKProfileNumberValue(SPKKVCObject(user, @"privacyStatus"));
    if (privacyStatus) {
        if (privacyStatus.integerValue == 2)
            return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_PRIVATE_PROFILE_TEXT");
        if (privacyStatus.integerValue == 1)
            return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_PUBLIC_PROFILE_TEXT");
    }

    id privateValue = SPKKVCObject(user, @"isPrivate");
    if (!privateValue)
        privateValue = SPKKVCObject(user, @"privateAccount");
    if (!privateValue)
        privateValue = SPKKVCObject(user, @"isPrivateAccount");
    if ([privateValue respondsToSelector:@selector(boolValue)]) {
        return [privateValue boolValue] ? SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_PRIVATE_PROFILE_TEXT") : SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_PUBLIC_PROFILE_TEXT");
    }

    return nil;
}

static UIAction *SPKProfileDisabledInfoAction(NSString *title, NSString *resourceName) {
    UIAction *action = [UIAction actionWithTitle:title
                                           image:[SPKAssetUtils menuIconNamed:(resourceName.length > 0 ? resourceName : @"info")]
                                      identifier:nil
                                         handler:^(__unused UIAction *menuAction){
                                         }];
    action.attributes = UIMenuElementAttributesDisabled;
    return action;
}

static NSNumber *SPKProfileFollowerCount(id user);
static NSNumber *SPKProfileFollowingCount(id user);

static NSArray<UIMenuElement *> *SPKProfileInfoMenuElements(id user) {
    if (!user)
        return @[];

    NSMutableArray<UIMenuElement *> *infoItems = [NSMutableArray array];
    NSString *privacyText = SPKProfilePrivacyText(user);
    if (privacyText.length > 0) {
        [infoItems addObject:SPKProfileDisabledInfoAction(privacyText, [privacyText containsString:@"Private"] ? @"lock" : @"unlock")];
    }

    NSString *followers = SPKProfileInfoString(SPKProfileFollowerCount(user));
    if (followers.length > 0) {
        [infoItems addObject:SPKProfileDisabledInfoAction([NSString stringWithFormat:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_FOLLOWERS_VALUE_FORMAT"), followers], @"users")];
    }

    NSString *following = SPKProfileInfoString(SPKProfileFollowingCount(user));
    if (following.length > 0) {
        [infoItems addObject:SPKProfileDisabledInfoAction([NSString stringWithFormat:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_FOLLOWING_VALUE_FORMAT"), following], @"users")];
    }

    return infoItems;
}

static NSArray *SPKProfileCountCandidates(id user) {
    if (!user)
        return @[];

    NSMutableArray *candidates = [NSMutableArray arrayWithObject:user];
    NSMutableSet<NSValue *> *seen = [NSMutableSet setWithObject:[NSValue valueWithNonretainedObject:user]];
    NSArray<NSString *> *keys = @[
        @"userGQL", @"profileUser", @"user", @"wrappedUser", @"baseUser",
        @"profile", @"profileModel", @"profileContext", @"profileHeader",
        @"header", @"model", @"viewModel", @"userInfo", @"data", @"fieldCache",
        @"additionalData", @"additionalUserData", @"profileData", @"graphqlUser"
    ];

    for (NSUInteger depth = 0; depth < 2; depth++) {
        NSArray *snapshot = [candidates copy];
        for (id candidate in snapshot) {
            for (NSString *key in keys) {
                id nested = SPKKVCObject(candidate, key) ?: SPKObjectForSelector(candidate, key);
                if (!nested ||
                    [nested isKindOfClass:[NSString class]] ||
                    [nested isKindOfClass:[NSNumber class]] ||
                    [nested isKindOfClass:[NSURL class]]) {
                    continue;
                }
                NSValue *seenKey = [NSValue valueWithNonretainedObject:nested];
                if ([seen containsObject:seenKey])
                    continue;
                [seen addObject:seenKey];
                [candidates addObject:nested];
            }
        }
    }

    return candidates;
}

static NSNumber *SPKProfileCountForUser(id user, NSArray<NSString *> *keys) {
    for (id candidate in SPKProfileCountCandidates(user)) {
        for (NSString *key in keys) {
            NSNumber *value = [SPKUtils numericValueForObj:candidate selectorName:key];
            if (value)
                return value;
            value = SPKProfileNumberValue(SPKObjectForSelector(candidate, key));
            if (value)
                return value;
            value = SPKProfileNumberValue(SPKKVCObject(candidate, key));
            if (value)
                return value;
        }
    }
    return nil;
}

static NSNumber *SPKProfileRuntimeCountForUser(id user, BOOL followers) {
    for (id candidate in SPKProfileCountCandidates(user)) {
        for (Class cls = [candidate class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            for (unsigned int index = 0; index < methodCount; index++) {
                SEL selector = method_getName(methods[index]);
                NSString *name = NSStringFromSelector(selector);
                if (!SPKProfileNameMatchesCountKind(name, followers))
                    continue;
                NSNumber *value = SPKProfileNumericSelectorValue(candidate, selector);
                if (value) {
                    free(methods);
                    return value;
                }
            }
            free(methods);

            unsigned int ivarCount = 0;
            Ivar *ivars = class_copyIvarList(cls, &ivarCount);
            for (unsigned int index = 0; index < ivarCount; index++) {
                NSString *name = [NSString stringWithUTF8String:ivar_getName(ivars[index]) ?: ""];
                if (!SPKProfileNameMatchesCountKind(name, followers))
                    continue;
                NSNumber *value = SPKProfileIvarNumberValue(candidate, ivars[index]);
                if (value) {
                    free(ivars);
                    return value;
                }
            }
            free(ivars);
        }
    }
    return nil;
}

static NSNumber *SPKProfileFollowerCount(id user) {
    NSNumber *value = SPKProfileCountForUser(user, @[
        @"followerCount",
        @"followersCount",
        @"follower_count",
        @"followers_count",
        @"edgeFollowedBy",
        @"edge_followed_by",
        @"followedByCount",
        @"followed_by_count"
    ]);
    return value ?: SPKProfileRuntimeCountForUser(user, YES);
}

static NSNumber *SPKProfileFollowingCount(id user) {
    NSNumber *value = SPKProfileCountForUser(user, @[
        @"followingCount",
        @"followingsCount",
        @"following_count",
        @"followings_count",
        @"edgeFollow",
        @"edge_follow",
        @"followCount"
    ]);
    return value ?: SPKProfileRuntimeCountForUser(user, NO);
}

static NSString *SPKProfileInfoSignature(id user) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *privacy = SPKProfilePrivacyText(user);
    if (privacy.length > 0)
        [parts addObject:privacy];
    NSString *followers = SPKProfileInfoString(SPKProfileFollowerCount(user));
    if (followers.length > 0)
        [parts addObject:[NSString stringWithFormat:SPKL(@"ACTION_BUTTON_MEDIA_STATS_FOLLOWERS_FORMAT"), followers]];
    NSString *following = SPKProfileInfoString(SPKProfileFollowingCount(user));
    if (following.length > 0)
        [parts addObject:[NSString stringWithFormat:SPKL(@"ACTION_BUTTON_MEDIA_STATS_FOLLOWING_FORMAT"), following]];
    return [parts componentsJoinedByString:@"|"];
}

static NSString *SPKProfileDefaultCopyInfoIdentifier(void) {
    NSString *identifier = [SPKUtils getStringPref:@"profile_action_btn_default_copy_info_action"] ?: kSPKActionProfileCopyUsername;
    NSDictionary<NSString *, NSString *> *legacyMap = @{
        @"id" : kSPKActionProfileCopyID,
        @"username" : kSPKActionProfileCopyUsername,
        @"name" : kSPKActionProfileCopyName,
        @"bio" : kSPKActionProfileCopyBio,
        @"link" : kSPKActionProfileCopyLink
    };
    identifier = legacyMap[identifier] ?: identifier;
    NSSet<NSString *> *supported = [NSSet setWithArray:@[
        kSPKActionProfileCopyID,
        kSPKActionProfileCopyUsername,
        kSPKActionProfileCopyName,
        kSPKActionProfileCopyBio,
        kSPKActionProfileCopyLink
    ]];
    return [supported containsObject:identifier] ? identifier : kSPKActionProfileCopyUsername;
}

static NSString *SPKProfileCopyValueForIdentifier(id user, NSString *identifier) {
    if ([identifier isEqualToString:kSPKActionProfileCopyID])
        return SPKProfileUserPK(user);
    if ([identifier isEqualToString:kSPKActionProfileCopyName])
        return SPKProfileFullName(user);
    if ([identifier isEqualToString:kSPKActionProfileCopyBio])
        return SPKProfileBiography(user);
    if ([identifier isEqualToString:kSPKActionProfileCopyLink])
        return SPKProfileURL(user).absoluteString;
    return SPKProfileUsername(user);
}

static NSString *SPKProfileCopySuccessTitleForIdentifier(NSString *identifier) {
    if ([identifier isEqualToString:kSPKActionProfileCopyID])
        return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_ID_COPIED_TEXT");
    if ([identifier isEqualToString:kSPKActionProfileCopyName])
        return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NAME_COPIED_TEXT");
    if ([identifier isEqualToString:kSPKActionProfileCopyBio])
        return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_BIO_COPIED_TEXT");
    if ([identifier isEqualToString:kSPKActionProfileCopyLink])
        return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_PROFILE_LINK_COPIED_TEXT");
    return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_USERNAME_COPIED_TEXT");
}

static BOOL SPKIsProfileCopyActionIdentifier(NSString *identifier) {
    return [@[
        kSPKActionProfileCopyInfo,
        kSPKActionProfileCopyID,
        kSPKActionProfileCopyUsername,
        kSPKActionProfileCopyName,
        kSPKActionProfileCopyBio,
        kSPKActionProfileCopyLink
    ] containsObject:identifier];
}

static BOOL SPKExecuteProfileCopyAction(NSString *identifier, SPKActionButtonContext *context) {
    id user = SPKResolveMediaForContext(context);
    if (!user) {
        SPKNotify(kSPKActionProfileCopyInfo, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_PROFILE_UNAVAILABLE_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return YES;
    }
    NSString *copyIdentifier = [identifier isEqualToString:kSPKActionProfileCopyInfo] ? SPKProfileDefaultCopyInfoIdentifier() : identifier;
    NSString *value = SPKProfileCopyValueForIdentifier(user, copyIdentifier);
    if (value.length == 0) {
        SPKNotify(kSPKActionProfileCopyInfo, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NOTHING_COPY_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return YES;
    }
    UIPasteboard.generalPasteboard.string = value;
    SPKNotify(kSPKActionProfileCopyInfo, SPKProfileCopySuccessTitleForIdentifier(copyIdentifier), nil, @"circle_check_filled", SPKNotificationToneSuccess);
    return YES;
}

static BOOL SPKActionMediaLooksLikeReel(id media) {
    if (!media)
        return NO;
    for (NSString *selectorName in @[ @"isReelMedia", @"isClipsMedia", @"isClipsItem", @"isReel", @"isInstagramReel" ]) {
        NSNumber *value = [SPKUtils numericValueForObj:media selectorName:selectorName];
        if (value.boolValue)
            return YES;
    }
    for (NSString *key in @[ @"productType", @"mediaType", @"mediaSource", @"inventorySource", @"clipsTabEntryPoint" ]) {
        NSString *value = SPKStringFromValue(SPKObjectForSelector(media, key));
        if (value.length == 0)
            value = SPKStringFromValue(SPKKVCObject(media, key));
        NSString *lower = value.lowercaseString;
        if ([lower containsString:@"clips"] || [lower containsString:@"reel"])
            return YES;
    }
    return NO;
}

static SPKGallerySaveMetadata *SPKGalleryMetadata(SPKActionButtonSource source, NSString *username, id media) {
    SPKGallerySaveMetadata *meta = [[SPKGallerySaveMetadata alloc] init];
    SPKGallerySource gallerySource = SPKGallerySourceForActionSource(source);
    if (source == SPKActionButtonSourceFeed && SPKActionMediaLooksLikeReel(media)) {
        gallerySource = SPKGallerySourceReels;
    }
    meta.source = (int16_t)gallerySource;
    if (username.length > 0) {
        meta.sourceUsername = username;
    }
    if (source == SPKActionButtonSourceProfile) {
        [SPKGalleryOriginController populateProfileMetadata:meta username:username user:media];
    } else {
        [SPKGalleryOriginController populateMetadata:meta fromMedia:media];
    }
    return meta;
}

static NSString *SPKExplicitSourceUsernameFromObject(id object) {
    NSString *username = SPKStringFromValue(SPKObjectForSelector(object, @"sourceUsername") ?: SPKKVCObject(object, @"sourceUsername"));
    return username.length > 0 ? username : nil;
}

static NSDate *SPKDateFromActionValue(id value) {
    if ([value isKindOfClass:NSDate.class])
        return (NSDate *)value;
    if ([value respondsToSelector:@selector(doubleValue)]) {
        double timestamp = [value doubleValue];
        if (timestamp <= 0)
            return nil;
        if (timestamp > 100000000000.0)
            timestamp /= 1000.0;
        return [NSDate dateWithTimeIntervalSince1970:timestamp];
    }
    return nil;
}

static NSString *SPKUsernameForEntry(SPKResolvedMediaEntry *entry, NSString *fallbackUsername) {
    NSString *username = entry.sourceUsername;
    if (username.length == 0)
        username = SPKExplicitSourceUsernameFromObject(entry.metadataObject ?: entry.mediaObject);
    if (username.length == 0)
        username = SPKExplicitSourceUsernameFromObject(entry.mediaObject);
    if (username.length == 0)
        username = SPKUsernameFromMediaObject(entry.metadataObject ?: entry.mediaObject);
    if (username.length == 0)
        username = fallbackUsername;
    return username;
}

static void SPKApplyEntryMetadata(SPKGallerySaveMetadata *meta, SPKResolvedMediaEntry *entry) {
    if (!meta || !entry)
        return;
    if (entry.sourceUsername.length > 0)
        meta.sourceUsername = entry.sourceUsername;
    if (entry.sourceMediaPK.length > 0)
        meta.sourceMediaPK = entry.sourceMediaPK;
    if (entry.sourceMediaURLString.length > 0)
        meta.sourceMediaURLString = entry.sourceMediaURLString;
    if (entry.importPostedDate)
        meta.importPostedDate = entry.importPostedDate;
}

extern "C" NSString *SPKActionButtonTitleForIdentifier(NSString *identifier) {
    return SPKActionDescriptorDisplayTitle(identifier, nil);
}

static NSArray<NSString *> *SPKBulkActionChildIdentifiers(void) {
    return @[
        kSPKActionDownloadAllLibrary,
        kSPKActionDownloadAllShare,
        kSPKActionDownloadAllGallery,
        kSPKActionDownloadAllClipboard,
        kSPKActionDownloadAllLinks
    ];
}

static BOOL SPKIsBulkChildActionIdentifier(NSString *identifier) {
    return [SPKBulkActionChildIdentifiers() containsObject:identifier];
}

static BOOL SPKIsBulkDownloadActionIdentifier(NSString *identifier) {
    return [@[
        kSPKActionDownloadAllLibrary,
        kSPKActionDownloadAllShare,
        kSPKActionDownloadAllGallery
    ] containsObject:identifier];
}

static BOOL SPKIsBulkCopyActionIdentifier(NSString *identifier) {
    return [@[
        kSPKActionDownloadAllClipboard,
        kSPKActionDownloadAllLinks
    ] containsObject:identifier];
}

static NSString *SPKBaseActionIdentifierForBulkChild(NSString *identifier) {
    if ([identifier isEqualToString:kSPKActionDownloadAllLibrary])
        return kSPKActionDownloadLibrary;
    if ([identifier isEqualToString:kSPKActionDownloadAllShare])
        return kSPKActionDownloadShare;
    if ([identifier isEqualToString:kSPKActionDownloadAllGallery])
        return kSPKActionDownloadGallery;
    if ([identifier isEqualToString:kSPKActionDownloadAllClipboard])
        return kSPKActionCopyMedia;
    if ([identifier isEqualToString:kSPKActionDownloadAllLinks])
        return kSPKActionCopyDownloadLink;
    return identifier;
}

static SPKStoryContext *SPKStoryContextForActionButtonContext(SPKActionButtonContext *context) {
    if (context.source != SPKActionButtonSourceStories)
        return nil;
    SPKStoryContext *storyContext = SPKStoryContextFromView(context.view);
    if (storyContext)
        return storyContext;
    return SPKStoryContextFromOverlay(SPKStoryActiveOverlay());
}

// Author of the instant on screen. Read from the author label only -- resolving the
// snap itself is far too expensive for menu construction, and can fall back to
// re-encoding the screen.
//
// Even the label lookup is a breadth-first walk of the whole window, and building one
// menu asks for the author four times (availability, title, icon, signature). The
// answer is memoized for long enough to collapse those into a single walk and no
// longer: the author only changes when the user taps to the next instant, which cannot
// happen and be followed by a menu build inside the window below.
static NSString *SPKInstantsAutoSaveUsernameForContext(SPKActionButtonContext *context) {
    if (!context || context.source != SPKActionButtonSourceInstants)
        return nil;
    UIView *view = context.view ?: context.controller.view;
    if (!view)
        return nil;

    static const CFTimeInterval kMemoWindow = 0.2;
    static NSString *memoUsername = nil;
    static __weak UIView *memoView = nil;
    static CFTimeInterval memoTime = 0;

    CFTimeInterval now = CACurrentMediaTime();
    if (memoView == view && (now - memoTime) < kMemoWindow)
        return memoUsername;

    memoUsername = SPKInstantsResolveCurrentAuthorUsername(view);
    memoView = view;
    memoTime = now;
    return memoUsername;
}

static NSString *SPKActionButtonDisplayTitleForContext(NSString *identifier,
                                                       SPKActionButtonContext *context,
                                                       SPKResolvedMediaEntry *currentEntry) {
    if ([identifier isEqualToString:kSPKActionToggleStorySeenUserRule]) {
        NSString *title = SPKStoryCurrentUserRuleActionTitle(SPKStoryContextForActionButtonContext(context));
        return title ?: SPKActionDescriptorDisplayTitle(identifier, context.settingsTitle);
    }
    if ([identifier isEqualToString:kSPKActionToggleStoryAutoSaveUserRule]) {
        NSString *title = SPKStoryAutoSaveCurrentUserActionTitle(SPKStoryContextForActionButtonContext(context));
        return title ?: SPKActionDescriptorDisplayTitle(identifier, context.settingsTitle);
    }
    if ([identifier isEqualToString:kSPKActionToggleDirectAutoSaveThreadRule]) {
        NSString *title = SPKDirectAutoSaveCurrentThreadActionTitle(SPKDirectThreadContextFromSource(context.controller));
        return title ?: SPKActionDescriptorDisplayTitle(identifier, context.settingsTitle);
    }
    if ([identifier isEqualToString:kSPKActionToggleInstantsAutoSaveUserRule]) {
        NSString *title = SPKInstantsAutoSaveActionTitleForUsername(SPKInstantsAutoSaveUsernameForContext(context));
        return title ?: SPKActionDescriptorDisplayTitle(identifier, context.settingsTitle);
    }
    if ([identifier isEqualToString:kSPKActionToggleProfileStorySeenUserRule]) {
        id user = SPKResolveMediaForContext(context);
        NSString *pk = user ? [SPKUtils pkFromIGUser:user] : nil;
        if (pk.length > 0) {
            BOOL manualSeenEnabled = SPKStoryManualSeenEnabled();
            BOOL listed = SPKStoryManualSeenListContainsUser(pk, manualSeenEnabled);
            BOOL applies = manualSeenEnabled ? !listed : listed;
            return applies ? SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_START_MARKING_STORIES_SEEN_TEXT") : SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_STOP_MARKING_STORIES_SEEN_TEXT");
        }
        return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_TOGGLE_STORY_SEEN_TEXT");
    }
    if ([identifier isEqualToString:kSPKActionToggleProfileMessagesSeenUserRule]) {
        id user = SPKResolveMediaForContext(context);
        NSString *pk = user ? [SPKUtils pkFromIGUser:user] : nil;
        if (pk.length > 0) {
            BOOL manualSeenEnabled = [SPKUtils getBoolPref:@"msgs_manual_seen"];
            NSDictionary *existingEntry = SPKDirectManualSeenThreadEntryForUserPK(pk, manualSeenEnabled);
            BOOL listed = (existingEntry != nil);
            BOOL applies = manualSeenEnabled ? !listed : listed;
            return applies ? SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_START_MARKING_MESSAGES_SEEN_MESSAGE") : SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_STOP_MARKING_MESSAGES_SEEN_MESSAGE");
        }
        return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_TOGGLE_MESSAGES_SEEN_MESSAGE");
    }
    if ([identifier isEqualToString:kSPKActionCopyMedia]) {
        BOOL isVideo = (currentEntry.videoURL != nil);
        if (isVideo) {
            return (context.source == SPKActionButtonSourceReels) ? SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPY_REEL_TEXT") : SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPY_VIDEO_TEXT");
        }
        return SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPY_PHOTO_TEXT");
    }
    return SPKActionDescriptorDisplayTitle(identifier, context.settingsTitle);
}

static NSString *SPKResolvedSettingsTitleForContext(SPKActionButtonContext *context) {
    if (context.settingsTitle.length > 0)
        return context.settingsTitle;
    return SPKActionButtonTopicTitleForSource(context.source);
}

static BOOL SPKStoryMediaHasMentions(id media) {
    NSArray *mentions = SPKArrayFromCollection(SPKObjectForSelector(media, @"reelMentions") ?: SPKKVCObject(media, @"reelMentions"));
    return mentions.count > 0;
}

NSString *SPKActionButtonOpenMenuIconName(void) {
    NSString *name = [SPKUtils getStringPref:@"general_action_btn_default_menu_icon"];
    return name.length > 0 ? name : @"action";
}

static UIImage *SPKIconForActionIdentifier(NSString *identifier, SPKActionButtonSource source, CGFloat size, SPKActionButtonContext *context) {
    if (SPKIsBulkChildActionIdentifier(identifier)) {
        return SPKIconForActionIdentifier(SPKBaseActionIdentifierForBulkChild(identifier), source, size, context);
    }

    NSString *iconName = [identifier isEqualToString:kSPKActionNone]
                             ? SPKActionButtonOpenMenuIconName()
                             : SPKActionDescriptorIconName(identifier);

    if (source == SPKActionButtonSourceReels) {
        NSString *reelsIconName = [iconName stringByAppendingString:@"_reels"];
        UIImage *reelsImage = [SPKAssetUtils resolvedImageNamed:reelsIconName
                                             fallbackSystemName:nil
                                                      pointSize:size
                                                         weight:UIImageSymbolWeightUnspecified
                                                         source:SPKResolvedImageSourceInstagramIcon
                                                  renderingMode:UIImageRenderingModeAlwaysTemplate];
        if (reelsImage) {
            return reelsImage;
        }
    }

    if ([identifier isEqualToString:kSPKActionToggleStorySeenUserRule]) {
        SPKStoryContext *storyCtx = SPKStoryContextForActionButtonContext(context);
        BOOL applies = storyCtx ? SPKStoryManualSeenAppliesToContext(storyCtx) : YES;
        return [SPKAssetUtils instagramIconNamed:applies ? @"eye_off" : @"eye" pointSize:size];
    }
    if ([identifier isEqualToString:kSPKActionToggleStoryAutoSaveUserRule]) {
        SPKStoryContext *storyCtx = SPKStoryContextForActionButtonContext(context);
        BOOL applies = storyCtx ? SPKStoryAutoSaveAppliesToCurrentUser(storyCtx) : NO;
        return [SPKAssetUtils instagramIconNamed:applies ? @"download_off" : @"download" pointSize:size];
    }
    if ([identifier isEqualToString:kSPKActionToggleDirectAutoSaveThreadRule]) {
        SPKDirectThreadContext *threadCtx = SPKDirectThreadContextFromSource(context.controller);
        BOOL applies = threadCtx ? SPKDirectAutoSaveAppliesToCurrentThread(threadCtx) : NO;
        return [SPKAssetUtils instagramIconNamed:applies ? @"download_off" : @"download" pointSize:size];
    }
    if ([identifier isEqualToString:kSPKActionToggleInstantsAutoSaveUserRule]) {
        NSString *username = SPKInstantsAutoSaveUsernameForContext(context);
        BOOL applies = username.length > 0 ? SPKInstantsAutoSaveAppliesToUsername(username) : NO;
        return [SPKAssetUtils instagramIconNamed:applies ? @"download_off" : @"download" pointSize:size];
    }
    if ([identifier isEqualToString:kSPKActionToggleProfileStorySeenUserRule]) {
        id user = context ? SPKResolveMediaForContext(context) : nil;
        NSString *pk = user ? [SPKUtils pkFromIGUser:user] : nil;
        BOOL applies = YES;
        if (pk.length > 0) {
            BOOL manualSeenEnabled = SPKStoryManualSeenEnabled();
            BOOL listed = SPKStoryManualSeenListContainsUser(pk, manualSeenEnabled);
            applies = manualSeenEnabled ? !listed : listed;
        }
        return [SPKAssetUtils instagramIconNamed:applies ? @"eye_off" : @"eye" pointSize:size];
    }
    if ([identifier isEqualToString:kSPKActionToggleProfileMessagesSeenUserRule]) {
        id user = context ? SPKResolveMediaForContext(context) : nil;
        NSString *pk = user ? [SPKUtils pkFromIGUser:user] : nil;
        BOOL applies = YES;
        if (pk.length > 0) {
            BOOL manualSeenEnabled = [SPKUtils getBoolPref:@"msgs_manual_seen"];
            NSDictionary *existingEntry = SPKDirectManualSeenThreadEntryForUserPK(pk, manualSeenEnabled);
            applies = manualSeenEnabled ? !(existingEntry != nil) : (existingEntry != nil);
        }
        return [SPKAssetUtils instagramIconNamed:applies ? @"eye_off" : @"eye" pointSize:size];
    }

    return [SPKAssetUtils instagramIconNamed:iconName pointSize:size];
}

static SPKFullScreenPlaybackSource SPKPlaybackSourceForActionSource(SPKActionButtonSource source) {
    switch (source) {
    case SPKActionButtonSourceFeed:
        return SPKFullScreenPlaybackSourceFeed;
    case SPKActionButtonSourceProfile:
        return SPKFullScreenPlaybackSourceProfile;
    case SPKActionButtonSourceReels:
        return SPKFullScreenPlaybackSourceReels;
    case SPKActionButtonSourceStories:
        return SPKFullScreenPlaybackSourceStories;
    case SPKActionButtonSourceDirect:
        return SPKFullScreenPlaybackSourceDirect;
    case SPKActionButtonSourceInstants:
        return SPKFullScreenPlaybackSourceInstants;
    default:
        return SPKFullScreenPlaybackSourceUnknown;
    }
}

static void SPKPausePlaybackForPreviewContext(SPKActionButtonContext *context) {
    if (!context)
        return;

    switch (context.source) {
    case SPKActionButtonSourceStories:
        SPKPauseStoryPlaybackFromOverlaySubview(context.view);
        return;
    case SPKActionButtonSourceDirect:
        SPKPauseDirectPlaybackFromController(context.controller);
        return;
    case SPKActionButtonSourceFeed:
    case SPKActionButtonSourceReels:
    case SPKActionButtonSourceProfile:
    default:
        return;
    }
}

static void SPKResumePlaybackForPreviewContext(SPKActionButtonContext *context) {
    if (!context)
        return;

    switch (context.source) {
    case SPKActionButtonSourceStories:
        SPKResumeStoryPlaybackFromOverlaySubview(context.view);
        return;
    case SPKActionButtonSourceDirect:
        SPKResumeDirectPlaybackFromController(context.controller);
        return;
    case SPKActionButtonSourceFeed:
    case SPKActionButtonSourceReels:
    case SPKActionButtonSourceProfile:
    default:
        return;
    }
}

static BOOL SPKActionIdentifierOpensPreview(NSString *identifier) {
    return [identifier isEqualToString:kSPKActionExpand] ||
           [identifier isEqualToString:kSPKActionViewThumbnail] ||
           [identifier isEqualToString:kSPKActionStoryMentionsSheet];
}

static SPKMediaPreviewPlaybackBlock SPKPausePlaybackBlockForContext(SPKActionButtonContext *context) {
    if (!context)
        return nil;
    __weak UIView *sourceView = context.view;
    __weak UIViewController *sourceController = context.controller;
    SPKActionButtonSource source = context.source;
    return [^{
        SPKActionButtonContext *previewContext = [[SPKActionButtonContext alloc] init];
        previewContext.source = source;
        previewContext.view = sourceView;
        previewContext.controller = sourceController;
        SPKPausePlaybackForPreviewContext(previewContext);
    } copy];
}

static SPKMediaPreviewPlaybackBlock SPKResumePlaybackBlockForContext(SPKActionButtonContext *context) {
    if (!context)
        return nil;
    __weak UIView *sourceView = context.view;
    __weak UIViewController *sourceController = context.controller;
    SPKActionButtonSource source = context.source;
    return [^{
        SPKActionButtonContext *previewContext = [[SPKActionButtonContext alloc] init];
        previewContext.source = source;
        previewContext.view = sourceView;
        previewContext.controller = sourceController;
        SPKResumePlaybackForPreviewContext(previewContext);
    } copy];
}

// Load at native size (0 = no downscale) and reinterpret to 22pt via
// menuSizedIcon:. Requesting a sub-native size here would send the icon through
// SPKAssetScaleImage's UIGraphicsImageRenderer pass, which iOS 16's UIMenu
// renders blank for vector-backed (.svg) glyphs. `size` is kept for API compat.
UIImage *SPKActionButtonMenuIconForIdentifier(NSString *identifier, CGFloat size) {
    (void)size;
    UIImage *icon = SPKIconForActionIdentifier(identifier, SPKActionButtonSourceFeed, 0, nil);
    return [SPKAssetUtils menuSizedIcon:icon];
}

static UIImage *SPKActionButtonMenuIconForContext(NSString *identifier, SPKActionButtonContext *context, CGFloat size) {
    (void)size;
    SPKActionButtonSource menuSource = (context.source == SPKActionButtonSourceReels)
                                           ? SPKActionButtonSourceFeed
                                           : context.source;
    UIImage *icon = SPKIconForActionIdentifier(identifier, menuSource, 0, context);
    return [SPKAssetUtils menuSizedIcon:icon];
}

static NSInteger SPKClampedIndex(NSInteger index, NSInteger count) {
    if (count <= 0)
        return 0;
    if (index < 0)
        return 0;
    if (index >= count)
        return count - 1;
    return index;
}

static NSURL *SPKURLFromURLCollectionValue(id collection) {
    if (!collection)
        return nil;

    NSArray *items = SPKArrayFromCollection(collection);
    if (!items)
        return SPKURLFromValue(collection);

    for (id item in items) {
        NSURL *url = nil;
        if ([item isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)item;
            url = SPKURLFromValue(dict[@"url"] ?: dict[@"urlString"]);
        } else {
            url = SPKURLFromValue(SPKObjectForSelector(item, @"url"));
            if (!url)
                url = SPKURLFromValue(SPKObjectForSelector(item, @"urlString"));
            if (!url)
                url = SPKURLFromValue(item);
        }
        if (url)
            return url;
    }

    return nil;
}

static NSURL *SPKURLFromAssetLikeObject(id object, BOOL videoHint) {
    if (!object)
        return nil;

    NSArray<NSString *> *primarySelectors = videoHint
                                                ? @[ @"videoURL", @"videoUrl", @"downloadURL", @"url", @"urlString" ]
                                                : @[ @"imageURL", @"imageUrl", @"displayURL", @"thumbnailURL", @"url", @"urlString" ];

    for (NSString *selectorName in primarySelectors) {
        NSURL *url = SPKURLFromValue(SPKObjectForSelector(object, selectorName));
        if (!url)
            url = SPKURLFromValue(SPKKVCObject(object, selectorName));
        if (url)
            return url;
    }

    if (videoHint) {
        for (NSString *selectorName in @[ @"allVideoURLs", @"sortedVideoURLsBySize", @"videoURLs", @"videoUrls" ]) {
            NSURL *url = SPKURLFromURLCollectionValue(SPKObjectForSelector(object, selectorName));
            if (!url)
                url = SPKURLFromURLCollectionValue(SPKKVCObject(object, selectorName));
            if (url)
                return url;
        }
    } else {
        SEL imageURLForWidth = NSSelectorFromString(SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_IMAGEURLFORWIDTH_TEXT"));
        if ([object respondsToSelector:imageURLForWidth]) {
            NSURL *url = ((id (*)(id, SEL, CGFloat))objc_msgSend)(object, imageURLForWidth, 100000.0);
            if ([url isKindOfClass:[NSURL class]])
                return url;
        }
    }

    return nil;
}

static id SPKFieldCacheValue(id obj, NSString *key) {
    if (!obj || key.length == 0)
        return nil;

    static Ivar fieldCacheIvar = NULL;
    static Class storableClass = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        storableClass = NSClassFromString(@"IGAPIStorableObject");
        if (storableClass) {
            fieldCacheIvar = class_getInstanceVariable(storableClass, "_fieldCache");
        }
    });

    if (!fieldCacheIvar || !storableClass || ![obj isKindOfClass:storableClass])
        return nil;

    id fieldCache = nil;
    @try {
        fieldCache = object_getIvar(obj, fieldCacheIvar);
    } @catch (__unused NSException *exception) {
        return nil;
    }

    if (![fieldCache isKindOfClass:[NSDictionary class]])
        return nil;
    id value = ((NSDictionary *)fieldCache)[key];
    if (!value || [value isKindOfClass:[NSNull class]])
        return nil;
    return value;
}

static id SPKUnderlyingMediaObjectForAction(id object) {
    if (!object)
        return nil;

    if ([SPKUtils getPhotoUrlForMedia:object] || [SPKUtils getVideoUrlForMedia:object]) {
        return object;
    }

    for (NSString *selectorName in @[ @"photo", @"rawPhoto", @"video", @"rawVideo" ]) {
        id nestedAsset = SPKObjectForSelector(object, selectorName);
        if (!nestedAsset)
            nestedAsset = SPKKVCObject(object, selectorName);
        if (nestedAsset && nestedAsset != object) {
            return object;
        }
    }

    for (NSString *selectorName in @[ @"media", @"item", @"storyItem", @"visualMessage", @"explorePostInFeed", @"rootItem", @"clipsItem", @"clipsMedia", @"post" ]) {
        id nested = SPKObjectForSelector(object, selectorName);
        if (!nested)
            nested = SPKKVCObject(object, selectorName);
        if (nested && nested != object) {
            id resolved = SPKUnderlyingMediaObjectForAction(nested);
            if (resolved)
                return resolved;
        }
    }

    return object;
}

static NSURL *SPKBestCandidatePhotoURLFromCandidates(id candidates) {
    if (![candidates isKindOfClass:[NSArray class]] || [(NSArray *)candidates count] == 0) {
        return nil;
    }

    NSDictionary *bestCandidate = nil;
    NSInteger bestWidth = 0;
    for (id candidate in (NSArray *)candidates) {
        if (![candidate isKindOfClass:[NSDictionary class]])
            continue;
        NSInteger width = [((NSDictionary *)candidate)[@"width"] integerValue];
        if (width > bestWidth) {
            bestWidth = width;
            bestCandidate = candidate;
        }
    }

    NSString *urlString = bestCandidate[@"url"];
    return urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
}

static NSString *SPKMediaPKForMediaObject(id mediaObject) {
    if (!mediaObject)
        return nil;
    for (NSString *selectorName in @[ @"pk", @"mediaID", @"id", @"mediaId", @"mediaIdentifier" ]) {
        id value = SPKObjectForSelector(mediaObject, selectorName);
        if (!value)
            value = SPKKVCObject(mediaObject, selectorName);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
        if ([value respondsToSelector:@selector(stringValue)]) {
            NSString *strVal = [value stringValue];
            if (strVal.length > 0)
                return strVal;
        }
    }
    return nil;
}

static NSURL *SPKHDPhotoURLForMediaObject(id mediaObject) {
    NSString *mediaPK = SPKMediaPKForMediaObject(mediaObject);
    if (mediaPK.length > 0) {
        NSArray *webCandidates = [SPKMediaQualityManager webPhotoCandidatesForPK:mediaPK];
        NSURL *webCacheURL = SPKBestCandidatePhotoURLFromCandidates(webCandidates);
        if (webCacheURL)
            return webCacheURL;
    }

    id imageVersions = SPKFieldCacheValue(mediaObject, @"image_versions2");
    id candidates = [imageVersions isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)imageVersions)[@"candidates"] : nil;
    if (!candidates) {
        candidates = SPKFieldCacheValue(mediaObject, @"candidates");
    }

    NSURL *fieldCacheURL = SPKBestCandidatePhotoURLFromCandidates(candidates);
    if (fieldCacheURL)
        return fieldCacheURL;

    id photoObject = SPKObjectForSelector(mediaObject, @"photo");
    if (!photoObject)
        return nil;

    Ivar originalVersionsIvar = class_getInstanceVariable([photoObject class], "_originalImageVersions");
    if (!originalVersionsIvar)
        return nil;

    id originalVersions = nil;
    @try {
        originalVersions = object_getIvar(photoObject, originalVersionsIvar);
    } @catch (__unused NSException *exception) {
        return nil;
    }

    if (![originalVersions isKindOfClass:[NSArray class]] || [(NSArray *)originalVersions count] == 0) {
        return nil;
    }

    NSURL *bestURL = nil;
    NSInteger bestWidth = 0;
    for (id item in (NSArray *)originalVersions) {
        NSURL *url = nil;
        NSInteger width = 0;
        if ([item isKindOfClass:[NSDictionary class]]) {
            NSString *urlString = ((NSDictionary *)item)[@"url"];
            if (urlString.length > 0)
                url = [NSURL URLWithString:urlString];
            width = [((NSDictionary *)item)[@"width"] integerValue];
        } else {
            if ([item respondsToSelector:@selector(url)]) {
                url = SPKURLFromValue([item valueForKey:@"url"]);
            }
            if ([item respondsToSelector:@selector(width)]) {
                width = [[item valueForKey:@"width"] integerValue];
            }
        }
        if (url && width > bestWidth) {
            bestWidth = width;
            bestURL = url;
        }
    }

    return bestURL;
}

static NSURL *SPKFieldCachePhotoURLForMediaObject(id mediaObject) {
    id imageVersions = SPKFieldCacheValue(mediaObject, @"image_versions2");
    id candidates = [imageVersions isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)imageVersions)[@"candidates"] : nil;
    if (!candidates) {
        candidates = SPKFieldCacheValue(mediaObject, @"candidates");
    }
    return SPKBestCandidatePhotoURLFromCandidates(candidates);
}

static NSURL *SPKBestDownloadURLForMediaObject(id mediaObject) {
    if (!mediaObject)
        return nil;

    mediaObject = SPKUnderlyingMediaObjectForAction(mediaObject);

    NSURL *videoURL = [SPKUtils getVideoUrlForMedia:mediaObject];
    if (videoURL)
        return videoURL;

    NSURL *hdPhotoURL = SPKHDPhotoURLForMediaObject(mediaObject);
    if (hdPhotoURL)
        return hdPhotoURL;

    NSURL *photoURL = [SPKUtils getPhotoUrlForMedia:mediaObject];
    if (photoURL)
        return photoURL;

    return SPKFieldCachePhotoURLForMediaObject(mediaObject);
}

static NSURL *SPKCoverURLForMediaObject(id mediaObject) {
    if (!mediaObject)
        return nil;

    mediaObject = SPKUnderlyingMediaObjectForAction(mediaObject);

    NSURL *hdPhotoURL = SPKHDPhotoURLForMediaObject(mediaObject);
    if (hdPhotoURL)
        return hdPhotoURL;

    NSURL *photoURL = [SPKUtils getPhotoUrlForMedia:mediaObject];
    if (photoURL)
        return photoURL;

    return SPKFieldCachePhotoURLForMediaObject(mediaObject);
}

static SPKResolvedMediaEntry *SPKEntryFromMediaObject(id mediaObject) {
    if (!mediaObject)
        return nil;

    NSURL *instantsURL = SPKURLFromValue(SPKObjectForSelector(mediaObject, @"sparkleMediaURL") ?: SPKKVCObject(mediaObject, @"sparkleMediaURL"));
    NSURL *instantsPhotoURL = SPKURLFromValue(SPKObjectForSelector(mediaObject, @"sparklePhotoURL") ?: SPKKVCObject(mediaObject, @"sparklePhotoURL"));
    NSURL *instantsVideoURL = SPKURLFromValue(SPKObjectForSelector(mediaObject, @"sparkleVideoURL") ?: SPKKVCObject(mediaObject, @"sparkleVideoURL"));
    NSNumber *instantsIsVideoNumber = [SPKUtils numericValueForObj:mediaObject selectorName:@"sparkleIsVideo"];
    BOOL instantsHasHint = instantsURL || instantsPhotoURL || instantsVideoURL || instantsIsVideoNumber != nil;
    if (instantsHasHint) {
        SPKResolvedMediaEntry *entry = [[SPKResolvedMediaEntry alloc] init];
        entry.mediaObject = mediaObject;
        entry.metadataObject = mediaObject;
        entry.sourceUsername = SPKExplicitSourceUsernameFromObject(mediaObject);
        entry.sourceMediaPK = SPKStringFromValue(SPKObjectForSelector(mediaObject, @"sourceMediaPK") ?: SPKKVCObject(mediaObject, @"sourceMediaPK"));
        entry.sourceMediaURLString = SPKStringFromValue(SPKObjectForSelector(mediaObject, @"sourceMediaURLString") ?: SPKKVCObject(mediaObject, @"sourceMediaURLString"));
        entry.importPostedDate = SPKDateFromActionValue(SPKObjectForSelector(mediaObject, @"importPostedDate") ?: SPKKVCObject(mediaObject, @"importPostedDate") ?
                                                                                                              : SPKObjectForSelector(mediaObject, @"takenAt")    ?
                                                                                                                                                                 : SPKKVCObject(mediaObject, @"takenAt"));
        BOOL isVideo = instantsIsVideoNumber ? instantsIsVideoNumber.boolValue : SPKIsVideoExtension((instantsVideoURL ?: instantsURL).pathExtension);
        if (isVideo) {
            entry.videoURL = instantsVideoURL ?: instantsURL;
            entry.photoURL = instantsPhotoURL;
        } else {
            entry.photoURL = instantsPhotoURL ?: instantsURL;
            if (!entry.photoURL && instantsVideoURL) {
                entry.videoURL = instantsVideoURL;
            }
        }
        return (entry.photoURL || entry.videoURL) ? entry : nil;
    }

    NSURL *directURL = SPKURLFromValue(mediaObject);
    if (directURL) {
        SPKResolvedMediaEntry *entry = [[SPKResolvedMediaEntry alloc] init];
        entry.mediaObject = mediaObject;
        entry.metadataObject = mediaObject;
        if (SPKIsVideoExtension(directURL.pathExtension)) {
            entry.videoURL = directURL;
        } else {
            entry.photoURL = directURL;
        }
        return entry;
    }

    mediaObject = SPKUnderlyingMediaObjectForAction(mediaObject);

    SPKResolvedMediaEntry *entry = [[SPKResolvedMediaEntry alloc] init];
    entry.mediaObject = mediaObject;
    entry.metadataObject = mediaObject;

    if (!entry.photoURL) {
        entry.photoURL = [SPKUtils getPhotoUrlForMedia:mediaObject];
    }
    if (!entry.videoURL) {
        entry.videoURL = [SPKUtils getVideoUrlForMedia:mediaObject];
    }

    id photoObject = SPKObjectForSelector(mediaObject, @"photo");
    if (!photoObject)
        photoObject = SPKObjectForSelector(mediaObject, @"rawPhoto");
    if (photoObject) {
        entry.photoURL = [SPKUtils getPhotoUrl:photoObject];
        if (!entry.photoURL) {
            entry.photoURL = SPKURLFromAssetLikeObject(photoObject, NO);
        }
    }

    if (!entry.photoURL)
        entry.photoURL = SPKURLFromValue(SPKObjectForSelector(mediaObject, @"imageURL"));
    if (!entry.photoURL)
        entry.photoURL = SPKURLFromValue(SPKObjectForSelector(mediaObject, @"imageUrl"));
    if (!entry.photoURL) {
        id imageSpecifier = SPKObjectForSelector(mediaObject, @"imageSpecifier");
        entry.photoURL = SPKURLFromValue(SPKObjectForSelector(imageSpecifier, @"url"));
    }
    if (!entry.photoURL)
        entry.photoURL = SPKURLFromValue(SPKObjectForSelector(mediaObject, @"displayURL"));
    if (!entry.photoURL)
        entry.photoURL = SPKURLFromValue(SPKObjectForSelector(mediaObject, @"thumbnailURL"));
    if (!entry.photoURL)
        entry.photoURL = [SPKUtils getBestProfilePictureURLForUser:mediaObject];

    id videoObject = SPKObjectForSelector(mediaObject, @"video");
    if (!videoObject)
        videoObject = SPKObjectForSelector(mediaObject, @"rawVideo");
    if (videoObject) {
        entry.videoURL = [SPKUtils getVideoUrl:videoObject];
        if (!entry.videoURL) {
            entry.videoURL = SPKURLFromAssetLikeObject(videoObject, YES);
        }
    }

    if (!entry.videoURL)
        entry.videoURL = SPKURLFromValue(SPKObjectForSelector(mediaObject, @"videoURL"));
    if (!entry.videoURL)
        entry.videoURL = SPKURLFromValue(SPKObjectForSelector(mediaObject, @"videoUrl"));

    NSURL *genericURL = SPKURLFromValue(SPKObjectForSelector(mediaObject, @"url"));
    if (genericURL) {
        if (!entry.videoURL && SPKIsVideoExtension(genericURL.pathExtension)) {
            entry.videoURL = genericURL;
        } else if (!entry.photoURL && !SPKIsVideoExtension(genericURL.pathExtension)) {
            entry.photoURL = genericURL;
        }
    }

    if (!entry.photoURL && !entry.videoURL) {
        return nil;
    }

    entry.sourceMediaPK = SPKMediaPKForMediaObject(mediaObject);

    return entry;
}

NSArray *SPKActionButtonCarouselChildren(id media) {
    if (!media)
        return @[];

    for (NSString *selectorName in @[ @"items", @"carouselMedia", @"carouselChildren", @"children", @"carousel_media" ]) {
        id value = SPKObjectForSelector(media, selectorName);
        if (!value)
            value = SPKKVCObject(media, selectorName);
        NSArray *items = SPKArrayFromCollection(value);
        if (items.count > 0)
            return items;
    }

    return @[];
}

static NSArray<SPKResolvedMediaEntry *> *SPKEntriesFromMedia(id media) {
    if (!media)
        return @[];

    NSMutableArray<SPKResolvedMediaEntry *> *entries = [NSMutableArray array];

    NSArray *directCollection = SPKArrayFromCollection(media);
    if (directCollection.count > 0) {
        for (id item in directCollection) {
            SPKResolvedMediaEntry *entry = SPKEntryFromMediaObject(item);
            if (!entry) {
                id nestedMedia = SPKObjectForSelector(item, @"media") ?: SPKKVCObject(item, @"media");
                entry = SPKEntryFromMediaObject(nestedMedia);
                if (entry && !entry.metadataObject) {
                    entry.metadataObject = nestedMedia ?: item;
                }
            }
            if (entry) {
                if (!entry.mediaObject)
                    entry.mediaObject = item;
                if (!entry.metadataObject)
                    entry.metadataObject = item;
                [entries addObject:entry];
            }
        }
        if (entries.count > 0)
            return entries;
    }

    NSArray *items = SPKActionButtonCarouselChildren(media);

    if (items.count > 0) {
        for (id item in items) {
            id nestedMedia = SPKObjectForSelector(item, @"media") ?: SPKKVCObject(item, @"media");
            SPKResolvedMediaEntry *entry = SPKEntryFromMediaObject(nestedMedia);
            if (!entry)
                entry = SPKEntryFromMediaObject(SPKObjectForSelector(item, @"visualMessage") ?: SPKKVCObject(item, @"visualMessage"));
            if (!entry)
                entry = SPKEntryFromMediaObject(SPKObjectForSelector(item, @"item") ?: SPKKVCObject(item, @"item"));
            if (!entry)
                entry = SPKEntryFromMediaObject(item);
            if (entry) {
                if (!entry.mediaObject) {
                    entry.mediaObject = item;
                }
                if (!entry.metadataObject) {
                    entry.metadataObject = nestedMedia ?: item;
                }
                [entries addObject:entry];
            }
        }
    } else {
        SPKResolvedMediaEntry *directEntry = SPKEntryFromMediaObject(media);
        if (directEntry)
            return @[ directEntry ];

        id nested = SPKObjectForSelector(media, @"media");
        if (!nested)
            nested = SPKKVCObject(media, @"media");
        SPKResolvedMediaEntry *singleEntry = SPKEntryFromMediaObject(nested);
        if (!singleEntry) {
            singleEntry = SPKEntryFromMediaObject(media);
        }
        if (singleEntry)
            [entries addObject:singleEntry];
    }

    return entries;
}

extern "C" BOOL SPKResolveGalleryDownloadForMedia(id media,
                                                  SPKActionButtonSource source,
                                                  NSString *fallbackUsername,
                                                  NSURL *__autoreleasing *outPhotoURL,
                                                  NSURL *__autoreleasing *outVideoURL,
                                                  SPKGallerySaveMetadata *__autoreleasing *outMetadata) {
    if (!media)
        return NO;

    SPKResolvedMediaEntry *entry = SPKEntriesFromMedia(media).firstObject;
    if (!entry.videoURL && !entry.photoURL)
        return NO;

    NSString *username = SPKUsernameForEntry(entry, fallbackUsername);
    SPKGallerySaveMetadata *meta = SPKGalleryMetadata(source, username, entry.metadataObject ?: entry.mediaObject ?: media);
    SPKApplyEntryMetadata(meta, entry);

    if (outPhotoURL)
        *outPhotoURL = entry.photoURL;
    if (outVideoURL)
        *outVideoURL = entry.videoURL;
    if (outMetadata)
        *outMetadata = meta;
    return YES;
}

static NSArray<SPKMediaItem *> *SPKPlayerItemsFromEntries(NSArray<SPKResolvedMediaEntry *> *entries, SPKActionButtonSource source, NSString *username, id media) {
    NSMutableArray<SPKMediaItem *> *items = [NSMutableArray array];

    NSInteger index = 0;
    for (SPKResolvedMediaEntry *entry in entries) {
        NSURL *url = entry.videoURL ?: entry.photoURL;
        if (!url) {
            index++;
            continue;
        }
        id metadataObject = entry.metadataObject ?: entry.mediaObject ?
                                                                      : media;
        NSString *itemUsername = source == SPKActionButtonSourceInstants ? SPKUsernameForEntry(entry, username) : username;

        SPKMediaItem *item = [SPKMediaItem itemWithFileURL:url];
        item.mediaType = entry.videoURL ? SPKMediaItemTypeVideo : SPKMediaItemTypeImage;
        item.gallerySaveSource = SPKGallerySourceForActionSource(source);
        item.galleryMetadata = SPKGalleryMetadata(source, itemUsername, metadataObject);
        SPKApplyEntryMetadata(item.galleryMetadata, entry);
        if (metadataObject != media && source != SPKActionButtonSourceInstants) {
            [SPKGalleryOriginController populateMetadata:item.galleryMetadata fromMedia:media];
            if (entries.count > 1) {
                item.galleryMetadata.sourceMediaURLString = [SPKUtils appendImgIndex:index toURLString:item.galleryMetadata.sourceMediaURLString];
            }
        }
        item.sourceMediaObject = metadataObject;
        if (itemUsername.length > 0)
            item.title = itemUsername;
        [items addObject:item];
        index++;
    }

    return items;
}

static UIView *SPKDirectMediaView(UIViewController *controller) {
    if (!controller)
        return nil;
    id viewerContainer = [SPKUtils getIvarForObj:controller name:"_viewerContainerView"];
    if (!viewerContainer)
        viewerContainer = SPKKVCObject(controller, @"viewerContainerView");
    id mediaView = SPKObjectForSelector(viewerContainer, @"mediaView");
    return [mediaView isKindOfClass:[UIView class]] ? (UIView *)mediaView : nil;
}

extern "C" void SPKPauseStoryPlaybackFromOverlaySubview(UIView *overlayView) {
    UIViewController *ancestorController = SPKViewControllerForAncestorView(overlayView);
    if (!ancestorController)
        return;

    if ([ancestorController respondsToSelector:NSSelectorFromString(@"pauseWithReason:")]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(ancestorController, NSSelectorFromString(@"pauseWithReason:"), 1);
    } else if ([ancestorController respondsToSelector:NSSelectorFromString(@"pauseWithReason:callsiteContext:")]) {
        ((void (*)(id, SEL, NSInteger, id))objc_msgSend)(ancestorController, NSSelectorFromString(@"pauseWithReason:callsiteContext:"), 1, nil);
    } else if ([ancestorController respondsToSelector:NSSelectorFromString(@"pause")]) {
        ((void (*)(id, SEL))objc_msgSend)(ancestorController, NSSelectorFromString(@"pause"));
    }
}

extern "C" void SPKResumeStoryPlaybackFromOverlaySubview(UIView *overlayView) {
    UIViewController *ancestorController = SPKViewControllerForAncestorView(overlayView);
    if (!ancestorController)
        return;

    if ([ancestorController respondsToSelector:NSSelectorFromString(@"tryResumePlayback")]) {
        ((void (*)(id, SEL))objc_msgSend)(ancestorController, NSSelectorFromString(@"tryResumePlayback"));
    } else if ([ancestorController respondsToSelector:NSSelectorFromString(@"tryResumePlaybackWithReason:")]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(ancestorController, NSSelectorFromString(@"tryResumePlaybackWithReason:"), 1);
    } else if ([ancestorController respondsToSelector:NSSelectorFromString(@"resumePlayback")]) {
        ((void (*)(id, SEL))objc_msgSend)(ancestorController, NSSelectorFromString(@"resumePlayback"));
    } else if ([ancestorController respondsToSelector:NSSelectorFromString(@"play")]) {
        ((void (*)(id, SEL))objc_msgSend)(ancestorController, NSSelectorFromString(@"play"));
    }
}

static void SPKPauseDirectPlaybackFromController(UIViewController *controller) {
    UIView *mediaView = SPKDirectMediaView(controller);
    SEL pauseSelector = NSSelectorFromString(@"pauseWithReason:");
    if (mediaView && [mediaView respondsToSelector:pauseSelector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(mediaView, pauseSelector, 0);
    }
}

static void SPKResumeDirectPlaybackFromController(UIViewController *controller) {
    UIView *mediaView = SPKDirectMediaView(controller);
    SEL playSelector = NSSelectorFromString(@"play");
    if (mediaView && [mediaView respondsToSelector:playSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(mediaView, playSelector);
    }
}

static UIImage *SPKButtonDefaultImage(NSString *identifier, SPKActionButtonSource source, SPKActionButtonContext *context) {
    CGFloat size = 24.0;
    if (source == SPKActionButtonSourceReels) {
        size = 44.0;
    } else if ([identifier isEqualToString:kSPKActionDownloadShare] ||
               [identifier isEqualToString:kSPKActionViewThumbnail] ||
               [identifier isEqualToString:kSPKActionDownloadGallery]) {
        size = 23.0;
    }

    NSString *resolvedIdentifier = identifier;
    if (source == SPKActionButtonSourceProfile && [identifier isEqualToString:kSPKActionProfileCopyInfo]) {
        resolvedIdentifier = SPKProfileDefaultCopyInfoIdentifier();
    }

    return SPKIconForActionIdentifier(resolvedIdentifier, source, size, context);
}

static CGSize SPKCustomButtonIconDisplaySize(NSString *identifier, SPKActionButtonSource source, UIImage *image, UIButton *button) {
    if (!image)
        return CGSizeZero;

    CGFloat width = image.size.width;
    CGFloat height = image.size.height;

    if (source == SPKActionButtonSourceReels) {
        if ([identifier isEqualToString:kSPKActionDownloadShare] ||
            [identifier isEqualToString:kSPKActionDownloadAudioShare]) {
            width = height = 38.0;
        } else if ([identifier isEqualToString:kSPKActionNone] ||
                   [identifier isEqualToString:kSPKActionViewThumbnail] ||
                   [identifier isEqualToString:kSPKActionDownloadGallery] ||
                   [identifier isEqualToString:kSPKActionCopyMedia] ||
                   [identifier isEqualToString:kSPKActionTrimSave] ||
                   [identifier isEqualToString:kSPKActionDownloadAudio] ||
                   [identifier isEqualToString:kSPKActionDownloadAudioGallery] ||
                   [identifier isEqualToString:kSPKActionPlayAudio] ||
                   [identifier isEqualToString:kSPKActionCopyCaption]) {
            // Actions without a dedicated 44pt _reels asset render at 28pt.
            width = height = 28.0;
        }
    }

    CGFloat maxWidth = CGRectGetWidth(button.bounds) > 0.0 ? CGRectGetWidth(button.bounds) : 44.0;
    CGFloat maxHeight = CGRectGetHeight(button.bounds) > 0.0 ? CGRectGetHeight(button.bounds) : 44.0;

    return CGSizeMake(MAX(1.0, MIN(maxWidth, width)), MAX(1.0, MIN(maxHeight, height)));
}

static UIImageView *SPKEnsureCustomIconImageView(UIButton *button) {
    UIImageView *imageView = objc_getAssociatedObject(button, kSPKActionButtonIconImageViewAssocKey);
    if ([imageView isKindOfClass:[UIImageView class]])
        return imageView;

    imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    imageView.userInteractionEnabled = NO;
    [button addSubview:imageView];

    [NSLayoutConstraint activateConstraints:@[
        [imageView.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
        [imageView.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [imageView.widthAnchor constraintLessThanOrEqualToAnchor:button.widthAnchor],
        [imageView.heightAnchor constraintLessThanOrEqualToAnchor:button.heightAnchor],
    ]];

    NSLayoutConstraint *widthConstraint = [imageView.widthAnchor constraintEqualToConstant:24.0];
    NSLayoutConstraint *heightConstraint = [imageView.heightAnchor constraintEqualToConstant:24.0];
    widthConstraint.active = YES;
    heightConstraint.active = YES;

    objc_setAssociatedObject(button, kSPKActionButtonIconImageViewAssocKey, imageView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, kSPKActionButtonIconWidthConstraintAssocKey, widthConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, kSPKActionButtonIconHeightConstraintAssocKey, heightConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return imageView;
}

static void SPKSetButtonVisualImage(UIButton *button, UIImage *image, SPKActionButtonSource source, NSString *identifier) {
    UIImage *templatedImage = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if ([button isKindOfClass:[SPKChromeButton class]]) {
        SPKChromeButton *chromeButton = (SPKChromeButton *)button;
        if (source == SPKActionButtonSourceReels) {
            chromeButton.iconView.contentMode = UIViewContentModeScaleAspectFit;
            CGSize displaySize = SPKCustomButtonIconDisplaySize(identifier, source, templatedImage, button);
            NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(chromeButton, kSPKActionButtonIconWidthConstraintAssocKey);
            NSLayoutConstraint *heightConstraint = objc_getAssociatedObject(chromeButton, kSPKActionButtonIconHeightConstraintAssocKey);
            if (!widthConstraint) {
                widthConstraint = [chromeButton.iconView.widthAnchor constraintEqualToConstant:displaySize.width];
                heightConstraint = [chromeButton.iconView.heightAnchor constraintEqualToConstant:displaySize.height];
                widthConstraint.active = YES;
                heightConstraint.active = YES;
                objc_setAssociatedObject(chromeButton, kSPKActionButtonIconWidthConstraintAssocKey, widthConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(chromeButton, kSPKActionButtonIconHeightConstraintAssocKey, heightConstraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else {
                widthConstraint.constant = displaySize.width;
                heightConstraint.constant = displaySize.height;
            }
        } else {
            NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(chromeButton, kSPKActionButtonIconWidthConstraintAssocKey);
            NSLayoutConstraint *heightConstraint = objc_getAssociatedObject(chromeButton, kSPKActionButtonIconHeightConstraintAssocKey);
            if (widthConstraint) {
                widthConstraint.active = NO;
                heightConstraint.active = NO;
                objc_setAssociatedObject(chromeButton, kSPKActionButtonIconWidthConstraintAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(chromeButton, kSPKActionButtonIconHeightConstraintAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            chromeButton.iconView.contentMode = UIViewContentModeCenter;
        }
        chromeButton.iconView.image = templatedImage;
        // ReelsActionButton mirrors Instagram's live UFI tint, including HDR/EDR.
        // Preserve it when settings rebuild the default-action image; other
        // surfaces continue to receive their normal source tint here.
        if (source != SPKActionButtonSourceReels)
            chromeButton.iconTint = SPKActionButtonTintForSource(source);
        [button setImage:nil forState:UIControlStateNormal];
        return;
    }

    UIImageView *customIconView = objc_getAssociatedObject(button, kSPKActionButtonIconImageViewAssocKey);
    if ([customIconView isKindOfClass:[UIImageView class]]) {
        customIconView.hidden = YES;
        customIconView.image = nil;
    }
    [button setImage:templatedImage forState:UIControlStateNormal];
}

static id SPKResolveMediaForContext(SPKActionButtonContext *context) {
    if (!context)
        return nil;
    if (context.mediaOverride)
        return context.mediaOverride;
    if (context.mediaResolver)
        return context.mediaResolver(context);
    return nil;
}

static id SPKResolveBulkMediaForContext(SPKActionButtonContext *context) {
    if (!context)
        return nil;
    if (context.bulkMediaResolver)
        return context.bulkMediaResolver(context);
    return SPKResolveMediaForContext(context);
}

static NSInteger SPKResolveCurrentIndexForContext(SPKActionButtonContext *context) {
    if (!context)
        return 0;
    if (context.currentIndexOverride >= 0)
        return context.currentIndexOverride;
    if (context.currentIndexResolver)
        return context.currentIndexResolver(context);
    return 0;
}

static NSArray<SPKResolvedMediaEntry *> *SPKBulkEntriesForContext(SPKActionButtonContext *context) {
    id bulkMedia = SPKResolveBulkMediaForContext(context);
    return SPKEntriesFromMedia(bulkMedia);
}

static NSArray<SPKResolvedMediaEntry *> *SPKDownloadableEntries(NSArray<SPKResolvedMediaEntry *> *entries) {
    NSMutableArray<SPKResolvedMediaEntry *> *filtered = [NSMutableArray array];
    for (SPKResolvedMediaEntry *entry in entries) {
        NSURL *url = entry.videoURL ?: entry.photoURL;
        if (url)
            [filtered addObject:entry];
    }
    return filtered;
}

// Where does the item on screen sit in the list we are about to hand the preview player?
// Not necessarily at the resolved index: that index counts the surface's own item list,
// while the preview list is a URL-filtered (and for stories, user-filtered) copy of it, so
// one item dropped for having no resolvable URL shifts everything after it and the viewer
// opens on a neighbour. Match the entry itself instead, and keep the number as a fallback.
static NSInteger SPKPreviewIndexForEntry(SPKResolvedMediaEntry *currentEntry,
                                         NSArray<SPKResolvedMediaEntry *> *previewEntries,
                                         NSInteger fallbackIndex) {
    NSInteger clampedFallback = SPKClampedIndex(fallbackIndex, (NSInteger)previewEntries.count);
    if (!currentEntry || previewEntries.count == 0)
        return clampedFallback;

    // Same surface, same entry objects (a non-bulk carousel): settled immediately.
    NSUInteger identical = [previewEntries indexOfObjectIdenticalTo:currentEntry];
    if (identical != NSNotFound)
        return (NSInteger)identical;

    // Bulk lists are resolved separately, so compare by URL — the one signal that stays
    // distinct across carousel slides of a single media object.
    NSString *currentURLString = (currentEntry.videoURL ?: currentEntry.photoURL).absoluteString;
    if (currentURLString.length > 0) {
        for (NSUInteger i = 0; i < previewEntries.count; i++) {
            SPKResolvedMediaEntry *entry = previewEntries[i];
            NSString *entryURLString = (entry.videoURL ?: entry.photoURL).absoluteString;
            if ([entryURLString isEqualToString:currentURLString])
                return (NSInteger)i;
        }
    }

    // Last signal: the media object behind the entry. Only trustworthy when exactly one
    // entry carries it, since every slide of a carousel shares the same parent object.
    id currentMedia = currentEntry.metadataObject ?: currentEntry.mediaObject;
    if (currentMedia) {
        NSInteger match = NSNotFound;
        NSUInteger matchCount = 0;
        for (NSUInteger i = 0; i < previewEntries.count; i++) {
            SPKResolvedMediaEntry *entry = previewEntries[i];
            if ((entry.metadataObject ?: entry.mediaObject) == currentMedia) {
                match = (NSInteger)i;
                matchCount++;
            }
        }
        if (matchCount == 1)
            return match;
    }

    return clampedFallback;
}

static UIViewController *SPKActionContextPresenter(SPKActionButtonContext *context) {
    if (context.controller.view.window)
        return context.controller;
    UIViewController *ancestor = SPKViewControllerForAncestorView(context.view);
    if (ancestor.view.window)
        return ancestor;
    return topMostController();
}

static UIView *SPKActionContextAnchorView(SPKActionButtonContext *context) {
    if ([context.view isKindOfClass:[UIView class]] && context.view.window)
        return context.view;
    return SPKActionContextPresenter(context).view;
}

static NSArray<SPKDownloadItemRequest *> *SPKBulkDownloadItemsFromEntries(NSArray<SPKResolvedMediaEntry *> *entries,
                                                                          SPKActionButtonSource source,
                                                                          NSString *username,
                                                                          id media,
                                                                          NSString *qualityOverride,
                                                                          SPKDownloadDestination destination) {
    NSMutableArray<SPKDownloadItemRequest *> *items = [NSMutableArray array];
    NSInteger index = 0;
    for (SPKResolvedMediaEntry *entry in entries) {
        NSURL *url = entry.videoURL ?: entry.photoURL;
        if (!url) {
            index++;
            continue;
        }
        BOOL isVideo = (entry.videoURL != nil);
        id metadataObject = entry.metadataObject ?: entry.mediaObject ?
                                                                      : media;

        if (!isVideo && (qualityOverride.length > 0 || ![[SPKUtils getStringPref:@"downloads_photo_quality"] isEqualToString:@"always_ask"])) {
            NSURL *resolvedURL = [SPKMediaQualityManager resolvedURLForMediaObject:metadataObject photoURL:entry.photoURL videoURL:entry.videoURL qualityOverride:qualityOverride destination:destination];
            if (resolvedURL.absoluteString.length > 0) {
                url = resolvedURL;
            }
        }

        NSString *itemUsername = source == SPKActionButtonSourceInstants ? SPKUsernameForEntry(entry, username) : username;
        SPKGallerySaveMetadata *meta = SPKGalleryMetadata(source, itemUsername, metadataObject);
        SPKApplyEntryMetadata(meta, entry);
        if (metadataObject != media && source != SPKActionButtonSourceInstants) {
            [SPKGalleryOriginController populateMetadata:meta fromMedia:media];
            if (entries.count > 1) {
                meta.sourceMediaURLString = [SPKUtils appendImgIndex:index toURLString:meta.sourceMediaURLString];
            }
        }
        NSString *extension = SPKExtensionForURL(url, isVideo);
        SPKDownloadMediaKind kind = isVideo ? SPKDownloadMediaKindVideo : SPKDownloadMediaKindImage;
        SPKDownloadItemRequest *item = url.isFileURL
                                           ? [SPKDownloadItemRequest itemWithLocalPath:url.path mediaKind:kind]
                                           : [SPKDownloadItemRequest itemWithRemoteURL:url mediaKind:kind];
        item.preferredFileExtension = extension;
        item.metadata = meta;
        item.index = index;
        item.linkString = SPKBestDownloadURLForMediaObject(metadataObject).absoluteString ?: url.absoluteString;
        item.expectedFilenameStem = [[SPKDownloadHelpers preferredFilenameForURL:url mediaKind:kind metadata:meta] stringByDeletingPathExtension];
        [items addObject:item];
        index++;
    }
    return items;
}

static NSArray<NSString *> *SPKBulkDownloadLinksFromEntries(NSArray<SPKResolvedMediaEntry *> *entries, id media, NSString *photoQualityOverride) {
    NSMutableOrderedSet<NSString *> *links = [NSMutableOrderedSet orderedSet];
    for (SPKResolvedMediaEntry *entry in entries) {
        id metadataObject = entry.metadataObject ?: entry.mediaObject ?
                                                                      : media;
        NSURL *linkURL = [SPKMediaQualityManager downloadLinkURLForMediaObject:metadataObject
                                                                      photoURL:entry.photoURL
                                                                      videoURL:entry.videoURL
                                                          photoQualityOverride:photoQualityOverride];
        if (linkURL.absoluteString.length > 0) {
            [links addObject:linkURL.absoluteString];
        }
    }
    return links.array;
}

NSArray<NSString *> *SPKConfiguredBulkActionIdentifiersForSource(SPKActionButtonSource source) {
    NSMutableOrderedSet<NSString *> *ordered = [NSMutableOrderedSet orderedSet];
    [ordered addObjectsFromArray:SPKActionButtonConfiguredBulkDownloadActionsForSource(source)];
    [ordered addObjectsFromArray:SPKActionButtonConfiguredBulkCopyActionsForSource(source)];
    return ordered.array;
}

static NSArray<UIMenuElement *> *SPKBulkActionMenuElementsForIdentifiers(NSArray<NSString *> *identifiers,
                                                                         void (^selectionHandler)(NSString *identifier)) {
    NSMutableArray<UIMenuElement *> *elements = [NSMutableArray array];
    for (NSString *identifier in identifiers) {
        UIImage *image = SPKActionButtonMenuIconForIdentifier(identifier, 22.0);
        NSString *title = SPKActionButtonTitleForIdentifier(identifier);
        [elements addObject:[UIAction actionWithTitle:title
                                                image:image
                                           identifier:nil
                                              handler:^(__unused UIAction *action) {
                                                  selectionHandler(identifier);
                                              }]];
    }
    return elements;
}

static NSArray<NSString *> *SPKFilterBulkActionIdentifiers(NSArray<NSString *> *identifiers,
                                                           BOOL (^predicate)(NSString *identifier)) {
    NSMutableArray<NSString *> *filtered = [NSMutableArray array];
    for (NSString *identifier in identifiers) {
        if (predicate && predicate(identifier)) {
            [filtered addObject:identifier];
        }
    }
    return filtered;
}

static UIMenu *SPKBulkActionMenuForContext(SPKActionButtonContext *context,
                                           NSArray<SPKResolvedMediaEntry *> *entries,
                                           NSString *username,
                                           id media,
                                           NSArray<NSString *> *configuredIdentifiers) {
    NSArray<SPKResolvedMediaEntry *> *downloadableEntries = SPKDownloadableEntries(entries);
    if (downloadableEntries.count < 2) {
        return nil;
    }

    __weak SPKActionButtonContext *weakContext = context;
    NSArray<UIMenuElement *> *children = SPKBulkActionMenuElementsForIdentifiers(configuredIdentifiers, ^(NSString *identifier) {
        SPKActionButtonContext *strongContext = weakContext;
        if (strongContext) {
            SPKExecuteActionIdentifier(identifier, strongContext, NO);
        }
    });
    if (children.count == 0)
        return nil;
    return [UIMenu menuWithTitle:@"" children:children];
}

static void SPKPresentBulkActionChooser(SPKActionButtonContext *context,
                                        NSArray<SPKResolvedMediaEntry *> *entries,
                                        NSString *username,
                                        id media) {
    UIMenu *menu = SPKBulkActionMenuForContext(context, entries, username, media, SPKConfiguredBulkActionIdentifiersForSource(context.source));
    if (!menu) {
        SPKNotify(kSPKActionDownloadAllLibrary, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_BULK_MEDIA_AVAILABLE_TEXT"), nil, @"error_filled", SPKNotificationToneError);
    }
}

// Renders `children` as a labeled, collapsible submenu — but when there is only
// one child, returns that child inline instead, so single-element submenus never
// add a redundant nesting level. Used everywhere a submenu/section is built so
// the behavior is uniform across built-in and custom sections.
static UIMenuElement *SPKSubmenuOrSingleElement(NSString *title, UIImage *image, NSArray<UIMenuElement *> *children) {
    if (children.count == 0)
        return nil;
    if (children.count == 1)
        return children.firstObject;
    return [UIMenu menuWithTitle:title ?: @""
                           image:image
                      identifier:nil
                         options:0
                        children:children];
}

static UIMenuElement *SPKBulkActionMenuElementForContext(SPKActionButtonContext *context,
                                                         NSArray<SPKResolvedMediaEntry *> *entries,
                                                         NSString *username,
                                                         id media,
                                                         NSArray<NSString *> *configuredIdentifiers,
                                                         NSString *title,
                                                         NSString *iconIdentifier) {
    UIMenu *menu = SPKBulkActionMenuForContext(context, entries, username, media, configuredIdentifiers);
    if (!menu)
        return nil;
    return SPKSubmenuOrSingleElement(title,
                                     SPKActionButtonMenuIconForContext(iconIdentifier ?: kSPKActionDownloadAll, context, 22.0),
                                     menu.children);
}

static NSString *SPKResolvedBulkUsernameForContext(SPKActionButtonContext *context, NSArray<SPKResolvedMediaEntry *> *entries, id media) {
    NSString *username = (context.source == SPKActionButtonSourceDirect)
                             ? SPKDirectUsernameFromController(context.controller)
                             : SPKUsernameFromMediaObject(media);
    if (username.length > 0)
        return username;
    for (SPKResolvedMediaEntry *entry in entries) {
        username = SPKUsernameFromMediaObject(entry.metadataObject ?: entry.mediaObject);
        if (username.length > 0)
            return username;
    }
    return nil;
}

// Audio is downloadable when the item is a video — its dash manifest carries an
// audio track. Reels are always videos (their videoURL resolves lazily and may be
// nil at menu-build), so the Reels tab always qualifies. Every other source keys
// off the already-resolved `videoURL` — the exact signal the video-download action
// uses — so audio appears wherever video download does, with no deep/expensive
// media traversal at menu-build time. Photos have no audio (no reliable cheap way
// to detect a rare photo-with-song, and guessing caused false positives → errors).
static BOOL SPKEntryHasDownloadableAudio(SPKActionButtonSource source, SPKResolvedMediaEntry *entry) {
    if (source == SPKActionButtonSourceReels)
        return YES;
    return entry.videoURL != nil;
}

static BOOL SPKIsActionVisible(SPKActionButtonContext *context,
                               SPKActionButtonConfiguration *configuration,
                               NSString *identifier,
                               id media,
                               NSArray<SPKResolvedMediaEntry *> *entries,
                               NSInteger currentIndex) {
    if (identifier.length == 0)
        return NO;
    if ([configuration.disabledActions containsObject:identifier] || [configuration.unassignedActions containsObject:identifier]) {
        return NO;
    }

    if ([identifier isEqualToString:kSPKActionToggleStorySeenUserRule]) {
        return context.source == SPKActionButtonSourceStories &&
               SPKStoryCurrentUserRuleActionTitle(SPKStoryContextForActionButtonContext(context)).length > 0;
    }
    if ([identifier isEqualToString:kSPKActionToggleStoryAutoSaveUserRule]) {
        return context.source == SPKActionButtonSourceStories &&
               [SPKUtils getBoolPref:@"stories_auto_save"] &&
               SPKStoryAutoSaveCurrentUserActionTitle(SPKStoryContextForActionButtonContext(context)).length > 0;
    }
    if ([identifier isEqualToString:kSPKActionToggleDirectAutoSaveThreadRule]) {
        return context.source == SPKActionButtonSourceDirect &&
               [SPKUtils getBoolPref:@"msgs_auto_save"] &&
               SPKDirectAutoSaveCurrentThreadActionTitle(SPKDirectThreadContextFromSource(context.controller)).length > 0;
    }
    if ([identifier isEqualToString:kSPKActionToggleInstantsAutoSaveUserRule]) {
        return context.source == SPKActionButtonSourceInstants &&
               [SPKUtils getBoolPref:@"instants_auto_save"] &&
               SPKInstantsAutoSaveActionTitleForUsername(SPKInstantsAutoSaveUsernameForContext(context)).length > 0;
    }
    if ([identifier isEqualToString:kSPKActionInstantsMarkSeen]) {
        // Not a menu action. It backs the viewer's own eye button, which has no need of a
        // menu row beside it, and the Instants menu is built once per button lifecycle so a
        // row there could never track the snap on screen anyway.
        return NO;
    }
    if ([identifier isEqualToString:kSPKActionToggleProfileStorySeenUserRule]) {
        return context.source == SPKActionButtonSourceProfile &&
               SPKResolveMediaForContext(context) != nil;
    }
    if ([identifier isEqualToString:kSPKActionToggleProfileMessagesSeenUserRule]) {
        return context.source == SPKActionButtonSourceProfile &&
               SPKResolveMediaForContext(context) != nil;
    }
    if ([identifier isEqualToString:kSPKActionStoryMentionsSheet]) {
        return context.source == SPKActionButtonSourceStories && SPKStoryMediaHasMentions(media);
    }
    if (context.source == SPKActionButtonSourceProfile && [identifier isEqualToString:kSPKActionProfileCopyInfo]) {
        return media != nil;
    }
    if (context.source == SPKActionButtonSourceProfile && [identifier isEqualToString:kSPKActionOpenTopicSettings]) {
        return SPKResolvedSettingsTitleForContext(context).length > 0;
    }
    if (context.source == SPKActionButtonSourceDirect && [identifier isEqualToString:kSPKActionDeletedMessagesLog]) {
        return YES;
    }

    if (entries.count == 0)
        return NO;

    NSInteger idx = SPKClampedIndex(currentIndex, (NSInteger)entries.count);
    SPKResolvedMediaEntry *currentEntry = entries[idx];
    NSURL *currentURL = currentEntry.videoURL ?: currentEntry.photoURL;

    if ([identifier isEqualToString:kSPKActionViewThumbnail]) {
        if (!currentEntry.videoURL)
            return NO;
        // For stories, photo items may falsely expose a videoURL.
        // Only show thumbnail if no photoURL exists (pure video),
        // or if both exist but are distinct URLs.
        if (context.source == SPKActionButtonSourceStories && currentEntry.photoURL) {
            return ![currentEntry.videoURL isEqual:currentEntry.photoURL];
        }
        return YES;
    }
    if ([identifier isEqualToString:kSPKActionTrimSave]) {
        // Video-only, but unlike thumbnail/download we can't rely on a resolved
        // videoURL — feed-inline reels resolve it lazily. Fall back to a cheap
        // media-object video check (duration / resolvable URL).
        if (currentEntry.videoURL) {
            if (context.source == SPKActionButtonSourceStories && currentEntry.photoURL) {
                return ![currentEntry.videoURL isEqual:currentEntry.photoURL];
            }
            return YES;
        }
        id mediaObj = currentEntry.mediaObject ?: media;
        return [SPKMediaQualityManager mediaObjectIsVideo:mediaObj];
    }
    if ([identifier isEqualToString:kSPKActionEditSave]) {
        // Photo-only (crop/rotate/flip editor) — the inverse of Trim & Save.
        // Needs a still image: a photoURL present and not a video.
        if (!currentEntry.photoURL)
            return NO;
        // A video item may also carry a photoURL (poster frame); treat any
        // distinct videoURL as video and hide edit.
        if (currentEntry.videoURL && ![currentEntry.videoURL isEqual:currentEntry.photoURL])
            return NO;
        id mediaObj = currentEntry.mediaObject ?: media;
        if ([SPKMediaQualityManager mediaObjectIsVideo:mediaObj])
            return NO;
        return YES;
    }
    if ([identifier isEqualToString:kSPKActionDownloadLibrary] ||
        [identifier isEqualToString:kSPKActionDownloadShare] ||
        [identifier isEqualToString:kSPKActionCopyDownloadLink] ||
        [identifier isEqualToString:kSPKActionCopyMedia] ||
        [identifier isEqualToString:kSPKActionDownloadGallery]) {
        return currentURL != nil;
    }
    if ([identifier isEqualToString:kSPKActionDownloadAudio] ||
        [identifier isEqualToString:kSPKActionDownloadAudioShare] ||
        [identifier isEqualToString:kSPKActionDownloadAudioGallery] ||
        [identifier isEqualToString:kSPKActionPlayAudio] ||
        [identifier isEqualToString:kSPKActionCopyAudioURL]) {
        if (![SPKUtils getBoolPref:@"downloads_audio_enabled"])
            return NO;
        return SPKEntryHasDownloadableAudio(context.source, currentEntry);
    }
    if ([identifier isEqualToString:kSPKActionCopyCaption]) {
        return context.captionResolver != nil && [context.captionResolver(context, media, entries, idx) length] > 0;
    }
    if ([identifier isEqualToString:kSPKActionOpenTopicSettings]) {
        return SPKResolvedSettingsTitleForContext(context).length > 0;
    }
    if ([identifier isEqualToString:kSPKActionRepost]) {
        return context.repostHandler != nil;
    }
    if (SPKIsBulkChildActionIdentifier(identifier)) {
        id bulkMedia = SPKResolveBulkMediaForContext(context);
        NSArray<SPKResolvedMediaEntry *> *bulkEntries = SPKDownloadableEntries(SPKEntriesFromMedia(bulkMedia));
        if (bulkEntries.count <= 1)
            return NO;
        if (SPKIsBulkDownloadActionIdentifier(identifier)) {
            return ![configuration.disabledActions containsObject:kSPKActionDownloadLibrary] ||
                   ![configuration.disabledActions containsObject:kSPKActionDownloadShare] ||
                   ![configuration.disabledActions containsObject:kSPKActionDownloadGallery];
        }
        if (SPKIsBulkCopyActionIdentifier(identifier)) {
            return ![configuration.disabledActions containsObject:kSPKActionCopyDownloadLink] ||
                   ![configuration.disabledActions containsObject:kSPKActionCopyMedia];
        }
    }
    if (context.visibilityResolver) {
        return context.visibilityResolver(context, identifier, media, entries, idx);
    }
    return YES;
}

static NSArray<NSString *> *SPKVisibleActionsForContext(SPKActionButtonContext *context, id media, NSArray<SPKResolvedMediaEntry *> *entries, NSInteger currentIndex) {
    SPKActionButtonConfiguration *configuration = [SPKActionButtonConfiguration configurationForSource:context.source
                                                                                            topicTitle:context.settingsTitle ?: SPKActionButtonTopicTitleForSource(context.source)
                                                                                      supportedActions:context.supportedActions ?: SPKActionButtonSupportedActionsForSource(context.source)
                                                                                       defaultSections:SPKActionButtonDefaultSectionsForSource(context.source)];
    NSArray<NSString *> *supportedActions = configuration.supportedActions ?: @[];
    if (supportedActions.count == 0)
        return @[];

    NSMutableArray<NSString *> *visible = [NSMutableArray array];
    for (NSString *identifier in supportedActions) {
        if (SPKIsActionVisible(context, configuration, identifier, media, entries, currentIndex)) {
            [visible addObject:identifier];
        }
    }
    return visible;
}

static NSString *SPKResolvedDefaultActionIdentifier(NSArray<NSString *> *visibleIdentifiers, SPKActionButtonSource source) {
    if (visibleIdentifiers.count == 0)
        return nil;

    NSString *saved = [SPKUtils getStringPref:SPKDefaultActionPrefKeyForSource(source)];
    if (source == SPKActionButtonSourceProfile && saved.length > 0) {
        NSDictionary<NSString *, NSString *> *legacyMap = @{
            @"copy_info" : kSPKActionProfileCopyInfo,
            @"view_picture" : kSPKActionExpand,
            @"share_picture" : kSPKActionDownloadShare,
            @"save_picture_gallery" : kSPKActionDownloadGallery,
            @"profile_settings" : kSPKActionOpenTopicSettings
        };
        saved = legacyMap[saved] ?: saved;
    }
    if ([saved isEqualToString:kSPKActionNone])
        return kSPKActionNone;
    if ([saved isEqualToString:kSPKActionDownloadAll] && [visibleIdentifiers containsObject:kSPKActionDownloadAllLibrary]) {
        return kSPKActionDownloadAllLibrary;
    }
    if (saved.length > 0 && [visibleIdentifiers containsObject:saved])
        return saved;
    if (saved.length > 0)
        return kSPKActionNone;
    if (source == SPKActionButtonSourceProfile)
        return kSPKActionNone;
    if ([visibleIdentifiers containsObject:kSPKActionDownloadLibrary])
        return kSPKActionDownloadLibrary;
    return visibleIdentifiers.firstObject;
}

static NSString *SPKActionButtonMenuSignature(SPKActionButtonContext *context,
                                              SPKActionButtonConfiguration *configuration,
                                              NSArray<NSString *> *visibleActions,
                                              NSString *defaultIdentifier,
                                              NSUInteger bulkEntryCount) {
    NSString *dynamicStoryRuleTitle = [visibleActions containsObject:kSPKActionToggleStorySeenUserRule]
                                          ? SPKStoryCurrentUserRuleActionTitle(SPKStoryContextForActionButtonContext(context))
                                          : @"";
    NSString *dynamicStoryAutoSaveTitle = [visibleActions containsObject:kSPKActionToggleStoryAutoSaveUserRule]
                                              ? SPKStoryAutoSaveCurrentUserActionTitle(SPKStoryContextForActionButtonContext(context))
                                              : @"";
    NSString *dynamicDirectAutoSaveTitle = [visibleActions containsObject:kSPKActionToggleDirectAutoSaveThreadRule]
                                               ? SPKDirectAutoSaveCurrentThreadActionTitle(SPKDirectThreadContextFromSource(context.controller))
                                               : @"";
    NSString *dynamicInstantsAutoSaveTitle = [visibleActions containsObject:kSPKActionToggleInstantsAutoSaveUserRule]
                                                 ? SPKInstantsAutoSaveActionTitleForUsername(SPKInstantsAutoSaveUsernameForContext(context))
                                                 : @"";
    NSString *dynamicProfileStoryRuleTitle = [visibleActions containsObject:kSPKActionToggleProfileStorySeenUserRule]
                                                 ? SPKActionButtonDisplayTitleForContext(kSPKActionToggleProfileStorySeenUserRule, context, nil)
                                                 : @"";
    NSString *dynamicProfileMessagesRuleTitle = [visibleActions containsObject:kSPKActionToggleProfileMessagesSeenUserRule]
                                                    ? SPKActionButtonDisplayTitleForContext(kSPKActionToggleProfileMessagesSeenUserRule, context, nil)
                                                    : @"";
    NSString *profileInfoSignature = (context.source == SPKActionButtonSourceProfile)
                                         ? SPKProfileInfoSignature(SPKResolveMediaForContext(context))
                                         : @"";
    id media = SPKResolveMediaForContext(context);
    NSInteger currentIndex = SPKResolveCurrentIndexForContext(context);
    return [NSString stringWithFormat:@"%@|%@|%@|bulk:%lu|%@|%@|%@|%@|%@|%@|%@|%@|%p|idx:%ld",
                                      SPKActionButtonTopicKeyForSource(context.source),
                                      defaultIdentifier ?: @"",
                                      [visibleActions componentsJoinedByString:@","],
                                      (unsigned long)bulkEntryCount,
                                      dynamicStoryRuleTitle ?: @"",
                                      dynamicStoryAutoSaveTitle ?: @"",
                                      dynamicDirectAutoSaveTitle ?: @"",
                                      dynamicInstantsAutoSaveTitle ?: @"",
                                      dynamicProfileStoryRuleTitle ?: @"",
                                      dynamicProfileMessagesRuleTitle ?: @"",
                                      profileInfoSignature ?: @"",
                                      configuration.dictionaryRepresentation.description ?: @"",
                                      media,
                                      (long)currentIndex];
}

void SPKArmPendingRepostFeedback(SPKActionButtonContext *context) {
    if (!context)
        return;

    NSString *sourceValue = [NSString stringWithFormat:@"%ld", (long)context.source];
    SPKPendingRepostFeedback = @{
        @"title" : SPKL(@"GENERAL_REPOST_TAPPED_TOAST"),
        @"iconResource" : @"ig_icon_reshare_outline_24",
        @"source" : sourceValue
    };
}

NSDictionary<NSString *, NSString *> *SPKConsumePendingRepostFeedback(SPKActionButtonSource source) {
    NSString *expectedSource = [NSString stringWithFormat:@"%ld", (long)source];
    if (![SPKPendingRepostFeedback[@"source"] isEqualToString:expectedSource])
        return nil;

    NSDictionary<NSString *, NSString *> *feedback = SPKPendingRepostFeedback;
    SPKPendingRepostFeedback = nil;
    return feedback;
}

// A cover is a separate artifact from the video it belongs to, but it shares the post's
// identity — and without any identity, `SPKDuplicateKey` has nothing to hash, so
// duplicate detection waves every cover save through no matter how often the same one was
// already downloaded. Carry the identity fields over (the media type already keeps the
// cover's key apart from the video's) and leave the measurements behind: the entry's pixel
// size and duration describe the video, not its cover.
static SPKGallerySaveMetadata *SPKThumbnailMetadataFromEntryMetadata(SPKGallerySaveMetadata *meta) {
    SPKGallerySaveMetadata *thumbnailMeta = [[SPKGallerySaveMetadata alloc] init];
    thumbnailMeta.source = (int16_t)SPKGallerySourceThumbnail;
    thumbnailMeta.sourceUsername = meta.sourceUsername;
    thumbnailMeta.sourceUserPK = meta.sourceUserPK;
    thumbnailMeta.sourceProfileURLString = meta.sourceProfileURLString;
    thumbnailMeta.sourceMediaPK = meta.sourceMediaPK;
    thumbnailMeta.sourceMediaCode = meta.sourceMediaCode;
    // Keeps any `img_index` the carousel slide added, so two slides' covers stay distinct.
    thumbnailMeta.sourceMediaURLString = meta.sourceMediaURLString;
    thumbnailMeta.importPostedDate = meta.importPostedDate;
    thumbnailMeta.sourceFullName = meta.sourceFullName;
    return thumbnailMeta;
}

static void SPKShowExtractedVideoCover(NSURL *videoURL, SPKGallerySaveMetadata *metadata, SPKActionButtonContext *context) {
    if (!videoURL) {
        SPKNotify(kSPKNotificationViewThumbnail, SPKL(@"ACTION_BUTTON_COVER_UNAVAILABLE_TOAST"), nil, @"error_filled", SPKNotificationToneError);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
        AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        generator.appliesPreferredTrackTransform = YES;
        generator.maximumSize = CGSizeMake(2160, 2160);

        NSError *error = nil;
        CGImageRef imageRef = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(0.0, 600) actualTime:NULL error:&error];
        if (!imageRef) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SPKNotify(kSPKNotificationViewThumbnail, SPKL(@"ACTION_BUTTON_COVER_UNAVAILABLE_TOAST"), error.localizedDescription ?: @"", @"error_filled", SPKNotificationToneError);
            });
            return;
        }

        UIImage *image = [UIImage imageWithCGImage:imageRef];
        CGImageRelease(imageRef);

        dispatch_async(dispatch_get_main_queue(), ^{
            [SPKFullScreenMediaPlayer showImage:image
                                       metadata:metadata
                                 playbackSource:SPKPlaybackSourceForActionSource(context.source)
                                     sourceView:context.view
                                     controller:context.controller
                                  pausePlayback:SPKPausePlaybackBlockForContext(context)
                                 resumePlayback:SPKResumePlaybackBlockForContext(context)];
        });
    });
}

static void SPKPerformBatchDownloadWithQualityPrompt(NSArray<SPKResolvedMediaEntry *> *selectedEntries,
                                                      SPKActionButtonSource source,
                                                      NSString *username,
                                                      id media,
                                                      SPKDownloadDestination destination,
                                                      NSString *identifier,
                                                      UIViewController *presenter,
                                                      UIView *anchorView,
                                                      SPKDownloadSourceSurface surface) {
    if (selectedEntries.count == 0)
        return;

    BOOL copiesLinks = [identifier isEqualToString:kSPKActionDownloadAllLinks];
    void (^performBatchDownloadWithQuality)(NSString *) = ^(NSString *qualityOverride) {
        void (^startDownload)(void) = ^{
            if (copiesLinks) {
                [[SPKNotificationCenter shared] dismissTransientProgressPill];
                NSArray<NSString *> *links = SPKBulkDownloadLinksFromEntries(selectedEntries, media, qualityOverride);
                if (links.count == 0) {
                    SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_LINKS_AVAILABLE_TEXT"), nil, @"error_filled", SPKNotificationToneError);
                    return;
                }
                [UIPasteboard generalPasteboard].string = [links componentsJoinedByString:@"\n"];
                SPKNotify(identifier, SPKCopiedDownloadURLTitleForSource(source, links.count > 1), links.count > 1 ? SPKLP(@"COMMON_ITEM_COUNT", (NSInteger)links.count) : nil, @"copy_filled", SPKNotificationToneForIconResource(@"copy_filled"));
                return;
            }
            NSArray<SPKDownloadItemRequest *> *bulkItems = SPKBulkDownloadItemsFromEntries(selectedEntries, source, username, media, qualityOverride, destination);
            [SPKDownloadHelpers performBulkDownloadIdentifier:identifier
                                                         items:bulkItems
                                                     presenter:presenter
                                                    anchorView:anchorView
                                                 sourceSurface:surface];
        };

        NSString *effectiveQuality = qualityOverride.length > 0 ? qualityOverride : [SPKUtils getStringPref:@"downloads_photo_quality"];
        // Without a presenter to ask, a link resolves Always Ask to Max.
        if (copiesLinks && [effectiveQuality isEqualToString:@"always_ask"])
            effectiveQuality = @"max";
        if ([effectiveQuality isEqualToString:@"max"] && [SPKUtils getBoolPref:@"downloads_fetch_4k_images"]) {
            NSString *topPK = SPKMediaPKForMediaObject(media);
            if (topPK.length > 0 && ![SPKMediaQualityManager hasWebPhotoCandidatesFetchedForPK:topPK]) {
                if (SPKNotificationIsEnabled(identifier)) {
                    [[SPKNotificationCenter shared] beginTransientProgressWithTitle:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_FETCHING_4K_CANDIDATES_TEXT") onCancel:nil];
                }
                [SPKInstagramAPI fetchWebMediaInfoForPK:topPK completion:^(NSDictionary *response, NSError *error) {
                    [SPKMediaQualityManager markWebPhotoCandidatesFetchedForPK:topPK];
                    if (response) {
                        [SPKMediaQualityManager cacheWebCandidatesFromResponse:response];
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        startDownload();
                    });
                }];
                return;
            }
        }

        startDownload();
    };

    NSString *photoQuality = [SPKUtils getStringPref:@"downloads_photo_quality"] ?: @"high";
    if ([photoQuality isEqualToString:@"always_ask"] && presenter) {
        BOOL can4K = [SPKUtils getBoolPref:@"downloads_fetch_4k_images"];
        NSMutableArray<SPKIGAlertAction *> *actions = [NSMutableArray array];
        if (can4K) {
            [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_MAX") style:SPKIGAlertActionStyleDefault handler:^{
                performBatchDownloadWithQuality(@"max");
            }]];
        }
        [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_HIGH") style:SPKIGAlertActionStyleDefault handler:^{
            performBatchDownloadWithQuality(@"high");
        }]];
        [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_MEDIUM") style:SPKIGAlertActionStyleDefault handler:^{
            performBatchDownloadWithQuality(@"medium");
        }]];
        [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_LOW") style:SPKIGAlertActionStyleDefault handler:^{
            performBatchDownloadWithQuality(@"low");
        }]];
        [actions addObject:[SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL") style:SPKIGAlertActionStyleCancel handler:nil]];

        [SPKIGAlertPresenter presentActionSheetFromViewController:presenter
                                                             title:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_BATCH_DOWNLOAD_QUALITY_TEXT")
                                                           message:[NSString stringWithFormat:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_SELECT_QUALITY_VALUE_ITEMS_FORMAT"), (unsigned long)selectedEntries.count]
                                                           actions:actions];
        return;
    }

    performBatchDownloadWithQuality(nil);
}

static BOOL SPKExecuteBulkChildAction(NSString *identifier,
                                      SPKActionButtonContext *context,
                                      NSArray<SPKResolvedMediaEntry *> *entries,
                                      NSString *username,
                                      id media) {
    NSArray<SPKResolvedMediaEntry *> *downloadableEntries = SPKDownloadableEntries(entries);
    if (downloadableEntries.count < 2) {
        SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_BULK_MEDIA_AVAILABLE_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return YES;
    }

    UIViewController *presenter = SPKActionContextPresenter(context);
    UIView *anchorView = SPKActionContextAnchorView(context);
    SPKDownloadSourceSurface surface = [SPKDownloadHelpers sourceSurfaceForActionButtonSource:context.source];
    SPKDownloadDestination destination = [identifier isEqualToString:kSPKActionDownloadAllGallery] ? SPKDownloadDestinationGallery : SPKDownloadDestinationPhotos;

    SPKPerformBatchDownloadWithQualityPrompt(downloadableEntries, context.source, username, media, destination, identifier, presenter, anchorView, surface);
    return YES;
}

static BOOL SPKExecuteCommonAction(NSString *identifier,
                                   SPKActionButtonContext *context,
                                   SPKResolvedMediaEntry *currentEntry,
                                   NSArray<SPKResolvedMediaEntry *> *entries,
                                   NSInteger resolvedIndex,
                                   NSString *username,
                                   SPKGallerySaveMetadata *meta,
                                   id media) {
    NSURL *currentURL = currentEntry.videoURL ?: currentEntry.photoURL;
    BOOL isVideo = (currentEntry.videoURL != nil);
    BOOL shouldNotify = SPKNotificationIsEnabled(identifier);

    if ([identifier isEqualToString:kSPKActionDownloadAll]) {
        return YES;
    }
    if (SPKIsBulkChildActionIdentifier(identifier)) {
        return SPKExecuteBulkChildAction(identifier, context, entries, username, media);
    }

    // Master audio-downloads toggle — guards here too in case a cached (stale) menu
    // still exposes an audio action after the toggle was turned off.
    if (([identifier isEqualToString:kSPKActionDownloadAudio] ||
         [identifier isEqualToString:kSPKActionDownloadAudioShare] ||
         [identifier isEqualToString:kSPKActionDownloadAudioGallery] ||
         [identifier isEqualToString:kSPKActionPlayAudio] ||
         [identifier isEqualToString:kSPKActionCopyAudioURL]) &&
        ![SPKUtils getBoolPref:@"downloads_audio_enabled"]) {
        return YES;
    }

    if ([identifier isEqualToString:kSPKActionDownloadAudio] ||
        [identifier isEqualToString:kSPKActionDownloadAudioShare] ||
        [identifier isEqualToString:kSPKActionDownloadAudioGallery]) {
        id audioMedia = currentEntry.metadataObject ?: currentEntry.mediaObject ?
                                                                                : media;
        SPKAudioItem *audioItem = [SPKAudioDownloadCoordinator audioItemFromMediaObject:audioMedia
                                                                                 source:SPKAudioSourceForActionSource(context.source)
                                                                     allowVideoFallback:YES];
        if (!audioItem && media && media != audioMedia) {
            audioItem = [SPKAudioDownloadCoordinator audioItemFromMediaObject:media
                                                                       source:SPKAudioSourceForActionSource(context.source)
                                                           allowVideoFallback:YES];
        }
        if (!audioItem) {
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_AUDIO_AVAILABLE_TEXT"), nil, @"error_filled", SPKNotificationToneError);
            return YES;
        }
        if (audioItem.artist.length == 0)
            audioItem.artist = username;
        if (audioItem.sourceURLString.length == 0)
            audioItem.sourceURLString = audioItem.url.absoluteString;

        SPKAudioAction audioAction = SPKAudioActionConvertAndShare;
        if ([identifier isEqualToString:kSPKActionDownloadAudioGallery]) {
            audioAction = SPKAudioActionConvertAndSaveToGallery;
        } else if ([identifier isEqualToString:kSPKActionDownloadAudio]) {
            audioAction = SPKAudioActionSaveToFiles;
        }
        [SPKAudioDownloadCoordinator performAction:audioAction
                                              item:audioItem
                                         presenter:SPKActionContextPresenter(context)
                                        sourceView:SPKActionContextAnchorView(context)
                                          metadata:meta
                            notificationIdentifier:identifier
                                    playbackSource:SPKPlaybackSourceForActionSource(context.source)
                                     pausePlayback:SPKPausePlaybackBlockForContext(context)
                                    resumePlayback:SPKResumePlaybackBlockForContext(context)];
        return YES;
    }

    if ([identifier isEqualToString:kSPKActionPlayAudio] ||
        [identifier isEqualToString:kSPKActionCopyAudioURL]) {
        id audioMedia = currentEntry.metadataObject ?: currentEntry.mediaObject ?
                                                                                : media;
        SPKAudioItem *audioItem = [SPKAudioDownloadCoordinator audioItemFromMediaObject:audioMedia
                                                                                 source:SPKAudioSourceForActionSource(context.source)];
        if (!audioItem && media && media != audioMedia) {
            audioItem = [SPKAudioDownloadCoordinator audioItemFromMediaObject:media
                                                                       source:SPKAudioSourceForActionSource(context.source)];
        }
        if (!audioItem) {
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_AUDIO_AVAILABLE_TEXT"), nil, @"error_filled", SPKNotificationToneError);
            return YES;
        }
        if (audioItem.artist.length == 0)
            audioItem.artist = username;
        if (audioItem.sourceURLString.length == 0)
            audioItem.sourceURLString = audioItem.url.absoluteString;

        SPKAudioAction audioAction = [identifier isEqualToString:kSPKActionPlayAudio] ? SPKAudioActionPlay : SPKAudioActionCopyURL;
        [SPKAudioDownloadCoordinator performAction:audioAction
                                              item:audioItem
                                         presenter:SPKActionContextPresenter(context)
                                        sourceView:SPKActionContextAnchorView(context)
                                          metadata:meta
                            notificationIdentifier:identifier
                                    playbackSource:SPKPlaybackSourceForActionSource(context.source)
                                     pausePlayback:SPKPausePlaybackBlockForContext(context)
                                    resumePlayback:SPKResumePlaybackBlockForContext(context)];
        return YES;
    }

    if ([identifier isEqualToString:kSPKActionTrimSave]) {
        id mediaForTrim = currentEntry.metadataObject ?: currentEntry.mediaObject ?
                                                                                  : media;
        [SPKTrimEntry beginTrimAndSaveForMediaObject:mediaForTrim
                                            photoURL:currentEntry.photoURL
                                            videoURL:currentEntry.videoURL
                                            metadata:meta
                                           presenter:SPKActionContextPresenter(context)];
        return YES;
    }

    if ([identifier isEqualToString:kSPKActionEditSave]) {
        id mediaForEdit = currentEntry.metadataObject ?: currentEntry.mediaObject ?
                                                                                  : media;
        [SPKPhotoEditEntry beginEditAndSaveForMediaObject:mediaForEdit
                                                 photoURL:currentEntry.photoURL
                                                 metadata:meta
                                                presenter:SPKActionContextPresenter(context)];
        return YES;
    }

    if ([identifier isEqualToString:kSPKActionDownloadLibrary] ||
        [identifier isEqualToString:kSPKActionDownloadShare] ||
        [identifier isEqualToString:kSPKActionDownloadGallery]) {
        if (!currentURL) {
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_DOWNLOADABLE_MEDIA_TEXT"), nil, @"error_filled", SPKNotificationToneError);
            return YES;
        }

        SPKDownloadDestination destination = SPKDownloadDestinationPhotos;
        if ([identifier isEqualToString:kSPKActionDownloadShare])
            destination = SPKDownloadDestinationShare;
        else if ([identifier isEqualToString:kSPKActionDownloadGallery])
            destination = SPKDownloadDestinationGallery;

        id mediaForDownload = currentEntry.metadataObject ?: currentEntry.mediaObject ?
                                                                                      : media;
        UIViewController *presenter = SPKActionContextPresenter(context);
        UIView *anchorView = SPKActionContextAnchorView(context);
        SPKDownloadSourceSurface surface = [SPKDownloadHelpers sourceSurfaceForActionButtonSource:context.source];
        if ([SPKMediaQualityManager handleDownloadDestination:destination
                                                   identifier:identifier
                                                    presenter:presenter
                                                   sourceView:anchorView
                                                  mediaObject:mediaForDownload
                                                     photoURL:currentEntry.photoURL
                                                     videoURL:currentEntry.videoURL
                                              galleryMetadata:meta
                                                 showProgress:shouldNotify
                                                sourceSurface:surface]) {
            return YES;
        }

        [SPKDownloadHelpers downloadURL:currentURL
                              extension:SPKExtensionForURL(currentURL, isVideo)
                            destination:destination
                               metadata:meta
                         notificationID:identifier
                              presenter:presenter
                          sourceSurface:surface];
        return YES;
    }

    if ([identifier isEqualToString:kSPKActionCopyDownloadLink]) {
        id mediaForCopy = currentEntry.metadataObject ?: currentEntry.mediaObject ?
                                                                                  : media;
        // Copying never adopts the "Fetching 4K candidates" pill the way a download
        // does, so it has to clear it or the pill spins forever.
        [[SPKNotificationCenter shared] dismissTransientProgressPill];
        SPKActionButtonSource source = context.source;
        [SPKMediaQualityManager resolveDownloadLinkForMediaObject:mediaForCopy
                                                         photoURL:currentEntry.photoURL
                                                         videoURL:currentEntry.videoURL
                                                        presenter:SPKActionContextPresenter(context)
                                                       sourceView:SPKActionContextAnchorView(context)
                                                       completion:^(NSURL *url) {
                                                           NSURL *bestURL = url ?: SPKBestDownloadURLForMediaObject(mediaForCopy);
                                                           if (!bestURL) {
                                                               SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_LINK_AVAILABLE_TEXT"), nil, @"error_filled", SPKNotificationToneError);
                                                               return;
                                                           }
                                                           [UIPasteboard generalPasteboard].string = bestURL.absoluteString ?: @"";
                                                           SPKNotify(identifier, SPKCopiedDownloadURLTitleForSource(source, NO), nil, @"copy_filled", SPKNotificationToneForIconResource(@"copy_filled"));
                                                       }];
        return YES;
    }

    if ([identifier isEqualToString:kSPKActionCopyMedia]) {
        id mediaForCopy = currentEntry.metadataObject ?: currentEntry.mediaObject ?
                                                                                  : media;
        SPKDownloadSourceSurface surface = [SPKDownloadHelpers sourceSurfaceForActionButtonSource:context.source];
        if ([SPKMediaQualityManager handleCopyActionWithIdentifier:identifier
                                                         presenter:SPKActionContextPresenter(context)
                                                        sourceView:SPKActionContextAnchorView(context)
                                                       mediaObject:mediaForCopy
                                                          photoURL:currentEntry.photoURL
                                                          videoURL:currentEntry.videoURL
                                                   galleryMetadata:meta
                                                      showProgress:shouldNotify
                                                     sourceSurface:surface]) {
            return YES;
        }

        if (!currentURL && !currentEntry.photoURL) {
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NOTHING_COPY_TEXT"), nil, @"error_filled", SPKNotificationToneForIconResource(@"error_filled"));
            return YES;
        }

        if (!isVideo) {
            NSData *imageData = currentURL ? [NSData dataWithContentsOfURL:currentURL] : nil;
            UIImage *image = imageData ? [UIImage imageWithData:imageData] : nil;
            if (image) {
                [[UIPasteboard generalPasteboard] setImage:image];
                SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPIED_PHOTO_CLIPBOARD_TEXT"), nil, @"copy_filled", SPKNotificationToneForIconResource(@"copy_filled"));
            }
            return YES;
        }

        NSData *data = [NSData dataWithContentsOfURL:currentURL];
        if (data) {
            [[UIPasteboard generalPasteboard] setData:data forPasteboardType:@"public.mpeg-4"];
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPIED_VIDEO_CLIPBOARD_TEXT"), nil, @"copy_filled", SPKNotificationToneForIconResource(@"copy_filled"));
        } else {
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NOTHING_COPY_TEXT"), nil, @"error_filled", SPKNotificationToneForIconResource(@"error_filled"));
        }
        return YES;
    }

    if ([identifier isEqualToString:kSPKActionExpand]) {
        // Filter here as well, so `playerItems` below (which skips entries with no URL)
        // stays one-to-one with `previewEntries` and the index needs no second mapping.
        NSArray<SPKResolvedMediaEntry *> *previewEntries = SPKDownloadableEntries(entries);
        NSArray<SPKResolvedMediaEntry *> *bulkEntries = SPKDownloadableEntries(SPKBulkEntriesForContext(context));
        if (bulkEntries.count > previewEntries.count) {
            previewEntries = bulkEntries;
        }
        NSArray<SPKMediaItem *> *playerItems = SPKPlayerItemsFromEntries(previewEntries, context.source, username, media);
        if (playerItems.count == 0) {
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_MEDIA_EXPAND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
            return YES;
        }

        NSInteger previewIndex = SPKPreviewIndexForEntry(currentEntry, previewEntries,
                                                         SPKResolveCurrentIndexForContext(context));
        NSInteger clampedIndex = SPKClampedIndex(previewIndex, (NSInteger)playerItems.count);
        SPKNotify(identifier, SPKL(@"FEED_FEED_ACTION_BUTTON_EXPANDED_MEDIA_TEXT"), nil, @"expand", SPKNotificationToneForIconResource(@"expand"));
        [SPKFullScreenMediaPlayer showMediaItems:playerItems
                                 startingAtIndex:clampedIndex
                                        metadata:meta
                                  playbackSource:SPKPlaybackSourceForActionSource(context.source)
                                      sourceView:context.view
                                      controller:context.controller
                                   pausePlayback:SPKPausePlaybackBlockForContext(context)
                                  resumePlayback:SPKResumePlaybackBlockForContext(context)];
        return YES;
    }

    if ([identifier isEqualToString:kSPKActionViewThumbnail]) {
        BOOL isVideo = currentEntry.videoURL != nil;
        if (isVideo && context.source == SPKActionButtonSourceStories && currentEntry.photoURL) {
            isVideo = ![currentEntry.videoURL isEqual:currentEntry.photoURL];
        }
        if (!isVideo) {
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_THUMBNAIL_ONLY_AVAILABLE_VIDEOS_TEXT"), nil, @"error_filled", SPKNotificationToneError);
            return YES;
        }

        SPKGallerySaveMetadata *thumbnailMeta = SPKThumbnailMetadataFromEntryMetadata(meta);
        id mediaForThumbnail = currentEntry.metadataObject ?: currentEntry.mediaObject ?
                                                                                       : media;
        NSURL *coverURL = SPKCoverURLForMediaObject(mediaForThumbnail);
        if (coverURL) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSData *data = [NSData dataWithContentsOfURL:coverURL];
                UIImage *image = data ? [UIImage imageWithData:data] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (image) {
                        [SPKFullScreenMediaPlayer showImage:image
                                                   metadata:thumbnailMeta
                                             playbackSource:SPKPlaybackSourceForActionSource(context.source)
                                                 sourceView:context.view
                                                 controller:context.controller
                                              pausePlayback:SPKPausePlaybackBlockForContext(context)
                                             resumePlayback:SPKResumePlaybackBlockForContext(context)];
                    } else {
                        SPKShowExtractedVideoCover(currentEntry.videoURL, thumbnailMeta, context);
                    }
                });
            });
        } else {
            SPKShowExtractedVideoCover(currentEntry.videoURL, thumbnailMeta, context);
        }
        SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_OPENED_THUMBNAIL_TEXT"), nil, @"photo_gallery", SPKNotificationToneForIconResource(@"photo_gallery"));
        return YES;
    }

    if ([identifier isEqualToString:kSPKActionCopyCaption]) {
        NSString *caption = context.captionResolver ? context.captionResolver(context, media, entries, resolvedIndex) : nil;
        if (caption.length == 0) {
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_CAPTION_AVAILABLE_TEXT"), nil, @"error_filled", SPKNotificationToneError);
            return YES;
        }

        [UIPasteboard generalPasteboard].string = caption;
        SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_CAPTION_COPIED_TEXT"), nil, @"copy_filled", SPKNotificationToneForIconResource(@"copy_filled"));
        return YES;
    }

    if ([identifier isEqualToString:kSPKActionOpenTopicSettings]) {
        NSString *settingsTitle = SPKResolvedSettingsTitleForContext(context);
        if (settingsTitle.length == 0) {
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_SETTINGS_UNAVAILABLE_TEXT"), nil, @"error_filled", SPKNotificationToneError);
            return YES;
        }

        SPKNotify(identifier, SPKL(@"COMMON_OPENED_SETTINGS_TOAST"), nil, @"settings", SPKNotificationToneForIconResource(@"settings"));
        [SPKUtils showSettingsForTopicTitle:settingsTitle];
        return YES;
    }

    if ([identifier isEqualToString:kSPKActionRepost]) {
        if (context.repostHandler) {
            SPKArmPendingRepostFeedback(context);
        }
        BOOL handled = context.repostHandler ? context.repostHandler(context) : NO;
        if (!handled) {
            SPKConsumePendingRepostFeedback(context.source);
        }
        if (!handled) {
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_REPOST_UNAVAILABLE_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        }
        return YES;
    }

    return NO;
}

static BOOL SPKExecuteToggleStoryAutoSaveUserRuleAction(SPKActionButtonContext *context) {
    SPKStoryContext *storyContext = SPKStoryContextForActionButtonContext(context);
    NSString *title = SPKStoryAutoSaveCurrentUserConfirmationTitle(storyContext);
    NSString *message = SPKStoryAutoSaveCurrentUserConfirmationMessage(storyContext);
    if (title.length == 0 || message.length == 0) {
        SPKNotify(kSPKNotificationStoryAutoSaveUserRule, SPKL(@"STORIES_STORY_SEEN_BUTTONS_STORY_USER_NOT_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return YES;
    }

    [SPKUtils
        showConfirmation:^{
            NSString *notificationTitle = nil;
            NSString *notificationSubtitle = nil;
            if (!SPKStoryToggleAutoSaveCurrentUser(storyContext, &notificationTitle, &notificationSubtitle)) {
                SPKNotify(kSPKNotificationStoryAutoSaveUserRule, SPKL(@"STORIES_STORY_SEEN_BUTTONS_STORY_USER_NOT_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
                return;
            }
            SPKNotify(kSPKNotificationStoryAutoSaveUserRule, notificationTitle, notificationSubtitle, @"circle_check_filled", SPKNotificationToneSuccess);
            [storyContext.overlayView setNeedsLayout];
        }
                   title:title
                 message:message];
    return YES;
}

static BOOL SPKExecuteToggleDirectAutoSaveThreadRuleAction(SPKActionButtonContext *context) {
    SPKDirectPresentAutoSaveThreadRuleToggle(SPKDirectThreadContextFromSource(context.controller));
    return YES;
}

/// The media PK of the Instant currently on screen, read straight off the resolved snap.
/// Deliberately a PK read and nothing more: this runs during menu construction.
static NSString *SPKInstantsMarkSeenMediaPKForContext(SPKActionButtonContext *context) {
    id media = context ? SPKResolveMediaForContext(context) : nil;
    if (!media)
        return nil;
    NSString *pk = SPKStringFromValue(SPKObjectForSelector(media, @"sourceMediaPK"));
    if (pk.length == 0)
        pk = SPKStringFromValue(SPKObjectForSelector(media, @"pk"));
    return pk;
}

/// Releases one held Instant: stops keeping it unseen and marks it seen for real.
static BOOL SPKExecuteInstantsMarkSeenAction(SPKActionButtonContext *context) {
    NSString *pk = SPKInstantsMarkSeenMediaPKForContext(context);
    if (pk.length == 0) {
        SPKNotify(kSPKNotificationInstantsMarkSeen,
                  SPKL(@"INSTANTS_MARK_SEEN_FAILED_TOAST"), nil, @"error_filled",
                  SPKNotificationToneError);
        return YES;
    }
    SPKInstantsManualSeenMarkMediaPK(pk);
    SPKNotify(kSPKNotificationInstantsMarkSeen,
              SPKL(@"INSTANTS_MARK_SEEN_DONE_TOAST"), nil, @"circle_check_filled",
              SPKNotificationToneSuccess);
    // The release above is written synchronously, so the viewer can move on straight away.
    if ([SPKUtils getBoolPref:@"instants_advance_on_manual_seen"])
        SPKInstantsAdvanceViewer(context.view);
    return YES;
}

static BOOL SPKExecuteToggleInstantsAutoSaveUserRuleAction(SPKActionButtonContext *context) {
    NSString *username = SPKInstantsAutoSaveUsernameForContext(context);
    NSString *title = SPKInstantsAutoSaveConfirmationTitleForUsername(username);
    NSString *message = SPKInstantsAutoSaveConfirmationMessageForUsername(username);
    if (title.length == 0 || message.length == 0) {
        SPKNotify(kSPKNotificationInstantsAutoSaveUserRule, SPKL(@"INSTANTS_AUTO_SAVE_AUTHOR_NOT_FOUND_TOAST"), nil, @"error_filled", SPKNotificationToneError);
        return YES;
    }

    __weak UIView *weakView = context.view;
    [SPKUtils
        showConfirmation:^{
            NSString *notificationTitle = nil;
            NSString *notificationSubtitle = nil;
            if (!SPKInstantsToggleAutoSaveForUsername(username, &notificationTitle, &notificationSubtitle)) {
                SPKNotify(kSPKNotificationInstantsAutoSaveUserRule, SPKL(@"INSTANTS_AUTO_SAVE_AUTHOR_NOT_FOUND_TOAST"), nil, @"error_filled", SPKNotificationToneError);
                return;
            }
            SPKNotify(kSPKNotificationInstantsAutoSaveUserRule, notificationTitle, notificationSubtitle, @"circle_check_filled", SPKNotificationToneSuccess);
            UIView *view = weakView;
            if (!view)
                return;

            // Catch the instant that's still on screen rather than making the user
            // tap forward for the rule to take effect.
            SPKInstantsAutoSaveConsiderCurrentSnapInView(view);

            // The Instants button builds its menu once per button lifecycle and is
            // never reconfigured from layout (unlike the story overlay, which a
            // setNeedsLayout would be enough for), so the action's title would keep
            // reading the pre-toggle state until the viewer is closed. Rebuild it
            // here, which is safe: the menu is already dismissed by the time an
            // action executes, so this cannot fight the iOS 26 menu morph.
            if ([view isKindOfClass:[UIButton class]])
                SPKConfigureActionButton((UIButton *)view, context);
        }
                   title:title
                 message:message];
    return YES;
}

static BOOL SPKExecuteToggleStorySeenUserRuleAction(SPKActionButtonContext *context) {
    SPKStoryContext *storyContext = SPKStoryContextForActionButtonContext(context);
    NSString *title = SPKStoryCurrentUserRuleConfirmationTitle(storyContext);
    NSString *message = SPKStoryCurrentUserRuleConfirmationMessage(storyContext);
    if (title.length == 0 || message.length == 0) {
        SPKNotify(kSPKNotificationStorySeenUserRule, SPKL(@"STORIES_STORY_SEEN_BUTTONS_STORY_USER_NOT_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return YES;
    }

    [SPKUtils
        showConfirmation:^{
            NSString *notificationTitle = nil;
            NSString *notificationSubtitle = nil;
            if (!SPKStoryToggleCurrentUserRule(storyContext, &notificationTitle, &notificationSubtitle)) {
                SPKNotify(kSPKNotificationStorySeenUserRule, SPKL(@"STORIES_STORY_SEEN_BUTTONS_STORY_USER_NOT_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
                return;
            }
            SPKNotify(kSPKNotificationStorySeenUserRule, notificationTitle, notificationSubtitle, @"circle_check_filled", SPKNotificationToneSuccess);
            [storyContext.overlayView setNeedsLayout];
        }
                   title:title
                 message:message];
    return YES;
}

static BOOL SPKExecuteToggleProfileStorySeenUserRuleAction(SPKActionButtonContext *context) {
    id user = SPKResolveMediaForContext(context);
    NSString *pk = user ? [SPKUtils pkFromIGUser:user] : nil;
    NSString *username = user ? SPKProfileUsername(user) : nil;
    NSString *fullName = user ? SPKProfileFullName(user) : nil;
    NSString *profilePicUrl = user ? spkDirectUserResolverProfilePicURLStringFromUser(user) : nil;
    if (pk.length == 0 || username.length == 0) {
        SPKNotify(kSPKNotificationProfileStorySeenUserRule, SPKL(@"MESSAGES_ACTIVITY_USER_NOT_FOUND_TOAST"), nil, @"error_filled", SPKNotificationToneError);
        return YES;
    }

    BOOL manualSeenEnabled = SPKStoryManualSeenEnabled();
    BOOL listed = SPKStoryManualSeenListContainsUser(pk, manualSeenEnabled);
    BOOL applies = manualSeenEnabled ? !listed : listed;

    NSString *title = applies ? SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_START_MARKING_STORIES_SEEN_TEXT") : SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_STOP_MARKING_STORIES_SEEN_TEXT");
    NSString *message = applies
                            ? [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_START_MARKING_STORIES_VALUE_SEEN_FORMAT"), username]
                            : [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_STOP_MARKING_STORIES_VALUE_SEEN_FORMAT"), username];

    [SPKUtils
        showConfirmation:^{
            SPKStoryToggleUserRuleForPK(pk, username, fullName, profilePicUrl);
            NSString *notificationTitle = applies
                                              ? [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_STORIES_SEEN_ON_FORMAT"), username]
                                              : [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_STORIES_SEEN_OFF_FORMAT"), username];
            SPKNotify(kSPKNotificationProfileStorySeenUserRule, notificationTitle, nil, @"circle_check_filled", SPKNotificationToneSuccess);
            [[NSNotificationCenter defaultCenter] postNotificationName:SPKActionButtonConfigurationDidChangeNotification object:nil];
        }
                   title:title
                 message:message];
    return YES;
}

static BOOL SPKExecuteToggleProfileMessagesSeenUserRuleAction(SPKActionButtonContext *context) {
    id user = SPKResolveMediaForContext(context);
    NSString *pk = user ? [SPKUtils pkFromIGUser:user] : nil;
    NSString *username = user ? SPKProfileUsername(user) : nil;
    NSString *fullName = user ? SPKProfileFullName(user) : nil;
    NSString *profilePicUrl = user ? spkDirectUserResolverProfilePicURLStringFromUser(user) : nil;
    if (pk.length == 0 || username.length == 0) {
        SPKNotify(kSPKNotificationProfileMessagesSeenUserRule, SPKL(@"MESSAGES_ACTIVITY_USER_NOT_FOUND_TOAST"), nil, @"error_filled", SPKNotificationToneError);
        return YES;
    }

    BOOL manualSeenEnabled = [SPKUtils getBoolPref:@"msgs_manual_seen"];
    NSDictionary *existingEntry = SPKDirectManualSeenThreadEntryForUserPK(pk, manualSeenEnabled);
    BOOL listed = (existingEntry != nil);
    BOOL applies = manualSeenEnabled ? !listed : listed;

    NSString *title = applies ? SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_START_MARKING_MESSAGES_SEEN_MESSAGE") : SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_STOP_MARKING_MESSAGES_SEEN_MESSAGE");
    NSString *message = applies
                            ? [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_START_MARKING_MESSAGES_VALUE_SEEN_MESSAGE"), (fullName.length > 0 ? fullName : [@"@" stringByAppendingString:username])]
                            : [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_STOP_MARKING_MESSAGES_VALUE_SEEN_MESSAGE"), (fullName.length > 0 ? fullName : [@"@" stringByAppendingString:username])];
    [SPKUtils
        showConfirmation:^{
            if (listed) {
                NSString *threadId = existingEntry[@"threadId"];
                SPKDirectRemoveManualSeenThreadId(threadId, manualSeenEnabled);
                NSString *notificationTitle = [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_MESSAGES_SEEN_OFF_FORMAT"), (fullName.length > 0 ? fullName : [@"@" stringByAppendingString:username])];
                NSString *notificationSubtitle = SPKDirectManualSeenListTitle(manualSeenEnabled);
                SPKNotify(kSPKNotificationProfileMessagesSeenUserRule, notificationTitle, notificationSubtitle, @"circle_check_filled", SPKNotificationToneSuccess);
                [[NSNotificationCenter defaultCenter] postNotificationName:SPKActionButtonConfigurationDidChangeNotification object:nil];
            } else {
                NSString *encodedRecipients = [[NSString stringWithFormat:@"[%@]", pk] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
                [SPKInstagramAPI sendRequestWithMethod:@"GET"
                                                  path:[NSString stringWithFormat:@"direct_v2/threads/get_by_participants/?recipient_users=%@", encodedRecipients]
                                                  body:nil
                                            completion:^(NSDictionary *threadResponse, NSError *threadError) {
                                                NSDictionary *thread = threadResponse[@"thread"];
                                                NSString *threadId = SPKStringFromValue(thread[@"thread_id"] ?: thread[@"threadId"]);
                                                if (threadId.length == 0 || threadError) {
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                        SPKNotify(kSPKNotificationProfileMessagesSeenUserRule, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_CHAT_THREAD_FOUND_TEXT"), SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_MAKE_ACTIVE_CHAT_USER_TEXT"), @"error_filled", SPKNotificationToneError);
                                                    });
                                                    return;
                                                }
                                                dispatch_async(dispatch_get_main_queue(), ^{
                                                    NSMutableDictionary *usersEntry = [@{
                                                        @"pk" : pk,
                                                        @"username" : username,
                                                        @"fullName" : fullName ?: @"",
                                                    } mutableCopy];
                                                    if (profilePicUrl.length > 0)
                                                        usersEntry[@"profilePicUrl"] = profilePicUrl;

                                                    SPKDirectAddOrUpdateManualSeenThreadEntry(@{@"threadId" : threadId,
                                                                                                @"threadName" : fullName.length > 0 ? fullName : username,
                                                                                                @"isGroup" : @(NO),
                                                                                                @"users" : @[ usersEntry.copy ],
                                                    },
                                                                                              manualSeenEnabled);

                                                    NSString *notificationTitle = [NSString stringWithFormat:SPKL(@"ACTION_BUTTON_MESSAGES_SEEN_ON_FORMAT"), (fullName.length > 0 ? fullName : [@"@" stringByAppendingString:username])];
                                                    NSString *notificationSubtitle = SPKDirectManualSeenListTitle(manualSeenEnabled);
                                                    SPKNotify(kSPKNotificationProfileMessagesSeenUserRule, notificationTitle, notificationSubtitle, @"circle_check_filled", SPKNotificationToneSuccess);
                                                    [[NSNotificationCenter defaultCenter] postNotificationName:SPKActionButtonConfigurationDidChangeNotification object:nil];
                                                });
                                            }];
            }
        }
                   title:title
                 message:message];
    return YES;
}

static BOOL SPKExecuteStoryMentionsSheetAction(SPKActionButtonContext *context) {
    if (context.source != SPKActionButtonSourceStories || !context.view) {
        SPKNotify(kSPKNotificationStoryMentionsSheet, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_STORY_MENTIONS_UNAVAILABLE_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return YES;
    }

    id media = SPKResolveMediaForContext(context);
    if (!SPKStoryMediaHasMentions(media)) {
        SPKNotify(kSPKNotificationStoryMentionsSheet, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NO_MENTIONS_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return YES;
    }

    SPKPresentStoryMentionsSheet(context.view);
    return YES;
}

static BOOL SPKIsDownloadOrCopyAction(NSString *identifier) {
    return [identifier isEqualToString:kSPKActionDownloadLibrary] ||
           [identifier isEqualToString:kSPKActionDownloadShare] ||
           [identifier isEqualToString:kSPKActionDownloadGallery] ||
           [identifier isEqualToString:kSPKActionCopyDownloadLink] ||
           [identifier isEqualToString:kSPKActionDownloadAllLibrary] ||
           [identifier isEqualToString:kSPKActionDownloadAllShare] ||
           [identifier isEqualToString:kSPKActionDownloadAllGallery] ||
           [identifier isEqualToString:kSPKActionDownloadAllClipboard] ||
           [identifier isEqualToString:kSPKActionDownloadAllLinks];
}

BOOL SPKExecuteActionIdentifier(NSString *identifier, SPKActionButtonContext *context, BOOL isDefaultTap) {
    if (identifier.length == 0 || !context)
        return NO;

    if ([identifier isEqualToString:kSPKActionToggleStorySeenUserRule]) {
        return SPKExecuteToggleStorySeenUserRuleAction(context);
    }
    if ([identifier isEqualToString:kSPKActionToggleDirectAutoSaveThreadRule]) {
        return SPKExecuteToggleDirectAutoSaveThreadRuleAction(context);
    }
    if ([identifier isEqualToString:kSPKActionToggleInstantsAutoSaveUserRule]) {
        return SPKExecuteToggleInstantsAutoSaveUserRuleAction(context);
    }
    if ([identifier isEqualToString:kSPKActionInstantsMarkSeen]) {
        return SPKExecuteInstantsMarkSeenAction(context);
    }
    if ([identifier isEqualToString:kSPKActionToggleStoryAutoSaveUserRule]) {
        return SPKExecuteToggleStoryAutoSaveUserRuleAction(context);
    }
    if ([identifier isEqualToString:kSPKActionToggleProfileStorySeenUserRule]) {
        return SPKExecuteToggleProfileStorySeenUserRuleAction(context);
    }
    if ([identifier isEqualToString:kSPKActionToggleProfileMessagesSeenUserRule]) {
        return SPKExecuteToggleProfileMessagesSeenUserRuleAction(context);
    }
    if ([identifier isEqualToString:kSPKActionStoryMentionsSheet]) {
        return SPKExecuteStoryMentionsSheetAction(context);
    }
    if (context.source == SPKActionButtonSourceProfile && SPKIsProfileCopyActionIdentifier(identifier)) {
        return SPKExecuteProfileCopyAction(identifier, context);
    }
    if ([identifier isEqualToString:kSPKActionOpenTopicSettings]) {
        NSString *settingsTitle = SPKResolvedSettingsTitleForContext(context);
        if (settingsTitle.length == 0) {
            SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_SETTINGS_UNAVAILABLE_TEXT"), nil, @"error_filled", SPKNotificationToneError);
            return YES;
        }
        SPKNotify(identifier, SPKL(@"COMMON_OPENED_SETTINGS_TOAST"), nil, @"settings", SPKNotificationToneForIconResource(@"settings"));
        [SPKUtils showSettingsForTopicTitle:settingsTitle];
        return YES;
    }
    if (context.source == SPKActionButtonSourceDirect && [identifier isEqualToString:kSPKActionDeletedMessagesLog]) {
        [SPKDeletedMessagesViewController presentFromViewController:SPKActionContextPresenter(context)];
        return YES;
    }

    id media = SPKResolveMediaForContext(context);

    BOOL isVideo = [SPKMediaQualityManager mediaObjectIsVideo:media];
    NSString *photoQuality = [SPKUtils getStringPref:@"downloads_photo_quality"] ?: @"high";
    BOOL isBulkAction = SPKIsBulkChildActionIdentifier(identifier);
    // The profile button acts on an IGUser: its pk is a user id, which the web media
    // endpoint can't resolve, and a profile picture has no 4K candidates anyway.
    BOOL shouldFetch4K = [SPKUtils getBoolPref:@"downloads_fetch_4k_images"] &&
                         context.source != SPKActionButtonSourceProfile &&
                         !isVideo && 
                         ([photoQuality isEqualToString:@"max"] || ([photoQuality isEqualToString:@"always_ask"] && !isBulkAction));

    if (SPKIsDownloadOrCopyAction(identifier) && shouldFetch4K) {
        NSString *topPK = SPKMediaPKForMediaObject(media);
        if (topPK.length > 0 && ![SPKMediaQualityManager hasWebPhotoCandidatesFetchedForPK:topPK]) {
            if (isDefaultTap && !SPKActionIdentifierOpensPreview(identifier)) {
                SPKPausePlaybackForPreviewContext(context);
            }
            if (SPKNotificationIsEnabled(identifier)) {
                [[SPKNotificationCenter shared] beginTransientProgressWithTitle:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_FETCHING_4K_CANDIDATES_TEXT") onCancel:nil];
            }
            [SPKInstagramAPI fetchWebMediaInfoForPK:topPK completion:^(NSDictionary *response, NSError *error) {
                [SPKMediaQualityManager markWebPhotoCandidatesFetchedForPK:topPK];
                if (response) {
                    [SPKMediaQualityManager cacheWebCandidatesFromResponse:response];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    SPKExecuteActionIdentifier(identifier, context, isDefaultTap);
                });
            }];
            return YES;
        }
    }

    NSArray<SPKResolvedMediaEntry *> *entries = SPKEntriesFromMedia(media);
    if (SPKIsBulkChildActionIdentifier(identifier)) {
        id bulkMedia = SPKResolveBulkMediaForContext(context);
        NSArray<SPKResolvedMediaEntry *> *bulkEntries = SPKDownloadableEntries(SPKEntriesFromMedia(bulkMedia));
        if (bulkEntries.count > 0) {
            media = bulkMedia ?: media;
            entries = bulkEntries;
        }
    }
    if (entries.count == 0) {
        [[SPKNotificationCenter shared] dismissTransientProgressPill];
        SPKNotify(identifier, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_MEDIA_NOT_FOUND_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return NO;
    }

    NSInteger resolvedIndex = SPKClampedIndex(SPKResolveCurrentIndexForContext(context), (NSInteger)entries.count);
    SPKResolvedMediaEntry *currentEntry = entries[resolvedIndex];
    id metadataObject = currentEntry.metadataObject ?: currentEntry.mediaObject ?
                                                                                : media;

    NSString *username = (context.source == SPKActionButtonSourceDirect)
                             ? SPKDirectUsernameFromController(context.controller)
                             : SPKUsernameFromMediaObject(media);
    if (context.source == SPKActionButtonSourceInstants) {
        NSString *explicitUsername = SPKUsernameForEntry(currentEntry, nil);
        if (explicitUsername.length > 0) {
            username = explicitUsername;
        }
    }
    if (username.length == 0)
        username = SPKUsernameFromMediaObject(metadataObject);
    if (username.length == 0) {
        for (SPKResolvedMediaEntry *entry in entries) {
            username = SPKUsernameFromMediaObject(entry.metadataObject ?: entry.mediaObject);
            if (username.length > 0)
                break;
        }
    }
    if (context.source == SPKActionButtonSourceDirect && username.length > 0) {
        NSString *sessionUsername = SPKSessionUsernameFromController(context.controller);
        if (sessionUsername.length > 0 && [username caseInsensitiveCompare:sessionUsername] == NSOrderedSame) {
            username = nil;
        }
    }

    SPKGallerySaveMetadata *meta = SPKGalleryMetadata(context.source, username, metadataObject);
    SPKApplyEntryMetadata(meta, currentEntry);
    if (metadataObject != media && context.source != SPKActionButtonSourceInstants) {
        [SPKGalleryOriginController populateMetadata:meta fromMedia:media];
        if (entries.count > 1) {
            meta.sourceMediaURLString = [SPKUtils appendImgIndex:resolvedIndex toURLString:meta.sourceMediaURLString];
        }
    }

    if (isDefaultTap && !SPKActionIdentifierOpensPreview(identifier)) {
        SPKPausePlaybackForPreviewContext(context);
    }

    return SPKExecuteCommonAction(identifier, context, currentEntry, entries, resolvedIndex, username, meta, media);
}

static BOOL SPKActionButtonLegacyDiagnosticsEnabled(SPKActionButtonSource source) {
    return source == SPKActionButtonSourceFeed && SYSTEM_VERSION_LESS_THAN(@"26.0");
}

UIButton *SPKActionButtonWithTag(UIView *container, NSInteger tag) {
    UIView *existing = [container viewWithTag:tag];
    if ([existing isKindOfClass:[UIButton class]]) {
        return (UIButton *)existing;
    }
    [existing removeFromSuperview];

    SPKActionMenuButton *button = [[SPKActionMenuButton alloc] initWithSymbol:@"" pointSize:24.0 diameter:44.0];
    button.tag = tag;
    button.adjustsImageWhenHighlighted = YES;
    button.showsMenuAsPrimaryAction = NO;
    button.clipsToBounds = NO;
    button.translatesAutoresizingMaskIntoConstraints = YES;
    [container addSubview:button];
    if (SYSTEM_VERSION_LESS_THAN(@"26.0")) {
        SPKLog(@"ActionButton", @"Created action button tag=%ld class=%@ container=%@ iOS=%@",
               (long)tag,
               NSStringFromClass(button.class),
               NSStringFromClass(container.class),
               [UIDevice currentDevice].systemVersion);
    }
    return button;
}

void SPKApplyButtonStyle(UIButton *button, SPKActionButtonSource source) {
    if (!button)
        return;

    button.tintColor = SPKActionButtonTintForSource(source);
    button.backgroundColor = UIColor.clearColor;
    button.layer.cornerRadius = 0.0;
    button.layer.shadowColor = UIColor.clearColor.CGColor;
    button.layer.shadowOpacity = 0.0;
    button.layer.shadowRadius = 0.0;
    button.layer.shadowOffset = CGSizeZero;
    button.clipsToBounds = NO;

    BOOL isChrome = [button isKindOfClass:[SPKChromeButton class]];
    if (isChrome) {
        SPKChromeButton *chromeButton = (SPKChromeButton *)button;
        chromeButton.iconTint = SPKActionButtonTintForSource(source);
        chromeButton.bubbleColor = UIColor.clearColor;

        // Reset iconView shadow by default
        chromeButton.iconView.layer.shadowColor = UIColor.clearColor.CGColor;
        chromeButton.iconView.layer.shadowOpacity = 0.0;
        chromeButton.iconView.layer.shadowRadius = 0.0;
        chromeButton.iconView.layer.shadowOffset = CGSizeZero;
        chromeButton.iconView.layer.masksToBounds = NO;
    }

    if (source == SPKActionButtonSourceReels) {
        if (isChrome) {
            SPKChromeButton *chromeButton = (SPKChromeButton *)button;
            chromeButton.iconView.layer.shadowColor = [UIColor blackColor].CGColor;
            chromeButton.iconView.layer.shadowOpacity = 0.24;
            chromeButton.iconView.layer.shadowRadius = 1.8;
            chromeButton.iconView.layer.shadowOffset = CGSizeMake(0.0, 1.0);
        } else {
            button.layer.cornerRadius = CGRectGetHeight(button.bounds) / 2.0;
            button.layer.shadowColor = [UIColor blackColor].CGColor;
            button.layer.shadowOpacity = 0.24;
            button.layer.shadowRadius = 1.8;
            button.layer.shadowOffset = CGSizeMake(0.0, 1.0);
        }
    } else if (source == SPKActionButtonSourceStories || source == SPKActionButtonSourceDirect) {
        // Instants is deliberately absent: its viewer draws on a fully black background, so
        // a drop shadow separates the glyph from nothing and only muddies it. The reset at
        // the top of this function is the Instants style.
        if (isChrome) {
            SPKChromeButton *chromeButton = (SPKChromeButton *)button;
            chromeButton.iconView.layer.shadowColor = [UIColor blackColor].CGColor;
            chromeButton.iconView.layer.shadowOpacity = 0.5;
            chromeButton.iconView.layer.shadowRadius = 2.0;
            chromeButton.iconView.layer.shadowOffset = CGSizeMake(0.0, 2.0);
        } else {
            button.layer.cornerRadius = 8.0;
            button.layer.shadowColor = [UIColor blackColor].CGColor;
            button.layer.shadowOpacity = 0.5;
            button.layer.shadowRadius = 2.0;
            button.layer.shadowOffset = CGSizeMake(0.0, 2.0);
        }
    }
}

BOOL SPKIsDirectVisualViewerAncestor(UIView *view) {
    static Class directViewerClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        directViewerClass = NSClassFromString(@"IGDirectVisualMessageViewerController");
    });
    if (!directViewerClass)
        return NO;
    UIViewController *ancestorController = SPKViewControllerForAncestorView(view);
    return [ancestorController isKindOfClass:directViewerClass];
}

SPKActionButtonContext *SPKActionButtonContextFromButton(UIButton *button) {
    id context = objc_getAssociatedObject(button, kSPKActionButtonContextAssocKey);
    return [context isKindOfClass:[SPKActionButtonContext class]] ? context : nil;
}

// Builds the "Bulk" section (Download All / Copy All / Select Media) for a
// carousel, titled "<sectionTitle> • N" with N the carousel item count.
// `sectionTitle`/`sectionIconName`/`collapsible` come from the user-orderable
// Bulk section so it behaves like any other section. Resolved lazily from a
// UIDeferredMenuElement so it reflects the fully-loaded carousel at the moment
// the menu opens, not whatever was available when the button was first
// configured (which is stale on the first story of a reel, etc.). Returns an
// empty array when there is no bulk media.
static NSArray<UIMenuElement *> *SPKBuildBulkMenuChildren(SPKActionButtonConfiguration *configuration,
                                                          SPKActionButtonContext *context,
                                                          NSString *sectionTitle,
                                                          NSString *sectionIconName,
                                                          BOOL collapsible) {
    id bulkMedia = SPKResolveBulkMediaForContext(context);
    NSArray<SPKResolvedMediaEntry *> *bulkEntries = SPKDownloadableEntries(SPKEntriesFromMedia(bulkMedia));
    if (bulkEntries.count <= 1)
        return @[];

    NSString *bulkUsername = SPKResolvedBulkUsernameForContext(context, bulkEntries, bulkMedia);
    NSArray<NSString *> *configuredBulkDownloadIdentifiers = SPKActionButtonConfiguredBulkDownloadActionsForSource(context.source);
    NSArray<NSString *> *configuredBulkCopyIdentifiers = SPKActionButtonConfiguredBulkCopyActionsForSource(context.source);

    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    // Each bulk entry sits in its own inline group so they read as separate rows
    // divided by separator lines. Download All / Copy All carry the download / copy
    // icons (not the generic "more" icon).
    UIMenuElement *downloadAll = SPKBulkActionMenuElementForContext(context, bulkEntries, bulkUsername, bulkMedia, configuredBulkDownloadIdentifiers, SPKActionButtonTitleForIdentifier(kSPKActionDownloadAll), kSPKActionDownloadAllLibrary);
    if (downloadAll)
        [children addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ downloadAll ]]];
    UIMenuElement *copyAll = SPKBulkActionMenuElementForContext(context, bulkEntries, bulkUsername, bulkMedia, configuredBulkCopyIdentifiers, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_COPY_TEXT"), kSPKActionDownloadAllClipboard);
    if (copyAll)
        [children addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ copyAll ]]];

    // "Select Media" picker — destinations are the configured bulk actions, in a
    // fixed order: Save to Photos, Share, Copy, Save to Gallery, Copy URLs.
    id media = SPKResolveMediaForContext(context);
    NSArray<SPKResolvedMediaEntry *> *entries = SPKEntriesFromMedia(media);
    NSInteger currentIndex = SPKResolveCurrentIndexForContext(context);
    NSArray<NSString *> *configuredBulkIdentifiers = SPKConfiguredBulkActionIdentifiersForSource(context.source);
    NSArray<NSString *> *selectMediaOrder = @[
        kSPKActionDownloadAllLibrary,
        kSPKActionDownloadAllShare,
        kSPKActionDownloadAllClipboard,
        kSPKActionDownloadAllGallery,
        kSPKActionDownloadAllLinks
    ];
    NSMutableArray<SPKBulkSelectionDestination *> *destinations = [NSMutableArray array];
    for (NSString *identifier in selectMediaOrder) {
        if (![configuredBulkIdentifiers containsObject:identifier])
            continue;
        if (SPKIsActionVisible(context, configuration, identifier, media, entries, currentIndex)) {
            [destinations addObject:[SPKBulkSelectionDestination destinationWithIdentifier:identifier
                                                                                     title:SPKActionButtonTitleForIdentifier(identifier)
                                                                                  iconName:SPKActionDescriptorIconName(identifier)]];
        }
    }
    if (destinations.count > 0) {
        UIAction *selectMediaAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_SELECT_MEDIA")
                                                          image:[SPKAssetUtils menuIconNamed:@"circle_check"]
                                                     identifier:nil
                                                        handler:^(__unused UIAction *action) {
                                                            // Re-resolve at tap time as well, in case the carousel changed.
                                                            id tapBulkMedia = SPKResolveBulkMediaForContext(context);
                                                            NSArray<SPKResolvedMediaEntry *> *tapBulkEntries = SPKDownloadableEntries(SPKEntriesFromMedia(tapBulkMedia));
                                                            if (tapBulkEntries.count == 0)
                                                                return;
                                                            NSString *tapBulkUsername = SPKResolvedBulkUsernameForContext(context, tapBulkEntries, tapBulkMedia);
                                                            NSMutableArray<SPKBulkSelectionItem *> *selectionItems = [NSMutableArray array];
                                                            for (SPKResolvedMediaEntry *entry in tapBulkEntries) {
                                                                [selectionItems addObject:[SPKBulkSelectionItem itemWithThumbnailURL:entry.photoURL ?: entry.videoURL
                                                                                                                             isVideo:(entry.videoURL != nil)]];
                                                            }
                                                            [SPKBulkMediaSelectionViewController presentFromViewController:SPKActionContextPresenter(context)
                                                                                                                     items:selectionItems
                                                                                                              destinations:destinations
                                                                                                                completion:^(NSIndexSet *selectedIndexes, NSString *destinationIdentifier) {
                                                                                                                    NSArray<SPKResolvedMediaEntry *> *selectedEntries = [tapBulkEntries objectsAtIndexes:selectedIndexes];
                                                                                                                    if (selectedEntries.count == 0)
                                                                                                                        return;
                                                                                                                    SPKDownloadDestination dest = [destinationIdentifier isEqualToString:kSPKActionDownloadAllGallery] ? SPKDownloadDestinationGallery : SPKDownloadDestinationPhotos;
                                                                                                                    UIViewController *presenter = SPKActionContextPresenter(context);
                                                                                                                    UIView *anchorView = SPKActionContextAnchorView(context);
                                                                                                                    SPKDownloadSourceSurface surface = [SPKDownloadHelpers sourceSurfaceForActionButtonSource:context.source];
                                                                                                                    SPKPerformBatchDownloadWithQualityPrompt(selectedEntries, context.source, tapBulkUsername, tapBulkMedia, dest, destinationIdentifier, presenter, anchorView, surface);
                                                                                                                }];
                                                        }];
        [children addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ selectMediaAction ]]];
    }

    if (children.count == 0)
        return @[];
    // Present the bulk actions as their own section, styled like the other
    // collapsible sections. Title carries the carousel item count.
    NSString *baseTitle = sectionTitle.length > 0 ? sectionTitle : SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CONFIGURATION_BULK_TEXT");
    NSString *title = [NSString stringWithFormat:@"%@ • %lu", baseTitle, (unsigned long)bulkEntries.count];
    UIImage *bulkIcon = [[[SPKAssetUtils menuIconNamed:(sectionIconName.length > 0 ? sectionIconName : @"carousel")] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] imageWithTintColor:[UIColor labelColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIMenuElement *section = collapsible
                                 ? SPKSubmenuOrSingleElement(title, bulkIcon, children)
                                 : [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:children];
    return section ? @[ section ] : @[];
}

// The posted date shown at the top of the menu, or an empty string.
static NSString *SPKActionMenuDateTitle(SPKActionButtonContext *context) {
    // Profile pictures have no posted date — the media object is an IGUser. Skip the
    // lookup rather than walking a large user object to conclude nothing every time.
    if (![SPKUtils getBoolPref:@"general_action_btn_show_date"] || context.source == SPKActionButtonSourceProfile)
        return @"";
    id media = SPKResolveMediaForContext(context);
    NSDate *postedDate = [SPKUtils postedDateFromMediaObject:media];
    if (!postedDate) {
        SPKLog(@"ActionButton", @"menu title has no date: source=%ld media=%@", (long)context.source,
               media ? NSStringFromClass([media class]) : @"(nil)");
        return @"";
    }
    return [SPKUtils spk_formattedDateHeader:postedDate] ?: @"";
}

// Builds the ordered section menu elements from a FRESH resolve of the current
// media / carousel slide. Extracted so the feed menu can re-run it lazily at
// open time (via a UIDeferredMenuElement) — this is what makes a mixed carousel
// track the CURRENT slide: video-only actions (Trim, View Thumbnail, audio)
// reflect the visible item instead of whatever slide 0 was when the button was
// first configured. Instants does the same for the snap on screen. Other
// surfaces call it once (their menus are built eagerly, as before).
static NSArray<UIMenuElement *> *SPKBuildActionMenuElements(SPKActionButtonContext *context,
                                                            SPKActionButtonConfiguration *configuration,
                                                            __weak UIButton *weakButton) {
    id media = SPKResolveMediaForContext(context);
    NSArray<SPKResolvedMediaEntry *> *entries = SPKEntriesFromMedia(media);
    NSInteger currentIndex = SPKResolveCurrentIndexForContext(context);
    SPKResolvedMediaEntry *currentEntry = nil;
    if (entries.count > 0) {
        currentEntry = entries[SPKClampedIndex(currentIndex, (NSInteger)entries.count)];
    }
    NSArray<NSString *> *visibleActions = SPKVisibleActionsForContext(context, media, entries, currentIndex);

    NSMutableArray<UIMenuElement *> *menuElements = [NSMutableArray array];
    NSArray<SPKActionMenuSection *> *visibleSectionsList = [configuration visibleSections];
    NSMutableDictionary<NSString *, SPKActionMenuSection *> *visibleSectionsByID = [NSMutableDictionary dictionary];
    for (SPKActionMenuSection *visibleSection in visibleSectionsList) {
        if (visibleSection.identifier)
            visibleSectionsByID[visibleSection.identifier] = visibleSection;
    }
    BOOL firstGroup = YES;
    for (SPKActionMenuSection *orderedSection in configuration.sections) {
        if ([orderedSection.identifier isEqualToString:@"bulk"]) {
            NSString *bulkTitle = orderedSection.title;
            NSString *bulkIconName = orderedSection.iconName;
            BOOL bulkCollapsible = orderedSection.collapsible;
            UIDeferredMenuElement *bulkDeferred = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
                completion(SPKBuildBulkMenuChildren(configuration, context, bulkTitle, bulkIconName, bulkCollapsible));
            }];
            if (!firstGroup) {
                [menuElements addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[]]];
            }
            [menuElements addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ bulkDeferred ]]];
            firstGroup = NO;
            continue;
        }
        SPKActionMenuSection *group = visibleSectionsByID[orderedSection.identifier];
        if (!group)
            continue;
        NSString *title = group.title;
        NSArray<NSString *> *identifiers = group.actions;
        if (![identifiers isKindOfClass:[NSArray class]] || identifiers.count == 0)
            continue;

        NSMutableArray<UIMenuElement *> *groupElements = [NSMutableArray array];
        UIMenuElement *profileCopyInfoElement = nil; // divided from the rest of Copy by a separator line
        for (NSString *identifier in identifiers) {
            if (![visibleActions containsObject:identifier])
                continue;

            if (context.source == SPKActionButtonSourceProfile && [identifier isEqualToString:kSPKActionProfileCopyInfo]) {
                NSMutableArray<UIMenuElement *> *copyChildren = [NSMutableArray array];
                for (NSString *copyIdentifier in SPKProfileConfiguredCopyInfoActions()) {
                    [copyChildren addObject:[UIAction actionWithTitle:SPKActionButtonTitleForIdentifier(copyIdentifier)
                                                                image:SPKActionButtonMenuIconForContext(copyIdentifier, context, 22.0)
                                                           identifier:nil
                                                              handler:^(__unused UIAction *action) {
                                                                  UIButton *strongButton = weakButton;
                                                                  if (strongButton) {
                                                                      objc_setAssociatedObject(strongButton, kSPKActionButtonLastMenuActionAssocKey, copyIdentifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
                                                                  }
                                                                  SPKExecuteActionIdentifier(copyIdentifier, context, NO);
                                                              }]];
                }
                profileCopyInfoElement = SPKSubmenuOrSingleElement(SPKActionButtonDisplayTitleForContext(identifier, context, currentEntry),
                                                                   SPKActionButtonMenuIconForContext(identifier, context, 22.0),
                                                                   copyChildren);
            } else {
                UIAction *menuAction = [UIAction actionWithTitle:SPKActionButtonDisplayTitleForContext(identifier, context, currentEntry)
                                                           image:SPKActionButtonMenuIconForContext(identifier, context, 22.0)
                                                      identifier:nil
                                                         handler:^(__unused UIAction *action) {
                                                             UIButton *strongButton = weakButton;
                                                             if (strongButton) {
                                                                 objc_setAssociatedObject(strongButton, kSPKActionButtonLastMenuActionAssocKey, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
                                                             }
                                                             SPKExecuteActionIdentifier(identifier, context, NO);
                                                         }];
                [groupElements addObject:menuAction];
            }
        }

        // On profile, divide the "Copy Info" submenu from the rest of the Copy
        // section with a separator line (two inline groups).
        if (profileCopyInfoElement) {
            if (groupElements.count > 0) {
                UIMenu *restGroup = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:[groupElements copy]];
                UIMenu *infoGroup = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ profileCopyInfoElement ]];
                [groupElements removeAllObjects];
                [groupElements addObject:restGroup];
                [groupElements addObject:infoGroup];
            } else {
                [groupElements addObject:profileCopyInfoElement];
            }
        }

        if (groupElements.count == 0)
            continue;
        if (!firstGroup) {
            [menuElements addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[]]];
        }
        if (group.collapsible && groupElements.count > 1) {
            UIImage *sectionImage = nil;
            if (group.iconName.length > 0) {
                sectionImage = [[[SPKAssetUtils menuIconNamed:group.iconName] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] imageWithTintColor:[UIColor labelColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
            }
            UIMenu *submenu = [UIMenu menuWithTitle:title ?: @""
                                              image:sectionImage
                                         identifier:nil
                                            options:0
                                           children:groupElements];
            [menuElements addObject:[UIMenu menuWithTitle:@""
                                                    image:nil
                                               identifier:nil
                                                  options:UIMenuOptionsDisplayInline
                                                 children:@[ submenu ]]];
        } else {
            [menuElements addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:groupElements]];
        }
        firstGroup = NO;
    }

    if (context.source == SPKActionButtonSourceProfile) {
        UIDeferredMenuElement *deferred = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
            id freshMedia = SPKResolveMediaForContext(context);
            completion(SPKProfileInfoMenuElements(freshMedia));
        }];
        [menuElements addObject:[UIMenu menuWithTitle:@""
                                                image:nil
                                           identifier:nil
                                              options:UIMenuOptionsDisplayInline
                                             children:@[ deferred ]]];
    }

    if (menuElements.count == 0) {
        for (NSString *identifier in visibleActions) {
            [menuElements addObject:[UIAction actionWithTitle:SPKActionButtonDisplayTitleForContext(identifier, context, currentEntry)
                                                        image:SPKActionButtonMenuIconForContext(identifier, context, 22.0)
                                                   identifier:nil
                                                      handler:^(__unused UIAction *action) {
                                                          UIButton *strongButton = weakButton;
                                                          if (strongButton) {
                                                              objc_setAssociatedObject(strongButton, kSPKActionButtonLastMenuActionAssocKey, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
                                                          }
                                                          SPKExecuteActionIdentifier(identifier, context, NO);
                                                      }]];
        }
    }

    return menuElements;
}

void SPKConfigureActionButton(UIButton *button, SPKActionButtonContext *context) {
    if (!button || !context)
        return;
    BOOL legacyDiagnostics = SPKActionButtonLegacyDiagnosticsEnabled(context.source);
    if (legacyDiagnostics) {
        SPKLog(@"ActionButton", @"Configuring feed action button class=%@ view=%@ iOS=%@",
               NSStringFromClass(button.class),
               NSStringFromClass(context.view.class),
               [UIDevice currentDevice].systemVersion);
    }

    if (!objc_getAssociatedObject(button, kSPKActionButtonConfigurationObserverAssocKey)) {
        __weak UIButton *weakObservedButton = button;
        id token = [[NSNotificationCenter defaultCenter] addObserverForName:SPKActionButtonConfigurationDidChangeNotification
                                                                     object:nil
                                                                      queue:nil
                                                                 usingBlock:^(__unused NSNotification *note) {
                                                                     dispatch_async(dispatch_get_main_queue(), ^{
                                                                         UIButton *strongButton = weakObservedButton;
                                                                         SPKActionButtonContext *storedContext = SPKActionButtonContextFromButton(strongButton);
                                                                         if (!strongButton || !storedContext)
                                                                             return;
                                                                         objc_setAssociatedObject(strongButton, kSPKActionButtonMenuSignatureAssocKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
                                                                         SPKConfigureActionButton(strongButton, storedContext);
                                                                     });
                                                                 }];
        objc_setAssociatedObject(button, kSPKActionButtonConfigurationObserverAssocKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    id media = SPKResolveMediaForContext(context);
    NSArray<SPKResolvedMediaEntry *> *entries = SPKEntriesFromMedia(media);
    NSInteger currentIndex = SPKResolveCurrentIndexForContext(context);
    NSArray<NSString *> *visibleActions = SPKVisibleActionsForContext(context, media, entries, currentIndex);
    if (legacyDiagnostics) {
        SPKLog(@"ActionButton", @"Feed action button resolved visibleActions=%lu entries=%lu currentIndex=%ld",
               (unsigned long)visibleActions.count,
               (unsigned long)entries.count,
               (long)currentIndex);
    }

    if (visibleActions.count == 0) {
        button.hidden = YES;
        button.menu = nil;
        if (legacyDiagnostics) {
            SPKLog(@"ActionButton", @"Feed action button hidden: no visible actions");
        }
        return;
    }

    button.hidden = NO;

    NSString *defaultIdentifier = SPKResolvedDefaultActionIdentifier(visibleActions, context.source);
    UIImage *defaultImage = SPKButtonDefaultImage(defaultIdentifier, context.source, context);
    SPKSetButtonVisualImage(button, defaultImage, context.source, defaultIdentifier);
    BOOL shouldOpenMenuOnTap = [defaultIdentifier isEqualToString:kSPKActionNone];
    SPKActionButtonConfiguration *configuration = [SPKActionButtonConfiguration configurationForSource:context.source
                                                                                            topicTitle:context.settingsTitle ?: SPKActionButtonTopicTitleForSource(context.source)
                                                                                      supportedActions:context.supportedActions ?: SPKActionButtonSupportedActionsForSource(context.source)
                                                                                       defaultSections:SPKActionButtonDefaultSectionsForSource(context.source)];
    // Instants builds its menu contents when it opens (below), so the bulk count is read there
    // instead. Resolving every snap's URLs here ran inside the header's layout pass.
    BOOL defersMenu = context.source == SPKActionButtonSourceFeed || context.source == SPKActionButtonSourceInstants;
    NSUInteger bulkEntryCount = 0;
    if (context.source != SPKActionButtonSourceInstants) {
        id bulkMedia = SPKResolveBulkMediaForContext(context);
        bulkEntryCount = SPKDownloadableEntries(SPKEntriesFromMedia(bulkMedia)).count;
    }
    NSString *menuSignature = SPKActionButtonMenuSignature(context, configuration, visibleActions, defaultIdentifier, bulkEntryCount);
    NSString *existingSignature = objc_getAssociatedObject(button, kSPKActionButtonMenuSignatureAssocKey);
    if ([existingSignature isEqualToString:menuSignature] && button.menu != nil) {
        button.showsMenuAsPrimaryAction = shouldOpenMenuOnTap;
        objc_setAssociatedObject(button, kSPKActionButtonContextAssocKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (legacyDiagnostics) {
            SPKLog(@"ActionButton", @"Feed action button reused menu default=%@ opensMenu=%@",
                   defaultIdentifier ?: @"(nil)",
                   shouldOpenMenuOnTap ? @"YES" : @"NO");
        }
        return;
    }

    __weak UIButton *weakButton = button;
    // No bespoke touch-down haptic: the resolved action emits its own completion haptic
    // (via SPKNotify, which already respects general_disable_haptics), and the menu-open
    // (None) path uses the system context-menu haptic. A selection haptic on touch-down
    // stacked a second, wrong-feeling tick on top of those. Clear any stale one left on a
    // reused button by an earlier configure pass.
    UIAction *oldHapticAction = objc_getAssociatedObject(button, kSPKActionButtonHapticActionAssocKey);
    if (oldHapticAction) {
        [button removeAction:oldHapticAction forControlEvents:UIControlEventTouchDown];
        objc_setAssociatedObject(button, kSPKActionButtonHapticActionAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIAction *oldTapAction = objc_getAssociatedObject(button, kSPKActionButtonTapActionAssocKey);
    if (oldTapAction)
        [button removeAction:oldTapAction forControlEvents:UIControlEventTouchUpInside];

    if (shouldOpenMenuOnTap) {
        objc_setAssociatedObject(button, kSPKActionButtonTapActionAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        UIAction *newTapAction = [UIAction actionWithHandler:^(__unused UIAction *action) {
            UIButton *strongButton = weakButton;
            SPKActionButtonContext *strongContext = SPKActionButtonContextFromButton(strongButton);
            if (!strongContext)
                return;

            id tapMedia = SPKResolveMediaForContext(strongContext);
            NSArray<SPKResolvedMediaEntry *> *tapEntries = SPKEntriesFromMedia(tapMedia);
            NSArray<NSString *> *tapVisibleActions = SPKVisibleActionsForContext(strongContext, tapMedia, tapEntries, SPKResolveCurrentIndexForContext(strongContext));
            NSString *tapIdentifier = SPKResolvedDefaultActionIdentifier(tapVisibleActions, strongContext.source);
            SPKExecuteActionIdentifier(tapIdentifier, strongContext, YES);
        }];
        [button addAction:newTapAction forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(button, kSPKActionButtonTapActionAssocKey, newTapAction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Feed items have in-line, laterally-swipeable mixed carousels whose current slide
    // changes WITHOUT the bar re-laying-out, and the Instants button keeps one menu for
    // the whole viewer session while the snap under it changes. Both resolve their menu
    // lazily at open time, so video-only actions track what is on screen and the bulk
    // resolve stays off the layout path. Other surfaces build eagerly.
    UIMenu *fullMenu;
    // The Instants menu outlives the snap it was built for; SPKActionMenuButton re-dates
    // it each time it opens.
    NSString *menuTitle = SPKActionMenuDateTitle(context);

    if (defersMenu) {
        UIDeferredMenuElement *deferred = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
            completion(SPKBuildActionMenuElements(context, configuration, weakButton));
        }];
        fullMenu = [UIMenu menuWithTitle:menuTitle children:@[ deferred ]];
    } else {
        fullMenu = [UIMenu menuWithTitle:menuTitle children:SPKBuildActionMenuElements(context, configuration, weakButton)];
    }
    button.menu = fullMenu;
    button.showsMenuAsPrimaryAction = shouldOpenMenuOnTap;
    objc_setAssociatedObject(button, kSPKActionButtonContextAssocKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, kSPKActionButtonMenuSignatureAssocKey, menuSignature, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (legacyDiagnostics) {
        SPKLog(@"ActionButton", @"Feed action button menu complete default=%@ opensMenu=%@",
               defaultIdentifier ?: @"(nil)",
               shouldOpenMenuOnTap ? @"YES" : @"NO");
    }
}
