#import "AssetUtils.h"

#import <math.h>

typedef NSDictionary<NSString *, id> SPKAssetDescriptor;

static NSString *const kSPKAssetFallbackSystemName = @"questionmark.square.dashed";

const CGFloat kSPKMenuIconPointSize = 22.0;
const CGFloat kSPKInstagramMenuIconPointSize = 24.0;

static UIImage *SPKAssetScaleImage(UIImage *image, CGFloat maxPointSize) {
    if (!image || maxPointSize <= 0) {
        return image;
    }

    CGFloat maxDimension = MAX(image.size.width, image.size.height);
    if (maxDimension <= maxPointSize + 0.01) {
        return image;
    }

    CGFloat ratio = maxPointSize / maxDimension;
    CGSize newSize = CGSizeMake(round(image.size.width * ratio), round(image.size.height * ratio));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = image.scale;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:newSize format:format];
    UIImage *scaled = [renderer imageWithActions:^(UIGraphicsImageRendererContext *_Nonnull context) {
        (void)context;
        [image drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    }];

    if (image.renderingMode != UIImageRenderingModeAutomatic) {
        scaled = [scaled imageWithRenderingMode:image.renderingMode];
    }

    return scaled;
}

static NSArray<NSNumber *> *SPKAssetCandidateSizes(CGFloat pointSize) {
    NSInteger rounded = (NSInteger)lround(MAX(pointSize, 0.0));
    NSMutableOrderedSet<NSNumber *> *sizes = [NSMutableOrderedSet orderedSet];
    if (rounded > 0) {
        [sizes addObject:@(rounded)];
    }
    for (NSNumber *value in @[ @24, @22, @20, @18, @16, @14, @12, @10, @32 ]) {
        [sizes addObject:value];
    }
    return sizes.array;
}

static NSString *SPKAssetNormalizeInternalName(NSString *name) {
    NSString *normalized = [[name ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    while ([normalized containsString:@"__"]) {
        normalized = [normalized stringByReplacingOccurrencesOfString:@"__" withString:@"_"];
    }
    return normalized;
}

static NSBundle *SPKAssetFrameworkBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks/FBSharedFramework.framework"];
        bundle = [NSBundle bundleWithPath:path];
    });
    return bundle;
}

static NSBundle *SPKAssetBundleForSource(SPKAssetCatalogSource source) {
    switch (source) {
    case SPKAssetCatalogSourceFBSharedFramework:
        return SPKAssetFrameworkBundle();
    case SPKAssetCatalogSourceMainApp:
        return [NSBundle mainBundle];
    case SPKAssetCatalogSourceAutomatic:
    default:
        return nil;
    }
}

static NSArray<NSNumber *> *SPKAssetSearchOrderForSource(SPKAssetCatalogSource requestedSource, SPKAssetCatalogSource defaultSource) {
    NSMutableOrderedSet<NSNumber *> *sources = [NSMutableOrderedSet orderedSet];
    if (requestedSource != SPKAssetCatalogSourceAutomatic) {
        [sources addObject:@(requestedSource)];
    } else {
        [sources addObject:@(defaultSource)];
    }
    [sources addObject:@(SPKAssetCatalogSourceFBSharedFramework)];
    [sources addObject:@(SPKAssetCatalogSourceMainApp)];
    return sources.array;
}

