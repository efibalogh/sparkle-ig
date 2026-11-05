#import "ActionButtonLookupUtils.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>
#import <stdarg.h>

#import "../../Utils.h"

id SPKObjectForSelector(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0)
        return nil;

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector])
        return nil;

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    const char *returnType = signature.methodReturnType;
    if (!returnType || (returnType[0] != '@' && returnType[0] != '#'))
        return nil;

    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static BOOL SPKClassOverridesNSObjectMethod(Class cls, SEL selector) {
    Method base = class_getInstanceMethod([NSObject class], selector);
    Method own = class_getInstanceMethod(cls, selector);
    return own && base && method_getImplementation(own) != method_getImplementation(base);
}

static BOOL SPKKVCKeyIsResolvableUncached(id target, Class cls, NSString *key) {
    // Pure Swift classes have no KVC at all; the call used to throw an unrecognized
    // selector, which came back as nil the same way.
    if (![cls instancesRespondToSelector:@selector(valueForKey:)])
        return NO;
    // Classes with their own KVC (collections map the key over their elements, CALayer and
    // Core Data answer arbitrary keys, and so on) keep their exact behaviour.
    if (SPKClassOverridesNSObjectMethod(cls, @selector(valueForKey:)) ||
        SPKClassOverridesNSObjectMethod(cls, @selector(valueForUndefinedKey:)))
        return YES;

    NSString *capitalized = [[key substringToIndex:1].uppercaseString stringByAppendingString:[key substringFromIndex:1]];
    // Simple accessors, in Foundation's search order.
    for (NSString *name in @[ [@"get" stringByAppendingString:capitalized], key,
                              [@"is" stringByAppendingString:capitalized], [@"_" stringByAppendingString:key] ]) {
        if ([target respondsToSelector:NSSelectorFromString(name)])
            return YES;
    }
    // Collection proxies: countOf<Key> is required by both the array and the set pattern.
    if ([target respondsToSelector:NSSelectorFromString([@"countOf" stringByAppendingString:capitalized])])
        return YES;
    // Direct instance variable access.
    if ([cls respondsToSelector:@selector(accessInstanceVariablesDirectly)] && [cls accessInstanceVariablesDirectly]) {
        for (NSString *name in @[ [@"_" stringByAppendingString:key], [@"_is" stringByAppendingString:capitalized],
                                  key, [@"is" stringByAppendingString:capitalized] ]) {
            Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
            if (!ivar)
                continue;
            // KVC can only box an ivar whose type it can read. Swift stored properties of
            // non-ObjC types (structs, enums, generics) carry an empty encoding, and KVC
            // treats them as undefined and throws, so they count as a miss.
            const char *encoding = ivar_getTypeEncoding(ivar);
            return encoding && encoding[0] != '\0';
        }
    }
    return NO;
}

BOOL SPKKVCKeyIsResolvable(id target, NSString *key) {
    if (!target || key.length == 0)
        return NO;
    Class cls = object_getClass(target);
    if (!cls)
        return NO;
    // The answer depends only on the class and the key, and the same few classes are
    // probed with the same keys over and over, so it is cached. Model objects are read
    // off the main thread too, hence the lock.
    static NSMutableDictionary<NSString *, NSNumber *> *cache;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    NSString *cacheKey = [NSString stringWithFormat:@"%p|%@", (__bridge void *)cls, key];
    os_unfair_lock_lock(&lock);
    if (!cache)
        cache = [NSMutableDictionary dictionary];
    NSNumber *cached = cache[cacheKey];
    os_unfair_lock_unlock(&lock);
    if (cached)
        return cached.boolValue;

    BOOL resolvable = SPKKVCKeyIsResolvableUncached(target, cls, key);
    os_unfair_lock_lock(&lock);
    if (cache.count > 4096)
        [cache removeAllObjects];
    cache[cacheKey] = @(resolvable);
    os_unfair_lock_unlock(&lock);
    return resolvable;
}

id SPKKVCObject(id target, NSString *key) {
    if (!SPKKVCKeyIsResolvable(target, key))
        return nil;

    @try {
        return [target valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

NSArray *SPKArrayFromCollection(id collection) {
    if (!collection ||
        [collection isKindOfClass:[NSDictionary class]] ||
        [collection isKindOfClass:[NSString class]] ||
        [collection isKindOfClass:[NSURL class]]) {
        return nil;
    }

    if ([collection isKindOfClass:[NSArray class]]) {
        return collection;
    }

    if ([collection isKindOfClass:[NSOrderedSet class]]) {
        return [(NSOrderedSet *)collection array];
    }

    if ([collection isKindOfClass:[NSSet class]]) {
        return [(NSSet *)collection allObjects];
    }

    if ([collection conformsToProtocol:@protocol(NSFastEnumeration)]) {
        NSMutableArray *array = [NSMutableArray array];
        for (id item in collection) {
            [array addObject:item];
        }
        return array;
    }

    return nil;
}

NSURL *SPKURLFromValue(id value) {
    if (!value)
        return nil;

    if ([value isKindOfClass:[NSURL class]]) {
        return value;
    }

    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)value;
        if (string.length == 0)
            return nil;
        return [NSURL URLWithString:string];
    }

    return nil;
}

NSString *SPKStringFromValue(id value) {
    if ([value isKindOfClass:[NSString class]])
        return value;
    if ([value respondsToSelector:@selector(stringValue)])
        return [value stringValue];
    return nil;
}

id SPKSundialCellMedia(id cell) {
    if (!cell)
        return nil;

    // IG 452 rewrote IGSundialViewerVideoCell in Swift: the stored property's ivar
    // lost its leading underscore and, like every Swift ivar, has no type encoding.
    // The carousel cell is still Objective-C and keeps the old name.
    Class mediaClass = NSClassFromString(@"IGMedia");
    static const char *const names[] = {"_mediaPassthrough", "mediaPassthrough"};
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        Ivar ivar = class_getInstanceVariable(object_getClass(cell), names[i]);
        if (!ivar)
            continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (type && type[0] != '\0' && type[0] != '@')
            continue;
        id media = object_getIvar(cell, ivar);
        if (media && (!mediaClass || [media isKindOfClass:mediaClass]))
            return media;
    }
    return nil;
}

