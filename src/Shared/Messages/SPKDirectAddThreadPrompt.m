#import "SPKStrings.h"
#import "SPKDirectAddThreadPrompt.h"

#import "../../Networking/SPKInstagramAPI.h"
#import "../../Utils.h"
#import "../ActionButton/ActionButtonLookupUtils.h"
#import "../UI/SPKIGAlertPresenter.h"

@implementation SPKDirectAddThreadPromptCopy
@end

static void SPKDirectAddThreadPresentError(UIViewController *host, NSString *title, NSString *message) {
    [SPKIGAlertPresenter presentAlertFromViewController:host
                                                  title:title
                                                message:message
                                                actions:@[ [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_OK")
                                                                                       style:SPKIGAlertActionStyleCancel
                                                                                     handler:nil] ]];
}

// A username is not enough on its own: these lists are keyed by thread, and a user you
// have never messaged has no thread to key on.
static void SPKDirectAddThreadResolveThread(UIViewController *host,
                                            SPKDirectAddThreadPromptCopy *copy,
                                            NSString *pk,
                                            NSString *username,
                                            NSString *fullName,
                                            NSString *profilePicUrl,
                                            void (^completion)(NSDictionary *entry, NSString *username)) {
    NSString *encodedRecipients = [[NSString stringWithFormat:@"[%@]", pk]
        stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    [SPKInstagramAPI sendRequestWithMethod:@"GET"
                                      path:[NSString stringWithFormat:@"direct_v2/threads/get_by_participants/?recipient_users=%@", encodedRecipients]
                                      body:nil
                                completion:^(NSDictionary *threadResponse, NSError *threadError) {
                                    NSDictionary *thread = threadResponse[@"thread"];
                                    NSString *threadId = [thread isKindOfClass:[NSDictionary class]]
                                                             ? SPKStringFromValue(thread[@"thread_id"] ?: thread[@"threadId"])
                                                             : nil;
                                    if (threadId.length == 0 || threadError) {
                                        SPKDirectAddThreadPresentError(host, copy.errorTitle,
                                                                       [NSString stringWithFormat:copy.noThreadFormat, username]);
                                        return;
                                    }

                                    NSMutableDictionary *userEntry = [@{@"pk" : pk, @"username" : username, @"fullName" : fullName} mutableCopy];
                                    if (profilePicUrl.length > 0)
                                        userEntry[@"profilePicUrl"] = profilePicUrl;
                                    NSDictionary *entry = @{
                                        @"threadId" : threadId,
                                        @"threadName" : SPKStringFromValue(thread[@"thread_title"]) ?: username,
                                        @"isGroup" : @(NO),
                                        @"users" : @[ userEntry.copy ],
                                    };

                                    NSString *message = fullName.length > 0
                                                            ? [NSString stringWithFormat:@"@%@ (%@)", username, fullName]
                                                            : [@"@" stringByAppendingString:username];
                                    [SPKIGAlertPresenter
                                        presentAlertFromViewController:host
                                                                 title:copy.confirmTitle
                                                               message:message
                                                               actions:@[
                                                                   [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL")
                                                                                               style:SPKIGAlertActionStyleCancel
                                                                                             handler:nil],
                                                                   [SPKIGAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_ADD")
                                                                                               style:SPKIGAlertActionStyleDefault
                                                                                             handler:^{
                                                                                                 completion(entry, username);
                                                                                             }],
                                                               ]];
                                }];
}

static void SPKDirectAddThreadLookupUsername(UIViewController *host,
                                             SPKDirectAddThreadPromptCopy *copy,
                                             NSString *rawUsername,
                                             void (^completion)(NSDictionary *entry, NSString *username)) {
    NSString *username = [SPKUtils sanitizedInstagramUsername:rawUsername];
    if (username.length == 0)
        return;

    [SPKInstagramAPI resolveUserForUsername:username
                                 completion:^(NSDictionary *user, NSError *error) {
                                     if (![user isKindOfClass:[NSDictionary class]] || error) {
                                         SPKDirectAddThreadPresentError(host, copy.errorTitle,
                                                                        [NSString stringWithFormat:copy.userNotFoundFormat, username]);
                                         return;
                                     }
                                     NSString *pk = SPKStringFromValue(user[@"pk"] ?: user[@"id"]);
                                     if (pk.length == 0) {
                                         SPKDirectAddThreadPresentError(host, copy.errorTitle, copy.unresolvedUserText);
                                         return;
                                     }
                                     SPKDirectAddThreadResolveThread(host,
                                                                     copy,
                                                                     pk,
                                                                     SPKStringFromValue(user[@"username"]) ?: username,
                                                                     SPKStringFromValue(user[@"full_name"] ?: user[@"fullName"]) ?: @"",
                                                                     SPKStringFromValue(user[@"profile_pic_url"] ?: user[@"profile_pic_url_hd"]),
                                                                     completion);
                                 }];
}

void SPKDirectPresentAddThreadPrompt(UIViewController *host,
                                     SPKDirectAddThreadPromptCopy *copy,
                                     void (^completion)(NSDictionary *entry, NSString *username)) {
    if (!host || !copy || !completion)
        return;
    [SPKIGAlertPresenter presentTextInputAlertFromViewController:host
                                                           title:copy.promptTitle
                                                         message:copy.promptMessage
                                                     placeholder:SPKL(@"INSTANTS_INSTANTS_AUTO_SAVE_USERNAME_TEXT")
                                                     initialText:nil
                                                 autocapitalized:NO
                                                    confirmTitle:SPKL(@"PROFILE_PROFILE_ANALYZER_LIST_SEARCH_TEXT")
                                                     cancelTitle:SPKL(@"VC_BTN_CANCEL")
                                                    confirmStyle:SPKIGAlertActionStyleDefault
                                                    confirmBlock:^(NSString *text) {
                                                        SPKDirectAddThreadLookupUsername(host, copy, text, completion);
                                                    }
                                                     cancelBlock:nil];
}
