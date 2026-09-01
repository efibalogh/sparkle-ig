#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "SPKStrings.h"

#import "../../AssetUtils.h"
#import "../../InstagramHeaders.h"
#import "../../Shared/Messages/SPKDirectHiddenChats.h"
#import "../../Shared/Messages/SPKDirectHiddenChatsLockManager.h"
#import "../../Shared/Messages/SPKDirectInboxMenu.h"
#import "../../Shared/Messages/SPKDirectSeenContext.h"
#import "../../Utils.h"

// Chats the user has hidden are removed from the inbox list, and brought back for
// as long as the inbox title is held down.
//
// Everything here re-reads its preferences at call time, so the toggles take
// effect without a restart. Filtering is deliberately confined to the inbox's own
// list: search, thread creation and the requests inbox keep showing the thread, so
// a hidden chat is never unreachable and the user can always long-press it back.

static const void *kSPKHiddenChatsGestureKey = &kSPKHiddenChatsGestureKey;

// The inbox currently on screen, so a change to the hidden set can re-diff the list
// the user is looking at without walking the view controller tree. Weak: the inbox
// is owned by its navigation stack and is torn down on account switches.
static __weak UIViewController *SPKHiddenChatsVisibleInbox;

// Unread threads currently being filtered out, refreshed on every inbox list pass.
// The badge subtracts this, so it can only be as fresh as the last inbox render:
// before the inbox has ever been built there is nothing to subtract and the badge
// is left exactly as Instagram computed it.
static NSUInteger SPKHiddenChatsUnreadCount = 0;

// Bumped on every change to the hidden set or the reveal state, and compared
// against what the inbox last rendered. Unhiding from the settings list happens
// while the inbox is off screen, and Instagram does not necessarily re-diff a list
// it did not change, so the inbox reloads itself on its way back when it is behind.
static NSUInteger SPKHiddenChatsGeneration = 0;
static NSUInteger SPKHiddenChatsRenderedGeneration = 0;

#pragma mark - Inbox list filtering

static BOOL SPKHiddenChatsViewModelIsThreadCell(id viewModel) {
    if (!viewModel)
        return NO;
    // Matched on the selector rather than the class: the thread cell view model is
    // one of the types Instagram has been migrating between ObjC and Swift, and its
    // class name is not stable across versions the way `threadId` is.
    return [viewModel respondsToSelector:@selector(threadId)];
}

static BOOL SPKHiddenChatsViewModelIsUnread(id viewModel) {
    if ([viewModel respondsToSelector:@selector(isUnseen)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, @selector(isUnseen)))
        return YES;
    if ([viewModel respondsToSelector:@selector(hasUnseenMessages)])
        return ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, @selector(hasUnseenMessages));
    return NO;
}

/// Membership test on the inbox hot path, which runs once per thread on every list
/// diff. The cheap case -- the thread's own id -- is one selector call and a set
/// lookup; the participant fallback that survives a changed thread id costs a walk
/// of the view model, so it only runs when the id missed.
static BOOL SPKHiddenChatsViewModelIsHidden(id viewModel) {
    NSString *threadId = nil;
    @try {
        threadId = ((NSString *(*)(id, SEL))objc_msgSend)(viewModel, @selector(threadId));
    } @catch (__unused NSException *exception) {
        threadId = nil;
    }
    if ([threadId isKindOfClass:[NSString class]] && SPKDirectHiddenChatListContainsThreadId(threadId))
        return YES;

    SPKDirectThreadContext *context = SPKDirectThreadContextFromInboxViewModel(viewModel);
    if (context.threadId.length == 0)
        return NO;
    return SPKDirectHiddenChatListContainsContext(context);
}

// Newest message timestamp on each side of the filter, and a counter so a waiting
// haptic can tell whether a fresh pass has run at all. Timestamps rather than unread
// counts: a second message into an already-unread chat leaves the count alone.
static NSTimeInterval SPKHiddenChatsNewestHiddenActivity;
static NSTimeInterval SPKHiddenChatsNewestVisibleActivity;
static NSUInteger SPKHiddenChatsFilterPassCount;

static NSTimeInterval SPKHiddenChatsViewModelActivity(id viewModel) {
    if (![viewModel respondsToSelector:@selector(mostRecentMessageActivityDate)])
        return 0;
    id date = ((id (*)(id, SEL))objc_msgSend)(viewModel, @selector(mostRecentMessageActivityDate));
    return [date isKindOfClass:[NSDate class]] ? ((NSDate *)date).timeIntervalSinceReferenceDate : 0;
}

static NSArray *SPKHiddenChatsFilterInboxObjects(NSArray *objects) {
    if (![objects isKindOfClass:[NSArray class]] || objects.count == 0)
        return objects;
    if (!SPKDirectHiddenChatsShouldFilterInbox()) {
        // Revealed (or nothing hidden): the badge must not keep subtracting a count
        // captured while the list was filtered.
        SPKHiddenChatsUnreadCount = 0;
        SPKHiddenChatsRenderedGeneration = SPKHiddenChatsGeneration;
        return objects;
    }

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:objects.count];
    NSUInteger unread = 0;
    NSTimeInterval newestHidden = 0;
    NSTimeInterval newestVisible = 0;
    for (id object in objects) {
        if (!SPKHiddenChatsViewModelIsThreadCell(object)) {
            [filtered addObject:object];
            continue;
        }
        if (!SPKHiddenChatsViewModelIsHidden(object)) {
            newestVisible = MAX(newestVisible, SPKHiddenChatsViewModelActivity(object));
            [filtered addObject:object];
            continue;
        }
        newestHidden = MAX(newestHidden, SPKHiddenChatsViewModelActivity(object));
        if (SPKHiddenChatsViewModelIsUnread(object))
            unread++;
    }

    SPKHiddenChatsUnreadCount = unread;
    SPKHiddenChatsRenderedGeneration = SPKHiddenChatsGeneration;
    SPKHiddenChatsNewestHiddenActivity = newestHidden;
    SPKHiddenChatsNewestVisibleActivity = newestVisible;
    SPKHiddenChatsFilterPassCount++;
    if (filtered.count != objects.count) {
        SPKLog(@"Messages", @"[Sparkle HiddenChats] Filtered inbox objects total=%lu shown=%lu unreadHidden=%lu",
               (unsigned long)objects.count,
               (unsigned long)filtered.count,
               (unsigned long)unread);
    }
    return filtered.copy;
}

