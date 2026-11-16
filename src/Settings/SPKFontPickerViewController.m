#import "SPKStrings.h"
#import "SPKFontPickerViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "../AssetUtils.h"
#import "../Shared/Fonts/SPKFontManager.h"
#import "../Shared/UI/SPKIGAlertPresenter.h"
#import "../Shared/UI/SPKMediaChrome.h"
#import "../Utils.h"
#import "SPKTopicSettingsSupport.h"

#pragma mark - Preview

static NSString *const kSPKFontSpecimenUppercase = @"ABCDEFGHIJKLMNOPQRSTUVWXYZ";
static NSString *const kSPKFontSpecimenLowercase = @"abcdefghijklmnopqrstuvwxyz";
static NSString *const kSPKFontSpecimenFigures = @"0123456789 &@#%$ ?!.,:;'\"-()";

// Text inset inside the specimen card. The card itself sits on the table's layout
// margins, so it lines up with the section below it.
static CGFloat const kSPKFontSpecimenInset = 20.0;

// A specimen card for the font currently selected. It is the whole point of the
// screen: the rows say which fonts exist, this says what the app is about to look
// like -- at a size worth judging, and face by face, so a family that ships only
// italics or has no real bold is obvious before it is applied.
@interface SPKFontSpecimenView : UIView
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *sampleLabel;
/// Uppercase, lowercase, and figures/punctuation. A sentence exercises maybe a
/// third of a font: these lines are where a missing glyph shows up, as a character
/// visibly set in the fallback face.
@property (nonatomic, strong) UIStackView *glyphsStack;
/// One row per pair of faces, rebuilt on every configure: how many faces a family
/// ships is a property of the family, not something the card can size for up front.
@property (nonatomic, strong) UIStackView *facesStack;
@property (nonatomic, strong) UILabel *hintLabel;
/// Holds the sample at a constant height. Samples differ in length, so without it
/// the card grows and shrinks under the finger as they are cycled. The height is
/// whatever the longest of them needs in the current font, not a fixed line count:
/// a font wide enough (or a translation long enough) to push one sample onto a
/// third line would otherwise have it truncated with an ellipsis.
@property (nonatomic, strong) NSLayoutConstraint *sampleHeightConstraint;
/// Every sample the card can cycle through, kept so the height can be measured
/// against all of them rather than only the one on screen.
@property (nonatomic, copy) NSArray<NSString *> *sampleTexts;
- (void)updateSampleHeightForWidth:(CGFloat)width;
@end

@implementation SPKFontSpecimenView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    _card = [[UIView alloc] init];
    _card.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    _card.layer.cornerRadius = 20.0;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_card];

    _nameLabel = [[UILabel alloc] init];
    _nameLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    _nameLabel.numberOfLines = 1;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.6;
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:_nameLabel];

    _sampleLabel = [[UILabel alloc] init];
    _sampleLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    // Line count is governed by the measured height constraint below, which is
    // sized to hold the longest sample outright.
    _sampleLabel.numberOfLines = 0;
    _sampleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:_sampleLabel];

    _glyphsStack = [[UIStackView alloc] init];
    _glyphsStack.axis = UILayoutConstraintAxisVertical;
    _glyphsStack.spacing = 6.0;
    _glyphsStack.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSString *line in @[ kSPKFontSpecimenUppercase, kSPKFontSpecimenLowercase, kSPKFontSpecimenFigures ]) {
        UILabel *label = [[UILabel alloc] init];
        label.text = line;
        label.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
        label.numberOfLines = 1;
        // Alphabets are wider than the card at any readable size, and wrapping them
        // would hide where the line ends; shrinking keeps each set on one line.
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.45;
        [_glyphsStack addArrangedSubview:label];
    }
    [_card addSubview:_glyphsStack];

    _facesStack = [[UIStackView alloc] init];
    _facesStack.axis = UILayoutConstraintAxisVertical;
    _facesStack.spacing = 10.0;
    _facesStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:_facesStack];

    _hintLabel = [[UILabel alloc] init];
    _hintLabel.text = SPKL(@"FONT_SPECIMEN_HINT_LABEL");
    _hintLabel.textColor = [SPKUtils SPKColor_InstagramTertiaryText];
    _hintLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:_hintLabel];

    CGFloat const inset = kSPKFontSpecimenInset;
    [NSLayoutConstraint activateConstraints:@[
        // The table's layout margins, where the rows below sit; they already
        // absorb a side column's safe-area inset.
        [_card.leadingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.leadingAnchor],
        [_card.trailingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.trailingAnchor],
        [_card.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:inset],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-inset],
        [_nameLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:inset],

        [_sampleLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_sampleLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_sampleLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:8.0],
        (_sampleHeightConstraint = [_sampleLabel.heightAnchor constraintEqualToConstant:0.0]),

        [_glyphsStack.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_glyphsStack.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_glyphsStack.topAnchor constraintEqualToAnchor:_sampleLabel.bottomAnchor constant:16.0],

        [_facesStack.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_facesStack.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_facesStack.topAnchor constraintEqualToAnchor:_glyphsStack.bottomAnchor constant:16.0],

        [_hintLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_hintLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_hintLabel.topAnchor constraintEqualToAnchor:_facesStack.bottomAnchor constant:14.0],
        // Closes the chain: without this the card has no resolvable height and the
        // header measures to nothing.
        [_hintLabel.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-14.0],
    ]];
    return self;
}

