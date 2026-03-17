import AVFoundation
import Foundation

/// 16kHz 单声道 16bit PCM 麦克风采集，按约 200ms 一包回调
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let bus = 0
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var isRunning = false
    private var onBuffer: ((Data) -> Void)?
    
    /// 约 200ms @ 16kHz 16bit mono = 6400 bytes
    private let bufferSize: AVAudioFrameCount = 3200
    
    init() {
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    }
    
    func start(onBuffer: @escaping (Data) -> Void) throws {
        Log.log("[Audio] start, 输入格式将由引擎决定")
        self.onBuffer = onBuffer

        // 记录当前线程
        let isMainThread = Thread.isMainThread
        Log.log("[Audio] 当前线程: \(isMainThread ? "主线程" : "后台线程")")

        // 注意：访问 engine.inputNode 必须在主线程，否则可能会阻塞
        // 如果不在主线程，切换到主线程
        Log.log("[Audio] 准备访问 inputNode...")
        var inputNode: AVAudioInputNode!
        if Thread.isMainThread {
            inputNode = engine.inputNode
            Log.log("[Audio] inputNode 获取成功（主线程）")
        } else {
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                inputNode = self.engine.inputNode
                Log.log("[Audio] inputNode 获取成功（通过主线程）")
                sem.signal()
            }
            Log.log("[Audio] 等待主线程返回 inputNode...")
            sem.wait()
        }

        Log.log("[Audio] 获取输入格式...")
        let inputFormat = inputNode.outputFormat(forBus: bus)
        Log.log("[Audio] 输入格式: rate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Log.log("[Audio] 无法创建格式转换器")
            throw NSError(domain: "AudioCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建音频格式转换器"])
        }
        self.converter = converter
        Log.log("[Audio] 格式转换器创建成功")

        isRunning = true

        Log.log("[Audio] 安装 tap...")
        inputNode.installTap(onBus: bus, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }
        Log.log("[Audio] tap 安装成功")

        Log.log("[Audio] 启动引擎...")
        do {
            try engine.start()
            Log.log("[Audio] 引擎已启动，开始采集")
        } catch {
            Log.log("[Audio] ❌ 引擎启动失败: \(error)")
            throw error
        }
    }
    
    func stop() {
        Log.log("[Audio] stop")
        isRunning = false
        engine.inputNode.removeTap(onBus: bus)
        engine.stop()
    }
    
    private var bufferCount = 0

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let conv = converter, let onBuffer = onBuffer else { return }

        bufferCount += 1
        if bufferCount <= 3 {
            Log.log("[Audio] processBuffer called, frameLength=\(buffer.frameLength)")
        }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        outBuffer.frameLength = 0
        var error: NSError?
        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if !provided {
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        conv.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if error != nil {
            Log.log("[Audio] ❌ 转换错误: \(error!)")
            return
        }
        guard let channelData = outBuffer.int16ChannelData else { return }
        let count = Int(outBuffer.frameLength) * Int(targetFormat.channelCount)
        let data = Data(bytes: channelData[0], count: count * 2)
        if !data.isEmpty {
            if bufferCount <= 3 {
                Log.log("[Audio] 回调音频数据: \(data.count) bytes")
            }
            onBuffer(data)
        }
    }
}
