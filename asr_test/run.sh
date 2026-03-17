#!/usr/bin/env bash
# 全自动：创建 venv、安装依赖、跑静音连接测试（不依赖麦克风）
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -d .venv ]]; then
  echo "[1/2] 创建虚拟环境 .venv ..."
  python3 -m venv .venv
fi
echo "[2/2] 激活并安装依赖 ..."
source .venv/bin/activate
pip install -q -r requirements.txt

echo ""
echo ">>> 运行测试（默认 2 秒静音，仅验证连接与协议）..."
python3 test_volc_asr.py

echo ""
echo ">>> 真实语音测试: python3 test_volc_asr.py --demo"
echo ">>> 可选：麦克风录音需先安装 portaudio 与 pyaudio"
echo "    Mac: brew install portaudio && pip install pyaudio"
echo "    然后: python3 test_volc_asr.py --mic 5"
echo ">>> 可选：指定 WAV: python3 test_volc_asr.py --wav /path/to/16k.wav"
