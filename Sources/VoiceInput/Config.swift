import Foundation
import Carbon.HIToolbox

/// 火山 ASR 模式。两个端点对应火山官方的两种使用方式，详见
/// 《大模型流式语音识别 API》：双向流式优化版为 bigmodel_async，
/// 流式输入模式为 bigmodel_nostream。两者参数组合不同（见 VolcanoASR）。
enum ASRMode: String, CaseIterable {
    case async      // /api/v3/sauc/bigmodel_async  双向流式（优化版）：边说边出字
    case nostream   // /api/v3/sauc/bigmodel_nostream  流式输入：负包或 ≥15s 后整段返回，准确率更高

    var displayName: String {
        switch self {
        case .async: return "双向流式（优化版） · 边说边出字"
        case .nostream: return "流式输入 · 整段返回，准确率更高"
        }
    }

    var endpointPath: String {
        switch self {
        case .async: return "/api/v3/sauc/bigmodel_async"
        case .nostream: return "/api/v3/sauc/bigmodel_nostream"
        }
    }
}

/// 通用快捷键绑定。用于：
/// - "粘贴最后识别结果"全局快捷键（必须带修饰键 + 普通键）
/// - 自定义触发键（只携带单修饰键 deviceFlag；keyCode=0 表示纯修饰键触发）
struct HotkeyBinding: Codable, Equatable {
    /// Carbon 虚拟键码。0 表示纯修饰键触发（不使用 keyCode）
    var keyCode: UInt32
    /// Carbon modifier flags（cmdKey | shiftKey | optionKey | controlKey）；仅在 keyCode != 0 时用
    var modifiers: UInt32
    /// 对于"单修饰键触发"，保存对应的 device-level HID flag（NX_DEVICELSHIFTKEYMASK 等）
    /// keyCode != 0 时此字段为 0
    var deviceFlag: UInt64
    /// UI 显示文案（例如 "⌘⇧V" 或 "Shift"）
    var displayName: String
}

