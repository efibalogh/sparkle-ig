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
SPK_NOTIF_CONST(kSPKNotificationShareSheetPin, "share_sheet_pin");
SPK_NOTIF_CONST(kSPKNotificationSearchPin, "search_pin");
SPK_NOTIF_CONST(kSPKNotificationClipboardUsername, "clipboard_username");
SPK_NOTIF_CONST(kSPKNotificationDirectAutoSave, "direct_auto_save");
SPK_NOTIF_CONST(kSPKNotificationDirectAutoSaveThreadRule, "toggle_direct_auto_save_thread_rule");
SPK_NOTIF_CONST(kSPKNotificationUnsentMessage, "unsent_message");
SPK_NOTIF_CONST(kSPKNotificationPresenceOnline, "presence_online");
SPK_NOTIF_CONST(kSPKNotificationPresenceOffline, "presence_offline");
SPK_NOTIF_CONST(kSPKNotificationPresenceTyping, "presence_typing");
SPK_NOTIF_CONST(kSPKNotificationPresenceRead, "presence_read");
SPK_NOTIF_CONST(kSPKNotificationPresenceUserRule, "presence_user_rule");
SPK_NOTIF_CONST(kSPKNotificationUnsentReaction, "unsent_reaction");
SPK_NOTIF_CONST(kSPKNotificationInstantsUpload, "instants_upload");
SPK_NOTIF_CONST(kSPKNotificationInstantsAutoSave, "instants_auto_save");
SPK_NOTIF_CONST(kSPKNotificationInstantsAutoSaveUserRule, "toggle_instants_auto_save_user_rule");
SPK_NOTIF_CONST(kSPKNotificationInstantsMarkSeen, "instants_mark_seen");

SPK_NOTIF_CONST(kSPKNotificationProfileCopyInfo, "profile_copy_info");
SPK_NOTIF_CONST(kSPKNotificationProfileAnalyzerComplete, "profile_analyzer_complete");
SPK_NOTIF_CONST(kSPKNotificationProfileStorySeenUserRule, "toggle_profile_story_seen_user_rule");
SPK_NOTIF_CONST(kSPKNotificationProfileMessagesSeenUserRule, "toggle_profile_messages_seen_user_rule");

SPK_NOTIF_CONST(kSPKNotificationMediaPreviewSavePhotos, "media_preview_save_photos");
SPK_NOTIF_CONST(kSPKNotificationMediaPreviewSaveGallery, "media_preview_save_gallery");
SPK_NOTIF_CONST(kSPKNotificationMediaPreviewShare, "media_preview_share");
SPK_NOTIF_CONST(kSPKNotificationMediaPreviewCopy, "media_preview_copy");
SPK_NOTIF_CONST(kSPKNotificationMediaPreviewDeleteGallery, "media_preview_delete_gallery");

SPK_NOTIF_CONST(kSPKNotificationGalleryOpenOriginal, "gallery_open_original");
SPK_NOTIF_CONST(kSPKNotificationGalleryOpenProfile, "gallery_open_profile");
SPK_NOTIF_CONST(kSPKNotificationGalleryDeleteFile, "gallery_delete_file");
SPK_NOTIF_CONST(kSPKNotificationGalleryDeleteSelected, "gallery_delete_selected");
SPK_NOTIF_CONST(kSPKNotificationGalleryBulkDelete, "gallery_bulk_delete");
SPK_NOTIF_CONST(kSPKNotificationGalleryImport, "gallery_import");

SPK_NOTIF_CONST(kSPKNotificationSettingsExport, "settings_export");
SPK_NOTIF_CONST(kSPKNotificationSettingsImport, "settings_import");
SPK_NOTIF_CONST(kSPKNotificationSettingsClearCache, "settings_clear_cache");
SPK_NOTIF_CONST(kSPKNotificationDownloadHistoryClear, "download_history_clear");
SPK_NOTIF_CONST(kSPKNotificationDeletedMessagesClear, "deleted_messages_clear");
SPK_NOTIF_CONST(kSPKNotificationProfileAnalyzerClear, "profile_analyzer_clear");
SPK_NOTIF_CONST(kSPKNotificationLocalSeenReset, "story_local_seen_reset");
SPK_NOTIF_CONST(kSPKNotificationPasscodeChanged, "passcode_changed");
SPK_NOTIF_CONST(kSPKNotificationLanguagePackUpdate, "language_pack_update");
SPK_NOTIF_CONST(kSPKNotificationCopyDescription, "copy_description");
SPK_NOTIF_CONST(kSPKNotificationCopyNoteText, "copy_note_text");
SPK_NOTIF_CONST(kSPKNotificationFakeLocation, "fake_location");
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
NSString *const kSPKNotificationStyleKey = @"notifs_style";

