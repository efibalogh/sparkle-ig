#import "SPKStrings.h"
#import "SPKSettingsViewController.h"
#import "../App/SPKStartupHooks.h"
#import "../AssetUtils.h"
#import "../Features/Messages/MessageSeenButtons.h"
#import "../Features/Profile/FollowIndicator.h"
#import "../Shared/ActionButton/ActionButtonCore.h"
#import "../Shared/Avatars/SPKAvatarCache.h"
#import "../Shared/UI/SPKIGAlertPresenter.h"
#import "../Shared/UI/SPKMediaChrome.h"
#import "../Shared/UI/SPKSwitch.h"
#import "../App/SPKCore.h"
#import "SPKOnboardingViewController.h"
#import "SPKLanguagePicker.h"
#import "SPKPreferenceAvailability.h"
#import "SPKSettingsInfoSheetViewController.h"
#import "SPKWhatsNewViewController.h"

static char rowStaticRef[] = "row";
static CGFloat const kSPKSettingsRemoteImageSize = 45.0;

static NSCache<NSString *, UIImage *> *SPKSettingsRemoteImageCache(void) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 64;
    });
    return cache;
}

static double SPKNormalizedStepperValue(SPKSetting *row, double value) {
    if (!row)
        return value;

    if (row.max >= row.min) {
        value = MIN(row.max, MAX(row.min, value));
    }

    if (row.step > 0.0) {
        double origin = row.min;
        double stepCount = round((value - origin) / row.step);
        value = origin + (stepCount * row.step);
        if (row.max >= row.min) {
            value = MIN(row.max, MAX(row.min, value));
        }
    }

    double nearestInteger = round(value);
    if (fabs(value - nearestInteger) < 0.0000001) {
        value = nearestInteger;
    }

    return value;
}

@interface SPKSettingsViewController () <UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate, UITableViewDropDelegate, UISearchResultsUpdating, UITextFieldDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *sections;
@property (nonatomic, strong) NSArray *originalSections;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UIBarButtonItem *applyRestartItem;
@property (nonatomic) BOOL reduceMargin;
@property (nonatomic) BOOL defersRestartPrompt;
@property (nonatomic) BOOL hasPendingRestartChanges;
@property (nonatomic) BOOL didAttemptOnboarding;
@property (nonatomic) BOOL showsLanguageSelector;

@end

///

static NSMutableArray *SPKMutableSectionsCopy(NSArray *sections) {
    NSMutableArray *mutableSections = [NSMutableArray array];
    for (NSDictionary *section in sections) {
        NSMutableDictionary *mutableSection = [section mutableCopy];
        NSArray *rows = section[@"rows"];
        mutableSection[@"rows"] = rows ? [rows mutableCopy] : [NSMutableArray array];
        [mutableSections addObject:mutableSection];
    }
    return mutableSections;
}

// Mutable copy with rows whose `hiddenProvider` returns YES dropped. Used to
// derive the displayed `sections` from the full `originalSections`, so a row can
// disappear/reappear live in response to another control (e.g. a passcode row
// that only exists while a lock switch is on) without restructuring the tree.
static NSMutableArray *SPKVisibleSectionsCopy(NSArray *sections) {
    NSMutableArray *mutableSections = SPKMutableSectionsCopy(sections);
    for (NSMutableDictionary *section in mutableSections) {
        NSMutableArray *rows = section[@"rows"];
        if (![rows isKindOfClass:[NSArray class]])
            continue;
        NSMutableArray *visibleRows = [NSMutableArray arrayWithCapacity:rows.count];
        for (id row in rows) {
            if ([row isKindOfClass:[SPKSetting class]] && ((SPKSetting *)row).hiddenProvider && ((SPKSetting *)row).hiddenProvider())
                continue;
            [visibleRows addObject:row];
        }
        section[@"rows"] = visibleRows;
    }
    return mutableSections;
}

static UIImage *SPKSettingsSizedRemoteImage(UIImage *image, BOOL circular) {
    if (!image)
        return nil;

    CGSize targetSize = CGSizeMake(kSPKSettingsRemoteImageSize, kSPKSettingsRemoteImageSize);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = UIScreen.mainScreen.scale;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *_Nonnull context) {
        CGRect bounds = (CGRect){.origin = CGPointZero, .size = targetSize};
        if (circular) {
            [[UIBezierPath bezierPathWithOvalInRect:bounds] addClip];
        }

        CGFloat scale = MAX(targetSize.width / image.size.width, targetSize.height / image.size.height);
        CGSize drawSize = CGSizeMake(image.size.width * scale, image.size.height * scale);
        CGRect drawRect = CGRectMake((targetSize.width - drawSize.width) / 2.0,
                                     (targetSize.height - drawSize.height) / 2.0,
                                     drawSize.width,
                                     drawSize.height);
        [image drawInRect:drawRect];
    }];
}

static NSString *SPKSettingsNormalizedQuery(NSString *query) {
    return [[query ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] localizedLowercaseString];
}

static NSString *SPKSettingsAccessoryText(SPKSetting *row) {
    NSString *providedText = row.accessoryTextProvider ? row.accessoryTextProvider() : nil;
    if ([providedText isKindOfClass:[NSString class]])
        return providedText;

    NSString *staticText = [row.userInfo[@"accessoryText"] isKindOfClass:[NSString class]] ? row.userInfo[@"accessoryText"] : nil;
    return staticText;
}

static NSArray<NSString *> *SPKSettingsSearchTokens(NSString *query) {
    NSString *normalized = SPKSettingsNormalizedQuery(query);
    if (normalized.length == 0)
        return @[];

    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSCharacterSet *separators = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    for (NSString *token in [normalized componentsSeparatedByCharactersInSet:separators]) {
        if (token.length > 0) {
            [tokens addObject:token];
        }
    }
    return tokens;
}

static void SPKSettingsAppendSearchString(NSMutableArray<NSString *> *strings, id value) {
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
        [strings addObject:value];
    } else if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *stringValue = [value stringValue];
        if (stringValue.length > 0)
            [strings addObject:stringValue];
    }
}

static void SPKSettingsCollectMenuSearchStrings(UIMenu *menu, NSMutableArray<NSString *> *strings) {
    if (![menu isKindOfClass:[UIMenu class]])
        return;
    SPKSettingsAppendSearchString(strings, menu.title);

    for (UIMenuElement *element in menu.children ?: @[]) {
        if ([element isKindOfClass:[UIMenu class]]) {
            SPKSettingsCollectMenuSearchStrings((UIMenu *)element, strings);
            continue;
        }

        SPKSettingsAppendSearchString(strings, element.title);
        if ([element isKindOfClass:[UICommand class]]) {
            NSDictionary *propertyList = ((UICommand *)element).propertyList;
            SPKSettingsAppendSearchString(strings, propertyList[@"defaultsKey"]);
            SPKSettingsAppendSearchString(strings, propertyList[@"value"]);
            SPKSettingsAppendSearchString(strings, propertyList[@"iconName"]);
        }
    }
}

static NSString *SPKSettingsRowSearchHaystack(SPKSetting *row, NSString *path, NSString *sectionTitle, NSString *sectionFooter) {
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    SPKSettingsAppendSearchString(strings, row.title);
    SPKSettingsAppendSearchString(strings, row.subtitle);
    SPKSettingsAppendSearchString(strings, row.defaultsKey);
    SPKSettingsAppendSearchString(strings, row.placeholder);
    SPKSettingsAppendSearchString(strings, row.label);
    SPKSettingsAppendSearchString(strings, row.singularLabel);
    SPKSettingsAppendSearchString(strings, row.searchKeywords);
    SPKSettingsAppendSearchString(strings, row.helpText);
    SPKSettingsAppendSearchString(strings, path);
    SPKSettingsAppendSearchString(strings, sectionTitle);
    SPKSettingsAppendSearchString(strings, sectionFooter);

    NSString *accessoryText = [row.userInfo[@"accessoryText"] isKindOfClass:[NSString class]] ? row.userInfo[@"accessoryText"] : nil;
    SPKSettingsAppendSearchString(strings, accessoryText);
    SPKSettingsCollectMenuSearchStrings(row.baseMenu, strings);
    return SPKSettingsNormalizedQuery([strings componentsJoinedByString:@" "]);
}

