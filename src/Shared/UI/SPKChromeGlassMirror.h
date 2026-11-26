#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// Shared plumbing for Sparkle buttons injected into IG's Liquid Glass chrome
// (profile nav header, feed header, DM inbox header). Those buttons sit beside IG's
// own nav buttons, which show a Liquid Glass "bubble" on an IGLiquidGlass private
// UIVisualEffectView subclass — it fades in with scroll (alpha 0 flush -> 1 once the
// header bar shows) and is what you actually see behind their glyphs.
//
// Rather than approximating that material, we sample the neighbouring bubble and
// adopt its live UIVisualEffect instance, so tint / opacity / ring match IG exactly
// and keep matching when IG restyles them.

// A circular glass bubble to sit behind an injected button's icon. It is created
// with NO effect and renders nothing until SPKChromeGlassMirrorSync gives it IG's
// own — there is deliberately no approximated material to fall back to. Returns nil
// pre-iOS 26 (no UIGlassEffect), where callers should leave the button a bare icon.
UIView *SPKChromeGlassMirrorMakeBubble(NSString *accessibilityIdentifier);

// Parents `glassView` behind `button`'s icon (inside SPKChromeButton's capture canvas,
// so it redacts along with the icon) and sizes both to a circle. The radius on the
// button matters even though it never masks: UIKit shapes the context-menu highlight
// and dismissal platter from it, and a radius of 0 flashes a square behind the button
// as the action menu closes.
void SPKChromeGlassMirrorAttach(UIView *glassView, UIButton *button);

// Gives `glassView` the system glass material and attaches it behind `button`'s
// icon, for buttons with no IG bubble beside them to mirror (their own glass
// circle in the side column or in a navigation bar). Write-guarded, so it can run
// on every layout pass.
void SPKChromeGlassMirrorUseSystemGlass(UIView *glassView, UIButton *button);

// Mirrors the strongest IG bubble found under `chromeView` onto `glassView`: copies
// its effect and hairline ring, and sets `glassView.alpha` to the bubble's (that
// alpha is what fades the bubble in as the header bar appears).
//
// Call this from the chrome's layout pass. `chromeView` is registered on first call,
// after which any alpha change IG animates on one of its bubbles marks it for layout
// — so callers don't need to poll to stay in sync.
//
// Returns the mirrored alpha, or < 0 when no IG bubble exists (iOS < 26 / IG 410).
CGFloat SPKChromeGlassMirrorSync(UIView *glassView, UIView *chromeView);

#ifdef __cplusplus
}
#endif