NSString *SPKClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"(nil)";
}

static NSString *SPKShallowUsernameFromObject(id object);

static void SPKDMTrace(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    SPKLog(@"DMTrace", @"%@", message ?: @"(nil)");
}

static BOOL SPKRelationNameLooksRelevant(NSString *name) {
    if (name.length == 0)
        return NO;
    NSString *lower = name.lowercaseString;
    for (NSString *token in @[ @"user", @"sender", @"author", @"owner", @"participant", @"thread", @"message", @"item", @"media" ]) {
        if ([lower containsString:token])
            return YES;
    }
    return NO;
}

static BOOL SPKAppendUniqueObject(NSMutableArray<NSDictionary *> *queue,
                                  NSMutableSet<NSValue *> *seen,
                                  id object,
                                  NSString *path,
                                  NSUInteger depth) {
    if (!object)
        return NO;
    if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]] || [object isKindOfClass:[NSURL class]] || [object isKindOfClass:[NSDate class]]) {
        return NO;
    }
    NSValue *key = [NSValue valueWithNonretainedObject:object];
    if ([seen containsObject:key])
        return NO;
    [seen addObject:key];
    [queue addObject:@{
        @"obj" : object,
        @"path" : path ?: @"(unknown)",
        @"depth" : @(depth)
    }];
    return YES;
}

static NSArray<NSString *> *SPKUsernameTraversalKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"user", @"owner", @"author", @"sender", @"senderUser", @"fromUser", @"messageUser",
            @"participantUser", @"participants", @"threadUser", @"threadUsers", @"thread",
            @"otherUser", @"recipientUser", @"peerUser", @"opponentUser", @"targetUser",
            @"message", @"messageItem", @"directMessage", @"visualMessage", @"media", @"item",
            @"items", @"mediaItems", @"storyItem", @"reelShare", @"xmaMediaShareItem",
            @"parentMessage", @"currentMessage"
        ];
    });
    return keys;
}

static BOOL SPKPathLooksLikeSessionPath(NSString *path) {
    if (path.length == 0)
        return NO;
    NSString *lower = path.lowercaseString;
    return ([lower containsString:@"usersession"] ||
            [lower containsString:@"_usersession"] ||
            [lower containsString:@"->session"] ||
            [lower containsString:@".session"]);
}

static NSString *SPKUsernameFromObjectGraph(id root,
                                            NSUInteger maxDepth,
                                            NSString *usernameToAvoid,
                                            NSString *__autoreleasing *outPath) {
    if (!root)
        return nil;

    NSMutableArray<NSDictionary *> *queue = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    SPKAppendUniqueObject(queue, seen, root, @"root", 0);

    NSUInteger processed = 0;
    const NSUInteger kMaxNodes = 220;

    while (queue.count > 0 && processed < kMaxNodes) {
        NSDictionary *node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        processed++;

        id object = node[@"obj"];
        NSString *path = node[@"path"];
        NSUInteger depth = [node[@"depth"] unsignedIntegerValue];

        NSString *username = SPKShallowUsernameFromObject(object);
        if (username.length > 0) {
            BOOL isAvoided = (usernameToAvoid.length > 0 &&
                              [username caseInsensitiveCompare:usernameToAvoid] == NSOrderedSame);
            BOOL isSessionPath = SPKPathLooksLikeSessionPath(path);
            if (!isAvoided && !isSessionPath) {
                if (outPath)
                    *outPath = path;
                return username;
            }
        }
        if (depth >= maxDepth)
            continue;

        for (NSString *key in SPKUsernameTraversalKeys()) {
            id child = SPKObjectForSelector(object, key);
            if (!child)
                child = SPKKVCObject(object, key);
            if (!child)
                continue;

            NSArray *array = SPKArrayFromCollection(child);
            if (array) {
                NSUInteger index = 0;
                for (id item in array) {
                    SPKAppendUniqueObject(queue, seen, item, [NSString stringWithFormat:@"%@.%@[%lu]", path, key, (unsigned long)index], depth + 1);
                    index++;
                }
                continue;
            }

            SPKAppendUniqueObject(queue, seen, child, [NSString stringWithFormat:@"%@.%@", path, key], depth + 1);
        }

        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList([object class], &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            Ivar ivar = ivars[i];
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@')
                continue;

            const char *rawName = ivar_getName(ivar);
            if (!rawName)
                continue;
            NSString *name = [NSString stringWithUTF8String:rawName];
            if (!SPKRelationNameLooksRelevant(name))
                continue;

            id child = object_getIvar(object, ivar);
            if (!child)
                continue;
            SPKAppendUniqueObject(queue, seen, child, [NSString stringWithFormat:@"%@->%@", path, name], depth + 1);
        }
        free(ivars);
    }

    return nil;
}

