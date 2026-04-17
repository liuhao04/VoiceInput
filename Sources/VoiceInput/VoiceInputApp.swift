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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var audioCapture: AudioCapture?
    private var asr: VolcanoASR?
    // 以下属性为 internal 以供 AppDelegate+Tests.swift extension 访问
    var isRecording = false
    var accumulatedText: String = ""
    /// 本 app 在后台时记录的前台应用，粘贴时先激活它再注入，否则注入会发到本 app 无效
    var lastFrontmostApp: NSRunningApplication?
    var frontmostCaptureTimer: DispatchSourceTimer?
    var inputPanel: VoiceInputPanel?
    /// 测试模式专用：保存固定的目标应用（避免被 menuWillOpen 等自动更新）
    var testTargetApp: NSRunningApplication?
    /// 编辑模式专用：进入编辑模式时保存的目标应用（防止编辑过程中被定时器更新）
    var editModeTargetApp: NSRunningApplication?

    // MARK: - 全局快捷键
    private var hotkeyTap: CFMachPort?
    /// 记录上次 flagsChanged 时按下的修饰键集合，用于判断"单独按下并释放"
    private var activeModifiers: UInt64 = 0
    /// 当修饰键按下后如果有其他普通键按下，则标记为组合操作，释放时不触发
    private var otherKeyPressed = false
    /// 记录按下修饰键时的设备级 flags，用于释放时匹配
    private var pendingTriggerKey: TriggerKey?
    /// 记录在触发键按下期间是否曾经有过其他修饰键同时存在（用于过滤 Karabiner 等工具的合成事件）
    private var hadOtherModsDuringPending = false

    // otherModsFirstSeen 已移除：不再容忍瞬态干扰，只要出现过其他修饰键就阻止触发
    /// 触发键按下的时间戳，用于过滤过短的合成事件
    private var pendingTriggerTime: CFAbsoluteTime = 0
    /// 上次 toggleRecording 的时间戳，用于防抖（防止 Karabiner 等工具产生的快速连续触发）
    private var lastToggleTime: CFAbsoluteTime = 0
    /// NSEvent 全局监听器（Cocoa 层级），用于捕获 BTT 等工具消费后仍可见的键盘事件
    private var globalKeyMonitor: Any?
    /// NSEvent 全局鼠标监听器，防止 Option+鼠标点击（如终端移动光标）误触发语音识别
    private var globalMouseMonitor: Any?
    /// 触发键上次释放的时间戳，用于检测 BTT 导致的快速释放-重按序列
    private var lastTriggerReleaseTime: CFAbsoluteTime = 0
    /// 上次释放的触发键，用于匹配释放-重按序列
    private var lastReleasedTriggerKey: TriggerKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("applicationDidFinishLaunching 开始")
        Config.migrateToKeychainIfNeeded()
        setupMainMenu()
        setupMenuBar()
        Log.log("菜单栏已设置")
        setupGlobalHotkey()
        Log.log("全局快捷键已设置，触发键: \(Config.triggerKeys.map { $0.displayName })")
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
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isRecording {
            stopRecording()
        }
    }

    /// 后台时持续记录当前前台应用（非本 app），供停止时激活并注入文字
    private func startFrontmostCaptureTimer() {
        frontmostCaptureTimer?.cancel()
        frontmostCaptureTimer = nil
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.lastFrontmostApp = front
            }
        }
        timer.resume()
        frontmostCaptureTimer = timer
    }

    // MARK: - 全局快捷键实现

    private func setupGlobalHotkey() {
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
                if delegate.pendingTriggerKey != nil {
                    delegate.otherKeyPressed = true
                }
                // 回车键（keyCode 36）在录音中且面板可见时，停止录音并插入文本
                // 编辑模式下回车由 NSTextView 的 doCommandBy 处理
                if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 36 {
                    if delegate.isRecording, delegate.inputPanel?.panel.isVisible == true,
                       delegate.inputPanel?.isEditing != true {
                        Log.log("[Hotkey] 检测到回车键，停止录音并插入文本")
                        DispatchQueue.main.async {
                            delegate.stopRecording()
                        }
                    }
                }
                // ESC 键（keyCode 53）：关闭面板，不插入文字
                // 编辑模式下 ESC 由 NSTextView 的 doCommandBy 处理，这里不重复处理
                if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                    if delegate.inputPanel?.isEditing == true {
                        // 编辑模式：ESC 由 NSTextView 处理（追加识别取消 / 退出编辑）
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
                Log.log("[Hotkey] ❌ 无法创建 event tap，请检查辅助功能权限")
                checkAccessibilityPermission()
                return
            }
            hotkeyTap = sessionTap
            let runLoopSource = CFMachPortCreateRunLoopSource(nil, sessionTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: sessionTap, enable: true)
            Log.log("[Hotkey] ✅ Session-level Event tap 已创建（降级模式）")
            return
        }

        hotkeyTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.log("[Hotkey] ✅ HID-level Event tap 已创建（先于 BTT 等工具）")

        // 额外添加 NSEvent 全局监听器（Cocoa 层级）
        // BTT 等工具通过 active CGEvent tap 消费 keyDown 事件后，
        // listenOnly CGEvent tap 看不到这些事件，但 NSEvent 全局监听器可能仍能收到。
        // 这是第二道防线。
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self = self, self.pendingTriggerKey != nil else { return }
            self.otherKeyPressed = true
        }

        // NSEvent 鼠标监听器：防止 Option+鼠标点击（如终端中移动光标）误触发
        // 使用 NSEvent 全局监听器而非 CGEvent tap，不会干扰鼠标事件的正常传递
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self = self, self.pendingTriggerKey != nil else { return }
            self.otherKeyPressed = true
        }
    }

    /// 处理修饰键变化事件
    private func handleFlagsChanged(_ event: CGEvent) {
        let rawFlags = event.flags.rawValue
        let triggerKeys = Config.triggerKeys

        if triggerKeys.isEmpty { return }

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
        if let pending = pendingTriggerKey, !hadOtherModsDuringPending {
            let otherMods = currentDeviceFlags & ~pending.deviceFlag
            if otherMods != 0 {
                hadOtherModsDuringPending = true
            }
        }

        // 检测哪个触发键刚被按下（之前没有，现在有了）
        for key in triggerKeys {
            let keyFlag = key.deviceFlag
            let wasDown = (activeModifiers & keyFlag) != 0
            let isDown = (currentDeviceFlags & keyFlag) != 0

            if isDown && !wasDown {
                // 修饰键刚按下：检查是否只有这一个修饰键被按下
                let otherModFlags = currentDeviceFlags & ~keyFlag
                if otherModFlags == 0 {
                    // 检测 BTT 导致的快速释放-重按序列：
                    // BTT 处理 Option+O 时会先释放 Option，再重新按下 Option，间隔极短（<100ms）
                    // 如果同一个触发键在刚释放后很快又被按下，说明是 BTT 的合成序列，跳过
                    let timeSinceLastRelease = now - lastTriggerReleaseTime
                    if lastReleasedTriggerKey == key && timeSinceLastRelease < 0.5 {
                        pendingTriggerKey = nil
                        hadOtherModsDuringPending = false
                    } else {
                        pendingTriggerKey = key
                        pendingTriggerTime = now
                        otherKeyPressed = false
                        hadOtherModsDuringPending = false
                    }
                } else {
                    // 有其他修饰键同时按下，不触发
                    pendingTriggerKey = nil
                    hadOtherModsDuringPending = false
                }
            } else if !isDown && wasDown {
                // 修饰键刚释放：检查是否满足"单独按下并释放"条件
                if let pending = pendingTriggerKey, pending == key, !hadOtherModsDuringPending {
                    // 确认释放时没有其他修饰键仍被按下
                    let remainingMods = currentDeviceFlags & ~keyFlag
                    if remainingMods == 0 {
                        let holdDuration = now - pendingTriggerTime
                        if holdDuration < 0.03 || otherKeyPressed || isAnyNonModifierKeyPressed() {
                            // 太短/组合键/HID检测到其他键，跳过
                        } else {
                            let hidKeyDown = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
                            let hidKeyUp = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyUp)
                            let csKeyDown = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                            let csKeyUp = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyUp)

                            let hadKeyEventDuringHold = hidKeyDown < holdDuration || hidKeyUp < holdDuration || csKeyDown < holdDuration || csKeyUp < holdDuration
                            if !hadKeyEventDuringHold {
                                let triggerKeyName = key.displayName
                                let isRec = isRecording
                                let pendingStart = pendingTriggerTime
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                                    guard let self = self else { return }
                                    if self.otherKeyPressed || self.isAnyNonModifierKeyPressed() {
                                        return
                                    }
                                    let totalElapsed = CFAbsoluteTimeGetCurrent() - pendingStart
                                    let dHidKD = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
                                    let dHidKU = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyUp)
                                    let dCsKD = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                                    let dCsKU = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyUp)
                                    let hadKeyEventDelayed = dHidKD < totalElapsed || dHidKU < totalElapsed || dCsKD < totalElapsed || dCsKU < totalElapsed
                                    if !hadKeyEventDelayed {
                                        Log.log("[Hotkey] 触发键 \(triggerKeyName) 确认触发, isRecording=\(isRec)")
                                        self.toggleRecording()
                                    }
                                }
                            }
                        }
                    } else {
                    }
                }
                // 记录释放时间和释放的键，用于检测 BTT 快速释放-重按序列
                lastTriggerReleaseTime = now
                lastReleasedTriggerKey = key
                pendingTriggerKey = nil
                hadOtherModsDuringPending = false
            }
        }

        activeModifiers = currentDeviceFlags
    }

    /// 检查当前是否有任何非修饰键被物理按下
    /// 通过 CGEventSourceKeyState 查询 HID 系统状态表，即使 BTT 等工具消费了 CGEvent，
    /// 物理按键状态仍然会在 HID 状态表中体现。
    /// 修饰键的 keyCode: 54/55=Cmd, 56/60=Shift, 58/61=Option, 59/62=Control, 57=CapsLock, 63=Fn
    private func isAnyNonModifierKeyPressed() -> Bool {
        let modifierKeyCodes: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        for keyCode: CGKeyCode in 0...126 {
            if modifierKeyCodes.contains(keyCode) { continue }
            if CGEventSource.keyState(.hidSystemState, key: keyCode) {
                Log.log("[Hotkey] HID 状态表: keyCode=\(keyCode) 当前按下")
                return true
            }
        }
        return false
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
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let toggleTitle = isRecording ? "停止语音输入" : "开始语音输入"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleRecording), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.keyEquivalentModifierMask = []
        menu.addItem(toggleItem)
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
            Log.log("⚠️ 辅助功能权限未授予")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "需要辅助功能权限"
                alert.informativeText = "VoiceInput 需要辅助功能权限来监听全局快捷键和插入文字。\n请在系统设置中授予权限后重启应用。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "打开系统设置")
                alert.addButton(withTitle: "稍后")
                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
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
        let elapsed = now - lastToggleTime

        // 防抖：300ms 内不允许再次触发（防止 Karabiner 等工具的快速连续事件）
        if elapsed < 0.3 {
            return
        }
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
        } else {
            startRecording()
        }
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
        lastStreamingResultTime = 0
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
        }
        let point = cursorOrMouseScreenPoint()
        inputPanel?.show(near: point)
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

    /// ESC 取消：关闭面板，不插入文字
    func cancelRecording() {
        Log.log("cancelRecording: 取消录音，不插入文字")
        finalResultTimer?.cancel()
        finalResultTimer = nil
        isRecording = false
        updateStatusIcon()

        audioCapture?.stop()
        audioCapture = nil
        asr?.close()
        asr = nil
        accumulatedText = ""

        inputPanel?.hide()
        inputPanel = nil
    }

    /// 等待二遍识别的超时定时器
    private var finalResultTimer: DispatchWorkItem?
    /// 录音中一遍识别结果间隔检测：超过阈值没有新结果则显示动态点
    private var streamingIdleTimer: DispatchWorkItem?
    /// 动态点自动停止 timer：显示动态点后若长时间无新结果则自动停止
    private var dotsAutoStopTimer: DispatchWorkItem?
    /// 上一次收到一遍识别结果的时间戳
    private var lastStreamingResultTime: CFAbsoluteTime = 0

    private func stopRecording() {
        Log.log("stopRecording 开始, accumulatedText 长度=\(accumulatedText.count)")
        isRecording = false
        updateStatusIcon()

        // 取消录音中空闲检测 timer
        streamingIdleTimer?.cancel()
        streamingIdleTimer = nil
        dotsAutoStopTimer?.cancel()
        dotsAutoStopTimer = nil

        // 停止音频捕获
        audioCapture?.stop()
        audioCapture = nil

        // 如果没有识别到任何文字，直接关闭面板，不需要等待二遍识别
        if accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.log("stopRecording: 无识别文字，直接关闭")
            asr?.close()
            asr = nil
            inputPanel?.hide()
            inputPanel = nil
            return
        }

        // 发送负包，但保持连接等待二遍识别结果
        asr?.sendLastPacket()

        // 显示动态等待点，提示用户正在等待二遍识别
        // 先停掉录音期间可能残留的动态点，再重新启动
        inputPanel?.hideWaitingDots()
        inputPanel?.showWaitingDots()

        // 设置超时：最多等 2 秒，超时后使用当前结果自动插入
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Log.log("stopRecording: 等待二遍识别超时，使用当前结果插入")
            self.finishAndInsertText()
        }
        finalResultTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: timeout)

        Log.log("stopRecording: 已发负包，等待二遍识别结果（最多2秒）")
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

    /// 用户再次按 F5 或通过其他方式关闭面板时，自动插入文本
    func closePanelAndInsertText() {
        let text = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 隐藏面板
        inputPanel?.hide()
        inputPanel = nil

        if !text.isEmpty {
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
            RecognitionHistory.append(text: text, app: appName)
        } else {
            Log.log("无识别文字，不插入")
        }
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
        // 收到新结果时停止动态点
        inputPanel?.hideWaitingDots()
        dotsAutoStopTimer?.cancel()
        dotsAutoStopTimer = nil
        inputPanel?.insertOrReplaceASRText(replaced)

        // 收到二遍识别最终结果（flags=0x03），自动插入
        if isFinal && !isRecording && finalResultTimer != nil {
            Log.log("收到二遍识别最终结果，自动插入")
            finishAndInsertText()
            return
        }

        if isRecording {
            let now = CFAbsoluteTimeGetCurrent()
            let gap = now - lastStreamingResultTime
            lastStreamingResultTime = now
            if gap < 2.0 {
                // 密集流式结果（正在说话）：启动空闲 timer，停顿后显示动态点
                resetStreamingIdleTimer()
            } else {
                // 回溯修正结果（长间隔后到达）：结果已稳定，不再启动 timer
                streamingIdleTimer?.cancel()
                streamingIdleTimer = nil
            }
        } else if finalResultTimer != nil {
            // 已停止录音但还在等二遍结果：在途一遍结果到达后恢复动态点
            inputPanel?.showWaitingDots()
        }
    }

    /// 重置录音中空闲检测 timer：800ms 没有新一遍结果则显示动态点
    private func resetStreamingIdleTimer() {
        streamingIdleTimer?.cancel()
        dotsAutoStopTimer?.cancel()
        let idle = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.inputPanel?.showWaitingDots()
            // 显示动态点后，最多再等 4 秒（回溯修正通常在 2.5-4.7s 内到达）
            // 超时则认为结果已稳定，自动停止动态点
            let autoStop = DispatchWorkItem { [weak self] in
                guard let self = self, self.isRecording else { return }
                self.inputPanel?.hideWaitingDots()
            }
            self.dotsAutoStopTimer = autoStop
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: autoStop)
        }
        streamingIdleTimer = idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: idle)
    }

    /// 返回面板显示位置：优先使用文本光标位置，失败则使用鼠标位置
    func cursorOrMouseScreenPoint() -> NSPoint {
        if let cursorPos = CursorLocator.getCursorPosition() {
            return cursorPos
        }

        let targetApp = lastFrontmostApp ?? NSWorkspace.shared.frontmostApplication
        if let frontmostApp = targetApp,
           let pid = frontmostApp.processIdentifier as pid_t? {

            let appElement = AXUIElementCreateApplication(pid)

            // 尝试获取焦点窗口
            var windowValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
               let window = windowValue {
                let windowElement = window as! AXUIElement

                // 获取窗口 frame
                var frameValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(windowElement, "AXFrame" as CFString, &frameValue) == .success,
                   let frameVal = frameValue,
                   CFGetTypeID(frameVal) == AXValueGetTypeID() {
                    var frame = CGRect.zero
                    if AXValueGetValue(frameVal as! AXValue, .cgRect, &frame) {
                        // AX frame 是 CG 坐标系（左上角原点），转换为 AppKit 坐标系（左下角原点）
                        let screenHeight = NSScreen.screens.first?.frame.height ?? 982
                        let appKitCenterY = screenHeight - (frame.origin.y + frame.size.height / 2)
                        let windowCenter = NSPoint(x: frame.origin.x + frame.size.width / 2, y: appKitCenterY)
                        return windowCenter
                    }
                }
            }

            // 方法3: 使用 CGWindowListCopyWindowInfo
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
                        // CGWindowListCopyWindowInfo 返回 CG 坐标系，转换为 AppKit
                        let screenHeight = NSScreen.screens.first?.frame.height ?? 982
                        let appKitCenterY = screenHeight - (y + height / 2)
                        let windowCenter = NSPoint(x: x + width / 2, y: appKitCenterY)
                        return windowCenter
                    }
                }
            }
        }

        // Fallback: 使用鼠标位置
        return NSEvent.mouseLocation
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
        // 如果历史记录窗口处于打开状态，就会闪现。所以先将其隐藏。
        HistoryWindow.shared.orderOutIfVisible()

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
            let originalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            RecognitionHistory.append(text: trimmed, app: appName, originalText: originalText)

            // 清理编辑模式保存的目标应用
            editModeTargetApp = nil
        } else {
            Log.log("文本为空，不插入")
        }
    }

    /// 编辑模式 ESC：取消插入，但记录识别结果到历史
    func handleEditingCancelled() {
        Log.log("handleEditingCancelled: 取消插入，记录历史")

        HistoryWindow.shared.orderOutIfVisible()

        let panelText = inputPanel?.getCurrentText() ?? ""
        inputPanel?.hide()
        inputPanel = nil

        // 不插入文字到目标应用，但记录到历史中
        let trimmed = panelText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let target = editModeTargetApp ?? testTargetApp ?? lastFrontmostApp
            let appName = target?.localizedName ?? "未知"
            let originalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            RecognitionHistory.append(text: trimmed, app: appName, originalText: originalText)
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
