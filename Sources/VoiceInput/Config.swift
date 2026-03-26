import Foundation
import Carbon.HIToolbox

/// 可配置的触发键（均为修饰键，单独按下并释放时触发）
enum TriggerKey: String, CaseIterable {
    case fn = "fn"
    case control = "control"
    case leftOption = "leftOption"
    case leftCommand = "leftCommand"
    case rightCommand = "rightCommand"
    case rightOption = "rightOption"

    var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .control: return "Control"
        case .leftOption: return "左Option"
        case .leftCommand: return "左Command"
        case .rightCommand: return "右Command"
        case .rightOption: return "右Option"
        }
    }

    /// CGEventFlags 中对应的 bit mask
    var cgFlag: CGEventFlags {
        switch self {
        case .fn: return CGEventFlags(rawValue: UInt64(NX_SECONDARYFNMASK))
        case .control: return .maskControl
        case .leftOption, .rightOption: return .maskAlternate
        case .leftCommand, .rightCommand: return .maskCommand
        }
    }

    /// 用于区分左右的 IOKit raw key flag（NX_DEVICE* 常量）
    var deviceFlag: UInt64 {
        switch self {
        case .fn: return UInt64(NX_SECONDARYFNMASK)
        case .control: return UInt64(NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK)
        case .leftOption: return UInt64(NX_DEVICELALTKEYMASK)
        case .rightOption: return UInt64(NX_DEVICERALTKEYMASK)
        case .leftCommand: return UInt64(NX_DEVICELCMDKEYMASK)
        case .rightCommand: return UInt64(NX_DEVICERCMDKEYMASK)
        }
    }
}

enum Config {
    // MARK: - 默认值（环境变量 → Keychain/UserDefaults → 内置默认）
    // 注意：敏感凭证（App ID、Access Token）存储在 macOS Keychain 中
    // 非敏感配置仍使用 UserDefaults
    // 也可通过环境变量设置：VOLC_APP_ID, VOLC_ACCESS_TOKEN, VOLC_BOOSTING_TABLE_ID
    private static let envVolcAppId = ProcessInfo.processInfo.environment["VOLC_APP_ID"]
    private static let envVolcAccessToken = ProcessInfo.processInfo.environment["VOLC_ACCESS_TOKEN"]
    private static let envBoostingTableId = ProcessInfo.processInfo.environment["VOLC_BOOSTING_TABLE_ID"]
    private static let defaultVolcResourceId = "volc.seedasr.sauc.duration"
    private static let defaultAsrWebSocketURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    private static let defaultReplaceWordsId = ""

    // MARK: - Keys
    private static let hotkeyDefaultsKey = "triggerKeys"
    private static let volcAppIdKey = "volcAppId"
    private static let volcAccessTokenKey = "volcAccessToken"
    private static let volcResourceIdKey = "volcResourceId"
    private static let asrWebSocketURLKey = "asrWebSocketURL"
    private static let boostingTableIdKey = "boostingTableId"
    private static let replaceWordsIdKey = "replaceWordsId"
    private static let replaceRulesFilePathKey = "replaceRulesFilePath"

    /// 固定 key（不含 build 号），确保 ACL 修复只执行一次
    private static let aclFixedKey = "keychainACLFixed_v1"

