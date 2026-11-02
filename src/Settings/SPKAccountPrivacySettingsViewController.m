#import "SPKStrings.h"
#import "SPKAccountPrivacySettingsViewController.h"

#import "../Shared/Account/SPKAccountManager.h"
#import "../Shared/Account/SPKAccountPrivacyService.h"
#import "../Shared/UI/SPKMediaChrome.h"
#import "../Shared/UI/SPKNotificationCenter.h"
#import "../Shared/UI/SPKNotificationPillView.h"
#import "../Utils.h"
#import "SPKSetting.h"
#import "SPKTopicSettingsSupport.h"

// The sheet only ever shows two switches and one footer line. Everything that
// happens around them (a slow save, a failed save, a failed read) is reported
// through a notification pill, so the rows never change shape and never need
// rebuilding while they animate.

static NSString *const kSPKAccountPrivacyRowKey = @"accountPrivacySetting";
enum { kSPKAccountPrivacySettingCount = 2 };
// Work that finishes faster than this needs no pill: a pill flashing in and
// out is only noise.
static NSTimeInterval const kSPKAccountPrivacyPillDelay = 0.5;
// Once a pill is up it stays long enough to be read before it resolves, or
// work that lands just after the delay would only flash it.
static NSTimeInterval const kSPKAccountPrivacyPillMinimumVisible = 1.0;
static CGFloat const kSPKAccountPrivacySheetMinimumHeight = 220.0;

// Last values Instagram reported, per account PK, so the sheet opens on real
// switch positions instead of dimmed placeholders. This is a cache of server
// state rather than a preference: it is keyed by PK explicitly, independent
// of the per-account preference namespacing, and the server value always
// replaces it once a read lands.
static NSString *const kSPKAccountPrivacyCacheKey = @"profile_account_privacy_cache";
static NSString *const kSPKAccountPrivacyCacheFields[kSPKAccountPrivacySettingCount] = {
    @"follow_lists",
    @"self_in_lists",
};

// The values on screen. Switching accounts drops them; the sheet then starts
// again from the new account's cached values.
static NSNumber *sValues[kSPKAccountPrivacySettingCount];
static BOOL sReading[kSPKAccountPrivacySettingCount];
static BOOL sSaving[kSPKAccountPrivacySettingCount];
static BOOL sCacheLoaded;
// Bumped on every account switch. A request started for the previous account
// still calls back afterwards; comparing generations drops that stale answer.
static NSUInteger sGeneration;
static __weak SPKAccountPrivacySettingsViewController *sVisiblePage;

@interface SPKAccountPrivacySettingsViewController ()
@property (nonatomic) CGFloat spk_measuredSheetHeight;
- (void)spk_syncVisibleRows;
@end

static void SPKAccountPrivacyLoadCacheIfNeeded(void) {
    if (sCacheLoaded)
        return;
    NSString *pk = [SPKUtils currentUserPK];
    if (pk.length == 0)
        return;
    sCacheLoaded = YES;

    NSDictionary *cache = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSPKAccountPrivacyCacheKey];
    NSDictionary *entry = [cache[pk] isKindOfClass:[NSDictionary class]] ? cache[pk] : nil;
    for (NSInteger index = 0; index < kSPKAccountPrivacySettingCount; index++) {
        id value = entry[kSPKAccountPrivacyCacheFields[index]];
        if (!sValues[index] && [value isKindOfClass:[NSNumber class]])
            sValues[index] = @([value boolValue]);
    }
}

