# 火山引擎大模型流式语音识别 API 测试

与[官方文档](https://www.volcengine.com/docs/6561/1354869)一致的 WebSocket 二进制协议测试脚本，用于验证鉴权、连接与识别流程。

## 全自动运行（推荐）

```bash
./run.sh
```

- 自动创建 `.venv` 并安装依赖（仅 `websocket-client`）
- 默认发送 2 秒静音，验证连接与首包；静音无识别结果属正常

## 配置

与 Mac App 一致，可在 `config.py` 中修改或通过环境变量覆盖：

- `VOLC_APP_ID`
- `VOLC_ACCESS_TOKEN`
- `VOLC_RESOURCE_ID`
- `ASR_WS_URL`（默认 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`，
  测试流式输入模式可改为 `.../api/v3/sauc/bigmodel_nostream`）

## 使用方式

| 命令 | 说明 |
|------|------|
| `python3 test_volc_asr.py` | 2 秒静音，仅测连接 |
| `python3 test_volc_asr.py --demo` | 真实语音测试（从国内可访问地址下载 16k 样例） |
| `python3 test_volc_asr.py --wav path/to/16k.wav` | 指定 16kHz 16bit 单声道 WAV |
| `python3 test_volc_asr.py --mic-stream 10` | 流式麦克风 10 秒：边说边发、边说边出结果 |
| `python3 test_volc_asr.py --mic 5` | 先录 5 秒再整段识别（需 pyaudio） |

### 自己说话测试（流式麦克风）

**边说边识别**：边说边往火山发数据，识别结果实时打印。**在本机终端**执行：

```bash
cd asr_test
./run_mic.sh 10
```

`10` 表示拾音 10 秒，可改成 5～300。看到 **「请直接说话…（边说边识别）」** 后直接说，结果会陆续打出 `[识别] xxx`。

也可直接：

```bash
source .venv/bin/activate
python3 test_volc_asr.py --mic-stream 10
```

首次运行需安装 pyaudio；Mac 请先：`brew install portaudio`，再 `pip install pyaudio`。

## 协议说明

- **首包**：Full client request，JSON 经 **gzip 压缩** 后发送（服务端要求）
- **后续包**：Audio only，每包约 200ms PCM（6400 字节），最后一包带结束标志
- **响应**：解析 `result.text` 并打印
