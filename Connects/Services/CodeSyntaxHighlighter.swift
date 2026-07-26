import UIKit

enum CodeHighlightToken {
    case keyword
    case typeName
    case number
    case stringLiteral
    case comment
    case macro
    case `default`
}

struct CodeHighlightPalette {
    let `default`: UIColor
    let keyword: UIColor
    let typeName: UIColor
    let number: UIColor
    let stringLiteral: UIColor
    let comment: UIColor
    let macro: UIColor

    static var current: CodeHighlightPalette {
        ThemeManager.shared.mode == .light ? .light : .dark
    }

    static let dark = CodeHighlightPalette(
        default: UIColor(red: 212/255, green: 212/255, blue: 212/255, alpha: 1),
        keyword: UIColor(red: 86/255, green: 156/255, blue: 214/255, alpha: 1),
        typeName: UIColor(red: 78/255, green: 201/255, blue: 176/255, alpha: 1),
        number: UIColor(red: 181/255, green: 206/255, blue: 168/255, alpha: 1),
        stringLiteral: UIColor(red: 206/255, green: 145/255, blue: 120/255, alpha: 1),
        comment: UIColor(red: 106/255, green: 153/255, blue: 85/255, alpha: 1),
        macro: UIColor(red: 190/255, green: 145/255, blue: 95/255, alpha: 1)
    )

    static let light = CodeHighlightPalette(
        default: UIColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1),
        keyword: UIColor(red: 0/255, green: 0/255, blue: 255/255, alpha: 1),
        typeName: UIColor(red: 38/255, green: 127/255, blue: 153/255, alpha: 1),
        number: UIColor(red: 9/255, green: 134/255, blue: 88/255, alpha: 1),
        stringLiteral: UIColor(red: 163/255, green: 21/255, blue: 21/255, alpha: 1),
        comment: UIColor(red: 0/255, green: 128/255, blue: 0/255, alpha: 1),
        macro: UIColor(red: 175/255, green: 0/255, blue: 219/255, alpha: 1)
    )

    func color(for token: CodeHighlightToken) -> UIColor {
        switch token {
        case .keyword: return keyword
        case .typeName: return typeName
        case .number: return number
        case .stringLiteral: return stringLiteral
        case .comment: return comment
        case .macro: return macro
        case .default: return `default`
        }
    }
}

enum CodeSyntaxHighlighter {
    static let defaultPointSize: CGFloat = 13

    static func font(size: CGFloat = defaultPointSize) -> UIFont {
        UIFont(name: "Menlo-Regular", size: size)
            ?? UIFont(name: "Courier", size: size)
            ?? UIFont.systemFont(ofSize: size)
    }

