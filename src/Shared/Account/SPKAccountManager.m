#import "SPKAccountManager.h"

#import <UIKit/UIKit.h>

#import "../../Utils.h"

NSNotificationName const SPKAccountDidChangeNotification = @"SPKAccountDidChangeNotification";

static NSString *const kSPKAccountRosterDefaultsKey = @"spk_account_roster";

@interface SPKAccountManager ()
@property (nonatomic, copy, nullable) NSString *cachedPK;
@property (nonatomic, copy, nullable) NSString *cachedUsername;
@property (nonatomic, assign) BOOL hasResolvedOnce;
+ (void)recordAccountPK:(NSString *)pk username:(nullable NSString *)username;
@end

@implementation SPKAccountManager

+ (instancetype)shared {
    static SPKAccountManager *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        // In-app account switches usually round-trip through the background, and
        // a fresh foreground is the cheapest reliable point to re-check.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applicationDidBecomeActive:(NSNotification *)note {
    [self refreshCurrentAccount];
}

#pragma mark - Resolution

// Resolves the active account's username from the live session user object.
static NSString *SPKAccountUsernameFromSession(id session) {
    @try {
        id user = [session valueForKey:@"user"];
        if (!user)
            return nil;
        id username = [user respondsToSelector:@selector(username)] ? [user valueForKey:@"username"] : nil;
        return [username isKindOfClass:[NSString class]] && [(NSString *)username length] > 0 ? username : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL SPKStringsEqual(NSString *a, NSString *b) {
    if (a == b)
        return YES;
    if (!a || !b)
        return NO;
    return [a isEqualToString:b];
}

- (void)refreshCurrentAccount {
    id session = [SPKUtils activeUserSession];
    NSString *pk = [SPKUtils currentUserPK];
    NSString *username = pk.length > 0 ? SPKAccountUsernameFromSession(session) : nil;

    NSString *previousPK = self.cachedPK;
    BOOL hadResolved = self.hasResolvedOnce;

    self.cachedPK = pk;
    if (username.length > 0)
        self.cachedUsername = username;
    else if (pk.length == 0)
        self.cachedUsername = nil; // logged out
    self.hasResolvedOnce = YES;

    if (pk.length > 0) {
        [[self class] recordAccountPK:pk username:self.cachedUsername];
    }

    // Only notify on an actual change after the baseline is established (not on
    // the first resolve).
    if (!hadResolved || SPKStringsEqual(previousPK, pk))
        return;

    [self postAccountChanged];
}

- (void)postAccountChanged {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (self.cachedPK.length > 0)
        info[@"pk"] = self.cachedPK;
    if (self.cachedUsername.length > 0)
        info[@"username"] = self.cachedUsername;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SPKAccountDidChangeNotification
                                                            object:[self class]
                                                          userInfo:info];
    });
}

- (void)noteSwitchedToAccountPK:(NSString *)pk {
    if (pk.length == 0)
        return;

    NSString *previous = self.cachedPK;
    self.cachedPK = pk;
    // The live session hasn't swapped yet at switch time, so fill the username
    // from the roster now and refine it from the session once it settles.
    NSString *rosterUsername = [[self class] usernameForPK:pk];
    self.cachedUsername = rosterUsername.length > 0 ? rosterUsername : nil;
    self.hasResolvedOnce = YES;
    [[self class] recordAccountPK:pk username:self.cachedUsername];

    if (!SPKStringsEqual(previous, pk)) {
        [self postAccountChanged];
    }

    // Refine the username from the swapped-in session without overriding the PK.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![self.cachedPK isEqualToString:pk])
            return; // switched again meanwhile
        NSString *liveUsername = SPKAccountUsernameFromSession([SPKUtils activeUserSession]);
        if (liveUsername.length > 0 && ![liveUsername isEqualToString:self.cachedUsername]) {
            self.cachedUsername = liveUsername;
            [[self class] recordAccountPK:pk username:liveUsername];
        }
    });
}

+ (NSString *)currentAccountPK {
    SPKAccountManager *manager = [self shared];
    if (!manager.hasResolvedOnce)
        [manager refreshCurrentAccount];
    return manager.cachedPK;
}

