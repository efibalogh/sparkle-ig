#import "SPKStrings.h"
#import "SPKLanguagePicker.h"
#import "SPKLanguagePack.h"
#import "../Shared/i18n/SPKLanguagePackAddFlow.h"
#import "../Shared/i18n/SPKLanguagePackUpdater.h"
#import "../Shared/UI/SPKNotificationCenter.h"
#import "SPKSetting.h"
#import "SPKSettingsViewController.h"
#import "SPKTopicSettingsSupport.h"
#import "../AssetUtils.h"
#import "../Shared/UI/SPKIGAlertPresenter.h"
#import "../Shared/UI/SPKMediaChrome.h"
#import "../Utils.h"


// Names the translation issue form. A bare issues/new carries a title but lands
// on the template chooser, because blank issues are disabled for this repository.
static NSString *const kSPKTranslationIssueURL =
    @"https://github.com/efibalogh/sparkle-ig/issues/new?template=3-translation.yaml";
static NSString *const kSPKTranslationGuideURL = @"https://github.com/efibalogh/sparkle-ig/blob/main/TRANSLATING.md";

/// The issue form's Language field, prefilled with the language being read right
/// now. Left empty for English, where the report is as likely to be about some
/// other language as about the text on screen.
static NSString *SPKTranslationIssueURLString(void) {
    NSString *active = [SPKStrings activeLanguage];
    if (active.length == 0 || [active isEqualToString:@"en"])
        return kSPKTranslationIssueURL;
    NSString *encoded = [active stringByAddingPercentEncodingWithAllowedCharacters:
                                    NSCharacterSet.URLQueryAllowedCharacterSet]
                        ?: active;
    return [NSString stringWithFormat:@"%@&language=%@", kSPKTranslationIssueURL, encoded];
}

// Endonyms (each language's own name) — best UX for a language picker. Covers the
// languages a community catalog exists for; an imported pack naming any other
// language falls back to what the system calls it.
static NSDictionary<NSString *, NSString *> *SPKLangNames(void) {
    static NSDictionary *m = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ m = @{
        @"en":@"English", @"ar":@"العربية", @"de":@"Deutsch", @"el":@"Ελληνικά",
        @"es-ES":@"Español", @"fr":@"Français", @"hi":@"हिन्दी", @"it":@"Italiano",
        @"ja":@"日本語", @"ko":@"한국어", @"lt":@"Lietuvių", @"pt-BR":@"Português (Brasil)", @"ru":@"Русский",
        @"pl":@"Polski", @"ro":@"Română",
        @"tr":@"Türkçe", @"uk":@"Українська", @"vi":@"Tiếng Việt", @"zh-Hans":@"简体中文",
        @"zh-Hant":@"繁體中文", @"fa":@"فارسی", @"th":@"ไทย", @"fil":@"Filipino",
        // Named here rather than left to the endonym fallback, which gets these three wrong:
        // it answers "Indonesia" (the country) for id, lowercases the Spanish variant, and reads
        // the BE in gsw-BE as Belgium, yielding "Schwiizertüütsch (Belgie)" for a Bernese pack.
        @"id":@"Bahasa Indonesia", @"es-419":@"Español (Latinoamérica)", @"gsw-BE":@"Bärndütsch" }; });
    return m;
}

NSString *SPKLanguageDisplayName(NSString *code) {
    if (code.length == 0 || [code isEqualToString:@"auto"]) return SPKL(@"LANGUAGE_SYSTEM_DEFAULT");
    NSString *known = SPKLangNames()[code];
    if (known)
        return known;
    // Ask the language to name itself, so an imported pack for a language Sparkle
    // has never shipped still reads naturally to the person who installed it.
    NSString *endonym = [[NSLocale localeWithLocaleIdentifier:code] localizedStringForLocaleIdentifier:code];
    return endonym.length > 0 ? endonym : code;
}

@interface SPKLanguagePickerViewController : SPKSettingsViewController

@property (nonatomic, copy) NSArray<NSString *> *languageCodes;
@property (nonatomic, copy) NSArray<SPKLanguagePack *> *installedPacks;
@property (nonatomic, assign) BOOL checkingForUpdates;

@end

@implementation SPKLanguagePickerViewController

- (instancetype)init {
    self = [super initWithTitle:SPKL(@"LANGUAGE_TITLE") sections:@[] reduceMargin:NO];
    if (self) {
        [self reloadLanguages];
    }
    return self;
}

