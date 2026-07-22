import UIKit

#if DEBUG
/// Focused Mac Catalyst debug for web-search quality on Kimi K2.6.
/// Launch: `-WebSearchDebug`
///
/// Exercises plan → SERP → page read → answer injection, and scores quality
/// beyond “a search panel exists” (empty results, off-topic hits, official-portal
/// pollution on culture topics, etc.).
enum WebSearchDebugHarness {
    private static let logTag = "[ConnectsWebSearchDebug]"
    private static var didStart = false

    private struct Case {
        let id: String
        let prompt: String
        /// Prior user/assistant turns for pronoun / follow-up resolution.
        var prior: [(role: MessageRole, text: String)] = []
        var mustContainAny: [String] = []
        var forbidAny: [String] = []
        /// Culture / hobby topics must not surface government portals.
        var forbidOfficialPortals = false
        var timeout: TimeInterval = 240
    }

    private struct ResultRow {
        let id: String
        let ok: Bool
        let detail: String
        let searchChars: Int
        let replyChars: Int
    }

    static func startIfRequested(from chat: ChatViewController) {
        guard ProcessInfo.processInfo.arguments.contains("-WebSearchDebug") else { return }
        guard !didStart else { return }
        didStart = true
        DebugAPIBootstrap.loadKimiKeyIfNeeded(logTag: logTag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            run(on: chat)
        }
    }

