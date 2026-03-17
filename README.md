# VoiceInput

English | [简体中文](README_CN.md)

A macOS menu bar app for global voice-to-text input, powered by [Volcano Engine](https://www.volcengine.com/product/speech/asr) (火山引擎豆包) streaming ASR.

Press a hotkey to start/stop recording. Recognized text is automatically pasted into the current input field.

<!-- TODO: Add demo GIF here
![Demo](docs/screenshots/demo.gif)
-->

## Features

- **Global hotkey** — trigger voice input from any app (default: left Option key, configurable)
- **Streaming ASR** — real-time transcription via Volcano Engine's large model speech recognition
- **Auto-paste** — recognized text is inserted at the cursor position via clipboard + Cmd+V
- **Live preview** — floating panel near the cursor shows transcription in real time
- **Editable results** — click the floating panel to edit text before inserting
- **Recognition history** — view past transcriptions from the menu bar
- **Clipboard protection** — original clipboard content is restored after pasting

## Requirements

- macOS 13.0+
- [Volcano Engine](https://console.volcengine.com/speech) speech recognition credentials (App ID + Access Token)

## Install

```bash
git clone https://github.com/liuhao04/VoiceInput.git
cd VoiceInput
./scripts/build-and-install.sh
```

The script builds a release binary and installs it to `~/Applications/VoiceInput.app`. To customize the install location:

```bash
INSTALL_DIR="/Applications" ./scripts/build-and-install.sh
```

## Configuration

### API Credentials

On first launch, click the menu bar icon > **Settings** and enter:

- **App ID** — from Volcano Engine console
- **Access Token** — from Volcano Engine console
- **Boosting Table ID** (optional) — for custom hotword recognition

Alternatively, set environment variables before launching:

```bash
export VOLC_APP_ID="your_app_id"
export VOLC_ACCESS_TOKEN="your_access_token"
export VOLC_BOOSTING_TABLE_ID="your_boosting_table_id"  # optional
```

### Getting Volcano Engine Credentials

1. Visit [Volcano Engine Speech Console](https://console.volcengine.com/speech)
2. Create or select an application to get the App ID and Access Token
3. (Optional) Create a hotword table to get a Boosting Table ID

## Permissions

The app requires two macOS permissions (prompted on first run):

| Permission | Purpose |
|---|---|
| **Microphone** | Audio capture for speech recognition |
| **Accessibility** | Global hotkey monitoring and Cmd+V paste simulation |

## Tech Stack

- Swift 5.9, macOS 13+
- AppKit (menu bar UI)
- AVFoundation (16kHz mono 16-bit PCM audio capture)
- URLSession WebSocket (Volcano Engine binary protocol)
- Accessibility APIs (global hotkey + paste simulation)

## Project Structure

```
Sources/VoiceInput/
  VoiceInputApp.swift      # Entry point, AppDelegate, menu bar, hotkey
  AudioCapture.swift        # Microphone → PCM audio chunks
  VolcanoASR.swift          # WebSocket client for Volcano Engine ASR
  VoiceInputPanel.swift     # Floating transcription panel
  PasteboardPaste.swift     # Clipboard paste + restore
  CursorLocator.swift       # Cursor position via Accessibility API
  Config.swift              # Configuration management
  KeychainHelper.swift      # Secure credential storage
  SettingsWindow.swift      # Settings UI
  HistoryWindow.swift       # Recognition history UI
  Logger.swift              # File logging
```

## Testing

```bash
# Quick CI test (build + protocol verification)
./scripts/ci-test.sh

# E2E test with mock audio
./scripts/e2e-test-app.sh

# E2E test with real microphone (5 seconds)
./scripts/e2e-test-mic.sh
```

## License

[MIT](LICENSE)
