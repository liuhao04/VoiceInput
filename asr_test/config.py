# 火山引擎 API 配置 - 需要通过环境变量设置
# 设置方法: export VOLC_APP_ID="your_app_id" VOLC_ACCESS_TOKEN="your_token"
import os

VOLC_APP_ID = os.environ.get("VOLC_APP_ID", "")
VOLC_ACCESS_TOKEN = os.environ.get("VOLC_ACCESS_TOKEN", "")
VOLC_RESOURCE_ID = os.environ.get("VOLC_RESOURCE_ID", "volc.seedasr.sauc.duration")
ASR_WS_URL = os.environ.get("ASR_WS_URL", "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")

# 音频格式（与 API 文档一致）
SAMPLE_RATE = 16000
CHANNELS = 1
BYTES_PER_SAMPLE = 2  # 16bit
# 建议每包 200ms：16000 * 0.2 * 2 = 6400 字节
FRAME_MS = 200
FRAME_BYTES = SAMPLE_RATE * FRAME_MS // 1000 * BYTES_PER_SAMPLE  # 6400
