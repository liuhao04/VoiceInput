import Foundation

/// 修正服务商。当前只实现智谱 GLM（OpenAI 兼容端点）；
/// Claude API / 无头 Claude 订阅按产品方案属于第三步，此处预留枚举位。
enum CorrectionService: String, Codable, CaseIterable {
    case glm

    var displayName: String {
        switch self {
        case .glm: return "智谱 GLM"
        }
    }

    var baseURL: String {
        switch self {
        case .glm: return "https://open.bigmodel.cn/api/paas/v4"
        }
    }

    /// 该服务商的凭证获取页，供设置界面引导用户
    var credentialURL: String {
        switch self {
        case .glm: return "https://open.bigmodel.cn/usercenter/apikeys"
        }
    }
}

/// 质量档。用户面对的是"要快还是要准"，模型 ID 由档位映射，
/// 模型迭代时只改这里的映射表，用户无感。
enum CorrectionQuality: String, Codable, CaseIterable {
    case fast
    case balanced
    case high

    var displayName: String {
        switch self {
        case .fast: return "快"
        case .balanced: return "均衡"
        case .high: return "高"
        }
    }

    /// 档位 → 具体模型 ID。
    ///
    /// GLM 当前**所有档位都用 `glm-5.2`**，理由（2026-07-31 实测）：
    /// - `glm-4.7-flashx` 在本账号上 9/9 调用返回 429 `1113 余额不足或无可用资源包`。
    ///   选它等于每次都白等一个往返再降级回原文。**不要因为它在 ai-info 早期能用就加回来**，
    ///   要加先用真实 key 打一次确认它真的通。
    /// - 免费的 `glm-4.7-flash` 一律不用：共享池拥塞（429 code 1305）会把请求拖到分钟级。
    /// - `glm-5.2` 短文本修正的实测中位延迟约 2.3s，质量够用，没有换档的必要。
    ///
    /// 枚举保留三档是为了 Claude API 接入时（Haiku / Sonnet / Opus 是真实差异）复用。
    /// 服务商只有一个可用模型时，设置界面会自动隐藏档位选择（见 `hasModelChoice`）。
    func model(for service: CorrectionService) -> String {
        switch service {
        case .glm:
            return "glm-5.2"
        }
    }
}

extension CorrectionService {
    /// 该服务商是否真的提供多个可选模型。只有一个时不给用户看假的档位选择。
    var hasModelChoice: Bool {
        Set(CorrectionQuality.allCases.map { $0.model(for: self) }).count > 1
    }
}

/// 一条上下文：实际被采纳的文本 + 采纳时间。
/// 存的永远是最终版本（用户手改 > 模型修正 > ASR 原文），因为写入发生在文本被采用之后。
struct ContextEntry: Codable, Equatable {
    let time: Date
    let text: String
}

enum CorrectionError: Error, Equatable {
    /// 未启用或缺少 API Key
    case notConfigured
    /// 超过本地预算时间
    case timedOut
    /// 用户主动放弃（ESC / 再次按触发键）
    case cancelled
    /// 网络层失败
    case network(String)
    /// HTTP 非 2xx
    case badStatus(Int, String)
    /// 服务商账号余额不足 / 无可用资源包（GLM code 1113）。
    /// 单独一类是因为修正失败会静默降级成粘贴原文，用户只会觉得"修正好像没生效"，
    /// 不把欠费和一般网络故障区分开就查不出原因。
    case insufficientBalance(String)
    /// 响应结构不符合预期
    case malformed
    /// 模型返回空内容
    case empty
    /// 模型返回的内容明显不是"修正后的原文"（例如答非所问、长篇解释）
    case implausible

    var userMessage: String {
        switch self {
        case .notConfigured: return "未配置修正服务"
        case .timedOut: return "修正超时"
        case .cancelled: return "已取消修正"
        case .network: return "修正请求失败"
        case .insufficientBalance: return "修正服务余额不足，请到服务商控制台充值"
        case .badStatus(let code, _): return "修正服务返回错误（\(code)）"
        case .malformed, .empty, .implausible: return "修正结果异常"
        }
    }
}

