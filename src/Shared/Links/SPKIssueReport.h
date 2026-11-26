#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// The GitHub bug form with the environment fields filled in: Sparkle and Instagram
/// versions, device model and iOS version.
FOUNDATION_EXPORT NSString *SPKIssueReportBugURLString(void);

/// The GitHub feature request form.
FOUNDATION_EXPORT NSString *SPKIssueReportFeatureURLString(void);

/// Open the forms in an in-app Safari view on top of whatever is showing. Handing the
/// link to the system lets the GitHub app claim it as a universal link, and the app
/// drops the query string, so every prefilled field would be lost.
FOUNDATION_EXPORT void SPKIssueReportOpenBugForm(void);
FOUNDATION_EXPORT void SPKIssueReportOpenFeatureForm(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
