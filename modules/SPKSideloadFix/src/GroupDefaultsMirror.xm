#import <objc/runtime.h>

#import "Header.h"

// App extensions read Instagram's group defaults through the redirected shared
// container in SideloadFix.xm. The main app still writes to its original suites
// so Instagram's own main-process persistence keeps working. Mirror those writes
// into the redirected container as well, otherwise an extension can see stale or
// incomplete account state even though the account is signed in in the app.

@interface NSUserDefaults (SPKSideloadPrivate)
- (NSString *)_identifier;
- (instancetype)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
@end

static const void *kSPKMirroredDefaultsTagKey = &kSPKMirroredDefaultsTagKey;

static NSString *SPKRedactedDefaultsKey(NSString *key) {
	if (key.length == 0) return @"";

	NSMutableString *result = [NSMutableString string];
	NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
	NSUInteger index = 0;
	while (index < key.length) {
		NSUInteger runStart = index;
		while (index < key.length && [digits characterIsMember:[key characterAtIndex:index]]) index++;
		if (index > runStart) {
			NSUInteger runLength = index - runStart;
			[result appendString:runLength >= 5 ? @"<id>" : [key substringWithRange:NSMakeRange(runStart, runLength)]];
			continue;
		}
		[result appendFormat:@"%C", [key characterAtIndex:index]];
		index++;
	}
	return result;
}

static NSString *SPKDefaultsSuiteName(NSUserDefaults *defaults) {
	if (![defaults respondsToSelector:@selector(_identifier)]) return nil;
	id identifier = [defaults _identifier];
	return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

static NSUserDefaults *SPKMirroredDefaultsForSuite(NSString *suiteName) {
	static NSMutableDictionary<NSString *, NSUserDefaults *> *cache;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		cache = [NSMutableDictionary dictionary];
	});

	@synchronized(cache) {
		NSUserDefaults *existing = cache[suiteName];
		if (existing) return existing;

		NSURL *sharedRoot = getAppGroupPathIfExists();
		if (!sharedRoot) return nil;

		NSURL *container = [sharedRoot URLByAppendingPathComponent:suiteName isDirectory:YES];
		NSURL *preferences = [[container URLByAppendingPathComponent:@"Library" isDirectory:YES]
			URLByAppendingPathComponent:@"Preferences" isDirectory:YES];
		if (!createDirectoryIfNotExists(preferences.path)) return nil;

		NSUserDefaults *mirror = [[NSUserDefaults alloc] _initWithSuiteName:suiteName container:container];
		if (!mirror) return nil;

		objc_setAssociatedObject(mirror, kSPKMirroredDefaultsTagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		cache[suiteName] = mirror;
		SPKSideloadLog(@"Group defaults mirror active suite=%@", suiteName);
		return mirror;
	}
}

static NSUserDefaults *SPKMirrorTargetForDefaults(NSUserDefaults *defaults) {
	if (isAppExtensionProcess()) return nil;
	if (objc_getAssociatedObject(defaults, kSPKMirroredDefaultsTagKey)) return nil;

	NSString *suiteName = SPKDefaultsSuiteName(defaults);
	if (![suiteName hasPrefix:@"group"]) return nil;
	return SPKMirroredDefaultsForSuite(suiteName);
}

static void SPKLogMirroredKeyOnce(NSString *suiteName, NSString *key) {
	if (suiteName.length == 0 || key.length == 0) return;

	static NSMutableSet<NSString *> *loggedKeys;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		loggedKeys = [NSMutableSet set];
	});

	NSString *token = [NSString stringWithFormat:@"%@\n%@", suiteName, key];
	@synchronized(loggedKeys) {
		if (loggedKeys.count >= 256 || [loggedKeys containsObject:token]) return;
		[loggedKeys addObject:token];
	}
	SPKSideloadLog(@"Mirrored group defaults suite=%@ key=%@", suiteName, SPKRedactedDefaultsKey(key));
}

static void SPKLogExtensionMissOnce(NSUserDefaults *defaults, NSString *key) {
	if (!isAppExtensionProcess() || key.length == 0) return;

	NSString *suiteName = SPKDefaultsSuiteName(defaults);
	if (![suiteName hasPrefix:@"group"]) return;

	static NSMutableSet<NSString *> *loggedMisses;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		loggedMisses = [NSMutableSet set];
	});

	NSString *token = [NSString stringWithFormat:@"%@\n%@", suiteName, key];
	@synchronized(loggedMisses) {
		if (loggedMisses.count >= 256 || [loggedMisses containsObject:token]) return;
		[loggedMisses addObject:token];
	}
	// Key names are enough to diagnose an incomplete mirror. Never log values:
	// group defaults may contain account state and other private data.
	SPKSideloadLog(@"Extension group defaults miss suite=%@ key=%@", suiteName, SPKRedactedDefaultsKey(key));
}

%hook NSUserDefaults

- (id)objectForKey:(NSString *)key {
	id value = %orig;
	if (!value) SPKLogExtensionMissOnce(self, key);
	return value;
}

- (void)setObject:(id)value forKey:(NSString *)key {
	%orig;
	NSUserDefaults *target = SPKMirrorTargetForDefaults(self);
	if (!target) return;
	[target setObject:value forKey:key];
	SPKLogMirroredKeyOnce(SPKDefaultsSuiteName(self), key);
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
	%orig;
	NSUserDefaults *target = SPKMirrorTargetForDefaults(self);
	if (!target) return;
	[target setBool:value forKey:key];
	SPKLogMirroredKeyOnce(SPKDefaultsSuiteName(self), key);
}

- (void)setInteger:(NSInteger)value forKey:(NSString *)key {
	%orig;
	NSUserDefaults *target = SPKMirrorTargetForDefaults(self);
	if (!target) return;
	[target setInteger:value forKey:key];
	SPKLogMirroredKeyOnce(SPKDefaultsSuiteName(self), key);
}

- (void)setDouble:(double)value forKey:(NSString *)key {
	%orig;
	NSUserDefaults *target = SPKMirrorTargetForDefaults(self);
	if (!target) return;
	[target setDouble:value forKey:key];
	SPKLogMirroredKeyOnce(SPKDefaultsSuiteName(self), key);
}

- (void)setFloat:(float)value forKey:(NSString *)key {
	%orig;
	NSUserDefaults *target = SPKMirrorTargetForDefaults(self);
	if (!target) return;
	[target setFloat:value forKey:key];
	SPKLogMirroredKeyOnce(SPKDefaultsSuiteName(self), key);
}

- (void)setURL:(NSURL *)value forKey:(NSString *)key {
	%orig;
	NSUserDefaults *target = SPKMirrorTargetForDefaults(self);
	if (!target) return;
	[target setURL:value forKey:key];
	SPKLogMirroredKeyOnce(SPKDefaultsSuiteName(self), key);
}

- (void)removeObjectForKey:(NSString *)key {
	%orig;
	NSUserDefaults *target = SPKMirrorTargetForDefaults(self);
	if (!target) return;
	[target removeObjectForKey:key];
	SPKLogMirroredKeyOnce(SPKDefaultsSuiteName(self), key);
}

- (void)setValue:(id)value forKey:(NSString *)key {
	%orig;
	NSUserDefaults *target = SPKMirrorTargetForDefaults(self);
	if (!target) return;
	if (value) {
		[target setValue:value forKey:key];
	} else {
		[target removeObjectForKey:key];
	}
	SPKLogMirroredKeyOnce(SPKDefaultsSuiteName(self), key);
}

%end
