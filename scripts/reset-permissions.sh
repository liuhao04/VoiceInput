#!/usr/bin/env bash
# 重置 VoiceInput 的麦克风和辅助功能权限
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/app-target.sh"

TARGET="distribution"

usage() {
  cat <<'USAGE'
Usage: ./scripts/reset-permissions.sh [--distribution|--personal]
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

echo "正在重置 $VOICEINPUT_TARGET 权限..."
echo "Bundle ID: $VOICEINPUT_BUNDLE_ID"
echo "App: $VOICEINPUT_APP_PATH"

voiceinput_kill_target

echo "重置麦克风权限..."
tccutil reset Microphone "$VOICEINPUT_BUNDLE_ID" 2>/dev/null || true

echo "重置辅助功能权限..."
tccutil reset Accessibility "$VOICEINPUT_BUNDLE_ID" 2>/dev/null || true

echo "重置所有权限..."
tccutil reset All "$VOICEINPUT_BUNDLE_ID" 2>/dev/null || true

echo "权限已重置。下次启动目标版本时，系统会重新请求权限。"
echo "请确认目标 app 仍在固定路径，避免 TCC 记录绑定到错误位置。"
