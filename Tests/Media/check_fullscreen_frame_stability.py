#!/usr/bin/env python3
"""横屏 feed 几何稳定性结构回归；不替代 macOS 原生断言。"""
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
full_page = re.search(r'BOOL nativeFillsPage = .*?if \(media\.width > media\.height\)', coordinator, re.S)
check(full_page is not None, '全宽 feed 视频有独立稳定 frame 分支')
body = full_page.group(0) if full_page else ''
check('recommended && nativeFillsPage && player.superview' in body and
      'stableFullscreenPlayerFrame:native inSuperviewBounds:player.superview.bounds' in body,
      '全屏容器宽度匹配页面时统一锚到宿主 bounds')
check('guide.size.height' not in body and '[self interactions]' not in body,
      '可见全屏分支不再读取会在 852/792 间抖动的交互层高度')
check('return bounds;' in geometry and 'CGRectIsEmpty(bounds)' in geometry and 'CGRectIsInfinite(bounds)' in geometry,
      '有效宿主 bounds 稳定输出，无效 bounds 安全回退')
check('DYYYFullscreenGeometry.m' in make and xm.count('%hook TTPlayerView') == 1 and
      xm.count('- (void)setFrame:(CGRect)frame {\n    %orig([DYYYFullscreenCoordinator frameForPlayer:self proposed:frame]);') == 1,
      '替换现有唯一 TTPlayerView frame 入口，无叠加 Hook')
runner = (ROOT / 'Tests/Media/run_media_tests.sh').read_text()
check('DYYYFullscreenGeometryTests.m' in runner and 'DYYYFullscreenGeometry.m' in runner and
      'check_fullscreen_frame_stability.py' in runner,
      '集成结构与原生 geometry 断言都加入现有 CI runner')
print('Fullscreen frame structural checks passed; native and device tests remain separate.')
