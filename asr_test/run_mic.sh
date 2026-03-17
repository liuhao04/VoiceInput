#!/usr/bin/env bash
# 麦克风测试：录音后发送到火山引擎识别（请在本机终端运行，看到「请说话」后开始说）
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -q -r requirements.txt

# 尝试安装 pyaudio（Mac 需先: brew install portaudio）
if ! python3 -c "import pyaudio" 2>/dev/null; then
  echo "正在安装 pyaudio（若失败请先执行: brew install portaudio）..."
  pip install pyaudio 2>/dev/null || {
    echo "pyaudio 安装失败。请先运行: brew install portaudio"
    echo "然后执行: pip install pyaudio"
    exit 1
  }
fi

SEC="${1:-10}"
echo ">>> 流式麦克风 ${SEC} 秒：边说边识别，看到「请直接说话」后开始说。"
python3 test_volc_asr.py --mic-stream "$SEC"