static BOOL SPKSettingsRowMatchesTokens(SPKSetting *row, NSArray<NSString *> *tokens, NSString *path, NSString *sectionTitle, NSString *sectionFooter) {
    if (![row isKindOfClass:[SPKSetting class]])
        return NO;
    if (tokens.count == 0)
        return YES;

    NSString *haystack = SPKSettingsRowSearchHaystack(row, path, sectionTitle, sectionFooter);
    for (NSString *token in tokens) {
        if ([haystack rangeOfString:token].location == NSNotFound) {
            return NO;
        }
    }
    return YES;
}

static NSArray<NSString *> *SPKSettingsPathComponentsByAppending(NSArray<NSString *> *components, NSString *component) {
    if (component.length == 0)
        return components ?: @[];
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithArray:components ?: @[]];
    [result addObject:component];
    return [result copy];
}

static NSString *SPKSettingsBreadcrumbText(NSArray<NSString *> *components) {
    return [components componentsJoinedByString:@" \u203a "];
}

static UIImage *SPKSettingsBreadcrumbChevronImage(void) {
    UIImage *image = [SPKAssetUtils instagramIconNamed:@"chevron_right"
                                             pointSize:12.0
                                         renderingMode:UIImageRenderingModeAlwaysTemplate];
    if (!image) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:10.0 weight:UIImageSymbolWeightSemibold];
        image = [[UIImage systemImageNamed:@"chevron.right" withConfiguration:config] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return image;
}

// MARK: - Section header info button

static CGFloat const kSPKSectionInfoIconSize = 18.0;
static CGFloat const kSPKSectionInfoTouchSize = 40.0;
static NSInteger const kSPKSectionInfoButtonTag = 0x5C1F0;
static CGFloat const kSPKSectionHeaderTextBottomInset = 7.0;

static UIImage *SPKSettingsInfoGlyph(void) {
    UIImage *icon = [SPKAssetUtils instagramIconNamed:@"info"
                                            pointSize:kSPKSectionInfoIconSize
                                        renderingMode:UIImageRenderingModeAlwaysTemplate];
    if (!icon) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:kSPKSectionInfoIconSize
                                                                                            weight:UIImageSymbolWeightRegular];
        icon = [[UIImage systemImageNamed:@"info.circle" withConfiguration:config] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return icon;
}

/// Vertical centre of a stock grouped header's text, measured from the bottom
/// of the header box: the title sits on the box's bottom edge with a small pad
/// under it. Measuring the box (rather than constraining to UIKit's own label,
/// which is not in the view tree yet when a header is about to be displayed)
/// keeps the glyph on the title's line without touching private views.
static CGFloat SPKSettingsHeaderTextCenterOffsetFromBottom(void) {
    UIListContentConfiguration *reference = [UIListContentConfiguration groupedHeaderConfiguration];
    UIFont *font = reference.textProperties.font ?: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    return kSPKSectionHeaderTextBottomInset + (font.lineHeight / 2.0);
}

@implementation SPKSettingsViewController

- (UIView *)selectionBackgroundView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = [SPKUtils SPKColor_InstagramPressedBackground];
    return view;
}

- (instancetype)initWithTitle:(NSString *)title sections:(NSArray *)sections reduceMargin:(BOOL)reduceMargin {
    self = [super init];

    if (self) {
        self.title = title;
        self.reduceMargin = reduceMargin;

        // Exclude development cells from release builds
        NSMutableArray *mutableSections = SPKMutableSectionsCopy(sections);

        [mutableSections enumerateObjectsWithOptions:NSEnumerationReverse
                                          usingBlock:^(NSDictionary *section, NSUInteger index, BOOL *stop) {
                                              if ([section[@"header"] hasPrefix:@"_"] && [section[@"footer"] hasPrefix:@"_"]) {
                                                  if (![[SPKUtils IGVersionString] isEqualToString:@"0.0.0"]) {
                                                      [mutableSections removeObjectAtIndex:index];
                                                  }
                                              }

                                              else if ([section[@"header"] isEqualToString:@"Experimental"]) {
                                                  if (![[SPKUtils IGVersionString] hasSuffix:@"-dev"]) {
                                                      [mutableSections removeObjectAtIndex:index];
                                                  }
                                              }
                                          }];

        self.originalSections = [mutableSections copy];
        self.sections = SPKVisibleSectionsCopy(mutableSections);
    }

    return self;
}

- (instancetype)init {
    self = [self initWithTitle:[SPKTweakSettings title] sections:[SPKTweakSettings sections] reduceMargin:YES];
    if (self) {
        self.searchesAllSettings = YES;
        self.showsLanguageSelector = YES;
    }
    return self;
}

- (UITableViewStyle)preferredTableViewStyle {
    return UITableViewStyleInsetGrouped;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.navigationController.navigationBar.prefersLargeTitles = NO;

    UITableViewStyle style = [self preferredTableViewStyle];
    UIColor *backgroundColor = (style == UITableViewStylePlain)
                                   ? [SPKUtils SPKColor_InstagramBackground]
                                   : [SPKUtils SPKColor_InstagramGroupedBackground];
    self.view.backgroundColor = backgroundColor;

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:style];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.dragInteractionEnabled = [self pageAllowsReordering];
    self.tableView.dragDelegate = self;
    self.tableView.dropDelegate = self;
    self.tableView.backgroundColor = backgroundColor;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    self.tableView.tintColor = [SPKUtils SPKColor_InstagramBlue];

    // Number pads (used by some text-field rows) have no return key; tap
    // elsewhere to dismiss the keyboard.
    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(spk_dismissKeyboard)];
    dismissTap.cancelsTouchesInView = NO;
    [self.tableView addGestureRecognizer:dismissTap];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;
    // Disable header/footer height estimation. The grouped footers are multi-line
    // self-sizing labels; with a non-zero estimate UIKit lays them out short, then
    // corrects to the real (taller) height as they scroll into view, which shifts
    // the content offset and reads as the table "jumping" (most visible on pages
    // with long footers like Storage). Computing the real heights up front removes it.
    self.tableView.estimatedSectionHeaderHeight = 0.0;
    self.tableView.estimatedSectionFooterHeight = 0.0;

    [self.view addSubview:self.tableView];
    [self setupNavigationItems];
    [self setupSearchController];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setupNavigationItems];
    [self.tableView reloadData];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self presentIntroSheetsIfNeeded];
}

// Intro sheets shown when the user opens Sparkle settings. Only the root settings
// page presents them (sub-topic pages are also SPKSettingsViewControllers pushed
// onto the same stack), and at most one flow per process:
//   - First-ever run (`app_first_run` never stamped) → onboarding only. On finish
//     it stamps both keys so a fresh install doesn't also get What's New.
//   - Otherwise, already onboarded but a new version's notes are unseen (including
//     upgraders who predate the feature) → What's New only.
// Gating predicates live in SPKCore so the launch-time auto-open agrees. The Tools
// "Show Onboarding" / "Show What's New" buttons replay each directly without
// touching this state (onFinish is nil).
- (void)presentIntroSheetsIfNeeded {
    if (self.didAttemptOnboarding)
        return;
    if (self.navigationController.viewControllers.firstObject != self)
        return;
    if (self.presentedViewController)
        return;

    self.didAttemptOnboarding = YES;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (SPKCoreOnboardingPending()) {
        [SPKOnboardingViewController presentFromViewController:self onFinish:^{
            [defaults setValue:SPKVersionString forKey:@"app_first_run"];
            [defaults setValue:SPKVersionString forKey:@"app_last_whatsnew_version"];
        }];
        return;
    }

    if (SPKCoreWhatsNewPending()) {
        [SPKWhatsNewViewController presentFromViewController:self onFinish:^{
            [defaults setValue:SPKVersionString forKey:@"app_last_whatsnew_version"];
        }];
    }
}