%group SPKHiddenChatsInboxHooks

%hook IGDirectInboxListAdapterDataSource

- (id)objectsForListAdapter:(id)adapter {
    return SPKHiddenChatsFilterInboxObjects(%orig);
}

%end

%end

#pragma mark - Reveal

static void SPKHiddenChatsToggleReveal(void);
static void SPKHiddenChatsToggleShareReveal(UIView *source);
static void SPKHiddenChatsEndShareReveal(NSString *reason);
static BOOL SPKHiddenChatsShareRevealCoversController(UIViewController *controller);
static void SPKHiddenChatsScheduleShareRevealCheck(void);
static UIViewController *SPKHiddenChatsRecipientListForView(UIView *view);
static BOOL SPKHiddenChatsShareRevealAvailable(void);

@interface SPKHiddenChatsRevealGestureTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SPKHiddenChatsRevealGestureTarget

+ (instancetype)shared {
    static SPKHiddenChatsRevealGestureTarget *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [self new];
    });
    return shared;
}

/// Re-diffs a list Instagram owns so a change to the hidden set takes effect
/// immediately. Without this the list keeps whatever `objectsForListAdapter:` last
/// returned until Instagram happens to update it, so hiding a chat appears to do
/// nothing until the screen is left and re-entered. Used by the inbox and by the
/// share sheet's recipient list, which are two different classes around one adapter.
+ (void)spk_reloadListForViewController:(UIViewController *)controller {
    if (!controller)
        return;
    id adapter = nil;
    if ([controller respondsToSelector:@selector(listAdapter)])
        adapter = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(listAdapter));
    if (!adapter)
        adapter = [SPKUtils getIvarForObj:controller name:"_listAdapter"];
    if (!adapter)
        adapter = [SPKUtils getIvarForObj:controller name:"listAdapter"];
    SEL performUpdates = @selector(performUpdatesAnimated:completion:);
    if (![adapter respondsToSelector:performUpdates]) {
        SPKLog(@"Messages", @"[Sparkle HiddenChats] List reload skipped: adapter=%@<%p> cannot perform updates",
               NSStringFromClass([adapter class]),
               adapter);
        return;
    }
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(adapter, performUpdates, YES, nil);
}

- (void)spk_handleTitleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan)
        return;
    SPKHiddenChatsToggleReveal();
}

- (void)spk_handleShareRevealLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan)
        return;
    SPKHiddenChatsToggleShareReveal(recognizer.view);
}

/// Set only on the share sheet recogniser. It recognises, and so cancels the button's
/// own tap, exactly when the long press is going to do something: inside a recipient
/// list, with the feature on and something to show. Everywhere else it never begins,
/// and the facepile button keeps opening the group composer on a held finger the way
/// Instagram intends.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    return SPKHiddenChatsShareRevealAvailable() && SPKHiddenChatsRecipientListForView(recognizer.view) != nil;
}

@end

/// Flips the reveal and reports what happened. The list itself is re-diffed by the
/// change observer, which also covers a reveal ending on its own.
static void SPKHiddenChatsToggleReveal(void) {
    if (!SPKDirectHiddenChatsEnabled())
        return;
    if (SPKDirectHiddenChatCount() == 0 && !SPKDirectHiddenChatsRevealed()) {
        // Nothing to reveal. Saying so beats a gesture that silently does nothing,
        // since the user cannot see the list they are asking for either way.
        SPKNotify(kSPKNotificationDirectHiddenChat,
                  SPKL(@"MESSAGES_HIDDEN_CHATS_NONE_HIDDEN_TITLE"),
                  SPKL(@"MESSAGES_HIDDEN_CHATS_NONE_HIDDEN_SUBTITLE"),
                  @"eye_off",
                  SPKNotificationToneInfo);
        return;
    }

    if (SPKDirectHiddenChatsRevealed()) {
        SPKDirectSetHiddenChatsRevealed(NO);
        SPKNotify(kSPKNotificationDirectHiddenChat,
                  SPKL(@"MESSAGES_HIDDEN_CHATS_CONCEALED_TITLE"),
                  nil,
                  @"eye_off",
                  SPKNotificationToneInfo);
        return;
    }

    // Authentication guards the reveal only, never the concealing above: locking the
    // list back up must always be possible, including when biometrics just failed.
    SPKDirectHiddenChatsAuthenticate(SPKHiddenChatsVisibleInbox, ^(BOOL granted) {
        if (!granted)
            return;
        SPKDirectSetHiddenChatsRevealed(YES);
        SPKNotify(kSPKNotificationDirectHiddenChat,
                  SPKL(@"MESSAGES_HIDDEN_CHATS_REVEALED_TITLE"),
                  nil,
                  @"eye",
                  SPKNotificationToneInfo);
    });
}

#pragma mark - Reveal gesture: Instagram's own title long press

// The inbox header already recognises a long press on its title and forwards it to
// its delegate, so the reveal rides on that recogniser instead of adding a second
// one to the same label, where the two would compete for the touch. The callback is
// underscore prefixed on older builds and unprefixed on the Swift header view.
static void (*SPKHiddenChatsOrigTitleLongPress)(id, SEL, id);

static void SPKHiddenChatsTitleLongPress(id self, SEL _cmd, id recognizer) {
    SPKHiddenChatsOrigTitleLongPress(self, _cmd, recognizer);
    if ([recognizer isKindOfClass:[UIGestureRecognizer class]] &&
        ((UIGestureRecognizer *)recognizer).state != UIGestureRecognizerStateBegan)
        return;
    SPKHiddenChatsToggleReveal();
}

static BOOL SPKHiddenChatsInstallTitleLongPressHook(void) {
    Class headerClass = SPKResolveIGClass(@"IGDirectInboxNavigationHeaderView.IGDirectInboxNavigationHeaderView",
                                          @"IGDirectInboxNavigationHeaderView");
    if (!headerClass)
        return NO;

    for (NSString *name in @[ @"titleLabelLongPressed:", @"_titleLabelLongPressed:" ]) {
        SEL selector = NSSelectorFromString(name);
        if (!class_getInstanceMethod(headerClass, selector))
            continue;
        MSHookMessageEx(headerClass, selector, (IMP)SPKHiddenChatsTitleLongPress, (IMP *)&SPKHiddenChatsOrigTitleLongPress);
        SPKLog(@"Messages", @"[Sparkle HiddenChats] Reveal riding on the header title long press class=%@ selector=%@",
               NSStringFromClass(headerClass),
               name);
        return YES;
    }
    return NO;
}