- (UILabel *)faceLabel {
    UILabel *label = [[UILabel alloc] init];
    label.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

// Called again whenever the card's width resolves or changes: the header is sized
// by frame rather than by Auto Layout, so the width the samples have to fit in is
// only known from the outside.
- (void)updateSampleHeightForWidth:(CGFloat)width {
    UIFont *font = self.sampleLabel.font;
    if (!font)
        return;
    CGFloat twoLines = ceil(font.lineHeight * 2.0);
    // The card spans the margins, the text sits one inset inside it.
    UIEdgeInsets margins = self.layoutMargins;
    CGFloat available = width - margins.left - margins.right - (kSPKFontSpecimenInset * 2.0);
    CGFloat tallest = twoLines;
    if (available > 0.0) {
        for (NSString *text in self.sampleTexts) {
            if (text.length == 0)
                continue;
            CGRect rect = [text boundingRectWithSize:CGSizeMake(available, CGFLOAT_MAX)
                                             options:NSStringDrawingUsesLineFragmentOrigin
                                          attributes:@{NSFontAttributeName : font}
                                             context:nil];
            tallest = MAX(tallest, ceil(CGRectGetHeight(rect)));
        }
    }
    if (fabs(self.sampleHeightConstraint.constant - tallest) > 0.5)
        self.sampleHeightConstraint.constant = tallest;
}

- (void)configureWithName:(NSString *)name
              displayFont:(UIFont *)displayFont
               sampleFont:(UIFont *)sampleFont
               sampleText:(NSString *)sampleText
              sampleTexts:(NSArray<NSString *> *)sampleTexts
                glyphFont:(UIFont *)glyphFont
              faceTitles:(NSArray<NSString *> *)faceTitles
               faceFonts:(NSArray<UIFont *> *)faceFonts
             overflowText:(NSString *)overflowText {
    self.nameLabel.text = name;
    self.nameLabel.font = displayFont;
    self.sampleLabel.text = sampleText;
    self.sampleLabel.font = sampleFont;
    self.sampleTexts = sampleTexts.count > 0 ? sampleTexts : (sampleText.length > 0 ? @[ sampleText ] : @[]);
    [self updateSampleHeightForWidth:CGRectGetWidth(self.bounds)];

    for (UIView *line in self.glyphsStack.arrangedSubviews) {
        if ([line isKindOfClass:[UILabel class]])
            ((UILabel *)line).font = glyphFont;
    }

    for (UIView *row in self.facesStack.arrangedSubviews) {
        [self.facesStack removeArrangedSubview:row];
        [row removeFromSuperview];
    }

    // Two per row: style names run long ("SemiBold Italic"), and each is set in its
    // own face, so a third column would shrink them past the point of judging them.
    UIStackView *row = nil;
    for (NSUInteger index = 0; index < faceTitles.count; index++) {
        if (index % 2 == 0) {
            row = [[UIStackView alloc] init];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.distribution = UIStackViewDistributionFillEqually;
            row.alignment = UIStackViewAlignmentFirstBaseline;
            row.spacing = 12.0;
            [self.facesStack addArrangedSubview:row];
        }
        UILabel *label = [self faceLabel];
        label.text = faceTitles[index];
        label.font = index < faceFonts.count ? faceFonts[index] : nil;
        [row addArrangedSubview:label];
    }
    // Keeps the last row's columns aligned with the rows above it when the count
    // is odd, instead of letting a lone face stretch across the card.
    if (faceTitles.count % 2 == 1 && row)
        [row addArrangedSubview:[[UIView alloc] init]];

    if (overflowText.length > 0) {
        UILabel *label = [self faceLabel];
        label.text = overflowText;
        label.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
        label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        [self.facesStack addArrangedSubview:label];
    }
}

@end

#pragma mark - Picker

// Cycled by tapping the card. The pangrams cover the alphabet in real words, and
// the Instagram line is the one that answers the question actually being asked:
// what the app's own chrome will look like in this font.
static NSArray<NSString *> *SPKFontSpecimenSamples(void) {
    static NSArray<NSString *> *samples = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        samples = @[
            SPKL(@"FONT_SPECIMEN_SAMPLE_LIKES"),
            SPKL(@"SETTINGS_FONT_PICKER_QUICK_BROWN_FOX_JUMPED_OVER_LAZY_DOG_TEXT"),
            SPKL(@"SETTINGS_FONT_PICKER_WEST_QUICKLY_GAVE_BERT_HANDSOME_PRIZES_SIX_JUICY_PLUMS_TEXT"),
            SPKL(@"SETTINGS_FONT_PICKER_FIVE_SIX_BIG_JET_PLANES_ZOOMED_QUICKLY_TOWER_TEXT"),
        ];
    });
    return samples;
}

