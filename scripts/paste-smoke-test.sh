#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/app-target.sh"

RESULT="/tmp/voiceinput_paste_smoke_result.json"
INCLUDE_ITERM2=0
RELAUNCH=1
TARGET="distribution"

usage() {
  cat <<'USAGE'
Usage: ./scripts/paste-smoke-test.sh [--distribution|--personal|--target TARGET] [--include-iterm2] [--no-relaunch]

Runs the installed app in --test-paste-smoke mode.

Default checks:
  - TextEdit paste through the app's real PasteboardPaste path
  - Clipboard restoration

Options:
  --include-iterm2  Also trigger the iTerm2 paste fallback path. This pastes
                   a no-newline marker into the current iTerm2 session.
  --no-relaunch     Do not reopen VoiceInput after the smoke test exits.
USAGE
  voiceinput_target_usage
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --distribution)
      TARGET="distribution"
      shift
      ;;
    --personal)
      TARGET="personal"
      shift
      ;;
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --include-iterm2)
      INCLUDE_ITERM2=1
      shift
      ;;
    --no-relaunch)
      RELAUNCH=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

voiceinput_configure_target "$TARGET"
voiceinput_require_installed

rm -f "$RESULT"

voiceinput_kill_target
sleep 0.5

args=(--test-paste-smoke)
if [[ "$INCLUDE_ITERM2" -eq 1 ]]; then
  args+=(--include-iterm2)
fi

"$VOICEINPUT_EXE" "${args[@]}" &
pid=$!

for _ in {1..60}; do
  if [[ -f "$RESULT" ]]; then
    break
  fi
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

wait "$pid" || true

if [[ ! -f "$RESULT" ]]; then
  echo "Paste smoke test did not produce $RESULT" >&2
  exit 1
fi

python3 - "$RESULT" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    report = json.load(f)

print(f"success: {report.get('success')}")
for check in report.get("checks", []):
    print(f"- {check.get('name')}: {check.get('status')} - {check.get('detail')}")
print(f"log: {report.get('logFile')}")
print(f"duration: {report.get('durationSeconds'):.2f}s")

sys.exit(0 if report.get("success") else 1)
PY

if [[ "$RELAUNCH" -eq 1 ]]; then
  open "$VOICEINPUT_APP_PATH"
fi
