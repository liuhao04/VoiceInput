import AppKit
import Carbon
import Foundation

/// 将文本插入到目标应用光标处：优先使用 Accessibility API 直接插入，失败则 fallback 到剪贴板方案
enum PasteboardPaste {
    /// 若传入 activateTarget：先等菜单关闭，激活目标，尝试 AX API 直接插入，失败则用剪贴板 + Cmd+V
    static func paste(text: String, activateTarget: NSRunningApplication? = nil) {
        // 检查辅助功能权限
        let trusted = AXIsProcessTrusted()
        Log.log("[Paste] 辅助功能权限: \(trusted ? "已授予" : "未授予")")

        if let app = activateTarget {
            let appName = app.localizedName ?? "未知"
            let bundleId = app.bundleIdentifier ?? "?"
            Log.log("[Paste] 目标应用: \(appName) (\(bundleId))")

            // 延长等待时间，确保菜单完全关闭
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // 强制激活（不使用 NSWorkspace.shared.open(bundleURL)，
                // 因为打开 .app bundle 会触发 kTCCServiceSystemPolicyAppBundles 权限请求）
                app.activate(options: [.activateIgnoringOtherApps])

                Log.log("[Paste] 激活目标应用")

                // 等待应用完全激活，检查前台应用
                var attempts = 0
                func waitForActivation() {
                    attempts += 1
                    let frontmost = NSWorkspace.shared.frontmostApplication
                    let isFrontmost = frontmost?.bundleIdentifier == bundleId

                    Log.log("[Paste] 检查前台应用 (尝试\(attempts)): \(frontmost?.localizedName ?? "未知"), 是否目标: \(isFrontmost)")

                    if isFrontmost || attempts >= 3 {
                        // 激活成功或达到最大尝试次数，尝试插入文本
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            insertTextViaAccessibility(text: text, fallbackApp: app)
                        }
                    } else {
                        // 重试激活
                        app.activate(options: [.activateIgnoringOtherApps])
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            waitForActivation()
                        }
                    }
                }

