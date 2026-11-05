#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

id SPKObjectForSelector(id target, NSString *selectorName);
id SPKKVCObject(id target, NSString *key);
/// YES when `-valueForKey:` on `target` would find something for `key` rather than fall
/// through to `-valueForUndefinedKey:` and throw. Mirrors Foundation's documented accessor
/// search, so guarding a KVC read with it changes no result, only skips the thrown and
/// caught NSUnknownKeyException that a miss otherwise costs. Speculative key probing over
/// Instagram's models misses far more often than it hits, so those throws added up to
/// hundreds per viewer session.
BOOL SPKKVCKeyIsResolvable(id target, NSString *key);
NSArray *SPKArrayFromCollection(id collection);
NSURL *SPKURLFromValue(id value);
NSString *SPKStringFromValue(id value);
NSString *SPKClassName(id object);
/// The IGMedia a reels viewer cell (video or carousel) is showing, or nil.
id SPKSundialCellMedia(id cell);

NSString *SPKUsernameFromMediaObject(id media);
NSString *SPKCaptionFromMediaObject(id media);
NSString *SPKSessionUsernameFromController(UIViewController *controller);

id SPKDirectCurrentMessageFromController(UIViewController *controller);
id SPKDirectResolvedMediaFromController(UIViewController *controller);
NSInteger SPKDirectCurrentIndexFromController(UIViewController *controller);
NSString *SPKDirectUsernameFromController(UIViewController *controller);

#ifdef __cplusplus
}
#endif
