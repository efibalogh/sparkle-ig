#import "../../InstagramHeaders.h"
#import "../../Shared/ActionButton/ActionButtonLookupUtils.h"
#import "../../Shared/Messages/SPKPresenceTracking.h"
#import "../../Utils.h"

#import <UserNotifications/UserNotifications.h>

// Sampling what Instagram already believed has to happen before the original
// implementation writes the new value, since that stored value is what the rest of
// the UI is drawn from. Only done for users we would actually notify about: this
// runs for everyone Instagram streams presence for.
static NSNumber *SPKPresenceSamplePriorState(NSString *userPk) {
    if (!SPKPresenceNotificationsEnabled() || !SPKPresenceAppliesToUser(userPk))
        return nil;
    return SPKPresenceIGActiveStateForPK(userPk);
}

// Installed unconditionally: SPKPresenceHandleUpdate re-reads the pref on every
// update, so the toggle takes effect without a restart. Presence is high-traffic,
// so the funnel bails on the disabled/untracked case before doing any work.
%hook IGPresenceManager

- (void)presenceRealtimeDataProvider:(id)provider
           didReceiveUpdateForUserPk:(id)pk
                            isActive:(BOOL)isActive
                    lastActivityAtMs:(double)lastActivityAtMs
                        capabilities:(unsigned long long)capabilities
                       correlationId:(id)correlationId
                       isCloseFriend:(BOOL)isCloseFriend {
    NSString *userPk = SPKStringFromValue(pk);
    NSNumber *prior = SPKPresenceSamplePriorState(userPk);
    %orig;
    SPKLog(@"Presence", @"[Sparkle Presence] raw update pk=%@ isActive=%d lastActivityAtMs=%f igPrior=%@",
           userPk, isActive, lastActivityAtMs, prior ?: @"unknown");
    SPKPresenceHandleUpdate(userPk, isActive, lastActivityAtMs, prior);
}

%end

// Newer builds carry a second realtime entry point alongside the delegate callback
// above, and presence arriving on it never reaches the other one. Watching only one
// of the two leaves our idea of a user's state stuck at whatever the other path last
// wrote, which is how a notification ends up disagreeing with the green dot.
//
// Grouped and installed by selector probe because it does not exist on older builds,
// where the delegate callback is still the only writer.
//
// The selector for it was renamed once already, so both spellings are carried and
// probed independently rather than assumed to be the same build's.
%group SPKPresenceUPC

%hook IGPresenceManager

- (void)handleUPCRealtimePresenceUpdateForUserPk:(id)pk
                                        isActive:(BOOL)isActive
                                lastActivityAtMs:(double)lastActivityAtMs
                                    capabilities:(unsigned long long)capabilities
                                   correlationId:(id)correlationId {
    NSString *userPk = SPKStringFromValue(pk);
    NSNumber *prior = SPKPresenceSamplePriorState(userPk);
    %orig;
    SPKLog(@"Presence", @"[Sparkle Presence] raw upc update pk=%@ isActive=%d lastActivityAtMs=%f igPrior=%@",
           userPk, isActive, lastActivityAtMs, prior ?: @"unknown");
    SPKPresenceHandleUpdate(userPk, isActive, lastActivityAtMs, prior);
}

%end

%end

%group SPKPresenceUnified

%hook IGPresenceManager

- (void)_unifiedPresenceDidReceiveRealtimeUpdateForUserPk:(id)pk
                                                 isActive:(BOOL)isActive
                                         lastActivityAtMs:(double)lastActivityAtMs
                                             capabilities:(unsigned long long)capabilities
                                            correlationId:(id)correlationId {
    NSString *userPk = SPKStringFromValue(pk);
    NSNumber *prior = SPKPresenceSamplePriorState(userPk);
    %orig;
    SPKLog(@"Presence", @"[Sparkle Presence] raw unified update pk=%@ isActive=%d lastActivityAtMs=%f igPrior=%@",
           userPk, isActive, lastActivityAtMs, prior ?: @"unknown");
    SPKPresenceHandleUpdate(userPk, isActive, lastActivityAtMs, prior);
}

%end

%end

// The dictionary is threadId -> typing state, but the value shape is not something
// to rely on: it has been a single status, a collection of them, and a nested
// dictionary keyed by pk. Collecting every IGDirectTypingStatus found underneath is
// version-proof. Keep the thread id with the sender: tracking is user-based, but
// notification copy must still distinguish a group burst from a 1:1 burst.
static void SPKPresenceCollectTypingStatuses(id node,
                                             NSMutableDictionary<NSString *, NSDictionary *> *out,
                                             NSUInteger depth,
                                             NSString *inheritedThreadID) {
    if (node == nil || depth > 3)
        return;

    Class statusClass = %c(IGDirectTypingStatus);
    if (statusClass && [node isKindOfClass:statusClass]) {
        IGDirectTypingStatus *status = node;
        if (!status.isActive)
            return;
        NSString *pk = SPKStringFromValue(status.userPk);
        if (pk.length == 0)
            return;
        NSString *threadID = SPKStringFromValue(status.threadId);
        if (threadID.length == 0)
            threadID = inheritedThreadID;
        NSDate *sentDate = [status.sentDate isKindOfClass:NSDate.class] ? status.sentDate : nil;
        NSString *eventKey = threadID.length > 0 ? [NSString stringWithFormat:@"%@:%@", threadID, pk] : pk;
        NSDictionary *existing = out[eventKey];
        NSDate *existingDate = [existing[@"sentDate"] isKindOfClass:NSDate.class] ? existing[@"sentDate"] : nil;
        if (!existing || (sentDate && (!existingDate || [sentDate compare:existingDate] == NSOrderedDescending))) {
            NSMutableDictionary *event = [@{ @"pk" : pk,
                                             @"sentDate" : sentDate ?: existingDate ?: NSDate.date } mutableCopy];
            if (threadID.length > 0)
                event[@"threadId"] = threadID;
            out[eventKey] = event;
        }
        return;
    }

    if ([node isKindOfClass:NSDictionary.class]) {
        [(NSDictionary *)node enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
            NSString *nextThreadID = inheritedThreadID;
            if (depth == 0) {
                NSString *candidate = SPKStringFromValue(key);
                if (candidate.length > 0)
                    nextThreadID = candidate;
            }
            SPKPresenceCollectTypingStatuses(value, out, depth + 1, nextThreadID);
        }];
        return;
    }
    if ([node isKindOfClass:NSArray.class] || [node isKindOfClass:NSSet.class]) {
        for (id value in (id<NSFastEnumeration>)node)
            SPKPresenceCollectTypingStatuses(value, out, depth + 1, inheritedThreadID);
    }
}

