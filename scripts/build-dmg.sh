#!/usr/bin/env bash
# build-dmg.sh — 一键构建签名公证的分发 DMG
#
# 分发版与个人版完全隔离：
#   - Bundle ID: com.voiceinput.mac
#   - App 名:    VoiceInput.app
#   - 安装位置由用户决定（通常拖到 /Applications）
#
# 个人版（用于自己日常使用）请用 ./scripts/build-and-install.sh
#
# 用法:
#   ./scripts/build-dmg.sh                    # 签名 + 公证（需要 API Key 环境变量）
#   ./scripts/build-dmg.sh --skip-notarize    # 只签名，跳过公证
#
# 公证需要以下环境变量（或在 ~/.zshrc 中 export）:
#   NOTARIZE_API_KEY_PATH   - AuthKey_XXXX.p8 文件路径
#   NOTARIZE_API_KEY_ID     - Key ID
#   NOTARIZE_API_ISSUER_ID  - Issuer ID

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 解析参数
SKIP_NOTARIZE=false
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=true ;;
    esac
done

cd "$PROJECT_DIR"

# ---------- 版本信息 ----------
PLIST="$PROJECT_DIR/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
DMG_NAME="VoiceInput-${VERSION}.dmg"
DIST_DIR="$PROJECT_DIR/dist"
mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/$DMG_NAME"
APP_NAME="VoiceInput"
APP_BUNDLE="/tmp/$APP_NAME.app"
ENTITLEMENTS="$PROJECT_DIR/VoiceInput.entitlements"

echo "=== VoiceInput 分发构建 ==="
echo "版本: $VERSION (build $BUILD)"
echo ""

# ---------- 构建 ----------
echo "▶ 构建 release..."
swift build -c release

# ---------- 创建 app bundle ----------
echo "▶ 创建 app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$PROJECT_DIR/.build/release/VoiceInput" "$APP_BUNDLE/Contents/MacOS/"
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
# 显式声明分发版的 bundle ID 和显示名（防御性，避免源 plist 被误改）
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.voiceinput.mac" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName VoiceInput" "$APP_BUNDLE/Contents/Info.plist"

if [ -f "$PROJECT_DIR/Assets/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

# ---------- 签名 ----------
SIGNING_IDENTITY="Developer ID Application"

echo "▶ 代码签名..."
codesign --deep --force --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE"

# 验证签名
codesign --verify --deep --strict "$APP_BUNDLE"
echo "  签名验证通过 ✓"

# ---------- 创建 DMG ----------
echo "▶ 创建 DMG..."
rm -f "$DMG_PATH"

# 创建临时目录用于 DMG 内容
DMG_STAGING="/tmp/voiceinput-dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create -volname "VoiceInput" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"

# 签名 DMG
codesign --force --sign "$SIGNING_IDENTITY" "$DMG_PATH"
echo "  DMG 已签名 ✓"

# ---------- 公证 ----------
if [ "$SKIP_NOTARIZE" = true ]; then
    echo ""
    echo "⏭  跳过公证（--skip-notarize）"
    echo "   ⚠️  没有公证的 DMG 在其他 Mac 上会被 Gatekeeper 拦截"
elif [ -n "$NOTARIZE_API_KEY_PATH" ] && [ -n "$NOTARIZE_API_KEY_ID" ] && [ -n "$NOTARIZE_API_ISSUER_ID" ]; then
    echo "▶ 提交 Apple 公证..."
    SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
        --key "$NOTARIZE_API_KEY_PATH" \
        --key-id "$NOTARIZE_API_KEY_ID" \
        --issuer "$NOTARIZE_API_ISSUER_ID" \
        --wait --timeout 30m 2>&1) || true
    echo "$SUBMIT_OUTPUT"

    if echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
        echo "  公证通过 ✓"

        echo "▶ Staple 公证票据..."
        xcrun stapler staple "$DMG_PATH"
        xcrun stapler validate "$DMG_PATH"
        echo "  Staple 完成 ✓"
    else
        echo "  ❌ 公证失败"
        SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
        if [ -n "$SUBMISSION_ID" ]; then
            echo ""
            echo "📋 详细日志:"
            xcrun notarytool log "$SUBMISSION_ID" \
                --key "$NOTARIZE_API_KEY_PATH" \
                --key-id "$NOTARIZE_API_KEY_ID" \
                --issuer "$NOTARIZE_API_ISSUER_ID" 2>&1 || true
        fi
        echo ""
        echo "DMG 已生成但未公证: $DMG_PATH"
        exit 1
    fi
else
    echo ""
    echo "⚠️  未配置公证 API Key，跳过公证"
    echo "   设置以下环境变量后重新运行即可公证:"
    echo "     export NOTARIZE_API_KEY_PATH=~/AuthKey_XXXX.p8"
    echo "     export NOTARIZE_API_KEY_ID=XXXXXXXXXX"
    echo "     export NOTARIZE_API_ISSUER_ID=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
fi

# ---------- 清理 ----------
rm -rf "$APP_BUNDLE"

# ---------- 完成 ----------
echo ""
echo "========================================="
echo "✅ DMG 已生成: $DMG_PATH"
echo "   大小: $(du -h "$DMG_PATH" | cut -f1)"
echo "========================================="
echo ""
echo "发给朋友后，双击 DMG → 把 VoiceInput 拖到 Applications 即可使用。"
