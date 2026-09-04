#import "SPKStrings.h"
#import "SPKNotificationCenter.h"
#import "../../AssetUtils.h"
#import "../../Settings/SPKPreferences.h"
#import "../../Utils.h"
#import "../AutoSave/SPKAutoSaveFilter.h"
#import "../Instants/SPKInstantsAutoSave.h"
#import "../Messages/SPKDirectAutoSave.h"
#import "../Messages/SPKDirectHiddenChats.h"
#import "../Messages/SPKDirectSeenContext.h"
#import "../Messages/SPKPresenceTracking.h"
#import "../Stories/SPKStoryAutoSave.h"
#import "../Stories/SPKStoryContext.h"

// Every filter list-change notification offers the same "tap to open the list"
// affordance, so they live in one table rather than a branch per surface. Returns nil
// when there's nothing to offer -- unknown identifier, or the user is already looking
// at a filter list.
static UIViewController *SPKAutoSaveListViewControllerForRuleIdentifier(NSString *identifier) {
    if (identifier.length == 0 || SPKAutoSaveFilterListUIVisible())
        return nil;
    if ([identifier isEqualToString:kSPKNotificationStoryAutoSaveUserRule])
        return SPKStoryAutoSaveListViewController();
    if ([identifier isEqualToString:kSPKNotificationDirectAutoSaveThreadRule])
        return SPKDirectAutoSaveListViewController();
    if ([identifier isEqualToString:kSPKNotificationInstantsAutoSaveUserRule])
        return SPKInstantsAutoSaveListViewController();
    if ([identifier isEqualToString:kSPKNotificationPresenceUserRule])
        return SPKPresenceListViewController();
    return nil;
}

#define SPK_NOTIF_CONST(name, value) NSString *const name = @value
SPK_NOTIF_CONST(kSPKNotificationDownloadLibrary, "download_library");
SPK_NOTIF_CONST(kSPKNotificationDownloadShare, "download_share");
SPK_NOTIF_CONST(kSPKNotificationCopyDownloadLink, "copy_download_link");
SPK_NOTIF_CONST(kSPKNotificationCopyMedia, "copy_media");
SPK_NOTIF_CONST(kSPKNotificationDownloadGallery, "download_gallery");
SPK_NOTIF_CONST(kSPKNotificationDownloadAllLibrary, "download_all_library");
SPK_NOTIF_CONST(kSPKNotificationDownloadAllShare, "download_all_share");
SPK_NOTIF_CONST(kSPKNotificationDownloadAllGallery, "download_all_gallery");
SPK_NOTIF_CONST(kSPKNotificationDownloadAllClipboard, "download_all_clipboard");
SPK_NOTIF_CONST(kSPKNotificationDownloadAllLinks, "download_all_links");
SPK_NOTIF_CONST(kSPKNotificationDownloadQueueFinished, "download_queue_finished");
SPK_NOTIF_CONST(kSPKNotificationQueuedDownloadFailed, "queued_download_failed");
SPK_NOTIF_CONST(kSPKNotificationExpand, "expand");
SPK_NOTIF_CONST(kSPKNotificationViewThumbnail, "view_thumbnail");
SPK_NOTIF_CONST(kSPKNotificationCopyCaption, "copy_caption");
SPK_NOTIF_CONST(kSPKNotificationOpenTopicSettings, "open_topic_settings");
SPK_NOTIF_CONST(kSPKNotificationRepost, "repost");

SPK_NOTIF_CONST(kSPKNotificationDownloadAudio, "download_audio");
SPK_NOTIF_CONST(kSPKNotificationDownloadAudioShare, "download_audio_share");
SPK_NOTIF_CONST(kSPKNotificationDownloadAudioGallery, "download_audio_gallery");
SPK_NOTIF_CONST(kSPKNotificationPlayAudio, "play_audio");
SPK_NOTIF_CONST(kSPKNotificationCopyAudioURL, "copy_audio_url");

SPK_NOTIF_CONST(kSPKNotificationStoryMarkSeen, "story_mark_seen");
SPK_NOTIF_CONST(kSPKNotificationStorySeenUserRule, "toggle_story_seen_user_rule");
SPK_NOTIF_CONST(kSPKNotificationStoryMentionsSheet, "story_mentions_sheet");
SPK_NOTIF_CONST(kSPKNotificationStoryAutoSave, "story_auto_save");
SPK_NOTIF_CONST(kSPKNotificationStoryAutoSaveUserRule, "toggle_story_auto_save_user_rule");
SPK_NOTIF_CONST(kSPKNotificationAutoSaveSummary, "auto_save_summary");
SPK_NOTIF_CONST(kSPKNotificationAutoSavePending, "auto_save_pending");
SPK_NOTIF_CONST(kSPKNotificationDirectVisualMarkSeen, "direct_visual_mark_seen");
SPK_NOTIF_CONST(kSPKNotificationThreadMessagesMarkSeen, "thread_messages_mark_seen");
SPK_NOTIF_CONST(kSPKNotificationDirectThreadSeenRule, "direct_thread_seen_rule");
SPK_NOTIF_CONST(kSPKNotificationDirectHiddenChat, "direct_hidden_chat");
SPK_NOTIF_CONST(kSPKNotificationDirectAutoSave, "direct_auto_save");
SPK_NOTIF_CONST(kSPKNotificationDirectAutoSaveThreadRule, "toggle_direct_auto_save_thread_rule");
SPK_NOTIF_CONST(kSPKNotificationUnsentMessage, "unsent_message");
SPK_NOTIF_CONST(kSPKNotificationPresenceOnline, "presence_online");
SPK_NOTIF_CONST(kSPKNotificationPresenceOffline, "presence_offline");
SPK_NOTIF_CONST(kSPKNotificationPresenceTyping, "presence_typing");
SPK_NOTIF_CONST(kSPKNotificationPresenceRead, "presence_read");
SPK_NOTIF_CONST(kSPKNotificationPresenceUserRule, "presence_user_rule");
SPK_NOTIF_CONST(kSPKNotificationUnsentReaction, "unsent_reaction");
SPK_NOTIF_CONST(kSPKNotificationInstantsCaptureBlocked, "instants_capture_blocked");
SPK_NOTIF_CONST(kSPKNotificationInstantsUpload, "instants_upload");
SPK_NOTIF_CONST(kSPKNotificationInstantsAutoSave, "instants_auto_save");
SPK_NOTIF_CONST(kSPKNotificationInstantsAutoSaveUserRule, "toggle_instants_auto_save_user_rule");

