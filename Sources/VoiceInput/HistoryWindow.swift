import AppKit

/// 支持 ⌘C 复制的 NSTableView 子类
private class CopyableTableView: NSTableView {
    var onCopy: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // ⌘C
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            onCopy?()
            return
        }
        super.keyDown(with: event)
    }
}

final class HistoryWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = HistoryWindow()

    private var window: NSWindow?
    private var tableView: CopyableTableView!
    private var datePopup: NSPopUpButton!
    private var countLabel: NSTextField!
    private var allMonthEntries: [HistoryEntry] = []
    private var entries: [HistoryEntry] = []
    private var months: [(year: Int, month: Int)] = []
    /// datePopup 选项对应的筛选值：nil=整月，Int=具体日
    private var dateFilterOptions: [(year: Int, month: Int, day: Int?)] = []

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let windowWidth: CGFloat = 800
        let windowHeight: CGFloat = 520

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "识别历史"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 550, height: 300)

        let contentView = w.contentView!

        // 顶部：筛选栏（固定在顶部）
        let topBar = NSView(frame: NSRect(x: 0, y: windowHeight - 40, width: windowWidth, height: 40))
        topBar.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(topBar)

        let dateLabel = NSTextField(labelWithString: "日期：")
        dateLabel.font = NSFont.systemFont(ofSize: 13)
        dateLabel.frame = NSRect(x: 16, y: 8, width: 45, height: 24)
        topBar.addSubview(dateLabel)

        datePopup = NSPopUpButton(frame: NSRect(x: 60, y: 6, width: 180, height: 28), pullsDown: false)
        datePopup.target = self
        datePopup.action = #selector(dateChanged)
        topBar.addSubview(datePopup)

        // 底部：记录数统计
        countLabel = NSTextField(labelWithString: "")
        countLabel.font = NSFont.systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        countLabel.frame = NSRect(x: 16, y: 8, width: windowWidth - 32, height: 20)
        countLabel.autoresizingMask = [.width]
        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: 36))
        bottomBar.autoresizingMask = [.width]
        bottomBar.addSubview(countLabel)
        contentView.addSubview(bottomBar)

        // 中间：表格
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 36, width: windowWidth, height: windowHeight - 76))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        tableView = CopyableTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = true
        tableView.onCopy = { [weak self] in self?.copySelected() }

        // 右键菜单也支持复制
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "复制", action: #selector(copyMenuAction(_:)), keyEquivalent: ""))
        tableView.menu = menu

        // 四列：时间、应用、识别文本、编辑后文本
        let timeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeCol.title = "时间"
        timeCol.width = 90
        timeCol.minWidth = 80
        timeCol.maxWidth = 120
        timeCol.resizingMask = .userResizingMask
        tableView.addTableColumn(timeCol)

        let appCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appCol.title = "应用"
        appCol.width = 90
        appCol.minWidth = 50
        appCol.maxWidth = 150
        appCol.resizingMask = .userResizingMask
        tableView.addTableColumn(appCol)

        let textCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textCol.title = "识别文本"
        textCol.width = 280
        textCol.minWidth = 100
        textCol.resizingMask = [.userResizingMask, .autoresizingMask]
        tableView.addTableColumn(textCol)

        let editedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("edited"))
        editedCol.title = "编辑后"
        editedCol.width = 280
        editedCol.minWidth = 80
        editedCol.resizingMask = [.userResizingMask, .autoresizingMask]
        tableView.addTableColumn(editedCol)

        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        // 列宽变化时重新计算行高
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnResized),
            name: NSTableView.columnDidResizeNotification, object: tableView
        )

        window = w

        reloadDateOptions()

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Data

    private func reloadDateOptions() {
        months = RecognitionHistory.availableMonths()
        datePopup.removeAllItems()
        dateFilterOptions = []

        if months.isEmpty {
            let cal = Calendar.current
            let now = Date()
            let year = cal.component(.year, from: now)
            let month = cal.component(.month, from: now)
            datePopup.addItem(withTitle: String(format: "%04d年%02d月", year, month))
            dateFilterOptions.append((year: year, month: month, day: nil))
            allMonthEntries = []
            entries = []
            tableView.reloadData()
            updateCount()
            return
        }

        // 为每个月份添加"整月"选项和"具体日"选项
        for m in months {
            let monthEntries = RecognitionHistory.load(year: m.year, month: m.month)
            let cal = Calendar.current
            var daySet = Set<Int>()
            for entry in monthEntries {
                daySet.insert(cal.component(.day, from: entry.time))
            }
            let sortedDays = daySet.sorted(by: >)  // 倒序，最近的日期在前

            // 整月选项
            let monthTitle = String(format: "%04d年%02d月", m.year, m.month)
            datePopup.addItem(withTitle: monthTitle)
            dateFilterOptions.append((year: m.year, month: m.month, day: nil))

            // 每天选项（缩进显示）
            for day in sortedDays {
                let dayTitle = String(format: "    %02d月%02d日", m.month, day)
                datePopup.addItem(withTitle: dayTitle)
                dateFilterOptions.append((year: m.year, month: m.month, day: day))
            }
        }

        loadSelectedDate()
    }

    private func loadSelectedDate() {
        let idx = datePopup.indexOfSelectedItem
        guard idx >= 0, idx < dateFilterOptions.count else {
            allMonthEntries = []
            entries = []
            tableView.reloadData()
            updateCount()
            return
        }

        let opt = dateFilterOptions[idx]
        allMonthEntries = RecognitionHistory.load(year: opt.year, month: opt.month).reversed()

        if let day = opt.day {
            let cal = Calendar.current
            entries = allMonthEntries.filter { cal.component(.day, from: $0.time) == day }
        } else {
            entries = allMonthEntries
        }

        tableView.reloadData()
        updateCount()
    }

    private func updateCount() {
        countLabel.stringValue = "共 \(entries.count) 条记录"
    }

    // MARK: - Actions

    @objc private func dateChanged(_ sender: NSPopUpButton) {
        loadSelectedDate()
    }

    @objc private func columnResized(_ notification: Notification) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshRowHeights), object: nil)
        perform(#selector(refreshRowHeights), with: nil, afterDelay: 0.05)
    }

    @objc private func refreshRowHeights() {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<entries.count))
        NSAnimationContext.endGrouping()
    }

    @objc private func copyMenuAction(_ sender: Any?) {
        copySelected()
    }

    private func copySelected() {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }

        let texts = selectedRows.compactMap { row -> String? in
            guard row < entries.count else { return nil }
            let entry = entries[row]
            return entry.edited ?? entry.text
        }

        let combined = texts.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)

        let original = countLabel.stringValue
        let preview = combined.prefix(40)
        countLabel.stringValue = "已复制 \(texts.count) 条记录到剪贴板：\(preview)..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.countLabel.stringValue = original
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count, let column = tableColumn else { return nil }

        let id = column.identifier
        let cellId = NSUserInterfaceItemIdentifier("HistoryCell_\(id.rawValue)")

        let cell: NSTextField
        if let existing = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField {
            cell = existing
        } else {
            cell = NSTextField(wrappingLabelWithString: "")
            cell.identifier = cellId
            cell.font = NSFont.systemFont(ofSize: 12)
            cell.maximumNumberOfLines = 0
            cell.cell?.wraps = true
            cell.cell?.isScrollable = false
        }

        let entry = entries[row]
        switch id.rawValue {
        case "time":
            cell.stringValue = entry.displayTime
            cell.textColor = .secondaryLabelColor
        case "app":
            cell.stringValue = entry.app
            cell.textColor = .secondaryLabelColor
        case "text":
            cell.stringValue = entry.text
            cell.textColor = .labelColor
        case "edited":
            cell.stringValue = entry.edited ?? ""
            cell.textColor = entry.edited != nil ? .systemBlue : .secondaryLabelColor
        default:
            break
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < entries.count else { return 24 }

        let entry = entries[row]
        let font = NSFont.systemFont(ofSize: 12)
        let minHeight: CGFloat = 24

        let textColWidth = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("text"))?.width ?? 200
        let editedColWidth = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("edited"))?.width ?? 200

        let padding: CGFloat = 8
        let textHeight = heightForString(entry.text, width: textColWidth - padding, font: font)
        let editedHeight = heightForString(entry.edited ?? "", width: editedColWidth - padding, font: font)

        let maxH = max(textHeight, editedHeight)
        return max(minHeight, maxH + 8)
    }

    private func heightForString(_ string: String, width: CGFloat, font: NSFont) -> CGFloat {
        guard !string.isEmpty, width > 0 else { return 17 }
        let attrStr = NSAttributedString(string: string, attributes: [.font: font])
        let rect = attrStr.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSTableView.columnDidResizeNotification, object: tableView)
        window = nil
    }
}
