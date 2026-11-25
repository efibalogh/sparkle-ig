#import "SPKProfileAnalyzerSettingsProvider.h"
#import "../SPKNewBadges.h"
#import "SPKStrings.h"
#import <UIKit/UIKit.h>

#import "../../Features/Profile/ProfileAnalyzer/SPKProfileAnalyzerViewController.h"
#import "../../Utils.h"
#import "../SPKSetting.h"
#import "../SPKTopicSettingsSupport.h"

@implementation SPKProfileAnalyzerSettingsProvider

+ (SPKSetting *)rootSetting {
    // Opens straight into the analyzer dashboard — no intermediate settings page.
    // Track Visits, Visited Profiles, About and Reset all live inside the dashboard.
    SPKSetting *setting = [SPKSetting navigationCellWithTitle:SPKL(@"DATA_GENERAL_PROFILE_ANALYZER_TITLE")
                                                     subtitle:@""
                                                         icon:SPKSettingsIcon(@"profile_analyzer")
                                               viewController:[SPKProfileAnalyzerViewController new]];
    setting.searchKeywords = @"profile analyzer followers following mutual unfollow tracker visited stalkers";
    setting.addedContentItems = @[ @"profile_analyzer_auto_refresh" ];
    return SPKSettingApplyIconTint(setting, [SPKUtils SPKColor_InstagramPrimaryText]);
}

@end
