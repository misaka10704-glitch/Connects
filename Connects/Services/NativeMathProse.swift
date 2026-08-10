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

    static func expandToInlines(_ tex: String) -> [NativeInline] {
        let source = tex
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }

        var segments = [(isMath: Bool, text: String)]()
        var index = source.startIndex
        var mathBuffer = ""

        func flushMath() {
            let trimmed = mathBuffer.trimmingCharacters(in: .whitespaces)
            mathBuffer = ""
            guard !trimmed.isEmpty else { return }
            if let last = segments.last, last.isMath {
                segments[segments.count - 1] = (true, last.text + " " + trimmed)
            } else {
                segments.append((true, trimmed))
            }
        }

        func appendText(_ raw: String) {
            guard !raw.isEmpty else { return }
            flushMath()
            if let last = segments.last, !last.isMath {
                segments[segments.count - 1] = (false, last.text + raw)
            } else {
                segments.append((false, raw))
            }
        }

        while index < source.endIndex {
            if let command = textCommand(at: index, in: source, proseOnly: false) {
                appendText(command.content)
                index = command.end
                continue
            }

            let ch = source[index]
            if let scalar = ch.unicodeScalars.first, isCJKScalar(scalar) {
                flushMath()
                var end = source.index(after: index)
                while end < source.endIndex {
                    guard let next = source[end].unicodeScalars.first, isCJKScalar(next) else { break }
                    end = source.index(after: end)
                }
                appendText(String(source[index..<end]))
                index = end
                continue
            }

            mathBuffer.append(ch)
            index = source.index(after: index)
        }
        flushMath()

        return segments.compactMap { seg in
            if seg.isMath {
                return .inlineMath(seg.text)
            }
            return .text(seg.text)
        }
    }

    /// True when TeX embeds prose-oriented text commands (not a lone Latin `\mathrm{d}`).
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

    /// Body looks like prose (spaces, CJK, quotes) rather than a short math label.
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
        // Multi-word punctuation prose without spaces — long runs still peel.
        if trimmed.count >= 12 { return true }
        return false
    }

    /// - Parameter proseOnly: when true (needsExpansion scan), only hit prose bodies.
    ///   when false (expand pass), peel every `\text`/`\mbox`/… command.
    private static func textCommand(
        at start: String.Index,
        in source: String,
        proseOnly: Bool
    ) -> (content: String, end: String.Index, forceExpand: Bool)? {
        let tail = source[start...]
        // Longer prefixes first (`textbf` before `text`).
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
                // Trigger whole-formula expansion only for real prose / CJK.
                guard prose || (command.alwaysPeel && containsCJK(content)) else { return nil }
            } else {
                // Expanding: peel all `\text` family; `\mathrm` only when prose/CJK.
                if !command.alwaysPeel, !prose { return nil }
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
