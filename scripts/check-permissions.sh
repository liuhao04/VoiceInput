#!/usr/bin/env bash
# 检查 VoiceInput 的权限状态

APP_PATH="$HOME/Applications/VoiceInput.app"
BUNDLE_ID="com.voiceinput.mac"

echo "=========================================="
echo "VoiceInput 权限检查"
echo "=========================================="

# 检查应用是否存在
if [ ! -d "$APP_PATH" ]; then
    echo "❌ 应用未安装: $APP_PATH"
    exit 1
fi
echo "✓ 应用已安装"

# 检查 Bundle ID
ACTUAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null)
echo "Bundle ID: $ACTUAL_BUNDLE_ID"

# 检查 Info.plist 中的权限声明
echo ""
echo "Info.plist 权限声明:"
MIC_USAGE=$(/usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "$APP_PATH/Contents/Info.plist" 2>/dev/null)
if [ -n "$MIC_USAGE" ]; then
    echo "✓ NSMicrophoneUsageDescription: $MIC_USAGE"
else
    echo "❌ 缺少 NSMicrophoneUsageDescription"
fi

ACCESSIBILITY_USAGE=$(/usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" "$APP_PATH/Contents/Info.plist" 2>/dev/null)
if [ -n "$ACCESSIBILITY_USAGE" ]; then
    echo "✓ NSAppleEventsUsageDescription: $ACCESSIBILITY_USAGE"
else
    echo "❌ 缺少 NSAppleEventsUsageDescription (可选)"
fi

echo ""
echo "=========================================="
echo "手动检查权限:"
echo "=========================================="
echo "1. 打开「系统设置」→「隐私与安全性」→「麦克风」"
echo "2. 查看列表中是否有 VoiceInput"
echo "3. 如果有，确保开关已打开"
echo "4. 如果没有，运行 ./scripts/reset-permissions.sh 并重启应用"
echo ""
echo "如果应用一直不请求权限，可能是 Bundle ID 已经被记录为拒绝。"
echo "建议操作："
echo "  1. 杀掉应用: pkill -9 VoiceInput"
echo "  2. 重置权限: ./scripts/reset-permissions.sh"
echo "  3. 重启 Mac（确保 TCC 数据库刷新）"
echo "  4. 重新启动应用并授予权限"
