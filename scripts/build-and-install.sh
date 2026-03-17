#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# 安装目录可通过环境变量 INSTALL_DIR 自定义，默认为 ~/Applications
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP_NAME="VoiceInput"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"

cd "$PROJECT_DIR"

# 每次 build 自动递增 CFBundleVersion（构建号），便于区分版本
PLIST="$PROJECT_DIR/Info.plist"
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || echo "0")
NEXT=$((CURRENT + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT" "$PLIST"
echo "Version: $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST").$NEXT (build $NEXT)"

echo "Building release..."
swift build -c release

echo "Creating app bundle at $APP_PATH"
# 不要删除整个 app bundle，以保持权限
# rm -rf "$APP_PATH"  # <- 这会导致权限丢失！
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# 只替换可执行文件和 Info.plist
cp "$PROJECT_DIR/.build/release/VoiceInput" "$APP_PATH/Contents/MacOS/"
cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"

# 复制图标（如果存在）
if [ -f "$PROJECT_DIR/Assets/AppIcon.icns" ]; then
    echo "Copying app icon..."
    cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP_PATH/Contents/Resources/"
fi

# 代码签名
# 自动检测本机开发者证书进行签名，保持代码身份一致，避免每次构建后重新授权权限。
# 可通过 SIGNING_IDENTITY 环境变量覆盖，设为 "none" 可跳过签名。
if [ "$SIGNING_IDENTITY" = "none" ]; then
    echo "Skipping code signing (SIGNING_IDENTITY=none)"
elif [ -n "$SIGNING_IDENTITY" ]; then
    echo "Code signing with identity: $SIGNING_IDENTITY"
    ENTITLEMENTS="$PROJECT_DIR/VoiceInput.entitlements"
    codesign --deep --force --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_PATH"
else
    # 自动查找本机开发者证书
    AUTO_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    if [ -n "$AUTO_IDENTITY" ]; then
        echo "Code signing with: $AUTO_IDENTITY"
        ENTITLEMENTS="$PROJECT_DIR/VoiceInput.entitlements"
        codesign --deep --force --sign "$AUTO_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_PATH"
    else
        echo "No signing identity found, using linker ad-hoc signature"
    fi
fi

echo "Installed to $APP_PATH"

# 若正在运行则先退出再启动，实现“每次 build 后自动重启”
if pgrep -x "VoiceInput" > /dev/null; then
  echo "Stopping running VoiceInput..."
  pkill -x "VoiceInput" || true
  sleep 1
fi

echo "Launching $APP_NAME..."
open "$APP_PATH"
