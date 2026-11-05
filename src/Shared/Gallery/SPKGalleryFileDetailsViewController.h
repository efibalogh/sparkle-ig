#import <UIKit/UIKit.h>

@class SPKGalleryFile;

NS_ASSUME_NONNULL_BEGIN

/// Edit-details form for a Gallery file: editable display name, source username and
/// date, plus read-only context (type, dimensions, size, folder, media code, and
/// the original link, which copies itself when tapped).
/// Replaces the old single-field "Rename".
@interface SPKGalleryFileDetailsViewController : UITableViewController

- (instancetype)initWithFile:(SPKGalleryFile *)file;

/// Called after the user saves changes (so the presenter can refetch/reload).
@property (nonatomic, copy, nullable) void (^onSaved)(void);

@end

NS_ASSUME_NONNULL_END
