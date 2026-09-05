#import <objc/message.h>
#import <objc/runtime.h>
#import <SafariServices/SafariServices.h>

#import "../../InstagramHeaders.h"
#import "../../Shared/UI/SPKIGAlertPresenter.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"

static const void *kSPKTappableTextLinksProcessedKey = &kSPKTappableTextLinksProcessedKey;
static const void *kSPKTappableTextLinksStyledURLsKey = &kSPKTappableTextLinksStyledURLsKey;
static const void *kSPKTappableTextLinksURLsKey = &kSPKTappableTextLinksURLsKey;
static const void *kSPKTappableTextLinksProxyKey = &kSPKTappableTextLinksProxyKey;
static const void *kSPKTappableTextLinksManagedCaptionViewKey = &kSPKTappableTextLinksManagedCaptionViewKey;
static const void *kSPKUnifiedCaptionDiagnosticKey = &kSPKUnifiedCaptionDiagnosticKey;

static BOOL SPKTextLinkIsWebURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

static NSString *SPKTextLinkTrimmedURLString(NSString *candidate) {
    if (candidate.length == 0)
        return nil;

    NSUInteger end = candidate.length;
    NSCharacterSet *sentencePunctuation = [NSCharacterSet characterSetWithCharactersInString:@".,!?;:"];
    while (end > 0 && [sentencePunctuation characterIsMember:[candidate characterAtIndex:end - 1]])
        end--;
    return [candidate substringToIndex:end];
}

static NSArray<NSDictionary *> *SPKTextLinkRanges(NSString *text) {
    if (text.length == 0 || text.length > 4096)
        return @[];

    static NSRegularExpression *detector;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        detector = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s<>]+"
                                                                 options:NSRegularExpressionCaseInsensitive
                                                                   error:nil];
    });

    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    [detector enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                             usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        (void)flags;
        (void)stop;
        NSString *raw = [text substringWithRange:match.range];
        NSString *trimmed = SPKTextLinkTrimmedURLString(raw);
        if (trimmed.length == 0)
            return;
        NSURL *url = [NSURL URLWithString:trimmed];
        if (!SPKTextLinkIsWebURL(url))
            return;
        NSUInteger length = trimmed.length;
        [results addObject:@{ @"range" : [NSValue valueWithRange:NSMakeRange(match.range.location, length)],
                              @"url" : url }];
    }];
    return results;
}

static IGCoreTextView *SPKFeedHeaderCoreTextView(id view) {
    @try {
        return [view valueForKey:@"coreTextView"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// The nearest ancestor controller may already be presenting something (a
// caption or comments sheet over the host viewer), and presenting on it would
// silently fail. Descend to the controller that actually owns the screen.
static UIViewController *SPKTappableTextLinkPresenter(UIView *sourceView) {
    UIViewController *presenter = [SPKUtils viewControllerForAncestralView:sourceView] ?: topMostController();
    for (NSUInteger depth = 0; depth < 8; depth++) {
        UIViewController *presented = presenter.presentedViewController;
        if (!presented || presented.isBeingDismissed)
            break;
        presenter = presented;
    }
    return presenter;
}

static void SPKOpenTappableTextURL(NSURL *url, UIView *sourceView) {
    if (!SPKTextLinkIsWebURL(url))
        return;

    NSString *mode = [SPKUtils getStringPref:@"general_tappable_text_links_opening_mode"];
    SPKLog(@"TappableLinks", @"Opening tapped web link host=%@ mode=%@", url.host ?: @"(none)", mode ?: @"(unset)");
    if ([mode isEqualToString:@"safari"]) {
        [SPKUtils openURL:url];
        return;
    }

    void (^openInApp)(void) = ^{
        UIViewController *presenter = SPKTappableTextLinkPresenter(sourceView);
        if (!presenter) {
            SPKLog(@"TappableLinks", @"Native in-app browser unavailable: no presenter host=%@", url.host ?: @"(none)");
            [SPKUtils openURL:url];
            return;
        }
        SFSafariViewController *browser = [[SFSafariViewController alloc] initWithURL:url];
        SPKLog(@"TappableLinks", @"Opening native in-app browser host=%@ presenter=%@", url.host ?: @"(none)", NSStringFromClass(presenter.class));
        [presenter presentViewController:browser animated:YES completion:nil];
    };
    if (![mode isEqualToString:@"ask"]) {
        openInApp();
        return;
    }

    UIViewController *presenter = SPKTappableTextLinkPresenter(sourceView);
    if (!presenter)
        return;
    [SPKIGAlertPresenter presentActionSheetFromViewController:presenter
                                                        title:SPKL(@"GENERAL_TEXT_LINKS_OPEN_LINK_TITLE")
                                                      message:nil
                                                      actions:@[
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"GENERAL_TEXT_LINKS_IN_APP_BROWSER_TEXT")
                                                                                      style:SPKIGAlertActionStyleDefault
                                                                                    handler:^{
                                                                                        openInApp();
                                                                                    }],
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"GENERAL_TEXT_LINKS_SAFARI_TEXT")
                                                                                      style:SPKIGAlertActionStyleDefault
                                                                                    handler:^{
                                                                                        [SPKUtils openURL:url];
                                                                                    }],
                                                          [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                      style:SPKIGAlertActionStyleCancel
                                                                                    handler:nil]
                                                      ]];
}

