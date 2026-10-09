#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// A single row in an SPKUserListViewController. `representedObject` carries the
// caller's own model (e.g. a thread/user dictionary) back to the action hooks.
@interface SPKUserListItem : NSObject
@property (nonatomic, copy, nullable) NSString *pk;            // numeric PK → avatar self-heal
@property (nonatomic, copy, nullable) NSString *title;         // bold line, e.g. "@username"
@property (nonatomic, copy, nullable) NSString *subtitle;      // secondary line
@property (nonatomic, copy, nullable) NSString *avatarURLString;
@property (nonatomic, assign) BOOL isGroup;                    // group-glyph placeholder
@property (nonatomic, assign) BOOL isVerified;
@property (nonatomic, strong, nullable) id representedObject;
@end

// Plain user-list screen matching the Profile Analyzer lists: a native table of
// avatar rows with search, a sort menu, an empty state, and swipe-to-delete —
// no settings-cell scaffolding. Subclass it, override -buildItems and the
// action hooks, then call -reloadItems whenever the backing data changes.
@interface SPKUserListViewController : UIViewController

// Empty-state copy.
@property (nonatomic, copy) NSString *emptyTitle;
@property (nonatomic, copy) NSString *emptySubtitle;
@property (nonatomic, copy, nullable) NSString *emptySearchSubtitle;
// Asset name of the empty-state glyph; defaults to "users_empty". Set before the view loads.
@property (nonatomic, copy, nullable) NSString *emptyIconName;

// When set, an "info" bar button presents this text in a "How It Works" alert.
@property (nonatomic, copy, nullable) NSString *infoText;

// Trailing bar buttons. Add shows a "+" that calls -didTapAdd. Sort/search are
// on by default; turn them off for short, fixed lists.
@property (nonatomic, assign) BOOL showsAddButton;
@property (nonatomic, assign) BOOL enablesSearch; // default YES
@property (nonatomic, assign) BOOL enablesSort;   // default YES
@property (nonatomic, assign) BOOL allowsDelete;  // default YES

// Rebuild + re-filter + reload from -buildItems. Safe to call repeatedly.
- (void)reloadItems;

#pragma mark - Subclass overrides

- (NSArray<SPKUserListItem *> *)buildItems;                 // required
- (void)didSelectItem:(SPKUserListItem *)item;              // default: opens the @username profile
- (void)didDeleteItem:(SPKUserListItem *)item;              // default: no-op
- (void)didTapAdd;                                          // default: no-op
- (void)listDidUpdateItemCount:(NSUInteger)count;          // default: no-op (override to retitle)
- (NSArray<UIBarButtonItem *> *)additionalTrailingBarItems; // default: none; own bubble at the trailing edge

@end

NS_ASSUME_NONNULL_END
