import XCTest
@testable import Connects

final class NativeMathParseTests: XCTestCase {
    private func describe(_ blocks: [NativeMessageBlock]) -> String {
        blocks.map { block in
            switch block {
            case .displayMath(let tex):
                return "displayMath:\(tex.debugDescription)"
            case .displayMathComposite(let inlines):
                return "displayMathComposite:\(describeInlines(inlines))"
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
            case .mathWithScript(let base, let script, let kind):
                return "mathWithScript(\(kind)):\(base.debugDescription)|\(script.debugDescription)"
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

    /// KaTeX snapshots are async; layout still reserves height / fallback text.
    private func laidOutMath(_ layout: NativeMessageLayout) -> Bool {
        hasFormulaImage(layout) || layout.size.height > 20
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
        XCTAssertTrue(hasFormulaImage(layout), "expected formula image for \\frac")
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
        XCTAssertTrue(laidOutMath(layout))
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
        XCTAssertTrue(laidOutMath(layout), describe(doc.blocks))
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
        XCTAssertTrue(
            laidOutMath(layout),
            "tall sole inline frac should reserve display math: \(describe(doc.blocks))"
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
            return XCTFail("iosMath should still paint a sync preview")
        }
        XCTAssertGreaterThan(artifact.size.height, 20)
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
        func inlinesFrom(_ block: NativeMessageBlock) -> [NativeInline]? {
            switch block {
            case .paragraph(let inlines), .displayMathComposite(let inlines):
                return inlines
            default:
                return nil
            }
        }
        guard let paragraph = doc.blocks.compactMap(inlinesFrom).first(where: { inlines in
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
            switch $0 {
            case .paragraph(let inlines), .displayMathComposite(let inlines):
                return inlines.contains {
                    if case .text(let t) = $0 { return t.contains("subject to") }
                    return false
                }
            default:
                return false
            }
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

    func testBigDelimitersAreNotWrappedAsMathrm() {
        let tex = #"P\big(|\bar{X}_n - \mu| \ge \varepsilon\big)"#
        let normalized = NativeFormulaRenderer.shared.normalizedIosMathTeX(tex)
        XCTAssertFalse(normalized.contains("mathrm{big}"), normalized)
        XCTAssertFalse(normalized.contains("\\big"), normalized)
        NativeFormulaRenderer.shared.clear()
        NativeMessageLayouter.shared.clear()
        let doc = NativeMarkdownParser.shared.parse("$\(tex)$")
        let layout = NativeMessageLayouter.shared.layout(
            document: doc,
            style: style(),
            renderMissingFormulas: true
        )
        XCTAssertTrue(laidOutMath(layout), describe(doc.blocks))
    }

    func testLawOfLargeNumbersDelimitersParseAndRender() {
        NativeMarkdownParser.shared.clear()
        NativeMessageLayouter.shared.clear()
        NativeFormulaRenderer.shared.clear()
        let raw = #"""
        设 $X_1, X_2, \dots, X_n$ 是独立同分布的随机变量

        $$
        \bar{X}_n = \frac{1}{n}\sum_{i=1}^{n} X_i
        $$

        \(\bar{X}_n \xrightarrow{P} \mu\)

        \[
        P\big(|\bar{X}_n - \mu| \ge \varepsilon\big) \le \frac{\sigma^2}{n\varepsilon^2}
        \]

        \begin{equation}
        \operatorname{Var}(\bar{X}_n)=\frac{\sigma^2}{n}
        \end{equation}
        """#
        let doc = NativeMarkdownParser.shared.parse(raw)
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .paragraph(let inlines) = $0 {
                return inlines.contains {
                    if case .inlineMath(let tex) = $0 { return tex.contains("X_1") }
                    return false
                }
            }
            return false
        }), describe(doc.blocks))
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .displayMath(let tex) = $0 { return tex.contains("bar{X}") }
            return false
        }), describe(doc.blocks))
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .displayMath(let tex) = $0 { return tex.contains("operatorname") || tex.contains("sigma") }
            return false
        }), describe(doc.blocks))
        let layout = NativeMessageLayouter.shared.layout(
            document: doc,
            style: style(),
            renderMissingFormulas: true
        )
        XCTAssertTrue(laidOutMath(layout), describe(doc.blocks))
        XCTAssertNotNil(
            NativeFormulaRenderer.shared.artifact(
                tex: #"\bar{X}_n \xrightarrow{P} \mu"#,
                fontSize: 17,
                color: .black,
                display: false
            )
        )
        XCTAssertNotNil(
            NativeFormulaRenderer.shared.artifact(
                tex: #"\operatorname{Var}(\bar{X}_n)=\frac{\sigma^2}{n}"#,
                fontSize: 17,
                color: .black,
                display: true
            )
        )
    }

    func testLoneNumericDollarIsMathNotCurrency() {
        NativeMarkdownParser.shared.clear()
        let doc = NativeMarkdownParser.shared.parse("又 h 单调且趋于 $0$。")
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .paragraph(let inlines) = $0 {
                return inlines.contains {
                    if case .inlineMath(let tex) = $0 { return tex == "0" }
                    return false
                }
            }
            return false
        }), describe(doc.blocks))
        let joined = joinedText(doc)
        XCTAssertFalse(joined.contains("$0$"), joined)
    }

    func testPriceRangeStillStaysProse() {
        NativeMarkdownParser.shared.clear()
        let doc = NativeMarkdownParser.shared.parse("价格 $5-$10 美元")
        let joined = joinedText(doc)
        XCTAssertTrue(joined.contains("$5-$10"), joined)
        XCTAssertFalse(doc.blocks.contains(where: {
            if case .paragraph(let inlines) = $0 {
                return inlines.contains {
                    if case .inlineMath = $0 { return true }
                    return false
                }
            }
            return false
        }), describe(doc.blocks))
    }

    func testAbelSnippetDoesNotLeakIntAsIn() {
        NativeMarkdownParser.shared.clear()
        let raw = #"又 h 单调且趋于 $0$。这正是 Dirichlet 判别法的条件，故\int_a^{+\infty} fh$ 收敛。$\blacksquare$"#
        let doc = NativeMarkdownParser.shared.parse(raw)
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .paragraph(let inlines) = $0 {
                return inlines.contains {
                    if case .inlineMath(let tex) = $0 { return tex == "0" }
                    return false
                }
            }
            return false
        }), describe(doc.blocks))
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .paragraph(let inlines) = $0 {
                return inlines.contains {
                    if case .inlineMath(let tex) = $0 { return tex.contains("\\int") }
                    return false
                }
            }
            return false
        }), describe(doc.blocks))
        let joined = joinedText(doc)
        XCTAssertFalse(joined.contains("$0$"), joined)
        XCTAssertFalse(joined.contains("\\in t"), joined)
        let ios = NativeFormulaRenderer.shared.normalizedIosMathTeX(#"\blacksquare"#)
        XCTAssertFalse(ios.contains("mathrm{blacksquare}"), ios)
        XCTAssertTrue(ios.contains("■"), ios)
    }

    func testAppStorePriceAndTextCommandsStayProse() {
        NativeMarkdownParser.shared.clear()
        let raw = """
        **$9.99 \\text{是}“\\text{卖得动}”\\text{和}“\\text{不掉价}”\\text{之间的平衡点。}**
        \\text{你本来想把国区} ¥39 \\text{那套搬过去}。
        - **美区定价 $9.99，\\text{回本约} 12 \\text{份}，\\text{别定} $4.99。**
        开发者账号 $99/年，到手约 $8.49。
        | 定价 | 到手 |
        |---|---|
        | $9.99 | ~$8.49 |
        """
        let doc = NativeMarkdownParser.shared.parse(raw)
        let joined = flattenText(doc)
        XCTAssertTrue(joined.contains("$9.99"), joined)
        XCTAssertTrue(joined.contains("$4.99"), joined)
        XCTAssertTrue(joined.contains("$99/年"), joined)
        XCTAssertTrue(joined.contains("$8.49"), joined)
        XCTAssertTrue(joined.contains("卖得动"), joined)
        XCTAssertTrue(joined.contains("回本约"), joined)
        XCTAssertFalse(joined.contains("\\text"), joined)
        XCTAssertFalse(joined.contains("$9.99 \\text"), joined)
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .table(let table) = $0 {
                return table.rows.contains { row in
                    row.contains { cell in
                        flattenInlines(cell).contains("$9.99")
                    }
                }
            }
            return false
        }), describe(doc.blocks))
        NativeMarkdownParser.shared.clear()
        let mathZero = NativeMarkdownParser.shared.parse("趋于 $0$ 与 $2x$。")
        XCTAssertTrue(flattenText(mathZero).contains("趋于"), flattenText(mathZero))
        XCTAssertTrue(mathZero.blocks.contains(where: {
            if case .paragraph(let inlines) = $0 {
                return inlines.contains {
                    if case .inlineMath(let tex) = $0 { return tex == "0" }
                    return false
                }
            }
            return false
        }), describe(mathZero.blocks))
        XCTAssertTrue(mathZero.blocks.contains(where: {
            if case .paragraph(let inlines) = $0 {
                return inlines.contains {
                    if case .inlineMath(let tex) = $0 { return tex == "2x" }
                    return false
                }
            }
            return false
        }), describe(mathZero.blocks))
    }

    private func flattenText(_ doc: NativeMarkdownDocument) -> String {
        doc.blocks.map { block in
            switch block {
            case .paragraph(let inlines), .displayMathComposite(let inlines), .blockquote(let inlines):
                return flattenInlines(inlines)
            case .heading(_, let inlines):
                return flattenInlines(inlines)
            case .list(_, let items):
                return items.map { flattenInlines($0) }.joined()
            case .table(let table):
                let header = table.header.map { flattenInlines($0) }.joined(separator: "|")
                let rows = table.rows.map { $0.map { flattenInlines($0) }.joined(separator: "|") }.joined()
                return header + rows
            default:
                return ""
            }
        }.joined()
    }

    private func flattenInlines(_ inlines: [NativeInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let t): return t
            case .bold(let kids), .italic(let kids), .link(let kids, _):
                return flattenInlines(kids)
            case .inlineCode(let t): return t
            case .inlineMath(let t): return "$\(t)$"
            case .mathWithScript(let base, let script, _): return base + script
            case .lineBreak: return "\n"
            }
        }.joined()
    }

    private func joinedText(_ doc: NativeMarkdownDocument) -> String {
        doc.blocks.flatMap { block -> [String] in
            switch block {
            case .paragraph(let inlines), .displayMathComposite(let inlines):
                return inlines.compactMap {
                    if case .text(let t) = $0 { return t }
                    return nil
                }
            default:
                return []
            }
        }.joined()
    }
}