static CGFloat const kSPKNotificationStackSpacing = 8.0;
static CGFloat const kSPKNotificationTopMargin = 8.0;
// Bottom notifications rest just above whatever is at the bottom of the screen: the
// tab bar, a toolbar, the bottom search bar, the keyboard, or the bottom safe area
// when there is nothing, and flush on the Direct composer. The Instagram style uses
// Instagram's own spacing (measured on 453); the pill keeps a little more room.
static CGFloat const kSPKNotificationInstagramChromeGap = 8.0;
static CGFloat const kSPKNotificationPillChromeGap = 12.0;
static NSTimeInterval const kSPKNotificationInsertDuration = 0.55;
static NSTimeInterval const kSPKNotificationDefaultPillDuration = 1.5;
static NSTimeInterval const kSPKNotificationMinPillDuration = 0.5;
static NSTimeInterval const kSPKNotificationMaxPillDuration = 5.0;
static NSUInteger const kSPKNotificationMaxQueuedToasts = 3;

// Last keyboard end frame in screen coordinates, CGRectNull while hidden. Tracked
// from load because the center is created lazily, often after the keyboard is up.
static CGRect sSPKNotificationKeyboardScreenFrame = {{INFINITY, INFINITY}, {0, 0}};

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

NSString *const kSPKNotificationModeValueAll = @"all";
NSString *const kSPKNotificationModeValueBanner = @"banner";
NSString *const kSPKNotificationModeValueHaptic = @"haptic";
NSString *const kSPKNotificationModeValueOff = @"off";
NSString *const kSPKNotificationErrorHapticKey = @"notifs_error_haptic";

// Which identifiers each group covers. Kept apart from the titles so the
// preference migration, which runs before localization is ready, can read it.
NSDictionary<NSString *, NSArray<NSString *> *> *SPKNotificationGroupMembership(void) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *membership;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        membership = @{
            @"downloads" : @[
                kSPKNotificationDownloadLibrary,
                kSPKNotificationDownloadShare,
                kSPKNotificationDownloadGallery,
                kSPKNotificationDownloadAllLibrary,
                kSPKNotificationDownloadAllShare,
                kSPKNotificationDownloadAllGallery,
                kSPKNotificationDownloadAudio,
                kSPKNotificationDownloadAudioShare,
                kSPKNotificationDownloadAudioGallery,
                kSPKNotificationPlayAudio,
                kSPKNotificationRepost,
                kSPKNotificationExpand,
                kSPKNotificationViewThumbnail,
                kSPKNotificationMediaPreviewSavePhotos,
                kSPKNotificationMediaPreviewSaveGallery,
                kSPKNotificationMediaPreviewShare,
                kSPKNotificationInstantsUpload,
            ],
            @"copies" : @[
                kSPKNotificationCopyDownloadLink,
                kSPKNotificationCopyMedia,
                kSPKNotificationDownloadAllClipboard,
                kSPKNotificationDownloadAllLinks,
                kSPKNotificationCopyCaption,
                kSPKNotificationCopyAudioURL,
                kSPKNotificationMediaPreviewCopy,
                kSPKNotificationProfileCopyInfo,
                kSPKNotificationCopyComment,
                kSPKNotificationCopyGIFLink,
                kSPKNotificationCopyGIFTitle,
                kSPKNotificationCopyDescription,
                kSPKNotificationCopyNoteText,
                kSPKNotificationShareLongPressCopyLink,
            ],
            @"seen" : @[
                kSPKNotificationStoryMarkSeen,
                kSPKNotificationDirectVisualMarkSeen,
                kSPKNotificationThreadMessagesMarkSeen,
                kSPKNotificationInstantsMarkSeen,
            ],
            @"lists" : @[
                kSPKNotificationStorySeenUserRule,
                kSPKNotificationProfileStorySeenUserRule,
                kSPKNotificationDirectThreadSeenRule,
                kSPKNotificationProfileMessagesSeenUserRule,
                kSPKNotificationDirectHiddenChat,
                kSPKNotificationStoryAutoSaveUserRule,
                kSPKNotificationDirectAutoSaveThreadRule,
                kSPKNotificationInstantsAutoSaveUserRule,
                kSPKNotificationPresenceUserRule,
                kSPKNotificationShareSheetPin,
                kSPKNotificationSearchPin,
            ],
            @"gallery" : @[
                kSPKNotificationGalleryOpenOriginal,
                kSPKNotificationGalleryOpenProfile,
                kSPKNotificationGalleryDeleteFile,
                kSPKNotificationGalleryDeleteSelected,
                kSPKNotificationGalleryBulkDelete,
                kSPKNotificationGalleryImport,
                kSPKNotificationMediaPreviewDeleteGallery,
                kSPKNotificationSettingsExport,
                kSPKNotificationSettingsImport,
                kSPKNotificationSettingsClearCache,
                kSPKNotificationDownloadHistoryClear,
                kSPKNotificationDeletedMessagesClear,
                kSPKNotificationProfileAnalyzerClear,
                kSPKNotificationLocalSeenReset,
            ],
            @"other" : @[
                kSPKNotificationStoryMentionsSheet,
                kSPKNotificationOpenTopicSettings,
                kSPKNotificationClipboardUsername,
                kSPKNotificationFakeLocation,
                kSPKNotificationMediaEncodingLogs,
                kSPKNotificationFlexUnavailable,
                kSPKNotificationPasscodeChanged,
            ],
            @"activity" : @[
                kSPKNotificationPresenceOnline,
                kSPKNotificationPresenceOffline,
                kSPKNotificationPresenceTyping,
                kSPKNotificationPresenceRead,
            ],
            @"unsent_messages" : @[
                kSPKNotificationUnsentMessage,
            ],
            @"unsent_reactions" : @[
                kSPKNotificationUnsentReaction,
            ],
            @"auto_save" : @[
                kSPKNotificationStoryAutoSave,
                kSPKNotificationDirectAutoSave,
                kSPKNotificationInstantsAutoSave,
                kSPKNotificationAutoSavePending,
                kSPKNotificationAutoSaveSummary,
            ],
            @"profile_analyzer" : @[
                kSPKNotificationProfileAnalyzerComplete,
            ],
            @"language_packs" : @[
                kSPKNotificationLanguagePackUpdate,
            ],
        };
    });
    return membership;
}

