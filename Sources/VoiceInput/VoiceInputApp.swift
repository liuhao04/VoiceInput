import AppKit
import AVFoundation
import Foundation
import UserNotifications

@main
struct VoiceInputApp {
    static func main() {
        let e2eRequested = CommandLine.arguments.contains("--e2e-test")
            || FileManager.default.fileExists(atPath: "/tmp/voiceinput_e2e_requested")
        if e2eRequested {
            NSApplication.shared.setActivationPolicy(.accessory)
            let micFile = "/tmp/voiceinput_e2e_mic"
            if FileManager.default.fileExists(atPath: micFile),
               let secData = try? Data(contentsOf: URL(fileURLWithPath: micFile)),
               let secStr = String(data: secData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let sec = Int(secStr), sec > 0 {
                E2ETest.runMic(seconds: sec) { exitCode in
                    exit(Int32(exitCode))
                }
            } else {
                E2ETest.run { exitCode in
                    exit(Int32(exitCode))
                }
            }
            RunLoop.main.run()
            return
        }
        Log.log("VoiceInput 进程启动")
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        Log.log("即将进入 run loop")
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var audioCapture: AudioCapture?
    private var asr: VolcanoASR?
    // 以下属性为 internal 以供 AppDelegate+Tests.swift extension 访问
    var isRecording = false
    var accumulatedText: String = ""
    /// 最近一次可复用的非空识别结果（ASR 原文或编辑后文本，包括按 ESC 取消插入的文本）。
    /// 供"粘贴最后识别结果"全局快捷键使用。Personal / Distribution 两版独立存储，互不共享。
    var lastRecognitionResult: String = ""
    /// 本 app 在后台时记录的前台应用，粘贴时先激活它再注入，否则注入会发到本 app 无效
    var lastFrontmostApp: NSRunningApplication?
    var frontmostCaptureTimer: DispatchSourceTimer?
    var inputPanel: VoiceInputPanel?
    /// 录音期间监听前台 App 切换，把面板可见性绑定到目标 App
    private var appActivationObserver: NSObjectProtocol?
    /// 测试模式专用：保存固定的目标应用（避免被 menuWillOpen 等自动更新）
    var testTargetApp: NSRunningApplication?
    /// 编辑模式专用：进入编辑模式时保存的目标应用（防止编辑过程中被定时器更新）
    var editModeTargetApp: NSRunningApplication?

    // MARK: - AI 修正

    /// 是否正在等待大模型修正结果（面板停留、尚未粘贴）
    var isCorrecting = false
    /// 放弃当前修正的闭包（ESC / 再次按触发键时调用）
    var abortCorrection: (() -> Void)?
    /// 本轮的 ASR 原始结果，用于历史里的「识别结果」一列
    var asrOriginalText: String = ""
    /// 本轮模型给出的修正结果（用户点过「修正」且模型确实改了才有值）
    var correctionResult: String?
    /// 录音中点了「修正」：先停录音，等识别落定后自动接着修正
    var correctAfterRecognition = false
    /// 最近几次实际采纳的输入，作为修正的上下文。
    /// 采纳的文本已经是"用户手改 > 模型修正 > ASR 原文"的最终结果，正是上下文该用的版本。
    /// 持久化在 UserDefaults（见 Config.recentContextEntries），重启后仍在；
    /// 刻意不读识别历史文件，历史默认在 iCloud，同步阻塞会拖慢粘贴这条关键路径。
    var recentContext: [String] {
        TextCorrector.freshContext(Config.recentContextEntries).map { $0.text }
    }

    // MARK: - 全局快捷键
    private var hotkeyTap: CFMachPort?
    /// tap 挂在主 run loop 上的 source，重建 tap 时要先摘掉，否则旧 source 泄漏
    private var hotkeyRunLoopSource: CFRunLoopSource?

    // MARK: - 辅助功能权限监视
    //
    // event tap 在辅助功能未授权时也能创建成功，但收不到任何按键事件，而且之后授权也不会
    // 让它活过来（1.1.0 朋友的机器就是这样：启动后才授权，快捷键从此彻底失灵）。
    // 所以要盯着权限变化，未授权→已授权时把 tap 拆了重建。
    private var permissionTracker = PermissionTransitionTracker()
    private var permissionPollTimer: DispatchSourceTimer?
    private var accessibilityDistributedObserver: NSObjectProtocol?
    /// 菜单里常驻的两条权限状态项，menuWillOpen 时刷新
    private var accessibilityStatusItem: NSMenuItem?
    private var microphoneStatusItem: NSMenuItem?
    /// 记录上次 flagsChanged 时按下的修饰键集合，用于判断"单独按下并释放"
    private var activeModifiers: UInt64 = 0
    /// 当修饰键按下后如果有其他普通键按下，则标记为组合操作，释放时不触发
    private var otherKeyPressed = false
    /// 记录按下修饰键时的设备级 flags，用于释放时匹配
    private var pendingTrigger: ActiveTrigger?
    /// 记录在触发键按下期间是否曾经有过其他修饰键同时存在（用于过滤 Karabiner 等工具的合成事件）
    private var hadOtherModsDuringPending = false
    /// 触发键按下瞬间已经存在的 HID-only 普通键状态。只忽略这批旧状态，避免放过触发期间新出现的组合键。
    private var pendingStaleHIDOnlyKeys: Set<CGKeyCode> = []

    // otherModsFirstSeen 已移除：不再容忍瞬态干扰，只要出现过其他修饰键就阻止触发
    /// 触发键按下的时间戳，用于过滤过短的合成事件
    private var pendingTriggerTime: CFAbsoluteTime = 0
    /// 上次 toggleRecording 的时间戳，用于防抖（防止 Karabiner 等工具产生的快速连续触发）
    private var lastToggleTime: CFAbsoluteTime = 0
    /// 激活态的触发键：内置的 TriggerKey 或用户自定义的单修饰键 binding（两者等价参与检测循环）
    enum ActiveTrigger: Equatable {
        case builtin(TriggerKey)
        case custom(deviceFlag: UInt64, displayName: String)

        var deviceFlag: UInt64 {
            switch self {
            case .builtin(let k): return k.deviceFlag
            case .custom(let f, _): return f
            }
        }
        var displayName: String {
            switch self {
            case .builtin(let k): return k.displayName
            case .custom(_, let n): return n
            }
        }
    }

    /// NSEvent 全局监听器（Cocoa 层级），用于捕获 BTT 等工具消费后仍可见的键盘事件
    private var globalKeyMonitor: Any?
    /// NSEvent 全局鼠标监听器，防止 Option+鼠标点击（如终端移动光标）误触发语音识别
    private var globalMouseMonitor: Any?
    /// NSEvent 全局 systemDefined 监听器：捕获 F1/F2/F10 等系统键（亮度/音量/媒体）
    /// 这些键按下时 OS 发送 NSSystemDefined（subtype 8 = Aux Keys），
    /// 不走 CGEvent 的 keyDown 流，所以必须单独监听，否则 fn+F1 等组合会被当成"单独按 fn"误触发
    private var globalSystemDefinedMonitor: Any?
    /// 触发键上次释放的时间戳，用于检测 BTT 导致的快速释放-重按序列
    private var lastTriggerReleaseTime: CFAbsoluteTime = 0
    /// 上次释放的触发键，用于匹配释放-重按序列
    private var lastReleasedTrigger: ActiveTrigger?
    /// 双击匹配：上次"单击释放但未触发"的键 + 时间，用于在 doubleTap 模式下识别双击
    private var lastSingleTapTrigger: ActiveTrigger?
    private var lastSingleTapReleaseTime: CFAbsoluteTime = 0
    /// 当前 pending 是否因"识别到双击第二次按下"而被标记，释放时照常触发
    private var isDoubleTapPending: Bool = false
    /// 双击匹配的最大间隔（秒）
    private let doubleTapWindow: CFTimeInterval = 0.4

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("applicationDidFinishLaunching 开始")
        Config.migrateOnLaunchIfNeeded()
        setupMainMenu()
        setupMenuBar()
        Log.log("菜单栏已设置")
        setupGlobalHotkey()
        Log.log("全局快捷键已设置，触发键: \(Config.triggerKeys.map { $0.displayName })")
        registerPasteLastHotkey()
        registerCustomTriggerHotkeys()
        startAccessibilityPermissionMonitor()
        checkAccessibilityPermission()
        // 麦克风权限不在启动时预请求：LSUIElement（菜单栏常驻）应用从后台调用
        // AVCaptureDevice.requestAccess，TCC 守护进程会静默吞掉对话框，
        // 导致权限既未被授予也未被拒绝，用户看不到任何提示。
        // 改为在用户首次按快捷键录音时走 handleMicPermission，届时 NSApp.activate
        // 可以把自己提为前台，让 TCC 对话框正常显示。
        Log.log("麦克风授权状态: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (0=未确定, 1=受限, 2=拒绝, 3=已授权)")
        requestNotificationPermission()
        startFrontmostCaptureTimer()
        Log.log("applicationDidFinishLaunching 结束")

        // 检查是否是测试模式
        if CommandLine.arguments.contains("--test-panel-edit") {
            Log.log("[TEST] 检测到测试模式，1秒后启动测试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.runPanelEditTest()
            }
        } else if CommandLine.arguments.contains("--test-right-option") {
            Log.log("[TEST] 检测到右Option测试模式，1秒后启动测试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.runRightOptionTest()
            }
        } else if CommandLine.arguments.contains("--test-gemini") {
            Log.log("[TEST] 检测到 Gemini 测试模式，1秒后启动测试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.runGeminiTest()
            }
        } else if CommandLine.arguments.contains("--test-multi-monitor") {
            Log.log("[TEST] 检测到多显示器测试模式，1秒后启动测试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.runMultiMonitorTest()
            }
        } else if CommandLine.arguments.contains("--test-iterm2-monitor") {
            Log.log("[TEST] 检测到 iTerm2 多显示器测试模式，1秒后启动测试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.runITerm2MonitorTest()
            }
        } else if CommandLine.arguments.contains("--test-paste-smoke") {
            Log.log("[TEST] 检测到粘贴冒烟测试模式，1秒后启动测试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.runPasteSmokeTest()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isRecording {
            stopRecording()
        }
        if let m = globalSystemDefinedMonitor {
            NSEvent.removeMonitor(m)
            globalSystemDefinedMonitor = nil
        }
        permissionPollTimer?.cancel()
        permissionPollTimer = nil
        if let o = accessibilityDistributedObserver {
            DistributedNotificationCenter.default().removeObserver(o)
            accessibilityDistributedObserver = nil
        }
        GlobalHotkeyManager.shared.unregisterAll()
    }

    // MARK: - 辅助功能权限监视

    /// 轮询 + 系统通知双路监视辅助功能权限。
    /// 轮询开销：AXIsProcessTrusted 是本地缓存查询（不是每次都走 tccd XPC），2 秒一次可忽略；
    /// `com.apple.accessibility.api` 分布式通知在权限列表变动时即时到达，但它不带内容、
    /// 且未公开文档，所以只当加速器，不当唯一依据。
    private func startAccessibilityPermissionMonitor() {
        // 首次观察只记基线：启动时已授权不需要重建，setupGlobalHotkey 刚建过
        _ = permissionTracker.observe(trusted: AXIsProcessTrusted())

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in self?.pollAccessibilityPermission() }
        timer.resume()
        permissionPollTimer = timer

        accessibilityDistributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // tccd 落库到 AXIsProcessTrusted 读到新值之间有一小段延迟，稍等再查
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.pollAccessibilityPermission() }
        }
    }

    private func pollAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        guard let transition = permissionTracker.observe(trusted: trusted) else { return }
        switch transition {
        case .granted:
            Log.log("[Permission] 辅助功能权限已授予（进程运行中授权），重建 event tap")
            rebuildHotkeyTap(reason: "辅助功能权限授予")
        case .revoked:
            Log.log("[Permission] ⚠️ 辅助功能权限被撤销，快捷键将失效；重新授权后会自动重建 event tap")
        }
        refreshPermissionMenuItems()
        NotificationCenter.default.post(name: .accessibilityPermissionChanged, object: trusted)
    }

    /// 拆掉现有 tap（含 run loop source），重新创建。触发键检测状态一并清零。
    private func rebuildHotkeyTap(reason: String) {
        teardownHotkeyTap()
        pendingTrigger = nil
        otherKeyPressed = false
        hadOtherModsDuringPending = false
        activeModifiers = 0
        if createHotkeyTap() {
            Log.log("[Hotkey] event tap 已重建（原因: \(reason)）")
        } else {
            Log.log("[Hotkey] ❌ event tap 重建失败（原因: \(reason)）")
        }
    }

    private func teardownHotkeyTap() {
        if let tap = hotkeyTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = hotkeyRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        hotkeyTap = nil
        hotkeyRunLoopSource = nil
    }

    /// 后台时持续记录当前前台应用（非本 app），供停止时激活并注入文字
    private func startFrontmostCaptureTimer() {
        frontmostCaptureTimer?.cancel()
        frontmostCaptureTimer = nil
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // 录音中锁定目标 App，不被新前台应用顶替；否则切走时
            // 面板/粘贴目标都会跟随，破坏"绑定到目标 App"的约定
            if self.isRecording { return }
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.lastFrontmostApp = front
            }
        }
        timer.resume()
        frontmostCaptureTimer = timer
    }

    /// 录音中绑定面板到目标 App：用户切到别的 App 时隐藏面板，切回时再显示
    private func startPanelBindingObserver() {
        if appActivationObserver != nil { return }
        let center = NSWorkspace.shared.notificationCenter
        appActivationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self, let panel = self.inputPanel else { return }
            // 编辑模式下 VoiceInput 自身被激活，是预期行为，不动面板
            if panel.isEditing { return }
            guard let active = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let ownBundle = Bundle.main.bundleIdentifier
            if active.bundleIdentifier == ownBundle { return }
            let target = self.lastFrontmostApp
            if active.processIdentifier == target?.processIdentifier {
                panel.panel.orderFrontRegardless()
            } else {
                panel.panel.orderOut(nil)
            }
        }
    }

    private func stopPanelBindingObserver() {
        if let token = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            appActivationObserver = nil
        }
    }

    // MARK: - 全局快捷键实现

    private func setupGlobalHotkey() {
        guard createHotkeyTap() else { return }
        installGlobalEventMonitors()
    }

    /// 创建 CGEvent tap 并挂到主 run loop。可重复调用（权限变化后重建），调用前须先 teardownHotkeyTap。
    /// 返回是否创建成功。创建成功不等于能收到事件：辅助功能未授权时 tap 照样能建，只是收不到按键。
    @discardableResult
    private func createHotkeyTap() -> Bool {
        // 使用 CGEvent tap 监听 flagsChanged（修饰键变化）和 keyDown/keyUp（普通键按下/释放）
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        // C 函数回调，通过 userInfo 回调到 AppDelegate
        let callback: CGEventTapCallBack = { _, type, event, userInfo -> Unmanaged<CGEvent>? in
            guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = delegate.hotkeyTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    Log.log("[Hotkey] Event tap 被重新启用")
                }
                return Unmanaged.passRetained(event)
            }

            if type == .keyDown || type == .keyUp {
                if delegate.pendingTrigger != nil {
                    delegate.otherKeyPressed = true
                }
                // 回车键（keyCode 36）在录音中且面板可见时，停止录音并插入文本
                // 编辑模式下回车由 NSTextView 的 doCommandBy 处理
                if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 36 {
                    if delegate.inputPanel?.panel.isVisible == true,
                       delegate.inputPanel?.isEditing != true {
                        if delegate.isRecording {
                            Log.log("[Hotkey] 回车：停止录音")
                            DispatchQueue.main.async { delegate.stopRecording() }
                        } else if delegate.isCorrecting {
                            // 修正在途时回车：放弃修正，回到可插入状态
                            Log.log("[Hotkey] 回车：放弃修正")
                            DispatchQueue.main.async { delegate.abortCorrection?() }
                        } else {
                            // 识别完成 / diff 视图：回车即插入（diff 下插入的是修正版）
                            Log.log("[Hotkey] 回车：插入面板内容")
                            DispatchQueue.main.async { delegate.insertFromPanel() }
                        }
                    }
                }
                // ESC 键（keyCode 53）：关闭面板，不插入文字
                // 编辑模式下 ESC 由 NSTextView 的 doCommandBy 处理，这里不重复处理
                if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                    if delegate.inputPanel?.isEditing == true {
                        // 编辑模式：ESC 由 NSTextView 处理（追加识别取消 / 退出编辑）
                    } else if delegate.isCorrecting {
                        // 等修正结果时按 ESC：放弃修正，面板回到可插入状态（文本不丢）
                        Log.log("[Hotkey] 修正等待期按 ESC，放弃修正")
                        DispatchQueue.main.async {
                            delegate.abortCorrection?()
                        }
                    } else if delegate.isRecording || delegate.inputPanel?.panel.isVisible == true {
                        Log.log("[Hotkey] 检测到 ESC 键，取消录音")
                        DispatchQueue.main.async {
                            delegate.cancelRecording()
                        }
                    }
                }
                return Unmanaged.passRetained(event)
            }

            if type == .flagsChanged {
                delegate.handleFlagsChanged(event)
            }

            return Unmanaged.passRetained(event)
        }

        // 使用 .cghidEventTap 在 HID 系统层级监听，先于 BTT 等工具的 session-level event tap
        // 这样即使 BTT 消费了 keyDown 事件，我们在 HID 层已经看到了
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.log("[Hotkey] ❌ 无法创建 HID event tap，尝试 session 级别...")
            // 降级到 session 级别
            guard let sessionTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                Log.log("[Hotkey] ❌ 无法创建 event tap，辅助功能权限: \(AXIsProcessTrusted() ? "已授权" : "未授权")")
                return false
            }
            attachHotkeyTap(sessionTap, level: "Session-level（降级模式）")
            return true
        }

        attachHotkeyTap(tap, level: "HID-level")
        return true
    }

    /// 挂 run loop、启用，并按真实权限如实写日志。
    /// 以前这里无条件打 ✅，权限没给也打，排查时完全看不出 tap 其实是死的。
    private func attachHotkeyTap(_ tap: CFMachPort, level: String) {
        hotkeyTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        hotkeyRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.log(HotkeyTapLog.creationLine(
            level: level,
            trusted: AXIsProcessTrusted(),
            listenAccess: CGPreflightListenEventAccess()
        ))
    }

    /// NSEvent 全局监听器只装一次，tap 重建时不重复装
    private func installGlobalEventMonitors() {
        // 额外添加 NSEvent 全局监听器（Cocoa 层级）
        // BTT 等工具通过 active CGEvent tap 消费 keyDown 事件后，
        // listenOnly CGEvent tap 看不到这些事件，但 NSEvent 全局监听器可能仍能收到。
        // 这是第二道防线。
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self = self, self.pendingTrigger != nil else { return }
            self.otherKeyPressed = true
        }

        // NSEvent 鼠标监听器：防止 Option+鼠标点击（如终端中移动光标）误触发
        // 使用 NSEvent 全局监听器而非 CGEvent tap，不会干扰鼠标事件的正常传递
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self = self, self.pendingTrigger != nil else { return }
            self.otherKeyPressed = true
        }

        // NSEvent systemDefined 监听器：F1/F2/F10 等系统键（亮度/音量/媒体/键盘背光）
        // 按下时 OS 发 NSSystemDefined 事件，CGEvent tap 的 keyDown/keyUp 看不到。
        // pending 期间检测到这类按键 → 标记 otherKeyPressed，阻止误触发（如 fn+F1）。
        globalSystemDefinedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.systemDefined]) { [weak self] event in
            guard let self = self, self.pendingTrigger != nil else { return }
            // subtype 8 = Aux Keys（亮度、音量、媒体、键盘背光等），其他 subtype 忽略
            if event.subtype.rawValue == 8 {
                self.otherKeyPressed = true
            }
        }
    }

    /// 处理修饰键变化事件
    private func handleFlagsChanged(_ event: CGEvent) {
        let rawFlags = event.flags.rawValue
        let triggerKeys = Config.triggerKeys
        let customBindings = Config.customTriggerBindings

        if triggerKeys.isEmpty && customBindings.isEmpty { return }

        // 注意：Karabiner 合成事件的 keycode 不保留原始物理键值（如 Caps Lock→rightOption
        // 时 keycode=61 而非 57），因此不能用 keycode 区分合成 vs 真实。
        // 改用 otherMods 检测：Karabiner 映射总是同时产生多个修饰键事件。

        // 所有修饰键的 device-level flags 合集
        let allModifierDeviceFlags: UInt64 =
            UInt64(NX_SECONDARYFNMASK) |
            UInt64(NX_DEVICELCTLKEYMASK) | UInt64(NX_DEVICERCTLKEYMASK) |
            UInt64(NX_DEVICELALTKEYMASK) | UInt64(NX_DEVICERALTKEYMASK) |
            UInt64(NX_DEVICELCMDKEYMASK) | UInt64(NX_DEVICERCMDKEYMASK) |
            UInt64(NX_DEVICELSHIFTKEYMASK) | UInt64(NX_DEVICERSHIFTKEYMASK)

        let currentDeviceFlags = rawFlags & allModifierDeviceFlags

        // 记录每次 flags 变化的历史，用于检测 Karabiner 等工具的合成事件
        // 如果在很短时间内（< 50ms）连续出现多个修饰键变化，说明是合成的组合键
        let now = CFAbsoluteTimeGetCurrent()

        // 如果有 pending 触发键，检查是否出现了其他修饰键
        // Karabiner 将 Caps Lock 映射为 left_control + right_option 时，
        // 会产生 rightOption↓ → leftControl↓(~3ms后) → leftControl↑(~135ms后) → rightOption↑
        // 只要 pending 期间出现过任何其他修饰键，就标记为组合键，阻止触发。
        if let pending = pendingTrigger, !hadOtherModsDuringPending {
            let otherMods = currentDeviceFlags & ~pending.deviceFlag
            if otherMods != 0 {
                hadOtherModsDuringPending = true
            }
        }

        // 合并：内置触发键 + 用户自定义的单修饰键 binding（deviceFlag != 0 的视为有效）
        let allTriggers: [ActiveTrigger] =
            triggerKeys.map { ActiveTrigger.builtin($0) } +
            customBindings
                .filter { $0.deviceFlag != 0 }
                .map { ActiveTrigger.custom(deviceFlag: $0.deviceFlag, displayName: $0.displayName) }

        // 检测哪个触发键刚被按下（之前没有，现在有了）
        for trigger in allTriggers {
            let keyFlag = trigger.deviceFlag
            let wasDown = (activeModifiers & keyFlag) != 0
            let isDown = (currentDeviceFlags & keyFlag) != 0

            if isDown && !wasDown {
                // 修饰键刚按下：检查是否只有这一个修饰键被按下
                let otherModFlags = currentDeviceFlags & ~keyFlag
                if otherModFlags == 0 {
                    let isDoubleTapMode = (Config.triggerActivation == .doubleTap)
                    // BTT 快速释放-重按序列检测（单击模式适用；双击模式下此窗口会误伤用户真双击，跳过）
                    let timeSinceLastRelease = now - lastTriggerReleaseTime
                    if !isDoubleTapMode && lastReleasedTrigger == trigger && timeSinceLastRelease < 0.5 {
                        pendingTrigger = nil
                        hadOtherModsDuringPending = false
                        pendingStaleHIDOnlyKeys = []
                    } else {
                        pendingTrigger = trigger
                        pendingTriggerTime = now
                        otherKeyPressed = false
                        hadOtherModsDuringPending = false
                        pendingStaleHIDOnlyKeys = currentStaleHIDOnlyNonModifierKeys()
                        if !pendingStaleHIDOnlyKeys.isEmpty {
                            Log.log("[Hotkey] 记录触发前 stale HID-only 按键: \(pendingStaleHIDOnlyKeys.sorted())")
                        }
                        // 双击匹配：若本次按下的键恰好是上次"第 1 次释放"记录的键且在窗口内，标记 pending
                        if isDoubleTapMode,
                           lastSingleTapTrigger == trigger,
                           now - lastSingleTapReleaseTime < doubleTapWindow {
                            isDoubleTapPending = true
                        } else {
                            isDoubleTapPending = false
                        }
                    }
                } else {
                    // 有其他修饰键同时按下，不触发
                    pendingTrigger = nil
                    hadOtherModsDuringPending = false
                    pendingStaleHIDOnlyKeys = []
                }
            } else if !isDown && wasDown {
                // 修饰键刚释放：检查是否满足"单独按下并释放"条件
                if let pending = pendingTrigger, pending == trigger, !hadOtherModsDuringPending {
                    // 确认释放时没有其他修饰键仍被按下
                    let remainingMods = currentDeviceFlags & ~keyFlag
                    if remainingMods == 0 {
                        let holdDuration = now - pendingTriggerTime
                        let staleHIDOnlyKeys = pendingStaleHIDOnlyKeys
                        if holdDuration < 0.03 || otherKeyPressed || isAnyNonModifierKeyPressed(since: holdDuration, staleHIDOnlyKeys: staleHIDOnlyKeys) {
                            // 太短/组合键/HID检测到其他键，跳过
                        } else {
                            let hidKeyDown = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
                            let hidKeyUp = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyUp)
                            let csKeyDown = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                            let csKeyUp = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyUp)

                            let hadKeyEventDuringHold = hidKeyDown < holdDuration || hidKeyUp < holdDuration || csKeyDown < holdDuration || csKeyUp < holdDuration
                            if !hadKeyEventDuringHold {
                                let isDoubleTapMode = (Config.triggerActivation == .doubleTap)
                                // 双击模式下：第一次释放只记录时间，不触发；等第二次按下+释放
                                if isDoubleTapMode && !isDoubleTapPending {
                                    lastSingleTapTrigger = trigger
                                    lastSingleTapReleaseTime = now
                                } else {
                                    let triggerKeyName = trigger.displayName
                                    let isRec = isRecording
                                    let pendingStart = pendingTriggerTime
                                    let staleHIDOnlyKeys = pendingStaleHIDOnlyKeys
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                                        guard let self = self else { return }
                                        let totalElapsed = CFAbsoluteTimeGetCurrent() - pendingStart
                                        if self.otherKeyPressed || self.isAnyNonModifierKeyPressed(since: totalElapsed, staleHIDOnlyKeys: staleHIDOnlyKeys) {
                                            return
                                        }
                                        let dHidKD = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
                                        let dHidKU = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyUp)
                                        let dCsKD = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                                        let dCsKU = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyUp)
                                        let hadKeyEventDelayed = dHidKD < totalElapsed || dHidKU < totalElapsed || dCsKD < totalElapsed || dCsKU < totalElapsed
                                        if !hadKeyEventDelayed {
                                            Log.log("[Hotkey] 触发键 \(triggerKeyName) 确认触发, isRecording=\(isRec), mode=\(isDoubleTapMode ? "double" : "single")")
                                            self.toggleRecording()
                                        }
                                    }
                                    // 触发后清双击状态
                                    lastSingleTapTrigger = nil
                                    isDoubleTapPending = false
                                }
                            }
                        }
                    } else {
                    }
                }
                // 记录释放时间和释放的键，用于检测 BTT 快速释放-重按序列
                lastTriggerReleaseTime = now
                lastReleasedTrigger = trigger
                pendingTrigger = nil
                hadOtherModsDuringPending = false
                pendingStaleHIDOnlyKeys = []
            }
        }

        activeModifiers = currentDeviceFlags
    }

    /// 检查当前是否有任何非修饰键被物理按下。
    /// HID 状态能看到被 BTT/Karabiner 等工具消费的按键，但有时 VirtualHID 会留下
    /// stale 的 HID-only 按下状态。只忽略触发键按下前已经存在的 stale baseline；
    /// 触发期间新出现的 HID-only 状态仍按组合键处理。
    /// 修饰键的 keyCode: 54/55=Cmd, 56/60=Shift, 58/61=Option, 59/62=Control, 57=CapsLock, 63=Fn
    private func isAnyNonModifierKeyPressed(since elapsed: CFTimeInterval, staleHIDOnlyKeys: Set<CGKeyCode>) -> Bool {
        let modifierKeyCodes: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        for keyCode: CGKeyCode in 0...126 {
            if modifierKeyCodes.contains(keyCode) { continue }
            guard CGEventSource.keyState(.hidSystemState, key: keyCode) else { continue }

            if CGEventSource.keyState(.combinedSessionState, key: keyCode) {
                Log.log("[Hotkey] HID+Session 状态表: keyCode=\(keyCode) 当前按下")
                return true
            }

            let hidKeyDown = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
            let hidKeyUp = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyUp)
            if hidKeyDown < elapsed || hidKeyUp < elapsed {
                Log.log("[Hotkey] HID 状态表: keyCode=\(keyCode) 当前按下（近期键盘事件，按组合键处理）")
                return true
            }

            if staleHIDOnlyKeys.contains(keyCode) {
                Log.log("[Hotkey] 忽略触发前 stale HID-only 按键状态: keyCode=\(keyCode)")
            } else {
                Log.log("[Hotkey] HID-only 状态表: keyCode=\(keyCode) 当前按下（非触发前 baseline，按组合键处理）")
                return true
            }
        }
        return false
    }

    private func currentStaleHIDOnlyNonModifierKeys() -> Set<CGKeyCode> {
        let modifierKeyCodes: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        var result = Set<CGKeyCode>()
        for keyCode: CGKeyCode in 0...126 {
            if modifierKeyCodes.contains(keyCode) { continue }
            if CGEventSource.keyState(.hidSystemState, key: keyCode),
               !CGEventSource.keyState(.combinedSessionState, key: keyCode) {
                result.insert(keyCode)
            }
        }
        return result
    }

    /// LSUIElement 应用没有主菜单栏，需要手动创建 Edit 菜单以支持 Cmd+C/V/X/A 等标准快捷键
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    private var statusMenu: NSMenu?

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        let menu = buildMenu()
        menu.delegate = self
        statusMenu = menu
        // 不直接设置 statusItem?.menu，改为通过 button action 手动弹出菜单
        // 直接设置 menu 会导致 updateStatusIcon() 更改图标时 macOS 意外弹出菜单，
        // 触发菜单项的 toggleRecording action，造成录音刚开始就被停止
        if let button = statusItem?.button {
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let menu = statusMenu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 5), in: sender)
    }

    /// Personal 版（个人开发版）的标识：bundle ID 以 .personal 结尾
    private static let isPersonalBuild: Bool = {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".personal")
    }()

    /// 菜单栏图标：mic.fill；录音时为橙色；Personal 版右上角叠加紫色圆点（始终可见）
    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.title = ""

        guard let micImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "语音输入") else { return }

        if Self.isPersonalBuild {
            // Personal 版：自渲染（带紫色角标），不能用 template
            let recording = isRecording
            let composed = NSImage(size: micImage.size, flipped: false) { rect in
                let baseColor: NSColor = recording ? .systemOrange : .labelColor
                micImage.draw(in: rect)
                baseColor.setFill()
                rect.fill(using: .sourceAtop)

                // 右上角紫色圆点
                let dotSize = rect.width * 0.4
                let dotRect = NSRect(
                    x: rect.width - dotSize,
                    y: rect.height - dotSize,
                    width: dotSize,
                    height: dotSize
                )
                NSColor.systemPurple.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                return true
            }
            composed.isTemplate = false
            button.image = composed
        } else if isRecording {
            // 分发版录音中：橙色
            let tinted = NSImage(size: micImage.size, flipped: false) { rect in
                micImage.draw(in: rect)
                NSColor.systemOrange.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.isTemplate = false
            button.image = tinted
        } else {
            // 分发版空闲：template（自动适配深色/浅色）
            micImage.isTemplate = true
            button.image = micImage
        }
    }

    /// NSMenuDelegate: 菜单即将显示时捕获当前前台应用
    func menuWillOpen(_ menu: NSMenu) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastFrontmostApp = front
            let name = front?.localizedName ?? "?"
            let bid = front?.bundleIdentifier ?? "?"
            Log.log("点击菜单时记录前台应用: \(name) (\(bid))")
        }
        // 更新菜单项状态
        if let firstItem = menu.items.first {
            firstItem.title = isRecording ? "停止语音输入" : "开始语音输入"
        }
        refreshPermissionMenuItems()
    }

    /// 按当前真实权限刷新菜单里的两条状态项
    private func refreshPermissionMenuItems() {
        let trusted = AXIsProcessTrusted()
        if let item = accessibilityStatusItem {
            item.title = PermissionStatusText.accessibility(trusted: trusted)
            item.isEnabled = !trusted
            item.image = NSImage(systemSymbolName: trusted ? "checkmark.circle" : "exclamationmark.triangle",
                                 accessibilityDescription: nil)
        }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if let item = microphoneStatusItem {
            item.title = PermissionStatusText.microphone(status: mic)
            item.isEnabled = mic != .authorized
            item.image = NSImage(systemSymbolName: mic == .authorized ? "checkmark.circle" : "exclamationmark.triangle",
                                 accessibilityDescription: nil)
        }
    }

    @objc private func openAccessibilitySettings() {
        // 带 prompt 调用会让 tccd 把本 app 登记进辅助功能列表（否则面板里根本找不到它，只能手动 + 添加）。
        // 系统提示框只在首次登记时出现一次，之后再调用不会重复弹；已授权时什么都不弹。
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        NSWorkspace.shared.open(PermissionSettingsURL.accessibility)
    }

    @objc private func openMicrophoneSettings() {
        NSWorkspace.shared.open(PermissionSettingsURL.microphone)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let toggleTitle = isRecording ? "停止语音输入" : "开始语音输入"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleRecording), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.keyEquivalentModifierMask = []
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())

        // 常驻权限状态：未授权时可点击直达系统设置面板；已授权时灰显只作说明。
        // 1.1.0 的朋友盲切了 10 次触发键，就是因为界面上看不到"权限没给"这件事。
        let axItem = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)
        accessibilityStatusItem = axItem
        let micItem = NSMenuItem(title: "", action: #selector(openMicrophoneSettings), keyEquivalent: "")
        micItem.target = self
        menu.addItem(micItem)
        microphoneStatusItem = micItem
        refreshPermissionMenuItems()
        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let replaceRulesItem = NSMenuItem(title: "替换规则...", action: #selector(openReplaceRules), keyEquivalent: "")
        replaceRulesItem.target = self
        menu.addItem(replaceRulesItem)
        menu.addItem(NSMenuItem.separator())

        let historyItem = NSMenuItem(title: "识别历史", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        let monitorItem = NSMenuItem(title: "用量监控", action: #selector(openVolcMonitor), keyEquivalent: "")
        monitorItem.target = self
        menu.addItem(monitorItem)
        let credentialItem = NSMenuItem(title: "申请火山引擎凭证…", action: #selector(openVolcCredentialGuide), keyEquivalent: "")
        credentialItem.target = self
        menu.addItem(credentialItem)
        let privacyItem = NSMenuItem(title: "隐私政策", action: #selector(openPrivacyPolicy), keyEquivalent: "")
        privacyItem.target = self
        menu.addItem(privacyItem)
        let logItem = NSMenuItem(title: "打开日志文件", action: #selector(openLogFile), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        let restartItem = NSMenuItem(title: "重启", action: #selector(restartApp), keyEquivalent: "r")
        restartItem.target = self
        menu.addItem(restartItem)
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.addItem(NSMenuItem.separator())
        let versionItem = NSMenuItem(title: "版本 \(Config.appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        return menu
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func openReplaceRules() {
        SettingsWindow.shared.show(tab: 2)
    }

    @objc private func openHistory() {
        HistoryWindow.shared.show()
    }

    @objc private func openVolcMonitor() {
        let appId = Config.volcAppId
        let resourceId = Config.volcResourceId
        let urlString = "https://console.volcengine.com/speech/monitor?AppID=\(appId)&ResourceID=\(resourceId)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else {
            Log.log("无法打开监控 URL: AppID 或 ResourceID 未配置")
        }
    }

    @objc private func openVolcCredentialGuide() {
        if let url = URL(string: "https://console.volcengine.com/speech/app") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openPrivacyPolicy() {
        if let url = URL(string: "https://github.com/liuhao04/VoiceInput/blob/main/docs/PRIVACY.md") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 麦克风权限未授予时的处理：
    /// - notDetermined：先 NSApp.activate 把 LSUIElement app 提为前台，再调 requestAccess；
    ///   granted 则重新进入录音流程，denied 则弹设置引导框。
    /// - denied/restricted：直接弹设置引导框，提供"打开系统设置"按钮。
    ///
    /// 为什么必须 activate：菜单栏常驻 app（LSUIElement=true）在后台触发
    /// TCC 权限对话框，系统会静默吞掉、不向用户展示，表现为 requestAccess
    /// 立刻返回 false。
    private func handleMicPermission(currentStatus: AVAuthorizationStatus) {
        switch currentStatus {
        case .notDetermined:
            Log.log("麦克风权限未确定，请求中")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    Log.log("麦克风权限请求结果: \(granted)")
                    if granted {
                        self?.startRecording()
                    } else {
                        self?.showMicPermissionDeniedAlert()
                    }
                }
            }
        case .denied, .restricted:
            Log.log("⚠️ 麦克风权限已拒绝，引导用户去系统设置")
            showMicPermissionDeniedAlert()
        default:
            break
        }
    }

    private func showMicPermissionDeniedAlert() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "需要麦克风权限"
            alert.informativeText = "VoiceInput 需要麦克风权限才能识别语音。\n请在 系统设置 → 隐私与安全性 → 麦克风 中打开 VoiceInput 的开关，然后重启 app。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Log.log("[Notification] 通知权限请求失败: \(error.localizedDescription)")
            } else {
                Log.log("[Notification] 通知权限: \(granted ? "已授权" : "被拒绝")")
            }
        }
    }

    private func checkAccessibilityPermission() {
        if !AXIsProcessTrusted() {
            Log.log("⚠️ 辅助功能权限未授予（授权后会自动重建 event tap，无需重启）")
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "需要辅助功能权限"
                // 不要再写"授予后重启"：权限监视会在授权瞬间重建 event tap，重启只是碰巧有效的绕法
                alert.informativeText = "VoiceInput 需要辅助功能权限来监听全局快捷键和插入文字。\n打开系统设置，在「辅助功能」列表里打开 VoiceInput 的开关即可，授权后立即生效，无需重启。\n菜单栏菜单和设置里随时能看到当前权限状态。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "打开系统设置")
                alert.addButton(withTitle: "稍后")
                if alert.runModal() == .alertFirstButtonReturn {
                    self.openAccessibilitySettings()
                }
            }
        }
    }

    @objc private func openLogFile() {
        NSWorkspace.shared.open(Log.logFileURL)
    }

    @objc private func restartApp() {
        if isRecording { stopRecording() }
        let url = Bundle.main.bundleURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", url.path]
            try? task.run()
            NSApp.terminate(nil)
        }
    }

    @objc private func quit() {
        if isRecording {
            stopRecording()
            // 延迟退出，给 AVAudioEngine 时间释放麦克风，避免系统仍显示占麦
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        } else {
            NSApp.terminate(nil)
        }
    }

    @objc func toggleRecording() {
        let now = CFAbsoluteTimeGetCurrent()

        // 正在等修正结果时按触发键：放弃修正，回到可插入状态
        if isCorrecting {
            Log.log("[Correct] 触发键中断修正")
            abortCorrection?()
            return
        }

        let elapsed = now - lastToggleTime
        // 防抖：300ms 内不允许再次触发（防止 Karabiner 等工具的快速连续事件）
        if elapsed < 0.3 { return }
        lastToggleTime = now

        // 编辑模式下按触发键：确认插入（和回车一样）
        if inputPanel?.isEditing == true {
            let text = inputPanel?.getCurrentText() ?? ""
            inputPanel?.exitEditModeForTesting()
            handleEditingFinished(text)
            return
        }

        if isRecording {
            stopRecording()
            return
        }

        // 识别已结束、面板还停在那儿等决定：这一下就是"插入"。
        // 用户要修正的话点面板上的「修正」按钮，不再有单独的档位。
        if let panel = inputPanel, panel.panel.isVisible {
            insertFromPanel()
            return
        }

        startRecording()
    }

    private func startRecording() {
        // 麦克风权限门禁：未授权直接转给 handleMicPermission 处理（弹请求/引导框）
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus != .authorized {
            handleMicPermission(currentStatus: micStatus)
            return
        }

        Log.log("startRecording 开始, inputPanel==nil: \(inputPanel == nil)")
        accumulatedText = ""
        asrOriginalText = ""
        correctionResult = nil
        isRecording = true
        updateStatusIcon()

        // 立即记录当前前台应用（在 VoiceInput 抢占焦点之前）
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastFrontmostApp = front
            Log.log("startRecording: 记录目标应用 \(front.localizedName ?? "未知") (\(front.bundleIdentifier ?? ""))")
        }

        if inputPanel == nil {
            inputPanel = VoiceInputPanel()
            // 点击面板文字区：停止录音进入编辑模式
            inputPanel?.onPanelClicked = { [weak self] in
                self?.handlePanelClicked()
            }
            // 编辑完成按回车/触发键时插入文本
            inputPanel?.onEditingFinished = { [weak self] text in
                self?.handleEditingFinished(text)
            }
            // 录音中 ESC：取消录音
            inputPanel?.onCancelled = { [weak self] in
                self?.cancelRecording()
            }
            // 编辑模式 ESC：取消但记录历史
            inputPanel?.onEditingCancelled = { [weak self] in
                self?.handleEditingCancelled()
            }
            // 点击"继续识别"按钮：从光标处恢复录音
            inputPanel?.onContinueRecording = { [weak self] in
                self?.handleContinueRecording()
            }
            // 修正由用户点按钮触发，不再随停止录音自动发生
            inputPanel?.onCorrectRequested = { [weak self] in
                self?.startCorrection()
            }
        }
        let point = cursorOrMouseScreenPoint()
        inputPanel?.show(near: point)
        startPanelBindingObserver()
        asr = VolcanoASR()
        asr?.start(
            onText: { text, isFinal in
                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.appendRecognizedText(text, isFinal: isFinal)
                }
            },
            onError: { [weak self] err in
                let msg = err.localizedDescription
                DispatchQueue.main.async {
                    self?.stopRecordingAndShowError(msg)
                }
            },
            onReady: {}
        )
        startAudioCapture()
    }

    private func startAudioCapture() {
        guard isRecording, audioCapture == nil else { return }

        // AVAudioEngine 推荐在主线程操作；且后台启动会与快速 stop 产生竞态：
        // 启动期间用户若按下 F5 停止，stopRecording 看到 audioCapture==nil 无法 stop，
        // 启动完成后赋值出一个孤儿 capture（麦克风一直开着，且下次 start 因 !=nil 被跳过）。
        let capture = AudioCapture()
        do {
            try capture.start { [weak self] pcm in
                self?.asr?.sendPCM(pcm)
            }
            audioCapture = capture
        } catch {
            Log.log("❌ 麦克风启动失败: \(error)")
            showError("麦克风启动失败: \(error.localizedDescription)")
            stopRecording()
        }
    }

    /// panel.hide() 之前调用：编辑模式或"继续识别"路径下 VoiceInput 会残留前台状态，
    /// 隐藏面板时 macOS 会把 key 转给同 app 下一个可见窗口（历史 / 设置），产生闪现。
    /// 先 orderOut 这些辅助窗口避免闪现。非前台时是 no-op，不会影响常规录音场景下
    /// 用户后台挂着设置/历史的体验。
    private func orderOutAuxWindowsIfFrontmost() {
        guard NSApp.isActive else { return }
        HistoryWindow.shared.orderOutIfVisible()
        SettingsWindow.shared.orderOutIfVisible()
    }

    /// ESC 取消：关闭面板，不插入文字
    func cancelRecording() {
        Log.log("cancelRecording: 取消录音，不插入文字")
        // ESC 只取消本次自动插入；当前识别文字仍应成为 Option+V 的最近结果。
        // 优先读取面板，以保留“继续识别”流程中旧编辑文本与新 ASR 的合并结果。
        let currentText = (inputPanel?.getCurrentText() ?? accumulatedText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentText.isEmpty {
            lastRecognitionResult = currentText
        }

        finalResultTimer?.cancel()
        finalResultTimer = nil
        // 修正在途时被取消：丢弃修正，文本仍按 ESC 语义不插入
        isCorrecting = false
        abortCorrection = nil
        correctAfterRecognition = false
        isRecording = false
        updateStatusIcon()
        stopPanelBindingObserver()

        audioCapture?.stop()
        audioCapture = nil
        asr?.close()
        asr = nil
        accumulatedText = ""

        orderOutAuxWindowsIfFrontmost()
        inputPanel?.hide()
        inputPanel = nil
    }

    /// 等待二遍识别的超时定时器
    private var finalResultTimer: DispatchWorkItem?

    private func stopRecording() {
        Log.log("stopRecording 开始, accumulatedText 长度=\(accumulatedText.count)")
        isRecording = false
        updateStatusIcon()
        stopPanelBindingObserver()
        // 用户切走时面板被 orderOut，二遍识别等待期需要恢复显示等待动画
        if accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           inputPanel?.panel.isVisible == false {
            inputPanel?.panel.orderFrontRegardless()
        }

        // 停止音频捕获
        audioCapture?.stop()
        audioCapture = nil

        // 是否有可注入文本以面板内容为准（涵盖"继续识别"前已编辑的文本）
        let panelHasText = !(inputPanel?.getCurrentText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let asrHasText = !accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // 如果本次新 ASR 没有识别到文字 且 面板里也没有遗留内容，直接关闭
        if !asrHasText && !panelHasText {
            Log.log("stopRecording: 无识别文字，直接关闭")
            correctAfterRecognition = false
            asr?.close()
            asr = nil
            orderOutAuxWindowsIfFrontmost()
            inputPanel?.hide()
            inputPanel = nil
            return
        }

        // 本次 ASR 没有新内容（继续识别后立即停止），无需等二遍识别，直接用面板已有文本注入
        if !asrHasText {
            Log.log("stopRecording: 本次 ASR 无新内容，直接用面板文本插入")
            asr?.close()
            asr = nil
            closePanelAndInsertText()
            return
        }

        // 发送负包，但保持连接等待二遍识别结果
        asr?.sendLastPacket()

        // 显示动态等待点，提示用户正在等待二遍识别
        inputPanel?.showWaitingDots()

        // 设置超时：最多等 1.2 秒（实测 p90=607ms, max=938ms），超时后使用当前结果自动插入
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Log.log("stopRecording: 等待二遍识别超时，使用当前结果插入")
            self.finishAndInsertText()
        }
        finalResultTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: timeout)

        Log.log("stopRecording: 已发负包，等待二遍识别结果（最多1.2秒）")
    }

    /// 二遍识别结果到达或超时后，插入文本
    private func finishAndInsertText() {
        finalResultTimer?.cancel()
        finalResultTimer = nil

        // 停止等待动画
        inputPanel?.hideWaitingDots()

        asr?.close()
        asr = nil

        closePanelAndInsertText()
    }

    /// 根据 Config.pasteLastHotkey 注册（或取消注册）全局快捷键
    func registerPasteLastHotkey() {
        if let binding = Config.pasteLastHotkey, binding.keyCode != 0 {
            GlobalHotkeyManager.shared.register(id: "pasteLast", binding: binding) { [weak self] in
                self?.pasteLastResult()
            }
        } else {
            GlobalHotkeyManager.shared.unregister(id: "pasteLast")
        }
    }

    /// 根据 Config.customTriggerBindings 里"组合键"类（keyCode != 0）的绑定注册全局快捷键。
    /// 单修饰键类（keyCode == 0 && deviceFlag != 0）由 handleFlagsChanged 的 press/release 路径处理，
    /// 不走 Carbon RegisterEventHotKey。
    func registerCustomTriggerHotkeys() {
        GlobalHotkeyManager.shared.unregisterAll(withPrefix: "customTrigger_")
        for (idx, binding) in Config.customTriggerBindings.enumerated() where binding.keyCode != 0 {
            GlobalHotkeyManager.shared.register(id: "customTrigger_\(idx)", binding: binding) { [weak self] in
                self?.toggleRecording()
            }
        }
    }

    /// 把最后一条识别结果粘贴到当前输入框。无记录时哔一声。
    /// 注意：Personal / Distribution 两版各自独立，本方法只读本进程的 lastRecognitionResult。
    private func pasteLastResult() {
        guard !lastRecognitionResult.isEmpty else {
            Log.log("[Hotkey] pasteLastResult: 本版无历史记录（Personal/Distribution 互不共享）")
            NSSound.beep()
            return
        }
        Log.log("[Hotkey] pasteLastResult: 粘贴 \(lastRecognitionResult.count) 字")
        PasteboardPaste.paste(text: lastRecognitionResult, activateTarget: nil)
    }

    /// 识别结束：面板停留，等用户决定插入还是先修正。**不再自动修正、不再自动插入。**
    func closePanelAndInsertText() {
        let rawText: String
        if let panelText = inputPanel?.getCurrentText(), !panelText.isEmpty {
            rawText = panelText
        } else {
            rawText = accumulatedText
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            correctAfterRecognition = false
            orderOutAuxWindowsIfFrontmost()
            inputPanel?.hide()
            inputPanel = nil
            Log.log("无识别文字，不插入")
            return
        }

        asrOriginalText = text
        correctionResult = nil
        if inputPanel?.panel.isVisible == false {
            inputPanel?.panel.orderFrontRegardless()
        }
        inputPanel?.enterAwaitingAction()
        Log.log("识别完成 \(text.count) 字，面板等待操作（⏎ 插入 / 点「修正」）")

        // 录音中点过「修正」：识别落定，接着把文字送去修正
        if correctAfterRecognition {
            correctAfterRecognition = false
            startCorrection()
        }
    }

    /// 用户点了面板上的「修正」按钮。
    /// 结果只覆盖面板内容并以批阅式 diff 展示，**绝不直接插入** —— 用户要能先看清模型动了什么。
    func startCorrection() {
        guard !isCorrecting else { return }
        // 已经在"等识别落定再修正"的路上，重复点按钮直接忽略
        guard !correctAfterRecognition else { return }
        guard let panel = inputPanel else { return }

        // 录音中点「修正」：先把录音结束掉，等二遍识别落定后自动接着修正。
        // 这样用户不用先按快捷键停、再点一次修正。
        if isRecording {
            Log.log("[Correct] 录音中点修正：先结束识别，识别完成后自动修正")
            correctAfterRecognition = true
            stopRecording()
            return
        }

        let original = panel.getCurrentText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }

        guard TextCorrector.isReady else {
            let why = Config.correctionEnabled ? "缺少 API Key" : "未启用 AI 修正"
            Log.log("[Correct] 无法修正：\(why)")
            panel.flashHint("无法修正：\(why)，请到设置里配置")
            return
        }

        panel.enterCorrecting()
        isCorrecting = true

        let cancel = TextCorrector.shared.correct(
            text: original,
            context: recentContext,
            properNouns: Config.properNouns
        ) { [weak self] result in
            guard let self = self, self.isCorrecting else { return }
            self.isCorrecting = false
            self.abortCorrection = nil
            guard let panel = self.inputPanel else { return }

            switch result {
            case .success(let corrected):
                if corrected == original {
                    Log.log("[Correct] 模型未做改动")
                } else {
                    Log.log("[Correct] 已修正：\(original.count)字 → \(corrected.count)字")
                    self.correctionResult = corrected
                }
                panel.showDiff(original: original, corrected: corrected)
            case .failure(let err):
                Log.log("[Correct] 修正失败：\(err.userMessage)")
                panel.enterAwaitingAction()
                if err != .cancelled {
                    panel.flashHint("修正失败：\(err.userMessage)")
                }
            }
        }
        abortCorrection = cancel
    }

    /// 面板上按 ⏎ / 触发键：把面板当前内容（diff 视图下是修正版）插入目标应用。
    func insertFromPanel() {
        guard let panel = inputPanel else { return }
        let text = panel.textToInsert().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            orderOutAuxWindowsIfFrontmost()
            inputPanel?.hide()
            inputPanel = nil
            return
        }
        insertFinalText(text)
    }

    /// 关闭面板并把最终文本注入目标应用，同时把三段文本分别记进历史。
    private func insertFinalText(_ text: String) {
        let asr = asrOriginalText.isEmpty ? text : asrOriginalText
        let corrected = correctionResult
        // 手改：最终文本既不等于 ASR 原文也不等于修正结果时，说明用户自己动过
        let edited: String? = (text != asr && text != corrected) ? text : nil

        orderOutAuxWindowsIfFrontmost()
        inputPanel?.hide()
        inputPanel = nil

        let appName: String
        if let target = lastFrontmostApp {
            appName = target.localizedName ?? "未知"
            let bid = target.bundleIdentifier ?? "?"
            Log.log("将注入 \(text.count) 字到目标应用: \(appName) (\(bid))")
            PasteboardPaste.paste(text: text, activateTarget: target)
        } else {
            appName = "未知"
            Log.log("无记录的前台应用，已复制到剪贴板")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        RecognitionHistory.append(asrText: asr, app: appName, corrected: corrected, edited: edited)
        lastRecognitionResult = text
        rememberContext(text)
        asrOriginalText = ""
        correctionResult = nil
    }

    /// 把实际采纳的文本记进上下文环形缓冲。
    /// 采纳的文本已经是"用户手改 > 模型修正 > ASR 原文"的最终版本，正是下次修正该参考的。
    func rememberContext(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var entries = TextCorrector.freshContext(Config.recentContextEntries)
        // 连着说同一句时不重复记：5 条里塞 5 份一样的内容会把信号稀释掉
        if entries.last?.text == trimmed { return }

        entries.append(ContextEntry(time: Date(), text: trimmed))
        if entries.count > TextCorrector.contextLimit {
            entries.removeFirst(entries.count - TextCorrector.contextLimit)
        }
        Config.recentContextEntries = entries
    }

    /// 流式 ASR 每次回调的是当前完整结果（递增），用最新结果替换而非追加
    private func appendRecognizedText(_ text: String, isFinal: Bool = false) {
        let replaced = TextReplacer.shared.apply(text)
        accumulatedText = replaced
        // 安全检查：如果正在录音但面板不可见，重新显示
        if isRecording, let panel = inputPanel, !panel.panel.isVisible {
                let point = cursorOrMouseScreenPoint()
            panel.show(near: point)
        }
        inputPanel?.insertOrReplaceASRText(replaced)

        // 收到二遍识别最终结果（flags=0x03），自动插入
        if isFinal && !isRecording && finalResultTimer != nil {
            Log.log("收到二遍识别最终结果，自动插入")
            finishAndInsertText()
            return
        }
    }

    /// 面板落点：文本光标 → 鼠标位置 → 目标窗口中心。
    ///
    /// 2026-09-02 调整兜底顺序：原来光标定位失败后直接返回"目标窗口中心"，鼠标排在最后、
    /// 实际永远跑不到。但窗口中心几乎必然离用户的注意力很远——Chrome 拿不到焦点元素
    /// （默认不构建 accessibility 树），面板就固定弹在网页正中。而按下触发键之前用户通常
    /// 刚点过输入框，鼠标就在光标附近，是比窗口中心好得多的近似。
    /// 窗口中心保留为最后一档：鼠标停在目标窗口外时用它，至少保证面板落在正在输入的窗口里。
    func cursorOrMouseScreenPoint() -> NSPoint {
        if let cursorPos = CursorLocator.getCursorPosition() {
            return cursorPos
        }

        let mouse = NSEvent.mouseLocation
        let windowFrame = targetWindowFrame()
        let point = AppDelegate.panelFallbackPoint(mouse: mouse, targetWindowFrame: windowFrame)
        // 记来源：日后再看"面板又跑偏了"的日志时，要能一眼分清是走了鼠标还是窗口中心
        let source = (point == mouse) ? "鼠标位置" : "窗口中心（鼠标在目标窗口外）"
        Log.log("[Panel] 光标定位失败，兜底用\(source): (\(point.x), \(point.y))")
        return point
    }

    /// 兜底落点的纯逻辑部分（便于测试）：鼠标在目标窗口内就用鼠标，否则退到窗口中心。
    static func panelFallbackPoint(mouse: NSPoint, targetWindowFrame: NSRect?) -> NSPoint {
        guard let frame = targetWindowFrame, !frame.isEmpty else { return mouse }
        if frame.contains(mouse) { return mouse }
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    /// 目标应用焦点窗口的 frame（AppKit 坐标系）。AX 拿不到时退到 CGWindowList。
    private func targetWindowFrame() -> NSRect? {
        guard let targetApp = lastFrontmostApp ?? NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let pid = targetApp.processIdentifier

        // AX frame 与 CGWindowList 都是 CG 坐标系（原点在主屏左上、Y 轴向下），统一翻转成 AppKit
        let screenHeight = NSScreen.screens.first?.frame.height ?? 982
        let toAppKit: (CGRect) -> NSRect = { cg in
            NSRect(x: cg.origin.x, y: screenHeight - (cg.origin.y + cg.size.height), width: cg.size.width, height: cg.size.height)
        }

        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
           let window = windowValue {
            let windowElement = window as! AXUIElement

            var frameValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, "AXFrame" as CFString, &frameValue) == .success,
               let frameVal = frameValue,
               CFGetTypeID(frameVal) == AXValueGetTypeID() {
                var frame = CGRect.zero
                if AXValueGetValue(frameVal as! AXValue, .cgRect, &frame) {
                    return toAppKit(frame)
                }
            }
        }

        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for windowInfo in windowList {
                if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                   ownerPID == pid,
                   let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                   let x = boundsDict["X"],
                   let y = boundsDict["Y"],
                   let width = boundsDict["Width"],
                   let height = boundsDict["Height"] {
                    return toAppKit(CGRect(x: x, y: y, width: width, height: height))
                }
            }
        }

        return nil
    }

    /// 出错时先停止录音释放麦克风，再弹窗（避免弹窗期间一直占麦）
    private func stopRecordingAndShowError(_ message: String) {
        // 非录音状态下的错误（如关闭连接时的 socket 错误）不弹窗
        guard isRecording else {
            return
        }
        stopRecording()
        showError(message)
    }

    private func showError(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "语音输入"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                // 通知发送失败（权限被拒等），fallback 到模态弹窗
                Log.log("[Error] 通知发送失败: \(error.localizedDescription)，使用弹窗显示")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "语音输入"
                    alert.informativeText = message
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    /// 点击面板时：停止录音和识别，进入编辑模式
    func handlePanelClicked() {
        // 修正在途时不进编辑模式，避免结果回来覆盖用户正在改的文字
        if isCorrecting { return }

        // 保存当前的目标应用，防止编辑过程中被定时器更新
        editModeTargetApp = testTargetApp ?? lastFrontmostApp

        isRecording = false
        updateStatusIcon()

        // 停止音频捕获
        audioCapture?.stop()
        audioCapture = nil

        // 停止 ASR 连接
        asr?.stop()
        asr = nil

        // 进入编辑模式
        inputPanel?.enterEditMode()
    }

    /// 编辑完成后按回车时：插入文本到目标应用
    func handleEditingFinished(_ text: String) {
        Log.log("handleEditingFinished: 插入文本长度=\(text.count)")
        Log.log("handleEditingFinished: editModeTargetApp = \(editModeTargetApp?.localizedName ?? "nil") (\(editModeTargetApp?.bundleIdentifier ?? "nil"))")
        Log.log("handleEditingFinished: lastFrontmostApp = \(lastFrontmostApp?.localizedName ?? "nil") (\(lastFrontmostApp?.bundleIdentifier ?? "nil"))")
        Log.log("handleEditingFinished: testTargetApp = \(testTargetApp?.localizedName ?? "nil") (\(testTargetApp?.bundleIdentifier ?? "nil"))")

        // 编辑模式下 VoiceInput 是前台应用，隐藏面板后 macOS 会激活下一个可见的 VoiceInput 窗口
        // 如果历史记录窗口 / 设置窗口处于打开状态，就会闪现。
        orderOutAuxWindowsIfFrontmost()

        // 隐藏面板
        inputPanel?.hide()
        inputPanel = nil

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // 优先使用编辑模式保存的目标应用，然后是测试目标应用，最后是常规目标应用
            let target = editModeTargetApp ?? testTargetApp ?? lastFrontmostApp
            let appName: String
            if let target = target {
                appName = target.localizedName ?? "未知"
                let bid = target.bundleIdentifier ?? "?"
                Log.log("将注入 \(trimmed.count) 字到目标应用: \(appName) (\(bid))")
                PasteboardPaste.paste(text: trimmed, activateTarget: target)
            } else {
                appName = "未知"
                Log.log("无记录的前台应用，已复制到剪贴板")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(trimmed, forType: .string)
            }
            let asr = asrOriginalText.isEmpty
                ? accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                : asrOriginalText
            let corrected = correctionResult
            let edited: String? = (trimmed != asr && trimmed != corrected) ? trimmed : nil
            RecognitionHistory.append(asrText: asr.isEmpty ? trimmed : asr, app: appName, corrected: corrected, edited: edited)
            lastRecognitionResult = trimmed
            // 用户手改过的文本是最强信号，优先作为后续修正的上下文
            rememberContext(trimmed)
            asrOriginalText = ""
            correctionResult = nil

            // 清理编辑模式保存的目标应用
            editModeTargetApp = nil
        } else {
            Log.log("文本为空，不插入")
        }
    }

    /// 编辑模式 ESC：取消插入，但记录识别结果到历史
    func handleEditingCancelled() {
        Log.log("handleEditingCancelled: 取消插入，记录历史")

        orderOutAuxWindowsIfFrontmost()

        let panelText = inputPanel?.getCurrentText() ?? ""
        inputPanel?.hide()
        inputPanel = nil

        // 不插入文字到目标应用，但记录到历史中
        let trimmed = panelText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let target = editModeTargetApp ?? testTargetApp ?? lastFrontmostApp
            let appName = target?.localizedName ?? "未知"
            let asr = asrOriginalText.isEmpty
                ? accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                : asrOriginalText
            let corrected = correctionResult
            let edited: String? = (trimmed != asr && trimmed != corrected) ? trimmed : nil
            RecognitionHistory.append(asrText: asr.isEmpty ? trimmed : asr, app: appName, corrected: corrected, edited: edited)
            lastRecognitionResult = trimmed
            rememberContext(trimmed)
            asrOriginalText = ""
            correctionResult = nil
            Log.log("handleEditingCancelled: 已记录到历史，文本长度=\(trimmed.count)")
        }

        editModeTargetApp = nil
    }

    /// "继续识别"按钮：从编辑模式恢复录音，ASR 结果插入到当前光标位置
    private func handleContinueRecording() {
        // 麦克风权限门禁（与 startRecording 入口一致）
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus != .authorized {
            handleMicPermission(currentStatus: micStatus)
            return
        }

        Log.log("handleContinueRecording: 从编辑模式恢复录音")

        // 记录光标位置并退出编辑模式（但保留面板）
        inputPanel?.prepareForContinueRecording()

        // 重新开始录音
        isRecording = true
        updateStatusIcon()
        startPanelBindingObserver()

        asr = VolcanoASR()
        asr?.start(
            onText: { text, isFinal in
                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.appendRecognizedText(text, isFinal: isFinal)
                }
            },
            onError: { [weak self] err in
                let msg = err.localizedDescription
                DispatchQueue.main.async {
                    self?.stopRecordingAndShowError(msg)
                }
            },
            onReady: {}
        )
        startAudioCapture()
    }

    // MARK: - 测试功能（见 AppDelegate+Tests.swift）
}
