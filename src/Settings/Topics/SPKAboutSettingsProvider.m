#import "SPKStrings.h"
#import "SPKAboutSettingsProvider.h"

#import "../../AssetUtils.h"
#import "../../Shared/Updates/SPKChangelogViewController.h"
#import "../../Shared/Updates/SPKUpdateChecker.h"
#import "../../Tweak.h"
#import "../../Utils.h"
#import "../SPKTopicSettingsSupport.h"

/// The installed version, which doubles as the way to check for a newer one: it shows what the
/// last check found, and a tap opens the update sheet or checks again.
static SPKSetting *SPKSparkleVersionCell(void) {
    SPKSetting *version = [SPKSetting buttonCellWithTitle:SPKL(@"ABOUT_INFORMATION_SPARKLE_TITLE")
                                                 subtitle:SPKVersionString
                                                     icon:SPKSettingsIcon(@"action")
                                                   action:^{
                                                       [SPKUpdateChecker checkNowFromViewController:SPKSettingsTopPresenter()];
                                                   }];
    version.accessoryTextProvider = ^NSString * {
        if ([SPKUpdateChecker isChecking])
            return SPKL(@"ABOUT_UPDATES_CHECKING_VALUE");
        if ([SPKUpdateChecker updateAvailable])
            return SPKL(@"ABOUT_UPDATES_UPDATE_BADGE");
        if ([SPKUpdateChecker lastCheckFailed])
            return SPKL(@"ABOUT_UPDATES_CHECK_FAILED_VALUE");
        return [SPKUpdateChecker latestKnownVersion] ? SPKL(@"ABOUT_UPDATES_UP_TO_DATE_VALUE") : nil;
    };
    version.accessoryTextProminentProvider = ^BOOL {
        return ![SPKUpdateChecker isChecking] && [SPKUpdateChecker updateAvailable];
    };
    return version;
}

#if SPK_DEV
// Dev builds only: compare against a pretend installed version, or a feed of your own, to see the
// update sheet without publishing a release.
static NSDictionary *SPKUpdatesDevSection(void) {
    return SPKTopicSection(@"", @[
        [SPKSetting textFieldCellWithTitle:SPKL(@"ABOUT_UPDATES_DEV_INSTALLED_VERSION_TITLE")
                               placeholder:SPKVersionString
                              keyboardType:UIKeyboardTypeDefault
                               defaultsKey:@"app_update_dev_installed_version"],
        [SPKSetting textFieldCellWithTitle:SPKL(@"ABOUT_UPDATES_DEV_FEED_URL_TITLE")
                               placeholder:@"https://…/latest.json or {\"version\":…}" // SPK_I18N_IGNORE: feed example
                              keyboardType:UIKeyboardTypeURL
                               defaultsKey:@"app_update_dev_feed_url"],
        [SPKSetting buttonCellWithTitle:SPKL(@"ABOUT_UPDATES_DEV_RESET_STATE_TITLE")
                               subtitle:nil
                                   icon:nil
                                 action:^{
                                     [SPKUpdateChecker resetState];
                                 }]
    ],
                           nil);
}
#endif

@implementation SPKAboutSettingsProvider

