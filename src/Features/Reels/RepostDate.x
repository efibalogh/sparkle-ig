// Repost Date — shows when a repost was made in the header of the sheet that
// opens from the "reposted this reel" bubble.
//
// The sheet is an IGDirectReplyToAuthorViewController whose share content
// carries the repost as an IGRepostModel. Instagram already has the exact
// creation date there and only shows the reposter's name, so we add the
// date on its own line under the name in the title view. Nothing is fetched.

#import <objc/runtime.h>

#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import "../../App/SPKPerfMeter.h"

static const void *kSPKRepostDateLabelKey = &kSPKRepostDateLabelKey;
static const CGFloat kSPKRepostDateSpacing = 2.0;

static inline BOOL SPKRepostDateEnabled(void) {
    return [SPKUtils getBoolPref:@"reels_show_repost_date"];
}

static id SPKRepostDateIvar(id object, const char *name) {
    if (!object)
        return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

// Walks up the responder chain to the sheet controller. The title view lives
// inside that controller's view, so no presented-controller search is needed.
static UIViewController *SPKRepostDateHostController(UIView *view) {
    Class hostClass = NSClassFromString(@"IGDirectReplyToAuthorViewController");
    if (!hostClass)
        return nil;
    for (UIResponder *responder = view.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:hostClass])
            return (UIViewController *)responder;
    }
    return nil;
}

static NSDate *SPKRepostDateForTitleView(UIView *titleView) {
    UIViewController *host = SPKRepostDateHostController(titleView);
    id shareContent = SPKRepostDateIvar(host, "_shareContent");
    id repost = SPKRepostDateIvar(shareContent, "_repost_note");
    Class repostClass = NSClassFromString(@"IGRepostModel");
    if (!repost || !repostClass || ![repost isKindOfClass:repostClass])
        return nil;

    id createdAt = nil;
    if ([repost respondsToSelector:@selector(createdAtDate)])
        createdAt = [repost createdAtDate];
    if ([createdAt isKindOfClass:[NSDate class]])
        return createdAt;
    if ([createdAt respondsToSelector:@selector(date)]) {
        id date = [createdAt date];
        if ([date isKindOfClass:[NSDate class]])
            return date;
    }
    return nil;
}

// Time alone for today, the date and time for older reposts, and the year only
// when it differs from the current one.
static NSString *SPKFormattedRepostDate(NSDate *date) {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    if ([calendar isDate:date inSameDayAsDate:now])
        return [SPKUtils spk_formattedTime:date];
    BOOL sameYear = [calendar component:NSCalendarUnitYear fromDate:date] ==
                    [calendar component:NSCalendarUnitYear fromDate:now];
    return [SPKUtils spk_formattedDateTime:date includingYear:!sameYear];
}

static UIButton *SPKRepostDateTitleButton(UIView *titleView) {
    UIButton *titleButton = SPKRepostDateIvar(titleView, "_titleButton");
    if (![titleButton isKindOfClass:[UIView class]] || titleButton.hidden || titleButton.superview != titleView)
        return nil;
    return titleButton;
}

static NSString *SPKRepostDateText(UIView *titleView) {
    if (!SPKRepostDateEnabled())
        return nil;
    NSDate *date = SPKRepostDateForTitleView(titleView);
    return date ? SPKFormattedRepostDate(date) : nil;
}

