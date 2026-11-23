#import "DYYYFullscreenCoordinator.h"
#import "DYYYFullscreenGeometry.h"
#import "DYYYUtils.h"
#import "AwemeHeaders.h"
#import <objc/runtime.h>
#import <math.h>

// AwemeCore 41.2 声明；不调用 Swift 懒加载的 innerVC getter。
@interface AWECommentContainerViewController (DYYYFullscreenBinding)
- (id)interactionViewController;
- (id)videoPlayer;
- (AWEAwemeModel *)model;
@end

@interface AFDSlidesView (DYYYFullscreenBinding)
- (AWEAwemeModel *)model;
@end

@interface DYYYFullscreenCommentState : NSObject
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, weak) UIView *outerView;
@property(nonatomic, weak) UIViewController *inner;
@property(nonatomic, assign) CGRect windowBounds;
@property(nonatomic, assign) UIEdgeInsets safeArea;
@property(nonatomic, assign) CGRect lastPanel;
@property(nonatomic, assign) BOOL fullscreen;
@property(nonatomic, assign) BOOL blur;
@end
@implementation DYYYFullscreenCommentState
@end

@interface DYYYFullscreenImageState : NSObject
@property(nonatomic, weak) UIViewController *owner;
@property(nonatomic, weak) UIView *cell;
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, weak) UIView *host;
@property(nonatomic, weak) AWEAwemeModel *model;
@property(nonatomic, copy) NSString *itemID;
@property(nonatomic, weak) UIImageView *artView;
@property(nonatomic, weak) UIImage *artwork;
@property(nonatomic, assign) CGRect artRect;
@property(nonatomic, assign) CGRect bounds;
@property(nonatomic, assign) CGRect hostBounds;
@property(nonatomic, assign) CGSize cellSize;
@property(nonatomic, assign) CGRect windowBounds;
@property(nonatomic, assign) UIEdgeInsets safeArea;
@property(nonatomic, assign) CGAffineTransform nativeTransform;
@property(nonatomic, assign) CGAffineTransform closedTransform;
@property(nonatomic, assign) CGAffineTransform lastAppliedTransform;
@property(nonatomic, assign) BOOL hasClosedTransform;
@property(nonatomic, assign) BOOL awaitingNativeTransform;
@property(nonatomic, assign) BOOL adjusted;
@property(nonatomic, assign) BOOL applying;
@end
@implementation DYYYFullscreenImageState
@end

@interface AWENormalModeTabBar (DYYYFullscreenChrome)
- (UIView *)backgroundView;
- (UIImageView *)darkBackgroundImageView;
- (UIImageView *)lightBackgroundImageView;
- (UIView *)compactModeBackgroundView;
- (UIView *)awe_blurView;
- (UIView *)separatorLine;
@end

@interface DYYYFullscreenBarBackdrop : NSObject
@property(nonatomic, strong) UIColor *nativeColor;
@property(nonatomic, assign) BOOL ownsColor;
@property(nonatomic, assign) BOOL ownsOpacity;
@property(nonatomic, assign) BOOL ownsHidden;
@end
@implementation DYYYFullscreenBarBackdrop
@end

@interface DYYYFullscreenPlayerState : NSObject
@property(nonatomic, weak) UIViewController *owner;
@property(nonatomic, assign) CGSize layoutWindowSize;
@property(nonatomic, assign) UIEdgeInsets layoutSafeArea;
@property(nonatomic, assign) CGRect nativeFrame;
@property(nonatomic, assign) CGRect lastAppliedFrame;
@property(nonatomic, assign) BOOL hasNativeFrame;
@property(nonatomic, assign) CGSize closedInteractionSize;
@property(nonatomic, assign) CGRect captionWindowFrame;
@property(nonatomic, assign) BOOL hasCaptionFrame;
@property(nonatomic, assign) BOOL captionAdjusted;
@property(nonatomic, assign) CGPoint captionNativeCenter;
@property(nonatomic, assign) CGPoint captionAppliedCenter;
@property(nonatomic, assign) BOOL applying;
@property(nonatomic, assign) BOOL adjusted;
@property(nonatomic, weak) UIViewController *playerOwner;
@property(nonatomic, weak) AWEAwemeModel *playerModel;
@property(nonatomic, weak) id playerContent;
@property(nonatomic, copy) NSString *playerItemID;
@property(nonatomic, weak) UIView *playerSuperview;
@property(nonatomic, weak) UIView *playerCell;
@property(nonatomic, weak) UIWindow *playerWindow;
@property(nonatomic, assign) CGRect playerSuperviewBounds;
@property(nonatomic, assign) CGSize playerCellSize;
@property(nonatomic, assign) BOOL playerCanCache;
@property(nonatomic, assign) BOOL awaitingNativeFrame;
@property(nonatomic, assign) CGRect normalWindowFrame;
@property(nonatomic, assign) BOOL hasNormalWindowFrame;
@property(nonatomic, assign) CGSize normalRenderSize;
@property(nonatomic, weak) UIWindow *normalWindow;
@property(nonatomic, weak) UIView *normalCell;
@property(nonatomic, assign) CGRect normalCellWindowFrame;
@property(nonatomic, assign) BOOL mediaHost;
@property(nonatomic, assign) CGRect mediaHostParentBounds;
@property(nonatomic, assign) CGRect nativeHostFrame;
@property(nonatomic, assign) CGRect fullscreenHostFrame;
@property(nonatomic, strong) NSMapTable<UIView *, DYYYFullscreenBarBackdrop *> *bottomBackgrounds;
@property(nonatomic, assign) BOOL updatingBottomBar;
@end
@implementation DYYYFullscreenPlayerState
@end

