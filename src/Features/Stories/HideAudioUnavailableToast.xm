#import <objc/runtime.h>

#import "../../InstagramHeaders.h"
#import "../../Utils.h"

extern "C" void MSHookMessageEx(Class cls, SEL sel, IMP replacement, IMP *result);

static NSString *const kSPKHideAudioUnavailableToastPreferenceKey = @"stories_hide_audio_unavailable_toast";
static NSString *const kSPKAudioUnavailableToastIdentifier = @"audio-go-dark-toast";

static BOOL SPKShouldHideAudioUnavailableToastModel(id model) {
    if (![SPKUtils getBoolPref:kSPKHideAudioUnavailableToastPreferenceKey] || !model)
        return NO;

    SEL identifierSelector = NSSelectorFromString(@"identifier");
    if (![model respondsToSelector:identifierSelector])
        return NO;

    id identifier = ((id (*)(id, SEL))objc_msgSend)(model, identifierSelector);
    return [identifier isKindOfClass:[NSString class]] && [identifier isEqualToString:kSPKAudioUnavailableToastIdentifier];
}

static void (*SPKOriginalShowActionableToast)(id, SEL, id, id, BOOL, double, long long, unsigned long long, unsigned long long, id, id, id, id) = NULL;
static void SPKShowActionableToast(id self,
                                   SEL selector,
                                   id model,
                                   id presentationContext,
                                   BOOL animated,
                                   double duration,
                                   long long priority,
                                   unsigned long long origin,
                                   unsigned long long toastType,
                                   id tapAction,
                                   id tapToastAction,
                                   id presentedHandler,
                                   id dismissedHandler) {
    if (SPKShouldHideAudioUnavailableToastModel(model))
        return;

    if (SPKOriginalShowActionableToast) {
        SPKOriginalShowActionableToast(self,
                                       selector,
                                       model,
                                       presentationContext,
                                       animated,
                                       duration,
                                       priority,
                                       origin,
                                       toastType,
                                       tapAction,
                                       tapToastAction,
                                       presentedHandler,
                                       dismissedHandler);
    }
}

static void (*SPKOriginalShowStoryAudioUnavailableToast)(id, SEL) = NULL;
static void SPKShowStoryAudioUnavailableToast(id self, SEL selector) {
    if ([SPKUtils getBoolPref:kSPKHideAudioUnavailableToastPreferenceKey])
        return;

    if (SPKOriginalShowStoryAudioUnavailableToast)
        SPKOriginalShowStoryAudioUnavailableToast(self, selector);
}

static void (*SPKOriginalPresentAudioUnavailableToast)(id, SEL, id) = NULL;
static void SPKPresentAudioUnavailableToast(id self, SEL selector, id media) {
    if ([SPKUtils getBoolPref:kSPKHideAudioUnavailableToastPreferenceKey])
        return;

    if (SPKOriginalPresentAudioUnavailableToast)
        SPKOriginalPresentAudioUnavailableToast(self, selector, media);
}

static BOOL SPKHookAudioUnavailableToastMethod(const char *className,
                                                SEL selector,
                                                IMP replacement,
                                                IMP *original) {
    Class cls = objc_getClass(className);
    if (!cls || !class_getInstanceMethod(cls, selector))
        return NO;

    MSHookMessageEx(cls, selector, replacement, original);
    return YES;
}

extern "C" void SPKInstallHideAudioUnavailableToastHooksIfEnabled(void) {
    // Install independently of the current value because this preference may
    // be account-scoped and is safe to re-check whenever Instagram presents it.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        BOOL installedCurrentStory = SPKHookAudioUnavailableToastMethod("_TtC30IGStorySectionAudioCoordinator30IGStorySectionAudioCoordinator",
                                                                         NSSelectorFromString(@"showAudioUnavailableToast"),
                                                                         (IMP)SPKShowStoryAudioUnavailableToast,
                                                                         (IMP *)&SPKOriginalShowStoryAudioUnavailableToast);
        BOOL installedLegacySundial = SPKHookAudioUnavailableToastMethod("IGSundialViewerInteractionCoordinator",
                                                                         NSSelectorFromString(@"presentAudioUnavailableToastFor:"),
                                                                         (IMP)SPKPresentAudioUnavailableToast,
                                                                         (IMP *)&SPKOriginalPresentAudioUnavailableToast);
        BOOL installedActionablePresenter = SPKHookAudioUnavailableToastMethod("IGActionableConfirmationToastPresenter",
                                                                               NSSelectorFromString(@"_showAlertWithViewModel:presentationContext:isAnimated:animationDuration:presentationPriority:origin:toastType:tapActionBlock:tapToastBlock:presentedHandler:dismissedHandler:"),
                                                                               (IMP)SPKShowActionableToast,
                                                                               (IMP *)&SPKOriginalShowActionableToast);
        (void)installedCurrentStory;
        (void)installedLegacySundial;
        (void)installedActionablePresenter;
    });
}