@interface SPKFontPickerViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) SPKFontSpecimenView *specimenView;
@property (nonatomic, copy) NSArray<NSString *> *families;
@property (nonatomic, copy) NSArray<SPKFontFile *> *files;
/// Files bucketed by the family they provide, in row order. Each entry is
/// @{@"key", @"title", @"files"}.
@property (nonatomic, copy) NSArray<NSDictionary *> *fileGroups;
@property (nonatomic, strong) NSMutableSet<NSString *> *expandedGroups;
@property (nonatomic, assign) BOOL seededExpansion;
@property (nonatomic, assign) BOOL expandsGroupsForSearch;
@property (nonatomic, assign) NSUInteger sampleIndex;
// Held for the lifetime of the presentation: UIDocumentPickerViewController keeps
// its delegate weakly, so nothing else retains us as the delegate while it is up.
@property (nonatomic, strong, nullable) UIDocumentPickerViewController *activePicker;
@end

@implementation SPKFontPickerViewController

- (instancetype)init {
    return [super initWithTitle:SPKL(@"FONT_APP_FONT_TITLE") sections:@[] reduceMargin:NO];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.specimenView = [[SPKFontSpecimenView alloc] initWithFrame:CGRectZero];
    self.specimenView.preservesSuperviewLayoutMargins = YES;
    [self.specimenView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                    action:@selector(cycleSampleText)]];
    self.tableView.tableHeaderView = self.specimenView;
    [self reloadFonts];
}

// The base resets the trailing bar items on load *and* on every appearance, so the
// import button has to be re-added after it rather than installed once.
- (void)setupNavigationItems {
    [super setupNavigationItems];
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[
        SPKMediaChromeTopBarButtonItemWithTint(@"plus", self, @selector(presentImportPicker),
                                               [SPKUtils SPKColor_InstagramPrimaryText], SPKL(@"FONT_IMPORT_BUTTON_TITLE")),
    ]);
}

// The settings row retains this controller, so a second visit shows the same
// object; fonts may have changed underneath it (a settings import, say).
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFonts];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutSpecimenHeader];
}

#pragma mark - Fonts for the rows

