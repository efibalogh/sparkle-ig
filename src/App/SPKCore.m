#import "SPKCore.h"

#import "../Shared/UI/SPKNotificationCenter.h"
#import "../Shared/Navigation/SPKTabConfiguration.h"
#import "../Tweak.h"
#import "../Utils.h"
#import "SPKStartupHooks.h"
#import "SPKStartupProfiler.h"

static NSDictionary *SPKBootstrapDefaults(void) {
    return @{
        @"tools_disable_safe_mode" : @(NO),
        @"tools_flex_app_launch" : @(NO),
        @"tools_flex_app_start" : @(NO),
        @"tools_flex_instagram" : @(NO),
        @"interface_liquid_glass" : @(NO),
        @"interface_liquid_glass_tabbar_mode" : @"default",
        @"interface_progressive_blur" : @(YES),
        @"interface_nav_order" : @"default",
        @"interface_custom_tab_order" : @[ @"feed", @"clips", @"direct", @"search", @"profile" ],
        @"interface_swipe_tabs" : @"default",
        @"interface_launch_tab" : @"default",
        @"interface_saved_tab_carrier" : @"none",
        @"interface_hide_feed_tab" : @(NO),
        @"interface_hide_reels_tab" : @(NO),
        @"interface_hide_msgs_tab" : @(NO),
        @"interface_hide_explore_tab" : @(NO),
        @"interface_hide_create_tab" : @(NO),
        @"interface_hide_profile_tab" : @(NO),
        @"interface_hide_tab_bar_in_messages_only" : @(NO),
        @"interface_show_header_button_in_messages_only" : @(YES),
        @"interface_open_clipboard_link" : @(YES),
        // Family name of the imported app-wide font; empty means the default face.
        // Bootstrap rather than feature defaults: the font hooks install in %ctor.
        @"interface_custom_font" : @"",
        // Device-global Sparkle language. "auto" follows Instagram, then iOS.
        @"interface_language" : @"auto",
        @"tools_settings_shortcut" : @(YES),
        @"tools_shortcut_haptics" : @(YES),
        @"gallery_quick_access_tab" : @"direct-inbox-tab",
        @"tools_open_settings_on_launch" : @(NO),
        @"tools_disable_all" : @(NO),
#if SPK_DEV
        @"tools_perf_meter" : @(NO),
        @"tools_perf_hud" : @(NO),
#endif
        @"app_safe_startup" : @(NO),
        @"general_hide_ads_stories" : @(YES),
        @"feed_mode" : @"default",
    };
}