    /// Shared paragraph metrics so gutter line numbers track editor line boxes.
    static func paragraphStyle(fontSize: CGFloat = defaultPointSize) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.alignment = .left
        let h = font(size: fontSize).lineHeight
        style.minimumLineHeight = h
        style.maximumLineHeight = h
        return style
    }

    static func typingAttributes(palette: CodeHighlightPalette = .current,
                                 fontSize: CGFloat = defaultPointSize) -> [NSAttributedString.Key: Any] {
        [
            .font: font(size: fontSize),
            .foregroundColor: palette.default,
            .paragraphStyle: paragraphStyle(fontSize: fontSize)
        ]
    }

    static func lineNumberAttributes(fontSize: CGFloat = defaultPointSize) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        // Never wrap digits — a tight gutter used to break "100"+ into two rows and desync.
        style.lineBreakMode = .byClipping
        let h = font(size: fontSize).lineHeight
        style.minimumLineHeight = h
        style.maximumLineHeight = h
        return [
            .font: font(size: fontSize),
            .foregroundColor: DSTheme.c.textTertiary,
            .paragraphStyle: style
        ]
    }

    /// Gutter width for `digits` of Menlo line numbers (includes text-container insets).
    static func lineNumberGutterWidth(digits: Int, fontSize: CGFloat = defaultPointSize) -> CGFloat {
        let count = max(2, digits)
        let sample = String(repeating: "0", count: count)
        let attrs = lineNumberAttributes(fontSize: fontSize)
        let textW = ceil((sample as NSString).size(withAttributes: attrs).width)
        // Match TextCodeEditor insets: left 4 + right 8, plus a little breathing room.
        return max(40, textW + 4 + 8 + 10)
    }

    static func highlight(_ source: String,
                          language: StudyTextLanguage,
                          palette: CodeHighlightPalette = .current,
                          fontSize: CGFloat = defaultPointSize) -> NSAttributedString {
        let ns = source as NSString
        let full = NSRange(location: 0, length: ns.length)
        let result = NSMutableAttributedString(
            string: source,
            attributes: typingAttributes(palette: palette, fontSize: fontSize)
        )
        guard language != .plain, full.length > 0 else { return result }

        // Order: comments/strings first so keywords inside them stay muted.
        apply(patterns: commentPatterns(for: language), token: .comment, on: result, full: full, palette: palette)
        apply(patterns: stringPatterns(for: language), token: .stringLiteral, on: result, full: full, palette: palette)
        apply(patterns: macroPatterns(for: language), token: .macro, on: result, full: full, palette: palette)
        apply(patterns: numberPatterns(for: language), token: .number, on: result, full: full, palette: palette)
        apply(patterns: typePatterns(for: language), token: .typeName, on: result, full: full, palette: palette)
        apply(patterns: keywordPatterns(for: language), token: .keyword, on: result, full: full, palette: palette)
        return result
    }

    private static func apply(patterns: [String],
                              token: CodeHighlightToken,
                              on result: NSMutableAttributedString,
                              full: NSRange,
                              palette: CodeHighlightPalette) {
        let color = palette.color(for: token)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            regex.enumerateMatches(in: result.string, options: [], range: full) { match, _, _ in
                guard let match = match else { return }
                let range = match.range
                guard range.location != NSNotFound else { return }
                // Skip if already comment/string (higher priority painted first).
                if token != .comment && token != .stringLiteral {
                    if isProtected(result, range: range, palette: palette) { return }
                }
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
    }

    private static func isProtected(_ attr: NSAttributedString,
                                    range: NSRange,
                                    palette: CodeHighlightPalette) -> Bool {
        guard range.length > 0, range.location < attr.length else { return false }
        let sampleLoc = range.location
        let color = attr.attribute(.foregroundColor, at: sampleLoc, effectiveRange: nil) as? UIColor
        return color == palette.comment || color == palette.stringLiteral
    }

    private static func keywordPatterns(for language: StudyTextLanguage) -> [String] {
        let words: [String]
        switch language {
        case .verilog:
            words = [
                "module", "endmodule", "primitive", "endprimitive", "macromodule",
                "input", "output", "inout", "wire", "reg", "integer", "real", "time", "realtime",
                "parameter", "localparam", "defparam", "assign", "always", "initial",
                "begin", "end", "if", "else", "case", "casex", "casez", "endcase",
                "for", "while", "repeat", "forever", "fork", "join",
                "posedge", "negedge", "or", "and", "not", "nand", "nor", "xor", "xnor",
                "generate", "endgenerate", "genvar", "function", "endfunction",
                "task", "endtask", "specify", "endspecify", "pulsestyle_onevent",
                "signed", "unsigned", "automatic", "static", "wait", "disable",
                "default", "typedef", "enum", "struct", "union", "logic", "bit", "byte",
                "shortint", "longint", "void", "string", "chandle", "virtual", "class",
                "endclass", "package", "endpackage", "import", "export", "interface",
                "endinterface", "modport", "clocking", "endclocking", "property",
                "endproperty", "sequence", "endsequence", "assert", "assume", "cover",
                "unique", "priority", "return", "break", "continue", "foreach",
                "do", "with", "inside", "dist", "rand", "randc", "constraint",
                "pure", "extern", "ref", "const", "var"
            ]
        case .c:
            words = [
                "auto", "break", "case", "char", "const", "continue", "default", "do",
                "double", "else", "enum", "extern", "float", "for", "goto", "if",
                "inline", "int", "long", "register", "restrict", "return", "short",
                "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
                "unsigned", "void", "volatile", "while", "_Bool", "_Complex", "_Imaginary"
            ]
        case .python:
            words = [
                "False", "None", "True", "and", "as", "assert", "async", "await",
                "break", "class", "continue", "def", "del", "elif", "else", "except",
                "finally", "for", "from", "global", "if", "import", "in", "is",
                "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
                "while", "with", "yield"
            ]
        case .plain:
            return []
        }
        let alt = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return ["\\b(?:\(alt))\\b"]
    }

    private static func typePatterns(for language: StudyTextLanguage) -> [String] {
        switch language {
        case .verilog:
            return ["\\b(?:integer|real|time|realtime|logic|bit|byte|shortint|longint|string|chandle|void)\\b"]
        case .c:
            return ["\\b(?:size_t|ssize_t|uint8_t|uint16_t|uint32_t|uint64_t|int8_t|int16_t|int32_t|int64_t|FILE)\\b"]
        case .python:
            return []
        case .plain:
            return []
        }
    }

    private static func numberPatterns(for language: StudyTextLanguage) -> [String] {
        switch language {
        case .verilog:
            return [
                "\\b\\d+'[sS]?[bB][01_xXzZ]+\\b",
                "\\b\\d+'[sS]?[oO][0-7_xXzZ]+\\b",
                "\\b\\d+'[sS]?[dD][0-9_xXzZ]+\\b",
                "\\b\\d+'[sS]?[hH][0-9a-fA-F_xXzZ]+\\b",
                "\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b"
            ]
        case .c, .python, .plain:
            return [
                "\\b0[xX][0-9a-fA-F_]+\\b",
                "\\b0[bB][01_]+\\b",
                "\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b"
            ]
        }
    }

    private static func stringPatterns(for language: StudyTextLanguage) -> [String] {
        switch language {
        case .python:
            return [
                "\"\"\"[\\s\\S]*?\"\"\"",
                "'''[\\s\\S]*?'''",
                "\"(?:\\\\.|[^\"\\\\])*\"",
                "'(?:\\\\.|[^'\\\\])*'"
            ]
        default:
            return ["\"(?:\\\\.|[^\"\\\\])*\""]
        }
    }

    private static func commentPatterns(for language: StudyTextLanguage) -> [String] {
        switch language {
        case .python:
            return ["#[^\n]*"]
        case .verilog, .c, .plain:
            return ["//[^\n]*", "/\\*[\\s\\S]*?\\*/"]
        }
    }

    private static func macroPatterns(for language: StudyTextLanguage) -> [String] {
        switch language {
        case .verilog:
            return ["`[A-Za-z_][A-Za-z0-9_]*"]
        case .c:
            return ["^\\s*#\\s*(?:include|define|ifdef|ifndef|endif|else|elif|pragma|undef)\\b.*",
                    "\\b[A-Z_][A-Z0-9_]{2,}\\b"]
        case .python, .plain:
            return []
        }
    }
}
