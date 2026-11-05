#import "SPKStrings.h"
#import "SPKGalleryCoreDataStack.h"
#import <objc/runtime.h>
#import "../../Utils.h"
#import "SPKGalleryPaths.h"

@interface SPKGalleryCoreDataStack ()
@property (nonatomic, strong, readwrite) NSPersistentContainer *persistentContainer;
@end

// Owns a throwaway copy of an archive store: deletes it when the reading context is gone.
@interface SPKGalleryScratchStore : NSObject
@property (nonatomic, copy) NSString *directory;
@end

@implementation SPKGalleryScratchStore
- (void)dealloc {
    if (self.directory.length > 0)
        [[NSFileManager defaultManager] removeItemAtPath:self.directory error:nil];
}
@end

static const void *SPKGalleryScratchStoreKey = &SPKGalleryScratchStoreKey;

static NSString *const kSPKGalleryEntityName = @"SPKGalleryFile";
// On-disk entity name used by stores created before the SCInsta -> Sparkle rename.
// Existing gallery.sqlite files carry this name; the Core Data migration below
// renames the entity to kSPKGalleryEntityName via renamingIdentifier.
static NSString *const kSPKGalleryLegacyEntityName = @"SCIGalleryFile";
static NSString *const kSPKGalleryStoreName = @"gallery.sqlite";

@implementation SPKGalleryCoreDataStack

+ (instancetype)shared {
    static SPKGalleryCoreDataStack *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SPKGalleryCoreDataStack alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupPersistentContainer];
    }
    return self;
}

- (NSManagedObjectModel *)buildModelWithAccountOwnership:(BOOL)includeAccountOwnership {
    return [self buildModelWithAccountOwnership:includeAccountOwnership
                                  includeAutoSave:YES
                                     entityName:kSPKGalleryEntityName
                                   renamingFrom:kSPKGalleryLegacyEntityName];
}

