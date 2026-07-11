import Foundation

/// Lightweight web search (no extra API key) → inject snippets into the chat request.
enum WebSearchService {
    struct Hit {
        let title: String
        let url: String
        let snippet: String
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

    /// Search then format a block suitable for model context.
    static func searchAndFormat(query: String, completion: @escaping (Result<String, Error>) -> Void) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            DispatchQueue.main.async { completion(.failure(SearchError.emptyQuery)) }
            return
        }

        let group = DispatchGroup()
        var htmlHits: [Hit] = []
        var iaText = ""
        var htmlError: Error?

        group.enter()
        fetchDuckDuckGoHTML(query: q) { result in
            switch result {
            case .success(let hits): htmlHits = hits
            case .failure(let err): htmlError = err
            }
            group.leave()
        }

        group.enter()
        fetchDuckDuckGoInstant(query: q) { text in
            iaText = text
            group.leave()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            var lines: [String] = []
            if !iaText.isEmpty {
                lines.append("摘要：\(iaText)")
                lines.append("")
            }
            for (i, hit) in htmlHits.prefix(6).enumerated() {
                lines.append("[\(i + 1)] \(hit.title)")
                if !hit.url.isEmpty { lines.append("链接：\(hit.url)") }
                if !hit.snippet.isEmpty { lines.append(hit.snippet) }
                lines.append("")
            }
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if body.isEmpty {
                    completion(.failure(htmlError ?? SearchError.noResults))
                } else {
                    completion(.success(body))
                }
            }
        }
    }

    /// Inject search block into the last user message (API-only; does not mutate stored chat).
    static func inject(into messages: [ChatMessage], searchBlock: String) -> [ChatMessage] {
        let block = searchBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !block.isEmpty else { return messages }
        guard let idx = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        var out = messages
        var user = out[idx]
        let original = user.content
        user.content = """
        【联网搜索结果｜请优先依据下列资料作答，并注明不确定处】
        \(block)

        【用户问题】
        \(original)
        """
        out[idx] = user
        return out
    }

    // MARK: - DuckDuckGo HTML

    private static func fetchDuckDuckGoHTML(query: String, completion: @escaping (Result<[Hit], Error>) -> Void) {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps?.url else {
            completion(.failure(SearchError.network("无效搜索 URL")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(
            "Mozilla/5.0 (iPad; CPU OS 12_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )
        req.timeoutInterval = 18

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(SearchError.network(error.localizedDescription)))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, let html = String(data: data, encoding: .utf8), (200..<300).contains(code) else {
                completion(.failure(SearchError.network("搜索请求失败 (\(code))")))
                return
            }
            let hits = parseDuckDuckGoHTML(html)
            completion(.success(hits))
        }.resume()
    }

    private static func parseDuckDuckGoHTML(_ html: String) -> [Hit] {
        // result__a href + text; result__snippet
        var hits: [Hit] = []
        let linkPattern = #"class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>"#
        let snipPattern = #"class=\"result__snippet\"[^>]*>([\\s\\S]*?)</(?:a|td|div)>"#

        let links = regexMatches(html, pattern: linkPattern)
        let snips = regexMatches(html, pattern: snipPattern)

        for (i, link) in links.enumerated() {
            guard link.count >= 3 else { continue }
            let rawURL = decodeHTML(link[1])
            let title = stripTags(decodeHTML(link[2])).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = unwrapDDGRedirect(rawURL)
            var snippet = ""
            if i < snips.count, snips[i].count >= 2 {
                snippet = stripTags(decodeHTML(snips[i][1]))
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if title.isEmpty && snippet.isEmpty { continue }
            hits.append(Hit(title: title.isEmpty ? url : title, url: url, snippet: snippet))
            if hits.count >= 8 { break }
        }
        return hits
    }

    // MARK: - Instant Answer (bonus abstract)

    private static func fetchDuckDuckGoInstant(query: String, completion: @escaping (String) -> Void) {
        var comps = URLComponents(string: "https://api.duckduckgo.com/")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]
        guard let url = comps?.url else {
            completion("")
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion("")
                return
            }
            let abstract = (obj["AbstractText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let answer = (obj["Answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let heading = (obj["Heading"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var parts: [String] = []
            if !heading.isEmpty { parts.append(heading) }
            if !abstract.isEmpty { parts.append(abstract) }
            else if !answer.isEmpty { parts.append(answer) }
            completion(parts.joined(separator: " — "))
        }.resume()
    }

    // MARK: - Helpers

    private static func regexMatches(_ text: String, pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, options: [], range: range).compactMap { match -> [String]? in
            var parts: [String] = []
            for i in 0..<match.numberOfRanges {
                guard let r = Range(match.range(at: i), in: text) else { return nil }
                parts.append(String(text[r]))
            }
            return parts
        }
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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
        return t
    }

    private static func unwrapDDGRedirect(_ raw: String) -> String {
        // //duckduckgo.com/l/?uddg=https%3A%2F%2F...
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
