#!/usr/bin/env python3
"""
火山引擎大模型流式语音识别 API 测试脚本（与官方文档二进制 WebSocket 协议一致）
支持：本地 WAV、麦克风录音、真实语音样本（--demo）、或静音测试连接。
"""
import argparse
import gzip
import json
import os
import struct
import sys
import threading
import time
import uuid
import wave

try:
    import websocket
except ImportError:
    print("请先安装: pip install -r requirements.txt", file=sys.stderr)
    sys.exit(1)

from config import (
    VOLC_APP_ID,
    VOLC_ACCESS_TOKEN,
    VOLC_RESOURCE_ID,
    ASR_WS_URL,
    SAMPLE_RATE,
    CHANNELS,
    FRAME_BYTES,
    FRAME_MS,
)


# 协议常量（与 PDF 一致；服务端要求 full request 使用 gzip）
HEADER_FULL_REQUEST_JSON_GZIP = bytes([0x11, 0x10, 0x01, 0x01])  # JSON, Gzip
HEADER_AUDIO = bytes([0x11, 0x20, 0x00, 0x00])
HEADER_AUDIO_LAST = bytes([0x11, 0x22, 0x00, 0x00])
MSG_TYPE_SERVER_RESPONSE = 0x09


def build_full_client_request():
    body = {
        "user": {"uid": "test_script", "did": "mac", "platform": "macOS"},
        "audio": {
            "format": "pcm",
            "rate": SAMPLE_RATE,
            "bits": 16,
            "channel": CHANNELS,
        },
        "request": {
            "model_name": "bigmodel",
            "enable_itn": True,
            "enable_punc": True,
        },
    }
    return json.dumps(body).encode("utf-8")


def send_full_request(ws):
    payload_json = build_full_client_request()
    payload = gzip.compress(payload_json, mtime=0)
    msg = HEADER_FULL_REQUEST_JSON_GZIP + struct.pack(">I", len(payload)) + payload
    ws.send(msg, opcode=websocket.ABNF.OPCODE_BINARY)
    print("[发送] full client request (gzip), payload len =", len(payload))


def send_audio(ws, pcm: bytes, is_last: bool = False):
    header = HEADER_AUDIO_LAST if is_last else HEADER_AUDIO
    msg = header + struct.pack(">I", len(pcm)) + pcm
    ws.send(msg, opcode=websocket.ABNF.OPCODE_BINARY)


def parse_server_response(data: bytes) -> str | None:
    if len(data) < 8:
        return None
    msg_type = (data[1] >> 4) & 0x0F
    flags = data[1] & 0x0F
    if msg_type != MSG_TYPE_SERVER_RESPONSE:
        return None
    offset = 4
    if (flags & 0x01) and len(data) >= 12:
        offset = 8
    if len(data) < offset + 4:
        return None
    (payload_size,) = struct.unpack_from(">I", data, offset)
    payload_start = offset + 4
    if len(data) < payload_start + payload_size or payload_size == 0:
        return None
    payload = data[payload_start : payload_start + payload_size]
    try:
        obj = json.loads(payload.decode("utf-8"))
        result = obj.get("result") or {}
        text = (result.get("text") or "").strip()
        return text if text else None
    except Exception:
        return None


def parse_and_log_any_response(data: bytes) -> bool:
    """解析任意服务端消息并打印，返回是否为可继续的 server response。"""
    if len(data) < 4:
        print("[响应] 过短:", len(data), "字节")
        return False
    msg_type = (data[1] >> 4) & 0x0F
    flags = data[1] & 0x0F
    # 0x0F = error
    if msg_type == 0x0F:
        if len(data) >= 12:
            code = struct.unpack_from(">I", data, 4)[0]
            sz = struct.unpack_from(">I", data, 8)[0]
            msg = data[12 : 12 + sz].decode("utf-8", errors="replace")
            print("[响应] 错误 type=0x0F code=%s msg=%s" % (code, msg))
        else:
            print("[响应] 错误 type=0x0F raw_len=%d" % len(data))
        return False
    if msg_type != MSG_TYPE_SERVER_RESPONSE:
        print("[响应] 未知 type=0x%X len=%d" % (msg_type, len(data)))
        return False
    offset = 8 if (flags & 0x01) and len(data) >= 12 else 4
    if len(data) < offset + 4:
        return True
    (payload_size,) = struct.unpack_from(">I", data, offset)
    payload_start = offset + 4
    if payload_size > 0 and len(data) >= payload_start + payload_size:
        try:
            obj = json.loads(data[payload_start : payload_start + payload_size].decode("utf-8"))
            if obj:
                print("[响应] JSON keys:", list(obj.keys()))
        except Exception:
            pass
    return True


