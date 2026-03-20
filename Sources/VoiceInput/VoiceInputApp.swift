import AppKit
import AVFoundation
import Foundation

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
    private var isRecording = false
    private var accumulatedText: String = ""
    /// 本 app 在后台时记录的前台应用，粘贴时先激活它再注入，否则注入会发到本 app 无效
    private var lastFrontmostApp: NSRunningApplication?
    private var frontmostCaptureTimer: DispatchSourceTimer?
    private var inputPanel: VoiceInputPanel?
    /// 测试模式专用：保存固定的目标应用（避免被 menuWillOpen 等自动更新）
    private var testTargetApp: NSRunningApplication?
    /// 编辑模式专用：进入编辑模式时保存的目标应用（防止编辑过程中被定时器更新）
    private var editModeTargetApp: NSRunningApplication?

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
        requestMicPermission()
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
    private func updateStatusIcon() {
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

    @objc private func toggleRecording() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastToggleTime
        Log.log("toggleRecording 被调用, isRecording=\(isRecording), 距上次=\(String(format: "%.3f", elapsed))s")

        // 防抖：300ms 内不允许再次触发（防止 Karabiner 等工具的快速连续事件）
        if elapsed < 0.3 {
            Log.log("toggleRecording: 防抖忽略（距上次 \(String(format: "%.0f", elapsed * 1000))ms）")
            return
        }
        lastToggleTime = now

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
        }
        let point = cursorOrMouseScreenPoint()
        inputPanel?.show(near: point)
        Log.log("startRecording: 面板已调用 show, panel.isVisible=\(inputPanel?.panel.isVisible ?? false)")

        asr = VolcanoASR()
        asr?.start(
            onText: { text in
                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.appendRecognizedText(text)
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

    private func stopRecording() {
        Log.log("stopRecording 开始, accumulatedText 长度=\(accumulatedText.count)")
        isRecording = false
        updateStatusIcon()

        // 停止音频和识别
        audioCapture?.stop()
        audioCapture = nil
        asr?.stop()
        asr = nil

        // 直接插入文本并关闭面板
        Log.log("stopRecording 结束，直接插入文本")
        closePanelAndInsertText()
    }

    /// 用户再次按 F5 或通过其他方式关闭面板时，自动插入文本
    private func closePanelAndInsertText() {
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
    private func appendRecognizedText(_ text: String) {
        accumulatedText = text
        // 安全检查：如果正在录音但面板不可见，重新显示
        if isRecording, let panel = inputPanel, !panel.panel.isVisible {
            Log.log("[安全恢复] 面板在录音中不可见，重新显示")
            let point = cursorOrMouseScreenPoint()
            panel.show(near: point)
        }
        inputPanel?.updateText(text)
    }

    /// 返回面板显示位置：优先使用文本光标位置，失败则使用鼠标位置
    private func cursorOrMouseScreenPoint() -> NSPoint {
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
        stopRecording()
        showError(message)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "语音输入"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// 点击面板时：停止录音和识别，进入编辑模式
    private func handlePanelClicked() {
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
    private func handleEditingFinished(_ text: String) {
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

    // MARK: - 测试功能

    /// 右Option键插入功能自动测试
    private func runRightOptionTest() {
        Log.log("[TEST] ========== 开始右Option键测试 ==========")

        // 1. Mock 识别结果
        accumulatedText = "右Option测试文字"
        Log.log("[TEST] Step 1: Mock 识别结果 = \"\(accumulatedText)\"")

        // 2. 设置测试目标应用（TextEdit）
        if let textEdit = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) {
            testTargetApp = textEdit
            lastFrontmostApp = textEdit
            textEdit.activate(options: .activateIgnoringOtherApps)
            Log.log("[TEST] Step 2: 设置目标应用 = TextEdit 并激活")
        } else {
            Log.log("[TEST] ❌ 未找到 TextEdit，请先打开 TextEdit")
            return
        }

        // 3. 模拟录音状态
        isRecording = true
        updateStatusIcon()
        Log.log("[TEST] Step 3: 设置 isRecording = true")

        // 4. 显示面板（模拟停止录音后的状态）
        if inputPanel == nil {
            inputPanel = VoiceInputPanel()
            inputPanel?.onPanelClicked = { [weak self] in
                self?.handlePanelClicked()
            }
            inputPanel?.onEditingFinished = { [weak self] text in
                self?.handleEditingFinished(text)
            }
        }

        let testPoint = NSPoint(x: 800, y: 400)
        inputPanel?.show(near: testPoint)
        inputPanel?.updateText(accumulatedText)
        Log.log("[TEST] Step 4: 面板已显示在 \(testPoint)")

        // 5. 第一次调用 toggleRecording（模拟第一次按右Option - 应该停止录音）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Log.log("[TEST] Step 5: 第一次按右Option (应该停止录音)")
            Log.log("[TEST] 按下前: isRecording=\(self.isRecording), panel visible=\(self.inputPanel?.panel.isVisible ?? false)")
            self.toggleRecording()
            Log.log("[TEST] 按下后: isRecording=\(self.isRecording), panel visible=\(self.inputPanel?.panel.isVisible ?? false)")

            // 6. 等待一下，然后第二次调用 toggleRecording（模拟第二次按右Option - 应该插入文字）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Log.log("[TEST] Step 6: 第二次按右Option (应该插入文字)")
                Log.log("[TEST] 按下前: isRecording=\(self.isRecording), panel visible=\(self.inputPanel?.panel.isVisible ?? false)")
                self.toggleRecording()
                Log.log("[TEST] 按下后: isRecording=\(self.isRecording), panel visible=\(self.inputPanel?.panel.isVisible ?? false)")

                // 7. 验证结果
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.verifyRightOptionTest()
                }
            }
        }
    }

    private func verifyRightOptionTest() {
        Log.log("[TEST] Step 7: 验证测试结果")

        // 检查面板状态
        if let panel = inputPanel {
            Log.log("[TEST] ❌ 面板仍然存在，visible=\(panel.panel.isVisible)")
        } else {
            Log.log("[TEST] ✅ 面板已关闭")
        }

        // 检查日志中是否有成功插入的记录
        // 因为 PasteboardPaste 使用 AX API 时不通过剪贴板，所以检查日志是最可靠的验证方式
        Log.log("[TEST] 查看上面的日志：")
        Log.log("[TEST] - 如果看到 '[Paste] ✅ AX API 插入成功'，说明文字已成功插入")
        Log.log("[TEST] - 如果看到 '将注入 11 字到目标应用: 文本编辑'，说明功能正常")
        Log.log("[TEST] ========== 测试完成 ==========")
        Log.log("[TEST] 请检查 TextEdit 是否有 '右Option测试文字' 来确认最终结果")
    }

    /// Gemini 页面插入功能测试
    private func runGeminiTest() {
        Log.log("[TEST] ========== 开始 Gemini 插入测试 ==========")

        // 1. 读取测试配置
        let testTextPath = "/tmp/voiceinput_test/test_text.txt"
        let targetAppPath = "/tmp/voiceinput_test/target_app.txt"

        guard let testText = try? String(contentsOfFile: testTextPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let targetBundle = try? String(contentsOfFile: targetAppPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            Log.log("[TEST] ❌ 无法读取测试配置文件")
            return
        }

        Log.log("[TEST] Step 1: 测试文字 = \"\(testText)\"")
        Log.log("[TEST] Step 2: 目标应用 = \(targetBundle)")

        // 2. 找到目标浏览器
        guard let browserApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == targetBundle }) else {
            Log.log("[TEST] ❌ 未找到浏览器: \(targetBundle)")
            return
        }

        testTargetApp = browserApp
        lastFrontmostApp = browserApp
        Log.log("[TEST] Step 3: 找到浏览器: \(browserApp.localizedName ?? "Unknown")")

        // 3. 等待浏览器成为前台应用（用户应该已经按了 Cmd+K）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // 4. Mock 识别结果
            self.accumulatedText = testText
            Log.log("[TEST] Step 4: 设置识别结果")

            // 5. 获取当前焦点元素信息（诊断用）
            self.logFocusedElementInfo()

            // 6. 模拟语音输入流程：显示面板
            if self.inputPanel == nil {
                self.inputPanel = VoiceInputPanel()
                self.inputPanel?.onPanelClicked = { [weak self] in
                    self?.handlePanelClicked()
                }
                self.inputPanel?.onEditingFinished = { [weak self] text in
                    self?.handleEditingFinished(text)
                }
            }

            let point = self.cursorOrMouseScreenPoint()
            Log.log("[TEST] Step 5: 光标位置 = \(point)")
            self.inputPanel?.show(near: point)
            self.inputPanel?.updateText(testText)

            // 7. 直接调用插入（模拟按右Option）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Log.log("[TEST] Step 6: 开始插入文字")
                self.closePanelAndInsertText()

                // 8. 等待插入完成，输出结果
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    Log.log("[TEST] ========== 测试完成 ==========")
                    Log.log("[TEST] 查看上面的日志中：")
                    Log.log("[TEST] - [Paste] 日志显示了插入方法（AX API / Cmd+V）")
                    Log.log("[TEST] - 焦点元素信息显示了目标输入框的属性")
                    Log.log("[TEST] 请在浏览器中检查文字是否成功插入")
                }
            }
        }
    }

    /// 诊断用：输出当前焦点元素的详细信息
    private func logFocusedElementInfo() {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let pid = frontmostApp.processIdentifier as pid_t? else {
            Log.log("[TEST] ❌ 无法获取前台应用")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        Log.log("[TEST] 前台应用: \(frontmostApp.localizedName ?? "Unknown") (\(frontmostApp.bundleIdentifier ?? ""))")

        // 获取焦点元素
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let focused = focusedElement else {
            Log.log("[TEST] ❌ 无法获取焦点元素")
            return
        }

        let element = focused as! AXUIElement

        // 获取角色
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String {
            Log.log("[TEST] 焦点元素角色: \(role)")
        }

        // 获取角色描述
        var roleDescValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &roleDescValue) == .success,
           let roleDesc = roleDescValue as? String {
            Log.log("[TEST] 角色描述: \(roleDesc)")
        }

        // 获取所有属性
        var attributeNames: CFArray?
        if AXUIElementCopyAttributeNames(element, &attributeNames) == .success,
           let names = attributeNames as? [String] {
            Log.log("[TEST] 可用属性 (\(names.count)): \(names.prefix(10).joined(separator: ", "))")

            // 检查是否支持 selectedText
            if names.contains(kAXSelectedTextAttribute as String) {
                Log.log("[TEST] ✅ 支持 AXSelectedText")
            } else {
                Log.log("[TEST] ❌ 不支持 AXSelectedText")
            }

            // 检查是否支持 value
            if names.contains(kAXValueAttribute as String) {
                Log.log("[TEST] ✅ 支持 AXValue")
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                   let val = value as? String {
                    Log.log("[TEST] 当前值: \"\(val)\"")
                }
            } else {
                Log.log("[TEST] ❌ 不支持 AXValue")
            }
        }
    }

    /// 面板编辑功能自动测试
    private func runPanelEditTest() {
        Log.log("[TEST] ========== 开始面板编辑测试 ==========")

        // 1. Mock 识别结果
        accumulatedText = "原始测试文字"
        Log.log("[TEST] Step 1: Mock 识别结果 = \"\(accumulatedText)\"")

        // 2. 设置测试目标应用（TextEdit）并激活它
        if let textEdit = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) {
            testTargetApp = textEdit  // 使用测试专用变量
            lastFrontmostApp = textEdit  // 也设置常规变量以保证兼容性
            textEdit.activate(options: .activateIgnoringOtherApps)  // 激活TextEdit
            Log.log("[TEST] Step 2: 设置目标应用 = TextEdit 并激活")
        } else {
            Log.log("[TEST] ❌ 未找到 TextEdit，请先打开 TextEdit")
            return
        }

        // 3. 显示面板
        if inputPanel == nil {
            inputPanel = VoiceInputPanel()
            inputPanel?.onPanelClicked = { [weak self] in
                self?.handlePanelClicked()
            }
            inputPanel?.onEditingFinished = { [weak self] text in
                self?.handleEditingFinished(text)
            }
        }

        let testPoint = NSPoint(x: 800, y: 400)
        inputPanel?.show(near: testPoint)
        inputPanel?.updateText(accumulatedText)
        Log.log("[TEST] Step 3: 面板已显示在 (\(testPoint.x), \(testPoint.y))")
        Log.log("[TEST] TEST_PANEL_SHOWN")

        // 4. 等待 1 秒后检测面板状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.checkPanelState()
        }
    }

    private func checkPanelState() {
        guard let panel = inputPanel else {
            Log.log("[TEST] ❌ 面板不存在")
            return
        }

        Log.log("[TEST] Step 4: 检查面板状态")
        Log.log("[TEST]   - isVisible: \(panel.panel.isVisible)")
        Log.log("[TEST]   - isKeyWindow: \(panel.panel.isKeyWindow)")
        Log.log("[TEST]   - frame: \(panel.panel.frame)")

        // 5. 模拟点击面板
        let panelFrame = panel.panel.frame
        let clickX = panelFrame.origin.x + panelFrame.width / 2
        let clickY = panelFrame.origin.y + panelFrame.height / 2

        Log.log("[TEST] Step 5: 模拟点击面板中心 (\(clickX), \(clickY))")
        simulateMouseClick(at: NSPoint(x: clickX, y: clickY))

        // 6. 等待点击生效，检查编辑状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.checkEditState()
        }
    }

    private func checkEditState() {
        guard let panel = inputPanel else {
            Log.log("[TEST] ❌ 面板不存在")
            return
        }

        Log.log("[TEST] Step 6: 检查编辑状态")

        // 使用 Accessibility API 检查 textView 状态
        let pid = ProcessInfo.processInfo.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var windowElement: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowElement) == .success,
           let windows = windowElement as? [AXUIElement],
           !windows.isEmpty {

            let window = windows[0]

            // 尝试查找 textView
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue)
            Log.log("[TEST]   - Window role: \(roleValue as? String ?? "unknown")")

            // 检查是否是 key window
            var isKeyValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &isKeyValue) == .success {
                let isKey = (isKeyValue as? Bool) ?? false
                Log.log("[TEST]   - isKeyWindow: \(isKey)")
            }
        }

        Log.log("[TEST]   - panel.isKeyWindow: \(panel.panel.isKeyWindow)")

        // 7. 直接修改 textView 内容（模拟键盘输入在某些情况下不生效）
        Log.log("[TEST] Step 7: 修改面板文字")
        self.inputPanel?.setTextForTesting("编辑后的文字")
        Log.log("[TEST] ✅ 已修改文字: \"编辑后的文字\"")


        // 8. 模拟按回车（直接触发面板的回调而不是真正的键盘事件）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Log.log("[TEST] Step 8: 模拟按下回车键")
            Log.log("[TEST] 按回车前 lastFrontmostApp = \\(self.lastFrontmostApp?.localizedName ?? \"nil\") (\\(self.lastFrontmostApp?.bundleIdentifier ?? \"nil\"))")
            self.inputPanel?.simulateEnterForTesting()
            Log.log("[TEST] ✅ 已按回车")

            // 9. 验证结果
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.verifyTestResult()
            }
        }
    }

    private func simulateMouseClick(at point: NSPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)

        if let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
           let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {

            mouseDown.post(tap: .cghidEventTap)
            usleep(50000) // 50ms
            mouseUp.post(tap: .cghidEventTap)

            Log.log("[TEST] ✅ 已发送鼠标点击事件")
        } else {
            Log.log("[TEST] ❌ 无法创建鼠标事件")
        }
    }

    private func simulateTextInput(_ text: String) {
        // 先全选
        simulateKeyPress(keyCode: 0x00, modifiers: .maskCommand) // Cmd+A
        usleep(100000)

        // 输入新文字
        for char in text {
            let string = String(char)
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                var utf16Chars: [UniChar] = Array(string.utf16)
                utf16Chars.withUnsafeMutableBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event.post(tap: .cghidEventTap)
                usleep(50000)
            }
        }

        Log.log("[TEST] ✅ 已输入文字: \"\(text)\"")
    }

    private func simulateEnterKey() {
        Log.log("[TEST] Step 8: 模拟按下回车键")
        simulateKeyPress(keyCode: 0x24, modifiers: []) // Return key
        Log.log("[TEST] ✅ 已按回车")
    }

    private func simulateKeyPress(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)

        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {

            keyDown.flags = modifiers
            keyUp.flags = modifiers

            keyDown.post(tap: .cghidEventTap)
            usleep(50000)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func verifyTestResult() {
        Log.log("[TEST] Step 9: 验证测试结果")

        // 读取 TextEdit 内容
        let script = """
        tell application "TextEdit"
            if it is running then
                try
                    return text of front document
                on error
                    return "ERROR_NO_DOCUMENT"
                end try
            else
                return "ERROR_NOT_RUNNING"
            end if
        end tell
        """

        if let scriptObject = NSAppleScript(source: script) {
            var error: NSDictionary?
            let result = scriptObject.executeAndReturnError(&error)

            if let err = error {
                Log.log("[TEST] ❌ AppleScript 错误: \(err)")
                Log.log("[TEST] ========== 测试失败 ==========")
            } else {
                let content = result.stringValue ?? ""
                Log.log("[TEST] TextEdit 内容: \"\(content)\"")

                if content.contains("编辑后的文字") {
                    Log.log("[TEST] ✅✅✅ 测试通过！")
                    Log.log("[TEST] ========== 测试成功 ==========")
                } else {
                    Log.log("[TEST] ❌ 测试失败：期望 '编辑后的文字'，实际 '\(content)'")
                    Log.log("[TEST] ========== 测试失败 ==========")

                    // 输出诊断信息
                    diagnosePanelIssue()
                }
            }
        }
    }

    private func diagnosePanelIssue() {
        Log.log("[TEST] === 诊断信息 ===")

        if let panel = inputPanel {
            Log.log("[TEST] 面板状态:")
            Log.log("[TEST]   - isVisible: \(panel.panel.isVisible)")
            Log.log("[TEST]   - isKeyWindow: \(panel.panel.isKeyWindow)")
            Log.log("[TEST]   - canBecomeKey: \(panel.panel.canBecomeKey)")
            Log.log("[TEST]   - styleMask: \(panel.panel.styleMask.rawValue)")
            Log.log("[TEST]   - level: \(panel.panel.level.rawValue)")
        } else {
            Log.log("[TEST] ❌ 面板已被销毁")
        }

        Log.log("[TEST] === 诊断结束 ===")
    }

    /// 多显示器面板定位测试
    private func runMultiMonitorTest() {
        Log.log("[MULTI-MONITOR] ========== 开始多显示器测试 ==========")

        // 1. 记录所有屏幕信息
        Log.log("[MULTI-MONITOR] Step 1: 检测屏幕配置")
        let screens = NSScreen.screens
        Log.log("[MULTI-MONITOR] 检测到 \(screens.count) 个屏幕")

        for (index, screen) in screens.enumerated() {
            let frame = screen.frame
            let visibleFrame = screen.visibleFrame
            Log.log("[MULTI-MONITOR] 屏幕 \(index): frame=\(frame), visibleFrame=\(visibleFrame)")
            if screen == NSScreen.main {
                Log.log("[MULTI-MONITOR]   ^ 这是主屏幕")
            }
        }

        // 2. 查找 TextEdit
        Log.log("[MULTI-MONITOR] Step 2: 查找 TextEdit")
        guard let textEdit = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) else {
            Log.log("[MULTI-MONITOR] ❌ 未找到 TextEdit，请先运行测试脚本")
            return
        }

        testTargetApp = textEdit
        lastFrontmostApp = textEdit
        Log.log("[MULTI-MONITOR] ✅ 找到 TextEdit")

        // 3. 等待 TextEdit 成为前台应用
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Log.log("[MULTI-MONITOR] Step 3: 检查 TextEdit 是否在前台")
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.bundleIdentifier == "com.apple.TextEdit" {
                Log.log("[MULTI-MONITOR] ✅ TextEdit 在前台")
            } else {
                Log.log("[MULTI-MONITOR] ⚠️  TextEdit 不在前台: \(frontmost?.localizedName ?? "unknown")")
            }

            // 4. 获取光标位置
            Log.log("[MULTI-MONITOR] Step 4: 获取光标位置")
            let cursorPoint = self.cursorOrMouseScreenPoint()
            Log.log("[MULTI-MONITOR] 光标位置: (\(cursorPoint.x), \(cursorPoint.y))")

            // 5. 找到包含光标的屏幕
            Log.log("[MULTI-MONITOR] Step 5: 查找包含光标的屏幕")
            let targetScreen = NSScreen.screens.first { screen in
                screen.frame.contains(cursorPoint)
            }

            if let screen = targetScreen {
                let frame = screen.frame
                Log.log("[MULTI-MONITOR] ✅ 找到目标屏幕: frame=\(frame)")

                // 检查是否是主屏幕
                if screen == NSScreen.main {
                    Log.log("[MULTI-MONITOR]   这是主屏幕")
                } else {
                    Log.log("[MULTI-MONITOR]   这是副屏幕")
                }
            } else {
                Log.log("[MULTI-MONITOR] ❌ 未找到包含光标的屏幕")
                Log.log("[MULTI-MONITOR]   尝试检查每个屏幕:")
                for (index, screen) in NSScreen.screens.enumerated() {
                    let contains = screen.frame.contains(cursorPoint)
                    Log.log("[MULTI-MONITOR]   屏幕 \(index): contains=\(contains), frame=\(screen.frame)")
                }
            }

            // 6. 模拟识别结果并显示面板
            Log.log("[MULTI-MONITOR] Step 6: 显示面板")
            self.accumulatedText = "多显示器测试文字"
            self.isRecording = false

            // 创建面板
            self.inputPanel = VoiceInputPanel()
            self.inputPanel?.onPanelClicked = { [weak self] in
                self?.handlePanelClicked()
            }
            self.inputPanel?.onEditingFinished = { [weak self] text in
                self?.handleEditingFinished(text)
            }

            // 显示面板
            self.inputPanel?.show(near: cursorPoint)
            self.inputPanel?.updateText(self.accumulatedText)

            // 7. 检查面板位置
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let panel = self.inputPanel?.panel {
                    let panelFrame = panel.frame
                    Log.log("[MULTI-MONITOR] Step 7: 面板已显示")
                    Log.log("[MULTI-MONITOR] 面板位置: origin=(\(panelFrame.origin.x), \(panelFrame.origin.y)), size=(\(panelFrame.width), \(panelFrame.height))")
                    Log.log("[MULTI-MONITOR] 面板可见性: \(panel.isVisible)")

                    // 检查面板在哪个屏幕上
                    let panelCenter = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
                    let panelScreen = NSScreen.screens.first { screen in
                        screen.frame.contains(panelCenter)
                    }

                    if let screen = panelScreen {
                        Log.log("[MULTI-MONITOR] 面板实际所在屏幕: frame=\(screen.frame)")
                        if screen == NSScreen.main {
                            Log.log("[MULTI-MONITOR]   面板在主屏幕上")
                        } else {
                            Log.log("[MULTI-MONITOR]   面板在副屏幕上")
                        }

                        // 对比目标屏幕和实际屏幕
                        if let target = targetScreen {
                            if screen == target {
                                Log.log("[MULTI-MONITOR] ✅✅✅ 面板显示在正确的屏幕上")
                            } else {
                                Log.log("[MULTI-MONITOR] ❌ 面板显示在错误的屏幕上")
                                Log.log("[MULTI-MONITOR]   目标屏幕: \(target.frame)")
                                Log.log("[MULTI-MONITOR]   实际屏幕: \(screen.frame)")
                            }
                        }
                    } else {
                        Log.log("[MULTI-MONITOR] ❌ 无法确定面板所在屏幕")
                    }

                    Log.log("[MULTI-MONITOR] ========== 测试完成 ==========")
                    Log.log("[MULTI-MONITOR] 请在 TextEdit 所在的显示器上查看面板是否正确显示")
                }
            }
        }
    }

    /// iTerm2 多显示器测试：模拟在 iTerm2 中按 F5，检查面板是否出现在 iTerm2 所在的显示器
    private func runITerm2MonitorTest() {
        Log.log("[ITERM2-TEST] ========== 开始 iTerm2 多显示器测试 ==========")

        // 1. 记录所有屏幕信息
        let screens = NSScreen.screens
        Log.log("[ITERM2-TEST] 检测到 \(screens.count) 个屏幕")

        for (index, screen) in screens.enumerated() {
            let frame = screen.frame
            let visibleFrame = screen.visibleFrame
            Log.log("[ITERM2-TEST] 屏幕 \(index): frame=\(frame), visibleFrame=\(visibleFrame)")
            if screen == NSScreen.main {
                Log.log("[ITERM2-TEST]   ^ 这是主屏幕")
            }
        }

        // 2. 查找 iTerm2
        Log.log("[ITERM2-TEST] Step 2: 查找 iTerm2")
        guard let iterm = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        }) else {
            Log.log("[ITERM2-TEST] ❌ 未找到 iTerm2")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.terminate(nil)
            }
            return
        }
        Log.log("[ITERM2-TEST] ✅ 找到 iTerm2")

        // 3. 记录 iTerm2 为目标应用（模拟按 F5 前的状态）
        lastFrontmostApp = iterm
        Log.log("[ITERM2-TEST] 已记录 iTerm2 为目标应用")

        // 停止前台应用捕获定时器，避免它覆盖 lastFrontmostApp
        frontmostCaptureTimer?.cancel()
        frontmostCaptureTimer = nil
        Log.log("[ITERM2-TEST] 已停止前台应用捕获定时器")

        // 4. 等待 iTerm2 窗口稳定，然后获取窗口位置
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Log.log("[ITERM2-TEST] Step 3: 检查 iTerm2 窗口位置")

            // 使用 CGWindowListCopyWindowInfo 获取 iTerm2 窗口位置
            if let pid = iterm.processIdentifier as pid_t? {
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

                            Log.log("[ITERM2-TEST] iTerm2 窗口位置: (\(x), \(y))")
                            Log.log("[ITERM2-TEST] iTerm2 窗口大小: (\(width), \(height))")

                            // 检查窗口在哪个屏幕上
                            let windowCenter = NSPoint(x: x + width / 2, y: y + height / 2)
                            if let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) {
                                Log.log("[ITERM2-TEST] iTerm2 窗口所在屏幕: frame=\(screen.frame)")
                                if screen == NSScreen.main {
                                    Log.log("[ITERM2-TEST]   窗口在主屏幕上")
                                } else {
                                    Log.log("[ITERM2-TEST]   窗口在副屏幕上")
                                }
                            }
                            break
                        }
                    }
                }
            }

            // 5. 获取光标位置（模拟 startRecording 中的调用）
            Log.log("[ITERM2-TEST] Step 4: 获取光标位置")
            let cursorPoint = self.cursorOrMouseScreenPoint()
            Log.log("[ITERM2-TEST] 光标位置: (\(cursorPoint.x), \(cursorPoint.y))")

            // 6. 查找包含光标的屏幕
            Log.log("[ITERM2-TEST] Step 5: 查找包含光标的屏幕")
            if let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(cursorPoint) }) {
                Log.log("[ITERM2-TEST] ✅ 找到目标屏幕: frame=\(targetScreen.frame)")
                if targetScreen == NSScreen.main {
                    Log.log("[ITERM2-TEST]   这是主屏幕")
                } else {
                    Log.log("[ITERM2-TEST]   这是副屏幕")
                }
            } else {
                Log.log("[ITERM2-TEST] ❌ 未找到包含光标的屏幕，将使用主屏幕")
            }

            // 7. 显示面板
            Log.log("[ITERM2-TEST] Step 6: 显示面板")
            if self.inputPanel == nil {
                self.inputPanel = VoiceInputPanel()
            }
            self.inputPanel?.show(near: cursorPoint)

            // 8. 验证面板位置
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let panel = self.inputPanel?.panel {
                    let panelFrame = panel.frame
                    Log.log("[ITERM2-TEST] Step 7: 面板已显示")
                    Log.log("[ITERM2-TEST] 面板位置: origin=(\(panelFrame.origin.x), \(panelFrame.origin.y)), size=(\(panelFrame.width), \(panelFrame.height))")
                    Log.log("[ITERM2-TEST] 面板可见性: \(panel.isVisible)")

                    // 检查面板在哪个屏幕上
                    let panelCenter = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
                    if let screen = NSScreen.screens.first(where: { $0.frame.contains(panelCenter) }) {
                        Log.log("[ITERM2-TEST] 面板实际所在屏幕: frame=\(screen.frame)")
                        if screen == NSScreen.main {
                            Log.log("[ITERM2-TEST]   面板在主屏幕上")
                        } else {
                            Log.log("[ITERM2-TEST]   面板在副屏幕上")
                        }

                        // 检查是否与光标所在屏幕一致
                        if let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(cursorPoint) }) {
                            if screen.frame == targetScreen.frame {
                                Log.log("[ITERM2-TEST] ✅✅✅ 面板显示在正确的屏幕上")
                            } else {
                                Log.log("[ITERM2-TEST] ❌❌❌ 面板显示在错误的屏幕上！")
                                Log.log("[ITERM2-TEST]   目标屏幕: \(targetScreen.frame)")
                                Log.log("[ITERM2-TEST]   实际屏幕: \(screen.frame)")
                            }
                        }
                    } else {
                        Log.log("[ITERM2-TEST] ❌ 无法确定面板所在屏幕")
                    }

                    Log.log("[ITERM2-TEST] ========== 测试完成 ==========")
                    Log.log("[ITERM2-TEST] 请在 iTerm2 所在的显示器上查看面板是否正确显示")
                    Log.log("[ITERM2-TEST] ")
                    Log.log("[ITERM2-TEST] 分析：对于终端应用（iTerm2），AX API 可能无法获取文本光标位置")
                    Log.log("[ITERM2-TEST] 因此会 fallback 到鼠标位置，如果鼠标不在 iTerm2 窗口上，面板会显示在错误的显示器")
                }
            }
        }
    }
}