SPK_NOTIF_CONST(kSPKNotificationProfileCopyInfo, "profile_copy_info");
SPK_NOTIF_CONST(kSPKNotificationProfileAnalyzerComplete, "profile_analyzer_complete");
SPK_NOTIF_CONST(kSPKNotificationProfileStorySeenUserRule, "toggle_profile_story_seen_user_rule");
SPK_NOTIF_CONST(kSPKNotificationProfileMessagesSeenUserRule, "toggle_profile_messages_seen_user_rule");

SPK_NOTIF_CONST(kSPKNotificationMediaPreviewSavePhotos, "media_preview_save_photos");
SPK_NOTIF_CONST(kSPKNotificationMediaPreviewSaveGallery, "media_preview_save_gallery");
SPK_NOTIF_CONST(kSPKNotificationMediaPreviewShare, "media_preview_share");
SPK_NOTIF_CONST(kSPKNotificationMediaPreviewCopy, "media_preview_copy");
SPK_NOTIF_CONST(kSPKNotificationMediaPreviewDeleteGallery, "media_preview_delete_gallery");
SPK_NOTIF_CONST(kSPKNotificationMediaPreviewOpenGallery, "media_preview_open_gallery");

SPK_NOTIF_CONST(kSPKNotificationGalleryOpenOriginal, "gallery_open_original");
SPK_NOTIF_CONST(kSPKNotificationGalleryOpenProfile, "gallery_open_profile");
SPK_NOTIF_CONST(kSPKNotificationGalleryDeleteFile, "gallery_delete_file");
SPK_NOTIF_CONST(kSPKNotificationGalleryDeleteSelected, "gallery_delete_selected");
SPK_NOTIF_CONST(kSPKNotificationGalleryBulkDelete, "gallery_bulk_delete");
SPK_NOTIF_CONST(kSPKNotificationGalleryImport, "gallery_import");

SPK_NOTIF_CONST(kSPKNotificationSettingsExport, "settings_export");
SPK_NOTIF_CONST(kSPKNotificationSettingsImport, "settings_import");
SPK_NOTIF_CONST(kSPKNotificationSettingsClearCache, "settings_clear_cache");
SPK_NOTIF_CONST(kSPKNotificationCopyDescription, "copy_description");
SPK_NOTIF_CONST(kSPKNotificationCopyNoteText, "copy_note_text");
SPK_NOTIF_CONST(kSPKNotificationShareLongPressCopyLink, "share_long_press_copy_link");
SPK_NOTIF_CONST(kSPKNotificationCopyComment, "copy_comment");
SPK_NOTIF_CONST(kSPKNotificationCopyGIFLink, "copy_gif_link");
SPK_NOTIF_CONST(kSPKNotificationCopyGIFTitle, "copy_gif_title");
SPK_NOTIF_CONST(kSPKNotificationMediaEncodingLogs, "media_encoding_logs");
SPK_NOTIF_CONST(kSPKNotificationFlexUnavailable, "flex_unavailable");
#undef SPK_NOTIF_CONST

NSString *const kSPKNotificationPillDurationKey = @"notifs_pill_duration";
NSString *const kSPKNotificationPillGlowEnabledKey = @"notifs_pill_glow";
NSString *const kSPKNotificationPillLiquidGlassEnabledKey = @"notifs_pill_liquid_glass";
NSString *const kSPKNotificationProgressSubtitleStyleKey = @"notifs_progress_subtitle_style";
NSString *const kSPKNotificationPillPositionKey = @"notifs_pill_position";

static CGFloat const kSPKNotificationStackSpacing = 8.0;
static CGFloat const kSPKNotificationTopMargin = 8.0;
// Bottom pills clear the safe-area bottom, but IG stacks a tab bar / composer /
// toolbar above it that the safe area doesn't cover. Lift bottom pills further so
// they float clear of that chrome instead of overlapping it.
static CGFloat const kSPKNotificationBottomMargin = 60.0;
static NSTimeInterval const kSPKNotificationInsertDuration = 0.55;
static NSTimeInterval const kSPKNotificationDefaultPillDuration = 1.5;
static NSTimeInterval const kSPKNotificationMinPillDuration = 0.5;
static NSTimeInterval const kSPKNotificationMaxPillDuration = 5.0;
static NSUInteger const kSPKNotificationMaxQueuedToasts = 3;

@interface SPKNotificationSlot : NSObject
@property (nonatomic, strong) SPKNotificationPillView *pill;
@property (nonatomic, strong) NSLayoutConstraint *topConstraint;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, assign) BOOL progress;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation SPKNotificationSlot
@end

@interface SPKNotificationOverlayRootViewController : UIViewController
@end

@implementation SPKNotificationOverlayRootViewController
- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    view.backgroundColor = UIColor.clearColor;
    self.view = view;
}
@end

@interface SPKNotificationPassthroughWindow : UIWindow
@end

@implementation SPKNotificationPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view)
        return nil;
    return hit;
}
// Tapping a pill must not make this overlay the key window — otherwise anything
// a pill's tap handler presents (e.g. the deleted-messages log sheet) attaches
// to this window and gets torn down with it when the pill dismisses. Pills still
// receive touches; key status isn't required for that.
- (BOOL)canBecomeKeyWindow {
    return NO;
}
@end

static NSDictionary *SPKNotificationItem(NSString *identifier, NSString *title, NSString *iconName) {
    return @{@"identifier" : identifier ?: @"", @"title" : title ?: @"", @"iconName" : iconName ?: @"info"};
}

NSString *SPKNotificationDefaultsKey(NSString *identifier) {
    return SPKPrefNotificationKey(identifier);
}

NSString *SPKNotificationHapticDefaultsKey(NSString *identifier) {
    return SPKPrefNotificationHapticKey(identifier);
}