static NSString *SPKUsernameFromUserObject(id user) {
    if (!user)
        return nil;

    id username = SPKObjectForSelector(user, @"username");
    if (!username) {
        username = SPKKVCObject(user, @"username");
    }
    if (!username) {
        username = SPKObjectForSelector(user, @"authorUsername");
    }
    if (!username) {
        username = SPKKVCObject(user, @"authorUsername");
    }
    if (!username) {
        username = SPKObjectForSelector(user, @"senderUsername");
    }
    if (!username) {
        username = SPKKVCObject(user, @"senderUsername");
    }

    if ([username isKindOfClass:[NSString class]] && [(NSString *)username length] > 0) {
        return (NSString *)username;
    }

    return nil;
}

NSString *SPKCaptionFromMediaObject(id media) {
    if (!media)
        return nil;

    for (NSString *selectorName in @[ @"fullCaptionString", @"captionString", @"caption", @"captionText", @"text" ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![media respondsToSelector:selector])
            continue;

        @try {
            id result = ((id (*)(id, SEL))objc_msgSend)(media, selector);
            if ([result isKindOfClass:[NSString class]] && [(NSString *)result length] > 0) {
                return result;
            }
            if (result && ![result isKindOfClass:[NSString class]]) {
                for (NSString *textSelectorName in @[ @"text", @"string", @"commentText", @"attributedString", @"rawText" ]) {
                    SEL textSelector = NSSelectorFromString(textSelectorName);
                    if (![result respondsToSelector:textSelector])
                        continue;

                    id text = ((id (*)(id, SEL))objc_msgSend)(result, textSelector);
                    if ([text respondsToSelector:@selector(string)] && ![text isKindOfClass:[NSString class]]) {
                        text = ((id (*)(id, SEL))objc_msgSend)(text, @selector(string));
                    }
                    if ([text isKindOfClass:[NSString class]] && [(NSString *)text length] > 0) {
                        return text;
                    }
                }
            }
        } @catch (__unused NSException *exception) {
        }
    }

    id capObj = SPKKVCObject(media, @"caption");
    if ([capObj isKindOfClass:[NSDictionary class]]) {
        id text = ((NSDictionary *)capObj)[@"text"];
        if ([text isKindOfClass:[NSString class]] && [(NSString *)text length] > 0) {
            return text;
        }
    } else if ([capObj isKindOfClass:[NSString class]] && [(NSString *)capObj length] > 0) {
        return capObj;
    }

    if (capObj && [capObj respondsToSelector:@selector(text)]) {
        @try {
            id text = ((id (*)(id, SEL))objc_msgSend)(capObj, @selector(text));
            if ([text isKindOfClass:[NSString class]] && [(NSString *)text length] > 0) {
                return text;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    return nil;
}

static NSString *SPKShallowUsernameFromObject(id object) {
    if (!object)
        return nil;

    for (NSString *stringSelector in @[
             @"username",
             @"sourceUsername",
             @"authorUsername",
             @"senderUsername",
             @"ownerUsername"
         ]) {
        id value = SPKObjectForSelector(object, stringSelector);
        if (!value)
            value = SPKKVCObject(object, stringSelector);
        NSString *s = SPKStringFromValue(value);
        if (s.length > 0)
            return s;
    }

    for (NSString *userSelector in @[
             @"user",
             @"owner",
             @"author",
             @"sender",
             @"senderUser",
             @"messageUser",
             @"userObject",
             @"threadUser",
             @"participantUser"
         ]) {
        id userObject = SPKObjectForSelector(object, userSelector);
        if (!userObject)
            userObject = SPKKVCObject(object, userSelector);
        NSString *username = SPKUsernameFromUserObject(userObject);
        if (username.length > 0)
            return username;
    }

    return nil;
}

NSString *SPKSessionUsernameFromController(UIViewController *controller) {
    if (!controller)
        return nil;

    id dataSource = [SPKUtils getIvarForObj:controller name:"_dataSource"];
    if (!dataSource)
        dataSource = SPKKVCObject(controller, @"dataSource");

    id userSession = [SPKUtils getIvarForObj:controller name:"_userSession"];
    if (!userSession)
        userSession = SPKKVCObject(controller, @"userSession");
    if (!userSession && dataSource) {
        userSession = [SPKUtils getIvarForObj:dataSource name:"_userSession"];
    }
    if (!userSession && dataSource) {
        userSession = SPKKVCObject(dataSource, @"userSession");
    }

    id user = SPKObjectForSelector(userSession, @"user");
    if (!user)
        user = SPKKVCObject(userSession, @"user");
    return SPKUsernameFromUserObject(user);
}

static NSArray<Class> *SPKClassesRespondingToClassSelector(NSString *selectorName) {
    if (selectorName.length == 0)
        return @[];

    static NSMutableDictionary<NSString *, id> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });

    id cached = cache[selectorName];
    if (cached) {
        return (cached == NSNull.null) ? @[] : (NSArray<Class> *)cached;
    }

    SEL selector = NSSelectorFromString(selectorName);
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) {
        cache[selectorName] = NSNull.null;
        return @[];
    }

    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    NSMutableArray<Class> *matches = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls)
            continue;
        if (class_respondsToSelector(object_getClass(cls), selector)) {
            [matches addObject:cls];
        }
    }
    free(classes);

    cache[selectorName] = matches.count > 0 ? [matches copy] : NSNull.null;
    return matches;
}