#pragma mark - Reveal gesture: fallback recogniser

/// The title label the fallback gesture attaches to. Instance variables are
/// underscore prefixed on the older view controller and unprefixed on the Swift one,
/// and the title is drawn either as a plain label or inside a navigation header, so
/// each spelling is tried before giving up.
static UIView *SPKHiddenChatsTitleView(UIViewController *inbox) {
    for (NSString *name in @[ @"_titleLabelView", @"titleLabelView" ]) {
        UIView *label = [SPKUtils getIvarForObj:inbox name:name.UTF8String];
        if ([label isKindOfClass:[UILabel class]])
            return label;
    }

    for (NSString *name in @[ @"_navigationHeaderView", @"navigationHeaderView" ]) {
        UIView *header = [SPKUtils getIvarForObj:inbox name:name.UTF8String];
        if (![header isKindOfClass:[UIView class]])
            continue;
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:header];
        // Breadth-first and shallow on purpose: the title sits near the top of the
        // header, and a deep walk on every appearance is exactly the kind of tree
        // traversal that shows up as navigation lag.
        for (NSUInteger depth = 0; depth < 3 && queue.count > 0; depth++) {
            NSMutableArray<UIView *> *next = [NSMutableArray array];
            for (UIView *view in queue) {
                if ([view isKindOfClass:[UILabel class]] && ((UILabel *)view).text.length > 0)
                    return view;
                [next addObjectsFromArray:view.subviews];
            }
            queue = next;
        }
    }

    UIView *titleView = inbox.navigationItem.titleView;
    return [titleView isKindOfClass:[UIView class]] ? titleView : nil;
}

static void SPKHiddenChatsInstallRevealGesture(UIViewController *inbox) {
    if (!SPKDirectHiddenChatsEnabled())
        return;
    if (objc_getAssociatedObject(inbox, kSPKHiddenChatsGestureKey))
        return;

    UIView *titleView = SPKHiddenChatsTitleView(inbox);
    if (!titleView) {
        SPKLog(@"Messages", @"[Sparkle HiddenChats] Reveal gesture not installed: no inbox title view");
        return;
    }

    titleView.userInteractionEnabled = YES;
    UILongPressGestureRecognizer *recognizer =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[SPKHiddenChatsRevealGestureTarget shared]
                                                      action:@selector(spk_handleTitleLongPress:)];
    // Instagram puts its own gestures on the header (the account switcher among
    // them); ours must not cancel them when it does nothing.
    recognizer.cancelsTouchesInView = NO;
    [titleView addGestureRecognizer:recognizer];
    objc_setAssociatedObject(inbox, kSPKHiddenChatsGestureKey, recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPKLog(@"Messages", @"[Sparkle HiddenChats] Installed fallback reveal gesture on %@<%p>",
           NSStringFromClass([titleView class]),
           titleView);
}

#pragma mark - Inbox lifecycle

// NO while the reveal rides on Instagram's own title long press, which is the normal
// case; the fallback recogniser is only added when that callback is missing.
static BOOL SPKHiddenChatsNeedsFallbackGesture = NO;

static void SPKHiddenChatsNoteInboxAppeared(UIViewController *inbox) {
    SPKHiddenChatsVisibleInbox = inbox;
    if (SPKHiddenChatsNeedsFallbackGesture)
        SPKHiddenChatsInstallRevealGesture(inbox);
    if (SPKDirectHiddenChatsEnabled() && SPKHiddenChatsRenderedGeneration != SPKHiddenChatsGeneration)
        [SPKHiddenChatsRevealGestureTarget spk_reloadListForViewController:inbox];
}

/// Opening a chat from a revealed list must not end the reveal, or coming back from
/// a hidden chat would find it gone. A pushed thread leaves the inbox on its own
/// navigation stack with something above it; every other way of leaving (switching
/// tabs, popping the inbox) leaves the inbox itself on top or off the stack.
static void SPKHiddenChatsNoteInboxDisappeared(UIViewController *inbox) {
    if (SPKHiddenChatsVisibleInbox == inbox)
        SPKHiddenChatsVisibleInbox = nil;
    UINavigationController *navigation = inbox.navigationController;
    if (navigation && navigation.topViewController != inbox && [navigation.viewControllers containsObject:inbox])
        return;
    SPKDirectHiddenChatsNoteLeftInbox();
}

%group SPKHiddenChatsRevealHooks

%hook IGDirectInboxViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SPKHiddenChatsNoteInboxAppeared(self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SPKHiddenChatsNoteInboxDisappeared(self);
}

%end

%end

// The Swift inbox view controller that replaced the ObjC one on newer builds is a
// separate class, not a subclass, so it needs the same two hooks. Which one backs
// the inbox is a server decision, so both are installed and whichever runs wins.
%group SPKHiddenChatsRevealSwiftHooks

%hook IGDirectInboxSwiftViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SPKHiddenChatsNoteInboxAppeared(self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SPKHiddenChatsNoteInboxDisappeared(self);
}

%end

%end

#pragma mark - Notification suppression

/// YES when a notification payload names a hidden thread.
///
/// Instagram's DM payload shape changes between versions and between transports
/// (the realtime copy and the push copy carry different key sets), so rather than
/// depending on one key this looks for a hidden thread id anywhere in the payload.
/// Thread ids are long and effectively unique, so a value match is not ambiguous.
static BOOL SPKHiddenChatsPayloadNamesHiddenThread(id value, NSUInteger depth) {
    if (depth > 3 || !value)
        return NO;

    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)value;
        if (string.length < 8)
            return NO;
        for (NSDictionary *entry in SPKDirectHiddenChatList()) {
            NSString *threadId = [entry[@"threadId"] isKindOfClass:[NSString class]] ? entry[@"threadId"] : nil;
            if (threadId.length >= 8 && [string rangeOfString:threadId].location != NSNotFound)
                return YES;
        }
        return NO;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        for (id nested in ((NSDictionary *)value).allValues) {
            if (SPKHiddenChatsPayloadNamesHiddenThread(nested, depth + 1))
                return YES;
        }
        return NO;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        for (id nested in (NSArray *)value) {
            if (SPKHiddenChatsPayloadNamesHiddenThread(nested, depth + 1))
                return YES;
        }
    }
    return NO;
}

