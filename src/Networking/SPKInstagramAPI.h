// Reusable wrapper for Instagram private API calls.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SPKAPICompletion)(NSDictionary *_Nullable response, NSError *_Nullable error);
typedef void (^SPKAPIStatusesCompletion)(NSDictionary *_Nullable statuses, NSError *_Nullable error);

@interface SPKInstagramAPI : NSObject

// `path` is the part after /api/v1/, e.g. "friendships/show/123/".
// `body` is form-encoded if non-nil. `completion` runs on the main queue.
+ (void)sendRequestWithMethod:(NSString *)method
                         path:(NSString *)path
                         body:(nullable NSDictionary *)body
                   completion:(nullable SPKAPICompletion)completion;

+ (void)followUserPK:(NSString *)pk completion:(nullable SPKAPICompletion)completion;
+ (void)unfollowUserPK:(NSString *)pk completion:(nullable SPKAPICompletion)completion;

+ (void)fetchFriendshipStatusesForPKs:(NSArray<NSString *> *)pks
                           completion:(nullable SPKAPIStatusesCompletion)completion;

// Resolves the current (short-lived) profile-pic CDN URL for a user PK via
// users/<pk>/info/. `completion` runs on the main queue; url is nil on failure.
+ (void)resolveProfilePicURLForPK:(NSString *)pk
                       completion:(void (^)(NSString *_Nullable url, NSError *_Nullable error))completion;

+ (void)fetchWebMediaInfoForPK:(NSString *)mediaPK
                    completion:(nullable SPKAPICompletion)completion;

// Server-side thread mute, the same state Instagram's own mute sheet writes. Muting
// has to go through the account rather than the device: a push that was already
// handed to iOS cannot be silenced locally. Instagram keeps messages and calls as two
// independent states (its sheet also has a third, "Hide message previews", which only
// empties the banner and still delivers the push), so each is set on its own.
+ (void)setThreadMuted:(BOOL)muted
              threadId:(NSString *)threadId
            completion:(nullable SPKAPICompletion)completion;

+ (void)setThreadCallsMuted:(BOOL)muted
                   threadId:(NSString *)threadId
                 completion:(nullable SPKAPICompletion)completion;

// As above with extra form fields, for the duration parameters the mute sheet sends.
+ (void)setThreadCallsMuted:(BOOL)muted
                   threadId:(NSString *)threadId
                 parameters:(nullable NSDictionary *)parameters
                 completion:(nullable SPKAPICompletion)completion;

// Current server mute state for a thread. Either value is nil when the thread could
// not be read or does not carry that field, which callers must not confuse with
// "not muted".
+ (void)fetchThreadMuteStateForThreadId:(NSString *)threadId
                             completion:(void (^)(NSNumber *_Nullable messagesMuted,
                                                  NSNumber *_Nullable callsMuted,
                                                  NSError *_Nullable error))completion;

+ (void)resolveUserForUsername:(NSString *)username
                    completion:(void (^)(NSDictionary *_Nullable userDict, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
