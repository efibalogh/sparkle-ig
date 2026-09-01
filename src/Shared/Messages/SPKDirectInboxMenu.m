#import "SPKDirectInboxMenu.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "../../Utils.h"

@interface SPKDirectInboxMenuEntry : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, assign) NSInteger order;
@property (nonatomic, copy) SPKDirectInboxMenuProvider provider;
@end

@implementation SPKDirectInboxMenuEntry
@end

@interface SPKDirectInboxMenuTransformerEntry : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, assign) NSInteger order;
@property (nonatomic, copy) SPKDirectInboxMenuTransformer transformer;
@end

@implementation SPKDirectInboxMenuTransformerEntry
@end

static NSMutableArray<SPKDirectInboxMenuEntry *> *SPKDirectInboxMenuEntries;
static NSMutableArray<SPKDirectInboxMenuTransformerEntry *> *SPKDirectInboxMenuTransformerEntries;

// Two inbox view controllers implement this delegate callback and which one backs
// the inbox is decided server side, so both are hooked and each keeps its own
// original implementation.
static id (*SPKDirectOrigInboxContextMenu)(id, SEL, id);
static id (*SPKDirectOrigInboxSwiftContextMenu)(id, SEL, id);
static id (*SPKDirectOrigInboxLegacyContextMenu)(id, SEL, id);

static id SPKDirectInboxMenuKVCObject(id target, NSString *key) {
    if (!target || key.length == 0)
        return nil;
    @try {
        return [target valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

void SPKDirectInboxMenuRegisterProvider(NSString *identifier, NSInteger order, SPKDirectInboxMenuProvider provider) {
    if (identifier.length == 0 || !provider)
        return;
    if (!SPKDirectInboxMenuEntries)
        SPKDirectInboxMenuEntries = [NSMutableArray array];

    [SPKDirectInboxMenuEntries filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPKDirectInboxMenuEntry *entry, NSDictionary *bindings) {
                                    (void)bindings;
                                    return ![entry.identifier isEqualToString:identifier];
                                }]];

    SPKDirectInboxMenuEntry *entry = [SPKDirectInboxMenuEntry new];
    entry.identifier = identifier;
    entry.order = order;
    entry.provider = provider;
    [SPKDirectInboxMenuEntries addObject:entry];
    [SPKDirectInboxMenuEntries sortUsingComparator:^NSComparisonResult(SPKDirectInboxMenuEntry *a, SPKDirectInboxMenuEntry *b) {
        if (a.order == b.order)
            return [a.identifier compare:b.identifier];
        return a.order < b.order ? NSOrderedAscending : NSOrderedDescending;
    }];
}

void SPKDirectInboxMenuRegisterTransformer(NSString *identifier, NSInteger order, SPKDirectInboxMenuTransformer transformer) {
    if (identifier.length == 0 || !transformer)
        return;
    if (!SPKDirectInboxMenuTransformerEntries)
        SPKDirectInboxMenuTransformerEntries = [NSMutableArray array];

    [SPKDirectInboxMenuTransformerEntries filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPKDirectInboxMenuTransformerEntry *entry, NSDictionary *bindings) {
                                               (void)bindings;
                                               return ![entry.identifier isEqualToString:identifier];
                                           }]];

    SPKDirectInboxMenuTransformerEntry *entry = [SPKDirectInboxMenuTransformerEntry new];
    entry.identifier = identifier;
    entry.order = order;
    entry.transformer = transformer;
    [SPKDirectInboxMenuTransformerEntries addObject:entry];
    [SPKDirectInboxMenuTransformerEntries sortUsingComparator:^NSComparisonResult(SPKDirectInboxMenuTransformerEntry *a, SPKDirectInboxMenuTransformerEntry *b) {
        if (a.order == b.order)
            return [a.identifier compare:b.identifier];
        return a.order < b.order ? NSOrderedAscending : NSOrderedDescending;
    }];
}

