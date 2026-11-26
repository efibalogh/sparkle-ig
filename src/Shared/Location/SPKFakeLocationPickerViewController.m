#import "SPKFakeLocationPickerViewController.h"

#import <MapKit/MapKit.h>

#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../UI/SPKMediaChrome.h"
#import "../i18n/SPKStrings.h"
#import "../UI/SPKFont.h"

// Region shown when there is no place to start from and no known real location.
static const CLLocationDistance kSPKFakeLocationPickerDefaultSpan = 2000.0;
// Reverse geocoding is rate limited per app; wait for the map to settle first.
static const NSTimeInterval kSPKFakeLocationPickerGeocodeDelay = 0.35;

static NSString *SPKFakeLocationPlacemarkAddress(CLPlacemark *placemark) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *street = placemark.thoroughfare;
    if (street.length && placemark.subThoroughfare.length)
        street = [NSString stringWithFormat:@"%@ %@", placemark.subThoroughfare, street];
    for (NSString *part in @[ street ?: @"", placemark.locality ?: @"", placemark.administrativeArea ?: @"", placemark.country ?: @"" ]) {
        if (part.length && ![parts containsObject:part] && ![part isEqualToString:placemark.name])
            [parts addObject:part];
    }
    return [parts componentsJoinedByString:SPKL(@"COMMON_LIST_SEPARATOR")];
}

#pragma mark - Search results

@interface SPKFakeLocationSearchResultsController : UITableViewController
@property (nonatomic, copy) NSArray<MKLocalSearchCompletion *> *results;
@property (nonatomic, copy) void (^onSelect)(MKLocalSearchCompletion *completion);
@end

@implementation SPKFakeLocationSearchResultsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)setResults:(NSArray<MKLocalSearchCompletion *> *)results {
    _results = [results copy];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const identifier = @"SPKFakeLocationSearchResult";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier]
                                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    MKLocalSearchCompletion *result = self.results[indexPath.row];
    cell.backgroundColor = [UIColor clearColor];
    cell.textLabel.text = result.title;
    cell.textLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    cell.detailTextLabel.text = result.subtitle;
    cell.detailTextLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    cell.imageView.image = [SPKAssetUtils instagramIconNamed:@"location" pointSize:22.0];
    cell.imageView.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.onSelect && indexPath.row < (NSInteger)self.results.count)
        self.onSelect(self.results[indexPath.row]);
}

@end

#pragma mark - Picker

static const CGFloat kSPKFakeLocationTrackingPlatterSize = 44.0;

@interface SPKFakeLocationPickerViewController () <MKMapViewDelegate, MKLocalSearchCompleterDelegate, UISearchResultsUpdating>
@property (nonatomic, strong, nullable) SPKFakeLocationPlace *initialPlace;
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) MKMarkerAnnotationView *pinView;
@property (nonatomic, strong) UIVisualEffectView *cardView;
@property (nonatomic, strong, nullable) UIVisualEffectView *trackingPlatter;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *addressLabel;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) SPKFakeLocationSearchResultsController *resultsController;
@property (nonatomic, strong) MKLocalSearchCompleter *completer;
@property (nonatomic, strong, nullable) MKLocalSearch *activeSearch;
@property (nonatomic, strong) CLGeocoder *geocoder;
@property (nonatomic, copy, nullable) NSString *resolvedName;
@property (nonatomic, copy, nullable) NSString *resolvedAddress;
// A name from a search result or the initial place outranks the reverse-geocoded
// one, until the user pans the map away from it.
@property (nonatomic, assign) BOOL keepsResolvedName;
@property (nonatomic, assign) BOOL movingProgrammatically;
@end

@implementation SPKFakeLocationPickerViewController

+ (void)presentFromViewController:(UIViewController *)presenter
                     initialPlace:(SPKFakeLocationPlace *)place
                            title:(NSString *)title
                       completion:(void (^)(SPKFakeLocationPlace *))completion {
    UIViewController *root = presenter ?: UIApplication.sharedApplication.keyWindow.rootViewController;
    while (root.presentedViewController && !root.presentedViewController.isBeingDismissed)
        root = root.presentedViewController;
    if (!root)
        return;

    SPKFakeLocationPickerViewController *picker = [[SPKFakeLocationPickerViewController alloc] initWithInitialPlace:place title:title];
    picker.completion = completion;
    UINavigationController *navigation = [[SPKChromeNavigationController alloc] initWithRootViewController:picker];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [root presentViewController:navigation animated:YES completion:nil];
}

