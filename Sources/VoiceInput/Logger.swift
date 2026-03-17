import Foundation

/// 同时输出到控制台和 ~/Library/Logs/VoiceInput.log，便于排查问题
enum Log {
    static var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoiceInput.log")
    }
    private static let logPath = logFileURL
    private static let queue = DispatchQueue(label: "com.voiceinput.log")
    
    static func log(_ message: String, file: String = #file, line: Int = #line) {
        let name = (file as NSString).lastPathComponent
        let lineStr = "[\(name):\(line)] \(message)"
        let full = "\(isoDate()) \(lineStr)"
        print(full)
        queue.async {
            guard let data = (full + "\n").data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logPath.path) {
                if let f = FileHandle(forWritingAtPath: logPath.path) {
                    f.seekToEndOfFile()
                    f.write(data)
                    try? f.close()
                }
            } else {
                try? data.write(to: logPath)
            }
        }
    }
    
    private static func isoDate() -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f.string(from: Date())
    }
}
