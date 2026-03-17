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
    private static let keychainMigratedKey = "keychainMigrated"

    private static let keychainACLRefreshedKey = "keychainACLRefreshed_v1"

    /// 将旧的 UserDefaults 凭证迁移到 Keychain（只执行一次）
    static func migrateToKeychainIfNeeded() {
        // 第一步：UserDefaults → Keychain 迁移（兼容旧版本）
        if !UserDefaults.standard.bool(forKey: keychainMigratedKey) {
            if let oldAppId = UserDefaults.standard.string(forKey: volcAppIdKey), !oldAppId.isEmpty {
                KeychainHelper.set(oldAppId, forKey: volcAppIdKey)
                UserDefaults.standard.removeObject(forKey: volcAppIdKey)
            }
            if let oldToken = UserDefaults.standard.string(forKey: volcAccessTokenKey), !oldToken.isEmpty {
                KeychainHelper.set(oldToken, forKey: volcAccessTokenKey)
                UserDefaults.standard.removeObject(forKey: volcAccessTokenKey)
            }
            if let oldBoosting = UserDefaults.standard.string(forKey: boostingTableIdKey), !oldBoosting.isEmpty {
                KeychainHelper.set(oldBoosting, forKey: boostingTableIdKey)
                UserDefaults.standard.removeObject(forKey: boostingTableIdKey)
            }
            if let oldReplace = UserDefaults.standard.string(forKey: replaceWordsIdKey), !oldReplace.isEmpty {
                KeychainHelper.set(oldReplace, forKey: replaceWordsIdKey)
                UserDefaults.standard.removeObject(forKey: replaceWordsIdKey)
            }
            UserDefaults.standard.set(true, forKey: keychainMigratedKey)
            Log.log("[Config] 已将凭证从 UserDefaults 迁移到 Keychain")
        }

        // 第二步：刷新 Keychain ACL（只执行一次）
        // 旧条目的 ACL 绑定了创建者的 cdhash，每次重编译后 cdhash 改变，
        // macOS 会弹出"想要使用钥匙串中的机密信息"提示。
        // 通过 refreshACL 重新写入条目，使用空的 trusted application list，
        // 表示"任何应用都可访问"，不再绑定特定 cdhash。
        if !UserDefaults.standard.bool(forKey: keychainACLRefreshedKey) {
            let keysToRefresh = [volcAppIdKey, volcAccessTokenKey, boostingTableIdKey, replaceWordsIdKey]
            for key in keysToRefresh {
                KeychainHelper.refreshACL(forKey: key)
            }
            UserDefaults.standard.set(true, forKey: keychainACLRefreshedKey)
            Log.log("[Config] 已刷新 Keychain ACL（无限制访问，不绑定 cdhash）")
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
        get { KeychainHelper.get(forKey: volcAppIdKey) ?? envVolcAppId ?? "" }
        set { KeychainHelper.set(newValue, forKey: volcAppIdKey) }
    }

    static var volcAccessToken: String {
        get { KeychainHelper.get(forKey: volcAccessTokenKey) ?? envVolcAccessToken ?? "" }
        set { KeychainHelper.set(newValue, forKey: volcAccessTokenKey) }
    }

    static var boostingTableId: String {
        get { KeychainHelper.get(forKey: boostingTableIdKey) ?? envBoostingTableId ?? "" }
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
}