                waitForActivation()
            }
        } else {
            Log.log("[Paste] 无目标应用，尝试直接插入到前台应用")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                insertTextViaAccessibility(text: text, fallbackApp: nil)
            }
        }
    }

    /// 使用 Accessibility API 直接插入文本到焦点元素
    private static func insertTextViaAccessibility(text: String, fallbackApp: NSRunningApplication?) {
        Log.log("[Paste] 尝试 AX API 直接插入")

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let pid = frontmostApp.processIdentifier as pid_t? else {
            Log.log("[Paste] ❌ 无法获取前台应用 PID")
            fallbackToPasteboard(text: text, withRestore: true)
            return
        }

        let appName = frontmostApp.localizedName ?? "未知"
        let bundleId = frontmostApp.bundleIdentifier ?? "?"
        Log.log("[Paste] 前台应用: \(appName) (\(bundleId)), PID: \(pid)")

        // 检测终端类应用，使用键盘事件模拟输入
        let terminalApps = ["com.googlecode.iterm2", "com.apple.Terminal", "com.github.wez.wezterm", "net.kovidgoyal.kitty"]
        if terminalApps.contains(bundleId) {
            Log.log("[Paste] 检测到终端应用，使用剪贴板 fallback 方案（带恢复）")
            fallbackToPasteboard(text: text, withRestore: true)
            return
        }

        // 检测 Web 浏览器：优先使用系统粘贴。Unicode 键盘事件无法可靠验证，容易静默失败。
        let webBrowsers = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac"]
        if webBrowsers.contains(bundleId) {
            Log.log("[Paste] 检测到 Web 浏览器，使用剪贴板 fallback 方案（带恢复）")
            fallbackToPasteboard(text: text, withRestore: true)
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        // 获取焦点元素
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if result != .success {
            Log.log("[Paste] ❌ 无法获取焦点元素: \(result.rawValue)")
            fallbackToPasteboard(text: text, withRestore: true)
            return
        }

        guard let focused = focusedElement else {
            Log.log("[Paste] ❌ 焦点元素为空")
            fallbackToPasteboard(text: text, withRestore: true)
            return
        }

        // CFTypeRef → AXUIElement 是 CoreFoundation 类型，使用 unsafeBitCast
        let element: AXUIElement = focused as! AXUIElement

        // 记录焦点元素的角色和属性
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success {
            Log.log("[Paste] 焦点元素角色: \(role as? String ?? "未知")")
        }

        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success {
            Log.log("[Paste] 焦点元素子角色: \(subrole as? String ?? "未知")")
        }

        // 列出所有可用属性
        var attributes: CFArray?
        if AXUIElementCopyAttributeNames(element, &attributes) == .success,
           let attrArray = attributes as? [String] {
            Log.log("[Paste] 可用属性 (\(attrArray.count)): \(attrArray.prefix(10).joined(separator: ", "))")
        }

        // 尝试方法 1: 直接插入到选中文本位置
        var selectedRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange)

        if rangeResult == .success, let range = selectedRange {
            Log.log("[Paste] 获取到选中范围: \(range)")
            // 使用 AXUIElementSetAttributeValue 插入文本
            let insertResult = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)

            if insertResult == .success {
                Log.log("[Paste] 方法1: AXUIElementSetAttributeValue 返回成功")

                // 验证：等待一下，然后检查文本是否真的插入了
                usleep(50000) // 50ms
                var verifyValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &verifyValue) == .success,
                   let value = verifyValue as? String {
                    if value.contains(text) {
                        Log.log("[Paste] ✅ AX API 插入成功 (方法1: selectedText) - 已验证")
                        return
                    } else {
                        Log.log("[Paste] ⚠️  方法1: API 返回成功但验证失败，value=\"\(value.prefix(50))\", 尝试方法2")
                    }
                } else {
                    Log.log("[Paste] ⚠️ 方法1: API 返回成功但无法验证，继续尝试其他插入方案")
                }
            } else {
                Log.log("[Paste] 方法1失败: \(insertResult.rawValue), 错误描述: \(axErrorDescription(insertResult))")
            }
        } else {
            Log.log("[Paste] 无法获取选中范围: \(rangeResult.rawValue), 错误描述: \(axErrorDescription(rangeResult))")
        }

        // 尝试方法 2: 获取当前值并追加/替换
        var currentValue: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue)

        if valueResult == .success {
            let currentStr = (currentValue as? String) ?? ""
            Log.log("[Paste] 获取到当前值，长度: \(currentStr.count)")

            // 如果有选中文本范围，替换选中部分；否则追加到末尾
            if rangeResult == .success,
               let range = selectedRange,
               CFGetTypeID(range) == AXValueGetTypeID() {
                // CFTypeRef → AXValue: CFGetTypeID 已验证类型，cast 安全
                let rangeValue = range as! AXValue
                var cfRange = CFRange(location: 0, length: 0)
                if AXValueGetValue(rangeValue, .cfRange, &cfRange) {
                    let current = (currentValue as? String) ?? ""
                    let start = current.index(current.startIndex, offsetBy: cfRange.location, limitedBy: current.endIndex) ?? current.startIndex
                    let end = current.index(start, offsetBy: cfRange.length, limitedBy: current.endIndex) ?? start

                    var newValue = current
                    newValue.replaceSubrange(start..<end, with: text)

                    let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef)
                    if setResult == .success {
                        // 验证是否真的插入了
                        var verifyValue: CFTypeRef?
                        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &verifyValue) == .success {
                            let actualValue = (verifyValue as? String) ?? ""
                            if actualValue == newValue {
                                Log.log("[Paste] ✅ AX API 插入成功并验证 (方法2: 替换选中)")

                                // 移动光标到插入文本的末尾
                                let newLocation = cfRange.location + text.utf16.count
                                var newRange = CFRange(location: newLocation, length: 0)
                                if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
                                    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newRangeValue as CFTypeRef)
                                }
                                return
                            } else {
                                Log.log("[Paste] ⚠️ 方法2返回成功但验证失败：期望长度 \(newValue.count), 实际长度 \(actualValue.count)")
                            }
                        } else {
                            Log.log("[Paste] ⚠️ 方法2返回成功但无法验证")
                        }
                    } else {
                        Log.log("[Paste] 方法2失败: \(setResult.rawValue)")
                    }
                }
            } else {
                // 没有选中范围，尝试追加到末尾
                let current = (currentValue as? String) ?? ""
                let newValue = current + text

                let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef)
                if setResult == .success {
                    var verifyValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &verifyValue) == .success,
                       let actualValue = verifyValue as? String,
                       actualValue == newValue {
                        Log.log("[Paste] ✅ AX API 插入成功并验证 (方法2: 追加)")
                        return
                    }
                    Log.log("[Paste] ⚠️ 方法2追加返回成功但无法验证，继续 fallback")
                } else {
                    Log.log("[Paste] 方法2失败: \(setResult.rawValue)")
                }
            }
        }

        // 尝试方法 3: 检查是否支持 performAction
        Log.log("[Paste] 尝试检查可用 actions（部分应用不支持）")

        // 所有 AX 方法都失败或无法验证，使用系统粘贴作为最终可恢复 fallback。
        Log.log("[Paste] ❌ AX API 未确认插入成功，fallback 到剪贴板方案（带恢复）")
        fallbackToPasteboard(text: text, withRestore: true)
    }

    // MARK: - 剪贴板保存/恢复

    /// 保存的剪贴板数据：按 item 结构保存，支持多 item 恢复
    private struct SavedPasteboardData {
        /// 每个 item 对应一组 (type, data)
        let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
        /// 保存时的 changeCount，用于检测外部修改
        let changeCount: Int
    }

    /// 保存当前剪贴板内容（按 item 结构保存）
    /// 注意：剪贴板原本为空时返回 items 为空的占位，而非 nil——这样粘贴完成后
    /// 仍会触发 restorePasteboard 把剪贴板清空，避免识别文本永久残留。
    private static func savePasteboard() -> SavedPasteboardData {
        let pb = NSPasteboard.general
        let changeCount = pb.changeCount
        guard let items = pb.pasteboardItems, !items.isEmpty else {
            Log.log("[Paste] 剪贴板为空，记录空状态（粘贴后将清空）")
            return SavedPasteboardData(items: [], changeCount: changeCount)
        }

        var savedItems: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []
        for item in items {
            var itemData: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData.append((type: type, data: data))
                }
            }
            if !itemData.isEmpty {
                savedItems.append(itemData)
            }
        }

        Log.log("[Paste] 保存剪贴板内容: \(savedItems.count) 个 item, changeCount=\(changeCount)")
        return SavedPasteboardData(items: savedItems, changeCount: changeCount)
    }

    /// 恢复剪贴板内容（按 item 结构恢复，保留多 item）
    /// items 为空时表示原本就是空剪贴板，清空即可（移除粘贴时写入的识别文本）。
    private static func restorePasteboard(_ saved: SavedPasteboardData) {
        let pb = NSPasteboard.general
        pb.clearContents()

        if saved.items.isEmpty {
            Log.log("[Paste] 剪贴板原为空，已清空（移除识别文本）")
            return
        }

        var pasteboardItems: [NSPasteboardItem] = []
        for itemData in saved.items {
            let item = NSPasteboardItem()
            for entry in itemData {
                item.setData(entry.data, forType: entry.type)
            }
            pasteboardItems.append(item)
        }
        pb.writeObjects(pasteboardItems)

        Log.log("[Paste] 已恢复剪贴板内容: \(saved.items.count) 个 item")
    }

    /// 备用方案：剪贴板 + 模拟 Cmd+V
    /// withRestore: 为 true 时先保存剪贴板，粘贴完成后恢复
    private static func fallbackToPasteboard(text: String, withRestore: Bool = false) {
        Log.log("[Paste] 使用剪贴板 fallback 方案 (恢复剪贴板: \(withRestore))")

        // 如果需要恢复，先保存剪贴板
        let savedPasteboard = withRestore ? savePasteboard() : nil

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let changeCountAfterWrite = pb.changeCount
        Log.log("[Paste] 已写剪贴板 \(text.count) 字: \"\(text.prefix(20))...\", changeCount=\(changeCountAfterWrite)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            simulateCmdV()

            // 如果有保存的剪贴板数据，通过轮询等待 Cmd+V 完成后恢复
            if let saved = savedPasteboard {
                waitForPasteAndRestore(saved: saved, changeCountAfterWrite: changeCountAfterWrite)
            }
        }
    }

    /// 轮询等待 Cmd+V 完成，然后恢复剪贴板
    /// - changeCountAfterWrite: 写入文本后的 changeCount
    /// - 逻辑：等待目标应用读取剪贴板（通过短暂延迟），然后检查 changeCount 确认用户没有在中间复制新内容
    private static func waitForPasteAndRestore(saved: SavedPasteboardData, changeCountAfterWrite: Int, attempt: Int = 0) {
        let pollInterval = 0.2 // 200ms，轮询3次（共0.6秒）后恢复

        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            let currentChangeCount = NSPasteboard.general.changeCount

            if currentChangeCount != changeCountAfterWrite {
                // changeCount 变了，说明有其他程序修改了剪贴板（用户复制了新内容）
                Log.log("[Paste] ⚠️ 剪贴板已被外部修改 (changeCount: \(changeCountAfterWrite) → \(currentChangeCount))，跳过恢复")
                return
            }

            if attempt < 2 {
                // 前几次轮询：等待 Cmd+V 真正完成（给目标应用足够时间读取剪贴板）
                waitForPasteAndRestore(saved: saved, changeCountAfterWrite: changeCountAfterWrite, attempt: attempt + 1)
                return
            }

            // 已等待足够时间（至少 0.1 + 0.6 = 0.7秒），恢复剪贴板
            // 再次检查 changeCount 确认没有外部修改
            let finalChangeCount = NSPasteboard.general.changeCount
            if finalChangeCount != changeCountAfterWrite {
                Log.log("[Paste] ⚠️ 恢复前剪贴板被修改 (changeCount: \(changeCountAfterWrite) → \(finalChangeCount))，跳过恢复")
                return
            }

            restorePasteboard(saved)
        }
    }

    private static func simulateCmdV() {
        Log.log("[Paste] simulateCmdV: 开始")

        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0.0

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            Log.log("[Paste] simulateCmdV: 创建 CGEvent 失败")
            return
        }

        // 只使用 flags 方式，不手动发送 Cmd 键
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        Log.log("[Paste] keyDown posted")

        usleep(10000) // 10ms
        keyUp.post(tap: .cghidEventTap)
        Log.log("[Paste] keyUp posted")

        Log.log("[Paste] simulateCmdV: 完成")
    }

    private static func axErrorDescription(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(error.rawValue))"
        }
    }

}
