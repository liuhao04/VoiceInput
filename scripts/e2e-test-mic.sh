#!/usr/bin/env bash
# E2E 麦克风测试：自动开始录音，默认 5 秒后自动停止并粘贴到 TextEdit，你只需在这 5 秒内说话
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_EXE="$HOME/Applications/VoiceInput.app/Contents/MacOS/VoiceInput"
RESULT_JSON="/tmp/voiceinput_e2e_result.json"
RECORD_SEC="${1:-5}"

cd "$PROJECT_DIR"

echo "[E2E-Mic] 1. 构建并安装 App..."
swift build -c release
mkdir -p "$HOME/Applications/VoiceInput.app/Contents/MacOS"
cp "$PROJECT_DIR/.build/release/VoiceInput" "$APP_EXE"
cp "$PROJECT_DIR/Info.plist" "$HOME/Applications/VoiceInput.app/Contents/Info.plist"

echo "[E2E-Mic] 2. 打开 TextEdit 并新建文档..."
osascript -e 'tell application "TextEdit" to activate' 2>/dev/null || true
sleep 0.5
osascript -e 'tell application "TextEdit" to make new document' 2>/dev/null || true
sleep 0.5

echo "[E2E-Mic] 3. 启动自动录音（${RECORD_SEC} 秒后自动停止）..."
rm -f "$RESULT_JSON"
echo "$RECORD_SEC" > /tmp/voiceinput_e2e_mic
touch /tmp/voiceinput_e2e_requested
pkill -x VoiceInput 2>/dev/null || true
sleep 1
"$APP_EXE" &
E2E_PID=$!
echo ""
echo "  >>> 请在这 ${RECORD_SEC} 秒内对着麦克风说话 <<<"
echo ""
for i in $(seq 1 60); do
  sleep 1
  if [ -f "$RESULT_JSON" ]; then break; fi
  if ! kill -0 "$E2E_PID" 2>/dev/null; then break; fi
done
wait "$E2E_PID" 2>/dev/null || true

echo "[E2E-Mic] 4. 检查结果..."
if [ ! -f "$RESULT_JSON" ]; then
  echo "FAIL: 未生成结果文件"
  exit 1
fi
SUCCESS=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(d.get('success', False))" 2>/dev/null || echo "false")
RECOGNIZED=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(d.get('recognized','')[:100])" 2>/dev/null || echo "")
DOC_TEXT=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(d.get('documentText','')[:100])" 2>/dev/null || echo "")

if [ "$SUCCESS" = "True" ]; then
  echo "PASS: 识别结果已注入 TextEdit"
  echo "  识别: $RECOGNIZED"
  echo "  文档: $DOC_TEXT"
  exit 0
else
  echo "FAIL: 识别未成功或文档中无对应文字"
  echo "  识别: $RECOGNIZED"
  echo "  文档: $DOC_TEXT"
  cat "$RESULT_JSON"
  exit 1
fi