static void SPKAccountPrivacyStoreCache(SPKAccountPrivacySetting setting, NSNumber *value) {
    NSString *pk = [SPKUtils currentUserPK];
    if (pk.length == 0 || !value)
        return;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *cache = [[defaults dictionaryForKey:kSPKAccountPrivacyCacheKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *entry = [cache[pk] isKindOfClass:[NSDictionary class]] ? [cache[pk] mutableCopy] : [NSMutableDictionary dictionary];
    entry[kSPKAccountPrivacyCacheFields[setting]] = @(value.boolValue);
    cache[pk] = entry;
    [defaults setObject:cache forKey:kSPKAccountPrivacyCacheKey];
}

static BOOL SPKAccountPrivacyRowIsInteractive(SPKAccountPrivacySetting setting) {
    return sValues[setting] != nil && !sSaving[setting];
}

static SPKAccountPrivacySetting SPKAccountPrivacySettingForRow(id row, BOOL *found) {
    NSNumber *setting = [row isKindOfClass:[SPKSetting class]] ? ((SPKSetting *)row).userInfo[kSPKAccountPrivacyRowKey] : nil;
    if (found)
        *found = setting != nil;
    return (SPKAccountPrivacySetting)setting.integerValue;
}

// The service's own descriptions are technical and English, so pills only show
// localized copy or Instagram's own, already localized, reason.
static NSString *SPKAccountPrivacySaveFailureReason(NSError *error) {
    if (error.code == SPKAccountPrivacyErrorServerRefused) {
        NSString *serverMessage = error.userInfo[SPKAccountPrivacyServerMessageKey];
        return serverMessage.length > 0 ? serverMessage : SPKL(@"ACCOUNT_PRIVACY_SAVE_ERROR_FALLBACK");
    }
    return SPKL(@"ACCOUNT_PRIVACY_REQUEST_ERROR_MESSAGE");
}

// Error pills skip the notification registry on purpose: they are the only sign
// that something did not work, so they are not something to switch off. The
// pill plays its own error haptic when it turns red.
static void SPKAccountPrivacyShowErrorPill(SPKNotificationPillView *pill,
                                           NSString *title,
                                           NSString *subtitle,
                                           void (^retry)(void)) {
    if (!pill)
        pill = [[SPKNotificationCenter shared] beginUnmanagedProgressWithTitle:nil onCancel:nil];
    pill.cancellable = NO;
    __weak SPKNotificationPillView *weakPill = pill;
    pill.onRetry = ^{
        [weakPill dismiss];
        retry();
    };
    // With no subtitle the pill says "Tap to retry" on its own.
    [pill showErrorWithTitle:title subtitle:subtitle icon:nil];
}

// Hands the outcome of a piece of work to `finish` together with its progress
// pill, if one was needed. The pill only appears if the work outlasts the
// delay, and once up it stays for the minimum time before `finish` runs.
typedef void (^SPKAccountPrivacyPillFinish)(SPKNotificationPillView *_Nullable pill);
typedef void (^SPKAccountPrivacyPillResolver)(SPKAccountPrivacyPillFinish finish);

static SPKAccountPrivacyPillResolver SPKAccountPrivacyDelayedPill(NSString *title) {
    __block SPKNotificationPillView *pill = nil;
    __block CFTimeInterval shownAt = 0;
    __block BOOL resolved = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKAccountPrivacyPillDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (resolved)
            return;
        pill = [[SPKNotificationCenter shared] beginUnmanagedProgressWithTitle:title onCancel:nil];
        pill.cancellable = NO;
        [pill setProgressIndeterminate:YES];
        shownAt = CACurrentMediaTime();
    });

    return ^(SPKAccountPrivacyPillFinish finish) {
        resolved = YES;
        if (!pill) {
            finish(nil);
            return;
        }
        NSTimeInterval wait = MAX(0.0, kSPKAccountPrivacyPillMinimumVisible - (CACurrentMediaTime() - shownAt));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            finish(pill);
        });
    };
}

static void SPKAccountPrivacyRead(SPKAccountPrivacySetting setting, void (^done)(BOOL failed)) {
    if (sReading[setting] || sSaving[setting]) {
        done(NO);
        return;
    }
    sReading[setting] = YES;

    NSUInteger generation = sGeneration;
    [SPKAccountPrivacyService fetchSetting:setting
                               completion:^(NSNumber *value, NSError *error) {
                                   if (generation != sGeneration)
                                       return;
                                   sReading[setting] = NO;
                                   // A save started while this read was out; its answer wins.
                                   if (!error && !sSaving[setting]) {
                                       sValues[setting] = value;
                                       SPKAccountPrivacyStoreCache(setting, value);
                                   }
                                   [sVisiblePage spk_syncVisibleRows];
                                   done(error != nil);
                               }];
}