static BOOL SPKHiddenChatsShouldSuppressNotification(UNNotificationRequest *request) {
    if (!SPKDirectHiddenChatsEnabled() || ![SPKUtils getBoolPref:@"msgs_hidden_chats_mute_notifications"])
        return NO;
    if (SPKDirectHiddenChatCount() == 0)
        return NO;
    return SPKHiddenChatsPayloadNamesHiddenThread(request.content.userInfo, 0);
}

%group SPKHiddenChatsNotificationHooks

%hook UNUserNotificationCenter

- (void)addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void (^)(NSError *error))completionHandler {
    // Installed from the surface registry, which already honours the master kill
    // switch, but this also runs off the main thread on a push, so the pref read is
    // kept as the only work done before falling through.
    if (!SPKHiddenChatsShouldSuppressNotification(request)) {
        %orig;
        return;
    }

    SPKLog(@"Messages", @"[Sparkle HiddenChats] Suppressed notification for hidden chat identifier=%@", request.identifier ?: @"(none)");
    // Drop it, but satisfy the API contract by completing without an error.
    if (completionHandler)
        completionHandler(nil);
}

%end

%end

#pragma mark - Badge exclusion

static unsigned long long SPKHiddenChatsAdjustedCount(unsigned long long count) {
    if (!SPKDirectHiddenChatsEnabled() || ![SPKUtils getBoolPref:@"msgs_hidden_chats_exclude_badge"])
        return count;
    if (SPKHiddenChatsUnreadCount == 0 || SPKDirectHiddenChatsRevealed())
        return count;
    return count > SPKHiddenChatsUnreadCount ? count - SPKHiddenChatsUnreadCount : 0;
}

%group SPKHiddenChatsBadgeHooks

%hook IGBadgeData

- (unsigned long long)directMessagesServerCalculated {
    return SPKHiddenChatsAdjustedCount(%orig);
}

- (NSNumber *)directMessagesClientCalculated {
    NSNumber *original = %orig;
    if (![original isKindOfClass:[NSNumber class]])
        return original;
    unsigned long long adjusted = SPKHiddenChatsAdjustedCount(original.unsignedLongLongValue);
    return adjusted == original.unsignedLongLongValue ? original : @(adjusted);
}

%end

%end

#pragma mark - Share sheet recipients

// The share sheet opens on the people Instagram ranks you as messaging most, which is
// the one other place a hidden chat announces itself without being asked for. It is
// filtered on the same terms as the inbox, and like the inbox only in its resting
// state: as soon as there is a search query the full list is handed back, so a hidden
// chat is still reachable by name and nothing becomes un-shareable.
// Revealing inside the share sheet is deliberately its own state rather than the
// inbox reveal: sharing to a hidden chat is a one-off errand, and borrowing the inbox
// reveal for it would leave the inbox itself unhidden afterwards. It is never
// persisted and is dropped when the sheet goes away, so every sheet opens hidden.
static BOOL SPKHiddenChatsShareRevealed = NO;

/// A reveal that ends has to re-arm the lock, or the unlock it was granted would make
/// every later reveal free for as long as the app stayed alive. The inbox reveal does
/// this from its own state setter; while that reveal is still up it owns the lock and
/// will re-arm it when it ends, so this only acts when the share sheet was the last
/// thing holding it open.
static void SPKHiddenChatsRearmLock(void) {
    if (SPKDirectHiddenChatsRevealed())
        return;
    [[SPKDirectHiddenChatsLockManager sharedManager] lockContent];
}

// The recipient list on screen, so the long press can re-diff the list it belongs to
// without walking the view controller tree.
static __weak UIViewController *SPKHiddenChatsVisibleRecipientList;

// Every recipient list currently on screen, weakly held.
static NSHashTable<UIViewController *> *SPKHiddenChatsVisibleRecipientLists(void) {
    static NSHashTable *lists;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lists = [NSHashTable weakObjectsHashTable];
    });
    return lists;
}

// The recipient lists taking part in the current reveal, weakly held. Appearance
// callbacks turned out to be the wrong signal for when a reveal is over: tapping the
// search field hands the sheet to a full screen list whose appearance is reported
// late enough that the sheet looks closed in between. Object lifetime is the honest
// signal instead. While any list that has drawn revealed chats is still alive, the
// sheet is still up; when the sheet closes they all deallocate together.
static NSHashTable<UIViewController *> *SPKHiddenChatsRevealParticipants(void) {
    static NSHashTable *participants;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        participants = [NSHashTable weakObjectsHashTable];
    });
    return participants;
}

/// Re-read at call time like every other Sparkle preference, so the toggle takes
/// effect on the next sheet without a restart.
static BOOL SPKHiddenChatsShareSheetFilterEnabled(void) {
    return SPKDirectHiddenChatsEnabled() && [SPKUtils getBoolPref:@"msgs_hidden_chats_hide_in_share_sheet"];
}

static BOOL SPKHiddenChatsIsRecipientListController(UIViewController *controller) {
    if (!controller)
        return NO;
    for (NSString *name in @[ @"IGDirectRecipientListViewController",
                              @"IGDirectRecipientPickerViewController",
                              @"IGDirectThreadCreationViewController" ]) {
        Class controllerClass = NSClassFromString(name);
        if (controllerClass && [controller isKindOfClass:controllerClass])
            return YES;
    }
    return NO;
}

/// The recipient list a view belongs to. The search bar can be owned by a child view
/// controller, so the nearest one is only the starting point.
static UIViewController *SPKHiddenChatsRecipientListForView(UIView *view) {
    UIViewController *controller = [SPKUtils nearestViewControllerForView:view];
    for (NSUInteger depth = 0; controller && depth < 4; depth++, controller = controller.parentViewController) {
        if (SPKHiddenChatsIsRecipientListController(controller))
            return controller;
    }
    return nil;
}

