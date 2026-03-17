#!/usr/bin/env bash
set -e

echo "=== iTerm2 多显示器面板定位测试 ==="
echo ""

# 1. 检查应用是否运行
if ! pgrep -x "VoiceInput" > /dev/null; then
    echo "❌ VoiceInput 未运行，请先启动应用"
    exit 1
fi
echo "✅ VoiceInput 正在运行"

# 2. 检查显示器数量
SCREEN_COUNT=$(system_profiler SPDisplaysDataType | grep -c "Resolution:")
echo "检测到 $SCREEN_COUNT 个显示器"

if [ "$SCREEN_COUNT" -lt 2 ]; then
    echo "⚠️  警告：只检测到 1 个显示器，多显示器测试需要至少 2 个显示器"
    echo "将继续单显示器测试..."
fi

# 3. 检查 iTerm2 是否运行
if ! pgrep -x "iTerm2" > /dev/null; then
    echo ""
    echo "启动 iTerm2..."
    open -a iTerm
    sleep 2
fi
echo "✅ iTerm2 正在运行"

# 4. 移动 iTerm2 窗口到副显示器并输入测试文本
echo ""
echo "配置 iTerm2 窗口..."

osascript << 'APPLESCRIPT'
tell application "iTerm"
    activate
    delay 0.5

    -- 创建新窗口（如果需要）
    if (count of windows) is 0 then
        create window with default profile
        delay 1
    end if
end tell

-- 等待窗口稳定
delay 0.5

-- 使用 System Events 移动窗口到副显示器
tell application "System Events"
    tell process "iTerm2"
        if (count of windows) > 0 then
            -- 移动到右侧副显示器（屏幕2）
            -- frame=(1512, 262, 1080, 720)
            -- 移动到该屏幕中心: x=1512+540=2052, y=262+360=622
            set position of front window to {2052, 622}
            delay 0.5

            set winPos to position of front window
            log "iTerm2 窗口位置: " & (item 1 of winPos) & ", " & (item 2 of winPos)

            -- 清空当前行
            keystroke "c" using control down
            delay 0.2

            -- 输入测试文本
            keystroke "# iTerm2 multi-monitor test - cursor here"
            delay 0.3
        end if
    end tell
end tell
APPLESCRIPT

echo "✅ iTerm2 窗口已配置"

# 5. 获取当前屏幕配置信息
echo ""
echo "========== 显示器配置信息 =========="
system_profiler SPDisplaysDataType | grep -A 5 "Resolution:"

# 6. 获取 iTerm2 窗口位置
echo ""
echo "========== iTerm2 窗口位置 =========="
osascript << 'APPLESCRIPT'
tell application "System Events"
    tell process "iTerm2"
        if (count of windows) > 0 then
            tell front window
                set winPos to position
                set winSize to size
                log "窗口位置: " & (item 1 of winPos) & ", " & (item 2 of winPos)
                log "窗口大小: " & (item 1 of winSize) & ", " & (item 2 of winSize)
            end tell
        end if
    end tell
end tell
APPLESCRIPT

# 7. 重启 VoiceInput 进入测试模式
echo ""
echo "重启 VoiceInput 进入 iTerm2 测试模式..."
killall VoiceInput 2>/dev/null || true
sleep 0.5

# 8. 启动测试
"$HOME/Applications/VoiceInput.app/Contents/MacOS/VoiceInput" --test-iterm2-monitor > /dev/null 2>&1 &
TEST_PID=$!
echo "VoiceInput 测试进程: $TEST_PID"

# 9. 等待测试完成
echo ""
echo "等待测试完成 (5秒)..."
sleep 5

# 10. 检查日志
echo ""
echo "========== 测试日志 =========="
echo ""
echo "查找 iTerm2 相关日志:"
tail -100 ~/Library/Logs/VoiceInput.log | grep -E "\[ITERM2-TEST\]|\[cursorOrMouseScreenPoint\]|iTerm|show\(near:|屏幕|Screen" | tail -40

echo ""
echo "========== 测试说明 =========="
echo "请检查："
echo "1. 日志中 iTerm2 窗口是否在副显示器上（位置应该是 2052, 622 附近）"
echo "2. 光标位置检测使用的是哪种方法（方法1/方法2/fallback）"
echo "3. 对于终端应用，AX API 可能无法获取文本光标位置"
echo "4. 目标屏幕是否匹配 iTerm2 窗口所在的屏幕"
echo "5. 面板位置是否在目标屏幕的范围内"
echo "6. 实际面板是否出现在 iTerm2 所在的显示器上"
echo ""

# 11. 清理
sleep 2
echo "清理测试环境..."
echo "✅ 测试完成"