def read_wav_pcm(path: str) -> bytes:
    with wave.open(path, "rb") as f:
        if f.getnchannels() != CHANNELS or f.getsampwidth() != 2 or f.getframerate() != SAMPLE_RATE:
            print(f"[警告] WAV 需为 {SAMPLE_RATE}Hz 16bit 单声道，将尝试直接读取", file=sys.stderr)
        return f.readframes(f.getnframes())


def record_mic(seconds: float) -> bytes:
    try:
        import pyaudio
    except ImportError:
        print("麦克风录音需要: pip install pyaudio", file=sys.stderr)
        sys.exit(1)
    p = pyaudio.PyAudio()
    stream = p.open(
        format=pyaudio.paInt16,
        channels=CHANNELS,
        rate=SAMPLE_RATE,
        input=True,
        frames_per_buffer=1024,
    )
    print(f"[录音] {seconds} 秒，请说话…")
    n_frames = int(SAMPLE_RATE * seconds)
    chunks = []
    for _ in range(0, n_frames, 1024):
        to_read = min(1024, n_frames - len(chunks) * 1024)
        if to_read <= 0:
            break
        data = stream.read(to_read, exception_on_overflow=False)
        chunks.append(data)
    stream.stop_stream()
    stream.close()
    p.terminate()
    return b"".join(chunks)


def run_stream_mic(seconds: float):
    """流式麦克风：边说边发、边说边出识别结果。"""
    try:
        import pyaudio
    except ImportError:
        print("流式麦克风需要: pip install pyaudio", file=sys.stderr)
        sys.exit(1)
    connect_id = str(uuid.uuid4())
    header_list = [
        f"X-Api-App-Key: {VOLC_APP_ID}",
        f"X-Api-Access-Key: {VOLC_ACCESS_TOKEN}",
        f"X-Api-Resource-Id: {VOLC_RESOURCE_ID}",
        f"X-Api-Connect-Id: {connect_id}",
    ]
    print(f"[连接] {ASR_WS_URL}")
    ws = websocket.WebSocket()
    ws.connect(ASR_WS_URL, header=header_list)
    results = []
    recv_stop = threading.Event()

    def recv_loop():
        nonlocal results
        ws.settimeout(0.3)
        while not recv_stop.is_set():
            try:
                raw = ws.recv()
            except websocket.WebSocketTimeoutException:
                continue
            except Exception:
                break
            if isinstance(raw, str):
                continue
            text = parse_server_response(raw)
            if text:
                results.append(text)
                print("[识别]", text, flush=True)

    try:
        send_full_request(ws)
        ws.settimeout(5.0)
        try:
            raw = ws.recv()
            if isinstance(raw, bytes) and not parse_and_log_any_response(raw):
                print("[退出] 首包为错误")
                return results
        except websocket.WebSocketTimeoutException:
            pass
        ws.settimeout(None)
        recv_thread = threading.Thread(target=recv_loop, daemon=True)
        recv_thread.start()
        time.sleep(0.15)
        p = pyaudio.PyAudio()
        stream = p.open(
            format=pyaudio.paInt16,
            channels=CHANNELS,
            rate=SAMPLE_RATE,
            input=True,
            frames_per_buffer=FRAME_BYTES,
        )
        print(f"[流式] 开始拾音 {seconds} 秒，请直接说话…（边说边识别）", flush=True)
        deadline = time.monotonic() + seconds
        n = 0
        while time.monotonic() < deadline:
            data = stream.read(FRAME_BYTES, exception_on_overflow=False)
            send_audio(ws, data, is_last=False)
            n += 1
            if n % 15 == 0:
                print(f"  … 已发送 {n} 包", flush=True)
            time.sleep(FRAME_MS / 1000.0)
        send_audio(ws, b"", is_last=True)
        print("[流式] 已结束发送，等待最后结果…", flush=True)
        time.sleep(2.0)
        recv_stop.set()
        recv_thread.join(timeout=1.0)
        stream.stop_stream()
        stream.close()
        p.terminate()
    finally:
        recv_stop.set()
        ws.close()
    return results


