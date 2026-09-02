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

# 环境无关化：本脚本要在 macOS 宿主和 Linux guest 两侧都能跑。
# host_exec 在宿主上是直接执行，在 guest 里经 hostexec 反向 SSH 落到宿主。
# 需要 keychain 的 swift/codesign/xcrun 不走 host_exec，走 guest 自己的 shim（GUI broker）。
HB_LIB="/Users/${USER}/Library/Mobile Documents/com~apple~CloudDocs/Projects/set-claude/scripts/lib/host-bridge.sh"
if [ -f "$HB_LIB" ]; then
    # shellcheck source=/dev/null
    source "$HB_LIB" || exit 1
else
    host_exec() { "$@"; }
fi
plistbuddy() { host_exec /usr/libexec/PlistBuddy "$@"; }

# 公证凭证存在 iCloud 的 apple-certs/notarize.env（不在 keychain，见全局 CLAUDE.md）。
# guest 里没有交互 shell 的 load-secrets.sh 注入，这里显式 source 一次。
NOTARIZE_ENV="/Users/${USER}/Library/Mobile Documents/com~apple~CloudDocs/Projects/apple-certs/notarize.env"
if [ -z "${NOTARIZE_API_KEY_ID:-}" ] && [ -f "$NOTARIZE_ENV" ]; then
    # shellcheck source=/dev/null
    source "$NOTARIZE_ENV"
fi
# notarize.env 里的 key 路径写的是 `~`/`$HOME`，在 guest 里会展开成 /home/liuhao.guest/…，
# 而 notarytool 实际在宿主上执行，找不到那个路径。统一改写成宿主家目录下的绝对路径。
if [ -n "${NOTARIZE_API_KEY_PATH:-}" ] && [ ! -f "$NOTARIZE_API_KEY_PATH" ]; then
    CANDIDATE="/Users/${USER}/${NOTARIZE_API_KEY_PATH#*/Library/}"
    [ -f "$CANDIDATE" ] || CANDIDATE="/Users/${USER}/Library/${NOTARIZE_API_KEY_PATH#*/Library/}"
    if [ -f "$CANDIDATE" ]; then
        echo "  公证 key 路径改写到宿主: $CANDIDATE"
        NOTARIZE_API_KEY_PATH="$CANDIDATE"
    fi
fi

# ---------- 版本信息 ----------
PLIST="$PROJECT_DIR/Info.plist"
VERSION=$(plistbuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(plistbuddy -c "Print :CFBundleVersion" "$PLIST")
DMG_NAME="VoiceInput-${VERSION}.dmg"
DIST_DIR="$PROJECT_DIR/dist"
mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/$DMG_NAME"
APP_NAME="VoiceInput"
# 暂存目录有两条硬约束：
#   1. 不能用 /tmp —— guest 的 /tmp 宿主看不见，宿主侧的 codesign/hdiutil 找不到文件
#   2. 不能放项目里 —— 项目在 iCloud Drive 上，文件会带 iCloud 扩展属性，
#      codesign 直接报 "resource fork, Finder information, or similar detritus not allowed"
# 所以放 /Users 下的非 iCloud 路径：guest 与宿主共享，又不沾 iCloud 元数据。
STAGE_DIR="/Users/${USER}/.cache/voiceinput-dmg"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
ENTITLEMENTS="$PROJECT_DIR/VoiceInput.entitlements"

echo "=== VoiceInput 分发构建 ==="
echo "版本: $VERSION (build $BUILD)"
echo ""

# ---------- 构建 ----------
echo "▶ 构建 release..."
swift build -c release

# ---------- 创建 app bundle ----------
echo "▶ 创建 app bundle..."
rm -rf "$STAGE_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$PROJECT_DIR/.build/release/VoiceInput" "$APP_BUNDLE/Contents/MacOS/"
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
# 显式声明分发版的 bundle ID 和显示名（防御性，避免源 plist 被误改）
plistbuddy -c "Set :CFBundleIdentifier com.voiceinput.mac" "$APP_BUNDLE/Contents/Info.plist"
plistbuddy -c "Set :CFBundleName VoiceInput" "$APP_BUNDLE/Contents/Info.plist"
# CFBundlePackageType 是 app bundle 的必需键。缺了它 Gatekeeper 会判
# "the code is valid but does not seem to be an app"，用户从 DMG 装完打不开。
# 本机安装不带隔离属性、不走首次验证，所以本地一直没暴露（2026-09-02 发版才发现）。
plistbuddy -c "Set :CFBundlePackageType APPL" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null   || plistbuddy -c "Add :CFBundlePackageType string APPL" "$APP_BUNDLE/Contents/Info.plist"

if [ -f "$PROJECT_DIR/Assets/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

# ---------- 签名 ----------
# 与 build-and-install.sh 保持一致：优先 Developer ID Application，其次显式 SIGNING_IDENTITY。
# Distribution DMG 必须签名；这里不支持 SIGNING_IDENTITY=none。
if [ "$SIGNING_IDENTITY" = "none" ]; then
    echo "❌ Distribution DMG 必须签名，不能使用 SIGNING_IDENTITY=none"
    exit 1
elif [ -n "$SIGNING_IDENTITY" ]; then
    SIGN_IDENTITY_EFFECTIVE="$SIGNING_IDENTITY"
else
    SIGN_IDENTITY_EFFECTIVE=$(host_exec security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
fi

if [ -z "$SIGN_IDENTITY_EFFECTIVE" ]; then
    echo "❌ 未找到 Developer ID Application 签名证书"
    echo "   请安装 Developer ID Application 证书，或通过 SIGNING_IDENTITY 指定分发签名身份。"
    exit 1
fi

# 保险起见再清一次扩展属性：签名对 detritus 零容忍，来源可能是 iCloud、下载隔离、Finder 信息
host_exec xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo "▶ 代码签名..."
codesign --deep --force --options runtime \
    --sign "$SIGN_IDENTITY_EFFECTIVE" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE"

# 验证签名
codesign --verify --deep --strict "$APP_BUNDLE"
echo "  签名验证通过 ✓"

# ---------- 创建 DMG ----------
echo "▶ 创建 DMG..."
rm -f "$DMG_PATH"

# 创建临时目录用于 DMG 内容
DMG_STAGING="$STAGE_DIR/staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
# 跨 virtiofs 用 cp -R 拷 .app 会破坏签名，必须用 ditto
ditto "$APP_BUNDLE" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

host_exec hdiutil create -volname "VoiceInput" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"

# 签名 DMG
codesign --force --sign "$SIGN_IDENTITY_EFFECTIVE" "$DMG_PATH"
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
rm -rf "$STAGE_DIR"

# ---------- 完成 ----------
echo ""
echo "========================================="
echo "✅ DMG 已生成: $DMG_PATH"
echo "   大小: $(du -h "$DMG_PATH" | cut -f1)"
echo "========================================="
echo ""
echo "发给朋友后，双击 DMG → 把 VoiceInput 拖到 Applications 即可使用。"