static NSString *SPKNonSessionUsernameFromUser(id user, NSString *sessionUsername) {
    NSString *username = SPKUsernameFromUserObject(user);
    if (username.length == 0)
        return nil;
    if (sessionUsername.length > 0 && [username caseInsensitiveCompare:sessionUsername] == NSOrderedSame) {
        return nil;
    }
    return username;
}

static NSString *SPKPKStringFromValue(id value) {
    if (!value)
        return nil;
    NSString *string = SPKStringFromValue(value);
    if (string.length > 0)
        return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([value respondsToSelector:@selector(integerValue)]) {
        return [NSString stringWithFormat:@"%lld", (long long)[value integerValue]];
    }
    return nil;
}

static BOOL SPKIsAllDigits(NSString *value) {
    if (value.length == 0)
        return NO;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [value rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

static NSString *SPKNormalizedNumericString(NSString *value) {
    if (value.length == 0)
        return nil;
    NSUInteger index = 0;
    while (index + 1 < value.length && [value characterAtIndex:index] == '0') {
        index++;
    }
    return [value substringFromIndex:index];
}

static BOOL SPKPKStringsEqual(NSString *lhs, NSString *rhs) {
    if (lhs.length == 0 || rhs.length == 0)
        return NO;
    lhs = [lhs stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    rhs = [rhs stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (SPKIsAllDigits(lhs) && SPKIsAllDigits(rhs)) {
        return [SPKNormalizedNumericString(lhs) isEqualToString:SPKNormalizedNumericString(rhs)];
    }
    return [lhs caseInsensitiveCompare:rhs] == NSOrderedSame;
}

static NSString *SPKUserPKStringFromObject(id object) {
    if (!object)
        return nil;
    for (NSString *key in @[
             @"pk", @"PK", @"userPk", @"userPK", @"userId", @"userID", @"id", @"identifier",
             @"senderPk", @"senderPK", @"authorPk", @"authorPK", @"participantPk", @"participantPK"
         ]) {
        id value = SPKObjectForSelector(object, key);
        if (!value)
            value = SPKKVCObject(object, key);
        NSString *pk = SPKPKStringFromValue(value);
        if (pk.length > 0)
            return pk;
    }
    return nil;
}

static NSString *SPKUsernameForSenderPKInObjectGraph(id root, NSString *senderPk, NSString *sessionUsername, NSString *__autoreleasing *outPath) {
    if (!root || senderPk.length == 0)
        return nil;

    NSMutableArray<NSDictionary *> *queue = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    SPKAppendUniqueObject(queue, seen, root, @"root", 0);

    NSUInteger processed = 0;
    const NSUInteger kMaxNodes = 260;

    static NSArray<NSString *> *traversalKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        traversalKeys = @[
            @"user", @"owner", @"author", @"sender", @"senderUser", @"fromUser", @"messageUser",
            @"participantUser", @"participants", @"threadUser", @"threadUsers", @"thread",
            @"otherUser", @"recipientUser", @"peerUser", @"opponentUser", @"targetUser",
            @"users", @"members", @"recipients", @"recipient", @"recipientUsers",
            @"message", @"messageItem", @"directMessage", @"visualMessage", @"media", @"item",
            @"items", @"mediaItems", @"metadata", @"currentMessage", @"parentMessage"
        ];
    });

    while (queue.count > 0 && processed < kMaxNodes) {
        NSDictionary *node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        processed++;

        id object = node[@"obj"];
        NSString *path = node[@"path"];
        NSUInteger depth = [node[@"depth"] unsignedIntegerValue];

        NSString *objectPk = SPKUserPKStringFromObject(object);
        if (SPKPKStringsEqual(senderPk, objectPk)) {
            NSString *username = SPKUsernameFromUserObject(object);
            if (username.length > 0 &&
                (sessionUsername.length == 0 || [username caseInsensitiveCompare:sessionUsername] != NSOrderedSame)) {
                if (outPath)
                    *outPath = path;
                return username;
            }
        }

        if (depth >= 7)
            continue;

        for (NSString *key in traversalKeys) {
            id child = SPKObjectForSelector(object, key);
            if (!child)
                child = SPKKVCObject(object, key);
            if (!child)
                continue;

            NSArray *array = SPKArrayFromCollection(child);
            if (array) {
                NSUInteger index = 0;
                for (id item in array) {
                    SPKAppendUniqueObject(queue, seen, item, [NSString stringWithFormat:@"%@.%@[%lu]", path, key, (unsigned long)index], depth + 1);
                    index++;
                }
                continue;
            }

            SPKAppendUniqueObject(queue, seen, child, [NSString stringWithFormat:@"%@.%@", path, key], depth + 1);
        }

        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList([object class], &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            Ivar ivar = ivars[i];
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@')
                continue;

            const char *rawName = ivar_getName(ivar);
            if (!rawName)
                continue;
            NSString *name = [NSString stringWithUTF8String:rawName];
            if (!SPKRelationNameLooksRelevant(name))
                continue;

            id child = object_getIvar(object, ivar);
            if (!child)
                continue;
            SPKAppendUniqueObject(queue, seen, child, [NSString stringWithFormat:@"%@->%@", path, name], depth + 1);
        }
        free(ivars);
    }

    return nil;
}

static NSString *SPKDirectSenderPKFromMessage(id message) {
    if (!message)
        return nil;

    NSMutableArray *candidates = [NSMutableArray arrayWithObject:message];
    id envelope = SPKObjectForSelector(message, @"message");
    if (!envelope)
        envelope = SPKKVCObject(message, @"message");
    if (envelope)
        [candidates addObject:envelope];

    id metadata = SPKObjectForSelector(envelope ?: message, @"metadata");
    if (!metadata)
        metadata = SPKKVCObject(envelope ?: message, @"metadata");
    if (metadata)
        [candidates addObject:metadata];

    for (id candidate in candidates) {
        for (NSString *key in @[ @"senderPk", @"senderPK", @"senderId", @"senderID", @"authorPk", @"authorPK", @"userPk", @"userPK" ]) {
            id value = SPKObjectForSelector(candidate, key);
            if (!value)
                value = SPKKVCObject(candidate, key);
            NSString *pk = SPKPKStringFromValue(value);
            if (pk.length > 0) {
                SPKDMTrace(@"senderPk resolved from %@.%@ = %@", SPKClassName(candidate), key, pk);
                return pk;
            }
        }
    }

    SPKDMTrace(@"senderPk not found on currentMessage/message.metadata");
    return nil;
}

static id SPKDirectCacheFromController(UIViewController *controller) {
    if (!controller)
        return nil;

    id dataSource = [SPKUtils getIvarForObj:controller name:"_dataSource"];
    if (!dataSource)
        dataSource = SPKKVCObject(controller, @"dataSource");

    for (id root in @[ dataSource ?: (id)NSNull.null, controller ?: (id)NSNull.null ]) {
        if (!root || root == (id)NSNull.null)
            continue;

        for (NSString *key in @[ @"directCache", @"_directCache" ]) {
            id cache = SPKObjectForSelector(root, key);
            if (!cache)
                cache = SPKKVCObject(root, key);
            if (!cache && [key hasPrefix:@"_"]) {
                cache = [SPKUtils getIvarForObj:root name:key.UTF8String];
            }
            if (cache) {
                SPKDMTrace(@"resolved directCache from %@.%@", SPKClassName(root), key);
                return cache;
            }
        }
    }

    return nil;
}

static id SPKDirectCacheUpdatesApplicatorFromController(UIViewController *controller) {
    if (!controller)
        return nil;

    id dataSource = [SPKUtils getIvarForObj:controller name:"_dataSource"];
    if (!dataSource)
        dataSource = SPKKVCObject(controller, @"dataSource");

    for (id root in @[ dataSource ?: (id)NSNull.null, controller ?: (id)NSNull.null ]) {
        if (!root || root == (id)NSNull.null)
            continue;

        for (NSString *key in @[ @"directCacheUpdatesApplicator", @"cacheUpdatesApplicator", @"_directCacheUpdatesApplicator" ]) {
            id value = SPKObjectForSelector(root, key);
            if (!value)
                value = SPKKVCObject(root, key);
            if (!value && [key hasPrefix:@"_"]) {
                value = [SPKUtils getIvarForObj:root name:key.UTF8String];
            }
            if (value) {
                SPKDMTrace(@"resolved directCacheUpdatesApplicator from %@.%@", SPKClassName(root), key);
                return value;
            }
        }
    }

    return nil;
}

static NSString *SPKDirectUsernameFromSenderPK(UIViewController *controller, id message, NSString *sessionUsername) {
    NSString *senderPk = SPKDirectSenderPKFromMessage(message);
    if (senderPk.length == 0)
        return nil;

    id envelope = SPKObjectForSelector(message, @"message");
    if (!envelope)
        envelope = SPKKVCObject(message, @"message");
    NSArray *messageCandidates = envelope && envelope != message ? @[ message, envelope ] : @[ message ];

    id directCache = SPKDirectCacheFromController(controller);
    id applicator = SPKDirectCacheUpdatesApplicatorFromController(controller);

    id dataSource = [SPKUtils getIvarForObj:controller name:"_dataSource"];
    if (!dataSource)
        dataSource = SPKKVCObject(controller, @"dataSource");

    for (id root in @[ message ?: (id)NSNull.null, dataSource ?: (id)NSNull.null, directCache ?: (id)NSNull.null, applicator ?: (id)NSNull.null, controller ?: (id)NSNull.null ]) {
        if (!root || root == (id)NSNull.null)
            continue;
        NSString *path = nil;
        NSString *u = SPKUsernameForSenderPKInObjectGraph(root, senderPk, sessionUsername, &path);
        if (u.length > 0) {
            SPKDMTrace(@"username from senderPk graph on %@ path=%@: %@", SPKClassName(root), path ?: @"(unknown)", u);
            return u;
        }
    }

    NSNumber *senderPkNumber = nil;
    if (senderPk.length > 0 && [senderPk rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) {
        senderPkNumber = @([senderPk longLongValue]);
    }
    NSArray *pkCandidates = senderPkNumber ? @[ senderPk, senderPkNumber ] : @[ senderPk ];

    for (Class cls in SPKClassesRespondingToClassSelector(@"userFromCurrentSessionDirectCacheWithPK:")) {
        SEL sel = NSSelectorFromString(@"userFromCurrentSessionDirectCacheWithPK:");
        for (id pkValue in pkCandidates) {
            id user = ((id (*)(id, SEL, id))objc_msgSend)(cls, sel, pkValue);
            NSString *u = SPKNonSessionUsernameFromUser(user, sessionUsername);
            if (u.length > 0) {
                SPKDMTrace(@"username from %@ userFromCurrentSessionDirectCacheWithPK:(%@): %@", NSStringFromClass(cls), SPKClassName(pkValue), u);
                return u;
            }
        }
    }

    if (directCache) {
        for (Class cls in SPKClassesRespondingToClassSelector(@"userFromPK:inDirectCache:")) {
            SEL sel = NSSelectorFromString(@"userFromPK:inDirectCache:");
            for (id pkValue in pkCandidates) {
                id user = ((id (*)(id, SEL, id, id))objc_msgSend)(cls, sel, pkValue, directCache);
                NSString *u = SPKNonSessionUsernameFromUser(user, sessionUsername);
                if (u.length > 0) {
                    SPKDMTrace(@"username from %@ userFromPK:inDirectCache:(%@): %@", NSStringFromClass(cls), SPKClassName(pkValue), u);
                    return u;
                }
            }
        }
    }

    if (applicator) {
        for (Class cls in SPKClassesRespondingToClassSelector(@"userFromPK:fromDirectCacheUpdatesApplicator:")) {
            SEL sel = NSSelectorFromString(@"userFromPK:fromDirectCacheUpdatesApplicator:");
            for (id pkValue in pkCandidates) {
                id user = ((id (*)(id, SEL, id, id))objc_msgSend)(cls, sel, pkValue, applicator);
                NSString *u = SPKNonSessionUsernameFromUser(user, sessionUsername);
                if (u.length > 0) {
                    SPKDMTrace(@"username from %@ userFromPK:fromDirectCacheUpdatesApplicator:(%@): %@", NSStringFromClass(cls), SPKClassName(pkValue), u);
                    return u;
                }
            }
        }
    }

    if (directCache) {
        for (Class cls in SPKClassesRespondingToClassSelector(@"senderFromMessage:directCache:")) {
            SEL sel = NSSelectorFromString(@"senderFromMessage:directCache:");
            for (id messageCandidate in messageCandidates) {
                id user = ((id (*)(id, SEL, id, id))objc_msgSend)(cls, sel, messageCandidate, directCache);
                NSString *u = SPKNonSessionUsernameFromUser(user, sessionUsername);
                if (u.length > 0) {
                    SPKDMTrace(@"username from %@ senderFromMessage:directCache: %@", NSStringFromClass(cls), u);
                    return u;
                }
            }
        }
    }

    if (applicator) {
        for (Class cls in SPKClassesRespondingToClassSelector(@"senderFromMessage:directCacheUpdatesApplicator:")) {
            SEL sel = NSSelectorFromString(@"senderFromMessage:directCacheUpdatesApplicator:");
            for (id messageCandidate in messageCandidates) {
                id user = ((id (*)(id, SEL, id, id))objc_msgSend)(cls, sel, messageCandidate, applicator);
                NSString *u = SPKNonSessionUsernameFromUser(user, sessionUsername);
                if (u.length > 0) {
                    SPKDMTrace(@"username from %@ senderFromMessage:directCacheUpdatesApplicator: %@", NSStringFromClass(cls), u);
                    return u;
                }
            }
        }
    }

    for (NSString *selectorName in @[ @"userFromPK:", @"userFromPk:", @"userForPK:", @"userForPk:", @"userWithPK:", @"userWithPk:", @"userForUserID:", @"userForUserId:", @"userForID:", @"userForId:" ]) {
        SEL sel = NSSelectorFromString(selectorName);
        if (directCache && [directCache respondsToSelector:sel]) {
            for (id pkValue in pkCandidates) {
                id user = ((id (*)(id, SEL, id))objc_msgSend)(directCache, sel, pkValue);
                NSString *u = SPKNonSessionUsernameFromUser(user, sessionUsername);
                if (u.length > 0) {
                    SPKDMTrace(@"username from directCache %@ (%@): %@", selectorName, SPKClassName(pkValue), u);
                    return u;
                }
            }
        }
        if (applicator && [applicator respondsToSelector:sel]) {
            for (id pkValue in pkCandidates) {
                id user = ((id (*)(id, SEL, id))objc_msgSend)(applicator, sel, pkValue);
                NSString *u = SPKNonSessionUsernameFromUser(user, sessionUsername);
                if (u.length > 0) {
                    SPKDMTrace(@"username from directCacheUpdatesApplicator %@ (%@): %@", selectorName, SPKClassName(pkValue), u);
                    return u;
                }
            }
        }
    }

    SPKDMTrace(@"senderPk fallback could not resolve a non-session username");
    return nil;
}

NSString *SPKUsernameFromMediaObject(id media) {
    if (!media)
        return nil;

    NSString *username = SPKShallowUsernameFromObject(media);
    if (username.length > 0)
        return username;

    for (NSString *nestedSelector in @[
             @"media",
             @"item",
             @"message",
             @"visualMessage",
             @"storyItem",
             @"reelShare",
             @"xmaMediaShareItem",
             @"currentMessage",
             @"parentMessage"
         ]) {
        id nested = SPKObjectForSelector(media, nestedSelector);
        if (!nested)
            nested = SPKKVCObject(media, nestedSelector);
        if (!nested || nested == media)
            continue;

        username = SPKShallowUsernameFromObject(nested);
        if (username.length > 0)
            return username;

        NSArray *nestedItems = SPKArrayFromCollection(nested);
        for (id nestedItem in nestedItems) {
            if (!nestedItem || nestedItem == media)
                continue;
            username = SPKShallowUsernameFromObject(nestedItem);
            if (username.length > 0)
                return username;
        }
    }

    return nil;
}

// The inbox visual-message viewer (IGDirectVisualMessageViewerController) tracks the
// current item as `_currentVisualMessageIndex` ON THE CONTROLLER, with the ordered
// item list on `_dataSource.visualMessages`. The generic data-source paths used for
// the thread viewer don't apply, so resolve this viewer explicitly — otherwise the
// current item stays frozen at index 0 as the user swipes.
static BOOL SPKIsDirectVisualMessageViewer(UIViewController *controller) {
    Class cls = NSClassFromString(@"IGDirectVisualMessageViewerController");
    return cls && [controller isKindOfClass:cls];
}

static NSArray *SPKDirectVisualViewerMessages(UIViewController *controller) {
    id dataSource = [SPKUtils getIvarForObj:controller name:"_dataSource"];
    if (!dataSource)
        dataSource = SPKKVCObject(controller, @"dataSource");
    id value = SPKObjectForSelector(dataSource, @"visualMessages");
    if (!value)
        value = SPKKVCObject(dataSource, @"visualMessages");
    NSArray *messages = SPKArrayFromCollection(value);
    return messages.count > 0 ? messages : nil;
}

// Returns the `_currentVisualMessageIndex` (a primitive long long ivar), or -1 when
// unset. The controller uses a max-value "not set" sentinel during transitions;
// treat that (and negatives) as unknown so callers don't index past the end.
static NSInteger SPKDirectVisualViewerIndex(UIViewController *controller) {
    Ivar idxIvar = class_getInstanceVariable([controller class], "_currentVisualMessageIndex");
    if (!idxIvar)
        return -1;
    ptrdiff_t offset = ivar_getOffset(idxIvar);
    long long idx = *(long long *)((char *)(__bridge void *)controller + offset);
    if (idx < 0 || idx == (long long)NSIntegerMax)
        return -1;
    return (NSInteger)idx;
}

id SPKDirectCurrentMessageFromController(UIViewController *controller) {
    if (!controller)
        return nil;

    // The aggregated media viewer (camera-roll / permanent chat media) exposes the
    // current item as `_mediaDisplayedInUI` (IGDirectAggregatedMedia). It carries a
    // `senderId`, which the senderPk → username machinery below resolves against the
    // session's direct cache.
    if ([controller isKindOfClass:NSClassFromString(@"IGDirectAggregatedMediaViewerViewController")]) {
        id media = [SPKUtils getIvarForObj:controller name:"_mediaDisplayedInUI"];
        if (!media)
            media = SPKObjectForSelector(controller, @"mediaDisplayedInUI");
        if (media)
            return media;
    }

    if (SPKIsDirectVisualMessageViewer(controller)) {
        NSArray *messages = SPKDirectVisualViewerMessages(controller);
        if (messages.count > 0) {
            NSInteger idx = SPKDirectVisualViewerIndex(controller);
            if (idx < 0)
                idx = 0;
            if ((NSUInteger)idx >= messages.count)
                idx = (NSInteger)messages.count - 1;
            id current = messages[idx];
            SPKDMTrace(@"visual viewer current message idx=%ld/%lu class=%@", (long)idx, (unsigned long)messages.count, SPKClassName(current));
            return current;
        }
    }

    id dataSource = [SPKUtils getIvarForObj:controller name:"_dataSource"];
    if (!dataSource)
        dataSource = SPKKVCObject(controller, @"dataSource");

    id message = [SPKUtils getIvarForObj:dataSource name:"_currentMessage"];
    if (!message)
        message = SPKKVCObject(dataSource, @"currentMessage");

    return message;
}

static NSArray *SPKItemsFromMediaContainer(id media) {
    if (!media)
        return nil;

    NSArray *items = SPKArrayFromCollection(SPKObjectForSelector(media, @"items"));
    if (items.count == 0) {
        items = SPKArrayFromCollection(SPKKVCObject(media, @"items"));
    }
    return items.count > 0 ? items : nil;
}

id SPKDirectResolvedMediaFromController(UIViewController *controller) {
    id message = SPKDirectCurrentMessageFromController(controller);
    SPKDMTrace(@"resolved currentMessage class=%@", SPKClassName(message));
    if (!message)
        return nil;

    if (SPKItemsFromMediaContainer(message).count > 0) {
        SPKDMTrace(@"using currentMessage as media container (items=%lu)", (unsigned long)SPKItemsFromMediaContainer(message).count);
        return message;
    }

    for (NSString *nestedKey in @[ @"media", @"visualMessage", @"item" ]) {
        id nested = SPKObjectForSelector(message, nestedKey);
        if (!nested)
            nested = SPKKVCObject(message, nestedKey);
        if (!nested || nested == message)
            continue;

        if (SPKItemsFromMediaContainer(nested).count > 0) {
            SPKDMTrace(@"using nested %@ as media container class=%@ (items=%lu)", nestedKey, SPKClassName(nested), (unsigned long)SPKItemsFromMediaContainer(nested).count);
            return nested;
        }
    }

    SPKDMTrace(@"falling back to currentMessage without items");
    return message;
}

NSInteger SPKDirectCurrentIndexFromController(UIViewController *controller) {
    if (!controller)
        return 0;

    if (SPKIsDirectVisualMessageViewer(controller)) {
        NSInteger idx = SPKDirectVisualViewerIndex(controller);
        if (idx >= 0) {
            SPKDMTrace(@"visual viewer current index = %ld", (long)idx);
            return idx;
        }
    }

    id dataSource = [SPKUtils getIvarForObj:controller name:"_dataSource"];
    if (!dataSource)
        dataSource = SPKKVCObject(controller, @"dataSource");

    for (NSString *selectorName in @[ @"currentItemIndex", @"currentIndex", @"itemIndex" ]) {
        NSNumber *n = [SPKUtils numericValueForObj:dataSource selectorName:selectorName];
        if (n && n.integerValue >= 0) {
            SPKDMTrace(@"resolved current index via selector %@ = %ld", selectorName, (long)n.integerValue);
            return n.integerValue;
        }
    }

    for (NSString *key in @[ @"currentItemIndex", @"currentIndex", @"itemIndex" ]) {
        id v = SPKKVCObject(dataSource, key);
        if ([v respondsToSelector:@selector(integerValue)] && [v integerValue] >= 0) {
            SPKDMTrace(@"resolved current index via KVC %@ = %ld", key, (long)[v integerValue]);
            return [v integerValue];
        }
    }

    for (NSString *key in @[ @"_currentItemIndex", @"_currentIndex", @"_itemIndex" ]) {
        id v = [SPKUtils getIvarForObj:dataSource name:key.UTF8String];
        if ([v respondsToSelector:@selector(integerValue)] && [v integerValue] >= 0) {
            SPKDMTrace(@"resolved current index via ivar %@ = %ld", key, (long)[v integerValue]);
            return [v integerValue];
        }
    }

    SPKDMTrace(@"could not resolve current index; defaulting to 0");
    return 0;
}

NSString *SPKDirectUsernameFromController(UIViewController *controller) {
    id message = SPKDirectCurrentMessageFromController(controller);
    SPKDMTrace(@"resolving username from currentMessage class=%@", SPKClassName(message));
    NSString *sessionUsername = SPKSessionUsernameFromController(controller);
    if (sessionUsername.length > 0) {
        SPKDMTrace(@"current session username=%@", sessionUsername);
    }
    // Aggregated media viewer: the current item carries the true `senderId`. Resolve
    // it first — the generic object-graph scan below would otherwise pick an arbitrary
    // participant in a group thread (there's no single "other" user to fall back to).
    if ([controller isKindOfClass:NSClassFromString(@"IGDirectAggregatedMediaViewerViewController")]) {
        NSString *sender = SPKDirectUsernameFromSenderPK(controller, message, sessionUsername);
        if (sender.length > 0) {
            SPKDMTrace(@"aggregated viewer username via senderPk: %@", sender);
            return sender;
        }
    }

    NSString *username = SPKUsernameFromMediaObject(message);
    if (username.length > 0) {
        if (sessionUsername.length > 0 &&
            [username caseInsensitiveCompare:sessionUsername] == NSOrderedSame) {
            SPKDMTrace(@"username on currentMessage matched session user; continuing search");
        } else {
            SPKDMTrace(@"username found on currentMessage: %@", username);
            return username;
        }
    }

    NSArray *items = SPKItemsFromMediaContainer(message);
    SPKDMTrace(@"username fallback scanning items count=%lu", (unsigned long)items.count);
    for (id item in items) {
        SPKDMTrace(@"checking item class=%@", SPKClassName(item));
        username = SPKUsernameFromMediaObject(item);
        if (username.length > 0) {
            if (sessionUsername.length > 0 &&
                [username caseInsensitiveCompare:sessionUsername] == NSOrderedSame) {
                SPKDMTrace(@"username on item matched session user; continuing search");
            } else {
                SPKDMTrace(@"username found on item: %@", username);
                return username;
            }
        }

        for (NSString *nestedKey in @[ @"media", @"visualMessage", @"item" ]) {
            id nested = SPKObjectForSelector(item, nestedKey);
            if (!nested)
                nested = SPKKVCObject(item, nestedKey);
            username = SPKUsernameFromMediaObject(nested);
            if (username.length > 0) {
                if (sessionUsername.length > 0 &&
                    [username caseInsensitiveCompare:sessionUsername] == NSOrderedSame) {
                    SPKDMTrace(@"username on item.%@ matched session user; continuing search", nestedKey);
                } else {
                    SPKDMTrace(@"username found on item.%@: %@", nestedKey, username);
                    return username;
                }
            }
        }
    }

    id dataSource = [SPKUtils getIvarForObj:controller name:"_dataSource"];
    if (!dataSource)
        dataSource = SPKKVCObject(controller, @"dataSource");

    for (id root in @[ message ?: (id)NSNull.null, dataSource ?: (id)NSNull.null, controller ?: (id)NSNull.null ]) {
        if (!root || root == (id)NSNull.null)
            continue;
        NSString *foundPath = nil;
        NSUInteger depth = (root == controller) ? 4 : 6;
        username = SPKUsernameFromObjectGraph(root, depth, sessionUsername, &foundPath);
        if (username.length > 0) {
            SPKDMTrace(@"username found via graph on %@ path=%@: %@", SPKClassName(root), foundPath ?: @"(unknown)", username);
            return username;
        }
    }

    username = SPKDirectUsernameFromSenderPK(controller, message, sessionUsername);
    if (username.length > 0) {
        return username;
    }

    SPKDMTrace(@"username not found on currentMessage or any items");
    return nil;
}