- (void)reloadLanguages {
    self.installedPacks = [SPKLanguagePackManager installedPacks];
    NSArray<NSString *> *languages = [SPKStrings supportedLanguages];
    // Following the system is only a choice when there is something else to
    // follow it to. With English alone installed, the row would be a second name
    // for the only row beneath it.
    NSMutableArray<NSString *> *codes = [NSMutableArray array];
    if (languages.count > 1)
        [codes addObject:@"auto"];
    [codes addObjectsFromArray:languages];
    self.languageCodes = [codes copy];
    [self rebuildSections];
}

/// The row to show as chosen. Without an override Sparkle follows the system, but
/// while that row is hidden the language it resolves to is the one to check.
- (NSString *)selectedLanguageCode {
    NSString *override = [SPKStrings languageOverride];
    if (override.length > 0)
        return override;
    return [self.languageCodes containsObject:@"auto"] ? @"auto" : @"en";
}

- (nullable SPKLanguagePack *)packForCode:(NSString *)code {
    for (SPKLanguagePack *pack in self.installedPacks) {
        if ([pack.code isEqualToString:code])
            return pack;
    }
    return nil;
}

- (void)rebuildSections {
    NSString *selected = [self selectedLanguageCode];
    __weak typeof(self) weakSelf = self;
    NSMutableArray<SPKSetting *> *languageRows = [NSMutableArray arrayWithCapacity:self.languageCodes.count];
    for (NSString *code in self.languageCodes) {
        BOOL isSelected = [selected isEqualToString:code];
        SPKLanguagePack *pack = [self packForCode:code];
        NSString *subtitle = pack ? [NSString stringWithFormat:SPKL(@"LANGUAGE_PACK_COVERAGE_SUBTITLE_FORMAT"),
                                                               (long)pack.coveragePercent]
                                  : nil;
        SPKSetting *row = [SPKSetting buttonCellWithTitle:SPKLanguageDisplayName(code)
                                                 subtitle:subtitle
                                                     icon:nil
                                                   action:^{
                                                       [weakSelf selectLanguageCode:code];
                                                   }];
        NSMutableDictionary *userInfo = [@{
            @"languageCode" : code,
            @"checkmarked" : @(isSelected),
            @"hidesDisclosure" : @(YES),
        } mutableCopy];
        if (pack)
            userInfo[@"pack"] = pack;
        row.userInfo = userInfo;
        [languageRows addObject:row];
    }

    // One row, not four. Downloading a published language is the answer almost every time; a file,
    // a link, and the English template belong to whoever is building a translation, and they live in
    // that screen's own more menu rather than as three rows nobody else needs to read past.
    // No icon on this row or the update toggle below it: the language rows above carry none, and a
    // glyph on the only row in its own titled section is decoration the section header already does.
    SPKSetting *addRow = [SPKSetting buttonCellWithTitle:SPKL(@"LANGUAGE_PACK_ADD_TITLE")
                                                subtitle:nil
                                                    icon:nil
                                                  action:^{
                                                      [weakSelf presentCatalog];
                                                  }];
    // The subtitle answers the only question the row raises once it is on: whether it has actually
    // run. Before the first check there is nothing to report, so the row stands on its title.
    NSString *lastChecked = [self lastCheckedSubtitle];
    SPKSetting *autoUpdateRow =
        lastChecked ? [SPKSetting switchCellWithTitle:SPKL(@"LANGUAGE_PACK_AUTO_UPDATE_TITLE")
                                             subtitle:lastChecked
                                          defaultsKey:kSPKLanguagePackAutoUpdateKey]
                    : [SPKSetting switchCellWithTitle:SPKL(@"LANGUAGE_PACK_AUTO_UPDATE_TITLE")
                                          defaultsKey:kSPKLanguagePackAutoUpdateKey];

    // The automatic check only runs when the version moves, which is the only thing that can change a
    // pack published as a release asset. A pack rebuilt and republished under a release the user
    // already has is invisible to that, so this is the way to pick one up.
    SPKSetting *checkNowRow =
        [SPKSetting buttonCellWithTitle:self.checkingForUpdates ? SPKL(@"LANGUAGE_PACK_CHECKING_TITLE")
                                                                : SPKL(@"LANGUAGE_PACK_CHECK_NOW_TITLE")
                               subtitle:nil
                                   icon:nil
                                 action:^{ [weakSelf checkForPackUpdates]; }];
    checkNowRow.userInfo = @{ @"hidesDisclosure" : @(YES) };

    // Reporting and contributing are different jobs with different destinations:
    // one fills in a form, the other opens the guide that needs no build.
    SPKSetting *reportRow = [SPKSetting linkCellWithTitle:SPKL(@"LANGUAGE_REPORT_ISSUE_TITLE")
                                                 subtitle:SPKL(@"LANGUAGE_REPORT_ISSUE_SUBTITLE")
                                                     icon:SPKSettingsIcon(@"flag")
                                                      url:SPKTranslationIssueURLString()];
    SPKSetting *contributeRow = [SPKSetting linkCellWithTitle:SPKL(@"LANGUAGE_CONTRIBUTE_TITLE")
                                                     subtitle:SPKL(@"LANGUAGE_CONTRIBUTE_SUBTITLE")
                                                         icon:SPKSettingsIcon(@"translate")
                                                          url:kSPKTranslationGuideURL];
    [self replaceSections:@[
        SPKTopicSection(@"", languageRows, SPKL(@"LANGUAGE_LIST_FOOTER")),
        SPKTopicSection(SPKL(@"LANGUAGE_PACKS_HEADER"), @[ addRow ], SPKL(@"LANGUAGE_PACK_ADD_FOOTER")),
        SPKTopicSection(SPKL(@"LANGUAGE_PACK_UPDATES_HEADER"), @[ autoUpdateRow, checkNowRow ], SPKL(@"LANGUAGE_PACK_UPDATES_FOOTER")),
        SPKTopicSection(@"", @[ reportRow, contributeRow ], SPKL(@"LANGUAGE_HELP_FOOTER")),
    ]];
}

