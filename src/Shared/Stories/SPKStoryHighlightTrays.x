// Keeps track of the highlight lists Instagram builds for profiles.
//
// A profile's highlights live in an IGHighlightsStoryTrayDataSource that the
// profile creates and owns. Nothing reachable from outside hands it back, and the
// story map is no substitute: it keeps whichever highlight reels happen to be
// retained, so right after a profile is reopened it can hold one stale reel and
// look like a complete, settled list. Recording each data source as it is
// created gives the highlight search the same list the profile is showing, in
// the profile's order, and a real answer to "has it finished loading".

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "../../InstagramHeaders.h"
#import "../../Utils.h"

static NSMutableDictionary<NSString *, NSHashTable *> *spk_highlightTraysByUser;
static BOOL spk_highlightTrayTrackingInstalled = NO;

BOOL SPKStoryHighlightTrayTrackingIsInstalled(void) {
    return spk_highlightTrayTrackingInstalled;
}

// The live highlight data sources for an account, newest last. Empty when the
// account's profile is not open, or when tracking is not installed.
NSArray *SPKStoryHighlightTraysForUser(NSString *userPK) {
    if (userPK.length == 0)
        return @[];
    @synchronized([SPKUtils class]) {
        return [spk_highlightTraysByUser[userPK] allObjects] ?: @[];
    }
}

%group SPKStoryHighlightTrayTracking

%hook IGHighlightsStoryTrayDataSource

- (id)initWithUserPK:(id)userPK userSession:(id)session diskManager:(id)diskManager isArchive:(BOOL)isArchive {
    id tray = %orig;
    // The archive variant lists the account owner's own archive, not highlights.
    if (tray && !isArchive && [userPK isKindOfClass:[NSString class]] && [(NSString *)userPK length] > 0) {
        @synchronized([SPKUtils class]) {
            if (!spk_highlightTraysByUser)
                spk_highlightTraysByUser = [NSMutableDictionary dictionary];
            NSHashTable *trays = spk_highlightTraysByUser[userPK];
            if (!trays) {
                trays = [NSHashTable weakObjectsHashTable];
                spk_highlightTraysByUser[userPK] = trays;
            }
            [trays addObject:tray];
        }
    }
    return tray;
}

%end

%end

void SPKInstallStoryHighlightTrayTrackingHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class trayClass = objc_getClass("IGHighlightsStoryTrayDataSource");
        if (trayClass && [trayClass instancesRespondToSelector:@selector(initWithUserPK:userSession:diskManager:isArchive:)]) {
            %init(SPKStoryHighlightTrayTracking);
            spk_highlightTrayTrackingInstalled = YES;
        } else {
            SPKLog(@"Stories", @"[Sparkle StoryOpen] Highlights tray class missing, highlight search falls back to the story map");
        }
    });
}
