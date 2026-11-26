#import <Foundation/Foundation.h>

// Whether this Instagram build ships the highlight reordering config. Builds
// without it (410.1.0) have nothing to turn on.
FOUNDATION_EXPORT BOOL SPKHighlightReorderIsAvailable(void);
