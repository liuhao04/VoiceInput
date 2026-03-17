# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VoiceInput is a macOS menu bar app that provides global voice-to-text input using Volcano Engine (火山引擎豆包) streaming ASR. Press F5 to start/stop recording, and recognized text is automatically pasted into the current input field.

**Key Technologies:**
- Swift 5.9, macOS 13+
- AppKit for menu bar UI
- AVFoundation for audio capture (16kHz mono 16-bit PCM)
- URLSession WebSocket for Volcano Engine binary WebSocket protocol
- Accessibility APIs for global F5 hotkey and Cmd+V paste simulation

## Build & Install

**Every code change MUST be followed by:**
```bash
./scripts/build-and-install.sh
```

This script:
1. Auto-increments `CFBundleVersion` in `Info.plist`
2. Builds release binary via `swift build -c release`
3. Creates app bundle at `~/Applications/VoiceInput.app`
4. If app is running, kills and relaunches it automatically

**Version Display Requirements:**
- After every build, explicitly tell the user the new version number (e.g., "版本 1.0.0.5 (build 5)")
- Version is read from `Info.plist`: `CFBundleShortVersionString` + `CFBundleVersion`
- Version is displayed in the menu bar menu (via `Config.appVersion`)

**Fixed Installation Path:**
The app MUST always be installed to `~/Applications/VoiceInput.app` to avoid repeated permission prompts (microphone and Accessibility permissions are tied to this specific path).

## Testing

```bash
# CI test: Python protocol test + build verification
./scripts/ci-test.sh

# E2E test: Mock audio → recognition → paste to TextEdit
./scripts/e2e-test-app.sh

# E2E test: Real microphone input test (5 seconds)
./scripts/e2e-test-mic.sh
```

The Python tests in `asr_test/` use the same Volcano Engine protocol as the Swift implementation. If Python tests pass, the protocol is correct.

## Architecture

**Main Flow:**
1. **VoiceInputApp.swift**: Entry point, sets up `AppDelegate`
2. **AppDelegate**: Manages menu bar, global F5 hotkey (via Carbon), recording state
3. **AudioCapture.swift**: Captures microphone → converts to 16kHz mono 16-bit PCM → ~200ms chunks
4. **VolcanoASR.swift**: WebSocket client for Volcano Engine binary protocol
   - First packet: gzip-compressed JSON config (header `[0x11, 0x10, 0x01, 0x01]`)
   - Audio packets: raw PCM (header `[0x11, 0x20, 0x00, 0x00]`)
   - Last packet: empty audio with header `[0x11, 0x22, 0x00, 0x00]`
   - Streaming results: Updates `accumulatedText` with latest full result (not incremental)
5. **VoiceInputPanel.swift**: Floating panel near cursor showing live transcription
6. **PasteboardPaste.swift**: On stop, activates last frontmost app and simulates Cmd+V

**Critical Implementation Details:**
- Audio capture starts immediately when recording begins (before WebSocket is ready)
- Audio is queued in `pcmQueue` until server sends first response
- Once connection is ready (`isConnectionReady = true`), buffered audio is sent first, then real-time stream
- This prevents missing the first few words after pressing F5

**Config:**
- Sensitive credentials (App ID, Access Token, Boosting Table ID) stored in macOS Keychain via `KeychainHelper.swift`
- Non-sensitive config (Resource ID, WebSocket URL) stored in UserDefaults
- Environment variables (`VOLC_APP_ID`, `VOLC_ACCESS_TOKEN`, `VOLC_BOOSTING_TABLE_ID`) can override Keychain values
- API endpoint: `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`

## Development Workflow Guidelines

**When modifying code:**
1. First, write automated tests to validate the changes
2. Modify the code
3. Run automated tests repeatedly until all issues are resolved
4. Run `./scripts/build-and-install.sh` to build and install
5. After build completes and app restarts, tell the user the new version number

**Testing Strategy:**
- For protocol changes: Run `asr_test/test_volc_asr.py --demo` first
- For full integration: Use `./scripts/e2e-test-app.sh` (mocked audio)
- For real microphone: Use `./scripts/e2e-test-mic.sh` (5 seconds of live audio)

## Automated Testing System

**Comprehensive test suite available:**

```bash
# Quick CI test (10 seconds)
./scripts/ci-test.sh

# Full automated test suite (60 seconds)
./scripts/comprehensive-test.sh

# Continuous testing (watches for file changes)
./scripts/continuous-test.sh watch

# Visual UI testing
python3 scripts/visual-test.py
```

**Test Coverage:**
- ✅ Build system (compilation, versioning, installation)
- ✅ Protocol layer (WebSocket, binary format, compression)
- ✅ Core functionality (audio capture, ASR, paste)
- ✅ UI elements (menu bar, panels, version display)
- ✅ System integration (logging, permissions, resources)

