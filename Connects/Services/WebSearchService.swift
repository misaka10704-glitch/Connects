import Foundation

/// Browse-then-answer web mode: SERP → open top pages → inject page text for the model.
enum WebSearchService {
    struct Hit {
        let title: String
        let url: String
        let snippet: String
    }

    struct SearchBundle {
        /// Injected into the model context.
        let evidenceBlock: String
        /// Shown in the collapsible “联网检索” panel.
        let processLog: String
    }

    struct WeightedTerm {
        let term: String
        let weight: Int
    }

    struct SearchPlan {
        let queries: [String]
        let weightedTerms: [WeightedTerm]

        static func fallback(_ query: String) -> SearchPlan {
            let cleaned = WebSearchService.sanitizeQuery(query)
            return SearchPlan(
                queries: cleaned.isEmpty ? [] : [cleaned],
                weightedTerms: cleaned.isEmpty ? [] : [WeightedTerm(term: cleaned, weight: 5)]
            )
        }
    }

    enum SearchError: LocalizedError {
        case emptyQuery
        case network(String)
        case noResults

        var errorDescription: String? {
            switch self {
            case .emptyQuery: return "搜索词为空"
            case .network(let s): return s
            case .noResults: return "未找到可用的搜索结果"
            }
        }
    }

    /// Keep web context focused: two successfully opened sources are enough
    /// for a normal answer, while several SERP candidates provide retries.
    private static let maxPagesToRead = 2
    private static let maxPageCandidates = 5
    private static let maxCharsPerPage = 1800
    private static let maxDownloadBytes = 300_000
    private static let maxInjectedEvidenceChars = 8_000
    private static let maxPlannedQueries = 5
    private static let maxWeightedTerms = 6

    /// Ask the model to turn conversation context into concrete search queries.
    /// Follow-ups like "那这个呢" should resolve against prior turns, not be searched verbatim.
    static func planSearchQueries(
        contextMessages: [ChatMessage],
        model: AIModelOption,
        fallbackQuery: String,
        completion: @escaping (SearchPlan) -> Void
    ) {
        let fallback = sanitizeQuery(fallbackQuery)
        let transcript = compactTranscript(contextMessages, maxChars: 3_500)
        guard !transcript.isEmpty else {
            DispatchQueue.main.async {
                completion(SearchPlan.fallback(fallback))
            }
            return
        }

        let prompt = ChatMessage(
            role: .user,
            content: """
            你是聊天应用的联网检索规划器。根据下方对话，为「最新一条用户消息」生成检索词，并给出用来挑选文章的核心概念权重。

            要求：
            - 必须结合前文消解指代（如「他呢」「那这个」「为什么」），写成具体实体 / 事件 / 问题，不要原样照抄模糊追问。
            - 用户用中文时优先写中文检索词；专有名词可保留原文。
            - 只要需要联网，输出 3–\(maxPlannedQueries) 条互补检索词，分别覆盖用户问题的定义/背景、起源/历史、发展/影响、研究/争议等实际相关维度；不要只是同一句话的机械改写。
            - 检索的是用户要解决的事实、事件、产品、人物或问题；禁止把问题误写成「某词笔顺 / 汉字释义 / 拼音 / 读音 / 字形 / 语法解释」等语言学习关键词，除非最新消息明确要求查询这些内容。
            - 不要搜索聊天措辞、单个虚词或泛化的元问题；必须保留具体主体与用户真正要了解的关系、原因或结论。
            - 对概念、文化、历史、社会现象类问题，检索定义、起源、发展、研究或报道；不要生成用于找动画、番剧、视频、在线播放或播放平台的词。
            - 权重词必须是区分资料相关性的具体实体、概念或关系；不要使用「文化」「社会」「新闻」等过泛词。权重 1–5，5 表示最核心。
            - 只输出合法 JSON，不要 Markdown、解释或其它文字：
              {"queries":["检索词 1"],"weights":[{"term":"核心概念","weight":5},{"term":"起源","weight":3}]}
            - 若完全不需要联网，只输出：{"queries":[],"weights":[]}

            【对话】
            \(transcript)
            """
        )

        APIClient.shared.complete(messages: [prompt], model: model, maxTokens: 220) { result in
            switch result {
            case .success(let raw):
                completion(parseSearchPlan(raw, fallback: fallback))
            case .failure:
                completion(SearchPlan.fallback(fallback))
            }
        }
    }

    /// Search the web, open top result pages, and format evidence for the model.
    /// `onStatus` is always called on the main queue (e.g. "正在搜索…" / "正在阅读网页…").
    static func searchAndFormat(
        query: String,
        onStatus: ((String) -> Void)? = nil,
        completion: @escaping (Result<SearchBundle, Error>) -> Void
    ) {
        searchAndFormat(queries: [query], weightedTerms: [], onStatus: onStatus, completion: completion)
    }