static NSDictionary *SPKFeatureDefaults(void) {
    NSMutableDictionary *defaults = [@{
        @"general_copy_text" : @(NO),
        @"stories_detailed_color_picker" : @(NO),
        @"msgs_disable_screenshot_detection" : @(YES),
#if SPK_DEV
        @"tools_hide_testflight_popup" : @(YES),
#endif
        @"tools_fix_duplicate_notifications" : @(NO),
        @"general_hold_send_copy_link" : @(YES),
        @"stories_mark_seen_on_like" : @(NO),
        @"stories_mark_seen_on_reply" : @(NO),
        @"stories_advance_on_like_seen" : @(NO),
        @"stories_advance_on_reply_seen" : @(NO),
        @"msgs_confirm_refresh" : @(NO),
        @"msgs_hide_audio_call_btn" : @(NO),
        @"msgs_hide_video_call_btn" : @(NO),
        @"msgs_hide_flag_btn" : @(NO),
        @"msgs_advance_visual_on_seen" : @(NO),
        @"msgs_stop_visual_auto_advance" : @(NO),
        @"feed_confirm_post_like" : @(NO),
        @"feed_confirm_double_tap_like" : @(NO),
        @"general_comments_confirm_like" : @(NO),
        @"msgs_confirm_double_tap" : @(NO),
        @"msgs_confirm_reaction" : @(NO),
        @"stories_confirm_like" : @(NO),
        @"reels_confirm_like" : @(NO),
        @"msgs_confirm_voice_msg" : @(NO),
        @"general_confirm_create_group" : @(NO),
        @"general_confirm_send" : @(NO),
        @"msgs_keep_deleted" : @(NO),
        @"msgs_deleted_log" : @(NO),
        @"msgs_deleted_log_reactions" : @(NO),
        @"msgs_deleted_log_respect_seen_list" : @(NO),
        @"profile_photo_zoom" : @(NO),
        @"profile_follow_indicator" : @(NO),
        // The mode (`profile_follow_indicator_mode`) and colorful
        // (`profile_follow_indicator_colorful`) keys are intentionally left
        // unregistered so FollowIndicator.x can fall back to the legacy bool
        // above for pre-mode-menu users (→ text + colorful). Everyone else
        // defaults to off / native gray.
        @"profile_analyzer_track_visits" : @(NO),
        @"feed_action_btn" : @(YES),
        @"feed_action_btn_default_action" : @"none",
        @"feed_header_button" : @(NO),
        @"feed_header_button_default" : @"menu",
        @"feed_header_button_dest_gallery" : @(YES),
        @"feed_header_button_dest_analyzer" : @(YES),
        @"feed_header_button_dest_deleted" : @(YES),
        @"feed_header_button_dest_downloads" : @(YES),
        @"feed_header_button_dest_settings" : @(YES),
        @"general_action_btn_default_menu_icon" : @"action",
        @"reels_action_btn" : @(YES),
        @"reels_action_btn_default_action" : @"none",
        @"stories_action_btn" : @(YES),
        @"stories_action_btn_default_action" : @"none",
        @"stories_audio_toggle" : @(NO),
        @"msgs_action_btn" : @(YES),
        @"msgs_action_btn_chat_media" : @(NO),
        @"msgs_action_btn_default_action" : @"none",
        @"profile_action_btn" : @(YES),
        @"profile_action_btn_default_action" : @"none",
        @"feed_long_press_expand" : @(NO),
        @"feed_expanded_vid_start_muted" : @(NO),
        @"general_preview_show_metadata" : @(YES),
        @"general_preview_live_text" : @(YES),
        @"general_action_btn_show_date" : @(NO),
        @"gallery_preview_show_metadata" : @(YES),
        @"stories_allow_video_sticker" : @(NO),
        @"stories_gallery_upload_sticker" : @(NO),
        @"stories_hide_join_trending" : @(NO),
        @"stories_mentions_btn" : @(NO),
        @"stories_mentions_count_badge" : @(YES),
        @"stories_unlock_preview" : @(NO),
        @"stories_hide_ig_plus_button" : @(NO),
        @"stories_search_viewer_list" : @(NO),
        @"stories_starred_viewers" : @[],
        @"stories_hide_recent_highlights" : @(NO),
        @"stories_auto_save" : @(NO),
        @"stories_auto_save_filter_mode" : @"all",
        @"msgs_auto_save" : @(NO),
        @"msgs_unlock_preview" : @(NO),
        @"msgs_hidden_chats" : @(NO),
        @"msgs_hidden_chats_list" : @[],
        @"msgs_hidden_chats_reveal_reset" : @"leave_inbox",
        @"msgs_hidden_chats_mute_notifications" : @(YES),
        @"msgs_hidden_chats_exclude_badge" : @(YES),
        @"msgs_hidden_chats_hide_in_share_sheet" : @(YES),
        @"msgs_auto_save_filter_mode" : @"all",
        @"msgs_presence_notifications" : @(NO),
        @"msgs_presence_notify_online" : @(YES),
        @"msgs_presence_notify_offline" : @(NO),
        @"msgs_presence_notify_typing" : @(NO),
        @"msgs_presence_notify_read" : @(YES),
        @"msgs_presence_mirror_notification_center" : @(YES),
        // Unlike the auto-save surfaces, this defaults to Selected: "All Users" here
        // would notify about everyone Instagram streams presence for, not just the
        // few the user cares about.
        @"msgs_presence_filter_mode" : @"selected",
        @"msgs_presence_cooldown" : @(60),
        @"msgs_presence_accurate_status" : @(NO),
        @"msgs_presence_refresh_interval" : @(20),
        @"instants_auto_save" : @(NO),
        @"instants_auto_save_filter_mode" : @"all",
        @"downloads_autosave_destination" : @"gallery",
        @"downloads_autosave_video_quality" : @"high_ignore_dash",
        @"downloads_autosave_photo_quality" : @"high",
        @"downloads_autosave_keep_history" : @(NO),
        @"feed_disable_appicon_gesture" : @(NO),
        @"reels_tap_control" : @"default",
        @"instants_disable_creation" : @(YES),
        @"instants_confirm_capture" : @(NO),
        @"instants_disable_camera_control" : @(NO),
        @"instants_skip_camera_after_viewing" : @(NO),
        @"instants_action_btn" : @(YES),
        @"instants_action_btn_default_action" : @"none",
        @"instants_allow_screenshot" : @(NO),
        @"instants_confirm_reaction" : @(NO),
        @"instants_camera_btn" : @(YES),
        @"msgs_disable_vanish_swipe_up" : @(NO),
        @"msgs_hide_vanish_screenshot" : @(NO),
        @"reels_disable_auto_unmute" : @(NO),
        @"reels_doom_scroll_limit" : @(1),
        @"feed_disable_bg_refresh" : @(NO),
        @"general_cache_auto_clear" : @"never",
        @"downloads_enhanced_media_resolution" : @(YES),
        @"downloads_fetch_4k_images" : @(NO),
        @"downloads_detect_duplicates" : @(YES),
        @"downloads_max_concurrent" : @(2),
        @"downloads_history_limit" : @(100),
        @"downloads_photos_album_enabled" : @(NO),
        @"downloads_photos_album" : @"Sparkle",
        @"general_hide_ads_feed" : @(YES),
        @"general_hide_ads_stories" : @(YES),
        @"general_hide_ads_reels" : @(YES),
        @"general_hide_ads_explore" : @(YES),
        @"general_comments_swipe_close_direction" : @"both",
        @"general_comments_copy_text" : @(YES),
        @"general_comments_media_actions" : @(YES),
        @"general_comments_gif_title" : @(NO),
        @"general_comments_hide_shopping" : @(NO),
        @"general_comments_hide_gifts_button" : @(NO),
        @"general_comments_gallery_upload" : @(NO),
        @"general_hide_reels_shopping_cta" : @(NO),
        @"general_hide_meta_ai_msgs" : @(NO),
        @"general_hide_meta_ai_explore" : @(NO),
        @"general_hide_meta_ai_comments" : @(NO),
        @"general_hide_meta_ai_creation" : @(NO),
        @"general_hide_meta_ai_global" : @(NO),
        @"general_hide_suggested_users_feed" : @(NO),
        @"general_hide_suggested_users_reels" : @(NO),
        @"general_hide_suggested_users_msgs" : @(NO),
        @"general_hide_suggested_users_search" : @(NO),
        @"general_hide_suggested_users_profile" : @(NO),
        @"general_hide_suggested_users_activity" : @(NO),
        @"general_hide_suggested_users_follow_lists" : @(NO),
        @"general_hide_suggested_users_subscriptions" : @(NO),
        @"reels_hide_like_count" : @(NO),
        @"reels_hide_comment_count" : @(NO),
        @"reels_hide_viewer_comment_bar" : @(NO),
        @"reels_hide_repost_count" : @(NO),
        @"reels_hide_reshare_count" : @(NO),
        @"reels_hide_save_count" : @(NO),
        @"downloads_video_quality" : @"always_ask",
        @"downloads_photo_quality" : @"high",
        @"downloads_adv_encoding" : @(NO),
        @"downloads_encoding_speed" : @"medium",
        @"downloads_encoding_vid_codec" : @"videotoolbox",
        @"downloads_encoding_preset" : @"medium",
        @"downloads_encoding_h264_profile" : @"high",
        @"downloads_encoding_h264_level" : @"auto",
        @"downloads_encoding_crf" : @"",
        @"downloads_encoding_vid_bitrate_kbps" : @"",
        @"downloads_encoding_max_resolution" : @"original",
        @"downloads_encoding_audio_bitrate_kbps" : @"128",
        @"downloads_encoding_audio_channels" : @"original",
        @"downloads_encoding_pixel_format" : @"default",
        @"downloads_encoding_faststart" : @(YES),
        @"downloads_audio_enabled" : @(YES),
        @"downloads_audio_page_button" : @(YES),
        @"downloads_audio_page_default_action" : @"none",
        @"msgs_download_audio_messages" : @(NO),
        @"msgs_download_notes_audio" : @(NO),
        @"msgs_copy_note_text" : @(YES),
        @"msgs_upload_audio_messages" : @(NO),
        @"msgs_audio_upload_trim" : @(NO),
        @"msgs_upload_gallery_media" : @(NO),
        @"msgs_gif_title" : @(NO),
        @"feed_disable_home_refresh" : @(NO),
        @"reels_disable_tab_refresh" : @(NO),
        @"stories_stop_auto_advance" : @(NO),
        @"stories_advance_on_manual_seen" : @(NO),
        @"msgs_seen_on_send" : @(NO),
        @"msgs_seen_on_reply" : @(NO),
        @"msgs_seen_on_reaction" : @(NO),
        @"msgs_seen_on_typing" : @(NO),
        @"msgs_seen_button_position" : @"top",
        @"msgs_last_active_format" : @"off",
        @"feed_confirm_repost" : @(NO),
        @"reels_confirm_repost" : @(NO),
        @"feed_hide_repost_btn" : @(NO),
        @"reels_hide_repost_btn" : @(NO),
        @"stories_poll_vote_counts" : @(NO),
        @"gallery_show_favorites_top" : @(NO),
        @"gallery_flat_browsing" : @(NO),
        @"gallery_hidden_sources" : @[],
        @"gallery_filter_current_account" : @(NO),
        @"general_per_account_settings" : @(NO),
        @"trim_gallery_prompt_replace" : @(YES),
        @"general_strip_share_link_tracking" : @(YES),
        @"general_hide_create_group" : @(NO),
        @"interface_hide_ui_on_capture" : @(NO),
        @"feed_disable_autoplay" : @(NO),
    } mutableCopy];

    [defaults addEntriesFromDictionary:SPKNotificationDefaultPreferences()];

    return defaults;
}

