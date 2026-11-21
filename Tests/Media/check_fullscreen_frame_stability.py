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
runner = (ROOT / 'Tests/Media/run_media_tests.sh').read_text()
check('DYYYFullscreenGeometryTests.m' in runner and 'DYYYFullscreenGeometry.m' in runner and
      'check_fullscreen_frame_stability.py' in runner,
      '集成结构与原生 geometry 断言都加入现有 CI runner')
print('Fullscreen frame structural checks passed; native and device tests remain separate.')