static NSDictionary *SPKNotificationGroup(NSString *group, NSString *kind, NSString *title, NSString *iconName, NSString *footer) {
    return @{
        @"group" : group,
        @"kind" : kind,
        @"title" : title ?: @"",
        @"iconName" : iconName ?: @"info",
        @"footer" : footer ?: @"",
        @"identifiers" : SPKNotificationGroupMembership()[group] ?: @[],
    };
}

// Groups follow what a notification tells you, not which screen sent it: the same
// "Saved to Photos" posted from the action button, the full-screen preview and an
// audio menu is one thing to the user, so it is one setting. Confirmations echo
// something you just did; events report something that happened without you.
// Built per call because the titles follow the interface language.
NSArray<NSDictionary *> *SPKNotificationGroups(void) {
    return @[
        SPKNotificationGroup(@"downloads", @"confirmation", SPKL(@"NOTIFICATION_GROUP_DOWNLOADS_TITLE"), @"download", SPKL(@"NOTIFICATION_GROUP_DOWNLOADS_HELP")),
        SPKNotificationGroup(@"copies", @"confirmation", SPKL(@"NOTIFICATION_GROUP_COPIES_TITLE"), @"copy", SPKL(@"NOTIFICATION_GROUP_COPIES_HELP")),
        SPKNotificationGroup(@"seen", @"confirmation", SPKL(@"NOTIFICATION_GROUP_SEEN_TITLE"), @"eye", SPKL(@"NOTIFICATION_GROUP_SEEN_HELP")),
        SPKNotificationGroup(@"lists", @"confirmation", SPKL(@"NOTIFICATION_GROUP_LISTS_TITLE"), @"pin", SPKL(@"NOTIFICATION_GROUP_LISTS_HELP")),
        SPKNotificationGroup(@"gallery", @"confirmation", SPKL(@"NOTIFICATION_GROUP_DATA_TITLE"), @"cloud", SPKL(@"NOTIFICATION_GROUP_DATA_HELP")),
        SPKNotificationGroup(@"other", @"confirmation", SPKL(@"NOTIFICATION_GROUP_OTHER_TITLE"), @"settings", SPKL(@"NOTIFICATION_GROUP_OTHER_HELP")),
        SPKNotificationGroup(@"activity", @"event", SPKL(@"NOTIFICATION_EVENT_ACTIVITY_TITLE"), @"activity", SPKL(@"NOTIFICATION_EVENT_ACTIVITY_HELP")),
        SPKNotificationGroup(@"unsent_messages", @"event", SPKL(@"NOTIFICATION_EVENT_UNSENT_MESSAGES_TITLE"), @"undo", SPKL(@"NOTIFICATION_EVENT_UNSENT_MESSAGES_HELP")),
        SPKNotificationGroup(@"unsent_reactions", @"event", SPKL(@"NOTIFICATION_EVENT_REMOVED_REACTIONS_TITLE"), @"reactions", SPKL(@"NOTIFICATION_EVENT_REMOVED_REACTIONS_HELP")),
        SPKNotificationGroup(@"auto_save", @"event", SPKL(@"UI_NOTIFICATION_CENTER_AUTO_SAVE_TITLE"), @"download", SPKL(@"NOTIFICATION_EVENT_AUTO_SAVE_HELP")),
        SPKNotificationGroup(@"profile_analyzer", @"event", SPKL(@"NOTIFICATION_EVENT_PROFILE_ANALYZER_TITLE"), @"profile_analyzer", SPKL(@"NOTIFICATION_EVENT_PROFILE_ANALYZER_HELP")),
        SPKNotificationGroup(@"language_packs", @"event", SPKL(@"SETTINGS_STORAGE_USAGE_LANGUAGE_PACKS_TITLE"), @"translate", SPKL(@"NOTIFICATION_EVENT_LANGUAGE_PACKS_HELP")),
    ];
}

