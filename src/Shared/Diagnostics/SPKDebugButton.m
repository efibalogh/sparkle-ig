#import "SPKDiagnostics.h"

#import "../../App/SPKFlexLoader.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../i18n/SPKStrings.h"
#import "../UI/SPKChipGlass.h"

// Floating debug button, shown from Tools > Diagnostics. It lives in its own
// window so it stays above stories, sheets and full-screen viewers without
// touching Instagram's view tree, and every report leaves its windows out.

static NSString *const kSPKDebugButtonPositionKey = @"tools_debug_button_position";
static const CGFloat kSPKDebugButtonSize = 48.0;
static const CGFloat kSPKDebugButtonMargin = 10.0;

// Off at every launch: a report with on-screen text is an explicit choice.
static BOOL sSPKDebugIncludeText = NO;

@interface SPKDebugOverlayWindow : UIWindow
@end

@implementation SPKDebugOverlayWindow
- (BOOL)canBecomeKeyWindow {
    return NO;
}

// Private UIWindow override: leaves the status bar style and visibility to
// Instagram's windows even though this one covers the screen.
- (BOOL)_canAffectStatusBarAppearance {
    return NO;
}
@end

// Set while the button's menu is on screen.
static BOOL sSPKDebugMenuVisible = NO;

// Full screen so the button's menu has room to present: UIKit presents it in
// the button's own window, and a button-sized window clipped it to a blob.
// Touches that miss the button fall through to Instagram, except while the
// menu is open: the tap outside it that dismisses it must land here.
@interface SPKDebugPassthroughWindow : SPKDebugOverlayWindow
@end

@implementation SPKDebugPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (sSPKDebugMenuVisible)
        return hit;
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

@interface SPKDebugMenuButton : UIButton
// Blur backing used where Liquid Glass is unavailable or off.
@property (nonatomic, strong, nullable) UIView *materialView;
@end

@implementation SPKDebugMenuButton
// UIButton creates its image view lazily, after the backing was inserted, and
// can place it underneath; keep the backing at the bottom on every pass.
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.materialView)
        [self sendSubviewToBack:self.materialView];
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration
                           animator:(id<UIContextMenuInteractionAnimating>)animator {
    [super contextMenuInteraction:interaction willDisplayMenuForConfiguration:configuration animator:animator];
    sSPKDebugMenuVisible = YES;
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
       willEndForConfiguration:(UIContextMenuConfiguration *)configuration
                      animator:(id<UIContextMenuInteractionAnimating>)animator {
    [super contextMenuInteraction:interaction willEndForConfiguration:configuration animator:animator];
    sSPKDebugMenuVisible = NO;
}
@end

static SPKDebugPassthroughWindow *sSPKDebugButtonWindow;
static SPKDebugOverlayWindow *sSPKDebugInspectWindow;

BOOL SPKDebugButtonOwnsWindow(UIWindow *window) {
    return window && (window == sSPKDebugButtonWindow || window == sSPKDebugInspectWindow);
}

// MARK: - Sharing

// Hands Copy the report text itself and every other activity a .txt file, so
// it can be pasted into a chat as well as saved or attached.
@interface SPKDebugReportItem : NSObject <UIActivityItemSource>
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSURL *fileURL;
@end

@implementation SPKDebugReportItem
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)controller {
    return self.fileURL;
}

- (id)activityViewController:(UIActivityViewController *)controller itemForActivityType:(UIActivityType)activityType {
    if ([activityType isEqualToString:UIActivityTypeCopyToPasteboard] || [activityType isEqualToString:UIActivityTypeMessage])
        return self.text;
    return self.fileURL;
}

- (NSString *)activityViewController:(UIActivityViewController *)controller subjectForActivityType:(UIActivityType)activityType {
    return self.fileURL.lastPathComponent;
}
@end

static void SPKDebugShareReport(NSString *name, NSString *report) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *fileName = [NSString stringWithFormat:@"Sparkle-%@-%@.txt", name, [formatter stringFromDate:NSDate.date]];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
    NSError *error = nil;
    if (![report writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error])
        SPKLog(@"Diagnostics", @"Could not write report %@: %@", fileName, error);

    SPKDebugReportItem *item = [SPKDebugReportItem new];
    item.text = report;
    item.fileURL = url;
    [SPKUtils showShareVC:item];
}

// MARK: - Inspect mode

@interface SPKDebugInspectController : UIViewController
@end

