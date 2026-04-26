# VoiceInput 自动化测试系统使用指南

## 概览

完全自动化的测试系统，包含构建、功能测试、UI 验证、性能监控等全面测试能力。

## 快速开始

### 运行完整测试
```bash
./scripts/comprehensive-test.sh
```
- ✅ 12 项全面测试
- 📊 精美 HTML 报告
- 📸 自动截图
- 🔔 macOS 通知

### 运行 CI 测试（最快）
```bash
./scripts/ci-test.sh
```
- Python 协议验证
- Swift 编译检查
- 适合快速验证

### 运行 E2E 测试
```bash
# 模拟音频测试
./scripts/e2e-test-app.sh --distribution --skip-build

# 真实麦克风测试（5秒录音）
./scripts/e2e-test-mic.sh 5 --distribution --skip-build
```

### 推荐测试顺序
日常验证 Distribution 版时，按这个顺序跑：

```bash
# 1. 快速编译和协议检查
./scripts/ci-test.sh

# 2. 真实 app 粘贴路径，验证 TextEdit 注入和剪贴板恢复
./scripts/paste-smoke-test.sh --distribution --no-relaunch

# 3. mock 音频 E2E，验证 ASR 协议到 TextEdit 注入
./scripts/e2e-test-app.sh --distribution --skip-build

# 4. 真实麦克风 E2E，验证麦克风采集、ASR 和 TextEdit 注入
./scripts/e2e-test-mic.sh 10 --distribution --skip-build
```

Personal 版使用同一套脚本，把 `--distribution` 换成 `--personal`。需要先安装目标版本：

```bash
./scripts/build-and-install.sh --distribution-only
./scripts/build-and-install.sh --personal-only
```

### 持续测试模式
```bash
# 监控文件变化自动测试
./scripts/continuous-test.sh watch

# 定时测试（每 300 秒）
./scripts/continuous-test.sh continuous 300

# 单次运行
./scripts/continuous-test.sh once
```

## 测试脚本说明

| 脚本 | 功能 | 用途 |
|-----|------|------|
| `build-and-install.sh` | 构建并安装 | 开发时使用 |
| `ci-test.sh` | CI 快速测试 | Git hooks/CI |
| `e2e-test-app.sh` | E2E 模拟音频 | 功能验证 |
| `e2e-test-mic.sh` | E2E 真实麦克风 | 完整测试 |
| `auto-test-suite.sh` | 完整测试套件 | 全面验证 |
| `comprehensive-test.sh` | 综合测试 | 发布前测试 |
| `visual-test.py` | 视觉 UI 测试 | UI 验证 |
| `continuous-test.sh` | 持续测试 | 开发监控 |

## 测试输出

### 报告位置
```
/tmp/voiceinput_test_results/
├── report_*.html          # HTML 测试报告
├── screenshots/           # 截图
│   ├── *_menubar_*.png
│   ├── *_e2e_*.png
│   └── ...
└── *.log                  # 详细日志

/tmp/voiceinput_visual_tests/
└── visual_test_report_*.json  # JSON 结构化报告
```

### E2E 结果文件
E2E 脚本会写入：

```bash
/tmp/voiceinput_e2e_result.json
```

`e2e-test-mic.sh` 会额外写入麦克风采集诊断：

```json
{
  "diagnostics": {
    "pcmPackets": 104,
    "pcmBytes": 332320
  }
}
```

含义：
- `pcmPackets > 0` 且 `pcmBytes > 0`：App 已经采集并向 ASR 发送 PCM 音频。
- `pcmPackets = 0` 或 `pcmBytes = 0`：优先检查麦克风输入设备、权限、录音窗口时机。
- `pcmPackets > 0` 但 `recognized` 为空：音频送出去了，但 ASR 没返回可用文本；优先检查说话音量、语音时机、背景噪声和 ASR 服务状态。

### 查看报告
测试完成后会自动打开 HTML 报告，也可以手动打开：
```bash
open /tmp/voiceinput_test_results/report_*.html
```

## 测试前提

### 必需权限
1. **麦克风权限** - 用于音频采集测试
2. **辅助功能权限** - 用于 UI 自动化测试
3. **屏幕录制权限** - 用于截图（通常自动授予终端）

### 首次运行
首次运行可能需要授予权限：
```bash
# 系统偏好设置 → 安全性与隐私 → 隐私
# 勾选：
# - 辅助功能：Terminal/iTerm
# - 屏幕录制：Terminal/iTerm
```

## 开发工作流

### 1. 修改代码前
```bash
# 运行基准测试
./scripts/comprehensive-test.sh
```

### 2. 开发过程中
```bash
# 启动监控模式（自动检测变化并测试）
./scripts/continuous-test.sh watch
```
或者手动运行快速测试：
```bash
./scripts/ci-test.sh
```