// The real system face, not what the app-font hooks would return. Building it from
// a descriptor sidesteps `+systemFontOfSize:`, which this feature replaces, so the
// Default row keeps previewing the default.
- (UIFont *)systemFontOfSize:(CGFloat)size weight:(UIFontWeight)weight {
    UIFontDescriptor *descriptor = [UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleBody];
    descriptor = [descriptor fontDescriptorByAddingAttributes:@{
        UIFontDescriptorTraitsAttribute : @{UIFontWeightTrait : @(weight)}
    }];
    return [UIFont fontWithDescriptor:descriptor size:size];
}

- (UIFont *)systemFontOfSize:(CGFloat)size weight:(UIFontWeight)weight italic:(BOOL)italic {
    UIFont *font = [self systemFontOfSize:size weight:weight];
    if (!italic || !font)
        return font;
    UIFontDescriptor *descriptor =
        [font.fontDescriptor fontDescriptorWithSymbolicTraits:font.fontDescriptor.symbolicTraits | UIFontDescriptorTraitItalic];
    return descriptor ? [UIFont fontWithDescriptor:descriptor size:size] : font;
}

- (UIFont *)fontForFamily:(NSString *)family size:(CGFloat)size weight:(UIFontWeight)weight {
    if (family.length == 0)
        return [self systemFontOfSize:size weight:weight];
    UIFont *font = [SPKFontManager fontInFamily:family size:size weight:weight italic:NO];
    return font ?: [self systemFontOfSize:size weight:weight];
}

#pragma mark - Specimen

- (void)layoutSpecimenHeader {
    if (!self.specimenView)
        return;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (width <= 0.0)
        return;

    [self.specimenView updateSampleHeightForWidth:width];

    // A table header view is sized by its frame, not by Auto Layout, so the height
    // has to be resolved here and the view re-assigned for the table to pick it up.
    CGFloat height = [self.specimenView systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                      withHorizontalFittingPriority:UILayoutPriorityRequired
                                            verticalFittingPriority:UILayoutPriorityFittingSizeLevel]
                         .height;
    if (height <= 0.0)
        return;
    height += 12.0; // breathing room before the first section

    CGRect frame = CGRectMake(0, 0, width, height);
    if (!CGRectEqualToRect(self.specimenView.frame, frame)) {
        self.specimenView.frame = frame;
        self.tableView.tableHeaderView = self.specimenView; // re-measure
    }
}

// Enough to characterize a family without turning the header into the whole screen.
static NSUInteger const kSPKFontSpecimenFaceLimit = 6;

- (void)cycleSampleText {
    self.sampleIndex = (self.sampleIndex + 1) % SPKFontSpecimenSamples().count;
    // Cross-dissolve rather than a hard swap: the card is the only thing that
    // changes, and a silent text replacement reads as a glitch.
    [UIView transitionWithView:self.specimenView
                      duration:0.18
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
                        [self refreshSpecimen];
                    }
                    completion:nil];
    [[UISelectionFeedbackGenerator new] selectionChanged];
}