    private static func run(on chat: ChatViewController) {
        guard SettingsManager.shared.hasAPIKey(for: .kimi) else {
            print("\(logTag) FAIL missing Kimi API key")
            finish(1)
            return
        }

        let allCases: [Case] = [
            // --- prior core regressions ---
            Case(
                id: "nobel-physics-2024",
                prompt: "2024年诺贝尔物理学奖得主是谁？请给出姓名并一句话说明贡献。",
                mustContainAny: ["Hopfield", "Hinton", "霍普菲尔德", "辛顿", "神经网络", "机器学习"],
                timeout: 260
            ),
            Case(
                id: "anime-culture-history",
                prompt: "中国的二次元文化是怎么发展起来的？",
                mustContainAny: ["二次元", "ACG", "动漫", "御宅", "同人"],
                forbidAny: ["七大洲", "板块", "地壳", "环太平洋", "中国政府网", "国务院"],
                forbidOfficialPortals: true,
                timeout: 280
            ),
            Case(
                id: "followup-pronoun",
                prompt: "那这个在中国是怎么发展起来的？",
                prior: [
                    (.user, "我想了解一下二次元亚文化。"),
                    (.assistant, "二次元通常指以动漫、游戏、漫画为核心的 ACG 爱好者文化。")
                ],
                mustContainAny: ["二次元", "ACG", "动漫", "御宅"],
                forbidAny: ["七大洲", "板块", "中国政府网"],
                forbidOfficialPortals: true,
                timeout: 280
            ),
            Case(
                id: "tech-fact-apple-intelligence",
                prompt: "Apple 在 2024 年 WWDC 发布的 AI 功能叫什么正式名称？",
                mustContainAny: ["Apple Intelligence", "苹果智能", "Intelligence"],
                timeout: 260
            ),
            Case(
                id: "policy-allow-gov",
                prompt: "中国个人所得税专项附加扣除目前有哪些项目？请列要点。",
                mustContainAny: ["子女教育", "住房", "赡养老人", "继续教育", "大病", "婴幼儿", "专项附加"],
                timeout: 280
            ),

            // --- culture / wrong-sense traps ---
            Case(
                id: "otaku-definition",
                prompt: "御宅族这个词最初在日本是什么意思？后来含义有何变化？",
                mustContainAny: ["御宅", "otaku", "动漫", "ACG", "爱好"],
                forbidAny: ["七大洲", "板块构造", "中国政府网"],
                forbidOfficialPortals: true,
                timeout: 260
            ),
            Case(
                id: "douban-movie-fact",
                prompt: "电影《盗梦空间》的导演是谁？上映年份大概是哪一年？",
                mustContainAny: ["诺兰", "Nolan", "2010", "克里斯托弗"],
                forbidOfficialPortals: true,
                timeout: 240
            ),
            Case(
                id: "bilibili-company",
                prompt: "哔哩哔哩公司的股票代码或常见简称是什么？一句话介绍它主要做什么。",
                mustContainAny: ["B站", "Bilibili", "哔哩哔哩", "9626", "视频"],
                forbidOfficialPortals: true,
                timeout: 240
            ),

            // --- science / tech ---
            Case(
                id: "nobel-chem-2024",
                prompt: "2024年诺贝尔化学奖主要授予了什么领域的工作？得主姓氏有哪些？",
                mustContainAny: ["蛋白质", "AlphaFold", "Baker", "Hassabis", "Jumper", "贝克", "哈萨比斯"],
                timeout: 260
            ),
            Case(
                id: "swift-concurrency",
                prompt: "Swift 的 async/await 大约从哪个大版本开始成为正式语言特性？",
                mustContainAny: ["Swift 5.5", "5.5", "async", "await", "并发"],
                timeout: 240
            ),
            Case(
                id: "verilog-vs-vhdl",
                prompt: "Verilog 和 VHDL 在硬件描述语言里各有什么典型定位？用三点对比。",
                mustContainAny: ["Verilog", "VHDL", "硬件", "仿真", "综合", "IEEE"],
                timeout: 240
            ),
            Case(
                id: "chatgpt-release",
                prompt: "OpenAI 的 ChatGPT 首次公开发布大约是哪一年哪个月？",
                mustContainAny: ["2022", "11月", "November", "ChatGPT"],
                timeout: 240
            ),

            // --- news / sports / geography (geo terms allowed) ---
            Case(
                id: "olympics-paris-2024",
                prompt: "2024年巴黎奥运会中国代表团金牌数大约是多少？",
                mustContainAny: ["40", "金牌", "巴黎", "中国"],
                timeout: 260
            ),
            Case(
                id: "geography-continent",
                prompt: "七大洲通常指哪七个？中国位于哪一洲？",
                mustContainAny: ["亚洲", "欧洲", "非洲", "南极", "美洲", "大洋洲"],
                timeout: 240
            ),

            // --- multi-turn / ambiguity ---
            Case(
                id: "followup-why",
                prompt: "为什么它会火起来？",
                prior: [
                    (.user, "最近很多人在聊 DeepSeek。"),
                    (.assistant, "DeepSeek 是一家中国 AI 公司，其大模型在开源与推理成本上引发关注。")
                ],
                mustContainAny: ["DeepSeek", "深度求索", "模型", "开源", "推理"],
                forbidAny: ["七大洲", "地壳"],
                timeout: 260
            ),
            Case(
                id: "apple-fruit-vs-company",
                prompt: "这里的苹果是指水果还是公司？请结合上文判断并解释。",
                prior: [
                    (.user, "我想买一台新电脑，预算有限。"),
                    (.assistant, "可以考虑二手或教育优惠渠道。"),
                    (.user, "那苹果现在哪款 Mac 性价比高？")
                ],
                mustContainAny: ["Apple", "Mac", "公司", "电脑"],
                forbidAny: ["富士苹果", "红富士", "水果店"],
                timeout: 240
            ),

            // --- policy / living info ---
            Case(
                id: "visa-schengen-basics",
                prompt: "中国护照申请申根旅游签证，常见需要准备哪些材料？列要点即可。",
                mustContainAny: ["护照", "行程", "保险", "酒店", "财力", "签证"],
                timeout: 260
            ),
            Case(
                id: "housing-fund-basics",
                prompt: "住房公积金一般可以用于哪些住房相关支出？简述几类。",
                mustContainAny: ["购房", "还款", "租房", "公积金", "贷款"],
                timeout: 260
            ),

            // --- English / mixed ---
            Case(
                id: "en-transformer-paper",
                prompt: "Who wrote the paper Attention Is All You Need, and what architecture did it introduce?",
                mustContainAny: ["Transformer", "Vaswani", "attention", "Google"],
                timeout: 240
            ),
            Case(
                id: "mixed-rust-ownership",
                prompt: "Rust 的 ownership 规则用中文概括三条核心约束。",
                mustContainAny: ["所有权", "借用", "生命周期", "ownership", "mutable", "引用"],
                timeout: 240
            )
        ]
        let cases = selectedCases(from: allCases)

        print("\(logTag) begin model=Kimi K2.6 cases=\(cases.count)")
        chat.loadViewIfNeeded()

        let savedThinking = SettingsManager.shared.thinkingEnabled
        let savedSearch = SettingsManager.shared.webSearchEnabled
        SettingsManager.shared.thinkingEnabled = false
        SettingsManager.shared.webSearchEnabled = true

        runCases(cases, index: 0, chat: chat, rows: []) { rows in
            SettingsManager.shared.thinkingEnabled = savedThinking
            SettingsManager.shared.webSearchEnabled = savedSearch
            writeReport(rows)
            let failed = rows.filter { !$0.ok }
            for row in rows {
                print("\(logTag) case \(row.id): \(row.ok ? "OK" : "FAIL") \(row.detail) search=\(row.searchChars) reply=\(row.replyChars)")
            }
            if failed.isEmpty {
                print("\(logTag) PASS all \(rows.count) search cases")
                finish(0)
            } else {
                print("\(logTag) FAIL \(failed.count)/\(rows.count)")
                finish(1)
            }
        }
    }