- (void)setupNavigationItems {
    BOOL isModalRoot = self.navigationController.presentingViewController &&
                       self.navigationController.viewControllers.firstObject == self;
    NSArray<UIBarButtonItem *> *leadingItems = isModalRoot
                                                   ? @[ SPKMediaChromeTopBarButtonItem(@"xmark", self, @selector(closeTapped)) ]
                                                   : @[];
    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, leadingItems);

    NSMutableArray<UIBarButtonItem *> *trailingItems = [NSMutableArray array];
    if (self.showsLanguageSelector) {
        [trailingItems addObject:SPKMediaChromeTopBarButtonItemWithTint(@"translate",
                                                                        self,
                                                                        @selector(showLanguagePicker),
                                                                        [SPKUtils SPKColor_InstagramPrimaryText],
                                                                        SPKL(@"LANGUAGE_TITLE"))];
    }
    if (self.defersRestartPrompt) {
        UIBarButtonItem *applyItem = SPKMediaChromeTopBarButtonItemWithStyle(@"check",
                                                                             self,
                                                                             @selector(applyRestartChanges),
                                                                             UIBarButtonItemStyleDone,
                                                                             [SPKUtils SPKColor_InstagramPrimaryText],
                                                                             SPKL(@"SETTINGS_SETTINGS_APPLY_LIQUID_GLASS_CHANGES_TEXT"));
        applyItem.enabled = self.hasPendingRestartChanges;
        self.applyRestartItem = applyItem;
        [trailingItems addObject:applyItem];
    } else {
        self.applyRestartItem = nil;
    }
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, trailingItems);
}

- (void)showLanguagePicker {
    SPKPresentLanguagePicker(self);
}

- (void)setupSearchController {
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.hidesNavigationBarDuringPresentation = NO;
    [self.searchController.searchBar setImage:[SPKAssetUtils instagramIconNamed:@"search" pointSize:18.0]
                             forSearchBarIcon:UISearchBarIconSearch
                                        state:UIControlStateNormal];
    self.searchController.searchBar.placeholder = self.searchesAllSettings ? SPKL(@"SETTINGS_SETTINGS_SEARCH_SETTINGS_TEXT") : [NSString stringWithFormat:SPKL(@"SETTINGS_SETTINGS_SEARCH_VALUE_FORMAT"), self.title ?: @"settings"];
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;
}

