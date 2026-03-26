import AppKit
import SwiftUI

/// 设置窗口管理器：使用 SwiftUI SettingsView 通过 NSHostingView 嵌入 NSWindow
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show(tab: Int = 0) {
        if let w = window {
            if tab != 0 {
                // 切换 tab 时需要关闭旧窗口再重建
                w.close()
                // windowWillClose 会将 window 置 nil
            } else {
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }

        var settingsView = SettingsView()
        settingsView.onClose = { [weak self] in
            self?.window?.close()
        }
        settingsView.initialTab = tab

        let hostingView = NSHostingView(rootView: settingsView)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "VoiceInput 设置"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.contentView = hostingView

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