@implementation SPKDebugInspectController {
    UIView *_highlight;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];

    UILabel *hint = [UILabel new];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.text = SPKL(@"TOOLS_DEBUG_BUTTON_INSPECT_HINT");
    hint.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    hint.textColor = UIColor.labelColor;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.numberOfLines = 0;

    UIVisualEffectView *pill = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.layer.cornerRadius = 20;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.clipsToBounds = YES;
    [pill.contentView addSubview:hint];
    [self.view addSubview:pill];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    [cancel setTitle:SPKL(@"ALERT_ACTION_CANCEL") forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    cancel.tintColor = UIColor.labelColor;
    cancel.backgroundColor = UIColor.secondarySystemBackgroundColor;
    cancel.layer.cornerRadius = 22;
    cancel.layer.cornerCurve = kCACornerCurveContinuous;
    cancel.contentEdgeInsets = UIEdgeInsetsMake(0, 28, 0, 28);
    [cancel addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [pill.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [pill.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [pill.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16],
        [hint.topAnchor constraintEqualToAnchor:pill.contentView.topAnchor constant:10],
        [hint.bottomAnchor constraintEqualToAnchor:pill.contentView.bottomAnchor constant:-10],
        [hint.leadingAnchor constraintEqualToAnchor:pill.contentView.leadingAnchor constant:18],
        [hint.trailingAnchor constraintEqualToAnchor:pill.contentView.trailingAnchor constant:-18],
        [cancel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [cancel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [cancel.heightAnchor constraintEqualToConstant:44],
    ]];

    [self.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pick:)]];
}

- (void)cancel {
    sSPKDebugInspectWindow.hidden = YES;
    sSPKDebugInspectWindow = nil;
}

- (void)pick:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized || _highlight)
        return;
    UIWindow *window = self.view.window;
    CGPoint point = [window convertPoint:[recognizer locationInView:window] toCoordinateSpace:window.windowScene.coordinateSpace];
    UIView *selected = nil;
    NSString *report = SPKDiagnosticsInspectReport(point, sSPKDebugIncludeText, &selected);
    [[UIImpactFeedbackGenerator new] impactOccurred];

    // Outline the picked view briefly so it is clear what the report is about.
    self.view.backgroundColor = UIColor.clearColor;
    for (UIView *subview in self.view.subviews)
        subview.hidden = YES;
    if (selected) {
        CGRect frame = [selected convertRect:selected.bounds toCoordinateSpace:window.windowScene.coordinateSpace];
        _highlight = [[UIView alloc] initWithFrame:[window convertRect:frame fromCoordinateSpace:window.windowScene.coordinateSpace]];
        _highlight.layer.borderColor = UIColor.systemPinkColor.CGColor;
        _highlight.layer.borderWidth = 2;
        _highlight.backgroundColor = [UIColor.systemPinkColor colorWithAlphaComponent:0.15];
        [self.view addSubview:_highlight];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self cancel];
        SPKDebugShareReport(@"Inspect", report);
    });
}
@end

