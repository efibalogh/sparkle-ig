#import "SPKStrings.h"
#import "SPKGalleryLockViewController.h"
#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "SPKGalleryManager.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import "../UI/SPKNotificationCenter.h"

static NSInteger const kPasscodeLength = 4;

@interface SPKGalleryLockViewController ()

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIStackView *dotsStackView;
@property (nonatomic, strong) NSMutableArray<UIView *> *dotViews;
@property (nonatomic, strong) UIStackView *keypadStackView;
@property (nonatomic, strong) UIButton *biometricButton;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UISelectionFeedbackGenerator *keyPressFeedbackGenerator;

@property (nonatomic, strong) NSMutableString *enteredPasscode;
@property (nonatomic, copy, nullable) NSString *firstPasscode; // for set/change confirm

/// For change mode: once we've verified the old passcode, we switch to "set new" sub-state.
@property (nonatomic, assign) BOOL hasVerifiedOldPasscode;
@property (nonatomic, strong) SPKGalleryManager *lockManager;

@end

@implementation SPKGalleryLockViewController

#pragma mark - Presentation

+ (void)presentUnlockFromViewController:(UIViewController *)presenter
                             completion:(void (^)(BOOL))completion {
    [self presentUnlockForManager:[SPKGalleryManager sharedManager]
               fromViewController:presenter
                       completion:completion];
}

+ (void)presentUnlockForManager:(SPKGalleryManager *)mgr
             fromViewController:(UIViewController *)presenter
                     completion:(void (^)(BOOL))completion {
    if ([mgr isBiometricsAvailable]) {
        [mgr authenticateWithBiometricsWithCompletion:^(BOOL success, NSError *err) {
            if (success) {
                if (completion)
                    completion(YES);
                return;
            }

            // A deliberate cancel should abort the unlock entirely rather than
            // dropping the user into the passcode keypad. Only genuine auth
            // failures (or an explicit fallback request) open the keypad.
            switch (err.code) {
            case LAErrorUserCancel:
            case LAErrorSystemCancel:
            case LAErrorAppCancel:
                if (completion)
                    completion(NO);
                return;
            default:
                [self presentMode:SPKGalleryLockModeUnlock forManager:mgr fromViewController:presenter completion:completion];
                return;
            }
        }];
    } else {
        [self presentMode:SPKGalleryLockModeUnlock forManager:mgr fromViewController:presenter completion:completion];
    }
}

+ (void)presentMode:(SPKGalleryLockMode)mode
    fromViewController:(UIViewController *)presenter
            completion:(void (^)(BOOL))completion {
    [self presentMode:mode forManager:[SPKGalleryManager sharedManager] fromViewController:presenter completion:completion];
}

+ (void)presentMode:(SPKGalleryLockMode)mode
            forManager:(SPKGalleryManager *)manager
    fromViewController:(UIViewController *)presenter
            completion:(void (^)(BOOL))completion {
    SPKGalleryLockViewController *vc = [[SPKGalleryLockViewController alloc] init];
    vc.mode = mode;
    vc.lockManager = manager;
    vc.completion = completion;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [presenter presentViewController:vc animated:YES completion:nil];
}

#pragma mark - Lifecycle

