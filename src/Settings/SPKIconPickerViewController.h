#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPKIconPickerCellStyle) {
    SPKIconPickerCellStyleGlyph = 0,   // template monochrome glyph (action/section icons)
    SPKIconPickerCellStyleAppIcon = 1, // full-colour rounded app-icon artwork
};

/// One selectable entry in an icon picker.
@interface SPKIconPickerItem : NSObject
@property (nonatomic, copy) NSString *identifier;           // value matched for selection / handed back on tap
@property (nonatomic, copy, nullable) NSString *title;      // display label
@property (nonatomic, copy, nullable) NSString *searchText; // lowercased haystack for search
@property (nonatomic, strong, nullable) id userInfo;        // optional subclass payload
/// When set, the item takes a full-width row showing these previews instead of
/// a single grid cell, one equal column per preview with its title beneath.
@property (nonatomic, copy, nullable) NSArray<UIImage *> *previewImages;
@property (nonatomic, copy, nullable) NSArray<NSString *> *previewTitles;
+ (instancetype)itemWithIdentifier:(NSString *)identifier
                             title:(nullable NSString *)title
                        searchText:(nullable NSString *)searchText;
@end

/// A titled group of items. A nil/empty title renders without a header.
@interface SPKIconPickerSection : NSObject
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy) NSArray<SPKIconPickerItem *> *items;
+ (instancetype)sectionWithTitle:(nullable NSString *)title items:(NSArray<SPKIconPickerItem *> *)items;
@end

/// Shared grid + search + scroll-to-selection scaffolding for every Sparkle icon
/// picker (app icon, action-button section/submenu/bulk icons). Subclasses supply
/// the data, the artwork, and the selection behaviour by overriding the hooks below.
@interface SPKIconPickerViewController : UIViewController

@property (nonatomic, copy, nullable) NSString *selectedIdentifier;

/// Updates the highlighted cell and scrolls it into view.
- (void)refreshSelectionHighlight;

#pragma mark - Subclass hooks (override)

/// Required: the grouped items to display.
- (NSArray<SPKIconPickerSection *> *)buildSections;
/// Required: artwork for an item (cached by identifier by the base class).
- (nullable UIImage *)imageForItem:(SPKIconPickerItem *)item;
/// Required: handle a tap. The base class does NOT auto-pop; the subclass owns navigation.
- (void)didSelectItem:(SPKIconPickerItem *)item;

/// Optional configuration. Defaults: Glyph style, 3 columns, style-derived height,
/// "Search Icons" placeholder, identifier equality for the selection check.
- (SPKIconPickerCellStyle)cellStyle;
- (NSInteger)columnCountForWidth:(CGFloat)width;
- (CGFloat)itemHeight;
- (NSString *)searchPlaceholder;
- (BOOL)isSelectedItem:(SPKIconPickerItem *)item;

@end

NS_ASSUME_NONNULL_END
