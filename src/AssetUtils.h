#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Point size for icons in Sparkle's own menus.
FOUNDATION_EXPORT const CGFloat kSPKMenuIconPointSize;
// Native point size of Instagram's menu glyphs, for rows Sparkle adds to them.
FOUNDATION_EXPORT const CGFloat kSPKInstagramMenuIconPointSize;

typedef NS_ENUM(NSInteger, SPKAssetCatalogSource) {
    SPKAssetCatalogSourceAutomatic = 0,
    SPKAssetCatalogSourceFBSharedFramework = 1,
    SPKAssetCatalogSourceMainApp = 2,
};

typedef NS_ENUM(NSInteger, SPKResolvedImageSource) {
    SPKResolvedImageSourceAutomatic = 0,
    SPKResolvedImageSourceInstagramIcon = 1,
    SPKResolvedImageSourceSystemSymbol = 2,
};

@interface SPKAssetUtils : NSObject

+ (nullable UIImage *)instagramIconNamed:(NSString *)name;
+ (nullable UIImage *)instagramIconNamed:(NSString *)name pointSize:(CGFloat)pointSize;
+ (nullable UIImage *)instagramIconNamed:(NSString *)name pointSize:(CGFloat)pointSize renderingMode:(UIImageRenderingMode)renderingMode;

+ (nullable UIImage *)instagramIconNamed:(NSString *)name
                               pointSize:(CGFloat)pointSize
                                  source:(SPKAssetCatalogSource)source
                           renderingMode:(UIImageRenderingMode)renderingMode;

// Icon for a UIMenu / UIAction / UIContextualAction slot. Loads the pristine
// catalog image at its native size (no rasterising downscale): iOS 16's UIMenu
// renders a re-rasterised bitmap blank for vector-backed (.svg) glyphs, so menu
// rows using those come up iconless. The menu scales the native image into its
// own fixed slot, so the on-screen size is unchanged. Always use this — never a
// sized instagramIconNamed: — when building menu / action icons. Returns an
// AlwaysTemplate image.
+ (nullable UIImage *)menuIconNamed:(NSString *)name;

// menuIconNamed: at an explicit point size. Pass kSPKInstagramMenuIconPointSize
// for a row Sparkle inserts into one of Instagram's own menus, whose glyphs are
// 24pt: a 22pt row next to them reads as a smaller, foreign icon.
+ (nullable UIImage *)menuIconNamed:(NSString *)name pointSize:(CGFloat)pointSize;

// Same 22pt menu sizing as menuIconNamed:, but applied to an already-resolved
// image — for callers that build the icon themselves (e.g. the action-button
// menu, which picks reels/toggle variants). Pass an image loaded at its native
// size (no downscale); this reinterprets its scale to 22pt with no redraw, so
// it stays renderable in iOS 16's UIMenu. Returns an AlwaysTemplate image.
+ (nullable UIImage *)menuSizedIcon:(nullable UIImage *)image;

// menuSizedIcon: at an explicit point size. A size at or above the image's
// native size returns it untouched.
+ (nullable UIImage *)menuSizedIcon:(nullable UIImage *)image pointSize:(CGFloat)pointSize;

+ (nullable UIImage *)resolvedImageNamed:(NSString *)name
                               pointSize:(CGFloat)pointSize
                                  weight:(UIImageSymbolWeight)weight
                                  source:(SPKResolvedImageSource)source
                           renderingMode:(UIImageRenderingMode)renderingMode;

+ (nullable UIImage *)resolvedImageNamed:(nullable NSString *)name
                      fallbackSystemName:(nullable NSString *)fallbackSystemName
                               pointSize:(CGFloat)pointSize
                                  weight:(UIImageSymbolWeight)weight
                                  source:(SPKResolvedImageSource)source
                           renderingMode:(UIImageRenderingMode)renderingMode;

// Resolves a name (shorthand alias like "carousel"/"action", or a raw
// "ig_icon_*" catalog name) to the canonical Instagram catalog asset name that
// actually renders for it — i.e. the inverse direction of instagramIconNamed:.
// Returns nil if nothing resolves. Used to match a stored icon name against the
// runtime Instagram icon list.
+ (nullable NSString *)resolvedInstagramIconNameForName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
