# 隐私政策 / Privacy Policy

> 最后更新：2026-04-23

[English](#english) | 中文

VoiceInput 是一个开源的 macOS 菜单栏语音输入工具。本政策说明本应用在本地和传输过程中如何处理你的数据。

## 数据在哪里、归谁处理

| 数据 | 本地存储 | 上传 | 备注 |
|---|---|---|---|
| **麦克风音频** | 不存储 | 仅在录音过程中实时加密流式发送给火山引擎 ASR 服务完成识别 | 录音停止后内存中的音频即被释放；本应用不会将完整录音写入磁盘，也不会将音频发送到除火山引擎之外的任何服务器 |
| **识别结果文本** | `~/Library/Mobile Documents/com~apple~CloudDocs/VoiceInput/history/` 下的 JSONL 历史文件 | 不上传 | 位于 iCloud Drive 目录，是否同步到 Apple iCloud 由你的 macOS 系统设置决定（不是本应用的行为）。你可以随时删除该目录清空历史 |
| **凭证**（火山引擎 App ID / Access Token / Resource ID / 热词表 ID） | `~/Library/Application Support/VoiceInput/credentials.json`（权限 `0600`） | 不上传 | 仅在调用火山引擎 API 时作为身份认证头发送给火山引擎 |
| **应用设置**（触发键、快捷键、识别模式等） | UserDefaults（`com.voiceinput.mac.plist`） | 不上传 | — |
| **本地日志** | `~/Library/Logs/VoiceInput.log` | 不上传 | 记录连接状态、错误信息、版本号等调试信息。可从菜单栏 > 打开日志文件查看内容 |

## 本应用不收集

- ❌ 不收集任何用于识别个人身份的信息
- ❌ 不内置分析、埋点、遥测、崩溃上报（Crash Reporter）
- ❌ 不使用第三方 SDK 追踪用户行为
- ❌ 不在后台上传任何数据到作者控制的服务器（本项目没有任何服务端组件）

## 第三方服务：火山引擎豆包 ASR

本应用的语音识别功能依赖 [火山引擎](https://www.volcengine.com/) 的语音识别 API。当你按下触发键开始录音时：

1. 麦克风采集的音频经过本地降采样（16 kHz / 单声道 / 16-bit PCM）
2. 通过 TLS 加密的 WebSocket 连接（`wss://openspeech.bytedance.com`）发送给火山引擎
3. 火山引擎返回识别文本，结果在本地显示并插入到当前输入框

音频数据在火山引擎侧的处理方式请参考 [火山引擎隐私政策](https://www.volcengine.com/docs/6256/64902) 以及《[语音技术产品服务协议](https://www.volcengine.com/docs/6561/135969)》。火山引擎是独立于本应用的服务商，对其处理行为我们不承担责任。

## 系统权限

本应用需要以下 macOS 权限，用途如下：

| 权限 | 用途 |
|---|---|
| 麦克风 | 录音用于识别，不录音时不读取 |
| 辅助功能（Accessibility） | 监听全局触发键 / 模拟 `Cmd+V` 将识别结果粘贴到前台应用 |

系统弹窗会在首次使用时请求授权。拒绝后可以在「系统设置 → 隐私与安全性」里再次授予或撤销。

## 你的控制权

- **卸载**：删除 `VoiceInput.app` 即卸载。可同时清理下列目录以移除所有本地数据：
  - `~/Library/Application Support/VoiceInput/`（凭证）
  - `~/Library/Mobile Documents/com~apple~CloudDocs/VoiceInput/history/`（识别历史）
  - `~/Library/Logs/VoiceInput.log`（日志）
- **清空识别历史**：手动删除 `history/` 目录中的 JSONL 文件
- **撤销系统权限**：在「系统设置 → 隐私与安全性 → 麦克风 / 辅助功能」中解除授权

## 变更

本政策的任何变更将通过更新本文件并在 [CHANGELOG.md](../CHANGELOG.md) 中公告。最后更新时间见页首。

## 联系

有问题请通过 [GitHub Issues](https://github.com/liuhao04/VoiceInput/issues) 提交反馈。

---

<a id="english"></a>

## English Summary

VoiceInput is an open-source macOS menu bar voice-to-text tool. This policy describes how the app handles your data locally and in transit.

- **Microphone audio** is streamed in real time over TLS WebSocket to Volcano Engine's ASR service for transcription. Audio is **not written to disk** by the app. It is released from memory after each recording.
- **Transcribed text** is stored locally under `~/Library/Mobile Documents/com~apple~CloudDocs/VoiceInput/history/` as JSONL history files. Whether this directory syncs to Apple iCloud is controlled by your macOS system settings, not by this app. You can delete the directory at any time.
- **Credentials** (Volcano Engine App ID / Access Token / Resource ID / Boosting Table ID) are stored locally at `~/Library/Application Support/VoiceInput/credentials.json` (chmod `0600`) and only sent to Volcano Engine for API authentication.
- **Logs** (`~/Library/Logs/VoiceInput.log`) contain connection status, errors, and version info. They are not uploaded.
- **No analytics, telemetry, or crash reporting** of any kind. The project has no server component controlled by the author.

### Third-party service

Audio data is sent to [Volcano Engine](https://www.volcengine.com/)'s ASR API for recognition. Their data handling is governed by the [Volcano Engine Privacy Policy](https://www.volcengine.com/docs/6256/64902) and [Speech Product Service Agreement](https://www.volcengine.com/docs/6561/135969). Volcano Engine is an independent service provider; we are not responsible for their practices.

### macOS permissions

- **Microphone** — required to capture audio during recording.
- **Accessibility** — required for global hotkey monitoring and simulating `Cmd+V` to paste recognized text.

### Your control

- Uninstall by removing `VoiceInput.app`. To wipe all local data, also remove `~/Library/Application Support/VoiceInput/`, `~/Library/Mobile Documents/com~apple~CloudDocs/VoiceInput/history/`, and `~/Library/Logs/VoiceInput.log`.
- Revoke system permissions at any time from **System Settings → Privacy & Security**.

### Contact

Open an issue at [GitHub Issues](https://github.com/liuhao04/VoiceInput/issues).