/// One-time rename of the Instants camera-screen preference.
///
/// `instants_upload_from_gallery` shipped as its own toggle for the upload button; that
/// button and the saved-instants button are now one button with a menu, behind
/// `instants_camera_btn`. Anyone who explicitly turned the old toggle on or off gets that
/// choice carried over; everyone else takes the new default. Values are copied per
/// namespace, since per-account preferences live under `u_<pk>_<key>` and a single global
/// read would silently drop every account's setting but one.
static void SPKCoreMigrateInstantsCameraButtonPreference(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    static NSString *const migratedKey = @"instants_camera_btn_migrated";
    if ([defaults boolForKey:migratedKey])
        return;

    NSString *legacyKey = @"instants_upload_from_gallery";
    NSString *newKey = @"instants_camera_btn";
    for (NSString *key in [defaults dictionaryRepresentation].allKeys) {
        if (![key isEqualToString:legacyKey] && ![key hasSuffix:[@"_" stringByAppendingString:legacyKey]])
            continue;
        id value = [defaults objectForKey:key];
        if (value != nil) {
            NSString *target = [[key substringToIndex:key.length - legacyKey.length] stringByAppendingString:newKey];
            if ([defaults objectForKey:target] == nil)
                [defaults setObject:value forKey:target];
        }
        [defaults removeObjectForKey:key];
    }

    [defaults setBool:YES forKey:migratedKey];
}