@interface SPKTappableTextLinkHandlerProxy : NSObject
@property (nonatomic, weak) id originalHandler;
@property (nonatomic, weak) IGCoreTextView *view;
@property (nonatomic, copy) NSSet<NSString *> *sparkleURLs;
@property (nonatomic, copy) NSString *lastOpenedURL;
@property (nonatomic, assign) CFAbsoluteTime lastOpenTime;
@end

@implementation SPKTappableTextLinkHandlerProxy

// Instagram may deliver a single tap through both the required callback and the
// optional atPoint: variant. Its own handlers implement only one of the two, so
// they never notice; the proxy implements both and would forward twice, pushing
// a hashtag or mention view controller once per delivery. Collapse repeat
// deliveries of the same URL inside one tap.
- (BOOL)spk_shouldSuppressRepeatDeliveryOfURL:(NSURL *)url {
    NSString *absolute = url.absoluteString ?: @"";
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if ([self.lastOpenedURL isEqualToString:absolute] && now - self.lastOpenTime < 0.25)
        return YES;
    self.lastOpenedURL = absolute;
    self.lastOpenTime = now;
    return NO;
}

- (void)spk_handleTapOnString:(NSString *)string
                          URL:(NSURL *)url
                         view:(IGCoreTextView *)view
                        point:(CGPoint)point
                     hasPoint:(BOOL)hasPoint {
    if ([self spk_shouldSuppressRepeatDeliveryOfURL:url])
        return;

    if ([self.sparkleURLs containsObject:url.absoluteString]) {
        SPKLog(@"TappableLinks", @"Sparkle URL callback received host=%@", url.host ?: @"(none)");
        SPKOpenTappableTextURL(url, view);
        return;
    }

    // Forward through whichever callback the real handler implements, matching
    // the variant we were called with when it supports both.
    id original = self.originalHandler;
    SEL plainSelector = @selector(coreTextView:didTapOnString:URL:);
    SEL pointSelector = @selector(coreTextView:didTapOnString:URL:atPoint:);
    BOOL originalTakesPoint = [original respondsToSelector:pointSelector];
    BOOL originalTakesPlain = [original respondsToSelector:plainSelector];

    if (originalTakesPoint && (hasPoint || !originalTakesPlain)) {
        ((void (*)(id, SEL, id, id, id, CGPoint))objc_msgSend)(original, pointSelector, view, string, url, point);
    } else if (originalTakesPlain) {
        [original coreTextView:view didTapOnString:string URL:url];
    } else {
        SPKLog(@"TappableLinks", @"Non-Sparkle URL callback had no compatible original handler");
    }
}

- (void)coreTextView:(IGCoreTextView *)view didTapOnString:(NSString *)string URL:(NSURL *)url {
    [self spk_handleTapOnString:string URL:url view:view point:CGPointZero hasPoint:NO];
}

- (void)coreTextView:(IGCoreTextView *)view didTapOnString:(NSString *)string URL:(NSURL *)url atPoint:(CGPoint)point {
    [self spk_handleTapOnString:string URL:url view:view point:point hasPoint:YES];
}

