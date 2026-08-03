import AppKit
import Foundation

/// 字符级 diff，用于把大模型的修正结果以「Word 批阅模式」呈现：
/// 删掉的画删除线、新增的加下划线、没动的保持原样。
///
/// 为什么必须这样而不是直接替换全文：模型有可能悄悄删掉不该删的内容，
/// 文本一长就完全看不出来。用户要能一眼确认「哪些被保留了、哪些被改了」再决定采不采用。
///
/// 按**字符**而不是按词切分：中文没有空格分词，按词切要先分词，
/// 分词本身会引入错误，而字符级 diff 对中文天然合适。相邻的同类片段会被合并，
/// 所以显示出来不会碎成一个个字。
enum TextDiff {

    enum Op: Equatable {
        case equal(String)
        case insert(String)
        case delete(String)

        var text: String {
            switch self {
            case .equal(let s), .insert(let s), .delete(let s): return s
            }
        }
    }

    /// LCS 动态规划的规模上限。超过就不做精细 diff，退化成"整段替换"的展示。
    /// 800×800 = 64 万格，远超日常口述长度，真触顶时精细 diff 也没有可读性了。
    static let maxDiffProduct = 640_000

    /// 计算 old → new 的差异。
    /// 结果里 `.equal` 与 `.delete` 拼起来是原文，`.equal` 与 `.insert` 拼起来是新文。
    static func diff(_ old: String, _ new: String) -> [Op] {
        if old == new { return old.isEmpty ? [] : [.equal(old)] }
        if old.isEmpty { return [.insert(new)] }
        if new.isEmpty { return [.delete(old)] }

        let a = Array(old)
        let b = Array(new)

        // 超长文本退化：给出"删掉整段、插入整段"，仍然是诚实的表示，只是不精细
        guard a.count * b.count <= maxDiffProduct else {
            return [.delete(old), .insert(new)]
        }

        // dp[i][j] = a[i...] 与 b[j...] 的最长公共子序列长度
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        if a.count > 0 && b.count > 0 {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j]
                        ? dp[i + 1][j + 1] + 1
                        : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var raw: [Op] = []
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                raw.append(.equal(String(a[i])))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                raw.append(.delete(String(a[i])))
                i += 1
            } else {
                raw.append(.insert(String(b[j])))
                j += 1
            }
        }
        while i < a.count { raw.append(.delete(String(a[i]))); i += 1 }
        while j < b.count { raw.append(.insert(String(b[j]))); j += 1 }

        return merge(raw)
    }

    /// 合并相邻的同类片段，避免逐字显示成碎片
    static func merge(_ ops: [Op]) -> [Op] {
        var out: [Op] = []
        for op in ops {
            guard let last = out.last else { out.append(op); continue }
            switch (last, op) {
            case (.equal(let a), .equal(let b)):   out[out.count - 1] = .equal(a + b)
            case (.insert(let a), .insert(let b)): out[out.count - 1] = .insert(a + b)
            case (.delete(let a), .delete(let b)): out[out.count - 1] = .delete(a + b)
            default: out.append(op)
            }
        }
        return out
    }

    /// 有没有实质改动。全是 `.equal` 说明模型什么都没动。
    static func hasChanges(_ ops: [Op]) -> Bool {
        ops.contains { if case .equal = $0 { return false } else { return true } }
    }

    /// 改动统计，用于在面板上给一句「删了 N 字、加了 M 字」的概览。
    static func stats(_ ops: [Op]) -> (deleted: Int, inserted: Int) {
        var deleted = 0
        var inserted = 0
        for op in ops {
            switch op {
            case .delete(let s): deleted += s.count
            case .insert(let s): inserted += s.count
            case .equal: break
            }
        }
        return (deleted, inserted)
    }

    /// 渲染成批阅样式的富文本。
    /// 删除用删除线 + 红色，新增用下划线 + 蓝色，这是 Word 修订模式的通行约定；
    /// 未改动部分保持正常颜色，避免整段都被染色而看不出重点。
    static func attributedString(_ ops: [Op], font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for op in ops {
            switch op {
            case .equal(let s):
                result.append(NSAttributedString(string: s, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]))
            case .delete(let s):
                result.append(NSAttributedString(string: s, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.systemRed,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.systemRed,
                ]))
            case .insert(let s):
                result.append(NSAttributedString(string: s, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSColor.systemBlue,
                ]))
            }
        }
        return result
    }
}
