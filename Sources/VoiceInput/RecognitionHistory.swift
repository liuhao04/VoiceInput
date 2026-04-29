import AppKit
import Foundation

struct HistoryEntry: Codable {
    let time: Date
    let text: String
    let app: String
    /// 手动编辑后的文本，仅当用户修改了识别结果时才有值
    let edited: String?

    private enum CodingKeys: String, CodingKey {
        case time, text, app, edited
    }

    init(time: Date = Date(), text: String, app: String, edited: String? = nil) {
        self.time = time
        self.text = text
        self.app = app
        self.edited = edited
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timeStr = try container.decode(String.self, forKey: .time)
        time = HistoryEntry.dateFormatter.date(from: timeStr) ?? Date()
        text = try container.decode(String.self, forKey: .text)
        app = try container.decode(String.self, forKey: .app)
        edited = try container.decodeIfPresent(String.self, forKey: .edited)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(HistoryEntry.dateFormatter.string(from: time), forKey: .time)
        try container.encode(text, forKey: .text)
        try container.encode(app, forKey: .app)
        try container.encodeIfPresent(edited, forKey: .edited)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    /// 用于显示的时间字符串
    var displayTime: String {
        Self.displayFormatter.string(from: time)
    }
}

enum RecognitionHistory {
    private static let queue = DispatchQueue(label: "com.voiceinput.history")

    private static let iCloudHistoryDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/VoiceInput/history")
    }()

    private static let localHistoryDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "VoiceInput")
            .appendingPathComponent("history")
    }()

    static var historyDir: URL {
        switch Config.historyStorageLocation {
        case .iCloud: return iCloudHistoryDir
        case .local: return localHistoryDir
        }
    }

    static var directoryDescription: String {
        switch Config.historyStorageLocation {
        case .iCloud: return "iCloud Drive"
        case .local: return "仅本地"
        }
    }

    /// 确保目录存在
    @discardableResult
    static func ensureDirectory() -> URL {
        let fm = FileManager.default
        let historyDir = historyDir
        if !fm.fileExists(atPath: historyDir.path) {
            try? fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        }
        return historyDir
    }

    /// 当月文件名，如 2026-03.jsonl
    private static func filename(year: Int, month: Int) -> String {
        String(format: "%04d-%02d.jsonl", year, month)
    }

    /// 当月文件路径
    private static func filePath(year: Int, month: Int) -> URL {
        historyDir.appendingPathComponent(filename(year: year, month: month))
    }

    /// 追加一条记录。originalText 为 ASR 原始结果，text 为实际插入的文本（可能经用户编辑）。
    /// 历史目录位于 iCloud Drive，文件系统偶尔会同步阻塞；写入放到后台队列避免卡住菜单栏 UI。
    static func append(text: String, app: String, originalText: String? = nil) {
        guard Config.historyEnabled else {
            Log.log("[History] 历史记录已关闭，跳过写入")
            return
        }
        let entryTime = Date()
        queue.async {
            appendSync(text: text, app: app, originalText: originalText, time: entryTime)
        }
    }

    private static func appendSync(text: String, app: String, originalText: String?, time: Date) {
        ensureDirectory()

        // 如果 originalText 与 text 不同，记录编辑后的文本
        let edited: String? = if let orig = originalText, orig != text { text } else { nil }
        let recorded = originalText ?? text
        let entry = HistoryEntry(time: time, text: recorded, app: app, edited: edited)

        // 手动拼 JSON 以保证字段顺序：time, app, text, edited
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
             .replacingOccurrences(of: "\r", with: "\\r")
             .replacingOccurrences(of: "\t", with: "\\t")
        }
        let timeStr = HistoryEntry.dateFormatter.string(from: entry.time)
        var line = "{\"time\":\"\(esc(timeStr))\",\"app\":\"\(esc(entry.app))\",\"text\":\"\(esc(entry.text))\""
        if let ed = entry.edited {
            line += ",\"edited\":\"\(esc(ed))\""
        }
        line += "}\n"

        let cal = Calendar.current
        let year = cal.component(.year, from: time)
        let month = cal.component(.month, from: time)
        let path = filePath(year: year, month: month)

        if let handle = try? FileHandle(forWritingTo: path) {
            _ = try? handle.seekToEnd()
            if let d = line.data(using: .utf8) {
                try? handle.write(contentsOf: d)
            }
            try? handle.close()
        } else {
            // 文件不存在，创建
            try? line.data(using: .utf8)?.write(to: path)
        }

        Log.log("[History] 已记录: \(text.prefix(30))... → \(app)")
    }

    /// 加载指定月份的记录
    static func load(year: Int, month: Int) -> [HistoryEntry] {
        guard Config.historyEnabled else { return [] }
        let path = filePath(year: year, month: month)
        guard let data = try? String(contentsOf: path, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        var entries: [HistoryEntry] = []
        for line in data.components(separatedBy: "\n") where !line.isEmpty {
            if let lineData = line.data(using: .utf8),
               let entry = try? decoder.decode(HistoryEntry.self, from: lineData) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// 扫描可用的月份，返回 [(year, month)] 按时间倒序
    static func availableMonths() -> [(year: Int, month: Int)] {
        guard Config.historyEnabled else { return [] }
        ensureDirectory()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: historyDir.path) else {
            return []
        }

        var months: [(year: Int, month: Int)] = []
        for file in files {
            // 匹配 YYYY-MM.jsonl
            guard file.hasSuffix(".jsonl"),
                  file.count == "YYYY-MM.jsonl".count else { continue }
            let name = String(file.dropLast(".jsonl".count))
            let parts = name.split(separator: "-")
            guard parts.count == 2,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]) else { continue }
            months.append((year: year, month: month))
        }

        // 按时间倒序
        months.sort { ($0.year, $0.month) > ($1.year, $1.month) }
        return months
    }

    static func openDirectory() {
        let directory = ensureDirectory()
        NSWorkspace.shared.open(directory)
    }

    static func clearCurrentStorage() -> Bool {
        var success = true
        queue.sync {
            let directory = ensureDirectory()
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                success = false
                return
            }
            for file in files where file.pathExtension == "jsonl" {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    success = false
                    Log.log("[History] 删除历史文件失败: \(file.path), error=\(error.localizedDescription)")
                }
            }
        }
        if success {
            Log.log("[History] 已清空当前历史目录: \(historyDir.path)")
        }
        return success
    }
}