def generate_silence(seconds: float) -> bytes:
    return b"\x00" * (int(SAMPLE_RATE * seconds) * CHANNELS * 2)


# 真实语音样本：国内可访问的 16k 样例（阿里云智能语音文档样例）
DEMO_WAV_URLS = [
    "https://help-static-aliyun-doc.aliyuncs.com/file-manage-files/zh-CN/20230223/hvow/nls-sample-16k.wav",
    "https://gw.alipayobjects.com/os/bmw-prod/0574ee2e-f494-45a5-820f-63aee583045a.wav",
]


def _resample_pcm(pcm: bytes, from_rate: int, to_rate: int, channels: int = 1, sample_width: int = 2) -> bytes:
    """简单线性插值重采样 PCM 到目标采样率。"""
    import numpy as np
    n = len(pcm) // (channels * sample_width)
    arr = np.frombuffer(pcm, dtype=np.int16)
    if channels > 1:
        arr = arr.reshape(-1, channels).mean(axis=1).astype(np.int16)
    n_new = int(n * to_rate / from_rate)
    indices = np.linspace(0, n - 1, n_new).astype(np.int32)
    return arr[indices].tobytes()


def fetch_demo_audio():
    """从国内可访问的地址下载一条真实语音 WAV，转为 16kHz 单声道 PCM，返回 (pcm_bytes, 描述)。"""
    from urllib.request import urlopen
    from urllib.error import URLError
    tmp = os.path.join(os.path.dirname(__file__) or ".", "_demo_sample.wav")
    last_err = None
    for url in DEMO_WAV_URLS:
        try:
            print("[Demo] 正在下载样本:", url)
            with urlopen(url, timeout=15) as r:
                data = r.read()
            if not data:
                continue
            with open(tmp, "wb") as f:
                f.write(data)
            with wave.open(tmp, "rb") as f:
                rate = f.getframerate()
                nch = f.getnchannels()
                width = f.getsampwidth()
                pcm = f.readframes(f.getnframes())
            if rate != SAMPLE_RATE or nch != CHANNELS or width != 2:
                import numpy as np
                pcm = _resample_pcm(pcm, rate, SAMPLE_RATE, nch, width)
            return pcm, "（国内 16k 语音样本，已转为 16kHz 单声道）"
        except (URLError, OSError, wave.Error) as e:
            last_err = e
            continue
        finally:
            if os.path.isfile(tmp):
                try:
                    os.remove(tmp)
                except Exception:
                    pass
    print("所有样本地址均下载失败，请检查网络或使用 --wav 指定本地文件", file=sys.stderr)
    if last_err:
        print("最后错误:", last_err, file=sys.stderr)
    sys.exit(1)


def run_test(audio_pcm: bytes, connect_id: str | None = None):
    connect_id = connect_id or str(uuid.uuid4())
    url = ASR_WS_URL
    header_list = [
        f"X-Api-App-Key: {VOLC_APP_ID}",
        f"X-Api-Access-Key: {VOLC_ACCESS_TOKEN}",
        f"X-Api-Resource-Id: {VOLC_RESOURCE_ID}",
        f"X-Api-Connect-Id: {connect_id}",
    ]
    print(f"[连接] {url}")
    print(f"[Connect-Id] {connect_id}")
    ws = websocket.WebSocket()
    ws.connect(url, header=header_list)
    results = []
    recv_done = threading.Event()

    def recv_loop():
        nonlocal results
        ws.settimeout(0.5)
        while not recv_done.is_set():
            try:
                raw = ws.recv()
            except websocket.WebSocketTimeoutException:
                continue
            except Exception:
                break
            if isinstance(raw, str):
                continue
            text = parse_server_response(raw)
            if text:
                results.append(text)
                print("[识别]", text)
        ws.settimeout(None)

    try:
        send_full_request(ws)
        # 先读首包响应，确认无错误再发音频
        ws.settimeout(5.0)
        try:
            raw = ws.recv()
            if isinstance(raw, bytes):
                if not parse_and_log_any_response(raw):
                    print("[退出] 首包为错误，不再发送音频")
                    return results
        except websocket.WebSocketTimeoutException:
            print("[警告] 未在 5s 内收到首包响应，继续发音频")
        except Exception as e:
            print("[首包 recv]", e)
        ws.settimeout(None)
        t = threading.Thread(target=recv_loop, daemon=True)
        t.start()
        time.sleep(0.1)
        n = 0
        for i in range(0, len(audio_pcm), FRAME_BYTES):
            chunk = audio_pcm[i : i + FRAME_BYTES]
            is_last = (i + FRAME_BYTES >= len(audio_pcm))
            send_audio(ws, chunk, is_last=is_last)
            n += 1
            if n % 10 == 0:
                print(f"[发送] 已发 {n} 包音频")
            time.sleep(FRAME_MS / 1000.0)
        # 若总长度不是 FRAME_BYTES 的整数倍，最后一包已在循环中带 is_last=True 发送；否则最后一包也已带 is_last=True，无需再发空包
        print("[发送] 音频发送完毕，等待识别结果…")
        time.sleep(5.0)
        recv_done.set()
        t.join(timeout=2.0)
        return results
    finally:
        recv_done.set()
        ws.close()