// `entityName` is the entity's on-disk name. `renamingIdentifier`, when non-nil,
// lets Core Data's inferred mapping match a store created under that older name
// (used to rename SCIGalleryFile -> SPKGalleryFile during migration).
//
// `includeAccountOwnership` and `includeAutoSave` exist so `migrateStoreAtURLIfNeeded:`
// can rebuild *historical* schemas as migration sources. Every attribute added over time
// needs a flag here: a source model that declares a column the on-disk store never had
// won't match its version hash, and the store silently falls through to "incompatible
// with all known schemas".
- (NSManagedObjectModel *)buildModelWithAccountOwnership:(BOOL)includeAccountOwnership
                                         includeAutoSave:(BOOL)includeAutoSave
                                              entityName:(NSString *)entityName
                                            renamingFrom:(NSString *)renamingIdentifier {
    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];

    NSEntityDescription *entity = [[NSEntityDescription alloc] init];
    entity.name = entityName;
    entity.renamingIdentifier = renamingIdentifier;
    entity.managedObjectClassName = @"SPKGalleryFile";

    NSAttributeDescription *identifier = [[NSAttributeDescription alloc] init];
    identifier.name = @"identifier";
    identifier.attributeType = NSStringAttributeType;
    identifier.optional = NO;

    NSAttributeDescription *relativePath = [[NSAttributeDescription alloc] init];
    relativePath.name = @"relativePath";
    relativePath.attributeType = NSStringAttributeType;
    relativePath.optional = NO;

    NSAttributeDescription *mediaType = [[NSAttributeDescription alloc] init];
    mediaType.name = @"mediaType";
    mediaType.attributeType = NSInteger16AttributeType;
    mediaType.optional = NO;
    mediaType.defaultValue = @0;

    NSAttributeDescription *source = [[NSAttributeDescription alloc] init];
    source.name = @"source";
    source.attributeType = NSInteger16AttributeType;
    source.optional = NO;
    source.defaultValue = @0;

    NSAttributeDescription *dateAdded = [[NSAttributeDescription alloc] init];
    dateAdded.name = @"dateAdded";
    dateAdded.attributeType = NSDateAttributeType;
    dateAdded.optional = NO;

    NSAttributeDescription *fileSize = [[NSAttributeDescription alloc] init];
    fileSize.name = @"fileSize";
    fileSize.attributeType = NSInteger64AttributeType;
    fileSize.optional = NO;
    fileSize.defaultValue = @0;

    NSAttributeDescription *isFavorite = [[NSAttributeDescription alloc] init];
    isFavorite.name = @"isFavorite";
    isFavorite.attributeType = NSBooleanAttributeType;
    isFavorite.optional = NO;
    isFavorite.defaultValue = @NO;

    NSAttributeDescription *folderPath = [[NSAttributeDescription alloc] init];
    folderPath.name = @"folderPath";
    folderPath.attributeType = NSStringAttributeType;
    folderPath.optional = YES;

    NSAttributeDescription *customName = [[NSAttributeDescription alloc] init];
    customName.name = @"customName";
    customName.attributeType = NSStringAttributeType;
    customName.optional = YES;

    NSAttributeDescription *sourceUsername = [[NSAttributeDescription alloc] init];
    sourceUsername.name = @"sourceUsername";
    sourceUsername.attributeType = NSStringAttributeType;
    sourceUsername.optional = YES;

    NSAttributeDescription *sourceUserPK = [[NSAttributeDescription alloc] init];
    sourceUserPK.name = @"sourceUserPK";
    sourceUserPK.attributeType = NSStringAttributeType;
    sourceUserPK.optional = YES;

    NSAttributeDescription *sourceProfileURLString = [[NSAttributeDescription alloc] init];
    sourceProfileURLString.name = @"sourceProfileURLString";
    sourceProfileURLString.attributeType = NSStringAttributeType;
    sourceProfileURLString.optional = YES;

    NSAttributeDescription *sourceMediaPK = [[NSAttributeDescription alloc] init];
    sourceMediaPK.name = @"sourceMediaPK";
    sourceMediaPK.attributeType = NSStringAttributeType;
    sourceMediaPK.optional = YES;

    NSAttributeDescription *sourceMediaCode = [[NSAttributeDescription alloc] init];
    sourceMediaCode.name = @"sourceMediaCode";
    sourceMediaCode.attributeType = NSStringAttributeType;
    sourceMediaCode.optional = YES;

    NSAttributeDescription *sourceMediaURLString = [[NSAttributeDescription alloc] init];
    sourceMediaURLString.name = @"sourceMediaURLString";
    sourceMediaURLString.attributeType = NSStringAttributeType;
    sourceMediaURLString.optional = YES;

    NSAttributeDescription *pixelWidth = [[NSAttributeDescription alloc] init];
    pixelWidth.name = @"pixelWidth";
    pixelWidth.attributeType = NSInteger32AttributeType;
    pixelWidth.optional = NO;
    pixelWidth.defaultValue = @0;

    NSAttributeDescription *pixelHeight = [[NSAttributeDescription alloc] init];
    pixelHeight.name = @"pixelHeight";
    pixelHeight.attributeType = NSInteger32AttributeType;
    pixelHeight.optional = NO;
    pixelHeight.defaultValue = @0;

    NSAttributeDescription *durationSeconds = [[NSAttributeDescription alloc] init];
    durationSeconds.name = @"durationSeconds";
    durationSeconds.attributeType = NSDoubleAttributeType;
    durationSeconds.optional = NO;
    durationSeconds.defaultValue = @0.0;

    NSMutableArray<NSPropertyDescription *> *properties = [@[
        identifier, relativePath, mediaType, source, dateAdded, fileSize, isFavorite, folderPath, customName,
        sourceUsername, sourceUserPK, sourceProfileURLString, sourceMediaPK, sourceMediaCode, sourceMediaURLString,
        pixelWidth, pixelHeight, durationSeconds
    ] mutableCopy];

    if (includeAutoSave) {
        // Auto-save marker. Non-optional with a NO default so existing rows
        // migrate as "saved manually".
        NSAttributeDescription *isAutoSave = [[NSAttributeDescription alloc] init];
        isAutoSave.name = @"isAutoSave";
        isAutoSave.attributeType = NSBooleanAttributeType;
        isAutoSave.optional = NO;
        isAutoSave.defaultValue = @NO;

        [properties addObject:isAutoSave];
    }

    if (includeAccountOwnership) {
        // Per-account ownership: the logged-in account this file belongs to.
        // Optional so legacy files migrate as nil = "unassigned".
        NSAttributeDescription *ownerAccountPK = [[NSAttributeDescription alloc] init];
        ownerAccountPK.name = @"ownerAccountPK";
        ownerAccountPK.attributeType = NSStringAttributeType;
        ownerAccountPK.optional = YES;

        NSAttributeDescription *ownerUsername = [[NSAttributeDescription alloc] init];
        ownerUsername.name = @"ownerUsername";
        ownerUsername.attributeType = NSStringAttributeType;
        ownerUsername.optional = YES;

        [properties addObjectsFromArray:@[ ownerAccountPK, ownerUsername ]];
    }

    entity.properties = properties;
    model.entities = @[ entity ];

    return model;
}

- (NSManagedObjectModel *)buildModel {
    return [self buildModelWithAccountOwnership:YES];
}

- (NSURL *)storeURL {
    NSString *storePath = [[SPKGalleryPaths galleryDirectory] stringByAppendingPathComponent:kSPKGalleryStoreName];
    return [NSURL fileURLWithPath:storePath];
}

- (NSArray<NSURL *> *)sidecarURLsForStoreURL:(NSURL *)storeURL {
    NSString *path = storeURL.path;
    return @[
        [NSURL fileURLWithPath:[path stringByAppendingString:@"-wal"]],
        [NSURL fileURLWithPath:[path stringByAppendingString:@"-shm"]]
    ];
}

- (void)removeStoreSidecarsAtURL:(NSURL *)storeURL {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSURL *url in [self sidecarURLsForStoreURL:storeURL]) {
        if ([fm fileExistsAtPath:url.path]) {
            [fm removeItemAtURL:url error:nil];
        }
    }
}

