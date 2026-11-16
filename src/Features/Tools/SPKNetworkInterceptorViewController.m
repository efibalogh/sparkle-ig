#import "SPKNetworkInterceptorViewController.h"

#import "SPKStrings.h"
#import "SPKNetworkInterceptor.h"
#import "../../AssetUtils.h"
#import "../../Shared/UI/SPKChipBar.h"
#import "../../Shared/UI/SPKMediaChrome.h"
#import "../../Shared/UI/SPKNotificationCenter.h"
#import "../../Utils.h"

typedef NS_ENUM(NSInteger, SPKNetworkScope) {
    SPKNetworkScopeAll,
    SPKNetworkScopeAPI,
    SPKNetworkScopeGraphQL,
    SPKNetworkScopeMedia,
    SPKNetworkScopeErrors,
};

static NSString *SPKNetworkByteString(long long bytes) {
    return [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile];
}

static NSString *SPKNetworkDurationString(NSTimeInterval duration) {
    NSMeasurement *measurement = [[NSMeasurement alloc] initWithDoubleValue:round(duration * 1000.0)
                                                                       unit:NSUnitDuration.milliseconds];
    static NSMeasurementFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSMeasurementFormatter new];
        formatter.unitOptions = NSMeasurementFormatterUnitOptionsProvidedUnit;
        formatter.unitStyle = NSFormattingUnitStyleShort;
        formatter.numberFormatter.maximumFractionDigits = 0;
    });
    return [formatter stringFromMeasurement:measurement];
}

static NSString *SPKNetworkTimeString(NSDate *date) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        [formatter setLocalizedDateFormatFromTemplate:@"HHmmss"];
    });
    return date ? [formatter stringFromDate:date] : @"";
}

static BOOL SPKNetworkEntryIsError(SPKNetworkEntry *entry) {
    return entry.state == SPKNetworkEntryStateFailed || entry.statusCode >= 400;
}

static NSString *SPKNetworkStatusString(SPKNetworkEntry *entry) {
    if (entry.state == SPKNetworkEntryStateFailed && entry.statusCode == 0)
        return SPKL(@"TOOLS_NETWORK_INTERCEPTOR_STATUS_FAILED");
    if (entry.statusCode > 0)
        return [NSString stringWithFormat:@"%ld", (long)entry.statusCode];
    return SPKL(@"TOOLS_NETWORK_INTERCEPTOR_STATUS_PENDING");
}