- (void)refreshSpecimen {
    NSString *family = [SPKFontManager selectedFamilyName];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<UIFont *> *fonts = [NSMutableArray array];
    NSString *overflow = nil;

    if (family.length > 0) {
        // The real faces, not three fixed weight requests: a family that ships only
        // an italic and a bold italic would otherwise preview as three identical
        // lines labelled Regular, Medium, and Bold.
        NSArray<SPKFontFace *> *faces = [SPKFontManager facesInFamily:family];
        for (SPKFontFace *face in faces) {
            if (titles.count >= kSPKFontSpecimenFaceLimit)
                break;
            UIFont *font = [UIFont fontWithName:face.postScriptName size:17.0];
            if (!font)
                continue;
            [titles addObject:face.styleName.length > 0 ? face.styleName : SPKL(@"FONT_STYLE_REGULAR")];
            [fonts addObject:font];
        }
        NSUInteger remaining = faces.count - titles.count;
        if (remaining > 0)
            overflow = [NSString stringWithFormat:SPKL(@"FONT_SPECIMEN_OVERFLOW_FORMAT"), (unsigned long)remaining,
                                                  remaining == 1 ? SPKL(@"FONT_SPECIMEN_FACE_SINGULAR") : SPKL(@"FONT_SPECIMEN_FACE_PLURAL")];
    } else {
        // The system font is a single variable face, so there is nothing to list;
        // these are the weights Instagram and Sparkle actually ask it for.
        NSArray<NSString *> *systemTitles = @[
            SPKL(@"FONT_STYLE_REGULAR"), SPKL(@"FONT_STYLE_MEDIUM"),
            SPKL(@"FONT_STYLE_BOLD"), SPKL(@"FONT_STYLE_ITALIC")
        ];
        NSArray<NSNumber *> *systemWeights = @[ @(UIFontWeightRegular), @(UIFontWeightMedium),
                                                @(UIFontWeightBold), @(UIFontWeightRegular) ];
        for (NSUInteger index = 0; index < systemTitles.count; index++) {
            UIFont *font = [self systemFontOfSize:17.0
                                           weight:systemWeights[index].doubleValue
                                           italic:(index == 3)];
            if (!font)
                continue;
            [titles addObject:systemTitles[index]];
            [fonts addObject:font];
        }
    }

    NSArray<NSString *> *samples = SPKFontSpecimenSamples();
    [self.specimenView configureWithName:family.length > 0 ? family : SPKL(@"FONT_DEFAULT_ROW_TITLE")
                             displayFont:[self fontForFamily:family size:30.0 weight:UIFontWeightSemibold]
                              sampleFont:[self fontForFamily:family size:16.0 weight:UIFontWeightRegular]
                              sampleText:samples[self.sampleIndex % samples.count]
                             sampleTexts:samples
                               glyphFont:[self fontForFamily:family size:15.0 weight:UIFontWeightRegular]
                              faceTitles:titles
                               faceFonts:fonts
                            overflowText:overflow];
    [self.view setNeedsLayout];
}

#pragma mark - Sections

- (void)reloadFonts {
    self.files = [SPKFontManager importedFonts];
    self.families = [SPKFontManager importedFamilyNames];
    [self rebuildFileGroups];
    [self rebuildSections];
    [self refreshSpecimen];
}

// A family is normally split across one file per weight, so an unfolded list is
// mostly repetition of the same name. Grouping by the family the file provides
// keeps the section as short as the font list above it until something needs
// looking at. Files Core Text cannot parse have no family to group under and get
// their own bucket rather than being hidden.
- (void)rebuildFileGroups {
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<SPKFontFile *> *> *buckets = [NSMutableDictionary dictionary];

    for (SPKFontFile *file in self.files) {
        NSString *key = file.familyName.length > 0 ? file.familyName : @"";
        NSMutableArray<SPKFontFile *> *bucket = buckets[key];
        if (!bucket) {
            bucket = [NSMutableArray array];
            buckets[key] = bucket;
            [order addObject:key];
        }
        [bucket addObject:file];
    }

    NSMutableArray<NSDictionary *> *groups = [NSMutableArray array];
    for (NSString *key in order) {
        [groups addObject:@{
            @"key" : key,
            @"title" : key.length > 0 ? key : SPKL(@"FONT_IMPORTED_FILES_UNRECOGNIZED_GROUP_TITLE"),
            @"files" : [buckets[key] copy],
        }];
    }
    self.fileGroups = groups;

    if (!self.expandedGroups)
        self.expandedGroups = [NSMutableSet set];
    // A single group collapsed shows nothing but its own name, which the font list
    // above already says. Seeded once, so a later collapse is respected.
    if (!self.seededExpansion && groups.count > 0) {
        self.seededExpansion = YES;
        if (groups.count == 1)
            [self.expandedGroups addObject:groups.firstObject[@"key"]];
    }
    // Deleting the last file of a family leaves its key behind otherwise, and the
    // group would come back expanded if the family were imported again.
    NSMutableSet<NSString *> *liveKeys = [NSMutableSet setWithArray:order];
    [self.expandedGroups intersectSet:liveKeys];
}

- (NSString *)sizeTextForFiles:(NSArray<SPKFontFile *> *)files {
    unsigned long long total = 0;
    for (SPKFontFile *file in files)
        total += file.byteSize;
    return [NSByteCountFormatter stringFromByteCount:(long long)total countStyle:NSByteCountFormatterCountStyleFile];
}

