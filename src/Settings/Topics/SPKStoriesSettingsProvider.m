#import "SPKStrings.h"
#import "SPKStoriesSettingsProvider.h"

#import "../../Features/Stories/StoryAudioToggle.h"
#import "../../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../../Shared/Stories/SPKStoryContext.h"
#import "../../Utils.h"
#import "../SPKSettingsViewController.h"
#import "../SPKTopicSettingsSupport.h"
static NSString *const kSPKStoriesActionButtonEnabledKey = @"stories_action_btn";

static NSDictionary *SPKStoriesSeenReceiptsSection(void);
static NSArray *SPKStoriesSettingsSections(void);

@interface SPKStoriesSettingsViewController : SPKSettingsViewController
@end

@implementation SPKStoriesSettingsViewController
- (instancetype)init {
    return [super initWithTitle:SPKL(@"STORIES_OTHER_STORIES_TITLE") sections:SPKStoriesSettingsSections() reduceMargin:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self replaceSections:SPKStoriesSettingsSections()];
}

- (void)switchChanged:(UISwitch *)sender {
    SPKSetting *row = [self settingForSender:sender];
    [super switchChanged:sender];
    if ([row.defaultsKey isEqualToString:@"stories_manual_seen"]) {
        [self replaceSections:SPKStoriesSettingsSections()];
    }
}
@end

static NSDictionary *SPKStoriesSeenReceiptsSection(void) {
    BOOL manualSeen = [SPKUtils getBoolPref:@"stories_manual_seen"];
    SPKSetting *manualSeenList = [SPKSetting navigationCellWithTitle:SPKStoryManualSeenListTitle(manualSeen)
                                                            subtitle:@""
                                                                icon:SPKSettingsIcon(@"users")
                                                      viewController:SPKStoryManualSeenListViewController()];
    manualSeenList.userInfo = @{@"accessoryText" : [NSString stringWithFormat:@"%lu", (unsigned long)SPKStoryManualSeenUserList(manualSeen).count]};
    // The list flips between an exclude and an include list with the manual-seen
    // switch, so its explanation has to flip with it.
    manualSeenList.helpText = manualSeen ? SPKL(@"STORIES_SEEN_RECEIPTS_EXCLUDED_USERS_HELP")
                                         : SPKL(@"STORIES_SEEN_RECEIPTS_INCLUDED_USERS_HELP");

    // The auto-seen triggers only do anything while manual seen is on. Keep their
    // stored value but lock the cells when manual seen is off.
    SPKSetting *markSeenOnLike = [SPKSetting switchCellWithTitle:SPKL(@"STORIES_GENERAL_MARK_SEEN_LIKE_TITLE") icon:SPKSettingsIcon(@"heart") defaultsKey:@"stories_mark_seen_on_like"];
    SPKSetting *markSeenOnReply = [SPKSetting switchCellWithTitle:SPKL(@"STORIES_GENERAL_MARK_SEEN_REPLY_TITLE") icon:SPKSettingsIcon(@"reply") defaultsKey:@"stories_mark_seen_on_reply"];
    markSeenOnLike.helpText = SPKL(@"STORIES_SEEN_RECEIPTS_MARK_SEEN_LIKE_HELP");
    markSeenOnReply.helpText = SPKL(@"STORIES_SEEN_RECEIPTS_MARK_SEEN_REPLY_HELP");
    markSeenOnLike.enabledProvider = ^BOOL {
        return [SPKUtils getBoolPref:@"stories_manual_seen"];
    };
    markSeenOnReply.enabledProvider = ^BOOL {
        return [SPKUtils getBoolPref:@"stories_manual_seen"];
    };

    return SPKTopicSection(SPKL(@"STORIES_SEEN_RECEIPTS_HEADER"), @[
        SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"MESSAGES_MESSAGING_MANUALLY_MARK_SEEN_TITLE")
                                       icon:SPKSettingsIcon(@"eye")
                                defaultsKey:@"stories_manual_seen"],
                           SPKL(@"STORIES_SEEN_RECEIPTS_MANUALLY_MARK_SEEN_HELP")),
        markSeenOnLike,
        markSeenOnReply,
        manualSeenList,
    ],
                           nil);
}