- (void)closeTapped {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

// MARK: - UITableViewDataSource

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKSetting *row = self.sections[indexPath.section][@"rows"][indexPath.row];
    if (!row)
        return nil;

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *cellContentConfig = cell.defaultContentConfiguration;
    // Plain (flat) pages use the page background so rows sit edge-to-edge with no
    // grouped-card tint; inset-grouped pages keep the elevated secondary color.
    cell.backgroundColor = ([self preferredTableViewStyle] == UITableViewStylePlain)
                               ? [SPKUtils SPKColor_InstagramBackground]
                               : [SPKUtils SPKColor_InstagramSecondaryBackground];
    cell.tintColor = [SPKUtils SPKColor_InstagramBlue];
    cell.selectedBackgroundView = [self selectionBackgroundView];
    cellContentConfig.textProperties.color = [SPKUtils SPKColor_InstagramPrimaryText];
    cellContentConfig.secondaryTextProperties.color = [SPKUtils SPKColor_InstagramSecondaryText];
    cellContentConfig.textProperties.numberOfLines = 0;
    cellContentConfig.secondaryTextProperties.numberOfLines = 0;
    cellContentConfig.secondaryTextProperties.lineBreakMode = NSLineBreakByWordWrapping;
    BOOL rowEnabled = (row.userInfo[@"enabled"] ? [row.userInfo[@"enabled"] boolValue] : YES) &&
                      (!row.enabledProvider || row.enabledProvider()) &&
                      SPKPrefIsAvailable(row.defaultsKey);

    cellContentConfig.text = row.title;

    // Subtitle
    if (row.subtitle.length) {
        cellContentConfig.secondaryText = row.subtitle;
        cellContentConfig.textToSecondaryTextVerticalPadding = 4.5;
    }

    // Icon
    UIImage *rowIcon = row.iconProvider ? row.iconProvider() : row.icon;
    if (rowIcon != nil) {
        cellContentConfig.image = rowIcon;
        if ([row.userInfo[@"avatarIcon"] boolValue]) {
            // Pre-rendered circular avatar image: apply the same sizing as remote imageUrl.
            cellContentConfig.imageProperties.tintColor = nil;
            cellContentConfig.imageProperties.maximumSize = CGSizeMake(kSPKSettingsRemoteImageSize, kSPKSettingsRemoteImageSize);
            cellContentConfig.imageProperties.reservedLayoutSize = CGSizeMake(kSPKSettingsRemoteImageSize, kSPKSettingsRemoteImageSize);
            cellContentConfig.imageToTextPadding = 14;
        } else {
            cellContentConfig.imageProperties.tintColor = row.iconTintColor ?: [SPKUtils SPKColor_InstagramPrimaryText];
        }
    }

    // Self-healing avatar (SPKAvatarCache, keyed by PK)
    if (row.avatarPK.length > 0) {
        UIImage *warm = [[SPKAvatarCache shared] cachedImageForPK:row.avatarPK];
        if (warm) {
            cellContentConfig.image = SPKSettingsSizedRemoteImage(warm, YES);
            cellContentConfig.imageProperties.tintColor = nil;
        } else {
            // Crisp native-size glyph placeholder (the asset is 24px — don't upscale).
            NSString *glyphName = row.avatarIsGroup ? @"group" : @"user_circle";
            UIImage *placeholder = [SPKAssetUtils instagramIconNamed:glyphName pointSize:24.0 renderingMode:UIImageRenderingModeAlwaysTemplate]
                                       ?: [SPKAssetUtils instagramIconNamed:@"user_circle" pointSize:24.0 renderingMode:UIImageRenderingModeAlwaysTemplate];
            cellContentConfig.image = placeholder;
            cellContentConfig.imageProperties.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
            [self loadAvatarForPK:row.avatarPK urlString:row.avatarURLString atIndexPath:indexPath forTableView:tableView];
        }
        cellContentConfig.imageProperties.maximumSize = CGSizeMake(kSPKSettingsRemoteImageSize, kSPKSettingsRemoteImageSize);
        cellContentConfig.imageProperties.reservedLayoutSize = CGSizeMake(kSPKSettingsRemoteImageSize, kSPKSettingsRemoteImageSize);
        cellContentConfig.imageToTextPadding = 14;
    }

    // Image url
    if (row.avatarPK.length == 0 && row.imageUrl != nil) {
        BOOL circular = ![row.userInfo[@"remoteImageCircular"] isEqual:@NO];
        NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", row.imageUrl.absoluteString, circular ? @"circle" : @"square"];
        UIImage *cachedImage = [SPKSettingsRemoteImageCache() objectForKey:cacheKey];
        if (cachedImage) {
            cellContentConfig.image = cachedImage;
            cellContentConfig.imageProperties.maximumSize = CGSizeMake(kSPKSettingsRemoteImageSize, kSPKSettingsRemoteImageSize);
            cellContentConfig.imageProperties.reservedLayoutSize = CGSizeMake(kSPKSettingsRemoteImageSize, kSPKSettingsRemoteImageSize);
        } else {
            [self loadImageFromURL:row.imageUrl atIndexPath:indexPath forTableView:tableView circular:circular];
        }

        cellContentConfig.imageToTextPadding = 14;
    }

    // Custom Tint Color
    if (row.tintColor != nil && rowEnabled) {
        cellContentConfig.textProperties.color = row.tintColor;
    }

    switch (row.type) {
    case SPKTableCellStatic: {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        break;
    }

    case SPKTableCellLink: {
        cellContentConfig.textProperties.color = [SPKUtils SPKColor_InstagramBlue];
        UIFont *linkFont = [row.userInfo[@"titleFont"] isKindOfClass:[UIFont class]]
                               ? row.userInfo[@"titleFont"]
                               : [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightMedium];
        cellContentConfig.textProperties.font = linkFont;

        cell.selectionStyle = UITableViewCellSelectionStyleDefault;

        UIImageView *imageView = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"compass" pointSize:20.0]];
        imageView.tintColor = [SPKUtils SPKColor_InstagramTertiaryText];
        cell.accessoryView = imageView;

        break;
    }

    case SPKTableCellSwitch: {
        SPKSwitch *toggle = [SPKSwitch new];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (row.switchValueProvider) {
            toggle.on = row.switchValueProvider();
        } else if (!SPKPrefIsAvailable(row.defaultsKey)) {
            toggle.on = NO;
        } else {
            NSString *effectiveKey = SPKEffectivePreferenceKey(row.defaultsKey);
            id storedValue = [defaults objectForKey:effectiveKey] ?: [defaults objectForKey:row.defaultsKey];
            NSNumber *defaultValue = row.userInfo[@"defaultValue"];
            toggle.on = storedValue ? [storedValue boolValue] : defaultValue.boolValue;
        }
        if (!row.switchValueProvider && row.mutuallyExclusiveDefaultsKey.length) {
            BOOL otherOn = [SPKUtils getBoolPref:row.mutuallyExclusiveDefaultsKey];
            toggle.enabled = toggle.isOn || !otherOn;
        }
        toggle.enabled = toggle.enabled && rowEnabled;
        if (!rowEnabled) {
            cellContentConfig.textProperties.color = [SPKUtils SPKColor_InstagramSecondaryText];
            cellContentConfig.secondaryTextProperties.color = [SPKUtils SPKColor_InstagramTertiaryText];
        }

        objc_setAssociatedObject(toggle, rowStaticRef, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];

        cell.accessoryView = toggle;
        cell.editingAccessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        break;
    }

    case SPKTableCellStepper: {
        UIStepper *stepper = [UIStepper new];
        stepper.minimumValue = row.min;
        stepper.maximumValue = row.max;
        stepper.stepValue = row.step;
        stepper.value = SPKNormalizedStepperValue(row, [SPKUtils getDoublePref:row.defaultsKey]);

        objc_setAssociatedObject(stepper, rowStaticRef, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        [stepper addTarget:self
                      action:@selector(stepperChanged:)
            forControlEvents:UIControlEventValueChanged];

        // Template subtitle
        if (row.subtitle.length) {
            cellContentConfig.secondaryText = [self formatString:row.subtitle withValue:stepper.value step:row.step label:row.label singularLabel:row.singularLabel];
        }

        cell.accessoryView = stepper;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        break;
    }

    case SPKTableCellButton: {
        NSString *accessoryText = SPKSettingsAccessoryText(row);
        if (rowEnabled && accessoryText.length > 0) {
            cellContentConfig.secondaryText = accessoryText;
            cellContentConfig.prefersSideBySideTextAndSecondaryText = YES;
            cellContentConfig.secondaryTextProperties.color = [SPKUtils SPKColor_InstagramSecondaryText];
            cellContentConfig.secondaryTextProperties.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize
                                                                               weight:UIFontWeightMedium];
        }
        // Avatar rows read as flat list entries (like Profile Analyzer), not
        // settings nav rows — no disclosure chevron.
        BOOL hidesChevron = row.avatarPK.length > 0 || [row.userInfo[@"hidesDisclosure"] boolValue];
        cell.accessoryType = (rowEnabled && !hidesChevron) ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        if (!rowEnabled) {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cellContentConfig.textProperties.color = [SPKUtils SPKColor_InstagramSecondaryText];
            cellContentConfig.secondaryTextProperties.color = [SPKUtils SPKColor_InstagramTertiaryText];
        }
        break;
    }

    case SPKTableCellMenu: {
        UIButton *menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [menuButton setTitle:@"•••" forState:UIControlStateNormal];
        menuButton.menu = [row menuForButton:menuButton];
        menuButton.showsMenuAsPrimaryAction = YES;
        menuButton.enabled = rowEnabled;
        menuButton.titleLabel.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize
                                                       weight:UIFontWeightMedium];
        menuButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [menuButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [menuButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        UIButtonConfiguration *config = menuButton.configuration ?: [UIButtonConfiguration plainButtonConfiguration];
        config.contentInsets = NSDirectionalEdgeInsetsMake(8, 8, 8, 8);
        config.image = [UIImage systemImageNamed:@"chevron.up.chevron.down"];
        config.imagePlacement = NSDirectionalRectEdgeTrailing;
        config.imagePadding = 6.0;
        config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:10.0 weight:UIImageSymbolWeightBold];

        menuButton.configuration = config;
        // Must be set AFTER assigning the configuration: UIButtonConfiguration
        // re-manages titleLabel and defaults it to multi-line, so a long selected
        // value wraps onto a second line inside the accessory. Clamp it to one line
        // (truncating) here so the value stays on the row like every other picker.
        menuButton.titleLabel.numberOfLines = 1;
        menuButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        menuButton.tintColor = rowEnabled ? [SPKUtils SPKColor_InstagramSecondaryText] : [SPKUtils SPKColor_InstagramTertiaryText];
        if (!rowEnabled) {
            cellContentConfig.textProperties.color = [SPKUtils SPKColor_InstagramSecondaryText];
            cellContentConfig.secondaryTextProperties.color = [SPKUtils SPKColor_InstagramTertiaryText];
        }

        [menuButton sizeToFit];

        cell.accessoryView = menuButton;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        break;
    }

    case SPKTableCellNavigation: {
        NSString *accessoryText = SPKSettingsAccessoryText(row);
        if (rowEnabled && accessoryText.length > 0) {
            cellContentConfig.secondaryText = accessoryText;
            cellContentConfig.prefersSideBySideTextAndSecondaryText = YES;
            cellContentConfig.secondaryTextProperties.numberOfLines = 1;
            cellContentConfig.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingTail;
            cellContentConfig.secondaryTextProperties.color = [SPKUtils SPKColor_InstagramSecondaryText];
            cellContentConfig.secondaryTextProperties.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize
                                                                               weight:UIFontWeightMedium];
        }
        cell.accessoryType = rowEnabled ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        if (!rowEnabled) {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cellContentConfig.textProperties.color = [SPKUtils SPKColor_InstagramSecondaryText];
            cellContentConfig.secondaryTextProperties.color = [SPKUtils SPKColor_InstagramTertiaryText];
        }
        break;
    }

    case SPKTableCellTextField: {
        UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 150, 34)];
        textField.textAlignment = NSTextAlignmentRight;
        textField.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightMedium];
        textField.textColor = rowEnabled ? [SPKUtils SPKColor_InstagramPrimaryText] : [SPKUtils SPKColor_InstagramTertiaryText];
        textField.placeholder = row.placeholder;
        textField.keyboardType = row.keyboardType;
        textField.text = [SPKUtils getStringPref:row.defaultsKey];
        textField.enabled = rowEnabled;
        textField.returnKeyType = UIReturnKeyDone;
        textField.delegate = self;

        if (!rowEnabled) {
            cellContentConfig.textProperties.color = [SPKUtils SPKColor_InstagramSecondaryText];
        }

        objc_setAssociatedObject(textField, rowStaticRef, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [textField addTarget:self action:@selector(textFieldChanged:) forControlEvents:UIControlEventEditingDidEnd];

        cell.accessoryView = textField;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        break;
    }

    case SPKTableCellValue: {
        cellContentConfig.secondaryText = row.subtitle;
        cellContentConfig.prefersSideBySideTextAndSecondaryText = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        break;
    }
    }

    cell.contentConfiguration = cellContentConfig;
    cell.showsReorderControl = NO;
    cell.shouldIndentWhileEditing = NO;

    return cell;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if ([self isSearching] && [self.sections[section][@"breadcrumbComponents"] isKindOfClass:[NSArray class]]) {
        return nil;
    }
    return self.sections[section][@"header"];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSArray<NSString *> *components = self.sections[section][@"breadcrumbComponents"];
    if (![self isSearching] || ![components isKindOfClass:[NSArray class]] || components.count == 0) {
        return nil;
    }

    UITableViewHeaderFooterView *header = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:nil];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 5.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    UIColor *textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    UIColor *chevronColor = [SPKUtils SPKColor_InstagramTertiaryText];
    UIImage *chevron = SPKSettingsBreadcrumbChevronImage();

    for (NSUInteger index = 0; index < components.count; index++) {
        if (index > 0) {
            if (chevron) {
                UIImageView *imageView = [[UIImageView alloc] initWithImage:chevron];
                imageView.tintColor = chevronColor;
                imageView.contentMode = UIViewContentModeScaleAspectFit;
                [imageView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
                [stack addArrangedSubview:imageView];
            } else {
                UILabel *separator = [UILabel new];
                separator.text = @"\u203a";
                separator.font = font;
                separator.textColor = chevronColor;
                [separator setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
                [stack addArrangedSubview:separator];
            }
        }

        UILabel *label = [UILabel new];
        label.text = components[index];
        label.font = font;
        label.textColor = textColor;
        label.numberOfLines = 1;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [stack addArrangedSubview:label];
    }

    [header.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:header.contentView.layoutMarginsGuide.leadingAnchor],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:header.contentView.layoutMarginsGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:header.contentView.topAnchor
                                        constant:8.0],
        [stack.bottomAnchor constraintEqualToAnchor:header.contentView.bottomAnchor
                                           constant:-4.0]
    ]];
    header.accessibilityLabel = SPKSettingsBreadcrumbText(components);
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if ([self isSearching] && [self.sections[section][@"breadcrumbComponents"] isKindOfClass:[NSArray class]] && [self.sections[section][@"breadcrumbComponents"] count] > 0) {
        return 34.0;
    }
    // Flat pages: collapse the empty section header so rows meet the nav bar with
    // no grey plain-header strip.
    NSString *header = self.sections[section][@"header"];
    if ([self preferredTableViewStyle] == UITableViewStylePlain && header.length == 0) {
        return CGFLOAT_MIN;
    }
    return UITableViewAutomaticDimension;
}

