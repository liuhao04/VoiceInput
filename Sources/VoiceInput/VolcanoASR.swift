import Foundation

// 仅在此文件使用 Log，避免 VolcanoASR 依赖具体 Logger 实现
private func _asrLog(_ msg: String) { Log.log("[ASR] \(msg)") }

/// 火山引擎大模型流式语音识别 - 二进制 WebSocket 协议
/// 协议：4 字节 header + 4 字节 payload size (大端) + payload
final class VolcanoASR: NSObject, @unchecked Sendable {
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "com.voiceinput.asr")
    private var onText: (@Sendable (String) -> Void)?
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
        onText: @escaping @Sendable (String) -> Void,
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
        var req = URLRequest(url: URL(string: Config.asrWebSocketURL)!)
        req.setValue(Config.volcAppId, forHTTPHeaderField: "X-Api-App-Key")
        req.setValue(Config.volcAccessToken, forHTTPHeaderField: "X-Api-Access-Key")
        req.setValue(Config.volcResourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        webSocketTask = session.webSocketTask(with: req)
        _asrLog("WebSocket 连接中: \(Config.asrWebSocketURL)")
        webSocketTask?.resume()
    }
    
    private func sendFullClientRequest() {
        _asrLog("发送 full client request (gzip)")
        guard let task = webSocketTask else { return }
        let params: [String: Any] = [
            "user": [
                "uid": "voice_input_mac",
                "did": "mac",
                "platform": "macOS"
            ],
            "audio": [
                "format": "pcm",
                "rate": 16000,
                "bits": 16,
                "channel": 1
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "boosting_table_id": Config.boostingTableId,
                "id": Config.replaceWordsId,  // 替换词ID
                "asr_appid": Config.volcAppId  // 根据文档字幕识别需要此参数
            ]
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: params) else {
            _asrLog("full client request 序列化失败")
            onError?(NSError(domain: "VolcanoASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "首包序列化失败"]))
            return
        }

        // 调试：打印发送的 JSON
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            _asrLog("发送的 request JSON: \(jsonString)")
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
            _asrLog("full client request 已发送，等待服务端首包响应后再开麦")
            // 不在此处 onReady：与测试脚本一致，等收到首包成功响应后再开麦
        }
    }
    
    private func _sendAudio(_ data: Data, isLast: Bool) {
        guard let task = webSocketTask else {
            _asrLog("_sendAudio 跳过: webSocketTask 为空")
            return
        }
        if !isConnectionReady {
            pcmQueue.append((data: data, isLast: isLast))
            _asrLog("连接未就绪，PCM 入队，当前队列长度=\(pcmQueue.count)")
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
        _asrLog("已刷新 PCM 队列，共 \(pcmQueue.count) 包")
        pcmQueue.removeAll()
    }
    
    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self, self.isRunning else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.parseServerResponse(data)
                case .string:
                    break
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let err):
                if self.isRunning {
                    self.onError?(err)
                }
            }
        }
    }
    
    private func parseServerResponse(_ data: Data) {
        guard data.count >= 4 else { return }
        let typeAndFlags = data[1]
        let messageType = (typeAndFlags >> 4) & 0x0F
        let flags = typeAndFlags & 0x0F

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
            _asrLog("收到首包成功响应，连接就绪，开始发送音频")
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
        let payload = data.subdata(in: payloadStart..<(payloadStart + Int(payloadSize)))
        if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let result = json["result"] as? [String: Any],
           let text = result["text"] as? String, !text.isEmpty {
            _asrLog("识别结果: \(text.prefix(80))\(text.count > 80 ? "…" : "")")
            DispatchQueue.main.async { self.onText?(text) }
        }
    }
}

extension VolcanoASR: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        _asrLog("WebSocket 已连接，稍后发送首包")
        // 延迟一帧再发首包，确保 socket 已可写（避免 "Socket is not connected"）
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendFullClientRequest()
            self?.receiveLoop()
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        _asrLog("WebSocket 已关闭 code=\(closeCode.rawValue)")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error {
            _asrLog("URLSession 错误: \(e.localizedDescription)")
            if isRunning { onError?(e) }
        }
    }
}