- (instancetype)init {
    if ((self = [super init])) {
        _enteredPasscode = [NSMutableString new];
        _dotViews = [NSMutableArray new];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    [self setupUI];
    [self updateUIForMode];
}

#pragma mark - Setup

- (void)setupUI {
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.font = [UIFont systemFontOfSize:14];
    self.subtitleLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.subtitleLabel];

    self.dotsStackView = [[UIStackView alloc] init];
    self.dotsStackView.axis = UILayoutConstraintAxisHorizontal;
    self.dotsStackView.spacing = 16;
    self.dotsStackView.alignment = UIStackViewAlignmentCenter;
    self.dotsStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.dotsStackView];

    for (NSInteger i = 0; i < kPasscodeLength; i++) {
        UIView *dot = [[UIView alloc] init];
        dot.layer.cornerRadius = 6;
        dot.layer.borderWidth = 1.5;
        dot.layer.borderColor = [SPKUtils SPKColor_InstagramPrimaryText].CGColor;
        dot.backgroundColor = [UIColor clearColor];
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [dot.widthAnchor constraintEqualToConstant:12],
            [dot.heightAnchor constraintEqualToConstant:12],
        ]];
        [self.dotsStackView addArrangedSubview:dot];
        [self.dotViews addObject:dot];
    }

    [self setupKeypad];
    self.keyPressFeedbackGenerator = [[UISelectionFeedbackGenerator alloc] init];
    [self.keyPressFeedbackGenerator prepare];

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.cancelButton setTitle:SPKL(@"ALERT_ACTION_CANCEL") forState:UIControlStateNormal];
    [self.cancelButton setTitleColor:[SPKUtils SPKColor_InstagramPrimaryText] forState:UIControlStateNormal];
    self.cancelButton.titleLabel.font = [UIFont systemFontOfSize:17];
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.cancelButton];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.titleLabel.topAnchor constraintEqualToAnchor:safe.topAnchor
                                                  constant:50],

        [self.subtitleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor
                                                     constant:8],

        [self.dotsStackView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.dotsStackView.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor
                                                     constant:32],

        [self.keypadStackView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.keypadStackView.topAnchor constraintEqualToAnchor:self.dotsStackView.bottomAnchor
                                                       constant:48],

        [self.cancelButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.cancelButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                                       constant:-20],
    ]];
}

- (void)setupKeypad {
    self.keypadStackView = [[UIStackView alloc] init];
    self.keypadStackView.axis = UILayoutConstraintAxisVertical;
    self.keypadStackView.spacing = 16;
    self.keypadStackView.alignment = UIStackViewAlignmentCenter;
    self.keypadStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.keypadStackView];

    NSArray<NSArray<NSNumber *> *> *layout = @[
        @[ @1, @2, @3 ],
        @[ @4, @5, @6 ],
        @[ @7, @8, @9 ],
        @[ @(-3), @0, @(-2) ], // -3 = biometric, -2 = delete
    ];

    for (NSArray<NSNumber *> *row in layout) {
        UIStackView *rowStack = [[UIStackView alloc] init];
        rowStack.axis = UILayoutConstraintAxisHorizontal;
        rowStack.spacing = 20;
        rowStack.alignment = UIStackViewAlignmentCenter;
        rowStack.distribution = UIStackViewDistributionFillEqually;

        for (NSNumber *num in row) {
            NSInteger n = num.integerValue;
            if (n == -1) {
                UIView *spacer = [[UIView alloc] init];
                [NSLayoutConstraint activateConstraints:@[
                    [spacer.widthAnchor constraintEqualToConstant:75],
                    [spacer.heightAnchor constraintEqualToConstant:75],
                ]];
                [rowStack addArrangedSubview:spacer];
            } else if (n == -3) {
                // Biometric unlock, mirroring the backspace button's position.
                // Always present so the keypad stays symmetric; visibility is
                // toggled per-mode in -updateUIForMode.
                UIButton *bio = [self createKeypadButton:nil tag:-3];
                bio.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
                [bio addTarget:self action:@selector(triggerBiometrics) forControlEvents:UIControlEventTouchUpInside];
                [bio addTarget:self action:@selector(keyTouchDown:) forControlEvents:UIControlEventTouchDown];
                [bio addTarget:self action:@selector(keyTouchUp:) forControlEvents:UIControlEventTouchUpInside];
                [bio addTarget:self action:@selector(keyTouchUp:) forControlEvents:UIControlEventTouchUpOutside];
                [bio addTarget:self action:@selector(keyTouchUp:) forControlEvents:UIControlEventTouchCancel];
                [bio addTarget:self action:@selector(keyTouchUp:) forControlEvents:UIControlEventTouchDragExit];
                self.biometricButton = bio;
                [rowStack addArrangedSubview:bio];
            } else if (n == -2) {
                UIButton *del = [self createKeypadButton:nil tag:-2];
                UIImage *deleteIcon = [SPKAssetUtils instagramIconNamed:@"backspace" pointSize:24.0];
                [del setImage:deleteIcon forState:UIControlStateNormal];
                [del setTitle:@"" forState:UIControlStateNormal];
                del.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
                [del addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
                [del addTarget:self action:@selector(keyTouchDown:) forControlEvents:UIControlEventTouchDown];
                [del addTarget:self action:@selector(keyTouchUp:) forControlEvents:UIControlEventTouchUpInside];
                [del addTarget:self action:@selector(keyTouchUp:) forControlEvents:UIControlEventTouchUpOutside];
                [del addTarget:self action:@selector(keyTouchUp:) forControlEvents:UIControlEventTouchCancel];
                [del addTarget:self action:@selector(keyTouchUp:) forControlEvents:UIControlEventTouchDragExit];
                [rowStack addArrangedSubview:del];
            } else {
                UIButton *btn = [self createKeypadButton:[NSString stringWithFormat:@"%ld", (long)n] tag:n];
                [btn addTarget:self action:@selector(numberTapped:) forControlEvents:UIControlEventTouchUpInside];
                [btn addTarget:self action:@selector(keyTouchDown:) forControlEvents:UIControlEventTouchDown];
                [btn addTarget:self action:@selector(keyTouchUp:) forControlEvents:UIControlEventTouchUpInside];
                [btn addTarget:self action:@selector(keyTouchUp:) forControlEvents:UIControlEventTouchUpOutside];
                [btn addTarget:self action:@selector(keyTouchUp:) forControlEvents:UIControlEventTouchCancel];
                [btn addTarget:self action:@selector(keyTouchUp:) forControlEvents:UIControlEventTouchDragExit];
                [rowStack addArrangedSubview:btn];
            }
        }

        [self.keypadStackView addArrangedSubview:rowStack];
    }
}

