import Foundation

enum MarkdownNormalizer {
    static func normalize(_ raw: String) -> String {
        normalizeReferenceLinks(MarkdownHTMLRenderer.normalizeForRender(raw))
    }

    private static func normalizeReferenceLinks(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var output = [String]()
        var index = 0
        var inReferences = false

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let headingText = trimmed
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: CharacterSet.whitespaces.union(
                    CharacterSet(charactersIn: "：:")
                ))
            if headingText == "参考链接" || headingText == "参考来源" || headingText == "参考资料" {
                output.append("### 参考来源")
                inReferences = true
                index += 1
                continue
            }
            if inReferences, trimmed.hasPrefix("#") {
                inReferences = false
            }
            if inReferences, trimmed.hasPrefix("- ") {
                let title = String(trimmed.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                if index + 1 < lines.count {
                    let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
                    if next.hasPrefix("https://") || next.hasPrefix("http://") {
                        output.append("- [\(title)](\(next))")
                        index += 2
                        continue
                    }
                }
            }
            if inReferences, trimmed.hasPrefix("https://") || inReferences && trimmed.hasPrefix("http://") {
                output.append("- [查看来源](\(trimmed))")
                index += 1
                continue
            }
            output.append(line)
            index += 1
        }
        return output.joined(separator: "\n")
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
            if tail.hasPrefix("$"), !tail.hasPrefix("$$"),
               let end = source[source.index(after: cursor)...].firstIndex(of: "$") {
                flush()
                result.append(.inlineMath(String(source[source.index(after: cursor)..<end])))
                cursor = source.index(after: end)
                continue
            }
            if tail.hasPrefix("\\(") || tail.hasPrefix("\\[") || tail.hasPrefix("$$") {
                flush()
                let bodyStart = source.index(cursor, offsetBy: 2)
                let body = String(source[bodyStart...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    result.append(.inlineMath(body))
                }
                cursor = source.endIndex
                continue
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
            #"^[A-Za-z](?:_(?:\{[^}\n]+\}|[A-Za-z0-9]+))(?:\^(?:\{[^}\n]+\}|[A-Za-z0-9]+))?"#
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

    private func displayMathStarting(at index: Int, lines: [String]) -> (source: String, next: Int)? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        let pairs: [(String, String)] = [("$$", "$$"), ("\\[", "\\]")]
        for (open, close) in pairs where trimmed.hasPrefix(open) {
            var body = String(trimmed.dropFirst(open.count))
            if body.hasSuffix(close) {
                body.removeLast(close.count)
                return (body, index + 1)
            }
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
        return commandCount >= 2 || (commandCount >= 1 && structural)
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
        let references = NativeMarkdownParser.shared.parse("""
        **参考链接**
        - Example reference
          https://example.com/article
        """)
        assert(references.blocks.contains {
            guard case .list(_, let items) = $0 else { return false }
            return items.flatMap { $0 }.contains {
                if case .link(_, let url) = $0 { return url?.host == "example.com" }
                return false
            }
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
