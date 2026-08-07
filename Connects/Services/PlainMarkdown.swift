import UIKit

/// Lightweight markdown → attributed string (no WKWebView). Safe on iOS 12 / low RAM.
enum PlainMarkdown {
    private static let cache = NSCache<NSString, NSAttributedString>()

    static func attributed(_ raw: String,
                           bodyFont: UIFont,
                           textColor: UIColor,
                           secondaryColor: UIColor,
                           cacheKey: String? = nil) -> NSAttributedString {
        if let key = cacheKey as NSString? {
            if let hit = cache.object(forKey: key) { return hit }
            let built = build(raw, bodyFont: bodyFont, textColor: textColor, secondaryColor: secondaryColor)
            cache.setObject(built, forKey: key)
            return built
        }
        return build(raw, bodyFont: bodyFont, textColor: textColor, secondaryColor: secondaryColor)
    }

    static func clearCache() {
        cache.removeAllObjects()
    }

    private static func build(_ raw: String,
                              bodyFont: UIFont,
                              textColor: UIColor,
                              secondaryColor: UIColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: textColor
        ]
        let boldFont = UIFont.systemFont(ofSize: bodyFont.pointSize, weight: .semibold)
        let mono = UIFont(name: "Menlo", size: bodyFont.pointSize * 0.92) ?? bodyFont

        // Keep fenced blocks as mono text — never strip ``` into blank lines.
        let paragraphs = flattenFencedCode(raw).components(separatedBy: "\n")
        var pendingBlank = false
        for line in paragraphs {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if out.length > 0 { pendingBlank = true }
                continue
            }
            if out.length > 0 {
                out.append(NSAttributedString(string: pendingBlank ? "\n\n" : "\n", attributes: base))
            }
            pendingBlank = false
            appendLine(line, to: out, base: base, boldFont: boldFont, mono: mono, textColor: textColor, secondary: secondaryColor)
        }
        return out
    }

    /// ```lang ... ``` → indented mono lines (fallback when WebView not used).
    private static func flattenFencedCode(_ raw: String) -> String {
        guard raw.contains("```") else { return raw }
        var out = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i...].hasPrefix("```") {
                var j = raw.index(i, offsetBy: 3, limitedBy: raw.endIndex) ?? raw.endIndex
                while j < raw.endIndex, raw[j] != "\n" { j = raw.index(after: j) }
                if j < raw.endIndex { j = raw.index(after: j) }
                if let end = raw.range(of: "```", range: j..<raw.endIndex) {
                    let body = String(raw[j..<end.lowerBound])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                    if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
                    for line in body.components(separatedBy: "\n") {
                        out += "  " + line + "\n"
                    }
                    i = end.upperBound
                    if i < raw.endIndex, raw[i] == "\n" { i = raw.index(after: i) }
                    continue
                }
            }
            out.append(raw[i])
            i = raw.index(after: i)
        }
        return out
    }

    private static func appendLine(_ line: String,
                                   to out: NSMutableAttributedString,
                                   base: [NSAttributedString.Key: Any],
                                   boldFont: UIFont,
                                   mono: UIFont,
                                   textColor: UIColor,
                                   secondary: UIColor) {
        var s = line
        // Headings
        if s.hasPrefix("### ") {
            s = String(s.dropFirst(4))
            out.append(NSAttributedString(string: s, attributes: [
                .font: UIFont.systemFont(ofSize: boldFont.pointSize + 1, weight: .semibold),
                .foregroundColor: textColor
            ]))
            return
        }
        if s.hasPrefix("## ") {
            s = String(s.dropFirst(3))
            out.append(NSAttributedString(string: s, attributes: [
                .font: UIFont.systemFont(ofSize: boldFont.pointSize + 2, weight: .semibold),
                .foregroundColor: textColor
            ]))
            return
        }
        if s.hasPrefix("# ") {
            s = String(s.dropFirst(2))
            out.append(NSAttributedString(string: s, attributes: [
                .font: UIFont.systemFont(ofSize: boldFont.pointSize + 4, weight: .bold),
                .foregroundColor: textColor
            ]))
            return
        }
        // Table rows — keep as mono
        if s.contains("|") && s.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            out.append(NSAttributedString(string: s, attributes: [
                .font: mono,
                .foregroundColor: textColor
            ]))
            return
        }
        // Unordered list
        if s.hasPrefix("- ") || s.hasPrefix("* ") {
            s = "• " + String(s.dropFirst(2))
        }

        // Inline **bold**, `code`, skip remaining markdown chars lightly
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "`" {
                if let end = s[s.index(after: i)...].firstIndex(of: "`") {
                    let code = String(s[s.index(after: i)..<end])
                    out.append(NSAttributedString(string: code, attributes: [
                        .font: mono,
                        .foregroundColor: textColor,
                        .backgroundColor: UIColor.gray.withAlphaComponent(0.2)
                    ]))
                    i = s.index(after: end)
                    continue
                }
            }
            if s.count >= 2, s[i] == "*", i < s.index(before: s.endIndex), s[s.index(after: i)] == "*" {
                let start = s.index(i, offsetBy: 2)
                if let endRange = s.range(of: "**", range: start..<s.endIndex) {
                    let bold = String(s[start..<endRange.lowerBound])
                    out.append(NSAttributedString(string: bold, attributes: [
                        .font: boldFont,
                        .foregroundColor: DSTheme.c.mdBoldFg
                    ]))
                    i = endRange.upperBound
                    continue
                }
            }
            // single char
            out.append(NSAttributedString(string: String(s[i]), attributes: base))
            i = s.index(after: i)
        }
    }
}
