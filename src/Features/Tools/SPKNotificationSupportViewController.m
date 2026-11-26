#import "SPKNotificationSupportViewController.h"

#import <UIKit/UIKit.h>

#import "../../Settings/SPKSetting.h"
#import "../../Settings/SPKTopicSettingsSupport.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"
#import "SPKNotificationSupport.h"

@interface SPKNotificationSupportViewController ()
@property (nonatomic, strong, nullable) SPKNotificationSupportReport *report;
@property (nonatomic) BOOL running;
@end

@implementation SPKNotificationSupportViewController

- (instancetype)init {
    return [super initWithTitle:SPKL(@"TOOLS_NOTIFICATION_SUPPORT_TITLE") sections:@[] reduceMargin:NO];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Coming back from iOS Settings re-checks, so the page never shows stale results.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(runChecks)
                                               name:UIApplicationWillEnterForegroundNotification
                                             object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self runChecks];
}

- (void)runChecks {
    if (self.running)
        return;
    self.running = YES;
    if (!self.report)
        [self rebuildSections];
    __weak typeof(self) weakSelf = self;
    [SPKNotificationSupport runWithCompletion:^(SPKNotificationSupportReport *report) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf)
            return;
        strongSelf.running = NO;
        strongSelf.report = report;
        [strongSelf rebuildSections];
    }];
}

static UIColor *SPKStatusColor(SPKNotificationCheckStatus status) {
    switch (status) {
    case SPKNotificationCheckStatusPass: return [SPKUtils SPKColor_InstagramSuccess];
    case SPKNotificationCheckStatusWarn: return UIColor.systemOrangeColor;
    case SPKNotificationCheckStatusFail: return [SPKUtils SPKColor_InstagramDestructive];
    case SPKNotificationCheckStatusInfo: return [SPKUtils SPKColor_InstagramSecondaryText];
    }
    return [SPKUtils SPKColor_InstagramSecondaryText];
}

static NSString *SPKStatusIconName(SPKNotificationCheckStatus status) {
    switch (status) {
    case SPKNotificationCheckStatusPass: return @"circle_check";
    case SPKNotificationCheckStatusWarn: return @"warning";
    case SPKNotificationCheckStatusFail: return @"error";
    case SPKNotificationCheckStatusInfo: return @"info";
    }
    return @"info";
}

static NSString *const kSPKValueColorKey = @"spkSupportValueColor";

static SPKSetting *SPKStatusRow(NSString *title, NSString *subtitle, SPKNotificationCheckStatus status) {
    SPKSetting *row = [SPKSetting staticCellWithTitle:title subtitle:subtitle icon:SPKSettingsIcon(SPKStatusIconName(status))];
    row.iconTintColor = SPKStatusColor(status);
    return row;
}

// Title and value side by side behind the status glyph. Anything already
// explained by the verdict keeps its glyph but goes grey.
static SPKSetting *SPKCheckRow(SPKNotificationCheckItem *item) {
    SPKSetting *row = [SPKSetting valueCellWithTitle:item.title subtitle:item.value icon:SPKSettingsIcon(SPKStatusIconName(item.status))];
    UIColor *color = item.muted ? [SPKUtils SPKColor_InstagramTertiaryText] : SPKStatusColor(item.status);
    row.iconTintColor = color;
    row.userInfo = @{kSPKValueColorKey : color};
    return row;
}

