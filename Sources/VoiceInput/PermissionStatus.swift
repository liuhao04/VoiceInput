import AppKit
import AVFoundation
import Foundation

// MARK: - 权限状态：可测的纯逻辑部分
//
// 2026-09-03 的事故：朋友装 1.1.0 后快捷键完全不响应。根因是 event tap 只在启动时创建一次，
// 她是启动之后才授予辅助功能权限的，那个 tap 从此处于"存在但收不到事件"的僵死态。
// 日志里 tap 创建时照打 ✅（权限没给也打），界面零反馈，她盲切了 10 次触发键才来问。
// 这里把三件事的判定抽成纯函数，便于用测试钉死：
//   1. 权限从未授权变为已授权 → 必须重建 tap（PermissionTransitionTracker）
//   2. tap 创建日志按真实权限如实标注（HotkeyTapLog）
//   3. 菜单栏 / 设置里常驻显示的权限文案（PermissionStatusText）

extension Notification.Name {
    /// 辅助功能权限状态发生变化（授予或撤销）。object 为 Bool（当前是否已授权）。
    static let accessibilityPermissionChanged = Notification.Name("VoiceInput.accessibilityPermissionChanged")
}

/// 跟踪辅助功能权限的变迁，只报告"变化"，不报告"现状"。
/// 首次观察只记录基线，不算变化：启动时已授权不需要重建 tap（启动流程本身会建）。
struct PermissionTransitionTracker {
    enum Transition: Equatable {
        case granted
        case revoked
    }

    private(set) var lastTrusted: Bool?

    /// 喂入一次观察结果，返回本次是否构成变迁
    mutating func observe(trusted: Bool) -> Transition? {
        defer { lastTrusted = trusted }
        guard let previous = lastTrusted else { return nil }
        if previous == trusted { return nil }
        return trusted ? .granted : .revoked
    }
}

/// event tap 创建后的日志文案：✅ 只在权限真的到位时出现。
/// 此前无论权限有没有都打 ✅，日志在骗人，排查时完全看不出 tap 其实收不到事件。
enum HotkeyTapLog {
    static func creationLine(level: String, trusted: Bool, listenAccess: Bool) -> String {
        if trusted {
            return "[Hotkey] ✅ \(level) Event tap 已创建，辅助功能已授权（输入监控预检: \(listenAccess ? "通过" : "未通过")）"
        }
        return "[Hotkey] ⚠️ \(level) Event tap 已创建，但辅助功能未授权，此 tap 收不到按键事件；授权后会自动重建（输入监控预检: \(listenAccess ? "通过" : "未通过")）"
    }
}

/// 常驻状态文案（菜单栏菜单 + 设置界面共用，两处措辞一致）
enum PermissionStatusText {
    static func accessibility(trusted: Bool) -> String {
        trusted ? "辅助功能：已授权" : "辅助功能：未授权（快捷键无效）"
    }

    static func microphone(status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "麦克风：已授权"
        case .denied: return "麦克风：已拒绝（无法录音）"
        case .restricted: return "麦克风：受限（无法录音）"
        case .notDetermined: return "麦克风：尚未请求（首次录音时询问）"
        @unknown default: return "麦克风：状态未知"
        }
    }

    /// 设置界面里给未授权状态配的说明。重点是"不用重启"：旧文案让用户以为要重启，
    /// 而实际上重启也只是恰好让 tap 在有权限的状态下重建。
    static let accessibilityHint = "授权后立即生效，无需重启。macOS 的辅助功能权限是全局快捷键和插入文字的前提。"
}

/// 系统设置的权限面板 URL（macOS 13+ 的 x-apple.systempreferences scheme）
enum PermissionSettingsURL {
    static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let microphone = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}
