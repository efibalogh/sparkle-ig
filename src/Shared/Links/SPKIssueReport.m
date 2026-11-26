#import "SPKIssueReport.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <sys/sysctl.h>

#import "../../Tweak.h"
#import "SPKWebLinkOpener.h"
#import "../../Utils.h"

// Issue forms are opened by name: blank issues are disabled for this repository, so a
// bare issues/new lands on the template chooser and drops every prefilled field.
static NSString *const kSPKIssueBaseURL = @"https://github.com/efibalogh/sparkle-ig/issues/new";
static NSString *const kSPKIssueBugTemplate = @"1-bug.yaml";
static NSString *const kSPKIssueFeatureTemplate = @"2-feat.yaml";

/// The marketing name ("iPhone 16 Pro") from MobileGestalt, which has no public
/// equivalent: UIDevice reports only "iPhone". Private and looked up at runtime, so a
/// missing symbol or a refused key just falls back to the hardware id.
static NSString *SPKIssueReportMarketingName(void) {
    void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    CFTypeRef (*copyAnswer)(CFStringRef) = handle ? (CFTypeRef (*)(CFStringRef))dlsym(handle, "MGCopyAnswer") : NULL;
    if (!copyAnswer)
        return nil;
    CFTypeRef answer = copyAnswer(CFSTR("marketing-name"));
    if (!answer)
        return nil;
    id value = CFBridgingRelease(answer);
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

static NSString *SPKIssueReportHardwareModel(void) {
    char model[64] = {0};
    size_t size = sizeof(model);
    if (sysctlbyname("hw.machine", model, &size, NULL, 0) != 0 || model[0] == '\0')
        return nil;
    return [NSString stringWithUTF8String:model];
}

/// "iPhone 16 Pro (iPhone17,1)": the name reads naturally and the id is exact.
static NSString *SPKIssueReportDeviceModel(void) {
    NSString *hardware = SPKIssueReportHardwareModel();
    NSString *name = SPKIssueReportMarketingName();
    if (name.length && hardware.length && ![name isEqualToString:hardware])
        return [NSString stringWithFormat:@"%@ (%@)", name, hardware];
    return name ?: hardware;
}

static NSString *SPKIssueReportURLString(NSString *templateName, NSDictionary<NSString *, NSString *> *fields) {
    NSURLComponents *components = [NSURLComponents componentsWithString:kSPKIssueBaseURL];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"template" value:templateName]];
    for (NSString *field in [fields.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (fields[field].length)
            [items addObject:[NSURLQueryItem queryItemWithName:field value:fields[field]]];
    }
    components.queryItems = items;
    return components.URL.absoluteString ?: [NSString stringWithFormat:@"%@?template=%@", kSPKIssueBaseURL, templateName];
}

// Only text fields are filled: GitHub ignores link values for dropdowns, so the Area and
// Install Type dropdowns are left for the reporter.
NSString *SPKIssueReportBugURLString(void) {
    NSMutableDictionary<NSString *, NSString *> *fields = [NSMutableDictionary dictionary];
    fields[@"info-sparkle-version"] = SPKVersionString;
    fields[@"info-instagram-version"] = [SPKUtils IGVersionString];
    fields[@"info-device"] = SPKIssueReportDeviceModel();
    fields[@"info-ios-version"] = UIDevice.currentDevice.systemVersion;
    return SPKIssueReportURLString(kSPKIssueBugTemplate, fields);
}

NSString *SPKIssueReportFeatureURLString(void) {
    return SPKIssueReportURLString(kSPKIssueFeatureTemplate, @{});
}

static void SPKIssueReportOpen(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url)
        return;
    UIViewController *presenter = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed)
        presenter = presenter.presentedViewController;
    SPKOpenWebLink(url, SPKWebLinkOpenModeInApp, presenter, nil);
}

void SPKIssueReportOpenBugForm(void) {
    SPKIssueReportOpen(SPKIssueReportBugURLString());
}

void SPKIssueReportOpenFeatureForm(void) {
    SPKIssueReportOpen(SPKIssueReportFeatureURLString());
}
