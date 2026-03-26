import AppKit
import ApplicationServices

/// 通过 Accessibility API 精确获取文本输入光标位置
final class CursorLocator {

    /// 获取当前聚焦文本输入框的光标位置（屏幕坐标）
    /// - Returns: 光标位置（屏幕坐标），如果无法获取则返回 nil
    static func getCursorPosition() -> NSPoint? {
        // 获取系统范围的焦点元素
        guard let focusedElement = getSystemWideFocusedElement() else {
            Log.log("[CursorLocator] 无法获取焦点元素")
            return nil
        }

        // 尝试多种方法获取光标位置
        if let position = getSelectedTextPosition(from: focusedElement) {
            Log.log("[CursorLocator] 通过 kAXSelectedTextRangeAttribute 获取光标: (\(position.x), \(position.y))")
            return position
        }

        if let position = getInsertionPointPosition(from: focusedElement) {
            Log.log("[CursorLocator] 通过 kAXInsertionPointLineNumberAttribute 获取光标: (\(position.x), \(position.y))")
            return position
        }

        if let position = getElementPosition(from: focusedElement) {
            Log.log("[CursorLocator] 通过元素位置推测光标: (\(position.x), \(position.y))")
            return position
        }

        Log.log("[CursorLocator] 所有方法均失败")
        return nil
    }

    // MARK: - Private Methods

    /// 获取系统范围的焦点元素
    private static func getSystemWideFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        guard appResult == .success, let app = focusedApp else {
            return nil
        }

        // CFTypeRef → AXUIElement: CoreFoundation 桥接类型，cast 始终成功
        let appElement = app as! AXUIElement
        var focusedElement: CFTypeRef?
        let elementResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard elementResult == .success, let element = focusedElement else {
            return nil
        }

        return (element as! AXUIElement)
    }

    /// 方法1: 通过 kAXSelectedTextRangeAttribute 获取光标位置（最精确）
    private static func getSelectedTextPosition(from element: AXUIElement) -> NSPoint? {
        var selectedRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange)
        guard rangeResult == .success else {
            return nil
        }
        let range = selectedRange as! AXValue

        var cfRange = CFRange()
        guard AXValueGetValue(range, .cfRange, &cfRange) else {
            return nil
        }

        // 获取选中文本的边界矩形
        var bounds: CFTypeRef?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            range,
            &bounds
        )

        guard boundsResult == .success else {
            return nil
        }
        let boundsValue = bounds as! AXValue

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect) else {
            return nil
        }

        // AX API 返回 CG 坐标系（原点在左上角，Y 轴向下）
        // 需要转换为 AppKit 坐标系（原点在左下角，Y 轴向上）
        guard let screenHeight = NSScreen.screens.first?.frame.height else {
            return nil
        }

        // CG rect 底部 = rect.origin.y + rect.size.height
        // 转换为 AppKit: appKitY = screenHeight - cgBottom
        let cgBottom = rect.origin.y + rect.size.height
        let appKitY = screenHeight - cgBottom

        return NSPoint(x: rect.origin.x, y: appKitY)
    }

    /// 方法2: 通过 kAXInsertionPointLineNumberAttribute 获取插入点位置
    private static func getInsertionPointPosition(from element: AXUIElement) -> NSPoint? {
        // 某些应用（如 TextEdit）支持这个属性
        var lineNumber: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXInsertionPointLineNumber" as CFString, &lineNumber)
        guard result == .success else {
            return nil
        }

        // 如果成功获取了行号，尝试结合元素位置计算
        return getElementPosition(from: element)
    }

    /// 方法3: 获取输入框元素自身的位置（Fallback）
    private static func getElementPosition(from element: AXUIElement) -> NSPoint? {
        var position: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)

        var size: CFTypeRef?
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)

        guard posResult == .success, sizeResult == .success else {
            return nil
        }
        let posValue = position as! AXValue
        let sizeValue = size as! AXValue

        var point = CGPoint.zero
        var cgSize = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &cgSize) else {
            return nil
        }

        // AX API 返回 CG 坐标系（原点在左上角，Y 轴向下）
        // 转换为 AppKit 坐标系（原点在左下角，Y 轴向上）
        guard let screenHeight = NSScreen.screens.first?.frame.height else {
            return nil
        }

        let appKitY = screenHeight - point.y - cgSize.height
        return NSPoint(x: point.x + 5, y: appKitY + 5)
    }

    /// 获取角色信息（调试用）
    static func getFocusedElementInfo() -> String? {
        guard let element = getSystemWideFocusedElement() else {
            return nil
        }

        var role: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)

        var subrole: CFTypeRef?
        let subroleResult = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)

        let roleStr = (roleResult == .success) ? (role as? String ?? "unknown") : "unknown"
        let subroleStr = (subroleResult == .success) ? (subrole as? String ?? "none") : "none"

        return "Role: \(roleStr), Subrole: \(subroleStr)"
    }
}
