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

项目维护两个完全隔离的版本，从同一份代码构建：

| | Personal 版（个人开发） | Distribution 版（分发 / 本地对照） |
|---|---|---|
| Bundle ID | `com.voiceinput.mac.personal` | `com.voiceinput.mac` |
| 安装路径 | `~/Applications/VoiceInput Personal.app` | `/Applications/VoiceInput.app`（用户拖拽或本机原地更新） |
| 构建脚本 | `./scripts/build-and-install.sh`（默认同时装 Distribution） | `./scripts/build-dmg.sh`（产公证 DMG） |
| 菜单栏图标 | mic.fill + 紫色角标 | mic.fill（template，自适配明暗模式） |
| Keychain service | `com.voiceinput.mac.personal` | `com.voiceinput.mac` |
| UserDefaults domain | `com.voiceinput.mac.personal` | `com.voiceinput.mac` |
| Log file | `~/Library/Logs/VoiceInput Personal.log` | `~/Library/Logs/VoiceInput.log` |
| TCC 权限 | 独立授权 | 独立授权 |
| 用途 | 日常自用 | 发给朋友/公测 + 本机并排对照 |

两个版本可以同时安装、同时运行，互不干扰。

**每次代码改动 MUST 跑这个（默认装 Personal + Distribution 两个）：**
```bash
./scripts/build-and-install.sh
```
1. 自动递增 `CFBundleVersion`
2. 构建一次 release
3. **Personal 版**：复制到 `~/Applications/VoiceInput Personal.app`、PlistBuddy 改 Bundle ID/显示名、Developer ID 签名、按路径 kill+open
4. **Distribution 版**：若 `/Applications/VoiceInput.app` 已存在，原地替换 `Contents/MacOS/VoiceInput` 和 `Contents/Info.plist`（保留 bundle 路径以保留 TCC 权限）、PlistBuddy 写回 `com.voiceinput.mac` + `VoiceInput`、同一证书签名、按路径 kill+open；若不存在则跳过并提示先用 `build-dmg.sh`
5. 两个版本可选 flag：`--personal-only` / `--distribution-only` 只装其中一个

**Distribution 版正式分发（要公证时跑）：**
```bash
./scripts/build-dmg.sh                 # 签名 + 公证（需要 NOTARIZE_API_KEY_* 环境变量）
./scripts/build-dmg.sh --skip-notarize # 仅签名
```
输出：`dist/VoiceInput-<version>.dmg`，用户双击安装。

**Personal/Distribution 隔离机制：**
- 代码层：`KeychainHelper.swift` 和 `Logger.swift` 都通过 `Bundle.main.bundleIdentifier` 动态选择服务名/路径
- 构建层：脚本用 PlistBuddy 修改 Info.plist 副本，不修改源文件
- 迁移：Personal 版首次启动会从分发版（`com.voiceinput.mac`）一次性拷贝 Keychain 凭证 + UserDefaults 配置，由 `Config.migratePersonalFromDistributionIfNeeded` 实现，标记 key 为 `personalMigratedFromDistribution_v1`
- 角标渲染：`AppDelegate.isPersonalBuild` 在 `updateStatusIcon()` 中决定是否绘制紫色角标

**Version Display Requirements:**
- After every build, explicitly tell the user the new version number (e.g., "版本 1.0.0.5 (build 5)")
- Version is read from `Info.plist`: `CFBundleShortVersionString` + `CFBundleVersion`
- Version is displayed in the menu bar menu (via `Config.appVersion`)

**安装路径稳定性：**
两个版本各自的安装路径 MUST 保持稳定（个人版恒为 `~/Applications/VoiceInput Personal.app`，分发版恒为用户首次拖拽的位置），因为麦克风和 Accessibility 权限绑定到具体路径 + bundle ID。

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
- Sensitive credentials (App ID, Access Token, Boosting Table ID) stored as plain JSON at `~/Library/Application Support/<CFBundleName>/credentials.json` (chmod 0600) via `CredentialsStore.swift` —— 不用 Keychain，原因见下方 "Keychain: Don't Use It"
- Non-sensitive config (Resource ID, ASR mode) stored in UserDefaults
- Environment variables (`VOLC_APP_ID`, `VOLC_ACCESS_TOKEN`, `VOLC_BOOSTING_TABLE_ID`) can override stored values
- API endpoint: `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`（由 `asrMode` 派生）

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