static BOOL SPKHiddenChatsRecipientIsHidden(id recipient) {
    if (![recipient respondsToSelector:@selector(threadID)])
        return NO;
    NSString *threadId = ((NSString *(*)(id, SEL))objc_msgSend)(recipient, @selector(threadID));
    if ([threadId isKindOfClass:[NSString class]] && SPKDirectHiddenChatListContainsThreadId(threadId))
        return YES;

    // Participant fallback, for the same reason the inbox has one: a suggested
    // recipient can carry no thread id at all, and an existing thread's id changes
    // when a request is accepted or a group is re-created.
    if (![recipient respondsToSelector:@selector(users)])
        return NO;
    NSArray *users = ((NSArray *(*)(id, SEL))objc_msgSend)(recipient, @selector(users));
    if (![users isKindOfClass:[NSArray class]] || users.count == 0)
        return NO;
    NSMutableArray<NSString *> *pks = [NSMutableArray arrayWithCapacity:users.count];
    for (id user in users) {
        NSString *pk = [SPKUtils pkFromIGUser:user];
        if (pk.length > 0)
            [pks addObject:pk];
    }
    if (pks.count == 0)
        return NO;
    BOOL isGroup = [recipient respondsToSelector:@selector(isGroupThread)] &&
                   ((BOOL (*)(id, SEL))objc_msgSend)(recipient, @selector(isGroupThread));
    return SPKDirectHiddenChatListContainsParticipants(pks, isGroup);
}

/// The picker's own search field. Read from the ivar rather than tracked through the
/// delegate callbacks, so a list rebuilt for any other reason still sees the query
/// that is on screen.
static const void *kSPKHiddenChatsSearchQueryKey = &kSPKHiddenChatsSearchQueryKey;

