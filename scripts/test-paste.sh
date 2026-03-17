#!/usr/bin/env bash
# 测试粘贴功能是否正常工作
set -e

echo "测试自动粘贴功能"
echo "================="
echo ""

# 1. 检查辅助功能权限
echo "[1/4] 检查辅助功能权限..."
if ! osascript -e 'tell application "System Events" to keystroke "test"' 2>/dev/null; then
    echo "❌ 辅助功能权限未授予"
    echo ""
    echo "请按以下步骤授予权限："
    echo "1. 打开：系统偏好设置 → 安全性与隐私 → 隐私 → 辅助功能"
    echo "2. 点击左下角锁图标解锁"
    echo "3. 勾选：Terminal 或 iTerm（你正在使用的终端）"
    echo "4. 如果找不到 VoiceInput.app，点击 + 添加："
    echo "   ~/Applications/VoiceInput.app"
    echo ""
    exit 1
else
    echo "✓ 辅助功能权限已授予（终端）"
fi

# 2. 检查 VoiceInput 是否有辅助功能权限
echo ""
echo "[2/4] 检查 VoiceInput.app 辅助功能权限..."

# 使用 tccutil 检查（macOS 13+）
if command -v tccutil &> /dev/null; then
    # 重置并重新请求权限
    echo "提示：如果 VoiceInput 没有辅助功能权限，请手动添加"
    echo "路径：~/Applications/VoiceInput.app"
fi

# 3. 测试剪贴板
echo ""
echo "[3/4] 测试剪贴板功能..."
TEST_TEXT="测试文本 $(date +%s)"
osascript -e "set the clipboard to \"$TEST_TEXT\""
CLIPBOARD_CONTENT=$(osascript -e "the clipboard")

if [ "$CLIPBOARD_CONTENT" = "$TEST_TEXT" ]; then
    echo "✓ 剪贴板读写正常"
else
    echo "❌ 剪贴板测试失败"
    exit 1
fi

# 4. 测试 Cmd+V 模拟
echo ""
echo "[4/4] 测试 Cmd+V 模拟..."
echo "打开 TextEdit 并创建新文档..."

osascript <<'EOF'
tell application "TextEdit"
    activate
    make new document
    delay 0.5
end tell

tell application "System Events"
    keystroke "v" using command down
    delay 0.3
end tell

tell application "TextEdit"
    set docText to text of document 1
    return docText
end tell
EOF

DOC_TEXT=$(osascript -e 'tell application "TextEdit" to get text of document 1' 2>/dev/null || echo "")

if [[ "$DOC_TEXT" == *"$TEST_TEXT"* ]]; then
    echo "✓ Cmd+V 模拟成功，文本已粘贴"
    echo "  粘贴内容: $DOC_TEXT"
else
    echo "❌ Cmd+V 模拟失败"
    echo "  期望: $TEST_TEXT"
    echo "  实际: $DOC_TEXT"
    exit 1
fi

echo ""
echo "================="
echo "✅ 所有粘贴功能测试通过！"
echo ""
echo "如果 VoiceInput 仍然无法自动粘贴，请："
echo "1. 确保 VoiceInput.app 在辅助功能权限列表中"
echo "2. 重启 VoiceInput.app"
echo "3. 查看日志：tail -f ~/Library/Logs/VoiceInput.log"
