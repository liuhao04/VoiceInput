# 中文语音识别结果中多余空格问题调研

## 问题描述

使用火山引擎豆包大模型 ASR (`bigmodel_async`) 进行中文语音识别时，输出文本中偶尔出现不当空格。例如：

- `因为 你现在的识别涉及二遍识别` — "因为"和"你"之间有多余空格
- `什么 VAD 的时间间隔` — 英文缩写前后的空格（此为合理行为）

## 根因分析

### 1. 空格来自服务端，非客户端拼接

客户端代码中，`VolcanoASR.swift` 直接从服务端 JSON 取 `result.text` 原样回传，`VoiceInputApp.swift` 使用 `accumulatedText = replaced`（覆盖而非追加）。空格 100% 来自火山引擎服务端。

### 2. 二遍识别不纠正空格

对比日志中一遍结果（flags=0x1）和二遍结果（flags=0x3），"因为 你"的空格在两者中完全一致。`enable_nonstream` 二遍识别主要优化字词准确率（纠正同音字、优化标点），不处理空格排版。

### 3. VAD 分段的间接影响

`end_window_size: 3000`（3秒）控制 VAD 判停。日志中"修复方案"到"因为"之间停顿约 2.5 秒，虽未超过阈值，但可能触发了服务端内部的"软分段"，导致分段边界处产生空格。

### 4. 大模型 ASR 的共性行为

ASR 大模型训练语料中，中英混排文本在语言边界通常有空格。模型学到了这个模式后会过度泛化——在纯中文语境下的语义停顿处也可能插入空格。

## 业界调研

### 这是行业共性问题

| 项目/平台 | 问题描述 | 解决方案 |
|-----------|---------|---------|
| Apple macOS 自带语音输入 | 中文输入产生多余空格 ([知乎](https://www.zhihu.com/question/640511040)) | 无官方解决方案 |
| CapsWriter-Offline | v0.4 和 v2.3 专门优化"中英混排空格" ([GitHub](https://github.com/HaujetZhao/CapsWriter-Offline)) | 客户端正则后处理 |
| LazyTyper | 语音识别口语化问题含空格 ([Issue #4](https://github.com/oldcai/LazyTyper-releases/issues/4)) | LLM 后处理或正则 |
| Paraformer-large | 输出含"多余空格、零宽字符" ([CSDN](https://blog.csdn.net/weixin_42146230/article/details/157351020)) | 正则清洗脚本 |

### 火山引擎无官方参数控制空格

查阅火山引擎豆包语音 [参数说明](https://www.volcengine.com/docs/6561/79823) 和 [大模型流式API文档](https://www.volcengine.com/docs/6561/1354869)，没有找到任何控制空格行为的参数。`enable_itn`（逆文本正则化）和 `enable_ddc`（语义顺滑）也不处理空格。

### 业界主流方案对比

| 方案 | 代表项目 | 优点 | 缺点 |
|------|---------|------|------|
| 正则后处理 | CapsWriter-Offline, Paraformer清洗脚本 | 简单快速零延迟 | 规则可能不完美 |
| LLM 后处理 | LazyTyper | 效果最好 | 延迟增加、成本高 |
| 替换词表 | 火山引擎 `correct_table_id` | 服务端处理 | 无法覆盖通用空格问题 |

## 解决方案

采用客户端正则后处理，去除中文字符之间的多余空格，保留中英/中数之间的空格：

```swift
// 匹配：中文字符/标点 + 空格 + 中文字符/标点
let pattern = "([\\u4e00-\\u9fff\\u3000-\\u303f\\uff00-\\uffef])\\s+([\\u4e00-\\u9fff\\u3000-\\u303f\\uff00-\\uffef])"
text = text.replacingOccurrences(of: pattern, with: "$1$2", options: .regularExpression)
```

示例：
- `因为 你` → `因为你` ✅
- `什么 VAD` → `什么 VAD`（保留）✅
- `VAD 时间` → `VAD 时间`（保留）✅

## 日期

2026-03-31
