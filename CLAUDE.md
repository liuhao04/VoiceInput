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

**2026-08-01 起只维护 Distribution 版。** Personal 版停止维护/构建/启动/使用，
app 仍留在 `~/Applications/VoiceInput Personal.app`（未删除），但不再更新。
两个版本从同一份代码构建、功能完全相同，唯一差别是菜单栏的紫色角标，日常并存没有收益。
`./scripts/build-and-install.sh` 默认只装 Distribution；要装 Personal 用 `--personal` / `--personal-only`。

下表保留两版对照，供理解隔离机制：

| | Personal 版（个人开发） | Distribution 版（分发 / 本地对照） |
|---|---|---|
| Bundle ID | `com.voiceinput.mac.personal` | `com.voiceinput.mac` |
| 安装路径 | `~/Applications/VoiceInput Personal.app` | `/Applications/VoiceInput.app`（用户拖拽或本机原地更新） |
| 构建脚本 | `./scripts/build-and-install.sh --personal` | `./scripts/build-and-install.sh`（默认）/ `build-dmg.sh` 产公证 DMG |
| 菜单栏图标 | mic.fill + 紫色角标 | mic.fill（template，自适配明暗模式） |
| Keychain service | `com.voiceinput.mac.personal` | `com.voiceinput.mac` |
| UserDefaults domain | `com.voiceinput.mac.personal` | `com.voiceinput.mac` |
| Log file | `~/Library/Logs/VoiceInput Personal.log` | `~/Library/Logs/VoiceInput.log` |
| TCC 权限 | 独立授权 | 独立授权 |
| 用途 | ~~日常自用~~（已停用） | 日常自用 + 发给朋友/公测 |

两个版本可以同时安装、同时运行，互不干扰。

**每次代码改动 MUST 跑这个（默认只装 Distribution）：**
```bash
./scripts/build-and-install.sh
```
1. 自动递增 `CFBundleVersion`
2. 构建一次 release
3. **Distribution 版**（默认且唯一）：原地替换 `Contents/MacOS/VoiceInput` 和 `Contents/Info.plist`（保留 bundle 路径以保留 TCC 权限）、PlistBuddy 写回 `com.voiceinput.mac` + `VoiceInput`、Developer ID 签名、按路径 kill+open。bundle 不存在时自动创建
4. **Personal 版**（需显式 `--personal` / `--personal-only`）：复制到 `~/Applications/VoiceInput Personal.app`、改 Bundle ID/显示名、同一证书签名、kill+open
5. Flag：`--personal-only` / `--distribution-only` / `--personal`（两个都装）/ `--both`

**Distribution 版正式分发（要公证时跑）：**
```bash
./scripts/build-dmg.sh                 # 签名 + 公证（需要 NOTARIZE_API_KEY_* 环境变量）
./scripts/build-dmg.sh --skip-notarize # 仅签名
```
输出：`dist/VoiceInput-<version>.dmg`，用户双击安装。

**Personal/Distribution 隔离机制：**
- 代码层：`CredentialsStore.swift` 通过 `CFBundleName` 选择 `Application Support` 凭证路径，`Logger.swift` 通过 bundle 信息选择日志路径
- 构建层：脚本用 PlistBuddy 修改 Info.plist 副本，不修改源文件
- 迁移：Personal 版首次启动会从分发版（`com.voiceinput.mac` / `VoiceInput`）一次性拷贝 UserDefaults 配置和缺失的 `credentials.json` 凭证；凭证迁移使用独立标记 `personalCredentialsMigratedFromDistribution_v1`，不会覆盖 Personal 已保存凭证
- 角标渲染：`AppDelegate.isPersonalBuild` 在 `updateStatusIcon()` 中决定是否绘制紫色角标

**Version Display Requirements:**
- After every build, explicitly tell the user the new version number (e.g., "版本 1.0.0.5 (build 5)")
- Version is read from `Info.plist`: `CFBundleShortVersionString` + `CFBundleVersion`
- Version is displayed in the menu bar menu (via `Config.appVersion`)