/// Walks from the tapped index path to the thread view model behind it. The Swift
/// view controller stores its adapter under an unprefixed ivar name, so all three
/// spellings are tried.
static id SPKDirectInboxMenuViewModelForIndexPath(id controller, id indexPath) {
    id adapter = SPKDirectInboxMenuKVCObject(controller, @"listAdapter");
    if (!adapter)
        adapter = [SPKUtils getIvarForObj:controller name:"_listAdapter"];
    if (!adapter)
        adapter = [SPKUtils getIvarForObj:controller name:"listAdapter"];
    if (!adapter || ![indexPath respondsToSelector:@selector(section)]) {
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Skipped: missing adapter/indexPath controller=%@<%p>",
               NSStringFromClass([controller class]),
               controller);
        return nil;
    }

    SEL sectionControllerSelector = NSSelectorFromString(@"sectionControllerForSection:");
    if (![adapter respondsToSelector:sectionControllerSelector]) {
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Skipped: adapter lacks sectionControllerForSection adapter=%@<%p>",
               NSStringFromClass([adapter class]),
               adapter);
        return nil;
    }

    NSInteger section = [(NSIndexPath *)indexPath section];
    id sectionController = ((id (*)(id, SEL, NSInteger))objc_msgSend)(adapter, sectionControllerSelector, section);
    id viewModel = SPKDirectInboxMenuKVCObject(sectionController, @"viewModel");
    if (!viewModel)
        viewModel = [SPKUtils getIvarForObj:sectionController name:"_viewModel"];
    if (!viewModel)
        viewModel = SPKDirectInboxMenuKVCObject(sectionController, @"item");
    if (!viewModel)
        viewModel = [SPKUtils getIvarForObj:sectionController name:"_item"];

    if (!viewModel) {
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Skipped: missing viewModel section=%ld sectionController=%@<%p>",
               (long)section,
               NSStringFromClass([sectionController class]),
               sectionController);
    }
    return viewModel;
}

static id SPKDirectInboxMenuWrapConfigurationForViewModel(id viewModel, id configuration) {
    if (SPKDirectInboxMenuEntries.count == 0 && SPKDirectInboxMenuTransformerEntries.count == 0)
        return configuration;
    if (![configuration isKindOfClass:[UIContextMenuConfiguration class]])
        return configuration;
    if (!viewModel)
        return configuration;

    SPKDirectThreadContext *context = SPKDirectThreadContextFromInboxViewModel(viewModel);
    if (context.threadId.length == 0) {
        SPKLog(@"Messages", @"[Sparkle InboxMenu] Skipped: no thread context viewModel=%@<%p>",
               NSStringFromClass([viewModel class]),
               viewModel);
        return configuration;
    }

    UIContextMenuConfiguration *original = (UIContextMenuConfiguration *)configuration;
    UIContextMenuActionProvider originalProvider = SPKDirectInboxMenuKVCObject(original, @"actionProvider");
    UIContextMenuContentPreviewProvider originalPreview = SPKDirectInboxMenuKVCObject(original, @"previewProvider");
    id<NSCopying> originalIdentifier = SPKDirectInboxMenuKVCObject(original, @"identifier");
    NSArray<SPKDirectInboxMenuEntry *> *entries = [SPKDirectInboxMenuEntries copy];
    NSArray<SPKDirectInboxMenuTransformerEntry *> *transformerEntries = [SPKDirectInboxMenuTransformerEntries copy];

    UIContextMenuActionProvider wrappedProvider = ^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIMenu *baseMenu = nil;
        @try {
            baseMenu = originalProvider ? originalProvider(suggestedActions) : [UIMenu menuWithChildren:suggestedActions ?: @[]];
        } @catch (NSException *exception) {
            SPKLog(@"Messages", @"[Sparkle InboxMenu] Original provider failed threadId=%@ exception=%@ reason=%@",
                   context.threadId ?: @"(unknown)",
                   exception.name,
                   exception.reason);
            return [UIMenu menuWithChildren:suggestedActions ?: @[]];
        }
        if (![baseMenu isKindOfClass:[UIMenu class]]) {
            SPKLog(@"Messages", @"[Sparkle InboxMenu] Original provider returned invalid menu threadId=%@ menu=%@",
                   context.threadId ?: @"(unknown)",
                   baseMenu);
            return [UIMenu menuWithChildren:suggestedActions ?: @[]];
        }

        for (SPKDirectInboxMenuTransformerEntry *entry in transformerEntries) {
            UIMenu *transformedMenu = nil;
            @try {
                transformedMenu = entry.transformer(context, viewModel, baseMenu);
            } @catch (NSException *exception) {
                SPKLog(@"Messages", @"[Sparkle InboxMenu] Transformer %@ threw exception=%@ reason=%@",
                       entry.identifier,
                       exception.name,
                       exception.reason);
                continue;
            }
            if ([transformedMenu isKindOfClass:[UIMenu class]])
                baseMenu = transformedMenu;
        }

        NSMutableArray<UIMenuElement *> *sparkleElements = [NSMutableArray array];
        for (SPKDirectInboxMenuEntry *entry in entries) {
            NSArray<UIMenuElement *> *elements = nil;
            @try {
                elements = entry.provider(context, viewModel);
            } @catch (NSException *exception) {
                SPKLog(@"Messages", @"[Sparkle InboxMenu] Provider %@ threw exception=%@ reason=%@",
                       entry.identifier,
                       exception.name,
                       exception.reason);
                continue;
            }
            for (UIMenuElement *element in elements ?: @[]) {
                if ([element isKindOfClass:[UIMenuElement class]])
                    [sparkleElements addObject:element];
            }
        }
        if (sparkleElements.count == 0)
            return baseMenu;

        // An inline menu renders as its own divided section rather than a nested
        // row, and putting it first in `children` keeps Sparkle's rows above
        // Instagram's own actions.
        UIMenu *sparkleSection = [UIMenu menuWithTitle:@""
                                                 image:nil
                                            identifier:nil
                                               options:UIMenuOptionsDisplayInline
                                              children:sparkleElements];
        NSMutableArray<UIMenuElement *> *children = [NSMutableArray arrayWithObject:sparkleSection];
        [children addObjectsFromArray:baseMenu.children ?: @[]];
        return [baseMenu menuByReplacingChildren:children];
    };

    return [UIContextMenuConfiguration configurationWithIdentifier:originalIdentifier
                                                  previewProvider:originalPreview
                                                   actionProvider:wrappedProvider];
}