/// One-time terminology rename for Hide Recent Searches. Copy both the global
/// value and every per-account namespace before removing the legacy key.
static void SPKCoreMigrateHideRecentSearchesPreference(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    static NSString *const migratedKey = @"general_hide_recent_searches_migrated";
    if ([defaults boolForKey:migratedKey])
        return;

    NSString *legacyKey = @"general_no_recent_searches";
    NSString *newKey = @"general_hide_recent_searches";
    for (NSString *key in [defaults dictionaryRepresentation].allKeys) {
        if (![key isEqualToString:legacyKey] && ![key hasSuffix:[@"_" stringByAppendingString:legacyKey]])
            continue;
        id value = [defaults objectForKey:key];
        if (value != nil) {
            NSString *target = [[key substringToIndex:key.length - legacyKey.length] stringByAppendingString:newKey];
            if ([defaults objectForKey:target] == nil)
                [defaults setObject:value forKey:target];
        }
        [defaults removeObjectForKey:key];
    }

    [defaults setBool:YES forKey:migratedKey];
}

void SPKCoreRegisterBootstrapDefaults(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSUserDefaults standardUserDefaults] registerDefaults:SPKBootstrapDefaults()];
        SPKMigrateTabConfigurationIfNeeded();
        SPKStartupMark(@"bootstrap defaults registered");
    });
}

