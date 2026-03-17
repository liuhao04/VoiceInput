import AppKit
import Foundation

/// 端到端测试：用本地音频 mock 识别，粘贴到 TextEdit，并验证是否写入成功（仅用于测试 App）
enum E2ETest {
    private static let resultPath = "/tmp/voiceinput_e2e_result.json"
    private static let chunkSize = 3200  // ~100ms @ 16kHz 16bit
    private static let chunkDelayMs = 50

    /// 从文件加载 PCM：.pcm 为原始 PCM，.wav 则解析 data 块或跳过 44 字节头
    static func loadPCM(from path: String) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else { return nil }
        if path.lowercased().hasSuffix(".wav"), data.prefix(4) == "RIFF".data(using: .utf8) {
            // 查找 "data" 块
            var i = 12
            while i + 8 <= data.count {
                let chunkId = String(data: data.subdata(in: i..<(i + 4)), encoding: .utf8) ?? ""
                let chunkLen = data.subdata(in: (i + 4)..<(i + 8)).withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
                if chunkId == "data" {
                    let start = i + 8
                    let end = min(start + Int(chunkLen), data.count)
                    return data.subdata(in: start..<end)
                }
                i += 8 + Int(chunkLen)
            }
            if data.count > 44 { return data.subdata(in: 44..<data.count) }
        }
        return data
    }

    static func getOrLaunchTextEdit() -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.TextEdit" }
        if let first = apps.first { return first }
        guard NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/TextEdit.app")) else { return nil }
        Thread.sleep(forTimeInterval: 1.0)
        return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.TextEdit" }
    }

    static func getTextEditDocument1Content() -> String {
        let script = "tell application \"TextEdit\" to get text of document 1"
        var err: NSDictionary?
        guard let scriptObj = NSAppleScript(source: script) else { return "" }
        let desc = scriptObj.executeAndReturnError(&err)
        return desc.stringValue ?? ""
    }

    static func writeResult(recognized: String, documentText: String, error: String?) {
        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = error == nil && (trimmed.isEmpty ? true : documentText.contains(trimmed))
        let dict: [String: Any] = [
            "recognized": recognized,
            "documentText": documentText,
            "success": ok,
            "error": error as Any
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: json, encoding: .utf8) else { return }
        try? str.write(toFile: resultPath, atomically: true, encoding: .utf8)
    }

    /// 运行 E2E：加载 PCM → ASR → 粘贴到 TextEdit → 写出结果并 exit
    static func run(completion: @escaping (Int) -> Void) {
        // 优先从 e2e 脚本写入的路径文件读取（open 启动时无 env）
        let pathFile = "/tmp/voiceinput_e2e_audio_path"
        var audioPath = ProcessInfo.processInfo.environment["VOICEINPUT_AUDIO_FILE"]
        if audioPath == nil, let pathData = try? Data(contentsOf: URL(fileURLWithPath: pathFile)),
           let s = String(data: pathData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            audioPath = s
        }
        let path = audioPath ?? "/tmp/voiceinput_demo.pcm"
        try? FileManager.default.removeItem(atPath: "/tmp/voiceinput_e2e_requested")
        try? "".write(toFile: "/tmp/voiceinput_e2e_started", atomically: true, encoding: .utf8)
        guard let pcmData = loadPCM(from: path) else {
            writeResult(recognized: "", documentText: "", error: "无法加载音频: \(path)")
            completion(1)
            return
        }
        guard let textEditApp = getOrLaunchTextEdit() else {
            writeResult(recognized: "", documentText: "", error: "无法启动 TextEdit")
            completion(1)
            return
        }
        textEditApp.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.5)

        let accumulated = NSMutableString()
        let asr = VolcanoASR()
        asr.start(
            onText: { text in
                DispatchQueue.main.async { accumulated.setString(text) }
            },
            onError: { err in
                writeResult(recognized: accumulated as String, documentText: "", error: err.localizedDescription)
                completion(1)
            },
            onReady: {
                sendPCMInChunks(asr: asr, data: pcmData) {
                    asr.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        let text = (accumulated as String).trimmingCharacters(in: .whitespacesAndNewlines)
                        PasteboardPaste.paste(text: text, activateTarget: textEditApp)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            let docText = getTextEditDocument1Content()
                            let ok = !text.isEmpty && docText.contains(text)
                            writeResult(recognized: text, documentText: docText, error: ok ? nil : "文档中未找到识别结果")
                            completion(ok ? 0 : 1)
                        }
                    }
                }
            }
        )
    }

    private static func sendPCMInChunks(asr: VolcanoASR, data: Data, completion: @escaping () -> Void) {
        var offset = 0
        func sendNext() {
            if offset >= data.count {
                completion()
                return
            }
            let end = min(offset + chunkSize, data.count)
            let isLast = end >= data.count
            asr.sendPCM(data.subdata(in: offset..<end))
            if isLast {
                completion()
                return
            }
            offset = end
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(chunkDelayMs) / 1000.0) { sendNext() }
        }
        sendNext()
    }

    /// E2E 麦克风测试：自动开始录音，N 秒后自动停止并粘贴到 TextEdit（无需用户点开始/停止）
    static func runMic(seconds: Int, completion: @escaping (Int) -> Void) {
        try? FileManager.default.removeItem(atPath: "/tmp/voiceinput_e2e_requested")
        try? FileManager.default.removeItem(atPath: "/tmp/voiceinput_e2e_mic")
        try? "".write(toFile: "/tmp/voiceinput_e2e_started", atomically: true, encoding: .utf8)
        guard let textEditApp = getOrLaunchTextEdit() else {
            writeResult(recognized: "", documentText: "", error: "无法启动 TextEdit")
            completion(1)
            return
        }
        textEditApp.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.5)

        let accumulated = NSMutableString()
        var audioCapture: AudioCapture?
        let asr = VolcanoASR()
        asr.start(
            onText: { text in
                DispatchQueue.main.async { accumulated.setString(text) }
            },
            onError: { err in
                writeResult(recognized: accumulated as String, documentText: "", error: err.localizedDescription)
                completion(1)
            },
            onReady: {
                do {
                    let capture = AudioCapture()
                    audioCapture = capture
                    try capture.start { pcm in
                        asr.sendPCM(pcm)
                    }
                } catch {
                    writeResult(recognized: accumulated as String, documentText: "", error: "麦克风启动失败: \(error.localizedDescription)")
                    completion(1)
                    return
                }
                // N 秒后自动停止
                let sec = max(1, min(seconds, 30))
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(sec)) {
                    audioCapture?.stop()
                    audioCapture = nil
                    asr.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        let text = (accumulated as String).trimmingCharacters(in: .whitespacesAndNewlines)
                        PasteboardPaste.paste(text: text, activateTarget: textEditApp)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            let docText = getTextEditDocument1Content()
                            let ok = !text.isEmpty && docText.contains(text)
                            writeResult(recognized: text, documentText: docText, error: ok ? nil : "文档中未找到识别结果")
                            completion(ok ? 0 : 1)
                        }
                    }
                }
            }
        )
    }
}