// Reads both values. Rows showing a cached value keep it while the read is
// out and simply move if Instagram reports something else; that refresh is
// silent. Only when a value is missing does the read get a loading pill, and
// only then is a failure worth reporting, once for the pair.
static void SPKAccountPrivacyReadAll(void) {
#if SPK_DEV
    // The load simulations act as a first-ever open, or a cached sheet would
    // refresh silently and never show the loading or load-error pill.
    NSString *simulation = [SPKUtils getStringPref:@"dev_account_privacy_simulate"];
    if ([simulation isEqualToString:@"slow"] || [simulation isEqualToString:@"read_failed"]) {
        for (NSInteger index = 0; index < kSPKAccountPrivacySettingCount; index++) {
            if (!sSaving[index])
                sValues[index] = nil;
        }
        sCacheLoaded = YES;
    }
#endif
    SPKAccountPrivacyLoadCacheIfNeeded();
    [sVisiblePage spk_syncVisibleRows];

    BOOL anyMissing = NO;
    for (NSInteger index = 0; index < kSPKAccountPrivacySettingCount; index++)
        anyMissing = anyMissing || sValues[index] == nil;

    SPKAccountPrivacyPillResolver resolver = anyMissing ? SPKAccountPrivacyDelayedPill(SPKL(@"ACCOUNT_PRIVACY_LOADING_PROGRESS")) : nil;
    NSUInteger generation = sGeneration;
    __block NSInteger pending = kSPKAccountPrivacySettingCount;
    __block BOOL anyFailed = NO;
    for (NSInteger index = 0; index < kSPKAccountPrivacySettingCount; index++) {
        SPKAccountPrivacyRead((SPKAccountPrivacySetting)index, ^(BOOL failed) {
            anyFailed = anyFailed || failed;
            pending -= 1;
            if (pending > 0 || !resolver)
                return;
            resolver(^(SPKNotificationPillView *pill) {
                if (!anyFailed || generation != sGeneration) {
                    [pill dismiss];
                    return;
                }
                SPKAccountPrivacyShowErrorPill(pill, SPKL(@"ACCOUNT_PRIVACY_LOAD_ERROR_TITLE"), nil, ^{
                    SPKAccountPrivacyReadAll();
                });
            });
        });
    }
}

static void SPKAccountPrivacySave(SPKAccountPrivacySetting setting, BOOL value) {
    if (sSaving[setting]) {
        // A switch rebuilt mid-save can still be flipped; put it back.
        [sVisiblePage spk_syncVisibleRows];
        return;
    }

    // The switch has already moved under the user's finger; keep that position
    // while the request is out and only move it back if Instagram says no.
    NSNumber *previous = sValues[setting];
    sValues[setting] = @(value);
    sSaving[setting] = YES;
    [sVisiblePage spk_syncVisibleRows];

    SPKAccountPrivacyPillResolver resolver = SPKAccountPrivacyDelayedPill(SPKL(@"ACCOUNT_PRIVACY_SAVING_PROGRESS"));
    NSUInteger generation = sGeneration;
    [SPKAccountPrivacyService setSetting:setting
                                   value:value
                              completion:^(NSNumber *result, NSError *error) {
                                  if (generation != sGeneration) {
                                      resolver(^(SPKNotificationPillView *pill) {
                                          [pill dismiss];
                                      });
                                      return;
                                  }
                                  sSaving[setting] = NO;
                                  if (error) {
                                      sValues[setting] = previous;
                                  } else {
                                      sValues[setting] = result;
                                      SPKAccountPrivacyStoreCache(setting, result);
                                  }
                                  [sVisiblePage spk_syncVisibleRows];

                                  // A pill that was shown ends in a check, as other
                                  // progress pills do; with no pill the switch alone
                                  // is the confirmation.
                                  resolver(^(SPKNotificationPillView *pill) {
                                      if (error) {
                                          SPKAccountPrivacyShowErrorPill(pill,
                                                                         SPKL(@"ACCOUNT_PRIVACY_SAVE_ERROR_TITLE"),
                                                                         SPKAccountPrivacySaveFailureReason(error),
                                                                         ^{
                                                                             SPKAccountPrivacySave(setting, value);
                                                                         });
                                      } else {
                                          [pill showSuccessWithTitle:SPKL(@"ACCOUNT_PRIVACY_SAVED_SUCCESS") subtitle:nil icon:nil];
                                      }
                                  });
                              }];
}

