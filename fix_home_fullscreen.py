from pathlib import Path
import shutil
import time
import sys

p = Path("/var/mobile/dyyy/DYYY/DYYY.xm")

if not p.is_file():
    sys.exit("[错误] 找不到 DYYY.xm")

s = p.read_text(encoding="utf-8")

old = """    // DYYY修复：全屏开关打开时，强制走 if 分支，UI层撑满852
    // 详情页原生走 else 是 732，比推荐页少120pt，这里统一到 852
    // v92: UI 层保留底栏 60pt，进度条不再贴屏底
    frame.size.height = superviewHeight - 60.0;

    if (fabs(frame.size.height - self.view.frame.size.height) > 0.5) {
        self.view.frame = frame;
    }"""

new = """    // 首页播放交互层保留原生高度，避免覆盖首页 cell 的分页布局。
    // 非首页页面继续保留原有全屏高度逻辑。
    if (!DYYYIsHomePlayInteraction(self.view)) {
        frame.size.height = superviewHeight - 60.0;

        if (fabs(frame.size.height - self.view.frame.size.height) > 0.5) {
            self.view.frame = frame;
        }
    }"""

if s.count(old) != 1:
    print("[停止] 目标代码块匹配数：", s.count(old))
    print("文件没有修改。请先检查 DYYY.xm 中的实际代码。")
    sys.exit(1)

if "DYYYIsHomePlayInteraction(UIView *view)" not in s:
    sys.exit("[停止] 找不到首页判定函数声明或定义，文件没有修改。")

backup = p.with_name("DYYY.xm.backup." + time.strftime("%Y%m%d-%H%M%S"))
shutil.copy2(p, backup)

p.write_text(s.replace(old, new, 1), encoding="utf-8")

print("[成功] 已修改首页全屏高度逻辑")
print("[备份]", backup)
print("[检查] 修改后的代码：")
lines = p.read_text(encoding="utf-8").splitlines()
for i, line in enumerate(lines):
    if "DYYYIsHomePlayInteraction(self.view)" in line:
        start = max(0, i - 4)
        end = min(len(lines), i + 10)
        print("\n".join(f"{n+1}: {lines[n]}" for n in range(start, end)))
        break
