#import <Foundation/Foundation.h>

// Whether this Instagram build switches its audio session into the mode that
// interrupts other apps. Builds without that switch (410.1.0) have nothing to
// turn off.
FOUNDATION_EXPORT BOOL SPKKeepOtherAudioPlayingIsAvailable(void);
