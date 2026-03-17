#!/usr/bin/env bash
# E2E 测试 VoiceInput.app：用本地音频 mock 识别，粘贴到 TextEdit，验证是否写入成功
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_EXE="$HOME/Applications/VoiceInput.app/Contents/MacOS/VoiceInput"
RESULT_JSON="/tmp/voiceinput_e2e_result.json"
DEMO_WAV="/tmp/voiceinput_demo.wav"
DEMO_PCM="/tmp/voiceinput_demo.pcm"
DEMO_URL="https://help-static-aliyun-doc.aliyuncs.com/file-manage-files/zh-CN/20230223/hvow/nls-sample-16k.wav"

cd "$PROJECT_DIR"

echo "[E2E] 1. 构建 App..."
swift build -c release
# 安装到固定路径（与 build-and-install 一致）
mkdir -p "$HOME/Applications/VoiceInput.app/Contents/MacOS"
cp "$PROJECT_DIR/.build/release/VoiceInput" "$APP_EXE"
cp "$PROJECT_DIR/Info.plist" "$HOME/Applications/VoiceInput.app/Contents/Info.plist"

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

echo "[E2E] 4. 运行 App 的 E2E 模式（mock 音频 → 识别 → 粘贴到 TextEdit）..."
rm -f "$RESULT_JSON"
# 通过请求文件触发 E2E，并写入音频路径
echo "$DEMO_PCM" > /tmp/voiceinput_e2e_audio_path
touch /tmp/voiceinput_e2e_requested
# 先结束已运行实例
pkill -x VoiceInput 2>/dev/null || true
sleep 1
# 直接运行可执行文件（E2E 模式会读请求文件并退出，不弹窗）
"$APP_EXE" &
E2E_PID=$!
# 等待结果文件（最多 60 秒）
for i in $(seq 1 60); do
  sleep 1
  if [ -f "$RESULT_JSON" ]; then break; fi
  if ! kill -0 "$E2E_PID" 2>/dev/null; then break; fi
done
wait "$E2E_PID" 2>/dev/null || true
if [ -f "$RESULT_JSON" ]; then EXIT_CODE=0; else EXIT_CODE=1; fi

echo "[E2E] 5. 检查结果..."
if [ ! -f "$RESULT_JSON" ]; then
  echo "FAIL: 未生成结果文件 $RESULT_JSON (exit=$EXIT_CODE)"
  exit 1
fi
SUCCESS=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(d.get('success', False))" 2>/dev/null || echo "false")
RECOGNIZED=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(d.get('recognized','')[:80])" 2>/dev/null || echo "")
DOC_TEXT=$(python3 -c "import json; d=json.load(open('$RESULT_JSON')); print(d.get('documentText','')[:80])" 2>/dev/null || echo "")

if [ "$SUCCESS" = "True" ]; then
  echo "PASS: 识别并已粘贴到 TextEdit"
  echo "  识别: $RECOGNIZED"
  echo "  文档: $DOC_TEXT"
  exit 0
else
  echo "FAIL: 粘贴未成功或文档中无识别结果 (exit=$EXIT_CODE)"
  echo "  识别: $RECOGNIZED"
  echo "  文档: $DOC_TEXT"
  cat "$RESULT_JSON"
  exit 1
fi
