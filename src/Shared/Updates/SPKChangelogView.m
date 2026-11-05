#import "SPKStrings.h"
#import "SPKChangelogView.h"
#import <WebKit/WebKit.h>

#import "SPKUpdateChecker.h"
#import "../../Utils.h"

// The page paints its own background, a shade off Sparkle's, so let the host show through. Its
// footer links back to the repo's landing page, which has nothing for the app, and the page's
// bottom padding is sized for a browser, so both go.
static NSString *const kSPKChangelogBaseCSS = @"html,body{background:transparent!important}"
                                               @"body>.wrap>footer{display:none!important}"
                                               @".wrap{padding-bottom:20px!important}";
// The host's navigation bar already carries the title, so drop the page's and the gap above it.
static NSString *const kSPKChangelogHideHeaderCSS = @"body>.wrap>header{display:none!important}"
                                                     @".wrap{padding-top:4px!important}";

// Each release is a `section.rel` headed by `.rel-head h2` ("v1.5.1"), newest first. Shared by the
// scripts below, which take their arguments as one JSON array.
static NSString *const kSPKChangelogVersionJS =
    @"function spkNum(v){return String(v).trim().replace(/^v/i,'').split(/[^0-9.]/)[0].split('.')"
     ".map(function(p){return parseInt(p,10)||0;});}"
     "function spkCmp(a,b){a=spkNum(a);b=spkNum(b);for(var i=0;i<Math.max(a.length,b.length);i++)"
     "{var d=(a[i]||0)-(b[i]||0);if(d)return d;}return 0;}"
     "function spkRels(){return [].slice.call(document.querySelectorAll('section.rel')).map(function(s)"
     "{var h=s.querySelector('.rel-head h2');return h?{s:s,v:h.textContent}:null;}).filter(Boolean);}";

// Folds the releases at or below the installed one behind a button. Takes [installed, buttonTitle].
static NSString *const kSPKChangelogFoldJS =
    @"(function(args){var rels=spkRels();"
     "var older=rels.filter(function(r){return spkCmp(r.v,args[0])<=0;}).map(function(r){return r.s;});"
     // Nothing newer (a dev override ahead of every release): still show the latest one.
     "if(older.length===rels.length)older=older.slice(1);"
     "if(!older.length)return;"
     "older.forEach(function(s){s.style.display='none';});"
     "var box=document.createElement('div');box.style.cssText='text-align:center;margin:28px 0 0';"
     "var b=document.createElement('button');b.type='button';b.className='btn ghost';b.textContent=args[1];"
     "b.onclick=function(){older.forEach(function(s){s.style.display='';});box.remove();};"
     "box.appendChild(b);older[0].parentNode.insertBefore(box,older[0]);"
     "})(%@);";

// Adds an outlined label to the installed release's heading, beside the page's own "Latest" pill
// when both land on the same release. Takes [installed, labelTitle].
static NSString *const kSPKChangelogMarkJS =
    @"(function(args){var hit=spkRels().filter(function(r){return spkCmp(r.v,args[0])===0;})[0];"
     "if(!hit)return;var head=hit.s.querySelector('.rel-head');"
     "var p=document.createElement('span');p.className='pill';p.textContent=args[1];"
     "p.style.cssText='background:transparent;color:var(--fg);box-shadow:inset 0 0 0 1px var(--line);'"
     "+(head.querySelector('.pill')?'margin-left:0':'');"
     "head.appendChild(p);"
     "})(%@);";

@interface SPKChangelogView () <WKNavigationDelegate>
@property (nonatomic, assign) SPKChangelogOptions options;
@property (nonatomic, strong, nullable) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIStackView *failureStack;
@property (nonatomic, strong) UIImpactFeedbackGenerator *softImpact;
@end

@implementation SPKChangelogView

- (instancetype)initWithOptions:(SPKChangelogOptions)options {
    self = [super initWithFrame:CGRectZero];
    if (!self)
        return nil;
    _options = options;
    _softImpact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.hidesWhenStopped = YES;
    [self addSubview:self.spinner];

    UILabel *failureLabel = [UILabel new];
    failureLabel.text = SPKL(@"CHANGELOG_LOAD_FAILED_TEXT");
    failureLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    failureLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
    failureLabel.textAlignment = NSTextAlignmentCenter;
    failureLabel.numberOfLines = 0;
    UIButton *retryButton = [self linkButtonWithTitle:SPKL(@"ALERT_ACTION_RETRY") action:@selector(retryTapped)];
    UIButton *safariButton = [self linkButtonWithTitle:SPKL(@"CHANGELOG_OPEN_IN_SAFARI_ACTION") action:@selector(openInSafariTapped)];
    self.failureStack = [[UIStackView alloc] initWithArrangedSubviews:@[ failureLabel, retryButton, safariButton ]];
    self.failureStack.axis = UILayoutConstraintAxisVertical;
    self.failureStack.alignment = UIStackViewAlignmentCenter;
    self.failureStack.spacing = 2.0;
    [self.failureStack setCustomSpacing:10.0 afterView:failureLabel];
    self.failureStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.failureStack.hidden = YES;
    [self addSubview:self.failureStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.centerYAnchor],
        [self.failureStack.centerYAnchor constraintEqualToAnchor:self.spinner.centerYAnchor],
        [self.failureStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:32.0],
        [self.failureStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-32.0],
        [failureLabel.widthAnchor constraintEqualToAnchor:self.failureStack.widthAnchor],
    ]];
    return self;
}

