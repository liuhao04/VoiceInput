import AppKit
import XCTest
@testable import VoiceInput

/// AI 修正接入应用流程的部分：配置默认值、就绪判定、上下文环形缓冲。
final class CorrectionFlowTests: XCTestCase {

    /// 每个用例跑完都把配置还原，避免污染开发机上的真实设置
    private var saved: (enabled: Bool, service: CorrectionService, quality: CorrectionQuality, timeout: Double)!

    override func setUp() {
        super.setUp()
        saved = (Config.correctionEnabled, Config.correctionService, Config.correctionQuality, Config.correctionTimeout)
    }

    override func tearDown() {
        Config.correctionEnabled = saved.enabled
        Config.correctionService = saved.service
        Config.correctionQuality = saved.quality
        Config.correctionTimeout = saved.timeout
        super.tearDown()
    }

    // MARK: - 配置

    /// 默认必须是关的：用户没填 API Key 之前启用没有意义，
    /// 而且分发版用户不该在不知情的情况下把语音内容发到第三方。
    func testCorrectionIsDisabledByDefault() {
        UserDefaults.standard.removeObject(forKey: "correctionEnabled")
        XCTAssertFalse(Config.correctionEnabled)
    }

    func testDefaultServiceAndQuality() {
        UserDefaults.standard.removeObject(forKey: "correctionService")
        UserDefaults.standard.removeObject(forKey: "correctionQuality")
        XCTAssertEqual(Config.correctionService, .glm)
        XCTAssertEqual(Config.correctionQuality, .balanced)
        XCTAssertEqual(Config.correctionModelID, "glm-5.2")
    }

    func testDefaultTimeoutIsSixSeconds() {
        UserDefaults.standard.removeObject(forKey: "correctionTimeout")
        XCTAssertEqual(Config.correctionTimeout, 6.0, accuracy: 0.001)
    }

    /// 超时是硬上限，用来保证语音输入不会卡死等模型。
    /// 存进去的极端值必须被夹到合理区间，不能出现 0 秒或 5 分钟。
    func testTimeoutIsClampedToSaneRange() {
        Config.correctionTimeout = 0
        XCTAssertGreaterThanOrEqual(Config.correctionTimeout, 1.0)

        Config.correctionTimeout = 9999
        XCTAssertLessThanOrEqual(Config.correctionTimeout, 30.0)

        Config.correctionTimeout = 8
        XCTAssertEqual(Config.correctionTimeout, 8.0, accuracy: 0.001)
    }

    /// 档位本身要能持久化（Claude API 接入后档位才有真实差异）；
    /// 但 GLM 当前只有一个可用模型，所以换档不改 model ID。
    func testQualityRoundTripsThroughUserDefaults() {
        Config.correctionQuality = .fast
        XCTAssertEqual(Config.correctionQuality, .fast)
        XCTAssertEqual(Config.correctionModelID, "glm-5.2")
    }

    // MARK: - 就绪判定

    /// 只有"启用了"没填 key 时不能算就绪，否则每次说完话都要白等一次超时
    func testNotReadyWhenEnabledButNoAPIKey() {
        Config.correctionEnabled = true
        guard Config.correctionAPIKey.isEmpty else {
            // 开发机上可能真的存了 key（或注入了 GLM_API_KEY 环境变量），跳过
            return
        }
        XCTAssertFalse(TextCorrector.isReady)
    }

    func testNotReadyWhenDisabled() {
        Config.correctionEnabled = false
        XCTAssertFalse(TextCorrector.isReady)
    }

    // MARK: - 上下文环形缓冲

    @MainActor
    func testRecentContextKeepsOnlyTheLatestEntries() {
        _ = NSApplication.shared
        let delegate = AppDelegate()

        for i in 1...(TextCorrector.contextLimit + 3) {
            delegate.rememberContext("第\(i)条")
        }

        XCTAssertEqual(delegate.recentContext.count, TextCorrector.contextLimit)
        XCTAssertEqual(delegate.recentContext.last, "第\(TextCorrector.contextLimit + 3)条")
        XCTAssertFalse(delegate.recentContext.contains("第1条"))
    }

    @MainActor
    func testRecentContextIgnoresBlankText() {
        _ = NSApplication.shared
        let delegate = AppDelegate()

        delegate.rememberContext("   ")
        delegate.rememberContext("\n\t")
        delegate.rememberContext("")

        XCTAssertTrue(delegate.recentContext.isEmpty)
    }

    @MainActor
    func testRecentContextTrimsStoredText() {
        _ = NSApplication.shared
        let delegate = AppDelegate()

        delegate.rememberContext("  帮我打开 Claude \n")

        XCTAssertEqual(delegate.recentContext, ["帮我打开 Claude"])
    }

    // MARK: - 录音档位

    @MainActor
    func testRecordingModeDefaultsToRefined() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        XCTAssertEqual(delegate.currentRecordingMode, .refined)
    }

    /// 降档窗口要足够短，不能长到把用户"说完一句就停"的正常操作误判成降档
    @MainActor
    func testFastModeWindowIsShortEnoughToNotSwallowRealStops() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let saved = Config.triggerActivation
        defer { Config.triggerActivation = saved }

        // 下限：要容得下一次从容的双击（触发本身还带 0.2s 确认延迟）
        // 上限：再长就会把"说了一个字就想停"的正常操作误判成降档
        Config.triggerActivation = .singleTap
        XCTAssertGreaterThanOrEqual(delegate.fastModeWindow, 0.6)
        XCTAssertLessThanOrEqual(delegate.fastModeWindow, 0.9)
    }

    /// 双击触发时，用户要再完成一整个双击才算降档，需要更长的窗口。
    /// 早期版本把降档限定在 singleTap，双击触发的用户完全用不上快速档。
    @MainActor
    func testFastModeWindowIsLongerWhenTriggerItselfIsADoubleTap() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let saved = Config.triggerActivation
        defer { Config.triggerActivation = saved }

        Config.triggerActivation = .singleTap
        let single = delegate.fastModeWindow
        Config.triggerActivation = .doubleTap
        let double = delegate.fastModeWindow

        XCTAssertGreaterThan(double, single, "双击触发时降档窗口必须更长")
        XCTAssertLessThanOrEqual(double, 1.6, "再长就会把正常的短句停止误判成降档")
    }
}

extension AppDelegate.RecordingMode: Equatable {}
