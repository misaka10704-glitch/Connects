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

    struct SearchTarget {
        let name: String
        let domain: String?
        let query: String
        let reason: String?
        let directURL: String?
    }

    struct SearchPlan {
        let topic: String
        let targets: [SearchTarget]

        static func fallback(_ query: String) -> SearchPlan {
            let cleaned = WebSearchService.sanitizeQuery(query)
            guard !cleaned.isEmpty else {
                return SearchPlan(topic: "", targets: [])
            }
            return SearchPlan(topic: cleaned, targets: heuristicTargets(for: cleaned))
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
    private static let maxPlannedQueries = 3
    private static let minQualifiedHits = 2
    private static let minHitScoreToKeep = 8
    /// DuckDuckGo rate-limits under burst traffic — one SERP at a time, few retries.
    private static let serpGate = DispatchSemaphore(value: 1)
    private static let serpRetryLimit = 2
    private static let trustedSourceHosts = [
        "baike.baidu.com", "zhihu.com", "wikipedia.org", "douban.com",
        "thepaper.cn", "edu.cn", "cnki.net", "huxiu.com", "36kr.com", "caixin.com"
    ]
    private static let blockedPlannerDomains = [
        "gov.cn", "www.gov.cn", "china.com.cn", "www.china.com.cn",
        "people.com.cn", "xinhuanet.com", "www.xinhuanet.com", "cctv.com", "news.cn"
    ]
    private static let topicStopwords: Set<String> = [
        "中国", "我国", "国内", "中华", "人民", "共和国", "国家", "大陆",
        "怎么", "如何", "为什么", "什么", "哪些", "怎样", "为何", "是否",
        "发展", "起来", "过程", "历程", "历史", "背景", "现状", "起源",
        "请问", "介绍", "讲解", "分析", "浅谈", "概述", "关于", "一下",
        "文化", "讨论", "产业", "行业"
    ]
    private static let cultureTopicMarkers = [
        "二次元", "ACG", "动漫", "亚文化", "御宅", "漫画", "游戏", "番剧", "同人"
    ]
    private static let geographyHitMarkers = [
        "七大洲", "大陆板块", "地理", "环太平洋", "地壳", "板块", "独特之处",
        "美洲", "非洲", "欧洲", "亚洲", "划分", "地球"
    ]
    private static let lowQualityHosts = [
        "toutiao.com", "baijiahao.baidu.com", "haokan.baidu.com", "uc.cn", "ufcn.cn",
        "qsllyof.cn", "tpjpuiv.cn", "tieba.baidu.com", "calculatorsoup.com",
        "calculator.net", "mathway.com", "theonlinecalculator.com", "web2.0calc.com",
        "w3calc.com", "tailscale.com", "bestbuy.com"
    ]
    private static let officialTopicMarkers = [
        "政策", "法规", "条例", "国务院", "政府", "两会", "白皮书", "公文",
        "社保", "公积金", "签证", "刑法", "宪法", "法律", "行政", "机关"
    ]
    private static let junkContentMarkers = [
        "免费观看", "高清电影", "影视大全", "在线播放", "免费在线", "电影免费",
        "电视剧", "综艺", "动漫在线", "番剧", "种子", "磁力", "博彩", "赌博",
        "cosplay 视频与亚文化", "动漫频道 - 二次元", "install tailscale", "math calculator"
    ]

    /// Ask the model where to look up the latest user question, then search those sites.
    static func planSearch(
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
            你是聊天应用的联网检索规划器。根据下方对话，为「最新一条用户消息」推荐 2–\(maxPlannedQueries) 个**适合查证该问题**的网站或资料来源，并给出检索词。

            要求：
            - 必须结合前文消解指代（如「他呢」「那这个」「为什么」），写成具体实体 / 事件 / 问题，不要原样照抄模糊追问。
            - topic 写成 6–18 字的问题核心（保留主题词），不要整句问话。
            - 优先推荐能给出定义、历史脉络、分析或可靠讨论的来源：百度百科、维基百科、知乎、豆瓣、行业媒体、高校站点等。
            - domain 仅表示偏好来源（应用会在开放检索结果中优先这些站），不要假设会强制 site: 检索。
            - 只有当用户明确询问政策、法规、政府文件、政务办理时，才可推荐 gov.cn / 中国政府网；文化、娱乐、亚文化、兴趣爱好、技术、生活类问题**禁止**推荐政府门户、人民网时政、中国网时政、央视时政。
            - 每个来源的 query 必须保留问题的**主题词**（如「二次元文化」「御宅族」「ACG」），不要只剩「中国」「我国」「大陆」等国家/地理泛称。
            - **禁止**用「大陆」指代中国大陆；请写「中国」或直接写主题词。地理问题除外。
            - 禁止推荐：免费观影/盗版资源站、影视聚合站、动漫在线播放站、下载站、购物导购。
            - 每个来源输出：
              - name：站点名称（如「百度百科」）
              - domain：域名（如 baike.baidu.com、zhihu.com）
              - query：在该站内搜索的具体词（8–24 字，保留问题主体）
              - reason：一句话说明为何查这里
              - directURL：可选，若你非常确定某条百科/专题页可直接给出完整 URL
            - 只输出合法 JSON，不要 Markdown、解释或其它文字：
              {"topic":"问题摘要","targets":[{"name":"百度百科","domain":"baike.baidu.com","query":"二次元文化","reason":"定义与背景"}]}
            - 若完全不需要联网，只输出：{"topic":"","targets":[]}

            【对话】
            \(transcript)
            """
        )

        APIClient.shared.complete(messages: [prompt], model: model, maxTokens: 360) { result in
            switch result {
            case .success(let raw):
                completion(parseSearchPlan(raw, fallback: fallback))
            case .failure:
                completion(SearchPlan.fallback(fallback))
            }
        }
    }

    /// Legacy entry — single open-web query.
    static func searchAndFormat(
        query: String,
        onStatus: ((String) -> Void)? = nil,
        completion: @escaping (Result<SearchBundle, Error>) -> Void
    ) {
        searchAndFormat(plan: SearchPlan.fallback(query), onStatus: onStatus, completion: completion)
    }

    /// Search recommended sources, open top pages, and format evidence.
    static func searchAndFormat(
        plan: SearchPlan,
        onStatus: ((String) -> Void)? = nil,
        completion: @escaping (Result<SearchBundle, Error>) -> Void
    ) {
        let targets = Array(plan.targets.prefix(maxPlannedQueries))
        guard !targets.isEmpty else {
            DispatchQueue.main.async { completion(.failure(SearchError.emptyQuery)) }
            return
        }

        let topicQuery = sanitizePlannerQuery(
            focusTopicPhrase(plan.topic.isEmpty ? (targets.first?.query ?? "") : plan.topic),
            topic: plan.topic
        )
        DispatchQueue.main.async {
            let label = topicQuery.isEmpty ? "正在搜索…" : "正在搜索：\(topicQuery)"
            onStatus?(label)
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var allSources: [[Hit]] = []
        var lastError: Error?

        // Lean strategy: ONE open-web SERP + planner directURLs + Wikipedia.
        // Avoid per-domain site: bursts (they hammer DuckDuckGo into 403 and
        // Bing often ignores site: anyway). Domain prefs are applied in ranking.
        if !topicQuery.isEmpty {
            group.enter()
            fetchAllEngines(query: topicQuery) { hits, error in
                lock.lock()
                if !hits.isEmpty { allSources.append(hits) }
                if let error = error, lastError == nil { lastError = error }
                lock.unlock()
                group.leave()
            }
        }

        for target in targets {
            if let direct = normalizedDirectURL(target.directURL) {
                lock.lock()
                allSources.append([
                    Hit(
                        title: target.name.isEmpty ? direct : target.name,
                        url: direct,
                        snippet: target.reason ?? target.query
                    )
                ])
                lock.unlock()
            }
        }

        if !topicQuery.isEmpty {
            group.enter()
            fetchWikipediaHits(queries: wikipediaQueryCandidates(from: topicQuery)) { wikiHits in
                lock.lock()
                if !wikiHits.isEmpty { allSources.append(wikiHits) }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            finishSearch(
                plan: plan,
                targets: targets,
                allSources: allSources,
                lastError: lastError,
                onStatus: onStatus,
                completion: completion
            )
        }
    }

    private static func finishSearch(
        plan: SearchPlan,
        targets: [SearchTarget],
        allSources: [[Hit]],
        lastError: Error?,
        onStatus: ((String) -> Void)? = nil,
        completion: @escaping (Result<SearchBundle, Error>) -> Void
    ) {
        let topic = plan.topic.isEmpty ? targets.first?.query ?? "" : plan.topic
        let hits = qualifiedHits(from: allSources, plan: plan, targets: targets, topic: topic)
        // Fail fast: retry only when completely empty — do not burn SERP quota
        // chasing a second weak hit.
        if hits.isEmpty {
            let retryTopic = sanitizePlannerQuery(focusTopicPhrase(topic), topic: topic)
            let retryGroup = DispatchGroup()
            let retryLock = NSLock()
            var retrySources: [[Hit]] = []
            var retryError = lastError
            if !retryTopic.isEmpty {
                retryGroup.enter()
                fetchAllEngines(query: retryTopic) { fetched, error in
                    retryLock.lock()
                    if !fetched.isEmpty { retrySources.append(fetched) }
                    if let error = error, retryError == nil { retryError = error }
                    retryLock.unlock()
                    retryGroup.leave()
                }
                retryGroup.enter()
                fetchWikipediaHits(queries: wikipediaQueryCandidates(from: retryTopic)) { wiki in
                    retryLock.lock()
                    if !wiki.isEmpty { retrySources.append(wiki) }
                    retryLock.unlock()
                    retryGroup.leave()
                }
            }
            retryGroup.notify(queue: .global(qos: .userInitiated)) {
                let mergedHits = qualifiedHits(
                    from: allSources + retrySources,
                    plan: plan,
                    targets: targets,
                    topic: topic
                )
                deliverSearchResults(
                    plan: plan,
                    targets: targets,
                    hits: mergedHits,
                    lastError: retryError,
                    onStatus: onStatus,
                    completion: completion
                )
            }
            return
        }
        deliverSearchResults(
            plan: plan,
            targets: targets,
            hits: hits,
            lastError: lastError,
            onStatus: onStatus,
            completion: completion
        )
    }

    private static func qualifiedHits(
        from sources: [[Hit]],
        plan: SearchPlan,
        targets: [SearchTarget],
        topic: String
    ) -> [Hit] {
        let focusedQueries = targets.map { sanitizePlannerQuery($0.query, topic: topic) }.filter { !$0.isEmpty }
        let merged = mergeHits(sources: sources, limit: 40)
            .filter { !isJunkHit($0) }
            .filter { !shouldBlockOfficialHit($0, topic: topic) }
            .filter { !isWrongSenseHit($0, topic: topic) }
            .filter { isTopicRelevantHit($0, topic: topic) }
        let queryPool = poolRelevantToQueries(merged, topic: topic, queries: focusedQueries)
        let rankedHits = rankHits(queryPool, topic: topic, targets: targets)
        let candidates = selectQualifiedHits(
            rankedHits,
            topic: topic,
            targetQueries: focusedQueries
        )
        let informativeHits = candidates.filter { !isPlaybackPlatform($0.url) }
        return informativeHits.isEmpty ? candidates : informativeHits
    }

    private static func deliverSearchResults(
        plan: SearchPlan,
        targets: [SearchTarget],
        hits: [Hit],
        lastError: Error?,
        onStatus: ((String) -> Void)?,
        completion: @escaping (Result<SearchBundle, Error>) -> Void
    ) {
        let topic = plan.topic.isEmpty ? targets.first?.query ?? "" : plan.topic
        guard !hits.isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(lastError ?? SearchError.noResults))
            }
            return
        }

        let toBrowse = pickBrowseTargets(from: hits, limit: maxPageCandidates)
        DispatchQueue.main.async {
            onStatus?("找到 \(hits.count) 条结果，开始阅读 \(toBrowse.count) 个网页…")
        }

        fetchPages(toBrowse, onProgress: { line in
            DispatchQueue.main.async { onStatus?(line) }
        }) { pages, _ in
            let usableHits = hits
                .filter { !isExcludedResultHost($0.url) && !isJunkHit($0) }
                .filter { !shouldBlockOfficialHit($0, topic: topic) }
                .filter { !isWrongSenseHit($0, topic: topic) }
                .filter { isTopicRelevantHit($0, topic: topic) }
            guard !usableHits.isEmpty else {
                DispatchQueue.main.async {
                    completion(.failure(SearchError.noResults))
                }
                return
            }
            let evidence = formatEvidence(plan: plan, hits: usableHits, pages: pages)
            let process = formatProcessLog(plan: plan, hits: usableHits, pages: pages)
            DispatchQueue.main.async {
                if evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completion(.failure(lastError ?? SearchError.noResults))
                } else {
                    completion(.success(SearchBundle(evidenceBlock: evidence, processLog: process)))
                }
            }
        }
    }

    /// Deprecated — use `searchAndFormat(plan:)`.
    static func searchAndFormat(
        queries: [String],
        onStatus: ((String) -> Void)? = nil,
        completion: @escaping (Result<SearchBundle, Error>) -> Void
    ) {
        let topic = queries.first ?? ""
        let targets = queries.map {
            SearchTarget(name: "开放检索", domain: nil, query: $0, reason: nil, directURL: nil)
        }
        searchAndFormat(plan: SearchPlan(topic: topic, targets: targets), onStatus: onStatus, completion: completion)
    }

    private static func heuristicTargets(for topic: String) -> [SearchTarget] {
        let focused = sanitizePlannerQuery(focusTopicPhrase(topic), topic: topic)
        return [
            SearchTarget(
                name: "百度百科",
                domain: "baike.baidu.com",
                query: focused,
                reason: "定义与背景",
                directURL: nil
            ),
            SearchTarget(
                name: "知乎",
                domain: "zhihu.com",
                query: focused,
                reason: "讨论与分析",
                directURL: nil
            ),
            SearchTarget(
                name: "维基百科",
                domain: "zh.wikipedia.org",
                query: focused,
                reason: "概念与脉络",
                directURL: nil
            )
        ]
    }

    private static func buildSearchQuery(for target: SearchTarget) -> String {
        let q = sanitizePlannerQuery(target.query, topic: target.query)
        guard !q.isEmpty else { return "" }
        if let domain = normalizeDomain(target.domain) {
            return "site:\(domain) \(q)"
        }
        return q
    }

    private static func normalizeDomain(_ raw: String?) -> String? {
        guard var domain = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !domain.isEmpty else { return nil }
        if domain.hasPrefix("http://") || domain.hasPrefix("https://") {
            domain = URL(string: domain)?.host?.lowercased() ?? domain
        }
        domain = domain.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return domain.isEmpty ? nil : domain
    }

    private static func normalizedDirectURL(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("http://") || raw.hasPrefix("https://") else { return nil }
        return raw
    }

    private static func fetchAllEngines(query: String, completion: @escaping ([Hit], Error?) -> Void) {
        // Serialize SERP traffic. Parallel site: bursts get DuckDuckGo 403s and
        // leave only polluted Bing rows that fail relevance filters.
        DispatchQueue.global(qos: .userInitiated).async {
            serpGate.wait()
            fetchAllEnginesUngated(query: query) { hits, error in
                serpGate.signal()
                completion(hits, error)
            }
        }
    }

    private static func fetchAllEnginesUngated(query: String, completion: @escaping ([Hit], Error?) -> Void) {
        // cn.bing.com frequently returns spam / wrong-sense rows for CJK.
        // DuckDuckGo is primary; Bing only contributes on-topic rows.
        let group = DispatchGroup()
        let lock = NSLock()
        var ddgHits: [Hit] = []
        var bingHits: [Hit] = []
        var lastError: Error?
        let topicHint = openWebQuery(from: query)

        group.enter()
        fetchDuckDuckGoHTML(query: query, attempt: 1) { result in
            lock.lock()
            switch result {
            case .success(let hits):
                ddgHits = hits
            case .failure(let error):
                if lastError == nil { lastError = error }
            }
            lock.unlock()
            group.leave()
        }

        group.enter()
        fetchBingHTML(query: query) { result in
            lock.lock()
            switch result {
            case .success(let hits):
                bingHits = hits
            case .failure(let error):
                if lastError == nil { lastError = error }
            }
            lock.unlock()
            group.leave()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            let merged = mergeEngineHits(
                primary: ddgHits,
                secondary: bingHits,
                topicHint: topicHint,
                siteDomain: siteConstraint(in: query)
            )
            finishEngineFetch(merged, lastError: lastError, completion: completion)
        }
    }

    private static func finishEngineFetch(
        _ hits: [Hit],
        lastError: Error?,
        completion: @escaping ([Hit], Error?) -> Void
    ) {
        let usable = hits
            .filter { !isExcludedResultHost($0.url) }
            .filter { !isJunkHit($0) }
        completion(Array(usable.prefix(8)), usable.isEmpty ? lastError : nil)
    }

    private static func mergeEngineHits(
        primary: [Hit],
        secondary: [Hit],
        topicHint: String,
        siteDomain: String?
    ) -> [Hit] {
        func accepted(_ hit: Hit, allowWeakPrimary: Bool) -> Bool {
            guard !isExcludedResultHost(hit.url), !isJunkHit(hit) else { return false }
            if let siteDomain = siteDomain, !hostMatchesDomain(hit.url, domain: siteDomain) {
                return false
            }
            if topicHint.isEmpty { return true }
            if isTopicRelevantHit(hit, topic: topicHint) { return true }
            // Never keep off-topic Bing/secondary rows. For DDG primary only,
            // allow encyclopedia paraphrases that already passed junk filters.
            return allowWeakPrimary && isEncyclopediaHost(hit.url)
        }

        var out: [Hit] = []
        var seen = Set<String>()
        for hit in primary where accepted(hit, allowWeakPrimary: true) {
            let key = hit.url.lowercased().isEmpty ? hit.title.lowercased() : hit.url.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(hit)
            if out.count >= 8 { break }
        }
        for hit in secondary where accepted(hit, allowWeakPrimary: false) {
            let key = hit.url.lowercased().isEmpty ? hit.title.lowercased() : hit.url.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(hit)
            if out.count >= 10 { break }
        }
        return out
    }

    private static func siteConstraint(in query: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"(?i)\bsite:([^\s]+)"#),
              let match = re.firstMatch(
                in: query,
                range: NSRange(query.startIndex..<query.endIndex, in: query)
              ),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: query) else {
            return nil
        }
        return normalizeDomain(String(query[range]))
    }

    private static func openWebQuery(from query: String) -> String {
        sanitizeQuery(
            query.replacingOccurrences(
                of: #"(?i)\bsite:[^\s]+\s*"#,
                with: "",
                options: .regularExpression
            )
        )
    }

    private static func hostMatchesDomain(_ urlString: String, domain: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        let d = domain.lowercased()
        return host == d || host.hasSuffix("." + d)
    }

    /// MediaWiki OpenSearch — no DuckDuckGo quota, good encyclopedia anchors.
    /// OpenSearch needs short lemmas; long planner topics return empty.
    private static func wikipediaQueryCandidates(from topic: String) -> [String] {
        let focused = focusTopicPhrase(topic)
        var out: [String] = []
        var seen = Set<String>()
        func add(_ value: String) {
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2, term.count <= 12, seen.insert(term.lowercased()).inserted else { return }
            out.append(term)
        }
        for marker in cultureTopicMarkers where focused.contains(marker) {
            add(marker)
        }
        for term in distinctiveTerms(in: focused).sorted(by: { $0.count < $1.count }) {
            add(term)
        }
        add(focusedSearchQuery(focused))
        add(focused)
        return Array(out.prefix(2))
    }

    private static func fetchWikipediaHits(queries: [String], completion: @escaping ([Hit]) -> Void) {
        let cleaned = queries.map { sanitizeQuery($0) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            completion([])
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var hits: [Hit] = []
        for query in cleaned {
            for lang in ["zh", "en"] {
                group.enter()
                fetchWikipediaOpenSearch(query: query, language: lang) { rows in
                    lock.lock()
                    hits.append(contentsOf: rows)
                    lock.unlock()
                    group.leave()
                }
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            var seen = Set<String>()
            let unique = hits.filter { hit in
                let key = hit.url.lowercased()
                return seen.insert(key).inserted
            }
            completion(Array(unique.prefix(8)))
        }
    }

    private static func fetchWikipediaHits(query: String, completion: @escaping ([Hit]) -> Void) {
        fetchWikipediaHits(queries: wikipediaQueryCandidates(from: query), completion: completion)
    }

    private static func fetchWikipediaOpenSearch(
        query: String,
        language: String,
        completion: @escaping ([Hit]) -> Void
    ) {
        guard let url = makeGETURL(
            base: "https://\(language).wikipedia.org/w/api.php",
            parameters: [
                "action": "opensearch",
                "search": query,
                "limit": "5",
                "namespace": "0",
                "format": "json"
            ]
        ) else {
            completion([])
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ConnectsSearch/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, (200..<300).contains(code),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count >= 4,
                  let titles = json[1] as? [String],
                  let descs = json[2] as? [String],
                  let urls = json[3] as? [String] else {
                completion([])
                return
            }
            var out: [Hit] = []
            for i in 0..<min(titles.count, urls.count) {
                let title = titles[i].trimmingCharacters(in: .whitespacesAndNewlines)
                let link = urls[i].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, link.hasPrefix("http") else { continue }
                let snip = i < descs.count ? descs[i] : ""
                out.append(Hit(title: title, url: link, snippet: snip))
            }
            completion(out)
        }.resume()
    }

    private struct SearchPlanPayload: Decodable {
        struct Target: Decodable {
            let name: String?
            let domain: String?
            let query: String?
            let reason: String?
            let directURL: String?
            let url: String?
        }

        struct Weight: Decodable {
            let term: String
            let weight: Int
        }

        let topic: String?
        let targets: [Target]?
        let queries: [String]?
        let weights: [Weight]?
    }

    private static func parseSearchPlan(_ raw: String, fallback: String) -> SearchPlan {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONDecoder().decode(SearchPlanPayload.self, from: data) {
            let topic = sanitizeQuery(payload.topic ?? fallback)
            let targets = normalizedTargets(payload.targets, fallbackTopic: topic.isEmpty ? fallback : topic)
            if !targets.isEmpty {
                return SearchPlan(topic: topic.isEmpty ? fallback : topic, targets: targets)
            }
            let legacyQueries = normalizedQueries(payload.queries ?? [], fallback: fallback)
            if !legacyQueries.isEmpty {
                return SearchPlan(
                    topic: topic.isEmpty ? legacyQueries[0] : topic,
                    targets: legacyQueries.map {
                        SearchTarget(name: "开放检索", domain: nil, query: $0, reason: nil, directURL: nil)
                    }
                )
            }
        }

        let lines = parsePlannedQueries(raw, fallback: fallback)
        if !lines.isEmpty {
            return SearchPlan(
                topic: lines[0],
                targets: lines.map {
                    SearchTarget(name: "开放检索", domain: nil, query: $0, reason: nil, directURL: nil)
                }
            )
        }
        return SearchPlan.fallback(fallback)
    }

    private static func normalizedTargets(_ raw: [SearchPlanPayload.Target]?, fallbackTopic: String) -> [SearchTarget] {
        guard let raw = raw else { return [] }
        var seen = Set<String>()
        return raw.compactMap { item -> SearchTarget? in
            let query = sanitizePlannerQuery(sanitizeQuery(item.query ?? fallbackTopic), topic: fallbackTopic)
            guard !query.isEmpty else { return nil }
            let domain = normalizeDomain(item.domain)
            if let domain = domain, isBlockedPlannerDomain(domain), !topicNeedsOfficialSources(fallbackTopic) {
                return nil
            }
            let name = sanitizeQuery(item.name ?? domain ?? "推荐来源")
            let key = (domain ?? name) + "|" + query.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return SearchTarget(
                name: name.isEmpty ? "推荐来源" : name,
                domain: domain,
                query: query,
                reason: item.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
                directURL: normalizedDirectURL(item.directURL ?? item.url)
            )
        }
        .prefix(maxPlannedQueries)
        .map { $0 }
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

    private static func formatEvidence(plan: SearchPlan, hits: [Hit], pages: [PageText]) -> String {
        var lines: [String] = []
        lines.append("问题：\(plan.topic)")
        lines.append("")
        lines.append("【推荐查证来源】")
        for (i, target) in plan.targets.enumerated() {
            var row = "\(i + 1). \(target.name)"
            if let domain = target.domain { row += " (\(domain))" }
            lines.append(row)
            lines.append("   检索：\(target.query)")
            if let reason = target.reason, !reason.isEmpty {
                lines.append("   原因：\(reason)")
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

    private static func formatProcessLog(plan: SearchPlan, hits: [Hit], pages: [PageText]) -> String {
        var lines: [String] = []
        lines.append("根据对话上下文推荐查证来源，并在对应站点定向检索。")
        lines.append("")
        lines.append("推荐查证来源：")
        for (i, target) in plan.targets.enumerated() {
            var row = "\(i + 1). \(target.name)"
            if let domain = target.domain { row += " (\(domain))" }
            lines.append(row)
            lines.append("   检索：\(target.query)")
            if let reason = target.reason, !reason.isEmpty {
                lines.append("   原因：\(reason)")
            }
            if let url = target.directURL, !url.isEmpty {
                lines.append("   直达：\(url)")
            }
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

    private static func formatEvidence(queries: [String], hits: [Hit], pages: [PageText]) -> String {
        formatEvidence(
            plan: SearchPlan(
                topic: queries.first ?? "",
                targets: queries.map {
                    SearchTarget(name: "开放检索", domain: nil, query: $0, reason: nil, directURL: nil)
                }
            ),
            hits: hits,
            pages: pages
        )
    }

    private static func formatProcessLog(queries: [String], hits: [Hit], pages: [PageText]) -> String {
        formatProcessLog(
            plan: SearchPlan(
                topic: queries.first ?? "",
                targets: queries.map {
                    SearchTarget(name: "开放检索", domain: nil, query: $0, reason: nil, directURL: nil)
                }
            ),
            hits: hits,
            pages: pages
        )
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
            if shouldBlockOfficialHit(hit, topic: "") && isOfficialPortalHost(host) { continue }
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
        if h == "baidu.com" || h == "www.baidu.com" { return true }
        if h.contains("google.") { return true }
        if h.contains("microsoft.com") || h.contains("microsoftonline.com") { return true }
        if h.contains("youtube.com") || h.contains("youtu.be") { return true }
        return false
    }

    private static func isJunkHit(_ hit: Hit) -> Bool {
        let blob = (hit.title + " " + hit.snippet + " " + hit.url).lowercased()
        if junkContentMarkers.contains(where: { blob.contains($0.lowercased()) }) {
            return true
        }
        if let host = URL(string: hit.url)?.host?.lowercased() {
            if lowQualityHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return true
            }
            if host.contains("ufcn") || host.contains("dytt") || host.contains("pianba") {
                return true
            }
        }
        return false
    }

    /// Baidu's public result pages are often available while its destination
    /// sites (Baike, Wenku, Zhidao, etc.) serve verification walls to a
    /// programmatic reader. Exclude the whole domain before both displaying
    /// summaries and choosing articles, so it cannot occupy the useful slots.
    private static func isExcludedResultHost(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "baidu.com" || host == "www.baidu.com"
    }

    // MARK: - Page fetch

    private static func fetchPages(
        _ hits: [Hit],
        onProgress: ((String) -> Void)? = nil,
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
        var readCount = 0

        for hit in hits {
            group.enter()
            fetchPageText(urlString: hit.url) { text in
                lock.lock()
                if let text = text, text.count >= 80 {
                    pages.append(PageText(hit: hit, text: text))
                    readCount += 1
                    let n = readCount
                    let title = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = title.isEmpty ? hit.url : title
                    lock.unlock()
                    onProgress?("已读到 (\(n))：\(String(label.prefix(48)))")
                } else if let host = URL(string: hit.url)?.host?.lowercased() {
                    failedHosts.insert(host)
                    lock.unlock()
                } else {
                    lock.unlock()
                }
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

    private static func fetchDuckDuckGoHTML(
        query: String,
        attempt: Int = 1,
        completion: @escaping (Result<[Hit], Error>) -> Void
    ) {
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
                if attempt < serpRetryLimit {
                    let delay = Double(attempt) * 0.8
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                        fetchDuckDuckGoHTML(query: query, attempt: attempt + 1, completion: completion)
                    }
                    return
                }
                completion(.failure(SearchError.network(error.localizedDescription)))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, let html = String(data: data, encoding: .utf8), (200..<300).contains(code) else {
                if attempt < serpRetryLimit, code == 403 || code == 429 || code == 202 {
                    let delay = Double(attempt) * 1.2
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                        fetchDuckDuckGoHTML(query: query, attempt: attempt + 1, completion: completion)
                    }
                    return
                }
                completion(.failure(SearchError.network("DuckDuckGo 请求失败 (\(code))")))
                return
            }
            let hits = parseDuckDuckGoHTML(html)
            // Empty SERP is a real miss — do not retry and burn quota.
            completion(.success(hits))
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
            // Traffic still lands on cn.bing.com from CN networks. Do NOT set
            // ENSEARCH/BENVER cookies: they "internationalize" the index and
            // scramble CJK queries into unrelated English/Tailscale/calculator
            // spam. Prefer the default regional feed, then let DuckDuckGo lead.
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

    private static func hitScore(_ hit: Hit, topic: String, targets: [SearchTarget]) -> Int {
        let compactTopic = sanitizePlannerQuery(focusTopicPhrase(topic), topic: topic).lowercased()
        let title = hit.title.lowercased()
        let snippet = hit.snippet.lowercased()
        let sourceText = title + " " + snippet
        var value = 0
        if !compactTopic.isEmpty {
            if title.contains(compactTopic) { value += 6 }
            if snippet.contains(compactTopic) { value += 3 }
        }
        if isTopicRelevantHit(hit, topic: topic) { value += 8 }
        for target in targets {
            if termMatches(sourceText, term: sanitizePlannerQuery(target.query, topic: topic)) { value += 6 }
        }
        if !hit.snippet.isEmpty { value += 1 }
        if isTrustedSource(hit.url) { value += 10 }
        if isEncyclopediaHost(hit.url) { value += 8 }
        if let host = URL(string: hit.url)?.host?.lowercased() {
            for target in targets {
                guard let domain = target.domain else { continue }
                if host == domain || host.hasSuffix("." + domain) {
                    value += 12
                }
            }
        }
        let explanatoryMarkers = [
            "定义", "起源", "发展", "历史", "研究", "论文", "报告",
            "解释", "分析", "背景", "影响"
        ]
        if explanatoryMarkers.contains(where: { sourceText.contains($0) }) {
            value += 4
        }
        if isJunkHit(hit) { value -= 50 }
        if shouldBlockOfficialHit(hit, topic: topic) { value -= 100 }
        if isWrongSenseHit(hit, topic: topic) { value -= 100 }
        if isGenericNationHit(hit) && !isTopicRelevantHit(hit, topic: topic) { value -= 100 }
        if isPlaybackPlatform(hit.url) { value -= 12 }
        return value
    }

    private static func isTrustedSource(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return trustedSourceHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func rankHits(
        _ hits: [Hit],
        topic: String,
        targets: [SearchTarget]
    ) -> [Hit] {
        hits.enumerated()
            .sorted { lhs, rhs in
                let ls = hitScore(lhs.element, topic: topic, targets: targets)
                let rs = hitScore(rhs.element, topic: topic, targets: targets)
                if ls != rs { return ls > rs }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func poolRelevantToQueries(_ hits: [Hit], topic: String, queries: [String]) -> [Hit] {
        var out: [Hit] = []
        var seen = Set<String>()
        for query in [topic] + queries {
            for hit in hits where isTopicRelevantHit(hit, topic: query) {
                let key = hit.url.lowercased().isEmpty ? hit.title.lowercased() : hit.url.lowercased()
                guard seen.insert(key).inserted else { continue }
                out.append(hit)
            }
        }
        return out
    }

    private static func selectQualifiedHits(
        _ rankedHits: [Hit],
        topic: String,
        targetQueries: [String]
    ) -> [Hit] {
        guard !rankedHits.isEmpty else { return [] }
        let dummyTargets = targetQueries.map {
            SearchTarget(name: "q", domain: nil, query: $0, reason: nil, directURL: nil)
        }
        // Drop weak / off-topic rows even if a fuzzy term overlap slipped through.
        let qualified = rankedHits.filter { hit in
            guard !isJunkHit(hit), !shouldBlockOfficialHit(hit, topic: topic),
                  !isWrongSenseHit(hit, topic: topic),
                  isTopicRelevantHit(hit, topic: topic) else { return false }
            let score = hitScore(hit, topic: topic, targets: dummyTargets)
            if isEncyclopediaHost(hit.url) || isTrustedSource(hit.url) {
                return score >= 6
            }
            return score >= minHitScoreToKeep
        }
        if qualified.count >= minQualifiedHits {
            return Array(qualified.prefix(6))
        }
        if !qualified.isEmpty {
            return padWithTopicRelevantHits(
                qualified,
                from: rankedHits.filter { hitScore($0, topic: topic, targets: dummyTargets) >= minHitScoreToKeep },
                topic: topic,
                targetCount: min(minQualifiedHits, 3)
            )
        }
        // Last resort: a single strong encyclopedia/trusted row is enough to answer.
        if let anchor = rankedHits.first(where: {
            (isEncyclopediaHost($0.url) || isTrustedSource($0.url))
                && isTopicRelevantHit($0, topic: topic)
                && !isWrongSenseHit($0, topic: topic)
        }) {
            return [anchor]
        }
        return []
    }

    private static func padWithTopicRelevantHits(
        _ seed: [Hit],
        from rankedHits: [Hit],
        topic: String,
        targetCount: Int
    ) -> [Hit] {
        var out = seed
        var seen = Set(seed.map { $0.url.lowercased() })
        for hit in rankedHits {
            guard out.count < targetCount else { break }
            let key = hit.url.lowercased()
            guard !seen.contains(key) else { continue }
            guard isTopicRelevantHit(hit, topic: topic),
                  !shouldBlockOfficialHit(hit, topic: topic),
                  !isWrongSenseHit(hit, topic: topic) else { continue }
            out.append(hit)
            seen.insert(key)
        }
        return out
    }

    private static func termMatches(_ text: String, term: String) -> Bool {
        let lower = text.lowercased()
        let needle = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return false }
        if lower.contains(needle) { return true }

        let textCompact = searchableCharacters(in: lower)
        let termCompact = searchableCharacters(in: needle)
        guard termCompact.count >= 2 else { return lower.contains(needle) }
        if textCompact.contains(termCompact) { return true }

        let requiredRun: Int
        if termCompact.count >= 6 {
            requiredRun = 5
        } else if termCompact.count >= 4 {
            requiredRun = 4
        } else {
            // 2-char fuzzy runs match too many unrelated CN titles.
            return false
        }
        return longestCommonRun(termCompact, textCompact) >= requiredRun
    }

    private static func isPlaybackPlatform(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        let platforms = [
            "bilibili.com", "acfun.cn", "iqiyi.com", "youku.com", "mgtv.com",
            "v.qq.com", "tencentvideo.com", "douyin.com", "kuaishou.com"
        ]
        return platforms.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Reject SERP rows that lack the topic's distinctive terms.
    private static func isTopicRelevantHit(_ hit: Hit, topic: String) -> Bool {
        if isWrongSenseHit(hit, topic: topic) { return false }
        if isGenericNationHit(hit) {
            return requiredMatchTerms(in: topic).contains { termMatches(hit.title + " " + hit.snippet, term: $0) }
        }
        let terms = requiredMatchTerms(in: topic)
        guard !terms.isEmpty else {
            return false
        }
        let blob = hit.title + " " + hit.snippet
        if terms.contains(where: { termMatches(blob, term: $0) }) {
            return true
        }
        // Encyclopedia titles often use Traditional Chinese or short lemmas
        // (签证/簽證, 御宅族). Accept a shared character run against the topic.
        if isEncyclopediaHost(hit.url) {
            let topicCompact = searchableCharacters(in: focusTopicPhrase(topic))
            let titleCompact = searchableCharacters(in: hit.title)
            let need = topicCompact.count >= 4 ? 3 : 2
            if topicCompact.count >= 2, longestCommonRun(topicCompact, titleCompact) >= need {
                return true
            }
        }
        return false
    }

    private static func isEncyclopediaHost(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host.contains("wikipedia.org")
            || host == "baike.baidu.com"
            || host.hasSuffix(".baike.baidu.com")
    }

    private static func requiredMatchTerms(in text: String) -> [String] {
        let focused = focusTopicPhrase(text)
        var terms = distinctiveTerms(in: focused)
        if !topicNeedsGeography(text) {
            terms = terms.filter { $0 != "大陆" }
        }
        let strong = terms.filter { term in
            term.count >= 4
                || term.uppercased().contains("ACG")
                || cultureTopicMarkers.contains { term.contains($0) }
        }
        if !strong.isEmpty {
            return Array(strong.prefix(3))
        }
        if let focusedTerm = terms.first(where: { $0.count >= 3 }) {
            return [focusedTerm]
        }
        return focused.count >= 3 ? [focused] : []
    }

    private static func sanitizePlannerQuery(_ raw: String, topic: String) -> String {
        var q = focusTopicPhrase(raw)
        if !topicNeedsGeography(topic) && q.contains("大陆") {
            q = q.replacingOccurrences(of: "大陆ACG", with: "中国ACG")
            q = q.replacingOccurrences(of: "大陆二次元", with: "中国二次元")
            q = q.replacingOccurrences(of: "大陆动漫", with: "中国动漫")
            q = q.replacingOccurrences(of: "大陆", with: "中国")
        }
        let focused = focusedSearchQuery(q)
        return focused.isEmpty ? q : focused
    }

    private static func topicNeedsGeography(_ topic: String) -> Bool {
        let markers = ["地理", "地形", "板块", "大洲", "七大洲", "经纬", "地貌", "火山", "地震"]
        return markers.contains { topic.contains($0) }
    }

    private static func topicIsCultural(_ topic: String) -> Bool {
        cultureTopicMarkers.contains { topic.uppercased().contains($0.uppercased()) || topic.contains($0) }
    }

    private static func isWrongSenseHit(_ hit: Hit, topic: String) -> Bool {
        let blob = hit.title + " " + hit.snippet
        guard topicIsCultural(topic) else { return false }
        if geographyHitMarkers.contains(where: { blob.contains($0) }) {
            return true
        }
        if blob.contains("大陆") && (blob.contains("划分") || blob.contains("七大洲") || blob.contains("独特之处")) {
            return true
        }
        return false
    }

    private static func focusTopicPhrase(_ raw: String) -> String {
        var q = sanitizeQuery(raw)
        let stripPrefixes = ["请问", "我想知道", "中国的", "中国", "我国", "关于"]
        for prefix in stripPrefixes where q.hasPrefix(prefix) {
            q = String(q.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let stripSuffixes = [
            "是怎么发展起来的", "是如何发展的", "的发展历程", "的发展历史",
            "是怎么来的", "是怎么产生的", "是什么", "有哪些", "怎么样", "吗"
        ]
        for suffix in stripSuffixes where q.hasSuffix(suffix) {
            q = String(q.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return q.isEmpty ? sanitizeQuery(raw) : q
    }

    private static func focusedSearchQuery(_ raw: String) -> String {
        let focused = focusTopicPhrase(raw)
        let terms = distinctiveTerms(in: focused)
        if let primary = terms.max(by: { $0.count < $1.count }) {
            return primary
        }
        return focused
    }

    private static func distinctiveTerms(in text: String) -> [String] {
        let focused = focusTopicPhrase(text)
        var terms: [String] = []
        var seen = Set<String>()

        func add(_ value: String) {
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2,
                  !topicStopwords.contains(term),
                  seen.insert(term.lowercased()).inserted else { return }
            terms.append(term)
        }

        add(focused)
        let pieces = focused
            .replacingOccurrences(of: #"[^\p{Han}a-zA-Z0-9]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for piece in pieces { add(piece) }

        if terms.count <= 2 {
            let compact = searchableCharacters(in: focused)
            if compact.count >= 4 {
                for length in stride(from: min(6, compact.count), through: 4, by: -1) {
                    for start in 0...(compact.count - length) {
                        let startIdx = compact.index(compact.startIndex, offsetBy: start)
                        let endIdx = compact.index(startIdx, offsetBy: length)
                        add(String(compact[startIdx..<endIdx]))
                    }
                }
            }
        }
        return terms.sorted { $0.count > $1.count }
    }

    private static func isGenericNationHit(_ hit: Hit) -> Bool {
        let title = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = [
            "中华人民共和国", "中国（", "中国政府网", "中华人民共和国国务院",
            "中国的概况", "中国 - 百度百科", "中国_百度百科"
        ]
        return markers.contains { title.hasPrefix($0) || title == $0 }
    }

    private static func isOfficialPortalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "gov.cn" || h.hasSuffix(".gov.cn") || h.contains(".gov.cn") { return true }
        if h == "china.com.cn" || h.hasSuffix(".china.com.cn") { return true }
        if h == "people.com.cn" || h.hasSuffix(".people.com.cn") { return true }
        if h == "xinhuanet.com" || h.hasSuffix(".xinhuanet.com") { return true }
        if h == "news.cn" || h.hasSuffix(".news.cn") { return true }
        return false
    }

    private static func isBlockedPlannerDomain(_ domain: String) -> Bool {
        let d = domain.lowercased()
        return blockedPlannerDomains.contains { d == $0 || d.hasSuffix("." + $0) || d.contains($0) }
    }

    private static func topicNeedsOfficialSources(_ topic: String) -> Bool {
        officialTopicMarkers.contains { topic.contains($0) }
    }

    private static func shouldBlockOfficialHit(_ hit: Hit, topic: String) -> Bool {
        guard let host = URL(string: hit.url)?.host?.lowercased() else { return false }
        if topicNeedsOfficialSources(topic) { return false }
        if isOfficialPortalHost(host) { return true }
        let blob = (hit.title + " " + hit.snippet).lowercased()
        if blob.contains("中国政府网") || blob.contains("国务院") || blob.contains("中央人民政府") {
            return true
        }
        return false
    }

    private static func relevantHits(_ hits: [Hit], for query: String) -> [Hit] {
        hits.filter { isTopicRelevantHit($0, topic: query) }
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
