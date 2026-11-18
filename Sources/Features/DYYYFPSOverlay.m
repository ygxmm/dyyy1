#import "DYYYFPSOverlay.h"
#import "DYYYConstants.h"
#import "DYYYHighFPSHooks.h"
#import "AwemeHeaders.h"

#import <math.h>

static NSHashTable<AWEFeedTopBarContainer *> *gDYYYFPSBars;
static UILabel *gDYYYFPSBadge;
static BOOL gDYYYFPSDisplayEnabled;
static BOOL gDYYYFPSAppActive;
static BOOL gDYYYFPSReading;
static BOOL gDYYYFPSCompact;
static NSInteger gDYYYFPSLastValue = -1;
static BOOL gDYYYFPSRefreshPending;

static BOOL DYYYFPSIsVisibleThrough(UIView *view, UIView *ancestor) {
    for (UIView *node = view; node; node = node.superview) {
        if (node.hidden || node.alpha <= 0.02) return NO;
        if (node == ancestor) return YES;
    }
    return NO;
}

static CGRect DYYYFPSRectInBar(UIView *view, AWEFeedTopBarContainer *bar) {
    return [view convertRect:view.bounds toView:bar];
}

static CGRect DYYYFPSBadgeFrame(AWEFeedTopBarContainer *bar, BOOL *compact) {
    UIWindow *window = bar.window;
    if (!window.isKeyWindow || !DYYYFPSIsVisibleThrough(bar, window) ||
        CGRectIsEmpty(CGRectIntersection([bar convertRect:bar.bounds toView:window], window.bounds))) return CGRectNull;
    if (![bar respondsToSelector:@selector(segmentControlView)]) return CGRectNull;
    AWEFeedMultiTabSegmentedControl *segment = (id)bar.segmentControlView;
    if (!DYYYFPSIsVisibleThrough(segment, bar) || ![segment respondsToSelector:@selector(mainTabIndex)] ||
        ![segment respondsToSelector:@selector(itemViews)]) return CGRectNull;
    NSInteger index = segment.mainTabIndex;
    NSArray *items = segment.itemViews;
    if (index < 0 || (NSUInteger)index >= items.count) return CGRectNull;
    AWEHPTopTabItemView *item = items[(NSUInteger)index];
    if (![item respondsToSelector:@selector(textContentView)]) return CGRectNull;
    AWEHPTopTabItemTextContentView *text = item.textContentView;
    UILabel *title = [text respondsToSelector:@selector(titleLabel)] ? text.titleLabel : nil;
    if (![title isKindOfClass:UILabel.class] || !DYYYFPSIsVisibleThrough(title, bar) || CGRectIsEmpty(title.bounds)) return CGRectNull;

    CGRect clip = DYYYFPSRectInBar(segment, bar);
    if ([segment respondsToSelector:@selector(multiTabSegmentedControlScollWrapperView)]) {
        UIView *scroll = segment.multiTabSegmentedControlScollWrapperView;
        if (scroll.window) clip = CGRectIntersection(clip, DYYYFPSRectInBar(scroll, bar));
    }
    CGRect textRect = DYYYFPSRectInBar(title, bar);
    CGRect itemRect = DYYYFPSRectInBar(item, bar);
    if (CGRectIsEmpty(clip) || CGRectGetMinX(textRect) < CGRectGetMinX(clip) - 1 ||
        CGRectGetMaxX(textRect) > CGRectGetMaxX(clip) + 1) return CGRectNull;

    // Sibling of the clipped segment: do not extend the tab or change its hit area.
    CGFloat x = ceil(MAX(CGRectGetMaxX(textRect) + 8, CGRectGetMaxX(itemRect) + 2));
    CGFloat right = CGRectGetMaxX(bar.bounds) - MAX(8, bar.safeAreaInsets.right);
    UIView *rightCTA = [bar respondsToSelector:@selector(topRightContainer)] ? bar.topRightContainer : nil;
    if (DYYYFPSIsVisibleThrough(rightCTA, bar) && !CGRectIsEmpty(rightCTA.bounds)) {
        right = MIN(right, CGRectGetMinX(DYYYFPSRectInBar(rightCTA, bar)) - 6);
    }
    for (UIView *other in items) {
        if (other == item || !DYYYFPSIsVisibleThrough(other, bar)) continue;
        CGRect visible = CGRectIntersection(DYYYFPSRectInBar(other, bar), clip);
        if (!CGRectIsEmpty(visible) && CGRectGetMaxX(visible) > CGRectGetMaxX(itemRect) + 1) {
            right = MIN(right, CGRectGetMinX(visible) - 3);
        }
    }
    UIView *arrow = [segment respondsToSelector:@selector(rightNavigationArrowView)] ? segment.rightNavigationArrowView : nil;
    if (DYYYFPSIsVisibleThrough(arrow, bar)) {
        CGRect arrowRect = DYYYFPSRectInBar(arrow, bar);
        if (!CGRectIsEmpty(arrowRect) && CGRectGetMaxX(arrowRect) > x) right = MIN(right, CGRectGetMinX(arrowRect) - 3);
    }
    *compact = right - x < 48;
    CGFloat width = *compact ? 29 : 48;
    if (right - x < width) return CGRectNull;
    return CGRectMake(x, round(CGRectGetMidY(textRect) - 9), width, 18);
}