+ (NSString *)preferenceNamespacePK {
    NSString *pk = [self currentAccountPK];
    if (pk.length > 0)
        return pk;

    // Session not resolved (early launch) or logged out — fall back to the
    // most-recently-seen account. Single pass over the roster, no sort/alloc,
    // since this runs on the preference-read hot path during the nil window.
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSPKAccountRosterDefaultsKey];
    if (![stored isKindOfClass:[NSDictionary class]])
        return nil;
    __block NSString *newestPK = nil;
    __block double newestSeen = -1.0;
    [stored enumerateKeysAndObjectsUsingBlock:^(NSString *rosterPK, id value, BOOL *stop) {
        if (rosterPK.length == 0 || ![value isKindOfClass:[NSDictionary class]])
            return;
        double seen = [value[@"lastSeen"] doubleValue];
        if (seen > newestSeen) {
            newestSeen = seen;
            newestPK = rosterPK;
        }
    }];
    return newestPK.length > 0 ? newestPK : nil;
}

+ (NSString *)currentAccountUsername {
    SPKAccountManager *manager = [self shared];
    if (!manager.hasResolvedOnce)
        [manager refreshCurrentAccount];
    return manager.cachedUsername;
}

#pragma mark - Roster

+ (void)recordAccountPK:(NSString *)pk username:(NSString *)username {
    if (pk.length == 0)
        return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *stored = [defaults dictionaryForKey:kSPKAccountRosterDefaultsKey];
    NSMutableDictionary *roster = [stored isKindOfClass:[NSDictionary class]] ? [stored mutableCopy] : [NSMutableDictionary dictionary];

    NSDictionary *existing = [roster[pk] isKindOfClass:[NSDictionary class]] ? roster[pk] : nil;
    NSString *resolvedUsername = username.length > 0 ? username : (existing[@"username"] ?: @"");
    NSDictionary *entry = @{
        @"username" : resolvedUsername,
        @"lastSeen" : @([[NSDate date] timeIntervalSince1970])
    };
    // lastSeen is what preferenceNamespacePK uses to pick the account before the
    // session resolves, so it must move whenever the active account changes, not
    // only when a username does. Skip the write only when this account is already
    // the newest entry and its username is unchanged (every foreground/refresh).
    if (existing && [existing[@"username"] isEqualToString:resolvedUsername]) {
        double ownSeen = [existing[@"lastSeen"] doubleValue];
        __block BOOL isNewest = YES;
        [roster enumerateKeysAndObjectsUsingBlock:^(NSString *otherPK, id value, BOOL *stop) {
            if ([otherPK isEqualToString:pk] || ![value isKindOfClass:[NSDictionary class]])
                return;
            if ([value[@"lastSeen"] doubleValue] >= ownSeen) {
                isNewest = NO;
                *stop = YES;
            }
        }];
        if (isNewest)
            return;
    }

    roster[pk] = entry;
    [defaults setObject:roster forKey:kSPKAccountRosterDefaultsKey];
}

+ (NSArray<NSDictionary *> *)knownAccounts {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSPKAccountRosterDefaultsKey];
    if (![stored isKindOfClass:[NSDictionary class]])
        return @[];

    NSMutableArray<NSDictionary *> *accounts = [NSMutableArray array];
    [stored enumerateKeysAndObjectsUsingBlock:^(NSString *pk, NSDictionary *value, BOOL *stop) {
        if (pk.length == 0 || ![value isKindOfClass:[NSDictionary class]])
            return;
        [accounts addObject:@{
            @"pk" : pk,
            @"username" : value[@"username"] ?: @"",
            @"lastSeen" : value[@"lastSeen"] ?: @0
        }];
    }];
    [accounts sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"lastSeen"] compare:a[@"lastSeen"]];
    }];
    return accounts;
}

+ (NSString *)usernameForPK:(NSString *)pk {
    if (pk.length == 0)
        return nil;
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSPKAccountRosterDefaultsKey];
    NSDictionary *entry = [stored isKindOfClass:[NSDictionary class]] ? stored[pk] : nil;
    NSString *username = [entry isKindOfClass:[NSDictionary class]] ? entry[@"username"] : nil;
    return username.length > 0 ? username : nil;
}

@end