- (void)selectLanguageCode:(NSString *)code {
    if ([[self selectedLanguageCode] isEqualToString:code]) {
        return;
    }
    [self applyLanguageCode:code];
}

- (void)applyLanguageCode:(NSString *)code {
    [SPKStrings setLanguageOverride:[code isEqualToString:@"auto"] ? nil : code];
    [NSUserDefaults.standardUserDefaults synchronize];
    [self rebuildSections];
    [self dismissViewControllerAnimated:YES completion:^{
        [SPKUtils showRestartConfirmation];
    }];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    SPKSetting *row = self.sections[indexPath.section][@"rows"][indexPath.row];
    if (row.userInfo[@"languageCode"]) {
        if ([row.userInfo[@"checkmarked"] boolValue]) {
            UIImage *image = [SPKAssetUtils instagramIconNamed:@"circle_check_filled"
                                                      pointSize:24.0
                                                  renderingMode:UIImageRenderingModeAlwaysTemplate];
            UIImageView *checkmark = [[UIImageView alloc] initWithImage:image];
            checkmark.tintColor = [SPKUtils SPKColor_InstagramBlue];
            cell.accessoryView = checkmark;
        } else {
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    }
    return cell;
}

#pragma mark - Deleting a pack

- (nullable SPKLanguagePack *)packAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)self.sections.count)
        return nil;
    NSArray<SPKSetting *> *rows = self.sections[indexPath.section][@"rows"];
    if (indexPath.row >= (NSInteger)rows.count)
        return nil;
    id pack = rows[indexPath.row].userInfo[@"pack"];
    return [pack isKindOfClass:[SPKLanguagePack class]] ? pack : nil;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self packAtIndexPath:indexPath] != nil;
}

// The base returns None for every row, which suppresses swipe-to-delete outright --
// canEditRowAtIndexPath: alone is not enough to bring it back.
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self packAtIndexPath:indexPath] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

// The system's own delete button would be a red bar reading "Delete"; every other
// Sparkle list deletes through a trash glyph on Instagram's destructive red.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKLanguagePack *pack = [self packAtIndexPath:indexPath];
    if (!pack)
        return nil;

    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:nil
                                              handler:^(__unused UIContextualAction *action, __unused UIView *sourceView,
                                                        void (^completionHandler)(BOOL)) {
                                                  [weakSelf deletePack:pack];
                                                  completionHandler(YES);
                                              }];
    deleteAction.image = [SPKAssetUtils menuIconNamed:@"trash"];
    deleteAction.backgroundColor = [SPKUtils SPKColor_InstagramDestructive];
    deleteAction.accessibilityLabel = SPKL(@"LANGUAGE_PACK_DELETE_ACCESSIBILITY_LABEL");
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction ]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete)
        return;
    [self deletePack:[self packAtIndexPath:indexPath]];
}