@implementation DYYYFullscreenCoordinator
+ (NSString *)buildIdentifier { return @"fullscreen-panel-owner-20261123.1"; }
+ (NSString *)contentSourceForController:(UIViewController *)controller {
    // 以当前内容来源为准，不能仅凭它仍挂在首页导航栈中判断。
    for (NSUInteger depth = 0; controller && depth < 8; depth++, controller = controller.parentViewController) {
        if (![controller respondsToSelector:@selector(referString)]) continue;
        NSString *refer = [(AWEPlayInteractionViewController *)controller referString];
        if (refer.length > 0) return refer;
    }
    return nil;
}
+ (BOOL)usesRecommendedLayoutForController:(UIViewController *)controller {
    return [[self contentSourceForController:controller] isEqualToString:@"homepage_hot"];
}
+ (BOOL)usesDetailLayoutForController:(UIViewController *)controller {
    Class detailClass = NSClassFromString(@"AWEAwemeDetailTableViewController");
    Class remoteClass = NSClassFromString(@"AFDPlayRemoteFeedTableViewController");
    BOOL detail = NO;
    for (NSUInteger depth = 0; controller && depth < 8; depth++, controller = controller.parentViewController) {
        if (remoteClass && [controller isKindOfClass:remoteClass]) return NO;
        if ([controller isKindOfClass:detailClass]) detail = YES;
    }
    return detail;
}
+ (UIScrollView *)pagingViewForCell:(UIView *)cell {
    for (UIView *view = cell.superview; view; view = view.superview) {
        if ([view isKindOfClass:[UITableView class]] || [view isKindOfClass:[UICollectionView class]]) return (UIScrollView *)view;
    }
    return nil;
}
+ (BOOL)view:(UIView *)view spansWidthOf:(UIView *)container {
    return view && container && container.bounds.size.width > 0 && fabs(view.bounds.size.width - container.bounds.size.width) <= 1;
}
+ (BOOL)usesFullscreenLayoutForController:(UIViewController *)controller {
    Class remoteClass = NSClassFromString(@"AFDPlayRemoteFeedTableViewController");
    BOOL pureMode = NO;
    for (UIViewController *parent = controller; parent; parent = parent.parentViewController) {
        if (remoteClass && [parent isKindOfClass:remoteClass]) return NO;
        if ([parent respondsToSelector:@selector(getPureModeContainerFrame)]) pureMode = YES;
    }
    if (pureMode || [self usesRecommendedLayoutForController:controller] || [self usesDetailLayoutForController:controller]) return YES;
    UIView *view = controller.viewIfLoaded;
    if (!view.window) return NO;
    UIView *cell = [self cellForPlayer:view owner:controller];
    if (![cell isKindOfClass:[UITableViewCell class]] && ![cell isKindOfClass:[UICollectionViewCell class]]) return NO;
    UIScrollView *pager = [self pagingViewForCell:cell];
    if (![self view:cell spansWidthOf:pager] || pager.bounds.size.height <= 0) return NO;
    // 分页能力和实际容器决定是否适配，窗口大小、设备型号不参与分类。
    if (pager.pagingEnabled) return YES;
    for (UIViewController *parent = controller; parent; parent = parent.parentViewController) {
        if ([parent respondsToSelector:@selector(currentVisibleCellIndex)]) return YES;
    }
    return NO;
}
+ (CGRect)frameForPureModeContainer:(UIViewController *)controller proposed:(CGRect)frame {
    if (![NSThread isMainThread] || !DYYYGetBool(@"DYYYEnableFullScreen")) return frame;
    UIView *view = controller.viewIfLoaded;
    if (!view) return frame;
    if (CGRectIsEmpty(frame) || CGRectIsNull(frame) || CGRectIsInfinite(frame) || fabs(frame.size.width - view.bounds.size.width) > 1) return frame;
    CGFloat height = CGRectGetMaxY(view.bounds) - frame.origin.y;
    // 交给原生列表同步计算行高和分页，媒体可延伸到底部清屏控制栏下方。
    if (height > 0) frame.size.height = height;
    return frame;
}
+ (CGFloat)bottomInsetForDetail:(CGFloat)inset controller:(UIViewController *)controller {
    if (![NSThread isMainThread] || !DYYYGetBool(@"DYYYEnableFullScreen") || ![self usesDetailLayoutForController:controller]) return inset;
    UIView *view = controller.viewIfLoaded;
    if (!view.window || CGRectIsEmpty(view.bounds)) return inset;
    // 行高只以本页原生视口为准；未加载时保留原生值，显示后统一修正缓存。
    return inset > 0 ? 0 : inset;
}
+ (CGFloat)heightForDetailRow:(CGFloat)height table:(UITableView *)table controller:(UIViewController *)controller {
    if (![NSThread isMainThread] || !DYYYGetBool(@"DYYYEnableFullScreen") || ![self usesDetailLayoutForController:controller]) return height;
    // 行高与 UITableView 分页视口使用同一尺寸，预加载时也不扣第二次底栏。
    return height > 0 && table.bounds.size.height > 0 ? table.bounds.size.height : height;
}
+ (void)reconcileDetailPaging:(UIViewController *)controller {
    if (![NSThread isMainThread] || !DYYYGetBool(@"DYYYEnableFullScreen") || ![self usesDetailLayoutForController:controller]) return;
    if (![controller respondsToSelector:@selector(tableView)] || ![controller respondsToSelector:@selector(currentVisibleCellIndex)] ||
        ![controller respondsToSelector:@selector(updateTableViewLayoutForTargetPageIndex:)]) return;
    AWEAwemeDetailTableViewController *detail = (AWEAwemeDetailTableViewController *)controller;
    UITableView *table = [detail tableView];
    CGFloat height = table.bounds.size.height;
    if (!table.window || height <= 0 || table.bounds.size.width <= 0 || [self hasCommentInWindow:table.window] ||
        table.tracking || table.dragging || table.decelerating || table.numberOfSections != 1) return;
    DYYYFullscreenPlayerState *state = objc_getAssociatedObject(table, @selector(state:));
    if (state.applying) return;
    NSInteger count = [table numberOfRowsInSection:0];
    NSUInteger index = [detail currentVisibleCellIndex];
    if (count <= 0 || index >= (NSUInteger)count) return;
    NSIndexPath *firstIndex = [NSIndexPath indexPathForRow:0 inSection:0];
    NSIndexPath *lastIndex = [NSIndexPath indexPathForRow:count - 1 inSection:0];
    CGRect first = [table rectForRowAtIndexPath:firstIndex];
    CGRect last = [table rectForRowAtIndexPath:lastIndex];
    if (fabs(first.size.height - height) < 0.5 && fabs(last.size.height - height) < 0.5 &&
        fabs(CGRectGetMinY(last) - CGRectGetMinY(first) - (count - 1) * height) < 0.5) return;
    if (![detail respondsToSelector:@selector(tableView:heightForRowAtIndexPath:)] ||
        fabs([detail tableView:table heightForRowAtIndexPath:firstIndex] - height) > 0.5 ||
        fabs([detail tableView:table heightForRowAtIndexPath:lastIndex] - height) > 0.5) return;
    state = [self state:table];
    state.applying = YES;
    @try {
        // 早期数据源可能已缓存带输入栏占位的行高；只改视口不会清除这些缓存。
        // 批量更新重新询问原生行高，随后按同一个视频索引恢复原生分页偏移。
        [UIView performWithoutAnimation:^{
            [table beginUpdates];
            [table endUpdates];
            [detail updateTableViewLayoutForTargetPageIndex:(NSInteger)index];
            [table layoutIfNeeded];
        }];
    } @finally {
        state.applying = NO;
    }
}
+ (void)restoreBackdrop:(DYYYFullscreenBarBackdrop *)saved inView:(UIView *)view {
    // 恢复本模块仍持有的属性；切页时原生已经重设的颜色或显隐不要覆盖。
    if (saved.ownsColor && [view.backgroundColor isEqual:UIColor.clearColor]) view.backgroundColor = saved.nativeColor;
    if (saved.ownsOpacity && !view.opaque) view.opaque = YES;
    if (saved.ownsHidden && view.hidden) view.hidden = NO;
}
+ (NSArray<UIView *> *)bottomBackgroundViews:(UIView *)bar {
    NSMutableOrderedSet<UIView *> *views = [NSMutableOrderedSet orderedSetWithObject:bar];
    if ([bar isKindOfClass:NSClassFromString(@"AWENormalModeTabBar")]) {
        AWENormalModeTabBar *rootBar = (AWENormalModeTabBar *)bar;
        NSArray *native = @[[rootBar respondsToSelector:@selector(backgroundView)] ? rootBar.backgroundView ?: NSNull.null : NSNull.null,
            [rootBar respondsToSelector:@selector(darkBackgroundImageView)] ? rootBar.darkBackgroundImageView ?: NSNull.null : NSNull.null,
            [rootBar respondsToSelector:@selector(lightBackgroundImageView)] ? rootBar.lightBackgroundImageView ?: NSNull.null : NSNull.null,
            [rootBar respondsToSelector:@selector(compactModeBackgroundView)] ? rootBar.compactModeBackgroundView ?: NSNull.null : NSNull.null,
            [rootBar respondsToSelector:@selector(awe_blurView)] ? rootBar.awe_blurView ?: NSNull.null : NSNull.null,
            [rootBar respondsToSelector:@selector(separatorLine)] ? rootBar.separatorLine ?: NSNull.null : NSNull.null,
            [rootBar respondsToSelector:@selector(skinContainerView)] ? rootBar.skinContainerView ?: NSNull.null : NSNull.null];
        for (id candidate in native) {
            if ([candidate isKindOfClass:UIView.class] && candidate != bar && [candidate isDescendantOfView:bar]) [views addObject:candidate];
        }
    }
    // 只取底栏的背景，不遍历按钮、输入框、图片内容或转场覆盖层。
    for (UIView *view in bar.subviews) {
        if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UILabel.class]) continue;
        BOOL backdrop = [view isKindOfClass:UIVisualEffectView.class] || [NSStringFromClass(view.class) containsString:@"Background"];
        CGRect rect = [view convertRect:view.bounds toView:bar];
        if (backdrop && rect.size.width >= bar.bounds.size.width - 1 && rect.size.height >= bar.bounds.size.height - 1) [views addObject:view];
    }
    return views.array;
}
+ (void)layoutBottomBar:(UIView *)bar enabled:(BOOL)enabled {
    DYYYFullscreenPlayerState *state = objc_getAssociatedObject(bar, @selector(state:));
    enabled = enabled && bar.window && !CGRectIsEmpty(bar.bounds);
    if ((!enabled && !state.bottomBackgrounds) || state.updatingBottomBar) return;
    state = [self state:bar];
    state.updatingBottomBar = YES;
    @try {
        NSArray<UIView *> *views = enabled ? [self bottomBackgroundViews:bar] : @[];
        for (UIView *view in state.bottomBackgrounds.keyEnumerator.allObjects) {
            if ([views containsObject:view]) continue;
            [self restoreBackdrop:[state.bottomBackgrounds objectForKey:view] inView:view];
            [state.bottomBackgrounds removeObjectForKey:view];
        }
        if (!enabled) { state.bottomBackgrounds = nil; return; }
        if (!state.bottomBackgrounds) state.bottomBackgrounds = [NSMapTable weakToStrongObjectsMapTable];
        for (UIView *view in views) {
            DYYYFullscreenBarBackdrop *saved = [state.bottomBackgrounds objectForKey:view];
            if (!saved) {
                saved = [DYYYFullscreenBarBackdrop new];
                [state.bottomBackgrounds setObject:saved forKey:view];
            }
            if (view == bar) {
                if (view.backgroundColor && ![view.backgroundColor isEqual:UIColor.clearColor]) {
                    saved.nativeColor = view.backgroundColor;
                    saved.ownsColor = YES;
                    view.backgroundColor = UIColor.clearColor;
                }
                if (view.opaque) { saved.ownsOpacity = YES; view.opaque = NO; }
            } else if (!view.hidden) {
                saved.ownsHidden = YES;
                view.hidden = YES;
            }
        }
    } @finally {
        state.updatingBottomBar = NO;
    }
}
+ (CGFloat)bottomOccupiedHeightForView:(UIView *)view {
    UIWindow *window = view.window;
    if (!window) return 0;
    UIViewController *controller = [DYYYUtils firstAvailableViewControllerFromView:view];
    for (UIViewController *owner = controller; owner; owner = owner.parentViewController) {
        if (![owner respondsToSelector:@selector(activeBottomBar)]) continue;
        UIView *bar = [(AWEAwemeDetailTableViewController *)owner activeBottomBar];
        if (bar.window == window && bar.bounds.size.height > 0) return bar.bounds.size.height;
    }
    // 评论会隐藏底栏，尺寸仍以同一窗口中的真实栏为准。
    for (UIView *bar in [self tabBars].allObjects) if (bar.window == window && bar.bounds.size.height > 0) return bar.bounds.size.height;
    return 0;
}
+ (CGRect)rect:(CGRect)rect followingView:(UIView *)view controller:(UIViewController *)controller anchor:(UIView *)anchor {
    UIWindow *window = view.window;
    UIView *cell = [self cellForPlayer:view owner:controller];
    UIScrollView *pager = [self pagingViewForCell:cell];
    if (window && pager.window == window && [self view:cell spansWidthOf:pager] && ![anchor isDescendantOfView:cell]) {
        // 固定底栏先跟随各自的分页 cell，再换算到文案容器；预加载、复用和
        // 翻页都使用同一个视口基准，不能让屏幕坐标改变每页的文案区域高度。
        CGRect cellRect = [cell convertRect:cell.bounds toView:window];
        CGRect viewport = [pager convertRect:pager.bounds toView:window];
        rect.origin.y += CGRectGetMinY(cellRect) - CGRectGetMinY(viewport);
    }
    return rect;
}
+ (CGRect)bottomBarRect:(UIView *)bar followingView:(UIView *)view controller:(UIViewController *)controller {
    if (!view.window || bar.window != view.window) return CGRectNull;
    return [self rect:[bar convertRect:bar.bounds toView:view.window] followingView:view controller:controller anchor:bar];
}
+ (BOOL)layoutNativeInteraction:(UIViewController *)controller {
    if (![NSThread isMainThread]) return NO;
    UIView *view = controller.viewIfLoaded;
    UIView *parent = view.superview;
    if (view.window) [[self interactions] addObject:controller];
    if (!view.window || ![self view:view spansWidthOf:parent]) return NO;
    BOOL enabled = DYYYGetBool(@"DYYYEnableFullScreen");
    BOOL legacy = [[self contentSourceForController:controller] isEqualToString:@"co_play_watch"];
    for (UIViewController *owner = controller; owner; owner = owner.parentViewController) {
        if (![owner respondsToSelector:@selector(activeBottomBar)]) continue;
        UIView *bar = [(AWEAwemeDetailTableViewController *)owner activeBottomBar];
        if (![bar isKindOfClass:[UIView class]]) continue;
        if (!enabled) { [self layoutBottomBar:bar enabled:NO]; continue; }
        if (bar.window != view.window || ![self visible:bar]) continue;
        CGRect barRect = [bar convertRect:bar.bounds toView:view.window];
        UIView *root = owner.viewIfLoaded;
        CGRect rootRect = [root convertRect:root.bounds toView:view.window];
        if (!root || barRect.size.height <= 0 || barRect.size.height >= rootRect.size.height ||
            fabs(barRect.size.width - rootRect.size.width) > 1 || fabs(CGRectGetMaxY(barRect) - CGRectGetMaxY(rootRect)) > 1) continue;
        [self layoutBottomBar:bar enabled:YES];
        if (legacy) return NO;
        CGRect frame = view.frame;
        barRect = [self bottomBarRect:bar followingView:view controller:controller];
        CGFloat bottom = CGRectGetMinY([parent convertRect:barRect fromView:view.window]);
        CGFloat height = MIN(CGRectGetMaxY(parent.bounds), bottom) - frame.origin.y;
        if (height <= 0) return NO;
        if (fabs(frame.size.height - height) > 0.25) { frame.size.height = height; view.frame = frame; }
        return YES;
    }
    // 没有普通底栏时，保留原有 referString 规则；合集、一起看等例外继续有效。
    return NO;
}
// Live 图文也含 TTPlayerView 和有效视频尺寸，不能用播放器存在与否区分。
+ (BOOL)isImageContentController:(UIViewController *)controller {
    for (NSUInteger depth = 0; controller && depth < 5; depth++, controller = controller.parentViewController) {
        if (![controller respondsToSelector:@selector(model)]) continue;
        AWEAwemeModel *model = [(AWEPlayInteractionViewController *)controller model];
        if (![model isKindOfClass:NSClassFromString(@"AWEAwemeModel")]) continue;
        if ([model respondsToSelector:@selector(awemeType)] && model.awemeType == 68) return YES;
        if ([model respondsToSelector:@selector(albumImages)] && model.albumImages.count > 0) return YES;
        if ([model respondsToSelector:@selector(isLivePhoto)] && model.isLivePhoto) return YES;
        if ([model respondsToSelector:@selector(animatedImageVideoInfo)] && model.animatedImageVideoInfo) return YES;
        return NO;
    }
    return NO;
}
+ (NSHashTable<UIView *> *)players {
    static NSHashTable *players;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ players = [NSHashTable weakObjectsHashTable]; });
    return players;
}
+ (NSHashTable<UIView *> *)images {
    static NSHashTable *images;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ images = [NSHashTable weakObjectsHashTable]; });
    return images;
}
+ (NSHashTable<UIView *> *)tabBars {
    static NSHashTable *views;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ views = [NSHashTable weakObjectsHashTable]; });
    return views;
}
+ (NSHashTable<UIViewController *> *)interactions {
    static NSHashTable *controllers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controllers = [NSHashTable weakObjectsHashTable]; });
    return controllers;
}
+ (void)invalidateGuides {
    static BOOL scheduled = NO;
    if (scheduled) return;
    scheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        scheduled = NO;
        for (UIViewController *controller in [self interactions].allObjects) [controller.viewIfLoaded setNeedsLayout];
        for (UIView *player in [self players].allObjects) if (player.window) [player setNeedsLayout];
        for (UIView *image in [self images].allObjects) if (image.window) [image setNeedsLayout];
    });
}
+ (void)layoutRootTabBar:(UIView *)bar {
    BOOL fullscreen = DYYYGetBool(@"DYYYEnableFullScreen");
    BOOL hide = DYYYGetBool(@"DYYYHideBottomBg");
    BOOL playback = NO;
    if (fullscreen && !hide && bar.window) {
        // 沿现有根底栏的选中项判定，不让后台播放控制器把“我/消息”等页面的底栏清掉。
        Class buttonClass = NSClassFromString(@"AWENormalModeTabBarGeneralButton");
        for (UIView *view in bar.subviews) {
            if (![view isKindOfClass:buttonClass] || view.hidden || [(AWENormalModeTabBarGeneralButton *)view status] != 2) continue;
            NSString *label = view.accessibilityLabel;
            if ([label isEqualToString:@"首页"] || [label isEqualToString:@"朋友"]) { playback = YES; break; }
        }
    }
    [self layoutBottomBar:bar enabled:hide || playback];
}
+ (void)registerTabBar:(UIView *)tabBar {
    if (![NSThread isMainThread]) return;
    [[self tabBars] addObject:tabBar];
    [self layoutRootTabBar:tabBar];
    CGRect rect = tabBar.window ? [tabBar convertRect:tabBar.bounds toView:tabBar.window] : CGRectNull;
    NSString *signature = [NSString stringWithFormat:@"%p/%@/%d", tabBar.window, NSStringFromCGRect(rect), [self visible:tabBar]];
    NSString *previous = objc_getAssociatedObject(tabBar, @selector(registerTabBar:));
    if (![signature isEqualToString:previous]) {
        objc_setAssociatedObject(tabBar, @selector(registerTabBar:), signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [self invalidateGuides];
    }
}
// v776: 同城页原生把互动层放在 792（852 − 60，给底栏留位），底对齐的头像/点赞/翻页器/时间
// 都以 792 为锚点。我们按“首页推荐”规则把它撑到 852 后，整摞 UI 跟着贴到屏幕最底
// （实测：stack 底边 791.67 → 851.67，差 60）。所以同城页必须跳过这一步。
+ (BOOL)isInsideNearbyPage:(UIViewController *)controller {
    Class container = NSClassFromString(@"AWENearbyContainerViewController");
    Class fullscreen = NSClassFromString(@"AWENearbyFullScreenViewController");
    Class skylight = NSClassFromString(@"AWENearbySkyLightViewController");
    for (NSUInteger depth = 0; controller && depth < 12; depth++, controller = controller.parentViewController) {
        if ([controller isKindOfClass:container] || [controller isKindOfClass:fullscreen] || [controller isKindOfClass:skylight]) return YES;
    }
    return NO;
}

+ (void)layoutInteraction:(UIViewController *)controller {
    // v757: 原来只认首页推荐（contentSource == homepage_hot），从搜索点开的详情页
    // 会被直接 return，互动层保持「屏高 − 83（底栏 49 + 安全区 34）」= 769，
    // 贴着它底边的进度条就整体上移 83。详情页同样需要撑满，这里一并放行。
    BOOL supported = [self usesRecommendedLayoutForController:controller] ||
                     [self usesDetailLayoutForController:controller];
    if (![NSThread isMainThread] || !supported) return;
    if ([self isInsideNearbyPage:controller]) return;   // v776: 同城保持原生 792
    UIView *view = controller.viewIfLoaded;
    UIView *parent = view.superview;
    if (!view.window || ![self view:view spansWidthOf:parent]) return;
    [[self interactions] addObject:controller];
    for (UIView *bar in [self tabBars].allObjects) if (bar.window == view.window) [self layoutRootTabBar:bar];
    if ([self isImageContentController:controller]) return;
    DYYYFullscreenPlayerState *state = [self state:view];
    state.owner = controller;
    CGRect current = view.frame;
    if (!state.hasNativeFrame || !CGRectEqualToRect(current, state.lastAppliedFrame)) state.nativeFrame = current;
    state.hasNativeFrame = YES;
    CGRect target = state.nativeFrame;
    target.size.height = MIN(target.size.height, MAX(0, CGRectGetMaxY(parent.bounds) - target.origin.y));
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        target.size.height = MAX(0, CGRectGetMaxY(parent.bounds) - target.origin.y);
        CGRect guide = [parent convertRect:target toView:view.window];
        for (UIView *tabBar in [self tabBars].allObjects) {
            // 清屏只隐藏底栏，不释放其占位；信息区沿用同一边界，退出时无需
            // 等待底栏的显隐动画恢复，也不会把文案按全屏高度重新锚到底部。
            if (tabBar.window != view.window || CGRectIsEmpty(tabBar.bounds)) continue;
            CGRect tabRect = [self bottomBarRect:tabBar followingView:view controller:controller];
            if (CGRectIsNull(tabRect)) continue;
            if (CGRectGetMinY(tabRect) < CGRectGetMidY(guide)) continue;
            CGRect available = [DYYYFullscreenGeometry unoccludedViewport:guide top:CGRectGetMinY(guide) panel:tabRect gap:0];
            if (!CGRectIsNull(available)) guide = available;
        }
        target = [parent convertRect:guide fromView:view.window];
    }
    BOOL activeComment = [self hasCommentForInteractionController:controller];
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        if (activeComment && state.normalWindow == view.window && state.closedInteractionSize.height > 0) {
            // 评论隐藏 Tab 并不代表信息区可扩高，否则原生底部约束会下跳一个 Tab 高度。
            target.size.height = state.closedInteractionSize.height;
        } else if (!activeComment) {
            state.closedInteractionSize = target.size;
            state.normalWindow = view.window;
        }
    } else {
        state.closedInteractionSize = CGSizeZero;
    }
    state.lastAppliedFrame = target;
    if (fabs(current.size.height - target.size.height) > 0.25 || fabs(current.origin.y - target.origin.y) > 0.25) {
        view.frame = target;
    }
    NSString *signature = [NSString stringWithFormat:@"%@/%d/%d", NSStringFromCGRect(target),
                           DYYYGetBool(@"DYYYEnableFullScreen"), DYYYGetBool(@"DYYYEnableCommentBlur")];
    NSString *previous = objc_getAssociatedObject(controller, @selector(layoutInteraction:));
    if (![signature isEqualToString:previous]) {
        objc_setAssociatedObject(controller, @selector(layoutInteraction:), signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
        // 仅几何输入变化时更新播放器，不能每次 layout 都再次标记自身。
        for (UIView *player in [self players].allObjects) if (player.window == view.window) [player setNeedsLayout];
    }
}
+ (NSHashTable<UIView *> *)informationLabels {
    static NSHashTable *labels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ labels = [NSHashTable weakObjectsHashTable]; });
    return labels;
}
+ (void)layoutInformationLabel:(UIView *)label {
    if (![NSThread isMainThread] || !label.window || !label.superview) return;
    UIViewController *owner = [DYYYUtils firstAvailableViewControllerFromView:label];
    if (![self usesRecommendedLayoutForController:owner]) return;
    DYYYFullscreenPlayerState *state = [self state:label];
    [[self informationLabels] addObject:label];
    BOOL active = DYYYGetBool(@"DYYYEnableFullScreen") && [self hasCommentInWindow:label.window];
    if (!active) {
        if (state.captionAdjusted && CGPointEqualToPoint(label.center, state.captionAppliedCenter)) label.center = state.captionNativeCenter;
        state.captionAdjusted = NO;
        state.captionWindowFrame = [label convertRect:label.bounds toView:label.window];
        state.hasCaptionFrame = DYYYGetBool(@"DYYYEnableFullScreen");
        state.normalWindow = label.window;
        return;
    }
    if (!state.hasCaptionFrame || state.normalWindow != label.window) return;
    CGRect current = [label convertRect:label.bounds toView:label.window];
    CGFloat shift = CGRectGetMaxY(current) - CGRectGetMaxY(state.captionWindowFrame);
    if (shift > 0.25) {
        if (!state.captionAdjusted || !CGPointEqualToPoint(label.center, state.captionAppliedCenter)) state.captionNativeCenter = label.center;
        // 只拦截越过关闭态底边的下移，保留普通评论合法的向上平移和缩放。
        CGRect target = current;
        target.origin.y -= shift;
        CGPoint center = label.center;
        center.y += CGRectGetMidY([label.superview convertRect:target fromView:label.window]) - CGRectGetMidY(label.frame);
        state.captionAppliedCenter = center;
        state.captionAdjusted = YES;
        label.center = center;
    }
}
+ (void)rememberInteractionGuide:(UIViewController *)controller {
    UIView *view = controller.viewIfLoaded;
    if (![NSThread isMainThread] || ![self usesRecommendedLayoutForController:controller] || !view.window || !DYYYGetBool(@"DYYYEnableFullScreen") || [self hasCommentInWindow:view.window]) return;
    DYYYFullscreenPlayerState *state = [self state:view];
    state.owner = controller;
    state.closedInteractionSize = view.frame.size;
    state.normalWindow = view.window;
}
+ (BOOL)keepsMediaHostFullscreen:(UIView *)view state:(DYYYFullscreenPlayerState *)state {
    return state.mediaHost && !state.applying && state.normalWindow == view.window &&
        CGRectEqualToRect(state.mediaHostParentBounds, view.superview.bounds) &&
        DYYYGetBool(@"DYYYEnableFullScreen") && [self usesFullscreenLayoutForController:state.owner];
}
+ (CGRect)boundsForMediaHost:(UIView *)view proposed:(CGRect)bounds {
    DYYYFullscreenPlayerState *state = objc_getAssociatedObject(view, @selector(state:));
    if (![self keepsMediaHostFullscreen:view state:state]) return bounds;
    CGRect native = state.nativeHostFrame;
    CGPoint center = CGPointMake(CGRectGetMidX(native), CGRectGetMidY(native));
    native.size = bounds.size;
    native.origin = CGPointMake(center.x - bounds.size.width * 0.5, center.y - bounds.size.height * 0.5);
    state.nativeHostFrame = native;
    return (CGRect){CGPointZero, state.fullscreenHostFrame.size};
}
+ (CGPoint)centerForMediaHost:(UIView *)view proposed:(CGPoint)center {
    DYYYFullscreenPlayerState *state = objc_getAssociatedObject(view, @selector(state:));
    if (![self keepsMediaHostFullscreen:view state:state]) return center;
    CGRect native = state.nativeHostFrame;
    native.origin = CGPointMake(center.x - native.size.width * 0.5, center.y - native.size.height * 0.5);
    state.nativeHostFrame = native;
    return CGPointMake(CGRectGetMidX(state.fullscreenHostFrame), CGRectGetMidY(state.fullscreenHostFrame));
}
+ (CGRect)frameForInteractionView:(UIView *)view proposed:(CGRect)frame {
    // 只访问已注册的互动根视图和媒体承载区，不遍历普通视图的 responder。
    DYYYFullscreenPlayerState *state = objc_getAssociatedObject(view, @selector(state:));
    if ([self keepsMediaHostFullscreen:view state:state]) {
        state.nativeHostFrame = frame;
        return state.fullscreenHostFrame;
    }
    if (state.closedInteractionSize.height > 0 && [self usesRecommendedLayoutForController:state.owner] && state.normalWindow == view.window &&
        fabs(frame.size.width - state.closedInteractionSize.width) <= 1 &&
        DYYYGetBool(@"DYYYEnableFullScreen") && [self hasCommentForInteractionController:state.owner]) {
        frame.size.height = state.closedInteractionSize.height;
    }
    return frame;
}
+ (NSMapTable<AWECommentContainerViewController *, DYYYFullscreenCommentState *> *)comments {
    static NSMapTable *comments;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ comments = [NSMapTable weakToStrongObjectsMapTable]; });
    return comments;
}
+ (void)beginCommentInWindow:(UIWindow *)window {
    if (![NSThread isMainThread] || !window || !DYYYGetBool(@"DYYYEnableFullScreen") || [self hasCommentInWindow:window]) return;
    // 只预采样关闭态，不把点击或未成功的打开动作当作可见评论。
    for (UIView *label in [self informationLabels].allObjects) {
        if (label.window == window && [self visible:label]) [self layoutInformationLabel:label];
    }
}
+ (DYYYFullscreenPlayerState *)state:(UIView *)player {
    DYYYFullscreenPlayerState *state = objc_getAssociatedObject(player, @selector(state:));
    if (!state) {
        state = [DYYYFullscreenPlayerState new];
        objc_setAssociatedObject(player, @selector(state:), state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIWindow *window = player.window;
    if (window && (!CGSizeEqualToSize(state.layoutWindowSize, window.bounds.size) || !UIEdgeInsetsEqualToEdgeInsets(state.layoutSafeArea, window.safeAreaInsets))) {
        state.layoutWindowSize = window.bounds.size;
        state.layoutSafeArea = window.safeAreaInsets;
        state.awaitingNativeFrame = [DYYYFullscreenGeometry awaitsNativePlayerFrame:state.awaitingNativeFrame
            adjusted:state.adjusted current:player.frame lastApplied:state.lastAppliedFrame];
        state.hasNativeFrame = NO;
        state.adjusted = NO;
        state.hasNormalWindowFrame = NO;
        state.normalRenderSize = CGSizeZero;
        state.closedInteractionSize = CGSizeZero;
        state.hasCaptionFrame = NO;
        state.captionAdjusted = NO;
    }
    return state;
}
+ (BOOL)visible:(UIView *)view {
    if (!view.window) return NO;
    CGFloat alpha = 1;
    for (UIView *v = view; v; v = v.superview) {
        alpha *= v.alpha;
        if (v.hidden || alpha < 0.01) return NO;
    }
    return CGRectIntersectsRect([view convertRect:view.bounds toView:view.window], view.window.bounds);
}
+ (UIViewController *)owner:(UIView *)player state:(DYYYFullscreenPlayerState *)state {
    // 复用时旧 owner 仍可能是祖先；重新查找最近的播放控制器，不能只验证 descendant。
    state.owner = nil;
    UIResponder *responder = player;
    for (NSUInteger i = 0; responder && i < 16; i++, responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            NSString *name = NSStringFromClass(responder.class);
            if ([name containsString:@"PlayVideoViewController"] || [self isImageContentController:(UIViewController *)responder]) {
                state.owner = (UIViewController *)responder;
                return state.owner;
            }
        }
    }
    return nil;
}
+ (UIView *)cellForPlayer:(UIView *)player owner:(UIViewController *)owner {
    UIView *cell = nil;
    for (UIView *view = player.superview; view && ![view isKindOfClass:[UIWindow class]]; view = view.superview) {
        if (([view isKindOfClass:[UITableViewCell class]] || [view isKindOfClass:[UICollectionViewCell class]]) &&
            [self view:view spansWidthOf:[self pagingViewForCell:view]]) cell = view;
    }
    return cell ?: owner.parentViewController.viewIfLoaded.superview ?: owner.viewIfLoaded.superview;
}
+ (CGRect)visibleRect:(CGRect)rect ofView:(UIView *)view inWindow:(UIWindow *)window {
    if (!window || view.window != window || ![DYYYFullscreenGeometry isUsablePlayerFrame:rect]) return CGRectNull;
    rect = [view convertRect:rect toView:window];
    CGFloat alpha = 1;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        alpha *= ancestor.alpha;
        if (ancestor.hidden || alpha < 0.01) return CGRectNull;
        if (ancestor == window) return CGRectIntersection(rect, window.bounds);
        if (ancestor != view && ancestor.clipsToBounds) {
            rect = CGRectIntersection(rect, [ancestor convertRect:ancestor.bounds toView:window]);
            if (CGRectIsEmpty(rect)) return CGRectNull;
        }
    }
    return CGRectNull;
}
+ (CGRect)partialPanelForInner:(UIViewController *)inner outer:(UIViewController *)outer state:(DYYYFullscreenCommentState *)state {
    if (!inner) return CGRectNull;
    UIView *view = inner.viewIfLoaded;
    UIWindow *window = state.window;
    if (!window || view.window != window || ![view isDescendantOfView:state.outerView]) return CGRectNull;
    UIViewController *parent = inner.parentViewController;
    for (NSUInteger i = 0; parent && parent != outer && i < 32; i++) parent = parent.parentViewController;
    if (parent != outer) return CGRectNull;
    CGRect raw = [view convertRect:view.bounds toView:window];
    // 只取真实半屏根，不把整页评论、容器或裁切后的整页当成底部面板。
    if (![DYYYFullscreenGeometry isUsablePlayerFrame:raw] || CGRectGetMinY(raw) <= CGRectGetMinY(window.bounds) + window.safeAreaInsets.top + 1) return CGRectNull;
    CGRect rect = [self visibleRect:view.bounds ofView:view inWindow:window];
    return [DYYYFullscreenGeometry isUsablePlayerFrame:rect] ? rect : CGRectNull;
}
+ (BOOL)validCommentAttachment:(DYYYFullscreenCommentState *)state outer:(UIViewController *)outer window:(UIWindow *)window {
    UIView *root = outer.viewIfLoaded;
    return window && state.window == window && state.outerView == root && root.window == window &&
        CGRectEqualToRect(state.windowBounds, window.bounds) && UIEdgeInsetsEqualToEdgeInsets(state.safeArea, window.safeAreaInsets);
}
+ (CGRect)registeredPanel:(AWECommentContainerViewController *)outer state:(DYYYFullscreenCommentState *)state window:(UIWindow *)window {
    if (![self validCommentAttachment:state outer:outer window:window]) return CGRectNull;
    return [self partialPanelForInner:state.inner outer:outer state:state];
}
+ (CGRect)resolvePanelForComment:(AWECommentContainerViewController *)outer state:(DYYYFullscreenCommentState *)state {
    CGRect rect = [self registeredPanel:outer state:state window:state.window];
    if (!CGRectIsNull(rect)) return rect;
    state.inner = nil;
    if (!state.window) return CGRectNull;
    Class innerClass = NSClassFromString(@"AWECommentPanelContainerSwiftImpl.CommentContainerInnerViewController");
    if (!innerClass) return CGRectNull;
    // 只在外层生命周期/布局通知中找子 controller；热路径重验弱引用，不遍历窗口。
    const NSUInteger limit = 32;
    NSMutableArray<UIViewController *> *queue = [NSMutableArray arrayWithObject:outer];
    for (NSUInteger i = 0; i < queue.count; i++) {
        UIViewController *child = queue[i];
        if (child != outer && [child isKindOfClass:innerClass]) {
            rect = [self partialPanelForInner:child outer:outer state:state];
            if (!CGRectIsNull(rect)) { state.inner = child; return rect; }
        }
        if (queue.count == limit) continue;
        for (UIViewController *nested in child.childViewControllers) {
            [queue addObject:nested];
            if (queue.count == limit) break;
        }
    }
    return CGRectNull;
}
+ (NSString *)itemIDForModel:(AWEAwemeModel *)model {
    if (![model isKindOfClass:NSClassFromString(@"AWEAwemeModel")] || ![model respondsToSelector:@selector(itemID)]) return nil;
    id identifier = model.itemID;
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}
+ (BOOL)controller:(UIViewController *)controller descendsFrom:(UIViewController *)ancestor {
    if (!ancestor) return NO;
    for (NSUInteger i = 0; controller && i < 16; i++, controller = controller.parentViewController) {
        if (controller == ancestor) return YES;
    }
    return NO;
}
+ (BOOL)comment:(AWECommentContainerViewController *)outer ownsMedia:(UIView *)media owner:(UIViewController *)owner model:(AWEAwemeModel *)model cell:(UIView *)cell {
    NSString *itemID = [self itemIDForModel:model];
    if (!itemID.length || !owner || !cell || ![media isDescendantOfView:cell]) return NO;
    id interaction = [outer respondsToSelector:@selector(interactionViewController)] ? outer.interactionViewController : nil;
    AWEAwemeModel *panelModel = [outer respondsToSelector:@selector(model)] ? outer.model : nil;
    NSString *panelItem = [self itemIDForModel:panelModel];
    if (panelItem.length && ![panelItem isEqualToString:itemID]) return NO;
    id nativePlayer = [outer respondsToSelector:@selector(videoPlayer)] ? outer.videoPlayer : nil;
    if (nativePlayer == media || nativePlayer == owner) return YES;
    if ([interaction isKindOfClass:UIViewController.class]) {
        UIViewController *hud = interaction;
        UIView *hudView = hud.viewIfLoaded;
        if (hudView.window != media.window) return NO;
        NSString *hudItem = [hud respondsToSelector:@selector(model)] ? [self itemIDForModel:[(AWEPlayInteractionViewController *)hud model]] : nil;
        if (hudItem.length && ![hudItem isEqualToString:itemID]) return NO;
        if ([hudView isDescendantOfView:cell] || [self controller:owner descendsFrom:hud]) return YES;
        // 有真实 HUD 但挂在另一 cell 时，不可回退到窗口内同 ID 作品。
        UIView *hudCell = [self cellForPlayer:hudView owner:hud];
        if ([hudCell isKindOfClass:UITableViewCell.class] || [hudCell isKindOfClass:UICollectionViewCell.class]) return NO;
    }
    UIViewController *host = outer.parentViewController;
    return panelItem.length && host && host != media.window.rootViewController &&
        ![host isKindOfClass:UINavigationController.class] && ![host isKindOfClass:UITabBarController.class] &&
        [self controller:owner descendsFrom:host];
}
+ (CGRect)panelInWindow:(UIWindow *)window viewport:(CGRect)viewport media:(UIView *)media owner:(UIViewController *)owner model:(AWEAwemeModel *)model cell:(UIView *)cell {
    if (![DYYYFullscreenGeometry isUsablePlayerFrame:viewport]) return CGRectNull;
    CGRect result = CGRectNull;
    NSMapTable *comments = [self comments];
    for (AWECommentContainerViewController *outer in comments) {
        CGRect rect = [self registeredPanel:outer state:[comments objectForKey:outer] window:window];
        if (CGRectIsNull(rect) || CGRectGetMinY(rect) <= CGRectGetMinY(viewport) + 1 || !CGRectIntersectsRect(rect, viewport) ||
            CGRectGetMinX(rect) > CGRectGetMinX(viewport) + 1 || CGRectGetMaxX(rect) < CGRectGetMaxX(viewport) - 1 ||
            ![self comment:outer ownsMedia:media owner:owner model:model cell:cell]) continue;
        if (CGRectIsNull(result) || CGRectGetMinY(rect) < CGRectGetMinY(result)) result = rect;
    }
    return result;
}
+ (BOOL)hasCommentInWindow:(UIWindow *)window {
    if (![NSThread isMainThread] || !window) return NO;
    NSMapTable *comments = [self comments];
    for (AWECommentContainerViewController *outer in comments) {
        if (!CGRectIsNull([self registeredPanel:outer state:[comments objectForKey:outer] window:window])) return YES;
    }
    return NO;
}
+ (BOOL)hasCommentForInteractionController:(UIViewController *)controller {
    if (![NSThread isMainThread] || !controller.viewIfLoaded.window) return NO;
    UIWindow *window = controller.viewIfLoaded.window;
    NSMapTable *comments = [self comments];
    for (AWECommentContainerViewController *outer in comments) {
        if (![outer respondsToSelector:@selector(interactionViewController)] || outer.interactionViewController != controller) continue;
        if (!CGRectIsNull([self registeredPanel:outer state:[comments objectForKey:outer] window:window])) return YES;
    }
    return NO;
}
+ (UIViewController *)synchronizePlayer:(UIView *)player state:(DYYYFullscreenPlayerState *)state {
    UIViewController *owner = [self owner:player state:state];
    AWEAwemeModel *model = [owner respondsToSelector:@selector(model)] ? [(AWEPlayVideoViewController *)owner model] : nil;
    id content = [model respondsToSelector:@selector(video)] ? model.video : nil;
    id identifier = [model respondsToSelector:@selector(itemID)] ? model.itemID : nil;
    NSString *itemID = [identifier isKindOfClass:NSString.class] ? identifier : nil;
    content = content ?: model;
    UIView *cell = [self cellForPlayer:player owner:owner];
    BOOL canCache = model && content && itemID.length && player.window && player.superview && cell && cell.window == player.window &&
        CGAffineTransformIsIdentity(player.transform) && CGAffineTransformIsIdentity(player.superview.transform) &&
        CGAffineTransformIsIdentity(cell.transform);
    BOOL sameItem = state.playerItemID == itemID || [state.playerItemID isEqualToString:itemID];
    // 作品标识、对象及坐标系都要相同；旧视图上的自身结果不自动升级成新作品的原生基准。
    if (!canCache || state.playerOwner != owner || state.playerModel != model || state.playerContent != content || !sameItem ||
        state.playerCell != cell || state.playerSuperview != player.superview || state.playerWindow != player.window ||
        !CGRectEqualToRect(state.playerSuperviewBounds, player.superview.bounds) || !CGSizeEqualToSize(state.playerCellSize, cell.bounds.size)) {
        state.awaitingNativeFrame = [DYYYFullscreenGeometry awaitsNativePlayerFrame:state.awaitingNativeFrame
            adjusted:state.adjusted current:player.frame lastApplied:state.lastAppliedFrame];
        state.hasNativeFrame = NO;
        state.adjusted = NO;
        state.hasNormalWindowFrame = NO;
        state.normalRenderSize = CGSizeZero;
        state.normalWindow = nil;
        state.normalCell = nil;
    }
    state.awaitingNativeFrame = [DYYYFullscreenGeometry awaitsNativePlayerFrame:state.awaitingNativeFrame
        adjusted:NO current:player.frame lastApplied:state.lastAppliedFrame];
    state.playerOwner = owner;
    state.playerModel = model;
    state.playerContent = content;
    state.playerItemID = itemID;
    state.playerCell = cell;
    state.playerSuperview = player.superview;
    state.playerWindow = player.window;
    state.playerSuperviewBounds = player.superview.bounds;
    state.playerCellSize = cell.bounds.size;
    state.playerCanCache = canCache;
    return owner;
}
+ (void)rememberNativeFrame:(CGRect)frame forPlayer:(UIView *)player state:(DYYYFullscreenPlayerState *)state {
    UIView *cell = state.playerCell;
    UIWindow *window = player.window;
    BOOL valid = state.playerCanCache && !state.awaitingNativeFrame && cell && cell.window == window &&
        window && player.superview && [DYYYFullscreenGeometry isUsablePlayerFrame:frame];
    if (!valid) {
        state.hasNormalWindowFrame = NO;
        return;
    }
    CGRect normal = [player.superview convertRect:frame toView:window];
    CGRect reference = [cell convertRect:cell.bounds toView:window];
    if (![DYYYFullscreenGeometry isUsablePlayerFrame:normal] || ![DYYYFullscreenGeometry isUsablePlayerFrame:reference]) {
        state.hasNormalWindowFrame = NO;
        return;
    }
    state.normalWindowFrame = normal;
    state.normalCell = cell;
    state.normalCellWindowFrame = reference;
    state.hasNormalWindowFrame = YES;
    state.normalWindow = window;
}
+ (CGRect)normalFrameForPlayer:(UIView *)player state:(DYYYFullscreenPlayerState *)state {
    UIView *cell = state.playerCell;
    UIWindow *window = player.window;
    if (!state.hasNormalWindowFrame || !window || state.normalWindow != window || state.normalCell != cell ||
        cell.window != window || !player.superview) return CGRectNull;
    CGRect reference = [cell convertRect:cell.bounds toView:window];
    CGRect normal = [DYYYFullscreenGeometry translateRect:state.normalWindowFrame fromReference:state.normalCellWindowFrame toReference:reference];
    if (CGRectIsNull(normal)) return CGRectNull;
    CGRect local = [player.superview convertRect:normal fromView:window];
    return [DYYYFullscreenGeometry isUsablePlayerFrame:local] ? local : CGRectNull;
}
+ (CGRect)viewportForCell:(UIView *)cell window:(UIWindow *)window {
    return [self visibleRect:cell.bounds ofView:cell inWindow:window];
}
+ (CGRect)viewport:(CGRect)viewport abovePanel:(CGRect)panel inWindow:(UIWindow *)window {
    if (CGRectIsNull(panel)) return CGRectNull;
    CGRect safe = UIEdgeInsetsInsetRect(window.bounds, UIEdgeInsetsMake(window.safeAreaInsets.top, window.safeAreaInsets.left, 0, window.safeAreaInsets.right));
    viewport = CGRectIntersection(viewport, safe);
    return [DYYYFullscreenGeometry unoccludedViewport:viewport top:CGRectGetMinY(viewport) panel:panel gap:0];
}
+ (BOOL)playerHasComment:(UIView *)player state:(DYYYFullscreenPlayerState *)state {
    if (![self comments].count) return NO;
    UIWindow *window = player.window;
    UIView *cell = state.playerCell;
    return !CGRectIsNull([self panelInWindow:window viewport:[self viewportForCell:cell window:window]
        media:player owner:state.playerOwner model:state.playerModel cell:cell]);
}
+ (CGRect)targetForPlayer:(UIView *)player native:(CGRect)native state:(DYYYFullscreenPlayerState *)state {
    if (!DYYYGetBool(@"DYYYEnableFullScreen") || ![self visible:player] ||
        !state.playerCanCache || state.awaitingNativeFrame || !state.hasNativeFrame) return native;
    UIWindow *window = player.window;
    UIViewController *owner = state.playerOwner;
    if (![self usesFullscreenLayoutForController:owner]) return native;
    if ([self isImageContentController:owner]) {
        state.hasNormalWindowFrame = NO;
        state.normalRenderSize = CGSizeZero;
        return native;
    }
    UIView *cell = state.playerCell;
    if (!owner || !cell || cell.window != window || !player.superview) return native;
    CGRect viewport = [self viewportForCell:cell window:window];
    CGRect panel = [self panelInWindow:window viewport:viewport media:player owner:owner model:state.playerModel cell:cell];
    BOOL activeComment = !CGRectIsNull(panel);
    if (!activeComment) {
        // 普通播放只记录本作品原生几何，不按宿主 bounds、交互层高度或视频横竖比改写。
        [self rememberNativeFrame:native forPlayer:player state:state];
        return native;
    }
    if (DYYYGetBool(@"DYYYEnableCommentBlur")) {
        CGRect normal = [self normalFrameForPlayer:player state:state];
        return CGRectIsNull(normal) ? native : normal;
    }
    CGSize media = CGSizeZero;
    if ([owner respondsToSelector:@selector(getPlayerVideoSize)]) media = [(AWEPlayVideoViewController *)owner getPlayerVideoSize];
    if (media.width <= 0 || media.height <= 0) return native;
    // 按实际渲染比例适配状态栏下沿至评论面板的可用区，不改渲染层。
    CGSize rendered = state.normalRenderSize;
    if (state.hasNormalWindowFrame && state.normalWindow == window && rendered.width > 0 && rendered.height > 0) media = rendered;
    CGRect available = [self viewport:viewport abovePanel:panel inWindow:window];
    CGRect fit = [DYYYFullscreenGeometry aspectFit:media inRect:available];
    return CGRectIsNull(fit) ? native : [player.superview convertRect:fit fromView:window];
}
+ (CGRect)frameForPlayer:(UIView *)player proposed:(CGRect)frame {
    if (![NSThread isMainThread]) return frame;
    DYYYFullscreenPlayerState *state = [self state:player];
    if (state.applying) return frame;
    [self synchronizePlayer:player state:state];
    if (!state.playerCanCache || ![DYYYFullscreenGeometry isUsablePlayerFrame:frame]) {
        state.hasNativeFrame = NO;
        state.adjusted = NO;
        state.hasNormalWindowFrame = NO;
        state.normalRenderSize = CGSizeZero;
        return frame;
    }
    // 当前作品明确收到原生 setter 输入，才解除复用后对旧自身结果的等待。
    state.awaitingNativeFrame = NO;
    state.nativeFrame = frame;
    state.hasNativeFrame = YES;
    CGRect target = [self targetForPlayer:player native:frame state:state];
    state.lastAppliedFrame = target;
    state.adjusted = !CGRectEqualToRect(target, frame);
    return target;
}
+ (void)preparePlayer:(UIView *)player {
    if (![NSThread isMainThread]) return;
    DYYYFullscreenPlayerState *state = [self state:player];
    if (state.applying) return;
    [[self players] addObject:player];
    UIViewController *owner = [self owner:player state:state];
    [self layoutPlayerContainer:owner.parentViewController];
    owner = [self synchronizePlayer:player state:state];
    if ([self isImageContentController:owner]) {
        state.hasNativeFrame = NO;
        state.adjusted = NO;
        state.hasNormalWindowFrame = NO;
        state.normalRenderSize = CGSizeZero;
        return;
    }
    if (!state.playerCanCache || state.awaitingNativeFrame) return;
    CGRect current = player.frame;
    if (![DYYYFullscreenGeometry isUsablePlayerFrame:current]) {
        state.hasNativeFrame = NO;
        state.adjusted = NO;
        state.hasNormalWindowFrame = NO;
        state.normalRenderSize = CGSizeZero;
        return;
    }
    CGRect savedNative = state.nativeFrame;
    BOOL canRestore = state.hasNativeFrame && state.adjusted && CGRectEqualToRect(current, state.lastAppliedFrame);
    if (canRestore && DYYYGetBool(@"DYYYEnableFullScreen") && ![self playerHasComment:player state:state]) {
        savedNative = [self normalFrameForPlayer:player state:state];
        // 参考坐标系不再可比较时，不把自己的结果缓存成下一次的原生基准。
        canRestore = [DYYYFullscreenGeometry isUsablePlayerFrame:savedNative];
        if (!canRestore) {
            state.awaitingNativeFrame = YES;
            state.adjusted = NO;
            return;
        }
    }
    // 只有当前 frame 仍是本模块最后一次改写的结果，才允许撤销评论避让。
    // 原生通过 bounds/center 或转场更新了几何时，以实际 frame 为准，绝不回放旧值。
    CGRect native = [DYYYFullscreenGeometry nativePlayerFrameForLayout:current savedNative:savedNative
        lastApplied:state.lastAppliedFrame adjusted:canRestore];
    state.nativeFrame = native;
    state.hasNativeFrame = YES;
    CGRect target = [self targetForPlayer:player native:native state:state];
    state.lastAppliedFrame = target;
    state.adjusted = !CGRectEqualToRect(target, native);
    if (!CGRectEqualToRect(current, target)) {
        state.applying = YES;
        @try {
            player.frame = target;
        } @finally {
            state.applying = NO;
        }
    }
}
+ (UIView *)renderView:(UIView *)player {
    for (UIView *view in player.subviews) {
        NSString *name = NSStringFromClass(view.class);
        if ([name hasPrefix:@"TTMetal"] || [name containsString:@"RenderView"]) return view;
    }
    return nil;
}
#pragma mark - 媒体容器

