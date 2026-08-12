import XCTest
@testable import Connects

final class ConversationRenderSwitchTests: XCTestCase {
    func testWidthBucketRoundsToNearestFourPoints() {
        XCTAssertEqual(RenderCacheStore.widthBucket(for: 0), 0)
        XCTAssertEqual(RenderCacheStore.widthBucket(for: 401), 400)
        XCTAssertEqual(RenderCacheStore.widthBucket(for: 403), 404)
        XCTAssertEqual(RenderCacheStore.widthBucket(for: 656.2), 656)
    }

    func testMathNormalizationPreservesMatrixRowSeparators() {
        let normalized = MarkdownHTMLRenderer.normalizeForRender(
            #"$$\begin{matrix}a&b\\c&d\end{matrix}$$"#
        )

        XCTAssertTrue(normalized.contains(#"b\\c"#))
    }

    func testMathNormalizationGroupsBareMultiLineDerivation() {
        let normalized = MarkdownHTMLRenderer.normalizeForRender("""
        \\operatorname{Var}(\\bar{X}_n)
        = \\frac{1}{n^2}\\sum_{i=1}^n \\operatorname{Var}(X_i)
        = \\frac{\\sigma^2}{n}.
        """)

        XCTAssertEqual(
            normalized,
            """
            $$\\operatorname{Var}(\\bar{X}_n)
            = \\frac{1}{n^2}\\sum_{i=1}^n \\operatorname{Var}(X_i)
            = \\frac{\\sigma^2}{n}.$$
            """
        )
    }

    func testMathNormalizationDoesNotNestBareFracInsideDollarFence() {
        let normalized = MarkdownHTMLRenderer.normalizeForRender("""
        $$
        \\frac{a}{b}
        $$
        """)
        XCTAssertEqual(
            normalized.trimmingCharacters(in: .whitespacesAndNewlines),
            """
            $$
            \\frac{a}{b}
            $$
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        XCTAssertFalse(normalized.contains("$$$$"))
        XCTAssertFalse(normalized.contains("$$\n$$"))
    }

    func testHeightCacheStorageKeyIncludesWidthBucket() {
        let key = RenderCacheStore.heightCacheStorageKey(conversationID: "abc", layoutWidth: 656.2)
        XCTAssertEqual(key, "abc|w656")
    }

    func testNearestPersistedHeightsPrefersExactBucket() {
        let cache: [String: [String: CGFloat]] = [
            "abc|w400": ["m1": 120],
            "abc|w656": ["m1": 180],
            "abc|w680": ["m1": 200]
        ]
        let map = RenderCacheStore.nearestPersistedHeights(
            conversationID: "abc",
            layoutWidth: 656,
            cache: cache
        )
        XCTAssertEqual(map["m1"], 180)
    }

    func testNearestPersistedHeightsFallsBackToClosestBucket() {
        let cache: [String: [String: CGFloat]] = [
            "abc|w400": ["m1": 120],
            "abc|w680": ["m1": 200]
        ]
        let map = RenderCacheStore.nearestPersistedHeights(
            conversationID: "abc",
            layoutWidth: 656,
            cache: cache
        )
        XCTAssertEqual(map["m1"], 200)
    }

    func testNearestPersistedHeightsUsesLegacyConversationKey() {
        let cache: [String: [String: CGFloat]] = [
            "abc": ["m1": 96]
        ]
        let map = RenderCacheStore.nearestPersistedHeights(
            conversationID: "abc",
            layoutWidth: 656,
            cache: cache
        )
        XCTAssertEqual(map["m1"], 96)
    }

    func testSwitchTailAssistantsCollectsLatestTurnPairs() {
        let messages = [
            ChatMessage(role: .user, content: "q1"),
            ChatMessage(role: .assistant, content: "a1"),
            ChatMessage(role: .user, content: "q2"),
            ChatMessage(role: .assistant, content: "a2"),
            ChatMessage(role: .user, content: "q3"),
            ChatMessage(role: .assistant, content: "a3", isStreaming: true)
        ]
        let assistants = AssistantMessageLayout.switchTailAssistants(
            messages: messages,
            turnPairLimit: 2
        )
        XCTAssertEqual(assistants.map(\.content), ["a2"])
    }

    func testSwitchTailAssistantsSkipsStreamingReplies() {
        let messages = [
            ChatMessage(role: .user, content: "q1"),
            ChatMessage(role: .assistant, content: "a1", isStreaming: true)
        ]
        XCTAssertTrue(
            AssistantMessageLayout.switchTailAssistants(messages: messages, turnPairLimit: 3).isEmpty
        )
    }

    func testSwitchTailAssistantsReturnsTailInConversationOrder() {
        let messages = [
            ChatMessage(role: .user, content: "q1"),
            ChatMessage(role: .assistant, content: "a1"),
            ChatMessage(role: .user, content: "q2"),
            ChatMessage(role: .assistant, content: "a2"),
            ChatMessage(role: .user, content: "q3"),
            ChatMessage(role: .assistant, content: "a3")
        ]

        let assistants = AssistantMessageLayout.switchTailAssistants(
            messages: messages,
            turnPairLimit: 2
        )

        XCTAssertEqual(assistants.map(\.content), ["a2", "a3"])
    }

    func testSwitchPrewarmGenerationInvalidatesStaleWork() {
        let first = AssistantMessageLayout.bumpSwitchPrewarmGeneration()
        XCTAssertTrue(AssistantMessageLayout.isSwitchPrewarmGeneration(first))
        let second = AssistantMessageLayout.bumpSwitchPrewarmGeneration()
        XCTAssertFalse(AssistantMessageLayout.isSwitchPrewarmGeneration(first))
        XCTAssertTrue(AssistantMessageLayout.isSwitchPrewarmGeneration(second))
    }

    func testRebuildDisplayHeightsHonorsThroughRowProbe() {
        let resolver = ChatRowHeightResolver()
        let messages = (0..<12).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: index.isMultiple(of: 2) ? "question \(index)" : String(repeating: "x", count: 400)
            )
        }
        let layoutWidth: CGFloat = 400
        resolver.resetForConversation(diskCache: [:], messages: messages, layoutWidth: layoutWidth)
        resolver.rebuildDisplayHeights(messages: messages, layoutWidth: layoutWidth, throughRow: 2)

        let headAssistant = messages[1]
        let tailAssistant = messages[11]
        let headHeight = resolver.displayColumnHeight(for: headAssistant.id) ?? 0
        let tailHeight = resolver.displayColumnHeight(for: tailAssistant.id) ?? 0
        XCTAssertGreaterThan(headHeight, 40)
        XCTAssertGreaterThan(tailHeight, 40)
        XCTAssertLessThanOrEqual(headHeight, 720)
    }

    func testScrollOffsetYToBottomUsesCommittedHeights() {
        let resolver = ChatRowHeightResolver()
        let messages = [
            ChatMessage(role: .user, content: "hello"),
            ChatMessage(role: .assistant, content: "world")
        ]
        resolver.resetForConversation(diskCache: [:], messages: messages, layoutWidth: 400)
        resolver.commit(columnHeight: 120, messageID: messages[0].id)
        resolver.commit(columnHeight: 240, messageID: messages[1].id)

        let total = resolver.scrollOffsetYToBottom(
            messages: messages,
            layoutWidth: 400,
            contentInsetTop: 0,
            contentInsetBottom: 0,
            viewportHeight: 300
        )
        // (120 + 8) + (240 + 8) - 300
        XCTAssertEqual(total, 76, accuracy: 0.5)
    }

    func testFencedLatexDocumentStaysCodeBlock() {
        let raw = """
        ```latex
        \\documentclass{article}
        \\begin{document}
        \\chord{Db}
        \\end{document}
        ```
        """
        let normalized = MarkdownHTMLRenderer.normalizeForRender(raw)
        XCTAssertTrue(normalized.contains("```latex"))
        XCTAssertFalse(normalized.contains("$$\\documentclass"))
    }

    func testBoldWrappedInlineMathNormalizesToHtmlStrong() {
        let raw = "**$x[n]=x_c(nT),\\quad-\\infin<n<\\infin$**"
        let normalized = MarkdownHTMLRenderer.normalizeForRender(raw)
        XCTAssertTrue(normalized.contains("<strong>"))
        XCTAssertTrue(normalized.contains("$x[n]=x_c(nT)"))
        XCTAssertTrue(normalized.contains("\\infty"))
        XCTAssertFalse(normalized.contains("\\infin<"))
        XCTAssertFalse(normalized.contains("**$"))
    }

    func testBoldWrappedIntegralKeepsBody() {
        let raw = "**$X(s)=\\int_{-\\infin}^{+\\infin}x(t)e^{-st}dt$**"
        let normalized = MarkdownHTMLRenderer.normalizeForRender(raw)
        XCTAssertTrue(normalized.contains("\\int"), normalized)
        XCTAssertTrue(normalized.contains("\\infty"), normalized)
        XCTAssertTrue(normalized.contains("<strong>$X(s)="), normalized)
        XCTAssertFalse(normalized.contains("<strong>$$</strong>"), normalized)
        XCTAssertFalse(normalized.contains("**$"), normalized)
    }

    func testBoldWrappedDisplayMathKeepsSumAndFrac() {
        let raw = "**$$X_p(j\\omega)=\\frac{1}{T}\\sum_k X_c(j(\\omega-k\\omega_s)) \\quad \\omega_s=2\\pi/T$$**"
        let normalized = MarkdownHTMLRenderer.normalizeForRender(raw)
        XCTAssertTrue(normalized.contains("<strong>$$"), normalized)
        XCTAssertTrue(normalized.contains("\\frac{1}{T}"), normalized)
        XCTAssertTrue(normalized.contains("\\sum_k"), normalized)
        XCTAssertTrue(normalized.hasSuffix("$$</strong>") || normalized.contains("$$</strong>"), normalized)
        XCTAssertFalse(normalized.contains("**$$"), normalized)
    }

    func testCJKParenBoldBecomesHtmlStrong() {
        let raw = "对此可以得到以下信息**(注意T是一个定值)**："
        let normalized = MarkdownHTMLRenderer.normalizeForRender(raw)
        XCTAssertTrue(
            normalized.contains("<strong>（注意T是一个定值）</strong>"),
            normalized
        )
        XCTAssertFalse(normalized.contains("**（"), normalized)
    }

    func testHanInsideMathBecomesText() {
        let raw = "$p(t)=\\sum c_k e^{jk\\omega_s t}\\quad其中c_k=\\frac{1}{T}$"
        let normalized = MarkdownHTMLRenderer.normalizeForRender(raw)
        XCTAssertTrue(normalized.contains("\\text{其中}"), normalized)
        XCTAssertFalse(normalized.contains("\\quad其中"), normalized)
    }

    func testNativeBoldWrappedInlineMathNormalizesToBoldsymbol() {
        let raw = "使得**$y(t)=H(j\\omega)e^{j\\omega t}$**恒成立"
        let normalized = MarkdownHTMLRenderer.normalizeForNative(raw)
        XCTAssertTrue(
            normalized.contains("\\boldsymbol{"),
            "Native bold-wrapped math should become boldsymbol: \(normalized)"
        )
    }

    func testCJKBoldDelimitersGainZWSPForMarked() {
        let raw = "**（注意T是一个定值）**"
        let normalized = MarkdownHTMLRenderer.normalizeForNative(raw)
        XCTAssertTrue(
            normalized.contains("\u{200B}（"),
            "Native CJK paren bold should insert ZWSP: \(normalized.debugDescription)"
        )
    }

    func testShortFencedLatexBecomesDisplayMath() {
        let raw = """
        ```latex
        \\frac{a}{b}
        ```
        """
        let normalized = MarkdownHTMLRenderer.normalizeForRender(raw)
        XCTAssertTrue(normalized.contains("$$\\frac{a}{b}$$"))
    }

    func testTyporaAssetsImageRewritesToPreviewScheme() {
        let raw = "![image-20260812160055978](./assets/image-20260812160055978.png)"
        let rewritten = MarkdownPreviewAssetIndex.rewriteForPreview(raw, catalog: nil)
        XCTAssertTrue(
            rewritten.contains("connects-mdasset://preview/assets/image-20260812160055978.png"),
            "Typora ./assets image should become preview scheme: \(rewritten)"
        )
        XCTAssertTrue(rewritten.hasPrefix("!["))
        XCTAssertFalse(rewritten.contains("〔图〕"))
    }

    func testAssetFolderImageRewritesToPreviewScheme() {
        let raw = "![plot](./asset/plot.png)"
        let rewritten = MarkdownPreviewAssetIndex.rewriteForPreview(raw, catalog: nil)
        XCTAssertTrue(rewritten.contains("connects-mdasset://preview/asset/plot.png"), rewritten)
    }

    func testPreviewIndexesAssetsFolderByBasename() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("md-asset-\(UUID().uuidString)", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let file = assets.appendingPathComponent("image-20260812160055978.png")
        try png.write(to: file)
        defer { try? fm.removeItem(at: root) }

        let catalog = MarkdownPreviewAssetIndex.catalog(documentFolder: root)
        let raw = "![image-20260812160055978](./assets/image-20260812160055978.png)"
        let rewritten = MarkdownPreviewAssetIndex.rewriteForPreview(raw, catalog: catalog)
        XCTAssertTrue(rewritten.contains("connects-mdasset://preview/assets/image-20260812160055978.png"), rewritten)
        let href = "connects-mdasset://preview/assets/image-20260812160055978.png"
        let resolved = MarkdownPreviewAssetIndex.fileURL(for: href, catalog: catalog)
        XCTAssertEqual(resolved?.standardizedFileURL.path, file.standardizedFileURL.path)
    }

    func testFigureChipLinkBecomesInlineImage() {
        let raw = "[〔图〕scope](https://connects.local/assets/scope.png)"
        let rewritten = MarkdownPreviewAssetIndex.rewriteForPreview(raw, catalog: nil)
        XCTAssertTrue(rewritten.contains("![scope](connects-mdasset://preview/assets/scope.png)"), rewritten)
        XCTAssertFalse(rewritten.contains("〔图〕"))
    }
}