void SPKCoreRegisterDefaults(void) {
    SPKCoreRegisterBootstrapDefaults();

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSUserDefaults standardUserDefaults] registerDefaults:SPKFeatureDefaults()];
        SPKCoreMigrateInstantsCameraButtonPreference();
        SPKCoreMigrateHideRecentSearchesPreference();
        SPKStartupMark(@"feature defaults registered");
    });
}

// Returns a merged snapshot of every default the tweak registers (bootstrap +
// feature). Used by the master kill switch to fall back to the registered
// default value when "Disable All Settings" is on.
NSDictionary<NSString *, id> *SPKCoreRegisteredDefaults(void) {
    static NSDictionary<NSString *, id> *snapshot;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary *merged = [NSMutableDictionary dictionary];
        [merged addEntriesFromDictionary:SPKBootstrapDefaults()];
        [merged addEntriesFromDictionary:SPKFeatureDefaults()];
        snapshot = [merged copy];
    });
    return snapshot;
}

void SPKCoreInstallLaunchCriticalHooks(void) {
    SPKCoreRegisterBootstrapDefaults();
    SPKInstallLaunchCriticalHooks();
}

void SPKCoreInstallSurfaceHooks(SPKSurface surface) {
    SPKCoreRegisterDefaults();

    switch (surface) {
    case SPKSurfaceGeneralUI:
        SPKInstallGeneralUIHooksIfNeeded();
        break;
    case SPKSurfaceFeed:
        SPKInstallFeedSurfaceHooksIfNeeded();
        break;
    case SPKSurfaceStories:
        SPKInstallStorySurfaceHooksIfNeeded();
        break;
    case SPKSurfaceReels:
        SPKInstallReelsSurfaceHooksIfNeeded();
        break;
    case SPKSurfaceMessages:
        SPKInstallMessagesSurfaceHooksIfNeeded();
        break;
    case SPKSurfaceProfile:
        SPKInstallProfileSurfaceHooksIfNeeded();
        break;
    }
}

void SPKCoreShowSettingsIfNeeded(UIWindow *window) {
    SPKCoreRegisterDefaults();
    [SPKUtils showSettingsVC:window];
}

BOOL SPKCoreOnboardingPending(void) {
    // Never stamped == never onboarded. Once stamped it stays put across version
    // bumps, so onboarding is a one-time, first-ever-run event.
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"app_first_run"] == nil;
}

BOOL SPKCoreWhatsNewPending(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // A brand-new user sees onboarding, not What's New (onboarding stamps both).
    if ([defaults objectForKey:@"app_first_run"] == nil)
        return NO;
    // Show once per version. A missing key means an upgrader who predates the
    // feature — they should see it too, so treat that as pending.
    id lastSeen = [defaults objectForKey:@"app_last_whatsnew_version"];
    return ![lastSeen isKindOfClass:[NSString class]] || ![lastSeen isEqualToString:SPKVersionString];
}
