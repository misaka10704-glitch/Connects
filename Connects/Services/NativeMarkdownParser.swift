import Foundation

enum MarkdownNormalizer {
    static func normalize(_ raw: String) -> String {
        normalizeReferenceLinks(MarkdownHTMLRenderer.normalizeForRender(raw))
    }

    private struct RefItem {
        var title: String
        var url: String
    }

    private static func normalizeReferenceLinks(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var output = [String]()
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isReferenceHeading(trimmed) {
                var items = [RefItem]()
                index += 1
                while index < lines.count {
                    let raw = lines[index]
                    let t = raw.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty {
                        // Allow a single blank inside the section; stop on a second blank or after items.
                        if index + 1 < lines.count {
                            let peek = lines[index + 1].trimmingCharacters(in: .whitespaces)
                            if peek.isEmpty || isReferenceHeading(peek) || isMarkdownHeading(peek) {
                                index += 1
                                break
                            }
                        }
                        index += 1
                        continue
                    }
                    if isReferenceHeading(t) || isMarkdownHeading(t) {
                        break
                    }
                    // Stop when the model continues with ordinary prose (no list/url/citation marker).
                    if !looksLikeReferenceLine(t), !items.isEmpty {
                        break
                    }

                    if let pair = parseReferenceLine(t) {
                        items.append(pair)
                        index += 1
                        continue
                    }

                    // Title on this line, bare URL on the next.
                    if index + 1 < lines.count {
                        let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
                        if let url = extractURL(next), looksLikeReferenceTitle(t) {
                            items.append(RefItem(title: cleanReferenceTitle(t, url: url), url: url))
                            index += 2
                            continue
                        }
                    }

                    if let url = extractURL(t) {
                        items.append(RefItem(title: cleanReferenceTitle("", url: url), url: url))
                        index += 1
                        continue
                    }

                    // Unrecognized line inside a declared references section — skip junk.
                    index += 1
                }

                let cleaned = dedupeReferences(items)
                if !cleaned.isEmpty {
                    if !output.isEmpty, !(output.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                        output.append("")
                    }
                    output.append("### 参考来源")
                    for (i, item) in cleaned.prefix(5).enumerated() {
                        let title = item.title.isEmpty ? cleanReferenceTitle("", url: item.url) : item.title
                        output.append("\(i + 1). [\(escapeLinkLabel(title))](\(item.url))")
                    }
                    output.append("")
                }
                continue
            }

            output.append(line)
            index += 1
        }