- (void)deletePack:(SPKLanguagePack *)pack {
    if (!pack)
        return;

    BOOL wasActive = [[SPKStrings languageOverride] isEqualToString:pack.code];
    NSError *error = nil;
    if (![SPKLanguagePackManager removePack:pack error:&error]) {
        [self presentErrorWithTitle:SPKL(@"LANGUAGE_PACK_DELETE_ERROR_TITLE") message:error.localizedDescription];
        return;
    }

    [self reloadLanguages];
    // The interface is still rendered in the language that just went away.
    if (wasActive) {
        [NSUserDefaults.standardUserDefaults synchronize];
        [SPKUtils showRestartConfirmation];
    }
}

#pragma mark - Adding a language

- (void)presentCatalog {
    __weak typeof(self) weakSelf = self;
    [SPKLanguagePackAddFlow presentCatalogFrom:self
                                      onImport:^(NSString *code) {
                                          [weakSelf reloadLanguages];
                                      }];
}

/// Runs the check the user asked for, ignoring the version stamp the automatic one goes by. A refresh
/// announces itself with its own pill naming the languages, so the only case left to report here is
/// finding nothing, which otherwise looks like the button did nothing at all.
- (void)checkForPackUpdates {
    if (self.checkingForUpdates)
        return;
    self.checkingForUpdates = YES;
    [self rebuildSections];

    __weak typeof(self) weakSelf = self;
    [SPKLanguagePackUpdater checkForUpdatesNow:^(NSInteger refreshed, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf)
            return;
        strongSelf.checkingForUpdates = NO;
        if (refreshed > 0)
            [strongSelf reloadLanguages];  // also rebuilds, and the pack list itself has changed
        else
            [strongSelf rebuildSections];

        if (error) {
            [strongSelf presentErrorWithTitle:SPKL(@"LANGUAGE_PACK_CATALOG_ERROR")
                                      message:error.localizedDescription];
        } else if (refreshed == 0) {
            SPKNotify(kSPKNotificationLanguagePackUpdate, SPKL(@"LANGUAGE_PACK_ALL_CURRENT_TOAST"), nil,
                      @"translate", SPKNotificationToneForIconResource(@"translate"));
        }
    }];
}

/// When the check last succeeded, or nil before it ever has.
- (nullable NSString *)lastCheckedSubtitle {
    NSDate *last = [SPKLanguagePackUpdater lastCheckDate];
    if (!last)
        return nil;  // nothing has run yet, so there is no date to claim
    NSDateFormatter *formatter = [NSDateFormatter new];
    // Written in the language Sparkle is being read in, so day names and ordering match the rest of
    // the screen. The shared helper keeps the device's regional variant when the language is merely
    // being followed, which is what preserves its 12/24-hour clock.
    formatter.locale = [SPKUtils spk_activeFormattingLocale];
    // The subtitle gets one line, so the date has to stay short. A check that just ran makes
    // "Today at 03:24" the useful reading; once the date is old enough to spell out, the time of day
    // stops being the interesting part, so it goes and the date alone still fits.
    BOOL relative = [NSCalendar.currentCalendar isDateInToday:last] || [NSCalendar.currentCalendar isDateInYesterday:last];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = relative ? NSDateFormatterShortStyle : NSDateFormatterNoStyle;
    formatter.doesRelativeDateFormatting = relative;
    return [NSString stringWithFormat:SPKL(@"LANGUAGE_PACK_LAST_CHECKED_FORMAT"),
                                      [formatter stringFromDate:last]];
}

- (void)presentErrorWithTitle:(NSString *)title message:(NSString *)message {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:title
                                                message:message.length > 0 ? message : SPKL(@"LANGUAGE_PACK_ERROR_GENERIC")
                                                actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK")
                                                                                       style:SPKIGAlertActionStyleCancel
                                                                                     handler:nil] ]];
}

@end

void SPKPresentLanguagePicker(UIViewController *presenter) {
    if (!presenter) {
        return;
    }
    SPKLanguagePickerViewController *picker = [SPKLanguagePickerViewController new];
    UINavigationController *navigationController = [[SPKChromeNavigationController alloc] initWithRootViewController:picker];
    navigationController.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = navigationController.sheetPresentationController;
    if (sheet) {
        sheet.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
        sheet.prefersGrabberVisible = YES;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
    }
    [presenter presentViewController:navigationController animated:YES completion:nil];
}