static void DYYYFPSUpdateBadgeText(void) {
    if (!gDYYYFPSBadge) return;
    NSString *number = gDYYYFPSLastValue < 0 ? @"—" : [NSString stringWithFormat:@"%ld", (long)gDYYYFPSLastValue];
    NSString *text = gDYYYFPSCompact ? number : [number stringByAppendingString:@" FPS"];
    if (![gDYYYFPSBadge.text isEqualToString:text]) gDYYYFPSBadge.text = text;
    gDYYYFPSBadge.accessibilityValue = gDYYYFPSLastValue < 0 ? @"采样中" : [number stringByAppendingString:@" 帧每秒"];
}

static void DYYYFPSRefreshBadge(void) {
    AWEFeedTopBarContainer *target = nil;
    CGRect frame = CGRectNull;
    BOOL compact = NO;
    if (gDYYYFPSDisplayEnabled && gDYYYFPSAppActive) {
        for (AWEFeedTopBarContainer *bar in gDYYYFPSBars) {
            frame = DYYYFPSBadgeFrame(bar, &compact);
            if (!CGRectIsNull(frame)) { target = bar; break; }
        }
    }
    if (!target) {
        [gDYYYFPSBadge removeFromSuperview];
        if (gDYYYFPSReading) {
            gDYYYFPSReading = NO;
            DYYYSetFPSReadout(nil);
        }
        return;
    }
    if (!gDYYYFPSBadge) {
        gDYYYFPSBadge = [[UILabel alloc] initWithFrame:frame];
        gDYYYFPSBadge.tag = DYYY_IGNORE_GLOBAL_ALPHA_TAG;
        gDYYYFPSBadge.userInteractionEnabled = NO;
        gDYYYFPSBadge.textAlignment = NSTextAlignmentCenter;
        gDYYYFPSBadge.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightSemibold];
        gDYYYFPSBadge.textColor = UIColor.whiteColor;
        gDYYYFPSBadge.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.38];
        gDYYYFPSBadge.layer.cornerRadius = 5;
        gDYYYFPSBadge.clipsToBounds = YES;
        gDYYYFPSBadge.accessibilityIdentifier = @"dyyy_fps_topbar_badge";
        gDYYYFPSBadge.accessibilityLabel = @"界面帧率";
    }
    if (gDYYYFPSBadge.superview != target) [target addSubview:gDYYYFPSBadge];
    if (!CGRectEqualToRect(gDYYYFPSBadge.frame, frame)) gDYYYFPSBadge.frame = frame;
    if (gDYYYFPSCompact != compact || !gDYYYFPSBadge.text) {
        gDYYYFPSCompact = compact;
        DYYYFPSUpdateBadgeText();
    }
    if (!gDYYYFPSReading) {
        gDYYYFPSReading = YES;
        DYYYSetFPSReadout(^(NSInteger fps) {
            gDYYYFPSLastValue = fps;
            DYYYFPSUpdateBadgeText();
        });
    }
}

static void DYYYFPSScheduleRefresh(void) {
    if (gDYYYFPSRefreshPending) return;
    gDYYYFPSRefreshPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gDYYYFPSRefreshPending = NO;
        DYYYFPSRefreshBadge();
    });
}

static void DYYYFPSReadPreference(void) {
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:DYYY_SHOW_FPS_OVERLAY_KEY];
    if (enabled == gDYYYFPSDisplayEnabled) return;
    gDYYYFPSDisplayEnabled = enabled;
    DYYYFPSScheduleRefresh();
}

void DYYYFPSOverlayTopBarChanged(AWEFeedTopBarContainer *bar) {
    if (!NSThread.isMainThread) return;
    if (!gDYYYFPSBars) gDYYYFPSBars = [NSHashTable weakObjectsHashTable];
    if (bar.window) {
        if (![gDYYYFPSBars containsObject:bar]) [gDYYYFPSBars addObject:bar];
    } else {
        [gDYYYFPSBars removeObject:bar];
    }
    if (gDYYYFPSDisplayEnabled) DYYYFPSScheduleRefresh();
}

void DYYYFPSOverlaySegmentChanged(UIView *segment) {
    if (NSThread.isMainThread && gDYYYFPSDisplayEnabled && segment.window) DYYYFPSScheduleRefresh();
}

void DYYYStartFPSOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gDYYYFPSAppActive = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        NSOperationQueue *queue = NSOperationQueue.mainQueue;
        [center addObserverForName:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults queue:nil usingBlock:^(__unused NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ DYYYFPSReadPreference(); });
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:queue usingBlock:^(__unused NSNotification *note) {
            gDYYYFPSAppActive = YES;
            DYYYFPSReadPreference();
            DYYYFPSScheduleRefresh();
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:queue usingBlock:^(__unused NSNotification *note) {
            gDYYYFPSAppActive = NO;
            DYYYFPSRefreshBadge();
        }];
        for (NSNotificationName name in @[ UIWindowDidBecomeKeyNotification, UIWindowDidResignKeyNotification ]) {
            [center addObserverForName:name object:nil queue:queue usingBlock:^(__unused NSNotification *note) {
                if (gDYYYFPSDisplayEnabled) DYYYFPSScheduleRefresh();
            }];
        }
        DYYYFPSReadPreference();
    });
}
