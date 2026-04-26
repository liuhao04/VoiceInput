#!/usr/bin/env bash
# 粘贴功能测试：检查终端辅助功能权限、剪贴板，并运行真实 app 粘贴冒烟测试。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/app-target.sh"

TARGET="distribution"
INCLUDE_ITERM2=0

usage() {
  cat <<'USAGE'
Usage: ./scripts/test-paste.sh [--distribution|--personal] [--include-iterm2]
USAGE
  voiceinput_target_usage
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --distribution) TARGET="distribution"; shift ;;
    --personal) TARGET="personal"; shift ;;
    --include-iterm2) INCLUDE_ITERM2=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

voiceinput_configure_target "$TARGET"

echo "测试自动粘贴功能"
echo "================="
voiceinput_print_target
echo ""

echo "[1/3] 检查当前终端的辅助功能权限..."
if ! osascript -e 'tell application "System Events" to keystroke "test"' 2>/dev/null; then
  echo "FAIL: 当前终端没有辅助功能权限。请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 Terminal/iTerm。"
  exit 1
fi
echo "PASS: 当前终端可发送辅助功能事件"

echo ""
echo "[2/3] 测试剪贴板读写..."
TEST_TEXT="VOICEINPUT_CLIPBOARD_TEST_$(date +%s)"
printf "%s" "$TEST_TEXT" | pbcopy
CLIPBOARD_CONTENT="$(pbpaste)"
if [[ "$CLIPBOARD_CONTENT" != "$TEST_TEXT" ]]; then
  echo "FAIL: 剪贴板读写失败"
  exit 1
fi
echo "PASS: 剪贴板读写正常"

echo ""
echo "[3/3] 运行真实 app 粘贴冒烟测试..."
args=(--target "$TARGET")
if [[ "$INCLUDE_ITERM2" -eq 1 ]]; then
  args+=(--include-iterm2)
fi
"$SCRIPT_DIR/paste-smoke-test.sh" "${args[@]}"