- (instancetype)initWithInitialPlace:(SPKFakeLocationPlace *)place title:(NSString *)title {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _initialPlace = place;
        _geocoder = [CLGeocoder new];
        self.title = title;
        if (place) {
            _resolvedName = place.name;
            _resolvedAddress = place.address;
            _keepsResolvedName = place.name.length > 0;
        }
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];

    SPKMediaChromeSetLeadingTopBarItems(self.navigationItem, @[
        SPKMediaChromeTopBarButtonItemWithTint(@"xmark", self, @selector(spk_cancel), nil, SPKL(@"ALERT_ACTION_CANCEL")),
    ]);
    // The only confirm on this screen commits the choice, so it is the prominent one.
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[
        SPKMediaChromeTopBarButtonItemWithStyle(@"check", self, @selector(spk_confirm), UIBarButtonItemStyleDone,
                                                [SPKUtils SPKColor_InstagramBlue], SPKL(@"MESSAGES_FAKE_LOCATION_PICKER_CONFIRM_A11Y")),
    ]);

    [self spk_buildMap];
    [self spk_buildPin];
    [self spk_buildCard];
    [self spk_buildSearch];
    [self spk_moveToInitialRegion];
    [self spk_refreshCard];
}

#pragma mark Layout

- (void)spk_buildMap {
    MKMapView *map = [MKMapView new];
    map.translatesAutoresizingMaskIntoConstraints = NO;
    map.delegate = self;
    map.showsCompass = YES;
    map.pointOfInterestFilter = [MKPointOfInterestFilter filterIncludingAllCategories];
    // MapKit runs its own location manager, which the fake location never touches,
    // so the blue dot is the real position. Only turn it on when access is already
    // granted: asking for it here would put a system prompt over the picker.
    CLAuthorizationStatus status = [CLLocationManager new].authorizationStatus;
    map.showsUserLocation = status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways;
    [self.view addSubview:map];
    [NSLayoutConstraint activateConstraints:@[
        [map.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [map.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [map.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [map.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    self.mapView = map;

    if (map.showsUserLocation) {
        // A round platter in the card's material, placed above the card on the
        // trailing side in spk_buildCard. The top trailing corner is MapKit's
        // compass, which appears whenever the map is rotated.
        UIVisualEffectView *platter = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        platter.translatesAutoresizingMaskIntoConstraints = NO;
        platter.layer.cornerRadius = kSPKFakeLocationTrackingPlatterSize / 2.0;
        platter.layer.cornerCurve = kCACornerCurveCircular;
        platter.clipsToBounds = YES;
        MKUserTrackingButton *tracking = [MKUserTrackingButton userTrackingButtonWithMapView:map];
        tracking.translatesAutoresizingMaskIntoConstraints = NO;
        tracking.tintColor = [SPKUtils SPKColor_InstagramBlue];
        [platter.contentView addSubview:tracking];
        [self.view addSubview:platter];
        [NSLayoutConstraint activateConstraints:@[
            [platter.widthAnchor constraintEqualToConstant:kSPKFakeLocationTrackingPlatterSize],
            [platter.heightAnchor constraintEqualToConstant:kSPKFakeLocationTrackingPlatterSize],
            [tracking.centerXAnchor constraintEqualToAnchor:platter.contentView.centerXAnchor],
            [tracking.centerYAnchor constraintEqualToAnchor:platter.contentView.centerYAnchor],
        ]];
        self.trackingPlatter = platter;
    }
}

// A fixed pin over the map centre rather than a draggable annotation: panning the
// map under it is easier to aim precisely than dragging a pin under a finger.
- (void)spk_buildPin {
    MKMarkerAnnotationView *pin = [[MKMarkerAnnotationView alloc] initWithAnnotation:nil reuseIdentifier:nil];
    pin.markerTintColor = [SPKUtils SPKColor_InstagramBlue];
    pin.glyphImage = [SPKAssetUtils instagramIconNamed:@"location_filled" pointSize:16.0];
    pin.userInteractionEnabled = NO;
    pin.animatesWhenAdded = NO;
    [self.view addSubview:pin];
    self.pinView = pin;
}

- (void)spk_buildCard {
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 20.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;

    UILabel *name = [UILabel new];
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleBody weight:UIFontWeightSemibold] to:name];
    name.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    name.numberOfLines = 1;

    UILabel *address = [UILabel new];
    [SPKFont apply:[SPKFont fontForStyle:SPKFontStyleSubheadline] to:address];
    address.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    address.numberOfLines = 2;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ name, address ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];

    [self.view addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16.0],
        [card.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16.0],
        [card.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16.0],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:14.0],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-14.0],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:16.0],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-16.0],
    ]];
    if (self.trackingPlatter) {
        [NSLayoutConstraint activateConstraints:@[
            [self.trackingPlatter.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
            [self.trackingPlatter.bottomAnchor constraintEqualToAnchor:card.topAnchor constant:-12.0],
        ]];
    }
    self.cardView = card;
    self.nameLabel = name;
    self.addressLabel = address;
}