+ (void)layoutPlayerContainer:(UIViewController *)controller {
    Class pureListClass = NSClassFromString(@"AFDPureModePageListViewController");
    BOOL pureModeList = pureListClass && [controller isKindOfClass:pureListClass];
    if (![NSThread isMainThread] || (!pureModeList && ![controller respondsToSelector:@selector(contentView)])) return;
    UIView *view = controller.viewIfLoaded;
    if (!view.window || !view.superview) return;
    BOOL enabled = DYYYGetBool(@"DYYYEnableFullScreen") && [self usesFullscreenLayoutForController:controller];
    UIView *content = pureModeList ? nil : [(AWEDPlayerViewController_Merge *)controller contentView];
    for (UIView *host in content && content != view ? @[view, content] : @[view]) {
        DYYYFullscreenPlayerState *state = objc_getAssociatedObject(host, @selector(state:));
        if (state.applying) continue;
        CGRect current = host.frame;
        if (!enabled) {
            BOOL restore = state.mediaHost && CGRectEqualToRect(current, state.fullscreenHostFrame);
            state.mediaHost = NO;
            if (restore) host.frame = state.nativeHostFrame;
            continue;
        }
        UIView *parent = host.superview;
        if (!parent || CGRectIsEmpty(parent.bounds) || !CGAffineTransformIsIdentity(host.transform)) continue;
        if (!state.mediaHost && ![self view:host spansWidthOf:parent]) continue;
        state = [self state:host];
        if (!state.mediaHost || state.normalWindow != view.window || !CGRectEqualToRect(state.mediaHostParentBounds, parent.bounds)) {
            state.nativeHostFrame = current;
            state.fullscreenHostFrame = current;
        }
        CGRect target = parent.bounds;
        state.mediaHost = YES;
        state.mediaHostParentBounds = parent.bounds;
        state.owner = controller;
        state.normalWindow = view.window;
        state.fullscreenHostFrame = target;
        // 承载区全程全高；评论避让只改内部播放器，不补背景或等待消失回调。
        if (!CGRectEqualToRect(current, target)) {
            state.applying = YES;
            host.frame = target;
            state.applying = NO;
        }
    }
}

