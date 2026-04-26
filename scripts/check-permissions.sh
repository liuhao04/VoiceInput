#!/usr/bin/env bash
# 检查 VoiceInput 的权限相关安装状态
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/app-target.sh"

TARGET="distribution"

usage() {
  cat <<'USAGE'
Usage: ./scripts/check-permissions.sh [--distribution|--personal]
USAGE
  voiceinput_target_usage
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --distribution) TARGET="distribution"; shift ;;
    --personal) TARGET="personal"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

voiceinput_configure_target "$TARGET"

echo "=========================================="
echo "VoiceInput 权限检查"
echo "=========================================="
voiceinput_print_target

if [[ ! -d "$VOICEINPUT_APP_PATH" ]]; then
  echo "FAIL: 应用未安装: $VOICEINPUT_APP_PATH"
  exit 1
fi
echo "PASS: 应用已安装"

ACTUAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$VOICEINPUT_APP_PATH/Contents/Info.plist" 2>/dev/null || echo "")
echo "Bundle ID: $ACTUAL_BUNDLE_ID"
if [[ "$ACTUAL_BUNDLE_ID" != "$VOICEINPUT_BUNDLE_ID" ]]; then
  echo "FAIL: Bundle ID 与目标版本不匹配，期望 $VOICEINPUT_BUNDLE_ID"
  exit 1
fi

echo ""
echo "Info.plist 权限声明:"
MIC_USAGE=$(/usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "$VOICEINPUT_APP_PATH/Contents/Info.plist" 2>/dev/null || true)
if [[ -n "$MIC_USAGE" ]]; then
  echo "PASS: NSMicrophoneUsageDescription: $MIC_USAGE"
else
  echo "FAIL: 缺少 NSMicrophoneUsageDescription"
fi

APPLE_EVENTS_USAGE=$(/usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" "$VOICEINPUT_APP_PATH/Contents/Info.plist" 2>/dev/null || true)
if [[ -n "$APPLE_EVENTS_USAGE" ]]; then
  echo "PASS: NSAppleEventsUsageDescription: $APPLE_EVENTS_USAGE"
else
  echo "INFO: 未声明 NSAppleEventsUsageDescription"
fi

echo ""
echo "签名摘要:"
codesign -dv --verbose=4 "$VOICEINPUT_APP_PATH" 2>&1 | rg 'Identifier|Authority|TeamIdentifier' || true

echo ""
echo "Entitlements:"
codesign -d --entitlements :- "$VOICEINPUT_APP_PATH" 2>/dev/null || true

echo ""
echo "手动检查权限:"
echo "1. 系统设置 → 隐私与安全性 → 麦克风：确认 VoiceInput 已允许"
echo "2. 系统设置 → 隐私与安全性 → 辅助功能：确认 VoiceInput 已允许"
echo "3. 如果权限异常，先确认 app 路径没有变化：$VOICEINPUT_APP_PATH"
echo "4. 需要重置时运行：./scripts/reset-permissions.sh $([[ "$TARGET" == "personal" ]] && echo "--personal" || echo "--distribution")"