    /// Search using one or more planned queries, then browse and format evidence.
    static func searchAndFormat(
        queries: [String],
        weightedTerms: [WeightedTerm] = [],
        onStatus: ((String) -> Void)? = nil,
        completion: @escaping (Result<SearchBundle, Error>) -> Void
    ) {
        let qs = Array(
            queries
                .map(sanitizeQuery)
                .filter { !$0.isEmpty }
                .prefix(maxPlannedQueries)
        )
        guard !qs.isEmpty else {
            DispatchQueue.main.async { completion(.failure(SearchError.emptyQuery)) }
            return
        }

        DispatchQueue.main.async { onStatus?("正在搜索…") }

        let group = DispatchGroup()
        let lock = NSLock()
        var allSources: [[Hit]] = []
        var lastError: Error?

        for q in qs {
            group.enter()
            fetchAllEngines(query: q) { hits, error in
                lock.lock()
                if !hits.isEmpty { allSources.append(hits) }
                if let error = error, lastError == nil { lastError = error }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            let rankKey = qs.joined(separator: " ")
            let rankedHits = rankHits(
                mergeHits(sources: allSources, limit: 40),
                query: rankKey,
                weightedTerms: weightedTerms
            )
            // Weights are not merely a tie-breaker. A page that does not
            // match the AI-selected core concepts must not reach browsing
            // just because it happened to be returned near the end of Bing's
            // result feed.
            let weightQualifiedHits = rankedHits.filter {
                passesWeightFilter($0, weightedTerms: weightedTerms)
            }
            let candidates = weightedTerms.isEmpty ? rankedHits : weightQualifiedHits
            // Watching/streaming platforms rarely provide an explanatory
            // source even when their titles happen to contain the topic.
            let informativeHits = candidates.filter { !isPlaybackPlatform($0.url) }
            let hits = informativeHits.isEmpty ? candidates : informativeHits
            guard !hits.isEmpty else {
                DispatchQueue.main.async {
                    completion(.failure(lastError ?? SearchError.noResults))
                }
                return
            }

            let toBrowse = pickBrowseTargets(from: hits, limit: maxPageCandidates)
            DispatchQueue.main.async { onStatus?("正在阅读网页…") }

            fetchPages(toBrowse) { pages, _ in
                let usableHits = hits.filter { !isExcludedResultHost($0.url) }
                guard !usableHits.isEmpty else {
                    DispatchQueue.main.async {
                        completion(.failure(SearchError.noResults))
                    }
                    return
                }
                let evidence = formatEvidence(queries: qs, hits: usableHits, pages: pages)
                let process = formatProcessLog(queries: qs, hits: usableHits, pages: pages)
                DispatchQueue.main.async {
                    if evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        completion(.failure(lastError ?? SearchError.noResults))
                    } else {
                        completion(.success(SearchBundle(evidenceBlock: evidence, processLog: process)))
                    }
                }
            }
        }
    }

    private static func fetchAllEngines(query: String, completion: @escaping ([Hit], Error?) -> Void) {
        fetchBingHTML(query: query) { result in
            switch result {
            case .success(let hits):
                // Bing has already ranked the RSS feed. A second strict
                // substring filter can incorrectly discard every valid
                // Chinese result when titles paraphrase the query.
                let usable = hits.filter { !isExcludedResultHost($0.url) }
                completion(Array(usable.prefix(8)), nil)
            case .failure(let error):
                completion([], error)
            }
        }
    }

    private struct SearchPlanPayload: Decodable {
        struct Weight: Decodable {
            let term: String
            let weight: Int
        }

        let queries: [String]
        let weights: [Weight]
    }

    private static func parseSearchPlan(_ raw: String, fallback: String) -> SearchPlan {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONDecoder().decode(SearchPlanPayload.self, from: data) {
            let queries = normalizedQueries(payload.queries, fallback: fallback)
            let weights = normalizedWeights(payload.weights)
            if !queries.isEmpty {
                return SearchPlan(
                    queries: queries,
                    weightedTerms: weights.isEmpty
                        ? [WeightedTerm(term: queries[0], weight: 5)]
                        : weights
                )
            }
        }

        let queries = parsePlannedQueries(raw, fallback: fallback)
        return queries.isEmpty
            ? SearchPlan.fallback(fallback)
            : SearchPlan(
                queries: queries,
                weightedTerms: [WeightedTerm(term: queries[0], weight: 5)]
            )
    }

    private static func normalizedQueries(_ raw: [String], fallback: String) -> [String] {
        var seen = Set<String>()
        return raw.compactMap { value -> String? in
            let query = sanitizeQuery(value)
            guard !query.isEmpty,
                  !looksLikeLanguageMetaQuery(query, fallback: fallback),
                  seen.insert(query.lowercased()).inserted else {
                return nil
            }
            return query
        }
        .prefix(maxPlannedQueries)
        .map { $0 }
    }

    private static func normalizedWeights(_ raw: [SearchPlanPayload.Weight]) -> [WeightedTerm] {
        var seen = Set<String>()
        return raw.compactMap { item -> WeightedTerm? in
            let term = sanitizeQuery(item.term)
            guard term.count >= 2,
                  seen.insert(term.lowercased()).inserted else {
                return nil
            }
            return WeightedTerm(term: term, weight: max(1, min(5, item.weight)))
        }
        .prefix(maxWeightedTerms)
        .map { $0 }
    }

