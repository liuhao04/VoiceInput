import SwiftUI
import AppKit
import Carbon.HIToolbox

/// 快捷键录入控件。三种模式：
/// - `.combo`：要求"修饰键 + 普通键"（用于"粘贴最后识别结果"全局快捷键）
/// - `.modifierOnly`：只接受单个修饰键（保留兼容；当前未使用）
/// - `.trigger`：接受"单修饰键"或"修饰键 + 普通键"（用于自定义触发键）
///
/// 录入用 NSEvent.addLocalMonitorForEvents。ESC 或再次点击按钮取消。
struct HotkeyRecorderView: View {
    enum Mode {
        case combo
        case modifierOnly
        case trigger
    }

    @Binding var binding: HotkeyBinding?
    let mode: Mode
    let placeholder: String
    var onChange: (() -> Void)? = nil

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var errorText: String?
    /// `.trigger` 模式下暂存的单修饰键（等到所有修饰键都释放后提交）
    @State private var pendingSingleMod: (flag: UInt64, name: String)?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { toggle() }) {
                Text(displayText)
                    .font(.system(size: 12))
                    .frame(minWidth: 140, alignment: .center)
            }
            .buttonStyle(.bordered)
            if let err = errorText {
                Text(err).foregroundColor(.red).font(.caption2)
            }
        }
        .onDisappear { stop() }
    }

    private var displayText: String {
        if isRecording { return "按下快捷键…（ESC 或点击取消）" }
        return binding?.displayName ?? placeholder
    }

    private func toggle() {
        if isRecording { stop() } else { start() }
    }

    private func start() {
        errorText = nil
        pendingSingleMod = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        pendingSingleMod = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        // ESC 取消
        if event.type == .keyDown, event.keyCode == 53 {
            stop()
            return
        }

        switch mode {
        case .combo:
            guard event.type == .keyDown else { return }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else {
                errorText = "必须带修饰键"
                return
            }
            let kc = UInt32(event.keyCode)
            let carbon = carbonModifiers(from: mods)
            let name = comboDisplay(keyCode: event.keyCode, mods: mods)
            binding = HotkeyBinding(keyCode: kc, modifiers: carbon, deviceFlag: 0, displayName: name)
            onChange?()
            stop()

        case .modifierOnly:
            guard event.type == .flagsChanged else { return }
            guard let (flag, name) = pressedModifier(event: event) else { return }
            binding = HotkeyBinding(keyCode: 0, modifiers: 0, deviceFlag: flag, displayName: name)
            onChange?()
            stop()

        case .trigger:
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            if event.type == .flagsChanged {
                if mods.isEmpty {
                    // 全部修饰键已释放：如有 pending，提交为"单修饰键"绑定
                    if let pending = pendingSingleMod {
                        binding = HotkeyBinding(keyCode: 0, modifiers: 0, deviceFlag: pending.flag, displayName: pending.name)
                        onChange?()
                        stop()
                    }
                    pendingSingleMod = nil
                } else if let (flag, name) = pressedModifier(event: event) {
                    // 修饰键刚按下：记录下来，等后续是 keyDown（组合）还是释放（单键）
                    pendingSingleMod = (flag, name)
                }
                // mods 不空且不是"刚按下单修饰键"（例如第二个修饰键按下或中间释放），保持 pending 不变
            } else if event.type == .keyDown {
                pendingSingleMod = nil
                let comboMods = mods.subtracting(.function)
                guard !comboMods.isEmpty else {
                    errorText = "组合键必须含 ⌘/⌥/⌃/⇧"
                    return
                }
                let kc = UInt32(event.keyCode)
                let carbon = carbonModifiers(from: comboMods)
                let name = comboDisplay(keyCode: event.keyCode, mods: comboMods)
                binding = HotkeyBinding(keyCode: kc, modifiers: carbon, deviceFlag: 0, displayName: name)
                onChange?()
                stop()
            }
        }
    }

    // MARK: Helpers

    private func carbonModifiers(from mods: NSEvent.ModifierFlags) -> UInt32 {
        var out: UInt32 = 0
        if mods.contains(.command)  { out |= UInt32(cmdKey) }
        if mods.contains(.shift)    { out |= UInt32(shiftKey) }
        if mods.contains(.option)   { out |= UInt32(optionKey) }
        if mods.contains(.control)  { out |= UInt32(controlKey) }
        return out
    }

    private func comboDisplay(keyCode: UInt16, mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control)  { s += "⌃" }
        if mods.contains(.option)   { s += "⌥" }
        if mods.contains(.shift)    { s += "⇧" }
        if mods.contains(.command)  { s += "⌘" }
        s += keyLabel(forKeyCode: keyCode)
        return s
    }

    /// flagsChanged 事件 → 推出"刚按下"的那个单修饰键 device flag + 显示名
    private func pressedModifier(event: NSEvent) -> (UInt64, String)? {
        let mf = event.modifierFlags
        switch event.keyCode {
        case 54:  // right cmd
            if mf.contains(.command) { return (UInt64(NX_DEVICERCMDKEYMASK), "右Command") }
        case 55:  // left cmd
            if mf.contains(.command) { return (UInt64(NX_DEVICELCMDKEYMASK), "左Command") }
        case 56:  // left shift
            if mf.contains(.shift) { return (UInt64(NX_DEVICELSHIFTKEYMASK), "左Shift") }
        case 58:  // left option
            if mf.contains(.option) { return (UInt64(NX_DEVICELALTKEYMASK), "左Option") }
        case 59:  // left control
            if mf.contains(.control) { return (UInt64(NX_DEVICELCTLKEYMASK), "左Control") }
        case 60:  // right shift
            if mf.contains(.shift) { return (UInt64(NX_DEVICERSHIFTKEYMASK), "右Shift") }
        case 61:  // right option
            if mf.contains(.option) { return (UInt64(NX_DEVICERALTKEYMASK), "右Option") }
        case 62:  // right control
            if mf.contains(.control) { return (UInt64(NX_DEVICERCTLKEYMASK), "右Control") }
        case 63:  // fn
            if mf.contains(.function) { return (UInt64(NX_SECONDARYFNMASK), "Fn") }
        default:
            break
        }
        return nil
    }

    private func keyLabel(forKeyCode kc: UInt16) -> String {
        // 尝试用 TISCopyCurrentKeyboardLayoutInputSource 解析成字符；失败则 fallback 到常量表
        if let s = unicodeLabel(forKeyCode: kc) { return s }
        switch Int(kc) {
        case kVK_Return: return "⏎"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        default:
            return String(format: "Key(%d)", kc)
        }
    }

    private func unicodeLabel(forKeyCode kc: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLen = 0
        let status = data.withUnsafeBytes { buf -> OSStatus in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return -1
            }
            return UCKeyTranslate(
                base,
                kc,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &actualLen,
                &chars
            )
        }
        guard status == noErr, actualLen > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: actualLen).uppercased()
        return s.isEmpty ? nil : s
    }
}