// MARK: - Section info sheets

// A named section plus the unnamed sections that continue it form one group:
// they are split apart purely to break a long list into visual blocks, so their
// rows are explained together under the one header the reader sees.
- (NSArray<NSDictionary *> *)spk_infoSheetSourceSections {
    return [self isSearching] ? self.sections : self.originalSections;
}

/// Index of the section whose header hosts `section`'s info button, or
/// NSNotFound while searching, when no row in the group carries help text, or
/// when the group has no header to hang the button on (a page's leading unnamed
/// section keeps its plain text footer).
- (NSInteger)spk_infoSheetAnchorForSection:(NSInteger)section {
    if ([self isSearching])
        return NSNotFound;

    NSArray<NSDictionary *> *sections = [self spk_infoSheetSourceSections];
    if (section < 0 || (NSUInteger)section >= sections.count)
        return NSNotFound;

    NSInteger anchor = section;
    while (anchor >= 0 && [sections[anchor][@"header"] length] == 0) {
        anchor--;
    }
    if (anchor < 0)
        return NSNotFound;

    NSUInteger helpRowCount = [self spk_infoSheetRowsForAnchor:anchor].count;
    if (helpRowCount == 0)
        return NSNotFound;

    // A section can say outright which treatment it wants; otherwise one
    // explained row is not worth a sheet, since a lone sentence about a lone
    // control reads better sitting under it as a footer.
    id override = sections[anchor][SPKTopicSectionInfoSheetKey];
    if ([override isKindOfClass:[NSNumber class]])
        return [override boolValue] ? anchor : NSNotFound;

    return helpRowCount > 1 ? anchor : NSNotFound;
}

- (NSArray<SPKSetting *> *)spk_infoSheetRowsForAnchor:(NSInteger)anchor {
    NSArray<NSDictionary *> *sections = [self spk_infoSheetSourceSections];
    if (anchor < 0 || (NSUInteger)anchor >= sections.count)
        return @[];

    NSMutableArray<SPKSetting *> *rows = [NSMutableArray array];
    for (NSInteger index = anchor; (NSUInteger)index < sections.count; index++) {
        if (index > anchor && [sections[index][@"header"] length] > 0)
            break;
        [rows addObjectsFromArray:SPKSettingsHelpRowsInSection(sections[index])];
    }
    return [rows copy];
}