/// Instagram's own search delegate callback is the only reliable query source here:
/// the full screen search list draws its field from a container, so the controller's
/// own search bar reads empty while results are narrowing on every keystroke.
static void SPKHiddenChatsNoteSearchQuery(id controller, id text) {
    NSString *query = [text isKindOfClass:[NSString class]] ? text : nil;
    objc_setAssociatedObject(controller, kSPKHiddenChatsSearchQueryKey, query.length > 0 ? query : nil,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static NSString *SPKHiddenChatsRecipientSearchText(id controller) {
    NSString *recorded = objc_getAssociatedObject(controller, kSPKHiddenChatsSearchQueryKey);
    if (recorded.length > 0)
        return recorded;
    id searchBar = [SPKUtils getIvarForObj:controller name:"_searchBar"];
    if ([searchBar respondsToSelector:@selector(text)]) {
        id text = ((id (*)(id, SEL))objc_msgSend)(searchBar, @selector(text));
        if ([text isKindOfClass:[NSString class]])
            return text;
    }
    // The new message composer types into a token field rather than a search bar and
    // keeps the live query here.
    id query = [SPKUtils getIvarForObj:controller name:"_currSearchQuery"];
    return [query isKindOfClass:[NSString class]] ? query : nil;
}

static NSArray *SPKHiddenChatsFilterRecipientObjects(id controller, NSArray *objects) {
    if (![objects isKindOfClass:[NSArray class]] || objects.count == 0)
        return objects;
    if (SPKHiddenChatsShareRevealed) {
        if (![controller isKindOfClass:[UIViewController class]] ||
            SPKHiddenChatsShareRevealCoversController(controller)) {
            // Whichever list is drawing the revealed chats keeps the reveal alive, so a
            // hand off into search carries it even though the first list is off screen.
            if ([controller isKindOfClass:[UIViewController class]])
                [SPKHiddenChatsRevealParticipants() addObject:controller];
            return objects;
        }
        // A different sheet is asking, so this reveal was for a share that is over.
        // Ended here rather than on the timer, so the new sheet is never drawn revealed.
        SPKHiddenChatsEndShareReveal(@"another sheet opened");
    }
    if (!SPKHiddenChatsShareSheetFilterEnabled() || !SPKDirectHiddenChatsShouldFilterInbox())
        return objects;
    if (SPKHiddenChatsRecipientSearchText(controller).length > 0)
        return objects;

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:objects.count];
    for (id object in objects) {
        id recipient = nil;
        if ([object respondsToSelector:@selector(recipient)])
            recipient = ((id (*)(id, SEL))objc_msgSend)(object, @selector(recipient));
        if (recipient && SPKHiddenChatsRecipientIsHidden(recipient))
            continue;
        [filtered addObject:object];
    }
    if (filtered.count != objects.count) {
        SPKLog(@"Messages", @"[Sparkle HiddenChats] Filtered recipients on %@ total=%lu shown=%lu query=%lu",
               NSStringFromClass([controller class]),
               (unsigned long)objects.count,
               (unsigned long)filtered.count,
               (unsigned long)SPKHiddenChatsRecipientSearchText(controller).length);
    }
    return filtered.copy;
}

// The modal the reveal belongs to. Instagram keeps its recipient list controllers
// alive after a sheet is dismissed, so object lifetime says nothing about whether the
// sheet is still up and a reveal leaked into every later share. The presentation does
// say it: a dismissed controller loses its presentingViewController, and a later sheet
// is a different presentation entirely.
static __weak UIViewController *SPKHiddenChatsShareRevealPresentation;
static BOOL SPKHiddenChatsShareRevealScoped = NO;

/// The presented modal a controller sits inside, or nil when it is not in one.
static UIViewController *SPKHiddenChatsPresentationForController(UIViewController *controller) {
    UIViewController *outermost = controller;
    for (NSUInteger depth = 0; depth < 8 && outermost.parentViewController; depth++)
        outermost = outermost.parentViewController;
    return outermost.presentingViewController ? outermost : nil;
}

/// YES while `controller` is inside the modal the reveal was granted in, or inside
/// something presented on top of it. Entering search puts a full screen list above the
/// sheet, which is still the same share; a second sheet is not.
static BOOL SPKHiddenChatsShareRevealCoversController(UIViewController *controller) {
    if (!SPKHiddenChatsShareRevealScoped)
        return YES;
    UIViewController *presentation = SPKHiddenChatsShareRevealPresentation;
    if (!presentation || !presentation.presentingViewController)
        return NO;
    UIViewController *node = SPKHiddenChatsPresentationForController(controller);
    // Walked upwards through presenters only. Descending through presentedViewController
    // instead would revisit the same branches and is a known way to hang the app.
    for (NSUInteger depth = 0; depth < 8 && node; depth++) {
        if (node == presentation)
            return YES;
        node = SPKHiddenChatsPresentationForController(node.presentingViewController);
    }
    return NO;
}

/// Whether a share sheet long press has anything to do. Also the gate on cancelling
/// the button's tap, so a sheet with nothing hidden behaves exactly like stock.
static BOOL SPKHiddenChatsShareRevealAvailable(void) {
    if (!SPKHiddenChatsShareSheetFilterEnabled())
        return NO;
    return SPKHiddenChatsShareRevealed || SPKDirectHiddenChatCount() > 0;
}

static void SPKHiddenChatsToggleShareReveal(UIView *source) {
    UIViewController *host = SPKHiddenChatsRecipientListForView(source) ?: SPKHiddenChatsVisibleRecipientList;
    if (!host) {
        // The same button also sits in the inbox search bar, where the reveal belongs
        // to the title long press. Doing nothing there is intentional.
        SPKLog(@"Messages", @"[Sparkle HiddenChats] Share reveal long press outside a recipient list, ignored");
        return;
    }
    if (!SPKHiddenChatsShareSheetFilterEnabled())
        return;
    if (SPKDirectHiddenChatCount() == 0 && !SPKHiddenChatsShareRevealed) {
        SPKNotify(kSPKNotificationDirectHiddenChat,
                  SPKL(@"MESSAGES_HIDDEN_CHATS_NONE_HIDDEN_TITLE"),
                  SPKL(@"MESSAGES_HIDDEN_CHATS_NONE_HIDDEN_SUBTITLE"),
                  @"eye_off",
                  SPKNotificationToneInfo);
        return;
    }

    if (SPKHiddenChatsShareRevealed) {
        SPKHiddenChatsEndShareReveal(@"toggled off");
        [SPKHiddenChatsRevealGestureTarget spk_reloadListForViewController:host];
        SPKNotify(kSPKNotificationDirectHiddenChat,
                  SPKL(@"MESSAGES_HIDDEN_CHATS_CONCEALED_TITLE"),
                  nil,
                  @"eye_off",
                  SPKNotificationToneInfo);
        return;
    }

    SPKDirectHiddenChatsAuthenticate(host, ^(BOOL granted) {
        if (!granted)
            return;
        SPKHiddenChatsShareRevealed = YES;
        SPKHiddenChatsShareRevealPresentation = SPKHiddenChatsPresentationForController(host);
        SPKHiddenChatsShareRevealScoped = SPKHiddenChatsShareRevealPresentation != nil;
        [SPKHiddenChatsRevealParticipants() addObject:host];
        SPKHiddenChatsScheduleShareRevealCheck();
        SPKLog(@"Messages", @"[Sparkle HiddenChats] Share sheet reveal scoped to %@",
               SPKHiddenChatsShareRevealScoped ? NSStringFromClass([SPKHiddenChatsShareRevealPresentation class])
                                               : @"(no modal, list lifetime)");
        [SPKHiddenChatsRevealGestureTarget spk_reloadListForViewController:host];
        SPKNotify(kSPKNotificationDirectHiddenChat,
                  SPKL(@"MESSAGES_HIDDEN_CHATS_REVEALED_TITLE"),
                  SPKL(@"MESSAGES_HIDDEN_CHATS_SHARE_REVEAL_SUBTITLE"),
                  @"eye",
                  SPKNotificationToneInfo);
    });
}

static const NSTimeInterval kSPKHiddenChatsShareRevealGrace = 1.5;

static void SPKHiddenChatsNoteRecipientListAppeared(UIViewController *controller) {
    SPKHiddenChatsVisibleRecipientList = controller;
    [SPKHiddenChatsVisibleRecipientLists() addObject:controller];
}

/// A closed sheet drops the reveal, so the next share starts hidden again. Checked one
/// runloop later rather than here: entering search replaces one recipient list with
/// another, and the outgoing list's disappearance can be reported either side of the
/// incoming list's appearance. Only when nothing is left has the sheet really gone.
static void SPKHiddenChatsEndShareReveal(NSString *reason) {
    if (!SPKHiddenChatsShareRevealed)
        return;
    SPKHiddenChatsShareRevealed = NO;
    SPKHiddenChatsShareRevealPresentation = nil;
    SPKHiddenChatsShareRevealScoped = NO;
    [SPKHiddenChatsRevealParticipants() removeAllObjects];
    SPKHiddenChatsRearmLock();
    SPKLog(@"Messages", @"[Sparkle HiddenChats] Share sheet reveal ended (%@)", reason);
}

/// Polls for the sheet having gone. Runs only while a reveal is up, which is rare and
/// short, and stops itself the moment the reveal ends.
static void SPKHiddenChatsScheduleShareRevealCheck(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKHiddenChatsShareRevealGrace * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!SPKHiddenChatsShareRevealed)
            return;
        if (SPKHiddenChatsShareRevealScoped) {
            UIViewController *presentation = SPKHiddenChatsShareRevealPresentation;
            if (presentation && presentation.presentingViewController) {
                SPKHiddenChatsScheduleShareRevealCheck();
                return;
            }
            SPKHiddenChatsEndShareReveal(@"sheet dismissed");
            return;
        }
        if (SPKHiddenChatsRevealParticipants().count > 0) {
            SPKHiddenChatsScheduleShareRevealCheck();
            return;
        }
        SPKHiddenChatsEndShareReveal(@"sheet closed");
    });
}

static void SPKHiddenChatsNoteRecipientListDisappeared(UIViewController *controller) {
    if (SPKHiddenChatsVisibleRecipientList == controller)
        SPKHiddenChatsVisibleRecipientList = nil;
    [SPKHiddenChatsVisibleRecipientLists() removeObject:controller];
}

static const void *kSPKHiddenChatsShareGestureKey = &kSPKHiddenChatsShareGestureKey;