        // Trim trailing blanks introduced by the section rewrite.
        while output.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            output.removeLast()
        }
        return output.joined(separator: "\n")
    }

    private static func isReferenceHeading(_ trimmed: String) -> Bool {
        let headingText = trimmed
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(
                CharacterSet(charactersIn: "：:")
            ))
        let aliases = ["参考链接", "参考来源", "参考资料", "引用来源", "Sources", "References", "Citation", "Citations"]
        return aliases.contains(headingText)
    }

    private static func isMarkdownHeading(_ line: String) -> Bool {
        for level in 1...6 {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) { return true }
        }
        return false
    }

    private static func looksLikeReferenceLine(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        if extractURL(line) != nil { return true }
        if line.range(of: #"^\s*\[\d+\]"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"^\s*\d+[\.、\)]\s+"#, options: .regularExpression) != nil { return true }
        if line.contains("](") { return true }
        return false
    }

    private static func looksLikeReferenceTitle(_ line: String) -> Bool {
        guard extractURL(line) == nil else { return false }
        let t = cleanReferenceTitle(line, url: "")
        return !t.isEmpty && t.count <= 160
    }

    private static func parseReferenceLine(_ line: String) -> RefItem? {
        var text = line.trimmingCharacters(in: .whitespaces)
        // Strip list / citation markers: "- ", "1. ", "[3] ", "（1）"
        if let re = try? NSRegularExpression(pattern: #"^(?:[-*+]\s+|\d+[\.、\)]\s+|\[\d+\]\s+|（\d+）\s+)"#) {
            text = re.stringByReplacingMatches(
                in: text,
                options: [],
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespaces)
        }

        // Markdown link: [title](url) possibly with trailing junk.
        if let re = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#),
           let match = re.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
           match.numberOfRanges >= 3,
           let titleRange = Range(match.range(at: 1), in: text),
           let urlRange = Range(match.range(at: 2), in: text) {
            let url = String(text[urlRange])
            let title = cleanReferenceTitle(String(text[titleRange]), url: url)
            return RefItem(title: title, url: url)
        }

        // "title：https://..." or "title - https://..."
        if let url = extractURL(text) {
            var title = text
            if let range = title.range(of: url) {
                title.removeSubrange(range)
            }
            title = cleanReferenceTitle(title, url: url)
            return RefItem(title: title, url: url)
        }
        return nil
    }

    private static func extractURL(_ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s<>\)\]\"']+"#) else { return nil }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var url = ns.substring(with: match.range)
        while url.hasSuffix(".") || url.hasSuffix(",") || url.hasSuffix("；") || url.hasSuffix("。") || url.hasSuffix(")") {
            url = String(url.dropLast())
        }
        return url.hasPrefix("http") ? url : nil
    }

    private static func cleanReferenceTitle(_ raw: String, url: String) -> String {
        var title = raw
            .replacingOccurrences(of: #"^\s*\[\d+\]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*\d+[\.、\)]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "：:-—–|｜")
            ))
        if title.hasPrefix("["), title.hasSuffix("]"), title.count > 2 {
            title = String(title.dropFirst().dropLast())
        }
        if title.isEmpty || title == url || title.hasPrefix("http://") || title.hasPrefix("https://") {
            if let host = URL(string: url)?.host, !host.isEmpty {
                return host.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
            }
            return "查看来源"
        }
        // Collapse whitespace.
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if title.count > 72 {
            let idx = title.index(title.startIndex, offsetBy: 72)
            title = String(title[..<idx]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return title
    }

    private static func escapeLinkLabel(_ title: String) -> String {
        title
            .replacingOccurrences(of: "[", with: "（")
            .replacingOccurrences(of: "]", with: "）")
    }

    private static func dedupeReferences(_ items: [RefItem]) -> [RefItem] {
        var out = [RefItem]()
        var seen = Set<String>()
        for item in items {
            let key = normalizeURLKey(item.url)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(item)
        }
        return out
    }

    private static func normalizeURLKey(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }
}

final class NativeMarkdownParser {
    static let shared = NativeMarkdownParser()

    private final class Box: NSObject {
        let document: NativeMarkdownDocument
        init(_ document: NativeMarkdownDocument) { self.document = document }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 96
    }

    func parse(_ raw: String) -> NativeMarkdownDocument {
        let normalized = MarkdownNormalizer.normalize(raw)
        let stamp = RenderCacheStore.stamp(normalized)
        if let hit = cache.object(forKey: stamp as NSString) {
            return hit.document
        }
        let document = NativeMarkdownDocument(stamp: stamp, blocks: parseBlocks(normalized))
        cache.setObject(Box(document), forKey: stamp as NSString)
        return document
    }

    func clear() {
        cache.removeAllObjects()
    }

