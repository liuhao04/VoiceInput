#!/usr/bin/env bash
set -e

echo "=== 多显示器面板定位测试 ==="
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

# 3. 打开测试应用（TextEdit）到特定位置
echo ""
echo "打开 TextEdit 并定位窗口..."

osascript << 'APPLESCRIPT'
tell application "TextEdit"
    activate
    delay 0.5

    -- 创建新文档
    if (count of documents) is 0 then
        make new document
    end if
end tell

-- 等待窗口稳定
delay 0.5

-- 使用 System Events 移动窗口
tell application "System Events"
    set screenCount to count of (get every desktop)
    log "屏幕数量: " & screenCount

    tell process "TextEdit"
        if (count of windows) > 0 then
            -- 移动到右侧副显示器的中心位置
            -- 用户的副显示器配置：
            --   屏幕2（右侧）: frame=(1512, 262, 1080, 720)
            -- 移动到该屏幕中心: x=1512+540=2052, y=262+360=622
            set position of front window to {2052, 622}
            delay 0.5
            log "窗口已移动到: " & (get position of front window)
        end if

        -- 点击文本区域并输入测试文本
        keystroke "Multi-monitor test: cursor should be here"
        delay 0.5
    end tell
end tell
APPLESCRIPT

echo "✅ TextEdit 窗口已定位"

# 4. 获取当前屏幕配置信息
echo ""
echo "========== 显示器配置信息 =========="
system_profiler SPDisplaysDataType | grep -A 5 "Resolution:"

# 5. 获取 TextEdit 窗口位置
echo ""
echo "========== TextEdit 窗口位置 =========="
osascript << 'APPLESCRIPT'
tell application "System Events"
    tell process "TextEdit"
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

# 6. 重启 VoiceInput 进入测试模式
echo ""
echo "重启 VoiceInput 进入多显示器测试模式..."
killall VoiceInput 2>/dev/null || true
sleep 0.5

# 7. 启动测试
"$HOME/Applications/VoiceInput.app/Contents/MacOS/VoiceInput" --test-multi-monitor > /dev/null 2>&1 &
TEST_PID=$!
echo "VoiceInput 测试进程: $TEST_PID"

# 8. 等待测试完成
echo ""
echo "等待测试完成 (5秒)..."
sleep 5

# 9. 检查日志
echo ""
echo "========== 测试日志 =========="
echo ""
echo "查找光标位置相关日志:"
tail -100 ~/Library/Logs/VoiceInput.log | grep -E "\[MULTI-MONITOR\]|cursorOrMouseScreenPoint|show\(near:|屏幕|Screen" | tail -30

echo ""
echo "========== 测试说明 =========="
echo "请检查："
echo "1. 日志中的 '光标位置' 坐标是否正确（应该在 TextEdit 窗口附近）"
echo "2. 日志中的 '目标屏幕' 信息是否匹配 TextEdit 所在的屏幕"
echo "3. 日志中的 '面板位置' 是否在目标屏幕的范围内"
echo "4. 实际面板是否出现在 TextEdit 所在的显示器上"
echo ""

# 10. 清理
sleep 2
echo "清理测试环境..."
echo "✅ 测试完成"
