#!/usr/bin/env bash
# 兼容旧入口：实时粘贴测试现在使用真实 app 的 PasteboardPaste 冒烟测试。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "test-paste-live.sh 已合并到 paste-smoke-test.sh。"
echo "将运行真实 app 粘贴路径；参数会原样透传。"
echo ""

"$SCRIPT_DIR/paste-smoke-test.sh" "$@"