// Readable rendering of a request body: form parameters one per line, with any
// JSON value (GraphQL variables, signed_body payloads) pretty-printed in place.
static NSString *SPKNetworkReadableRequestBody(SPKNetworkEntry *entry) {
    NSData *body = entry.requestBody;
    if (body.length == 0)
        return nil;
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    BOOL looksLikeForm = text.length > 0 && ![text hasPrefix:@"{"] && ![text hasPrefix:@"["] &&
                         [text rangeOfString:@"="].location != NSNotFound && [text rangeOfString:@"\n"].location == NSNotFound;
    if (!looksLikeForm)
        return SPKNetworkInterceptorReadableBody(body);

    NSMutableString *out = [NSMutableString string];
    for (NSString *component in [text componentsSeparatedByString:@"&"]) {
        if (component.length == 0)
            continue;
        NSRange equals = [component rangeOfString:@"="];
        NSString *rawKey = equals.location == NSNotFound ? component : [component substringToIndex:equals.location];
        NSString *rawValue = equals.location == NSNotFound ? @"" : [component substringFromIndex:equals.location + 1];
        NSString *key = [[rawKey stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding] ?: rawKey;
        NSString *value = [[rawValue stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding] ?: rawValue;

        NSString *prefix = @"";
        NSString *json = value;
        // signed_body is "SIGNATURE.<json>".
        NSRange dot = [value rangeOfString:@"."];
        if (dot.location != NSNotFound && dot.location < 80 && value.length > dot.location + 1 &&
            ([value characterAtIndex:dot.location + 1] == '{' || [value characterAtIndex:dot.location + 1] == '[')) {
            prefix = [value substringToIndex:dot.location + 1];
            json = [value substringFromIndex:dot.location + 1];
        }
        NSString *pretty = nil;
        if ([json hasPrefix:@"{"] || [json hasPrefix:@"["])
            pretty = SPKNetworkInterceptorReadableBody([json dataUsingEncoding:NSUTF8StringEncoding]);
        if (pretty)
            [out appendFormat:@"%@ = %@\n%@\n", key, prefix, pretty];
        else
            [out appendFormat:@"%@ = %@\n", key, value];
    }
    return out;
}

static NSString *SPKNetworkHeaderBlock(NSDictionary<NSString *, NSString *> *headers) {
    if (headers.count == 0)
        return nil;
    NSMutableString *out = [NSMutableString string];
    for (NSString *name in [headers.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)])
        [out appendFormat:@"%@: %@\n", name, headers[name]];
    return out;
}

static NSString *SPKNetworkResponseBodyText(SPKNetworkEntry *entry) {
    if (entry.responseBodySkipped)
        return [NSString stringWithFormat:SPKL(@"TOOLS_NETWORK_INTERCEPTOR_BODY_NOT_CAPTURED_FORMAT"),
                                          entry.MIMEType ?: @"?", SPKNetworkByteString(entry.responseBytes)];
    NSData *body = [entry responseBodySnapshot];
    if (body.length == 0) {
        if (entry.state == SPKNetworkEntryStatePending)
            return SPKL(@"TOOLS_NETWORK_INTERCEPTOR_BODY_WAITING");
        return entry.responseObserved ? SPKL(@"TOOLS_NETWORK_INTERCEPTOR_BODY_EMPTY") : SPKL(@"TOOLS_NETWORK_INTERCEPTOR_BODY_NOT_OBSERVED");
    }
    NSString *readable = SPKNetworkInterceptorReadableBody(body);
    if (!readable)
        return [NSString stringWithFormat:SPKL(@"TOOLS_NETWORK_INTERCEPTOR_BODY_BINARY_FORMAT"), SPKNetworkByteString((long long)body.length)];
    if (entry.responseBodyTruncated)
        return [NSString stringWithFormat:@"%@\n\n%@", readable,
                                          [NSString stringWithFormat:SPKL(@"TOOLS_NETWORK_INTERCEPTOR_BODY_TRUNCATED_FORMAT"), SPKNetworkByteString((long long)body.length)]];
    return readable;
}

static NSDictionary *SPKNetworkEntryExportDictionary(SPKNetworkEntry *entry) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"id"] = @(entry.identifier);
    dict[@"start"] = @(entry.startDate.timeIntervalSince1970);
    dict[@"method"] = entry.method ?: @"";
    dict[@"url"] = entry.URL.absoluteString ?: @"";
    dict[@"status"] = @(entry.statusCode);
    dict[@"duration_ms"] = @(round(entry.duration * 1000.0));
    dict[@"response_bytes"] = @(entry.responseBytes);
    if (entry.graphQLName)
        dict[@"graphql_name"] = entry.graphQLName;
    if (entry.graphQLDocumentID)
        dict[@"graphql_doc_id"] = entry.graphQLDocumentID;
    if (entry.surface)
        dict[@"surface"] = entry.surface;
    if (entry.errorDescription)
        dict[@"error"] = entry.errorDescription;
    dict[@"request_headers"] = entry.requestHeaders ?: @{};
    if (entry.requestBody) {
        NSString *text = [[NSString alloc] initWithData:entry.requestBody encoding:NSUTF8StringEncoding];
        dict[@"request_body"] = text ?: [entry.requestBody base64EncodedStringWithOptions:0];
    }
    if (entry.responseHeaders)
        dict[@"response_headers"] = entry.responseHeaders;
    NSData *body = [entry responseBodySnapshot];
    if (body.length > 0) {
        NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (text)
            dict[@"response_body"] = text;
    }
    return dict;
}

static NSURL *SPKNetworkWriteTemporaryFile(NSString *stem, NSString *extension, NSData *data) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"%@-%@.%@", stem, [formatter stringFromDate:[NSDate date]], extension];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    return [data writeToURL:url atomically:YES] ? url : nil;
}

// MARK: - Detail

@interface SPKNetworkEntryDetailViewController : UIViewController
- (instancetype)initWithEntry:(SPKNetworkEntry *)entry;
@end

@implementation SPKNetworkEntryDetailViewController {
    SPKNetworkEntry *_entry;
    UITextView *_textView;
    NSString *_plainText;
}