- (UIButton *)createKeypadButton:(NSString *)title tag:(NSInteger)tag {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.tag = tag;
    BOOL isIconButton = (tag == -2 || tag == -3);
    btn.layer.cornerRadius = isIconButton ? 0.0 : 37.5;
    btn.backgroundColor = isIconButton ? [UIColor clearColor] : [SPKUtils SPKColor_InstagramSecondaryBackground];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [btn.widthAnchor constraintEqualToConstant:75],
        [btn.heightAnchor constraintEqualToConstant:75],
    ]];

    if (title) {
        UILabel *digitLabel = [[UILabel alloc] init];
        digitLabel.text = title;
        digitLabel.font = [UIFont systemFontOfSize:32 weight:UIFontWeightLight];
        digitLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
        digitLabel.textAlignment = NSTextAlignmentCenter;
        digitLabel.translatesAutoresizingMaskIntoConstraints = NO;
        digitLabel.userInteractionEnabled = NO;
        [btn addSubview:digitLabel];

        [NSLayoutConstraint activateConstraints:@[
            [digitLabel.centerXAnchor constraintEqualToAnchor:btn.centerXAnchor],
            [digitLabel.centerYAnchor constraintEqualToAnchor:btn.centerYAnchor],
        ]];
    }

    return btn;
}

#pragma mark - Mode / UI updates

