// Capture-aware chrome primitives. SPKChromeCanvas handles redaction via
// the UITextField secure-canvas technique; SPKChromeButton / SPKChromeLabel
// own the full visible hierarchy so IG's liquid glass can't wrap them.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted by the settings toggle so live instances can refresh `secureTextEntry`.
FOUNDATION_EXPORT NSNotificationName const SPKHideUIOnCapturePreferenceDidChangeNotification;

/// Opts a custom button/icon hierarchy into the runtime EDR compositing path when
/// the installed OS supports it. Uses runtime lookup because Sparkle builds with
/// the iOS 16.2 SDK, where this CALayer property is not declared on CALayer.
FOUNDATION_EXPORT void SPKChromeEnableExtendedDynamicRangeContent(UIView *view);

// MARK: - SPKChromeCanvas

@interface SPKChromeCanvas : UIView
@property (nonatomic, readonly) UIView *contentContainer;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// YES if `field` is the secure-canvas helper owned by SPKChromeCanvas.
/// Used by the Instants screenshot bypass to skip our own redaction fields.
BOOL SPKChromeCanvasOwnsSecureField(UITextField *field);

/// Marks a Sparkle-made redaction field so the Instants screenshot bypass, which
/// turns off every other secure field while an Instant is up, leaves it secure.
void SPKChromeMarkSecureFieldOwned(UITextField *field);

#ifdef __cplusplus
}
#endif

// MARK: - SPKChromeButton

@interface SPKChromeButton : UIButton
- (instancetype)initWithSymbol:(NSString *)symbol
                     pointSize:(CGFloat)pointSize
                      diameter:(CGFloat)diameter NS_DESIGNATED_INITIALIZER;

@property (nonatomic, assign, readonly) CGFloat diameter;
@property (nonatomic, assign) CGSize customSize;
@property (nonatomic, assign) UIOffset iconOffset;
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, assign) CGFloat symbolPointSize;
@property (nonatomic, copy) UIColor *iconTint;
@property (nonatomic, copy) UIColor *bubbleColor;
/// Optional blur behind the glyph, hosted *inside* the button's secure bubble so
/// it redacts on capture and morphs with the button (e.g. iOS 26 menu glass
/// animation). Set `bubbleColor` to clear when using this. Nil removes it.
@property (nonatomic, strong, nullable) UIVisualEffect *bubbleEffect;
/// `symbolName` is SF-only. For IG-styled glyphs use `setIconResource:` or
/// assign `iconView.image` directly with a baked image.
@property (nonatomic, strong, readonly) UIImageView *iconView;

/// Fired when the button's own context menu (long-press, `showsMenuAsPrimaryAction
/// = NO`) is about to display — a hook for haptics/side effects on menu open.
/// Nil (default) leaves standard behaviour untouched.
@property (nonatomic, copy, nullable) void (^menuWillDisplayHandler)(void);

/// IG-styled glyph via `+[SPKAssetUtils instagramIconNamed:]`. Clears `symbolName`.
- (void)setIconResource:(NSString *)resourceName pointSize:(CGFloat)pointSize;

/// Adds `view` inside the button's capture-redacted canvas, so accessories such
/// as a count badge disappear from screenshots and recordings along with the
/// glyph. A plain `addSubview:` lands outside the canvas and stays visible: the
/// generic tag-based capture interception deliberately skips this class because
/// the button owns its redaction.
///
/// Constrain the view against `chromeAnchorView`, never against its resulting
/// superview: the canvas re-parents its children once the secure canvas layer
/// materialises, and only constraints pinned to the stable ancestor survive.
- (void)addChromeSubview:(UIView *)view;

/// Stable ancestor to constrain views passed to `addChromeSubview:` against.
@property (nonatomic, strong, readonly) UIView *chromeAnchorView;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@end

// MARK: - SPKChromeLabel

/// A self-sizing, capture-redacted label with an optional leading glyph. Hosts
/// its content inside an SPKChromeCanvas so the text/icon disappear from
/// screenshots/recordings when "Hide UI on Capture" is on — no external tag or
/// `addSubview:` interception needed. Reports `intrinsicContentSize`, so pinning
/// just two edges (e.g. leading + bottom to a container) both places and sizes
/// it. Content is fixed at init; build a new instance to change it.
@interface SPKChromeLabel : UIView
- (instancetype)initWithText:(nullable NSString *)text
                        icon:(nullable UIImage *)icon
                        font:(UIFont *)font
                       color:(UIColor *)color NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@end

#ifdef __cplusplus
extern "C" {
#endif

// Bar button item whose customView is an SPKChromeButton. `outButton` yields
// the inner button for menu/tint/etc.
UIBarButtonItem *SPKChromeBarButtonItem(NSString *symbol,
                                        CGFloat pointSize,
                                        id _Nullable target,
                                        SEL _Nullable action,
                                        SPKChromeButton *_Nullable *_Nullable outButton);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
