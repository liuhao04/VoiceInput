import AppKit
import XCTest
@testable import VoiceInput

/// diff 的正确性直接决定用户能不能信任修正结果。
/// 核心不变量：equal+delete 拼回原文，equal+insert 拼出新文。任何一条破了，
/// 面板上显示的东西就在骗人。
final class TextDiffTests: XCTestCase {

    private func oldSide(_ ops: [TextDiff.Op]) -> String {
        ops.compactMap { op -> String? in
            switch op {
            case .equal(let s), .delete(let s): return s
            case .insert: return nil
            }
        }.joined()
    }

    private func newSide(_ ops: [TextDiff.Op]) -> String {
        ops.compactMap { op -> String? in
            switch op {
            case .equal(let s), .insert(let s): return s
            case .delete: return nil
            }
        }.joined()
    }

    private func assertRoundTrip(_ old: String, _ new: String, file: StaticString = #filePath, line: UInt = #line) {
        let ops = TextDiff.diff(old, new)
        XCTAssertEqual(oldSide(ops), old, "equal+delete 必须拼回原文", file: file, line: line)
        XCTAssertEqual(newSide(ops), new, "equal+insert 必须拼出新文", file: file, line: line)
    }

    // MARK: - 不变量

    func testRoundTripOnRealCorrection() {
        assertRoundTrip(
            "我希望它一旦处于，一旦切换到非 busy 状态的时候，就给我发一个 push over 通知",
            "我希望它一旦切换到非 busy 状态的时候，就给我发一个 Pushover 通知"
        )
    }

    func testRoundTripOnPureInsertion() {
        assertRoundTrip("先跑测试再看延迟", "先跑测试，再看延迟")
    }

    func testRoundTripOnPureDeletion() {
        assertRoundTrip("那个文件在哪，就是说，我想找配置文件", "那个文件在哪，我想找配置文件")
    }

    func testRoundTripWithLineBreaks() {
        assertRoundTrip("第一段第二段", "第一段\n\n第二段")
    }

    func testRoundTripOnCompletelyDifferentText() {
        assertRoundTrip("完全不相干的一段话", "另外一句毫无关系的内容")
    }

    // MARK: - 基本行为

    func testIdenticalTextProducesOnlyEqual() {
        let ops = TextDiff.diff("没有任何改动", "没有任何改动")
        XCTAssertEqual(ops, [.equal("没有任何改动")])
        XCTAssertFalse(TextDiff.hasChanges(ops))
    }

    func testEmptyOldIsAllInsert() {
        XCTAssertEqual(TextDiff.diff("", "新加的"), [.insert("新加的")])
    }

    func testEmptyNewIsAllDelete() {
        XCTAssertEqual(TextDiff.diff("被删光", ""), [.delete("被删光")])
    }

    func testBothEmpty() {
        XCTAssertEqual(TextDiff.diff("", ""), [])
    }

    /// 逐字显示会碎成一堆片段，读不了。相邻同类必须合并。
    func testAdjacentSameKindOpsAreMerged() {
        let ops = TextDiff.diff("abc", "axyc")
        XCTAssertEqual(ops.filter { if case .insert = $0 { return true } else { return false } }.count, 1)
        for op in ops {
            XCTAssertFalse(op.text.isEmpty)
        }
    }

    func testMergeCombinesRuns() {
        let merged = TextDiff.merge([.equal("a"), .equal("b"), .delete("c"), .delete("d"), .insert("e")])
        XCTAssertEqual(merged, [.equal("ab"), .delete("cd"), .insert("e")])
    }

    // MARK: - 改动检测与统计

    func testHasChangesDetectsRealEdits() {
        XCTAssertTrue(TextDiff.hasChanges(TextDiff.diff("cloud code", "Claude Code")))
    }

    func testStatsCountsDeletedAndInserted() {
        let stats = TextDiff.stats(TextDiff.diff("先跑测试再看延迟", "先跑测试，再看延迟"))
        XCTAssertEqual(stats.inserted, 1)
        XCTAssertEqual(stats.deleted, 0)
    }

    func testStatsOnDeletionOnly() {
        let stats = TextDiff.stats(TextDiff.diff("就是说我想找配置", "我想找配置"))
        XCTAssertEqual(stats.deleted, 3)
        XCTAssertEqual(stats.inserted, 0)
    }

    // MARK: - 超长文本退化

    /// 超长文本不做精细 diff，但退化后的结果仍必须满足往返不变量，
    /// 否则面板会显示出和真实文本对不上的内容。
    func testVeryLongTextFallsBackButStaysHonest() {
        let old = String(repeating: "甲", count: 1200)
        let new = String(repeating: "乙", count: 1200)
        let ops = TextDiff.diff(old, new)
        XCTAssertEqual(ops, [.delete(old), .insert(new)])
        XCTAssertEqual(oldSide(ops), old)
        XCTAssertEqual(newSide(ops), new)
    }

    func testSizeJustUnderTheCapStillDoesRealDiff() {
        let old = String(repeating: "甲", count: 100)
        let new = old + "尾巴"
        let ops = TextDiff.diff(old, new)
        XCTAssertEqual(ops, [.equal(old), .insert("尾巴")])
    }

    // MARK: - 富文本渲染

    func testAttributedStringMarksDeletionsWithStrikethrough() {
        let ops: [TextDiff.Op] = [.equal("保留"), .delete("删掉"), .insert("新增")]
        let attr = TextDiff.attributedString(ops, font: .systemFont(ofSize: 14))

        XCTAssertEqual(attr.string, "保留删掉新增")

        let deleteRange = (attr.string as NSString).range(of: "删掉")
        let strike = attr.attribute(.strikethroughStyle, at: deleteRange.location, effectiveRange: nil) as? Int
        XCTAssertEqual(strike, NSUnderlineStyle.single.rawValue)

        let insertRange = (attr.string as NSString).range(of: "新增")
        let underline = attr.attribute(.underlineStyle, at: insertRange.location, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)

        let equalStrike = attr.attribute(.strikethroughStyle, at: 0, effectiveRange: nil)
        XCTAssertNil(equalStrike, "未改动部分不该有任何标记")
    }
}
