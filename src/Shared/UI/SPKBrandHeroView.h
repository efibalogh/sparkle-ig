#import <UIKit/UIKit.h>

@class SPKBrandLogoView;

NS_ASSUME_NONNULL_BEGIN

/// The animated Sparkle brand hero: the logo over Instagram's gradient tile with a soft glow,
/// shared by the paged intro sheets and the update sheet. It scales and rotates its logo as pages
/// change (`pageProgress`, 0…n-1). It deliberately does NOT react to a page's vertical scroll: the
/// hero sits at a fixed layout slot, so shrinking it wouldn't reclaim space and only reads as a
/// glitch.
@interface SPKBrandHeroView : UIView
@property (nonatomic, strong) UIView *glowView;
@property (nonatomic, strong) SPKBrandLogoView *logoView;
- (void)setPageProgress:(CGFloat)progress;
@end

NS_ASSUME_NONNULL_END
