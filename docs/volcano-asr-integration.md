# 火山引擎流式 ASR 接入参考

本文档汇总 VoiceInput 项目调用火山引擎（豆包）大模型流式语音识别的做法，供其他语音输入项目复用参考。

## 一、接入概览

- **接口**：`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`（豆包大模型流式语音识别，异步二遍）
- **Resource ID**：`volc.seedasr.sauc.duration`（按时长计费）
- **三件凭证**：
  - `X-Api-App-Key`（App ID）
  - `X-Api-Access-Key`（Access Token）
  - `X-Api-Resource-Id`
  - 额外需要 `X-Api-Connect-Id`（每次连接的 UUID）
- **可选 corpus**：
  - 热词表 `boosting_table_id`
  - 替换词表 `correct_table_id`
  - 均在火山控制台创建后拿到 ID

## 二、二进制 WebSocket 协议（关键）

帧结构统一为：**4 字节 header + 4 字节 payload size（大端 UInt32）+ payload**

| 帧类型 | header (4B) | payload |
|---|---|---|
| 首包（Full Client Request） | `0x11 0x10 0x01 0x01` | **gzip 压缩的 JSON** 配置 |
| 音频中间包 | `0x11 0x20 0x00 0x00` | 原始 PCM（不压缩） |
| 音频最后一包（负包） | `0x11 0x22 0x00 0x00` | 空 Data 或最后一段 PCM |

服务端响应同样是 header + size + payload；解析要点：

- `messageType = (data[1] >> 4) & 0x0F`
  - `0x09` = 识别结果
  - `0x0F` = 错误
- `compression = data[3] & 0x0F`
  - `0x01` 表示 payload 是 gzip（需解压）
- `flags = data[1] & 0x0F`
  - `0x00` 无序列号
  - `0x01` 一遍正序列号
  - `0x02` 最后一包标志
  - `0x03` **负序列号 = 二遍识别最终结果**（`enable_nonstream=true` 才会收到）
- 如果 `flags & 0x01 != 0`，payload size 前面会多 4 字节序列号，需要把 offset 从 4 跳到 8
- 错误帧格式：`code (4B 大端) + msgSize (4B 大端) + utf8 msg`

## 三、首包 JSON 配置（本项目用法）

```json
{
  "user": {
    "uid": "voice_input_mac",
    "did": "mac",
    "platform": "macOS"
  },
  "audio": {
    "format": "pcm",
    "rate": 16000,
    "bits": 16,
    "channel": 1,
    "language": "zh-CN"
  },
  "request": {
    "model_name": "bigmodel",
    "enable_itn": true,
    "enable_punc": true,
    "enable_ddc": true,
    "enable_nonstream": true,
    "end_window_size": 1000
  },
  "corpus": {
    "boosting_table_id": "...",
    "correct_table_id": "..."
  }
}
```

request 字段含义：

| 字段 | 含义 |
|---|---|
| `enable_itn` | 数字规整（Inverse Text Normalization） |
| `enable_punc` | 自动标点 |
| `enable_ddc` | 语义顺滑（去口癖） |
| `enable_nonstream` | 开启二遍识别（更准，收尾时以 `flags=0x03` 返回） |
| `end_window_size` | VAD 判停时间（ms），默认 800 |

## 四、时序与可靠性要点（踩过的坑）

1. **首包要 gzip，音频包不压缩。** Apple 的 `COMPRESSION_ZLIB` 输出的是 zlib（2B 头 + deflate + 4B adler32），要手动拆成 deflate 再自己拼 gzip 头 + CRC32 + ISIZE。参考 `Sources/VoiceInput/Gzip.swift`。

2. **WebSocket `didOpen` 后延迟 ~50ms 再发首包**，否则偶发 "Socket is not connected"。

3. **音频要在连接就绪前就开始采集并入队**：用户按下热键立刻 `AVAudioEngine` 采集，PCM 先塞 `pcmQueue`；等收到服务端第一个 `messageType=0x09` 响应后置 `isConnectionReady=true`，先 flush 队列再进入实时发送。**这是防止丢掉最前面几个字的关键**。

4. **结束有两种**：
   - `sendLastPacket()`：发空负包后保持连接继续接收二遍结果；等最终 `flags=0x03` 到达后再 `close()`。生产流程使用此路径。
   - `stop()`：测试场景可用，发负包后 0.3s 硬关。

5. **识别结果取值**：`json["result"]["text"]`
   - 一遍结果是"当前累计全文"（覆盖而非增量）
   - 二遍以 `flags==0x03` 区分，通常比一遍更准，UI 上用它替换最终文本

6. **URLSession WebSocket 的 receive 是单次**，需在循环里持续 `try await task.receive()`；`isRunning=false` 后停止并把 `onError` 置 nil，避免主动关闭时触发 UI 报错。

## 五、音频采集要求

- 16kHz / 单声道 / 16-bit PCM / 小端交织
- 每包约 200ms（本项目是 3200 帧 = 6400 字节）
- `AVAudioEngine.inputNode` 拿到的是设备原始格式（常见 44.1/48kHz float），用 `AVAudioConverter` 下采样到 16k Int16，再把 `int16ChannelData[0]` 打包成 `Data` 回调

参考 `Sources/VoiceInput/AudioCapture.swift`。

## 六、可以直接复用的文件

| 文件 | 作用 | 依赖 |
|---|---|---|
| `Sources/VoiceInput/VolcanoASR.swift` | 协议客户端，约 290 行 | `Foundation` |
| `Sources/VoiceInput/Gzip.swift` | gzip 压缩/解压 | `Compression.framework` |
| `Sources/VoiceInput/AudioCapture.swift` | 16k PCM 采集 | `AVFoundation` |

这三个文件基本可零改拷到另一个 macOS/iOS Swift 项目，只需把 `Config.volcAppId / AccessToken / ResourceId / asrWebSocketURL` 换成新项目的配置来源即可。

## 七、Python 参考实现

`asr_test/test_volc_asr.py` 是同协议的 Python 实现，调试协议问题时比 Swift 更易排查，建议一并拷过去作为 ground truth：协议一致的情况下，Python 能跑通 = 服务端配置和凭证正确；Swift 跑不通就一定是客户端 bug。

## 八、凭证存储建议（macOS）

如果目标项目也是 macOS 非沙盒应用：

- 敏感凭证（App ID、Access Token、corpus IDs）存 Keychain
- 使用 `SecAccessCreate(name, [] as CFArray, &access)` 创建**空信任列表**的 ACL（任何应用可访问、不弹窗），避免 ACL 绑定 cdhash 导致每次重编译弹框
- 非敏感配置（Resource ID、WebSocket URL）存 UserDefaults
- 支持环境变量覆盖，便于 CI / 本地调试

详见本项目 `Sources/VoiceInput/Config.swift` 和 `KeychainHelper.swift`，以及 `CLAUDE.md` 中 "Keychain Best Practices" 一节。
