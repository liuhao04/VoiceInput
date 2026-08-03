import XCTest
@testable import VoiceInput

/// TextCorrector 的纯函数部分：prompt 构建、响应解析、模型映射。
/// 不发网络请求。
final class TextCorrectorTests: XCTestCase {

    // MARK: - 质量档 → 模型映射

    func testQualityMapsToConcreteModelIDs() {
        for quality in CorrectionQuality.allCases {
            XCTAssertEqual(quality.model(for: .glm), "glm-5.2")
        }
    }

    /// 免费 flash 档在 ai-info 实测会遭遇共享池拥塞（429 code 1305），把批次拖到分钟级。
    /// `glm-4.7-flashx` 则在本账号 2026-07-31 实测 9/9 返回 429 code 1113 余额不足。
    /// 两者都不得被任何档位选中 —— 选中等于每次白等一个往返再降级回原文。
    func testNoQualityMapsToUnusableGLMModels() {
        let banned = ["glm-4.7-flash", "glm-4.7-flashx", "glm-4-flash", "glm-4.6v-flash"]
        for quality in CorrectionQuality.allCases {
            let model = quality.model(for: .glm)
            XCTAssertFalse(banned.contains(model), "\(quality) 映射到了不可用模型 \(model)")
            XCTAssertFalse(model.contains("flash"), "\(quality) 映射到了 flash 系模型 \(model)")
        }
    }

    /// 服务商只有一个可用模型时不该给用户看三个档位 —— 那是假选择。
    func testGLMReportsNoModelChoiceWhileItHasASingleModel() {
        XCTAssertFalse(CorrectionService.glm.hasModelChoice)
    }

    // MARK: - 欠费识别

    /// 修正失败会静默降级成粘贴原文，用户只会觉得"修正好像没生效"。
    /// 欠费必须和一般故障分开，否则查不出原因（一个要充值，一个等等就好）。
    func testArrearsDetectionByGLMErrorCode() {
        XCTAssertTrue(TextCorrector.isArrears(code: "1113", message: "余额不足或无可用资源包,请充值。"))
    }

    func testArrearsDetectionByMessageWhenCodeMissing() {
        XCTAssertTrue(TextCorrector.isArrears(code: "", message: "余额不足或无可用资源包,请充值。"))
        XCTAssertTrue(TextCorrector.isArrears(code: "", message: "Insufficient balance"))
    }

    func testOrdinaryErrorsAreNotTreatedAsArrears() {
        XCTAssertFalse(TextCorrector.isArrears(code: "1305", message: "该模型当前访问量过大"))
        XCTAssertFalse(TextCorrector.isArrears(code: "1211", message: "模型不存在，请检查模型代码。"))
    }

    func testParseClassifiesArrearsErrorBody() {
        let data = try! JSONSerialization.data(
            withJSONObject: ["error": ["message": "余额不足或无可用资源包,请充值。", "code": "1113"]]
        )
        let result = TextCorrector.parseResponse(data, originalText: "x")
        guard case .failure(.insufficientBalance) = result else {
            return XCTFail("应识别为余额不足，实际 \(result)")
        }
    }

    func testArrearsErrorHasActionableUserMessage() {
        let msg = CorrectionError.insufficientBalance("余额不足").userMessage
        XCTAssertTrue(msg.contains("余额不足"))
        XCTAssertTrue(msg.contains("充值"))
    }

    // MARK: - Prompt 构建

    func testUserPromptContainsTextToCorrect() {
        let prompt = TextCorrector.buildUserPrompt(text: "帮我打开 cloud", context: [])
        XCTAssertTrue(prompt.contains("帮我打开 cloud"))
        XCTAssertTrue(prompt.contains("<待修正>"))
    }

    func testUserPromptOmitsContextBlockWhenNoContext() {
        let prompt = TextCorrector.buildUserPrompt(text: "测试", context: [])
        XCTAssertFalse(prompt.contains("<最近输入>"))
    }

    func testUserPromptIncludesContextAndMarksItNotToBeCorrected() {
        let prompt = TextCorrector.buildUserPrompt(
            text: "再帮我跑一下 cloud",
            context: ["我在用 Claude Code 写这个项目", "Claude 的响应有点慢"]
        )
        XCTAssertTrue(prompt.contains("<最近输入>"))
        XCTAssertTrue(prompt.contains("我在用 Claude Code 写这个项目"))
        XCTAssertTrue(prompt.contains("Claude 的响应有点慢"))
        XCTAssertTrue(prompt.contains("不要修正它们"))
        // 待修正文本必须出现在上下文之后，避免模型混淆边界
        let ctxRange = prompt.range(of: "<最近输入>")!
        let targetRange = prompt.range(of: "<待修正>")!
        XCTAssertTrue(ctxRange.lowerBound < targetRange.lowerBound)
    }