- (void)backupStoreAtURL:(NSURL *)storeURL suffix:(NSString *)suffix {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithObject:storeURL];
    [urls addObjectsFromArray:[self sidecarURLsForStoreURL:storeURL]];
    for (NSURL *url in urls) {
        if (![fm fileExistsAtPath:url.path])
            continue;
        NSString *backupPath = [url.path stringByAppendingFormat:@".%@", suffix];
        [fm removeItemAtPath:backupPath error:nil];
        NSError *error = nil;
        if (![fm copyItemAtPath:url.path toPath:backupPath error:&error]) {
            SPKLog(@"General", @"[Sparkle Gallery] Failed to back up store file %@: %@", url.lastPathComponent, error);
        }
    }
}

- (BOOL)migrateStoreAtURLIfNeeded:(NSURL *)storeURL toModel:(NSManagedObjectModel *)destinationModel {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:storeURL.path])
        return YES;

    NSError *metadataError = nil;
    NSDictionary *metadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
                                                                                        URL:storeURL
                                                                                    options:nil
                                                                                      error:&metadataError];
    if (!metadata) {
        SPKLog(@"General", @"[Sparkle Gallery] Failed reading store metadata: %@", metadataError);
        return NO;
    }

    if ([destinationModel isConfiguration:nil compatibleWithStoreMetadata:metadata]) {
        return YES;
    }

    // Find a source model that matches the on-disk store. Candidates cover the
    // pre-/post-account schemas, the pre-/post-auto-save schemas, AND the pre-rename
    // entity name (SCIGalleryFile), so a single inferred mapping can rename the entity
    // and add any missing columns at once. Each candidate must describe a schema that
    // really shipped, or it won't match any store's version hash.
    NSArray<NSManagedObjectModel *> *candidateSourceModels = @[
        // Current schema minus auto-save: what every user upgrading to auto-save is on.
        [self buildModelWithAccountOwnership:YES
                             includeAutoSave:NO
                                  entityName:kSPKGalleryEntityName
                                renamingFrom:nil],
        [self buildModelWithAccountOwnership:YES
                             includeAutoSave:NO
                                  entityName:kSPKGalleryLegacyEntityName
                                renamingFrom:nil],
        [self buildModelWithAccountOwnership:NO
                             includeAutoSave:NO
                                  entityName:kSPKGalleryLegacyEntityName
                                renamingFrom:nil],
        [self buildModelWithAccountOwnership:NO
                             includeAutoSave:NO
                                  entityName:kSPKGalleryEntityName
                                renamingFrom:nil],
    ];
    NSManagedObjectModel *sourceModel = nil;
    for (NSManagedObjectModel *candidate in candidateSourceModels) {
        if ([candidate isConfiguration:nil compatibleWithStoreMetadata:metadata]) {
            sourceModel = candidate;
            break;
        }
    }
    if (!sourceModel) {
        SPKLog(@"General", @"[Sparkle Gallery] Store is incompatible with all known schemas; leaving it untouched");
        return NO;
    }

    NSError *mappingError = nil;
    NSMappingModel *mapping = [NSMappingModel inferredMappingModelForSourceModel:sourceModel
                                                                destinationModel:destinationModel
                                                                           error:&mappingError];
    if (!mapping) {
        SPKLog(@"General", @"[Sparkle Gallery] Failed creating inferred migration mapping: %@", mappingError);
        return NO;
    }

    NSString *tmpName = [NSString stringWithFormat:@"gallery-migration-%@.sqlite", [NSUUID UUID].UUIDString];
    NSURL *tmpURL = [[storeURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:tmpName];
    NSMigrationManager *manager = [[NSMigrationManager alloc] initWithSourceModel:sourceModel destinationModel:destinationModel];
    NSDictionary *destinationOptions = @{NSSQLitePragmasOption : @{@"journal_mode" : @"DELETE"}};

    NSError *migrationError = nil;
    BOOL migrated = [manager migrateStoreFromURL:storeURL
                                            type:NSSQLiteStoreType
                                         options:nil
                                withMappingModel:mapping
                                toDestinationURL:tmpURL
                                 destinationType:NSSQLiteStoreType
                              destinationOptions:destinationOptions
                                           error:&migrationError];
    if (!migrated) {
        SPKLog(@"General", @"[Sparkle Gallery] Failed migrating store to current schema: %@", migrationError);
        [fm removeItemAtURL:tmpURL error:nil];
        [self removeStoreSidecarsAtURL:tmpURL];
        return NO;
    }

    NSString *backupSuffix = [NSString stringWithFormat:@"pre-migration-%@", @((long long)[NSDate date].timeIntervalSince1970)];
    [self backupStoreAtURL:storeURL suffix:backupSuffix];
    [fm removeItemAtURL:storeURL error:nil];
    [self removeStoreSidecarsAtURL:storeURL];

    NSError *moveError = nil;
    if (![fm moveItemAtURL:tmpURL toURL:storeURL error:&moveError]) {
        SPKLog(@"General", @"[Sparkle Gallery] Failed installing migrated store: %@", moveError);
        [fm removeItemAtURL:tmpURL error:nil];
        [self removeStoreSidecarsAtURL:tmpURL];
        return NO;
    }

    [self removeStoreSidecarsAtURL:tmpURL];
    SPKLog(@"General", @"[Sparkle Gallery] Migrated gallery store to current schema");
    return YES;
}

