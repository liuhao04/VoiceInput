#!/usr/bin/env bash
set -e

echo "=== Gemini 页面语音插入测试 ==="
echo ""

# 1. 检查应用是否运行
if ! pgrep -x "VoiceInput" > /dev/null; then
    echo "❌ VoiceInput 未运行，请先启动应用"
    exit 1
fi
echo "✅ VoiceInput 正在运行"

# 2. 检查浏览器选择
BROWSER="${1:-Safari}"
if [[ "$BROWSER" != "Safari" && "$BROWSER" != "Google Chrome" ]]; then
    echo "❌ 不支持的浏览器: $BROWSER"
    echo "用法: $0 [Safari|Google Chrome]"
    exit 1
fi
echo "使用浏览器: $BROWSER"

# 3. 打开浏览器并导航到 Gemini
echo ""
echo "打开 $BROWSER 并导航到 Gemini..."

if [[ "$BROWSER" == "Safari" ]]; then
    osascript << 'APPLESCRIPT'
tell application "Safari"
    activate
    delay 0.5

    -- 打开新标签页或窗口
    if (count of windows) is 0 then
        make new document
    end if

    -- 设置 URL
    set URL of current tab of front window to "https://gemini.google.com/app"
end tell
APPLESCRIPT
else
    osascript << 'APPLESCRIPT'
tell application "Google Chrome"
    activate
    delay 0.5

    -- 打开新标签页或窗口
    if (count of windows) is 0 then
        make new window
    end if

    -- 设置 URL
    set URL of active tab of front window to "https://gemini.google.com/app"
end tell
APPLESCRIPT
fi

echo "✅ 已打开 Gemini 页面"
echo ""
echo "等待页面加载 (10秒)..."
sleep 10

# 4. 按快捷键新起对话，定位光标到文本框
echo ""
if [[ "$BROWSER" == "Safari" ]]; then
    echo "按 Cmd+Shift+O 定位到输入框..."
    osascript << 'APPLESCRIPT'
tell application "System Events"
    keystroke "o" using {command down, shift down}
    delay 1
end tell
APPLESCRIPT
    echo "✅ 已按 Cmd+Shift+O"
else
    echo "按 Cmd+K 定位到输入框..."
    osascript << 'APPLESCRIPT'
tell application "System Events"
    keystroke "k" using command down
    delay 1
end tell
APPLESCRIPT
    echo "✅ 已按 Cmd+K"
fi

# 5. 等待焦点定位，然后清空输入框（防止有历史内容）
sleep 1
echo "清空输入框..."
osascript << 'APPLESCRIPT'
tell application "System Events"
    keystroke "a" using command down
    delay 0.1
    key code 51  -- Delete key
    delay 0.3
end tell
APPLESCRIPT

# 6. 触发 VoiceInput 测试模式
echo ""
echo "启动语音输入测试..."

# 先保存当前浏览器 PID，供测试使用
if [[ "$BROWSER" == "Safari" ]]; then
    BROWSER_BUNDLE="com.apple.Safari"
else
    BROWSER_BUNDLE="com.google.Chrome"
fi

# 创建测试标记文件，告诉 VoiceInput 使用特定的目标应用
mkdir -p /tmp/voiceinput_test
echo "$BROWSER_BUNDLE" > /tmp/voiceinput_test/target_app.txt
echo "Gemini测试文字：你好世界" > /tmp/voiceinput_test/test_text.txt

# 7. 停止当前运行的 VoiceInput
echo ""
echo "重启 VoiceInput 进入测试模式..."
killall VoiceInput 2>/dev/null || true
sleep 0.5

# 8. 以测试模式启动
"$HOME/Applications/VoiceInput.app/Contents/MacOS/VoiceInput" --test-gemini > /dev/null 2>&1 &
TEST_PID=$!
echo "VoiceInput 测试进程: $TEST_PID"

# 9. 等待测试完成
echo ""
echo "等待测试完成 (10秒)..."
sleep 10

# 10. 检查结果
echo ""
echo "========== 测试结果 =========="

# 读取日志
echo ""
echo "最近的日志："
tail -50 ~/Library/Logs/VoiceInput.log | grep -E "\[TEST\]|\[Paste\]|将注入" | tail -20

# 11. 尝试读取浏览器中的内容
echo ""
echo "检查 $BROWSER 输入框内容..."
if [[ "$BROWSER" == "Safari" ]]; then
    osascript << 'APPLESCRIPT'
tell application "System Events"
    tell process "Safari"
        -- 全选文本框内容
        keystroke "a" using command down
        delay 0.2
        -- 复制
        keystroke "c" using command down
        delay 0.2
    end tell
end tell
APPLESCRIPT
else
    osascript << 'APPLESCRIPT'
tell application "System Events"
    tell process "Google Chrome"
        -- 全选文本框内容
        keystroke "a" using command down
        delay 0.2
        -- 复制
        keystroke "c" using command down
        delay 0.2
    end tell
end tell
APPLESCRIPT
fi

sleep 0.5
CLIPBOARD=$(osascript -e 'the clipboard')
echo "剪贴板内容: $CLIPBOARD"

if [[ "$CLIPBOARD" == *"Gemini测试文字"* ]]; then
    echo "✅✅✅ 测试通过！文字成功插入到 Gemini 输入框"
    EXIT_CODE=0
else
    echo "❌ 测试失败：输入框中没有找到测试文字"
    echo "期望: Gemini测试文字：你好世界"
    echo "实际: $CLIPBOARD"
    EXIT_CODE=1
fi

# 12. 清理
echo ""
echo "清理测试环境..."
rm -rf /tmp/voiceinput_test
echo "✅ 已清理"
echo ""

exit $EXIT_CODE
