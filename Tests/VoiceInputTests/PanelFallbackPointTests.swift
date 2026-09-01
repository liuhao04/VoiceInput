import AppKit
import XCTest
@testable import VoiceInput

/// 光标定位失败后的兜底落点。
///
/// 背景：Chrome 默认不构建 accessibility 树（`AXFocusedUIElement` 返回 missing value），
/// Word 拿得到焦点元素但不支持 `kAXBoundsForRange`，两者都会让 `CursorLocator` 落空。
/// 日志里这类兜底占了 8 月全部 Word/Chrome 用例的绝大多数，所以兜底落点选得好不好
/// 直接决定"面板贴不贴光标"的体感。
final class PanelFallbackPointTests: XCTestCase {

    private let window = NSRect(x: 100, y: 100, width: 800, height: 600)

    /// 鼠标在目标窗口内：直接用鼠标。按触发键前用户通常刚点过输入框，
    /// 鼠标就在注意力附近，比窗口中心近得多。
    func testMouseInsideWindowWins() {
        let mouse = NSPoint(x: 300, y: 250)
        XCTAssertEqual(AppDelegate.panelFallbackPoint(mouse: mouse, targetWindowFrame: window), mouse)
    }

    /// 鼠标停在目标窗口外（另一块屏幕、另一个窗口上）：退到窗口中心，
    /// 至少保证面板落在用户正在输入的那个窗口里，而不是飞到别处。
    func testMouseOutsideWindowFallsBackToCenter() {
        let mouse = NSPoint(x: 1400, y: 900)
        let point = AppDelegate.panelFallbackPoint(mouse: mouse, targetWindowFrame: window)
        XCTAssertEqual(point, NSPoint(x: window.midX, y: window.midY))
    }

    /// 拿不到目标窗口 frame：只能用鼠标。这是旧实现里排在最后、实际几乎跑不到的那一档。
    func testUnknownWindowUsesMouse() {
        let mouse = NSPoint(x: 42, y: 43)
        XCTAssertEqual(AppDelegate.panelFallbackPoint(mouse: mouse, targetWindowFrame: nil), mouse)
    }

    /// 空 frame 与拿不到等价：零尺寸窗口的"中心"是个没有意义的点，
    /// 而且 contains 恒为 false，不特判就会把面板钉在那个点上。
    func testEmptyWindowFrameUsesMouse() {
        let mouse = NSPoint(x: 42, y: 43)
        let empty = NSRect(x: 500, y: 500, width: 0, height: 0)
        XCTAssertEqual(AppDelegate.panelFallbackPoint(mouse: mouse, targetWindowFrame: empty), mouse)
    }

    /// 关键回归守卫：窗口中心不能再优先于鼠标。
    /// 旧实现在这个场景返回 (500, 400)，面板弹在网页正中，离光标十万八千里。
    func testWindowCenterNoLongerPreemptsMouse() {
        let mouse = NSPoint(x: 150, y: 680)   // 窗口内、靠左上，典型的地址栏/输入框附近
        let point = AppDelegate.panelFallbackPoint(mouse: mouse, targetWindowFrame: window)
        XCTAssertNotEqual(point, NSPoint(x: window.midX, y: window.midY))
        XCTAssertEqual(point, mouse)
    }
}