static NSDictionary<NSString *, SPKAssetDescriptor *> *SPKAssetOverrides(void) {
    static NSDictionary<NSString *, SPKAssetDescriptor *> *overrides;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overrides = @{
            @"action" : @{@"candidates" : @[ @"ig_icon_stars_pano_outline_24", @"ig_icon_stars_outline_24", @"ig_icon_flash_outline_24", @"ig_icon_flash_outline_20" ]},
            @"activity" : @{@"candidates" : @[ @"ig_icon_channels_broadcast_outline_24"]},
            @"activity_filled" : @{@"candidates" : @[ @"ig_icon_channels_broadcast_filled_24"]},
            @"ads" : @{@"candidates" : @[ @"ig_icon_ads_prism_outline_24", @"ig_icon_ads_outline_24", @"ig_icon_ad_outline_24" ]},
            @"app" : @{@"candidates" : @[ @"ig_icon_app_instagram_pano_outline_24", @"ig_icon_app_instagram_outline_24" ]},
            @"arrow_up" : @{@"candidates" : @[ @"ig_icon_arrow_up_outline_24" ]},
            @"arrow_up_right" : @{@"candidates" : @[ @"ig_icon_arrow_up_right_outline_24" ]},
            @"arrow_down" : @{@"candidates" : @[ @"ig_icon_arrow_down_outline_24" ]},
            @"arrow_left" : @{@"candidates" : @[ @"ig_icon_arrow_left_outline_24" ]},
            @"arrow_right" : @{@"candidates" : @[ @"ig_icon_arrow_right_outline_24" ]},
            @"arrow_cw" : @{@"candidates" : @[ @"ig_icon_arrow_cw_outline_24" ]},
            @"arrow_ccw" : @{@"candidates" : @[ @"ig_icon_arrow_ccw_outline_24" ]},
            @"audio" : @{@"candidates" : @[ @"ig_icon_audio_wave_outline_24" ]},
            @"audio_filled" : @{@"candidates" : @[ @"ig_icon_audio_wave_filled_16" ]},
            @"audio_download" : @{@"candidates" : @[ @"ig_icon_music_import_outline_24" ]},
            @"audio_page" : @{@"candidates" : @[ @"ig_icon_audio_page_prism_outline_24", @"ig_icon_audio_page_outline_24" ]},
            @"audio_upload" : @{@"candidates" : @[ @"ig_icon_audio_extract_outline_24" ]},
            @"aura" : @{@"candidates" : @[ @"ig_icon_aura_outline_24", @"ig_icon_circle_add_outline_24" ]},
            @"autoplay_off" : @{@"candidates" : @[ @"ig_icon_auto_play_off_outline_24" ]},
            @"autoscroll" : @{@"candidates" : @[ @"ig_icon_auto_scroll_outline_24" ]},
            @"backspace" : @{@"candidates" : @[ @"ig_icon_backspace_outline_24" ]},
            @"beaker" : @{@"candidates" : @[ @"ig_icon_beaker_outline_24" ]},
            @"blend" : @{@"candidates" : @[ @"ig_icon_blend_outline_24" ]},
            @"calendar" : @{@"candidates" : @[ @"ig_icon_calendar_outline_24" ]},
            @"call" : @{@"candidates" : @[ @"ig_icon_call_outline_24" ]},
            @"caption" : @{@"candidates" : @[ @"ig_icon_community_notes_outline_24" ]},
            @"carousel" : @{@"candidates" : @[ @"ig_icon_carousel_prism_outline_24", @"ig_icon_carousel_outline_24" ]},
            @"carousel_filled" : @{@"candidates" : @[ @"ig_icon_carousel_prism_filled_12", @"ig_icon_carousel_filled_12" ]},
            @"check" : @{@"candidates" : @[ @"ig_icon_check_outline_24" ]},
            @"chevron_left" : @{@"candidates" : @[ @"ig_icon_chevron_left_outline_24" ]},
            @"chevron_right" : @{@"candidates" : @[ @"ig_icon_chevron_right_filled_16", @"ig_icon_chevron_right_outline_16", @"ig_icon_chevron_right_filled_12", @"ig_icon_chevron_right_outline_12", @"ig_icon_chevron_right_filled_24", @"ig_icon_chevron_right_outline_24", @"ig_icon_chevron_right_filled_8", @"ig_icon_chevron_right_outline_8", @"ig_icon_chevron_right_filled_6", @"ig_icon_chevron_right_outline_6", @"ig_icon_chevron_right_filled_2", @"ig_icon_chevron_right_outline_2", @"ig_icon_chevron_right_filled_44", @"ig_icon_chevron_right_outline_44" ]},
            @"chest" : @{@"candidates" : @[ @"ig_icon_chest_outline_24" ]},
            @"circle" : @{@"candidates" : @[ @"ig_icon_circle_outline_24" ]},
            @"circle_off" : @{@"candidates" : @[ @"ig_icon_circle_block_pano_outline_24", @"ig_icon_circle_block_outline_24" ]},
            @"circle_check" : @{@"candidates" : @[ @"ig_icon_circle_check_outline_24" ]},
            @"circle_check_filled" : @{@"candidates" : @[ @"ig_icon_circle_check_pano_filled_24", @"ig_icon_circle_check_filled_24" ]},
            @"circle_xmark" : @{@"candidates" : @[ @"ig_icon_circle_x_pano_outline_24", @"ig_icon_circle_x_outline_24" ]},
            @"circle_xmark_filled" : @{@"candidates" : @[ @"ig_icon_circle_x_pano_filled_24", @"ig_icon_circle_x_filled_24" ]},
            @"clock" : @{@"candidates" : @[ @"ig_icon_clock_pano_outline_24", @"ig_icon_clock_outline_24" ]},
            @"clock_filled" : @{@"candidates" : @[ @"ig_icon_clock_filled_24" ]},
            @"close" : @{@"candidates" : @[ @"ig_icon_x_pano_outline_24", @"ig_icon_x_outline_24" ]},
            @"cloud" : @{@"candidates" : @[ @"ig_icon_app_icloud_outline_24" ]},
            @"comment" : @{@"candidates" : @[ @"ig_icon_comment_pano_outline_24", @"ig_icon_comment_outline_24" ]},
            @"comment_filled" : @{@"candidates" : @[ @"ig_icon_comment_filled_24" ]},
            @"compass" : @{@"candidates" : @[ @"ig_icon_compass_outline_24" ]},
            @"copy" : @{@"candidates" : @[ @"ig_icon_copy_prism_outline_24", @"ig_icon_copy_outline_24" ]},
            @"copy_filled" : @{@"candidates" : @[ @"ig_icon_copy_prism_filled_24", @"ig_icon_copy_filled_24" ]},
            @"crop" : @{@"candidates" : @[ @"ig_icon_crop_outline_24" ]},
            @"donate" : @{@"candidates" : @[ @"ig_icon_donations_outline_44" ]},
            @"download" : @{@"candidates" : @[ @"ig_icon_download_outline_24" ]},
            @"download_filled" : @{@"candidates" : @[ @"ig_icon_download_filled_24" ]},
            @"download_off" : @{@"candidates" : @[ @"ig_icon_download_off_outline_24" ]},
            @"download_reels" : @{@"candidates" : @[ @"ig_icon_download_outline_44" ]},
            @"duplicate" : @{@"candidates" : @[ @"ig_icon_photo_dump_outline_24" ]},
            @"edit" : @{@"candidates" : @[ @"ig_icon_edit_outline_24" ]},
            @"empty" : @{@"candidates" : @[ @"ig_icon_circle_x_outline_96" ]},
            @"error" : @{@"candidates" : @[ @"ig_icon_error_outline_24" ]},
            @"error_filled" : @{@"candidates" : @[ @"ig_icon_error_filled_24" ]},
            @"expand" : @{@"candidates" : @[ @"ig_icon_fit_outline_24" ]},
            @"expand_reels" : @{@"candidates" : @[ @"ig_icon_fit_outline_44" ]},
            @"explore_grid" : @{@"candidates" : @[ @"ig_icon_photo_grid_outline_24" ]},
            @"external_link" : @{@"candidates" : @[ @"ig_icon_external_link_outline_24" ]},
            @"eye" : @{@"candidates" : @[ @"ig_icon_eye_outline_24" ]},
            @"eye_off" : @{@"candidates" : @[ @"ig_icon_eye_off_outline_24" ]},
            @"eyedropper" : @{@"candidates" : @[ @"ig_icon_eyedropper_outline_24" ]},
            @"face_happy" : @{@"candidates" : @[ @"ig_icon_face2_outline_24" ]},
            @"face_sad" : @{@"candidates" : @[ @"ig_icon_face4_outline_24" ]},
            @"flag" : @{@"candidates" : @[ @"ig_icon_flag_outline_24" ]},
            @"feed" : @{@"candidates" : @[ @"ig_icon_feeds_outline_24", @"ig_icon_photo_list_outline_24" ]},
            @"feed_filled" : @{@"candidates" : @[ @"ig_icon_feeds_filled_24" ]},
            @"filter" : @{@"candidates" : @[ @"ig_icon_align_center_outline_24", @"ig_icon_sliders_pano_outline_24", @"ig_icon_sliders_outline_24" ]},
            @"folder" : @{@"candidates" : @[ @"ig_icon_folder_prism_outline_24", @"ig_icon_folder_outline_24" ]},
            @"folder_move" : @{@"candidates" : @[ @"ig_icon_folder_arrow_right_prism_outline_24", @"ig_icon_folder_arrow_right_outline_24" ]},
            @"gif" : @{@"candidates" : @[ @"ig_icon_gif_outline_24" ]},
            @"gif_filled" : @{@"candidates" : @[ @"ig_icon_gif_filled_24" ]},
            @"gift" : @{@"candidates" : @[ @"ig_icon_gift_box_prism_outline_24", @"ig_icon_gift_box_outline_24" ]},
            @"grid" : @{@"candidates" : @[ @"ig_icon_collections_outline_24" ]},
            @"group" : @{@"candidates" : @[ @"ig_icon_group_outline_24" ]},
            @"haptics" : @{@"candidates" : @[ @"ig_icon_audio_crunchy_outline_24" ]},
            @"hd" : @{@"candidates" : @[ @"ig_icon_hd_outline_24" ]},
            @"hd_check_filled" : @{@"candidates" : @[ @"ig_icon_hd_check_filled_24" ]},
            @"heart" : @{@"candidates" : @[ @"ig_icon_heart_pano_outline_24", @"ig_icon_heart_outline_24" ]},
            @"heart_filled" : @{@"candidates" : @[ @"ig_icon_heart_filled_24" ]},
            @"highlights" : @{@"candidates" : @[ @"ig_icon_story_highlight_pano_outline_24", @"ig_icon_story_highlight_outline_24" ]},
            @"history" : @{@"candidates" : @[ @"ig_icon_history_pano_outline_24", @"ig_icon_history_outline_24" ]},
            @"home" : @{@"candidates" : @[ @"ig_icon_home_pano_prism_outline_24", @"ig_icon_home_prism_outline_24", @"ig_icon_home_pano_outline_24", @"ig_icon_home_outline_24" ]},
            @"info" : @{@"candidates" : @[ @"ig_icon_info_pano_outline_24", @"ig_icon_info_outline_24" ]},
            @"info_filled" : @{@"candidates" : @[ @"ig_icon_info_filled_16" ]},
            @"interface" : @{@"candidates" : @[ @"ig_icon_device_phone_prism_outline_24", @"ig_icon_device_phone_pano_outline_24", @"ig_icon_device_phone_outline_24" ]},
            @"instants" : @{@"candidates" : @[ @"ig_icon_app_instants_outline_24" ]},
            @"instants_burst" : @{@"candidates" : @[ @"ig_icon_app_instants_burst_filled_24" ]},
            @"key" : @{@"candidates" : @[ @"ig_icon_key_outline_24" ]},
            @"keyboard" : @{@"candidates" : @[ @"ig_icon_keyboard_prism_outline_24", @"ig_icon_keyboard_outline_24" ]},
            @"left_right" : @{@"candidates" : @[ @"ig_icon_replace_outline_24", @"ig_icon_replace_2_outline_24" ]},
            @"link" : @{@"candidates" : @[ @"ig_icon_link_outline_24" ]},
            @"link_reels" : @{@"candidates" : @[ @"ig_icon_link_outline_44" ]},
            @"list" : @{@"candidates" : @[ @"ig_icon_edit_list_outline_24" ]},
            @"lock" : @{@"candidates" : @[ @"ig_icon_lock_prism_outline_24", @"ig_icon_lock_outline_24" ]},
            @"lock_filled" : @{@"candidates" : @[ @"ig_icon_lock_prism_filled_24", @"ig_icon_lock_filled_24" ]},
            @"logs" : @{@"candidates" : @[ @"ig_icon_document_lined_prism_outline_24", @"ig_icon_document_lined_outline_24" ]},
            @"map" : @{@"candidates" : @[ @"ig_icon_map_outline_24", @"ig_icon_location_map_outline_24" ]},
            @"media" : @{@"candidates" : @[ @"ig_icon_collage_prism_outline_24", @"ig_icon_collage_outline_24", @"ig_icon_media_prism_outline_24", @"ig_icon_media_outline_24" ]},
            @"media_empty" : @{@"candidates" : @[ @"ig_icon_media_outline_96" ]},
            @"mention" : @{@"candidates" : @[ @"ig_icon_story_mention_pano_outline_24" ]},
            @"message" : @{@"candidates" : @[ @"ig_icon_app_whatsapp_chat_prism_outline_24", @"ig_icon_app_whatsapp_chat_outline_24" ]},
            @"messages" : @{@"candidates" : @[ @"ig_icon_direct_prism_outline_24", @"ig_icon_direct_outline_24" ]},
            @"messages_empty" : @{@"candidates" : @[ @"ig_icon_channels_outline_96" ]},
            @"messages_filled" : @{@"candidates" : @[ @"ig_icon_direct_prism_filled_24", @"ig_icon_direct_filled_24" ]},
            @"messages_off" : @{@"candidates" : @[ @"ig_icon_direct_off_prism_outline_24", @"ig_icon_direct_off_outline_24" ]},
            @"mirror" : @{@"candidates" : @[ @"ig_icon_mirror_outline_24" ]},
            @"music_reels" : @{@"candidates" : @[ @"ig_icon_music_outline_44" ]},
            @"meta_ai" : @{@"candidates" : @[ @"ig_icon_meta_ai_orbit_7_segment_outline_24", @"ig_icon_meta_gen_ai_outline_24" ]},
            @"more" : @{@"candidates" : @[ @"ig_icon_more_horizontal_outline_24" ]},
            @"notes" : @{@"candidates" : @[ @"ig_icon_content_note_outline_24", @"ig_icon_content_note_add_outline_24" ]},
            @"notification" : @{@"candidates" : @[ @"ig_icon_alert_pano_outline_24", @"ig_icon_alert_outline_24" ]},
            @"notification_off" : @{@"candidates" : @[ @"ig_icon_alert_off_pano_outline_24", @"ig_icon_alert_off_outline_24" ]},
            @"notifications" : @{@"candidates" : @[ @"bells-stacked_Outline_24" ]},
            @"palette" : @{@"candidates" : @[ @"ig_icon_palette_outline_24" ]},
            @"parallel" : @{@"candidates" : @[ @"ig_icon_pause_filled_24" ]},
            @"pause" : @{@"candidates" : @[ @"ig_icon_pause_filled_24" ]},
            @"photo" : @{@"candidates" : @[ @"ig_icon_photo_outline_24" ]},
            @"photo_filled" : @{@"candidates" : @[ @"ig_icon_photo_filled_24" ]},
            @"photo_reels" : @{@"candidates" : @[ @"ig_icon_photo_outline_44" ]},
            @"photo_gallery" : @{@"candidates" : @[ @"ig_icon_photo_gallery_outline_24" ]},
            @"pin" : @{@"candidates" : @[ @"ig_icon_pin_outline_24" ]},
            @"pin_filled" : @{@"candidates" : @[ @"ig_icon_pin_filled_24" ]},
            @"pinch" : @{@"candidates" : @[ @"ig_icon_fill_outline_24" ]},
            @"play" : @{@"candidates" : @[ @"ig_icon_play_prism_outline_24", @"ig_icon_play_outline_24" ]},
            @"play_filled" : @{@"candidates" : @[ @"ig_icon_play_prism_filled_24", @"ig_icon_play_filled_24" ]},
            @"play_filled_32" : @{@"candidates" : @[ @"ig_icon_play_prism_filled_32", @"ig_icon_play_filled_32" ]},
            @"plus" : @{@"candidates" : @[ @"ig_icon_add_pano_outline_24", @"ig_icon_add_outline_24" ]},
            @"poll" : @{@"candidates" : @[ @"ig_icon_poll_outline_24" ]},
            @"profile_analyzer" : @{@"candidates" : @[ @"ig_icon_trending_up_bars_outline_24", @"ig_icon_reach_outline_24" ]},
            @"promote_empty" : @{@"candidates" : @[ @"ig_icon_promote_outline_96" ]},
            @"question" : @{@"candidates" : @[ @"ig_icon_questions_outline_24" ]},
            @"reactions" : @{@"candidates" : @[ @"ig_icon_reactions_outline_24" ]},
            @"reels" : @{@"candidates" : @[ @"ig_icon_reels_pano_prism_outline_24", @"ig_icon_reels_prism_outline_24", @"ig_icon_reels_pano_outline_24", @"ig_icon_reels_outline_24" ]},
            @"reels_filled" : @{@"candidates" : @[ @"ig_icon_reels_pano_prism_filled_24", @"ig_icon_reels_prism_filled_24", @"ig_icon_reels_filled_24", @"ig_icon_reels_filled_24" ]},
            @"reels_gallery" : @{
                @"candidates" : @[ @"ig_icon_reels_gallery_outline_24" ],
                @"alias" : @"reels"
            },
            @"reply" : @{@"candidates" : @[ @"ig_icon_reply_outline_24" ]},
            @"repost" : @{@"candidates" : @[ @"ig_icon_reshare_pano_outline_24", @"ig_icon_reshare_outline_24" ]},
            @"repost_reels" : @{@"candidates" : @[ @"reshare-unshadowed_outline_44" ]},
            // Modern IG uses the bend arrow (flipped into the two directions in
            // SPKPhotoEditor); IG 410 lacks it, so fall back to the older filled
            // bend arrow — which points the right way already and only needs the
            // horizontal flip for "left" (no vertical flip). See SPKPhotoEditor.
            @"rotate_left" : @{@"candidates" : @[ @"ig_icon_arrow_bottom_right_bend_outline_24", @"ig_icon_arrow_right_bend_filled_24" ]},
            @"rotate_right" : @{@"candidates" : @[ @"ig_icon_arrow_bottom_right_bend_outline_24", @"ig_icon_arrow_right_bend_filled_24" ]},
            @"save" : @{@"candidates" : @[ @"ig_icon_save_prism_outline_24", @"ig_icon_save_pano_outline_24", @"ig_icon_save_outline_24" ]},
            @"save_filled" : @{@"candidates" : @[ @"ig_icon_save_prism_filled_24", @"ig_icon_save_pano_filled_24", @"ig_icon_save_filled_24" ]},
            @"search" : @{@"candidates" : @[ @"ig_icon_search_pano_outline_24", @"ig_icon_search_outline_24" ]},
            @"settings" : @{@"candidates" : @[ @"ig_icon_settings_pano_outline_24", @"ig_icon_settings_outline_24" ]},
            @"hamburger": @{@"candidates": @[ @"ig_icon_menu_outline_24" ]},
            @"settings_reels" : @{@"candidates" : @[ @"ig_icon_settings_outline_44" ]},
            @"share" : @{@"candidates" : @[ @"ig_icon_share_pano_outline_24" ]},
            @"share_reels" : @{@"candidates" : @[ @"ig_icon_share_outline_44" ]},
            @"shares" : @{@"candidates" : @[ @"ig_icon_direct_prism_outline_16" ]},
            @"shares_filled" : @{@"candidates" : @[ @"ig_icon_direct_prism_filled_16" ]},
            @"shopping_bag" : @{@"candidates" : @[ @"ig_icon_shopping_bag_pano_outline_24", @"ig_icon_shopping_bag_outline_24" ]},
            @"shopping_cart" : @{@"candidates" : @[ @"ig_icon_shopping_cart_pano_outline_24", @"ig_icon_shopping_cart_outline_24" ]},
            @"size_large" : @{@"candidates" : @[ @"ig_icon_fit_outline_24" ]},
            @"size_small" : @{@"candidates" : @[ @"ig_icon_fill_outline_24" ]},
            @"slider" : @{@"candidates" : @[ @"ig_icon_sliders_pano_outline_24", @"ig_icon_sliders_outline_24" ]},
            @"sort" : @{@"candidates" : @[ @"ig_icon_sort_pano_outline_24" ]},
            @"subtract" : @{@"candidates" : @[ @"ig_icon_subtract_outline_24" ]},
            @"sparkle_gallery" : @{@"candidates" : @[ @"ig_icon_effect_page_prism_outline_24", @"ig_icon_effect_page_outline_24" ]},
            @"sticker" : @{@"candidates" : @[ @"ig_icon_sticker_prism_outline_24", @"ig_icon_sticker_pano_outline_24" ]},
            @"sticker_filled" : @{@"candidates" : @[ @"ig_icon_sticker_prism_filled_24", @"ig_icon_sticker_pano_filled_24" ]},
            @"story" : @{@"candidates" : @[ @"ig_icon_story_pano_outline_24", @"ig_icon_story_outline_24" ]},
            @"story_filled" : @{@"candidates" : @[ @"ig_icon_story_pano_filled_24", @"ig_icon_story_filled_24" ]},
            @"story_preview": @{@"candidates" : @[ @"eye-off_Outline_24" ]},
            @"star" : @{@"candidates" : @[ @"ig_icon_star_pano_outline_24", @"ig_icon_star_outline_24" ]},
            @"star_filled" : @{@"candidates" : @[ @"ig_icon_star_pano_filled_24", @"ig_icon_star_filled_24" ]},
            @"text" : @{@"candidates" : @[ @"ig_icon_text_outline_24" ]},
            @"threads" : @{@"candidates" : @[ @"ig_icon_app_threads_pano_outline_24", @"ig_icon_app_threads_outline_24" ]},
            @"toolbox" : @{@"candidates" : @[ @"ig_icon_toolbox_outline_24" ]},
            @"translate" : @{@"candidates" : @[ @"ig_icon_translate_prism_outline_24", @"ig_icon_translate_pano_outline_24" ]},
            @"trash" : @{@"candidates" : @[ @"ig_icon_delete_outline_24" ]},
            @"trim" : @{@"candidates" : @[ @"ig_icon_app_edits_outline_24", @"ig_icon_edit_outline_24" ]},
            @"trash_filled" : @{@"candidates" : @[ @"ig_icon_delete_filled_24" ]},
            @"trending" : @{@"candidates" : @[ @"ig_icon_trending_up_outline_24" ]},
            @"undo_circle" : @{@"candidates" : @[ @"ig_icon_undo_circle_outline_24" ]},
            @"undo_filled" : @{@"candidates" : @[ @"ig_icon_undo_filled_16" ]},
            @"unlock" : @{@"candidates" : @[ @"ig_icon_unlock_prism_outline_24", @"ig_icon_unlock_outline_24" ]},
            @"unlock_filled" : @{@"candidates" : @[ @"ig_icon_unlock_prism_filled_24", @"ig_icon_unlock_filled_24" ]},
            @"user" : @{@"candidates" : @[ @"ig_icon_user_prism_outline_24", @"ig_icon_user_outline_24" ]},
            @"user_check" : @{@"candidates" : @[ @"ig_icon_user_following_prism_outline_24", @"ig_icon_user_following_outline_24" ]},
            @"user_circle" : @{@"candidates" : @[ @"ig_icon_user_circle_pano_prism_outline_24", @"ig_icon_user_circle_prism_outline_24", @"ig_icon_user_circle_pano_outline_24", @"ig_icon_user_circle_outline_24" ]},
            @"user_circle_filled" : @{@"candidates" : @[ @"ig_icon_user_circle_prism_filled_24", @"ig_icon_user_circle_filled_24" ]},
            @"user_follow" : @{@"candidates" : @[ @"ig_icon_user_follow_prism_outline_24", @"ig_icon_user_follow_outline_24" ]},
            @"user_following" : @{@"candidates" : @[ @"ig_icon_user_following_prism_outline_24", @"ig_icon_user_following_outline_24" ]},
            @"user_request" : @{@"candidates" : @[ @"ig_icon_user_requested_prism_outline_24", @"ig_icon_user_requested_outline_24" ]},
            @"user_unfollow" : @{@"candidates" : @[ @"ig_icon_user_unfollow_prism_outline_24", @"ig_icon_user_unfollow_outline_24" ]},
            @"username" : @{@"candidates" : @[ @"ig_icon_user_nickname_prism_outline_24", @"ig_icon_user_nickname_outline_24" ]},
            @"users_empty": @{@"candidates" : @[ @"ig_icon_users_prism_outline_96", @"ig_icon_users_outline_96" ]},
            @"users" : @{@"candidates" : @[ @"ig_icon_users_prism_outline_24", @"ig_icon_users_prism_outline_24" ]},
            @"vanish" : @{@"candidates" : @[ @"ig_icon_vanish_mode_outline_24", @"ig_icon_clock_dotted_pano_outline_24", @"ig_icon_clock_dotted_outline_24" ]},
            @"verified" : @{@"candidates" : @[ @"ig_icon_verified_filled_12", @"ig_icon_verified_filled_16", @"ig_icon_verified_outline_16" ]},
            @"video" : @{@"candidates" : @[ @"ig_icon_video_chat_pano_outline_24", @"ig_icon_video_chat_outline_24" ]},
            @"video_play" : @{@"candidates" : @[ @"video-play-small", @"ig_icon_play_prism_outline_24", @"ig_icon_play_outline_24" ]},
            @"video_pause" : @{@"candidates" : @[ @"video-pause", @"ig_icon_pause_filled_24" ]},
            @"video_filled" : @{@"candidates" : @[ @"ig_icon_video_chat_pano_filled_24" ]},
            @"view_once" : @{@"candidates" : @[ @"ig_icon_view_once_pano_outline_24", @"ig_icon_view_once_outline_24" ]},
            @"view_twice" : @{@"candidates" : @[ @"ig_icon_view_twice_outline_24" ]},
            @"voice" : @{@"candidates" : @[ @"ig_icon_microphone_pano_outline_24", @"ig_icon_microphone_outline_24" ]},
            @"voice_filled" : @{@"candidates" : @[ @"ig_icon_microphone_filled_24" ]},
            @"volume" : @{@"candidates" : @[ @"ig_icon_volume_pano_outline_24", @"ig_icon_volume_outline_24" ]},
            @"volume_none" : @{@"candidates" : @[ @"ig_icon_volume_none_pano_outline_24" ]},
            @"volume_off" : @{@"candidates" : @[ @"ig_icon_volume_off_pano_outline_24", @"ig_icon_volume_off_outline_24" ]},
            @"warning" : @{@"candidates" : @[ @"ig_icon_warning_pano_outline_24", @"ig_icon_warning_outline_24" ]},
            @"warning_filled" : @{@"candidates" : @[ @"ig_icon_warning_pano_filled_24", @"ig_icon_warning_filled_24" ]},
            @"web" : @{@"candidates" : @[ @"globe_Outline_24", @"globe_outline_24" ]},
            @"xmark" : @{@"candidates" : @[ @"ig_icon_x_pano_outline_24" ]},
            @"zoom" : @{@"candidates" : @[ @"ig_icon_fullscreen_outline_24" ]}
        };
    });
    return overrides;
}

