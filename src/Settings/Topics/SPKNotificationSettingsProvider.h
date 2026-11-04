#import <UIKit/UIKit.h>

@interface SPKNotificationSettingsProvider : NSObject
+ (NSArray *)sections;
/// The Notifications page: `sections` under a live preview of the current style.
+ (UIViewController *)settingsViewController;
@end
