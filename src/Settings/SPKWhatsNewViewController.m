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

// A patch release that extends the previous release's sheet names both versions.
// Set to nil when a release gets a sheet of its own.
static NSString *const SPKWhatsNewPreviousVersion = nil;

- (NSArray<SPKPagedSheetPage *> *)buildPages {
    NSString *intro = SPKWhatsNewPreviousVersion.length
        ? [NSString stringWithFormat:SPKL(@"SETTINGS_WHATS_NEW_TWO_VERSIONS_VALUE_FORMAT"), SPKWhatsNewPreviousVersion, SPKVersionString]
        : [NSString stringWithFormat:SPKL(@"SETTINGS_WHATS_NEW_WHAT_S_NEW_VALUE_FORMAT"), SPKVersionString];
    return @[
        [SPKPagedSheetPage pageWithTitle:SPKL(@"SETTINGS_WHATS_NEW_NEW_FEATURES_TEXT")
                                    body:intro
                                    rows:@[
                                        @{ @"icon": @"device_tablet", @"symbol": @"ipad", @"rotation": @90, @"text": SPKL(@"SETTINGS_WHATS_NEW_IPHONE_DUO_TEXT") },
                                        @{ @"icon": @"layout", @"text": SPKL(@"SETTINGS_WHATS_NEW_TAB_HOLDS_TEXT") },
                                        @{ @"icon": @"interface", @"rotation": @180, @"text": SPKL(@"SETTINGS_WHATS_NEW_SYSTEM_TAB_BAR_TEXT") },
                                        @{ @"icon": @"eye_off", @"text": SPKL(@"SETTINGS_WHATS_NEW_CHATS_SEEN_LOCALLY_TEXT") },
                                        @{ @"icon": @"web", @"text": SPKL(@"SETTINGS_WHATS_NEW_NETWORK_INTERCEPTOR_TEXT") },
                                        @{ @"icon": @"grid_tall", @"text": SPKL(@"SETTINGS_WHATS_NEW_POSTS_TAB_FILTER_TEXT") },
                                        @{ @"icon": @"crop", @"text": SPKL(@"SETTINGS_WHATS_NEW_MEDIA_EDITORS_TEXT") },
                                        @{ @"icon": @"search", @"text": SPKL(@"SETTINGS_WHATS_NEW_RESTORE_ACCOUNT_SEARCH_TEXT") },
                                        @{ @"icon": @"profile_analyzer", @"text": SPKL(@"SETTINGS_WHATS_NEW_PROFILE_ANALYZER_AUTO_REFRESH_TEXT") },
                                    ]],
        [SPKPagedSheetPage pageWithTitle:SPKL(@"SETTINGS_WHATS_NEW_MORE_EXPLORE_TEXT")
                                    body:@""
                                    rows:@[
                                        @{ @"icon": @"pause", @"text": SPKL(@"SETTINGS_WHATS_NEW_REELS_HOLD_TO_PAUSE_TEXT") },
                                        @{ @"icon": @"music", @"text": SPKL(@"SETTINGS_WHATS_NEW_KEEP_OTHER_AUDIO_TEXT") },
                                        @{ @"icon": @"notification", @"text": SPKL(@"SETTINGS_WHATS_NEW_NOTIFICATION_SUPPORT_TEXT") },
                                        @{ @"icon": @"highlights", @"text": SPKL(@"SETTINGS_WHATS_NEW_REORDER_HIGHLIGHTS_TEXT") },
                                        @{ @"icon": @"link", @"text": SPKL(@"SETTINGS_WHATS_NEW_COPY_STORY_LINK_TEXT") },
                                        @{ @"icon": @"download", @"text": SPKL(@"SETTINGS_WHATS_NEW_FILE_NAMES_TEXT") },
                                        @{ @"icon": @"muse", @"text": SPKL(@"SETTINGS_WHATS_NEW_HIDE_MUSE_TEXT") },
                                        @{ @"icon": @"sparkle_gallery", @"text": SPKL(@"SETTINGS_WHATS_NEW_GALLERY_HOME_TEXT") },
                                        @{ @"icon": @"sparkles", @"text": SPKL(@"SETTINGS_WHATS_NEW_NEW_LABELS_TEXT") },
                                       // @{ @"text": SPKL(@"SETTINGS_WHATS_NEW_PLENTY_MORE_TEXT") },
                                    ]],
        [SPKPagedSheetPage pageWithTitle:SPKL(@"SETTINGS_WHATS_NEW_FIXES_IMPROVEMENTS_TEXT")
                                    body:@""
                                    rows:@[
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_INSTAGRAM_457_COMPATIBILITY_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_MESSAGE_MENU_DOWNLOADS_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_MESSAGE_PREVIEW_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_INSTANTS_NATIVE_HEADER_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_STORIES_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_REELS_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_HOME_FEED_RESET_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_REGRAM_IMPORT_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_APP_ICON_RESET_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_TEXT_SIZE_TEXT") },
                                        @{ @"icon": @"subtract", @"text": SPKL(@"SETTINGS_WHATS_NEW_FIX_SEEN_RECEIPT_GUARD_TEXT") },
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