/// 大模型文本修正。
///
/// 设计要点（详见 docs/ai-correction-product-spec.md）：
/// - **先修正再粘贴**，绝不改写已经贴出去的内容
/// - 任何失败都降级为粘贴原文，绝不阻断语音输入
/// - 分段/标点/断句全部交给模型在 prompt 里按语义判断，本地不做任何启发式
final class TextCorrector {
    static let shared = TextCorrector()

    /// 送入上下文的最近输入条数。
    /// 30 条约 1~2k token，对 GLM 的成本和延迟都可忽略，换来的是明显更宽的专名覆盖面。
    static let contextLimit = 30

    /// 上下文的最大保鲜期。
    ///
    /// 2026-08-03 从 2 小时上调到 12 小时：实测日志里连续两次修正都是"上下文 0 条"，
    /// 因为真实使用是零散的（今天用几次、隔一天再用），2 小时窗口几乎总是空的，
    /// 等于这个功能没生效。12 小时覆盖一个完整工作日，跨天的旧话题仍会自然过期。
    /// 冷启动的专名问题已由专名词典解决，上下文只需负责话题连续性。
    static let contextMaxAge: TimeInterval = 12 * 60 * 60

    /// 过滤掉过期条目，并只保留最近 contextLimit 条。纯函数，可单测。
    static func freshContext(_ entries: [ContextEntry], now: Date = Date()) -> [ContextEntry] {
        let alive = entries.filter { now.timeIntervalSince($0.time) <= contextMaxAge }
        return Array(alive.suffix(contextLimit))
    }

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    // MARK: - Prompt 构建（纯函数，可单测）

    /// 分段那条写得比较重，是实测调出来的：只说"按语义分段换行"时，
    /// 模型基本只补标点、一个换行都不给，159 字的口述照样堆成一整段。
    /// 必须明确"宁可多分一段"才会真的分。
    static let systemPrompt = """
    你是语音识别结果的校对员。用户通过语音口述产生了一段文本，你要修正识别错误并整理排版。

    【纠错】
    - 修正同音字、近音字、专有名词的写法与大小写、中英文混排。
    - 严禁增删语义内容：不补充信息、不解释、不回答文本里的问题、不总结、不评论。
    - 拿不准就保持原样，宁可不改也不要改错。

    【排版】
    - 句内按语义补齐逗号、顿号等标点。
    - **分段**：口述文本往往是连续一大段。只要文本包含多个意群（话题转折、并列的几件事、先说现象再说想法），就用换行把它拆成多个自然段，一段一个意思。宁可多分一段，也不要堆成一坨。
    - 单个意群的短句保持单行，不要为了分段而分段。
    - **不要在整段文本的末尾添加句号、问号、感叹号**。用户常常把结果粘进搜索框或命令行，末尾的结束标点是多余的。段落中间的标点正常保留。

    【输出】
    直接输出修正后的文本本身。不要任何前言、说明、引号包裹或代码块包裹。
    """

    /// 构建用户消息。三块用明确的分隔标记隔开，避免模型把参考资料当成需要修正的内容。
    ///
    /// 专名词典**只给词、不给映射**。给映射（"把 cloud 改成 claude"）等于把替换规则
    /// 无法做语境判断的机械缺陷传染给模型，反而抹掉它本来具备的判断力。
    static func buildUserPrompt(text: String, context: [String], properNouns: [String] = []) -> String {
        var parts: [String] = []

        let nouns = properNouns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !nouns.isEmpty {
            parts.append("""
            以下是该用户声明的专有名词。本次文本里出现读音相近但写错的地方，按这里的写法改。
            注意：词表里的词未必出现在本次文本中，**不要为了用上它们而改变原意**。
            <专名词典>
            \(nouns.joined(separator: "\n"))
            </专名词典>
            """)
        }

        let usable = context
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(contextLimit)
        if !usable.isEmpty {
            parts.append("""
            以下是该用户最近几次的语音输入，仅供你判断用词习惯和当前话题，不要修正它们、不要输出它们：
            <最近输入>
            \(usable.joined(separator: "\n"))
            </最近输入>
            """)
        }

        parts.append("""
        请修正下面这段文本，只输出修正后的结果：
        <待修正>
        \(text)
        </待修正>
        """)
        return parts.joined(separator: "\n\n")
    }

