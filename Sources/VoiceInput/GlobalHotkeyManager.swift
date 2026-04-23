import AppKit
import Carbon.HIToolbox

/// Carbon RegisterEventHotKey 封装，用于注册系统级全局快捷键（不需额外权限）。
///
/// 支持多个并发快捷键，每个用字符串 id 标识（覆盖同 id 时自动替换旧注册）。
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private struct Entry {
        let id: String
        let ref: EventHotKeyRef
        let handler: () -> Void
    }

    private var entries: [UInt32: Entry] = [:]  // hotKeyID.id → Entry
    private var idToHandlerID: [String: UInt32] = [:]  // 字符串 id → hotKeyID.id
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = OSType(0x56494b59)  // 'VIKY'

    private init() {}

    /// 注册一个全局快捷键。若同 id 已存在则先 unregister 再 register。
    /// binding.keyCode == 0 视为无效配置直接跳过。
    func register(id: String, binding: HotkeyBinding, handler: @escaping () -> Void) {
        unregister(id: id)
        guard binding.keyCode != 0 else {
            Log.log("[Hotkey] 全局快捷键 id=\(id) keyCode=0，跳过注册")
            return
        }

        installEventHandlerIfNeeded()

        let hkID = EventHotKeyID(signature: signature, id: nextID)
        nextID += 1

        var hkRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &hkRef
        )
        if status != noErr {
            Log.log("[Hotkey] RegisterEventHotKey 失败 status=\(status) id=\(id) (可能被其他 app 占用)")
            return
        }
        guard let ref = hkRef else { return }
        entries[hkID.id] = Entry(id: id, ref: ref, handler: handler)
        idToHandlerID[id] = hkID.id
        Log.log("[Hotkey] 已注册全局快捷键 id=\(id) \(binding.displayName)")
    }

    func unregister(id: String) {
        guard let hkid = idToHandlerID.removeValue(forKey: id) else { return }
        if let entry = entries.removeValue(forKey: hkid) {
            UnregisterEventHotKey(entry.ref)
        }
    }

    /// 取消所有 id 以某前缀开头的快捷键（用于批量清理一组自定义 hotkey）。
    func unregisterAll(withPrefix prefix: String) {
        let ids = idToHandlerID.keys.filter { $0.hasPrefix(prefix) }
        for id in ids { unregister(id: id) }
    }

    func unregisterAll() {
        for (_, entry) in entries {
            UnregisterEventHotKey(entry.ref)
        }
        entries.removeAll()
        idToHandlerID.removeAll()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        let eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event = event, let userData = userData else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                let mgr = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                if let entry = mgr.entries[hkID.id] {
                    DispatchQueue.main.async {
                        entry.handler()
                    }
                }
                return noErr
            },
            1,
            [eventType],
            selfPtr,
            &handlerRef
        )
        if status == noErr {
            eventHandler = handlerRef
        } else {
            Log.log("[Hotkey] InstallEventHandler 失败 status=\(status)")
        }
    }
}