static void SPKPresenceHandleTypingStore(id store,
                                         NSString *updatedThreadID,
                                         id updatedStatuses,
                                         NSString *source) {
    if (!SPKPresenceNotificationsEnabled())
        return;
    // The store is republished on every thread load during inbox sync. Skip the
    // walk when typing notifications are off or nobody is tracked.
    if (![SPKUtils getBoolPref:@"msgs_presence_notify_typing"] || !SPKPresenceHasAnyTarget())
        return;

    NSMutableDictionary<NSString *, NSDictionary *> *active = [NSMutableDictionary dictionary];
    SPKPresenceCollectTypingStatuses(store, active, 0, nil);
    // Some builds notify listeners with the per-thread value before publishing the
    // same value through the copied dictionary. Preserve the explicit thread id so
    // group activity is not lost in that window.
    SPKPresenceCollectTypingStatuses(updatedStatuses, active, 0, updatedThreadID);

    NSUInteger threadCount = [store isKindOfClass:NSDictionary.class] ? [(NSDictionary *)store count] : 0;
    if (active.count > 0) {
        SPKLog(@"Presence", @"[Sparkle Presence] typing snapshot source=%@ threads=%lu typing=%lu updatedThread=%@ updatedClass=%@",
               source ?: @"unknown",
               (unsigned long)threadCount,
               (unsigned long)active.count,
               updatedThreadID ?: @"none",
               updatedStatuses ? NSStringFromClass([updatedStatuses class]) : @"nil");
    }
    SPKPresenceHandleTypingSnapshot(active);
}

// Typing state is replaced wholesale on every change, so the setter is the single
// point every incoming typing update passes through, on both the realtime and the
// delta path. Hooking it avoids having to reach the session-scoped service instance
// that addListener: would need.
%hook IGDirectTypingStatusService

- (void)setThreadIdToTypingStatuses:(NSDictionary *)statuses {
    %orig;
    SPKPresenceHandleTypingStore(statuses, nil, nil, @"store");
}

- (id)updatedTypingStatusesForThreadId:(id)threadIDValue {
    id statuses = %orig;
    if (SPKPresenceNotificationsEnabled()) {
        NSString *threadID = SPKStringFromValue(threadIDValue);
        NSDictionary *store = self.threadIdToTypingStatuses;
        SPKPresenceHandleTypingStore(store, threadID, statuses, @"thread");
    }
    return statuses;
}

%end

// Activity notifications are only posted while Instagram is in the background, so one
// reaching this delegate means the app came back to the front in the moment between
// the state check and delivery. Answering with no presentation options drops it: the
// user is looking at the app, and handing it to Instagram's own handler would mean
// letting it parse a notification it never created.
%hook IGAppCoordinator

- (void)userNotificationCenter:(id)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))handler {
    NSDictionary *userInfo = notification.request.content.userInfo;
    if ([userInfo isKindOfClass:NSDictionary.class] && [userInfo[kSPKPresenceNotificationMarker] boolValue]) {
        if (handler)
            handler(UNNotificationPresentationOptionNone);
        return;
    }
    %orig;
}

%end

void SPKInstallPresenceNotificationsHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!%c(IGPresenceManager)) {
            SPKLog(@"Presence", @"[Sparkle Presence] IGPresenceManager unavailable, activity notifications inactive");
            return;
        }
        %init;
        SEL upcSelector = @selector(handleUPCRealtimePresenceUpdateForUserPk:isActive:lastActivityAtMs:capabilities:correlationId:);
        if ([%c(IGPresenceManager) instancesRespondToSelector:upcSelector]) {
            %init(SPKPresenceUPC);
            SPKLog(@"Presence", @"[Sparkle Presence] UPC realtime path present, hooked");
        }
        SEL unifiedSelector = @selector(_unifiedPresenceDidReceiveRealtimeUpdateForUserPk:isActive:lastActivityAtMs:capabilities:correlationId:);
        if ([%c(IGPresenceManager) instancesRespondToSelector:unifiedSelector]) {
            %init(SPKPresenceUnified);
            SPKLog(@"Presence", @"[Sparkle Presence] Unified realtime path present, hooked");
        }
        if (!%c(IGDirectTypingStatusService)) {
            SPKLog(@"Presence", @"[Sparkle Presence] IGDirectTypingStatusService unavailable, typing notifications inactive");
        }
        SPKPresenceNoteStreamStarted();
        // Foregrounding is followed by IG replaying presence it already knew, which
        // should seed rather than notify.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
                                                        SPKPresenceNoteStreamStarted();
                                                    }];
        SPKLog(@"Presence", @"[Sparkle Presence] Installed presence hooks, currentUserPK=%@", [SPKUtils currentUserPK]);
    });
}
