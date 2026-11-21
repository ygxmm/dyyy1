#!/usr/bin/env python3
"""Static regression checks for Story/small-daily layout isolation."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]

def check(ok, reason):
    print(('PASS' if ok else 'FAIL') + ' Story layout: ' + reason)
    if not ok:
        raise SystemExit(1)

make = (ROOT / 'Makefile').read_text()
source_files = re.search(r'DYYY_FILES\s*=\s*(.*?)\nDYYY_CFLAGS', make, re.S)
check(source_files is not None, 'Makefile 源码清单可解析')
compiled = source_files.group(1).replace('\\', '').split()
hooks = []
for name in compiled:
    if not name.endswith(('.xm', '.x')):
        continue
    path = ROOT / name
    if not path.is_file():
        continue
    text = path.read_text()
    for match in re.finditer(r'(?ms)^%hook\s+AWEStoryContainerCollectionView\b(.*?)^%end\b', text):
        hooks.append((name, match.group(1)))
check(len(hooks) == 1, '实际编译源码中只有一个 Story 容器 Hook')
name, body = hooks[0]
check(len(re.findall(r'^\s*-\s*\(void\)layoutSubviews\s*\{', body, re.M)) == 1,
      'Story 容器 layoutSubviews 只有一个入口')
check(body.count('%orig;') == 1 and body.index('%orig;') < body.index('self.subviews.count'),
      '%orig 只调用一次并先保留原生布局')
check(re.search(r'UIResponder\s*\*responder\s*=\s*self\.nextResponder\s*;', body) is not None
      and re.search(r'UIResponder\s*\*responder\s*=\s*self\s*;', body) is None,
      '上下文从父级开始，避免类名自匹配')
check('containsString:@"Story"' in body and 'containsString:@"Moment"' in body,
      '小日常标记只检查父级响应链')
check(re.search(r'while\s*\(responder\s*&&\s*guard\+\+\s*<\s*50\)', body) is not None
      and re.search(r'if\s*\(responder\)\s*return\s*;', body) is not None,
      '响应链有界且超限时安全退出')
check('@try' in body and '@catch' in body and 'valueForKey:@"enableEnterProfile"' in body,
      'enableEnterProfile KVC 异常受保护')
check('if (!isHome && !isAuthorProfile) return;' in body,
      '仅首页或作者主页进入自定义布局')
check('kDYYYWorkImageAppliedYKey' in body and 'fabs(currentY - appliedYNum.doubleValue) < 0.5' in body,
      '保留作者作品偏移的重复布局保护')
print('Story layout structural checks passed; runtime/device behavior is separate.')
