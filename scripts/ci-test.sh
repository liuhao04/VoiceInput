#!/usr/bin/env bash
# 自动化测试：1) Python 协议测试 2) 构建 Mac App
# 默认跑全量；CI 可用 --asr-only 接在已有 build 后面，避免重复构建。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASR_TEST_DIR="$PROJECT_DIR/asr_test"
RUN_ASR=true
RUN_BUILD=true

usage() {
  echo "Usage: $0 [--asr-only|--build-only]"
}

for arg in "$@"; do
  case "$arg" in
    --asr-only)
      RUN_ASR=true
      RUN_BUILD=false
      ;;
    --build-only)
      RUN_ASR=false
      RUN_BUILD=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

run_asr_test() {
  local label="$1"
  echo "========== ${label}Python 协议测试（真实语音） =========="
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
}

run_build_test() {
  local label="$1"
  echo "========== ${label}构建 VoiceInput App =========="
  cd "$PROJECT_DIR"
  if ! swift build -c release 2>&1; then
    echo "FAIL: App 构建失败"
    exit 1
  fi
  echo "PASS: App 构建成功"
}

if $RUN_ASR && $RUN_BUILD; then
  run_asr_test "1/2 "
  echo ""
  run_build_test "2/2 "
elif $RUN_ASR; then
  run_asr_test ""
elif $RUN_BUILD; then
  run_build_test ""
fi

echo ""
echo "========== 全部通过 =========="