    private static func parsePlannedQueries(_ raw: String, fallback: String) -> [String] {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
                // Strip common list markers: "1.", "1)", "-", "*", "•"
                if let re = try? NSRegularExpression(pattern: #"^\s*(?:\d+[\.\)、]|\-|\*|•)\s*"#) {
                    s = re.stringByReplacingMatches(
                        in: s,
                        options: [],
                        range: NSRange(s.startIndex..<s.endIndex, in: s),
                        withTemplate: ""
                    )
                }
                if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("「") && s.hasSuffix("」")) {
                    s = String(s.dropFirst().dropLast())
                }
                return sanitizeQuery(s)
            }
            .filter { !$0.isEmpty && !looksLikeLanguageMetaQuery($0, fallback: fallback) }

        if lines.contains(where: { $0.uppercased() == "NONE" }) {
            return []
        }

        var out: [String] = []
        var seen = Set<String>()
        for line in lines {
            let key = line.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(line)
            if out.count >= maxPlannedQueries { break }
        }
        return out
    }

    private static func looksLikeLanguageMetaQuery(_ query: String, fallback: String) -> Bool {
        let markers = ["笔顺", "汉字", "拼音", "读音", "字形", "字义", "部首", "怎么写", "发音"]
        guard markers.contains(where: { query.contains($0) }) else { return false }
        // Preserve legitimate language-learning searches explicitly requested
        // by the user, but reject planner hallucinations for ordinary topics.
        return !markers.contains(where: { fallback.contains($0) })
    }

    private static func compactTranscript(_ messages: [ChatMessage], maxChars: Int) -> String {
        var lines: [String] = []
        for msg in messages where msg.role == .user || msg.role == .assistant {
            let role = msg.role == .user ? "用户" : "助手"
            let body = msg.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            // Skip transient search status placeholders if any leaked in.
            if body.hasPrefix("正在搜索") || body.hasPrefix("正在阅读") || body.hasPrefix("正在规划") {
                continue
            }
            let clipped = body.count > 900 ? String(body.prefix(900)) + "…" : body
            lines.append("\(role)：\(clipped)")
        }
        var text = lines.joined(separator: "\n")
        if text.count > maxChars {
            text = String(text.suffix(maxChars))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Inject search/browse context before the last user message (API-only).
    static func inject(into messages: [ChatMessage], searchBlock: String) -> [ChatMessage] {
        let block = capped(searchBlock.trimmingCharacters(in: .whitespacesAndNewlines), at: maxInjectedEvidenceChars)
        guard !block.isEmpty else { return messages }
        guard let idx = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        var out = messages
        let evidence = ChatMessage(
            role: .system,
            content: """
            [Web search context]
            以下是为最新用户问题抓取的网页证据。只使用与问题直接相关的内容；若证据跑题、薄弱或互相冲突，忽略它并按已有知识直接回答，不要为了套模板而改变问题。
            不要描述检索过程。确实引用网页时，最多列 5 条，并在末尾用“### 参考来源”下的连续编号 Markdown 链接呈现；没有有效引用时不要强行添加来源区。

            \(block)
            """
        )
        out.insert(evidence, at: idx)
        return out
    }

    static func inject(into messages: [ChatMessage], bundle: SearchBundle) -> [ChatMessage] {
        inject(into: messages, searchBlock: bundle.evidenceBlock)
    }

    static func fitInjectedContext(_ messages: [ChatMessage], model: AIModelOption) -> [ChatMessage] {
        let budget = ContextBuilder.charBudget(for: model)
        guard ContextBuilder.estimatedChars(messages) > budget else { return messages }

        var out = messages
        guard let evidenceIndex = out.firstIndex(where: {
            $0.role == .system && $0.content.hasPrefix("[Web search context]")
        }) else {
            return out
        }

        // The chat history was already compacted by ContextBuilder before web
        // evidence was injected. Dropping dialogue here can therefore turn a
        // continuation into an apparent brand-new chat. Search evidence is
        // supplementary, so it must yield before any conversation turn does.
        let evidence = out[evidenceIndex]
        out.remove(at: evidenceIndex)
        let roomForEvidence = budget - ContextBuilder.estimatedChars(out) - 24
        guard roomForEvidence > 0 else { return out }

        var fittedEvidence = evidence
        if fittedEvidence.content.count > roomForEvidence {
            let marker = "\n…[web evidence truncated to preserve conversation context]"
            if roomForEvidence <= marker.count {
                fittedEvidence.content = String(fittedEvidence.content.prefix(roomForEvidence))
            } else {
                let bodyLimit = roomForEvidence - marker.count
                fittedEvidence.content = String(fittedEvidence.content.prefix(bodyLimit))
                    .trimmingCharacters(in: .whitespacesAndNewlines) + marker
            }
        }
        guard !fittedEvidence.content.isEmpty else { return out }
        out.insert(fittedEvidence, at: evidenceIndex)
        return out
    }

    private static func capped(_ text: String, at limit: Int) -> String {
        guard text.count > limit else { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n…[web evidence truncated]"
    }

    // MARK: - Format

    private struct PageText {
        let hit: Hit
        let text: String
    }

    private static func formatEvidence(queries: [String], hits: [Hit], pages: [PageText]) -> String {
        var lines: [String] = []
        if queries.count <= 1 {
            lines.append("检索词：\(queries.first ?? "")")
        } else {
            lines.append("检索词：")
            for (i, q) in queries.enumerated() {
                lines.append("  \(i + 1). \(q)")
            }
        }
        lines.append("")

        lines.append("【搜索结果摘要】")
        for (i, hit) in hits.prefix(5).enumerated() {
            lines.append("[\(i + 1)] \(hit.title)")
            if !hit.url.isEmpty { lines.append("链接：\(hit.url)") }
            if !hit.snippet.isEmpty { lines.append(hit.snippet) }
            lines.append("")
        }

        if !pages.isEmpty {
            lines.append("【网页正文】")
            for (i, page) in pages.enumerated() {
                lines.append("—— 来源 \(i + 1)：\(page.hit.title)")
                if !page.hit.url.isEmpty { lines.append(page.hit.url) }
                lines.append(page.text)
                lines.append("")
            }
        } else {
            lines.append("【网页正文】")
            lines.append("（本次未提取到可用正文。）")
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatProcessLog(queries: [String], hits: [Hit], pages: [PageText]) -> String {
        var lines: [String] = []
        lines.append("根据对话上下文（含前文）规划检索，而不是只搜最后一句原文。")
        lines.append("")
        lines.append("检索词：")
        for (i, q) in queries.enumerated() {
            lines.append("\(i + 1). \(q)")
        }
        lines.append("")
        lines.append("搜索结果：")
        for (i, hit) in hits.prefix(5).enumerated() {
            var row = "\(i + 1). \(hit.title)"
            if !hit.url.isEmpty { row += "\n   \(hit.url)" }
            lines.append(row)
            if !hit.snippet.isEmpty {
                let snip = hit.snippet.count > 120 ? String(hit.snippet.prefix(120)) + "…" : hit.snippet
                lines.append("   \(snip)")
            }
        }
        lines.append("")
        if pages.isEmpty {
            lines.append("网页正文：本次未提取到可用正文。")
        } else {
            lines.append("已阅读网页：")
            for page in pages {
                var row = "· \(page.hit.title)"
                if !page.hit.url.isEmpty { row += "\n  \(page.hit.url)" }
                lines.append(row)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pickBrowseTargets(from hits: [Hit], limit: Int) -> [Hit] {
        var out: [Hit] = []
        var seenHost = Set<String>()
        for hit in hits {
            guard out.count < limit else { break }
            guard let url = URL(string: hit.url),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host?.lowercased(),
                  !host.isEmpty else { continue }
            if isBlockedHost(host) { continue }
            // Prefer unique hosts so we don't read three pages from the same site.
            if seenHost.contains(host) { continue }
            seenHost.insert(host)
            out.append(hit)
        }
        // If host diversity left us short, fill with remaining usable URLs.
        if out.count < limit {
            for hit in hits {
                guard out.count < limit else { break }
                guard let url = URL(string: hit.url),
                      let host = url.host?.lowercased(),
                      !isBlockedHost(host) else { continue }
                if out.contains(where: { $0.url == hit.url }) { continue }
                out.append(hit)
            }
        }
        return out
    }

    private static func isBlockedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "duckduckgo.com" || h.hasSuffix(".duckduckgo.com") { return true }
        if h == "bing.com" || h.hasSuffix(".bing.com") { return true }
        if h == "baidu.com" || h.hasSuffix(".baidu.com") { return true }
        if h.contains("google.") { return true }
        if h.contains("microsoft.com") || h.contains("microsoftonline.com") { return true }
        if h.contains("youtube.com") || h.contains("youtu.be") { return true }
        return false
    }

    /// Baidu's public result pages are often available while its destination
    /// sites (Baike, Wenku, Zhidao, etc.) serve verification walls to a
    /// programmatic reader. Exclude the whole domain before both displaying
    /// summaries and choosing articles, so it cannot occupy the useful slots.
    private static func isExcludedResultHost(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "baidu.com" || host.hasSuffix(".baidu.com")
    }

    // MARK: - Page fetch

    private static func fetchPages(
        _ hits: [Hit],
        completion: @escaping ([PageText], Set<String>) -> Void
    ) {
        guard !hits.isEmpty else {
            completion([], [])
            return
        }
        // Fetch candidates concurrently. Sequential per-site timeouts made a
        // single web search take far too long.
        let group = DispatchGroup()
        let lock = NSLock()
        var pages: [PageText] = []
        var failedHosts = Set<String>()

        for hit in hits {
            group.enter()
            fetchPageText(urlString: hit.url) { text in
                lock.lock()
                if let text = text, text.count >= 80 {
                    pages.append(PageText(hit: hit, text: text))
                } else if let host = URL(string: hit.url)?.host?.lowercased() {
                    failedHosts.insert(host)
                }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            lock.lock()
            let ordered = hits.compactMap { hit in
                pages.first(where: { $0.hit.url == hit.url })
            }
            let failed = failedHosts
            lock.unlock()
            completion(Array(ordered.prefix(maxPagesToRead)), failed)
        }
    }

    private static func fetchPageText(urlString: String, completion: @escaping (String?) -> Void) {
        guard var url = URL(string: urlString) else {
            completion(nil)
            return
        }
        if url.scheme == nil {
            url = URL(string: "https://" + urlString) ?? url
        }
        guard let host = url.host?.lowercased(), !isBlockedHost(host) else {
            completion(nil)
            return
        }
        // Use the reader first. It reliably handles dynamic and anti-bot
        // public pages that frequently reject the app's direct request.
        fetchReaderText(url: url) { text in
            if let text = text, !isReaderAccessWall(text) {
                completion(text)
            } else {
                fetchPageTextDirect(url: url, completion: completion)
            }
        }
    }

    private static func fetchPageTextDirect(url: URL, completion: @escaping (String?) -> Void) {
        let path = url.path.lowercased()
        let blockedExt = [".pdf", ".jpg", ".jpeg", ".png", ".gif", ".webp", ".mp4", ".zip", ".rar", ".dmg"]
        if blockedExt.contains(where: { path.hasSuffix($0) }) {
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyBrowserHeaders(&req)
        req.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { data, response, _ in
            guard let data = data, !data.isEmpty else {
                completion(nil)
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<400).contains(code) else {
                completion(nil)
                return
            }
            if let mime = (response as? HTTPURLResponse)?.mimeType?.lowercased(),
               !mime.contains("html"), !mime.contains("text"), !mime.contains("xml") {
                completion(nil)
                return
            }
            let capped = data.count > maxDownloadBytes ? Data(data.prefix(maxDownloadBytes)) : data
            let html = decodeHTMLData(capped, response: response as? HTTPURLResponse)
            let text = extractReadableText(from: html, maxChars: maxCharsPerPage)
            if text.count >= 80 {
                completion(text)
            } else {
                completion(nil)
            }
        }.resume()
    }

    /// Some public pages reject a non-JavaScript mobile client with 403 or
    /// render no article HTML. Jina's text reader returns a server-rendered
    /// plain-text representation of the same public page.
    private static func fetchReaderText(url: URL, completion: @escaping (String?) -> Void) {
        guard let readerURL = URL(string: "https://r.jina.ai/http://\(url.absoluteString)") else {
            completion(nil)
            return
        }
        var req = URLRequest(url: readerURL)
        req.httpMethod = "GET"
        req.setValue("text/plain, text/markdown;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, (200..<400).contains(code) else {
                completion(nil)
                return
            }
            let downloaded = data.count > maxDownloadBytes ? Data(data.prefix(maxDownloadBytes)) : data
            let text = String(data: downloaded, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            completion(text.count >= 80 ? capped(text, at: maxCharsPerPage) : nil)
        }.resume()
    }

    private static func isReaderAccessWall(_ text: String) -> Bool {
        let prefix = text.prefix(1_000).lowercased()
        return prefix.contains("安全验证")
            || prefix.contains("访问验证")
            || prefix.contains("captcha")
            || prefix.contains("verify you are human")
    }

    private static func decodeHTMLData(_ data: Data, response: HTTPURLResponse?) -> String {
        if let s = String(data: data, encoding: .utf8), looksLikeHTML(s) || s.count > 200 {
            return s
        }
        // Common for older CN sites.
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb18030)) {
            return s
        }
        if let header = response?.allHeaderFields["Content-Type"] as? String,
           header.lowercased().contains("gb"),
           let s = String(data: data, encoding: String.Encoding(rawValue: gb18030)) {
            return s
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func looksLikeHTML(_ s: String) -> Bool {
        let head = s.prefix(200).lowercased()
        return head.contains("<html") || head.contains("<!doctype") || head.contains("<head")
    }

    private static func extractReadableText(from html: String, maxChars: Int) -> String {
        var s = html
        // Drop noisy blocks first.
        let dropPatterns = [
            #"(?is)<script[^>]*>[\s\S]*?</script>"#,
            #"(?is)<style[^>]*>[\s\S]*?</style>"#,
            #"(?is)<noscript[^>]*>[\s\S]*?</noscript>"#,
            #"(?is)<svg[^>]*>[\s\S]*?</svg>"#,
            #"(?is)<!--[\s\S]*?-->"#,
            #"(?is)<nav[^>]*>[\s\S]*?</nav>"#,
            #"(?is)<footer[^>]*>[\s\S]*?</footer>"#,
            #"(?is)<header[^>]*>[\s\S]*?</header>"#
        ]
        for p in dropPatterns {
            s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }

        // Prefer <article> / <main> when present.
        if let article = firstMatch(s, pattern: #"(?is)<article[^>]*>([\s\S]*?)</article>"#), article.count > 200 {
            s = article
        } else if let main = firstMatch(s, pattern: #"(?is)<main[^>]*>([\s\S]*?)</main>"#), main.count > 200 {
            s = main
        }

        // Block-level tags → newlines so paragraphs survive.
        s = s.replacingOccurrences(
            of: #"(?is)</(p|div|br|li|h1|h2|h3|h4|tr|section|article)>"#,
            with: "\n",
            options: .regularExpression
        )
        s = s.replacingOccurrences(of: #"(?is)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = stripTags(s)
        s = decodeHTML(s)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)

        let lines = s
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard line.count >= 2 else { return false }
                // Drop ultra-short nav crumbs / cookie banners.
                let lower = line.lowercased()
                if lower.contains("cookie") || lower.contains("privacy policy") { return false }
                if lower.hasPrefix("javascript:") { return false }
                return true
            }

        var text = lines.joined(separator: "\n")
        if text.count > maxChars {
            let idx = text.index(text.startIndex, offsetBy: maxChars)
            text = String(text[..<idx]) + "…"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - Query / URL encoding

    private static func sanitizeQuery(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func percentEncodeQueryValue(_ value: String) -> String? {
        // Query/form values must use RFC 3986's unreserved ASCII characters.
        // `CharacterSet.alphanumerics` is broader on Apple platforms.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private static func makeGETURL(base: String, parameters: [String: String]) -> URL? {
        var parts: [String] = []
        for (name, value) in parameters {
            guard let en = percentEncodeQueryValue(name),
                  let ev = percentEncodeQueryValue(value) else { return nil }
            parts.append("\(en)=\(ev)")
        }
        let joined = parts.joined(separator: "&")
        if base.contains("?") {
            return URL(string: base + (base.hasSuffix("&") || base.hasSuffix("?") ? "" : "&") + joined)
        }
        return URL(string: base + "?" + joined)
    }

    private static func formBody(_ parameters: [String: String]) -> Data? {
        var parts: [String] = []
        for (name, value) in parameters {
            guard let en = percentEncodeQueryValue(name),
                  let ev = percentEncodeQueryValue(value) else { return nil }
            parts.append("\(en)=\(ev)")
        }
        return parts.joined(separator: "&").data(using: .utf8)
    }

    // MARK: - DuckDuckGo HTML

    private static func fetchDuckDuckGoHTML(query: String, completion: @escaping (Result<[Hit], Error>) -> Void) {
        guard let url = URL(string: "https://html.duckduckgo.com/html/"),
              let body = formBody(["q": query, "kl": "cn-zh"]) else {
            completion(.failure(SearchError.network("无效搜索 URL")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        applyBrowserHeaders(&req)
        req.timeoutInterval = 12

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(SearchError.network(error.localizedDescription)))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, let html = String(data: data, encoding: .utf8), (200..<300).contains(code) else {
                completion(.failure(SearchError.network("DuckDuckGo 请求失败 (\(code))")))
                return
            }
            completion(.success(parseDuckDuckGoHTML(html)))
        }.resume()
    }

    private static func parseDuckDuckGoHTML(_ html: String) -> [Hit] {
        let linkPattern = #"class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>|href="([^"]+)"[^>]*class="result__a"[^>]*>([\s\S]*?)</a>"#
        let snipPattern = #"class="result__snippet"[^>]*>([\s\S]*?)</(?:a|td|div)>"#

        let links = regexMatches(html, pattern: linkPattern)
        let snips = regexMatches(html, pattern: snipPattern)

        var hits: [Hit] = []
        for (i, link) in links.enumerated() {
            let rawURL: String
            let titleHTML: String
            if link.count >= 5, !link[3].isEmpty {
                rawURL = decodeHTML(link[3])
                titleHTML = decodeHTML(link[4])
            } else if link.count >= 3 {
                rawURL = decodeHTML(link[1])
                titleHTML = decodeHTML(link[2])
            } else {
                continue
            }
            let title = stripTags(titleHTML).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = unwrapDDGRedirect(rawURL)
            var snippet = ""
            if i < snips.count, snips[i].count >= 2 {
                snippet = normalizeWhitespace(stripTags(decodeHTML(snips[i][1])))
            }
            if title.isEmpty && snippet.isEmpty { continue }
            hits.append(Hit(title: title.isEmpty ? url : title, url: url, snippet: snippet))
            if hits.count >= 8 { break }
        }
        return hits
    }

    // MARK: - Bing HTML

    private static func fetchBingHTML(query: String, completion: @escaping (Result<[Hit], Error>) -> Void) {
        guard let url = makeGETURL(
            // `cn.bing.com` redirects to a request with `mkt=zh-CN`. Bing's
            // CN-market SERP can incorrectly reduce Chinese multi-character
            // topics (such as “二次元” / “亚文化”) to their first character.
            // The global endpoint preserves the complete query.
            base: "https://www.bing.com/search",
            parameters: ["q": query, "format": "rss"]
        ) else {
            completion(.failure(SearchError.network("无效 Bing URL")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyBrowserHeaders(&req)
        req.setValue("application/rss+xml, application/xml;q=0.9, text/xml;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 12

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(SearchError.network(error.localizedDescription)))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, let html = String(data: data, encoding: .utf8), (200..<300).contains(code) else {
                completion(.failure(SearchError.network("Bing 请求失败 (\(code))")))
                return
            }
            let rssHits = parseBingRSS(html)
            // Some regional/CDN responses ignore `format=rss` and return the
            // rendered search page instead. Accept both representations.
            completion(.success(rssHits.isEmpty ? parseBingHTML(html) : rssHits))
        }.resume()
    }

    /// Bing's rendered HTML differs by client, experiment, and locale. Its
    /// RSS response is a stable result feed and avoids relying on `b_algo`
    /// classes that can be absent in the iPad response.
    private static func parseBingRSS(_ xml: String) -> [Hit] {
        let itemBlocks = regexMatches(xml, pattern: #"<item[^>]*>([\s\S]*?)</item>"#)
        func element(_ name: String, in block: String) -> String {
            guard let match = regexMatches(
                block,
                pattern: "<\(name)[^>]*>([\\s\\S]*?)</\(name)>"
            ).first,
            match.count >= 2 else {
                return ""
            }
            return match[1]
                .replacingOccurrences(of: "<![CDATA[", with: "")
                .replacingOccurrences(of: "]]>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var hits: [Hit] = []
        for item in itemBlocks {
            guard item.count >= 2 else { continue }
            let block = item[1]
            let title = normalizeWhitespace(stripTags(decodeHTML(element("title", in: block))))
            let url = decodeHTML(element("link", in: block))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = normalizeWhitespace(stripTags(decodeHTML(element("description", in: block))))
            guard url.hasPrefix("http"), !title.isEmpty else { continue }
            hits.append(Hit(title: title, url: url, snippet: snippet))
            if hits.count >= 8 { break }
        }
        return hits
    }

    private static func parseBingHTML(_ html: String) -> [Hit] {
        let blocks = regexMatches(html, pattern: #"<li class="b_algo"[\s\S]*?</li>"#)
        var hits: [Hit] = []
        for block in blocks {
            guard let raw = block.first else { continue }
            let link = regexMatches(raw, pattern: #"<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#).first
                ?? regexMatches(raw, pattern: #"<a[^>]*href="([^"]+)"[^>]*h="ID=SERP[^"]*"[^>]*>([\s\S]*?)</a>"#).first
            guard let link = link, link.count >= 3 else { continue }
            let url = decodeHTML(link[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = normalizeWhitespace(stripTags(decodeHTML(link[2])))
            var snippet = ""
            if let sn = regexMatches(raw, pattern: #"<p[^>]*>([\s\S]*?)</p>"#).first, sn.count >= 2 {
                snippet = normalizeWhitespace(stripTags(decodeHTML(sn[1])))
            }
            guard url.hasPrefix("http"), !title.isEmpty else { continue }
            let host = (URL(string: url)?.host ?? "").lowercased()
            if host.contains("bing.com"), !url.contains("/ck/") { continue }
            if host.contains("microsoft.com") || host.contains("microsoftonline.com") { continue }
            hits.append(Hit(title: title, url: url, snippet: snippet))
            if hits.count >= 8 { break }
        }
        return hits
    }

    // MARK: - Baidu HTML

    private static func fetchBaiduHTML(query: String, completion: @escaping (Result<[Hit], Error>) -> Void) {
        guard let url = makeGETURL(base: "https://www.baidu.com/s", parameters: ["wd": query, "ie": "utf-8"]) else {
            completion(.failure(SearchError.network("无效百度 URL")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyBrowserHeaders(&req)
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 12

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(SearchError.network(error.localizedDescription)))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data,
                  let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii),
                  (200..<300).contains(code) else {
                completion(.failure(SearchError.network("百度请求失败 (\(code))")))
                return
            }
            completion(.success(parseBaiduHTML(html)))
        }.resume()
    }

    private static func parseBaiduHTML(_ html: String) -> [Hit] {
        let linkPattern = #"<h3[^>]*class="[^"]*(?:c-title|t)[^"]*"[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#
        let links = regexMatches(html, pattern: linkPattern)
        var hits: [Hit] = []
        for link in links {
            guard link.count >= 3 else { continue }
            var url = decodeHTML(link[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if url.hasPrefix("//") { url = "https:" + url }
            let title = normalizeWhitespace(stripTags(decodeHTML(link[2])))
            guard url.hasPrefix("http"), !title.isEmpty else { continue }
            hits.append(Hit(title: title, url: url, snippet: ""))
            if hits.count >= 8 { break }
        }
        return hits
    }

    // MARK: - Helpers

    private static func applyBrowserHeaders(_ req: inout URLRequest) {
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    }

    private static func rankHits(
        _ hits: [Hit],
        query: String,
        weightedTerms: [WeightedTerm]
    ) -> [Hit] {
        let terms = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        let compactQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        func score(_ hit: Hit) -> Int {
            let title = hit.title.lowercased()
            let snippet = hit.snippet.lowercased()
            let sourceText = title + " " + snippet
            var value = 0
            if !compactQuery.isEmpty {
                if title.contains(compactQuery) { value += 6 }
                if snippet.contains(compactQuery) { value += 3 }
            }
            for term in terms {
                if title.contains(term) { value += 2 }
                if snippet.contains(term) { value += 1 }
            }
            if !hit.snippet.isEmpty { value += 1 }
            for weighted in weightedTerms {
                let term = weighted.term.lowercased()
                if title.contains(term) { value += weighted.weight * 8 }
                if snippet.contains(term) { value += weighted.weight * 4 }
            }
            let explanatoryMarkers = [
                "定义", "起源", "发展", "历史", "研究", "论文", "报告",
                "解释", "分析", "背景", "影响"
            ]
            if explanatoryMarkers.contains(where: { sourceText.contains($0) }) {
                value += 4
            }
            let playbackMarkers = [
                "在线观看", "在线播放", "播放", "番剧", "全集", "高清视频免费"
            ]
            if playbackMarkers.contains(where: { sourceText.contains($0) }) {
                value -= 10
            }
            if isPlaybackPlatform(hit.url) {
                value -= 12
            }
            return value
        }

        return hits.enumerated()
            .sorted { lhs, rhs in
                let ls = score(lhs.element)
                let rs = score(rhs.element)
                if ls != rs { return ls > rs }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func passesWeightFilter(_ hit: Hit, weightedTerms: [WeightedTerm]) -> Bool {
        guard !weightedTerms.isEmpty else { return true }
        let text = (hit.title + " " + hit.snippet).lowercased()
        let highWeightTerms = weightedTerms.filter { $0.weight >= 4 }
        if highWeightTerms.contains(where: { text.contains($0.term.lowercased()) }) {
            return true
        }
        let matchedWeight = weightedTerms.reduce(0) { total, weighted in
            text.contains(weighted.term.lowercased()) ? total + weighted.weight : total
        }
        return matchedWeight >= 5
    }

    private static func isPlaybackPlatform(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        let platforms = [
            "bilibili.com", "acfun.cn", "iqiyi.com", "youku.com", "mgtv.com",
            "v.qq.com", "tencentvideo.com", "douyin.com", "kuaishou.com"
        ]
        return platforms.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Reject SERP rows that are clearly for a truncated or unrelated query.
    /// This matters especially for Chinese: a result for just "二" must not
    /// be accepted for "二次元文化起源与发展历程".
    private static func relevantHits(_ hits: [Hit], for query: String) -> [Hit] {
        let compactQuery = searchableCharacters(in: query)
        guard compactQuery.count >= 3 else { return hits }

        let requiredRun = compactQuery.count >= 8 ? 3 : 2
        return hits.filter { hit in
            let candidate = searchableCharacters(in: hit.title + " " + hit.snippet)
            guard !candidate.isEmpty else { return false }
            if candidate.contains(compactQuery) { return true }
            return longestCommonRun(compactQuery, candidate) >= requiredRun
        }
    }

    private static func searchableCharacters(in text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func longestCommonRun(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(repeating: 0, count: b.count + 1)
        var best = 0
        for x in a {
            var current = Array(repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() where x == y {
                current[j + 1] = previous[j] + 1
                best = max(best, current[j + 1])
            }
            previous = current
        }
        return best
    }

    private static func mergeHits(sources: [[Hit]], limit: Int) -> [Hit] {
        var out: [Hit] = []
        var seen = Set<String>()
        func key(_ h: Hit) -> String {
            let u = h.url.lowercased()
            if !u.isEmpty { return u }
            return h.title.lowercased()
        }
        for list in sources {
            for hit in list {
                let k = key(hit)
                if seen.contains(k) { continue }
                seen.insert(k)
                out.append(hit)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    private static func regexMatches(_ text: String, pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, options: [], range: range).compactMap { match -> [String]? in
            var parts: [String] = []
            for i in 0..<match.numberOfRanges {
                let nr = match.range(at: i)
                if nr.location == NSNotFound {
                    parts.append("")
                    continue
                }
                guard let r = Range(nr, in: text) else { return nil }
                parts.append(String(text[r]))
            }
            return parts
        }
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func normalizeWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTML(_ s: String) -> String {
        var t = s
        let map = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " "
        ]
        for (k, v) in map {
            t = t.replacingOccurrences(of: k, with: v)
        }
        if let re = try? NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#) {
            let ns = t as NSString
            let matches = re.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                let hex = ns.substring(with: m.range(at: 1))
                if let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) {
                    t = (t as NSString).replacingCharacters(in: m.range, with: String(Character(scalar)))
                }
            }
        }
        if let re = try? NSRegularExpression(pattern: #"&#([0-9]+);"#) {
            let ns = t as NSString
            let matches = re.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                let num = ns.substring(with: m.range(at: 1))
                if let value = UInt32(num), let scalar = UnicodeScalar(value) {
                    t = (t as NSString).replacingCharacters(in: m.range, with: String(Character(scalar)))
                }
            }
        }
        return t
    }

    private static func unwrapDDGRedirect(_ raw: String) -> String {
        if let r = raw.range(of: "uddg=") {
            let enc = String(raw[r.upperBound...]).split(separator: "&").first.map(String.init) ?? ""
            if let decoded = enc.removingPercentEncoding, decoded.hasPrefix("http") {
                return decoded
            }
        }
        if raw.hasPrefix("//") { return "https:" + raw }
        return raw
    }
}