NSString *SPKNotificationGroupModeKey(NSString *group) {
    return [NSString stringWithFormat:@"notifs_group_%@", group ?: @""];
}

static NSDictionary<NSString *, NSString *> *SPKNotificationGroupByIdentifier(void) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary<NSString *, NSString *> *m = [NSMutableDictionary dictionary];
        [SPKNotificationGroupMembership() enumerateKeysAndObjectsUsingBlock:^(NSString *group, NSArray<NSString *> *identifiers, __unused BOOL *stop) {
            for (NSString *identifier in identifiers)
                m[identifier] = group;
        }];
        map = [m copy];
    });
    return map;
}

NSDictionary<NSString *, id> *SPKNotificationDefaultPreferences(void) {
    NSMutableDictionary *defaults = [@{
        kSPKNotificationPillGlowEnabledKey : @YES,
        kSPKNotificationPillLiquidGlassEnabledKey : @NO,
        kSPKNotificationPillDurationKey : @(kSPKNotificationDefaultPillDuration),
        kSPKNotificationProgressSubtitleStyleKey : @"both",
        kSPKNotificationPillPositionKey : @"top",
        kSPKNotificationStyleKey : @"pill",
        kSPKNotificationErrorHapticKey : @YES,
    } mutableCopy];
    for (NSString *group in SPKNotificationGroupMembership())
        defaults[SPKNotificationGroupModeKey(group)] = kSPKNotificationModeValueAll;
    return defaults;
}

SPKNotificationMode SPKNotificationModeForIdentifier(NSString *identifier) {
    NSString *group = identifier.length > 0 ? SPKNotificationGroupByIdentifier()[identifier] : nil;
    if (group.length == 0)
        return SPKNotificationModeOff;
    // Via SPKUtils so per-account values resolve (see SPKNotificationPillDuration).
    NSString *value = [SPKUtils getStringPref:SPKNotificationGroupModeKey(group)];
    if ([value isEqualToString:kSPKNotificationModeValueOff])
        return SPKNotificationModeOff;
    if ([value isEqualToString:kSPKNotificationModeValueHaptic])
        return SPKNotificationModeHapticOnly;
    if ([value isEqualToString:kSPKNotificationModeValueBanner])
        return SPKNotificationModeBannerOnly;
    return SPKNotificationModeBannerAndHaptic;
}

BOOL SPKNotificationIsEnabled(NSString *identifier) {
    SPKNotificationMode mode = SPKNotificationModeForIdentifier(identifier);
    return mode == SPKNotificationModeBannerAndHaptic || mode == SPKNotificationModeBannerOnly;
}

BOOL SPKNotificationIsActive(NSString *identifier) {
    return SPKNotificationModeForIdentifier(identifier) != SPKNotificationModeOff;
}

BOOL SPKNotificationIdentifierIsEvent(NSString *identifier) {
    static NSSet<NSString *> *eventGroups;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        eventGroups = [NSSet setWithArray:@[ @"activity", @"unsent_messages", @"unsent_reactions", @"auto_save", @"profile_analyzer", @"language_packs" ]];
    });
    NSString *group = identifier.length > 0 ? SPKNotificationGroupByIdentifier()[identifier] : nil;
    return group.length > 0 && [eventGroups containsObject:group];
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

BOOL SPKNotificationUsesInstagramStyle(void) {
    return [[SPKUtils getStringPref:kSPKNotificationStyleKey] isEqualToString:@"instagram"];
}

UIImage *SPKNotificationIconNamed(NSString *iconResource, BOOL instagramStyle) {
    if (iconResource.length == 0)
        return nil;
    NSString *name = iconResource;
    if (instagramStyle) {
        NSString *base = [name hasSuffix:@"_filled"] ? [name substringToIndex:name.length - @"_filled".length] : name;
        NSString *outline = [base stringByAppendingString:@"_outline"];
        if ([SPKAssetUtils resolvedInstagramIconNameForName:outline].length > 0)
            name = outline;
        else if (base.length < name.length && [SPKAssetUtils resolvedInstagramIconNameForName:base].length > 0)
            name = base;
    }
    return [SPKAssetUtils instagramIconNamed:name
                                   pointSize:instagramStyle ? kSPKNotificationInstagramIconSize : 16.0
                               renderingMode:UIImageRenderingModeAlwaysTemplate];
}

