import AppKit
import XCTest
@testable import VoiceInput

/// diff 视图的「接受」按钮：采用修正结果但不插入，面板回到等待操作状态。
/// 与「还原」互为镜像：还原回修正前文本，接受换成修正后文本，两者都回 awaitingAction。
final class DiffAcceptTests: XCTestCase {

    @MainActor
    func testAcceptShowsCorrectedTextAndReturnsToAwaitingAction() {
        _ = NSApplication.shared
        let panel = VoiceInputPanel()

        panel.showDiff(original: "田轨号劫的第一集", corrected: "《天轨浩劫》的第一集")
        XCTAssertEqual(panel.stage, .showingDiff)

        panel.acceptCorrection()

        XCTAssertEqual(panel.stage, .awaitingAction)
        XCTAssertEqual(panel.getCurrentText(), "《天轨浩劫》的第一集")
        XCTAssertEqual(panel.textToInsert(), "《天轨浩劫》的第一集")
        // 接受后必须恢复可编辑，否则点击文字进编辑模式后改不了字
        XCTAssertTrue(panel.isTextEditableForTesting())
    }

    /// 接受后点「重新修正」要拿修正后的文本再送模型，所以 correctedText 不能清掉
    /// （按钮文案靠它区分「修正 / 重新修正」）。
    @MainActor
    func testAcceptKeepsCorrectedTextForRecorrectLabel() {
        _ = NSApplication.shared
        let panel = VoiceInputPanel()

        panel.showDiff(original: "原文", corrected: "修正版")
        panel.acceptCorrection()

        XCTAssertEqual(panel.correctedText, "修正版")
    }

    /// 非 diff 状态下调用是 no-op，不能把面板文字换掉
    @MainActor
    func testAcceptIsNoopOutsideDiffView() {
        _ = NSApplication.shared
        let panel = VoiceInputPanel()

        panel.setTextForTesting("识别中的文字")
        panel.enterAwaitingAction()

        panel.acceptCorrection()

        XCTAssertEqual(panel.stage, .awaitingAction)
        XCTAssertEqual(panel.getCurrentText(), "识别中的文字")
    }

    /// 「还原」的既有行为不许被接受按钮的改动破坏
    @MainActor
    func testRevertStillRestoresOriginalText() {
        _ = NSApplication.shared
        let panel = VoiceInputPanel()

        panel.showDiff(original: "田轨号劫", corrected: "《天轨浩劫》")
        panel.revertCorrection()

        XCTAssertEqual(panel.stage, .awaitingAction)
        XCTAssertEqual(panel.getCurrentText(), "田轨号劫")
        XCTAssertNil(panel.correctedText)
        XCTAssertTrue(panel.isTextEditableForTesting())
    }
}
