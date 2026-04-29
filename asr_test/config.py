"""火山引擎 API 配置。

环境变量优先；若未设置，则读取 VoiceInput app 的本机私有凭证文件。
不要把 credentials.json 或真实 token 提交到仓库。
"""
import json
import os
from pathlib import Path


def _credential_candidates() -> list[Path]:
    paths: list[Path] = []
    explicit = os.environ.get("VOICEINPUT_CREDENTIALS_FILE")
    if explicit:
        paths.append(Path(explicit).expanduser())

    app_support = Path.home() / "Library" / "Application Support"
    # Personal 优先：这是开发机日常使用版本；Distribution 作为兜底。
    paths.append(app_support / "VoiceInput Personal" / "credentials.json")
    paths.append(app_support / "VoiceInput" / "credentials.json")
    return paths


def _load_local_credentials() -> tuple[dict[str, str], str | None]:
    for path in _credential_candidates():
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if data.get("volcAppId") or data.get("volcAccessToken"):
            return data, str(path)
    return {}, None


_LOCAL_CREDENTIALS, _LOCAL_CREDENTIALS_PATH = _load_local_credentials()


def _credential_value(env_key: str, file_key: str) -> str:
    return os.environ.get(env_key) or _LOCAL_CREDENTIALS.get(file_key, "")


VOLC_APP_ID = _credential_value("VOLC_APP_ID", "volcAppId")
VOLC_ACCESS_TOKEN = _credential_value("VOLC_ACCESS_TOKEN", "volcAccessToken")
VOLC_RESOURCE_ID = os.environ.get("VOLC_RESOURCE_ID", "volc.seedasr.sauc.duration")
ASR_WS_URL = os.environ.get("ASR_WS_URL", "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")
CREDENTIAL_SOURCE = "environment" if os.environ.get("VOLC_APP_ID") and os.environ.get("VOLC_ACCESS_TOKEN") else (_LOCAL_CREDENTIALS_PATH or "missing")

# 音频格式（与 API 文档一致）
SAMPLE_RATE = 16000
CHANNELS = 1
BYTES_PER_SAMPLE = 2  # 16bit
# 建议每包 200ms：16000 * 0.2 * 2 = 6400 字节
FRAME_MS = 200
FRAME_BYTES = SAMPLE_RATE * FRAME_MS // 1000 * BYTES_PER_SAMPLE  # 6400
