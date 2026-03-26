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
        requestMicPermission()
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
                if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 36 {
                    if delegate.isRecording, delegate.inputPanel?.panel.isVisible == true {
                        Log.log("[Hotkey] 检测到回车键，停止录音并插入文本")
                        DispatchQueue.main.async {
                            delegate.stopRecording()
                        }
                    }
                }
                // ESC 键（keyCode 53）：关闭面板，不插入文字
                if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                    if delegate.isRecording || delegate.inputPanel?.panel.isVisible == true {
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
            Log.log("[Hotkey] NSEvent 全局监听器检测到键盘事件 (keyCode=\(event.keyCode), type=\(event.type == .keyDown ? "keyDown" : "keyUp"))")
        }
        if globalKeyMonitor != nil {
            Log.log("[Hotkey] ✅ NSEvent 全局键盘监听器已创建")
        }

        // NSEvent 鼠标监听器：防止 Option+鼠标点击（如终端中移动光标）误触发
        // 使用 NSEvent 全局监听器而非 CGEvent tap，不会干扰鼠标事件的正常传递
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self = self, self.pendingTriggerKey != nil else { return }
            self.otherKeyPressed = true
            Log.log("[Hotkey] NSEvent 全局监听器检测到鼠标点击, 标记 otherKeyPressed")
        }
        if globalMouseMonitor != nil {
            Log.log("[Hotkey] ✅ NSEvent 全局鼠标监听器已创建")
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
                Log.log("[Hotkey] pending \(pending.displayName) 期间检测到其他修饰键, otherMods=0x\(String(otherMods, radix: 16))")
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
                        Log.log("[Hotkey] 触发键 \(key.displayName) 在释放后 \(Int(timeSinceLastRelease * 1000))ms 内再次按下, 忽略（BTT 合成序列）")
                        pendingTriggerKey = nil
                        hadOtherModsDuringPending = false
                    } else {
                        pendingTriggerKey = key
                        pendingTriggerTime = now
                        otherKeyPressed = false
                        hadOtherModsDuringPending = false
                        Log.log("[Hotkey] 触发键 \(key.displayName) 按下, flags=0x\(String(currentDeviceFlags, radix: 16))")
                    }
                } else {
                    // 有其他修饰键同时按下，不触发
                    Log.log("[Hotkey] 触发键 \(key.displayName) 按下但有其他修饰键, otherMods=0x\(String(otherModFlags, radix: 16)), 跳过")
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
                        if holdDuration < 0.03 {
                            // 太短（< 30ms）说明是 Karabiner 等工具的合成事件快速闪烁
                            Log.log("[Hotkey] 触发键 \(key.displayName) 按下时间太短 (\(Int(holdDuration * 1000))ms), 忽略（可能是合成事件）")
                        } else if otherKeyPressed {
                            // otherKeyPressed: CGEvent tap 或 NSEvent 全局监听器检测到了键盘事件
                            Log.log("[Hotkey] 触发键 \(key.displayName) 释放 (\(Int(holdDuration * 1000))ms), 但检测到组合键(eventTap/NSEvent), 跳过")
                        } else if isAnyNonModifierKeyPressed() {
                            Log.log("[Hotkey] 触发键 \(key.displayName) 释放 (\(Int(holdDuration * 1000))ms), 但 HID 状态表检测到有键按下, 跳过")
                        } else {
                            // 诊断日志：检查各种 secondsSinceLastEventType 在 BTT 消费事件后是否有用
                            let hidKeyDown = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
                            let hidKeyUp = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyUp)
                            let csKeyDown = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                            let csKeyUp = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyUp)
                            Log.log("[Hotkey] 诊断: holdDuration=\(String(format: "%.3f", holdDuration))s, HID keyDown=\(String(format: "%.3f", hidKeyDown))s, HID keyUp=\(String(format: "%.3f", hidKeyUp))s, CS keyDown=\(String(format: "%.3f", csKeyDown))s, CS keyUp=\(String(format: "%.3f", csKeyUp))s")

                            // 核心判断：如果在 hold 期间有任何 keyDown 或 keyUp 发生，说明有组合键
                            let hadKeyEventDuringHold = hidKeyDown < holdDuration || hidKeyUp < holdDuration || csKeyDown < holdDuration || csKeyUp < holdDuration
                            if hadKeyEventDuringHold {
                                Log.log("[Hotkey] 触发键 \(key.displayName) 释放 (\(Int(holdDuration * 1000))ms), secondsSince 检测到期间有键盘事件, 跳过")
                            } else {
                                let triggerKeyName = key.displayName
                                let isRec = isRecording
                                let pendingStart = pendingTriggerTime
                                Log.log("[Hotkey] 触发键 \(triggerKeyName) 预备触发 (\(Int(holdDuration * 1000))ms), 延迟50ms确认, isRecording=\(isRec)")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                                    guard let self = self else { return }
                                    if self.otherKeyPressed {
                                        Log.log("[Hotkey] 延迟确认：检测到组合键(50ms内收到键盘事件), 取消触发")
                                    } else if self.isAnyNonModifierKeyPressed() {
                                        Log.log("[Hotkey] 延迟确认：HID 状态表检测到有键按下, 取消触发")
                                    } else {
                                        // 延迟后再查一次
                                        let totalElapsed = CFAbsoluteTimeGetCurrent() - pendingStart
                                        let dHidKD = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
                                        let dHidKU = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyUp)
                                        let dCsKD = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                                        let dCsKU = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyUp)
                                        let hadKeyEventDelayed = dHidKD < totalElapsed || dHidKU < totalElapsed || dCsKD < totalElapsed || dCsKU < totalElapsed
                                        if hadKeyEventDelayed {
                                            Log.log("[Hotkey] 延迟确认：secondsSince 检测到期间有键盘事件 (HID kd=\(String(format: "%.3f", dHidKD))s ku=\(String(format: "%.3f", dHidKU))s CS kd=\(String(format: "%.3f", dCsKD))s ku=\(String(format: "%.3f", dCsKU))s elapsed=\(String(format: "%.3f", totalElapsed))s), 取消触发")
                                        } else {
                                            Log.log("[Hotkey] 触发键 \(triggerKeyName) 确认单独按下并释放, isRecording=\(isRec)")
                                            self.toggleRecording()
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        Log.log("[Hotkey] 触发键 \(key.displayName) 释放但仍有其他修饰键, remainingMods=0x\(String(remainingMods, radix: 16))")
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

    /// 菜单栏图标：始终使用 mic.fill，录音时右上角叠加红色圆点
    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.title = ""

        guard let micImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "语音输入") else { return }

        if isRecording {
            // 录音中：用柔和的橙色绘制同一个图标
            let tinted = NSImage(size: micImage.size, flipped: false) { rect in
                micImage.draw(in: rect)
                NSColor.systemOrange.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.isTemplate = false
            button.image = tinted
        } else {
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

    private func requestMicPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.log("麦克风授权状态: \(status.rawValue) (0=未确定, 1=受限, 2=拒绝, 3=已授权)")
        switch status {
        case .notDetermined:
            Log.log("请求麦克风权限...")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.log("麦克风权限请求结果: \(granted)")
                if granted {
                    Log.log("✅ 麦克风权限已授权")
                } else {
                    Log.log("❌ 麦克风权限被拒绝")
                }
            }
        case .denied, .restricted:
            Log.log("⚠️ 麦克风权限被拒绝或受限，录音将无法工作")
        case .authorized:
            Log.log("✅ 麦克风权限已授权")
        @unknown default:
            break
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
        Log.log("toggleRecording 被调用, isRecording=\(isRecording), 距上次=\(String(format: "%.3f", elapsed))s")

        // 防抖：300ms 内不允许再次触发（防止 Karabiner 等工具的快速连续事件）
        if elapsed < 0.3 {
            Log.log("toggleRecording: 防抖忽略（距上次 \(String(format: "%.0f", elapsed * 1000))ms）")
            return
        }
        lastToggleTime = now

        // 编辑模式下按 Option：等同于回车，结束编辑并插入文字
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
        Log.log("startRecording 开始, inputPanel==nil: \(inputPanel == nil)")
        accumulatedText = ""
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
            // 点击面板时停止录音并进入编辑模式
            inputPanel?.onPanelClicked = { [weak self] in
                self?.handlePanelClicked()
            }
            // 编辑完成按回车时插入文本
            inputPanel?.onEditingFinished = { [weak self] text in
                self?.handleEditingFinished(text)
            }
            // ESC 取消编辑
            inputPanel?.onCancelled = { [weak self] in
                self?.cancelRecording()
            }
        }
        let point = cursorOrMouseScreenPoint()
        inputPanel?.show(near: point)
        Log.log("startRecording: 面板已调用 show, panel.isVisible=\(inputPanel?.panel.isVisible ?? false)")

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
            onReady: {
                Log.log("ASR 连接就绪，缓冲的音频将开始发送")
            }
        )
        // 立即开麦：音频在 ASR 侧排队，连接就绪后会先发缓冲再收实时流，避免丢失按键后开头几句
        startAudioCapture()
        Log.log("startRecording 结束（已开麦，ASR 连接就绪后会自动发送缓冲）")
    }

    private func startAudioCapture() {
        guard isRecording, audioCapture == nil else { return }
        Log.log("准备启动音频捕获...")

        // 在后台线程中初始化 AudioCapture，因为 AVAudioEngine().inputNode 可能会阻塞
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            Log.log("后台线程：创建 AudioCapture...")
            let capture = AudioCapture()

            do {
                Log.log("后台线程：启动 AudioCapture...")
                try capture.start { [weak self] pcm in
                    self?.asr?.sendPCM(pcm)
                }

                DispatchQueue.main.async {
                    self.audioCapture = capture
                    Log.log("音频捕获已启动")
                }
            } catch {
                Log.log("麦克风启动失败: \(error)")
                DispatchQueue.main.async {
                    self.showError("麦克风启动失败: \(error.localizedDescription)")
                    self.stopRecording()
                }
            }
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

    private func stopRecording() {
        Log.log("stopRecording 开始, accumulatedText 长度=\(accumulatedText.count)")
        isRecording = false
        updateStatusIcon()

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

        // 面板保持显示当前文本，等待二遍结果更新

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
            Log.log("[安全恢复] 面板在录音中不可见，重新显示")
            let point = cursorOrMouseScreenPoint()
            panel.show(near: point)
        }
        inputPanel?.updateText(replaced)

        // 收到二遍识别最终结果（flags=0x03），自动插入
        if isFinal && !isRecording && finalResultTimer != nil {
            Log.log("收到二遍识别最终结果，自动插入")
            finishAndInsertText()
        }
    }

    /// 返回面板显示位置：优先使用文本光标位置，失败则使用鼠标位置
    func cursorOrMouseScreenPoint() -> NSPoint {
        Log.log("[cursorOrMouseScreenPoint] 开始获取光标位置")

        // 方法1: 使用 CursorLocator 精确获取输入光标位置
        if let cursorPos = CursorLocator.getCursorPosition() {
            Log.log("[cursorOrMouseScreenPoint] ✓ 成功获取输入光标位置: (\(cursorPos.x), \(cursorPos.y))")
            if let info = CursorLocator.getFocusedElementInfo() {
                Log.log("[cursorOrMouseScreenPoint]   焦点元素: \(info)")
            }
            return cursorPos
        }

        Log.log("[cursorOrMouseScreenPoint] 无法获取输入光标，尝试窗口位置")

        // 方法2: Fallback 到窗口位置
        let targetApp = lastFrontmostApp ?? NSWorkspace.shared.frontmostApplication
        if let frontmostApp = targetApp,
           let pid = frontmostApp.processIdentifier as pid_t? {
            let appName = frontmostApp.localizedName ?? "unknown"
            Log.log("[cursorOrMouseScreenPoint] 目标应用: \(appName)")

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
                        Log.log("[cursorOrMouseScreenPoint] ✓ 窗口中心位置 (AppKit): (\(windowCenter.x), \(windowCenter.y))")
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
                        Log.log("[cursorOrMouseScreenPoint] ✓ 窗口中心 (CGWindow, AppKit): (\(windowCenter.x), \(windowCenter.y))")
                        return windowCenter
                    }
                }
            }
        }

        // Fallback: 使用鼠标位置
        let mousePoint = NSEvent.mouseLocation
        Log.log("[cursorOrMouseScreenPoint] Fallback: 使用鼠标位置 (\(mousePoint.x), \(mousePoint.y))")
        return mousePoint
    }

    /// 出错时先停止录音释放麦克风，再弹窗（避免弹窗期间一直占麦）
    private func stopRecordingAndShowError(_ message: String) {
        // 非录音状态下的错误（如关闭连接时的 socket 错误）不弹窗
        guard isRecording else {
            Log.log("stopRecordingAndShowError: 非录音状态，忽略错误: \(message)")
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
        Log.log("handlePanelClicked: 停止录音和识别")

        // 保存当前的目标应用，防止编辑过程中被定时器更新
        editModeTargetApp = testTargetApp ?? lastFrontmostApp
        Log.log("handlePanelClicked: 保存目标应用 = \(editModeTargetApp?.localizedName ?? "nil") (\(editModeTargetApp?.bundleIdentifier ?? "nil"))")

        isRecording = false
        updateStatusIcon()

        // 停止音频捕获
        audioCapture?.stop()
        audioCapture = nil

        // 停止 ASR 连接
        asr?.stop()
        asr = nil

        // 保留面板和当前文本，等待编辑
    }

    /// 编辑完成后按回车时：插入文本到目标应用
    func handleEditingFinished(_ text: String) {
        Log.log("handleEditingFinished: 插入文本长度=\(text.count)")
        Log.log("handleEditingFinished: editModeTargetApp = \(editModeTargetApp?.localizedName ?? "nil") (\(editModeTargetApp?.bundleIdentifier ?? "nil"))")
        Log.log("handleEditingFinished: lastFrontmostApp = \(lastFrontmostApp?.localizedName ?? "nil") (\(lastFrontmostApp?.bundleIdentifier ?? "nil"))")
        Log.log("handleEditingFinished: testTargetApp = \(testTargetApp?.localizedName ?? "nil") (\(testTargetApp?.bundleIdentifier ?? "nil"))")

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

    // MARK: - 测试功能（见 AppDelegate+Tests.swift）
}
