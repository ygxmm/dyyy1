from pathlib import Path

p = Path("DYYY.xm")
s = p.read_text()

start = s.find("- (void)layoutSubviews {\n    %orig;\n\n    static char kDYYYTTMetalViewVPOriginalTransformKey;")
if start < 0:
    raise SystemExit("ERROR: 找不到目标代码，未修改文件")

end = s.find("\n}\n\n%end", start)
if end < 0:
    raise SystemExit("ERROR: 找不到目标方法结束位置，未修改文件")

old = s[start:end + 2]
new = """- (void)layoutSubviews {
    %orig;
    // 暂停 DYYY 自定义纵向 transform，交由抖音原生布局处理。
}"""

s = s[:start] + new + s[end + 2:]
p.write_text(s)
print("已停用 TTMetalViewVP 的自定义 transform；setCenter: 保持不变。")