- (instancetype)initWithEntry:(SPKNetworkEntry *)entry {
    self = [super init];
    if (!self)
        return nil;
    _entry = entry;
    self.title = entry.displayTitle.lastPathComponent ?: entry.displayTitle;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    _textView = [[UITextView alloc] initWithFrame:CGRectZero];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.editable = NO;
    _textView.alwaysBounceVertical = YES;
    _textView.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    _textView.textContainerInset = UIEdgeInsetsMake(16.0, 14.0, 16.0, 14.0);
    _textView.layer.cornerRadius = 14.0;
    _textView.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    _textView.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    _textView.text = SPKL(@"TOOLS_NETWORK_INTERCEPTOR_LOADING");
    [self.view addSubview:_textView];

    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12.0],
        [_textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [_textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [_textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12.0],
    ]];

    UIBarButtonItem *shareItem = SPKMediaChromeTopBarButtonItem(@"share", self, @selector(shareTapped));
    shareItem.accessibilityLabel = SPKL(@"ALERT_ACTION_SHARE");
    UIBarButtonItem *copyItem = SPKMediaChromeTopBarMenuButtonItem(@"copy", [self copyMenu], SPKL(@"TOOLS_NETWORK_INTERCEPTOR_COPY_MENU_ACCESSIBILITY"));
    SPKMediaChromeSetTrailingTopBarItemGroups(self.navigationItem, @[ @[ copyItem ], @[ shareItem ] ]);

    [self reloadContent];
}

- (UIMenu *)copyMenu {
    __weak typeof(self) weakSelf = self;
    SPKNetworkEntry *entry = _entry;
    UIImage *copyIcon = [SPKAssetUtils menuIconNamed:@"copy"];
    UIImage *linkIcon = [SPKAssetUtils menuIconNamed:@"link"];
    UIImage *textIcon = [SPKAssetUtils menuIconNamed:@"text"];
    return [UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:SPKL(@"TOOLS_NETWORK_INTERCEPTOR_COPY_CURL") image:copyIcon identifier:nil handler:^(__unused UIAction *action) {
            [weakSelf copyString:[entry curlCommand]];
        }],
        [UIAction actionWithTitle:SPKL(@"TOOLS_NETWORK_INTERCEPTOR_COPY_URL") image:linkIcon identifier:nil handler:^(__unused UIAction *action) {
            [weakSelf copyString:entry.URL.absoluteString];
        }],
        [UIAction actionWithTitle:SPKL(@"TOOLS_NETWORK_INTERCEPTOR_COPY_RESPONSE") image:textIcon identifier:nil handler:^(__unused UIAction *action) {
            [weakSelf copyString:SPKNetworkInterceptorReadableBody([entry responseBodySnapshot])];
        }],
        [UIAction actionWithTitle:SPKL(@"TOOLS_NETWORK_INTERCEPTOR_COPY_EVERYTHING") image:copyIcon identifier:nil handler:^(__unused UIAction *action) {
            typeof(self) strongSelf = weakSelf;
            if (strongSelf)
                [strongSelf copyString:strongSelf->_plainText];
        }],
    ]];
}

