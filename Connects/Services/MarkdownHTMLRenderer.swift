import Foundation

/// Markdown normalization shared by the native renderer (no WebKit path).
enum MarkdownHTMLRenderer {
    /// Render-time normalize (does not mutate stored conversation text).
    static func normalizeForRender(_ raw: String) -> String {
        var s = normalizeMathDelimiters(raw)
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        // Old / CN model fullwidth table punctuation → GFM
        s = s.replacingOccurrences(of: "｜", with: "|")
        s = s.replacingOccurrences(of: "－", with: "-")
        s = s.replacingOccurrences(of: "—", with: "-")
        // Collapse 3+ blank lines left by older plain renderers / copy-paste
        while s.contains("\n\n\n\n") {
            s = s.replacingOccurrences(of: "\n\n\n\n", with: "\n\n\n")
        }
        return s
    }

    /// Normalize odd model outputs toward KaTeX-friendly delimiters.
    static func normalizeMathDelimiters(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "［", with: "[")
        s = s.replacingOccurrences(of: "］", with: "]")
        s = s.replacingOccurrences(of: "＄", with: "$")
        s = s.replacingOccurrences(of: "\\（", with: "\\(")
        s = s.replacingOccurrences(of: "\\）", with: "\\)")
        if let re = try? NSRegularExpression(
            pattern: "```(?:math|latex|tex|katex|formula|equation)(?:[ \\t]*\\n|[ \\t]+)([\\s\\S]*?)```",
            options: [.caseInsensitive]
        ) {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = re.stringByReplacingMatches(
                in: s,
                options: [],
                range: range,
                withTemplate: #"\$\$$1\$\$"#
            )
        }
        // Other chat providers use BBCode/XML-style math wrappers.
        let wrapperPatterns = [
            #"(?is)\[(?:math|latex|tex)\](.*?)\[/(?:math|latex|tex)\]"#,
            #"(?is)<math(?:\s[^>]*)?>(.*?)</math>"#
        ]
        for pattern in wrapperPatterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = re.stringByReplacingMatches(
                in: s,
                options: [],
                range: range,
                withTemplate: #"\$\$$1\$\$"#
            )
        }
        // Some providers double-escape delimiters while serialising JSON.
        let escapedDelimiters = [
            (#"\\{2,}\("#, #"\\("#),
            (#"\\{2,}\)"#, #"\\)"#),
            (#"\\{2,}\["#, #"\\["#),
            (#"\\{2,}\]"#, #"\\]"#),
            (#"\\{2,}begin\{"#, #"\\begin{"#),
            (#"\\{2,}end\{"#, #"\\end{"#)
        ]
        for (pattern, template) in escapedDelimiters {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = re.stringByReplacingMatches(
                in: s,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        s = decodeDoubleEscapedCommandsInsideMath(s)

        let lines = s.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let openingBraces = trimmed.filter { $0 == "{" }.count
            let closingBraces = trimmed.filter { $0 == "}" }.count
            guard trimmed.hasPrefix("\\"),
                  !trimmed.hasPrefix("\\["),
                  !trimmed.hasPrefix("\\("),
                  !trimmed.hasPrefix("\\begin{"),
                  trimmed.range(
                    of: #"^\\(?:boxed|displaystyle|frac|dfrac|tfrac|sum|prod|int|iint|iiint|lim|sqrt|left)\b"#,
                    options: .regularExpression
                  ) != nil,
                  openingBraces == closingBraces else { return line }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            return "\(indent)$$\(trimmed)$$"
        }
        s = lines.joined(separator: "\n")
        return s
    }

    private static func decodeDoubleEscapedCommandsInsideMath(_ source: String) -> String {
        var result = source
        let spanPatterns = [
            #"(?s)\\\((.*?)\\\)"#,
            #"(?s)\\\[(.*?)\\\]"#,
            #"(?s)\$\$(.*?)\$\$"#,
            #"(?s)\\begin\{([A-Za-z*]+)\}(.*?)\\end\{\1\}"#,
            #"(?s)(?<!\\)(?<!\$)\$(?!\$)(.+?)(?<!\\)\$(?!\$)"#
        ]
        for pattern in spanPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(location: 0, length: (result as NSString).length)
            let matches = regex.matches(in: result, options: [], range: fullRange)
            for match in matches.reversed() {
                let bodyIndex = pattern.contains(#"begin\{"#) ? 2 : 1
                guard match.numberOfRanges > bodyIndex,
                      match.range(at: bodyIndex).location != NSNotFound else { continue }
                let ns = result as NSString
                let bodyRange = match.range(at: bodyIndex)
                let body = ns.substring(with: bodyRange)
                guard containsDoubleEscapedCommand(body) else { continue }
                let decoded = body.replacingOccurrences(of: "\\\\", with: "\\")
                result = ns.replacingCharacters(in: bodyRange, with: decoded)
            }
        }
        return result
    }

    private static func containsDoubleEscapedCommand(_ source: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"\\\\(?:[A-Za-z]+|[,;:!])"#
        ) else { return false }
        let range = NSRange(location: 0, length: (source as NSString).length)
        return regex.firstMatch(in: source, options: [], range: range) != nil
    }
}
