import AppKit

/// 测试功能：从 VoiceInputApp.swift 提取，通过 --test-* 命令行参数触发
extension AppDelegate {

    // MARK: - 右Option键测试

    func runRightOptionTest() {
        Log.log("[TEST] ========== 开始右Option键测试 ==========")

        accumulatedText = "右Option测试文字"
        Log.log("[TEST] Step 1: Mock 识别结果 = \"\(accumulatedText)\"")

        if let textEdit = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) {
            testTargetApp = textEdit
            lastFrontmostApp = textEdit
            textEdit.activate(options: .activateIgnoringOtherApps)
            Log.log("[TEST] Step 2: 设置目标应用 = TextEdit 并激活")
        } else {
            Log.log("[TEST] ❌ 未找到 TextEdit，请先打开 TextEdit")
            return
        }

        isRecording = true
        updateStatusIcon()
        Log.log("[TEST] Step 3: 设置 isRecording = true")

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

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Log.log("[TEST] Step 5: 第一次按右Option (应该停止录音)")
            Log.log("[TEST] 按下前: isRecording=\(self.isRecording), panel visible=\(self.inputPanel?.panel.isVisible ?? false)")
            self.toggleRecording()
            Log.log("[TEST] 按下后: isRecording=\(self.isRecording), panel visible=\(self.inputPanel?.panel.isVisible ?? false)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Log.log("[TEST] Step 6: 第二次按右Option (应该插入文字)")
                Log.log("[TEST] 按下前: isRecording=\(self.isRecording), panel visible=\(self.inputPanel?.panel.isVisible ?? false)")
                self.toggleRecording()
                Log.log("[TEST] 按下后: isRecording=\(self.isRecording), panel visible=\(self.inputPanel?.panel.isVisible ?? false)")

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.verifyRightOptionTest()
                }
            }
        }
    }

    private func verifyRightOptionTest() {
        Log.log("[TEST] Step 7: 验证测试结果")

        if let panel = inputPanel {
            Log.log("[TEST] ❌ 面板仍然存在，visible=\(panel.panel.isVisible)")
        } else {
            Log.log("[TEST] ✅ 面板已关闭")
        }

        Log.log("[TEST] 查看上面的日志：")
        Log.log("[TEST] - 如果看到 '[Paste] ✅ AX API 插入成功'，说明文字已成功插入")
        Log.log("[TEST] - 如果看到 '将注入 11 字到目标应用: 文本编辑'，说明功能正常")
        Log.log("[TEST] ========== 测试完成 ==========")
        Log.log("[TEST] 请检查 TextEdit 是否有 '右Option测试文字' 来确认最终结果")
    }

    // MARK: - Gemini 测试

    func runGeminiTest() {
        Log.log("[TEST] ========== 开始 Gemini 插入测试 ==========")

        let testTextPath = "/tmp/voiceinput_test/test_text.txt"
        let targetAppPath = "/tmp/voiceinput_test/target_app.txt"

        guard let testText = try? String(contentsOfFile: testTextPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let targetBundle = try? String(contentsOfFile: targetAppPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            Log.log("[TEST] ❌ 无法读取测试配置文件")
            return
        }

        Log.log("[TEST] Step 1: 测试文字 = \"\(testText)\"")
        Log.log("[TEST] Step 2: 目标应用 = \(targetBundle)")

        guard let browserApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == targetBundle }) else {
            Log.log("[TEST] ❌ 未找到浏览器: \(targetBundle)")
            return
        }

        testTargetApp = browserApp
        lastFrontmostApp = browserApp
        Log.log("[TEST] Step 3: 找到浏览器: \(browserApp.localizedName ?? "Unknown")")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.accumulatedText = testText
            Log.log("[TEST] Step 4: 设置识别结果")

            self.logFocusedElementInfo()

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

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Log.log("[TEST] Step 6: 开始插入文字")
                self.closePanelAndInsertText()

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

    // MARK: - 焦点元素诊断

    private func logFocusedElementInfo() {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let pid = frontmostApp.processIdentifier as pid_t? else {
            Log.log("[TEST] ❌ 无法获取前台应用")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        Log.log("[TEST] 前台应用: \(frontmostApp.localizedName ?? "Unknown") (\(frontmostApp.bundleIdentifier ?? ""))")

        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let focused = focusedElement else {
            Log.log("[TEST] ❌ 无法获取焦点元素")
            return
        }

        let element = focused as! AXUIElement

        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String {
            Log.log("[TEST] 焦点元素角色: \(role)")
        }

        var roleDescValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &roleDescValue) == .success,
           let roleDesc = roleDescValue as? String {
            Log.log("[TEST] 角色描述: \(roleDesc)")
        }

        var attributeNames: CFArray?
        if AXUIElementCopyAttributeNames(element, &attributeNames) == .success,
           let names = attributeNames as? [String] {
            Log.log("[TEST] 可用属性 (\(names.count)): \(names.prefix(10).joined(separator: ", "))")

            if names.contains(kAXSelectedTextAttribute as String) {
                Log.log("[TEST] ✅ 支持 AXSelectedText")
            } else {
                Log.log("[TEST] ❌ 不支持 AXSelectedText")
            }

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

    // MARK: - 面板编辑测试

    func runPanelEditTest() {
        Log.log("[TEST] ========== 开始面板编辑测试 ==========")

        accumulatedText = "原始测试文字"
        Log.log("[TEST] Step 1: Mock 识别结果 = \"\(accumulatedText)\"")

        if let textEdit = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) {
            testTargetApp = textEdit
            lastFrontmostApp = textEdit
            textEdit.activate(options: .activateIgnoringOtherApps)
            Log.log("[TEST] Step 2: 设置目标应用 = TextEdit 并激活")
        } else {
            Log.log("[TEST] ❌ 未找到 TextEdit，请先打开 TextEdit")
            return
        }

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

        let panelFrame = panel.panel.frame
        let clickX = panelFrame.origin.x + panelFrame.width / 2
        let clickY = panelFrame.origin.y + panelFrame.height / 2

        Log.log("[TEST] Step 5: 模拟点击面板中心 (\(clickX), \(clickY))")
        simulateMouseClick(at: NSPoint(x: clickX, y: clickY))

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

        let pid = ProcessInfo.processInfo.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var windowElement: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowElement) == .success,
           let windows = windowElement as? [AXUIElement],
           !windows.isEmpty {

            let window = windows[0]

            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue)
            Log.log("[TEST]   - Window role: \(roleValue as? String ?? "unknown")")

            var isKeyValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &isKeyValue) == .success {
                let isKey = (isKeyValue as? Bool) ?? false
                Log.log("[TEST]   - isKeyWindow: \(isKey)")
            }
        }

        Log.log("[TEST]   - panel.isKeyWindow: \(panel.panel.isKeyWindow)")

        Log.log("[TEST] Step 7: 修改面板文字")
        self.inputPanel?.setTextForTesting("编辑后的文字")
        Log.log("[TEST] ✅ 已修改文字: \"编辑后的文字\"")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Log.log("[TEST] Step 8: 模拟按下回车键")
            Log.log("[TEST] 按回车前 lastFrontmostApp = \\(self.lastFrontmostApp?.localizedName ?? \"nil\") (\\(self.lastFrontmostApp?.bundleIdentifier ?? \"nil\"))")
            self.inputPanel?.simulateEnterForTesting()
            Log.log("[TEST] ✅ 已按回车")

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.verifyTestResult()
            }
        }
    }

    // MARK: - 测试辅助方法

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

    // MARK: - 多显示器测试

    func runMultiMonitorTest() {
        Log.log("[MULTI-MONITOR] ========== 开始多显示器测试 ==========")

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

        Log.log("[MULTI-MONITOR] Step 2: 查找 TextEdit")
        guard let textEdit = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) else {
            Log.log("[MULTI-MONITOR] ❌ 未找到 TextEdit，请先运行测试脚本")
            return
        }

        testTargetApp = textEdit
        lastFrontmostApp = textEdit
        Log.log("[MULTI-MONITOR] ✅ 找到 TextEdit")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Log.log("[MULTI-MONITOR] Step 3: 检查 TextEdit 是否在前台")
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.bundleIdentifier == "com.apple.TextEdit" {
                Log.log("[MULTI-MONITOR] ✅ TextEdit 在前台")
            } else {
                Log.log("[MULTI-MONITOR] ⚠️  TextEdit 不在前台: \(frontmost?.localizedName ?? "unknown")")
            }

            Log.log("[MULTI-MONITOR] Step 4: 获取光标位置")
            let cursorPoint = self.cursorOrMouseScreenPoint()
            Log.log("[MULTI-MONITOR] 光标位置: (\(cursorPoint.x), \(cursorPoint.y))")

            Log.log("[MULTI-MONITOR] Step 5: 查找包含光标的屏幕")
            let targetScreen = NSScreen.screens.first { screen in
                screen.frame.contains(cursorPoint)
            }

            if let screen = targetScreen {
                let frame = screen.frame
                Log.log("[MULTI-MONITOR] ✅ 找到目标屏幕: frame=\(frame)")
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

            Log.log("[MULTI-MONITOR] Step 6: 显示面板")
            self.accumulatedText = "多显示器测试文字"
            self.isRecording = false

            self.inputPanel = VoiceInputPanel()
            self.inputPanel?.onPanelClicked = { [weak self] in
                self?.handlePanelClicked()
            }
            self.inputPanel?.onEditingFinished = { [weak self] text in
                self?.handleEditingFinished(text)
            }

            self.inputPanel?.show(near: cursorPoint)
            self.inputPanel?.updateText(self.accumulatedText)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let panel = self.inputPanel?.panel {
                    let panelFrame = panel.frame
                    Log.log("[MULTI-MONITOR] Step 7: 面板已显示")
                    Log.log("[MULTI-MONITOR] 面板位置: origin=(\(panelFrame.origin.x), \(panelFrame.origin.y)), size=(\(panelFrame.width), \(panelFrame.height))")
                    Log.log("[MULTI-MONITOR] 面板可见性: \(panel.isVisible)")

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

    // MARK: - iTerm2 多显示器测试

    func runITerm2MonitorTest() {
        Log.log("[ITERM2-TEST] ========== 开始 iTerm2 多显示器测试 ==========")

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

        lastFrontmostApp = iterm
        Log.log("[ITERM2-TEST] 已记录 iTerm2 为目标应用")

        frontmostCaptureTimer?.cancel()
        frontmostCaptureTimer = nil
        Log.log("[ITERM2-TEST] 已停止前台应用捕获定时器")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Log.log("[ITERM2-TEST] Step 3: 检查 iTerm2 窗口位置")

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

            Log.log("[ITERM2-TEST] Step 4: 获取光标位置")
            let cursorPoint = self.cursorOrMouseScreenPoint()
            Log.log("[ITERM2-TEST] 光标位置: (\(cursorPoint.x), \(cursorPoint.y))")

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

            Log.log("[ITERM2-TEST] Step 6: 显示面板")
            if self.inputPanel == nil {
                self.inputPanel = VoiceInputPanel()
            }
            self.inputPanel?.show(near: cursorPoint)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let panel = self.inputPanel?.panel {
                    let panelFrame = panel.frame
                    Log.log("[ITERM2-TEST] Step 7: 面板已显示")
                    Log.log("[ITERM2-TEST] 面板位置: origin=(\(panelFrame.origin.x), \(panelFrame.origin.y)), size=(\(panelFrame.width), \(panelFrame.height))")
                    Log.log("[ITERM2-TEST] 面板可见性: \(panel.isVisible)")

                    let panelCenter = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
                    if let screen = NSScreen.screens.first(where: { $0.frame.contains(panelCenter) }) {
                        Log.log("[ITERM2-TEST] 面板实际所在屏幕: frame=\(screen.frame)")
                        if screen == NSScreen.main {
                            Log.log("[ITERM2-TEST]   面板在主屏幕上")
                        } else {
                            Log.log("[ITERM2-TEST]   面板在副屏幕上")
                        }

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