// 渲染布局完成后记录画面尺寸，供评论避让使用。
+ (void)finishPlayer:(UIView *)player {
    if (![NSThread isMainThread]) return;
    DYYYFullscreenPlayerState *state = [self state:player];
    UIViewController *owner = [self owner:player state:state];
    [self layoutPlayerContainer:owner.parentViewController];
    owner = [self synchronizePlayer:player state:state];
    if (!state.playerCanCache || state.awaitingNativeFrame) return;
    if (![self usesFullscreenLayoutForController:owner] || [self isImageContentController:owner]) return;
    BOOL fullscreen = DYYYGetBool(@"DYYYEnableFullScreen");
    BOOL activeComment = fullscreen && [self playerHasComment:player state:state];
    if (activeComment && DYYYGetBool(@"DYYYEnableCommentBlur")) [self preparePlayer:player];
    UIView *render = [self renderView:player];
    if (fullscreen && !activeComment && state.hasNormalWindowFrame && render.bounds.size.width > 0 && render.bounds.size.height > 0) {
        state.normalRenderSize = render.bounds.size;
    }
}
+ (DYYYFullscreenImageState *)imageState:(UIView *)view {
    DYYYFullscreenImageState *state = objc_getAssociatedObject(view, @selector(imageState:));
    if (!state) {
        state = [DYYYFullscreenImageState new];
        objc_setAssociatedObject(view, @selector(imageState:), state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}
+ (UIImageView *)artworkViewForImage:(UIView *)view {
    static Class imageClass;
    static Ivar artworkIvar;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        imageClass = NSClassFromString(@"BDMultiContentContainer.ImageContentView");
        Ivar ivar = imageClass ? class_getInstanceVariable(imageClass, "imageContentView") : NULL;
        const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
        if (type && *type == '@') artworkIvar = ivar;
    });
    // 不选第一个 UIImageView：加载图、装饰层和封面可能同时在树上。
    id art = artworkIvar && [view isKindOfClass:imageClass] ? object_getIvar(view, artworkIvar) : nil;
    return [art isKindOfClass:UIImageView.class] && [art isDescendantOfView:view] ? art : nil;
}
+ (BOOL)usableImageTransform:(CGAffineTransform)transform {
    // 旋转、镜像以及非均匀原生变换不接管。
    return isfinite(transform.a) && transform.a > 0 && transform.a == transform.d &&
        transform.b == 0 && transform.c == 0 && isfinite(transform.tx) && isfinite(transform.ty);
}
+ (CGRect)artRectForImage:(UIImageView *)art inView:(UIView *)view {
    if (!art.image || ![DYYYFullscreenGeometry isUsablePlayerFrame:art.bounds]) return CGRectNull;
    CGRect rect = art.bounds;
    switch (art.contentMode) {
        case UIViewContentModeScaleAspectFit:
            rect = [DYYYFullscreenGeometry aspectFit:art.image.size inRect:rect];
            break;
        case UIViewContentModeScaleToFill:
            break;
        case UIViewContentModeScaleAspectFill:
            if (art.clipsToBounds) break;
            return CGRectNull;
        default:
            return CGRectNull;
    }
    if (CGRectIsNull(rect)) return CGRectNull;
    rect = [art convertRect:rect toView:view];
    for (UIView *ancestor = art; ancestor && ancestor != view; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha < 0.01 || ![self usableImageTransform:ancestor.transform]) return CGRectNull;
        if ([ancestor isKindOfClass:UIScrollView.class]) {
            UIScrollView *scroll = (UIScrollView *)ancestor;
            if (scroll.isZooming || fabs(scroll.zoomScale - 1) > 0.001) return CGRectNull;
        }
        if (ancestor.clipsToBounds) rect = CGRectIntersection(rect, [ancestor convertRect:ancestor.bounds toView:view]);
    }
    if (view.clipsToBounds) rect = CGRectIntersection(rect, view.bounds);
    return [DYYYFullscreenGeometry isUsablePlayerFrame:rect] ? rect : CGRectNull;
}
+ (BOOL)synchronizeImage:(UIView *)view state:(DYYYFullscreenImageState *)state {
    UIWindow *window = view.window;
    UIView *host = view.superview;
    UIViewController *owner = window ? [DYYYUtils firstAvailableViewControllerFromView:view] : nil;
    UIView *cell = [self cellForPlayer:view owner:owner];
    UIImageView *art = [self artworkViewForImage:view];
    UIImage *artwork = art.image;
    CGRect artRect = [self artRectForImage:art inView:view];
    AWEAwemeModel *model = nil;
    Class slidesClass = NSClassFromString(@"AFDSlidesView");
    for (UIView *ancestor = host; ancestor && ancestor != cell; ancestor = ancestor.superview) {
        if (slidesClass && [ancestor isKindOfClass:slidesClass] && [ancestor respondsToSelector:@selector(model)]) {
            model = [(AFDSlidesView *)ancestor model];
            break;
        }
    }
    if (![self itemIDForModel:model].length) {
        for (UIViewController *controller = owner; controller && [controller.viewIfLoaded isDescendantOfView:cell]; controller = controller.parentViewController) {
            if (![controller respondsToSelector:@selector(model)]) continue;
            AWEAwemeModel *candidate = [(AWEPlayInteractionViewController *)controller model];
            if ([self itemIDForModel:candidate].length) { model = candidate; break; }
        }
    }
    NSString *itemID = [self itemIDForModel:model];
    CGPoint anchor = view.layer.anchorPoint;
    BOOL valid = owner && cell && cell.window == window && [view isDescendantOfView:cell] && window && host && artwork && itemID.length &&
        !CGRectIsNull(artRect) && anchor.x == 0.5 && anchor.y == 0.5 && [DYYYFullscreenGeometry isUsablePlayerFrame:view.bounds];
    if (!valid || state.owner != owner || state.model != model || ![state.itemID isEqualToString:itemID] || state.artView != art ||
        state.artwork != artwork || state.cell != cell || state.host != host || state.window != window ||
        !CGRectEqualToRect(state.artRect, artRect) || !CGRectEqualToRect(state.bounds, view.bounds) ||
        !CGRectEqualToRect(state.hostBounds, host.bounds) || !CGSizeEqualToSize(state.cellSize, cell.bounds.size) ||
        !CGRectEqualToRect(state.windowBounds, window.bounds) || !UIEdgeInsetsEqualToEdgeInsets(state.safeArea, window.safeAreaInsets)) {
        // 复用时不能把视图上残留的自身结果升级为新作品的关闭态。
        state.awaitingNativeTransform = state.awaitingNativeTransform || state.adjusted;
        state.adjusted = NO;
        state.hasClosedTransform = NO;
    }
    state.awaitingNativeTransform = state.awaitingNativeTransform && CGAffineTransformEqualToTransform(view.transform, state.lastAppliedTransform);
    state.owner = owner;
    state.model = model;
    state.itemID = itemID;
    state.artView = art;
    state.artwork = artwork;
    state.artRect = artRect;
    state.cell = cell;
    state.host = host;
    state.window = window;
    state.bounds = view.bounds;
    state.hostBounds = host.bounds;
    state.cellSize = cell.bounds.size;
    state.windowBounds = window.bounds;
    state.safeArea = window.safeAreaInsets;
    return valid;
}
+ (CGAffineTransform)targetForImageView:(UIView *)view native:(CGAffineTransform)native state:(DYYYFullscreenImageState *)state restoring:(BOOL)restoring {
    if (!DYYYGetBool(@"DYYYEnableFullScreen") || ![self usesFullscreenLayoutForController:state.owner]) {
        state.hasClosedTransform = NO;
        return native;
    }
    if (![self usableImageTransform:native] || ![self visible:view]) {
        state.hasClosedTransform = NO;
        return native;
    }
    UIWindow *window = state.window;
    CGRect viewport = [self comments].count ? [self viewportForCell:state.cell window:window] : CGRectNull;
    CGRect panel = [self panelInWindow:window viewport:viewport media:view owner:state.owner model:state.model cell:state.cell];
    if (CGRectIsNull(panel)) {
        if (restoring && state.hasClosedTransform) return state.closedTransform;
        state.closedTransform = native;
        state.hasClosedTransform = YES;
        return native;
    }
    if (DYYYGetBool(@"DYYYEnableCommentBlur")) return state.hasClosedTransform ? state.closedTransform : native;
    CGRect available = [self viewport:viewport abovePanel:panel inWindow:window];
    if (CGRectIsNull(available)) return native;
    CGRect local = [state.host convertRect:available fromView:window];
    if (![DYYYFullscreenGeometry isUsablePlayerFrame:local]) return native;
    CGAffineTransform fit = [DYYYFullscreenGeometry aspectFitTransformForBounds:view.bounds contentRect:state.artRect center:view.center inRect:local];
    return [self usableImageTransform:fit] ? fit : native;
}
+ (CGAffineTransform)transformForImageView:(UIView *)view proposed:(CGAffineTransform)transform {
    if (![NSThread isMainThread]) return transform;
    DYYYFullscreenImageState *state = [self imageState:view];
    if (state.applying) return transform;
    BOOL valid = [self synchronizeImage:view state:state];
    state.awaitingNativeTransform = NO; // 当前绑定明确收到了原生 setter 输入。
    state.nativeTransform = transform;
    CGAffineTransform target = valid ? [self targetForImageView:view native:transform state:state restoring:NO] : transform;
    state.lastAppliedTransform = target;
    state.adjusted = !CGAffineTransformEqualToTransform(target, transform);
    return target;
}
+ (void)layoutImageView:(UIView *)view {
    if (![NSThread isMainThread]) return;
    DYYYFullscreenImageState *state = [self imageState:view];
    if (state.applying || ![self synchronizeImage:view state:state] || state.awaitingNativeTransform) return;
    [[self images] addObject:view];
    CGAffineTransform current = view.transform;
    BOOL owns = state.adjusted && CGAffineTransformEqualToTransform(current, state.lastAppliedTransform);
    CGAffineTransform native = owns ? state.nativeTransform : current;
    CGAffineTransform target = [self targetForImageView:view native:native state:state restoring:owns];
    state.nativeTransform = native;
    state.lastAppliedTransform = target;
    state.adjusted = !CGAffineTransformEqualToTransform(target, native);
    if (!CGAffineTransformEqualToTransform(current, target)) {
        state.applying = YES;
        @try {
            view.transform = target;
        } @finally {
            state.applying = NO;
        }
    }
}
+ (void)invalidateCommentMediaInWindow:(UIWindow *)window {
    if (!window) return;
    static NSHashTable<UIWindow *> *windows;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ windows = [NSHashTable weakObjectsHashTable]; });
    BOOL scheduled = windows.count > 0;
    [windows addObject:window];
    if (scheduled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<UIWindow *> *affected = windows.allObjects;
        [windows removeAllObjects];
        for (UIView *player in [self players].allObjects) if (player.window && [affected containsObject:player.window]) [player setNeedsLayout];
        for (UIView *image in [self images].allObjects) if (image.window && [affected containsObject:image.window]) [image setNeedsLayout];
    });
}
+ (void)commentController:(UIViewController *)controller visible:(BOOL)visible {
    if (![NSThread isMainThread] || ![controller isKindOfClass:NSClassFromString(@"AWECommentContainerViewController")]) return;
    AWECommentContainerViewController *outer = (AWECommentContainerViewController *)controller;
    NSMapTable *comments = [self comments];
    DYYYFullscreenCommentState *state = [comments objectForKey:outer];
    UIWindow *previous = state.window;
    UIView *view = visible ? outer.viewIfLoaded : nil;
    UIWindow *window = view.window;
    if (!window || outer.isBeingDismissed || outer.isMovingFromParentViewController) {
        [comments removeObjectForKey:outer];
        [self invalidateCommentMediaInWindow:previous];
        return;
    }
    if (!state) {
        state = [DYYYFullscreenCommentState new];
        state.lastPanel = CGRectNull;
        [comments setObject:state forKey:outer];
    }
    UIViewController *previousInner = state.inner;
    BOOL geometryChanged = ![self validCommentAttachment:state outer:outer window:window];
    if (geometryChanged) state.inner = nil;
    state.window = window;
    state.outerView = view;
    state.windowBounds = window.bounds;
    state.safeArea = window.safeAreaInsets;
    CGRect panel = [self resolvePanelForComment:outer state:state];
    BOOL fullscreen = DYYYGetBool(@"DYYYEnableFullScreen");
    BOOL blur = DYYYGetBool(@"DYYYEnableCommentBlur");
    BOOL changed = geometryChanged || previousInner != state.inner || !CGRectEqualToRect(panel, state.lastPanel) ||
        fullscreen != state.fullscreen || blur != state.blur;
    state.lastPanel = panel;
    state.fullscreen = fullscreen;
    state.blur = blur;
    if (previous != window) [self invalidateCommentMediaInWindow:previous];
    if (changed) [self invalidateCommentMediaInWindow:window];
}
@end