static NSArray *SPKStoriesSettingsSections(void) {
    return @[
        SPKTopicSection(SPKL(@"FEED_ACTION_BUTTON_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_ACTION_BUTTON_STORIES_ACTION_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(@"action")
                                    defaultsKey:kSPKStoriesActionButtonEnabledKey],
                               SPKL(@"STORIES_ACTION_BUTTON_ENABLED_HELP")),
            SPKActionButtonDefaultActionNavigationSetting(SPKActionButtonSourceStories),
            SPKActionButtonConfigurationNavigationSetting(SPKActionButtonSourceStories, SPKL(@"STORIES_OTHER_STORIES_TITLE"), SPKActionButtonSupportedActionsForSource(SPKActionButtonSourceStories), SPKActionButtonDefaultSectionsForSource(SPKActionButtonSourceStories))
        ],
                        nil),
        SPKStoriesSeenReceiptsSection(),
        SPKTopicSection(SPKL(@"STORIES_PLAYBACK_HEADER"), @[
            ({
                SPKSetting *storyAudioToggle = [SPKSetting switchCellWithTitle:SPKL(@"STORIES_PLAYBACK_AUDIO_TOGGLE_TITLE")
                                                                           icon:SPKSettingsIcon(@"volume")
                                                                    defaultsKey:@"stories_audio_toggle"];
                storyAudioToggle.switchChangeHandler = ^(BOOL isOn) {
                    SPKPreferenceSetObject(@(isOn), @"stories_audio_toggle");
                    [[NSNotificationCenter defaultCenter] postNotificationName:SPKStoryAudioTogglePreferenceDidChangeNotification object:nil];
                };
                storyAudioToggle.helpText = SPKL(@"STORIES_PLAYBACK_AUDIO_TOGGLE_HELP");
                storyAudioToggle;
            }),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_PLAYBACK_HIDE_AUDIO_UNAVAILABLE_TOAST_TITLE")
                                           icon:SPKSettingsIcon(@"error")
                                    defaultsKey:@"stories_hide_audio_unavailable_toast"],
                               SPKL(@"STORIES_PLAYBACK_HIDE_AUDIO_UNAVAILABLE_TOAST_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_OTHER_HIDE_JOIN_TRENDING_TITLE")
                                           icon:SPKSettingsIcon(@"arrow_up_right")
                                    defaultsKey:@"stories_hide_join_trending"],
                               SPKL(@"STORIES_OTHER_HIDE_JOIN_TRENDING_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_OTHER_HIDE_RECENT_HIGHLIGHTS_TITLE")
                                           icon:SPKSettingsIcon(@"highlights")
                                    defaultsKey:@"stories_hide_recent_highlights"],
                               SPKL(@"STORIES_OTHER_HIDE_RECENT_HIGHLIGHTS_HELP")),
        ],
                        nil),

        SPKTopicSection(SPKL(@"STORIES_STORY_NAVIGATION_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"MESSAGES_VISUAL_MESSAGES_STOP_AUTO_ADVANCE_TITLE")
                                           icon:SPKSettingsIcon(@"autoscroll")
                                    defaultsKey:@"stories_stop_auto_advance"],
                               SPKL(@"STORIES_NAVIGATION_STOP_AUTO_ADVANCE_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_STORY_NAVIGATION_ADVANCE_EYE_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(@"eye")
                                    defaultsKey:@"stories_advance_on_manual_seen"],
                               SPKL(@"STORIES_NAVIGATION_ADVANCE_EYE_BUTTON_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_STORY_NAVIGATION_ADVANCE_STORY_LIKE_TITLE")
                                           icon:SPKSettingsIcon(@"heart")
                                    defaultsKey:@"stories_advance_on_like_seen"],
                               SPKL(@"STORIES_NAVIGATION_ADVANCE_STORY_LIKE_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_STORY_NAVIGATION_ADVANCE_STORY_REPLY_TITLE")
                                           icon:SPKSettingsIcon(@"reply")
                                    defaultsKey:@"stories_advance_on_reply_seen"],
                               SPKL(@"STORIES_NAVIGATION_ADVANCE_STORY_REPLY_HELP")),
        ],
                                                         nil),
        SPKTopicSection(SPKL(@"STORIES_CONFIRMATIONS_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_CONFIRMATION_CONFIRM_LIKE_TITLE")
                                           icon:SPKSettingsIcon(@"heart")
                                    defaultsKey:@"stories_confirm_like"],
                               SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_LIKE_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_QUICK_REACTION_TITLE")
                                           icon:SPKSettingsIcon(@"reactions")
                                    defaultsKey:@"stories_confirm_quick_reaction"],
                               SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_QUICK_REACTION_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_STICKER_INTERACTION_TITLE")
                                           icon:SPKSettingsIcon(@"sticker")
                                    defaultsKey:@"stories_confirm_sticker"],
                               SPKL(@"STORIES_CONFIRMATIONS_CONFIRM_STICKER_HELP"))
        ],
                        nil),
        
        SPKTopicSection(SPKL(@"STORIES_INSTAGRAM_PLUS_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_INSTAGRAM_PLUS_UNLOCK_STORY_PREVIEW_TITLE")
                                           icon:SPKSettingsIcon(@"story_preview")
                                    defaultsKey:@"stories_unlock_preview"],
                               SPKL(@"STORIES_INSTAGRAM_PLUS_UNLOCK_STORY_PREVIEW_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_INSTAGRAM_PLUS_HIDE_INSTAGRAM_PLUS_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(@"aura")
                                    defaultsKey:@"stories_hide_ig_plus_button"],
                               SPKL(@"STORIES_INSTAGRAM_PLUS_HIDE_BUTTON_HELP"))
        ],
                        nil),

        SPKTopicSection(SPKL(@"INSTANTS_CREATION_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_CREATION_ALLOW_VIDEOS_PHOTO_STICKER_TITLE")
                                           icon:SPKSettingsIcon(@"video")
                                    defaultsKey:@"stories_allow_video_sticker"],
                               SPKL(@"STORIES_CREATION_ALLOW_VIDEOS_PHOTO_STICKER_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_CREATION_SHOW_GALLERY_UPLOAD_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(@"sparkle_gallery")
                                    defaultsKey:@"stories_gallery_upload_sticker"],
                               SPKL(@"STORIES_CREATION_GALLERY_STICKER_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_CREATION_USE_DETAILED_COLOR_PICKER_TITLE")
                                           icon:SPKSettingsIcon(@"eyedropper")
                                    defaultsKey:@"stories_detailed_color_picker"],
                               SPKL(@"STORIES_CREATION_DETAILED_COLOR_PICKER_HELP"))
        ],
                        nil),

        SPKTopicSection(SPKL(@"STORIES_TOOLS_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_OTHER_SEARCH_VIEWER_LIST_TITLE")
                                           icon:SPKSettingsIcon(@"search")
                                    defaultsKey:@"stories_search_viewer_list"],
                               SPKL(@"STORIES_OTHER_SEARCH_VIEWER_LIST_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_OTHER_SHOW_STORY_MENTIONS_TITLE")
                                           icon:SPKSettingsIcon(@"mention")
                                    defaultsKey:@"stories_mentions_btn"],
                               SPKL(@"STORIES_OTHER_SHOW_STORY_MENTIONS_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_OTHER_MENTIONS_COUNT_BADGE_TITLE")
                                           icon:SPKSettingsIcon(@"users")
                                    defaultsKey:@"stories_mentions_count_badge"],
                               SPKL(@"STORIES_OTHER_MENTIONS_COUNT_BADGE_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"STORIES_OTHER_SHOW_POLL_VOTE_COUNTS_TITLE")
                                           icon:SPKSettingsIcon(@"poll")
                                    defaultsKey:@"stories_poll_vote_counts"],
                               SPKL(@"STORIES_OTHER_SHOW_POLL_VOTE_COUNTS_HELP")),
        ],
                        nil)
    ];
}

@implementation SPKStoriesSettingsProvider

+ (SPKSetting *)rootSetting {
    SPKSetting *setting = [SPKSetting navigationCellWithTitle:SPKL(@"STORIES_OTHER_STORIES_TITLE")
                                                     subtitle:@""
                                                         icon:SPKSettingsIcon(@"story")
                                               viewController:[[SPKStoriesSettingsViewController alloc] init]];
    setting.searchSectionsProvider = ^NSArray * {
        return SPKStoriesSettingsSections();
    };
    return SPKSettingApplyIconTint(setting, [SPKUtils SPKColor_InstagramPrimaryText]);
}

@end
