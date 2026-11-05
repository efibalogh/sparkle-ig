//  SPKChangelogView.h
//  The public changelog page (changelog.html on the repo), shown in a web view that blends into the
//  Sparkle surface hosting it. Used by the update sheet and by the Changelog page in About.
//
//  The page itself stays as published, since Zebra and Cydia show it as the package depiction. Any
//  in-app adjustments are injected scripts, and each one leaves the page alone when the markup it
//  expects is missing.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, SPKChangelogOptions) {
    SPKChangelogOptionNone = 0,
    /// Folds away the releases this install already has, behind a button that brings them back.
    SPKChangelogOptionFoldInstalled = 1 << 0,
    /// Hides the page's own icon and title, for a host whose navigation bar already names it.
    SPKChangelogOptionHidePageHeader = 1 << 1,
    /// Labels the installed release.
    SPKChangelogOptionMarkInstalled = 1 << 2,
};

@interface SPKChangelogView : UIView

- (instancetype)initWithOptions:(SPKChangelogOptions)options NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Starts loading unless the page is already loaded or loading. After a failure it starts over.
- (void)loadIfNeeded;

@end

NS_ASSUME_NONNULL_END