- (void)spk_presentInfoSheetForAnchor:(NSInteger)anchor {
    NSArray<NSDictionary *> *sections = [self spk_infoSheetSourceSections];
    if (anchor < 0 || (NSUInteger)anchor >= sections.count)
        return;

    // An untitled group borrows the page title.
    NSString *header = sections[anchor][@"header"];
    [SPKSettingsInfoSheetViewController presentFromViewController:self
                                                            title:header.length > 0 ? header : self.title
                                                             rows:[self spk_infoSheetRowsForAnchor:anchor]];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]])
        return;

    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    // Header views are reused, so an inherited button has to go before this
    // section decides whether it wants one.
    [[header.contentView viewWithTag:kSPKSectionInfoButtonTag] removeFromSuperview];

    if ([self spk_infoSheetAnchorForSection:section] != section)
        return;

    __weak typeof(self) weakSelf = self;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = kSPKSectionInfoButtonTag;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setImage:SPKSettingsInfoGlyph() forState:UIControlStateNormal];
    button.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
    button.accessibilityLabel = SPKL(@"SETTINGS_SECTION_INFO_ACCESSIBILITY_LABEL");
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                 [weakSelf spk_presentInfoSheetForAnchor:section];
             }]
     forControlEvents:UIControlEventTouchUpInside];
    [header.contentView addSubview:button];

    // The button is a full-size touch target with the glyph centred inside it,
    // so it overhangs the text margin by half its padding to leave the glyph
    // itself flush with the rows above and below.
    CGFloat overhang = (kSPKSectionInfoTouchSize - kSPKSectionInfoIconSize) / 2.0;
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:header.contentView.layoutMarginsGuide.trailingAnchor constant:overhang],
        [button.widthAnchor constraintEqualToConstant:kSPKSectionInfoTouchSize],
        [button.heightAnchor constraintEqualToConstant:kSPKSectionInfoTouchSize],
        [button.centerYAnchor constraintEqualToAnchor:header.contentView.bottomAnchor
                                             constant:-SPKSettingsHeaderTextCenterOffsetFromBottom()]
    ]];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (![self isSearching]) {
        // The group has an info button, so its explanations live in the sheet.
        if ([self spk_infoSheetAnchorForSection:section] != NSNotFound)
            return nil;

        // Too small for a sheet, or with no header to hang a button on: the
        // help text stays where it has always been, under the rows.
        NSArray<SPKSetting *> *helpRows = SPKSettingsHelpRowsInSection(self.sections[section]);
        if (helpRows.count > 0) {
            NSMutableArray<NSString *> *paragraphs = [NSMutableArray arrayWithCapacity:helpRows.count];
            for (SPKSetting *row in helpRows) {
                [paragraphs addObject:row.helpText];
            }
            return [paragraphs componentsJoinedByString:@"\n\n"];
        }
    }
    return self.sections[section][@"footer"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

// MARK: - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKSetting *row = self.sections[indexPath.section][@"rows"][indexPath.row];
    if (!row)
        return;
    BOOL rowEnabled = (row.userInfo[@"enabled"] ? [row.userInfo[@"enabled"] boolValue] : YES) &&
                      (!row.enabledProvider || row.enabledProvider()) &&
                      SPKPrefIsAvailable(row.defaultsKey);
    if (!rowEnabled) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }

    if (row.type == SPKTableCellLink) {
        [[UIApplication sharedApplication] openURL:row.url options:@{} completionHandler:nil];
    } else if (row.type == SPKTableCellButton) {
        if (row.action != nil) {
            row.action();
            [tableView reloadData];
        }
    } else if (row.type == SPKTableCellNavigation) {
        __weak __typeof(self) weakSelf = self;
        void (^push)(void) = ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf)
                return;
            if (row.navSections.count > 0) {
                UIViewController *vc = [[SPKSettingsViewController alloc] initWithTitle:row.title sections:row.navSections reduceMargin:NO];
                ((SPKSettingsViewController *)vc).defersRestartPrompt = [row.userInfo[@"deferRestartPrompt"] boolValue];
                vc.title = row.title;
                [strongSelf.navigationController pushViewController:vc animated:YES];
            } else if (row.navViewController) {
                [strongSelf.navigationController pushViewController:row.navViewController animated:YES];
            }
        };
        if (row.navigationGate)
            row.navigationGate(push);
        else
            push();
    }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isSearching])
        return NO;
    return [self.sections[indexPath.section][@"allowsReordering"] boolValue];
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    if (sourceIndexPath.section != proposedDestinationIndexPath.section) {
        NSInteger rowCount = [self.sections[sourceIndexPath.section][@"rows"] count];
        NSInteger targetRow = MIN(MAX(0, proposedDestinationIndexPath.row), MAX(0, rowCount - 1));
        return [NSIndexPath indexPathForRow:targetRow inSection:sourceIndexPath.section];
    }
    return proposedDestinationIndexPath;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    NSMutableArray *rows = self.sections[sourceIndexPath.section][@"rows"];
    if (![rows isKindOfClass:[NSMutableArray class]])
        return;

    SPKSetting *row = rows[sourceIndexPath.row];
    [rows removeObjectAtIndex:sourceIndexPath.row];
    [rows insertObject:row atIndex:destinationIndexPath.row];

    NSString *reorderDefaultsKey = self.sections[sourceIndexPath.section][@"reorderDefaultsKey"];
    if (reorderDefaultsKey.length > 0) {
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        for (SPKSetting *candidate in rows) {
            NSString *identifier = candidate.userInfo[@"actionIdentifier"];
            if (identifier.length > 0)
                [order addObject:identifier];
        }
        [[NSUserDefaults standardUserDefaults] setObject:[order copy] forKey:SPKEffectivePreferenceKey(reorderDefaultsKey)];
    }
    self.originalSections = [self.sections copy];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    if (![self tableView:tableView canMoveRowAtIndexPath:indexPath]) {
        return @[];
    }

    SPKSetting *row = self.sections[indexPath.section][@"rows"][indexPath.row];
    NSString *identifier = row.userInfo[@"actionIdentifier"] ?: row.title ?
                                                                          : @"action";
    NSItemProvider *provider = [[NSItemProvider alloc] initWithObject:identifier];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:provider];
    item.localObject = row;
    return @[ item ];
}

- (BOOL)tableView:(UITableView *)tableView dragSessionAllowsMoveOperation:(id<UIDragSession>)session {
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView dragSessionIsRestrictedToDraggingApplication:(id<UIDragSession>)session {
    return YES;
}

- (UITableViewDropProposal *)tableView:(UITableView *)tableView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    if (session.localDragSession == nil || destinationIndexPath == nil) {
        return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
    }
    if (![self.sections[destinationIndexPath.section][@"allowsReordering"] boolValue]) {
        return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
    }
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove intent:UITableViewDropIntentInsertAtDestinationIndexPath];
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    NSIndexPath *destinationIndexPath = coordinator.destinationIndexPath;
    if (destinationIndexPath == nil)
        return;

    id<UITableViewDropItem> dropItem = coordinator.items.firstObject;
    NSIndexPath *sourceIndexPath = dropItem.sourceIndexPath;
    if (sourceIndexPath == nil || sourceIndexPath.section != destinationIndexPath.section)
        return;
    if (![self tableView:tableView canMoveRowAtIndexPath:sourceIndexPath])
        return;

    NSInteger rowCount = [self.sections[sourceIndexPath.section][@"rows"] count];
    NSInteger destinationRow = MIN(MAX(0, destinationIndexPath.row), MAX(0, rowCount - 1));
    NSIndexPath *clampedDestination = [NSIndexPath indexPathForRow:destinationRow inSection:destinationIndexPath.section];

    [tableView
        performBatchUpdates:^{
            [self tableView:tableView moveRowAtIndexPath:sourceIndexPath toIndexPath:clampedDestination];
            [tableView moveRowAtIndexPath:sourceIndexPath toIndexPath:clampedDestination];
        }
                 completion:nil];

    [coordinator dropItem:dropItem.dragItem toRowAtIndexPath:clampedDestination];
}

// MARK: - Search

- (BOOL)isSearching {
    return self.searchController.isActive && self.searchController.searchBar.text.length > 0;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = SPKSettingsNormalizedQuery(searchController.searchBar.text);
    if (query.length == 0) {
        self.sections = SPKVisibleSectionsCopy(self.originalSections);
    } else if (self.searchesAllSettings) {
        self.sections = [self searchAllSettingsForQuery:query];
    } else {
        self.sections = [self filterCurrentSettingsForQuery:query];
    }
    self.tableView.dragInteractionEnabled = ![self isSearching] && [self pageAllowsReordering];
    [self.tableView reloadData];
}

- (NSMutableArray *)filterCurrentSettingsForQuery:(NSString *)query {
    NSArray<NSString *> *tokens = SPKSettingsSearchTokens(query);
    NSMutableArray *filteredSections = [NSMutableArray array];
    for (NSDictionary *section in self.originalSections) {
        NSArray *rows = section[@"rows"];
        NSMutableArray *matchedRows = [NSMutableArray array];
        NSString *sectionTitle = section[@"header"];
        NSString *sectionFooter = section[@"footer"];
        for (SPKSetting *row in rows) {
            if (row.hiddenProvider && row.hiddenProvider())
                continue;
            if (SPKSettingsRowMatchesTokens(row, tokens, self.title, sectionTitle, sectionFooter)) {
                [matchedRows addObject:row];
            }
        }
        if (matchedRows.count == 0)
            continue;

        NSMutableDictionary *filteredSection = [section mutableCopy];
        filteredSection[@"rows"] = matchedRows;
        filteredSection[@"allowsReordering"] = @NO;
        [filteredSections addObject:filteredSection];
    }
    return filteredSections;
}

