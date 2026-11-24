#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Whether this Instagram build has the share sheet Muse destination (not 410).
BOOL SPKHideMuseShareSheetIsAvailable(void);

/// Whether this Instagram build has the profile navigation bar Muse button (not 410).
BOOL SPKHideMuseProfileButtonIsAvailable(void);

void SPKInstallHideMuseHooksIfNeeded(void);

#ifdef __cplusplus
}
#endif
