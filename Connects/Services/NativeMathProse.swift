import Foundation

/// iosMath / XITS has no CJK glyphs, and `\text{…}` prose inside math often
/// includes quotes/punctuation that look broken when forced through `\mathrm`.
/// Expand mixed prose math into Native text + inline-math islands.
enum NativeMathProse {
    static func needsExpansion(_ tex: String) -> Bool {
        if containsCJK(tex) { return true }
        return hasExpandableTextCommand(tex)
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { isCJKScalar($0) }
    }

    /// Split TeX into iosMath fragments, CJK script hybrids, and prose text.
    static func decompose(_ tex: String) -> [NativeInline] {
        let source = tex
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }

        var result = [NativeInline]()
        var mathStart = source.startIndex
        var index = source.startIndex

        func flushMath(upTo end: String.Index) {
            guard end > mathStart else { return }
            let chunk = String(source[mathStart..<end])
            if !chunk.isEmpty {
                result.append(.inlineMath(chunk))
            }
            mathStart = end
        }

        while index < source.endIndex {
            if let match = cjkScriptGroup(at: index, in: source) {
                let base = extractScriptHost(before: match.scriptStart, in: source)
                let baseStart = baseStartIndex(before: match.scriptStart, base: base, in: source)
                flushMath(upTo: baseStart)
                result.append(.mathWithScript(
                    base: base,
                    script: match.script,
                    kind: match.kind
                ))
                index = match.end
                mathStart = index
                continue
            }

            if let command = textCommand(at: index, in: source, proseOnly: false) {
                flushMath(upTo: index)
                result.append(.text(command.content))
                index = command.end
                mathStart = index
                continue
            }

            let ch = source[index]
            if let scalar = ch.unicodeScalars.first, isCJKScalar(scalar) {
                flushMath(upTo: index)
                var end = source.index(after: index)
                while end < source.endIndex {
                    guard let next = source[end].unicodeScalars.first, isCJKScalar(next) else { break }
                    end = source.index(after: end)
                }
                result.append(.text(String(source[index..<end])))
                index = end
                mathStart = index
                continue
            }

            index = source.index(after: index)
        }
        flushMath(upTo: source.endIndex)
        return coalesceAdjacentMath(result)
    }

    static func expandToInlines(_ tex: String) -> [NativeInline] {
        decompose(tex)
    }

    /// Peel a leading `\\text{…}` (and kin) so chat prose does not leak the command.
    static func peelTextCommand(at start: String.Index,
                                in source: String) -> (content: String, end: String.Index)? {
        guard let command = textCommand(at: start, in: source, proseOnly: false) else { return nil }
        return (command.content, command.end)
    }

    private static func coalesceAdjacentMath(_ inlines: [NativeInline]) -> [NativeInline] {
        var merged = [NativeInline]()
        for inline in inlines {
            switch inline {
            case .inlineMath(let tex):
                if case .inlineMath(let prior)? = merged.last {
                    merged[merged.count - 1] = .inlineMath(prior + tex)
                } else {
                    merged.append(inline)
                }
            default:
                merged.append(inline)
            }
        }
        return merged
    }

    private struct CJKScriptMatch {
        let scriptStart: String.Index
        let end: String.Index
        let script: String
        let kind: NativeMathScriptKind
    }

    private static func cjkScriptGroup(at index: String.Index,
                                       in source: String) -> CJKScriptMatch? {
        guard index < source.endIndex else { return nil }
        let marker = source[index]
        guard marker == "_" || marker == "^" else { return nil }
        let kind: NativeMathScriptKind = marker == "_" ? .sub : .sup
        let contentStart = source.index(after: index)
        guard contentStart < source.endIndex else { return nil }

        let content: String
        let end: String.Index
        if source[contentStart] == "{" {
            guard let close = closingBrace(from: source.index(after: contentStart), in: source) else {
                return nil
            }
            content = String(source[source.index(after: contentStart)..<close])
            end = source.index(after: close)
        } else {
            content = String(source[contentStart])
            end = source.index(after: contentStart)
        }

        let script = unwrapTextCommand(content)
        guard containsCJK(script) else { return nil }
        return CJKScriptMatch(
            scriptStart: index,
            end: end,
            script: script,
            kind: kind
        )
    }

    private static func baseStartIndex(before scriptStart: String.Index,
                                       base: String,
                                       in source: String) -> String.Index {
        guard !base.isEmpty else { return scriptStart }
        return source.index(scriptStart, offsetBy: -base.count, limitedBy: source.startIndex)
            ?? source.startIndex
    }

    private static func extractScriptHost(before scriptStart: String.Index,
                                          in source: String) -> String {
        guard scriptStart > source.startIndex else { return "" }
        var index = source.index(before: scriptStart)
        while index > source.startIndex, source[index].isWhitespace {
            index = source.index(before: index)
        }
        guard index >= source.startIndex else { return "" }

        if source[index] == "}" {
            var depth = 1
            var cursor = source.index(before: index)
            while cursor > source.startIndex {
                switch source[cursor] {
                case "}":
                    depth += 1
                case "{":
                    depth -= 1
                    if depth == 0 {
                        return String(source[cursor...index])
                    }
                default:
                    break
                }
                cursor = source.index(before: cursor)
            }
            return ""
        }

        var start = index
        while start > source.startIndex {
            let prev = source.index(before: start)
            let ch = source[prev]
            if ch.isLetter || ch.isNumber || ch == "\\" || ch == "'" || ch == ")" {
                start = prev
            } else {
                break
            }
        }
        return String(source[start...index])
    }

    private static func unwrapTextCommand(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["\\text{", "\\mbox{", "\\textrm{", "\\mathrm{"]
        for prefix in prefixes {
            guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("}") else { continue }
            let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let end = trimmed.index(before: trimmed.endIndex)
            return String(trimmed[start..<end])
        }
        return trimmed
    }

    private static func hasExpandableTextCommand(_ tex: String) -> Bool {
        var index = tex.startIndex
        while index < tex.endIndex {
            if let command = textCommand(at: index, in: tex, proseOnly: true) {
                if command.forceExpand { return true }
                index = command.end
                continue
            }
            index = tex.index(after: index)
        }
        return false
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,
             0x3040...0x30FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    private static func isProseTextBody(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if containsCJK(trimmed) { return true }
        if trimmed.contains(where: { $0 == " " || $0 == "\t" }) { return true }
        if trimmed.contains(where: {
            "\"'\u{201C}\u{201D}\u{2018}\u{2019}\u{300C}\u{300D}\u{300E}\u{300F}".contains($0)
        }) {
            return true
        }
        if trimmed.count >= 12 { return true }
        return false
    }

    private static func textCommand(
        at start: String.Index,
        in source: String,
        proseOnly: Bool
    ) -> (content: String, end: String.Index, forceExpand: Bool)? {
        let tail = source[start...]
        let commands: [(prefix: String, alwaysPeel: Bool)] = [
            ("\\textbf{", true),
            ("\\textit{", true),
            ("\\textsf{", true),
            ("\\texttt{", true),
            ("\\textrm{", true),
            ("\\text{", true),
            ("\\mbox{", true),
            ("\\hbox{", true),
            ("\\mathrm{", false)
        ]
        for command in commands {
            guard tail.hasPrefix(command.prefix) else { continue }
            let contentStart = source.index(start, offsetBy: command.prefix.count)
            guard let close = closingBrace(from: contentStart, in: source) else { return nil }
            let content = String(source[contentStart..<close])
            let prose = isProseTextBody(content)
            if proseOnly {
                guard prose || (command.alwaysPeel && containsCJK(content)) else { return nil }
            } else if !command.alwaysPeel, !prose {
                return nil
            }
            let end = source.index(after: close)
            return (content, end, true)
        }
        return nil
    }

    private static func closingBrace(
        from start: String.Index,
        in source: String
    ) -> String.Index? {
        var depth = 1
        var index = start
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