    private func parseBlocks(_ source: String) -> [NativeMessageBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks = [NativeMessageBlock]()
        var paragraph = [String]()
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(parseInlines(paragraph.joined(separator: "\n"))))
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code = [String]()
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.codeBlock(
                    language: language.isEmpty ? nil : language,
                    code: code.joined(separator: "\n")
                ))
                continue
            }

            if let math = displayMathStarting(at: index, lines: lines) {
                flushParagraph()
                blocks.append(.displayMath(math.source))
                index = math.next
                continue
            }

            if index + 1 < lines.count, isTableSeparator(lines[index + 1]), line.contains("|") {
                flushParagraph()
                let header = splitTableRow(line).map(parseInlines)
                let alignments = parseAlignments(lines[index + 1])
                var rows = [[[NativeInline]]]()
                index += 2
                while index < lines.count {
                    let row = lines[index]
                    guard row.contains("|"),
                          !row.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                    rows.append(splitTableRow(row).map(parseInlines))
                    index += 1
                }
                blocks.append(.table(NativeTable(
                    header: header,
                    rows: rows,
                    alignments: alignments
                )))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.horizontalRule)
                index += 1
                continue
            }

            if let heading = headingInfo(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, inlines: parseInlines(heading.text)))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote = trimmed
                quote.removeFirst()
                blocks.append(.blockquote(parseInlines(quote.trimmingCharacters(in: .whitespaces))))
                index += 1
                continue
            }

            if let marker = listMarker(trimmed) {
                flushParagraph()
                var items = [[NativeInline]]()
                var start = marker.start
                while index < lines.count, let item = listMarker(lines[index].trimmingCharacters(in: .whitespaces)),
                      item.ordered == marker.ordered {
                    if start == nil { start = item.start }
                    items.append(parseInlines(item.text))
                    index += 1
                }
                let kind: NativeListKind = marker.ordered ? .ordered(start: start ?? 1) : .unordered
                blocks.append(.list(kind: kind, items: items))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private func parseInlines(_ source: String) -> [NativeInline] {
        var result = [NativeInline]()
        var cursor = source.startIndex
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(.text(buffer))
            buffer = ""
        }

        while cursor < source.endIndex {
            let tail = source[cursor...]
            if tail.hasPrefix("\\("), let end = source.range(of: "\\)", range: source.index(cursor, offsetBy: 2)..<source.endIndex) {
                flush()
                result.append(.inlineMath(String(source[source.index(cursor, offsetBy: 2)..<end.lowerBound])))
                cursor = end.upperBound
                continue
            }
            if tail.hasPrefix("\\["),
               let end = source.range(
                   of: "\\]",
                   range: source.index(cursor, offsetBy: 2)..<source.endIndex
               ) {
                flush()
                result.append(.inlineMath(String(
                    source[source.index(cursor, offsetBy: 2)..<end.lowerBound]
                )))
                cursor = end.upperBound
                continue
            }
            if tail.hasPrefix("$$"),
               let end = source.range(
                   of: "$$",
                   range: source.index(cursor, offsetBy: 2)..<source.endIndex
               ) {
                flush()
                result.append(.inlineMath(String(
                    source[source.index(cursor, offsetBy: 2)..<end.lowerBound]
                )))
                cursor = end.upperBound
                continue
            }
            if tail.hasPrefix("$"), !tail.hasPrefix("$$"), !isEscaped(cursor, in: source),
               let end = nextUnescapedDollar(after: cursor, in: source) {
                let body = String(source[source.index(after: cursor)..<end])
                if shouldParseDollarMath(body) {
                    flush()
                    result.append(.inlineMath(body))
                    cursor = source.index(after: end)
                    continue
                }
            }
            if let bareMath = bareInlineMathPrefix(tail) {
                flush()
                result.append(.inlineMath(bareMath))
                cursor = source.index(cursor, offsetBy: bareMath.count)
                continue
            }
            if tail.hasPrefix("**"),
               let end = source.range(of: "**", range: source.index(cursor, offsetBy: 2)..<source.endIndex) {
                flush()
                result.append(.bold(parseInlines(String(source[source.index(cursor, offsetBy: 2)..<end.lowerBound]))))
                cursor = end.upperBound
                continue
            }
            if tail.hasPrefix("`"),
               let end = source[source.index(after: cursor)...].firstIndex(of: "`") {
                flush()
                result.append(.inlineCode(String(source[source.index(after: cursor)..<end])))
                cursor = source.index(after: end)
                continue
            }
            if tail.hasPrefix("["),
               let close = source[source.index(after: cursor)...].firstIndex(of: "]"),
               close < source.index(before: source.endIndex),
               source[source.index(after: close)] == "(",
               let end = source[source.index(close, offsetBy: 2)...].firstIndex(of: ")") {
                flush()
                let label = String(source[source.index(after: cursor)..<close])
                let rawURL = String(source[source.index(close, offsetBy: 2)..<end])
                result.append(.link(parseInlines(label), URL(string: rawURL)))
                cursor = source.index(after: end)
                continue
            }
            if (tail.hasPrefix("*") || tail.hasPrefix("_")) {
                let marker = source[cursor]
                if let end = source[source.index(after: cursor)...].firstIndex(of: marker) {
                    flush()
                    result.append(.italic(parseInlines(String(source[source.index(after: cursor)..<end]))))
                    cursor = source.index(after: end)
                    continue
                }
            }
            if source[cursor] == "\n" {
                flush()
                result.append(.lineBreak)
            } else {
                buffer.append(source[cursor])
            }
            cursor = source.index(after: cursor)
        }
        flush()
        return result
    }

    private func bareInlineMathPrefix(_ tail: Substring) -> String? {
        let value = String(tail)
        let patterns = [
            #"^\\(?:dot|ddot|bar|vec|hat|tilde|overline|underline)\{[^{}\n]+\}(?:_(?:\{[^}\n]+\}|[A-Za-z0-9]+))?(?:\^(?:\{[^}\n]+\}|[A-Za-z0-9]+))?"#,
            // Keep useful bare forms such as x_n and x_10, but do not turn
            // ordinary identifiers (`t_filter`) or URL fragments into math.
            #"^[A-Za-z](?:_(?:\{[^}\n]+\}|[A-Za-z0-9]{1,3}))(?:\^(?:\{[^}\n]+\}|[A-Za-z0-9]{1,3}))?(?![A-Za-z0-9_])"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: value,
                    range: NSRange(location: 0, length: (value as NSString).length)
                  ),
                  match.range.location == 0,
                  match.range.length > 0 else { continue }
            return (value as NSString).substring(with: match.range)
        }
        return nil
    }

    private func isEscaped(_ index: String.Index, in source: String) -> Bool {
        guard index > source.startIndex else { return false }
        var cursor = source.index(before: index)
        var slashCount = 0
        while source[cursor] == "\\" {
            slashCount += 1
            guard cursor > source.startIndex else { break }
            cursor = source.index(before: cursor)
        }
        return slashCount % 2 == 1
    }

    private func nextUnescapedDollar(after opener: String.Index,
                                     in source: String) -> String.Index? {
        var cursor = source.index(after: opener)
        while cursor < source.endIndex {
            if source[cursor] == "$", !isEscaped(cursor, in: source) {
                return cursor
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private func shouldParseDollarMath(_ body: String) -> Bool {
        let value = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n") else { return false }
        // `$5-$10` and similar prices are prose, not two formulas.
        if value.first?.isNumber == true,
           value.range(of: #"[A-Za-z\\_^{}]"#, options: .regularExpression) == nil {
            return false
        }
        return true
    }

    private func displayMathStarting(at index: Int, lines: [String]) -> (source: String, next: Int)? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        // Models frequently put `\(...\)` on its own line even though the
        // delimiter is conventionally inline. Treat that line as display math
        // here; otherwise a plain-render fallback can expose the delimiters.
        let pairs: [(String, String)] = [
            ("$$", "$$"),
            ("\\[", "\\]"),
            ("\\(", "\\)")
        ]
        for (open, close) in pairs where trimmed.hasPrefix(open) {
            var body = String(trimmed.dropFirst(open.count))
            if let sameLineClose = body.range(of: close) {
                let remainder = body[sameLineClose.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                // A line-leading inline formula may continue with prose.
                // Leave that line to parseInlines instead of swallowing later
                // lines while looking for another closing delimiter.
                guard remainder.isEmpty else { return nil }
                return (String(body[..<sameLineClose.lowerBound]), index + 1)
            }
            // Parenthesis delimiters are inline by definition. If their close
            // is absent on this line, preserve the text literally rather than
            // consuming unrelated following paragraphs.
            if open == "\\(" { return nil }
            var next = index + 1
            while next < lines.count {
                if let range = lines[next].range(of: close) {
                    body += (body.isEmpty ? "" : "\n") + String(lines[next][..<range.lowerBound])
                    return (body, next + 1)
                }
                body += (body.isEmpty ? "" : "\n") + lines[next]
                next += 1
            }
            return nil
        }
        if trimmed.hasPrefix("\\begin{"), let envEnd = trimmed.firstIndex(of: "}") {
            let env = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)..<envEnd])
            let close = "\\end{\(env)}"
            var body = trimmed
            var next = index + 1
            while !body.contains(close), next < lines.count {
                body += "\n" + lines[next]
                next += 1
            }
            return body.contains(close) ? (body, next) : nil
        }
        // Models occasionally omit delimiters around a multi-line command,
        // especially \boxed{...}. Consume the complete brace-balanced TeX
        // expression instead of exposing it as raw markdown.
        // Do not reinterpret numbered/bulleted Markdown items as one large
        // formula merely because their inline formulas contain several slashes.
        if listMarker(trimmed) != nil || headingInfo(trimmed) != nil || trimmed.hasPrefix(">") {
            return nil
        }
        let bareDisplayCommands = [
            "\\boxed{", "\\displaystyle", "\\begin{", "\\left", "\\frac{",
            "\\dfrac{", "\\sqrt{", "\\sum_", "\\int_", "\\lim_"
        ]
        if bareDisplayCommands.contains(where: { trimmed.hasPrefix($0) }) {
            var body = trimmed
            var balance = braceBalance(trimmed)
            var next = index + 1
            while balance > 0, next < lines.count {
                let continuation = lines[next].trimmingCharacters(in: .whitespaces)
                if continuation.isEmpty { break }
                body += "\n" + continuation
                balance += braceBalance(continuation)
                next += 1
            }
            if balance <= 0 {
                return (body, next)
            }
        }
        if looksLikeBareMathLine(trimmed) {
            var body = trimmed
            var next = index + 1
            while next < lines.count {
                let continuation = lines[next].trimmingCharacters(in: .whitespaces)
                guard looksLikeBareMathContinuation(continuation) else { break }
                body += "\n" + continuation
                next += 1
            }
            return (body, next)
        }
        return nil
    }

    private func looksLikeBareMathLine(_ line: String) -> Bool {
        guard !line.isEmpty, !containsCJK(line) else { return false }
        let commandCount = line.components(separatedBy: "\\").count - 1
        let structural = line.contains("=") || line.contains("_") || line.contains("^")
            || line.contains("\\left") || line.contains("\\frac")
        let withoutCommands = line.replacingOccurrences(
            of: #"\\[A-Za-z]+"#,
            with: "",
            options: .regularExpression
        )
        let hasProseWords = withoutCommands.range(
            of: #"\b[A-Za-z]{2,}\b"#,
            options: .regularExpression
        ) != nil
        return !hasProseWords && (commandCount >= 2 || (commandCount >= 1 && structural))
    }

    private func looksLikeBareMathContinuation(_ line: String) -> Bool {
        guard !line.isEmpty,
              !containsCJK(line),
              !line.hasPrefix("#"),
              !line.hasPrefix("```") else { return false }
        return line.contains("\\") || line.contains("=") || line.contains("_")
            || line.contains("^") || line.hasPrefix("{") || line.hasSuffix("}")
    }

    private func containsCJK(_ source: String) -> Bool {
        source.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value)
                || (0x4E00...0x9FFF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value)
        }
    }

    private func braceBalance(_ source: String) -> Int {
        var balance = 0
        var escaped = false
        for character in source {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
            } else if character == "{" {
                balance += 1
            } else if character == "}" {
                balance -= 1
            }
        }
        return balance
    }

    private func headingInfo(_ line: String) -> (level: Int, text: String)? {
        for level in 1...6 {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                return (level, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private func listMarker(_ line: String) -> (ordered: Bool, start: Int?, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return (false, nil, String(line.dropFirst(2)))
        }
        guard let dot = line.firstIndex(of: "."),
              dot != line.startIndex,
              line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " ",
              let number = Int(line[..<dot]) else { return nil }
        return (true, number, String(line[line.index(dot, offsetBy: 2)...]))
    }

    private func splitTableRow(_ row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private func isTableSeparator(_ row: String) -> Bool {
        let cells = splitTableRow(row)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy {
            let value = $0.replacingOccurrences(of: ":", with: "")
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }

    private func parseAlignments(_ row: String) -> [NativeTable.Alignment] {
        splitTableRow(row).map {
            let value = $0.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(":") && value.hasSuffix(":") { return .center }
            if value.hasSuffix(":") { return .right }
            return .left
        }
    }
}

enum NativeRendererSelfTest {
    static func installFixtureIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-NativeRendererFixture"),
              let conversation = ConversationStore.shared.currentConversation,
              conversation.messages.isEmpty else { return }
        ConversationStore.shared.updateCurrentQuietly { value in
            value.messages.append(ChatMessage(role: .user, content: "测试原生渲染"))
            value.messages.append(ChatMessage(
                role: .assistant,
                content: """
                # Native Block Render

                普通文字包含 **粗体**、*斜体*、`inline code` 和行内公式 $E=mc^2$。
                无分隔符也支持 \\dot{x}、x_n 和 \\bar{x}_n。

                > 已完成消息只使用单一 native render view 绘制。

                - 第一项
                - 第二项

                | 模块 | 状态 |
                |:---|---:|
                | Markdown | Native |
                | TeX | iosMath |

                $$\\int_0^t e^{-\\tau}\\,d\\tau = 1-e^{-t}$$

                \\boxed{f(t)=\\frac{1}{2\\pi}\\int_{-\\infty}^{\\infty}
                F(j\\omega)e^{j\\omega t}\\,d\\omega}

                \\operatorname{Var}(\\bar{X}_n)
                = \\frac{1}{n^2}\\sum_{i=1}^n \\operatorname{Var}(X_i)
                = \\frac{\\sigma^2}{n}.

                ```swift
                let stable = true
                ```
                """,
                reasoningContent: "",
                isStreaming: false
            ))
        }
        #endif
    }

    static func run() {
        #if DEBUG
        // This corpus is a developer-only test harness. Running it on every
        // Debug launch can trip an assertion on older iOS rendering stacks and
        // prevents the actual app from opening.
        guard ProcessInfo.processInfo.arguments.contains("-RunNativeRendererSelfTest") else { return }
        runDeviceCorpusIfRequested()
        let sample = """
        # Native renderer

        **bold** and $x^2 + y^2$.

        | A | B |
        |:--|--:|
        | 1 | 2 |

        $$\\frac{a}{b}=\\sum_{i=1}^{n}i$$

        ```swift
        let value = 42
        ```
        """
        let document = NativeMarkdownParser.shared.parse(sample)
        assert(document.blocks.count >= 5)
        let bare = NativeMarkdownParser.shared.parse("""
        这是逆变换：
        \\boxed{f(t)=\\frac{1}{2\\pi}\\int_{-\\infty}^{\\infty}
        F(j\\omega)e^{j\\omega t}\\,d\\omega}
        """)
        assert(bare.blocks.contains {
            if case .displayMath = $0 { return true }
            return false
        })
        let dollarDelimited = NativeMarkdownParser.shared.parse(
            "$$\\boxed{F(j\\omega)=\\int_{-\\infty}^{\\infty}f(t)e^{-j\\omega t}\\,dt}$$"
        )
        assert(dollarDelimited.blocks.contains {
            if case .displayMath = $0 { return true }
            return false
        })
        let formulaList = NativeMarkdownParser.shared.parse("""
        1. \\([a_{n+1},b_{n+1}] \\subseteq [a_n,b_n]\\), \\(\\forall n\\)
        2. \\(\\lim_{n\\to\\infty}(b_n-a_n)=0\\)
        """)
        let listFormulaCount = formulaList.blocks.reduce(0) { count, block in
            guard case .list(_, let items) = block else { return count }
            return count + items.flatMap { $0 }.reduce(0) { inlineCount, inline in
                if case .inlineMath = inline { return inlineCount + 1 }
                return inlineCount
            }
        }
        assert(listFormulaCount == 3)
        let gatewayEscaped = #"""
        连续形式：
        \\((f * g)(t) = \\int_{-\\infty}^{\\infty} f(\\tau)\\,g(t-\\tau)\\,\\mathrm{d}\\tau\\)

        \\[y(t) = \\int x(\\tau)\\,h(t-\\tau)\\,\\mathrm{d}\\tau = (x*h)(t)\\]
        """#
        let normalizedGatewayMath = MarkdownNormalizer.normalize(gatewayEscaped)
        assert(normalizedGatewayMath.contains(#"\((f * g)(t) = \int"#))
        assert(normalizedGatewayMath.contains(#"\[y(t) = \int"#))
        assert(!normalizedGatewayMath.contains(#"\\int"#))
        let gatewayDocument = NativeMarkdownParser.shared.parse(gatewayEscaped)
        let gatewayFormulaCount = gatewayDocument.blocks.reduce(0) { count, block in
            switch block {
            case .displayMath:
                return count + 1
            case .paragraph(let inlines):
                return count + inlines.reduce(0) {
                    if case .inlineMath = $1 { return $0 + 1 }
                    return $0
                }
            default:
                return count
            }
        }
        assert(gatewayFormulaCount == 2)
        let matrixRows = MarkdownNormalizer.normalize(
            #"$$\begin{matrix}a&b\\c&d\end{matrix}$$"#
        )
        assert(matrixRows.contains(#"b\\c"#))
        assert(MarkdownNormalizer.normalize("""
        ```latex
        \\frac{a}{b}
        ```
        """).hasPrefix("$$\\frac{a}{b}"))
        assert(MarkdownNormalizer.normalize("[math]x^2+y^2[/math]") == "$$x^2+y^2$$")
        let leadingInlineWithProse = NativeMarkdownParser.shared.parse("""
        \\(x(t)=1\\) 因此结论成立。
        下一行仍保留 \\(z=2\\)。
        """)
        let leadingInlineCount = leadingInlineWithProse.blocks.reduce(0) { total, block in
            guard case .paragraph(let inlines) = block else { return total }
            return total + inlines.reduce(0) {
                if case .inlineMath = $1 { return $0 + 1 }
                return $0
            }
        }
        assert(leadingInlineCount == 2)
        assert(!leadingInlineWithProse.blocks.contains {
            if case .displayMath = $0 { return true }
            return false
        })
        let malformed = NativeMarkdownParser.shared.parse(
            "未闭合：\\( 以及 \\[ 都必须保留；价格 $5-$10 也不是公式。"
        )
        let malformedText = malformed.blocks.compactMap { block -> String? in
            guard case .paragraph(let inlines) = block else { return nil }
            return inlines.compactMap {
                if case .text(let text) = $0 { return text }
                return nil
            }.joined()
        }.joined()
        assert(malformedText.contains("\\("))
        assert(malformedText.contains("\\["))
        assert(malformedText.contains("$5-$10"))
        let identifierControl = NativeMarkdownParser.shared.parse(
            "t_filter 与 https://example.invalid/e_Altruism 保持普通文本，x_n 可作为短数学下标。"
        )
        let identifierMathCount = identifierControl.blocks.reduce(0) { total, block in
            guard case .paragraph(let inlines) = block else { return total }
            return total + inlines.reduce(0) {
                if case .inlineMath = $1 { return $0 + 1 }
                return $0
            }
        }
        assert(identifierMathCount == 1)
        assert(MarkdownNormalizer.normalize("""
        ```katex
        x^2
        ```
        """) == "$$x^2\n$$")
        let references = NativeMarkdownParser.shared.parse("""
        **参考链接**
        [1] [Example reference](https://example.com/article)
        [5] Duplicate host
        https://example.com/article
        [2] [Another source](https://news.example.org/story)
        """)
        let refList = references.blocks.compactMap { block -> [[NativeInline]]? in
            if case .list(_, let items) = block { return items }
            return nil
        }.first
        assert(refList?.count == 2)
        let titles = (refList ?? []).map { item in
            item.compactMap { inline -> String? in
                if case .link(let children, _) = inline {
                    return children.compactMap {
                        if case .text(let t) = $0 { return t }
                        return nil
                    }.joined()
                }
                return nil
            }.joined()
        }
        assert(titles.contains(where: { $0.contains("Example") }))
        assert(titles.contains(where: { $0.contains("Another") }))
        assert(!titles.contains(where: { $0.hasPrefix("[") }))
        assert(references.blocks.contains {
            if case .heading(_, let inlines) = $0 {
                return inlines.contains {
                    if case .text(let t) = $0 { return t.contains("参考来源") }
                    return false
                }
            }
            return false
        })
        let layout = NativeMessageLayouter.shared.layout(
            document: document,
            style: NativeLayoutStyle(
                width: 600,
                bodyFontSize: 16,
                appearance: SettingsManager.shared.appearanceMode.rawValue,
                colors: DSTheme.c
            )
        )
        assert(layout.size.height > 100)
        let formula = "\\frac{1}{1+\\frac{1}{1+\\frac{1}{x}}}=\\sum_{k=0}^{20}\\frac{x^k}{k!}"
        let first = NativeFormulaRenderer.shared.artifact(
            tex: formula,
            fontSize: 17,
            color: DSTheme.c.textPrimary,
            display: true
        )
        let second = NativeFormulaRenderer.shared.artifact(
            tex: formula,
            fontSize: 17,
            color: DSTheme.c.textPrimary,
            display: true
        )
        assert(first != nil && second != nil)
        assert(first?.image === second?.image)
        assert(NativeFormulaRenderer.shared.artifact(
            tex: "\\bar{X}_n \\xrightarrow{P} \\mu",
            fontSize: 17,
            color: DSTheme.c.textPrimary,
            display: false
        ) != nil)
        assert(NativeFormulaRenderer.shared.artifact(
            tex: "\\foobar{x}+1",
            fontSize: 17,
            color: DSTheme.c.textPrimary,
            display: false
        ) != nil)
        assert(NativeFormulaRenderer.shared.artifact(
            tex: "a=b\\tag{1}",
            fontSize: 17,
            color: DSTheme.c.textPrimary,
            display: true
        ) != nil)
        let compact = NativeMessageLayouter.shared.layout(
            document: document,
            style: NativeLayoutStyle(
                width: 160,
                bodyFontSize: 16,
                appearance: SettingsManager.shared.appearanceMode.rawValue,
                colors: DSTheme.c
            )
        )
        for command in compact.commands {
            let maxX: CGFloat
            switch command {
            case .text(let fragment): maxX = fragment.frame.maxX
            case .image(_, let frame), .fill(let frame, _, _), .stroke(let frame, _, _):
                maxX = frame.maxX
            case .line(let start, let end, _, let width):
                maxX = max(start.x, end.x) + width
            }
            assert(maxX <= compact.size.width + 1)
        }
        let compactPreview = NativeMessageLayouter.shared.layout(
            document: document,
            style: NativeLayoutStyle(
                width: 160,
                bodyFontSize: 16,
                appearance: SettingsManager.shared.appearanceMode.rawValue,
                colors: DSTheme.c
            ),
            renderMissingFormulas: false
        )
        assert(compactPreview.size.height >= compact.size.height)
        #endif
    }

    #if DEBUG
    private static func runDeviceCorpusIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-NativeRendererCorpus") else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("renderer-corpus.json")
        guard let data = try? Data(contentsOf: url),
              let conversations = try? JSONDecoder().decode([Conversation].self, from: data) else {
            assertionFailure("Unable to load renderer-corpus.json")
            return
        }
        var contents = [String]()
        for conversation in conversations {
            for message in conversation.messages where message.role == .assistant {
                contents.append(message.content)
                contents.append(contentsOf: message.versions.map(\.content))
            }
        }
        for content in Set(contents) where content.contains("\\") {
            let document = NativeMarkdownParser.shared.parse(content)
            for width: CGFloat in [270, 600] {
                let style = NativeLayoutStyle(
                    width: width,
                    bodyFontSize: 16,
                    appearance: SettingsManager.shared.appearanceMode.rawValue,
                    colors: DSTheme.c
                )
                let preview = NativeMessageLayouter.shared.layout(
                    document: document,
                    style: style,
                    renderMissingFormulas: false
                )
                let final = NativeMessageLayouter.shared.layout(document: document, style: style)
                assert(
                    preview.size.height >= final.size.height,
                    "Preview clipped final layout at width \(width)"
                )
                for command in final.commands {
                    let maxY: CGFloat
                    switch command {
                    case .text(let fragment): maxY = fragment.frame.maxY
                    case .image(_, let frame), .fill(let frame, _, _), .stroke(let frame, _, _):
                        maxY = frame.maxY
                    case .line(let start, let end, _, let lineWidth):
                        maxY = max(start.y, end.y) + lineWidth
                    }
                    assert(maxY <= final.size.height + 1, "Draw command exceeds layout height")
                }
            }
        }
    }
    #endif
}
