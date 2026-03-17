# VoiceInput

[English](README.md) | 简体中文

基于[火山引擎豆包](https://www.volcengine.com/product/speech/asr)流式语音识别的 macOS 菜单栏全局语音输入工具。

按下热键开始/停止录音，识别的文字会自动粘贴到当前输入框。

## 功能特性

- **全局热键** — 在任何应用中触发语音输入（默认：左 Option 键，可配置）
- **流式识别** — 通过火山引擎大模型语音识别实现实时转写
- **自动粘贴** — 识别的文字通过剪贴板 + Cmd+V 自动插入到光标位置
- **实时预览** — 光标附近的悬浮面板实时显示转写内容
- **编辑结果** — 点击悬浮面板可在插入前编辑文本
- **识别历史** — 从菜单栏查看历史转写记录
- **剪贴板保护** — 粘贴后自动恢复原剪贴板内容

## 系统要求

- macOS 13.0+
- [火山引擎](https://console.volcengine.com/speech)语音识别凭证（App ID + Access Token）

## 安装

```bash
git clone https://github.com/liuhao04/VoiceInput.git
cd VoiceInput
./scripts/build-and-install.sh
```

脚本会构建 release 版本并安装到 `~/Applications/VoiceInput.app`。如需自定义安装位置：

```bash
INSTALL_DIR="/Applications" ./scripts/build-and-install.sh
```

## 配置

### API 凭证

首次启动时，点击菜单栏图标 > **设置**，输入：

- **App ID** — 从火山引擎控制台获取
- **Access Token** — 从火山引擎控制台获取
- **Boosting Table ID**（可选）— 用于自定义热词识别

也可以在启动前设置环境变量：

```bash
export VOLC_APP_ID="your_app_id"
export VOLC_ACCESS_TOKEN="your_access_token"
export VOLC_BOOSTING_TABLE_ID="your_boosting_table_id"  # 可选
```

### 获取火山引擎凭证

1. 访问[火山引擎语音控制台](https://console.volcengine.com/speech)
2. 创建或选择一个应用以获取 App ID 和 Access Token
3. （可选）创建热词表以获取 Boosting Table ID

## 权限

应用需要两个 macOS 权限（首次运行时会提示）：

| 权限 | 用途 |
|---|---|
| **麦克风** | 采集音频用于语音识别 |
| **辅助功能** | 全局热键监听和 Cmd+V 粘贴模拟 |

## 技术栈

- Swift 5.9, macOS 13+
- AppKit（菜单栏 UI）
- AVFoundation（16kHz 单声道 16-bit PCM 音频采集）
- URLSession WebSocket（火山引擎二进制协议）
- Accessibility APIs（全局热键 + 粘贴模拟）

## 项目结构

```
Sources/VoiceInput/
  VoiceInputApp.swift      # 入口、AppDelegate、菜单栏、热键
  AudioCapture.swift        # 麦克风 → PCM 音频块
  VolcanoASR.swift          # 火山引擎 ASR WebSocket 客户端
  VoiceInputPanel.swift     # 悬浮转写面板
  PasteboardPaste.swift     # 剪贴板粘贴 + 恢复
  CursorLocator.swift       # 通过辅助功能 API 定位光标
  Config.swift              # 配置管理
  KeychainHelper.swift      # 安全凭证存储
  SettingsWindow.swift      # 设置窗口 UI
  HistoryWindow.swift       # 识别历史 UI
  Logger.swift              # 文件日志
```

## 测试

```bash
# 快速 CI 测试（构建 + 协议验证）
./scripts/ci-test.sh

# 使用模拟音频的端到端测试
./scripts/e2e-test-app.sh

# 使用真实麦克风的端到端测试（5 秒）
./scripts/e2e-test-mic.sh
```

## 许可证

[MIT](LICENSE)
