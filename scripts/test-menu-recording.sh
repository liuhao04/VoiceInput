#!/bin/bash
# 自动测试菜单点击启动录音功能

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/voiceinput_menu_test"
APP_PATH="$HOME/Applications/VoiceInput.app"

mkdir -p "$TEST_DIR"

echo "[Test] 1. 确保 app 正在运行..."
pkill -9 VoiceInput 2>/dev/null || true
sleep 0.5
open "$APP_PATH"
sleep 3

echo "[Test] 2. 截图初始状态（应该没有录音）..."
screencapture -x -R 0,0,1200,30 "$TEST_DIR/menubar_before.png"

# 清空日志相关行，以便后续检测
echo "[Test] 3. 记录当前日志行数..."
LOG_FILE=~/Library/Logs/VoiceInput.log
BEFORE_LINE_COUNT=$(wc -l < "$LOG_FILE")

echo "[Test] 4. 使用 AppleScript 点击菜单并启动录音..."
APPLESCRIPT_RESULT=$(osascript <<'EOF' 2>&1
try
    tell application "System Events"
        tell process "VoiceInput"
            set frontmost to true
            delay 0.3

            -- 尝试方法1：通过菜单栏项查找
            try
                set menuBarItems to menu bar items of menu bar 1
                repeat with menuBarItem in menuBarItems
                    try
                        click menuBarItem
                        delay 0.5
                        click menu item 1 of menu 1 of menuBarItem
                        delay 0.5
                        return "Success: Clicked menu item"
                    end try
                end repeat
            end try

            return "Failed: Could not find menu"
        end tell
    end tell
on error errMsg
    return "Error: " & errMsg
end try
EOF
)

echo "AppleScript 结果: $APPLESCRIPT_RESULT"

echo "[Test] 5. 等待录音启动..."
sleep 3

echo "[Test] 6. 截图检查菜单栏录音状态..."
screencapture -x -R 0,0,1200,30 "$TEST_DIR/menubar_recording.png"

echo "[Test] 7. 检查日志确认录音已启动..."
# 只看新增的日志行
AFTER_LINE_COUNT=$(wc -l < "$LOG_FILE")
NEW_LOG=$(tail -n +$((BEFORE_LINE_COUNT + 1)) "$LOG_FILE")

echo "新增日志："
echo "$NEW_LOG"
echo ""

LOG_RECORDING=false
AUDIO_STARTED=false
MENU_CLICKED=false

if echo "$NEW_LOG" | grep -q "toggleRecording 被调用, isRecording=false"; then
    echo "✅ 检测到菜单点击事件"
    MENU_CLICKED=true
fi

if echo "$NEW_LOG" | grep -q "startRecording 开始"; then
    echo "✅ 日志显示录音已启动"
    LOG_RECORDING=true
fi

if echo "$NEW_LOG" | grep -q "\[Audio\] 引擎已启动，开始采集"; then
    echo "✅ 音频引擎已启动"
    AUDIO_STARTED=true
fi

if echo "$NEW_LOG" | grep -q "\[ASR\] WebSocket 已连接"; then
    echo "✅ ASR WebSocket 已连接"
fi

echo ""
echo "========== 测试结果 =========="
echo "菜单点击触发: $MENU_CLICKED"
echo "日志显示录音启动: $LOG_RECORDING"
echo "音频引擎已启动: $AUDIO_STARTED"

echo ""
echo "截图保存在:"
echo "  录音前: $TEST_DIR/menubar_before.png"
echo "  录音后: $TEST_DIR/menubar_recording.png"
echo "  可以用 open 命令查看截图"

echo ""
if [ "$MENU_CLICKED" = true ] && [ "$LOG_RECORDING" = true ] && [ "$AUDIO_STARTED" = true ]; then
    echo "✅✅✅ 测试通过：菜单点击可以正常启动录音 ✅✅✅"

    # 停止录音
    echo ""
    echo "[Test] 8. 停止录音..."
    osascript <<'EOF' 2>&1 || true
    tell application "System Events"
        tell process "VoiceInput"
            try
                click menu bar item 1 of menu bar 1
                delay 0.5
                click menu item 1 of menu 1 of menu bar item 1 of menu bar 1
            end try
        end tell
    end tell
EOF
    sleep 1

    echo ""
    echo "验证录音已停止..."
    sleep 1
    STOP_LOG=$(tail -10 "$LOG_FILE")
    if echo "$STOP_LOG" | grep -q "stopRecording 开始"; then
        echo "✅ 录音已正常停止"
    fi

    exit 0
else
    echo "❌❌❌ 测试失败：菜单点击无法启动录音 ❌❌❌"
    echo ""
    echo "问题诊断："
    if [ "$MENU_CLICKED" = false ]; then
        echo "- ❌ 菜单项点击未被触发（toggleRecording 未被调用）"
    fi
    if [ "$LOG_RECORDING" = false ]; then
        echo "- ❌ startRecording 未被调用"
    fi
    if [ "$AUDIO_STARTED" = false ]; then
        echo "- ❌ 音频引擎未启动"
    fi
    exit 1
fi