- (void)setupPersistentContainer {
    NSManagedObjectModel *model = [self buildModel];
    self.persistentContainer = [[NSPersistentContainer alloc] initWithName:@"SPKGalleryModel" managedObjectModel:model];

    NSURL *storeURL = [self storeURL];
    [self migrateStoreAtURLIfNeeded:storeURL toModel:model];
    NSPersistentStoreDescription *storeDesc = [[NSPersistentStoreDescription alloc] initWithURL:storeURL];
    storeDesc.shouldMigrateStoreAutomatically = YES;
    storeDesc.shouldInferMappingModelAutomatically = YES;
    self.persistentContainer.persistentStoreDescriptions = @[ storeDesc ];

    [self.persistentContainer loadPersistentStoresWithCompletionHandler:^(NSPersistentStoreDescription *desc, NSError *error) {
        if (error) {
            SPKLog(@"General", @"[Sparkle Gallery] Failed to load Core Data store: %@", error);
        }
    }];

    self.persistentContainer.viewContext.automaticallyMergesChangesFromParent = YES;
    [self repairCollectionDescriptionFields];
}

// "(\n    123\n)" -> "123". Older builds stored a collection's description when
// KVC on an array answered an array of values. One element is recoverable as
// the value that was meant; anything else becomes nil so the field is re-derived
// (the profile open resolves a missing pk from the username and writes it back).
static NSString *SPKGalleryScalarFromCollectionDescription(NSString *stored) {
    NSString *trimmed = [stored stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![trimmed hasPrefix:@"("] || ![trimmed hasSuffix:@")"] || trimmed.length < 2)
        return stored;
    NSString *inner = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
    NSArray<NSString *> *parts = [inner componentsSeparatedByString:@","];
    if (parts.count != 1)
        return nil;
    NSMutableCharacterSet *strip = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
    [strip addCharactersInString:@"\""];
    NSString *value = [parts.firstObject stringByTrimmingCharactersInSet:strip];
    if (value.length == 0 || [value isEqualToString:@"<null>"])
        return nil;
    return value;
}

// Runs every load; the predicate matches nothing once the store is clean, so the
// steady-state cost is one unindexed fetch that returns zero rows.
- (void)repairCollectionDescriptionFields {
    NSArray<NSString *> *keys = @[ @"sourceUserPK", @"sourceMediaPK", @"sourceMediaCode" ];
    [self.persistentContainer performBackgroundTask:^(NSManagedObjectContext *ctx) {
        NSMutableArray<NSPredicate *> *clauses = [NSMutableArray array];
        for (NSString *key in keys)
            [clauses addObject:[NSPredicate predicateWithFormat:@"%K BEGINSWITH %@", key, @"("]];
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:kSPKGalleryEntityName];
        request.predicate = [NSCompoundPredicate orPredicateWithSubpredicates:clauses];
        NSError *error = nil;
        NSArray<NSManagedObject *> *rows = [ctx executeFetchRequest:request error:&error];
        if (rows.count == 0)
            return;
        for (NSManagedObject *row in rows) {
            for (NSString *key in keys) {
                NSString *stored = [row valueForKey:key];
                if (![stored isKindOfClass:NSString.class] || ![stored hasPrefix:@"("])
                    continue;
                [row setValue:SPKGalleryScalarFromCollectionDescription(stored) forKey:key];
            }
        }
        if ([ctx save:&error])
            SPKLog(@"Gallery", @"repaired %lu item(s) holding a collection description in an id field", (unsigned long)rows.count);
        else
            SPKLog(@"Gallery", @"collection description repair failed: %@", error);
    }];
}

- (NSManagedObjectContext *)viewContext {
    return self.persistentContainer.viewContext;
}

- (void)saveContext {
    NSManagedObjectContext *ctx = self.viewContext;
    if (![ctx hasChanges])
        return;

    NSError *error;
    if (![ctx save:&error]) {
        SPKLog(@"General", @"[Sparkle Gallery] Failed to save context: %@", error);
    }
}

- (void)unloadPersistentStores {
    NSPersistentStoreCoordinator *coordinator = self.persistentContainer.persistentStoreCoordinator;
    for (NSPersistentStore *store in [coordinator.persistentStores copy]) {
        NSError *removeError = nil;
        [coordinator removePersistentStore:store error:&removeError];
        if (removeError) {
            SPKLog(@"General", @"[Sparkle Gallery] Failed unloading persistent store: %@", removeError);
        }
    }
}

- (void)reloadPersistentContainer {
    [self unloadPersistentStores];
    [self setupPersistentContainer];
}

// Treat nil and empty owner PKs as the same (both "unassigned").
static BOOL SPKGalleryOwnerEqual(NSString *a, NSString *b) {
    if (a.length == 0 && b.length == 0)
        return YES;
    return [a isEqualToString:b];
}

// Run a Core Data block on the main queue (the view context's queue). Synchronous so
// callers on a background queue can interleave fast main-thread CD work with their own
// background file I/O.
static void SPKGalleryRunOnMain(void (^block)(void)) {
    if ([NSThread isMainThread])
        block();
    else
        dispatch_sync(dispatch_get_main_queue(), block);
}

