import AppKit

/// 可以成为 key window 的自定义 Panel（用于接收键盘输入）
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 可点击的 TextView，点击时触发回调
class ClickableTextView: NSTextView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        Log.log("[Panel] ClickableTextView mouseDown 被调用")
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

/// 类似系统输入法 / Rime 的浮动面板，在光标附近实时显示语音识别结果
final class VoiceInputPanel: NSObject, NSTextViewDelegate {
    let panel: KeyablePanel  // 使用自定义的 KeyablePanel
    private let textView: ClickableTextView
    private let scrollView: NSScrollView
    private let maxWidth: CGFloat = 280
    private let maxHeight: CGFloat = 120
    private let padding: CGFloat = 10
    private let cornerRadius: CGFloat = 8

    var onPanelClicked: (() -> Void)?
    var onEditingFinished: ((String) -> Void)?
    private var savedMainMenu: NSMenu?

    override init() {
        panel = KeyablePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.hidesOnDeactivate = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: maxWidth + padding * 2, height: maxHeight + padding * 2))
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = cornerRadius
        contentView.layer?.masksToBounds = true

        let effectView = NSVisualEffectView(frame: contentView.bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
        contentView.addSubview(effectView)

        scrollView = NSScrollView(frame: NSRect(x: padding, y: padding, width: maxWidth, height: maxHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        contentView.addSubview(scrollView)

        textView = ClickableTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.textContainer?.containerSize = NSSize(width: maxWidth - 4, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: maxWidth, height: .greatestFiniteMagnitude)
        scrollView.documentView = textView

        panel.contentView = contentView
        panel.contentView?.wantsLayer = true
        panel.contentView?.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            s.shadowOffset = NSSize(width: 0, height: -2)
            s.shadowBlurRadius = 8
            return s
        }()

        super.init()

        textView.delegate = self

        // 设置 textView 的点击回调
        textView.onMouseDown = { [weak self] in
            self?.handlePanelClick()
        }
    }

    private func handlePanelClick() {
        Log.log("[Panel] 面板被点击，进入编辑模式")
        enterEditMode()
        onPanelClicked?()
    }

    private func enterEditMode() {
        Log.log("[Panel] enterEditMode: 开始")

        // 允许面板激活
        panel.styleMask.remove(.nonactivatingPanel)
        panel.styleMask.insert(.titled)

        // 激活面板并设置为 key window
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 使文本可编辑
        textView.isEditable = true

        // 强制设置焦点
        panel.makeFirstResponder(textView)

        // 选中所有文本，方便编辑
        textView.selectAll(nil)

        // 设置临时 Edit 菜单，使 Cmd+C/V/X/A/Z 等快捷键生效
        setupEditMenu()

        Log.log("[Panel] enterEditMode: 完成，isEditable=\(textView.isEditable), firstResponder=\(panel.firstResponder == textView)")
    }

    private func exitEditMode() {
        // 恢复非激活状态
        textView.isEditable = false
        panel.styleMask.remove(.titled)
        panel.styleMask.insert(.nonactivatingPanel)

        // 恢复之前的菜单
        restoreMainMenu()
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

    // NSTextViewDelegate: 监听回车键
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            Log.log("[Panel] 检测到回车，完成编辑")
            let text = textView.string
            exitEditMode()
            onEditingFinished?(text)
            return true
        }
        return false
    }
    
    /// 在指定位置显示面板（通常为光标/鼠标下方，避免遮挡）
    /// screenPoint 应该是 AppKit 坐标系（原点在左下角，Y 向上）
    func show(near screenPoint: NSPoint) {
        Log.log("[Panel.show] 输入点 (AppKit): (\(screenPoint.x), \(screenPoint.y))")

        let margin: CGFloat = 8
        let size = NSSize(width: maxWidth + padding * 2, height: maxHeight + padding * 2)

        // 获取光标所在屏幕的可见区域
        let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        Log.log("[Panel.show] 屏幕可见区域: (\(visibleFrame.origin.x), \(visibleFrame.origin.y), \(visibleFrame.size.width), \(visibleFrame.size.height))")

        // 默认在光标下方显示，x 从光标位置开始（不居中）
        var originX = screenPoint.x
        var originY = screenPoint.y - size.height - margin

        // 如果面板底部超出屏幕下边界，改为在光标上方显示
        if originY < visibleFrame.minY {
            originY = screenPoint.y + margin + 34 // 34 是大约一行文字的高度
            Log.log("[Panel.show] 光标在底部，面板改为上方显示")
        }

        // 如果面板顶部超出屏幕上边界，限制在屏幕上边界内
        if originY + size.height > visibleFrame.maxY {
            originY = visibleFrame.maxY - size.height
        }

        // 如果面板右侧超出屏幕右边界，左移
        if originX + size.width > visibleFrame.maxX {
            originX = visibleFrame.maxX - size.width
        }

        // 如果面板左侧超出屏幕左边界，右移
        if originX < visibleFrame.minX {
            originX = visibleFrame.minX
        }

        let origin = NSPoint(x: originX, y: originY)
        Log.log("[Panel.show] 面板位置: origin=(\(origin.x), \(origin.y)), size=(\(size.width), \(size.height))")

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        textView.string = ""
        panel.orderFrontRegardless()

        Log.log("[Panel.show] 面板已显示")
    }
    
    func updateText(_ text: String) {
        guard panel.isVisible else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if textView.string != trimmed {
            textView.string = trimmed
            if !trimmed.isEmpty {
                textView.scrollRangeToVisible(NSRange(location: trimmed.utf16.count, length: 0))
            }
        }
    }
    
    func hide() {
        panel.orderOut(nil)
    }

    // MARK: - 测试辅助方法

    /// 用于测试：直接设置文本内容
    func setTextForTesting(_ text: String) {
        textView.string = text
    }

    /// 用于测试：模拟按下回车（触发编辑完成）
    func simulateEnterForTesting() {
        let text = textView.string
        exitEditMode()
        onEditingFinished?(text)
    }

    /// 退出编辑模式（供外部调用，比如按右option键时）
    func exitEditModeForTesting() {
        exitEditMode()
    }

    /// 获取当前文本内容
    func getCurrentText() -> String {
        return textView.string
    }
}