static SPKAssetDescriptor *SPKAssetResolvedDescriptor(NSString *name) {
    SPKAssetDescriptor *descriptor = SPKAssetOverrides()[name];
    if (!descriptor)
        return nil;
    NSString *alias = descriptor[@"alias"];
    if (alias.length > 0) {
        SPKAssetDescriptor *aliasDescriptor = SPKAssetOverrides()[alias];
        if (aliasDescriptor) {
            NSMutableDictionary *merged = [aliasDescriptor mutableCopy];
            for (NSString *key in descriptor) {
                if ([key isEqualToString:@"candidates"]) {
                    NSMutableOrderedSet *mergedCandidates = [NSMutableOrderedSet orderedSetWithArray:descriptor[@"candidates"]];
                    [mergedCandidates addObjectsFromArray:aliasDescriptor[@"candidates"] ?: @[]];
                    merged[@"candidates"] = mergedCandidates.array;
                } else {
                    merged[key] = descriptor[key];
                }
            }
            return merged;
        }
    }
    return descriptor;
}

static CGFloat SPKAssetResolvedPointSize(NSString *name, CGFloat pointSize) {
    if (pointSize <= 0) {
        return pointSize;
    }

    SPKAssetDescriptor *descriptor = SPKAssetResolvedDescriptor(SPKAssetNormalizeInternalName(name));
    NSDictionary *sizeMap = descriptor[@"size_map"];
    if (![sizeMap isKindOfClass:[NSDictionary class]]) {
        return pointSize;
    }

    NSNumber *mapped = sizeMap[[NSString stringWithFormat:@"%ld", (long)lround(pointSize)]];
    if ([mapped isKindOfClass:[NSNumber class]] && mapped.doubleValue > 0) {
        return mapped.doubleValue;
    }

    return pointSize;
}