- (void)copyString:(NSString *)string {
    if (string.length == 0) {
        SPKNotify(kSPKNotificationNetworkInterceptor, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NOTHING_COPY_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return;
    }
    [UIPasteboard generalPasteboard].string = string;
    SPKNotify(kSPKNotificationNetworkInterceptor, SPKL(@"TOOLS_NETWORK_INTERCEPTOR_COPIED"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
}

- (void)shareTapped {
    NSData *data = [_plainText dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0)
        return;
    NSURL *url = SPKNetworkWriteTemporaryFile(@"Sparkle-Request", @"txt", data);
    [SPKUtils showShareVC:url ?: _plainText];
}

- (void)reloadContent {
    SPKNetworkEntry *entry = _entry;
    UIColor *headingColor = [SPKUtils SPKColor_InstagramPrimaryText];
    UIColor *bodyColor = [SPKUtils SPKColor_InstagramSecondaryText];
    // Pretty-printing a large response is not main-thread work.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableAttributedString *text = [NSMutableAttributedString new];
        NSMutableString *plain = [NSMutableString string];
        UIFont *headingFont = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightBold];
        UIFont *bodyFont = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];

        void (^append)(NSString *, UIFont *, UIColor *) = ^(NSString *string, UIFont *font, UIColor *color) {
            if (string.length == 0)
                return;
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:string
                                                                         attributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : color}]];
            [plain appendString:string];
        };
        void (^section)(NSString *, NSString *) = ^(NSString *title, NSString *content) {
            append([NSString stringWithFormat:@"\n%@\n", title], headingFont, headingColor);
            append([NSString stringWithFormat:@"%@\n", content.length > 0 ? content : SPKL(@"TOOLS_NETWORK_INTERCEPTOR_NONE")], bodyFont, bodyColor);
        };

        append([NSString stringWithFormat:@"%@ %@\n", entry.method, entry.URL.absoluteString ?: @"?"], headingFont, headingColor);

        NSMutableString *overview = [NSMutableString string];
        [overview appendFormat:@"%@: %@\n", SPKL(@"TOOLS_NETWORK_INTERCEPTOR_FIELD_STATUS"), SPKNetworkStatusString(entry)];
        if (entry.state != SPKNetworkEntryStatePending)
            [overview appendFormat:@"%@: %@\n", SPKL(@"TOOLS_NETWORK_INTERCEPTOR_FIELD_DURATION"), SPKNetworkDurationString(entry.duration)];
        [overview appendFormat:@"%@: %@\n", SPKL(@"TOOLS_NETWORK_INTERCEPTOR_FIELD_SIZE"), SPKNetworkByteString(entry.responseBytes)];
        if (entry.MIMEType)
            [overview appendFormat:@"%@: %@\n", SPKL(@"TOOLS_NETWORK_INTERCEPTOR_FIELD_CONTENT_TYPE"), entry.MIMEType];
        [overview appendFormat:@"%@: %@\n", SPKL(@"TOOLS_NETWORK_INTERCEPTOR_FIELD_STARTED"), SPKNetworkTimeString(entry.startDate)];
        if (entry.graphQLName)
            [overview appendFormat:@"%@: %@\n", SPKL(@"TOOLS_NETWORK_INTERCEPTOR_FIELD_GRAPHQL_QUERY"), entry.graphQLName];
        if (entry.graphQLDocumentID)
            [overview appendFormat:@"%@: %@\n", SPKL(@"TOOLS_NETWORK_INTERCEPTOR_FIELD_DOCUMENT_ID"), entry.graphQLDocumentID];
        if (entry.surface)
            [overview appendFormat:@"%@: %@\n", SPKL(@"TOOLS_NETWORK_INTERCEPTOR_FIELD_SURFACE"), entry.surface];
        if (entry.errorDescription)
            [overview appendFormat:@"%@: %@\n", SPKL(@"TOOLS_NETWORK_INTERCEPTOR_FIELD_ERROR"), entry.errorDescription];
        append(overview, bodyFont, bodyColor);

        section(SPKL(@"TOOLS_NETWORK_INTERCEPTOR_SECTION_REQUEST_HEADERS"), SPKNetworkHeaderBlock(entry.requestHeaders));

        NSMutableString *requestBody = [NSMutableString string];
        if (entry.requestBodyWasGzip)
            [requestBody appendFormat:@"%@\n", SPKL(@"TOOLS_NETWORK_INTERCEPTOR_BODY_DECOMPRESSED_GZIP")];
        if (entry.requestBodyNote)
            [requestBody appendFormat:@"(%@)\n", entry.requestBodyNote];
        NSString *readableRequest = SPKNetworkReadableRequestBody(entry);
        if (readableRequest)
            [requestBody appendString:readableRequest];
        else if (entry.requestBody.length > 0)
            [requestBody appendFormat:SPKL(@"TOOLS_NETWORK_INTERCEPTOR_BODY_BINARY_FORMAT"), SPKNetworkByteString((long long)entry.requestBody.length)];
        section(SPKL(@"TOOLS_NETWORK_INTERCEPTOR_SECTION_REQUEST_BODY"), requestBody);

        section(SPKL(@"TOOLS_NETWORK_INTERCEPTOR_SECTION_RESPONSE_HEADERS"), SPKNetworkHeaderBlock(entry.responseHeaders));
        section(SPKL(@"TOOLS_NETWORK_INTERCEPTOR_SECTION_RESPONSE_BODY"), SPKNetworkResponseBodyText(entry));

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_plainText = plain;
            self->_textView.attributedText = text;
        });
    });
}

@end

// MARK: - List

