#import "SPKStrings.h"
#import "SPKProfileSettingsProvider.h"

#import "../../AssetUtils.h"
#import "../../Features/Profile/FollowIndicator.h"
#import "../../Shared/ActionButton/SPKActionButtonConfiguration.h"
#import "../../Utils.h"
#import "../SPKTopicSettingsSupport.h"

static NSString *const kSPKProfileActionNone = @"none";
static NSString *const kSPKProfileActionCopyInfo = @"copy_info";
static NSString *const kSPKProfileActionViewPicture = @"view_picture";
static NSString *const kSPKProfileActionSharePicture = @"share_picture";
static NSString *const kSPKProfileActionSavePictureToGallery = @"save_picture_gallery";
static NSString *const kSPKProfileActionOpenSettings = @"profile_settings";
static NSString *const kSPKProfileDefaultCopyInfoKey = @"profile_action_btn_default_copy_info_action";
static NSString *const kSPKProfileCopyInfoID = @"id";
static NSString *const kSPKProfileCopyInfoUsername = @"username";
static NSString *const kSPKProfileCopyInfoName = @"name";
static NSString *const kSPKProfileCopyInfoBio = @"bio";
static NSString *const kSPKProfileCopyInfoLink = @"link";
static CGFloat const kSPKProfileSettingsMenuIconPointSize = 22.0;

static UIImage *SPKProfileSettingsMenuIcon(NSString *resourceName) {
    return [SPKAssetUtils instagramIconNamed:resourceName pointSize:kSPKProfileSettingsMenuIconPointSize];
}

static UICommand *SPKProfileActionDefaultCommand(NSString *title, NSString *resourceName, NSString *value) {
    UIImage *image = SPKProfileSettingsMenuIcon(resourceName);
    return [UICommand commandWithTitle:title
                                 image:image
                                action:@selector(menuChanged:)
                          propertyList:@{
                              @"defaultsKey" : @"profile_action_btn_default_action",
                              @"value" : value,
                              @"iconName" : resourceName
                          }];
}

static UIMenu *SPKProfileActionDefaultMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKProfileActionDefaultCommand(SPKL(@"FEED_HEADER_ACTION_BUTTON_OPEN_MENU_TEXT"), @"action", kSPKProfileActionNone),
        SPKProfileActionDefaultCommand(SPKL(@"SETTINGS_PROFILE_COPY_INFO_TEXT"), @"copy", kSPKProfileActionCopyInfo),
        SPKProfileActionDefaultCommand(SPKL(@"SETTINGS_PROFILE_VIEW_PICTURE_TEXT"), @"photo", kSPKProfileActionViewPicture),
        SPKProfileActionDefaultCommand(SPKL(@"SETTINGS_PROFILE_SHARE_PICTURE_TEXT"), @"share", kSPKProfileActionSharePicture),
        SPKProfileActionDefaultCommand(SPKL(@"FEED_COMMENT_ACTIONS_SAVE_GALLERY_TEXT"), @"sparkle_gallery", kSPKProfileActionSavePictureToGallery),
        SPKProfileActionDefaultCommand(SPKL(@"SETTINGS_PROFILE_PROFILE_SETTINGS_TEXT"), @"settings", kSPKProfileActionOpenSettings)
    ]];
}

static UICommand *SPKProfileDefaultCopyInfoCommand(NSString *title, NSString *resourceName, NSString *value) {
    UIImage *image = SPKProfileSettingsMenuIcon(resourceName);
    return [UICommand commandWithTitle:title
                                 image:image
                                action:@selector(menuChanged:)
                          propertyList:@{
                              @"defaultsKey" : kSPKProfileDefaultCopyInfoKey,
                              @"value" : value,
                              @"iconName" : resourceName
                          }];
}

static UIMenu *SPKProfileDefaultCopyInfoMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKProfileDefaultCopyInfoCommand(SPKL(@"SETTINGS_PROFILE_ID_TEXT"), @"key", kSPKProfileCopyInfoID),
        SPKProfileDefaultCopyInfoCommand(SPKL(@"SETTINGS_PROFILE_USERNAME_TEXT"), @"username", kSPKProfileCopyInfoUsername),
        SPKProfileDefaultCopyInfoCommand(SPKL(@"SETTINGS_PROFILE_NAME_TEXT"), @"text", kSPKProfileCopyInfoName),
        SPKProfileDefaultCopyInfoCommand(SPKL(@"SETTINGS_PROFILE_BIO_TEXT"), @"caption", kSPKProfileCopyInfoBio),
        SPKProfileDefaultCopyInfoCommand(SPKL(@"SETTINGS_PROFILE_PROFILE_LINK_TEXT"), @"link", kSPKProfileCopyInfoLink)
    ]];
}