- (void)updateUIForMode {
    NSString *protectedName = self.lockManager.protectedContentName;
    switch (self.mode) {
    case SPKGalleryLockModeUnlock:
        self.titleLabel.text = SPKL(@"GALLERY_GALLERY_LOCK_ENTER_PASSCODE_TEXT");
        self.subtitleLabel.text = [NSString stringWithFormat:SPKL(@"GALLERY_GALLERY_LOCK_ENTER_PASSCODE_UNLOCK_VALUE_FORMAT"), protectedName];
        break;

    case SPKGalleryLockModeSetPasscode:
        self.titleLabel.text = self.firstPasscode ? SPKL(@"GALLERY_GALLERY_LOCK_CONFIRM_PASSCODE_TEXT") : SPKL(@"GALLERY_GALLERY_LOCK_NEW_PASSCODE_TEXT");
        self.subtitleLabel.text = self.firstPasscode
                                      ? SPKL(@"GALLERY_GALLERY_LOCK_RE_ENTER_NEW_PASSCODE_TEXT")
                                      : [NSString stringWithFormat:SPKL(@"GALLERY_GALLERY_LOCK_CREATE_PASSCODE_PROTECT_VALUE_FORMAT"), protectedName];
        break;

    case SPKGalleryLockModeChangePasscode:
        if (!self.hasVerifiedOldPasscode) {
            self.titleLabel.text = SPKL(@"GALLERY_GALLERY_LOCK_ENTER_CURRENT_PASSCODE_TEXT");
            self.subtitleLabel.text = [NSString stringWithFormat:SPKL(@"GALLERY_GALLERY_LOCK_ENTER_CURRENT_VALUE_PASSCODE_FORMAT"), protectedName];
        } else {
            self.titleLabel.text = self.firstPasscode ? SPKL(@"GALLERY_GALLERY_LOCK_CONFIRM_PASSCODE_TEXT") : SPKL(@"GALLERY_GALLERY_LOCK_NEW_PASSCODE_TEXT");
            self.subtitleLabel.text = self.firstPasscode
                                          ? SPKL(@"GALLERY_GALLERY_LOCK_RE_ENTER_NEW_PASSCODE_TEXT")
                                          : SPKL(@"GALLERY_GALLERY_LOCK_CREATE_NEW_PASSCODE_TEXT");
        }
        break;
    }

    // Biometrics button only active during unlock, when available. We keep the
    // slot occupied (alpha 0 rather than hidden) so the keypad stays symmetric.
    SPKGalleryManager *mgr = self.lockManager;
    BOOL showBiometrics = (self.mode == SPKGalleryLockModeUnlock) && [mgr isBiometricsAvailable];
    self.biometricButton.alpha = showBiometrics ? 1.0 : 0.0;
    self.biometricButton.userInteractionEnabled = showBiometrics;
    if (showBiometrics) {
        NSString *icon = [mgr biometryType] == SPKGalleryBiometryTypeFaceID ? @"faceid" : @"touchid";
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightRegular];
        [self.biometricButton setImage:[UIImage systemImageNamed:icon withConfiguration:cfg] forState:UIControlStateNormal];
        self.biometricButton.tintColor = [SPKUtils SPKColor_InstagramPrimaryText];
    } else {
        [self.biometricButton setImage:nil forState:UIControlStateNormal];
    }

    [self updateDots];
}

- (void)updateDots {
    for (NSInteger i = 0; i < self.dotViews.count; i++) {
        UIView *dot = self.dotViews[i];
        BOOL filled = i < (NSInteger)self.enteredPasscode.length;
        dot.backgroundColor = filled ? [SPKUtils SPKColor_InstagramPrimaryText] : [UIColor clearColor];
    }
}

- (void)shakeDots {
    CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    shake.duration = 0.4;
    shake.values = @[ @(-12), @(12), @(-10), @(10), @(-6), @(6), @(-2), @(2), @(0) ];
    [self.dotsStackView.layer addAnimation:shake forKey:@"shake"];

    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    [gen impactOccurred];
}

#pragma mark - Keypad actions

- (void)keyTouchDown:(UIButton *)sender {
    [UIView animateWithDuration:0.08
                     animations:^{
                         sender.transform = CGAffineTransformMakeScale(0.93, 0.93);
                         sender.alpha = 0.72;
                     }];
}

- (void)keyTouchUp:(UIButton *)sender {
    [UIView animateWithDuration:0.12
                          delay:0.0
         usingSpringWithDamping:0.72
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         sender.transform = CGAffineTransformIdentity;
                         sender.alpha = 1.0;
                     }
                     completion:nil];
}

- (void)numberTapped:(UIButton *)sender {
    if (self.enteredPasscode.length >= kPasscodeLength)
        return;
    [self.keyPressFeedbackGenerator selectionChanged];
    [self.keyPressFeedbackGenerator prepare];
    [self.enteredPasscode appendFormat:@"%ld", (long)sender.tag];
    [self updateDots];

    if (self.enteredPasscode.length == kPasscodeLength) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [self handlePasscodeComplete];
                       });
    }
}