// Builds a main-queue context over a store, or returns nil + sets *error.
- (NSManagedObjectContext *)contextForStoreAtURL:(NSURL *)storeURL
                                           model:(NSManagedObjectModel *)model
                                         options:(NSDictionary *)options
                                           error:(NSError *_Nullable *_Nullable)error {
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    if (![coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:options error:error]) {
        return nil;
    }
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    context.persistentStoreCoordinator = coordinator; // context retains the coordinator
    return context;
}

// Copies an archive store (plus its sidecars) into a throwaway directory, so it can be
// opened read-write and migrated without ever mutating the user's backup file.
- (NSURL *)copyStoreToScratchDirectoryFromURL:(NSURL *)storeURL scratchDirectory:(NSString **)outDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                    [NSString stringWithFormat:@"spk-gallery-archive-%@", [NSUUID UUID].UUIDString]];
    if (![fm createDirectoryAtPath:scratch withIntermediateDirectories:YES attributes:nil error:nil])
        return nil;

    NSURL *scratchStoreURL = [NSURL fileURLWithPath:[scratch stringByAppendingPathComponent:kSPKGalleryStoreName]];
    NSMutableArray<NSURL *> *sources = [NSMutableArray arrayWithObject:storeURL];
    [sources addObjectsFromArray:[self sidecarURLsForStoreURL:storeURL]];
    for (NSURL *source in sources) {
        if (![fm fileExistsAtPath:source.path])
            continue;
        NSString *suffix = [source.path substringFromIndex:storeURL.path.length]; // "", "-wal", "-shm"
        NSString *destination = [scratchStoreURL.path stringByAppendingString:suffix];
        NSError *copyError = nil;
        if (![fm copyItemAtPath:source.path toPath:destination error:&copyError]) {
            SPKLog(@"General", @"[Sparkle Gallery] Failed copying archive store for migration: %@", copyError);
            [fm removeItemAtPath:scratch error:nil];
            return nil;
        }
    }
    if (outDirectory)
        *outDirectory = scratch;
    return scratchStoreURL;
}

// Opens an exported bundle's gallery.sqlite against the current model. Returns nil +
// sets *error on failure, or nil + no error when the bundle has no store.
- (NSManagedObjectContext *)archiveContextForBundleDirectory:(NSString *)bundleGalleryDirectory error:(NSError *_Nullable *_Nullable)error {
    NSString *archiveStorePath = [bundleGalleryDirectory stringByAppendingPathComponent:kSPKGalleryStoreName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:archiveStorePath])
        return nil;

    NSManagedObjectModel *model = [self buildModel];
    NSURL *archiveStoreURL = [NSURL fileURLWithPath:archiveStorePath];
    [self migrateStoreAtURLIfNeeded:archiveStoreURL toModel:model];

    NSError *readOnlyError = nil;
    NSManagedObjectContext *context = [self contextForStoreAtURL:archiveStoreURL
                                                           model:model
                                                         options:@{
                                                             NSReadOnlyPersistentStoreOption : @YES,
                                                             NSSQLitePragmasOption : @{@"journal_mode" : @"DELETE"}
                                                         }
                                                           error:&readOnlyError];
    if (context)
        return context;

    // The archive was written by a build whose schema `migrateStoreAtURLIfNeeded:` has no
    // candidate source model for, so the explicit migration left it alone and the strict
    // open failed with "the managed object model version ... is incompatible". The live
    // store never hits this (its description migrates automatically), only backups do.
    // Copy the store out and let Core Data infer a lightweight migration for it, which
    // covers every earlier schema generically instead of only the enumerated candidates.
    SPKLog(@"General", @"[Sparkle Gallery] Archive store did not open against the current schema (%@); retrying with an inferred migration", readOnlyError);

    NSString *scratchDirectory = nil;
    NSURL *scratchStoreURL = [self copyStoreToScratchDirectoryFromURL:archiveStoreURL scratchDirectory:&scratchDirectory];
    if (!scratchStoreURL) {
        if (error)
            *error = readOnlyError;
        return nil;
    }

    NSError *migratingError = nil;
    context = [self contextForStoreAtURL:scratchStoreURL
                                   model:model
                                 options:@{
                                     NSMigratePersistentStoresAutomaticallyOption : @YES,
                                     NSInferMappingModelAutomaticallyOption : @YES,
                                     NSSQLitePragmasOption : @{@"journal_mode" : @"DELETE"}
                                 }
                                   error:&migratingError];
    if (!context) {
        SPKLog(@"General", @"[Sparkle Gallery] Failed opening archive store with an inferred migration: %@", migratingError);
        [[NSFileManager defaultManager] removeItemAtPath:scratchDirectory error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"com.sparkle.gallery"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : SPKL(@"GALLERY_BACKUP_UNREADABLE_FORMAT_ERROR"),
                                         NSUnderlyingErrorKey : migratingError ?: readOnlyError
                                     }];
        }
        return nil;
    }

    // Tie the scratch copy's lifetime to the context that reads it.
    SPKGalleryScratchStore *scratch = [[SPKGalleryScratchStore alloc] init];
    scratch.directory = scratchDirectory;
    objc_setAssociatedObject(context, SPKGalleryScratchStoreKey, scratch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SPKLog(@"General", @"[Sparkle Gallery] Opened archive store via an inferred migration");
    return context;
}

