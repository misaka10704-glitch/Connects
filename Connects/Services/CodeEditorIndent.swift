import Foundation

/// Newline auto-indent for the Study code editor (spaces only, tabWidth = 4).
enum CodeEditorIndent {
    static let tabWidth = 4
    static var indentUnit: String { String(repeating: " ", count: tabWidth) }

    /// Leading spaces/tabs on `line` (tabs count as one character each in the prefix string).
    static func leadingWhitespace(of line: String) -> String {
        var end = line.startIndex
        while end < line.endIndex {
            let ch = line[end]
            if ch == " " || ch == "\t" {
                end = line.index(after: end)
            } else {
                break
            }
        }
        return String(line[line.startIndex..<end])
    }

    /// UTF-16 range of non-whitespace content within a line (excludes leading/trailing spaces/tabs and the trailing newline).
    /// Empty / whitespace-only lines collapse to a zero-length range at the first content column (after indent).
    static func contentBounds(inLine lineRange: NSRange, of ns: NSString) -> NSRange {
        let lineEnd = NSMaxRange(lineRange)
        var bodyEnd = lineEnd
        if bodyEnd > lineRange.location {
            let last = ns.character(at: bodyEnd - 1)
            if last == 10 || last == 13 { bodyEnd -= 1 }
            if bodyEnd > lineRange.location, ns.character(at: bodyEnd - 1) == 13 {
                bodyEnd -= 1
            }
        }
        var start = lineRange.location
        while start < bodyEnd {
            let c = ns.character(at: start)
            if c == 32 || c == 9 { start += 1 } else { break }
        }
        var end = bodyEnd
        while end > start {
            let c = ns.character(at: end - 1)
            if c == 32 || c == 9 { end -= 1 } else { break }
        }
        return NSRange(location: start, length: end - start)
    }

    /// Text to insert after a newline at UTF-16 `location` in `fullText` (caret before the new line).
    static func insertionAfterNewline(fullText: String, location: Int, language: StudyTextLanguage) -> String {
        let ns = fullText as NSString
        let len = ns.length
        let loc = max(0, min(location, len))
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        var indent = leadingWhitespace(of: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        switch language {
        case .c, .verilog:
            if shouldIncreaseIndent(trimmedLine: trimmed, language: language) {
                indent += indentUnit
            }
        case .python:
            if trimmed.hasSuffix(":") {
                indent += indentUnit
            }
        case .markdown:
            // List / fence: keep same leading whitespace (no extra indent layer).
            break
        case .plain:
            break
        }
        return "\n" + indent
    }

    private static func shouldIncreaseIndent(trimmedLine: String, language: StudyTextLanguage) -> Bool {
        if trimmedLine.hasSuffix("{") { return true }
        if language == .verilog {
            let lower = trimmedLine.lowercased()
            if lower == "begin" || lower.hasSuffix(" begin") { return true }
        }
        return false
    }
}