- (void)rebuildSections {
    NSString *selected = [SPKFontManager selectedFamilyName];
    __weak typeof(self) weakSelf = self;

    NSMutableArray<SPKSetting *> *fontRows = [NSMutableArray array];
    SPKSetting *defaultRow = [SPKSetting buttonCellWithTitle:SPKL(@"FONT_DEFAULT_ROW_TITLE")
                                                    subtitle:@""
                                                        icon:nil
                                                      action:^{
                                                          [weakSelf selectFamily:nil];
                                                      }];
    // No chevron: these rows pick a value, they don't lead anywhere. The checkmark
    // is the only accessory a selection list should carry.
    //
    // An empty family pins this row to the real system face. Left alone it would
    // inherit the page's font like any other label, so with a custom font applied
    // the row offering to turn it off would be set in the font it turns off.
    defaultRow.userInfo = @{
        @"checkmarked" : @(selected.length == 0),
        @"hidesDisclosure" : @(YES),
        @"family" : @"",
    };
    [fontRows addObject:defaultRow];

    for (NSString *family in self.families) {
        SPKSetting *row = [SPKSetting buttonCellWithTitle:family
                                                 subtitle:@""
                                                     icon:nil
                                                   action:^{
                                                       [weakSelf selectFamily:family];
                                                   }];
        // Each row is set in its own typeface below, so the name itself is the
        // sample. A sentence per row was noise; the card above carries the real one.
        row.userInfo = @{
            @"checkmarked" : @([family isEqualToString:selected]),
            @"hidesDisclosure" : @(YES),
            @"family" : family,
        };
        [fontRows addObject:row];
    }

    NSMutableArray *sections = [NSMutableArray array];
    [sections addObject:SPKTopicSection(SPKL(@"FONT_ROWS_SECTION_HEADER"), fontRows,
                                        SPKL(@"FONT_ROWS_SECTION_FOOTER"))];

    if (self.fileGroups.count > 0) {
        NSMutableArray<SPKSetting *> *fileRows = [NSMutableArray array];
        for (NSDictionary *group in self.fileGroups) {
            NSString *key = group[@"key"];
            NSArray<SPKFontFile *> *files = group[@"files"];
            BOOL expanded = self.expandsGroupsForSearch || [self.expandedGroups containsObject:key];

            NSString *count = files.count == 1 ? SPKL(@"FONT_FILE_COUNT_SINGULAR") : [NSString stringWithFormat:SPKL(@"FONT_FILE_COUNT_PLURAL_FORMAT"), (unsigned long)files.count];
            SPKSetting *groupRow = [SPKSetting buttonCellWithTitle:group[@"title"]
                                                          subtitle:[NSString stringWithFormat:SPKL(@"FONT_FILE_COUNT_SIZE_JOINER_FORMAT"), count, [self sizeTextForFiles:files]]
                                                              icon:nil
                                                            action:^{
                                                                [weakSelf toggleGroupWithKey:key];
                                                            }];
            // The chevron is drawn as the accessory below so it can point down while
            // the group is open; the built-in disclosure indicator cannot rotate.
            groupRow.userInfo = @{@"group" : key, @"expanded" : @(expanded), @"hidesDisclosure" : @(YES)};
            [fileRows addObject:groupRow];

            if (!expanded)
                continue;
            for (SPKFontFile *file in files) {
                NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)file.byteSize
                                                                countStyle:NSByteCountFormatterCountStyleFile];
                NSString *subtitle = file.familyName.length > 0
                                         ? size
                                         : [NSString stringWithFormat:SPKL(@"FONT_UNUSABLE_FILE_SUBTITLE_FORMAT"), size];
                SPKSetting *row = [SPKSetting staticCellWithTitle:file.fileName subtitle:subtitle icon:nil];
                row.userInfo = @{@"file" : file, @"indented" : @(YES)};
                [fileRows addObject:row];
            }
        }
        [sections addObject:SPKTopicSection(SPKL(@"FONT_IMPORTED_FILES_SECTION_HEADER"), fileRows,
                                            SPKL(@"FONT_IMPORTED_FILES_FOOTER"))];
    }

    [self replaceSections:sections];
}

