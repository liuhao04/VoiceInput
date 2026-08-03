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

    /// 实测 102 字文本的延迟是 2.4 / 4.1 / 4.9s（min/中位/max），
    /// 6s 预算只比实测最大值高 1s，撞上 GLM 抖动就静默降级成粘原文。
    /// 预算放宽在成功路径上零代价（成功时等的是真实延迟），只延长最坏情况。
    func testDefaultTimeoutLeavesHeadroomOverObservedLatency() {
        UserDefaults.standard.removeObject(forKey: "correctionTimeout")
        XCTAssertGreaterThanOrEqual(Config.correctionTimeout, 10.0, "至少要给实测最大值一倍余量")
        XCTAssertLessThanOrEqual(Config.correctionTimeout, 20.0, "再长就变成干等")
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

    private func clearContext() {
        Config.recentContextEntries = []
    }

    @MainActor
    func testRecentContextKeepsOnlyTheLatestEntries() {
        _ = NSApplication.shared
        clearContext()
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
        clearContext()
        let delegate = AppDelegate()

        delegate.rememberContext("   ")
        delegate.rememberContext("\n\t")
        delegate.rememberContext("")

        XCTAssertTrue(delegate.recentContext.isEmpty)
    }

    @MainActor
    func testRecentContextTrimsStoredText() {
        _ = NSApplication.shared
        clearContext()
        let delegate = AppDelegate()

        delegate.rememberContext("  帮我打开 Claude \n")

        XCTAssertEqual(delegate.recentContext, ["帮我打开 Claude"])
    }

    /// 连着说同一句时不该记多份，否则 5 条里全是重复内容，把信号稀释掉
    @MainActor
    func testRecentContextSkipsConsecutiveDuplicates() {
        _ = NSApplication.shared
        clearContext()
        let delegate = AppDelegate()

        delegate.rememberContext("无头 chrome")
        delegate.rememberContext("无头 chrome")
        delegate.rememberContext("无头 chrome")

        XCTAssertEqual(delegate.recentContext, ["无头 chrome"])
    }

    @MainActor
    func testRecentContextAllowsRepeatAfterSomethingElse() {
        _ = NSApplication.shared
        clearContext()
        let delegate = AppDelegate()

        delegate.rememberContext("无头 chrome")
        delegate.rememberContext("天轨浩劫")
        delegate.rememberContext("无头 chrome")

        XCTAssertEqual(delegate.recentContext, ["无头 chrome", "天轨浩劫", "无头 chrome"])
    }

    /// 上下文要跨 app 重启存活，否则每次重启后的前几句都是没有上下文的裸修正
    @MainActor
    func testRecentContextSurvivesAcrossInstances() {
        _ = NSApplication.shared
        clearContext()

        let first = AppDelegate()
        first.rememberContext("我在调无头 chrome 的截图")

        let second = AppDelegate()
        XCTAssertEqual(second.recentContext, ["我在调无头 chrome 的截图"])
    }

    // MARK: - 上下文时效

    func testFreshContextDropsStaleEntries() {
        let now = Date()
        let entries = [
            ContextEntry(time: now.addingTimeInterval(-TextCorrector.contextMaxAge - 60), text: "很久以前说的"),
            ContextEntry(time: now.addingTimeInterval(-60), text: "刚刚说的"),
        ]
        let fresh = TextCorrector.freshContext(entries, now: now)
        XCTAssertEqual(fresh.map { $0.text }, ["刚刚说的"])
    }

    func testFreshContextKeepsEntriesInsideTheWindow() {
        let now = Date()
        let entries = [
            ContextEntry(time: now.addingTimeInterval(-TextCorrector.contextMaxAge + 60), text: "窗口内"),
        ]
        XCTAssertEqual(TextCorrector.freshContext(entries, now: now).count, 1)
    }

    /// 实测日志里连续两次修正都是"上下文 0 条"——真实使用是零散的，
    /// 2 小时窗口几乎总是空的，等于功能没生效。要覆盖一个完整工作日。
    func testContextMaxAgeCoversAFullWorkingDay() {
        XCTAssertGreaterThanOrEqual(TextCorrector.contextMaxAge, 8 * 60 * 60)
        XCTAssertLessThanOrEqual(TextCorrector.contextMaxAge, 24 * 60 * 60, "再长会把昨天的话题带进来")
    }

    // MARK: - 历史三列

    /// 识别结果 / 修正结果 / 编辑后 三列各自独立，才能事后评估模型改了什么。
    /// 与 ASR 原文相同的不重复记，保持"这一列真的产生了变化"的语义。
    func testHistoryEntryCarriesAllThreeTexts() {
        let e = HistoryEntry(text: "原始识别", app: "Berth", corrected: "修正结果", edited: "手改结果")
        XCTAssertEqual(e.text, "原始识别")
        XCTAssertEqual(e.corrected, "修正结果")
        XCTAssertEqual(e.edited, "手改结果")
    }

    func testHistoryEntryRoundTripsThroughJSON() throws {
        let e = HistoryEntry(text: "原始识别", app: "Berth", corrected: "修正结果", edited: nil)
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(HistoryEntry.self, from: data)
        XCTAssertEqual(back.text, "原始识别")
        XCTAssertEqual(back.corrected, "修正结果")
        XCTAssertNil(back.edited)
    }

    /// 老历史文件没有 corrected 字段，必须还能读
    func testHistoryEntryDecodesLegacyEntryWithoutCorrected() throws {
        let json = #"{"time":"2026-08-01T12:00:00+0800","app":"Berth","text":"旧记录","edited":"改过"}"#
        let back = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(back.text, "旧记录")
        XCTAssertNil(back.corrected)
        XCTAssertEqual(back.edited, "改过")
    }
}
