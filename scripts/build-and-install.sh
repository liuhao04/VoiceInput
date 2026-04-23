#!/usr/bin/env bash
# build-and-install.sh — 构建并安装 Personal + Distribution 两个本地版本（默认同时装）
#
# 个人版与分发版完全隔离，默认同时更新：
#   个人版 (Personal):
#     - Bundle ID: com.voiceinput.mac.personal
#     - App 名:    VoiceInput Personal.app
#     - 安装位置:  ~/Applications/VoiceInput Personal.app
#     - 菜单栏图标右上角带紫色圆点
#   分发版 (Distribution，用于本地对照/公测):
#     - Bundle ID: com.voiceinput.mac
#     - App 名:    VoiceInput.app
#     - 安装位置:  /Applications/VoiceInput.app（必须已存在，通常由 DMG 首次装入）
#     - 原地替换 MacOS/Info.plist，保留 bundle 路径以保留 TCC 权限
#
# 选项:
#   --personal-only       仅装 Personal 版（跳过 Distribution）
#   --distribution-only   仅装 Distribution 版（跳过 Personal）
#
# 正式分发 DMG（签名+公证）请用 ./scripts/build-dmg.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

INSTALL_PERSONAL=true
INSTALL_DISTRIBUTION=true
for arg in "$@"; do
    case "$arg" in
        --personal-only)      INSTALL_DISTRIBUTION=false ;;
        --distribution-only)  INSTALL_PERSONAL=false ;;
    esac
done

BUNDLE_ID_BASE="com.voiceinput.mac"
BUNDLE_ID="${BUNDLE_ID_BASE}.personal"
BUNDLE_NAME="VoiceInput Personal"

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$INSTALL_DIR/${BUNDLE_NAME}.app"

DIST_APP_PATH="/Applications/VoiceInput.app"

cd "$PROJECT_DIR"

# 每次 build 自动递增 CFBundleVersion（构建号），便于区分版本
PLIST="$PROJECT_DIR/Info.plist"
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || echo "0")
NEXT=$((CURRENT + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT" "$PLIST"
echo "Version: $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST").$NEXT (build $NEXT)"

echo "Building release..."
swift build -c release

# 决定签名身份（两个版本共用）
# 自动检测本机开发者证书进行签名，保持代码身份一致，避免每次构建后重新授权权限。
# 可通过 SIGNING_IDENTITY 环境变量覆盖，设为 "none" 可跳过签名。
ENTITLEMENTS="$PROJECT_DIR/VoiceInput.entitlements"
SIGN_IDENTITY_EFFECTIVE=""
if [ "$SIGNING_IDENTITY" = "none" ]; then
    echo "Skipping code signing (SIGNING_IDENTITY=none)"
elif [ -n "$SIGNING_IDENTITY" ]; then
    SIGN_IDENTITY_EFFECTIVE="$SIGNING_IDENTITY"
else
    AUTO_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    if [ -z "$AUTO_IDENTITY" ]; then
        AUTO_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    fi
    SIGN_IDENTITY_EFFECTIVE="$AUTO_IDENTITY"
fi

sign_bundle() {
    local bundle="$1"
    if [ -z "$SIGN_IDENTITY_EFFECTIVE" ]; then
        echo "  No signing identity found, using linker ad-hoc signature for $bundle"
        return 0
    fi
    echo "  Signing $bundle with: $SIGN_IDENTITY_EFFECTIVE"
    codesign --deep --force --options runtime --sign "$SIGN_IDENTITY_EFFECTIVE" --entitlements "$ENTITLEMENTS" "$bundle"
}

# ---------- Personal 版 ----------
if [ "$INSTALL_PERSONAL" = true ]; then
    echo ""
    echo "=== Personal 版 ==="
    echo "Creating app bundle at $APP_PATH"
    # 不要删除整个 app bundle，以保持权限
    mkdir -p "$APP_PATH/Contents/MacOS"
    mkdir -p "$APP_PATH/Contents/Resources"

    # 只替换可执行文件和 Info.plist
    cp "$PROJECT_DIR/.build/release/VoiceInput" "$APP_PATH/Contents/MacOS/"
    cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
    # Personal 版改写 bundle ID 和显示名（不污染源 plist）
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_PATH/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName ${BUNDLE_NAME}" "$APP_PATH/Contents/Info.plist"

    # 复制图标（如果存在）
    if [ -f "$PROJECT_DIR/Assets/AppIcon.icns" ]; then
        cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP_PATH/Contents/Resources/"
    fi

    sign_bundle "$APP_PATH"
    echo "Installed to $APP_PATH"

    # 提醒用户清理旧的 ~/Applications/VoiceInput.app（与 Personal 不同 bundle ID 的孤儿）
    OLD_APP_PATH="$INSTALL_DIR/VoiceInput.app"
    if [ "$APP_PATH" != "$OLD_APP_PATH" ] && [ -d "$OLD_APP_PATH" ]; then
        OLD_BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$OLD_APP_PATH/Contents/Info.plist" 2>/dev/null || echo "?")
        echo ""
        echo "⚠️  发现旧的 ~/Applications/VoiceInput.app (bundle ID: $OLD_BID)"
        echo "    它和当前 Personal 版是不同 bundle ID，权限/凭证已迁移到 Personal 版。"
        echo "    可以安全删除：rm -rf \"$OLD_APP_PATH\""
    fi

    # 若正在运行则先退出再启动（用路径精确匹配，避免误杀分发版）
    RUNNING_PID=$(pgrep -f "$APP_PATH/Contents/MacOS/VoiceInput" || true)
    if [ -n "$RUNNING_PID" ]; then
      echo "Stopping running Personal version (pid $RUNNING_PID)..."
      kill "$RUNNING_PID" || true
      sleep 1
    fi

    echo "Launching $BUNDLE_NAME..."
    open "$APP_PATH"
fi

# ---------- Distribution 版 ----------
if [ "$INSTALL_DISTRIBUTION" = true ]; then
    echo ""
    echo "=== Distribution 版 ==="
    if [ ! -d "$DIST_APP_PATH" ]; then
        echo "⚠️  $DIST_APP_PATH 不存在 — 跳过 Distribution 版安装。"
        echo "    首次安装请通过 ./scripts/build-dmg.sh 产 DMG 后拖进 /Applications。"
    else
        echo "In-place updating $DIST_APP_PATH..."

        # 若正在运行则先停掉
        DIST_PID=$(pgrep -f "$DIST_APP_PATH/Contents/MacOS/VoiceInput" || true)
        if [ -n "$DIST_PID" ]; then
            echo "Stopping running Distribution version (pid $DIST_PID)..."
            kill "$DIST_PID" || true
            sleep 1
        fi

        # 只替换可执行文件和 Info.plist（保留 bundle 路径以保留 TCC 权限）
        cp "$PROJECT_DIR/.build/release/VoiceInput" "$DIST_APP_PATH/Contents/MacOS/VoiceInput"
        cp "$PROJECT_DIR/Info.plist" "$DIST_APP_PATH/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.voiceinput.mac" "$DIST_APP_PATH/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleName VoiceInput" "$DIST_APP_PATH/Contents/Info.plist"

        if [ -f "$PROJECT_DIR/Assets/AppIcon.icns" ]; then
            cp "$PROJECT_DIR/Assets/AppIcon.icns" "$DIST_APP_PATH/Contents/Resources/"
        fi

        sign_bundle "$DIST_APP_PATH"
        echo "Updated $DIST_APP_PATH"

        echo "Launching VoiceInput..."
        open "$DIST_APP_PATH"
    fi
fi