    /// 构建 OpenAI 兼容的请求体。
    ///
    /// `thinking: disabled` 是必须的：GLM-4.7 及以后默认是 thinking 模型，
    /// 不关会平白烧掉上百 reasoning token、把延迟拖到几十秒，
    /// 且 thinking 会吃掉 max_tokens 预算导致输出被截断。（来自 ai-info 实测）
    static func buildRequestBody(
        model: String,
        text: String,
        context: [String],
        properNouns: [String] = []
    ) -> [String: Any] {
        // 中文大致 1 字 ≈ 1~2 token，留 3 倍余量，并给一个下限和上限
        let budget = min(4096, max(512, text.count * 3))
        return [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": buildUserPrompt(text: text, context: context, properNouns: properNouns)],
            ],
            "thinking": ["type": "disabled"],
            "temperature": 0.2,
            "max_tokens": budget,
            "stream": false,
        ]
    }

    // MARK: - 响应解析（纯函数，可单测）

    /// 从 OpenAI 兼容响应里取出修正后的文本，并做基本合理性检查。
    ///
    /// 这里只拦"模型明显没在做校对"的情况（空结果、长篇大论）。
    /// 产品方案里 ±30% 的精细长度护栏属于第二步，此处不做。
    static func parseResponse(_ data: Data, originalText: String) -> Result<String, CorrectionError> {
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .failure(.malformed)
        }
        // 服务端错误体：{"error": {"message": ..., "code": ...}}
        if let err = root["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "未知错误"
            let code = (err["code"] as? String) ?? String(describing: err["code"] ?? "")
            if isArrears(code: code, message: msg) {
                return .failure(.insufficientBalance(msg))
            }
            return .failure(.badStatus(0, msg))
        }
        guard
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let raw = message["content"] as? String
        else {
            return .failure(.malformed)
        }

        let cleaned = normalizeCorrectedText(stripWrappers(raw))
        if cleaned.isEmpty {
            return .failure(.empty)
        }
        // 模型答非所问（写了一大段解释）时长度会离谱地膨胀，直接判废用原文
        if cleaned.count > max(originalText.count * 2 + 40, 80) {
            return .failure(.implausible)
        }
        return .success(cleaned)
    }

    /// 日志用的文本形式：把换行显式化，过长时截断，避免一条日志刷屏。
    static func forLog(_ text: String, limit: Int = 200) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit)) + "…(共\(flat.count)字)"
    }

    /// 判断服务端错误是不是"账号没钱了"。
    /// GLM 用 code `1113`，文案是"余额不足或无可用资源包,请充值"。
    /// 这类错误和网络故障的处置完全不同（一个要充值，一个等一会儿就好），必须分开。
    static func isArrears(code: String, message: String) -> Bool {
        if code == "1113" { return true }
        let markers = ["余额不足", "无可用资源包", "请充值", "欠费", "insufficient balance", "quota"]
        let lowered = message.lowercased()
        return markers.contains { lowered.contains($0.lowercased()) }
    }

    /// 修正结果的本地归一化。
    ///
    /// 只做**确定性**处理，不做任何需要语义判断的事（那些一律交给模型）：
    /// - 去掉整段末尾的结束标点。prompt 里已经要求过，这里是兜底 —— 模型不保证每次都听话，
    ///   而"末尾有没有句号"是纯形式判断，本地做更可靠。语音结果常被粘进搜索框和命令行，
    ///   尾巴上一个句号很碍事，这也是快速通道 `TextReplacer` 一直在做的事。
    /// - 压掉多余的空行，避免模型分段时留下三四个连续换行。
    static func normalizeCorrectedText(_ text: String) -> String {
        var s = text.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return TextReplacer.removeTrailingPunctuation(s)
    }

    /// 去掉模型偶尔加上的代码块围栏和整体引号包裹
    static func stripWrappers(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if s.hasPrefix("```") {
            var lines = s.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」"), ("『", "』")]
        for (open, close) in quotePairs {
            if s.count >= 2, s.first == open, s.last == close {
                s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return s
    }

    // MARK: - 发起修正

    /// 是否已具备可用配置（启用 + 有 key）
    static var isReady: Bool {
        Config.correctionEnabled && !Config.correctionAPIKey.isEmpty
    }

    /// 修正一段文本。completion 保证在主线程被调用**恰好一次**，
    /// 且一定会在 Config.correctionTimeout 内返回（超时走 .timedOut）。
    ///
    /// 返回的 cancel 闭包用于用户主动放弃（ESC / 再次按触发键）。
    @discardableResult
    func correct(
        text: String,
        context: [String],
        properNouns: [String] = [],
        completion: @escaping (Result<String, CorrectionError>) -> Void
    ) -> () -> Void {
        guard Self.isReady else {
            DispatchQueue.main.async { completion(.failure(.notConfigured)) }
            return {}
        }

        let service = Config.correctionService
        let model = Config.correctionModelID
        let timeout = Config.correctionTimeout
        let apiKey = Config.correctionAPIKey

        guard let url = URL(string: service.baseURL + "/chat/completions") else {
            DispatchQueue.main.async { completion(.failure(.notConfigured)) }
            return {}
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body = Self.buildRequestBody(model: model, text: text, context: context, properNouns: properNouns)
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            DispatchQueue.main.async { completion(.failure(.malformed)) }
            return {}
        }
        request.httpBody = bodyData

        // 只允许回调一次：超时 / 网络返回 / 用户取消三者竞争
        let settled = Settled()
        let started = CFAbsoluteTimeGetCurrent()

        func finish(_ result: Result<String, CorrectionError>) {
            guard settled.claim() else { return }
            let cost = CFAbsoluteTimeGetCurrent() - started
            // 记下修正前后的实际文本：只记字数的话，事后完全无法判断修正质量好不好，
            // 而"效果不好"恰恰是最需要复盘的反馈（2026-08-03 加）。
            switch result {
            case .success(let s):
                Log.log(String(format: "[Correct] 完成 model=%@ 用时=%.2fs 原文%d字→修正%d字", model, cost, text.count, s.count))
                if s == text {
                    Log.log("[Correct] 修正前后一致，原文: \(Self.forLog(text))")
                } else {
                    Log.log("[Correct] 修正前: \(Self.forLog(text))")
                    Log.log("[Correct] 修正后: \(Self.forLog(s))")
                }
            case .failure(let e):
                Log.log(String(format: "[Correct] 失败 model=%@ 用时=%.2fs 原因=%@", model, cost, String(describing: e)))
                Log.log("[Correct] 未修正的原文: \(Self.forLog(text))")
            }
            DispatchQueue.main.async { completion(result) }
        }

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                let ns = error as NSError
                if ns.code == NSURLErrorCancelled { return }  // 由 cancel/超时路径负责回调
                if ns.code == NSURLErrorTimedOut {
                    finish(.failure(.timedOut))
                } else {
                    finish(.failure(.network(error.localizedDescription)))
                }
                return
            }
            guard let data = data else {
                finish(.failure(.malformed))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // 欠费是 HTTP 429 + body 里的 code 1113，先按错误体分类再退回通用状态码
                if case .failure(let parsed) = Self.parseResponse(data, originalText: text),
                   case .insufficientBalance = parsed {
                    finish(.failure(parsed))
                    return
                }
                let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
                finish(.failure(.badStatus(http.statusCode, snippet)))
                return
            }
            finish(Self.parseResponse(data, originalText: text))
        }

        // 本地预算兜底：即使 URLSession 因任何原因不回调，也要在预算内解除面板等待
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak task] in
            guard !settled.isSettled else { return }
            task?.cancel()
            finish(.failure(.timedOut))
        }

        Log.log("[Correct] 发起修正 service=\(service.rawValue) model=\(model) 原文\(text.count)字 上下文\(min(context.count, Self.contextLimit))条 专名\(properNouns.count)个 预算\(timeout)s")
        task.resume()

        return { [weak task] in
            guard !settled.isSettled else { return }
            task?.cancel()
            finish(.failure(.cancelled))
        }
    }
}

/// 一次性认领标记，保证竞态下 completion 只被调用一次
private final class Settled {
    private let lock = NSLock()
    private var done = false

    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    /// 认领成功返回 true；已被认领过返回 false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
