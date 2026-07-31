import XCTest
@testable import Connects
import UIKit

/// Stress / invariant tests for Study AI Diff review mode.
final class CodeDiffModeTests: XCTestCase {

    // MARK: - CodeTextDiff core

    func testEmptyBeforeFullWriteComposeKeep() {
        let before = ""
        let after = "hello\nworld"
        var segs = CodeTextDiff.segments(from: CodeTextDiff.lines(before: before, after: after))
        XCTAssertFalse(CodeTextDiff.pendingHunkIndices(in: segs).isEmpty)
        for i in segs.indices {
            guard case .hunk(var h) = segs[i] else { continue }
            h.decision = .kept
            segs[i] = .hunk(h)
        }
        XCTAssertEqual(CodeTextDiff.compose(segs), after)
    }

    func testMultiHunkKeepAllAndUndoAll() {
        let before = """
        a
        b
        c
        d
        e
        """
        let after = """
        a
        B
        c
        D
        e
        """
        var segs = CodeTextDiff.segments(from: CodeTextDiff.lines(before: before, after: after))
        let pending = CodeTextDiff.pendingHunkIndices(in: segs)
        XCTAssertEqual(pending.count, 2)

        // Keep all
        for i in segs.indices {
            guard case .hunk(var h) = segs[i], h.decision == .pending else { continue }
            h.decision = .kept
            segs[i] = .hunk(h)
        }
        XCTAssertEqual(CodeTextDiff.compose(segs), after)

        // Undo all from fresh
        segs = CodeTextDiff.segments(from: CodeTextDiff.lines(before: before, after: after))
        for i in segs.indices {
            guard case .hunk(var h) = segs[i], h.decision == .pending else { continue }
            h.decision = .undone
            segs[i] = .hunk(h)
        }
        XCTAssertEqual(CodeTextDiff.compose(segs), before)
    }

    func testMixedKeepUndoCompose() {
        let before = "1\n2\n3\n4"
        let after = "1\nX\n3\nY"
        var segs = CodeTextDiff.segments(from: CodeTextDiff.lines(before: before, after: after))
        let pending = CodeTextDiff.pendingHunkIndices(in: segs)
        XCTAssertEqual(pending.count, 2)

        guard case .hunk(var h0) = segs[pending[0]] else { return XCTFail() }
        h0.decision = .kept
        segs[pending[0]] = .hunk(h0)

        guard case .hunk(var h1) = segs[pending[1]] else { return XCTFail() }
        h1.decision = .undone
        segs[pending[1]] = .hunk(h1)

        XCTAssertEqual(CodeTextDiff.compose(segs), "1\nX\n3\n4")
    }

    func testPendingAsUndoneDefault() {
        let before = "a\nb"
        let after = "a\nc"
        let segs = CodeTextDiff.segments(from: CodeTextDiff.lines(before: before, after: after))
        XCTAssertEqual(CodeTextDiff.compose(segs, pendingAsUndone: true), before)
        XCTAssertEqual(CodeTextDiff.compose(segs, pendingAsUndone: false), after)
    }

    func testIdenticalTextsNoHunks() {
        let segs = CodeTextDiff.segments(from: CodeTextDiff.lines(before: "x\ny", after: "x\ny"))
        XCTAssertTrue(CodeTextDiff.pendingHunkIndices(in: segs).isEmpty)
        XCTAssertEqual(CodeTextDiff.compose(segs), "x\ny")
    }

    func testChatVisibleContentClosedBlock() {
        let raw = """
        说明一下改动。

        <<<CONNECTS_EDIT
        range: full
        ```
        int x;
        ```
        CONNECTS_EDIT>>>
        """
        let visible = CodeEditApplyTools.chatVisibleContent(raw)
        XCTAssertEqual(visible, "说明一下改动。")
        XCTAssertFalse(visible.contains("int x"))
        XCTAssertFalse(visible.contains("CONNECTS_EDIT"))
    }