    /// 启动时执行一次性迁移/修复
    ///
    /// 1. UserDefaults → Keychain（兼容最早版本）
    /// 2. 修复旧 Keychain 条目的 ACL：read → delete → re-add with open ACL
    ///    读取旧条目可能弹窗（最多 3 次），但修复后永不再弹。
    ///    使用固定 key 标记，确保整个过程只执行一次。
    static func migrateToKeychainIfNeeded() {
        // 第一步：UserDefaults → Keychain（只执行一次，与之前逻辑相同）
        let udMigratedKey = "keychainMigrated"
        if !UserDefaults.standard.bool(forKey: udMigratedKey) {
            let keys = [volcAppIdKey, volcAccessTokenKey, boostingTableIdKey, replaceWordsIdKey]
            for key in keys {
                if let old = UserDefaults.standard.string(forKey: key), !old.isEmpty {
                    KeychainHelper.set(old, forKey: key)
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            UserDefaults.standard.set(true, forKey: udMigratedKey)
            Log.log("[Config] 已将凭证从 UserDefaults 迁移到 Keychain")
        }

        // 第二步：修复旧条目 ACL（只执行一次，固定 key 不含 build 号）
        // 旧条目的 ACL 绑定了创建者的 cdhash，每次重编译后 cdhash 改变，
        // macOS 会弹出钥匙串授权提示。
        // 修复方式：读取值 → 删除旧条目 → 用无限制 ACL 重新创建。
        // SecItemDelete 不检查 ACL（不弹窗），SecItemAdd 创建新条目带 open ACL。
        // 只有 read 步骤可能弹窗，但只执行这一次。
        if !UserDefaults.standard.bool(forKey: aclFixedKey) {
            let keys = [volcAppIdKey, volcAccessTokenKey, boostingTableIdKey, replaceWordsIdKey]
            for key in keys {
                // get 读取旧值（可能弹窗）
                guard let value = KeychainHelper.get(forKey: key) else { continue }
                // delete 旧条目（不弹窗）
                KeychainHelper.delete(forKey: key)
                // set 重新创建（带 open ACL，不弹窗）
                KeychainHelper.set(value, forKey: key)
                Log.log("[Config] 已修复 \(key) 的 ACL")
            }
            UserDefaults.standard.set(true, forKey: aclFixedKey)
            Log.log("[Config] Keychain ACL 修复完成（后续构建不再弹窗）")
        }
    }

    /// 从 Info.plist 读取（短版本 + 构建号），未打包时返回开发版本
    static var appVersion: String {
        let short = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let b = build, !b.isEmpty { return "\(short).\(b)" }
        return short
    }

    /// 当前已启用的触发键（持久化到 UserDefaults）
    static var triggerKeys: Set<TriggerKey> {
        get {
            guard let raw = UserDefaults.standard.stringArray(forKey: hotkeyDefaultsKey) else {
                return [.rightOption]  // 默认值
            }
            return Set(raw.compactMap { TriggerKey(rawValue: $0) })
        }
        set {
            let raw = newValue.map { $0.rawValue }
            UserDefaults.standard.set(raw, forKey: hotkeyDefaultsKey)
        }
    }

    // MARK: - 敏感凭证（Keychain 存储，环境变量可覆盖）

    static var volcAppId: String {
        get { envVolcAppId ?? KeychainHelper.get(forKey: volcAppIdKey) ?? "" }
        set { KeychainHelper.set(newValue, forKey: volcAppIdKey) }
    }

    static var volcAccessToken: String {
        get { envVolcAccessToken ?? KeychainHelper.get(forKey: volcAccessTokenKey) ?? "" }
        set { KeychainHelper.set(newValue, forKey: volcAccessTokenKey) }
    }

    static var boostingTableId: String {
        get { envBoostingTableId ?? KeychainHelper.get(forKey: boostingTableIdKey) ?? "" }
        set { KeychainHelper.set(newValue, forKey: boostingTableIdKey) }
    }

    static var replaceWordsId: String {
        get { KeychainHelper.get(forKey: replaceWordsIdKey) ?? "" }
        set { KeychainHelper.set(newValue, forKey: replaceWordsIdKey) }
    }

    // MARK: - 非敏感配置（UserDefaults 存储）

    static var volcResourceId: String {
        get { UserDefaults.standard.string(forKey: volcResourceIdKey) ?? defaultVolcResourceId }
        set { UserDefaults.standard.set(newValue, forKey: volcResourceIdKey) }
    }

    static var asrWebSocketURL: String {
        get { UserDefaults.standard.string(forKey: asrWebSocketURLKey) ?? defaultAsrWebSocketURL }
        set { UserDefaults.standard.set(newValue, forKey: asrWebSocketURLKey) }
    }

    static var replaceRulesFilePath: String {
        get { UserDefaults.standard.string(forKey: replaceRulesFilePathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: replaceRulesFilePathKey) }
    }
}