/// The facepile button in the recipient search bar is the one control that is always
/// there, never scrolls away and carries no long press of its own, so the reveal can
/// ride on it without competing for a touch.
static void SPKHiddenChatsInstallShareRevealGesture(UIView *button) {
    if (!button || !SPKDirectHiddenChatsEnabled())
        return;
    // The recogniser is attached whatever the share sheet preference says and asks
    // again in its delegate, so turning the preference on mid-session does not leave
    // the buttons already on screen without a gesture.
    if (objc_getAssociatedObject(button, kSPKHiddenChatsShareGestureKey))
        return;

    UILongPressGestureRecognizer *recognizer =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[SPKHiddenChatsRevealGestureTarget shared]
                                                      action:@selector(spk_handleShareRevealLongPress:)];
    // Lifting the finger after a recognised long press would otherwise still send the
    // button its tap and open the group composer on top of the reveal. Cancelling the
    // touch only happens once the press is recognised, and the delegate below keeps it
    // from being recognised at all where the reveal does nothing, so an ordinary tap
    // and a held finger on any other screen are both untouched.
    recognizer.cancelsTouchesInView = YES;
    recognizer.delegate = [SPKHiddenChatsRevealGestureTarget shared];
    [button addGestureRecognizer:recognizer];
    objc_setAssociatedObject(button, kSPKHiddenChatsShareGestureKey, recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%group SPKHiddenChatsShareRevealGestureHooks

%hook IGSearchBarNewGroupFacepileButton

- (void)layoutSubviews {
    %orig;
    SPKHiddenChatsInstallShareRevealGesture((UIView *)self);
}

%end

%end

/// Direct's own search screen shows a recents list before anything is typed, built
/// from the same recipient models. That list is offered unasked, so it is filtered
/// like the share sheet; results for a typed query are not, so a hidden chat stays
/// findable by name.
static NSArray *SPKHiddenChatsFilterInboxSearchObjects(id dataSource, NSArray *objects) {
    if (![objects isKindOfClass:[NSArray class]] || objects.count == 0)
        return objects;
    if (SPKHiddenChatsShareRevealed || !SPKHiddenChatsShareSheetFilterEnabled() || !SPKDirectHiddenChatsShouldFilterInbox())
        return objects;
    if ([dataSource respondsToSelector:@selector(queryString)]) {
        NSString *query = ((NSString *(*)(id, SEL))objc_msgSend)(dataSource, @selector(queryString));
        if ([query isKindOfClass:[NSString class]] && query.length > 0)
            return objects;
    }

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:objects.count];
    for (id object in objects) {
        id recipient = nil;
        if ([object respondsToSelector:@selector(recipient)])
            recipient = ((id (*)(id, SEL))objc_msgSend)(object, @selector(recipient));
        if (recipient && SPKHiddenChatsRecipientIsHidden(recipient))
            continue;
        [filtered addObject:object];
    }
    if (filtered.count != objects.count) {
        SPKLog(@"Messages", @"[Sparkle HiddenChats] Filtered inbox search recents total=%lu shown=%lu",
               (unsigned long)objects.count,
               (unsigned long)filtered.count);
    }
    return filtered.copy;
}

%group SPKHiddenChatsInboxSearchHooks

%hook IGDirectInboxSearchListAdapterDataSource

- (id)objectsForListAdapter:(id)adapter {
    return SPKHiddenChatsFilterInboxSearchObjects(self, %orig);
}

%end

%end

%group SPKHiddenChatsShareSheetHooks

%hook IGDirectRecipientListViewController

- (id)objectsForListAdapter:(id)adapter {
    return SPKHiddenChatsFilterRecipientObjects(self, %orig);
}

- (void)searchBar:(id)searchBar didChangeSearchText:(id)text {
    %orig;
    SPKHiddenChatsNoteSearchQuery(self, text);
}

