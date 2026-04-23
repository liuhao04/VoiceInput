import AppKit

/// 可以成为 key window 的自定义 Panel（用于接收键盘输入）
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 可点击的 TextView，点击时触发回调
class ClickableTextView: NSTextView {
    var onMouseDown: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

/// 类似系统输入法 / Rime 的浮动面板，在光标附近实时显示语音识别结果
final class VoiceInputPanel: NSObject, NSTextViewDelegate {
    let panel: KeyablePanel
    private let textView: ClickableTextView
    private let scrollView: NSScrollView
    private let maxWidth: CGFloat = 420
    private let initialHeight: CGFloat = 100
    private let maxHeight: CGFloat = 400
    private let padding: CGFloat = 12
    private let cornerRadius: CGFloat = 10
    private let hintBarHeight: CGFloat = 24
    private var panelShowsAboveCursor = false

    private var hintBar: NSView!
    private var hintLabel: NSTextField!
    private var separatorLine: NSBox!
    private var continueButton: NSButton!
    private var waitingSpinner: NSProgressIndicator!

    var onPanelClicked: (() -> Void)?
    var onEditingFinished: ((String) -> Void)?
    var onCancelled: (() -> Void)?
    var onEditingCancelled: (() -> Void)?
    var onContinueRecording: (() -> Void)?
    private(set) var isEditing = false
    /// ASR 文本在 textView 中的插入起点
    private var asrInsertionPoint: Int = 0
    /// ASR 当前已插入的文本长度（用于替换更新）
    private var asrTextLength: Int = 0
    private var savedMainMenu: NSMenu?

    override init() {
        let totalWidth = maxWidth + padding * 2
        let totalHeight = initialHeight + padding * 2
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.hidesOnDeactivate = false

        // 用 effectView 作为 contentView，自带圆角和毛玻璃
        let effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true

        // 底部提示栏
        hintBar = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: hintBarHeight))
        hintBar.autoresizingMask = [.width]
        effectView.addSubview(hintBar)

        separatorLine = NSBox(frame: NSRect(x: padding, y: hintBarHeight - 1, width: totalWidth - padding * 2, height: 1))
        separatorLine.boxType = .separator
        separatorLine.autoresizingMask = [.width]
        effectView.addSubview(separatorLine)

        // "继续识别"按钮（编辑模式显示，录音中隐藏）
        continueButton = NSButton(title: "继续识别", target: nil, action: nil)
        continueButton.bezelStyle = .recessed
        continueButton.controlSize = .small
        continueButton.font = NSFont.systemFont(ofSize: 11)
        continueButton.isHidden = true
        let buttonWidth: CGFloat = 70
        continueButton.frame = NSRect(x: totalWidth - padding - buttonWidth, y: 2, width: buttonWidth, height: hintBarHeight - 4)
        continueButton.autoresizingMask = [.minXMargin]
        hintBar.addSubview(continueButton)

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.frame = NSRect(x: padding, y: 2, width: totalWidth - padding * 2, height: hintBarHeight - 4)
        hintLabel.autoresizingMask = [.width]
        hintLabel.stringValue = "ESC : 取消    ⏎/快捷键 : 结束识别    点击文字编辑"
        hintBar.addSubview(hintLabel)

        // 文本区域：从 hintBar 顶部到面板顶部留 padding
        let scrollY = hintBarHeight
        let scrollHeight = totalHeight - scrollY - padding
        scrollView = NSScrollView(frame: NSRect(x: padding, y: scrollY, width: totalWidth - padding * 2, height: scrollHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        effectView.addSubview(scrollView)

        let textContentWidth = totalWidth - padding * 2
        textView = ClickableTextView(frame: NSRect(x: 0, y: 0, width: textContentWidth, height: scrollHeight))
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.textContainer?.containerSize = NSSize(width: textContentWidth - 8, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: textContentWidth, height: .greatestFiniteMagnitude)
        scrollView.documentView = textView

        // 等待中旋转图标（跟在 ASR 文字末尾显示；代替以往在文字后追加 ... 的实现）
        // 作为 textView 子视图，随滚动自动跟随
        let spinnerSize: CGFloat = 14
        waitingSpinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: spinnerSize, height: spinnerSize))
        waitingSpinner.style = .spinning
        waitingSpinner.controlSize = .small
        waitingSpinner.isDisplayedWhenStopped = false
        waitingSpinner.isHidden = true
        textView.addSubview(waitingSpinner)

