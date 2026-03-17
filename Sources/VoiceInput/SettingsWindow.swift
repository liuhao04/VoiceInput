import AppKit

final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var triggerKeyButtons: [TriggerKey: NSButton] = [:]
    private var volcAppIdField: NSTextField!
    private var volcAccessTokenField: NSTextField!
    private var volcResourceIdField: NSTextField!
    private var asrURLField: NSTextField!
    private var boostingTableIdField: NSTextField!

    static let shared = SettingsWindow()

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let windowWidth: CGFloat = 680
        let margin: CGFloat = 28
        let contentWidth = windowWidth - margin * 2

        // 布局参数
        let sectionSpacing: CGFloat = 22
        let titleHeight: CGFloat = 17
        let titleToContent: CGFloat = 12
        let checkboxHeight: CGFloat = 20
        let checkboxVSpacing: CGFloat = 8
        let checkboxColumns = 3
        let checkboxRows = (TriggerKey.allCases.count + checkboxColumns - 1) / checkboxColumns
        let fieldHeight: CGFloat = 24
        let fieldSpacing: CGFloat = 10
        let labelWidth: CGFloat = 130
        let buttonHeight: CGFloat = 32

        // 计算总高度（自上而下）
        var totalHeight: CGFloat = margin  // 顶部边距
        totalHeight += titleHeight + titleToContent  // 触发键标题
        totalHeight += CGFloat(checkboxRows) * checkboxHeight + CGFloat(checkboxRows - 1) * checkboxVSpacing  // 复选框
        totalHeight += sectionSpacing  // 间距
        totalHeight += 1 + sectionSpacing  // 分隔线 + 间距
        totalHeight += titleHeight + titleToContent  // 火山引擎标题
        totalHeight += 5 * fieldHeight + 4 * fieldSpacing  // 5个输入框
        totalHeight += sectionSpacing  // 间距
        totalHeight += 1 + sectionSpacing  // 分隔线 + 间距
        totalHeight += buttonHeight  // 保存按钮
        totalHeight += 20  // 底部边距

        // 创建窗口
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: totalHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "VoiceInput 设置"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false

        let contentView = w.contentView!

        // 自上而下布局（AppKit y 轴向上，所以从 totalHeight 开始递减）
        var y = totalHeight - margin

        // ── 触发键区域 ──
        y -= titleHeight
        let triggerTitle = NSTextField(labelWithString: "触发键（单独按下触发语音输入）")
        triggerTitle.font = NSFont.boldSystemFont(ofSize: 13)
        triggerTitle.frame = NSRect(x: margin, y: y, width: contentWidth, height: titleHeight)
        contentView.addSubview(triggerTitle)
        y -= titleToContent

        let btnWidth: CGFloat = 140
        let btnHSpacing = (contentWidth - btnWidth * CGFloat(checkboxColumns)) / CGFloat(checkboxColumns - 1)
        let currentKeys = Config.triggerKeys
        triggerKeyButtons = [:]

        for (i, key) in TriggerKey.allCases.enumerated() {
            let col = i % checkboxColumns
            let row = i / checkboxColumns
            let bx = margin + CGFloat(col) * (btnWidth + btnHSpacing)
            let by = y - CGFloat(row) * (checkboxHeight + checkboxVSpacing) - checkboxHeight

            let btn = NSButton(checkboxWithTitle: key.displayName, target: self, action: #selector(triggerKeyToggled(_:)))
            btn.font = NSFont.systemFont(ofSize: 13)
            btn.frame = NSRect(x: bx, y: by, width: btnWidth, height: checkboxHeight)
            btn.state = currentKeys.contains(key) ? .on : .off
            btn.tag = i
            contentView.addSubview(btn)
            triggerKeyButtons[key] = btn
        }
        y -= CGFloat(checkboxRows) * (checkboxHeight + checkboxVSpacing) - checkboxVSpacing
        y -= sectionSpacing

        // ── 分隔线 ──
        let sep1 = NSBox(frame: NSRect(x: margin, y: y, width: contentWidth, height: 1))
        sep1.boxType = .separator
        contentView.addSubview(sep1)
        y -= 1 + sectionSpacing

        // ── 火山引擎配置 ──
        y -= titleHeight
        let volcTitle = NSTextField(labelWithString: "火山引擎 ASR 配置")
        volcTitle.font = NSFont.boldSystemFont(ofSize: 13)
        volcTitle.frame = NSRect(x: margin, y: y, width: contentWidth, height: titleHeight)
        contentView.addSubview(volcTitle)
        y -= titleToContent

        volcAppIdField = addFormRow(to: contentView, label: "App ID:", value: Config.volcAppId,
                                    y: &y, margin: margin, labelWidth: labelWidth, contentWidth: contentWidth,
                                    fieldHeight: fieldHeight, fieldSpacing: fieldSpacing)
        volcAccessTokenField = addFormRow(to: contentView, label: "Access Token:", value: Config.volcAccessToken,
                                          y: &y, margin: margin, labelWidth: labelWidth, contentWidth: contentWidth,
                                          fieldHeight: fieldHeight, fieldSpacing: fieldSpacing)
        volcResourceIdField = addFormRow(to: contentView, label: "Resource ID:", value: Config.volcResourceId,
                                         y: &y, margin: margin, labelWidth: labelWidth, contentWidth: contentWidth,
                                         fieldHeight: fieldHeight, fieldSpacing: fieldSpacing)
        asrURLField = addFormRow(to: contentView, label: "WebSocket URL:", value: Config.asrWebSocketURL,
                                 y: &y, margin: margin, labelWidth: labelWidth, contentWidth: contentWidth,
                                 fieldHeight: fieldHeight, fieldSpacing: fieldSpacing)
        boostingTableIdField = addFormRow(to: contentView, label: "热词表 ID:", value: Config.boostingTableId,
                                          y: &y, margin: margin, labelWidth: labelWidth, contentWidth: contentWidth,
                                          fieldHeight: fieldHeight, fieldSpacing: fieldSpacing, isLast: true)
        y -= sectionSpacing

        // ── 分隔线 ──
        let sep2 = NSBox(frame: NSRect(x: margin, y: y, width: contentWidth, height: 1))
        sep2.boxType = .separator
        contentView.addSubview(sep2)
        y -= 1 + sectionSpacing

        // ── 保存按钮（右对齐）──
        y -= buttonHeight
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: windowWidth - margin - 80, y: y, width: 80, height: buttonHeight)
        contentView.addSubview(saveBtn)

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI helpers

    private func addFormRow(to parent: NSView, label: String, value: String,
                            y: inout CGFloat, margin: CGFloat, labelWidth: CGFloat,
                            contentWidth: CGFloat, fieldHeight: CGFloat, fieldSpacing: CGFloat,
                            isLast: Bool = false) -> NSTextField {
        y -= fieldHeight

        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.alignment = .right
        lbl.frame = NSRect(x: margin, y: y + 3, width: labelWidth, height: 17)
        parent.addSubview(lbl)

        let fieldX = margin + labelWidth + 10
        let fieldW = contentWidth - labelWidth - 10
        let field = NSTextField(string: value)
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.frame = NSRect(x: fieldX, y: y, width: fieldW, height: fieldHeight)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        parent.addSubview(field)

        if !isLast {
            y -= fieldSpacing
        }

        return field
    }

    // MARK: - Actions

    @objc private func triggerKeyToggled(_ sender: NSButton) {
        let allCases = TriggerKey.allCases
        guard sender.tag < allCases.count else { return }
        let key = allCases[sender.tag]

        var keys = Config.triggerKeys
        if sender.state == .on {
            keys.insert(key)
        } else {
            if keys.count <= 1 {
                sender.state = .on
                return
            }
            keys.remove(key)
        }
        Config.triggerKeys = keys
        Log.log("[Settings] 触发键已更新: \(keys.map { $0.displayName })")
    }

    @objc private func save() {
        let appId = volcAppIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = volcAccessTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceId = volcResourceIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = asrURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let boostingId = boostingTableIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if appId.isEmpty || token.isEmpty || resourceId.isEmpty || url.isEmpty {
            let alert = NSAlert()
            alert.messageText = "配置不完整"
            alert.informativeText = "App ID、Access Token、Resource ID 和 WebSocket URL 不能为空。"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        Config.volcAppId = appId
        Config.volcAccessToken = token
        Config.volcResourceId = resourceId
        Config.asrWebSocketURL = url
        Config.boostingTableId = boostingId

        Log.log("[Settings] 火山引擎配置已保存")
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
