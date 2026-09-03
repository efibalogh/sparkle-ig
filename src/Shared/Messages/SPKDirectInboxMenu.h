#import <UIKit/UIKit.h>

#import "SPKDirectSeenContext.h"

NS_ASSUME_NONNULL_BEGIN

/// Builds the elements one feature contributes to a thread's inbox long-press menu.
/// Return nil (or an empty array) when the feature has nothing to offer for this
/// thread. Called every time the menu is built, so read preferences here rather
/// than gating installation on them.
typedef NSArray<UIMenuElement *> *_Nullable (^SPKDirectInboxMenuProvider)(SPKDirectThreadContext *context, id viewModel);
typedef UIMenu *_Nullable (^SPKDirectInboxMenuTransformer)(SPKDirectThreadContext *context, id viewModel, UIMenu *menu);

#ifdef __cplusplus
extern "C" {
#endif

/// Registers one feature's contribution to the inbox long-press menu.
///
/// Both inbox view controllers (the ObjC one and the Swift one that replaced it on
/// newer builds; which one is live is a server decision) implement the same menu
/// delegate callback, and every Sparkle feature wanting a row there needs the same
/// wrap. Each feature hooking that selector itself means the second install wraps
/// the first's replacement and the rows fight over ordering, so features register
/// here instead and a single hook does the wrapping.
///
/// `order` sorts the sections against each other, lowest first. Registering the same
/// `identifier` twice replaces the earlier provider.
void SPKDirectInboxMenuRegisterProvider(NSString *identifier, NSInteger order, SPKDirectInboxMenuProvider provider);

/// Registers a feature that can transform Instagram's completed inbox menu
/// before Sparkle's own sections are inserted. Returning nil or an invalid menu
/// leaves the previous menu untouched.
void SPKDirectInboxMenuRegisterTransformer(NSString *identifier, NSInteger order, SPKDirectInboxMenuTransformer transformer);

/// Installs the shared hook. Idempotent, and safe to call before any provider is
/// registered: with no providers the menu is returned untouched.
void SPKDirectInboxMenuInstallHooksIfNeeded(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
