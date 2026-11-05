#import "SPKStrings.h"
#import "SPKChangelogViewController.h"

#import "SPKChangelogView.h"
#import "../../Utils.h"

@interface SPKChangelogViewController ()
@property (nonatomic, strong) SPKChangelogView *changelogView;
@end

@implementation SPKChangelogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SPKL(@"ABOUT_INFORMATION_CHANGELOG_TITLE");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    // The whole history, nothing folded; the page's own title would repeat the navigation bar's.
    self.changelogView = [[SPKChangelogView alloc] initWithOptions:SPKChangelogOptionHidePageHeader | SPKChangelogOptionMarkInstalled];
    self.changelogView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.changelogView];
    [NSLayoutConstraint activateConstraints:@[
        [self.changelogView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.changelogView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.changelogView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.changelogView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self.changelogView loadIfNeeded];
}

@end
