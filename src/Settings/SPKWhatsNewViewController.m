#import "SPKStrings.h"
#import "SPKWhatsNewViewController.h"
#import "../Tweak.h"

@implementation SPKWhatsNewViewController

// Release notes are curated from the conventional-commit log for the release range
// (see whats-new.sh). Feature rows carry a per-surface IG catalog glyph; fix rows
// share the `subtract` bullet so they read as one clean list. Icon names are
// SPKAssetUtils override keys — never SF Symbols. Keep in sync with README/FEATURES.
//
// Every content row is replaced wholesale each release. The keys name the change
// rather than its English wording, and the previous release's keys are deleted from
// every catalog, so a stale translation can never be reused for a different row.
- (NSArray<SPKPagedSheetPage *> *)buildPages {
    return @[
        [SPKPagedSheetPage pageWithTitle:SPKL(@"SETTINGS_WHATS_NEW_NEW_FEATURES_TEXT")
                                    body:[NSString stringWithFormat:SPKL(@"SETTINGS_WHATS_NEW_WHAT_S_NEW_VALUE_FORMAT"), SPKVersionString]
                                    rows:@[
                                        @{ @"icon": @"download", @"text": SPKL(@"SETTINGS_WHATS_NEW_UPDATE_CHECKER_TEXT") },
                                        @{ @"icon": @"moon", @"text": SPKL(@"SETTINGS_WHATS_NEW_OLED_DARK_MODE_TEXT") },
                                        @{ @"icon": @"pin", @"text": SPKL(@"SETTINGS_WHATS_NEW_SEARCH_PINS_TEXT") },
                                        @{ @"icon": @"lock", @"text": SPKL(@"SETTINGS_WHATS_NEW_ACCOUNT_PRIVACY_TEXT") },
                                        @{ @"icon": @"highlights", @"text": SPKL(@"SETTINGS_WHATS_NEW_GALLERY_OPEN_STORIES_TEXT") },
                                        @{ @"icon": @"instants", @"text": SPKL(@"SETTINGS_WHATS_NEW_INSTANTS_SEEN_USER_LISTS_TEXT") },
                                        @{ @"icon": @"users", @"text": SPKL(@"SETTINGS_WHATS_NEW_EXACT_FOLLOWER_COUNT_TEXT") },
                                        @{ @"icon": @"sparkles", @"text": SPKL(@"SETTINGS_WHATS_NEW_LIQUID_GLASS_MODE_TEXT") },
                                    ]],
        [SPKPagedSheetPage pageWithTitle:SPKL(@"SETTINGS_WHATS_NEW_MORE_EXPLORE_TEXT")
                                    body:@""
                                    rows:@[
                                        @{ @"icon": @"user_follow", @"text": SPKL(@"SETTINGS_WHATS_NEW_PROFILE_SUGGESTIONS_BUTTON_TEXT") },
                                        @{ @"icon": @"mention", @"text": SPKL(@"SETTINGS_WHATS_NEW_CLIPBOARD_USERNAME_TEXT") },
                                        @{ @"icon": @"arrow_cw", @"text": SPKL(@"SETTINGS_WHATS_NEW_CONFIRM_FEED_REFRESH_TEXT") },
                                        @{ @"icon": @"reels", @"text": SPKL(@"SETTINGS_WHATS_NEW_CONFIRM_REEL_SEND_TEXT") },
                                        @{ @"icon": @"meta_ai", @"text": SPKL(@"SETTINGS_WHATS_NEW_HIDE_META_AI_SHARE_TEXT") },
                                        @{ @"icon": @"story", @"text": SPKL(@"SETTINGS_WHATS_NEW_HIDE_STORY_SUGGESTED_ACCOUNTS_TEXT") },
                                        @{ @"icon": @"notification", @"text": SPKL(@"SETTINGS_WHATS_NEW_NOTIFICATION_GROUPS_TEXT") },
                                        @{ @"icon": @"sparkle_gallery", @"text": SPKL(@"SETTINGS_WHATS_NEW_GALLERY_HIGHLIGHT_BADGE_TEXT") },
                                        @{ @"text": SPKL(@"SETTINGS_WHATS_NEW_PLENTY_MORE_TEXT") },
                                    ]],
        [SPKPagedSheetPage pageWithTitle:SPKL(@"SETTINGS_WHATS_NEW_FIXES_IMPROVEMENTS_TEXT")
                                    body:@""
                                    rows:@[
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_INSTAGRAM_454_COMPATIBILITY_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_GALLERY_ORIGINALS_KEPT_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_GALLERY_MISSING_FILE_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_EDIT_PHOTO_QUALITY_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_FEED_DOUBLED_AUDIO_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_HIGHLIGHT_STORY_LINK_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_PROGRESS_CANCEL_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_FASTER_LAUNCH_TAB_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_OTHER_BUG_FIXES_UI_IMPROVEMENTS_TEXT") },
                                    ]],
    ];
}

- (NSString *)finishButtonTitle {
    return SPKL(@"SETTINGS_WHATS_NEW_DONE_TEXT");
}

- (BOOL)allowsInteractiveDismiss {
    return YES;
}

@end