NSArray<NSDictionary *> *SPKNotificationPreferenceSections(void) {
    return @[
        @{@"title" : SPKL(@"UI_NOTIFICATION_CENTER_ACTION_BUTTONS_ACTION"),
          @"items" : @[
              SPKNotificationItem(kSPKNotificationDownloadLibrary, SPKL(@"FEED_COMMENT_ACTIONS_SAVE_PHOTOS_TEXT"), @"download"),
              SPKNotificationItem(kSPKNotificationDownloadShare, SPKL(@"ALERT_ACTION_SHARE"), @"share"),
              SPKNotificationItem(kSPKNotificationCopyDownloadLink, SPKL(@"FEED_COMMENT_ACTIONS_COPY_DOWNLOAD_URL_TEXT"), @"link"),
              SPKNotificationItem(kSPKNotificationCopyMedia, SPKL(@"ACTION_BUTTON_COPY_MEDIA_TITLE"), @"copy"),
              SPKNotificationItem(kSPKNotificationDownloadGallery, SPKL(@"FEED_COMMENT_ACTIONS_SAVE_GALLERY_TEXT"), @"sparkle_gallery"),
              SPKNotificationItem(kSPKNotificationDownloadAllLibrary, SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_SAVE_PHOTOS_TEXT"), @"download"),
              SPKNotificationItem(kSPKNotificationDownloadAllShare, SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_SHARE_TEXT"), @"share"),
              SPKNotificationItem(kSPKNotificationDownloadAllGallery, SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_SAVE_GALLERY_TEXT"), @"sparkle_gallery"),
              SPKNotificationItem(kSPKNotificationDownloadAllClipboard, SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_COPY_MEDIA_TEXT"), @"copy"),
              SPKNotificationItem(kSPKNotificationDownloadAllLinks, SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_COPY_DOWNLOAD_URLS_TEXT"), @"link"),
              SPKNotificationItem(kSPKNotificationExpand, SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_EXPAND_TEXT"), @"expand"),
              SPKNotificationItem(kSPKNotificationViewThumbnail, SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_VIEW_THUMBNAIL_TEXT"), @"photo_gallery"),
              SPKNotificationItem(kSPKNotificationCopyCaption, SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_COPY_CAPTION_TEXT"), @"caption"),
              SPKNotificationItem(kSPKNotificationOpenTopicSettings, SPKL(@"UI_NOTIFICATION_CENTER_OPEN_TOPIC_SETTINGS_TEXT"), @"settings"),
              SPKNotificationItem(kSPKNotificationRepost, SPKL(@"ACTION_BUTTON_ACTION_DESCRIPTOR_REPOST_TEXT"), @"repost"),
              SPKNotificationItem(kSPKNotificationDownloadAudio, SPKL(@"ALERT_ACTION_SAVE_AUDIO_FILES"), @"audio_download"),
              SPKNotificationItem(kSPKNotificationDownloadAudioShare, SPKL(@"ALERT_ACTION_SHARE_AUDIO"), @"share"),
              SPKNotificationItem(kSPKNotificationDownloadAudioGallery, SPKL(@"ALERT_ACTION_SAVE_AUDIO_GALLERY"), @"sparkle_gallery"),
              SPKNotificationItem(kSPKNotificationPlayAudio, SPKL(@"ALERT_ACTION_PLAY_AUDIO"), @"play"),
              SPKNotificationItem(kSPKNotificationCopyAudioURL, SPKL(@"ALERT_ACTION_COPY_AUDIO_DOWNLOAD_URL"), @"link"),
          ]},
        // Every auto-save toast lives here rather than under its surface: they're
        // configured together, and the summary/pending pair isn't per-surface at all.
        @{@"title" : SPKL(@"UI_NOTIFICATION_CENTER_AUTO_SAVE_TITLE"),
          @"items" : @[
              SPKNotificationItem(kSPKNotificationStoryAutoSave, SPKL(@"UI_NOTIFICATION_CENTER_STORY_AUTO_SAVE_STARTED_TEXT"), @"story"),
              SPKNotificationItem(kSPKNotificationDirectAutoSave, SPKL(@"UI_NOTIFICATION_CENTER_DM_AUTO_SAVE_STARTED_TEXT"), @"messages"),
              SPKNotificationItem(kSPKNotificationInstantsAutoSave, SPKL(@"UI_NOTIFICATION_CENTER_INSTANTS_AUTO_SAVE_STARTED_TEXT"), @"instants"),
              SPKNotificationItem(kSPKNotificationAutoSavePending, SPKL(@"UI_NOTIFICATION_CENTER_AUTO_SAVE_STILL_WORKING_TEXT"), @"history"),
              SPKNotificationItem(kSPKNotificationAutoSaveSummary, SPKL(@"UI_NOTIFICATION_CENTER_AUTO_SAVE_SUMMARY_TEXT"), @"download"),
              SPKNotificationItem(kSPKNotificationStoryAutoSaveUserRule, SPKL(@"UI_NOTIFICATION_CENTER_STORY_AUTO_SAVE_LIST_CHANGES_TEXT"), @"story"),
              SPKNotificationItem(kSPKNotificationDirectAutoSaveThreadRule, SPKL(@"UI_NOTIFICATION_CENTER_DM_AUTO_SAVE_LIST_CHANGES_TEXT"), @"messages"),
              SPKNotificationItem(kSPKNotificationInstantsAutoSaveUserRule, SPKL(@"UI_NOTIFICATION_CENTER_INSTANTS_AUTO_SAVE_LIST_CHANGES_TEXT"), @"instants"),
          ]},
        @{@"title" : SPKL(@"STORIES_OTHER_STORIES_TITLE"),
          @"items" : @[
              SPKNotificationItem(kSPKNotificationStoryMarkSeen, SPKL(@"UI_NOTIFICATION_CENTER_MARK_STORY_SEEN_TEXT"), @"story"),
              SPKNotificationItem(kSPKNotificationStorySeenUserRule, SPKL(@"UI_NOTIFICATION_CENTER_STORY_SEEN_LIST_CHANGES_TEXT"), @"eye"),
              SPKNotificationItem(kSPKNotificationStoryMentionsSheet, SPKL(@"UI_NOTIFICATION_CENTER_OPEN_STORY_MENTIONS_TEXT"), @"mention"),
          ]},
        @{@"title" : SPKL(@"MESSAGES_CONFIRMATION_MESSAGES_TITLE"),
          @"items" : @[
              SPKNotificationItem(kSPKNotificationDirectVisualMarkSeen, SPKL(@"UI_NOTIFICATION_CENTER_MARK_VISUAL_MESSAGE_SEEN_MESSAGE"), @"view_twice"),
              SPKNotificationItem(kSPKNotificationThreadMessagesMarkSeen, SPKL(@"UI_NOTIFICATION_CENTER_MARK_MESSAGES_SEEN_MESSAGE"), @"messages"),
              SPKNotificationItem(kSPKNotificationDirectThreadSeenRule, SPKL(@"UI_NOTIFICATION_CENTER_CHAT_SEEN_LIST_CHANGES_TEXT"), @"eye"),
              SPKNotificationItem(kSPKNotificationDirectHiddenChat, SPKL(@"UI_NOTIFICATION_CENTER_HIDDEN_CHAT_CHANGES_TEXT"), @"messages_off"),
              SPKNotificationItem(kSPKNotificationUnsentMessage, SPKL(@"UI_NOTIFICATION_CENTER_UNSENT_MESSAGE"), @"undo"),
              SPKNotificationItem(kSPKNotificationUnsentReaction, SPKL(@"UI_NOTIFICATION_CENTER_REMOVED_REACTION_ACTION"), @"reactions"),
              SPKNotificationItem(kSPKNotificationPresenceOnline, SPKL(@"MESSAGES_ACTIVITY_USER_ONLINE_TITLE"), @"circle_check_filled"),
              SPKNotificationItem(kSPKNotificationPresenceOffline, SPKL(@"MESSAGES_ACTIVITY_USER_OFFLINE_TITLE"), @"circle_xmark_filled"),
              SPKNotificationItem(kSPKNotificationPresenceTyping, SPKL(@"MESSAGES_ACTIVITY_USER_TYPING_TITLE"), @"keyboard"),
              SPKNotificationItem(kSPKNotificationPresenceRead, SPKL(@"MESSAGES_ACTIVITY_MESSAGE_READ_TITLE"), @"eye"),
              SPKNotificationItem(kSPKNotificationPresenceUserRule, SPKL(@"MESSAGES_ACTIVITY_LIST_CHANGES_TITLE"), @"activity"),
          ]},
        @{@"title" : SPKL(@"INSTANTS_CONFIRMATION_INSTANTS_TITLE"),
          @"items" : @[
              SPKNotificationItem(kSPKNotificationInstantsCaptureBlocked, SPKL(@"UI_NOTIFICATION_CENTER_INSTANT_CAPTURE_BLOCKED_TEXT"), @"lock"),
              SPKNotificationItem(kSPKNotificationInstantsUpload, SPKL(@"UI_NOTIFICATION_CENTER_INSTANT_UPLOAD_FAILED_TEXT"), @"warning"),
          ]},
        @{@"title" : SPKL(@"PROFILE_TITLE"),
          @"items" : @[
              SPKNotificationItem(kSPKNotificationProfileCopyInfo, SPKL(@"UI_NOTIFICATION_CENTER_COPY_PROFILE_INFO_TEXT"), @"copy"),
              SPKNotificationItem(kSPKNotificationProfileAnalyzerComplete, SPKL(@"UI_NOTIFICATION_CENTER_PROFILE_ANALYZER_COMPLETE_TEXT"), @"profile_analyzer"),
              SPKNotificationItem(kSPKNotificationProfileStorySeenUserRule, SPKL(@"UI_NOTIFICATION_CENTER_STORY_SEEN_LIST_CHANGES_TEXT"), @"eye"),
              SPKNotificationItem(kSPKNotificationProfileMessagesSeenUserRule, SPKL(@"UI_NOTIFICATION_CENTER_CHAT_SEEN_LIST_CHANGES_TEXT"), @"eye"),
          ]},
        @{@"title" : SPKL(@"GENERAL_COMMENTS_HEADER"),
          @"items" : @[
              SPKNotificationItem(kSPKNotificationCopyComment, SPKL(@"GENERAL_COMMENTS_COPY_COMMENT_TITLE"), @"copy"),
              SPKNotificationItem(kSPKNotificationCopyGIFLink, SPKL(@"UI_NOTIFICATION_CENTER_COPY_MEDIA_LINK_TEXT"), @"link"),
              SPKNotificationItem(kSPKNotificationCopyGIFTitle, SPKL(@"UI_NOTIFICATION_CENTER_COPY_GIF_TITLE"), @"gif"),
          ]},
        @{@"title" : SPKL(@"FEED_MEDIA_HEADER"),
          @"items" : @[
              SPKNotificationItem(kSPKNotificationMediaPreviewSavePhotos, SPKL(@"FEED_COMMENT_ACTIONS_SAVE_PHOTOS_TEXT"), @"download"),
              SPKNotificationItem(kSPKNotificationMediaPreviewSaveGallery, SPKL(@"FEED_COMMENT_ACTIONS_SAVE_GALLERY_TEXT"), @"sparkle_gallery"),
              SPKNotificationItem(kSPKNotificationMediaPreviewShare, SPKL(@"ALERT_ACTION_SHARE"), @"share"),
              SPKNotificationItem(kSPKNotificationMediaPreviewCopy, SPKL(@"ACTION_BUTTON_COPY_MEDIA_TITLE"), @"copy"),
              SPKNotificationItem(kSPKNotificationMediaPreviewDeleteGallery, SPKL(@"UI_NOTIFICATION_CENTER_DELETE_MEDIA_TEXT"), @"trash"),
              SPKNotificationItem(kSPKNotificationMediaPreviewOpenGallery, SPKL(@"UI_NOTIFICATION_CENTER_OPEN_MEDIA_TEXT"), @"media"),
              SPKNotificationItem(kSPKNotificationMediaEncodingLogs, SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_ENCODING_LOGS_TEXT"), @"logs"),
          ]},
        @{@"title" : SPKL(@"GALLERY_TITLE"),
          @"items" : @[
              SPKNotificationItem(kSPKNotificationGalleryOpenOriginal, SPKL(@"ALERT_ACTION_OPEN_ORIGINAL_POST"), @"external_link"),
              SPKNotificationItem(kSPKNotificationGalleryOpenProfile, SPKL(@"ALERT_ACTION_OPEN_PROFILE"), @"user_circle"),
              SPKNotificationItem(kSPKNotificationGalleryDeleteFile, SPKL(@"UI_NOTIFICATION_CENTER_DELETE_FILE_TEXT"), @"media"),
              SPKNotificationItem(kSPKNotificationGalleryDeleteSelected, SPKL(@"UI_NOTIFICATION_CENTER_DELETE_SELECTED_FILES_TEXT"), @"circle_check"),
              SPKNotificationItem(kSPKNotificationGalleryBulkDelete, SPKL(@"UI_NOTIFICATION_CENTER_BULK_DELETE_TEXT"), @"trash"),
              SPKNotificationItem(kSPKNotificationGalleryImport, SPKL(@"GALLERY_GALLERY_SETTINGS_IMPORT_MEDIA_TITLE"), @"media"),
          ]},
        @{@"title" : SPKL(@"UI_NOTIFICATION_CENTER_SETTINGS_TOOLS_TEXT"),
          @"items" : @[
              SPKNotificationItem(kSPKNotificationSettingsExport, SPKL(@"UI_NOTIFICATION_CENTER_EXPORT_SETTINGS_TEXT"), @"arrow_up"),
              SPKNotificationItem(kSPKNotificationSettingsImport, SPKL(@"UI_NOTIFICATION_CENTER_IMPORT_SETTINGS_TEXT"), @"arrow_down"),
              SPKNotificationItem(kSPKNotificationSettingsClearCache, SPKL(@"GENERAL_GENERAL_CLEAR_CACHE_TITLE"), @"trash"),
              SPKNotificationItem(kSPKNotificationCopyDescription, SPKL(@"UI_NOTIFICATION_CENTER_COPY_DESCRIPTION_TEXT"), @"copy"),
              SPKNotificationItem(kSPKNotificationCopyNoteText, SPKL(@"MESSAGES_NOTES_COPY_NOTE_TEXT_TITLE"), @"copy"),
              SPKNotificationItem(kSPKNotificationShareLongPressCopyLink, SPKL(@"GENERAL_BEHAVIOR_HOLD_SEND_COPY_LINK_TITLE"), @"link"),
              SPKNotificationItem(kSPKNotificationFlexUnavailable, SPKL(@"UI_NOTIFICATION_CENTER_FLEX_UNAVAILABLE_TEXT"), @"warning"),
          ]},
    ];
}

static BOOL SPKNotificationIdentifierIsRegistered(NSString *identifier) {
    if (identifier.length == 0)
        return NO;
    static NSSet<NSString *> *registeredIdentifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
        for (NSDictionary *section in SPKNotificationPreferenceSections()) {
            for (NSDictionary *item in section[@"items"] ?: @[]) {
                NSString *itemIdentifier = item[@"identifier"];
                if (itemIdentifier.length > 0) {
                    [identifiers addObject:itemIdentifier];
                }
            }
        }
        registeredIdentifiers = [identifiers copy];
    });
    return [registeredIdentifiers containsObject:identifier];
}

NSDictionary<NSString *, id> *SPKNotificationDefaultPreferences(void) {
    NSMutableDictionary *defaults = [@{
        kSPKNotificationPillGlowEnabledKey : @YES,
        kSPKNotificationPillLiquidGlassEnabledKey : @NO,
        kSPKNotificationPillDurationKey : @(kSPKNotificationDefaultPillDuration),
        kSPKNotificationProgressSubtitleStyleKey : @"both",
        kSPKNotificationPillPositionKey : @"top",
    } mutableCopy];
    for (NSDictionary *section in SPKNotificationPreferenceSections()) {
        for (NSDictionary *item in section[@"items"] ?: @[]) {
            defaults[SPKNotificationDefaultsKey(item[@"identifier"])] = @YES;
            defaults[SPKNotificationHapticDefaultsKey(item[@"identifier"])] = @YES;
        }
    }
    return defaults;
}

BOOL SPKNotificationIsEnabled(NSString *identifier) {
    if (!SPKNotificationIdentifierIsRegistered(identifier))
        return NO;
    // Via SPKUtils so per-account toggles resolve (see SPKNotificationPillDuration).
    return [SPKUtils getBoolPref:SPKNotificationDefaultsKey(identifier)];
}

NSTimeInterval SPKNotificationPillDuration(void) {
    // Read through SPKUtils so the per-account effective key resolves — the
    // settings UI writes via SPKEffectivePreferenceKey, so a raw read here would
    // always miss it and fall back to the default when per-account prefs are on.
    NSTimeInterval duration = [SPKUtils getDoublePref:kSPKNotificationPillDurationKey];
    if (duration <= 0.0)
        duration = kSPKNotificationDefaultPillDuration;
    return MIN(kSPKNotificationMaxPillDuration, MAX(kSPKNotificationMinPillDuration, duration));
}

void SPKNotificationTriggerHaptic(NSString *identifier, SPKNotificationTone tone) {
    if (!SPKNotificationIdentifierIsRegistered(identifier))
        return;
    if ([SPKUtils getBoolPref:@"general_disable_haptics"])
        return;
    if (![SPKUtils getBoolPref:SPKNotificationHapticDefaultsKey(identifier)])
        return;

    dispatch_block_t trigger = ^{
        switch (tone) {
        case SPKNotificationToneSuccess: {
            UINotificationFeedbackGenerator *haptic = [[UINotificationFeedbackGenerator alloc] init];
            [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
            break;
        }
        case SPKNotificationToneError: {
            UINotificationFeedbackGenerator *haptic = [[UINotificationFeedbackGenerator alloc] init];
            [haptic notificationOccurred:UINotificationFeedbackTypeError];
            break;
        }
        case SPKNotificationToneInfo:
        default: {
            UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [haptic impactOccurred];
            break;
        }
        }
    };

    if (NSThread.isMainThread)
        trigger();
    else
        dispatch_async(dispatch_get_main_queue(), trigger);
}

SPKNotificationTone SPKNotificationToneForIconResource(NSString *iconResource) {
    if ([iconResource isEqualToString:@"error_filled"] ||
        [iconResource isEqualToString:@"error_circle_filled"])
        return SPKNotificationToneError;
    if ([iconResource isEqualToString:@"circle_check_filled"] ||
        [iconResource isEqualToString:@"copy_filled"]) {
        return SPKNotificationToneSuccess;
    }
    return SPKNotificationToneInfo;
}

static NSString *SPKNotificationIconResourceForTone(NSString *iconResource, SPKNotificationTone tone) {
    switch (tone) {
    case SPKNotificationToneSuccess:
        return @"circle_check_filled";
    case SPKNotificationToneError:
        return @"error_filled";
    case SPKNotificationToneInfo:
    default:
        return iconResource.length ? iconResource : @"info_filled";
    }
}

@interface SPKNotificationCenter ()
@property (nonatomic, strong) NSMutableArray<SPKNotificationSlot *> *visible;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *queue;
@property (nonatomic, strong) SPKNotificationPassthroughWindow *overlayWindow;
@property (nonatomic, strong) SPKNotificationOverlayRootViewController *overlayRoot;
// The pill shown for preparatory work that runs before the real flow starts (e.g.
// the 4K candidate fetch). Weak: it's owned by its slot, and whoever adopts it as a
// real progress pill clears this so it's no longer dismissed out from under them.
@property (nonatomic, weak) SPKNotificationPillView *transientProgressPill;
- (void)notifyIdentifier:(NSString *)identifier
                   title:(NSString *)title
                subtitle:(NSString *)subtitle
            iconResource:(NSString *)iconResource
                    tone:(SPKNotificationTone)tone
           triggerHaptic:(BOOL)triggerHaptic
                   onTap:(void (^)(void))onTap;
@end

// Whether any Sparkle settings UI is on screen — the manual-seen manage lists are
// SPKSettingsViewController subclasses, so this is YES both when that list is open
// and anywhere else in Settings. Used to suppress the "tap to open list" pill
// affordance when the user is already there.
static BOOL SPKNotifTreeHasClass(UIViewController *vc, Class cls, NSMutableSet *seen) {
    if (!vc || [seen containsObject:vc])
        return NO;
    [seen addObject:vc];
    if ([vc isKindOfClass:cls])
        return YES;
    if (SPKNotifTreeHasClass(vc.presentedViewController, cls, seen))
        return YES;
    if ([vc isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)vc).viewControllers) {
            if (SPKNotifTreeHasClass(child, cls, seen))
                return YES;
        }
    }
    for (UIViewController *child in vc.childViewControllers) {
        if (SPKNotifTreeHasClass(child, cls, seen))
            return YES;
    }
    return NO;
}

static BOOL SPKManualSeenSettingsUIVisible(void) {
    Class cls = NSClassFromString(@"SPKSettingsViewController");
    if (!cls)
        return NO;
    NSMutableSet *seen = [NSMutableSet set];
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden)
            continue;
        if (SPKNotifTreeHasClass(window.rootViewController, cls, seen))
            return YES;
    }
    return NO;
}

@implementation SPKNotificationCenter

+ (instancetype)shared {
    static SPKNotificationCenter *center;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        center = [SPKNotificationCenter new];
    });
    return center;
}

- (instancetype)init {
    self = [super init];
    if (!self)
        return nil;
    _visible = [NSMutableArray array];
    _queue = [NSMutableArray array];
    return self;
}

- (UIWindow *)primaryWindow {
    UIViewController *topController = topMostController();
    if (topController.view.window && !topController.view.window.hidden)
        return topController.view.window;
    if (UIApplication.sharedApplication.keyWindow && !UIApplication.sharedApplication.keyWindow.hidden)
        return UIApplication.sharedApplication.keyWindow;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (!window.hidden && window.alpha > 0.01 && window.windowLevel <= UIWindowLevelAlert)
            return window;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

- (UIWindowScene *)windowScene {
    UIWindow *window = [self primaryWindow];
    if ([window.windowScene isKindOfClass:UIWindowScene.class])
        return window.windowScene;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class])
            return (UIWindowScene *)scene;
    }
    return nil;
}

