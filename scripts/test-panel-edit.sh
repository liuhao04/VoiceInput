#!/usr/bin/env bash
set -e

echo "=== VoiceInput 面板编辑功能测试 ==="
echo ""

# 1. 检查应用是否运行
if ! pgrep -x "VoiceInput" > /dev/null; then
    echo "❌ VoiceInput 未运行，请先启动应用"
    exit 1
fi
echo "✅ VoiceInput 正在运行"

# 2. 打开 TextEdit 并准备新文档
echo ""
echo "准备 TextEdit..."
osascript << 'APPLESCRIPT'
tell application "TextEdit"
    activate
    make new document
end tell
delay 0.5
tell application "System Events"
    tell process "TextEdit"
        keystroke "n" using command down
    end tell
end tell
APPLESCRIPT
sleep 1
echo "✅ TextEdit 已准备"

# 3. 模拟开始录音（点击菜单栏第一项）
echo ""
echo "启动录音..."
osascript << 'APPLESCRIPT'
tell application "System Events"
    tell application process "VoiceInput"
        tell (menu bar item 1 of menu bar 1)
            click
            delay 0.3
            click menu item 1 of menu 1
        end tell
    end tell
end tell
APPLESCRIPT
echo "🎤 录音已启动"

# 4. 等待识别结果
echo ""
echo "等待识别结果 (5秒)..."
for i in {5..1}; do
    echo -n "$i... "
    sleep 1
done
echo ""

# 5. 停止录音（点击菜单栏第一项）
echo ""
echo "停止录音..."
osascript << 'APPLESCRIPT'
tell application "System Events"
    tell application process "VoiceInput"
        tell (menu bar item 1 of menu bar 1)
            click
            delay 0.3
            click menu item 1 of menu 1
        end tell
    end tell
end tell
APPLESCRIPT
echo "✅ 录音已停止，面板应保持显示"

# 6. 等待面板显示并稳定
sleep 1.5

# 7. 查找并点击面板
echo ""
echo "查找并点击面板..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICK_RESULT=$(python3 "$SCRIPT_DIR/click-panel.py" 2>&1)

if [ $? -eq 0 ]; then
    echo "✅ 已点击面板"
else
    echo "❌ 点击面板失败"
    echo "$CLICK_RESULT"
    exit 1
fi

# 8. 等待面板进入编辑状态
sleep 0.5

# 9. 检查面板是否可编辑（通过读取窗口属性）
echo ""
echo "检查编辑状态..."
EDITABLE=$(osascript << 'APPLESCRIPT'
tell application "System Events"
    tell application process "VoiceInput"
        try
            set panelWindow to window 1
            set isKey to frontmost of panelWindow
            return isKey
        on error
            return false
        end try
    end tell
end tell
APPLESCRIPT
)

if [ "$EDITABLE" = "true" ]; then
    echo "✅ 面板已激活 (可能进入编辑状态)"
else
    echo "⚠️  面板未激活 (可能未进入编辑状态)"
fi

# 10. 修改文字（清空并输入新文字）
echo ""
echo "修改面板文字..."
osascript << 'APPLESCRIPT'
tell application "System Events"
    keystroke "a" using command down
    delay 0.2
    keystroke "测试编辑功能"
end tell
APPLESCRIPT
echo "✅ 已输入新文字: 测试编辑功能"

# 11. 按回车确认
echo ""
echo "按回车确认..."
sleep 0.3
osascript << 'APPLESCRIPT'
tell application "System Events"
    key code 36  -- Return key
end tell
APPLESCRIPT
sleep 1
echo "✅ 已按回车"

# 12. 切换到 TextEdit 并读取内容
echo ""
echo "读取 TextEdit 内容..."
sleep 0.5
RESULT=$(osascript << 'APPLESCRIPT'
tell application "TextEdit" to activate
delay 0.3
tell application "System Events"
    tell process "TextEdit"
        try
            set textContent to value of text area 1 of scroll area 1 of window 1
            return textContent
        on error errMsg
            return "读取失败: " & errMsg
        end try
    end tell
end tell
APPLESCRIPT
)

# 13. 验证结果
echo ""
echo "========== 测试结果 =========="
if [[ "$RESULT" == *"测试编辑功能"* ]]; then
    echo "✅ 测试通过！"
    echo "   期望: 测试编辑功能"
    echo "   实际: $RESULT"
    EXIT_CODE=0
else
    echo "❌ 测试失败！"
    echo "   期望: 测试编辑功能"
    echo "   实际: $RESULT"
    echo ""
    echo "查看日志:"
    tail -30 "$HOME/Library/Logs/VoiceInput.log" | grep -E "\[Panel\]" || true
    EXIT_CODE=1
fi

# 14. 清理
echo ""
echo "清理测试环境..."
osascript << 'APPLESCRIPT' > /dev/null 2>&1
tell application "TextEdit"
    close every document saving no
end tell
APPLESCRIPT
echo "✅ 已清理"
echo ""

exit $EXIT_CODE
