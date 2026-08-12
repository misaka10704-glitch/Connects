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
            switch $0 {
            case .image, .mathScroll: return true
            default: return false
            }
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
        let normalized = MarkdownHTMLRenderer.normalizeForNative(raw)
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
        let normalized = MarkdownHTMLRenderer.normalizeForNative(raw)
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

    func testSoleTallInlineFracPromotesToDisplayImage() {
        NativeMarkdownParser.shared.clear()
        NativeMessageLayouter.shared.clear()
        NativeFormulaRenderer.shared.clear()
        // Models often emit a lone `$…$` line; that must not paint as a clipped attachment.
        let doc = NativeMarkdownParser.shared.parse(
            "示波器内部电路也有上升时间：\n\n$tr_{scope} \\approx \\frac{0.35}{\\mathrm{BW}}$\n\n如果测到的边沿"
        )
        let layout = NativeMessageLayouter.shared.layout(
            document: doc,
            style: style(),
            renderMissingFormulas: true
        )
        let hasDisplayImage = layout.commands.contains {
            switch $0 {
            case .image, .mathScroll: return true
            default: return false
            }
        }
        XCTAssertTrue(
            hasDisplayImage,
            "tall sole inline frac should promote to display image: \(describe(doc.blocks))"
        )
    }

    func testFracArtifactHasOpaquePixelsInLowerHalf() {
        NativeFormulaRenderer.shared.clear()
        guard let artifact = NativeFormulaRenderer.shared.artifact(
            tex: #"tr_{scope} \approx \frac{0.35}{\mathrm{BW}}"#,
            fontSize: 17,
            color: .white,
            display: true
        ) else {
            return XCTFail("iosMath failed to render frac")
        }
        guard let cg = artifact.image.cgImage else {
            return XCTFail("missing cgImage")
        }
        let width = cg.width
        let height = cg.height
        XCTAssertGreaterThan(height, 20)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(ok)
        // Lower third of the bitmap must contain the denominator (not an empty clip).
        let y0 = (height * 2) / 3
        var opaque = 0
        for y in y0..<height {
            for x in 0..<width {
                let a = Int(data[(y * width + x) * 4 + 3])
                if a > 20 { opaque += 1 }
            }
        }
        XCTAssertGreaterThan(
            opaque,
            30,
            "denominator region empty — formula bitmap likely clipped"
        )
    }

    func testCJKTextInDisplayMathExpandsToProse() {
        NativeMarkdownParser.shared.clear()
        let raw = #"""
        傅里叶变换做的事情：
        \[
        \text{对每个频率 }\omega，\text{ 用基函数 } e^{-j\omega t} \text{ 去"探测"信号 } f(t) \text{ 中该频率成分的多少}
        \]
        """#
        let doc = NativeMarkdownParser.shared.parse(raw)
        XCTAssertFalse(
            doc.blocks.contains(where: {
                if case .displayMath = $0 { return true }
                return false
            }),
            "CJK prose math must not stay as displayMath: \(describe(doc.blocks))"
        )
        guard let paragraph = doc.blocks.compactMap({ block -> [NativeInline]? in
            if case .paragraph(let inlines) = block { return inlines }
            return nil
        }).first(where: { inlines in
            inlines.contains {
                if case .text(let t) = $0 { return t.contains("探测") }
                return false
            }
        }) else {
            return XCTFail("expected expanded Chinese prose: \(describe(doc.blocks))")
        }
        let joinedText = paragraph.compactMap { inline -> String? in
            if case .text(let t) = inline { return t }
            return nil
        }.joined()
        XCTAssertTrue(joinedText.contains("对每个频率"))
        XCTAssertTrue(joinedText.contains("探测"))
        XCTAssertTrue(paragraph.contains {
            if case .inlineMath(let tex) = $0 { return tex.contains("\\omega") || tex == "\\omega" }
            return false
        })
        XCTAssertTrue(paragraph.contains {
            if case .inlineMath(let tex) = $0 {
                return tex.contains("e^{-j")
            }
            return false
        })
    }

    func testProseTextCommandTriggersExpansion() {
        NativeMarkdownParser.shared.clear()
        let raw = #"$$\text{subject to } x+y=1$$"#
        let doc = NativeMarkdownParser.shared.parse(raw)
        XCTAssertFalse(doc.blocks.contains(where: {
            if case .displayMath = $0 { return true }
            return false
        }), describe(doc.blocks))
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .paragraph(let inlines) = $0 {
                return inlines.contains {
                    if case .text(let t) = $0 { return t.contains("subject to") }
                    return false
                }
            }
            return false
        }), describe(doc.blocks))
    }

    func testShortTextUnitStaysDisplayMath() {
        NativeMarkdownParser.shared.clear()
        let raw = #"$$tr \approx 0.35\text{ns}$$"#
        let doc = NativeMarkdownParser.shared.parse(raw)
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .displayMath = $0 { return true }
            return false
        }), describe(doc.blocks))
    }
}