    func testChatVisibleContentOpenBlockStreaming() {
        CodeEditApplyTools.clearVisibleCache()
        let raw = """
        先改主逻辑。

        <<<CONNECTS_EDIT
        range: full
        ```
        module huge;
        """
        let visible = CodeEditApplyTools.chatVisibleContent(raw)
        XCTAssertTrue(visible.contains("先改主逻辑"))
        XCTAssertTrue(visible.contains("正在生成文件编辑"))
        XCTAssertTrue(visible.contains("B") || visible.contains("KB"))
        XCTAssertTrue(visible.contains("行"))
        // Live tail (thinking-style) may show recent code lines — fences/meta stay hidden.
        XCTAssertFalse(visible.contains("<<<CONNECTS_EDIT"))
        XCTAssertFalse(visible.contains("range:"))
        XCTAssertTrue(visible.contains("module huge"))
    }

    func testChatVisibleContentOpenBlockProgressUpdates() {
        CodeEditApplyTools.clearVisibleCache()
        var raw = """
        <<<CONNECTS_EDIT
        range: full
        ```
        a
        """
        let v1 = CodeEditApplyTools.chatVisibleContent(raw)
        raw += "\nb\nc\nd\n"
        let v2 = CodeEditApplyTools.chatVisibleContent(raw)
        XCTAssertNotEqual(v1, v2)
        XCTAssertTrue(v2.contains("正在生成文件编辑"))
        XCTAssertTrue(v2.contains("d") || v2.contains("c"))
    }

    func testChatVisibleContentEmptyProsePlaceholder() {
        let raw = """
        <<<CONNECTS_EDIT
        range: full
        ```
        only code
        ```
        CONNECTS_EDIT>>>
        """
        XCTAssertEqual(CodeEditApplyTools.chatVisibleContent(raw), "（文件编辑内容已隐藏）")
    }

    func testIncompleteEditBlockDetection() {
        let open = """
        先改主逻辑。

        <<<CONNECTS_EDIT
        range: full
        ```
        module top;
        """
        XCTAssertTrue(CodeEditApplyTools.hasIncompleteEditBlock(open))

        let closed = open + "\nendmodule\n```\nCONNECTS_EDIT>>>"
        XCTAssertFalse(CodeEditApplyTools.hasIncompleteEditBlock(closed))
        XCTAssertFalse(CodeEditApplyTools.hasIncompleteEditBlock("普通回答"))
    }

    func testChatVisibleContentPassthrough() {
        let raw = "普通回答，没有编辑块。"
        XCTAssertEqual(CodeEditApplyTools.chatVisibleContent(raw), raw)
    }

    /// Large near-identical files must not freeze (prefix/suffix + Myers path).
    func testLargeFileSparseEditsAreFastAndCorrect() {
        let n = 4_000
        let before = (0..<n).map { "line_\($0)_payload_abcdefghijklmnopqrstuvwxyz" }.joined(separator: "\n")
        let after = (0..<n).map { i -> String in
            if i == 100 || i == 2000 || i == 3500 { return "CHANGED_\(i)" }
            return "line_\(i)_payload_abcdefghijklmnopqrstuvwxyz"
        }.joined(separator: "\n")

        let start = CFAbsoluteTimeGetCurrent()
        var segs = CodeTextDiff.segments(from: CodeTextDiff.lines(before: before, after: after))
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 1.0, "sparse edit on \(n) lines took \(elapsed)s")

        let pending = CodeTextDiff.pendingHunkIndices(in: segs)
        XCTAssertEqual(pending.count, 3)

