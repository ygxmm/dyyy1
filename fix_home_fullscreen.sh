#!/bin/sh
set -eu

FILE="/var/mobile/dyyy/DYYY/DYYY.xm"
BACKUP="/var/mobile/dyyy/DYYY/DYYY.xm.before_homefix"

if [ ! -f "$FILE" ]; then
    echo "找不到源码文件"
    exit 1
fi

if [ ! -f "$BACKUP" ]; then
    cp -p "$FILE" "$BACKUP"
fi

python3 - "$FILE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

story_old = '''                CGRect frame = subview.frame;
                if (DYYYGetBool(@"DYYYEnableFullScreen")) {
                    frame.size.height = subview.superview.frame.size.height - gCurrentTabBarHeight;
                    subview.frame = frame;
                }'''

table_old = '''    // v250: 只对当前可见 cell 里的 player VC 拉高。
    // 只拉 table frame 时，cell 里 player VC 还是原生高度 → 视频挤顶部。
    // 只处理 visibleCells（1~2 个），不触发非可见 cell 的播放器重排。
    // v253: 只处理屏幕中央那个 cell（真正在播放的），
    // 预加载 cell（屏幕外）不处理 —— 避免跟抖音每帧打架累积错位。
    CGFloat centerY = self.contentOffset.y + self.bounds.size.height * 0.5;
    CGFloat halfH = self.bounds.size.height * 0.5;
    for (UITableViewCell *cell in [self visibleCells]) {
        CGFloat cellCenterY = cell.frame.origin.y + cell.frame.size.height * 0.5;
        if (fabs(cellCenterY - centerY) < halfH * 0.8) {
            DYYYExpandPlayerInCell(cell, targetH);
        }
    }'''

story_new = '''                // 首页全屏：不重复修改播放交互视图高度。
                // 避免与原生分页布局发生冲突。'''

table_new = '''    // 首页全屏：暂不逐个拉高可见播放器控制器。
    // 避免滑动或返回前台时重复触发布局。'''

if s.count(story_old) != 1 or s.count(table_old) != 1:
    print("匹配失败，源码未修改。")
    print("Story 匹配数:", s.count(story_old))
    print("Table 匹配数:", s.count(table_old))
    sys.exit(2)

s = s.replace(story_old, story_new, 1)
s = s.replace(table_old, table_new, 1)
p.write_text(s)
print("修复完成")
PY
