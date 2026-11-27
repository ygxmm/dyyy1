#!/usr/bin/env python3
"""原生播放器几何保留的结构回归；不替代 macOS 原生断言或 UIKit 真机验收。"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]

def check(condition, reason):
    print(('PASS' if condition else 'FAIL') + ' fullscreen frame: ' + reason)
    if not condition:
        raise SystemExit(1)

geometry = (ROOT / 'Sources/Features/DYYYFullscreenGeometry.m').read_text()
coordinator = (ROOT / 'Sources/Features/DYYYFullscreenCoordinator.m').read_text()
xm = (ROOT / 'DYYY.xm').read_text()
make = (ROOT / 'Makefile').read_text()
def method(name):
    tail = coordinator.split(name, 1)[1]
    return tail.split('\n+ (', 1)[0]

target = method('+ (CGRect)targetForPlayer:')
closed = re.search(r'if \(!activeComment\) \{(.*?)\n    \}', target, re.S)
check(closed is not None and 'return native;' in closed.group(1),
      '无评论时在选比例和面板计算前原样返回原生 frame')
check('stableFullscreenPlayerFrame' not in coordinator + geometry and
      not re.search(r'native\.(?:origin|size)\s*(?:\.[xy]|\.width|\.height)?\s*=', target) and
      'guide.size.height' not in target and 'player.superview.bounds' not in target,
      '删除宿主强制归零、横屏交互层改高和竖屏 MAX 扩高')
check(closed.end() < target.index('getPlayerVideoSize') and
      'normalFrameForPlayer:player state:state' in target and 'panelInWindow:window viewport:viewport' in target,
      '磨砂冻结与普通评论避让独立保留，普通播放不读媒体比例')
sync = method('+ (UIViewController *)synchronizePlayer:')
check(all(key in sync for key in ('state.playerOwner != owner', 'state.playerContent != content',
      'state.playerCell != cell', 'state.playerSuperview != player.superview', 'state.playerWindow != player.window')) and
      all(key in sync for key in ('state.hasNativeFrame = NO', 'state.adjusted = NO',
      'state.hasNormalWindowFrame = NO', 'state.normalRenderSize = CGSizeZero')),
      '作品、控制器、cell、父视图和窗口变化均使原生缓存失效')
check('itemID.length' in sync and 'CGAffineTransformIsIdentity(player.transform)' in sync and
      'state.playerModel != model' in sync and '!sameItem' in sync and '!state.playerCanCache' in target,
      '未知作品或非恒等变换不接管，model 与 itemID 一并校验')
prepare = method('+ (void)preparePlayer:')
setter = method('+ (CGRect)frameForPlayer:')
check('CGRect current = player.frame;' in prepare and 'nativePlayerFrameForLayout:current' in prepare and
      'canRestore' in prepare and 'awaitingNativeFrame' in prepare and 'native:state.nativeFrame' not in prepare,
      '布局以实际 frame 为准，旧作品结果必须等待当前作品原生 setter')
check('state.lastAppliedFrame = target;' in setter and 'state.adjusted = !CGRectEqualToRect(target, frame);' in setter and
      setter.index('synchronizePlayer:player state:state') < setter.index('state.nativeFrame = frame'),
      '唯一 setter 同步身份并记录本模块目标，恢复仍需精确匹配当前实际值')
check('adjusted && CGRectEqualToRect(current, lastApplied) && [self isUsablePlayerFrame:native] ? native : current' in geometry and
      'isfinite(frame.origin.x)' in geometry,
      '恢复必须精确匹配自身结果且保存几何有效')
check('awaiting || adjusted' in geometry and 'return awaiting ||' not in geometry and
      'normalFrameForPlayer:player state:state' in prepare and 'isUsablePlayerFrame:savedNative' in prepare,
      '失效后等待可信原生输入或实际几何更新，转换无效不回退旧局部坐标')
check('normalFrameForPlayer:player state:state' in prepare and '@finally' in prepare and 'state.applying = NO;' in prepare,
      '关闭评论恢复同页基准，异常路径也解除重入闸')
check('CGRect target = parent.bounds;' in method('+ (void)layoutPlayerContainer:'),
      '全屏外部承载区仍铺满，未删除背景和底栏能力')
check('DYYYFullscreenGeometry.m' in make and xm.count('%hook TTPlayerView') == 1 and
      xm.count('- (void)setFrame:(CGRect)frame {\n    %orig([DYYYFullscreenCoordinator frameForPlayer:self proposed:frame]);') == 1,
      '替换现有唯一 TTPlayerView frame 入口，无叠加 Hook')
finish = method('+ (void)finishPlayer:')
check(all('!state.playerCanCache' in body for body in (setter, prepare, finish)) and
      all('synchronizePlayer:player state:state' in body for body in (setter, prepare, finish)) and
      setter.index('state.awaitingNativeFrame = NO') < setter.index('state.nativeFrame = frame'),
      'setter、prepare、finish 都先同步并拒绝不可信缓存')
check('state.playerSuperviewBounds' in sync and 'state.playerCellSize' in sync and
      'canRestore = [DYYYFullscreenGeometry isUsablePlayerFrame:savedNative]' in prepare,
      '同 window 内父区或 cell 改尺寸也使旧恢复失效')
check('%hook TTMetalView' not in xm and 'gDYYYInRotation' not in xm,
      '删除两个空转 Metal 位置钩子和无人读取的旋转闸，不加渲染层位移')
feed = re.search(r'^%hook AWEFeedTableViewController\s*$(.*?)^%end\s*$', xm, re.M | re.S)
check(feed is not None and len(re.findall(r'^%hook AWEFeedTableViewController\s*$', xm, re.M)) == 1,
      '首页控制器维持唯一 Hook 入口')
check(not re.search(r'^%hook AWEFeedTableView\s*$', xm, re.M) and
      'DYYYStretchPagerTableToSuperview' not in xm,
      '删除首页分页表布局后置写高与关闭时重复扣底栏的整段旧实现')
feed_inset = re.search(r'- \(double\)tableViewBottomInsetForAllPlatform\s*\{(.*?)\n\}', feed.group(1), re.S)
check(feed_inset is not None and
      re.fullmatch(r'\s*if \(DYYYGetBoolCached\(@"DYYYEnableFullScreen"\)\) return 0\.0;\s*return %orig;\s*',
                   feed_inset.group(1)) is not None,
      '首页全屏底部预留归零，关闭后返回原生预留')
check(all(selector not in feed.group(1) for selector in (
      'heightForRowAtIndexPath:', 'smartSlidePageSnapCellHeightForIndex:',
      'applyTableViewLayoutForAllPlatform {', 'scrollViewDidScroll:',
      'scrollViewWillEndDragging:', 'setContentOffset:', 'setFrame:')),
      '首页表尺寸、行高、滚动偏移与分页吸附统一使用原生布局')
comment_hook = re.search(r'^%hook AWECommentContainerViewController\s*$(.*?)^%end\s*$', xm, re.M | re.S)
check(comment_hook is not None and comment_hook.group(1).count('commentController:self visible:YES') == 2 and
      comment_hook.group(1).count('commentController:self visible:NO') == 1 and
      comment_hook.group(1).index('if (skipsPanelLifecycle)') < comment_hook.group(1).index('commentController:self visible:NO'),
      '复用真实评论生命周期，媒体预览不会被当成正式退场')
registration = method('+ (void)commentController:')
panel = method('+ (CGRect)partialPanelForInner:')
match = method('+ (CGRect)panelInWindow:')
check('CommentContainerInnerViewController' in method('+ (CGRect)resolvePanelForComment:') and
      'parent != outer' in panel and 'view.window != window' in panel and
      'visibleRect:view.bounds' in panel and 'ownsMedia:media' in match and
      'removeObjectForKey:outer' in registration and 'pendingComments' not in coordinator,
      '以同窗真实半屏及当前作品为准，不以整个评论容器或定时状态替代')
check('hasCommentForInteractionController:self' in xm and
      'outer.interactionViewController != controller' in method('+ (BOOL)hasCommentForInteractionController:') and
      'isPlayVC && frame.origin.x' not in xm,
      '磨砂只冻结本互动控制器的评论，移除全局吞帧路径')
check(all(field not in coordinator for field in ('hasClosedImageTransform', 'imageAdjusted')),
      '图文状态已从播放器状态完全迁出，旧字段不可保留')
image = method('+ (CGAffineTransform)targetForImageView:')
image_layout = method('+ (void)layoutImageView:')
check(image.index('DYYYEnableFullScreen') < image.index('DYYYEnableCommentBlur') and
      image.index('CGRectIsNull(panel)') < image.index('DYYYEnableCommentBlur') and
      'CGAffineTransformEqualToTransform(current, state.lastAppliedTransform)' in image_layout and
      'state.awaitingNativeTransform' in image_layout,
      '图文非评论状态透传原生变换，复用时不沿用旧图缩放')
bar = method('+ (void)layoutBottomBar:')
check('DYYYRepairTabBarInternalBackground' not in xm and 'restoreBackdrop:' in bar and
      'ownsHidden' in method('+ (void)restoreBackdrop:') and
      'separatorLine' in method('+ (NSArray<UIView *> *)bottomBackgroundViews:'),
      '底栏仅用一个可恢复的背景入口，不改按钮和底栏占位')
check('![DYYYFullscreenCoordinator isInsideNearbyPage:self] &&' in xm and
      'if (occupied <= 0.5) occupied = 60.0;' not in xm and 'BOOL useFullHeight' not in xm,
      '同城不再进入布局后改高分支，不猜固定底栏占位')
detail_list = re.search(r'^%hook AWEDetailFeedListContainer\s*$(.*?)^%end\s*$', xm, re.M | re.S)
check(detail_list is not None and not any(s in detail_list.group(1) for s in
      ('contentOffsetYForCellAtIndex:', 'indexForContentOffsetY:')),
      '移除 41.2 详情列表中不存在的两个旧分页选择器')
detail_gate = ('if ([DYYYFullscreenCoordinator usesRecommendedLayoutForController:self]) {\n'
               '        [DYYYFullscreenCoordinator layoutInteraction:self];')
check(xm.count(detail_gate) == 1 and
      xm.count('[DYYYFullscreenCoordinator layoutInteraction:self];') == 1 and
      'CGFloat occupied = [DYYYFullscreenCoordinator bottomOccupiedHeightForView:self.view];' in xm and
      'occupied = 49.0 + safeBottom;' in xm and
      'if (![DYYYFullscreenCoordinator isImageContentController:self]) return;' in xm,
      '非推荐详情保留逻辑底栏占位，避免 offscreen tabbar 令交互层下移60pt')
runner = (ROOT / 'Tests/Media/run_media_tests.sh').read_text()
detail_table = re.search(r'^%hook AWEAwemeDetailTableView\s*$(.*?)^%end\s*$', xm, re.M | re.S)
check(detail_table is not None and len(re.findall(r'^%hook AWEAwemeDetailTableView\s*$', xm, re.M)) == 1 and
      detail_table.group(1).count('- (void)setContentInset:(UIEdgeInsets)contentInset') == 1 and
      'contentInset.bottom = 0;' in detail_table.group(1) and
      detail_table.group(1).index('DYYYEnableFullScreen') < detail_table.group(1).index('%orig(contentInset);') and
      detail_table.group(1).count('- (void)setFrame:(CGRect)frame') == 1 and
      detail_table.group(1).count('- (void)layoutSubviews') == 1,
      '详情表唯一 setter 在全屏清掉残留 bottom inset，关闭时原样传递')
comment_bar = re.search(r'^%hook AWECommentInputBackgroundView\s*$(.*?)^%end\s*$', xm, re.M | re.S)
hide_helper = re.search(r'static void DYYYSetCommentInputSubviewsHidden\(.*?\n\}', xm, re.S)
comment_backdrop_match = re.search(r'static BOOL DYYYCommentInputMatchesDarkReserve\(.*?\n\}', xm, re.S)
check(comment_bar is not None and len(re.findall(r'^%hook AWECommentInputBackgroundView\s*$', xm, re.M)) == 1 and
      comment_bar.group(1).count('- (void)layoutSubviews') == 1 and
      'removeFromSuperview' not in comment_bar.group(1) and
      'DYYYSetCommentInputSubviewsHidden(self, DYYYGetBool(@"DYYYHideComment"));' in comment_bar.group(1) and
      'self.transform = newTransform;' in comment_bar.group(1) and
      hide_helper is not None and 'OBJC_ASSOCIATION_RETAIN_NONATOMIC' in hide_helper.group(0) and
      'NSMutableOrderedSet<UIView *> *targets' in hide_helper.group(0) and
      'for (UIView *sibling in bar.superview.subviews)' in hide_helper.group(0) and
      'DYYYCommentInputMatchesDarkReserve(sibling, bar, NO)' in hide_helper.group(0) and
      comment_backdrop_match is not None and 'candidate.superview != bar.superview' in comment_backdrop_match.group(0) and
      'fabs(candidateFrame.origin.y - barFrame.origin.y) > 0.5' in comment_backdrop_match.group(0) and
      'white < 0.25' in comment_backdrop_match.group(0) and
      'subview.hidden = [state[@"hidden"] boolValue];' in hide_helper.group(0),
      '隐藏底栏评论还接管41.3同尺寸深色兄弟背景并可恢复')
view_hook = re.search(r'^%hook UIView\s*$(.*?)^%end\s*$', xm, re.M | re.S)
reserve_sibling = re.search(r'static BOOL DYYYIsCommentInputDarkReserveSibling\(.*?\n\}', xm, re.S)
check(view_hook is not None and len(re.findall(r'^%hook UIView\s*$', xm, re.M)) == 1 and
      view_hook.group(1).count('- (void)setHidden:(BOOL)hidden') == 1 and
      'if (!hidden && DYYYIsCommentInputDarkReserveSibling(self)) {' in view_hook.group(1) and
      view_hook.group(1).index('DYYYIsCommentInputDarkReserveSibling(self)') < view_hook.group(1).index('DYYYViewHideGate()') and
      '%orig(YES);' in view_hook.group(1) and
      reserve_sibling is not None and 'DYYYGetBoolCached(@"DYYYHideComment")' in reserve_sibling.group(0) and
      'DYYYCommentInputMatchesDarkReserve(candidate, sibling, YES)' in reserve_sibling.group(0) and
      'allowPreUnhideState' in comment_backdrop_match.group(0),
      '翻页后只阻止隐藏评论时 41.3 深色兄弟背景重新显示')
check('DYYYFullscreenGeometryTests.m' in runner and 'DYYYFullscreenGeometry.m' in runner and
      'check_fullscreen_frame_stability.py' in runner,
      '集成结构与原生 geometry 断言都加入现有 CI runner')
print('Fullscreen frame structural checks passed; native and device tests remain separate.')