static NSString *const kSPKFollowIndicatorModeKey = @"profile_follow_indicator_mode";
static NSString *const kSPKFollowIndicatorModeOff = @"off";
static NSString *const kSPKFollowIndicatorModeText = @"text";
static NSString *const kSPKFollowIndicatorModeIcon = @"icon";
static NSString *const kSPKFollowIndicatorModeIconText = @"icontext";

// Mirrors FollowIndicator.x: no default is registered for the mode key, so an
// empty value means "use the legacy on/off bool" for pre-mode-menu users.
static NSString *SPKFollowIndicatorEffectiveMode(void) {
    NSString *mode = [SPKUtils getStringPref:kSPKFollowIndicatorModeKey];
    if (mode.length > 0)
        return mode;
    return [SPKUtils getBoolPref:@"profile_follow_indicator"] ? kSPKFollowIndicatorModeText
                                                              : kSPKFollowIndicatorModeOff;
}

static NSString *const kSPKFollowIndicatorColorfulKey = @"profile_follow_indicator_colorful";

// Mirrors FollowIndicator.x: no default is registered, so a never-set value
// falls back to the legacy bool (pre-menu enabled users keep colored).
static BOOL SPKFollowIndicatorColorfulEnabled(void) {
    id value = SPKPreferenceObjectForKey(kSPKFollowIndicatorColorfulKey);
    if (value == nil)
        return [SPKUtils getBoolPref:@"profile_follow_indicator"];
    return [value boolValue];
}

// No per-item icons: the menu is a plain title list. The cell keeps a static
// leading icon instead of reflecting the selection.
static UICommand *SPKFollowIndicatorModeCommand(NSString *title, NSString *value) {
    return [UICommand commandWithTitle:title
                                 image:nil
                                action:@selector(menuChanged:)
                          propertyList:@{
                              @"defaultsKey" : kSPKFollowIndicatorModeKey,
                              @"value" : value
                          }];
}