static void SPKAccountPrivacyObserveAccountChange(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:SPKAccountDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
                                                          sGeneration += 1;
                                                          sCacheLoaded = NO;
                                                          for (NSInteger index = 0; index < kSPKAccountPrivacySettingCount; index++) {
                                                              sValues[index] = nil;
                                                              sReading[index] = NO;
                                                              sSaving[index] = NO;
                                                          }
                                                          if (sVisiblePage)
                                                              SPKAccountPrivacyReadAll();
                                                      }];
    });
}

static SPKSetting *SPKAccountPrivacySwitch(SPKAccountPrivacySetting setting, NSString *title, NSString *iconName) {
    SPKSetting *row = [SPKSetting switchCellWithTitle:title icon:SPKSettingsIcon(iconName) defaultsKey:@""];
    NSMutableDictionary *userInfo = [row.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    userInfo[kSPKAccountPrivacyRowKey] = @(setting);
    row.userInfo = userInfo;

    row.switchValueProvider = ^BOOL {
        return sValues[setting].boolValue;
    };
    // Only "no value yet" dims the row. A save in flight just stops touches,
    // which spk_syncVisibleRows applies to the live switch.
    row.enabledProvider = ^BOOL {
        return sValues[setting] != nil;
    };
    row.switchChangeHandler = ^(BOOL isOn) {
        SPKAccountPrivacySave(setting, isOn);
    };
    return row;
}

static NSArray *SPKAccountPrivacySectionsForSearch(BOOL forSearch) {
    // Rows render their switch position as soon as they are built, so pick up
    // the cached values before that.
    SPKAccountPrivacyLoadCacheIfNeeded();
    NSArray *rows = @[
        SPKAccountPrivacySwitch(SPKAccountPrivacySettingFollowLists, SPKL(@"ACCOUNT_PRIVACY_HIDE_FOLLOW_LISTS_TITLE"), @"users"),
        SPKAccountPrivacySwitch(SPKAccountPrivacySettingSelfInLists, SPKL(@"ACCOUNT_PRIVACY_HIDE_SELF_TITLE"), @"eye_off")
    ];
    NSMutableArray *sections = [NSMutableArray arrayWithObject:SPKTopicSection(SPKL(@"ACCOUNT_PRIVACY_SECTION_HEADER"), rows, SPKL(@"ACCOUNT_PRIVACY_SECTION_FOOTER"))];
#if SPK_DEV
    if (!forSearch) {
        SPKSetting *simulate = [SPKSetting menuCellWithTitle:SPKL(@"ACCOUNT_PRIVACY_DEV_SIMULATE_TITLE")
                                                        icon:SPKSettingsIcon(@"warning")
                                                        menu:SPKAccountPrivacySimulationMenu()];
        [sections addObject:SPKTopicSection(@"", @[ simulate ], SPKL(@"ACCOUNT_PRIVACY_DEV_SIMULATE_FOOTER"))];
    }
#endif
    return sections;
}

@implementation SPKAccountPrivacySettingsViewController

- (instancetype)init {
    self = [super initWithTitle:SPKL(@"ACCOUNT_PRIVACY_TITLE")
                       sections:SPKAccountPrivacySectionsForSearch(NO)
                 reduceMargin:NO];
    if (self)
        SPKAccountPrivacyObserveAccountChange();
    return self;
}

+ (NSArray *)searchSections {
    return SPKAccountPrivacySectionsForSearch(YES);
}

+ (void)presentFromViewController:(UIViewController *)presenter {
    if (!presenter)
        return;

    SPKAccountPrivacySettingsViewController *page = [self new];
    UINavigationController *nav = [[SPKChromeNavigationController alloc] initWithRootViewController:page];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;

    UISheetPresentationController *sheet = nav.sheetPresentationController;
    sheet.prefersGrabberVisible = YES;
    sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
    if (@available(iOS 16.0, *)) {
        // One stop, exactly as tall as the rows need.
        __weak SPKAccountPrivacySettingsViewController *weakPage = page;
        sheet.detents = @[ [UISheetPresentationControllerDetent
            customDetentWithIdentifier:@"spk.account.privacy.fitted"
                              resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                                  CGFloat height = weakPage.spk_measuredSheetHeight;
                                  if (height <= 0.0)
                                      height = context.maximumDetentValue * 0.45;
                                  return MIN(MAX(height, kSPKAccountPrivacySheetMinimumHeight), context.maximumDetentValue);
                              }] ];
    } else {
        // iOS 15 has no custom detents, so the closest fixed stop has to do.
        sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent ];
    }

    // Settings can sit over Instagram surfaces that force their own style;
    // inherit the presenter's so the sheet does not flip light or dark.
    UIUserInterfaceStyle style = presenter.view.window.traitCollection.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified)
        style = presenter.traitCollection.userInterfaceStyle;
    if (style != UIUserInterfaceStyleUnspecified) {
        nav.overrideUserInterfaceStyle = style;
        page.overrideUserInterfaceStyle = style;
    }

    [presenter presentViewController:nav animated:YES completion:nil];
}