- (void)rebuildSections {
    SPKNotificationSupportReport *report = self.report;
    if (!report) {
        [self replaceSections:@[ SPKTopicSection(@"", @[ [SPKSetting staticCellWithTitle:SPKL(@"TOOLS_NOTIFICATION_SUPPORT_CHECKING_TITLE")
                                                                                subtitle:@""
                                                                                    icon:SPKSettingsIcon(@"notification")] ],
                                                 nil) ]];
        return;
    }

    NSMutableArray *sections = [NSMutableArray array];

    SPKNotificationCheckStatus verdictStatus = report.level == SPKNotificationSupportLevelFull      ? SPKNotificationCheckStatusPass
                                               : report.level == SPKNotificationSupportLevelPartial ? SPKNotificationCheckStatusWarn
                                                                                                    : SPKNotificationCheckStatusFail;
    // With no notifications at all the title already says it, so the fix is
    // the whole story. Otherwise the detail says what is lost, then the fix.
    NSString *verdictSubtitle = report.verdictDetail;
    if (report.fix.length)
        verdictSubtitle = report.level == SPKNotificationSupportLevelNone ? report.fix : [NSString stringWithFormat:@"%@ %@", report.verdictDetail, report.fix];
    SPKSetting *verdict = SPKStatusRow(report.verdictTitle, verdictSubtitle, verdictStatus);
    verdict.tintColor = SPKStatusColor(verdictStatus);
    NSMutableArray *verdictRows = [NSMutableArray arrayWithObject:verdict];
    if (report.permissionNeedsAttention) {
        [verdictRows addObject:[SPKSetting buttonCellWithTitle:SPKL(@"TOOLS_NOTIFICATION_SUPPORT_OPEN_SETTINGS_TITLE")
                                                      subtitle:nil
                                                          icon:SPKSettingsIcon(@"notification")
                                                        action:^{
                                                            NSString *target = UIApplicationOpenSettingsURLString;
                                                            if (@available(iOS 16.0, *))
                                                                target = UIApplicationOpenNotificationSettingsURLString;
                                                            NSURL *url = [NSURL URLWithString:target];
                                                            if (url)
                                                                [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
                                                        }]];
    }
    [sections addObject:SPKTopicSection(@"", verdictRows, nil)];

    for (SPKNotificationCheckSection *section in report.sections) {
        NSMutableArray *rows = [NSMutableArray array];
        NSMutableArray<NSString *> *notes = [NSMutableArray array];
        for (SPKNotificationCheckItem *item in section.items) {
            [rows addObject:SPKCheckRow(item)];
            if (item.note.length && !item.muted)
                [notes addObject:[NSString stringWithFormat:SPKL(@"TOOLS_NOTIFICATION_SUPPORT_NOTE_FORMAT"), item.title, item.note]];
        }
        NSString *footer = notes.count ? [notes componentsJoinedByString:@"\n"] : nil;
        if (rows.count)
            [sections addObject:SPKTopicSection(section.title, rows, footer)];
    }

    __weak typeof(self) weakSelf = self;
    SPKSetting *copy = [SPKSetting buttonCellWithTitle:SPKL(@"TOOLS_NOTIFICATION_SUPPORT_COPY_REPORT_TITLE")
                                              subtitle:nil
                                                  icon:SPKSettingsIcon(@"copy")
                                                action:^{
                                                    NSString *text = weakSelf.report.plainTextReport;
                                                    if (!text.length)
                                                        return;
                                                    UIPasteboard.generalPasteboard.string = text;
                                                    SPKNotify(kSPKNotificationNotificationSupport, SPKL(@"TOOLS_NOTIFICATION_SUPPORT_COPIED_TOAST"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                }];
    [sections addObject:SPKTopicSection(@"", @[ copy ], SPKL(@"TOOLS_NOTIFICATION_SUPPORT_ACTIONS_FOOTER"))];

    [self replaceSections:sections];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    NSArray *rows = self.sections[indexPath.section][@"rows"];
    SPKSetting *row = indexPath.row < (NSInteger)rows.count ? rows[indexPath.row] : nil;
    UIColor *valueColor = [row isKindOfClass:[SPKSetting class]] ? row.userInfo[kSPKValueColorKey] : nil;
    if ([valueColor isKindOfClass:[UIColor class]] && [cell.contentConfiguration isKindOfClass:[UIListContentConfiguration class]]) {
        UIListContentConfiguration *config = (UIListContentConfiguration *)cell.contentConfiguration;
        config.secondaryTextProperties.color = valueColor;
        cell.contentConfiguration = config;
    }
    return cell;
}

@end
