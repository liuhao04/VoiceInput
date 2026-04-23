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
        self.onBuffer = onBuffer
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: bus)
        Log.log("[Audio] 输入格式: rate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Log.log("[Audio] ❌ 无法创建格式转换器")
            throw NSError(domain: "AudioCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建音频格式转换器"])
        }
        self.converter = converter
        isRunning = true

        inputNode.installTap(onBus: bus, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        do {
            try engine.start()
            Log.log("[Audio] 引擎已启动，开始采集")
        } catch {
            Log.log("[Audio] ❌ 引擎启动失败: \(error)")
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        // 必须先 stop（同步等待 IO 线程退出），再 removeTap。
        // 反过来会留出一个 IO 线程仍在跑、tap 回调已被置 NULL 的窗口，
        // 触发 com.apple.audio.IOThread.client 的 PC=0 崩溃。
        engine.stop()
        engine.inputNode.removeTap(onBus: bus)
        converter = nil
        onBuffer = nil
    }
    
    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let conv = converter, let onBuffer = onBuffer else { return }

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
        if error != nil { return }
        guard let channelData = outBuffer.int16ChannelData else { return }
        let count = Int(outBuffer.frameLength) * Int(targetFormat.channelCount)
        let data = Data(bytes: channelData[0], count: count * 2)
        if !data.isEmpty {
            onBuffer(data)
        }
    }
}