- (UIView *)hostView {
    UIWindowScene *scene = [self windowScene];
    if (!scene)
        return [self primaryWindow] ?: topMostController().view;
    if (!self.overlayWindow || self.overlayWindow.windowScene != scene) {
        self.overlayRoot = [SPKNotificationOverlayRootViewController new];
        self.overlayWindow = [[SPKNotificationPassthroughWindow alloc] initWithWindowScene:scene];
        self.overlayWindow.rootViewController = self.overlayRoot;
        self.overlayWindow.backgroundColor = UIColor.clearColor;
        self.overlayWindow.opaque = NO;
        self.overlayWindow.windowLevel = UIWindowLevelAlert + 100.0;
        self.overlayWindow.frame = scene.coordinateSpace.bounds;
    }
    self.overlayRoot.view.frame = self.overlayWindow.bounds;
    self.overlayWindow.hidden = NO;
    return self.overlayRoot.view;
}

- (void)cleanupIfEmpty {
    if (self.visible.count > 0 || self.queue.count > 0)
        return;
    self.overlayWindow.hidden = YES;
    self.overlayWindow.rootViewController = nil;
    self.overlayWindow = nil;
    self.overlayRoot = nil;
}

- (void)onMain:(dispatch_block_t)block {
    if (!block)
        return;
    if (NSThread.isMainThread)
        block();
    else
        dispatch_async(dispatch_get_main_queue(), block);
}