void SPKNotificationTriggerHaptic(NSString *identifier, SPKNotificationTone tone) {
    if ([SPKUtils getBoolPref:@"general_disable_haptics"])
        return;
    if (tone == SPKNotificationToneError) {
        // Errors have their own switch: they show whatever the group says, so the
        // group cannot be what silences their haptic.
        if (!SPKNotificationGroupByIdentifier()[identifier ?: @""] || ![SPKUtils getBoolPref:kSPKNotificationErrorHapticKey])
            return;
    } else {
        SPKNotificationMode mode = SPKNotificationModeForIdentifier(identifier);
        if (mode != SPKNotificationModeBannerAndHaptic && mode != SPKNotificationModeHapticOnly)
            return;
    }

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

// Builds a pill about to be presented. In the Instagram style it is built with
// animations off: setting a pill up runs layout passes and an icon pulse, and those
// would still be playing inside Instagram's toast while it slides in, where
// Instagram's own toast arrives settled and only slides.
static void SPKNotificationBuildPill(dispatch_block_t build) {
    if (!SPKNotificationUsesInstagramStyle()) {
        build();
        return;
    }
    [UIView performWithoutAnimation:build];
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
// Identifier of the flow that last claimed the shared progress pill.
@property (nonatomic, copy) NSString *progressIdentifier;
// The transient pill last told to go away, while it is still animating out.
@property (nonatomic, weak) SPKNotificationPillView *departingTransientPill;
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

+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardWillChangeFrameNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
                                                    [self spk_keyboardWillChange:note hiding:NO];
                                                }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardWillHideNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
                                                    [self spk_keyboardWillChange:note hiding:YES];
                                                }];
}

+ (void)spk_keyboardWillChange:(NSNotification *)note hiding:(BOOL)hiding {
    NSValue *endFrame = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    sSPKNotificationKeyboardScreenFrame = (hiding || !endFrame) ? CGRectNull : endFrame.CGRectValue;
    SPKNotificationCenter *center = [self spk_existingCenter];
    if (center.visible.count == 0)
        return;
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = (UIViewAnimationCurve)[note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    [center relayout];
    [UIView animateWithDuration:duration > 0.0 ? duration : 0.25
                          delay:0
                        options:(UIViewAnimationOptions)curve << 16 | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                         [center.overlayRoot.view layoutIfNeeded];
                     }
                     completion:nil];
}

static SPKNotificationCenter *sSPKNotificationSharedCenter;

+ (instancetype)spk_existingCenter {
    return sSPKNotificationSharedCenter;
}

+ (instancetype)shared {
    static SPKNotificationCenter *center;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        center = [SPKNotificationCenter new];
        sSPKNotificationSharedCenter = center;
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

// How far the keyboard rises above the host's safe-area bottom, 0 while it is
// hidden, undocked or floating (narrower than the host).
- (CGFloat)keyboardLift {
    UIView *host = self.overlayRoot.view;
    UIScreen *screen = host.window.screen;
    if (!host.window || !screen || CGRectIsNull(sSPKNotificationKeyboardScreenFrame) || CGRectIsEmpty(sSPKNotificationKeyboardScreenFrame))
        return 0.0;
    CGRect keyboard = [host convertRect:sSPKNotificationKeyboardScreenFrame fromCoordinateSpace:screen.coordinateSpace];
    if (CGRectGetWidth(keyboard) < CGRectGetWidth(host.bounds) - 1.0 || CGRectGetMinY(keyboard) >= CGRectGetMaxY(host.bounds))
        return 0.0;
    CGFloat safeBottom = CGRectGetMaxY(host.bounds) - host.safeAreaInsets.bottom;
    return MAX(0.0, safeBottom - CGRectGetMinY(keyboard));
}

// The app's own window: the key window that is not Sparkle's overlay.
- (UIWindow *)spk_appWindow {
    UIWindowScene *scene = self.overlayWindow.windowScene;
    NSMutableArray<UIWindowScene *> *scenes = [NSMutableArray array];
    if (scene)
        [scenes addObject:scene];
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class] && candidate != scene)
            [scenes addObject:(UIWindowScene *)candidate];
    }
    UIWindow *fallback = nil;
    for (UIWindowScene *windowScene in scenes) {
        for (UIWindow *window in windowScene.windows) {
            if (window == self.overlayWindow || window.hidden || [window isKindOfClass:SPKNotificationPassthroughWindow.class])
                continue;
            if (window.isKeyWindow)
                return window;
            if (!fallback && window.windowLevel == UIWindowLevelNormal)
                fallback = window;
        }
    }
    return fallback;
}

static BOOL SPKNotificationViewIsOnScreen(UIView *view, UIWindow *window) {
    if (!view || view.window != window)
        return NO;
    for (UIView *current = view; current && current != window; current = current.superview) {
        if (current.hidden || current.alpha < 0.01)
            return NO;
    }
    CGRect frame = [view convertRect:view.bounds toView:nil];
    return CGRectGetHeight(frame) > 1.0 && CGRectGetMinY(frame) < CGRectGetHeight(window.bounds) - 1.0;
}