**🔴 guest 侧的路径陷阱（客居架构下必读）：**
只有 `/Users` 是 guest 与宿主的共享挂载。**`/Applications` 不是** —— 在 guest 里 `ls /Applications`
看到的是 Linux VM 自己的目录，宿主装没装 app 完全看不出来。
2026-08-01 发现 `build-and-install.sh` 因此长期误判：`[ ! -d "$DIST_APP_PATH" ]` 在 guest 恒为真，
于是每次构建都打印"不存在，跳过 Distribution 版安装"，导致分发版从 2026-04-17 起 3 个半月没被更新过，
而用户一直在用那个旧构建。现在该段所有文件操作（test/mkdir/cp）都经 `host_exec` 在宿主执行。
判断宿主上的东西一律用 `host_exec`，别用 guest 本地的 test/ls。

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
6. **TextCorrector.swift**: 可选的大模型修正（见下方 "AI 修正"）
7. **PasteboardPaste.swift**: On stop, activates last frontmost app and simulates Cmd+V

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

## AI 修正（TextCorrector.swift）

可选功能，默认关闭。产品方案见 `docs/ai-correction-product-spec.md`（含未实现的第二、三步）。

**两档模式**
- 单击触发键 = **精修档**：ASR → 替换规则 → 大模型修正 → 粘贴
- 录音刚开始的窗口内**再做一次同样的触发手势** = 本次**降为快速档**：直接粘贴，不修正

降档判定放在 `toggleRecording()` 的 300ms 防抖**之前**（连续两次触发天然落在防抖窗口里）。
之所以用"录音开始后的短窗口"而不是延迟启动来区分，是因为档位只在停止录音时才起作用，
第二次触发可以在录音已开始后到达，这样启动和停止都是零额外延迟。

窗口长度看触发方式：**单击触发 0.7s**（用户心里的"双击 = 快速档"就是"单击开始 + 紧接着再点一下"），
双击触发 1.2s（用户要再完成一整个双击，需要更久）。0.7s 而不是更短，是因为触发本身带 0.2s 确认延迟。
用户 2026-08-01 明确要的操作模型：**单击 = 精修档，双击 = 快速档**，对应 `triggerActivation = singleTap`。
**不要把降档限定成只在 singleTap 下生效** —— 曾经这么写过，结果用双击触发的用户
（`triggerActivation = doubleTap`）完全用不上快速档，且没有任何提示。

**不可违反的约束**
- **先修正再粘贴**。绝不改写已经贴出去的文本（要模拟选中+删除+重粘，失败会破坏用户文档）
- **任何失败都降级为粘贴原文**：无 key、网络失败、超时、响应异常、用户中断，全部走 `insertFinalText(原文)`
- `Config.correctionTimeout`（默认 6s）是硬上限。`TextCorrector.correct` 用本地定时器兜底，
  即使 URLSession 不回调也保证在预算内解除面板等待
- ESC / 再按触发键 = 放弃修正、立即粘贴原文（不是丢弃文本）

**GLM 接入的两条硬经验**（来自 ai-info 项目实测，不要重新踩）
- **必须关 thinking**：payload 里带 `"thinking": {"type": "disabled"}`。GLM-4.7 及以后默认是
  thinking 模型，不关会烧上百 reasoning token、延迟几十秒，且 thinking 吃 max_tokens 预算导致输出截断
- **不要用任何 flash 系模型**。免费 `glm-4.7-flash` 有共享池拥塞（429 code 1305），
  请求会被拖到分钟级；付费 `glm-4.7-flashx` 在本账号 2026-07-31 实测 9/9 返回
  429 code **1113 余额不足或无可用资源包**（glm-5.2 同一 key 正常 200）。
  选中不可用模型等于每次白等一个往返再降级回原文。有测试守着，要加回来先用真实 key 打一次确认真的通
- 因此 GLM 的三个质量档**全部映射到 `glm-5.2`**，设置界面据 `hasModelChoice`
  自动隐藏档位选择（只有一个模型时摆三个档是假选择）。枚举保留是给 Claude API 用的

**prompt 的两个实测结论**（改 prompt 前先看）
- 分段必须写重。只说"按语义分段换行"时模型一个换行都不给，159 字口述照样堆成一整段；
  加上"宁可多分一段，也不要堆成一坨"之后才真的分段
- 末尾结束标点要显式禁止。语音结果常被粘进搜索框和命令行，尾巴上一个句号很碍事。
  prompt 里禁止 + `normalizeCorrectedText` 本地兜底（这是确定性处理，符合"本地只做确定性处理"的通则）