// Search filters the rows this page has built, so a file inside a collapsed family
// is not a row yet and could never be found. Every group is unfolded for the
// duration of a query and folded back when it is cleared.
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    BOOL searching = searchController.searchBar.text.length > 0;
    if (searching != self.expandsGroupsForSearch) {
        self.expandsGroupsForSearch = searching;
        [self rebuildSections];
    }
    [super updateSearchResultsForSearchController:searchController];
}

- (void)toggleGroupWithKey:(NSString *)key {
    if (!key)
        return;
    if ([self.expandedGroups containsObject:key])
        [self.expandedGroups removeObject:key];
    else
        [self.expandedGroups addObject:key];
    [self rebuildSections];
}

- (void)selectFamily:(NSString *)family {
    NSString *current = [SPKFontManager selectedFamilyName];
    BOOL unchanged = (family.length == 0 && current.length == 0) || (family.length > 0 && [family isEqualToString:current]);
    if (unchanged)
        return;

    [SPKFontManager setSelectedFamilyName:family];
    // The restart action acts on this immediately, so the write has to be on disk
    // before the alert goes up rather than at the next autosave.
    [NSUserDefaults.standardUserDefaults synchronize];

    [self rebuildSections];
    [self refreshSpecimen];
    [SPKUtils showRestartConfirmation];
}

#pragma mark - Rows

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    SPKSetting *row = self.sections[indexPath.section][@"rows"][indexPath.row];

    // The base class styles rows through a UIListContentConfiguration, so the row's
    // typeface has to be set there -- writing to cell.textLabel would be discarded.
    NSString *family = row.userInfo[@"family"];
    if (family && [cell.contentConfiguration isKindOfClass:[UIListContentConfiguration class]]) {
        UIListContentConfiguration *content = [(UIListContentConfiguration *)cell.contentConfiguration copy];
        CGFloat pointSize = content.textProperties.font.pointSize ?: [UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize;
        UIFont *rowFont = [self fontForFamily:family size:pointSize weight:UIFontWeightRegular];
        if (rowFont) {
            content.textProperties.font = rowFont;
            cell.contentConfiguration = content;
        }
    }

    // Nested under the family that owns them, so the group reads as a heading rather
    // than as one more row in a flat list.
    if ([row.userInfo[@"indented"] boolValue] && [cell.contentConfiguration isKindOfClass:[UIListContentConfiguration class]]) {
        UIListContentConfiguration *content = [(UIListContentConfiguration *)cell.contentConfiguration copy];
        NSDirectionalEdgeInsets margins = content.directionalLayoutMargins;
        margins.leading += 16.0;
        content.directionalLayoutMargins = margins;
        cell.contentConfiguration = content;
    }

    if (row.userInfo[@"group"]) {
        UIImageView *chevronView = [[UIImageView alloc] initWithImage:[self groupChevronImage]];
        chevronView.tintColor = [SPKUtils SPKColor_InstagramTertiaryText];
        // Points right when closed and down when open, the way a disclosure triangle
        // does. Nothing animates it: the rows around it are rebuilt on the same tap.
        if ([row.userInfo[@"expanded"] boolValue])
            chevronView.transform = CGAffineTransformMakeRotation(M_PI_2);
        cell.accessoryView = chevronView;
    } else if (row.userInfo[@"checkmarked"]) {
        if ([row.userInfo[@"checkmarked"] boolValue]) {
            UIImageView *checkmarkView = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"circle_check_filled"]];
            checkmarkView.tintColor = [SPKUtils SPKColor_InstagramBlue];
            cell.accessoryView = checkmarkView;
        } else {
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    } else {
        // Cells are reused across all three kinds of row here, so an accessory has to
        // be cleared explicitly or a file row inherits the last one's chevron.
        cell.accessoryView = nil;
    }
    return cell;
}

