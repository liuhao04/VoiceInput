import Foundation
import os

/// 同时输出到控制台、os.Logger (Console.app) 和 ~/Library/Logs/VoiceInput.log
enum Log {
    /// 系统日志：自动集成到 Console.app，支持日志级别和搜索
    private static let osLogger = os.Logger(subsystem: "com.voiceinput.mac", category: "general")
    static var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoiceInput.log")
    }
    private static let logPath = logFileURL
    private static let queue = DispatchQueue(label: "com.voiceinput.log")
    /// 写入计数器，每 100 次检查一次文件大小
    private static var writeCount: UInt = 0
    private static let maxLogSize: UInt64 = 5_000_000 // 5MB
    private static let rotateCheckInterval: UInt = 100

    static func log(_ message: String, file: String = #file, line: Int = #line) {
        let name = (file as NSString).lastPathComponent
        let lineStr = "[\(name):\(line)] \(message)"
        let full = "\(isoDate()) \(lineStr)"
        print(full)
        // 同时输出到 Console.app（根据内容判断日志级别）
        if message.contains("❌") || message.contains("失败") || message.contains("error") {
            osLogger.error("\(lineStr)")
        } else {
            osLogger.info("\(lineStr)")
        }
        queue.async {
            guard let data = (full + "\n").data(using: .utf8) else { return }

            // 定期检查日志文件大小，超过阈值时轮转
            writeCount += 1
            if writeCount % rotateCheckInterval == 0 {
                rotateIfNeeded()
            }

            if FileManager.default.fileExists(atPath: logPath.path) {
                if let f = try? FileHandle(forWritingTo: logPath) {
                    _ = try? f.seekToEnd()
                    try? f.write(contentsOf: data)
                    try? f.close()
                }
            } else {
                try? data.write(to: logPath)
            }
        }
    }

    /// 日志轮转：超过 maxLogSize 时将当前日志重命名为 .old.log
    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath.path),
              let size = attrs[.size] as? UInt64, size > maxLogSize else { return }
        let oldPath = logPath.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: oldPath)
        try? FileManager.default.moveItem(at: logPath, to: oldPath)
    }
    
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    private static func isoDate() -> String {
        isoFormatter.string(from: Date())
    }
}