- (BOOL)respondsToSelector:(SEL)selector {
    // Advertise the optional atPoint: callback only when the real handler does,
    // so Instagram dispatches taps the same way it would without the proxy.
    if (selector == @selector(coreTextView:didTapOnString:URL:atPoint:))
        return [self.originalHandler respondsToSelector:selector];
    return [super respondsToSelector:selector] || [self.originalHandler respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    return [self.originalHandler respondsToSelector:selector] ? self.originalHandler : [super forwardingTargetForSelector:selector];
}
@end

static NSSet<NSString *> *SPKDecorateTappableTextLinks(IGStyledString *styledString, BOOL *didDecorate) {
    if (didDecorate)
        *didDecorate = NO;
    if (!styledString)
        return [NSSet set];
    NSSet<NSString *> *urls = objc_getAssociatedObject(styledString, kSPKTappableTextLinksStyledURLsKey);
    if (!objc_getAssociatedObject(styledString, kSPKTappableTextLinksProcessedKey)) {
        objc_setAssociatedObject(styledString, kSPKTappableTextLinksProcessedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *text = styledString.attributedString.string;
        NSArray<NSDictionary *> *links = SPKTextLinkRanges(text);
        NSMutableSet<NSString *> *newURLs = [NSMutableSet set];
        for (NSDictionary *entry in links) {
            NSRange range = [entry[@"range"] rangeValue];
            NSURL *url = entry[@"url"];
            id existingURL = [styledString.attributedString attribute:NSLinkAttributeName
                                                               atIndex:range.location
                                                        effectiveRange:NULL];
            if (existingURL)
                continue;
            [styledString setURL:url range:range];
            // Instagram's accent is a violet-leaning blue, not the iOS system
            // blue, so decorated links match the mentions and hashtags beside them.
            [styledString setColor:[SPKUtils SPKColor_InstagramBlue] range:range];
            [newURLs addObject:url.absoluteString];
            if (didDecorate)
                *didDecorate = YES;
        }
        urls = [newURLs copy];
        objc_setAssociatedObject(styledString, kSPKTappableTextLinksStyledURLsKey, urls, OBJC_ASSOCIATION_COPY_NONATOMIC);
        if (urls.count > 0)
            SPKLog(@"TappableLinks", @"Added %lu tappable URL range(s) textLength=%lu",
                   (unsigned long)urls.count, (unsigned long)text.length);
    }
    return urls ?: [NSSet set];
}

static void SPKAttachTappableTextLinkHandler(IGCoreTextView *view, NSSet<NSString *> *urls) {
    if (!view)
        return;

    if (urls.count == 0) {
        objc_setAssociatedObject(view, kSPKTappableTextLinksURLsKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        SPKTappableTextLinkHandlerProxy *proxy = objc_getAssociatedObject(view, kSPKTappableTextLinksProxyKey);
        proxy.sparkleURLs = [NSSet set];
        return;
    }

    objc_setAssociatedObject(view, kSPKTappableTextLinksURLsKey, urls, OBJC_ASSOCIATION_COPY_NONATOMIC);
    id currentHandler = view.linkHandler;
    SPKTappableTextLinkHandlerProxy *proxy = objc_getAssociatedObject(view, kSPKTappableTextLinksProxyKey);
    if (!proxy) {
        proxy = [SPKTappableTextLinkHandlerProxy new];
        proxy.view = view;
        objc_setAssociatedObject(view, kSPKTappableTextLinksProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (currentHandler != proxy)
        proxy.originalHandler = currentHandler;
    proxy.sparkleURLs = urls;
    if (currentHandler != proxy)
        view.linkHandler = proxy;
}

static void SPKProcessTappableTextLinks(IGCoreTextView *view, IGStyledString *styledString) {
    if (!view || !styledString)
        return;

    BOOL decorated = NO;
    NSSet<NSString *> *urls = SPKDecorateTappableTextLinks(styledString, &decorated);

    // Fallback for a caller that decorates after Instagram has already installed
    // and laid out the string: reassigning it is the only way to rebuild the
    // CoreText link hit map, at the cost of a second layout pass. The hooks above
    // decorate in place, so this should stay quiet; the log names any caller that
    // still reaches it.
    if (decorated && view.styledString == styledString) {
        SPKLog(@"TappableLinks", @"Forcing relayout to refresh link map handler=%@ length=%lu",
               NSStringFromClass([view.linkHandler class]) ?: @"(none)",
               (unsigned long)styledString.attributedString.length);
        view.styledString = styledString;
    }

    SPKAttachTappableTextLinkHandler(view, urls);
}

static IGCoreTextView *SPKCommentCellCoreTextView(id cell) {
    SEL commentViewSelector = @selector(commentView);
    if (![cell respondsToSelector:commentViewSelector])
        return nil;
    typedef id (*ObjectGetter)(id, SEL);
    id commentView = ((ObjectGetter)objc_msgSend)(cell, commentViewSelector);
    SEL coreTextViewSelector = @selector(coreTextView);
    if (![commentView respondsToSelector:coreTextViewSelector])
        return nil;
    id textView = ((ObjectGetter)objc_msgSend)(commentView, coreTextViewSelector);
    return [textView isKindOfClass:objc_getClass("IGCoreTextView")] ? textView : nil;
}

static IGCoreTextView *SPKUnifiedCaptionTextView(id captionView, const char *ivarName) {
    Ivar ivar = class_getInstanceVariable([captionView class], ivarName);
    if (!ivar)
        return nil;
    id textView = object_getIvar(captionView, ivar);
    return [textView isKindOfClass:objc_getClass("IGCoreTextView")] ? textView : nil;
}

static void SPKMarkManagedCaptionTextView(IGCoreTextView *view) {
    if (!view || objc_getAssociatedObject(view, kSPKTappableTextLinksManagedCaptionViewKey))
        return;
    objc_setAssociatedObject(view, kSPKTappableTextLinksManagedCaptionViewKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// A text view whose current styled string has already been decorated needs no
// further work, and the styled string carries that flag itself.
static BOOL SPKUnifiedCaptionTextViewIsProcessed(IGCoreTextView *view) {
    if (!view)
        return YES;
    IGStyledString *styledString = view.styledString;
    if (!styledString)
        return YES;
    return objc_getAssociatedObject(styledString, kSPKTappableTextLinksProcessedKey) != nil;
}

static void SPKProcessUnifiedVideoCaption(id captionView) {
    IGCoreTextView *collapsed = SPKUnifiedCaptionTextView(captionView, "_collapsedTextView");
    IGCoreTextView *expanded = SPKUnifiedCaptionTextView(captionView, "_expandedTextView");
    SPKMarkManagedCaptionTextView(collapsed);
    SPKMarkManagedCaptionTextView(expanded);

    // This runs from -sizeThatFits:, so it is hit on every sizing pass while
    // scrolling and throughout the expansion animation. Bail out before the
    // decoration work once the current text has been handled.
    if (SPKUnifiedCaptionTextViewIsProcessed(collapsed) && SPKUnifiedCaptionTextViewIsProcessed(expanded))
        return;

    if (!objc_getAssociatedObject(captionView, kSPKUnifiedCaptionDiagnosticKey)
        && (collapsed.styledString || expanded.styledString)) {
        objc_setAssociatedObject(captionView, kSPKUnifiedCaptionDiagnosticKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SPKLog(@"TappableLinks", @"Reels caption text ready collapsedLength=%lu expandedLength=%lu",
               (unsigned long)collapsed.styledString.attributedString.length,
               (unsigned long)expanded.styledString.attributedString.length);
    }
    SPKProcessTappableTextLinks(collapsed, collapsed.styledString);
    if (expanded != collapsed)
        SPKProcessTappableTextLinks(expanded, expanded.styledString);
}

static void SPKProcessCoreTextDescendants(UIView *root) {
    Class coreTextClass = objc_getClass("IGCoreTextView");
    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:coreTextClass]) {
            IGCoreTextView *textView = (IGCoreTextView *)subview;
            objc_setAssociatedObject(textView, kSPKTappableTextLinksManagedCaptionViewKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SPKProcessTappableTextLinks(textView, textView.styledString);
        } else {
            SPKProcessCoreTextDescendants(subview);
        }
    }
}

static BOOL SPKIsSupportedCaptionLinkHandler(id handler) {
    if (!handler)
        return NO;

    // The rich caption section controller is a Swift class, so it is registered
    // under its mangled symbol rather than the "Module.Class" spelling that
    // objc_getClass would need. Resolve it through the shared helper instead.
    static Class unifiedCaptionClass;
    static Class richCaptionControllerClass;
    static Class feedTextCellClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unifiedCaptionClass = objc_getClass("IGUnifiedVideoCaptionView");
        richCaptionControllerClass = SPKResolveIGClass(@"IGCommentRichCaptionView.IGCommentRichCaptionSectionController", nil);
        feedTextCellClass = objc_getClass("IGFeedItemTextCell");
        SPKLog(@"TappableLinks", @"Caption handler classes resolved unified=%@ richCaption=%@ feedTextCell=%@",
               unifiedCaptionClass ? @"YES" : @"NO", richCaptionControllerClass ? @"YES" : @"NO",
               feedTextCellClass ? @"YES" : @"NO");
    });
    return (unifiedCaptionClass && [handler isKindOfClass:unifiedCaptionClass])
        || (richCaptionControllerClass && [handler isKindOfClass:richCaptionControllerClass])
        || (feedTextCellClass && [handler isKindOfClass:feedTextCellClass]);
}

%group SPKTappableTextLinksHooks
%hook IGCoreTextView
- (void)setStyledString:(IGStyledString *)styledString {
    id handler = self.linkHandler;
    SPKTappableTextLinkHandlerProxy *proxy = objc_getAssociatedObject(self, kSPKTappableTextLinksProxyKey);
    id nativeHandler = handler == proxy ? proxy.originalHandler : handler;
    BOOL managedCaption = [objc_getAssociatedObject(self, kSPKTappableTextLinksManagedCaptionViewKey) boolValue]
        || SPKIsSupportedCaptionLinkHandler(nativeHandler);
    if (!managedCaption) {
        %orig;
        return;
    }

    objc_setAssociatedObject(self, kSPKTappableTextLinksManagedCaptionViewKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSSet<NSString *> *urls = SPKDecorateTappableTextLinks(styledString, NULL);
    %orig;
    SPKAttachTappableTextLinkHandler(self, urls);
}

- (void)setLinkHandler:(id)handler {
    if (!handler) {
        // Instagram clears the handler when it recycles the view. Tear the proxy
        // down with it, otherwise it stays installed with no original handler and
        // silently swallows taps on Instagram's own mentions and hashtags.
        SPKTappableTextLinkHandlerProxy *staleProxy = objc_getAssociatedObject(self, kSPKTappableTextLinksProxyKey);
        if (staleProxy) {
            staleProxy.originalHandler = nil;
            staleProxy.sparkleURLs = [NSSet set];
            objc_setAssociatedObject(self, kSPKTappableTextLinksProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(self, kSPKTappableTextLinksURLsKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        %orig;
        return;
    }

    BOOL managedCaption = [objc_getAssociatedObject(self, kSPKTappableTextLinksManagedCaptionViewKey) boolValue]
        || SPKIsSupportedCaptionLinkHandler(handler);
    if (!managedCaption) {
        %orig;
        return;
    }

    objc_setAssociatedObject(self, kSPKTappableTextLinksManagedCaptionViewKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPKTappableTextLinkHandlerProxy *proxy = objc_getAssociatedObject(self, kSPKTappableTextLinksProxyKey);
    NSSet<NSString *> *urls = objc_getAssociatedObject(self, kSPKTappableTextLinksURLsKey);
    if (proxy && urls.count > 0 && handler != proxy) {
        proxy.originalHandler = handler;
        %orig(proxy);
        return;
    }
    %orig;
    if (SPKIsSupportedCaptionLinkHandler(handler))
        SPKProcessTappableTextLinks(self, self.styledString);
}
%end

%hook IGFeedItemTextCell
// Instagram builds a fresh styled string every time a caption is expanded or a
// cell is reconfigured, and it installs that string straight onto the core text
// view. Marking the view here, before any string is assigned, lets the
// IGCoreTextView hook decorate in place. Decorating afterwards instead forces a
// second CoreText layout pass over the full caption, which is the stutter on
// "more" that only appears when the caption actually contains a link.
- (void)configureWithStyledStringProvider:(id)styledStringProvider
         textCellModelMediaAccessProvider:(id)mediaAccessProvider
                          backgroundColor:(id)backgroundColor
                              feedItemRow:(id)feedItemRow
                             cellDelegate:(id)cellDelegate
                     touchHandlerDelegate:(id)touchHandlerDelegate
                               topPadding:(double)topPadding
                              userSession:(id)userSession {
    if ([SPKUtils getBoolPref:@"general_tappable_text_links"])
        SPKMarkManagedCaptionTextView(self.coreTextView);
    %orig;
}

- (void)updateStyledString {
    if ([SPKUtils getBoolPref:@"general_tappable_text_links"])
        SPKMarkManagedCaptionTextView(self.coreTextView);
    %orig;
    if ([SPKUtils getBoolPref:@"general_tappable_text_links"]) {
        SPKProcessTappableTextLinks(self.coreTextView, self.styledString);
    }
}

- (void)coreTextView:(IGCoreTextView *)view didTapOnString:(NSString *)string URL:(NSURL *)url {
    NSSet<NSString *> *urls = objc_getAssociatedObject(view, kSPKTappableTextLinksURLsKey);
    if ([SPKUtils getBoolPref:@"general_tappable_text_links"] && [urls containsObject:url.absoluteString]) {
        SPKLog(@"TappableLinks", @"Feed URL callback received host=%@", url.host ?: @"(none)");
        SPKOpenTappableTextURL(url, view);
        return;
    }
    %orig;
}
%end

%hook IGCommentCell
- (void)bindViewModel:(id)viewModel {
    %orig;
    if ([SPKUtils getBoolPref:@"general_tappable_text_links"]) {
        IGCoreTextView *textView = SPKCommentCellCoreTextView(self);
        SPKProcessTappableTextLinks(textView, textView.styledString);
    }
}
%end

%hook IGFeedItemHeaderCoreTextView
- (void)setStyledString:(IGStyledString *)styledString {
    %orig;
    if ([SPKUtils getBoolPref:@"general_tappable_text_links"]) {
        IGCoreTextView *textView = SPKFeedHeaderCoreTextView(self);
        SPKProcessTappableTextLinks(textView, textView.styledString ?: styledString);
    }
}
%end


%hook IGUnifiedVideoCaptionView
- (void)setViewModel:(id)viewModel {
    %orig;
    if ([SPKUtils getBoolPref:@"general_tappable_text_links"])
        SPKProcessUnifiedVideoCaption(self);
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize result = %orig;
    if ([SPKUtils getBoolPref:@"general_tappable_text_links"])
        SPKProcessUnifiedVideoCaption(self);
    return result;
}

- (void)prepareForAnimationToExpansionPercentage:(double)percentage {
    %orig;
    if ([SPKUtils getBoolPref:@"general_tappable_text_links"])
        SPKProcessUnifiedVideoCaption(self);
}

- (void)coreTextView:(IGCoreTextView *)view didTapOnString:(NSString *)string URL:(NSURL *)url {
    NSSet<NSString *> *urls = objc_getAssociatedObject(view, kSPKTappableTextLinksURLsKey);
    if ([SPKUtils getBoolPref:@"general_tappable_text_links"] && [urls containsObject:url.absoluteString]) {
        SPKLog(@"TappableLinks", @"Reels URL callback received host=%@", url.host ?: @"(none)");
        SPKOpenTappableTextURL(url, view);
        return;
    }
    %orig;
}
%end


%hook IGCommentRichCaptionView
- (void)configureWith:(id)viewModel {
    %orig;
    if ([SPKUtils getBoolPref:@"general_tappable_text_links"])
        SPKProcessCoreTextDescendants(self);
}

- (void)setCoreTextLinkHandler:(id)handler {
    %orig;
    if ([SPKUtils getBoolPref:@"general_tappable_text_links"])
        SPKProcessCoreTextDescendants(self);
}
%end
%end

extern "C" void SPKInstallTappableTextLinksHooksIfEnabled(void) {
    BOOL enabled = [SPKUtils getBoolPref:@"general_tappable_text_links"];
    SPKLog(@"TappableLinks", @"Installer reached enabled=%@", enabled ? @"YES" : @"NO");
    if (!enabled)
        return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKTappableTextLinksHooks,
              IGCommentCell = SPKResolveIGClass(@"IGCommentCells.IGCommentCell", @"IGCommentCell"),
              IGCommentRichCaptionView = SPKResolveIGClass(@"IGCommentRichCaptionView.IGCommentRichCaptionView", nil));
        SPKLog(@"TappableLinks", @"Caption and comment hooks installed");
    });
}