static void SPKDebugBeginInspect(void) {
    UIWindowScene *scene = sSPKDebugButtonWindow.windowScene;
    if (!scene || sSPKDebugInspectWindow)
        return;
    SPKDebugOverlayWindow *window = [[SPKDebugOverlayWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.windowLevel = sSPKDebugButtonWindow.windowLevel - 1;
    window.backgroundColor = UIColor.clearColor;
    window.rootViewController = [SPKDebugInspectController new];
    window.hidden = NO;
    sSPKDebugInspectWindow = window;
}

// MARK: - Menu

static UIAction *SPKDebugReportAction(NSString *title, NSString *icon, NSString *name, NSString * (^build)(BOOL includeText)) {
    return [UIAction actionWithTitle:title
                               image:[SPKAssetUtils menuIconNamed:icon]
                          identifier:nil
                             handler:^(__unused UIAction *action) {
                                 SPKDebugShareReport(name, build(sSPKDebugIncludeText));
                             }];
}

static NSArray<UIMenuElement *> *SPKDebugMenuElements(void) {
    NSMutableArray<UIMenuElement *> *reports = [NSMutableArray array];
    [reports addObject:[UIAction actionWithTitle:SPKL(@"TOOLS_DEBUG_BUTTON_MENU_INSPECT")
                                           image:[SPKAssetUtils menuIconNamed:@"search"]
                                      identifier:nil
                                         handler:^(__unused UIAction *action) {
                                             SPKDebugBeginInspect();
                                         }]];
    [reports addObject:SPKDebugReportAction(SPKL(@"TOOLS_DEBUG_BUTTON_MENU_SCREEN_REPORT"), @"interface", @"Screen", ^NSString *(BOOL includeText) {
                 return SPKDiagnosticsScreenReport(includeText);
             })];
    [reports addObject:SPKDebugReportAction(SPKL(@"TOOLS_DEBUG_BUTTON_MENU_VIEW_HIERARCHY"), @"duplicate", @"Hierarchy", ^NSString *(BOOL includeText) {
                 return SPKDiagnosticsHierarchyReport(includeText);
             })];
#if SPK_DEV
    // Captured after a delay so the keyboard, a sheet or a menu can be brought
    // up first: opening this menu dismisses whatever was presented.
    [reports addObject:[UIAction actionWithTitle:SPKL(@"TOOLS_DEBUG_BUTTON_MENU_COLOR_REPORT")
                                           image:[SPKAssetUtils menuIconNamed:@"palette"]
                                      identifier:nil
                                         handler:^(__unused UIAction *action) {
                                             dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                 [[UIImpactFeedbackGenerator new] impactOccurred];
                                                 SPKDebugShareReport(@"Colors", SPKDiagnosticsColorReport());
                                             });
                                         }]];
#endif

    UIAction *includeText = [UIAction actionWithTitle:SPKL(@"TOOLS_DEBUG_BUTTON_MENU_INCLUDE_TEXT")
                                                image:[SPKAssetUtils menuIconNamed:@"text"]
                                           identifier:nil
                                              handler:^(__unused UIAction *action) {
                                                  sSPKDebugIncludeText = !sSPKDebugIncludeText;
                                              }];
    includeText.state = sSPKDebugIncludeText ? UIMenuElementStateOn : UIMenuElementStateOff;

    NSMutableArray<UIMenuElement *> *tools = [NSMutableArray arrayWithObject:includeText];
    if (SPKFlexIsBundled() || SPKFlexIsLoaded()) {
        [tools addObject:[UIAction actionWithTitle:SPKL(@"TOOLS_DEBUG_BUTTON_MENU_OPEN_FLEX")
                                             image:[SPKAssetUtils menuIconNamed:@"beaker"]
                                        identifier:nil
                                           handler:^(__unused UIAction *action) {
                                               SPKFlexShowExplorer(@"debug_button");
                                           }]];
    }
    UIAction *hide = [UIAction actionWithTitle:SPKL(@"TOOLS_DEBUG_BUTTON_MENU_HIDE")
                                         image:[SPKAssetUtils menuIconNamed:@"eye_off"]
                                    identifier:nil
                                       handler:^(__unused UIAction *action) {
                                           SPKPreferenceSetObject(@NO, kSPKPrefToolsDebugButton);
                                           SPKDebugButtonRefresh();
                                       }];
    hide.attributes = UIMenuElementAttributesDestructive;
    [tools addObject:hide];

    NSMutableArray<UIMenuElement *> *elements = [NSMutableArray array];
    [elements addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:reports]];
    [elements addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:tools]];
    return elements;
}

// MARK: - Button

@interface SPKDebugButtonController : UIViewController
@end