static NSArray<NSString *> *SPKAssetHeuristicCandidates(NSString *name, CGFloat pointSize) {
    NSString *normalized = SPKAssetNormalizeInternalName(name);
    if (normalized.length == 0) {
        return @[];
    }

    if ([normalized hasPrefix:@"ig_icon_"]) {
        return @[ normalized ];
    }

    NSString *baseName = normalized;
    NSString *variant = nil;
    if ([baseName hasSuffix:@"_filled"]) {
        baseName = [baseName substringToIndex:baseName.length - @"_filled".length];
        variant = @"filled";
    } else if ([baseName hasSuffix:@"_outline"]) {
        baseName = [baseName substringToIndex:baseName.length - @"_outline".length];
        variant = @"outline";
    }

    NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSet];
    [candidates addObject:normalized];
    [candidates addObject:[NSString stringWithFormat:@"ig_icon_%@", normalized]];

    for (NSNumber *sizeValue in SPKAssetCandidateSizes(pointSize)) {
        NSInteger size = sizeValue.integerValue;
        if (variant.length > 0) {
            [candidates addObject:[NSString stringWithFormat:@"ig_icon_%@_%@_%ld", baseName, variant, (long)size]];
            [candidates addObject:[NSString stringWithFormat:@"ig_icon_%@_%ld", baseName, (long)size]];
        } else {
            [candidates addObject:[NSString stringWithFormat:@"ig_icon_%@_%ld", baseName, (long)size]];
            [candidates addObject:[NSString stringWithFormat:@"ig_icon_%@_outline_%ld", baseName, (long)size]];
            [candidates addObject:[NSString stringWithFormat:@"ig_icon_%@_filled_%ld", baseName, (long)size]];
        }
    }

    return candidates.array;
}