static UIViewController *SPKNotificationNextController(UIViewController *controller) {
    UIViewController *presented = controller.presentedViewController;
    if (presented && !presented.isBeingDismissed)
        return presented;
    if ([controller isKindOfClass:UINavigationController.class])
        return ((UINavigationController *)controller).topViewController;
    if ([controller isKindOfClass:UITabBarController.class])
        return ((UITabBarController *)controller).selectedViewController;
    // Instagram's containers are custom: follow the visible child covering the most.
    UIViewController *best = nil;
    CGFloat bestArea = 0.0;
    for (UIViewController *child in controller.childViewControllers) {
        if (!child.isViewLoaded || !child.view.window || child.view.hidden || child.view.alpha < 0.01)
            continue;
        CGRect frame = [child.view convertRect:child.view.bounds toView:nil];
        CGFloat area = CGRectGetWidth(frame) * CGRectGetHeight(frame);
        if (area > bestArea) {
            bestArea = area;
            best = child;
        }
    }
    return best;
}

// The Direct composer under `root`, if one is showing. Bounded: it is only looked for
// inside a Direct thread.
static UIView *SPKNotificationDirectComposer(UIView *root) {
    static NSArray<Class> *composerClasses;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<Class> *classes = [NSMutableArray array];
        for (NSString *name in @[ @"IGDirectComposer.IGDirectComposer", @"IGDirectComposer" ]) {
            Class cls = NSClassFromString(name);
            if (cls)
                [classes addObject:cls];
        }
        composerClasses = [classes copy];
    });
    if (!root || composerClasses.count == 0)
        return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (queue.count > 0 && visited < 800) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (view.hidden)
            continue;
        for (Class cls in composerClasses) {
            if ([view isKindOfClass:cls])
                return view;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

// How far above the screen's bottom edge a bottom notification should end, keyboard
// aside, by what is on screen: Instagram's tab bar and Direct composer do not report through the
// safe area, so they are found as views; UIKit chrome (toolbars, the bottom search bar)
// raises the top controllers' safe area, so that covers the rest.
- (CGFloat)spk_bottomChromeGapWithSpacing:(CGFloat)spacing {
    UIWindow *window = [self spk_appWindow];
    CGFloat screenHeight = window ? CGRectGetHeight(window.bounds) : CGRectGetHeight(UIScreen.mainScreen.bounds);
    CGFloat gap = (window ? window.safeAreaInsets.bottom : 34.0) + spacing;
    if (!window)
        return gap;

    Class tabBarControllerClass = NSClassFromString(@"IGTabBarController");
    UIViewController *threadController = nil;
    UIViewController *controller = window.rootViewController;
    for (int depth = 0; controller && depth < 16; depth++) {
        if (controller.isViewLoaded && controller.view.window == window) {
            UIView *view = controller.view;
            // A scroll view's bounds follow its content, so its safe area edge is not a
            // screen position.
            if (![view isKindOfClass:UIScrollView.class]) {
                CGFloat edge = [view convertPoint:CGPointMake(0.0, CGRectGetHeight(view.bounds) - view.safeAreaInsets.bottom) toView:nil].y;
                CGFloat chrome = screenHeight - edge;
                if (chrome >= 0.0 && chrome < screenHeight / 2.0)
                    gap = MAX(gap, chrome + spacing);
            }
            if (tabBarControllerClass && [controller isKindOfClass:tabBarControllerClass] && [controller respondsToSelector:@selector(tabBar)]) {
                UIView *tabBar = ((UITabBarController *)controller).tabBar;
                if ([tabBar isKindOfClass:UIView.class] && SPKNotificationViewIsOnScreen(tabBar, window)) {
                    CGFloat top = CGRectGetMinY([tabBar convertRect:tabBar.bounds toView:nil]);
                    gap = MAX(gap, screenHeight - top + spacing);
                }
            }
            if ([NSStringFromClass(controller.class) containsString:@"DirectThread"])
                threadController = controller;
        }
        controller = SPKNotificationNextController(controller);
    }

    UIView *composer = threadController ? SPKNotificationDirectComposer(threadController.view) : nil;
    if (composer && SPKNotificationViewIsOnScreen(composer, window)) {
        CGFloat top = CGRectGetMinY([composer convertRect:composer.bounds toView:nil]);
        gap = MAX(gap, screenHeight - top);
    }
    return gap;
}

- (CGFloat)spk_chromeSpacing {
    return SPKNotificationUsesInstagramStyle() ? kSPKNotificationInstagramChromeGap : kSPKNotificationPillChromeGap;
}

// Where the bottom stack rests with no keyboard, above the overlay's safe area (the
// stack is anchored to it).
- (CGFloat)baseBottomMargin {
    // One relayout asks once per toast; the screen cannot change in between, and the
    // lookup walks the controller chain, so it is reused for a moment.
    static CFTimeInterval cachedAt = 0.0;
    static CGFloat cachedGap = 0.0;
    static CGFloat cachedSpacing = -1.0;
    CGFloat spacing = [self spk_chromeSpacing];
    CFTimeInterval now = CACurrentMediaTime();
    if (now - cachedAt > 0.05 || cachedSpacing != spacing) {
        cachedGap = [self spk_bottomChromeGapWithSpacing:spacing];
        cachedSpacing = spacing;
        cachedAt = now;
    }
    return MAX(0.0, cachedGap - self.overlayRoot.view.safeAreaInsets.bottom);
}

// How much the keyboard raises the bottom stack above its resting spot. Kept apart
// from the base so the pill can leave from the keyboard edge instead of sliding
// behind the keyboard.
- (CGFloat)bottomStackLift {
    CGFloat lift = [self keyboardLift];
    return lift > 0.0 ? MAX(0.0, lift + [self spk_chromeSpacing] - [self baseBottomMargin]) : 0.0;
}

- (CGFloat)offsetForIndex:(NSUInteger)index {
    BOOL isBottom = [[SPKUtils getStringPref:kSPKNotificationPillPositionKey] isEqualToString:@"bottom"];
    CGFloat offset = isBottom ? [self baseBottomMargin] : kSPKNotificationTopMargin;
    if (isBottom)
        offset += [self bottomStackLift];
    for (NSUInteger i = 0; i < index && i < self.visible.count; i++) {
        SPKNotificationPillView *pill = self.visible[i].pill;
        CGFloat height = CGRectGetHeight(pill.bounds);
        if (height < 1.0)
            height = 52.0;
        offset += height + kSPKNotificationStackSpacing;
    }
    return offset;
}

- (void)relayout {
    BOOL isBottom = [[SPKUtils getStringPref:kSPKNotificationPillPositionKey] isEqualToString:@"bottom"];
    CGFloat bottomLift = isBottom ? [self bottomStackLift] : 0.0;
    for (NSUInteger i = 0; i < self.visible.count; i++) {
        CGFloat offset = [self offsetForIndex:i];
        self.visible[i].topConstraint.constant = isBottom ? -offset : offset;
        self.visible[i].pill.presentationBottomLift = bottomLift;
    }
}

- (void)relayoutAnimated:(BOOL)animated {
    UIView *host = self.overlayRoot.view;
    [self relayout];
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
        // Starts just under the stack's base, so with the keyboard up it rises from
        // the keyboard edge rather than through it.
        CGFloat lift = [self bottomStackLift];
        anchor = [pill.bottomAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.bottomAnchor constant:90.0 - lift];
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

    if (pill.instagramSkin) {
        [self spk_presentInstagramToast:pill anchor:anchor bottom:isBottom host:host];
    } else {
        [self spk_presentSparklePill:pill anchor:anchor bottom:isBottom host:host];
    }

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

// Instagram's own toast (measured on 453): no fade and no scale, only an additive
// position spring from just past the screen edge to its place. Mass 1, stiffness
// 977.163, damping 46.889: a 0.2s perceptual spring with 0.25 bounce.
- (void)spk_presentInstagramToast:(SPKNotificationPillView *)pill
                           anchor:(NSLayoutConstraint *)anchor
                           bottom:(BOOL)isBottom
                             host:(UIView *)host {
    pill.alpha = 1.0;
    pill.transform = CGAffineTransformIdentity;
    anchor.constant = isBottom ? -[self offsetForIndex:self.visible.count - 1] : [self offsetForIndex:self.visible.count - 1];
    [UIView performWithoutAnimation:^{
        [host layoutIfNeeded];
    }];
    CGFloat distance = isBottom ? CGRectGetHeight(host.bounds) - CGRectGetMinY(pill.frame) : -CGRectGetMaxY(pill.frame);
    // Through UIKit, as Instagram does, rather than a spring added to the layer by
    // hand: UIKit's animation asks for the display's high frame rate (30-120Hz) and a
    // hand-built one asks for nothing, which is what made Sparkle's entrance less
    // smooth with otherwise identical numbers. A property animator also makes the same
    // additive position spring Instagram's does.
    CGPoint restingCenter = pill.center;
    [UIView performWithoutAnimation:^{
        pill.center = CGPointMake(restingCenter.x, restingCenter.y + distance);
    }];
    UISpringTimingParameters *spring = [[UISpringTimingParameters alloc] initWithMass:1.0
                                                                            stiffness:977.163
                                                                              damping:46.889
                                                                      initialVelocity:CGVectorMake(0.0, 0.0)];
    UIViewPropertyAnimator *entrance = [[UIViewPropertyAnimator alloc] initWithDuration:0.3 timingParameters:spring];
    [entrance addAnimations:^{
        pill.center = restingCenter;
    }];
    [entrance startAnimation];

    // Pills already on screen make room with the usual motion.
    [UIView animateWithDuration:kSPKNotificationInsertDuration
                          delay:0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.85
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         [self relayoutAnimated:NO];
                     }
                     completion:nil];
}

- (void)spk_presentSparklePill:(SPKNotificationPillView *)pill
                        anchor:(NSLayoutConstraint *)anchor
                        bottom:(BOOL)isBottom
                          host:(UIView *)host {
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
    // A failure always shows: silencing a group is about the confirmations, and a
    // hidden error looks exactly like an action that did nothing.
    BOOL showsBanner = tone == SPKNotificationToneError ? SPKNotificationGroupByIdentifier()[identifier ?: @""] != nil
                                                        : SPKNotificationIsEnabled(identifier);
    if (!showsBanner)
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
                BOOL manualSeenEnabled = SPKStoryManualSeenEnabled();
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
        UIImage *icon = SPKNotificationIconNamed(resolvedIconResource, SPKNotificationUsesInstagramStyle());
        __block SPKNotificationPillView *pill = nil;
        SPKNotificationBuildPill(^{
            pill = [SPKNotificationPillView toastPillWithTitle:title subtitle:resolvedSubtitle icon:icon tone:tone];
        });

        if (offersListTap) {
            if ([identifier isEqualToString:kSPKNotificationStorySeenUserRule] ||
                [identifier isEqualToString:kSPKNotificationProfileStorySeenUserRule]) {
                pill.onTapWhenCompleted = ^{
                    [SPKUtils presentViewControllerInSheet:SPKStoryManualSeenListViewController() revealKey:@"list.story_manual_seen"];
                };
            } else if ([identifier isEqualToString:kSPKNotificationDirectThreadSeenRule] ||
                       [identifier isEqualToString:kSPKNotificationProfileMessagesSeenUserRule]) {
                pill.onTapWhenCompleted = ^{
                    [SPKUtils presentViewControllerInSheet:SPKDirectManualSeenListViewController() revealKey:@"list.direct_manual_seen"];
                };
            } else if ([identifier isEqualToString:kSPKNotificationDirectHiddenChat]) {
                pill.onTapWhenCompleted = ^{
                    [SPKUtils presentViewControllerInSheet:SPKDirectHiddenChatsListViewController() revealKey:@"list.direct_hidden_chats"];
                };
            } else if (SPKAutoSaveListViewControllerForRuleIdentifier(identifier)) {
                pill.onTapWhenCompleted = ^{
                    // Re-resolved on tap rather than captured: by then the user may have
                    // switched Filter Mode, and the list screen reads its mode at init.
                    UIViewController *list = SPKAutoSaveListViewControllerForRuleIdentifier(identifier);
                    if (list)
                        [SPKUtils presentViewControllerInSheet:list revealKey:[@"list." stringByAppendingString:identifier]];
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
    self.progressIdentifier = identifier;
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
        self.departingTransientPill = pill;
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
            // A pill on its way out still has a superview, but adopting it would
            // put the new title on something that vanishes a moment later and
            // leave the new step with no pill at all. That is what happens when
            // one preparatory step ends and the next begins in the same pass.
            if (slot.pill && slot.pill == self.departingTransientPill)
                continue;
            if (slot.progress && slot.pill && slot.pill.superview) {
                pill = slot.pill;
                if (title.length > 0) {
                    [pill updateProgressTitle:title subtitle:nil];
                }
                if (onCancel) {
                    pill.onCancel = onCancel;
                }
                pill.cancellable = YES;
                // Reusing a live progress pill means a real flow now owns it (either
                // it was already real, or a transient pill just morphed into one), so
                // it must no longer be dismissed as transient.
                self.transientProgressPill = nil;
                return;
            }
        }
        SPKNotificationBuildPill(^{
            pill = [SPKNotificationPillView progressPill];
            [pill updateProgressTitle:title ?: SPKL(@"MEDIA_TRIM_TRIM_ENTRY_DOWNLOADING_TEXT") subtitle:nil];
        });
        pill.onCancel = onCancel;
        __weak SPKNotificationPillView *weakPillRef = pill;
        pill.onTonePresented = ^(SPKNotificationTone tone) {
            // The shared progress pill belongs to whichever group claimed it last, so
            // its finishing haptic follows that group (Banner Only stays silent).
            // Pills started without an identifier keep the old behaviour.
            NSString *progressIdentifier = self.progressIdentifier;
            BOOL hapticAllowed = YES;
            if (progressIdentifier.length > 0) {
                if (tone == SPKNotificationToneError)
                    hapticAllowed = [SPKUtils getBoolPref:kSPKNotificationErrorHapticKey];
                else
                    hapticAllowed = SPKNotificationModeForIdentifier(progressIdentifier) == SPKNotificationModeBannerAndHaptic;
            }
            if (hapticAllowed && ![SPKUtils getBoolPref:@"general_disable_haptics"]) {
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