1. **NEVER use ad-hoc `codesign --sign -`** — This changes the code identity on every build, causing macOS to re-request all permissions. The build script auto-detects Developer ID Application certificate (preferred) or Apple Development certificate to maintain a stable identity. Set `SIGNING_IDENTITY=none` to skip signing entirely.

2. **NEVER use `NSWorkspace.shared.open(bundleURL)` to activate apps** — Opening a `.app` bundle URL triggers `kTCCServiceSystemPolicyAppBundles` ("APP管理") permission. Use `app.activate(options: [.activateIgnoringOtherApps])` instead.

3. **NEVER add entitlements that require a Team ID** — For example, `keychain-access-groups` requires a real Apple Developer Team ID. With ad-hoc signing, this causes Error 163 (launchd refuses to spawn the app).

4. **NEVER change the installation path** — Permissions are tied to `~/Applications/VoiceInput.app`. Changing the path means re-requesting all permissions.

5. **NEVER delete the entire app bundle during install** — The build script only replaces the binary and Info.plist inside the existing bundle. Running `rm -rf VoiceInput.app` would destroy the permission association.

**Safe patterns:**
- Store sensitive credentials in Keychain with `kSecAttrAccessibleWhenUnlocked` + `SecAccessCreate(name, [] as CFArray, &access)` to create unrestricted ACL (avoids binding to cdhash)
- Use `app.activate(options:)` for app activation (no TCC permission needed)
- Keep the `VoiceInput.entitlements` file empty (just `<dict/>`)
- Only replace files inside the app bundle, never recreate the bundle from scratch

## Keychain: Don't Use It (Lessons Learned)

**结论**：在 Developer ID 签名 + 非沙盒 + 无 provisioning profile 条件下，macOS Keychain **没有**"不弹窗"的干净方案。本项目应避开 Keychain，凭证改存 `~/Library/Application Support/`。

**2026-04-23 实测验证了三条都走不通（曾错误地认为 Legacy ACL 有解）**：

1. **Legacy ACL `SecAccessCreate(name, [] as CFArray, &access)`** —— 曾误以为 `[]` = "any app can access without prompt"。**错了**。实际语义：
   - `nil` → "creator only"（绑 cdhash，rebuild 弹）
   - `[]` → "no trusted apps"，**任何 app 访问都弹 + 点"始终允许"后下次还弹**（partition list 机制）
   - 命令行 `security` 工具也会被弹（不同 partition）
   - 用户确认过：点"始终允许"下一次仍弹；同一次 run 里读多条会每条都弹

2. **`kSecUseDataProtectionKeychain: true`** —— Probe 返回 **-34018 `errSecMissingEntitlement`**，不管有没有 `kSecAttrAccessGroup` 都报错。Developer ID 签名不会自动授予任何 access group。

3. **加 `keychain-access-groups` entitlement** —— codesign 成功但启动 **Error 163 `Launchd job spawn failed`**。`keychain-access-groups` 需要 provisioning profile 声明该 access group，Developer ID 签名本身不带 profile。

**迁移 legacy 条目时的必要弹窗**：迁出 legacy Keychain 条目的唯一办法是 `SecItemCopyMatching`，它受 ACL 保护会弹窗。**不能 lazy 迁移**（会把弹窗分散到用户好几次启动里），必须在首次启动时一次性把所有 4 个 key 读完、写入新存储、`SecItemDelete`。用户最多要点 ~4 次"始终允许"，然后永不再弹。

