#import "SPKSideloadDiagnostics.h"

#import "../../Shared/UI/SPKIGAlertPresenter.h"
#import "../../Shared/UI/SPKMediaChrome.h"
#import "../../Utils.h"

static NSString *const kSPKDiagnosticsGroup = @"group.com.burbn.instagram";
static NSString *const kSPKDiagnosticsDirectoryName = @"SparkleDiagnostics";
static NSString *const kSPKDiagnosticsEnabledName = @".enabled";
static NSString *const kSPKDiagnosticsLogName = @"sideload-notifications.log";

static NSURL *SPKSideloadDiagnosticsDirectoryURL(void) {
    NSURL *groupURL = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:kSPKDiagnosticsGroup];
    if (!groupURL) return nil;
    return [groupURL URLByAppendingPathComponent:kSPKDiagnosticsDirectoryName isDirectory:YES];
}

static NSURL *SPKSideloadDiagnosticsEnabledURL(void) {
    return [SPKSideloadDiagnosticsDirectoryURL() URLByAppendingPathComponent:kSPKDiagnosticsEnabledName];
}

static NSURL *SPKSideloadDiagnosticsLogURL(void) {
    return [SPKSideloadDiagnosticsDirectoryURL() URLByAppendingPathComponent:kSPKDiagnosticsLogName];
}

BOOL SPKSideloadDiagnosticsEnabled(void) {
    NSURL *enabledURL = SPKSideloadDiagnosticsEnabledURL();
    return enabledURL && [[NSFileManager defaultManager] fileExistsAtPath:enabledURL.path];
}

void SPKSetSideloadDiagnosticsEnabled(BOOL enabled) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *directory = SPKSideloadDiagnosticsDirectoryURL();
    NSURL *enabledURL = SPKSideloadDiagnosticsEnabledURL();
    if (!directory || !enabledURL) return;

    if (enabled) {
        [fileManager createDirectoryAtURL:directory
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:nil];
        [@"enabled\n" writeToURL:enabledURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fileManager removeItemAtURL:enabledURL error:nil];
    }
}

@interface SPKSideloadDiagnosticsViewController ()
@property (nonatomic, strong) UITextView *textView;
@end

@implementation SPKSideloadDiagnosticsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Notification Diagnostics";
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    self.textView.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    self.textView.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    self.textView.textContainerInset = UIEdgeInsetsMake(16.0, 14.0, 16.0, 14.0);
    self.textView.layer.cornerRadius = 14.0;
    [self.view addSubview:self.textView];

    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12.0],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12.0],
    ]];

    UIBarButtonItem *copyItem = SPKMediaChromeTopBarButtonItem(@"copy", self, @selector(copyTapped));
    copyItem.accessibilityLabel = @"Copy";
    UIBarButtonItem *shareItem = SPKMediaChromeTopBarButtonItem(@"share", self, @selector(shareTapped));
    shareItem.accessibilityLabel = @"Share";
    UIBarButtonItem *clearItem = SPKMediaChromeTopBarButtonItem(@"trash", self, @selector(clearTapped));
    clearItem.accessibilityLabel = @"Clear";
    clearItem.tintColor = [SPKUtils SPKColor_InstagramDestructive];
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ clearItem, copyItem, shareItem ]);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadContent];
}

- (void)reloadContent {
    NSURL *logURL = SPKSideloadDiagnosticsLogURL();
    NSString *content = logURL ? [NSString stringWithContentsOfURL:logURL encoding:NSUTF8StringEncoding error:nil] : nil;
    if (content.length > 0) {
        self.textView.text = content;
    } else if (!SPKSideloadDiagnosticsEnabled()) {
        self.textView.text = @"Diagnostics are off. Enable Log Notification Diagnostics in Tools > Instagram, reproduce the notification issue, then return here.";
    } else {
        self.textView.text = @"No diagnostics yet. Leave logging enabled and reproduce the notification issue.";
    }
}

- (void)copyTapped {
    NSURL *logURL = SPKSideloadDiagnosticsLogURL();
    NSString *content = logURL ? [NSString stringWithContentsOfURL:logURL encoding:NSUTF8StringEncoding error:nil] : nil;
    if (content.length > 0) [UIPasteboard generalPasteboard].string = content;
}

- (void)shareTapped {
    NSURL *logURL = SPKSideloadDiagnosticsLogURL();
    if (logURL && [[NSFileManager defaultManager] fileExistsAtPath:logURL.path]) {
        [SPKUtils showShareVC:logURL];
    }
}

- (void)clearTapped {
    __weak typeof(self) weakSelf = self;
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:@"Clear Diagnostics?"
                                                message:@"This permanently deletes the collected notification diagnostics."
                                                actions:@[
        [SPKIGAlertAction actionWithTitle:@"Cancel" style:SPKIGAlertActionStyleCancel handler:nil],
        [SPKIGAlertAction actionWithTitle:@"Clear" style:SPKIGAlertActionStyleDestructive handler:^{
            NSURL *logURL = SPKSideloadDiagnosticsLogURL();
            if (logURL) [[NSFileManager defaultManager] removeItemAtURL:logURL error:nil];
            [weakSelf reloadContent];
        }],
    ]];
}

@end
