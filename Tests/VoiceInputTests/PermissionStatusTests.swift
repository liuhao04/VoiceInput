import AVFoundation
import XCTest
@testable import VoiceInput

/// 权限状态三件事的守卫测试。背景见 PermissionStatus.swift 顶部注释。
final class PermissionStatusTests: XCTestCase {

    // MARK: - 变迁判定：只有未授权→已授权才触发重建

    func testFirstObservationIsBaselineNotTransition() {
        var tracker = PermissionTransitionTracker()
        XCTAssertNil(tracker.observe(trusted: false))
        XCTAssertEqual(tracker.lastTrusted, false)

        var trackerTrusted = PermissionTransitionTracker()
        XCTAssertNil(trackerTrusted.observe(trusted: true))
        XCTAssertEqual(trackerTrusted.lastTrusted, true)
    }

    func testGrantAfterLaunchIsReportedExactlyOnce() {
        var tracker = PermissionTransitionTracker()
        _ = tracker.observe(trusted: false)
        XCTAssertNil(tracker.observe(trusted: false), "权限一直没给，不算变化")
        XCTAssertEqual(tracker.observe(trusted: true), .granted, "启动后才授权，正是要重建 tap 的时刻")
        XCTAssertNil(tracker.observe(trusted: true), "已授权状态持续，不能反复重建")
    }

    func testRevokeThenRegrantReportsBoth() {
        var tracker = PermissionTransitionTracker()
        _ = tracker.observe(trusted: true)
        XCTAssertEqual(tracker.observe(trusted: false), .revoked)
        XCTAssertEqual(tracker.observe(trusted: true), .granted)
    }

    // MARK: - 日志如实标注

    func testTapCreationLogOnlyShowsCheckmarkWhenTrusted() {
        let trusted = HotkeyTapLog.creationLine(level: "HID-level", trusted: true, listenAccess: true)
        XCTAssertTrue(trusted.contains("✅"))
        XCTAssertTrue(trusted.contains("已授权"))
        XCTAssertFalse(trusted.contains("⚠️"))

        let untrusted = HotkeyTapLog.creationLine(level: "HID-level", trusted: false, listenAccess: false)
        XCTAssertFalse(untrusted.contains("✅"), "权限没给不许打 ✅，这正是 1.1.0 日志骗人的地方")
        XCTAssertTrue(untrusted.contains("⚠️"))
        XCTAssertTrue(untrusted.contains("未授权"))
        XCTAssertTrue(untrusted.contains("自动重建"), "要告诉排查者授权后不需要重启")
    }

    func testTapCreationLogCarriesLevelAndListenPreflight() {
        let line = HotkeyTapLog.creationLine(level: "Session-level", trusted: true, listenAccess: false)
        XCTAssertTrue(line.contains("Session-level"))
        XCTAssertTrue(line.contains("未通过"))
    }

    // MARK: - 常驻状态文案

    func testAccessibilityStatusTextDistinguishesStates() {
        XCTAssertNotEqual(PermissionStatusText.accessibility(trusted: true),
                          PermissionStatusText.accessibility(trusted: false))
        XCTAssertTrue(PermissionStatusText.accessibility(trusted: false).contains("快捷键无效"),
                      "未授权时必须点明后果，用户才知道该去授权而不是换触发键")
    }

    func testMicrophoneStatusTextCoversAllCases() {
        let statuses: [AVAuthorizationStatus] = [.authorized, .denied, .restricted, .notDetermined]
        let texts = Set(statuses.map { PermissionStatusText.microphone(status: $0) })
        XCTAssertEqual(texts.count, statuses.count, "四种状态文案必须两两不同")
        XCTAssertTrue(PermissionStatusText.microphone(status: .denied).contains("无法录音"))
    }

    func testAccessibilityHintSaysNoRestartNeeded() {
        XCTAssertTrue(PermissionStatusText.accessibilityHint.contains("无需重启"))
    }
}