    func testUserPromptDropsBlankContextEntries() {
        let prompt = TextCorrector.buildUserPrompt(text: "测试", context: ["  ", "\n", ""])
        XCTAssertFalse(prompt.contains("<最近输入>"))
    }

    func testUserPromptKeepsOnlyTheMostRecentContextEntries() {
        let total = TextCorrector.contextLimit + 5
        let context = (1...total).map { "第\($0)条内容" }
        let prompt = TextCorrector.buildUserPrompt(text: "测试", context: context)

        XCTAssertTrue(prompt.contains("第\(total)条内容"), "最新一条必须在")
        XCTAssertTrue(prompt.contains("第\(total - TextCorrector.contextLimit + 1)条内容"), "窗口内最旧一条必须在")
        XCTAssertFalse(
            prompt.contains("第\(total - TextCorrector.contextLimit)条内容"),
            "只应保留最近 \(TextCorrector.contextLimit) 条"
        )
        XCTAssertFalse(prompt.contains("第1条内容"))
    }

    // MARK: - 专名词典

    func testUserPromptOmitsDictionaryBlockWhenEmpty() {
        let prompt = TextCorrector.buildUserPrompt(text: "测试", context: [], properNouns: [])
        XCTAssertFalse(prompt.contains("<专名词典>"))
    }

    func testUserPromptIncludesProperNouns() {
        let prompt = TextCorrector.buildUserPrompt(
            text: "田轨号劫又打了两把",
            context: [],
            properNouns: ["天轨浩劫", "无头 chrome"]
        )
        XCTAssertTrue(prompt.contains("<专名词典>"))
        XCTAssertTrue(prompt.contains("天轨浩劫"))
        XCTAssertTrue(prompt.contains("无头 chrome"))
    }

    /// 词典只给词、不给映射。给映射等于把替换规则"无法做语境判断"的机械缺陷
    /// 传染给模型，反而抹掉它本来具备的判断力。
    func testDictionaryBlockTellsModelNotToForceTheWordsIn() {
        let prompt = TextCorrector.buildUserPrompt(text: "测试", context: [], properNouns: ["天轨浩劫"])
        XCTAssertTrue(prompt.contains("不要为了用上它们而改变原意"))
        XCTAssertTrue(prompt.contains("未必出现在本次文本中"))
    }

    func testDictionaryComesBeforeContextAndTarget() {
        let prompt = TextCorrector.buildUserPrompt(
            text: "待修文本",
            context: ["最近说的话"],
            properNouns: ["天轨浩劫"]
        )
        let dict = prompt.range(of: "<专名词典>")!
        let ctx = prompt.range(of: "<最近输入>")!
        let target = prompt.range(of: "<待修正>")!
        XCTAssertTrue(dict.lowerBound < ctx.lowerBound)
        XCTAssertTrue(ctx.lowerBound < target.lowerBound)
    }

    func testDictionaryDropsBlankEntries() {
        let prompt = TextCorrector.buildUserPrompt(text: "测试", context: [], properNouns: ["  ", "\n"])
        XCTAssertFalse(prompt.contains("<专名词典>"))
    }

    func testRequestBodyCarriesProperNouns() {
        let body = TextCorrector.buildRequestBody(
            model: "glm-5.2", text: "测试", context: [], properNouns: ["天轨浩劫"]
        )
        let messages = body["messages"] as? [[String: String]]
        XCTAssertTrue(messages?[1]["content"]?.contains("天轨浩劫") == true)
    }

    // MARK: - 上下文条数

    /// 用户 2026-08-02 明确要求提到 30 条：覆盖面比 5 条宽得多，
    /// 成本和延迟对 GLM 都可忽略。
    func testContextLimitIsThirty() {
        XCTAssertEqual(TextCorrector.contextLimit, 30)
    }

    // MARK: - 请求体

    /// GLM-4.7 及以后默认是 thinking 模型。不关 thinking 会烧掉上百 reasoning token、
    /// 把延迟拖到几十秒，并吃掉 max_tokens 预算导致输出截断。（ai-info 实测）
    func testRequestBodyDisablesThinking() {
        let body = TextCorrector.buildRequestBody(model: "glm-5.2", text: "测试", context: [])
        let thinking = body["thinking"] as? [String: Any]
        XCTAssertEqual(thinking?["type"] as? String, "disabled")
    }

