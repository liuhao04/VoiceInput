# Changelog

All notable changes to VoiceInput will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Build 155: Menu bar icon change no longer triggers unintended recording toggle (replaced direct menu assignment with manual popUp)
- Build 159-166: Hotkey detection improved to prevent false triggers when BetterTouchTool consumes Option+key events
  - Build 166: Switched CGEvent tap from session-level to HID-level (.cghidEventTap), intercepting key events before BTT can consume them
  - Added NSEvent global monitor, HID key state table check, secondsSinceLastEventType check, 50ms delayed confirmation as fallback layers
  - Added BTT synthetic sequence detection (500ms cooldown after release)

### Added
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

[Unreleased]: https://github.com/liuhao04/VoiceInput/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/liuhao04/VoiceInput/releases/tag/v1.0.0