@interface SPKNetworkInterceptorViewController () <UISearchResultsUpdating, UITableViewDataSource, UITableViewDelegate, SPKChipBarDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) SPKChipBar *chipBar;
@property (nonatomic, copy) NSArray<SPKNetworkEntry *> *visibleEntries;
@end

@implementation SPKNetworkInterceptorViewController {
    UISearchController *_searchController;
    BOOL _reloadDeferred;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (!self)
        return nil;
    self.title = SPKL(@"TOOLS_NETWORK_INTERCEPTOR_TITLE");
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    // Root of its own sheet (opened from the debug button), not pushed from Settings.
    if (self.navigationController.viewControllers.firstObject == self)
        SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[ SPKMediaChromeTopBarButtonItem(@"xmark", self, @selector(close)) ]);

    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchResultsUpdater = self;
    _searchController.searchBar.placeholder = SPKL(@"TOOLS_NETWORK_INTERCEPTOR_SEARCH_PLACEHOLDER");
    [_searchController.searchBar setImage:[SPKAssetUtils instagramIconNamed:@"search" pointSize:18.0]
                         forSearchBarIcon:UISearchBarIconSearch
                                    state:UIControlStateNormal];
    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    // The kind filter lives outside the search bar so it stays put whether or
    // not a search is active.
    self.chipBar = [[SPKChipBar alloc] initWithFrame:CGRectZero];
    self.chipBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.chipBar.delegate = self;
    self.chipBar.distributesProportionally = YES;
    [self.chipBar setItems:@[
        SPKL(@"TOOLS_NETWORK_INTERCEPTOR_SCOPE_ALL"),
        SPKL(@"TOOLS_NETWORK_INTERCEPTOR_SCOPE_API"),
        SPKL(@"TOOLS_NETWORK_INTERCEPTOR_SCOPE_GRAPHQL"),
        SPKL(@"TOOLS_NETWORK_INTERCEPTOR_SCOPE_MEDIA"),
        SPKL(@"TOOLS_NETWORK_INTERCEPTOR_SCOPE_ERRORS"),
    ]
                   symbols:nil];
    self.chipBar.selectedIndex = 0;
    [self.view addSubview:self.chipBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.chipBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.chipBar.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.chipBar.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.chipBar.heightAnchor constraintEqualToConstant:50.0],
        [self.tableView.topAnchor constraintEqualToAnchor:self.chipBar.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(entriesChanged)
                                                 name:SPKNetworkInterceptorDidChangeNotification
                                               object:nil];
    [self updateBarItems];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadEntries];
}

- (void)updateBarItems {
    BOOL recording = SPKNetworkInterceptorIsRecording();
    UIBarButtonItem *recordItem = SPKMediaChromeTopBarButtonItemWithTint(recording ? @"pause" : @"play_filled",
                                                                         self, @selector(toggleRecording),
                                                                         recording ? [SPKUtils SPKColor_InstagramDestructive] : nil,
                                                                         recording ? SPKL(@"TOOLS_NETWORK_INTERCEPTOR_STOP_RECORDING") : SPKL(@"TOOLS_NETWORK_INTERCEPTOR_START_RECORDING"));
    __weak typeof(self) weakSelf = self;
    UIAction *clearAction = [UIAction actionWithTitle:SPKL(@"ALERT_ACTION_CLEAR")
                                                image:[SPKAssetUtils menuIconNamed:@"trash"]
                                           identifier:nil
                                              handler:^(__unused UIAction *action) {
                                                  SPKNetworkInterceptorClear();
                                                  [weakSelf reloadEntries];
                                              }];
    clearAction.attributes = UIMenuElementAttributesDestructive;
    UIMenu *menu = [UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:SPKL(@"TOOLS_NETWORK_INTERCEPTOR_EXPORT_JSON")
                            image:[SPKAssetUtils menuIconNamed:@"share"]
                       identifier:nil
                          handler:^(__unused UIAction *action) {
                              [weakSelf exportVisible];
                          }],
        clearAction,
    ]];
    UIBarButtonItem *moreItem = SPKMediaChromeTopBarMenuButtonItem(@"more", menu, SPKL(@"TOOLS_NETWORK_INTERCEPTOR_MORE_ACCESSIBILITY"));
    // Two separate glass bubbles, record on the left and More on the right.
    SPKMediaChromeSetTrailingTopBarItemGroups(self.navigationItem, @[ @[ recordItem ], @[ moreItem ] ]);
}

