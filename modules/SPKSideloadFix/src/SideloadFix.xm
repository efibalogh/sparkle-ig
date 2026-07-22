#import "Header.h"

static NSString * const SPKOriginalInstagramBundleIdentifier = @"com.burbn.instagram";

static BOOL SPKIsMainBundle(NSBundle *bundle) {
	return bundle != nil && bundle == [NSBundle mainBundle];
}

static void SPKLogBundleIdentitySpoofOnce(NSString *runtimeIdentifier) {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		SPKSideloadLog(@"Normalizing duplicate-app runtime bundle identity original=%@ runtime=%@",
			SPKOriginalInstagramBundleIdentifier,
			runtimeIdentifier.length > 0 ? runtimeIdentifier : @"unavailable");
	});
}

static NSURL *redirectedAppGroupURL(NSString *groupIdentifier) {
	if (![groupIdentifier hasPrefix:@"group"]) return nil;

	if (NSURL *appGroupURL = getAppGroupPathIfExists()) {
		return [appGroupURL URLByAppendingPathComponent:groupIdentifier];
	}

	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *documentsPath = [paths lastObject];
	if (!documentsPath) return nil;

	NSString *fakePath = [documentsPath stringByAppendingPathComponent:groupIdentifier];
	return [NSURL fileURLWithPath:fakePath];
}

%hook CKContainer
- (id)_setupWithContainerID:(id)a options:(id)b { return nil; }
- (id)_initWithContainerIdentifier:(id)a { return nil; }
%end

%hook CKEntitlements
- (id)initWithEntitlementsDict:(NSDictionary *)entitlements {
	NSMutableDictionary *mutEntitlements = [entitlements mutableCopy];
	[mutEntitlements removeObjectForKey:@"com.apple.developer.icloud-container-environment"];
	[mutEntitlements removeObjectForKey:@"com.apple.developer.icloud-services"];
	return %orig([mutEntitlements copy]);  // why? whatever
}
%end

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	if (NSURL *fakeAppGroupURL = redirectedAppGroupURL(groupIdentifier)) {
		createDirectoryIfNotExists(fakeAppGroupURL.path);
		return fakeAppGroupURL;
	}

	return %orig(groupIdentifier);
}
%end

static BOOL isAppExtensionProcess(void) {
	static BOOL cached = NO;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		cached = ([[NSBundle mainBundle] infoDictionary][@"NSExtension"] != nil);
	});
	return cached;
}

%hook NSUserDefaults
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
	if (!isAppExtensionProcess()) {
		return %orig(suiteName, container);
	}

	if (![suiteName hasPrefix:@"group"]) {
		return %orig(suiteName, container);
	}

	if (NSURL *customContainerURL = redirectedAppGroupURL(suiteName)) {
		createDirectoryIfNotExists(customContainerURL.path);
		SPKSideloadLog(@"Redirecting extension defaults suite=%@ to app group container", suiteName);
		return %orig(suiteName, customContainerURL);
	}

	SPKSideloadLog(@"Unable to construct app group container for suite=%@; using original container", suiteName);
	return %orig(suiteName, container);
}
%end

// Keep the install-time identifier on disk, but present Instagram's original
// identifier to code querying the main bundle. Restrict this to the main bundle
// so embedded frameworks and resources retain their real identities.
%hook NSBundle
- (NSString *)bundleIdentifier {
	NSString *runtimeIdentifier = %orig;
	if (SPKIsMainBundle(self) &&
		![runtimeIdentifier isEqualToString:SPKOriginalInstagramBundleIdentifier]) {
		SPKLogBundleIdentitySpoofOnce(runtimeIdentifier);
		return SPKOriginalInstagramBundleIdentifier;
	}
	return runtimeIdentifier;
}

- (id)objectForInfoDictionaryKey:(NSString *)key {
	id value = %orig(key);
	if (SPKIsMainBundle(self) &&
		[key isEqualToString:@"CFBundleIdentifier"] &&
		![value isEqual:SPKOriginalInstagramBundleIdentifier]) {
		SPKLogBundleIdentitySpoofOnce([value isKindOfClass:[NSString class]] ? value : nil);
		return SPKOriginalInstagramBundleIdentifier;
	}
	return value;
}
%end