- (CGFloat)offsetForIndex:(NSUInteger)index {
    BOOL isBottom = [[SPKUtils getStringPref:kSPKNotificationPillPositionKey] isEqualToString:@"bottom"];
    CGFloat offset = isBottom ? kSPKNotificationBottomMargin : kSPKNotificationTopMargin;
    for (NSUInteger i = 0; i < index && i < self.visible.count; i++) {
        SPKNotificationPillView *pill = self.visible[i].pill;
        CGFloat height = CGRectGetHeight(pill.bounds);
        if (height < 1.0)
            height = 52.0;
        offset += height + kSPKNotificationStackSpacing;
    }
    return offset;
}

- (void)relayoutAnimated:(BOOL)animated {
    UIView *host = self.overlayRoot.view;
    BOOL isBottom = [[SPKUtils getStringPref:kSPKNotificationPillPositionKey] isEqualToString:@"bottom"];
    for (NSUInteger i = 0; i < self.visible.count; i++) {
        CGFloat offset = [self offsetForIndex:i];
        self.visible[i].topConstraint.constant = isBottom ? -offset : offset;
    }
    void (^layout)(void) = ^{
        [host layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseOut animations:layout completion:nil];
    } else {
        layout();
    }
}

- (void)insertPill:(SPKNotificationPillView *)pill identifier:(NSString *)identifier progress:(BOOL)progress {
    UIView *host = [self hostView];
    [host addSubview:pill];
    BOOL isBottom = [[SPKUtils getStringPref:kSPKNotificationPillPositionKey] isEqualToString:@"bottom"];
    NSLayoutConstraint *anchor;
    if (isBottom) {
        anchor = [pill.bottomAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.bottomAnchor constant:90.0];
    } else {
        anchor = [pill.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:-90.0];
    }
    [pill setPresentationTopConstraint:anchor];
    [NSLayoutConstraint activateConstraints:@[
        anchor,
        [pill.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
    ]];

    SPKNotificationSlot *slot = [SPKNotificationSlot new];
    slot.pill = pill;
    slot.topConstraint = anchor;
    slot.identifier = identifier ?: @"";
    slot.progress = progress;
    [self.visible addObject:slot];

    __weak typeof(self) weakSelf = self;
    __weak SPKNotificationSlot *weakSlot = slot;
    pill.onDidDismiss = ^{
        __strong typeof(weakSelf) self = weakSelf;
        SPKNotificationSlot *strongSlot = weakSlot;
        if (!self || !strongSlot)
            return;
        [strongSlot.timer invalidate];
        [self.visible removeObject:strongSlot];
        [self relayoutAnimated:YES];
        [self drainQueue];
        [self cleanupIfEmpty];
    };

    [host layoutIfNeeded];
    pill.alpha = 0.0;
    CGFloat entranceY = isBottom ? 24.0 : -24.0;
    pill.transform = CGAffineTransformConcat(CGAffineTransformMakeTranslation(0.0, entranceY), CGAffineTransformMakeScale(0.88, 0.88));
    anchor.constant = isBottom ? -[self offsetForIndex:self.visible.count - 1] : [self offsetForIndex:self.visible.count - 1];
    [UIView animateWithDuration:kSPKNotificationInsertDuration
                          delay:0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.85
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         pill.alpha = 1.0;
                         pill.transform = CGAffineTransformIdentity;
                         [self relayoutAnimated:NO];
                     }
                     completion:nil];

    if (!progress) {
        slot.timer = [NSTimer scheduledTimerWithTimeInterval:SPKNotificationPillDuration()
                                                     repeats:NO
                                                       block:^(__unused NSTimer *timer) {
                                                           SPKNotificationSlot *strongSlot = weakSlot;
                                                           if (strongSlot.pill.superview)
                                                               [strongSlot.pill dismiss];
                                                       }];
    }
}

