import Foundation

// 仅在此文件使用 Log，避免 VolcanoASR 依赖具体 Logger 实现
private func _asrLog(_ msg: String) { Log.log("[ASR] \(msg)") }

/// 火山引擎大模型流式语音识别 - 二进制 WebSocket 协议
/// 协议：4 字节 header + 4 字节 payload size (大端) + payload
final class VolcanoASR: NSObject, @unchecked Sendable {
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "com.voiceinput.asr")
    private var onText: (@Sendable (String, Bool) -> Void)?  // (text, isFinal)
    private var onError: (@Sendable (Error) -> Void)?
    private var onReady: (@Sendable () -> Void)?
    private var isRunning = false
    /// 仅在收到服务端首包成功响应后才发送音频（与 Python 测试脚本一致）
    private var isConnectionReady = false
    private var hasReceivedFirstResponse = false
    private var pcmQueue: [(data: Data, isLast: Bool)] = []
    
    // 协议常量 (大端)，与测试脚本一致；服务端要求首包 gzip
    private let headerFullClientRequest: [UInt8] = [0x11, 0x10, 0x01, 0x01]  // JSON, Gzip
    private let headerAudioOnly: [UInt8] = [0x11, 0x20, 0x00, 0x00]           // raw, 无压缩
    private let headerAudioLast: [UInt8] = [0x11, 0x22, 0x00, 0x00]          // 最后一包
    
    func start(
        onText: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onReady: @escaping @Sendable () -> Void
    ) {
        _asrLog("start")
        self.onText = onText
        self.onError = onError
        self.onReady = onReady
        isRunning = true
        connect()
    }
    
    /// 发送负包（最后一包），但保持连接以接收二遍识别结果
    func sendLastPacket() {
        _asrLog("sendLastPacket: 发送负包，等待最终结果")
        queue.async { [weak self] in
            self?._sendAudio(Data(), isLast: true)
        }
    }

    /// 完全关闭连接
    func close() {
        _asrLog("close: 关闭 WebSocket 连接")
        isRunning = false
        onError = nil  // 防止关闭时的 socket 错误触发 UI 报错
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        // URLSession 强引用 delegate（即 self），不 invalidate 则每次录音泄漏一个 VolcanoASR + 连接
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    /// 便捷方法：发送负包后 0.3s 自动关闭连接（用于测试等快速关闭场景）。
    /// 生产流程使用 sendLastPacket() 等待二遍识别结果后再调 close()。
    func stop() {
        _asrLog("stop")
        isRunning = false
        queue.async { [weak self] in
            self?._sendAudio(Data(), isLast: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self?.webSocketTask = nil
            }
        }
    }
    
    func sendPCM(_ data: Data) {
        queue.async { [weak self] in
            self?._sendAudio(data, isLast: false)
        }
    }
    
    private func connect() {
        guard let url = URL(string: Config.asrWebSocketURL) else {
            let err = NSError(domain: "VolcanoASR", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "WebSocket URL 无效: \(Config.asrWebSocketURL)"])
            _asrLog("URL 无效: \(Config.asrWebSocketURL)")
            onError?(err)
            return
        }
        var req = URLRequest(url: url)
        req.setValue(Config.volcAppId, forHTTPHeaderField: "X-Api-App-Key")
        req.setValue(Config.volcAccessToken, forHTTPHeaderField: "X-Api-Access-Key")
        req.setValue(Config.volcResourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        webSocketTask = session.webSocketTask(with: req)
        webSocketTask?.resume()
    }
    
    private func sendFullClientRequest() {
        guard let task = webSocketTask else { return }
        let mode = Config.asrMode
        var audio: [String: Any] = [
            "format": "pcm",
            "rate": 16000,
            "bits": 16,
            "channel": 1
        ]
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": true        // 语义顺滑
        ]
        switch mode {
        case .async:
            // 双向流式（优化版）：二遍识别提高尾字准确率；端点不支持 audio.language
            request["enable_nonstream"] = true
            request["end_window_size"] = 2500  // VAD 判停 ms，调大以减少思考停顿被过早 finalize
        case .nostream:
            // 流式输入：不支持 enable_nonstream；language 仅此端点生效
            audio["language"] = "zh-CN"
        }
        var params: [String: Any] = [
            "user": [
                "uid": "voice_input_mac",
                "did": "mac",
                "platform": "macOS"
            ],
            "audio": audio,
            "request": request
        ]
        // corpus 参数：热词表和替换词表（仅在有值时添加）
        var corpus: [String: Any] = [:]
        if !Config.boostingTableId.isEmpty {
            corpus["boosting_table_id"] = Config.boostingTableId
        }
        if !Config.replaceWordsId.isEmpty {
            corpus["correct_table_id"] = Config.replaceWordsId
        }
        if !corpus.isEmpty {
            params["corpus"] = corpus
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: params) else {
            _asrLog("full client request 序列化失败")
            onError?(NSError(domain: "VolcanoASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "首包序列化失败"]))
            return
        }

        guard let payload = Gzip.compress(jsonData) else {
            _asrLog("full client request gzip 压缩失败")
            onError?(NSError(domain: "VolcanoASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "首包 gzip 压缩失败"]))
            return
        }
        var msg = Data(headerFullClientRequest)
        var size = UInt32(payload.count).bigEndian
        msg.append(Data(bytes: &size, count: 4))
        msg.append(payload)
        task.send(.data(msg)) { [weak self] err in
            guard let self = self else { return }
            if let e = err {
                _asrLog("发送 full client request 失败: \(e.localizedDescription)")
                self.onError?(e)
                return
            }
        }
    }
    
    private func _sendAudio(_ data: Data, isLast: Bool) {
        guard let task = webSocketTask else { return }
        if !isConnectionReady {
            pcmQueue.append((data: data, isLast: isLast))
            return
        }
        _doSendAudio(task: task, data: data, isLast: isLast)
    }
    
    private func _doSendAudio(task: URLSessionWebSocketTask, data: Data, isLast: Bool) {
        let header = isLast ? headerAudioLast : headerAudioOnly
        var msg = Data(header)
        var size = UInt32(data.count).bigEndian
        msg.append(Data(bytes: &size, count: 4))
        msg.append(data)
        task.send(.data(msg)) { [weak self] err in
            if let e = err {
                _asrLog("发送音频失败: \(e.localizedDescription)")
                self?.onError?(e)
            }
        }
    }
    
    private func _flushPcmQueue() {
        guard let task = webSocketTask else { return }
        for item in pcmQueue {
            _doSendAudio(task: task, data: item.data, isLast: item.isLast)
        }
        pcmQueue.removeAll()
    }
    
    private func receiveLoop() {
        guard let task = webSocketTask else { return }
        Task { [weak self] in
            do {
                while let self = self, self.isRunning {
                    let message = try await task.receive()
                    switch message {
                    case .data(let data):
                        self.parseServerResponse(data)
                    case .string:
                        break
                    @unknown default:
                        break
                    }
                }
            } catch {
                guard let self = self, self.isRunning else { return }
                self.onError?(error)
            }
        }
    }
    
    private func parseServerResponse(_ data: Data) {
        guard data.count >= 4 else { return }
        let typeAndFlags = data[1]
        let messageType = (typeAndFlags >> 4) & 0x0F
        let flags = typeAndFlags & 0x0F
        // 检查压缩方式：header 第 4 字节低 4 位，0x01 = gzip
        let compression = data[3] & 0x0F

        // 0x0F = 服务端错误，解析并回调 onError
        if messageType == 0x0F {
            var errMsg = "服务端返回错误"
            if data.count >= 12 {
                let code = data.subdata(in: 4..<8).withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
                let msgSize = data.subdata(in: 8..<12).withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
                if data.count >= 12 + Int(msgSize), let s = String(data: data.subdata(in: 12..<(12 + Int(msgSize))), encoding: .utf8) {
                    errMsg = s
                }
                _asrLog("服务端错误 type=0x0F code=\(code) msg=\(errMsg)")
            }
            DispatchQueue.main.async { self.onError?(NSError(domain: "VolcanoASR", code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg])) }
            return
        }

        // 0x09 = full server response
        if messageType != 0x09 { return }
        if !hasReceivedFirstResponse {
            hasReceivedFirstResponse = true
            queue.async { [weak self] in
                guard let self = self else { return }
                self.isConnectionReady = true
                self._flushPcmQueue()
            }
            DispatchQueue.main.async { self.onReady?() }
        }
        var offset = 4
        if (flags & 0x01) != 0, data.count >= 12 {
            offset = 8
        }
        if data.count < offset + 4 { return }
        let payloadSize = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
        let payloadStart = offset + 4
        guard data.count >= payloadStart + Int(payloadSize), payloadSize > 0 else { return }
        var payload = data.subdata(in: payloadStart..<(payloadStart + Int(payloadSize)))

        // 如果响应是 gzip 压缩的，先解压
        if compression == 0x01 {
            guard let decompressed = Gzip.decompress(payload) else {
                _asrLog("响应 gzip 解压失败")
                return
            }
            payload = decompressed
        }

        // flags 含义：0x00=无序列号, 0x01=正序列号(一遍), 0x02=最后一包(负包), 0x03=负序列号(二遍)
        // 不同模式下"最终结果"的信号不同：
        //   async   端点走二遍识别（flags=0x03）
        //   nostream 端点没有二遍；最后一包（0x02）或负序列号（0x03）都视为最终
        let isFinal: Bool
        switch Config.asrMode {
        case .async:    isFinal = (flags == 0x03)
        case .nostream: isFinal = (flags == 0x02 || flags == 0x03)
        }

        if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let result = json["result"] as? [String: Any],
           let text = result["text"] as? String, !text.isEmpty {
            _asrLog("识别结果 (flags=0x\(String(flags, radix: 16)), final=\(isFinal)): \(text)")
            DispatchQueue.main.async { self.onText?(text, isFinal) }
        }
    }
}

extension VolcanoASR: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        // 延迟一帧再发首包，确保 socket 已可写（避免 "Socket is not connected"）
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendFullClientRequest()
            self?.receiveLoop()
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error {
            _asrLog("URLSession 错误: \(e.localizedDescription)")
            if isRunning { onError?(e) }
        }
    }
}
