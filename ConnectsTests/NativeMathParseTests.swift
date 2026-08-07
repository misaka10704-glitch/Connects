import XCTest
@testable import Connects

final class NativeMathParseTests: XCTestCase {
    private func describe(_ blocks: [NativeMessageBlock]) -> String {
        blocks.map { block in
            switch block {
            case .displayMath(let tex):
                return "displayMath:\(tex.debugDescription)"
            case .paragraph(let inlines):
                return "paragraph:\(describeInlines(inlines))"
            case .heading(let level, let inlines):
                return "heading\(level):\(describeInlines(inlines))"
            case .codeBlock(let language, let code):
                return "code(\(language ?? "")):\(code.debugDescription)"
            default:
                return "other"
            }
        }.joined(separator: " | ")
    }

    private func describeInlines(_ inlines: [NativeInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let t): return "text:\(t.debugDescription)"
            case .inlineMath(let t): return "inlineMath:\(t.debugDescription)"
            case .lineBreak: return "br"
            case .bold(let kids): return "bold:\(describeInlines(kids))"
            case .italic(let kids): return "italic:\(describeInlines(kids))"
            case .inlineCode(let t): return "code:\(t.debugDescription)"
            case .link(let kids, _): return "link:\(describeInlines(kids))"
            }
        }.joined(separator: ",")
    }

    private func style() -> NativeLayoutStyle {
        NativeLayoutStyle(
            width: 320,
            bodyFontSize: 16,
            appearance: "light",
            colors: DSTheme.c
        )
    }

    private func hasFormulaImage(_ layout: NativeMessageLayout) -> Bool {
        if layout.commands.contains(where: {
            if case .image = $0 { return true }
            return false
        }) {
            return true
        }
        // Inline math is painted as NSTextAttachment inside .text commands.
        return layout.commands.contains { cmd in
            guard case .text(let frag) = cmd else { return false }
            var found = false
            frag.attributedText.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: frag.attributedText.length)
            ) { value, _, stop in
                if value is NSTextAttachment {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }
    }

    func testMultiLineDollarFracParsesAsSingleDisplayMath() {
        NativeMarkdownParser.shared.clear()
        let raw = "$$\n\\frac{a}{b}\n$$"
        let normalized = MarkdownHTMLRenderer.normalizeForRender(raw)
        XCTAssertFalse(
            normalized.contains("$$\n$$"),
            "must not nest bare-wrap inside an open $$ fence: \(normalized.debugDescription)"
        )
        let doc = NativeMarkdownParser.shared.parse(raw)
        XCTAssertEqual(doc.blocks.count, 1, describe(doc.blocks))
        guard case .displayMath(let tex) = doc.blocks[0] else {
            return XCTFail(describe(doc.blocks))
        }
        XCTAssertEqual(tex.trimmingCharacters(in: .whitespacesAndNewlines), #"\frac{a}{b}"#)
    }

    func testSimpleFracDisplayProducesImage() {
        NativeMarkdownParser.shared.clear()
        NativeMessageLayouter.shared.clear()
        NativeFormulaRenderer.shared.clear()
        let doc = NativeMarkdownParser.shared.parse(#"$$\frac{a}{b}$$"#)
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .displayMath = $0 { return true }
            return false
        }), describe(doc.blocks))
        let layout = NativeMessageLayouter.shared.layout(
            document: doc,
            style: style(),
            renderMissingFormulas: true
        )
        XCTAssertTrue(hasFormulaImage(layout), "expected iosMath image for \\frac")
    }

    func testInlineDollarMathProducesAttachment() {
        NativeMarkdownParser.shared.clear()
        NativeMessageLayouter.shared.clear()
        NativeFormulaRenderer.shared.clear()
        let doc = NativeMarkdownParser.shared.parse("因此 $$E=mc^2$$ 成立")
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .paragraph(let inlines) = $0 {
                return inlines.contains {
                    if case .inlineMath = $0 { return true }
                    return false
                }
            }
            return false
        }), describe(doc.blocks))
        let layout = NativeMessageLayouter.shared.layout(
            document: doc,
            style: style(),
            renderMissingFormulas: true
        )
        XCTAssertTrue(hasFormulaImage(layout), "expected inline attachment for $$ math")
    }

    func testFencedLatexStillBecomesDisplayMathImage() {
        NativeMarkdownParser.shared.clear()
        NativeMessageLayouter.shared.clear()
        NativeFormulaRenderer.shared.clear()
        let doc = NativeMarkdownParser.shared.parse("```latex\n\\frac{a}{b}\n```")
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .displayMath(let tex) = $0 {
                return tex.contains(#"\frac{a}{b}"#)
            }
            return false
        }), describe(doc.blocks))
        let layout = NativeMessageLayouter.shared.layout(
            document: doc,
            style: style(),
            renderMissingFormulas: true
        )
        XCTAssertTrue(hasFormulaImage(layout))
    }

    func testMatrixDisplayStillRenders() {
        NativeMarkdownParser.shared.clear()
        NativeMessageLayouter.shared.clear()
        NativeFormulaRenderer.shared.clear()
        let doc = NativeMarkdownParser.shared.parse(
            #"$$\begin{matrix}a&b\\c&d\end{matrix}$$"#
        )
        let layout = NativeMessageLayouter.shared.layout(
            document: doc,
            style: style(),
            renderMissingFormulas: true
        )
        XCTAssertTrue(hasFormulaImage(layout), describe(doc.blocks))
    }

    func testBoldWrappedInlineMathNormalizesAndParses() {
        NativeMarkdownParser.shared.clear()
        let raw = "使得**$y(t)=H(j\\omega)e^{j\\omega t}$**恒成立"
        let normalized = MarkdownHTMLRenderer.normalizeForRender(raw)
        XCTAssertTrue(
            normalized.contains("\\boldsymbol{"),
            "bold-wrapped math should become boldsymbol: \(normalized)"
        )
        XCTAssertFalse(
            normalized.contains("**$"),
            "markdown bold markers around pure math should be peeled: \(normalized)"
        )
        let doc = NativeMarkdownParser.shared.parse(raw)
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .paragraph(let inlines) = $0 {
                return inlines.contains {
                    if case .inlineMath(let tex) = $0 {
                        return tex.contains("y(t)")
                    }
                    return false
                }
            }
            return false
        }), describe(doc.blocks))
    }

    func testBoldWrappedConvolutionMathKeepsAsteriskInsideTeX() {
        NativeMarkdownParser.shared.clear()
        let raw = "**$x(t)*h(t)$**"
        let doc = NativeMarkdownParser.shared.parse(raw)
        guard case .paragraph(let inlines) = doc.blocks.first else {
            return XCTFail(describe(doc.blocks))
        }
        XCTAssertTrue(inlines.contains {
            if case .inlineMath(let tex) = $0 {
                return tex.contains("x(t)") && tex.contains("h(t)")
            }
            return false
        }, describe(doc.blocks))
    }
}