- (void)deleteTapped {
    if (self.enteredPasscode.length == 0)
        return;
    [self.keyPressFeedbackGenerator selectionChanged];
    [self.keyPressFeedbackGenerator prepare];
    [self.enteredPasscode deleteCharactersInRange:NSMakeRange(self.enteredPasscode.length - 1, 1)];
    [self updateDots];
}

- (void)cancelTapped {
    [self.lockManager cancelBiometricAuthentication];
    [self dismissViewControllerAnimated:YES
                             completion:^{
                                 if (self.completion)
                                     self.completion(NO);
                             }];
}

- (void)triggerBiometrics {
    __weak typeof(self) weakSelf = self;
    [self.lockManager authenticateWithBiometricsWithCompletion:^(BOOL success, NSError *err) {
        if (!success)
            return;
        [weakSelf.presentingViewController dismissViewControllerAnimated:YES
                                                              completion:^{
                                                                  if (weakSelf.completion)
                                                                      weakSelf.completion(YES);
                                                              }];
    }];
}

#pragma mark - Passcode handling

- (void)handlePasscodeComplete {
    SPKGalleryManager *mgr = self.lockManager;
    NSString *entered = [self.enteredPasscode copy];

    switch (self.mode) {
    case SPKGalleryLockModeUnlock: {
        if ([mgr verifyPasscode:entered]) {
            [mgr cancelBiometricAuthentication];
            [self.presentingViewController dismissViewControllerAnimated:YES
                                                              completion:^{
                                                                  if (self.completion)
                                                                      self.completion(YES);
                                                              }];
        } else {
            [self shakeDots];
            [self.enteredPasscode setString:@""];
            [self updateDots];
        }
        break;
    }

    case SPKGalleryLockModeSetPasscode: {
        if (!self.firstPasscode) {
            self.firstPasscode = entered;
            [self.enteredPasscode setString:@""];
            [self updateUIForMode];
        } else if ([self.firstPasscode isEqualToString:entered]) {
            if ([mgr setPasscode:entered]) {
                [self.presentingViewController dismissViewControllerAnimated:YES
                                                                  completion:^{
                                                                      if (self.completion)
                                                                          self.completion(YES);
                                                                  }];
            } else {
                [self shakeDots];
                [self resetSetFlow];
            }
        } else {
            [self shakeDots];
            [self resetSetFlow];
        }
        break;
    }

    case SPKGalleryLockModeChangePasscode: {
        if (!self.hasVerifiedOldPasscode) {
            if ([mgr verifyPasscode:entered]) {
                self.hasVerifiedOldPasscode = YES;
                [self.enteredPasscode setString:@""];
                [self updateUIForMode];
            } else {
                [self shakeDots];
                [self.enteredPasscode setString:@""];
                [self updateDots];
            }
        } else if (!self.firstPasscode) {
            self.firstPasscode = entered;
            [self.enteredPasscode setString:@""];
            [self updateUIForMode];
        } else if ([self.firstPasscode isEqualToString:entered]) {
            if ([mgr setPasscode:entered]) {
                [self.presentingViewController dismissViewControllerAnimated:YES
                                                                  completion:^{
                                                                      // The sheet closing looks the same as a cancel, so say it worked.
                                                                      SPKNotify(kSPKNotificationPasscodeChanged, SPKL(@"GALLERY_GALLERY_LOCK_PASSCODE_CHANGED_TOAST"), nil, @"key", SPKNotificationToneSuccess);
                                                                      if (self.completion)
                                                                          self.completion(YES);
                                                                  }];
            } else {
                [self shakeDots];
                [self resetSetFlow];
            }
        } else {
            [self shakeDots];
            [self resetSetFlow];
        }
        break;
    }
    }
}

- (void)resetSetFlow {
    self.firstPasscode = nil;
    [self.enteredPasscode setString:@""];
    [self updateUIForMode];
}

@end
