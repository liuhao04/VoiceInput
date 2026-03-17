#!/usr/bin/env bash
# 自动化测试：1) Python 协议测试 2) 构建 Mac App
# 协议与首包逻辑与 asr_test 一致，Python 通过则协议正确；再构建 App 确保编译通过。
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASR_TEST_DIR="$PROJECT_DIR/asr_test"

echo "========== 1/2 Python 协议测试（真实语音） =========="
cd "$ASR_TEST_DIR"
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -q -r requirements.txt 2>/dev/null || true
pip install -q websocket-client numpy 2>/dev/null || true
if ! python3 test_volc_asr.py --demo 2>&1 | tee /tmp/voiceinput_asr_log.txt; then
  echo "FAIL: Python ASR 测试未通过"
  exit 1
fi
if ! grep -q "最终结果:" /tmp/voiceinput_asr_log.txt 2>/dev/null; then
  echo "FAIL: 未看到识别最终结果"
  exit 1
fi
echo "PASS: Python 协议测试通过"

echo ""
echo "========== 2/2 构建 VoiceInput App =========="
cd "$PROJECT_DIR"
if ! swift build -c release 2>&1; then
  echo "FAIL: App 构建失败"
  exit 1
fi
echo "PASS: App 构建成功"

echo ""
echo "========== 全部通过 =========="