- (NSInteger)galleryImportConflictCountForBundleDirectory:(NSString *)bundleGalleryDirectory
                                           ownerAccountPK:(nullable NSString *)ownerAccountPK {
    if (ownerAccountPK.length == 0)
        return 0;
    NSManagedObjectContext *archiveContext = [self archiveContextForBundleDirectory:bundleGalleryDirectory error:nil];
    if (!archiveContext)
        return 0;

    NSFetchRequest *archiveRequest = [NSFetchRequest fetchRequestWithEntityName:kSPKGalleryEntityName];
    archiveRequest.resultType = NSDictionaryResultType;
    archiveRequest.propertiesToFetch = @[ @"identifier" ];
    NSMutableSet<NSString *> *archiveIDs = [NSMutableSet set];
    for (NSDictionary *row in [archiveContext executeFetchRequest:archiveRequest error:nil]) {
        NSString *identifier = row[@"identifier"];
        if ([identifier isKindOfClass:[NSString class]])
            [archiveIDs addObject:identifier];
    }

    NSFetchRequest *mainRequest = [NSFetchRequest fetchRequestWithEntityName:kSPKGalleryEntityName];
    mainRequest.resultType = NSDictionaryResultType;
    mainRequest.propertiesToFetch = @[ @"identifier", @"ownerAccountPK" ];
    NSInteger conflicts = 0;
    for (NSDictionary *row in [self.viewContext executeFetchRequest:mainRequest error:nil]) {
        NSString *identifier = row[@"identifier"];
        if (![identifier isKindOfClass:[NSString class]] || ![archiveIDs containsObject:identifier])
            continue;
        NSString *owner = row[@"ownerAccountPK"];
        if (![owner isKindOfClass:[NSString class]])
            owner = nil;
        if (!SPKGalleryOwnerEqual(owner, ownerAccountPK))
            conflicts++;
    }
    return conflicts;
}