**设计通则**：本地只做确定性的、无歧义的处理；任何需要语义判断的一律交给模型。
反例：本地赘词词表、`<40字不分段` 字符阈值、把映射式替换规则喂给模型。

**欠费是静默失败**：修正失败一律降级为粘贴原文，用户只会觉得"修正好像没生效"。
所以 `CorrectionError.insufficientBalance` 单独成一类（`isArrears` 认 code 1113 和余额类文案），
设置界面有「测试」按钮打一次真实请求，把 key 错、欠费、网络不通区分开。

**配置**：`correctionEnabled` / `correctionService` / `correctionQuality` / `correctionTimeout`
存 UserDefaults；API Key 走 `CredentialsStore`（`glmApiKey`），可被环境变量 `GLM_API_KEY` 覆盖。
设置界面第 4 个 Tab。

**专名词典**（`Config.properNouns`，UserDefaults）：用户自己声明的专有名词，**只有词、没有映射**。
与替换规则的区别是本质的：替换规则 `cloud → claude` 是无条件强制指令，用户日常也说 cloud 时就误伤；
词典只告诉模型"这些词存在于这个人的世界里"，由模型按语境判断该不该用。规则做不了语境判断，模型能。
**绝不能把替换规则的映射关系送进 prompt** —— 那等于把规则的机械缺陷传染给模型，自废武功。

实测（2026-08-02，`田轨号劫` → 期望 `天轨浩劫`）：
- 无词典无上文 → 模型**自信编造** `《铁轨号劫》`
- **只给词典（无上文）→ 修对**。所以词典解决冷启动，上下文只解决重复出现
- 词典在但本次文本与它无关 → 不会硬套（prompt 里明确写了"未必出现在本次文本中"）

设置界面第 3 个 Tab「专名词典」，替换规则降级为其中折叠的「高级：强制替换」并附误伤提示。
待做：同步到火山热词表（从识别源头干预），需先确认火山接口支持按 ID 读写热词内容。

**上下文**：最近 30 条**实际采纳**的文本，持久化在 `Config.recentContextEntries`（UserDefaults），
带时间戳，超过 `TextCorrector.contextMaxAge`（2 小时）的条目自动失效，连续重复不重记。
30 条约 1~2k prompt token，实测没有带来稳定的延迟增长（同规模两次请求 2.0s / 1.2s，差异是服务端抖动）。
存的永远是最终版本，优先级天然是**用户手改 > 模型修正 > ASR 原文**，因为写入点
（`insertFinalText` / `handleEditingFinished` / `handleEditingCancelled`）都在文本被采用之后。
刻意不读识别历史文件——历史默认存 iCloud，同步阻塞会拖慢粘贴这条关键路径。

**上下文只治"重复出现"，治不了"第一次"**（2026-08-01 实测）：
- 通用技术术语（`无头克罗姆` → `无头 Chrome`）模型自带知识，**无上文也能修对**
- 私有专名（`田轨号劫` → `《天轨浩劫》`）**无上文必错**，而且失败方式是模型
  **自信地编一个** `《铁轨号劫》`。prompt 里的"拿不准就保持原样"挡不住这种看起来合理的猜测。
  有上文才修对。
→ 所以私有专名的正解是**先声明**（产品方案第二步的专名词典 + 火山热词表），
  不是等它偶然蒙对一次再靠上下文维持。上下文是巩固机制，不是冷启动机制。

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

4. **NEVER change the installation path** — Permissions are tied to the installed app path (`~/Applications/VoiceInput Personal.app` for Personal, `/Applications/VoiceInput.app` or the user's dragged location for Distribution). Changing the path means re-requesting all permissions.

5. **NEVER delete the entire app bundle during install** — The build script only replaces the binary and Info.plist inside the existing bundle. Running `rm -rf VoiceInput.app` would destroy the permission association.

**Safe patterns:**
- Store sensitive credentials in `~/Library/Application Support/<CFBundleName>/credentials.json` with file mode `0600`; do not move them back to Keychain
- Use `app.activate(options:)` for app activation (no TCC permission needed)
- Keep `VoiceInput.entitlements` limited to required non-profile entitlements such as `com.apple.security.device.audio-input`
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