### 3. 提交代码前
```bash
# 运行完整测试
./scripts/comprehensive-test.sh
```

### 4. 发布版本前
```bash
# 运行所有测试（包括真实麦克风）
./scripts/comprehensive-test.sh
./scripts/paste-smoke-test.sh --distribution --no-relaunch
./scripts/e2e-test-app.sh --distribution --skip-build
./scripts/e2e-test-mic.sh 10 --distribution --skip-build
```

## 测试覆盖

### 构建系统
- ✅ Swift 编译
- ✅ 版本号自动递增
- ✅ App bundle 创建
- ✅ 安装到固定路径
- ✅ 自动重启

### 协议层
- ✅ WebSocket 连接
- ✅ 二进制协议（header + payload）
- ✅ Gzip 压缩首包
- ✅ 音频流传输
- ✅ 识别结果接收

### 核心功能
- ✅ 麦克风采集（16kHz mono 16bit）
- ✅ 音频格式转换
- ✅ 流式识别
- ✅ 文字粘贴
- ✅ F5 热键（手动测试）

### UI
- ✅ 菜单栏图标
- ✅ 版本号显示
- ✅ 浮动面板
- ✅ 日志文件访问

### 系统集成
- ✅ 进程管理
- ✅ 日志记录
- ✅ 剪贴板操作
- ✅ 权限检查

## 故障排除

### 测试失败：找不到 VoiceInput 进程
**原因：** E2E 测试后 app 自动退出
**解决：** 重新启动 app
```bash
open /Applications/VoiceInput.app
# 或个人版：
open ~/Applications/VoiceInput\ Personal.app
```

### 测试失败：无法访问菜单栏
**原因：** 缺少辅助功能权限
**解决：** 授予终端辅助功能权限
```
系统偏好设置 → 安全性与隐私 → 隐私 → 辅助功能 → 勾选 Terminal
```

### 测试失败：Protocol test failed
**原因：** 网络问题或 API 配置错误
**解决：**
1. 检查网络连接
2. 验证 `Sources/VoiceInput/Config.swift` 中的 API 配置

### 真实麦克风 E2E 没有识别文字
先查看脚本输出里的 `诊断`，或打开 `/tmp/voiceinput_e2e_result.json`。

- `pcmPackets = 0` 或 `pcmBytes = 0`：测试期间没有采集到 PCM 数据。检查系统输入设备、麦克风权限，以及是否在录音窗口内说话。
- `pcmPackets > 0` 且 `recognized` 为空：音频已经发送给 ASR，但服务端没有返回文本。重新用更清晰、更长的句子测试；如果持续复现，再检查网络和 ASR 服务状态。
- `recognized` 有值但 `documentText` 为空：识别成功但粘贴失败，优先跑 `./scripts/paste-smoke-test.sh --distribution --no-relaunch`。

### Python 环境问题
**解决：** 重新创建虚拟环境
```bash
cd asr_test
rm -rf .venv
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## CI/CD 集成

### GitHub Actions 示例
```yaml
name: Test
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v2
      - name: Run tests
        run: ./scripts/ci-test.sh
```

### Git Hook 示例
```bash
# .git/hooks/pre-commit
#!/bin/bash
./scripts/ci-test.sh || {
    echo "❌ 测试失败，提交已取消"
    exit 1
}
```

## 性能基准

### 测试时间
- `ci-test.sh`: ~10 秒
- `e2e-test-app.sh`: ~15 秒
- `comprehensive-test.sh`: ~60 秒
- `e2e-test-mic.sh`: ~10 秒（5秒录音 + 5秒处理）

### 资源使用
- 内存：< 100MB（运行时）
- CPU：< 5%（空闲时）
- 磁盘：~250KB（app）

## 最佳实践

1. **频繁运行 CI 测试**：快速验证，适合开发时
2. **发布前运行完整测试**：确保所有功能正常
3. **使用监控模式开发**：实时反馈代码质量
4. **保留测试报告**：用于回归对比
5. **定期清理测试输出**：避免占用过多磁盘空间

```bash
# 清理测试输出
rm -rf /tmp/voiceinput_*
```

## 扩展测试

### 添加新测试
在 `comprehensive-test.sh` 中添加：
```bash
echo -e "${BLUE}[N/12]${NC} 新测试名称..."
if 测试命令; then
    record_test "测试名称" "pass" "详细信息"
else
    record_test "测试名称" "fail" "失败原因"
fi
```

### 自定义测试参数
编辑脚本顶部的配置变量。

## 支持

遇到问题？
1. 查看 `TEST_REPORT.md` 了解最新测试结果
2. 检查 `/tmp/voiceinput_*.log` 详细日志
3. 运行 `./scripts/ci-test.sh` 快速诊断

---

**自动化测试让开发更安心！🚀**
