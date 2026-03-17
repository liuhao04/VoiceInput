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

    /// 用于显示的时间字符串
    var displayTime: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: time)
    }
}

enum RecognitionHistory {
    private static let historyDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/VoiceInput/history")
    }()

    /// 确保目录存在
    private static func ensureDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: historyDir.path) {
            try? fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        }
    }

    /// 当月文件名，如 2026-03.jsonl
    private static func filename(year: Int, month: Int) -> String {
        String(format: "%04d-%02d.jsonl", year, month)
    }

    /// 当月文件路径
    private static func filePath(year: Int, month: Int) -> URL {
        historyDir.appendingPathComponent(filename(year: year, month: month))
    }

    /// 追加一条记录。originalText 为 ASR 原始结果，text 为实际插入的文本（可能经用户编辑）
    static func append(text: String, app: String, originalText: String? = nil) {
        ensureDirectory()

        // 如果 originalText 与 text 不同，记录编辑后的文本
        let edited: String? = if let orig = originalText, orig != text { text } else { nil }
        let recorded = originalText ?? text
        let entry = HistoryEntry(text: recorded, app: app, edited: edited)

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
        let now = Date()
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        let path = filePath(year: year, month: month)

        if let handle = try? FileHandle(forWritingTo: path) {
            handle.seekToEndOfFile()
            if let d = line.data(using: .utf8) {
                handle.write(d)
            }
            handle.closeFile()
        } else {
            // 文件不存在，创建
            try? line.data(using: .utf8)?.write(to: path)
        }

        Log.log("[History] 已记录: \(text.prefix(30))... → \(app)")
    }

    /// 加载指定月份的记录
    static func load(year: Int, month: Int) -> [HistoryEntry] {
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
}
