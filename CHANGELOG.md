# Changelog

All notable changes to VoiceInput will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

## [1.0.1] - 2026-04-23

### Added
- Privacy policy at [docs/PRIVACY.md](docs/PRIVACY.md) describing audio handling, credential storage, and the absence of analytics/telemetry
- Menu bar entries: **申请火山引擎凭证…** (opens the Volcano Engine app console) and **隐私政策** (opens the privacy policy)
- Inline helper text in the ASR settings tab linking to the Volcano Engine console and clarifying that hotword table management must be done there

### Changed
- Reworded the hotword documentation in both READMEs: the app forwards the Boosting Table ID, but creating/editing hotwords is done in the Volcano Engine console (no in-app hotword management yet)
- Expanded the "Getting Volcano Engine Credentials" section in both READMEs with explicit steps: register → activate streaming ASR service → create app

### Fixed (previously on main since 1.0.0)
- Build 155: Menu bar icon change no longer triggers unintended recording toggle (replaced direct menu assignment with manual popUp)
- Build 159-166: Hotkey detection improved to prevent false triggers when BetterTouchTool consumes Option+key events
  - Build 166: Switched CGEvent tap from session-level to HID-level (.cghidEventTap), intercepting key events before BTT can consume them
  - Added NSEvent global monitor, HID key state table check, secondsSinceLastEventType check, 50ms delayed confirmation as fallback layers
  - Added BTT synthetic sequence detection (500ms cooldown after release)

### Added (previously on main since 1.0.0)
- Build 160: Recognition history stored to iCloud (~/Library/Mobile Documents/com~apple~CloudDocs/VoiceInput/history/) with monthly JSONL rotation
- Build 160: History viewer window with month/day filtering

## [1.0.0] - 2026-03-18

### Added
- Initial release
- Real-time voice-to-text using Volcano Engine ASR
- Menu bar app with system tray icon
- F5 hotkey to start/stop recording
- Floating panel showing live transcription
- Auto-paste recognized text into active input field
- Editable transcription panel (click to edit, Enter to confirm)
- Multi-display support with cursor-aware positioning
- Audio buffering to prevent missing first words
- Keychain-based credential storage
- Comprehensive logging system
- Automated build and test scripts

### Requirements
- macOS 13.0 or later
- Microphone permission
- Accessibility permission

[Unreleased]: https://github.com/liuhao04/VoiceInput/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/liuhao04/VoiceInput/releases/tag/v1.0.1
[1.0.0]: https://github.com/liuhao04/VoiceInput/releases/tag/v1.0.0-rc1