def main():
    ap = argparse.ArgumentParser(description="火山引擎流式语音识别 API 测试")
    ap.add_argument("--wav", type=str, help="16kHz 16bit 单声道 WAV 文件路径")
    ap.add_argument("--mic", type=float, metavar="SEC", help="（先录后发）麦克风录 SEC 秒再整段识别")
    ap.add_argument("--mic-stream", type=float, metavar="SEC", help="流式麦克风：边说边发、边说边出结果，持续 SEC 秒")
    ap.add_argument("--silence", type=float, default=0, metavar="SEC", help="先发送 SEC 秒静音再发真实音频（用于测试连接，默认 0）")
    ap.add_argument("--demo", action="store_true", help="使用真实语音样本测试（从 Hugging Face 拉取 LibriSpeech 一条）")
    ap.add_argument("--list-devices", action="store_true", help="列出麦克风设备后退出")
    args = ap.parse_args()

    if args.list_devices:
        try:
            import pyaudio
            p = pyaudio.PyAudio()
            for i in range(p.get_device_count()):
                info = p.get_device_info_by_index(i)
                if info.get("maxInputChannels", 0) > 0:
                    print(i, info.get("name"), "inputs:", info.get("maxInputChannels"))
            p.terminate()
        except Exception as e:
            print("pyaudio 未安装或无设备:", e)
        return

    if args.wav:
        if not os.path.isfile(args.wav):
            print("文件不存在:", args.wav, file=sys.stderr)
            sys.exit(1)
        audio_pcm = read_wav_pcm(args.wav)
        print(f"[WAV] {args.wav}, {len(audio_pcm)} 字节, {len(audio_pcm)/(SAMPLE_RATE*2):.2f} 秒")
    elif args.demo:
        audio_pcm, demo_desc = fetch_demo_audio()
        print(f"[Demo] 样本时长 {len(audio_pcm)/(SAMPLE_RATE*2):.2f} 秒 {demo_desc}")
    elif args.mic_stream is not None:
        sec = args.mic_stream
        if sec <= 0 or sec > 300:
            print("--mic-stream 请设为 (0, 300] 秒", file=sys.stderr)
            sys.exit(1)
        results = run_stream_mic(sec)
        print("\n[汇总] 识别结果条数:", len(results))
        if results:
            print("最终结果:", results[-1])
        return
    elif args.mic is not None:
        if args.mic <= 0 or args.mic > 60:
            print("--mic 请设为 (0, 60] 秒", file=sys.stderr)
            sys.exit(1)
        audio_pcm = record_mic(args.mic)
        print(f"[录音] {len(audio_pcm)} 字节")
    else:
        # 默认：2 秒静音，仅用于验证连接与协议
        duration = 2.0
        audio_pcm = generate_silence(duration)
        print(f"[静音] 生成 {duration} 秒静音用于连接测试")

    if args.silence > 0:
        prefix = generate_silence(args.silence)
        audio_pcm = prefix + audio_pcm
        print(f"[前缀] 已加 {args.silence} 秒静音")

    if not audio_pcm:
        print("无音频数据", file=sys.stderr)
        sys.exit(1)

    results = run_test(audio_pcm)
    print("\n[汇总] 识别结果条数:", len(results))
    if results:
        print("最终结果:", results[-1])
        if len(results) > 1:
            print("（流式共 %d 条，上为最终句）" % len(results))


if __name__ == "__main__":
    main()
