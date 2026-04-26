#!/usr/bin/env bash

voiceinput_target_usage() {
  cat <<'USAGE'
Target options:
  --distribution  Use /Applications/VoiceInput.app (default)
  --personal      Use ~/Applications/VoiceInput Personal.app
USAGE
}

voiceinput_configure_target() {
  local target="${1:-distribution}"

  case "$target" in
    distribution)
      VOICEINPUT_TARGET="distribution"
      VOICEINPUT_APP_PATH="/Applications/VoiceInput.app"
      VOICEINPUT_BUNDLE_ID="com.voiceinput.mac"
      VOICEINPUT_BUILD_FLAG="--distribution-only"
      VOICEINPUT_LOG_FILE="$HOME/Library/Logs/VoiceInput.log"
      ;;
    personal)
      VOICEINPUT_TARGET="personal"
      VOICEINPUT_APP_PATH="$HOME/Applications/VoiceInput Personal.app"
      VOICEINPUT_BUNDLE_ID="com.voiceinput.mac.personal"
      VOICEINPUT_BUILD_FLAG="--personal-only"
      VOICEINPUT_LOG_FILE="$HOME/Library/Logs/VoiceInput Personal.log"
      ;;
    *)
      echo "Unknown VoiceInput target: $target" >&2
      return 2
      ;;
  esac

  VOICEINPUT_EXE="$VOICEINPUT_APP_PATH/Contents/MacOS/VoiceInput"
  export VOICEINPUT_TARGET VOICEINPUT_APP_PATH VOICEINPUT_BUNDLE_ID VOICEINPUT_BUILD_FLAG VOICEINPUT_EXE VOICEINPUT_LOG_FILE
}

voiceinput_require_installed() {
  if [[ ! -x "$VOICEINPUT_EXE" ]]; then
    echo "VoiceInput $VOICEINPUT_TARGET app not found at $VOICEINPUT_EXE" >&2
    echo "Run ./scripts/build-and-install.sh $VOICEINPUT_BUILD_FLAG first." >&2
    return 1
  fi
}

voiceinput_kill_target() {
  local pids
  pids="$(pgrep -f "$VOICEINPUT_EXE" 2>/dev/null || true)"
  for pid in $pids; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done
}

voiceinput_print_target() {
  echo "Target: $VOICEINPUT_TARGET"
  echo "App: $VOICEINPUT_APP_PATH"
  echo "Bundle ID: $VOICEINPUT_BUNDLE_ID"
}