// Newer builds hand the delegate an index path and expect the callee to find the
// thread behind it; older ones pass the view model straight in. Both funnel into the
// same wrap, so a feature's rows never depend on which callback is live.
static id SPKDirectInboxMenuWrapConfiguration(id controller, id indexPath, id configuration) {
    if (![configuration isKindOfClass:[UIContextMenuConfiguration class]])
        return configuration;
    return SPKDirectInboxMenuWrapConfigurationForViewModel(SPKDirectInboxMenuViewModelForIndexPath(controller, indexPath),
                                                           configuration);
}

static id SPKDirectInboxContextMenu(id self, SEL _cmd, id indexPath) {
    return SPKDirectInboxMenuWrapConfiguration(self, indexPath, SPKDirectOrigInboxContextMenu(self, _cmd, indexPath));
}

static id SPKDirectInboxSwiftContextMenu(id self, SEL _cmd, id indexPath) {
    return SPKDirectInboxMenuWrapConfiguration(self, indexPath, SPKDirectOrigInboxSwiftContextMenu(self, _cmd, indexPath));
}

static id SPKDirectInboxLegacyContextMenu(id self, SEL _cmd, id viewModel) {
    return SPKDirectInboxMenuWrapConfigurationForViewModel(viewModel, SPKDirectOrigInboxLegacyContextMenu(self, _cmd, viewModel));
}

static BOOL SPKDirectInboxMenuHookClass(NSString *className, SEL selector, IMP replacement, IMP *orig) {
    Class inboxClass = NSClassFromString(className);
    if (!inboxClass || !class_getInstanceMethod(inboxClass, selector))
        return NO;

    MSHookMessageEx(inboxClass, selector, replacement, orig);
    SPKLog(@"Messages", @"[Sparkle InboxMenu] Installed inbox context menu hook class=%@", className);
    return YES;
}

void SPKDirectInboxMenuInstallHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL selector = NSSelectorFromString(@"networkingCoordinator_contextMenuConfigurationForThreadCellAtIndexPath:");
        BOOL installed = SPKDirectInboxMenuHookClass(@"IGDirectInboxViewController",
                                                     selector,
                                                     (IMP)SPKDirectInboxContextMenu,
                                                     (IMP *)&SPKDirectOrigInboxContextMenu);
        installed |= SPKDirectInboxMenuHookClass(@"IGDirectInboxSwiftViewController.IGDirectInboxSwiftViewController",
                                                 selector,
                                                 (IMP)SPKDirectInboxSwiftContextMenu,
                                                 (IMP *)&SPKDirectOrigInboxSwiftContextMenu);
        if (!installed) {
            // Builds before the networking-coordinator callback existed build the
            // configuration from the view model itself.
            installed = SPKDirectInboxMenuHookClass(@"IGDirectInboxViewController",
                                                    NSSelectorFromString(@"_contextMenuConfigurationForThreadCellWithViewModel:"),
                                                    (IMP)SPKDirectInboxLegacyContextMenu,
                                                    (IMP *)&SPKDirectOrigInboxLegacyContextMenu);
        }
        if (!installed)
            SPKLog(@"Messages", @"[Sparkle InboxMenu] No inbox context menu hook installed: no inbox class implements a known menu callback");
    });
}
