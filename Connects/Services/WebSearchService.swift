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

    private static let maxPagesToRead = 2
    private static let maxCharsPerPage = 1800
    private static let maxDownloadBytes = 300_000
    private static let maxInjectedEvidenceChars = 8_000
    private static let maxPlannedQueries = 2

    /// Ask the model to turn conversation context into concrete search queries.
    /// Follow-ups like "那这个呢" should resolve against prior turns, not be searched verbatim.
    static func planSearchQueries(
        contextMessages: [ChatMessage],
        model: AIModelOption,
        fallbackQuery: String,
        completion: @escaping ([String]) -> Void
    ) {
        let fallback = sanitizeQuery(fallbackQuery)
        let transcript = compactTranscript(contextMessages, maxChars: 3_500)
        guard !transcript.isEmpty else {
            DispatchQueue.main.async {
                completion(fallback.isEmpty ? [] : [fallback])
            }
            return
        }

        let prompt = ChatMessage(
            role: .user,
            content: """
            你是聊天应用的联网检索规划器。根据下方对话，为「最新一条用户消息」写出 1–\(maxPlannedQueries) 条适合搜索引擎的检索词。

            要求：
            - 必须结合前文消解指代（如「他呢」「那这个」「为什么」），写成具体实体 / 事件 / 问题，不要原样照抄模糊追问。
            - 用户用中文时优先写中文检索词；专有名词可保留原文。
            - 每条检索词一行，短而可搜；不要编号、引号、解释或其它文字。
            - 若完全不需要联网，只输出：NONE

            【对话】
            \(transcript)
            """
        )

        APIClient.shared.complete(messages: [prompt], model: model, maxTokens: 120) { result in
            switch result {
            case .success(let raw):
                let planned = parsePlannedQueries(raw)
                if planned.isEmpty {
                    completion(fallback.isEmpty ? [] : [fallback])
                } else {
                    completion(planned)
                }
            case .failure:
                completion(fallback.isEmpty ? [] : [fallback])
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
        searchAndFormat(queries: [query], onStatus: onStatus, completion: completion)
    }

    /// Search using one or more planned queries, then browse and format evidence.
    static func searchAndFormat(
        queries: [String],
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
            let hits = rankHits(mergeHits(sources: allSources, limit: 10), query: rankKey)
            guard !hits.isEmpty else {
                DispatchQueue.main.async {
                    completion(.failure(lastError ?? SearchError.noResults))
                }
                return
            }

            let toBrowse = pickBrowseTargets(from: hits, limit: maxPagesToRead)
            DispatchQueue.main.async { onStatus?("正在阅读网页…") }

            fetchPages(toBrowse) { pages in
                let evidence = formatEvidence(queries: qs, hits: hits, pages: pages)
                let process = formatProcessLog(queries: qs, hits: hits, pages: pages)
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
        let group = DispatchGroup()
        var ddgHits: [Hit] = []
        var bingHits: [Hit] = []
        var baiduHits: [Hit] = []
        var lastError: Error?

        group.enter()
        fetchDuckDuckGoHTML(query: query) { result in
            switch result {
            case .success(let hits): ddgHits = hits
            case .failure(let err): lastError = err
            }
            group.leave()
        }

        group.enter()
        fetchBingHTML(query: query) { result in
            switch result {
            case .success(let hits): bingHits = hits
            case .failure(let err):
                if lastError == nil { lastError = err }
            }
            group.leave()
        }

        group.enter()
        fetchBaiduHTML(query: query) { result in
            switch result {
            case .success(let hits): baiduHits = hits
            case .failure(let err):
                if lastError == nil { lastError = err }
            }
            group.leave()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            let merged = mergeHits(sources: [ddgHits, bingHits, baiduHits], limit: 8)
            completion(merged, lastError)
        }
    }

    private static func parsePlannedQueries(_ raw: String) -> [String] {
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
            .filter { !$0.isEmpty }

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
            The app planned search queries from the full conversation (including prior turns), then fetched the web evidence below for the latest user question.
            Use it only when it is relevant. Answer the user directly; do not describe the search process.
            If the evidence is insufficient or conflicts, say so plainly and do not invent facts.
            When citing sources, put at most 5 links at the end under "### 参考来源" as a sequential numbered list:
            1. [短标题](https://...)
            2. [短标题](https://...)
            Renumber 1…n (do not keep body citation indices like [1]/[5]). Prefer short titles; never dump bare URLs alone.

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
        while ContextBuilder.estimatedChars(out) > budget {
            let lastUserIndex = out.lastIndex(where: { $0.role == .user }) ?? out.count
            if let dropIndex = out.indices.first(where: { $0 < lastUserIndex && out[$0].role != .system }) {
                out.remove(at: dropIndex)
                continue
            }

            guard let evidenceIndex = out.firstIndex(where: {
                $0.role == .system && $0.content.hasPrefix("[Web search context]")
            }) else {
                break
            }

            var evidence = out[evidenceIndex]
            let overflow = ContextBuilder.estimatedChars(out) - budget
            let keep = max(1_200, evidence.content.count - overflow - 200)
            guard keep < evidence.content.count else { break }
            evidence.content = String(evidence.content.prefix(keep))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n…[web evidence truncated to fit context budget]"
            out[evidenceIndex] = evidence
        }
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
            lines.append("（未能打开网页正文，请仅依据上方摘要谨慎作答，并说明资料有限。）")
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
            lines.append("网页正文：未能打开（仅依据摘要作答）。")
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

    // MARK: - Page fetch

    private static func fetchPages(_ hits: [Hit], completion: @escaping ([PageText]) -> Void) {
        guard !hits.isEmpty else {
            completion([])
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var pages: [PageText] = []

        for hit in hits {
            group.enter()
            fetchPageText(urlString: hit.url) { text in
                if let text = text, text.count >= 80 {
                    lock.lock()
                    pages.append(PageText(hit: hit, text: text))
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            // Keep original SERP order.
            let ordered = hits.compactMap { hit in pages.first(where: { $0.hit.url == hit.url }) }
            completion(ordered)
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
            completion(text.count >= 80 ? text : nil)
        }.resume()
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
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
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
            base: "https://cn.bing.com/search",
            parameters: ["q": query, "setlang": "zh-Hans", "mkt": "zh-CN"]
        ) else {
            completion(.failure(SearchError.network("无效 Bing URL")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyBrowserHeaders(&req)
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
            completion(.success(parseBingHTML(html)))
        }.resume()
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

    private static func rankHits(_ hits: [Hit], query: String) -> [Hit] {
        let terms = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        let compactQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        func score(_ hit: Hit) -> Int {
            let title = hit.title.lowercased()
            let snippet = hit.snippet.lowercased()
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
