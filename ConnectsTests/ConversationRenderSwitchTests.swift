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

    func testShortFencedLatexBecomesDisplayMath() {
        let raw = """
        ```latex
        \\frac{a}{b}
        ```
        """
        let normalized = MarkdownHTMLRenderer.normalizeForRender(raw)
        XCTAssertTrue(normalized.contains("$$\\frac{a}{b}$$"))
    }
}
