#!/usr/bin/env bash
# 重置 VoiceInput 的麦克风和辅助功能权限

APP_BUNDLE_ID="com.voiceinput.mac"

echo "正在重置权限..."

# 重置麦克风权限
echo "重置麦克风权限..."
tccutil reset Microphone "$APP_BUNDLE_ID" 2>/dev/null || true

# 重置辅助功能权限
echo "重置辅助功能权限..."
tccutil reset Accessibility "$APP_BUNDLE_ID" 2>/dev/null || true

# 重置所有权限
echo "重置所有权限..."
tccutil reset All "$APP_BUNDLE_ID" 2>/dev/null || true

echo "权限已重置！"
echo "下次启动应用时，系统会重新请求权限。"
echo ""
echo "⚠️  请在系统弹窗中点击「允许」授予权限。"