- (NSMutableArray *)searchAllSettingsForQuery:(NSString *)query {
    NSMutableDictionary<NSString *, NSMutableArray<SPKSetting *> *> *rowsByPath = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *componentsByPath = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *orderedPaths = [NSMutableArray array];
    NSArray<NSString *> *tokens = SPKSettingsSearchTokens(query);
    [self collectSearchRowsFromSections:self.originalSections
                         pathComponents:@[]
                                 tokens:tokens
                             rowsByPath:rowsByPath
                       componentsByPath:componentsByPath
                           orderedPaths:orderedPaths];

    NSMutableArray *sections = [NSMutableArray array];
    for (NSString *path in orderedPaths) {
        NSArray *rows = rowsByPath[path];
        if (rows.count == 0)
            continue;
        [sections addObject:[@{
                      @"header" : path,
                      @"breadcrumbComponents" : componentsByPath[path] ?: @[],
                      @"rows" : [rows mutableCopy],
                      @"allowsReordering" : @NO
                  } mutableCopy]];
    }
    return sections;
}

- (void)collectSearchRowsFromSections:(NSArray *)sections
                       pathComponents:(NSArray<NSString *> *)pathComponents
                               tokens:(NSArray<NSString *> *)tokens
                           rowsByPath:(NSMutableDictionary<NSString *, NSMutableArray<SPKSetting *> *> *)rowsByPath
                     componentsByPath:(NSMutableDictionary<NSString *, NSArray<NSString *> *> *)componentsByPath
                         orderedPaths:(NSMutableArray<NSString *> *)orderedPaths {
    for (NSDictionary *section in sections) {
        NSString *sectionTitle = section[@"header"];
        NSString *sectionFooter = section[@"footer"];
        NSArray<NSString *> *sectionPathComponents = SPKSettingsPathComponentsByAppending(pathComponents, sectionTitle);
        for (SPKSetting *row in section[@"rows"]) {
            if (![row isKindOfClass:[SPKSetting class]])
                continue;
            if (row.hiddenProvider && row.hiddenProvider())
                continue;

            NSArray<NSString *> *rowPathComponents = sectionPathComponents.count > 0 ? sectionPathComponents : SPKSettingsPathComponentsByAppending(pathComponents, row.title);
            NSString *rowPath = SPKSettingsBreadcrumbText(rowPathComponents);
            if (SPKSettingsRowMatchesTokens(row, tokens, rowPath, sectionTitle, sectionFooter)) {
                NSString *resultPath = rowPath.length > 0 ? rowPath : (row.title ?: @"");
                NSMutableArray *rows = rowsByPath[resultPath];
                if (!rows) {
                    rows = [NSMutableArray array];
                    rowsByPath[resultPath] = rows;
                    componentsByPath[resultPath] = rowPathComponents;
                    [orderedPaths addObject:resultPath];
                }
                [rows addObject:row];
            }

            NSArray *childSections = row.navSections.count > 0 ? row.navSections : (row.searchSectionsProvider ? row.searchSectionsProvider() : nil);
            if (childSections.count > 0) {
                NSArray<NSString *> *childPathComponents = SPKSettingsPathComponentsByAppending(pathComponents, row.title);
                [self collectSearchRowsFromSections:childSections
                                     pathComponents:childPathComponents
                                             tokens:tokens
                                         rowsByPath:rowsByPath
                                   componentsByPath:componentsByPath
                                       orderedPaths:orderedPaths];
            }
        }
    }
}

// MARK: - Actions

- (SPKSetting *)settingForSender:(id)sender {
    return objc_getAssociatedObject(sender, rowStaticRef);
}