static NSString *const kSPKNetworkInterceptorRevealKey = @"network_interceptor";

+ (void)present {
    if ([SPKUtils revealViewControllerWithKey:kSPKNetworkInterceptorRevealKey])
        return;
    [SPKUtils presentViewControllerInSheet:[self new] revealKey:kSPKNetworkInterceptorRevealKey];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

+ (void)setRecording:(BOOL)recording clearFirst:(BOOL)clearFirst {
    if (clearFirst)
        SPKNetworkInterceptorClear();
    SPKNetworkInterceptorSetRecording(recording);
    SPKNotify(kSPKNotificationNetworkInterceptor,
              recording ? SPKL(@"TOOLS_NETWORK_INTERCEPTOR_RECORDING_STARTED") : SPKL(@"TOOLS_NETWORK_INTERCEPTOR_RECORDING_STOPPED"),
              nil, recording ? @"circle_check_filled" : @"info_filled",
              recording ? SPKNotificationToneSuccess : SPKNotificationToneInfo);
}

- (void)toggleRecording {
    [SPKNetworkInterceptorViewController setRecording:!SPKNetworkInterceptorIsRecording() clearFirst:NO];
    [self updateBarItems];
    [self reloadEntries];
}

- (void)exportVisible {
    NSArray<SPKNetworkEntry *> *entries = self.visibleEntries ?: @[];
    if (entries.count == 0) {
        SPKNotify(kSPKNotificationNetworkInterceptor, SPKL(@"TOOLS_NETWORK_INTERCEPTOR_EMPTY_TITLE"), nil, @"info_filled", SPKNotificationToneInfo);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:entries.count];
        for (SPKNetworkEntry *entry in entries.reverseObjectEnumerator)
            [items addObject:SPKNetworkEntryExportDictionary(entry)];
        NSData *data = [NSJSONSerialization dataWithJSONObject:items options:NSJSONWritingPrettyPrinted error:nil];
        NSURL *url = data ? SPKNetworkWriteTemporaryFile(@"Sparkle-Network", @"json", data) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (url)
                [SPKUtils showShareVC:url];
        });
    });
}

// Live updates insert at the top. Reloading while the list is scrolled would
// shift the rows being read, so that waits until the list is back at the top.
- (BOOL)isAtTop {
    return self.tableView.contentOffset.y <= -self.tableView.adjustedContentInset.top + 8.0;
}

- (void)entriesChanged {
    if (!self.viewIfLoaded.window)
        return;
    if (![self isAtTop] || self.tableView.isTracking || self.tableView.isDecelerating) {
        _reloadDeferred = YES;
        return;
    }
    [self reloadEntries];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (_reloadDeferred && [self isAtTop])
        [self reloadEntries];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate && _reloadDeferred && [self isAtTop])
        [self reloadEntries];
}

- (void)scrollViewDidScrollToTop:(UIScrollView *)scrollView {
    if (_reloadDeferred)
        [self reloadEntries];
}