- (void)_searchCancelTapped {
    %orig;
    SPKHiddenChatsNoteSearchQuery(self, nil);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SPKHiddenChatsNoteRecipientListAppeared((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SPKHiddenChatsNoteRecipientListDisappeared((UIViewController *)self);
}

%end

%end

%group SPKHiddenChatsThreadCreationHooks

%hook IGDirectThreadCreationViewController

- (id)objectsForListAdapter:(id)adapter {
    return SPKHiddenChatsFilterRecipientObjects(self, %orig);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SPKHiddenChatsNoteRecipientListAppeared((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SPKHiddenChatsNoteRecipientListDisappeared((UIViewController *)self);
}

%end

%end

%group SPKHiddenChatsRecipientPickerHooks

%hook IGDirectRecipientPickerViewController

- (id)objectsForListAdapter:(id)adapter {
    return SPKHiddenChatsFilterRecipientObjects(self, %orig);
}

- (void)searchBar:(id)searchBar didChangeSearchText:(id)text {
    %orig;
    SPKHiddenChatsNoteSearchQuery(self, text);
}

- (void)_searchCancelTapped {
    %orig;
    SPKHiddenChatsNoteSearchQuery(self, nil);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SPKHiddenChatsNoteRecipientListAppeared((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SPKHiddenChatsNoteRecipientListDisappeared((UIViewController *)self);
}

%end

%end

#pragma mark - Inbox haptic

// Instagram plays a local haptic when a message lands while the inbox is on screen.
// That is not the push, so muting the thread on the account does not touch it, and a
// hidden chat still buzzes the device it is hidden on.
//
// The only method reachable from Objective-C is the helper's generate:, which is handed
// a feedback style and nothing about the thread, and it runs about 15ms BEFORE the list
// diff that would say which thread moved. So the haptic is held rather than dropped:
// once the diff lands, the newest message timestamp on each side of the filter says
// whether the message belongs to a hidden chat, and the haptic is either played late or
// abandoned. Anything ambiguous plays, because a missing buzz is worse than a late one.
static const NSTimeInterval kSPKHiddenChatsHapticDecisionDelay = 0.15;
static void (*SPKHiddenChatsOrigGenerateHaptic)(id, SEL, unsigned long long);

static BOOL SPKHiddenChatsShouldFilterHaptics(void) {
    return SPKDirectHiddenChatsEnabled() && [SPKUtils getBoolPref:@"msgs_hidden_chats_mute_notifications"] &&
           !SPKDirectHiddenChatsRevealed() && SPKDirectHiddenChatCount() > 0;
}

static void SPKHiddenChatsGenerateHaptic(id self, SEL _cmd, unsigned long long style) {
    if (!SPKHiddenChatsShouldFilterHaptics()) {
        SPKHiddenChatsOrigGenerateHaptic(self, _cmd, style);
        return;
    }

    NSTimeInterval hiddenBefore = SPKHiddenChatsNewestHiddenActivity;
    NSTimeInterval visibleBefore = SPKHiddenChatsNewestVisibleActivity;
    NSUInteger passBefore = SPKHiddenChatsFilterPassCount;
    __strong id helper = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPKHiddenChatsHapticDecisionDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       BOOL diffed = SPKHiddenChatsFilterPassCount != passBefore;
                       BOOL hiddenAdvanced = SPKHiddenChatsNewestHiddenActivity > hiddenBefore;
                       BOOL visibleAdvanced = SPKHiddenChatsNewestVisibleActivity > visibleBefore;
                       // Both sides moving means two messages landed together and one of
                       // them is a chat the user can see, so it keeps its haptic.
                       if (diffed && hiddenAdvanced && !visibleAdvanced) {
                           SPKLog(@"Messages", @"[Sparkle HiddenChats] Suppressed inbox haptic for a hidden chat style=%llu", style);
                           return;
                       }
                       // Logged too: only the suppression being visible makes a wrongly
                       // swallowed haptic indistinguishable from one that never fired.
                       SPKLog(@"Messages", @"[Sparkle HiddenChats] Played inbox haptic style=%llu diffed=%d hidden=%d visible=%d",
                              style, diffed, hiddenAdvanced, visibleAdvanced);
                       SPKHiddenChatsOrigGenerateHaptic(helper, _cmd, style);
                   });
}

static void SPKHiddenChatsInstallHapticHook(void) {
    Class helper = SPKResolveIGClass(@"IGDirectInAppNotificationService.IGDirectInboxHapticFeedbackHelper",
                                     @"IGDirectInboxHapticFeedbackHelper");
    SEL selector = NSSelectorFromString(@"generate:");
    if (!helper || !class_getInstanceMethod(helper, selector)) {
        SPKLog(@"Messages", @"[Sparkle HiddenChats] Inbox haptic helper unavailable class=%@",
               helper ? NSStringFromClass(helper) : @"(none)");
        return;
    }
    MSHookMessageEx(helper, selector, (IMP)SPKHiddenChatsGenerateHaptic, (IMP *)&SPKHiddenChatsOrigGenerateHaptic);
    SPKLog(@"Messages", @"[Sparkle HiddenChats] Inbox haptic hook installed on %@", NSStringFromClass(helper));
}

#pragma mark - Installation

extern "C" void SPKInstallHiddenChatsHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SPKDirectInboxMenuRegisterProvider(@"hidden_chats", 0, ^NSArray<UIMenuElement *> *(SPKDirectThreadContext *context, id viewModel) {
            (void)viewModel;
            if (!SPKDirectHiddenChatsEnabled())
                return nil;
            NSString *title = SPKDirectHiddenChatsMenuActionTitle(context);
            if (title.length == 0)
                return nil;

            BOOL hidden = SPKDirectHiddenChatListContainsContext(context);
            // Not the eye pair: the seen toggle directly below in the same section
            // owns that, and two eyes in one menu read as two views of one setting.
            UIAction *action = [UIAction actionWithTitle:title
                                                   image:[SPKAssetUtils menuIconNamed:hidden ? @"messages" : @"messages_off"
                                                                            pointSize:kSPKInstagramMenuIconPointSize]
                                              identifier:nil
                                                 handler:^(__unused UIAction *menuAction) {
                                                     SPKDirectHiddenChatsToggleThread(context, nil);
                                                 }];
            return @[ action ];
        });
        SPKDirectInboxMenuInstallHooksIfNeeded();
        SPKHiddenChatsInstallHapticHook();
        SPKHiddenChatsNeedsFallbackGesture = !SPKHiddenChatsInstallTitleLongPressHook();
        if (SPKHiddenChatsNeedsFallbackGesture)
            SPKLog(@"Messages", @"[Sparkle HiddenChats] Inbox header title long press unavailable, falling back to an added recogniser");

        %init(SPKHiddenChatsInboxHooks,
              IGDirectInboxListAdapterDataSource = SPKResolveIGClass(@"IGDirectInboxListAdapterDataSource.IGDirectInboxListAdapterDataSource", @"IGDirectInboxListAdapterDataSource"));
        %init(SPKHiddenChatsRevealHooks);
        Class swiftInbox = SPKResolveIGClass(@"IGDirectInboxSwiftViewController.IGDirectInboxSwiftViewController", nil);
        if (swiftInbox)
            %init(SPKHiddenChatsRevealSwiftHooks, IGDirectInboxSwiftViewController = swiftInbox);
        if (NSClassFromString(@"IGSearchBarNewGroupFacepileButton"))
            %init(SPKHiddenChatsShareRevealGestureHooks);
        if (NSClassFromString(@"IGDirectInboxSearchListAdapterDataSource"))
            %init(SPKHiddenChatsInboxSearchHooks);
        if (NSClassFromString(@"IGDirectRecipientListViewController"))
            %init(SPKHiddenChatsShareSheetHooks);
        if (NSClassFromString(@"IGDirectThreadCreationViewController"))
            %init(SPKHiddenChatsThreadCreationHooks);
        if (NSClassFromString(@"IGDirectRecipientPickerViewController"))
            %init(SPKHiddenChatsRecipientPickerHooks);
        %init(SPKHiddenChatsNotificationHooks);
        %init(SPKHiddenChatsBadgeHooks);

        [[NSNotificationCenter defaultCenter] addObserverForName:SPKDirectHiddenChatsDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *notification) {
                                                          SPKHiddenChatsGeneration++;
                                                          // Hiding a chat happens from the inbox the user is
                                                          // looking at, so the list has to re-diff now rather
                                                          // than on its next appearance.
                                                          [SPKHiddenChatsRevealGestureTarget spk_reloadListForViewController:SPKHiddenChatsVisibleInbox];
                                                      }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *notification) {
                                                          SPKDirectHiddenChatsNoteBackgrounded();
                                                          // A share sheet reveal never survives leaving the app,
                                                          // whatever the sheet's own lifecycle reported.
                                                          SPKHiddenChatsEndShareReveal(@"app backgrounded");
                                                      }];
    });
}