@implementation SPKDebugButtonController {
    UIButton *_button;
    CGPoint _dragStartTouch;
    CGPoint _dragStartOrigin;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    SPKDebugMenuButton *button = [SPKDebugMenuButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, kSPKDebugButtonSize, kSPKDebugButtonSize);
    button.tintColor = UIColor.labelColor;
    button.accessibilityLabel = SPKL(@"TOOLS_DEBUG_BUTTON_ACCESSIBILITY_LABEL");
    [button setImage:[SPKAssetUtils menuIconNamed:@"beaker" pointSize:22] forState:UIControlStateNormal];
    if (!SPKChipApplyGlass(button, NO, kSPKDebugButtonSize / 2.0, nil)) {
        UIVisualEffectView *material = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        material.frame = button.bounds;
        material.userInteractionEnabled = NO;
        material.layer.cornerRadius = kSPKDebugButtonSize / 2.0;
        material.clipsToBounds = YES;
        [button insertSubview:material atIndex:0];
        button.materialView = material;
        button.layer.shadowColor = UIColor.blackColor.CGColor;
        button.layer.shadowOpacity = 0.18;
        button.layer.shadowRadius = 8;
        button.layer.shadowOffset = CGSizeMake(0, 2);
    }
    // Rebuilt on every open so the Include Text state and FLEX availability are current.
    button.menu = [UIMenu menuWithTitle:SPKL(@"TOOLS_DEBUG_BUTTON_TITLE")
                               children:@[ [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
                                   completion(SPKDebugMenuElements());
                               }] ]];
    button.showsMenuAsPrimaryAction = YES;
    // Keep the order as written; by default iOS reverses a menu that opens upward.
    if (@available(iOS 16.0, *))
        button.preferredMenuElementOrder = UIContextMenuConfigurationElementOrderFixed;
    [button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    [self.view addSubview:button];
    _button = button;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Placed once the window has its size, from the saved {side, vertical
    // center fraction}; defaults to the right edge, a little below the middle.
    if (_button.tag)
        return;
    _button.tag = 1;
    CGRect bounds = self.view.bounds;
    NSArray *position = SPKPreferenceObjectForKey(kSPKDebugButtonPositionKey);
    BOOL left = NO;
    CGFloat fraction = 0.62;
    if ([position isKindOfClass:NSArray.class] && position.count == 2) {
        left = [position[0] integerValue] == 0;
        fraction = MIN(MAX([position[1] doubleValue], 0.1), 0.9);
    }
    CGFloat x = left ? kSPKDebugButtonMargin : CGRectGetWidth(bounds) - kSPKDebugButtonSize - kSPKDebugButtonMargin;
    _button.frame = CGRectMake(x, CGRectGetHeight(bounds) * fraction - kSPKDebugButtonSize / 2.0, kSPKDebugButtonSize, kSPKDebugButtonSize);
}

- (void)drag:(UIPanGestureRecognizer *)pan {
    CGPoint touch = [pan locationInView:self.view];
    if (pan.state == UIGestureRecognizerStateBegan) {
        _dragStartTouch = touch;
        _dragStartOrigin = _button.frame.origin;
        return;
    }
    CGRect frame = _button.frame;
    frame.origin = CGPointMake(_dragStartOrigin.x + touch.x - _dragStartTouch.x, _dragStartOrigin.y + touch.y - _dragStartTouch.y);
    if (pan.state == UIGestureRecognizerStateChanged) {
        _button.frame = frame;
        return;
    }
    // Rest against the nearer side, clear of the status bar and home indicator.
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    BOOL left = CGRectGetMidX(frame) < CGRectGetMidX(bounds);
    frame.origin.x = left ? kSPKDebugButtonMargin : CGRectGetWidth(bounds) - kSPKDebugButtonSize - kSPKDebugButtonMargin;
    frame.origin.y = MIN(MAX(frame.origin.y, safe.top + kSPKDebugButtonMargin),
                         CGRectGetHeight(bounds) - safe.bottom - kSPKDebugButtonSize - kSPKDebugButtonMargin);
    UIButton *button = _button;
    [UIView animateWithDuration:0.35
                          delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         button.frame = frame;
                     }
                     completion:nil];
    SPKPreferenceSetObject(@[ @(left ? 0 : 1), @(CGRectGetMidY(frame) / MAX(CGRectGetHeight(bounds), 1)) ], kSPKDebugButtonPositionKey);
}
@end

static UIWindowScene *SPKDebugActiveScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)scene;
    }
    return nil;
}

static void SPKDebugButtonShow(UIWindowScene *scene) {
    SPKDebugPassthroughWindow *window = [[SPKDebugPassthroughWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.windowLevel = UIWindowLevelAlert + 150.0;
    window.backgroundColor = UIColor.clearColor;
    window.rootViewController = [SPKDebugButtonController new];
    window.hidden = NO;
    sSPKDebugButtonWindow = window;
}

void SPKDebugButtonRefresh(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPKDebugButtonRefresh();
        });
        return;
    }
    // A scene that activates later, or a toggle flipped before one exists,
    // gets the button on its next activation.
    static dispatch_once_t observeOnce;
    dispatch_once(&observeOnce, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
                                                        SPKDebugButtonRefresh();
                                                    }];
    });

    BOOL wanted = [SPKUtils getBoolPref:kSPKPrefToolsDebugButton];
    if (!wanted) {
        sSPKDebugInspectWindow.hidden = YES;
        sSPKDebugInspectWindow = nil;
        sSPKDebugButtonWindow.hidden = YES;
        sSPKDebugButtonWindow = nil;
        sSPKDebugMenuVisible = NO;
        return;
    }
    if (sSPKDebugButtonWindow)
        return;
    UIWindowScene *scene = SPKDebugActiveScene();
    if (scene)
        SPKDebugButtonShow(scene);
}

void SPKInstallDebugButtonIfEnabled(void) {
    SPKDebugButtonRefresh();
}