    /// Optional filter: `-WebSearchDebugCase id1,id2` or env `CONNECTS_WEBSEARCH_CASES`.
    private static func selectedCases(from all: [Case]) -> [Case] {
        let args = ProcessInfo.processInfo.arguments
        var filterRaw: String?
        if let idx = args.firstIndex(of: "-WebSearchDebugCase"), idx + 1 < args.count {
            let candidate = args[idx + 1]
            if !candidate.hasPrefix("-") { filterRaw = candidate }
        }
        if filterRaw == nil {
            filterRaw = ProcessInfo.processInfo.environment["CONNECTS_WEBSEARCH_CASES"]
        }
        guard let raw = filterRaw?
            .split(separator: ",")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty }),
              !raw.isEmpty else {
            return all
        }
        let wanted = Set(raw)
        let picked = all.filter { wanted.contains($0.id) }
        if picked.count != wanted.count {
            let missing = wanted.subtracting(picked.map(\.id))
            print("\(logTag) WARN unknown case ids: \(missing.sorted().joined(separator: ","))")
        }
        return picked.isEmpty ? all : picked
    }

    private static func runCases(
        _ cases: [Case],
        index: Int,
        chat: ChatViewController,
        rows: [ResultRow],
        completion: @escaping ([ResultRow]) -> Void
    ) {
        guard index < cases.count else {
            completion(rows)
            return
        }
        let step = cases[index]
        print("\(logTag) send \(index + 1)/\(cases.count): \(step.id)")

        let conv = ConversationStore.shared.createConversation(model: .kimi26)
        chat.applyConversationSwitchHint()
        chat.switchToConversation(id: conv.id, coldLaunch: true)
        chat.reloadChat()

        seedPriorTurns(conversationID: conv.id, prior: step.prior)
        chat.reloadChat()

        chat.debugSendUserMessage(step.prompt, timeout: step.timeout) { ok in
            var next = rows
            if !ok {
                next.append(ResultRow(
                    id: step.id,
                    ok: false,
                    detail: "stream timeout/fail",
                    searchChars: 0,
                    replyChars: 0
                ))
            } else {
                next.append(evaluate(step))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                runCases(cases, index: index + 1, chat: chat, rows: next, completion: completion)
            }
        }
    }

    private static func seedPriorTurns(conversationID: String, prior: [(role: MessageRole, text: String)]) {
        guard !prior.isEmpty else { return }
        ConversationStore.shared.updateConversationQuietly(id: conversationID) { conversation in
            for turn in prior {
                conversation.messages.append(ChatMessage(role: turn.role, content: turn.text))
            }
        }
    }

    private static func evaluate(_ step: Case) -> ResultRow {
        guard let conv = ConversationStore.shared.currentConversation,
              let assistant = conv.messages.last(where: { $0.role == .assistant }) else {
            return ResultRow(id: step.id, ok: false, detail: "no assistant message", searchChars: 0, replyChars: 0)
        }

        let search = assistant.searchProcessContent
        let reply = assistant.content
        let blob = (search + "\n" + reply).lowercased()
        let searchChars = search.count
        let replyChars = reply.trimmingCharacters(in: .whitespacesAndNewlines).count

        if !assistant.hasSearchProcess && assistant.searchProcessPhase == .idle {
            return ResultRow(id: step.id, ok: false, detail: "no search process recorded", searchChars: searchChars, replyChars: replyChars)
        }
        if search.contains("检索未成功") || search.contains("未找到可用") {
            return ResultRow(id: step.id, ok: false, detail: "search reported failure", searchChars: searchChars, replyChars: replyChars)
        }
        if !search.contains("搜索结果") && !search.contains("已阅读网页") && !search.contains("网页正文") {
            // Planner-only / empty SERP path.
            if searchChars < 40 {
                return ResultRow(id: step.id, ok: false, detail: "search log too thin", searchChars: searchChars, replyChars: replyChars)
            }
        }
        if search.contains("本次未提取到可用正文") && !search.contains("http") {
            return ResultRow(id: step.id, ok: false, detail: "no usable hits or pages", searchChars: searchChars, replyChars: replyChars)
        }
        if replyChars < 8 {
            return ResultRow(id: step.id, ok: false, detail: "empty assistant reply", searchChars: searchChars, replyChars: replyChars)
        }

        if step.forbidOfficialPortals {
            let portals = ["gov.cn", "中国政府网", "people.com.cn", "xinhuanet.com", "china.com.cn", "国务院"]
            if portals.contains(where: { search.lowercased().contains($0.lowercased()) }) {
                return ResultRow(id: step.id, ok: false, detail: "official portal polluted culture search", searchChars: searchChars, replyChars: replyChars)
            }
        }
        for bad in step.forbidAny where blob.contains(bad.lowercased()) {
            return ResultRow(id: step.id, ok: false, detail: "forbidden off-topic hit: \(bad)", searchChars: searchChars, replyChars: replyChars)
        }
        if !step.mustContainAny.isEmpty {
            let hit = step.mustContainAny.contains { blob.contains($0.lowercased()) }
            if !hit {
                let preview = String((search + " | " + reply).prefix(180)).replacingOccurrences(of: "\n", with: " ")
                return ResultRow(
                    id: step.id,
                    ok: false,
                    detail: "missing expected terms \(step.mustContainAny.joined(separator: "/")); preview=\(preview)",
                    searchChars: searchChars,
                    replyChars: replyChars
                )
            }
        }

        print("\(logTag) search preview [\(step.id)]:\n\(String(search.prefix(500)))")
        return ResultRow(id: step.id, ok: true, detail: "ok", searchChars: searchChars, replyChars: replyChars)
    }

    private static func writeReport(_ rows: [ResultRow]) {
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("connects-websearch-debug-report.json")
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "model": AIModelOption.kimi26.modelId,
            "passCount": rows.filter(\.ok).count,
            "failCount": rows.filter { !$0.ok }.count,
            "cases": rows.map {
                [
                    "id": $0.id,
                    "ok": $0.ok,
                    "detail": $0.detail,
                    "searchChars": $0.searchChars,
                    "replyChars": $0.replyChars
                ] as [String: Any]
            }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: url)
            print("\(logTag) report → \(url.path)")
        }
    }

    private static func finish(_ code: Int32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            exit(code)
        }
    }
}
#endif
