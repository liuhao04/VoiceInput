#!/bin/bash
# iTerm2 面板定位自动化测试

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_RESULTS_DIR="/tmp/voiceinput_iterm2_test"
SCREENSHOT_DIR="$TEST_RESULTS_DIR/screenshots"

mkdir -p "$SCREENSHOT_DIR"

echo "=== iTerm2 面板定位自动化测试 ==="
echo ""

# 检查 VoiceInput 是否运行
if ! pgrep -x "VoiceInput" > /dev/null; then
    echo "❌ VoiceInput 未运行，请先启动应用"
    exit 1
fi

echo "✅ VoiceInput 正在运行"
echo ""

# 激活 iTerm2
osascript <<'EOF'
tell application "iTerm2"
    activate
end tell
delay 0.5
EOF

echo "✅ 已激活 iTerm2"
echo ""

# 获取 iTerm2 窗口信息
WINDOW_INFO=$(osascript <<'EOF'
tell application "iTerm2"
    tell current window
        set windowBounds to bounds
        set {x1, y1, x2, y2} to windowBounds
        return {x1, y1, x2, y2}
    end tell
end tell
EOF
)

echo "📊 iTerm2 窗口信息: $WINDOW_INFO"
echo ""

# 截图1: 测试前状态
screencapture -x "$SCREENSHOT_DIR/01_before_test.png"
echo "📸 截图1: 测试前状态"

# 触发语音输入 (模拟 F5)
osascript <<'EOF'
tell application "System Events"
    key code 96  -- F5
end tell
delay 0.5
EOF

echo "✅ 已触发语音输入 (F5)"
echo ""

# 等待面板出现
sleep 1.5

# 截图2: 面板显示后
screencapture -x "$SCREENSHOT_DIR/02_panel_appeared.png"
echo "📸 截图2: 面板显示后"

# 获取面板位置（通过日志）
PANEL_LOG=$(tail -50 ~/Library/Logs/VoiceInput.log | grep "\[Panel.show\]" | tail -3)
echo ""
echo "📋 面板日志:"
echo "$PANEL_LOG"
echo ""

# 停止录音
osascript <<'EOF'
tell application "System Events"
    key code 96  -- F5
end tell
delay 0.5
EOF

echo "✅ 已停止录音"
echo ""

# 截图3: 测试后状态
screencapture -x "$SCREENSHOT_DIR/03_after_test.png"
echo "📸 截图3: 测试后状态"

# 使用 Python 分析截图，检测面板位置
python3 - <<'PYTHON_SCRIPT'
import sys
import json
from AppKit import NSScreen, NSRect, NSPoint
import Quartz

# 获取主屏幕信息
main_screen = NSScreen.mainScreen()
screen_frame = main_screen.frame()

print("\n📊 屏幕信息:")
print(f"  宽度: {screen_frame.size.width}")
print(f"  高度: {screen_frame.size.height}")
print(f"  原点: ({screen_frame.origin.x}, {screen_frame.origin.y})")

# 读取日志获取面板位置
import subprocess
import os
log_output = subprocess.check_output(['tail', '-50', os.path.expanduser('~/Library/Logs/VoiceInput.log')], encoding='utf-8')

import re
panel_origin = None
cursor_pos = None

for line in log_output.split('\n'):
    if '[Panel.show]' in line and 'origin=' in line:
        match = re.search(r'origin=\(([^,]+),\s*([^)]+)\)', line)
        if match:
            panel_origin = (float(match.group(1)), float(match.group(2)))
    if '[CursorLocator]' in line and '获取光标:' in line:
        match = re.search(r'\(([^,]+),\s*([^)]+)\)', line)
        if match:
            cursor_pos = (float(match.group(1)), float(match.group(2)))

print("\n📍 定位信息:")
if cursor_pos:
    print(f"  光标位置: ({cursor_pos[0]:.1f}, {cursor_pos[1]:.1f})")
else:
    print("  光标位置: 未检测到")

if panel_origin:
    print(f"  面板位置: ({panel_origin[0]:.1f}, {panel_origin[1]:.1f})")
else:
    print("  面板位置: 未检测到")

# 分析是否合理
if cursor_pos and panel_origin:
    # macOS 坐标系：原点在左下角
    # 面板应该在光标下方
    distance = ((cursor_pos[0] - panel_origin[0])**2 + (cursor_pos[1] - panel_origin[1])**2)**0.5
    print(f"\n📏 光标与面板距离: {distance:.1f} 像素")

    if panel_origin[1] < cursor_pos[1]:
        print("✅ 面板在光标下方（正确）")
    else:
        print("❌ 面板在光标上方（错误）")

    # 检查是否在屏幕范围内
    if (0 <= panel_origin[0] <= screen_frame.size.width and
        0 <= panel_origin[1] <= screen_frame.size.height):
        print("✅ 面板在屏幕范围内")
    else:
        print("❌ 面板超出屏幕范围")

    # 检查水平居中
    panel_center_x = panel_origin[0] + 140  # maxWidth/2 + padding
    h_distance = abs(panel_center_x - cursor_pos[0])
    if h_distance < 20:
        print(f"✅ 面板水平居中（偏移 {h_distance:.1f} 像素）")
    else:
        print(f"⚠️  面板未水平居中（偏移 {h_distance:.1f} 像素）")

PYTHON_SCRIPT

echo ""
echo "📂 测试结果保存在: $TEST_RESULTS_DIR"
echo ""

# 打开截图目录
open "$SCREENSHOT_DIR"

echo "✅ 测试完成"
