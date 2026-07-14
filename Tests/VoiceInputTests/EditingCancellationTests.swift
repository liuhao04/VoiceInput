import AppKit
import XCTest
@testable import VoiceInput

final class EditingCancellationTests: XCTestCase {
    @MainActor
    func testRecordingCancelMakesPanelTextTheLatestRecognitionResult() {
        _ = NSApplication.shared

        let delegate = AppDelegate()
        delegate.lastRecognitionResult = "上一次识别结果"
        delegate.accumulatedText = "仅包含本轮新增识别"

        let panel = VoiceInputPanel()
        panel.setTextForTesting("  继续识别前后的完整结果\n")
        delegate.inputPanel = panel

        delegate.cancelRecording()

        XCTAssertEqual(delegate.lastRecognitionResult, "继续识别前后的完整结果")
        XCTAssertEqual(delegate.accumulatedText, "")
        XCTAssertNil(delegate.inputPanel)
    }

    @MainActor
    func testEditingCancelMakesEditedTextTheLatestRecognitionResult() {
        _ = NSApplication.shared

        let wasHistoryEnabled = Config.historyEnabled
        Config.historyEnabled = false
        defer { Config.historyEnabled = wasHistoryEnabled }

        let delegate = AppDelegate()
        delegate.lastRecognitionResult = "上一次识别结果"
        delegate.accumulatedText = "编辑前的识别结果"

        let panel = VoiceInputPanel()
        panel.setTextForTesting("  当前编辑后的结果\n")
        delegate.inputPanel = panel

        delegate.handleEditingCancelled()

        XCTAssertEqual(delegate.lastRecognitionResult, "当前编辑后的结果")
        XCTAssertNil(delegate.inputPanel)
    }
}