static NSArray<NSString *> *SPKAssetCandidatesForInternalName(NSString *name, CGFloat pointSize) {
    NSString *normalized = SPKAssetNormalizeInternalName(name);
    SPKAssetDescriptor *descriptor = SPKAssetResolvedDescriptor(normalized);
    NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSet];

    NSArray<NSString *> *explicitCandidates = descriptor[@"candidates"];
    if ([explicitCandidates isKindOfClass:[NSArray class]]) {
        [candidates addObjectsFromArray:explicitCandidates];
    }
    [candidates addObjectsFromArray:SPKAssetHeuristicCandidates(normalized, pointSize)];
    return candidates.array;
}

static SPKAssetCatalogSource SPKAssetDefaultSourceForInternalName(NSString *name) {
    SPKAssetDescriptor *descriptor = SPKAssetResolvedDescriptor(SPKAssetNormalizeInternalName(name));
    NSNumber *sourceValue = descriptor[@"source"];
    if ([sourceValue isKindOfClass:[NSNumber class]]) {
        return (SPKAssetCatalogSource)sourceValue.integerValue;
    }
    return SPKAssetCatalogSourceFBSharedFramework;
}

static UIImage *SPKAssetApplyRenderingMode(UIImage *image, UIImageRenderingMode renderingMode) {
    if (!image || renderingMode == UIImageRenderingModeAutomatic) {
        return image;
    }
    return [image imageWithRenderingMode:renderingMode];
}

