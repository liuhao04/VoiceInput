#!/usr/bin/env bash
# E2E 麦克风测试：自动录音 → ASR → 粘贴到 TextEdit → 验证结果
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/app-target.sh"

TARGET="distribution"
BUILD=1
RECORD_SEC=5

usage() {
  cat <<'USAGE'
Usage: ./scripts/e2e-test-mic.sh [seconds] [--distribution|--personal] [--skip-build]

Runs the installed app bundle in microphone E2E mode without creating ad-hoc app bundles.
USAGE
  voiceinput_target_usage
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --distribution) TARGET="distribution"; shift ;;
    --personal) TARGET="personal"; shift ;;
    --skip-build) BUILD=0; shift ;;
    -h|--help) usage; exit 0 ;;
    ''|*[!0-9]*) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    *) RECORD_SEC="$1"; shift ;;
  esac
done

voiceinput_configure_target "$TARGET"
RESULT_JSON="/tmp/voiceinput_e2e_result.json"

cd "$PROJECT_DIR"

echo "[E2E-Mic] 1. 准备目标 app..."
voiceinput_print_target
if [[ "$BUILD" -eq 1 ]]; then
  "$SCRIPT_DIR/build-and-install.sh" "$VOICEINPUT_BUILD_FLAG"
fi
voiceinput_require_installed

echo "[E2E-Mic] 2. 打开 TextEdit 并新建文档..."
osascript -e 'tell application "TextEdit" to activate' 2>/dev/null || true
sleep 0.5
osascript -e 'tell application "TextEdit" to make new document' 2>/dev/null || true
sleep 0.5

echo "[E2E-Mic] 3. 启动 $VOICEINPUT_TARGET 自动录音（${RECORD_SEC} 秒后自动停止）..."
rm -f "$RESULT_JSON"
echo "$RECORD_SEC" > /tmp/voiceinput_e2e_mic
touch /tmp/voiceinput_e2e_requested
voiceinput_kill_target
sleep 1
"$VOICEINPUT_EXE" &
E2E_PID=$!

echo ""
echo "  >>> 请在这 ${RECORD_SEC} 秒内对着麦克风说话 <<<"
echo ""
for _ in $(seq 1 60); do
  sleep 1
  if [[ -f "$RESULT_JSON" ]]; then break; fi
  if ! kill -0 "$E2E_PID" 2>/dev/null; then break; fi
done
wait "$E2E_PID" 2>/dev/null || true

echo "[E2E-Mic] 4. 检查结果..."
if [[ ! -f "$RESULT_JSON" ]]; then
  echo "FAIL: 未生成结果文件"
  exit 1
fi

SUCCESS=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(d.get('success', False))" 2>/dev/null || echo "false")
RECOGNIZED=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(d.get('recognized','')[:100])" 2>/dev/null || echo "")
DOC_TEXT=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(d.get('documentText','')[:100])" 2>/dev/null || echo "")
DIAGNOSTICS=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(json.dumps(d.get('diagnostics', {}), ensure_ascii=False, sort_keys=True))" 2>/dev/null || echo "{}")

if [[ "$SUCCESS" == "True" ]]; then
  echo "PASS: 识别结果已注入 TextEdit"
  echo "  识别: $RECOGNIZED"
  echo "  文档: $DOC_TEXT"
  echo "  诊断: $DIAGNOSTICS"
else
  echo "FAIL: 识别未成功或文档中无对应文字"
  echo "  识别: $RECOGNIZED"
  echo "  文档: $DOC_TEXT"
  echo "  诊断: $DIAGNOSTICS"
  cat "$RESULT_JSON"
  exit 1
fi
