#!/usr/bin/env bash
# 剪贴板保护测试：通过真实 app 粘贴冒烟测试验证插入与剪贴板恢复。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========== 剪贴板保护测试 =========="
echo "该测试会运行真实 app 的 PasteboardPaste 路径，并验证剪贴板恢复。"
echo ""

"$SCRIPT_DIR/paste-smoke-test.sh" "$@"
