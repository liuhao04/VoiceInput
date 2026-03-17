import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.voiceinput.mac"

    static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // Delete existing item first (ignore errors)
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        // 创建无限制的 ACL：不绑定任何可信应用（trusted application list 为空数组时
        // 表示"任何应用都可访问"），避免 cdhash 变化后弹出钥匙串授权提示。
        // 注意：SecAccessCreate 的第二个参数传 nil 时表示"仅限创建者"，
        // 传空数组 [] 时表示"任何应用都可访问且不弹提示"。
        var access: SecAccess?
        let accessStatus = SecAccessCreate("VoiceInput" as CFString, [] as CFArray, &access)
        if accessStatus == errSecSuccess, let access = access {
            addQuery[kSecAttrAccess as String] = access
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            Log.log("[Keychain] set \(key) failed: \(status)")
        }
    }

    static func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.log("[Keychain] get \(key) failed: \(status)")
        }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 重新写入现有条目，更新 ACL 为无限制（修复旧版绑定 cdhash 的问题）
    static func refreshACL(forKey key: String) {
        guard let value = get(forKey: key), !value.isEmpty else { return }
        set(value, forKey: key)
        Log.log("[Keychain] 已刷新 \(key) 的 ACL（无限制访问）")
    }
}