- (void)drainQueue {
    while (self.queue.count > 0) {
        NSUInteger visibleToasts = 0;
        for (SPKNotificationSlot *slot in self.visible) {
            if (!slot.progress)
                visibleToasts++;
        }
        if (visibleToasts >= kSPKNotificationMaxQueuedToasts)
            return;
        NSDictionary *next = self.queue.firstObject;
        [self.queue removeObjectAtIndex:0];
        [self notifyIdentifier:next[@"identifier"]
                         title:next[@"title"]
                      subtitle:next[@"subtitle"]
                  iconResource:next[@"icon"]
                          tone:[next[@"tone"] unsignedIntegerValue]
                 triggerHaptic:NO
                         onTap:next[@"onTap"]];
    }
}

- (void)notifyIdentifier:(NSString *)identifier
                   title:(NSString *)title
                subtitle:(NSString *)subtitle
            iconResource:(NSString *)iconResource
                    tone:(SPKNotificationTone)tone {
    [self notifyIdentifier:identifier title:title subtitle:subtitle iconResource:iconResource tone:tone triggerHaptic:YES onTap:nil];
}

- (void)notifyIdentifier:(NSString *)identifier
                   title:(NSString *)title
                subtitle:(NSString *)subtitle
            iconResource:(NSString *)iconResource
                    tone:(SPKNotificationTone)tone
           triggerHaptic:(BOOL)triggerHaptic
                   onTap:(void (^)(void))onTap {
    if (triggerHaptic) {
        SPKNotificationTriggerHaptic(identifier, tone);
    }
    if (!SPKNotificationIsEnabled(identifier))
        return;
    [self onMain:^{
        NSUInteger visibleToasts = 0;
        for (SPKNotificationSlot *slot in self.visible) {
            if (!slot.progress)
                visibleToasts++;
        }
        if (visibleToasts >= kSPKNotificationMaxQueuedToasts) {
            NSMutableDictionary *queued = [@{
                @"identifier" : identifier ?: @"",
                @"title" : title ?: @"",
                @"subtitle" : subtitle ?: @"",
                @"icon" : SPKNotificationIconResourceForTone(iconResource, tone) ?: @"",
                @"tone" : @(tone),
            } mutableCopy];
            if (onTap)
                queued[@"onTap"] = [onTap copy];
            [self.queue addObject:queued];
            return;
        }
        // When the user is already in the manage list (or anywhere in Settings),
        // don't advertise/enable "tap to open" — there's nothing to open.
        BOOL suppressSeenListTap = SPKManualSeenSettingsUIVisible();
        // Hidden chat pills are informational rather than success toned, because their
        // icon says which way the chat went and the success tone replaces it with a
        // checkmark. They still open their list, so the tap is offered for that
        // identifier on any tone.
        BOOL offersListTap = (tone == SPKNotificationToneSuccess ||
                              [identifier isEqualToString:kSPKNotificationDirectHiddenChat]) &&
                             !suppressSeenListTap;
        NSString *resolvedSubtitle = subtitle;
        if (offersListTap) {
            if ([identifier isEqualToString:kSPKNotificationStorySeenUserRule] ||
                [identifier isEqualToString:kSPKNotificationProfileStorySeenUserRule]) {
                BOOL manualSeenEnabled = [SPKUtils getBoolPref:@"stories_manual_seen"];
                resolvedSubtitle = manualSeenEnabled ? SPKL(@"UI_NOTIFICATION_CENTER_TAP_OPEN_EXCLUDED_LIST_TEXT") : SPKL(@"UI_NOTIFICATION_CENTER_TAP_OPEN_INCLUDED_LIST_TEXT");
            } else if ([identifier isEqualToString:kSPKNotificationDirectThreadSeenRule] ||
                       [identifier isEqualToString:kSPKNotificationProfileMessagesSeenUserRule]) {
                BOOL manualSeenEnabled = [SPKUtils getBoolPref:@"msgs_manual_seen"];
                resolvedSubtitle = manualSeenEnabled ? SPKL(@"UI_NOTIFICATION_CENTER_TAP_OPEN_EXCLUDED_LIST_TEXT") : SPKL(@"UI_NOTIFICATION_CENTER_TAP_OPEN_INCLUDED_LIST_TEXT");
            } else if ([identifier isEqualToString:kSPKNotificationDirectHiddenChat]) {
                // Only when the pill has nothing more specific to say: the hide pill's
                // own subtitle explains how to get the chat back, which is worth more
                // than naming the screen the tap opens.
                if (resolvedSubtitle.length == 0)
                    resolvedSubtitle = SPKL(@"UI_NOTIFICATION_CENTER_TAP_OPEN_HIDDEN_CHATS_TEXT");
            } else if ([identifier isEqualToString:kSPKNotificationPresenceUserRule]) {
                resolvedSubtitle = SPKL(@"MESSAGES_ACTIVITY_TAP_TO_OPEN_LIST_SUBTITLE");
            } else if (SPKAutoSaveListViewControllerForRuleIdentifier(identifier)) {
                resolvedSubtitle = SPKL(@"UI_NOTIFICATION_CENTER_TAP_OPEN_AUTO_SAVE_LIST_TEXT");
            }
        }

        NSString *resolvedIconResource = SPKNotificationIconResourceForTone(iconResource, tone);
        UIImage *icon = resolvedIconResource.length
                            ? [SPKAssetUtils instagramIconNamed:resolvedIconResource pointSize:16.0 renderingMode:UIImageRenderingModeAlwaysTemplate]
                            : nil;
        SPKNotificationPillView *pill = [SPKNotificationPillView toastPillWithTitle:title subtitle:resolvedSubtitle icon:icon tone:tone];

        if (offersListTap) {
            if ([identifier isEqualToString:kSPKNotificationStorySeenUserRule] ||
                [identifier isEqualToString:kSPKNotificationProfileStorySeenUserRule]) {
                pill.onTapWhenCompleted = ^{
                    [SPKUtils presentViewControllerInSheet:SPKStoryManualSeenListViewController()];
                };
            } else if ([identifier isEqualToString:kSPKNotificationDirectThreadSeenRule] ||
                       [identifier isEqualToString:kSPKNotificationProfileMessagesSeenUserRule]) {
                pill.onTapWhenCompleted = ^{
                    [SPKUtils presentViewControllerInSheet:SPKDirectManualSeenListViewController()];
                };
            } else if ([identifier isEqualToString:kSPKNotificationDirectHiddenChat]) {
                pill.onTapWhenCompleted = ^{
                    [SPKUtils presentViewControllerInSheet:SPKDirectHiddenChatsListViewController()];
                };
            } else if (SPKAutoSaveListViewControllerForRuleIdentifier(identifier)) {
                pill.onTapWhenCompleted = ^{
                    // Re-resolved on tap rather than captured: by then the user may have
                    // switched Filter Mode, and the list screen reads its mode at init.
                    UIViewController *list = SPKAutoSaveListViewControllerForRuleIdentifier(identifier);
                    if (list)
                        [SPKUtils presentViewControllerInSheet:list];
                };
            }
        }
        // An explicit tap handler takes precedence over the identifier-based ones.
        if (onTap)
            pill.onTapWhenCompleted = onTap;

        [self insertPill:pill identifier:identifier progress:NO];
    }];
}

