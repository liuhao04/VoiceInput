#!/usr/bin/env python3
"""分析面板位置是否正确"""

import sys
import re
import subprocess

# 读取日志
import os
log_output = subprocess.check_output(['tail', '-100', os.path.expanduser('~/Library/Logs/VoiceInput.log')], encoding='utf-8')

panel_origin = None
cursor_pos = None
panel_size = (300, 140)  # 默认面板大小

for line in log_output.split('\n'):
    if '[Panel.show]' in line and 'origin=' in line:
        match = re.search(r'origin=\(([^,]+),\s*([^)]+)\)', line)
        if match:
            panel_origin = (float(match.group(1)), float(match.group(2)))
        match_size = re.search(r'size=\(([^,]+),\s*([^)]+)\)', line)
        if match_size:
            panel_size = (float(match_size.group(1)), float(match_size.group(2)))
    if '[Panel.show]' in line and '输入点:' in line:
        match = re.search(r'\(([^,]+),\s*([^)]+)\)', line)
        if match:
            cursor_pos = (float(match.group(1)), float(match.group(2)))

print("\n" + "="*60)
print("📊 iTerm2 面板定位分析")
print("="*60)

if cursor_pos:
    print(f"\n✅ 光标位置 (输入点): ({cursor_pos[0]:.1f}, {cursor_pos[1]:.1f})")
else:
    print("\n❌ 未检测到光标位置")
    sys.exit(1)

if panel_origin:
    print(f"✅ 面板位置: origin=({panel_origin[0]:.1f}, {panel_origin[1]:.1f}), size=({panel_size[0]:.1f}, {panel_size[1]:.1f})")
else:
    print("❌ 未检测到面板位置")
    sys.exit(1)

print("\n" + "-"*60)
print("🔍 问题诊断:")
print("-"*60)

issues = []

# 检查1: X 坐标是否为负
if panel_origin[0] < 0:
    issues.append(f"❌ 面板 X 坐标为负数 ({panel_origin[0]:.1f})，超出屏幕左侧")
    print(f"❌ 面板 X 坐标为负数 ({panel_origin[0]:.1f})，超出屏幕左侧")
else:
    print(f"✅ 面板 X 坐标正常 ({panel_origin[0]:.1f})")

# 检查2: Y 坐标关系
if panel_origin[1] < cursor_pos[1]:
    print(f"✅ 面板在光标下方 (面板Y={panel_origin[1]:.1f}, 光标Y={cursor_pos[1]:.1f})")
else:
    issues.append(f"❌ 面板不在光标下方")
    print(f"❌ 面板不在光标下方 (面板Y={panel_origin[1]:.1f}, 光标Y={cursor_pos[1]:.1f})")

# 检查3: 水平居中
panel_center_x = panel_origin[0] + panel_size[0] / 2
h_offset = panel_center_x - cursor_pos[0]
print(f"\n📏 水平对齐:")
print(f"   光标 X: {cursor_pos[0]:.1f}")
print(f"   面板中心 X: {panel_center_x:.1f}")
print(f"   偏移: {h_offset:.1f} 像素")

if abs(h_offset) < 5:
    print(f"✅ 水平居中良好 (偏移 {abs(h_offset):.1f} 像素)")
else:
    issues.append(f"⚠️  水平未居中 (偏移 {abs(h_offset):.1f} 像素)")
    print(f"⚠️  水平未居中 (偏移 {abs(h_offset):.1f} 像素)")

# 检查4: 垂直距离
v_distance = cursor_pos[1] - (panel_origin[1] + panel_size[1])
print(f"\n📏 垂直间距: {v_distance:.1f} 像素")
if 5 < v_distance < 20:
    print(f"✅ 垂直间距合理")
else:
    print(f"⚠️  垂直间距可能不合理")

print("\n" + "="*60)
if issues:
    print(f"❌ 发现 {len(issues)} 个问题:")
    for issue in issues:
        print(f"   {issue}")
    print("\n💡 建议:")
    if any("X 坐标为负" in i for i in issues):
        print("   - CursorLocator 获取的光标 X 坐标太小 (5.0)，可能是坐标系问题")
        print("   - 需要检查 iTerm2 的坐标获取逻辑")
        print("   - 或者在面板显示时增加边界检查，确保不超出屏幕")
else:
    print("✅ 未发现明显问题")

print("="*60 + "\n")

sys.exit(0 if not issues else 1)