- (void)reloadEntries {
    _reloadDeferred = NO;
    NSString *query = [_searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    SPKNetworkScope scope = (SPKNetworkScope)self.chipBar.selectedIndex;
    NSMutableArray<SPKNetworkEntry *> *filtered = [NSMutableArray array];
    for (SPKNetworkEntry *entry in SPKNetworkInterceptorEntries()) {
        switch (scope) {
        case SPKNetworkScopeAll:
            break;
        case SPKNetworkScopeAPI:
            if (entry.kind != SPKNetworkEntryKindAPI)
                continue;
            break;
        case SPKNetworkScopeGraphQL:
            if (entry.kind != SPKNetworkEntryKindGraphQL)
                continue;
            break;
        case SPKNetworkScopeMedia:
            if (entry.kind != SPKNetworkEntryKindMedia)
                continue;
            break;
        case SPKNetworkScopeErrors:
            if (!SPKNetworkEntryIsError(entry))
                continue;
            break;
        }
        if (query.length > 0) {
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@", entry.method, entry.URL.absoluteString ?: @"",
                                                            entry.graphQLName ?: @"", entry.graphQLDocumentID ?: @"", entry.surface ?: @""];
            if ([haystack rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound)
                continue;
        }
        [filtered addObject:entry];
    }
    self.visibleEntries = filtered;
    self.tableView.backgroundView = filtered.count == 0 ? [self emptyStateView] : nil;
    [self.tableView reloadData];
}

- (UIView *)emptyStateView {
    UIView *container = [UIView new];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"empty" pointSize:96 renderingMode:UIImageRenderingModeAlwaysTemplate]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = [SPKUtils SPKColor_InstagramTertiaryText];
    [container addSubview:icon];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    title.text = SPKL(@"TOOLS_NETWORK_INTERCEPTOR_EMPTY_TITLE");
    [container addSubview:title];

    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.font = [UIFont systemFontOfSize:14];
    subtitle.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    subtitle.text = SPKNetworkInterceptorIsRecording() ? SPKL(@"TOOLS_NETWORK_INTERCEPTOR_EMPTY_RECORDING_SUBTITLE")
                                                       : SPKL(@"TOOLS_NETWORK_INTERCEPTOR_EMPTY_PAUSED_SUBTITLE");
    [container addSubview:subtitle];

    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.centerXAnchor],
        [icon.widthAnchor constraintEqualToConstant:96],
        [icon.heightAnchor constraintEqualToConstant:96],
        [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:18],
        // Centre the icon + text block, nudged up like the other empty screens.
        [title.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:6],
        [title.leadingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.leadingAnchor constant:40],
        [title.trailingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.trailingAnchor constant:-40],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
    ]];
    return container;
}

// MARK: Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self reloadEntries];
}

- (void)chipBar:(SPKChipBar *)bar didSelectIndex:(NSInteger)index {
    [self reloadEntries];
}

// MARK: Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleEntries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const reuseIdentifier = @"SPKNetworkEntryCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    cell.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    SPKNetworkEntry *entry = self.visibleEntries[indexPath.row];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = entry.displayTitle;
    content.textProperties.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    content.textProperties.color = [SPKUtils SPKColor_InstagramPrimaryText];
    content.textProperties.numberOfLines = 2;
    content.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;

    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:entry.method, SPKNetworkStatusString(entry), nil];
    if (entry.URL.host)
        [parts addObject:entry.URL.host];
    if (entry.responseBytes > 0)
        [parts addObject:SPKNetworkByteString(entry.responseBytes)];
    if (entry.state != SPKNetworkEntryStatePending)
        [parts addObject:SPKNetworkDurationString(entry.duration)];
    [parts addObject:SPKNetworkTimeString(entry.startDate)];
    content.secondaryText = [parts componentsJoinedByString:@" · "];
    content.secondaryTextProperties.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    content.secondaryTextProperties.color = SPKNetworkEntryIsError(entry) ? [SPKUtils SPKColor_InstagramDestructive]
                                                                          : [SPKUtils SPKColor_InstagramSecondaryText];
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SPKNetworkEntry *entry = self.visibleEntries[indexPath.row];
    [self.navigationController pushViewController:[[SPKNetworkEntryDetailViewController alloc] initWithEntry:entry] animated:YES];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                        point:(CGPoint)point {
    SPKNetworkEntry *entry = self.visibleEntries[indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) {
                                                        return [UIMenu menuWithChildren:@[
                                                            [UIAction actionWithTitle:SPKL(@"TOOLS_NETWORK_INTERCEPTOR_COPY_CURL")
                                                                                image:[SPKAssetUtils menuIconNamed:@"copy"]
                                                                           identifier:nil
                                                                              handler:^(__unused UIAction *action) {
                                                                                  [UIPasteboard generalPasteboard].string = [entry curlCommand];
                                                                                  SPKNotify(kSPKNotificationNetworkInterceptor, SPKL(@"TOOLS_NETWORK_INTERCEPTOR_COPIED"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                              }],
                                                            [UIAction actionWithTitle:SPKL(@"TOOLS_NETWORK_INTERCEPTOR_COPY_URL")
                                                                                image:[SPKAssetUtils menuIconNamed:@"link"]
                                                                           identifier:nil
                                                                              handler:^(__unused UIAction *action) {
                                                                                  [UIPasteboard generalPasteboard].string = entry.URL.absoluteString ?: @"";
                                                                                  SPKNotify(kSPKNotificationNetworkInterceptor, SPKL(@"TOOLS_NETWORK_INTERCEPTOR_COPIED"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
                                                                              }],
                                                        ]];
                                                    }];
}

@end