**Test Outputs:**
- HTML reports: `/tmp/voiceinput_test_results/report_*.html`
- Screenshots: `/tmp/voiceinput_test_results/screenshots/`
- JSON reports: `/tmp/voiceinput_visual_tests/`

See `scripts/README_TESTS.md` for detailed testing documentation.

## Permissions

The app requires:
- **Microphone**: For audio capture
- **Accessibility**: For global F5 monitoring and Cmd+V simulation

On first run, macOS will prompt for these permissions. If permissions are denied, the app will fail to record or paste.

## Permission Protection Rules (CRITICAL - DO NOT VIOLATE)

macOS permissions (Microphone, Accessibility, etc.) are tied to the app's **code identity**. Any change to the code identity will cause macOS to treat the app as a new application and re-request ALL permissions. This is extremely disruptive to users.

**NEVER do any of the following:**

1. **NEVER use ad-hoc `codesign --sign -`** — This changes the code identity on every build, causing macOS to re-request all permissions. The build script auto-detects the local Apple Development certificate to maintain a stable identity. Set `SIGNING_IDENTITY=none` to skip signing entirely.

2. **NEVER use `NSWorkspace.shared.open(bundleURL)` to activate apps** — Opening a `.app` bundle URL triggers `kTCCServiceSystemPolicyAppBundles` ("APP管理") permission. Use `app.activate(options: [.activateIgnoringOtherApps])` instead.

3. **NEVER add entitlements that require a Team ID** — For example, `keychain-access-groups` requires a real Apple Developer Team ID. With ad-hoc signing, this causes Error 163 (launchd refuses to spawn the app).

4. **NEVER change the installation path** — Permissions are tied to `~/Applications/VoiceInput.app`. Changing the path means re-requesting all permissions.

5. **NEVER delete the entire app bundle during install** — The build script only replaces the binary and Info.plist inside the existing bundle. Running `rm -rf VoiceInput.app` would destroy the permission association.

**Safe patterns:**
- Store sensitive credentials in Keychain with `kSecAttrAccessibleWhenUnlocked` + `SecAccessCreate(name, [] as CFArray, &access)` to create unrestricted ACL (avoids binding to cdhash)
- Use `app.activate(options:)` for app activation (no TCC permission needed)
- Keep the `VoiceInput.entitlements` file empty (just `<dict/>`)
- Only replace files inside the app bundle, never recreate the bundle from scratch

## Keychain Best Practices (Lessons Learned)

**Problem**: Legacy Keychain ACL binds to creator's `cdhash`. Every rebuild changes cdhash → macOS prompts "想要使用钥匙串中的机密信息" even after clicking "始终允许".

**Solution**: Use `SecAccessCreate` with empty trusted app list:
```swift
var access: SecAccess?
SecAccessCreate("VoiceInput" as CFString, [] as CFArray, &access)
// [] = any app can access without prompt (NOT nil, which means "creator only")
addQuery[kSecAttrAccess as String] = access
```

**NEVER do:**
1. **NEVER use `kSecUseDataProtectionKeychain: true`** without a provisioning profile — requires `keychain-access-groups` entitlement → `$(AppIdentifierPrefix)` → provisioning profile → Error 163 without one
2. **NEVER delete old Keychain entries before verifying new write succeeded** — migration code that deletes first then writes can lose user credentials if the write fails (e.g., -34018 errSecMissingEntitlement)

**Migration safety pattern:**
```swift
// CORRECT: Read → Write new → Verify → Delete old
guard let value = get(forKey: key) else { return }
let writeStatus = writeToNewLocation(value)
guard writeStatus == errSecSuccess else { return } // Don't delete if write failed!
deleteOldEntry(key)

// WRONG: Read → Delete → Write (data loss if write fails!)
```

## Karabiner Hotkey Interaction (Lessons Learned)

When users remap keys with Karabiner Elements:
1. **Karabiner replaces keycode**: A Caps Lock mapped to `right_option` sends `keycode=61` (rightOption), NOT `keycode=57` (capsLock). Keycode-based filtering is impossible.
2. **Karabiner event sequence**: For Caps Lock → `left_control + right_option` mapping: `rightOption↓ → leftControl↓(~3ms later) → leftControl↑(~135ms later) → rightOption↑ → capsLock events (to_if_alone)`
3. **Don't use tolerance windows for otherMods detection**: A tolerance window with timer reset allows Karabiner's ~135ms modifier presence to be missed. Use immediate detection: any other modifier during pending = block immediately.
4. **pendingTriggerTime < 30ms filter**: Still needed to catch extremely fast Karabiner synthetic events that arrive as separate flagsChanged events within microseconds.

## Logging

All logs are written to `~/Library/Logs/VoiceInput.log` via `Logger.swift`. Users can access the log file via the menu bar → "打开日志文件".