        panel.contentView = effectView

        super.init()

        textView.delegate = self
        textView.onMouseDown = { [weak self] in
            self?.handlePanelClick()
        }
        continueButton.target = self
        continueButton.action = #selector(continueButtonClicked)
    }

    @objc private func continueButtonClicked() {
        Log.log("[Panel] 点击继续识别按钮")
        onContinueRecording?()
    }

    private func updateHintText() {
        if isEditing {
            hintLabel.stringValue = "ESC : 取消    ⏎/快捷键 : 确认插入    tip:可在识别历史中查看"
            continueButton.isHidden = false
            // hint label 缩短宽度，给按钮让出空间
            let buttonSpace: CGFloat = 80
            hintLabel.frame.size.width = panel.frame.width - padding * 2 - buttonSpace
        } else {
            hintLabel.stringValue = "ESC : 取消    ⏎/快捷键 : 结束识别    点击文字进入编辑"
            continueButton.isHidden = true
            hintLabel.frame.size.width = panel.frame.width - padding * 2
        }
    }

    private func handlePanelClick() {
        if isEditing { return }
        Log.log("[Panel] 点击面板，停止录音进入编辑模式")
        onPanelClicked?()
    }

    func enterEditMode() {
        hideWaitingDots()
        isEditing = true
        updateHintText()

        panel.styleMask.remove(.nonactivatingPanel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        setupEditMenu()
    }

    private func exitEditMode() {
        isEditing = false
        updateHintText()
        panel.styleMask.insert(.nonactivatingPanel)
        restoreMainMenu()
    }

    /// 准备从编辑模式恢复录音：记录当前光标位置，退出编辑模式但保留面板
    func prepareForContinueRecording() {
        asrInsertionPoint = textView.selectedRange().location
        asrTextLength = 0
        exitEditMode()
    }

    /// ASR 流式结果：在 asrInsertionPoint 处插入/替换文本
    func insertOrReplaceASRText(_ text: String) {
        guard panel.isVisible, !isEditing else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsString = textView.string as NSString
        let safeStart = min(asrInsertionPoint, nsString.length)
        let safeEnd = min(safeStart + asrTextLength, nsString.length)
        let replaceRange = NSRange(location: safeStart, length: safeEnd - safeStart)

        // 先去掉可能存在的等待点
        hideWaitingDots()

        textView.replaceCharacters(in: replaceRange, with: trimmed)
        asrTextLength = (trimmed as NSString).length
        let newCursorPos = safeStart + asrTextLength
        textView.setSelectedRange(NSRange(location: newCursorPos, length: 0))
        resizePanelToFitText()
        if !trimmed.isEmpty {
            textView.scrollRangeToVisible(NSRange(location: newCursorPos, length: 0))
        }
    }

    private func setupEditMenu() {
        savedMainMenu = NSApp.mainMenu

        let mainMenu = NSMenu()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func restoreMainMenu() {
        NSApp.mainMenu = savedMainMenu
        savedMainMenu = nil
    }

    // NSTextViewDelegate: 监听回车键和 ESC 键
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let text = textView.string
            exitEditMode()
            onEditingFinished?(text)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if isEditing {
                // 编辑模式 ESC：取消，关闭面板（但记录历史）
                exitEditMode()
                onEditingCancelled?()
            } else {
                onCancelled?()
            }
            return true
        }
        return false
    }

    /// 在指定位置显示面板（录音开始时调用）
    func show(near screenPoint: NSPoint) {
        let margin: CGFloat = 8
        let size = NSSize(width: maxWidth + padding * 2, height: initialHeight + padding * 2)

        let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame

        var originX = screenPoint.x
        var originY = screenPoint.y - size.height - margin
        panelShowsAboveCursor = false

        if originY < visibleFrame.minY {
            originY = screenPoint.y + margin + 34
            panelShowsAboveCursor = true
        }
        if originY + size.height > visibleFrame.maxY {
            originY = visibleFrame.maxY - size.height
        }
        if originX + size.width > visibleFrame.maxX {
            originX = visibleFrame.maxX - size.width
        }
        if originX < visibleFrame.minX {
            originX = visibleFrame.minX
        }

        panel.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: size), display: true)
        textView.string = ""
        asrInsertionPoint = 0
        asrTextLength = 0
        isEditing = false
        updateHintText()
        panel.orderFrontRegardless()
    }

    /// 根据文字内容动态调整面板高度
    private func resizePanelToFitText() {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let textHeight = layoutManager.usedRect(for: textContainer).height
        let insetHeight = textView.textContainerInset.height * 2
        let contentHeight = textHeight + insetHeight

        let targetHeight = min(max(contentHeight + hintBarHeight, initialHeight), maxHeight)
        let panelHeight = targetHeight + padding * 2

        let currentFrame = panel.frame
        let currentPanelHeight = currentFrame.height

        if abs(panelHeight - currentPanelHeight) < 1 { return }

        var newOrigin = currentFrame.origin
        if !panelShowsAboveCursor {
            newOrigin.y = currentFrame.origin.y + currentPanelHeight - panelHeight
        }

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: currentFrame.midX, y: currentFrame.midY)) }) ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            if newOrigin.y < visibleFrame.minY {
                newOrigin.y = visibleFrame.minY
            }
            if newOrigin.y + panelHeight > visibleFrame.maxY {
                newOrigin.y = visibleFrame.maxY - panelHeight
            }
        }

        let newFrame = NSRect(x: newOrigin.x, y: newOrigin.y, width: currentFrame.width, height: panelHeight)
        panel.setFrame(newFrame, display: true, animate: false)
    }

    /// 在文字末尾显示旋转等待图标
    func showWaitingDots() {
        guard !isEditing else { return }
        positionSpinnerAtTextEnd()
        waitingSpinner.isHidden = false
        waitingSpinner.startAnimation(nil)
    }

    /// 停止等待图标
    func hideWaitingDots() {
        waitingSpinner.stopAnimation(nil)
        waitingSpinner.isHidden = true
    }

    /// 把 spinner 摆到 textView 中最后一个字形之后（与原"…"动画位置一致）
    private func positionSpinnerAtTextEnd() {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)

        let spinnerSize: CGFloat = 14
        let inset = textView.textContainerInset
        let nsString = textView.string as NSString
        let len = nsString.length

        let x: CGFloat
        let y: CGFloat

        if len == 0 {
            // 无文字时显示在左上角（开始录音后等 ASR 首个结果的场景）
            x = inset.width + 4
            y = inset.height + 4
        } else {
            let lastCharIdx = len - 1
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: lastCharIdx)
            let rect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIdx, length: 1),
                in: textContainer
            )
            let rawX = rect.maxX + inset.width + 2
            // 若摆不下就换到下一行开头
            let maxX = textView.bounds.width - spinnerSize - 2
            if rawX > maxX {
                x = inset.width + 2
                y = rect.maxY + inset.height + 2
            } else {
                x = rawX
                let lineCenterY = rect.minY + rect.height / 2
                y = lineCenterY + inset.height - spinnerSize / 2
            }
        }

        waitingSpinner.frame = NSRect(x: x, y: y, width: spinnerSize, height: spinnerSize)
    }

    func hide() {
        hideWaitingDots()
        if isEditing {
            exitEditMode()
        }
        panel.orderOut(nil)
    }

    // MARK: - 测试辅助方法

    func setTextForTesting(_ text: String) {
        textView.string = text
    }

    func simulateEnterForTesting() {
        let text = textView.string
        exitEditMode()
        onEditingFinished?(text)
    }

    func exitEditModeForTesting() {
        exitEditMode()
    }

    func getCurrentText() -> String {
        return textView.string
    }
}