static UIImage *SPKAssetFallbackImage(CGFloat pointSize, UIImageRenderingMode renderingMode) {
    UIImageConfiguration *configuration = nil;
    if (pointSize > 0) {
        configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize];
    }

    UIImage *image = configuration
                         ? [UIImage systemImageNamed:kSPKAssetFallbackSystemName withConfiguration:configuration]
                         : [UIImage systemImageNamed:kSPKAssetFallbackSystemName];
    return SPKAssetApplyRenderingMode(image, renderingMode);
}

static UIImage *SPKAssetSystemSymbolImage(NSString *name, CGFloat pointSize, UIImageSymbolWeight weight, UIImageRenderingMode renderingMode) {
    if (name.length == 0) {
        return nil;
    }

    UIImageConfiguration *configuration = nil;
    if (pointSize > 0) {
        configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:weight];
    } else if (weight != UIImageSymbolWeightUnspecified) {
        configuration = [UIImageSymbolConfiguration configurationWithWeight:weight];
    }

    UIImage *image = configuration
                         ? [UIImage systemImageNamed:name withConfiguration:configuration]
                         : [UIImage systemImageNamed:name];
    return SPKAssetApplyRenderingMode(image, renderingMode);
}

static BOOL SPKAssetHasExplicitOverride(NSString *name) {
    return SPKAssetResolvedDescriptor(SPKAssetNormalizeInternalName(name)) != nil;
}

