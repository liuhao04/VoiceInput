# VoiceInput 开源调研报告

> 调研日期：2026-03-12

## 一、同类开源项目竞品分析

### macOS 语音输入类开源项目

| 项目 | Stars | 语言 | 识别引擎 | 许可证 | 特点 |
|------|-------|------|---------|--------|------|
| [finnvoor/yap](https://github.com/finnvoor/yap) | 1,380 | Swift | Apple Speech.framework | CC0 | CLI 工具，macOS 26 原生，纯离线 |
| [sveinbjornt/hear](https://github.com/sveinbjornt/hear) | 639 | ObjC | Apple 内置识别 | — | CLI，macOS 原生语音识别 |
| [watzon/pindrop](https://github.com/watzon/pindrop) | 331 | Swift | WhisperKit (本地) | MIT | **最接近本项目**，菜单栏 app，本地离线 |
| [liamadsr/dial8](https://github.com/liamadsr/dial8-open-source) | 179 | Swift | 本地模型 | — | 定位为 Wispr Flow 的开源替代 |
| [ykdojo/super-voice-assistant](https://github.com/ykdojo/super-voice-assistant) | 145 | Swift | WhisperKit/Gemini | — | 全局热键 + 截屏识别 |
| [whisper-key-local](https://github.com/PinW/whisper-key-local) | 108 | Python | Whisper (本地) | — | 跨平台，全局热键 |
| [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac) | 95 | Swift | WhisperKit (本地) | GPL-3.0 | 完全离线，隐私优先 |
| [TransFlow](https://github.com/Cyronlee/TransFlow) | 65 | Swift | 本地模型 | — | 实时转录 + 翻译，离线 |

### 竞品趋势

- **主流方向是「本地/离线」**：几乎所有竞品都主打 WhisperKit 或 Apple 原生识别
- **核心卖点是「隐私」**：语音数据不出设备
- **中文支持普遍较弱**：Whisper 在中文上表现远不如商业服务

### VoiceInput 的差异化

- 使用火山引擎豆包大模型，**中文识别质量远超 Whisper**
- 真正的流式识别（逐字返回），而非 Whisper 的 30 秒窗口
- 支持热词增强（boosting_table_id）
- 劣势：依赖云端 API、需要用户注册火山引擎账号

---

## 二、WhisperKit 介绍

### 基本信息

- **开发者**：Argmax, Inc.（成立于 2023 年 11 月）
- **GitHub**: https://github.com/argmaxinc/WhisperKit （5,772 stars）
- **许可证**：MIT（完全免费，可商用）
- **最新版本**：v0.16.0（2026-03-03）
- **本质**：将 OpenAI Whisper 模型转换为 Apple CoreML 格式，在 Apple 设备上本地运行

### 支持的模型

| 模型 | 参数量 | 大小 | 多语言 |
|------|-------|------|--------|
| whisper-tiny | 39M | ~75 MB | 99 种语言 |
| whisper-base | 74M | ~142 MB | 99 种语言 |
| whisper-small | 244M | ~466 MB | 99 种语言 |
| whisper-medium | 769M | ~1.5 GB | 99 种语言 |
| whisper-large-v2 | 1550M | ~2.9 GB | 99 种语言 |
| whisper-large-v3 | 1550M | ~2.9 GB | 99 种语言 |
| whisper-large-v3-turbo | 809M | ~1.6 GB | 99 种语言 |

另有量化版本（体积更小，精度略降）。

### 技术架构

- 使用 **Apple CoreML** 作为推理后端
- **Apple Neural Engine (ANE)** 加速编码器和解码器（macOS 14+ 完整支持）
- 支持平台：macOS 13+、iOS 16+、watchOS 10+、visionOS 1.0+
- 提供实时流式转录（AudioStreamTranscriber）、VAD（语音活动检测）、词级时间戳

### 性能基准（M4 Mac mini）

| 模型 | WER | 速度（x 实时） |
|------|-----|---------------|
| whisper-base.en | 15.2% | 111x |
| whisper-small.en | 12.8% | 35x |
| Apple SpeechAnalyzer | 14.0% | 70x |

### 关键局限

1. **30 秒窗口架构**：不是真正的流式，有固有延迟
2. **中文质量差距大**：通用多语言模型，未针对中文优化
3. **首次加载慢**：CoreML 需要针对设备编译模型
4. **内存占用高**：large-v3 需要 3+ GB RAM
5. **无热词增强**：不支持自定义词汇表
6. **幻觉问题**：静音时可能凭空生成文字
7. **无 ITN（反向文本规范化）**：如不能可靠地将「二十三」转为「23」

### 「隐私叙事」解释

WhisperKit 阵营的核心营销策略是**数据隐私**：

> "你的语音数据完全在设备上处理，绝不上传到任何服务器。"

这对欧美用户（尤其是企业用户、GDPR 合规场景）非常有吸引力。所有竞品（pindrop、TypeWhisper、dial8）都在 README 中突出强调 "privacy-first"、"no cloud"、"fully offline"。

VoiceInput 使用云端 API，在这个叙事下天然处于劣势。但对中文用户来说，**识别准确率远比隐私更重要** — 这是不同市场的不同需求。

---

## 三、中文 ASR 效果对比

### 数据来源

**SpeechColab（SpeechIO）中文 ASR 排行榜**
- GitHub: https://github.com/SpeechColab/Leaderboard
- 业内公认的中文语音识别评测平台
- 46 个真实场景测试集，涵盖：新闻播报、直播带货、播客、在线教育、相声脱口秀、方言电影等
- 评测指标：CER（字错误率，Character Error Rate），越低越好

### 商业中文 ASR 服务排行

#### 简单场景（ZH00001~ZH00026：标准普通话，新闻/教育/播客等）

| 排名 | 服务商 | CER | 测试时间 |
|------|--------|-----|---------|
| 1 | 喜马拉雅 | **1.72%** | 2025.01 |
| 2 | 阿里云（文件转写） | **1.80%** | 2025.01 |
| 3 | 微软 Azure（离线转写） | 1.95% | 2025.01 |
| 4 | 讯飞（转写） | 3.01% | 2025.01 |
| 5 | 腾讯云 | 3.20% | 2025.01 |
| 6 | 思必驰 | 3.61% | 2025.01 |
| 7 | 百度（极速版） | 7.30% | 2025.01 |

#### 困难场景（ZH00027~ZH00046：方言、口音、电影、歌词等）

| 排名 | 服务商 | CER | 测试时间 |
|------|--------|-----|---------|
| 1 | 微软 Azure（离线转写） | **5.26%** | 2025.01 |
| 2 | 喜马拉雅 | 6.89% | 2025.01 |
| 3 | 阿里云（文件转写） | 6.92% | 2025.01 |
| 4 | 腾讯云 | 7.81% | 2025.01 |
| 5 | 讯飞（转写） | 8.70% | 2025.01 |
| 6 | 思必驰 | 10.42% | 2025.01 |
| 7 | 百度（极速版） | 16.23% | 2025.01 |

#### 全部场景综合（ZH00001~ZH00046）

| 排名 | 服务商 | CER | 测试时间 |
|------|--------|-----|---------|
| 1 | 微软 Azure（离线转写） | **2.99%** | 2025.01 |
| 2 | 喜马拉雅 | 3.35% | 2025.01 |
| 3 | 阿里云（文件转写） | 3.40% | 2025.01 |
| 4 | 腾讯云 | 4.64% | 2025.01 |
| 5 | 讯飞（转写） | 4.80% | 2025.01 |
| 6 | 思必驰 | 5.75% | 2025.01 |
| 7 | 百度（极速版） | 10.10% | 2025.01 |

> **注：** 火山引擎/豆包未在 SpeechColab 排行榜中。其实测数据见下方 Seed-ASR 论文结果。

### 火山引擎 Seed-ASR 官方评测结果

**论文来源**：[Seed-ASR: Understanding Diverse Speech and Contexts with LLM-based Speech Recognition](https://arxiv.org/abs/2407.04675)（2024.07，字节跳动）

Seed-ASR 是火山引擎豆包语音识别的底层模型。论文公布了在中文公开数据集上与其他模型的对比：

#### Table 3：中文公开数据集 CER（%）对比

| 测试集 | Paraformer-large | Qwen-Audio | Hubert+Baichuan2 | **Seed-ASR (CN)** |
|--------|-----------------|------------|-----------------|-------------------|
| AISHELL-1 test | 1.68 | 1.3 | 0.95 | **0.68** |
| AISHELL-2 Android | 3.13 | 3.3 | 3.5 (avg) | **2.27** |
| AISHELL-2 iOS | 2.85 | 3.1 | — | **2.27** |
| AISHELL-2 Mic | 3.06 | 3.3 | — | **2.28** |
| WenetSpeech test_net | 6.74 | 9.5 | 6.06 | **4.66** |
| WenetSpeech test_meeting | 6.97 | 10.87 | 6.26 | **5.69** |
| **6 集平均** | 4.07 | 5.23 | 3.96 | **2.98** |

> Seed-ASR (CN) 相比其他已发布模型，**平均 CER 降低 24%-40%**。

#### Table 4：多领域/视频/专有名词评测

| 模型 | 多领域 WER(%) | 视频 7 集平均 WER(%) | 专有名词 F1(%) |
|------|-------------|-------------------|--------------|
| Transducer E2E (300M+) | 3.68 | 3.92 | 90.42 |
| Paraformer-large | 5.23 | 5.97 | 87.99 |
| **Seed-ASR (CN)** | **1.94** | **2.70** | **93.72** |

#### Table 5：中文方言评测（13 种方言）

| 模型 | 13 种方言平均 WER(%) |
|------|-------------------|
| Finetuned Whisper Medium-v2 | 21.68 |
| **Seed-ASR (CN)** | **19.09** |

> 即使在方言上，Seed-ASR 也比同数据微调的 Whisper Medium-v2 低 11.4%（相对降幅）。

#### Table 6：中文口音评测（11 种口音）

| 模型 | 11 种口音平均 WER(%) |
|------|-------------------|
| Transducer E2E | 13.74 |
| Seed-ASR (CN)（无口音数据） | 5.90 |
| **Seed-ASR (CN)** | **4.96** |

### Whisper 在中文公开数据集上的表现

论文中未直接对比 Whisper 在标准中文数据集上的完整结果，但从社区测试和学术论文汇总：

| 模型 | AISHELL-1 CER | 说明 |
|------|--------------|------|
| **Seed-ASR (CN)** | **0.68%** | 火山引擎论文数据 |
| Hubert+Baichuan2 | 0.95% | 学术论文数据 |
| Qwen-Audio | 1.3% | 阿里论文数据 |
| Paraformer-large | 1.68% | 阿里达摩院开源模型 |
| Whisper large-v3 | ~7-8%（推测） | 社区测试，无官方中文数据 |
| Whisper large-v2 | ~8-10%（推测） | 社区测试 |
| Whisper small | ~15-20%（推测） | 中文勉强可用 |
| Whisper tiny/base | ~25%+（推测） | 中文几乎不可用 |

> **注意**：Whisper 的中文 CER 数据标注为「推测」，因为 OpenAI 未公布 AISHELL-1 上的官方数据。AISHELL-1 是最简单的中文测试集（安静环境标准普通话朗读），真实场景差距会更大。

### 对比总结

```
AISHELL-1 CER（中文标准测试集，越低越好）：

Seed-ASR (CN)    0.68%   ██
Hubert+Baichuan2 0.95%   ███
Qwen-Audio       1.30%   ████
Paraformer-large 1.68%   █████
Whisper large-v3 ~7-8%   ████████████████████████
Whisper small    ~15-20% ████████████████████████████████████████████████
```

**结论**：
1. **Seed-ASR（火山引擎豆包）在中文识别上是目前公开数据中最强的模型**，AISHELL-1 CER 仅 0.68%
2. **Whisper large-v3 的中文 CER 约为 Seed-ASR 的 10-12 倍**（~7% vs 0.68%）
3. 在更复杂的场景（多领域、方言、口音）上，差距更大
4. 这是 VoiceInput 相对于 WhisperKit 竞品的核心竞争力 — 不是同一量级的识别效果

---

## 四、开源策略建议

### 推荐方案：开源核心 + 托管 API 服务

1. **开源代码**，凭证改为用户自行配置
2. 提供「开箱即用」付费选项：用户订阅 API 代理服务，无需注册火山引擎
3. 强调中文识别质量优势，与 WhisperKit 竞品形成差异化

### 开源前必须完成的工作

- [ ] 移除硬编码 API 凭证（Config.swift、asr_test/config.py），改为环境变量/配置文件
- [ ] 从 git 历史中清除凭证，轮换 token
- [x] 添加 .gitignore（排除 .build/、.swiftpm/、.venv/ 等）
- [x] 添加 LICENSE 文件（推荐 MIT）
- [x] 清理个人路径（README.md、build 脚本中的硬编码路径）
- [x] 改善 README（中英双语，添加截图/GIF，说明如何获取 API 凭证）
- [x] 移除不应公开的文件（.claude/、.cursor/、TEST_REPORT.md 已加入 .gitignore）
