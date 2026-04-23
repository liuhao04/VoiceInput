#!/usr/bin/env bash
# notarize.sh - 提交 DMG 到 Apple 公证服务并 staple
#
# 用法: ./scripts/notarize.sh <path-to-dmg>
#
# 认证方式（通过环境变量）:
#
#   方式一：App Store Connect API Key（推荐，CI 友好）
#     NOTARIZE_API_KEY_PATH   - .p8 密钥文件路径
#     NOTARIZE_API_KEY_ID     - Key ID
#     NOTARIZE_API_ISSUER_ID  - Issuer ID
#
#   方式二：Apple ID（交互式，本地使用）
#     NOTARIZE_APPLE_ID       - Apple ID 邮箱
#     NOTARIZE_PASSWORD       - App-specific password
#     NOTARIZE_TEAM_ID        - Team ID

set -e

DMG_PATH="$1"

if [ -z "$DMG_PATH" ]; then
    echo "用法: $0 <path-to-dmg>"
    echo ""
    echo "示例:"
    echo "  export NOTARIZE_API_KEY_PATH=~/AuthKey_XXXX.p8"
    echo "  export NOTARIZE_API_KEY_ID=XXXXXXXXXX"
    echo "  export NOTARIZE_API_ISSUER_ID=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
    echo "  $0 /tmp/VoiceInput.dmg"
    exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "❌ 文件不存在: $DMG_PATH"
    exit 1
fi

# 构建 notarytool 认证参数
AUTH_ARGS=()
if [ -n "$NOTARIZE_API_KEY_PATH" ] && [ -n "$NOTARIZE_API_KEY_ID" ] && [ -n "$NOTARIZE_API_ISSUER_ID" ]; then
    echo "使用 API Key 认证"
    AUTH_ARGS=(--key "$NOTARIZE_API_KEY_PATH" --key-id "$NOTARIZE_API_KEY_ID" --issuer "$NOTARIZE_API_ISSUER_ID")
elif [ -n "$NOTARIZE_APPLE_ID" ] && [ -n "$NOTARIZE_PASSWORD" ] && [ -n "$NOTARIZE_TEAM_ID" ]; then
    echo "使用 Apple ID 认证"
    AUTH_ARGS=(--apple-id "$NOTARIZE_APPLE_ID" --password "$NOTARIZE_PASSWORD" --team-id "$NOTARIZE_TEAM_ID")
else
    echo "❌ 缺少认证信息。请设置以下环境变量之一："
    echo ""
    echo "  API Key 方式:"
    echo "    NOTARIZE_API_KEY_PATH, NOTARIZE_API_KEY_ID, NOTARIZE_API_ISSUER_ID"
    echo ""
    echo "  Apple ID 方式:"
    echo "    NOTARIZE_APPLE_ID, NOTARIZE_PASSWORD, NOTARIZE_TEAM_ID"
    exit 1
fi

# 提交公证
echo "📤 提交公证: $DMG_PATH"
SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" "${AUTH_ARGS[@]}" --wait --timeout 30m 2>&1) || true
echo "$SUBMIT_OUTPUT"

# 提取 submission ID
SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')

# 检查结果
if echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
    echo "✅ 公证通过！"
else
    echo "❌ 公证失败"
    if [ -n "$SUBMISSION_ID" ]; then
        echo ""
        echo "📋 获取详细日志..."
        xcrun notarytool log "$SUBMISSION_ID" "${AUTH_ARGS[@]}" 2>&1 || true
    fi
    exit 1
fi

# Staple 公证票据
echo "📎 Staple 公证票据到 DMG..."
xcrun stapler staple "$DMG_PATH"

# 验证
echo "🔍 验证 staple..."
xcrun stapler validate "$DMG_PATH"

echo ""
echo "✅ 完成！DMG 已签名并公证: $DMG_PATH"