    func testRequestBodyCarriesModelAndBothMessages() {
        let body = TextCorrector.buildRequestBody(model: "glm-5.2", text: "测试文本", context: [])
        XCTAssertEqual(body["model"] as? String, "glm-5.2")
        let messages = body["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"], "system")
        XCTAssertEqual(messages?[1]["role"], "user")
        XCTAssertTrue(messages?[1]["content"]?.contains("测试文本") == true)
    }

    func testRequestBodyGrowsTokenBudgetWithInputLength() {
        let short = TextCorrector.buildRequestBody(model: "m", text: "短", context: [])
        let long = TextCorrector.buildRequestBody(
            model: "m",
            text: String(repeating: "很长的一段话", count: 200),
            context: []
        )
        let shortBudget = short["max_tokens"] as? Int ?? 0
        let longBudget = long["max_tokens"] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(shortBudget, 512, "短文本也要有下限预算")
        XCTAssertGreaterThan(longBudget, shortBudget)
        XCTAssertLessThanOrEqual(longBudget, 4096, "预算要有上限")
    }

    func testRequestBodyIsJSONSerializable() {
        let body = TextCorrector.buildRequestBody(model: "glm-5.2", text: "测试", context: ["上下文"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    // MARK: - 响应解析

    private func responseData(content: String) -> Data {
        let json: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": content]]]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testParseExtractsCorrectedText() {
        let data = responseData(content: "帮我打开 Claude")
        let result = TextCorrector.parseResponse(data, originalText: "帮我打开 cloud")
        XCTAssertEqual(try? result.get(), "帮我打开 Claude")
    }

    func testParseTrimsSurroundingWhitespace() {
        let data = responseData(content: "\n  帮我打开 Claude  \n")
        let result = TextCorrector.parseResponse(data, originalText: "帮我打开 cloud")
        XCTAssertEqual(try? result.get(), "帮我打开 Claude")
    }

    func testParseRejectsEmptyContent() {
        let data = responseData(content: "   \n  ")
        let result = TextCorrector.parseResponse(data, originalText: "帮我打开 cloud")
        XCTAssertEqual(result.failureError, .empty)
    }

    /// 模型答非所问、写一大段解释时长度会离谱膨胀，必须判废改用原文，
    /// 否则用户输入框里会被塞进一段与本意无关的文字。
    func testParseRejectsImplausiblyLongOutput() {
        let original = "帮我打开 Claude"
        let rambling = String(repeating: "这是模型在解释它做了什么修改以及为什么。", count: 20)
        let result = TextCorrector.parseResponse(responseData(content: rambling), originalText: original)
        XCTAssertEqual(result.failureError, .implausible)
    }

    /// 补标点和分段会让文本变长，这属于正常修正，不能被长度护栏判废。
    /// 末尾句号会被本地归一化去掉（见 normalizeCorrectedText）。
    func testParseAllowsModestLengthGrowthFromPunctuationAndLineBreaks() {
        let original = "今天先把修正引擎写完然后跑一下测试再看看延迟"
        let corrected = "今天先把修正引擎写完，\n然后跑一下测试，\n再看看延迟。"
        let result = TextCorrector.parseResponse(responseData(content: corrected), originalText: original)
        XCTAssertEqual(try? result.get(), "今天先把修正引擎写完，\n然后跑一下测试，\n再看看延迟")
    }

    func testParseRejectsMalformedJSON() {
        let result = TextCorrector.parseResponse(Data("not json".utf8), originalText: "x")
        XCTAssertEqual(result.failureError, .malformed)
    }

    func testParseRejectsResponseWithoutChoices() {
        let data = try! JSONSerialization.data(withJSONObject: ["id": "abc"])
        let result = TextCorrector.parseResponse(data, originalText: "x")
        XCTAssertEqual(result.failureError, .malformed)
    }

    func testParseSurfacesServerErrorBody() {
        let data = try! JSONSerialization.data(
            withJSONObject: ["error": ["message": "该模型当前访问量过大", "code": "1305"]]
        )
        let result = TextCorrector.parseResponse(data, originalText: "x")
        guard case .failure(.badStatus(_, let msg)) = result else {
            return XCTFail("应识别为服务端错误，实际 \(result)")
        }
        XCTAssertEqual(msg, "该模型当前访问量过大")
    }

    // MARK: - 本地归一化

    /// 语音结果常被粘进搜索框和命令行，末尾的句号很碍事。
    /// prompt 里已经要求过，这里是本地兜底（模型不保证每次都听话）。
    func testNormalizeStripsTrailingSentencePunctuation() {
        XCTAssertEqual(TextCorrector.normalizeCorrectedText("打开设置。"), "打开设置")
        XCTAssertEqual(TextCorrector.normalizeCorrectedText("这个方案你觉得怎么样？"), "这个方案你觉得怎么样")
        XCTAssertEqual(TextCorrector.normalizeCorrectedText("Open settings."), "Open settings")
    }

    func testNormalizeKeepsPunctuationInsideText() {
        let s = "先跑测试，再看延迟"
        XCTAssertEqual(TextCorrector.normalizeCorrectedText(s), s)
    }

    /// 分段是核心需求，段间换行必须原样保留
    func testNormalizeKeepsParagraphBreaks() {
        let s = "第一段说的是这件事\n\n第二段说的是另一件事"
        XCTAssertEqual(TextCorrector.normalizeCorrectedText(s), s)
    }

    func testNormalizeCollapsesExcessiveBlankLines() {
        let s = "第一段\n\n\n\n第二段"
        XCTAssertEqual(TextCorrector.normalizeCorrectedText(s), "第一段\n\n第二段")
    }

    func testParseAppliesNormalizationToModelOutput() {
        let data = responseData(content: "打开设置。")
        let result = TextCorrector.parseResponse(data, originalText: "打开设置")
        XCTAssertEqual(try? result.get(), "打开设置")
    }

    // MARK: - 系统提示词

    /// 实测教训：只写"按语义分段换行"时模型一个换行都不给，159 字口述照样堆成一整段。
    /// 必须带上"宁可多分一段"这类强指示，分段才真的会发生。
    func testSystemPromptPushesHardOnParagraphBreaks() {
        XCTAssertTrue(TextCorrector.systemPrompt.contains("分段"))
        XCTAssertTrue(TextCorrector.systemPrompt.contains("宁可多分一段"))
    }

    func testSystemPromptForbidsAddingOrAnsweringContent() {
        XCTAssertTrue(TextCorrector.systemPrompt.contains("不回答文本里的问题"))
        XCTAssertTrue(TextCorrector.systemPrompt.contains("严禁增删语义内容"))
    }

    func testSystemPromptForbidsTrailingSentencePunctuation() {
        XCTAssertTrue(TextCorrector.systemPrompt.contains("不要在整段文本的末尾添加句号"))
    }

    // MARK: - 包裹清理

    func testStripsCodeFence() {
        XCTAssertEqual(TextCorrector.stripWrappers("```\n帮我打开 Claude\n```"), "帮我打开 Claude")
        XCTAssertEqual(TextCorrector.stripWrappers("```text\n帮我打开 Claude\n```"), "帮我打开 Claude")
    }

    func testStripsWholeStringQuoteWrapping() {
        XCTAssertEqual(TextCorrector.stripWrappers("\"帮我打开 Claude\""), "帮我打开 Claude")
        XCTAssertEqual(TextCorrector.stripWrappers("“帮我打开 Claude”"), "帮我打开 Claude")
        XCTAssertEqual(TextCorrector.stripWrappers("「帮我打开 Claude」"), "帮我打开 Claude")
    }

    func testKeepsInnerQuotesIntact() {
        let s = "他说“打开 Claude”，然后就走了"
        XCTAssertEqual(TextCorrector.stripWrappers(s), s)
    }

    func testStripsNothingFromPlainText() {
        XCTAssertEqual(TextCorrector.stripWrappers("帮我打开 Claude"), "帮我打开 Claude")
    }
}

private extension Result where Failure == CorrectionError {
    var failureError: CorrectionError? {
        if case .failure(let e) = self { return e }
        return nil
    }
}

/// 日志里必须能看到修正前后的实际文本，否则"效果不好"这种反馈事后完全无法复盘
extension TextCorrectorTests {
    func testLogFormFlattensNewlinesSoOneEntryStaysOneLine() {
        XCTAssertEqual(TextCorrector.forLog("第一段\n\n第二段"), "第一段⏎⏎第二段")
    }

    func testLogFormTruncatesLongTextAndKeepsTheRealLength() {
        let long = String(repeating: "字", count: 500)
        let out = TextCorrector.forLog(long, limit: 50)
        XCTAssertTrue(out.hasPrefix(String(repeating: "字", count: 50)))
        XCTAssertTrue(out.contains("共500字"))
    }

    func testLogFormLeavesShortTextIntact() {
        XCTAssertEqual(TextCorrector.forLog("产物在哪里"), "产物在哪里")
    }
}