- (void)setupNavigationItems {
    [super setupNavigationItems];
    // Sparkle's half-sheets close with the grabber or a swipe, never a button.
    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[]);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Two switches need no search field.
    self.navigationItem.searchController = nil;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat measured = [SPKUtils sheetHeightFittingContentOfScrollView:self.tableView];
    if (measured > 0.0 && fabs(measured - self.spk_measuredSheetHeight) > 0.5) {
        self.spk_measuredSheetHeight = measured;
        if (@available(iOS 16.0, *))
            [self.navigationController.sheetPresentationController invalidateDetents];
    }
    [SPKUtils updateScrollingForFittedContent:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    sVisiblePage = self;
    // Every open re-reads, so the sheet always ends on Instagram's current
    // value; rows that already have one keep it in the meantime.
    SPKAccountPrivacyReadAll();
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (sVisiblePage == self)
        sVisiblePage = nil;
}

- (void)refresh {
    SPKAccountPrivacyReadAll();
}

// Applies the current values to the switches already on screen. The rows are
// never rebuilt: a rebuild swaps in a fresh switch and cuts its animation.
- (void)spk_syncVisibleRows {
    UITableView *tableView = self.tableView;
    if (!tableView.window)
        return;

    for (NSIndexPath *indexPath in tableView.indexPathsForVisibleRows) {
        if (indexPath.section >= (NSInteger)self.sections.count)
            continue;
        NSArray *rows = self.sections[indexPath.section][@"rows"];
        if (indexPath.row >= (NSInteger)rows.count)
            continue;

        BOOL found = NO;
        SPKAccountPrivacySetting setting = SPKAccountPrivacySettingForRow(rows[indexPath.row], &found);
        UITableViewCell *cell = found ? [tableView cellForRowAtIndexPath:indexPath] : nil;
        if (![cell.accessoryView isKindOfClass:[UISwitch class]])
            continue;

        UISwitch *toggle = (UISwitch *)cell.accessoryView;
        BOOL hasValue = sValues[setting] != nil;
        BOOL on = sValues[setting].boolValue;
        if (toggle.isOn != on)
            [toggle setOn:on animated:YES];

        // A saving row keeps its full look and only stops taking touches; a row
        // with no value yet is dimmed like any unavailable setting.
        toggle.enabled = hasValue;
        toggle.userInteractionEnabled = SPKAccountPrivacyRowIsInteractive(setting);

        if ([cell.contentConfiguration isKindOfClass:[UIListContentConfiguration class]]) {
            UIListContentConfiguration *config = (UIListContentConfiguration *)cell.contentConfiguration;
            UIColor *textColor = hasValue ? [SPKUtils SPKColor_InstagramPrimaryText] : [SPKUtils SPKColor_InstagramSecondaryText];
            if (![config.textProperties.color isEqual:textColor]) {
                config.textProperties.color = textColor;
                cell.contentConfiguration = config;
            }
        }
    }
}

@end
