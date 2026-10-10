// car-splice: merge the facets and renditions of one compiled asset catalog
// into another, so an Icon Composer icon compiled on its own can be added to
// an app's existing Assets.car without decompiling and rebuilding it.
//
// usage: car-splice <base.car> <addition.car> <out.car>
//
// Keys are re-encoded into the base catalog's key format (attributes the base
// lacks must be zero in the addition). A facet identifier is a 16-bit hash of
// the asset name, so with thousands of names in the base a collision is likely;
// colliding identifiers are moved to a free one. Lookups go name -> facet key
// -> rendition, so only the keys need rewriting, plus the layer references that
// icon stack and icon group renditions embed as key token lists.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>

typedef struct { uint16_t identifier; uint16_t value; } SPKKeyToken;
typedef struct { uint32_t tag, version, count; uint32_t attrs[]; } SPKKeyFormat;

enum { SPKAttrAppearance = 7, SPKAttrIdentifier = 17 };

// Test switch: move every added facet, to prove nothing depends on the hash.
#ifndef SPK_REMAP_ALL
#define SPK_REMAP_ALL 0
#endif

@interface CUICommonAssetStorage : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (instancetype)initWithPath:(NSString *)path forWriting:(BOOL)writing;
- (NSArray<NSString *> *)allRenditionNames;
- (const SPKKeyToken *)renditionKeyForName:(const char *)name hotSpot:(CGPoint *)hotSpot;
- (const SPKKeyFormat *)keyFormat;
- (NSArray *)allAssetKeys;
- (NSData *)assetForKey:(NSData *)key;
- (NSDictionary<NSString *, NSNumber *> *)appearances;
- (BOOL)assetExistsForKey:(NSData *)key;
- (unsigned int)renditionCount;
@end

@interface CUIRenditionKey : NSObject
- (const SPKKeyToken *)keyList;
@end

@interface CUIMutableCommonAssetStorage : CUICommonAssetStorage
- (BOOL)setAsset:(NSData *)asset forKey:(NSData *)key;
- (void)setRenditionKey:(const SPKKeyToken *)key hotSpot:(CGPoint)hotSpot forName:(const char *)name;
- (void)setRenditionCount:(unsigned int)count;
- (BOOL)useBitmapIndex;
- (BOOL)updateBitmapInfo;
- (BOOL)writeToDiskAndCompact:(BOOL)compact;
@end

static int fail(NSString *message) {
    fprintf(stderr, "car-splice: %s\n", message.UTF8String);
    return 1;
}

static NSInteger formatIndex(const SPKKeyFormat *format, uint32_t attribute) {
    for (uint32_t i = 0; i < format->count; i++) {
        if (format->attrs[i] == attribute) return i;
    }
    return -1;
}

// Layer references are stored as { element, part, identifier } token triples.
// Rewrites the identifier of every triple that names a moved facet.
static NSData *retargetLayerReferences(NSData *asset, NSDictionary<NSNumber *, NSNumber *> *identifierMap) {
    enum { SPKAttrElement = 1, SPKAttrPart = 2 };
    NSMutableData *patched = nil;
    const uint8_t *bytes = asset.bytes;
    for (NSUInteger offset = 0; offset + 3 * sizeof(SPKKeyToken) <= asset.length; offset++) {
        SPKKeyToken triple[3];
        memcpy(triple, bytes + offset, sizeof(triple));
        if (triple[0].identifier != SPKAttrElement || triple[1].identifier != SPKAttrPart ||
            triple[2].identifier != SPKAttrIdentifier) continue;
        NSNumber *mapped = identifierMap[@(triple[2].value)];
        if (!mapped || mapped.unsignedShortValue == triple[2].value) continue;
        if (!patched) patched = [asset mutableCopy];
        uint16_t value = mapped.unsignedShortValue;
        [patched replaceBytesInRange:NSMakeRange(offset + 2 * sizeof(SPKKeyToken) + sizeof(uint16_t), sizeof(value)) withBytes:&value];
        offset += sizeof(triple) - 1;
    }
    return patched ?: asset;
}