- (UIImage *)groupChevronImage {
    UIImage *image = [SPKAssetUtils instagramIconNamed:@"chevron_right"
                                             pointSize:14.0
                                         renderingMode:UIImageRenderingModeAlwaysTemplate];
    if (image)
        return image;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:12.0
                                                                                         weight:UIImageSymbolWeightSemibold];
    return [[UIImage systemImageNamed:@"chevron.right" withConfiguration:config] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

#pragma mark - Delete

- (SPKFontFile *)fileAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)self.sections.count)
        return nil;
    NSArray *rows = self.sections[indexPath.section][@"rows"];
    if (indexPath.row >= (NSInteger)rows.count)
        return nil;
    SPKSetting *row = rows[indexPath.row];
    return [row.userInfo[@"file"] isKindOfClass:[SPKFontFile class]] ? row.userInfo[@"file"] : nil;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self fileAtIndexPath:indexPath] != nil;
}

// The base returns None for every row, which suppresses swipe-to-delete outright --
// canEditRowAtIndexPath: alone is not enough to bring it back.
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self fileAtIndexPath:indexPath] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

// The system's own delete button would be a red bar reading "Delete"; every other
// Sparkle list deletes through a trash glyph on Instagram's destructive red.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPKFontFile *file = [self fileAtIndexPath:indexPath];
    if (!file)
        return nil;

    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:nil
                                              handler:^(__unused UIContextualAction *action, __unused UIView *sourceView,
                                                        void (^completionHandler)(BOOL)) {
                                                  [weakSelf deleteFontFile:file];
                                                  completionHandler(YES);
                                              }];
    deleteAction.image = [SPKAssetUtils menuIconNamed:@"trash"];
    deleteAction.backgroundColor = [SPKUtils SPKColor_InstagramDestructive];
    deleteAction.accessibilityLabel = SPKL(@"FONT_DELETE_FILE_ACCESSIBILITY_LABEL");
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction ]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete)
        return;
    [self deleteFontFile:[self fileAtIndexPath:indexPath]];
}

- (void)deleteFontFile:(SPKFontFile *)file {
    if (!file)
        return;

    NSString *wasSelected = [SPKFontManager selectedFamilyName];
    NSError *error = nil;
    if (![SPKFontManager removeFontFile:file error:&error]) {
        [self presentErrorWithTitle:SPKL(@"FONT_DELETE_ERROR_TITLE") message:error.localizedDescription];
        return;
    }

    [self reloadFonts];
    // Deleting the last file of the family in use drops the selection back to the
    // default, which only takes full effect on relaunch.
    if (wasSelected.length > 0 && [SPKFontManager selectedFamilyName].length == 0) {
        [NSUserDefaults.standardUserDefaults synchronize];
        [SPKUtils showRestartConfirmation];
    }
}

#pragma mark - Import

- (void)presentImportPicker {
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (NSString *identifier in @[ @"public.opentype-font", @"public.truetype-font",
                                    @"public.truetype-ttf-font", @"public.truetype-collection-font" ]) {
        UTType *type = [UTType typeWithIdentifier:identifier];
        if (type)
            [types addObject:type];
    }
    // Oddly-typed files can arrive as plain data; the import validates by parsing,
    // so a permissive picker is safer than one that hides real fonts.
    if (types.count == 0)
        [types addObject:UTTypeData];

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    self.activePicker = picker;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.activePicker = nil;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    self.activePicker = nil;

    NSUInteger imported = 0;
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSError *error = nil;
        if ([SPKFontManager importFontAtURL:url error:&error]) {
            imported++;
        } else {
            [failures addObject:error.localizedDescription ?: url.lastPathComponent];
        }
    }

    [self reloadFonts];

    if (failures.count > 0) {
        [self presentErrorWithTitle:imported > 0 ? SPKL(@"FONT_IMPORT_PARTIAL_ERROR_TITLE") : SPKL(@"FONT_IMPORT_ERROR_TITLE")
                            message:[failures componentsJoinedByString:@"\n"]];
    }
}

- (void)presentErrorWithTitle:(NSString *)title message:(NSString *)message {
    [SPKIGAlertPresenter presentAlertFromViewController:self
                                                  title:title
                                                message:message.length > 0 ? message : SPKL(@"FONT_ERROR_GENERIC_MESSAGE")
                                                actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK")
                                                                                       style:SPKIGAlertActionStyleCancel
                                                                                     handler:nil] ]];
}

@end