+ (SPKSetting *)rootSetting {
    // Larger, bolder title so it reads in balance with the 45pt Ko-fi icon.
    SPKSetting *donate = [SPKSetting linkCellWithTitle:SPKL(@"ABOUT_GENERAL_DONATE_WAFFLE_TITLE")
                                              subtitle:@""
                                              imageUrl:@"https://cdn.prod.website-files.com/5c14e387dab576fe667689cf/670f5a01229bf8a18f97a3c1_favion.png"
                                                   url:@"https://ko-fi.com/sparkle_ig"];
    donate.userInfo = @{
        @"titleFont" : [UIFont systemFontOfSize:20.0 weight:UIFontWeightSemibold],
        @"remoteImageCircular" : @NO
    };

    NSMutableArray *sections = [@[
        SPKTopicSection(SPKL(@"ABOUT_SUPPORT_HEADER"), @[
            SPKSettingWithHelp(donate, SPKL(@"ABOUT_SUPPORT_DONATE_HELP"))
        ],
                        nil),
        SPKTopicSection(SPKL(@"ABOUT_INFORMATION_HEADER"), @[
            SPKSparkleVersionCell(),
            [SPKSetting staticCellWithTitle:SPKL(@"ABOUT_INFORMATION_INSTAGRAM_TITLE")
                                   subtitle:[SPKUtils IGVersionString]
                                       icon:SPKSettingsIcon(@"app")],
            [SPKSetting staticCellWithTitle:SPKL(@"ABOUT_INFORMATION_BUNDLE_ID_TITLE")
                                   subtitle:[[NSBundle mainBundle] bundleIdentifier]
                                       icon:SPKSettingsIcon(@"key")]
        ],
                        nil),
        SPKTopicSection(@"", @[
            [SPKSetting navigationCellWithTitle:SPKL(@"ABOUT_INFORMATION_CHANGELOG_TITLE")
                                       subtitle:@""
                                           icon:SPKSettingsIcon(@"history")
                                 viewController:[SPKChangelogViewController new]],
        ],
                        nil),
        SPKTopicSection(@"", @[
            [SPKSetting linkCellWithTitle:SPKL(@"ABOUT_INFORMATION_WAFFLE_TITLE")
                                 subtitle:SPKL(@"ABOUT_INFORMATION_SPARKLE_DEVELOPER_SUBTITLE")
                                 imageUrl:@"https://avatars.githubusercontent.com/u/117626247?v=4"
                                      url:@"https://github.com/efibalogh"],
            [SPKSetting linkCellWithTitle:SPKL(@"ABOUT_INFORMATION_VIEW_SOURCE_CODE_TITLE")
                                 subtitle:SPKL(@"ABOUT_INFORMATION_TAP_OPEN_GITHUB_SUBTITLE")
                                 imageUrl:@"https://i.imgur.com/BBUNzeP.png"
                                      url:@"https://github.com/efibalogh/sparkle-ig"]
        ],
                        nil),
        SPKTopicSection(SPKL(@"ABOUT_COMMUNITY_HEADER"), @[
            [SPKSetting linkCellWithTitle:SPKL(@"ABOUT_COMMUNITY_TELEGRAM_CHANNEL_TITLE")
                                 subtitle:SPKL(@"ABOUT_COMMUNITY_JOIN_COMMUNITY_UPDATES_SUPPORT_SUBTITLE")
                                 imageUrl:@"https://upload.wikimedia.org/wikipedia/commons/thumb/8/82/Telegram_logo.svg/960px-Telegram_logo.svg.png"
                                      url:@"https://t.me/sparkle_ig"],
        ],
                        nil),
        SPKTopicSection(SPKL(@"ABOUT_CREDITS_HEADER"), @[
            [SPKSetting linkCellWithTitle:SPKL(@"ABOUT_CREDITS_SOCUUL_SCINSTA_TITLE")
                                 subtitle:SPKL(@"ABOUT_CREDITS_BASE_PROJECT_SPARKLE_BUILT_SUBTITLE")
                                 imageUrl:@"https://i.imgur.com/c9CbytZ.png"
                                      url:@"https://github.com/SoCuul/SCInsta"],
            [SPKSetting linkCellWithTitle:SPKL(@"ABOUT_CREDITS_RYUK_RYUKGRAM_TITLE")
                                 subtitle:SPKL(@"ABOUT_CREDITS_CODE_INSPIRATION_HELP_SUBTITLE")
                                 imageUrl:@"https://avatars.githubusercontent.com/u/51106560?v=4"
                                      url:@"https://github.com/faroukbmiled/"],
            [SPKSetting linkCellWithTitle:SPKL(@"ABOUT_CREDITS_N3D1117_INSTASANE_TITLE")
                                 subtitle:SPKL(@"ABOUT_CREDITS_FOLLOWING_FEED_MODE_SUBTITLE")
                                 imageUrl:@"https://avatars.githubusercontent.com/u/11541888?v=4"
                                      url:@"https://github.com/n3d1117/InstaSane"],
            [SPKSetting linkCellWithTitle:SPKL(@"ABOUT_CREDITS_ASDFZXCVBN_ZXPLUGINSINJECT_TITLE")
                                 subtitle:SPKL(@"ABOUT_CREDITS_FIXES_SIDELOADED_INSTALLS_SUBTITLE")
                                 imageUrl:@"https://avatars.githubusercontent.com/u/109937991?v=4"
                                      url:@"https://github.com/asdfzxcvbn/zxPluginsInject"]
        ],
                        nil),
        SPKTopicSection(@"", @[
            [SPKSetting staticCellWithTitle:@"@grxphxnx" // SPK_I18N_IGNORE: contributor name
                                   subtitle:SPKL(@"ABOUT_CREDITS_LOCALIZATION_SUBTITLE")
                                   imageUrl:@"https://avatars.githubusercontent.com/u/26267688?v=4"]
        ],
                        nil)
    ] mutableCopy];
#if SPK_DEV
    // Right under Information, beside the version row it drives.
    [sections insertObject:SPKUpdatesDevSection() atIndex:2];
#endif
    return SPKTopicNavigationSetting(SPKL(@"ABOUT_TITLE"), @"info", 24.0, sections);
}

@end