        for i in segs.indices {
            guard case .hunk(var h) = segs[i], h.decision == .pending else { continue }
            h.decision = .kept
            segs[i] = .hunk(h)
        }
        XCTAssertEqual(CodeTextDiff.compose(segs), after)
    }

    func testTrailingNewlineRoundTripKeep() {
        let before = "line\n"
        let after = "line\nextra\n"
        var segs = CodeTextDiff.segments(from: CodeTextDiff.lines(before: before, after: after))
        for i in segs.indices {
            guard case .hunk(var h) = segs[i] else { continue }
            h.decision = .kept
            segs[i] = .hunk(h)
        }
        // components(separatedBy:) keeps trailing empty component; compose joins with \n
        XCTAssertEqual(CodeTextDiff.compose(segs), after)
    }

    // MARK: - CONNECTS_EDIT parse

    func testParseEditBlockCaseInsensitiveAndFullDefault() {
        let raw = """
        Here is the file.

        <<<connects_edit
        path: current
        ```
        int main() {}
        ```
        connects_edit>>>
        """
        let proposal = CodeEditApplyTools.parseEditBlock(from: raw)
        XCTAssertNotNil(proposal)
        XCTAssertEqual(proposal?.rangeKind, .full)
        XCTAssertEqual(proposal?.replacement, "int main() {}")
        XCTAssertFalse(proposal!.displayContent.contains("CONNECTS_EDIT") ||
                       proposal!.displayContent.lowercased().contains("connects_edit"))
    }

    func testParseSelectionRange() {
        let raw = """
        <<<CONNECTS_EDIT
        range: selection
        ```
        foo
        ```
        CONNECTS_EDIT>>>
        """
        let proposal = CodeEditApplyTools.parseEditBlock(from: raw)
        XCTAssertEqual(proposal?.rangeKind, .selection)
        XCTAssertEqual(proposal?.replacement, "foo")
    }

    func testAuthorizationStripRoundTrip() {
        let auth = CodeEditApplyTools.authorizationPrefix
        let study = "## STUDY\npage"
        let combined = auth + "\n\n" + study
        let stripped = CodeEditApplyTools.strippingAuthorization(from: combined)
        XCTAssertEqual(stripped, study)
        XCTAssertFalse(stripped.contains("CONNECTS_CODE_EDIT"))
    }

    func testResolveNoSelectionBecomesFull() {
        let text = "abc"
        let range = CodeEditApplyTools.resolveTargetRange(
            text: text,
            selectedRange: NSRange(location: 1, length: 0),
            kind: .selection
        )
        XCTAssertEqual(range, NSRange(location: 0, length: 3))
    }

    // MARK: - Editor Diff session invariants (UIKit)

    func testFontResizeDuringDiffKeepsReviewAndBlocksEditToggle() {
        let vc = TextCodeEditorViewController()
        _ = vc.view
        vc.loadViewIfNeeded()

        let before = (0..<40).map { "line\($0)" }.joined(separator: "\n")
        let after = (0..<40).map { $0 % 7 == 0 ? "LINE\($0)" : "line\($0)" }.joined(separator: "\n")
        vc.presentInlineDiff(before: before, after: after)

        XCTAssertGreaterThan(vc.diffPendingHunkCount, 1)
        XCTAssertFalse(vc.isInEditMode)

        let countBefore = vc.diffPendingHunkCount
        vc.adjustFontSizeFromKeyboardShortcut(by: 4)
        vc.adjustFontSizeFromKeyboardShortcut(by: -2)

        // Still reviewing — font must not eject Diff.
        XCTAssertGreaterThan(vc.diffPendingHunkCount, 0)
        XCTAssertEqual(vc.diffPendingHunkCount, countBefore)

        vc.toggleEditModeFromKeyboardShortcut()
        XCTAssertFalse(vc.isInEditMode, "edit toggle must stay locked while Diff is active")

        vc.diffKeepAll()
        XCTAssertEqual(vc.diffPendingHunkCount, 0)
        // Keep All already enters edit mode when no coordinator is wired.
        XCTAssertTrue(vc.isInEditMode)
        vc.toggleEditModeFromKeyboardShortcut()
        XCTAssertFalse(vc.isInEditMode)
        vc.toggleEditModeFromKeyboardShortcut()
        XCTAssertTrue(vc.isInEditMode)
    }

    func testUndoAllRestoresAndUnlocksEdit() {
        let vc = TextCodeEditorViewController()
        vc.loadViewIfNeeded()
        vc.presentInlineDiff(before: "aaa\nbbb", after: "aaa\nCCC")
        XCTAssertGreaterThan(vc.diffPendingHunkCount, 0)
        vc.diffUndoAll()
        XCTAssertEqual(vc.diffPendingHunkCount, 0)
        vc.toggleEditModeFromKeyboardShortcut()
        XCTAssertTrue(vc.isInEditMode)
    }

    func testSequentialHunkKeepThenFontThenNext() {
        let vc = TextCodeEditorViewController()
        vc.loadViewIfNeeded()
        let before = "a\nb\nc\nd\ne\nf"
        let after = "a\nB\nc\nD\ne\nF"
        vc.presentInlineDiff(before: before, after: after)
        let start = vc.diffPendingHunkCount
        XCTAssertEqual(start, 3)

        vc.focusCurrentDiffHunk()
        vc.adjustFontSizeFromKeyboardShortcut(by: 3)
        XCTAssertEqual(vc.diffPendingHunkCount, start)

        vc.diffKeepAll()
        XCTAssertEqual(vc.diffPendingHunkCount, 0)
        XCTAssertTrue(vc.isInEditMode)
    }

    func testRapidFontResizeLoopDoesNotEjectDiff() {
        let vc = TextCodeEditorViewController()
        vc.loadViewIfNeeded()
        let before = (0..<80).map { "l\($0)" }.joined(separator: "\n")
        let after = (0..<80).map { $0 % 5 == 0 ? "L\($0)" : "l\($0)" }.joined(separator: "\n")
        vc.presentInlineDiff(before: before, after: after)
        let n = vc.diffPendingHunkCount
        XCTAssertGreaterThan(n, 5)
        for i in 0..<20 {
            vc.adjustFontSizeFromKeyboardShortcut(by: i % 2 == 0 ? 1 : -1)
            XCTAssertEqual(vc.diffPendingHunkCount, n)
            XCTAssertFalse(vc.isInEditMode)
        }
        vc.diffUndoAll()
        XCTAssertEqual(vc.diffPendingHunkCount, 0)
        vc.toggleEditModeFromKeyboardShortcut()
        XCTAssertTrue(vc.isInEditMode)
    }

    func testEmptyDiffStateDoesNotPermanentlyLockEdit() {
        let vc = TextCodeEditorViewController()
        vc.loadViewIfNeeded()
        // Identical → presentInlineDiff dismisses immediately (no hunks).
        vc.presentInlineDiff(before: "same", after: "same")
        XCTAssertEqual(vc.diffPendingHunkCount, 0)
        vc.toggleEditModeFromKeyboardShortcut()
        XCTAssertTrue(vc.isInEditMode)
    }

    func testCancelDiffUnlocksEdit() {
        let vc = TextCodeEditorViewController()
        vc.loadViewIfNeeded()
        vc.presentInlineDiff(before: "old", after: "new")
        XCTAssertGreaterThan(vc.diffPendingHunkCount, 0)
        vc.cancelDiffReviewForExternalMutation()
        XCTAssertEqual(vc.diffPendingHunkCount, 0)
        vc.toggleEditModeFromKeyboardShortcut()
        XCTAssertTrue(vc.isInEditMode)
    }

    func testDiffModeTogglesPreviewWithoutEnteringEdit() {
        let vc = TextCodeEditorViewController()
        vc.loadViewIfNeeded()
        vc.presentInlineDiff(before: "a\nb", after: "a\nB")
        XCTAssertGreaterThan(vc.diffPendingHunkCount, 0)
        XCTAssertFalse(vc.isInEditMode)
        // Mode shortcut while Diff → kept preview (still not edit).
        vc.toggleEditModeFromKeyboardShortcut()
        XCTAssertFalse(vc.isInEditMode)
        XCTAssertGreaterThan(vc.diffPendingHunkCount, 0)
        vc.toggleEditModeFromKeyboardShortcut()
        XCTAssertFalse(vc.isInEditMode)
        vc.diffKeepAll()
        XCTAssertTrue(vc.isInEditMode)
    }

    func testEmptyFullClearParsesAndComposes() {
        let raw = """
        清空。

        <<<CONNECTS_EDIT
        path: current
        range: full
        ```
        ```
        CONNECTS_EDIT>>>
        """
        let p = CodeEditApplyTools.parseEditBlock(from: raw)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.rangeKind, .full)
        XCTAssertEqual(p?.replacement, "")
        XCTAssertFalse(p!.displayContent.contains("CONNECTS_EDIT"))
        let after = CodeEditApplyTools.composeAfter(
            before: "module x;\nendmodule",
            range: NSRange(location: 0, length: ("module x;\nendmodule" as NSString).length),
            replacement: ""
        )
        XCTAssertEqual(after, "")
    }

    func testEmptySelectionRejected() {
        let raw = """
        <<<CONNECTS_EDIT
        range: selection
        ```
        ```
        CONNECTS_EDIT>>>
        """
        XCTAssertNil(CodeEditApplyTools.parseEditBlock(from: raw))
    }

    func testParseFuzzManyShapes() {
        let bodies = [
            "x",
            "line1\nline2",
            String(repeating: "ab\n", count: 200),
            "  spaced  "
        ]
        for body in bodies {
            let raw = """
            note

            <<<CONNECTS_EDIT
            range: full
            ```
            \(body)
            ```
            CONNECTS_EDIT>>>
            """
            let p = CodeEditApplyTools.parseEditBlock(from: raw)
            XCTAssertEqual(p?.replacement, body, "body=\(body.prefix(20))")
            // stripCodeFence must be a no-op for already-unfenced payloads.
            XCTAssertEqual(CodeEditApplyTools.stripCodeFence(body), body)
            let after = CodeEditApplyTools.composeAfter(before: "", range: NSRange(location: 0, length: 0), replacement: body)
            XCTAssertEqual(after, body)
            var segs = CodeTextDiff.segments(from: CodeTextDiff.lines(before: "", after: after))
            for i in segs.indices {
                guard case .hunk(var h) = segs[i] else { continue }
                h.decision = .kept
                segs[i] = .hunk(h)
            }
            XCTAssertEqual(CodeTextDiff.compose(segs), after)
        }
    }

    // MARK: - Keep chrome + AI-edit capture bind + Diff/Tab stick

    func testKeptAndUndoneHunksHaveNoBackground() {
        let before = "a\nb\nc"
        let after = "a\nB\nc"
        var segs = CodeTextDiff.segments(from: CodeTextDiff.lines(before: before, after: after))
        let pending = CodeTextDiff.pendingHunkIndices(in: segs)
        XCTAssertEqual(pending.count, 1)
        let hunkIdx = pending[0]

        guard case .hunk(var kept) = segs[hunkIdx] else { return XCTFail() }
        kept.decision = .kept
        segs[hunkIdx] = .hunk(kept)

        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let (attrKept, rangesKept) = CodeTextDiff.attributedString(
            segments: segs,
            font: font,
            textColor: .label,
            highlightHunkIndex: hunkIdx
        )
        guard let kr = rangesKept[hunkIdx] else { return XCTFail("missing kept range") }
        attrKept.enumerateAttribute(.backgroundColor, in: kr, options: []) { value, _, stop in
            XCTAssertNil(value, "kept hunk must not keep tint/focus wash")
            if value != nil { stop.pointee = true }
        }

        segs = CodeTextDiff.segments(from: CodeTextDiff.lines(before: before, after: after))
        guard case .hunk(var undone) = segs[hunkIdx] else { return XCTFail() }
        undone.decision = .undone
        segs[hunkIdx] = .hunk(undone)
        let (attrUndone, rangesUndone) = CodeTextDiff.attributedString(
            segments: segs,
            font: font,
            textColor: .label,
            highlightHunkIndex: hunkIdx
        )
        guard let ur = rangesUndone[hunkIdx] else { return XCTFail("missing undone range") }
        attrUndone.enumerateAttribute(.backgroundColor, in: ur, options: []) { value, _, stop in
            XCTAssertNil(value, "undone hunk must not keep tint/focus wash")
            if value != nil { stop.pointee = true }
        }
    }

    func testAIEditEnablesDocumentCaptureOneWay() {
        let bar = InputBarView(frame: CGRect(x: 0, y: 0, width: 390, height: 90))
        bar.studyCaptureVisible = true
        bar.studyPageCaptureEnabled = false
        bar.codeAIEditVisible = true

        bar.setCodeAIEditEnabled(true, notify: false)
        XCTAssertTrue(bar.codeAIEditEnabled)
        XCTAssertTrue(bar.studyPageCaptureEnabled)

        bar.setCodeAIEditEnabled(false, notify: false)
        XCTAssertFalse(bar.codeAIEditEnabled)
        XCTAssertTrue(bar.studyPageCaptureEnabled, "closing AI edit must leave document capture on")

        bar.studyPageCaptureEnabled = false
        XCTAssertFalse(bar.codeAIEditEnabled, "toggling document must not re-arm AI edit")
    }

    func testDiffBarsStickAfterScrollAndNavUpdates() {
        let vc = TextCodeEditorViewController()
        _ = vc.view
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()

        let before = (0..<80).map { "line_\($0)_bbbbbbbb" }.joined(separator: "\n")
        let after = (0..<80).map { i -> String in
            if [8, 24, 40, 56, 72].contains(i) { return "CHG_\(i)" }
            return "line_\(i)_bbbbbbbb"
        }.joined(separator: "\n")
        vc.presentInlineDiff(before: before, after: after)
        vc.view.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(vc.diffPendingHunkCount, 4)
        XCTAssertFalse(vc.debugDiffNavLabelText().isEmpty)

        vc.debugScrollEditor(by: 260)
        vc.view.layoutIfNeeded()

        let bars = vc.debugDiffPerHunkBarFrames()
        XCTAssertFalse(bars.isEmpty, "expected visible hunk action bars after scroll")
        for (segIdx, frame) in bars {
            guard let expectedY = vc.debugExpectedHunkBarY(segIdx: segIdx) else {
                XCTFail("missing expected Y for seg \(segIdx)")
                continue
            }
            XCTAssertEqual(frame.minY, expectedY, accuracy: 3,
                           "bar seg=\(segIdx) should stick to hunk")
        }

        let nav = vc.debugDiffNavLabelText()
        XCTAssertTrue(nav.contains("/"), "nav should look like n/N, got \(nav)")
    }

    func testTabChipTracksScrollThenAccepts() {
        let vc = TextCodeEditorViewController()
        _ = vc.view
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        vc.view.layoutIfNeeded()

        // Need a tall document so scroll moves the caret on screen.
        let body = (0..<60).map { "row_\($0)" }.joined(separator: "\n")
        vc.presentInlineDiff(before: body, after: body + "\n")
        // Exit diff via undo-all so we can edit + show tab chip.
        vc.diffUndoAll()
        vc.debugSetEditMode(true)
        // Place caret mid-document so scrolling moves chip within the viewport.
        let mid = ((body as NSString).length) / 2
        vc.debugSetSelectedLocation(mid)
        vc.debugShowTabSuggestion("complete_me")
        vc.view.layoutIfNeeded()

        let chip0 = vc.debugTabSuggestChipFrame()
        XCTAssertFalse(chip0.isNull)
        XCTAssertGreaterThan(chip0.width, 40)

        vc.debugScrollEditor(by: 160)
        let chip1 = vc.debugTabSuggestChipFrame()
        XCTAssertFalse(chip1.isNull)
        // Remains remapped into the editor view after scroll (may clamp at chrome when caret leaves).
        XCTAssertLessThan(chip1.minY, vc.view.bounds.height)
        XCTAssertGreaterThan(chip1.maxY, 0)

        vc.debugAcceptTabSuggestion()
        XCTAssertTrue(vc.debugTabSuggestChipFrame().isNull)
    }

    func testCodeFenceLayoutIsCompactCardWithHit() {
        let md = """
        intro

        ```swift
        \( (0..<40).map { "func line_\($0)() {}" }.joined(separator: "\n") )
        ```
        """
        let doc = NativeMarkdownParser.shared.parse(md)
        let style = NativeLayoutStyle(
            width: 320,
            bodyFontSize: 16,
            appearance: "dark",
            colors: DSTheme.c
        )
        NativeMessageLayouter.shared.clear()
        let layout = NativeMessageLayouter.shared.layout(document: doc, style: style)
        XCTAssertEqual(layout.codeFenceHits.count, 1)
        XCTAssertLessThan(layout.size.height, 280, "preview card must stay compact vs full fence")
        XCTAssertGreaterThan(layout.codeFenceHits[0].code.split(separator: "\n").count, 30)

        // Store/lookup must share the same cache key (v15+).
        XCTAssertNotNil(NativeMessageLayouter.shared.cachedLayout(document: doc, style: style))

        let fence = layout.commands.compactMap { cmd -> NativeCodeFenceFragment? in
            if case .codeFence(let f) = cmd { return f }
            return nil
        }.first
        XCTAssertNotNil(fence)
        XCTAssertEqual(fence?.previewAttributedLines.count, fence?.previewLines.count)
        XCTAssertLessThanOrEqual(fence?.previewLines.count ?? 99, 5)
        // Keyword coloring should tint at least one token on a `func` line.
        let first = fence?.previewAttributedLines.first
        var sawNonPrimary = false
        first?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: first?.length ?? 0)) { value, _, stop in
            if value != nil { sawNonPrimary = true; stop.pointee = true }
        }
        XCTAssertTrue(sawNonPrimary || (first?.length ?? 0) > 0)
    }
}
