#import "SPKStrings.h"
#import "SPKAccountPrivacySettingsProvider.h"

#import "../../Utils.h"
#import "../SPKAccountPrivacySettingsViewController.h"
#import "../SPKTopicSettingsSupport.h"

@implementation SPKAccountPrivacySettingsProvider

+ (SPKSetting *)rootSetting {
    // Two switches do not earn a pushed page, so the row opens them as a sheet.
    SPKSetting *setting = [SPKSetting buttonCellWithTitle:SPKL(@"ACCOUNT_PRIVACY_TITLE")
                                                 subtitle:nil
                                                     icon:SPKSettingsIcon(@"lock")
                                                   action:^{
                                                       [SPKAccountPrivacySettingsViewController presentFromViewController:SPKSettingsTopPresenter()];
                                                   }];
    setting.searchKeywords = @"privacy hide followers following list account visibility who can see";
    setting.searchSectionsProvider = ^NSArray * {
        return [SPKAccountPrivacySettingsViewController searchSections];
    };
    return setting;
}

@end
