#import <UIKit/UIKit.h>

#import "../Shared/ActionButton/ActionButtonCore.h"
#import "../Shared/ActionButton/SPKActionMenuSection.h"
#import "SPKSetting.h"

NS_ASSUME_NONNULL_BEGIN

NSDictionary *SPKTopicSection(NSString *header, NSArray *rows, NSString *_Nullable footer);
/// Overrides where a section's help text is shown, for the cases the row count
/// gets wrong. By default a header group with two or more explained rows gets an
/// info button and a group with one keeps a plain footer; pass YES to force the
/// button (the group still needs a header to host it) or NO to force the footer.
NSDictionary *SPKTopicSectionWithInfoSheet(NSDictionary *section, BOOL usesInfoSheet);
FOUNDATION_EXPORT CGFloat const SPKSettingsCellIconPointSize;
UIImage *SPKSettingsIcon(NSString *name);
UIImage *SPKSettingsSystemIcon(NSString *name, CGFloat pointSize, UIImageSymbolWeight weight);
SPKSetting *SPKSettingApplyIconTint(SPKSetting *setting, UIColor *_Nullable tintColor);
/// Attaches `helpText` to a row built inline inside a section's row array.
SPKSetting *SPKSettingWithHelp(SPKSetting *setting, NSString *helpText);
SPKSetting *SPKSettingApplySelectedMenuIcon(SPKSetting *setting, UIImage *_Nullable fallbackIcon);
SPKSetting *SPKTopicNavigationSetting(NSString *title, NSString *iconName, CGFloat iconSize, NSArray *sections);
SPKSetting *SPKActionButtonDefaultActionNavigationSetting(SPKActionButtonSource source);
SPKSetting *SPKActionButtonConfigurationNavigationSetting(SPKActionButtonSource source, NSString *topicTitle, NSArray<NSString *> *supportedActions, NSArray<SPKActionMenuSection *> *defaultSections);
UIMenu *SPKReelsTapControlMenu(void);
UIMenu *SPKMainFeedModeMenu(void);
UIMenu *SPKSeenButtonPositionMenu(void);
UIMenu *SPKHiddenChatsRevealResetMenu(void);
UIMenu *SPKLastActiveFormatMenu(void);
UIMenu *SPKLiquidGlassTabBarStateMenu(void);
UIMenu *SPKSwipeCloseCommentsDirectionMenu(void);
UIMenu *SPKCacheAutoClearMenu(void);
UIMenu *SPKNotificationProgressSubtitleStyleMenu(void);
UIMenu *SPKNotificationPillPositionMenu(void);
UIMenu *SPKMediaVideoQualityMenu(void);
UIMenu *SPKMediaPhotoQualityMenu(void);
UIMenu *SPKAutoSaveDestinationMenu(void);
UIMenu *SPKAutoSaveVideoQualityMenu(void);
UIMenu *SPKAutoSavePhotoQualityMenu(void);
UIMenu *SPKAutoSaveFilterModeMenu(NSString *filterModeKey, NSString *subjectPlural);
UIMenu *SPKStoryAutoSaveFilterModeMenu(void);
UIMenu *SPKGalleryShortcutTargetMenu(void);
SPKSetting *SPKFeedHeaderButtonDefaultActionNavigationSetting(void);

/// The view controller a settings row should present from: the topmost presented
/// controller, which is normally the navigation controller wrapping the page.
UIViewController *SPKSettingsTopPresenter(void);

/// Reloads whichever settings page is on screen behind `presenter`, so rows whose
/// enabled state depends on something outside NSUserDefaults (a keychain-backed lock,
/// for one) redraw after the flow that changed it finishes.
void SPKSettingsReloadPresenter(UIViewController *presenter);

NS_ASSUME_NONNULL_END