- (void)switchChanged:(UISwitch *)sender {
    SPKSetting *row = objc_getAssociatedObject(sender, rowStaticRef);
    if (!row)
        return;
    if (!SPKPrefIsAvailable(row.defaultsKey)) {
        sender.on = NO;
        return;
    }

    if (row.switchChangeHandler) {
        row.switchChangeHandler(sender.isOn);
        if (row.action) {
            row.action();
        }
        // Avoid reloading by default: rebuilding the cell swaps in a fresh
        // switch set non-animated, which cuts the native (Liquid Glass) toggle
        // animation short. Handlers that need a table refresh either set
        // reloadsTableOnSwitchChange or reload themselves (e.g. rebuildSections).
        if (row.reloadsTableOnSwitchChange) {
            [self refreshDependentRowsAfterSwitchChange:sender];
        }
        return;
    }

    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:SPKEffectivePreferenceKey(row.defaultsKey)];
    if (sender.isOn && row.mutuallyExclusiveDefaultsKey.length) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:SPKEffectivePreferenceKey(row.mutuallyExclusiveDefaultsKey)];
    }

    SPKLog(@"General", @"Switch changed: %@", sender.isOn ? @"ON" : @"OFF");
    if (sender.isOn && !row.requiresRestart) {
        SPKInstallEnabledFeatureHooks();
    }

    if (row.mutuallyExclusiveDefaultsKey.length) {
        [self.tableView reloadData];
    }

    if (row.requiresRestart) {
        // A restart action may terminate the process before defaults flush on
        // their own. Persist the new state before presenting that action.
        [[NSUserDefaults standardUserDefaults] synchronize];
        if (self.defersRestartPrompt) {
            self.hasPendingRestartChanges = YES;
            self.applyRestartItem.enabled = YES;
        } else {
            [SPKUtils showRestartConfirmation];
        }
    }

    if (row.action) {
        row.action();
    }

    // Same contract as the switchChangeHandler branch above: a plain pref-backed switch
    // that gates other rows still has to refresh them, or their enabledProvider state is
    // stale until the page is left and re-entered.
    if (row.reloadsTableOnSwitchChange) {
        [self refreshDependentRowsAfterSwitchChange:sender];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)spk_dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)textFieldChanged:(UITextField *)sender {
    SPKSetting *row = objc_getAssociatedObject(sender, rowStaticRef);
    if (!row)
        return;

    NSString *value = [sender.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [[NSUserDefaults standardUserDefaults] setObject:value ?: @"" forKey:SPKEffectivePreferenceKey(row.defaultsKey)];
}

- (void)applyRestartChanges {
    [SPKUtils showRestartConfirmation];
}

- (void)stepperChanged:(UIStepper *)sender {
    SPKSetting *row = objc_getAssociatedObject(sender, rowStaticRef);
    double normalizedValue = SPKNormalizedStepperValue(row, sender.value);
    sender.value = normalizedValue;
    [[NSUserDefaults standardUserDefaults] setDouble:normalizedValue forKey:SPKEffectivePreferenceKey(row.defaultsKey)];

    SPKLog(@"General", @"Stepper changed: %f", normalizedValue);

    [self reloadCellForView:sender];
}

- (void)menuChanged:(UICommand *)command {
    NSDictionary *properties = command.propertyList;

    NSString *defaultsKey = properties[@"defaultsKey"];
    NSString *writeKey = SPKEffectivePreferenceKey(defaultsKey);
    [[NSUserDefaults standardUserDefaults] setValue:properties[@"value"] forKey:writeKey];
    // Flush immediately: a requiresRestart change may kill the app before the
    // automatic NSUserDefaults sync, losing the just-written value.
    [[NSUserDefaults standardUserDefaults] synchronize];
    if ([defaultsKey containsString:@"_action_btn"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:SPKActionButtonConfigurationDidChangeNotification object:nil];
    }
    if ([defaultsKey hasPrefix:@"profile_follow_indicator"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:SPKFollowIndicatorDidChangeNotification object:nil];
    }
    if ([defaultsKey isEqualToString:@"msgs_seen_button_position"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:SPKMessageSeenButtonPositionDidChangeNotification object:nil];
    }

    SPKLog(@"General", @"Menu changed: %@ = %@", writeKey, properties[@"value"]);

    // A menu selection can gate another row's visibility (e.g. the Create Tab
    // toggle only shows for the Classic tab order). Only pay for a full rebuild
    // on pages that actually have hideable rows; otherwise keep the animated
    // single-cell refresh.
    BOOL hasHideableRows = NO;
    for (NSDictionary *section in self.originalSections) {
        for (id row in section[@"rows"]) {
            if ([row isKindOfClass:[SPKSetting class]] && ((SPKSetting *)row).hiddenProvider) {
                hasHideableRows = YES;
                break;
            }
        }
        if (hasHideableRows)
            break;
    }
    if (hasHideableRows && ![self isSearching]) {
        [self rebuildVisibleSections];
    } else {
        [self reloadCellForView:command.sender animated:YES];
    }

    if (properties[@"requiresRestart"]) {
        [SPKUtils showRestartConfirmation];
    }
}

// MARK: - Helper

- (void)replaceSections:(NSArray *)sections {
    self.originalSections = [sections copy] ?: @[];
    self.sections = SPKVisibleSectionsCopy(self.originalSections);
    self.tableView.dragInteractionEnabled = ![self isSearching] && [self pageAllowsReordering];
    [self.tableView reloadData];
}

// Re-evaluate every row's `hiddenProvider` against the full `originalSections`
// and reload. Call after a control changes state that another row's visibility
// depends on. No-op while searching (search maintains its own filtered set).
- (void)rebuildVisibleSections {
    if ([self isSearching])
        return;
    self.sections = SPKVisibleSectionsCopy(self.originalSections);
    [self.tableView reloadData];
}

// Like rebuildVisibleSections, but reloads every row *except* the one holding
// `sender`, so a toggled switch keeps its native slide animation while dependent
// rows refresh their enabled/greyed state. Falls back to a full reload if the
// visible row layout changed (a row appeared/disappeared), where a targeted
// reload would desync the table.
- (void)refreshDependentRowsAfterSwitchChange:(UISwitch *)sender {
    if ([self isSearching]) {
        [self.tableView reloadData];
        return;
    }

    UITableViewCell *cell = (UITableViewCell *)sender.superview;
    while (cell && ![cell isKindOfClass:[UITableViewCell class]])
        cell = (UITableViewCell *)cell.superview;
    NSIndexPath *senderPath = cell ? [self.tableView indexPathForCell:cell] : nil;

    NSMutableArray<NSNumber *> *previousCounts = [NSMutableArray array];
    for (NSDictionary *section in self.sections)
        [previousCounts addObject:@([section[@"rows"] count])];

    self.sections = SPKVisibleSectionsCopy(self.originalSections);

    NSMutableArray<NSNumber *> *newCounts = [NSMutableArray array];
    for (NSDictionary *section in self.sections)
        [newCounts addObject:@([section[@"rows"] count])];

    if (!senderPath || ![previousCounts isEqualToArray:newCounts]) {
        [self.tableView reloadData];
        return;
    }

    NSMutableArray<NSIndexPath *> *paths = [NSMutableArray array];
    for (NSInteger s = 0; s < (NSInteger)self.sections.count; s++) {
        NSInteger rowCount = [self.sections[s][@"rows"] count];
        for (NSInteger r = 0; r < rowCount; r++) {
            if (s == senderPath.section && r == senderPath.row)
                continue;
            [paths addObject:[NSIndexPath indexPathForRow:r inSection:s]];
        }
    }
    if (paths.count > 0)
        [self.tableView reloadRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationNone];
}

- (NSString *)formatString:(NSString *)template withValue:(double)value step:(double)step label:(NSString *)label singularLabel:(NSString *)singularLabel {
    // Singular or plural labels
    NSString *applicableLabel = fabs(value - 1.0) < 0.00001 ? singularLabel : label;

    // Force value to 0 to prevent it being -0
    if (fabs(value) < 0.00001) {
        value = 0.0;
    }

    // Get correct decimal value based on step value
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.minimumFractionDigits = 0;
    formatter.maximumFractionDigits = step > 0.0 ? [SPKUtils decimalPlacesInDouble:step] : [SPKUtils decimalPlacesInDouble:value];

    NSString *stringValue = [formatter stringFromNumber:@(value)];

    return [NSString stringWithFormat:template, stringValue, applicableLabel];
}

- (void)reloadCellForView:(UIView *)view animated:(BOOL)animated {
    UITableViewCell *cell = (UITableViewCell *)view.superview;
    while (cell && ![cell isKindOfClass:[UITableViewCell class]]) {
        cell = (UITableViewCell *)cell.superview;
    }
    if (!cell)
        return;

    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath)
        return;

    [self.tableView reloadRowsAtIndexPaths:@[ indexPath ]
                          withRowAnimation:animated ? UITableViewRowAnimationAutomatic : UITableViewRowAnimationNone];
}
- (void)reloadCellForView:(UIView *)view {
    [self reloadCellForView:view animated:NO];
}

- (BOOL)pageAllowsReordering {
    if ([self isSearching])
        return NO;
    for (NSDictionary *section in self.sections) {
        if ([section[@"allowsReordering"] boolValue]) {
            return YES;
        }
    }
    return NO;
}

- (void)loadAvatarForPK:(NSString *)pk urlString:(NSString *)urlString atIndexPath:(NSIndexPath *)indexPath forTableView:(UITableView *)tableView {
    if (pk.length == 0)
        return;
    // SPKAvatarCache self-heals: tries the stored URL, then re-resolves a fresh one
    // for numeric user PKs when it has expired. Completion is on the main queue.
    [[SPKAvatarCache shared] avatarForPK:pk
                               urlString:urlString
                              completion:^(UIImage *image) {
                                  if (!image)
                                      return;
                                  UIImage *circular = SPKSettingsSizedRemoteImage(image, YES);
                                  if (!circular)
                                      return;

                                  UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
                                  if (![cell.contentConfiguration isKindOfClass:UIListContentConfiguration.class])
                                      return;
                                  UIListContentConfiguration *config = (UIListContentConfiguration *)cell.contentConfiguration;
                                  config.image = circular;
                                  config.imageProperties.tintColor = nil;
                                  config.imageProperties.maximumSize = CGSizeMake(kSPKSettingsRemoteImageSize, kSPKSettingsRemoteImageSize);
                                  config.imageProperties.reservedLayoutSize = CGSizeMake(kSPKSettingsRemoteImageSize, kSPKSettingsRemoteImageSize);
                                  cell.contentConfiguration = config;
                              }];
}

- (void)loadImageFromURL:(NSURL *)url atIndexPath:(NSIndexPath *)indexPath forTableView:(UITableView *)tableView circular:(BOOL)circular {
    if (!url)
        return;

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", url.absoluteString, circular ? @"circle" : @"square"];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
                                                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                                 if (!data || error)
                                                                     return;

                                                                 UIImage *image = SPKSettingsSizedRemoteImage([UIImage imageWithData:data], circular);
                                                                 if (!image)
                                                                     return;
                                                                 [SPKSettingsRemoteImageCache() setObject:image forKey:cacheKey];

                                                                 dispatch_async(dispatch_get_main_queue(), ^{
                                                                     UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
                                                                     if (!cell)
                                                                         return;

                                                                     UIListContentConfiguration *config = (UIListContentConfiguration *)cell.contentConfiguration;
                                                                     config.image = image;
                                                                     config.imageProperties.maximumSize = CGSizeMake(kSPKSettingsRemoteImageSize, kSPKSettingsRemoteImageSize);
                                                                     config.imageProperties.reservedLayoutSize = CGSizeMake(kSPKSettingsRemoteImageSize, kSPKSettingsRemoteImageSize);
                                                                     cell.contentConfiguration = config;
                                                                 });
                                                             }];

    [task resume];
}

@end