**NEVER do:**
1. ~~"加 `keychain-access-groups` entitlement 或用 DPK"~~ —— 见上面 2/3 条，都坏掉。
2. **NEVER use partition list hack** (`security set-generic-password-partition-list`) —— 需要用户 login 密码交互、仍绑 cdhash、OS 升级后脆弱。
3. **NEVER delete old Keychain entries before verifying new write succeeded** — migration code that deletes first then writes can lose user credentials if the write fails.
4. **NEVER use `SecItemUpdate` to fix ACL** — `SecItemUpdate` on an entry with old ACL also triggers the Keychain popup. Instead use read → delete → re-add.

## Karabiner Hotkey Interaction (Lessons Learned)

When users remap keys with Karabiner Elements:
1. **Karabiner replaces keycode**: A Caps Lock mapped to `right_option` sends `keycode=61` (rightOption), NOT `keycode=57` (capsLock). Keycode-based filtering is impossible.
2. **Karabiner event sequence**: For Caps Lock → `left_control + right_option` mapping: `rightOption↓ → leftControl↓(~3ms later) → leftControl↑(~135ms later) → rightOption↑ → capsLock events (to_if_alone)`
3. **Don't use tolerance windows for otherMods detection**: A tolerance window with timer reset allows Karabiner's ~135ms modifier presence to be missed. Use immediate detection: any other modifier during pending = block immediately.
4. **pendingTriggerTime < 30ms filter**: Still needed to catch extremely fast Karabiner synthetic events that arrive as separate flagsChanged events within microseconds.

## Code Signing & Notarization

**Hardened runtime** is enabled on all builds (`codesign --options runtime`). This is required for Apple notarization but does NOT affect app functionality — VoiceInput uses no JIT, DYLD injection, or unsigned library loading.

**Local builds** (`build-and-install.sh`):
- Auto-detects signing certificate, preferring `Developer ID Application` over `Apple Development`
- Override with `SIGNING_IDENTITY` env var, or set to `none` to skip
- Hardened runtime is always enabled when signing

**CI releases** (`.github/workflows/release.yml`):
- Imports Developer ID certificate from GitHub Secrets into a temporary keychain
- Signs app bundle and DMG with hardened runtime
- Submits to Apple notarization via `notarytool` with App Store Connect API key
- Staples the notarization ticket to the DMG
- Falls back to unsigned build if secrets are not configured

**Local notarization** (`scripts/notarize.sh`):
- Helper script for manually notarizing a DMG
- Supports API Key auth (recommended) and Apple ID auth
- Usage: `./scripts/notarize.sh <path-to-dmg>`

**Required GitHub Secrets for CI signing:**

| Secret | Description |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | Base64-encoded .p12 certificate |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | .p12 export password |
| `NOTARIZE_API_KEY_ID` | App Store Connect API Key ID |
| `NOTARIZE_API_ISSUER_ID` | App Store Connect Issuer ID |
| `NOTARIZE_API_KEY_CONTENT` | Base64-encoded .p8 API key file |

**Entitlements**: `VoiceInput.entitlements` must contain `com.apple.security.device.audio-input = true`. Hardened runtime gates microphone access BEFORE TCC: without this entitlement, `AVCaptureDevice.requestAccess(for: .audio)` returns false in ~20ms silently (no TCC prompt, no DB write). Accessibility (TCC), Keychain (no ACL group), and networking still don't need entitlements. Do NOT add `keychain-access-groups` or App Sandbox entitlements — those require a provisioning profile, which breaks ad-hoc local signing.

**Debugging microphone permission that silently fails:**
1. Verify entitlement is embedded in the signed bundle (not just in the file): `codesign -d --entitlements - /path/to/app | grep audio-input`
2. Verify no stale `com.voiceinput.mac` registration with a different TeamID exists in LaunchServices: `lsregister -dump | grep -B1 -A4 voiceinput`. Orphan old-sign apps (e.g. `~/Applications/VoiceInput.app` from before the Personal rename) will conflict with the distribution version sharing the same bundle ID and cause TCC to reject silently. Delete them and unregister with `lsregister -u <path>`.

## Logging

All logs are written to `~/Library/Logs/VoiceInput.log` via `Logger.swift`. Users can access the log file via the menu bar → "打开日志文件".