static UILabel *SPKRepostDateLabel(UIView *titleView, UIButton *titleButton, NSString *text) {
    UILabel *label = objc_getAssociatedObject(titleView, kSPKRepostDateLabelKey);
    if (!label) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.textColor = [UIColor secondaryLabelColor];
        label.numberOfLines = 1;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [titleView addSubview:label];
        objc_setAssociatedObject(titleView, kSPKRepostDateLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // One step below the name so it reads as secondary to it.
    UIFont *titleFont = [titleButton respondsToSelector:@selector(titleLabel)] ? titleButton.titleLabel.font : nil;
    CGFloat pointSize = titleFont.pointSize > 0 ? titleFont.pointSize - 1.0 : 13.0;
    label.font = [UIFont systemFontOfSize:pointSize weight:UIFontWeightRegular]; // spk-font-fixed: one step under Instagram's own title, which owns the scaling
    label.text = text;
    return label;
}

// Height the date line adds under the name, including the gap above it.
static CGFloat SPKRepostDateLineHeight(UILabel *label) {
    return ceil(label.font.lineHeight) + kSPKRepostDateSpacing;
}

static const void *kSPKRepostDateReservedKey = &kSPKRepostDateReservedKey;
static const void *kSPKRepostDateShiftedFrameKey = &kSPKRepostDateShiftedFrameKey;

static void SPKLayoutRepostDate(UIView *titleView) {
    UILabel *existing = objc_getAssociatedObject(titleView, kSPKRepostDateLabelKey);
    UIButton *titleButton = SPKRepostDateTitleButton(titleView);
    NSString *text = titleButton && !CGRectIsEmpty(titleButton.frame) ? SPKRepostDateText(titleView) : nil;
    if (text.length == 0) {
        existing.hidden = YES;
        return;
    }

    UILabel *label = SPKRepostDateLabel(titleView, titleButton, text);
    label.hidden = NO;
    CGFloat lineHeight = SPKRepostDateLineHeight(label);
    CGRect buttonFrame = titleButton.frame;

    // Push everything IG placed under the name down by one line. IG lays these
    // out by frame on every pass; a view still at the frame we gave it last time
    // was not reset, so it is skipped rather than pushed down twice.
    CGFloat nameBottom = CGRectGetMaxY(buttonFrame);
    for (UIView *subview in titleView.subviews) {
        if (subview == label || subview == titleButton || subview.hidden)
            continue;
        if (CGRectGetMinY(subview.frame) < nameBottom - 0.5)
            continue;
        NSValue *shifted = objc_getAssociatedObject(subview, kSPKRepostDateShiftedFrameKey);
        if (shifted && CGRectEqualToRect(shifted.CGRectValue, subview.frame))
            continue;
        subview.frame = CGRectOffset(subview.frame, 0.0, lineHeight);
        objc_setAssociatedObject(subview, kSPKRepostDateShiftedFrameKey, [NSValue valueWithCGRect:subview.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Align with the name text rather than the button's edge.
    CGFloat x = CGRectGetMinX(buttonFrame);
    UILabel *nameLabel = [titleButton respondsToSelector:@selector(titleLabel)] ? titleButton.titleLabel : nil;
    if (nameLabel && !CGRectIsEmpty(nameLabel.frame))
        x = [titleButton convertRect:nameLabel.frame toView:titleView].origin.x;
    label.frame = CGRectMake(x,
                             nameBottom + kSPKRepostDateSpacing,
                             MAX(0.0, CGRectGetWidth(titleView.bounds) - x),
                             ceil(label.font.lineHeight));

    // The first measurement can happen before the sheet controller is reachable,
    // so the header was sized without the date. Ask the sheet to measure again.
    if (![objc_getAssociatedObject(titleView, kSPKRepostDateReservedKey) boolValue]) {
        objc_setAssociatedObject(titleView, kSPKRepostDateReservedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [titleView invalidateIntrinsicContentSize];
        [titleView.superview setNeedsLayout];
    }
}

%group SPKRepostDateHooks

%hook IGDirectMessageModalTitleView

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize fitted = %orig;
    UIButton *titleButton = SPKRepostDateTitleButton((UIView *)self);
    NSString *text = titleButton ? SPKRepostDateText((UIView *)self) : nil;
    if (text.length > 0) {
        UILabel *label = SPKRepostDateLabel((UIView *)self, titleButton, text);
        fitted.height += SPKRepostDateLineHeight(label);
        objc_setAssociatedObject(self, kSPKRepostDateReservedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return fitted;
}

- (void)layoutSubviews {
    %orig;
    SPK_PERF_SCOPE(@"RepostDate.layoutSubviews");
    SPKLayoutRepostDate((UIView *)self);
}

%end

%end

// Installed unconditionally so the toggle works without a restart; the hook
// only touches the reply sheet header and re-checks the pref on every layout.
void SPKInstallRepostDateHooksIfEnabled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKRepostDateHooks);
    });
}