static NSCache<NSString *, id> *SPKAssetIconNameCache(void) {
    static NSCache<NSString *, id> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 512;
    });
    return cache;
}

static NSString *SPKAssetResolvedIconCandidateName(NSString *name, CGFloat pointSize, SPKAssetCatalogSource source) {
    NSString *normalizedName = SPKAssetNormalizeInternalName(name);
    if (normalizedName.length == 0) {
        return nil;
    }

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%.2f|%ld", normalizedName, pointSize, (long)source];
    id cachedName = [SPKAssetIconNameCache() objectForKey:cacheKey];
    if (cachedName) {
        return cachedName == [NSNull null] ? nil : cachedName;
    }

    CGFloat resolvedPointSize = SPKAssetResolvedPointSize(normalizedName, pointSize);
    SPKAssetCatalogSource defaultSource = SPKAssetDefaultSourceForInternalName(normalizedName);
    NSArray<NSNumber *> *sourceOrder = SPKAssetSearchOrderForSource(source, defaultSource);
    NSArray<NSString *> *candidates = SPKAssetCandidatesForInternalName(normalizedName, resolvedPointSize);

    for (NSNumber *sourceValue in sourceOrder) {
        NSBundle *bundle = SPKAssetBundleForSource((SPKAssetCatalogSource)sourceValue.integerValue);
        if (!bundle) {
            continue;
        }

        for (NSString *candidate in candidates) {
            UIImage *image = [UIImage imageNamed:candidate inBundle:bundle compatibleWithTraitCollection:nil];
            if (image) {
                [SPKAssetIconNameCache() setObject:candidate forKey:cacheKey];
                return candidate;
            }
        }
    }

    [SPKAssetIconNameCache() setObject:[NSNull null] forKey:cacheKey];
    return nil;
}

// Resolving an icon walks every candidate name across every candidate bundle and
// then redraws the hit through UIGraphicsImageRenderer to scale it. That is far
// too expensive to repeat per call site: collection view cells reconfigure their
// badges on every dequeue, so an uncached lookup turns into a full off-screen
// render pass per cell while scrolling. Results are pure functions of the four
// lookup inputs, so memoize them (misses included, so a miss does not rescan).
static NSCache<NSString *, id> *SPKAssetIconCache(void) {
    static NSCache<NSString *, id> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 512;
    });
    return cache;
}

static UIImage *SPKAssetLookupInstagramIcon(NSString *name, CGFloat pointSize, SPKAssetCatalogSource source, UIImageRenderingMode renderingMode) {
    NSString *normalizedName = SPKAssetNormalizeInternalName(name);
    if (normalizedName.length == 0) {
        return nil;
    }

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%.2f|%ld|%ld",
                                                    normalizedName, pointSize, (long)source, (long)renderingMode];
    id cached = [SPKAssetIconCache() objectForKey:cacheKey];
    if (cached) {
        return cached == [NSNull null] ? nil : cached;
    }

    CGFloat resolvedPointSize = SPKAssetResolvedPointSize(normalizedName, pointSize);
    SPKAssetCatalogSource defaultSource = SPKAssetDefaultSourceForInternalName(normalizedName);
    NSArray<NSNumber *> *sourceOrder = SPKAssetSearchOrderForSource(source, defaultSource);
    NSArray<NSString *> *candidates = SPKAssetCandidatesForInternalName(normalizedName, resolvedPointSize);

    for (NSNumber *sourceValue in sourceOrder) {
        NSBundle *bundle = SPKAssetBundleForSource((SPKAssetCatalogSource)sourceValue.integerValue);
        if (!bundle) {
            continue;
        }

        for (NSString *candidate in candidates) {
            UIImage *image = [UIImage imageNamed:candidate inBundle:bundle compatibleWithTraitCollection:nil];
            if (!image) {
                continue;
            }

            image = SPKAssetScaleImage(image, resolvedPointSize);
            image = SPKAssetApplyRenderingMode(image, renderingMode);
            [SPKAssetIconCache() setObject:(image ?: (id)[NSNull null]) forKey:cacheKey];
            return image;
        }
    }

    [SPKAssetIconCache() setObject:[NSNull null] forKey:cacheKey];
    return nil;
}

@implementation SPKAssetUtils

+ (UIImage *)instagramIconNamed:(NSString *)name {
    return [self instagramIconNamed:name
                          pointSize:0
                             source:SPKAssetCatalogSourceAutomatic
                      renderingMode:UIImageRenderingModeAlwaysTemplate];
}