- (NSInteger)mergeGalleryFilesFromBundleDirectory:(NSString *)bundleGalleryDirectory
                              remapOwnerAccountPK:(nullable NSString *)remapOwnerAccountPK
                                    ownerUsername:(nullable NSString *)ownerUsername
                                 conflictStrategy:(SPKGalleryImportConflictStrategy)conflictStrategy
                                  progressHandler:(nullable void (^)(NSInteger done, NSInteger total))progressHandler
                                            error:(NSError *_Nullable *_Nullable)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *attributeNames = [self buildModel].entitiesByName[kSPKGalleryEntityName].attributesByName.allKeys;

    // 1. Read the archive rows as plain dictionaries and the live identifier→owner map.
    // Core Data reads happen on the main queue; everything after is plain data + file I/O.
    __block NSArray<NSDictionary *> *archiveRows = nil;
    __block NSError *readError = nil;
    NSMutableDictionary<NSString *, NSString *> *existingOwners = [NSMutableDictionary dictionary]; // identifier → ownerPK ("" = unassigned)
    SPKGalleryRunOnMain(^{
        NSManagedObjectContext *archiveContext = [self archiveContextForBundleDirectory:bundleGalleryDirectory error:&readError];
        if (!archiveContext)
            return;
        NSArray<NSManagedObject *> *objs = [archiveContext executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:kSPKGalleryEntityName] error:&readError];
        NSMutableArray<NSDictionary *> *dicts = [NSMutableArray arrayWithCapacity:objs.count];
        for (NSManagedObject *o in objs) {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            for (NSString *a in attributeNames) {
                id v = [o valueForKey:a];
                if (v)
                    d[a] = v;
            }
            [dicts addObject:d];
        }
        archiveRows = dicts;

        NSFetchRequest *mreq = [NSFetchRequest fetchRequestWithEntityName:kSPKGalleryEntityName];
        mreq.resultType = NSDictionaryResultType;
        mreq.propertiesToFetch = @[ @"identifier", @"ownerAccountPK" ];
        for (NSDictionary *row in [self.viewContext executeFetchRequest:mreq error:nil]) {
            NSString *identifier = row[@"identifier"];
            if (![identifier isKindOfClass:[NSString class]])
                continue;
            NSString *owner = [row[@"ownerAccountPK"] isKindOfClass:[NSString class]] ? row[@"ownerAccountPK"] : @"";
            existingOwners[identifier] = owner;
        }
    });
    if (readError) {
        SPKLog(@"General", @"[Sparkle Gallery] Merge: failed reading archive: %@", readError);
        if (error)
            *error = readError;
        return -1;
    }
    if (archiveRows.count == 0)
        return 0;

    NSString *mediaDir = [SPKGalleryPaths galleryMediaDirectory];
    NSString *thumbDir = [SPKGalleryPaths galleryThumbnailsDirectory];
    NSString *archiveFilesDir = [bundleGalleryDirectory stringByAppendingPathComponent:@"Files"];
    NSString *archiveThumbsDir = [bundleGalleryDirectory stringByAppendingPathComponent:@"Thumbnails"];

    // Copies a row's media (collision-safe) + thumbnail. Returns the dest relativePath, or nil.
    NSString * (^copyFiles)(NSDictionary *, NSString *, NSString *) = ^NSString *(NSDictionary *row, NSString *srcId, NSString *targetId) {
        NSString *relativePath = row[@"relativePath"];
        NSString *srcMedia = [archiveFilesDir stringByAppendingPathComponent:relativePath];
        if (![fm fileExistsAtPath:srcMedia])
            return nil;
        NSString *destRelative = relativePath;
        NSString *destMedia = [mediaDir stringByAppendingPathComponent:destRelative];
        if ([fm fileExistsAtPath:destMedia]) {
            NSString *stem = [relativePath stringByDeletingPathExtension];
            NSString *ext = [relativePath pathExtension];
            NSUInteger n = 1;
            do {
                destRelative = ext.length > 0 ? [NSString stringWithFormat:@"%@-%lu.%@", stem, (unsigned long)n, ext]
                                              : [NSString stringWithFormat:@"%@-%lu", stem, (unsigned long)n];
                destMedia = [mediaDir stringByAppendingPathComponent:destRelative];
                n++;
            } while ([fm fileExistsAtPath:destMedia]);
        }
        if (![fm copyItemAtPath:srcMedia toPath:destMedia error:nil])
            return nil;
        NSString *srcThumb = [archiveThumbsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.jpg", srcId]];
        NSString *destThumb = [thumbDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.jpg", targetId]];
        if ([fm fileExistsAtPath:srcThumb] && ![fm fileExistsAtPath:destThumb]) {
            [fm copyItemAtPath:srcThumb toPath:destThumb error:nil];
        }
        return destRelative;
    };

    // 2. Plan + copy files (no Core Data here — safe to run on a background queue), with progress.
    NSMutableArray<NSDictionary *> *insertPlans = [NSMutableArray array]; // {row, targetId, destRelative}
    NSMutableArray<NSString *> *claimIdentifiers = [NSMutableArray array];
    NSInteger total = archiveRows.count, done = 0;
    for (NSDictionary *row in archiveRows) {
        @autoreleasepool {
            NSString *identifier = row[@"identifier"];
            NSString *relativePath = row[@"relativePath"];
            if (identifier.length > 0 && relativePath.length > 0) {
                NSString *existingOwner = existingOwners[identifier];
                if (existingOwner != nil) {
                    BOOL conflict = remapOwnerAccountPK.length > 0 && !SPKGalleryOwnerEqual(existingOwner.length ? existingOwner : nil, remapOwnerAccountPK);
                    if (conflict && conflictStrategy == SPKGalleryImportConflictStrategyClaim) {
                        [claimIdentifiers addObject:identifier];
                    } else if (conflict && conflictStrategy == SPKGalleryImportConflictStrategyDuplicate) {
                        NSString *newId = [NSUUID UUID].UUIDString;
                        NSString *destRel = copyFiles(row, identifier, newId);
                        if (destRel)
                            [insertPlans addObject:@{@"row" : row, @"targetId" : newId, @"destRelative" : destRel}];
                    }
                    // No conflict, or Skip strategy: leave the existing file untouched.
                } else {
                    NSString *destRel = copyFiles(row, identifier, identifier);
                    if (destRel) {
                        [insertPlans addObject:@{@"row" : row, @"targetId" : identifier, @"destRelative" : destRel}];
                        existingOwners[identifier] = remapOwnerAccountPK.length ? remapOwnerAccountPK : @""; // guard duplicate ids in the archive
                    }
                }
            }
        }
        done++;
        if (progressHandler)
            progressHandler(done, total);
    }

    // 3. Apply to the live store (fast Core Data work on the main queue).
    __block NSInteger added = 0;
    __block NSError *saveError = nil;
    SPKGalleryRunOnMain(^{
        NSManagedObjectContext *ctx = self.viewContext;
        for (NSDictionary *plan in insertPlans) {
            NSDictionary *row = plan[@"row"];
            NSManagedObject *dst = [NSEntityDescription insertNewObjectForEntityForName:kSPKGalleryEntityName inManagedObjectContext:ctx];
            for (NSString *attribute in attributeNames) {
                id v = row[attribute];
                if (v)
                    [dst setValue:v forKey:attribute];
            }
            [dst setValue:plan[@"targetId"] forKey:@"identifier"];
            [dst setValue:plan[@"destRelative"] forKey:@"relativePath"];
            if (remapOwnerAccountPK.length > 0) {
                [dst setValue:remapOwnerAccountPK forKey:@"ownerAccountPK"];
                [dst setValue:(ownerUsername.length > 0 ? ownerUsername : nil) forKey:@"ownerUsername"];
            }
            added++;
        }
        if (claimIdentifiers.count > 0) {
            NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:kSPKGalleryEntityName];
            req.predicate = [NSPredicate predicateWithFormat:@"identifier IN %@", claimIdentifiers];
            for (NSManagedObject *o in [ctx executeFetchRequest:req error:nil]) {
                [o setValue:remapOwnerAccountPK forKey:@"ownerAccountPK"];
                [o setValue:(ownerUsername.length > 0 ? ownerUsername : nil) forKey:@"ownerUsername"];
                added++;
            }
        }
        if (ctx.hasChanges && ![ctx save:&saveError]) {
            SPKLog(@"General", @"[Sparkle Gallery] Merge: failed saving merged rows: %@", saveError);
        }
    });
    if (saveError) {
        if (error)
            *error = saveError;
        return -1;
    }

    SPKLog(@"General", @"[Sparkle Gallery] Merge: added/updated %ld file(s) from import", (long)added);
    return added;
}

