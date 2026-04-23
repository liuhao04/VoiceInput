import Foundation

/// 凭证存储：`~/Library/Application Support/<CFBundleName>/credentials.json`
///
/// 替代 Keychain。原因见 CLAUDE.md "Keychain: Don't Use It" —— macOS Developer ID
/// 签名 + 非沙盒 + 无 provisioning profile 条件下 Keychain 不存在"不弹窗"方案。
///
/// 威胁模型说明：明文 JSON + chmod 0600。同用户会话下其他 app 能读，和 legacy
/// Keychain 在 ACL=open 时等价；磁盘层面依赖用户 FileVault。对本项目（单用户家
/// 用工具）足够。需更强保护请走 sandbox + Data Protection Keychain 路径。
enum CredentialsStore {
    /// 当前 bundle 的 credentials.json 路径。CFBundleName 区分 Personal/Distribution：
    /// - Distribution: `~/Library/Application Support/VoiceInput/credentials.json`
    /// - Personal:     `~/Library/Application Support/VoiceInput Personal/credentials.json`
    static var fileURL: URL {
        fileURL(forBundleName: currentBundleName)
    }

    /// 指定 bundle name 的 file URL（用于 Personal 迁移时读 Distribution 数据）
    static func fileURL(forBundleName name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(name, isDirectory: true)
        return dir.appendingPathComponent("credentials.json")
    }

    private static var currentBundleName: String {
        (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "VoiceInput"
    }

    static func load() -> [String: String] {
        load(from: fileURL)
    }

    static func load(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// 原子写 + chmod 0600。失败抛异常（迁移逻辑依赖写成功与否决定后续动作）。
    static func save(_ map: [String: String]) throws {
        let url = fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(map)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func get(_ key: String) -> String? {
        let value = load()[key]
        return (value?.isEmpty == false) ? value : nil
    }

    static func set(_ key: String, _ value: String) {
        var map = load()
        if value.isEmpty {
            map.removeValue(forKey: key)
        } else {
            map[key] = value
        }
        do {
            try save(map)
        } catch {
            Log.log("[CredStore] save failed: \(error)")
        }
    }
}