- (void)spk_buildSearch {
    SPKFakeLocationSearchResultsController *results = [[SPKFakeLocationSearchResultsController alloc] initWithStyle:UITableViewStylePlain];
    __weak typeof(self) weakSelf = self;
    results.onSelect = ^(MKLocalSearchCompletion *completion) {
        [weakSelf spk_selectCompletion:completion];
    };
    self.resultsController = results;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:results];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = YES;
    search.searchBar.placeholder = SPKL(@"MESSAGES_FAKE_LOCATION_PICKER_SEARCH_PLACEHOLDER");
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.searchController = search;

    MKLocalSearchCompleter *completer = [MKLocalSearchCompleter new];
    completer.delegate = self;
    completer.resultTypes = MKLocalSearchCompleterResultTypeAddress | MKLocalSearchCompleterResultTypePointOfInterest;
    self.completer = completer;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // The marker's tip sits at the bottom centre of its frame; put the tip on the
    // map centre so the coordinate read back is the one under the point.
    CGPoint centre = CGPointMake(CGRectGetMidX(self.mapView.frame), CGRectGetMidY(self.mapView.frame));
    CGSize size = self.pinView.intrinsicContentSize;
    if (size.width <= 0 || size.height <= 0)
        size = CGSizeMake(40.0, 48.0);
    self.pinView.bounds = CGRectMake(0, 0, size.width, size.height);
    self.pinView.center = CGPointMake(centre.x, centre.y - size.height / 2.0);
    // Lifts MapKit's legal label and compass clear of the card. The centre the pin
    // reads is the frame's, which the card never reaches.
    CGFloat cardInset = CGRectGetHeight(self.view.bounds) - CGRectGetMinY(self.cardView.frame);
    self.mapView.layoutMargins = UIEdgeInsetsMake(0, 0, MAX(0, cardInset), 0);
}

#pragma mark Region

- (void)spk_setCentre:(CLLocationCoordinate2D)coordinate animated:(BOOL)animated {
    self.movingProgrammatically = YES;
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(coordinate, kSPKFakeLocationPickerDefaultSpan, kSPKFakeLocationPickerDefaultSpan);
    [self.mapView setRegion:region animated:animated];
    if (!animated)
        self.movingProgrammatically = NO;
}

- (void)spk_moveToInitialRegion {
    if (self.initialPlace) {
        [self spk_setCentre:self.initialPlace.coordinate animated:NO];
        return;
    }
    // Fall back to the real location MapKit already knows, if any; the spoofed one
    // is deliberately not used, since this manager is not Instagram's.
    CLLocation *known = [CLLocationManager new].location;
    if (known)
        [self spk_setCentre:known.coordinate animated:NO];
    [self spk_scheduleGeocode];
}

- (void)mapView:(MKMapView *)mapView regionWillChangeAnimated:(BOOL)animated {
    if (!self.movingProgrammatically)
        self.keepsResolvedName = NO;
    [self.geocoder cancelGeocode];
}

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {
    self.movingProgrammatically = NO;
    if (!self.keepsResolvedName)
        [self spk_scheduleGeocode];
    [self spk_refreshCard];
}

#pragma mark Geocoding