static UIMenu *SPKFollowIndicatorModeMenu(void) {
    return [UIMenu menuWithChildren:@[
        SPKFollowIndicatorModeCommand(SPKL(@"MENU_OFF"), kSPKFollowIndicatorModeOff),
        SPKFollowIndicatorModeCommand(SPKL(@"SETTINGS_PROFILE_ICON_TEXT"), kSPKFollowIndicatorModeIcon),
        SPKFollowIndicatorModeCommand(SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_TEXT"), kSPKFollowIndicatorModeText),
        SPKFollowIndicatorModeCommand(SPKL(@"PROFILE_FOLLOW_INDICATOR_ICON_AND_TEXT_LABEL"), kSPKFollowIndicatorModeIconText)
    ]];
}

@implementation SPKProfileSettingsProvider

+ (SPKSetting *)rootSetting {
    return SPKTopicNavigationSetting(SPKL(@"PROFILE_TITLE"), @"user_circle", 24.0, @[
        // Two short explanations, each about one control: they read better as
        // footers under their own rows than behind a shared info button.
        SPKTopicSectionWithInfoSheet(SPKTopicSection(SPKL(@"FEED_ACTION_BUTTON_HEADER"), @[
                                         SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"PROFILE_ACTION_BUTTON_PROFILE_ACTION_BUTTON_TITLE")
                                                                        icon:SPKSettingsIcon(@"action")
                                                                 defaultsKey:@"profile_action_btn"],
                                                            SPKL(@"PROFILE_ACTION_BUTTON_ENABLED_HELP")),
                                         SPKActionButtonDefaultActionNavigationSetting(SPKActionButtonSourceProfile),
                                         SPKActionButtonConfigurationNavigationSetting(SPKActionButtonSourceProfile, SPKL(@"PROFILE_TITLE"), SPKActionButtonSupportedActionsForSource(SPKActionButtonSourceProfile), SPKActionButtonDefaultSectionsForSource(SPKActionButtonSourceProfile))
                                     ],
                                                            nil),
                                     NO),
        SPKTopicSection(@"", @[
            SPKSettingWithHelp(SPKSettingApplySelectedMenuIcon([SPKSetting menuCellWithTitle:SPKL(@"PROFILE_ACTION_BUTTON_COPY_INFO_DEFAULT_TITLE") icon:SPKSettingsIcon(@"copy") menu:SPKProfileDefaultCopyInfoMenu()], SPKSettingsIcon(@"copy")),
                               SPKL(@"PROFILE_ACTION_BUTTON_COPY_INFO_DEFAULT_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"PROFILE_PROFILE_PICTURE_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_MEDIA_LONG_PRESS_EXPAND_TITLE")
                                           icon:SPKSettingsIcon(@"expand")
                                    defaultsKey:@"profile_photo_zoom"],
                               SPKL(@"PROFILE_PROFILE_PICTURE_LONG_PRESS_EXPAND_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"PROFILE_TABS_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"PROFILE_TABS_SAVED_TAB_TITLE")
                                           icon:SPKSettingsIcon(@"save")
                                    defaultsKey:@"profile_saved_tab"],
                               SPKL(@"PROFILE_TABS_SAVED_TAB_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"PROFILE_TABS_SQUARE_GRID_TITLE")
                                           icon:SPKSettingsIcon(@"grid_square")
                                    defaultsKey:@"profile_square_grid"],
                               SPKL(@"PROFILE_TABS_SQUARE_GRID_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"PROFILE_INDICATORS_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"PROFILE_INDICATORS_EXACT_FOLLOWER_COUNT_TITLE")
                                           icon:SPKSettingsIcon(@"hashtag")
                                    defaultsKey:@"profile_exact_follower_count"],
                               SPKL(@"PROFILE_INDICATORS_EXACT_FOLLOWER_COUNT_HELP")),
            ({
                SPKSetting *mode = [SPKSetting menuCellWithTitle:SPKL(@"PROFILE_INDICATORS_FOLLOWING_INDICATOR_TITLE")
                                                            icon:SPKSettingsIcon(@"user_check")
                                                            menu:SPKFollowIndicatorModeMenu()];
                mode.accessoryTextProvider = ^NSString * {
                    NSString *value = SPKFollowIndicatorEffectiveMode();
                    if ([value isEqualToString:kSPKFollowIndicatorModeText])
                        return SPKL(@"MESSAGES_DELETED_MESSAGES_MODELS_TEXT");
                    if ([value isEqualToString:kSPKFollowIndicatorModeIcon])
                        return SPKL(@"SETTINGS_PROFILE_ICON_TEXT");
                    if ([value isEqualToString:kSPKFollowIndicatorModeIconText])
                        return SPKL(@"PROFILE_HEADER_BUTTON_ICON_AND_TEXT_LABEL");
                    return SPKL(@"MENU_OFF");
                };
                mode.helpText = SPKL(@"PROFILE_INDICATORS_FOLLOWING_INDICATOR_HELP");
                mode;
            }),
            ({
                // Off (default) = Instagram's native gray for both states, so it
                // doesn't stand out as modded. On = the colored green/red. Uses a
                // custom value provider so the legacy fallback (pre-menu users who
                // had the indicator on keep colored) is reflected accurately.
                SPKSetting *colorful = [SPKSetting switchCellWithTitle:SPKL(@"PROFILE_INDICATORS_COLORFUL_INDICATOR_TITLE")
                                                                  icon:SPKSettingsIcon(@"palette")
                                                           defaultsKey:kSPKFollowIndicatorColorfulKey];
                colorful.switchValueProvider = ^BOOL {
                    return SPKFollowIndicatorColorfulEnabled();
                };
                colorful.switchChangeHandler = ^(BOOL isOn) {
                    SPKPreferenceSetObject(@(isOn), kSPKFollowIndicatorColorfulKey);
                    [[NSNotificationCenter defaultCenter] postNotificationName:SPKFollowIndicatorDidChangeNotification object:nil];
                };
                colorful.hiddenProvider = ^BOOL {
                    return [SPKFollowIndicatorEffectiveMode() isEqualToString:kSPKFollowIndicatorModeOff];
                };
                colorful.helpText = SPKL(@"PROFILE_INDICATORS_COLORFUL_INDICATOR_HELP");
                colorful;
            })
        ],
                        nil),
        SPKTopicSection(@"", @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"PROFILE_INDICATORS_HIDE_NOTES_BUBBLE_TITLE")
                                           icon:SPKSettingsIcon(@"notes")
                                    defaultsKey:@"profile_hide_notes_bubble"],
                               SPKL(@"PROFILE_INDICATORS_HIDE_NOTES_BUBBLE_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"PROFILE_INDICATORS_HIDE_THREADS_BUTTON_TITLE")
                                           icon:SPKSettingsIcon(@"threads")
                                    defaultsKey:@"profile_hide_threads_btn"],
                               SPKL(@"PROFILE_INDICATORS_HIDE_THREADS_BUTTON_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"FEED_CONFIRMATION_HEADER"), @[
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"PROFILE_CONFIRMATION_CONFIRM_FOLLOW_TITLE")
                                           icon:SPKSettingsIcon(@"user_follow")
                                    defaultsKey:@"profile_confirm_follow"],
                               SPKL(@"PROFILE_CONFIRMATION_CONFIRM_FOLLOW_HELP")),
            SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"PROFILE_CONFIRMATION_CONFIRM_UNFOLLOW_TITLE")
                                           icon:SPKSettingsIcon(@"user_unfollow")
                                    defaultsKey:@"profile_confirm_unfollow"],
                               SPKL(@"PROFILE_CONFIRMATION_CONFIRM_UNFOLLOW_HELP"))
        ],
                        nil)
    ]);
}

@end
