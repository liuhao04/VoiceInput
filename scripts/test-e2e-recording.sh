#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== VoiceInput 端到端录音测试 ==="
echo ""

# 1. 检查应用是否运行
if ! pgrep -x "VoiceInput" > /dev/null; then
    echo "❌ VoiceInput 未运行，请先启动应用"
    exit 1
fi
echo "✅ VoiceInput 正在运行"

# 2. 检查权限
echo ""
echo "检查权限..."
MIC_STATUS=$(sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
    "SELECT auth_value FROM access WHERE service='kTCCServiceMicrophone' AND client='com.voiceinput.mac';" 2>/dev/null || echo "0")
if [[ "$MIC_STATUS" != "2" ]]; then
    echo "❌ 麦克风权限未授予（状态: $MIC_STATUS），请在系统设置中授予权限"
    exit 1
fi
echo "✅ 麦克风权限已授予"

# 3. 打开 TextEdit 并清空内容
echo ""
echo "准备 TextEdit..."
osascript -e 'tell application "TextEdit" to activate' \
    -e 'delay 0.5' \
    -e 'tell application "System Events" to tell process "TextEdit"' \
    -e 'keystroke "n" using command down' \
    -e 'end tell' 2>/dev/null || true
sleep 1
echo "✅ TextEdit 已准备"

# 4. 创建 AppleScript 脚本
cat > /tmp/test_start_recording.scpt << 'APPLESCRIPT'
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

cat > /tmp/test_stop_recording.scpt << 'APPLESCRIPT'
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

# 5. 开始录音
echo ""
echo "开始录音..."
osascript /tmp/test_start_recording.scpt > /dev/null 2>&1
echo "🎤 录音中... 请对着麦克风说：测试一下"
echo ""

# 6. 等待 5 秒
for i in {5..1}; do
    echo -n "$i... "
    sleep 1
done
echo ""

# 7. 停止录音
echo ""
echo "停止录音..."
osascript /tmp/test_stop_recording.scpt > /dev/null 2>&1
sleep 1.5  # 等待粘贴完成
echo "✅ 录音已停止"

# 8. 读取 TextEdit 内容
echo ""
echo "读取识别结果..."
RESULT=$(osascript -e 'tell application "System Events" to tell process "TextEdit" to get value of text area 1 of scroll area 1 of window 1' 2>/dev/null || echo "")

# 9. 验证结果
echo ""
EXIT_CODE=0
if [[ "$RESULT" == "测试一下" ]]; then
    echo "✅ 测试通过！"
    echo "   识别结果: $RESULT"
else
    echo "❌ 测试失败！"
    echo "   期望结果: 测试一下"
    echo "   实际结果: $RESULT"
    echo ""
    echo "查看日志:"
    tail -20 "$HOME/Library/Logs/VoiceInput.log" | grep -E "\[ASR\]|\[Paste\]" || true
    EXIT_CODE=1
fi

# 10. 清理：关闭测试创建的 TextEdit 文档
echo ""
echo "清理临时文档..."
osascript << 'APPLESCRIPT' > /dev/null 2>&1
tell application "TextEdit"
    if it is running then
        try
            close every document saving no
        end try
    end if
end tell
APPLESCRIPT
echo "✅ 已清理"
echo ""

exit $EXIT_CODE
