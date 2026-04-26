#!/usr/bin/env bash
# E2E 测试：本地音频 mock → ASR → 粘贴到 TextEdit → 验证结果
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/app-target.sh"

TARGET="distribution"
BUILD=1

usage() {
  cat <<'USAGE'
Usage: ./scripts/e2e-test-app.sh [--distribution|--personal] [--skip-build]

Runs the installed app bundle in E2E mode without creating ad-hoc app bundles.
USAGE
  voiceinput_target_usage
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --distribution) TARGET="distribution"; shift ;;
    --personal) TARGET="personal"; shift ;;
    --skip-build) BUILD=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

voiceinput_configure_target "$TARGET"

RESULT_JSON="/tmp/voiceinput_e2e_result.json"
DEMO_WAV="/tmp/voiceinput_demo.wav"
DEMO_PCM="/tmp/voiceinput_demo.pcm"
DEMO_URL="https://help-static-aliyun-doc.aliyuncs.com/file-manage-files/zh-CN/20230223/hvow/nls-sample-16k.wav"

cd "$PROJECT_DIR"

echo "[E2E] 1. 准备目标 app..."
voiceinput_print_target
if [[ "$BUILD" -eq 1 ]]; then
  "$SCRIPT_DIR/build-and-install.sh" "$VOICEINPUT_BUILD_FLAG"
fi
voiceinput_require_installed

echo "[E2E] 2. 下载测试用语音样本并转为 PCM..."
curl -sSL --connect-timeout 10 "$DEMO_URL" -o "$DEMO_WAV" || { echo "下载失败"; exit 1; }
test -s "$DEMO_WAV" || { echo "样本为空"; exit 1; }
python3 -c "
import wave
with wave.open('$DEMO_WAV', 'rb') as f:
    pcm = f.readframes(f.getnframes())
    open('$DEMO_PCM', 'wb').write(pcm)
" || { echo "WAV 转 PCM 失败"; exit 1; }
echo "$DEMO_PCM" > /tmp/voiceinput_e2e_audio_path

echo "[E2E] 3. 打开 TextEdit 并新建文档..."
osascript -e 'tell application "TextEdit" to activate' 2>/dev/null || true
sleep 0.5
osascript -e 'tell application "TextEdit" to make new document' 2>/dev/null || true
sleep 0.5

echo "[E2E] 4. 运行 $VOICEINPUT_TARGET E2E 模式..."
rm -f "$RESULT_JSON"
echo "$DEMO_PCM" > /tmp/voiceinput_e2e_audio_path
touch /tmp/voiceinput_e2e_requested
voiceinput_kill_target
sleep 1
"$VOICEINPUT_EXE" &
E2E_PID=$!

for _ in $(seq 1 60); do
  sleep 1
  if [[ -f "$RESULT_JSON" ]]; then break; fi
  if ! kill -0 "$E2E_PID" 2>/dev/null; then break; fi
done
wait "$E2E_PID" 2>/dev/null || true

echo "[E2E] 5. 检查结果..."
if [[ ! -f "$RESULT_JSON" ]]; then
  echo "FAIL: 未生成结果文件 $RESULT_JSON"
  exit 1
fi

SUCCESS=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(d.get('success', False))" 2>/dev/null || echo "false")
RECOGNIZED=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(d.get('recognized','')[:80])" 2>/dev/null || echo "")
DOC_TEXT=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(d.get('documentText','')[:80])" 2>/dev/null || echo "")

if [[ "$SUCCESS" == "True" ]]; then
  echo "PASS: 识别并已粘贴到 TextEdit"
  echo "  识别: $RECOGNIZED"
  echo "  文档: $DOC_TEXT"
else
  echo "FAIL: 粘贴未成功或文档中无识别结果"
  echo "  识别: $RECOGNIZED"
  echo "  文档: $DOC_TEXT"
  cat "$RESULT_JSON"
  exit 1
fi
