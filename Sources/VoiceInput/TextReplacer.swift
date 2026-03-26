import Foundation

struct ReplaceRule: Codable, Equatable {
    var from: String
    var to: String
}

final class TextReplacer {
    static let shared = TextReplacer()

    private(set) var rules: [ReplaceRule] = []

    private init() {
        reload()
    }

    /// 从 Config.replaceRulesFilePath 重新加载规则
    func reload() {
        let path = Config.replaceRulesFilePath
        guard !path.isEmpty else {
            rules = []
            return
        }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            rules = []
            return
        }
        do {
            rules = try JSONDecoder().decode([ReplaceRule].self, from: data)
            Log.log("[TextReplacer] 已加载 \(rules.count) 条替换规则")
        } catch {
            Log.log("[TextReplacer] 解析规则文件失败: \(error.localizedDescription)")
            rules = []
        }
    }

    /// 保存当前规则到文件
    func save() {
        let path = Config.replaceRulesFilePath
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(rules)
            try data.write(to: url, options: .atomic)
            Log.log("[TextReplacer] 已保存 \(rules.count) 条替换规则")
        } catch {
            Log.log("[TextReplacer] 保存规则文件失败: \(error.localizedDescription)")
        }
    }

    /// 对文本逐条应用替换规则
    func apply(_ text: String) -> String {
        guard !rules.isEmpty else { return text }
        var result = text
        for rule in rules {
            result = result.replacingOccurrences(of: rule.from, with: rule.to)
        }
        return result
    }

    /// 添加一条规则并保存
    func addRule(from: String, to: String) {
        rules.append(ReplaceRule(from: from, to: to))
        save()
    }

    /// 删除指定索引的规则并保存
    func removeRule(at index: Int) {
        guard index >= 0 && index < rules.count else { return }
        rules.remove(at: index)
        save()
    }

    /// 更新指定索引的规则并保存
    func updateRule(at index: Int, from: String, to: String) {
        guard index >= 0 && index < rules.count else { return }
        rules[index] = ReplaceRule(from: from, to: to)
        save()
    }

    /// 交换两个相邻规则的位置并保存
    func swapRules(_ indexA: Int, _ indexB: Int) {
        guard indexA >= 0 && indexA < rules.count else { return }
        guard indexB >= 0 && indexB < rules.count else { return }
        rules.swapAt(indexA, indexB)
        save()
    }

    /// 更新规则列表并保存
    func setRules(_ newRules: [ReplaceRule]) {
        rules = newRules
        save()
    }
}