static uint16_t facetIdentifier(const SPKKeyToken *tokens) {
    for (; tokens && tokens->identifier; tokens++) {
        if (tokens->identifier == SPKAttrIdentifier) return tokens->value;
    }
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 4) return fail(@"usage: car-splice <base.car> <addition.car> <out.car>");
        if (!dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW)) {
            return fail(@"cannot load CoreUI");
        }

        NSString *basePath = @(argv[1]), *additionPath = @(argv[2]), *outPath = @(argv[3]);
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:outPath error:nil];
        NSError *error = nil;
        if (![fm copyItemAtPath:basePath toPath:outPath error:&error]) return fail(error.localizedDescription);

        CUICommonAssetStorage *addition = [[NSClassFromString(@"CUICommonAssetStorage") alloc] initWithPath:additionPath];
        CUIMutableCommonAssetStorage *out = [[NSClassFromString(@"CUIMutableCommonAssetStorage") alloc] initWithPath:outPath forWriting:YES];
        if (!addition || !out) return fail(@"cannot open catalogs");

        // Appearance ids are per-catalog; translate through their names.
        NSDictionary<NSString *, NSNumber *> *addAppearances = addition.appearances, *outAppearances = out.appearances;
        NSMutableDictionary<NSNumber *, NSNumber *> *appearanceMap = [NSMutableDictionary dictionary];
        for (NSString *name in addAppearances) {
            NSNumber *target = outAppearances[name];
            if (!target) return fail([NSString stringWithFormat:@"base catalog lacks appearance %@", name]);
            appearanceMap[addAppearances[name]] = target;
        }

        NSMutableSet<NSNumber *> *usedIdentifiers = [NSMutableSet set];
        NSSet<NSString *> *baseNames = [NSSet setWithArray:out.allRenditionNames];
        for (NSString *name in baseNames) {
            [usedIdentifiers addObject:@(facetIdentifier([out renditionKeyForName:name.UTF8String hotSpot:NULL]))];
        }
        // Some renditions (packed atlases, for one) belong to no named facet.
        for (CUIRenditionKey *renditionKey in out.allAssetKeys) {
            [usedIdentifiers addObject:@(facetIdentifier(renditionKey.keyList))];
        }

        NSArray<NSString *> *names = addition.allRenditionNames;
        // Facets that keep their identifier claim it first, so a moved one cannot
        // be handed an identifier a later facet of the addition still needs.
        NSMutableDictionary<NSNumber *, NSNumber *> *identifierMap = [NSMutableDictionary dictionary];
        NSMutableOrderedSet<NSNumber *> *colliding = [NSMutableOrderedSet orderedSet];
        for (NSString *name in names) {
            if ([baseNames containsObject:name]) return fail([NSString stringWithFormat:@"name already in base: %@", name]);
            NSNumber *identifier = @(facetIdentifier([addition renditionKeyForName:name.UTF8String hotSpot:NULL]));
            if (identifierMap[identifier] || [colliding containsObject:identifier]) continue;
            if (SPK_REMAP_ALL || [usedIdentifiers containsObject:identifier]) {
                [colliding addObject:identifier];
            } else {
                identifierMap[identifier] = identifier;
                [usedIdentifiers addObject:identifier];
            }
        }
        uint32_t nextFree = 1;
        for (NSNumber *identifier in colliding) {
            while (nextFree <= UINT16_MAX && [usedIdentifiers containsObject:@(nextFree)]) nextFree++;
            if (nextFree > UINT16_MAX) return fail(@"no free facet identifier left in base");
            identifierMap[identifier] = @(nextFree);
            [usedIdentifiers addObject:@(nextFree)];
        }
        unsigned int moved = (unsigned int)colliding.count;

        for (NSString *name in names) {
            CGPoint hotSpot = CGPointZero;
            const SPKKeyToken *tokens = [addition renditionKeyForName:name.UTF8String hotSpot:&hotSpot];
            size_t count = 0;
            while (tokens[count].identifier) count++;
            SPKKeyToken copy[count + 1];
            memcpy(copy, tokens, sizeof(copy));
            for (size_t i = 0; i < count; i++) {
                if (copy[i].identifier == SPKAttrIdentifier) copy[i].value = identifierMap[@(copy[i].value)].unsignedShortValue;
            }
            [out setRenditionKey:copy hotSpot:hotSpot forName:name.UTF8String];
        }

        const SPKKeyFormat *addFormat = addition.keyFormat, *outFormat = out.keyFormat;
        unsigned int added = 0;
        for (CUIRenditionKey *renditionKey in addition.allAssetKeys) {
            uint16_t source[addFormat->count], target[outFormat->count];
            memset(source, 0, sizeof(source));
            memset(target, 0, sizeof(target));
            for (const SPKKeyToken *token = renditionKey.keyList; token->identifier; token++) {
                NSInteger sourceIndex = formatIndex(addFormat, token->identifier);
                NSInteger targetIndex = formatIndex(outFormat, token->identifier);
                if (sourceIndex >= 0) source[sourceIndex] = token->value;
                if (!token->value) continue;
                if (targetIndex < 0) {
                    return fail([NSString stringWithFormat:@"base key format lacks attribute %u", token->identifier]);
                }
                uint16_t value = token->value;
                if (token->identifier == SPKAttrAppearance) {
                    NSNumber *mapped = appearanceMap[@(value)];
                    if (!mapped) return fail([NSString stringWithFormat:@"unknown appearance id %u", value]);
                    value = mapped.unsignedShortValue;
                } else if (token->identifier == SPKAttrIdentifier) {
                    NSNumber *mapped = identifierMap[@(value)];
                    if (!mapped) return fail([NSString stringWithFormat:@"rendition with unknown facet identifier %u", value]);
                    value = mapped.unsignedShortValue;
                }
                target[targetIndex] = value;
            }
            NSData *value = [addition assetForKey:[NSData dataWithBytes:source length:sizeof(source)]];
            NSData *outKey = [NSData dataWithBytes:target length:sizeof(target)];
            if (!value) return fail(@"cannot read rendition from addition");
            if ([out assetExistsForKey:outKey]) return fail(@"rendition key already exists in base");
            if (moved) value = retargetLayerReferences(value, identifierMap);
            if (![out setAsset:value forKey:outKey]) return fail(@"setAsset:forKey: failed");
            added++;
        }

        [out setRenditionCount:out.renditionCount + added];
        if (out.useBitmapIndex && ![out updateBitmapInfo]) return fail(@"updateBitmapInfo failed");
        if (![out writeToDiskAndCompact:YES]) return fail(@"write failed");
        printf("spliced %lu facets (%u moved to a free identifier), %u renditions into %s\n",
               (unsigned long)names.count, moved, added, outPath.UTF8String);
    }
    return 0;
}