/// 触发激活方式：单击或双击
enum TriggerActivation: String, Codable, CaseIterable {
    case singleTap, doubleTap
    var displayName: String {
        switch self {
        case .singleTap: return "单击"
        case .doubleTap: return "双击"
        }
    }
}

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
    // MARK: - 默认值（环境变量 → CredentialsStore → UserDefaults → 内置默认）
    // 敏感凭证（App ID / Access Token）存在 ~/Library/Application Support/<BundleName>/credentials.json
    // 非敏感配置用 UserDefaults
    // 也可通过环境变量设置：VOLC_APP_ID, VOLC_ACCESS_TOKEN, VOLC_BOOSTING_TABLE_ID
    private static let envVolcAppId = ProcessInfo.processInfo.environment["VOLC_APP_ID"]
    private static let envVolcAccessToken = ProcessInfo.processInfo.environment["VOLC_ACCESS_TOKEN"]
    private static let envBoostingTableId = ProcessInfo.processInfo.environment["VOLC_BOOSTING_TABLE_ID"]
    private static let defaultVolcResourceId = "volc.seedasr.sauc.duration"
    private static let asrWebSocketHost = "wss://openspeech.bytedance.com"
    private static let defaultReplaceWordsId = ""

    // MARK: - Keys
    private static let hotkeyDefaultsKey = "triggerKeys"
    private static let volcAppIdKey = "volcAppId"
    private static let volcAccessTokenKey = "volcAccessToken"
    private static let volcResourceIdKey = "volcResourceId"
    private static let asrModeKey = "asrMode"
    private static let legacyAsrWebSocketURLKey = "asrWebSocketURL"
    private static let boostingTableIdKey = "boostingTableId"
    private static let replaceWordsIdKey = "replaceWordsId"
    private static let replaceRulesFilePathKey = "replaceRulesFilePath"
    private static let pasteLastHotkeyKey = "pasteLastHotkey"
    private static let customTriggerBindingsKey = "customTriggerBindings"
    private static let triggerActivationKey = "triggerActivation"

    /// Personal 版"从分发版迁移 UserDefaults"只执行一次的标记
    private static let personalMigrationKey = "personalMigratedFromDistribution_v1"

    /// 从旧版 `asrWebSocketURL` 字符串迁移到 `asrMode` 枚举，只执行一次
    private static let asrModeMigrationKey = "asrModeMigratedFromURL_v1"

    /// 分发版固定 bundle ID（用于 Personal 版迁移源识别）
    private static let distributionBundleID = "com.voiceinput.mac"

    /// 启动时执行一次性 UserDefaults 迁移。凭证存储走 CredentialsStore 文件，
    /// 完全不碰 macOS Keychain（原因见 CLAUDE.md "Keychain: Don't Use It"），
    /// 所以这里没有 Keychain 读写路径。
    static func migrateOnLaunchIfNeeded() {
        migrateAsrModeFromLegacyURLIfNeeded()
        migratePersonalFromDistributionIfNeeded()
    }

    /// 旧版本让用户手填完整 WebSocket URL。现在改成在"双向流式优化版"与"流式输入"之间
    /// 二选一的枚举。这里把旧 URL 里的端点后缀映射成模式，然后清掉旧 key。
    private static func migrateAsrModeFromLegacyURLIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: asrModeMigrationKey) else { return }
        if let legacy = UserDefaults.standard.string(forKey: legacyAsrWebSocketURLKey) {
            let mode: ASRMode = legacy.contains("bigmodel_nostream") ? .nostream : .async
            UserDefaults.standard.set(mode.rawValue, forKey: asrModeKey)
            UserDefaults.standard.removeObject(forKey: legacyAsrWebSocketURLKey)
            Log.log("[Config] 迁移 asrWebSocketURL=\(legacy) → asrMode=\(mode.rawValue)")
        }
        UserDefaults.standard.set(true, forKey: asrModeMigrationKey)
    }

    /// Personal 版首次启动时，从分发版拷贝 **UserDefaults**（触发键、语言、mode 等）。
    /// 凭证不在这里 —— 凭证用 CredentialsStore 文件独立存，不跨版本迁移。
    private static func migratePersonalFromDistributionIfNeeded() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let isPersonal = bundleID == "\(distributionBundleID).personal"
        guard isPersonal else { return }
        guard !UserDefaults.standard.bool(forKey: personalMigrationKey) else { return }

        if let oldDefaults = UserDefaults(suiteName: distributionBundleID) {
            if let triggerKeys = oldDefaults.stringArray(forKey: hotkeyDefaultsKey) {
                UserDefaults.standard.set(triggerKeys, forKey: hotkeyDefaultsKey)
            }
            if let resourceId = oldDefaults.string(forKey: volcResourceIdKey) {
                UserDefaults.standard.set(resourceId, forKey: volcResourceIdKey)
            }
            if let legacyURL = oldDefaults.string(forKey: legacyAsrWebSocketURLKey) {
                let mode: ASRMode = legacyURL.contains("bigmodel_nostream") ? .nostream : .async
                UserDefaults.standard.set(mode.rawValue, forKey: asrModeKey)
            } else if let modeRaw = oldDefaults.string(forKey: asrModeKey) {
                UserDefaults.standard.set(modeRaw, forKey: asrModeKey)
            }
            if let path = oldDefaults.string(forKey: replaceRulesFilePathKey) {
                UserDefaults.standard.set(path, forKey: replaceRulesFilePathKey)
            }
        }

        UserDefaults.standard.set(true, forKey: personalMigrationKey)
        Log.log("[Config] Personal 版已从分发版迁移 UserDefaults 配置")
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

    // MARK: - 敏感凭证（`~/Library/Application Support/<BundleName>/credentials.json` 存储，环境变量可覆盖）

    static var volcAppId: String {
        get { envVolcAppId ?? CredentialsStore.get(volcAppIdKey) ?? "" }
        set { CredentialsStore.set(volcAppIdKey, newValue) }
    }

    static var volcAccessToken: String {
        get { envVolcAccessToken ?? CredentialsStore.get(volcAccessTokenKey) ?? "" }
        set { CredentialsStore.set(volcAccessTokenKey, newValue) }
    }

    static var boostingTableId: String {
        get { envBoostingTableId ?? CredentialsStore.get(boostingTableIdKey) ?? "" }
        set { CredentialsStore.set(boostingTableIdKey, newValue) }
    }

    static var replaceWordsId: String {
        get { CredentialsStore.get(replaceWordsIdKey) ?? "" }
        set { CredentialsStore.set(replaceWordsIdKey, newValue) }
    }

    // MARK: - 非敏感配置（UserDefaults 存储）

    static var volcResourceId: String {
        get { UserDefaults.standard.string(forKey: volcResourceIdKey) ?? defaultVolcResourceId }
        set { UserDefaults.standard.set(newValue, forKey: volcResourceIdKey) }
    }

    static var asrMode: ASRMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: asrModeKey),
                  let mode = ASRMode(rawValue: raw) else { return .async }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: asrModeKey) }
    }

    /// 由 `asrMode` 派生的 WebSocket URL（只读）。
    static var asrWebSocketURL: String {
        asrWebSocketHost + asrMode.endpointPath
    }

    static var replaceRulesFilePath: String {
        get { UserDefaults.standard.string(forKey: replaceRulesFilePathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: replaceRulesFilePathKey) }
    }

    /// "粘贴最后识别结果"全局快捷键（可空，用户未配置时为 nil）
    static var pasteLastHotkey: HotkeyBinding? {
        get {
            guard let data = UserDefaults.standard.data(forKey: pasteLastHotkeyKey) else { return nil }
            return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
        }
        set {
            if let v = newValue, let data = try? JSONEncoder().encode(v) {
                UserDefaults.standard.set(data, forKey: pasteLastHotkeyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: pasteLastHotkeyKey)
            }
        }
    }

    /// 用户自定义触发键（当前版本只接受 deviceFlag != 0 的纯修饰键；keyCode/modifiers 忽略）
    static var customTriggerBindings: [HotkeyBinding] {
        get {
            guard let data = UserDefaults.standard.data(forKey: customTriggerBindingsKey) else { return [] }
            return (try? JSONDecoder().decode([HotkeyBinding].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: customTriggerBindingsKey)
            }
        }
    }

    /// 单击 / 双击激活方式（全局，作用于所有触发键）
    static var triggerActivation: TriggerActivation {
        get {
            guard let raw = UserDefaults.standard.string(forKey: triggerActivationKey),
                  let v = TriggerActivation(rawValue: raw) else { return .singleTap }
            return v
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: triggerActivationKey) }
    }
}