- (BOOL)exportGalleryFilesToBundleDirectory:(NSString *)bundleGalleryDirectory
                             ownerAccountPK:(nullable NSString *)ownerAccountPK
                            progressHandler:(nullable void (^)(NSInteger done, NSInteger total))progressHandler
                                      error:(NSError *_Nullable *_Nullable)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destFiles = [bundleGalleryDirectory stringByAppendingPathComponent:@"Files"];
    NSString *destThumbs = [bundleGalleryDirectory stringByAppendingPathComponent:@"Thumbnails"];
    [fm createDirectoryAtPath:destFiles withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:destThumbs withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray<NSString *> *attributeNames = [self buildModel].entitiesByName[kSPKGalleryEntityName].attributesByName.allKeys;

    // 1. Read the in-scope rows as plain dictionaries (Core Data on main).
    __block NSArray<NSDictionary *> *rows = nil;
    __block NSError *fetchError = nil;
    SPKGalleryRunOnMain(^{
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:kSPKGalleryEntityName];
        if (ownerAccountPK.length > 0)
            request.predicate = [NSPredicate predicateWithFormat:@"ownerAccountPK == %@", ownerAccountPK];
        NSArray<NSManagedObject *> *objs = [self.viewContext executeFetchRequest:request error:&fetchError];
        NSMutableArray<NSDictionary *> *dicts = [NSMutableArray arrayWithCapacity:objs.count];
        for (NSManagedObject *o in objs) {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            for (NSString *a in attributeNames) {
                id v = [o valueForKey:a];
                if (v)
                    d[a] = v;
            }
            [dicts addObject:d];
        }
        rows = dicts;
    });
    if (!rows) {
        if (error)
            *error = fetchError;
        return NO;
    }

    // 2. Copy the media + thumbnails (no Core Data — safe on a background queue), with progress.
    NSString *srcFiles = [SPKGalleryPaths galleryMediaDirectory];
    NSString *srcThumbs = [SPKGalleryPaths galleryThumbnailsDirectory];
    NSMutableArray<NSDictionary *> *exported = [NSMutableArray array];
    NSInteger total = rows.count, done = 0;
    for (NSDictionary *row in rows) {
        @autoreleasepool {
            NSString *identifier = row[@"identifier"];
            NSString *relativePath = row[@"relativePath"];
            if (identifier.length > 0 && relativePath.length > 0) {
                NSString *srcMediaPath = [srcFiles stringByAppendingPathComponent:relativePath];
                if ([fm fileExistsAtPath:srcMediaPath]) {
                    [fm copyItemAtPath:srcMediaPath toPath:[destFiles stringByAppendingPathComponent:relativePath] error:nil];
                    NSString *srcThumb = [srcThumbs stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.jpg", identifier]];
                    if ([fm fileExistsAtPath:srcThumb]) {
                        [fm copyItemAtPath:srcThumb toPath:[destThumbs stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.jpg", identifier]] error:nil];
                    }
                    [exported addObject:row];
                }
            }
        }
        done++;
        if (progressHandler)
            progressHandler(done, total);
    }

    // 3. Build the fresh export store with the exported rows (isolated context; on main).
    __block BOOL ok = YES;
    __block NSError *storeError = nil;
    SPKGalleryRunOnMain(^{
        NSPersistentStoreCoordinator *destCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self buildModel]];
        NSURL *destStoreURL = [NSURL fileURLWithPath:[bundleGalleryDirectory stringByAppendingPathComponent:kSPKGalleryStoreName]];
        if (![destCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:destStoreURL options:@{NSSQLitePragmasOption : @{@"journal_mode" : @"DELETE"}} error:&storeError]) {
            ok = NO;
            return;
        }
        NSManagedObjectContext *destContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        destContext.persistentStoreCoordinator = destCoordinator;
        for (NSDictionary *row in exported) {
            NSManagedObject *dst = [NSEntityDescription insertNewObjectForEntityForName:kSPKGalleryEntityName inManagedObjectContext:destContext];
            for (NSString *attribute in attributeNames) {
                id v = row[attribute];
                if (v)
                    [dst setValue:v forKey:attribute];
            }
        }
        if (destContext.hasChanges && ![destContext save:&storeError])
            ok = NO;
        for (NSPersistentStore *store in [destCoordinator.persistentStores copy])
            [destCoordinator removePersistentStore:store error:nil];
    });
    if (!ok) {
        if (error)
            *error = storeError;
        return NO;
    }
    return YES;
}

@end