- (void)spk_scheduleGeocode {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(spk_geocodeCentre) object:nil];
    self.resolvedName = nil;
    self.resolvedAddress = nil;
    [self spk_refreshCard];
    [self performSelector:@selector(spk_geocodeCentre) withObject:nil afterDelay:kSPKFakeLocationPickerGeocodeDelay];
}

- (void)spk_geocodeCentre {
    CLLocationCoordinate2D centre = self.mapView.centerCoordinate;
    CLLocation *location = [[CLLocation alloc] initWithLatitude:centre.latitude longitude:centre.longitude];
    [self.geocoder cancelGeocode];
    __weak typeof(self) weakSelf = self;
    [self.geocoder reverseGeocodeLocation:location
                        completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
                            typeof(self) strongSelf = weakSelf;
                            if (!strongSelf || strongSelf.keepsResolvedName)
                                return;
                            CLPlacemark *placemark = placemarks.firstObject;
                            if (!placemark)
                                return;
                            strongSelf.resolvedName = placemark.name ?: placemark.locality;
                            strongSelf.resolvedAddress = SPKFakeLocationPlacemarkAddress(placemark);
                            [strongSelf spk_refreshCard];
                        }];
}

- (SPKFakeLocationPlace *)spk_currentPlace {
    CLLocationCoordinate2D centre = self.mapView.centerCoordinate;
    SPKFakeLocationPlace *probe = [SPKFakeLocationPlace placeWithName:@"" address:nil coordinate:centre];
    NSString *name = self.resolvedName.length ? self.resolvedName : [probe displaySubtitle];
    return [SPKFakeLocationPlace placeWithName:name address:self.resolvedAddress coordinate:centre];
}

- (void)spk_refreshCard {
    SPKFakeLocationPlace *place = [self spk_currentPlace];
    BOOL resolved = self.resolvedName.length > 0;
    self.nameLabel.text = resolved ? place.name : SPKL(@"MESSAGES_FAKE_LOCATION_PICKER_RESOLVING");
    // The coordinate stays visible even once an address is found: two nearby taps
    // can resolve to the same street, and the numbers are what tell them apart.
    SPKFakeLocationPlace *coordinateOnly = [SPKFakeLocationPlace placeWithName:@"" address:nil coordinate:place.coordinate];
    NSString *coordinateText = [coordinateOnly displaySubtitle];
    self.addressLabel.text = place.address.length
                                 ? [NSString stringWithFormat:@"%@\n%@", place.address, coordinateText]
                                 : coordinateText;
}

#pragma mark Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) {
        [self.completer cancel];
        self.resultsController.results = @[];
        return;
    }
    self.completer.region = self.mapView.region;
    self.completer.queryFragment = query;
}

- (void)completerDidUpdateResults:(MKLocalSearchCompleter *)completer {
    self.resultsController.results = completer.results;
}

- (void)completer:(MKLocalSearchCompleter *)completer didFailWithError:(NSError *)error {
    SPKLog(@"FakeLocation", @"[Sparkle] Place search failed: %@", error.localizedDescription);
}

- (void)spk_selectCompletion:(MKLocalSearchCompletion *)completion {
    [self.activeSearch cancel];
    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] initWithCompletion:completion];
    MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:request];
    self.activeSearch = search;
    __weak typeof(self) weakSelf = self;
    [search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        MKMapItem *item = response.mapItems.firstObject;
        if (!strongSelf || !item)
            return;
        strongSelf.searchController.active = NO;
        strongSelf.resolvedName = item.name ?: completion.title;
        strongSelf.resolvedAddress = SPKFakeLocationPlacemarkAddress(item.placemark);
        strongSelf.keepsResolvedName = YES;
        [strongSelf spk_setCentre:item.placemark.coordinate animated:YES];
        [strongSelf spk_refreshCard];
    }];
}

#pragma mark Actions

- (void)spk_cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)spk_confirm {
    SPKFakeLocationPlace *place = [self spk_currentPlace];
    void (^completion)(SPKFakeLocationPlace *) = self.completion;
    // The completion runs once the sheet is gone: callers often present a naming
    // prompt next, and UIKit refuses to present over a controller mid-dismissal.
    [self dismissViewControllerAnimated:YES
                             completion:^{
                                 if (completion)
                                     completion(place);
                             }];
}

@end