- (SPKNotificationPillView *)beginProgressForIdentifier:(NSString *)identifier
                                                  title:(NSString *)title
                                               onCancel:(void (^)(void))onCancel {
    if (!SPKNotificationIsEnabled(identifier))
        return nil;
    return [self beginUnmanagedProgressWithTitle:title onCancel:onCancel];
}

- (SPKNotificationPillView *)beginUnmanagedProgressWithTitle:(NSString *)title
                                                    onCancel:(void (^)(void))onCancel {
    return [self beginUnmanagedProgressWithTitle:title onCancel:onCancel transient:NO];
}

- (SPKNotificationPillView *)beginTransientProgressWithTitle:(NSString *)title
                                                    onCancel:(void (^)(void))onCancel {
    return [self beginUnmanagedProgressWithTitle:title onCancel:onCancel transient:YES];
}

- (void)dismissTransientProgressPill {
    dispatch_block_t dismiss = ^{
        SPKNotificationPillView *pill = self.transientProgressPill;
        self.transientProgressPill = nil;
        if (pill && pill.superview)
            [pill dismiss];
    };
    if (NSThread.isMainThread)
        dismiss();
    else
        dispatch_async(dispatch_get_main_queue(), dismiss);
}

- (SPKNotificationPillView *)beginUnmanagedProgressWithTitle:(NSString *)title
                                                    onCancel:(void (^)(void))onCancel
                                                   transient:(BOOL)transient {
    __block SPKNotificationPillView *pill = nil;
    dispatch_block_t create = ^{
        for (SPKNotificationSlot *slot in self.visible) {
            if (slot.progress && slot.pill && slot.pill.superview) {
                pill = slot.pill;
                if (title.length > 0) {
                    [pill updateProgressTitle:title subtitle:nil];
                }
                if (onCancel) {
                    pill.onCancel = onCancel;
                }
                // Reusing a live progress pill means a real flow now owns it (either
                // it was already real, or a transient pill just morphed into one), so
                // it must no longer be dismissed as transient.
                self.transientProgressPill = nil;
                return;
            }
        }
        pill = [SPKNotificationPillView progressPill];
        [pill updateProgressTitle:title ?: SPKL(@"MEDIA_TRIM_TRIM_ENTRY_DOWNLOADING_TEXT") subtitle:nil];
        pill.onCancel = onCancel;
        __weak SPKNotificationPillView *weakPillRef = pill;
        pill.onTonePresented = ^(SPKNotificationTone tone) {
            if (![SPKUtils getBoolPref:@"general_disable_haptics"]) {
                UINotificationFeedbackGenerator *haptic = [[UINotificationFeedbackGenerator alloc] init];
                if (tone == SPKNotificationToneError)
                    [haptic notificationOccurred:UINotificationFeedbackTypeError];
                else if (tone == SPKNotificationToneSuccess)
                    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
                else
                    [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
            }
            // Auto-dismiss progress pills in terminal state after the configured duration.
            NSTimeInterval duration = SPKNotificationPillDuration();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SPKNotificationPillView *p = weakPillRef;
                if (p && p.superview)
                    [p dismiss];
            });
        };
        self.transientProgressPill = transient ? pill : nil;
        // Prep work is a single request with nothing to report: spin instead of
        // sitting at 0%. The download that adopts this pill flips it back.
        if (transient)
            [pill setProgressIndeterminate:YES];
        [self insertPill:pill identifier:@"download_queue_aggregate" progress:YES];
    };
    if (NSThread.isMainThread)
        create();
    else
        dispatch_sync(dispatch_get_main_queue(), create);
    return pill;
}

@end

void SPKNotify(NSString *identifier,
               NSString *title,
               NSString *subtitle,
               NSString *iconResource,
               SPKNotificationTone tone) {
    [[SPKNotificationCenter shared] notifyIdentifier:identifier title:title subtitle:subtitle iconResource:iconResource tone:tone];
}

void SPKNotifyTappable(NSString *identifier,
                       NSString *title,
                       NSString *subtitle,
                       NSString *iconResource,
                       SPKNotificationTone tone,
                       void (^onTap)(void)) {
    [[SPKNotificationCenter shared] notifyIdentifier:identifier title:title subtitle:subtitle iconResource:iconResource tone:tone triggerHaptic:YES onTap:onTap];
}

SPKNotificationPillView *SPKNotifyProgress(NSString *identifier, NSString *title, void (^onCancel)(void)) {
    return [[SPKNotificationCenter shared] beginProgressForIdentifier:identifier title:title onCancel:onCancel];
}