+ (UIImage *)instagramIconNamed:(NSString *)name pointSize:(CGFloat)pointSize {
    return [self instagramIconNamed:name
                          pointSize:pointSize
                             source:SPKAssetCatalogSourceAutomatic
                      renderingMode:UIImageRenderingModeAlwaysTemplate];
}

+ (UIImage *)instagramIconNamed:(NSString *)name pointSize:(CGFloat)pointSize renderingMode:(UIImageRenderingMode)renderingMode {
    return [self instagramIconNamed:name
                          pointSize:pointSize
                             source:SPKAssetCatalogSourceAutomatic
                      renderingMode:renderingMode];
}

+ (UIImage *)instagramIconNamed:(NSString *)name
                      pointSize:(CGFloat)pointSize
                         source:(SPKAssetCatalogSource)source
                  renderingMode:(UIImageRenderingMode)renderingMode {
    UIImage *image = SPKAssetLookupInstagramIcon(name, pointSize, source, renderingMode);
    if (image) {
        return image;
    }
    return SPKAssetFallbackImage(pointSize, renderingMode);
}

+ (UIImage *)menuIconNamed:(NSString *)name {
    return [self menuIconNamed:name pointSize:kSPKMenuIconPointSize];
}

+ (UIImage *)menuIconNamed:(NSString *)name pointSize:(CGFloat)pointSize {
    // pointSize 0 = SPKAssetScaleImage no-ops, so the catalog image is returned
    // untouched with no UIGraphicsImageRenderer pass. That pass is exactly what
    // iOS 16's UIMenu refuses to render for vector-backed (.svg) glyphs — even
    // when the render size equals the native size, so we cannot redraw at all.
    UIImage *image = [self instagramIconNamed:name
                                    pointSize:0
                                       source:SPKAssetCatalogSourceAutomatic
                                renderingMode:UIImageRenderingModeAlwaysTemplate];
    return [self menuSizedIcon:image pointSize:pointSize];
}

+ (UIImage *)menuSizedIcon:(UIImage *)image {
    return [self menuSizedIcon:image pointSize:kSPKMenuIconPointSize];
}

+ (UIImage *)menuSizedIcon:(UIImage *)image pointSize:(CGFloat)pointSize {
    if (!image || pointSize <= 0.0) {
        return image;
    }

    // IG menu glyphs are 24pt native, but our own menus want the standard 22pt.
    // We can't downscale through a renderer (see menuIconNamed:), so instead
    // reinterpret the image's scale: relabelling its existing pixels at a higher
    // scale makes the same bitmap map to a smaller point size, with no redraw —
    // so it renders like the native image does, just smaller. A caller asking for
    // the native 24pt therefore falls through untouched, which is what a row
    // sitting inside one of Instagram's own menus wants.
    CGFloat maxDimension = MAX(image.size.width, image.size.height);
    CGImageRef cgImage = image.CGImage;
    if (cgImage && maxDimension > pointSize + 0.01) {
        CGFloat rescaled = image.scale * (maxDimension / pointSize);
        image = [[UIImage imageWithCGImage:cgImage
                                     scale:rescaled
                               orientation:image.imageOrientation]
                    imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return image;
}

+ (NSString *)resolvedInstagramIconNameForName:(NSString *)name {
    if (name.length == 0) {
        return nil;
    }
    return SPKAssetResolvedIconCandidateName(name, 24.0, SPKAssetCatalogSourceAutomatic);
}

+ (UIImage *)resolvedImageNamed:(NSString *)name
                      pointSize:(CGFloat)pointSize
                         weight:(UIImageSymbolWeight)weight
                         source:(SPKResolvedImageSource)source
                  renderingMode:(UIImageRenderingMode)renderingMode {
    return [self resolvedImageNamed:name
                 fallbackSystemName:nil
                          pointSize:pointSize
                             weight:weight
                             source:source
                      renderingMode:renderingMode];
}

+ (UIImage *)resolvedImageNamed:(NSString *)name
             fallbackSystemName:(NSString *)fallbackSystemName
                      pointSize:(CGFloat)pointSize
                         weight:(UIImageSymbolWeight)weight
                         source:(SPKResolvedImageSource)source
                  renderingMode:(UIImageRenderingMode)renderingMode {
    if (name.length == 0 && fallbackSystemName.length == 0) {
        return nil;
    }

    UIImage *image = nil;

    switch (source) {
    case SPKResolvedImageSourceInstagramIcon:
        image = SPKAssetLookupInstagramIcon(name, pointSize, SPKAssetCatalogSourceAutomatic, renderingMode);
        if (!image && fallbackSystemName.length > 0) {
            image = SPKAssetSystemSymbolImage(fallbackSystemName, pointSize, weight, renderingMode);
        }
        break;
    case SPKResolvedImageSourceSystemSymbol:
        image = SPKAssetSystemSymbolImage(name, pointSize, weight, renderingMode);
        if (!image && fallbackSystemName.length > 0) {
            image = SPKAssetSystemSymbolImage(fallbackSystemName, pointSize, weight, renderingMode);
        }
        break;
    case SPKResolvedImageSourceAutomatic:
    default: {
        BOOL shouldTryInstagramFirst = [name hasPrefix:@"ig_icon_"] || SPKAssetHasExplicitOverride(name);
        if (shouldTryInstagramFirst) {
            image = SPKAssetLookupInstagramIcon(name, pointSize, SPKAssetCatalogSourceAutomatic, renderingMode);
        }
        if (!image) {
            image = SPKAssetSystemSymbolImage(name, pointSize, weight, renderingMode);
        }
        if (!image && !shouldTryInstagramFirst) {
            image = SPKAssetLookupInstagramIcon(name, pointSize, SPKAssetCatalogSourceAutomatic, renderingMode);
        }
        if (!image && fallbackSystemName.length > 0) {
            image = SPKAssetSystemSymbolImage(fallbackSystemName, pointSize, weight, renderingMode);
        }
        break;
    }
    }

    if (image) {
        return image;
    }
    if (fallbackSystemName.length > 0) {
        return SPKAssetFallbackImage(pointSize, renderingMode);
    }
    return nil;
}

@end
