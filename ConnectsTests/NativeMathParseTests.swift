import XCTest
import UIKit
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
            display: true,
            maxWidth: 0
        ) else {
            return XCTFail("iosMath should still paint a sync preview")
        }
        XCTAssertGreaterThan(artifact.size.height, 20)
    }

    /// KaTeX-first: `\text{中文}` and prose inside display math render fine via
    /// system font fallback, so the block must reach the renderer as ONE piece.
    /// Parse-time decomposition split TeX into structurally invalid fragments.
    func testCJKTextInDisplayMathStaysWholeForKaTeX() {
        NativeMarkdownParser.shared.clear()
        let raw = #"""
        傅里叶变换做的事情：
        \[
        \text{对每个频率 }\omega，\text{ 用基函数 } e^{-j\omega t} \text{ 去"探测"信号 } f(t) \text{ 中该频率成分的多少}
        \]
        """#
        let doc = NativeMarkdownParser.shared.parse(raw)
        guard let tex = doc.blocks.compactMap({ block -> String? in
            if case .displayMath(let tex) = block { return tex }
            return nil
        }).first else {
            return XCTFail("CJK prose math must stay one displayMath block: \(describe(doc.blocks))")
        }
        XCTAssertTrue(tex.contains("\\text{对每个频率 }"), tex)
        XCTAssertTrue(tex.contains("探测"), tex)
        XCTAssertTrue(tex.contains("e^{-j"), tex)
        XCTAssertFalse(doc.blocks.contains(where: {
            if case .displayMathComposite = $0 { return true }
            return false
        }), describe(doc.blocks))
    }

    func testProseTextCommandStaysInsideDisplayMath() {
        NativeMarkdownParser.shared.clear()
        let raw = #"$$\text{subject to } x+y=1$$"#
        let doc = NativeMarkdownParser.shared.parse(raw)
        XCTAssertTrue(doc.blocks.contains(where: {
            if case .displayMath(let tex) = $0 {
                return tex.contains("\\text{subject to }") && tex.contains("x+y=1")
            }
            return false
        }), describe(doc.blocks))
    }

    func testUnderbraceCJKTextStaysOneDisplayMath() {
        NativeMarkdownParser.shared.clear()
        let raw = #"$$D_n=\underbrace{(x_2-x_1)}_{D_2\text{ 层}}\,(x_3-x_1)\cdots(x_n-x_{n-1})$$"#
        let doc = NativeMarkdownParser.shared.parse(raw)
        XCTAssertEqual(doc.blocks.count, 1, describe(doc.blocks))
        guard case .displayMath(let tex) = doc.blocks.first else {
            return XCTFail("underbrace with CJK text must stay whole: \(describe(doc.blocks))")
        }
        XCTAssertTrue(tex.contains("\\underbrace{(x_2-x_1)}_{D_2\\text{ 层}}"), tex)
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
                display: false,
                maxWidth: 0
            )
        )
        XCTAssertNotNil(
            NativeFormulaRenderer.shared.artifact(
                tex: #"\operatorname{Var}(\bar{X}_n)=\frac{\sigma^2}{n}"#,
                fontSize: 17,
                color: .black,
                display: true,
                maxWidth: 0
            )
        )
    }

    func testPrepareTeXPeelsNestedDelimitersInsideEquationEnv() {
        // `\begin{equation}` bodies sometimes get bare-line-wrapped in `$$` by the
        // normalizer; prepareTeX must peel both layers so KaTeX never sees a `$`.
        let hybrid = "\\begin{equation}\n$$\\operatorname{Var}(\\bar{X}_n)=\\frac{\\sigma^2}{n}$$\n\\end{equation}"
        let prepared = NativeFormulaRenderer.shared.prepareTeX(hybrid)
        XCTAssertFalse(prepared.contains("$"), prepared)
        XCTAssertFalse(prepared.contains("\\begin{equation}"), prepared)
        XCTAssertTrue(prepared.contains("\\operatorname{Var}"), prepared)
        XCTAssertEqual(
            NativeFormulaRenderer.shared.prepareTeX(#"$\bar{X}_n$"#),
            #"\bar{X}_n"#
        )
        XCTAssertEqual(
            NativeFormulaRenderer.shared.prepareTeX(#"$$\frac{a}{b}$$"#),
            #"\frac{a}{b}"#
        )
    }

    func testBracelessFractionCommandsNormalizeForIosMath() {
        XCTAssertEqual(
            NativeFormulaRenderer.shared.normalizedIosMathTeX(#"\tfrac12"#),
            #"\frac12"#
        )
        XCTAssertEqual(
            NativeFormulaRenderer.shared.normalizedIosMathTeX(#"\dfrac34"#),
            #"\frac34"#
        )
        XCTAssertEqual(
            NativeFormulaRenderer.shared.normalizedIosMathTeX(#"4+\tfrac12=\tfrac92"#),
            #"4+\frac12=\frac92"#
        )
        XCTAssertEqual(
            NativeFormulaRenderer.shared.normalizedIosMathTeX(#"\tfrac{1}{2}"#),
            #"\frac{1}{2}"#
        )
    }

    func testTallInlineListWarmRequestUsesExactLayouterArtifactKeyInputs() {
        let doc = NativeMarkdownParser.shared.parse(#"- 强迫响应：\(\tfrac12 e^{-3t}\)"#)
        guard let request = NativeMessageLayouter.formulaWarmRequests(document: doc)
            .first(where: { $0.tex == #"\tfrac12 e^{-3t}"# }) else {
            XCTFail("tfrac inline math missing from warm requests")
            return
        }
        XCTAssertFalse(request.display, "source span is inline math in a list item")
        XCTAssertTrue(request.artifactDisplay, "tall inline math is promoted to display mode at the artifact call site")
        XCTAssertEqual(request.fontSize(bodyFontSize: 17.5), 17.5, accuracy: 0.0001)
        XCTAssertEqual(request.shrinkFloor, NativeFormulaRenderer.inlineShrinkFloor, accuracy: 0.0001)
        XCTAssertEqual(request.colorContext.rawValue, "primary")
    }

    func testRenderViewReconfiguresWhenFormulaArtifactGenerationAdvances() {
        NativeMarkdownParser.shared.clear()
        NativeMessageLayouter.shared.clear()
        NativeFormulaRenderer.shared.clear()
        let view = NativeMessageRenderView(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        let content = #"系数 \(\tfrac12\) 已化简"#
        _ = view.configure(
            content: content,
            width: 320,
            fontSize: 16,
            appearance: "light",
            colors: DSTheme.c
        )
        let warmupDeadline = Date().addingTimeInterval(0.25)
        while Date() < warmupDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard let beforeKey = view.layout?.key else {
            XCTFail("initial native layout must be applied")
            return
        }

        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        NativeFormulaRenderer.shared.storeExternalArtifact(
            NativeFormulaArtifact(image: image, size: CGSize(width: 4, height: 4), baseline: 3),
            cacheKey: "manual-regression-\(UUID().uuidString)"
        )
        _ = view.configure(
            content: content,
            width: 320,
            fontSize: 16,
            appearance: "light",
            colors: DSTheme.c
        )
        XCTAssertNotEqual(
            view.layout?.key,
            beforeKey,
            "KaTeX artifact completion must invalidate the render-view/layout key path; otherwise the stale iosMath bitmap stays on screen"
        )
    }

    func testBareLineWrapSkipsEquationEnvironmentBodies() {
        // The bare-TeX-line wrapper must not fire inside `\begin{equation}` fences —
        // rewrapping produced the hybrid that prepareTeX then had to peel.
        let raw = "\\begin{equation}\n\\operatorname{Var}(\\bar{X}_n)=\\frac{\\sigma^2}{n}\n\\end{equation}"
        let normalized = MarkdownHTMLRenderer.normalizeForRender(raw)
        XCTAssertFalse(normalized.contains("$$"), normalized)
    }

    func testAlignedRowBreakWithSpacingKeepsBothBackslashes() {
        // `\\[2mm]` is TeX row-break-with-spacing, never a double-escaped `\[` delimiter.
        let raw = #"$$\begin{aligned} a&=b\\[2mm] c&=d \end{aligned}$$"#
        let normalized = MarkdownHTMLRenderer.normalizeForRender(raw)
        XCTAssertTrue(normalized.contains(#"\\[2mm]"#), normalized)
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

    func testNestedListRecordsIndentLevels() {
        let doc = NativeMarkdownParser.shared.parse("""
        - outer
          - inner
            - deep
        - back
        """)
        guard case .list(_, let items, let levels) = doc.blocks.first else {
            XCTFail(describe(doc.blocks))
            return
        }
        XCTAssertEqual(items.count, 4, describe(doc.blocks))
        XCTAssertEqual(levels, [0, 1, 2, 0])
    }

    func testIndentedLineContinuesListItem() {
        let doc = NativeMarkdownParser.shared.parse("""
        - first line
          continued here
        - second
        """)
        guard case .list(_, let items, let levels) = doc.blocks.first else {
            XCTFail(describe(doc.blocks))
            return
        }
        XCTAssertEqual(items.count, 2, describe(doc.blocks))
        XCTAssertEqual(levels, [0, 0])
        XCTAssertTrue(
            flattenInlines(items[0]).contains("first line continued here"),
            flattenInlines(items[0])
        )
    }

    func testConsecutiveBlockquoteLinesMergeIntoOneBlock() {
        let doc = NativeMarkdownParser.shared.parse("""
        > first line
        >
        > second line
        """)
        let quotes = doc.blocks.filter {
            if case .blockquote = $0 { return true }
            return false
        }
        XCTAssertEqual(quotes.count, 1, describe(doc.blocks))
        guard case .blockquote(let inlines) = quotes.first else { return }
        XCTAssertEqual(
            inlines.filter {
                if case .lineBreak = $0 { return true }
                return false
            }.count,
            2,
            describeInlines(inlines)
        )
        XCTAssertTrue(flattenInlines(inlines).contains("first line"))
        XCTAssertTrue(flattenInlines(inlines).contains("second line"))
    }

    func testMacroBackedInlineMathParses() {
        let doc = NativeMarkdownParser.shared.parse("方差 $\\Var(X)$ 与期望 $\\E[X]$。")
        let texes = doc.blocks.flatMap { block -> [String] in
            guard case .paragraph(let inlines) = block else { return [] }
            return inlines.compactMap {
                if case .inlineMath(let tex) = $0 { return tex }
                return nil
            }
        }
        XCTAssertTrue(texes.contains("\\Var(X)"), describe(doc.blocks))
        XCTAssertTrue(texes.contains("\\E[X]"), describe(doc.blocks))
        XCTAssertEqual(
            NativeFormulaRenderer.shared.prepareTeX("\\Var(X)"),
            "\\Var(X)"
        )
        XCTAssertEqual(
            NativeFormulaRenderer.shared.prepareTeX("\\begin{eqnarray}a&=&b\\end{eqnarray}"),
            "\\begin{aligned}a&=&b\\end{aligned}"
        )
    }

    private func flattenText(_ doc: NativeMarkdownDocument) -> String {
        doc.blocks.map { block in
            switch block {
            case .paragraph(let inlines), .displayMathComposite(let inlines), .blockquote(let inlines):
                return flattenInlines(inlines)
            case .heading(_, let inlines):
                return flattenInlines(inlines)
            case .list(_, let items, _):
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