- (UIButton *)linkButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[SPKUtils SPKColor_InstagramBlue] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:36.0].active = YES;
    return button;
}

#pragma mark - Loading

/// One script per adjustment, with its strings passed as JSON so neither can break out of it.
- (void)addScript:(NSString *)format arguments:(NSArray<NSString *> *)arguments to:(WKUserContentController *)controller {
    NSData *json = [NSJSONSerialization dataWithJSONObject:arguments options:0 error:nil];
    if (!json)
        return;
    NSString *source = [kSPKChangelogVersionJS
        stringByAppendingString:[NSString stringWithFormat:format, [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]]];
    [controller addUserScript:[[WKUserScript alloc] initWithSource:source
                                                     injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                                  forMainFrameOnly:YES]];
}

- (WKWebViewConfiguration *)configuration {
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    // Nothing the page needs outlives the view, and nothing of Instagram's should reach it.
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    WKUserContentController *controller = configuration.userContentController;

    NSString *css = kSPKChangelogBaseCSS;
    if (self.options & SPKChangelogOptionHidePageHeader)
        css = [css stringByAppendingString:kSPKChangelogHideHeaderCSS];
    NSData *cssJSON = [NSJSONSerialization dataWithJSONObject:@[ css ] options:0 error:nil];
    if (cssJSON) {
        NSString *source = [NSString stringWithFormat:@"(function(a){var s=document.createElement('style');s.textContent=a[0];"
                                                      @"document.documentElement.appendChild(s);})(%@);",
                                                      [[NSString alloc] initWithData:cssJSON encoding:NSUTF8StringEncoding]];
        [controller addUserScript:[[WKUserScript alloc] initWithSource:source
                                                         injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                                      forMainFrameOnly:YES]];
    }

    NSString *installed = [SPKUpdateChecker installedVersion];
    if (self.options & SPKChangelogOptionMarkInstalled)
        [self addScript:kSPKChangelogMarkJS arguments:@[ installed, SPKL(@"CHANGELOG_INSTALLED_BADGE") ] to:controller];
    if (self.options & SPKChangelogOptionFoldInstalled)
        [self addScript:kSPKChangelogFoldJS arguments:@[ installed, SPKL(@"CHANGELOG_SHOW_EARLIER_ACTION") ] to:controller];
    return configuration;
}

- (void)loadIfNeeded {
    if (self.webView)
        return;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:[self configuration]];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.navigationDelegate = self;
    // Transparent until the page paints, so dark mode does not flash white.
    self.webView.opaque = NO;
    self.webView.backgroundColor = UIColor.clearColor;
    self.webView.scrollView.backgroundColor = UIColor.clearColor;
    self.webView.alpha = 0.0;
    [self insertSubview:self.webView atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    self.failureStack.hidden = YES;
    [self.spinner startAnimating];
    [self.webView loadRequest:[NSURLRequest requestWithURL:[SPKUpdateChecker changelogURL]
                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                           timeoutInterval:20.0]];
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    // Links in the notes (GitHub, Telegram) leave the app instead of replacing the changelog.
    if (navigationAction.navigationType == WKNavigationTypeLinkActivated && navigationAction.request.URL) {
        [UIApplication.sharedApplication openURL:navigationAction.request.URL options:@{} completionHandler:nil];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self.spinner stopAnimating];
    [UIView animateWithDuration:0.2 animations:^{
        webView.alpha = 1.0;
    }];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self showFailure:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self showFailure:error];
}

- (void)showFailure:(NSError *)error {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled)
        return;
    SPKLog(@"Update", @"Changelog failed to load: %@", error.localizedDescription);
    [self.spinner stopAnimating];
    [self.webView removeFromSuperview];
    // Dropped so Retry, or the next -loadIfNeeded, starts over.
    self.webView = nil;
    self.failureStack.hidden = NO;
}

#pragma mark - Actions

- (void)softTap {
    [self.softImpact impactOccurred];
    [self.softImpact prepare];
}

- (void)retryTapped {
    [self softTap];
    [self loadIfNeeded];
}

- (void)openInSafariTapped {
    [self softTap];
    [UIApplication.sharedApplication openURL:[SPKUpdateChecker changelogURL] options:@{} completionHandler:nil];
}

@end
