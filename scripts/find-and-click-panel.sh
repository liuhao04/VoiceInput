#!/usr/bin/env bash
# 查找 VoiceInput 面板并点击

# 等待面板稳定
sleep 0.5

# 使用 osascript 获取窗口信息
WINDOW_DATA=$(osascript << 'EOF'
tell application "System Events"
    tell process "VoiceInput"
        if (count of windows) > 0 then
            set w to window 1
            set p to position of w
            set s to size of w
            return (item 1 of p) & " " & (item 2 of p) & " " & (item 1 of s) & " " & (item 2 of s)
        else
            return "NO_WINDOW"
        end if
    end tell
end tell
EOF
)

if [ "$WINDOW_DATA" = "NO_WINDOW" ]; then
    echo "❌ 未找到面板窗口" >&2
    exit 1
fi

# 解析数据
read -r X Y W H <<< "$WINDOW_DATA"

# 计算中心点
CX=$((X + W / 2))
CY=$((Y + H / 2))

echo "面板位置: $X,$Y 大小: ${W}x${H}" >&2
echo "点击中心: $CX,$CY" >&2

# 点击
cliclick c:$CX,$CY

echo "$CX,$CY"
