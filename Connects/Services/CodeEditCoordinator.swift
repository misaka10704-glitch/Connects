import Foundation
import UIKit

/// Bridges chat-finished edit proposals into the Study code editor Diff surface.
final class CodeEditCoordinator: CodeEditorCompletionProviding {
    weak var editor: TextCodeEditorViewController?
    /// Forwards editor Diff session changes to chat InputBar banner.
    var onDiffSessionChange: ((Bool, Int) -> Void)?

    private(set) var isPresentingDiff = false
    private var pendingBefore: String = ""
    private var generation: UInt = 0

    func bindEditor(_ editor: TextCodeEditorViewController?) {
        self.editor = editor
        editor?.onDiffSessionChange = { [weak self] active, count in
            self?.onDiffSessionChange?(active, count)
        }
    }

    /// Why `presentProposal` refused to open Diff (for chat toast / bubble copy).
    enum PresentFailure: Equatable {
        case noEditor
        case tooLarge
        case alignment
        case identical
        case noHunks
    }

    private(set) var lastPresentFailure: PresentFailure?

    @discardableResult
    func presentProposal(_ proposal: CodeEditProposal) -> Bool {
        lastPresentFailure = nil
        guard let editor = editor else {
            lastPresentFailure = .noEditor
            return false
        }
        let snap = editor.aiEditSnapshot()
        let range = CodeEditApplyTools.resolveTargetRange(
            text: snap.text,
            selectedRange: snap.selectedRange,
            kind: proposal.rangeKind
        )
        if proposal.replacement.count > CodeEditApplyTools.maxChars
            || snap.text.count > CodeEditApplyTools.maxChars {
            lastPresentFailure = .tooLarge
            ConnectsToast.show("内容过大，请缩小选区后再试", in: editor.view, duration: 1.6)
            return false
        }
        let after = CodeEditApplyTools.composeAfter(
            before: snap.text,
            range: range,
            replacement: proposal.replacement
        )
        guard CodeEditApplyTools.validateAlignment(
            before: snap.text,
            after: after,
            range: range,
            replacement: proposal.replacement
        ) else {
            lastPresentFailure = .alignment
            return false
        }
        if after == snap.text {
            lastPresentFailure = .identical
            ConnectsToast.show("提案与当前文件相同，未打开 Diff", in: editor.view, duration: 1.8)
            return false
        }

        generation &+= 1
        pendingBefore = snap.text
        isPresentingDiff = true
        editor.onDiffSessionChange = { [weak self] active, count in
            self?.onDiffSessionChange?(active, count)
        }
        editor.onDiffFinished = { [weak self] finalText in
            self?.finish(finalText: finalText)
        }
        // Legacy callback unused for hunk flow.
        editor.onDiffDecision = nil
        let opened = editor.presentInlineDiff(before: snap.text, after: after)
        if !opened {
            // Empty hunk list (should be rare after identical check) — don't leave Diff flagged on.
            isPresentingDiff = false
            editor.onDiffFinished = nil
            pendingBefore = ""
            lastPresentFailure = .noHunks
            ConnectsToast.show("未检测到可审阅的改动块", in: editor.view, duration: 1.8)
            return false
        }
        return true
    }

    private func finish(finalText: String?) {
        guard let editor = editor, isPresentingDiff else { return }
        isPresentingDiff = false
        editor.onDiffFinished = nil
        let before = pendingBefore
        pendingBefore = ""
        if let final = finalText, final != before {
            editor.applyResolvedDiffText(final)
            editor.enterEditModeAfterKeep()
            ConnectsToast.show("Kept", in: editor.view, duration: 1.0)
        } else {
            // Editor already restored `before` in finishDiffSession when undoing.
            ConnectsToast.show("Undone", in: editor.view, duration: 1.0)
        }
        onDiffSessionChange?(false, 0)
    }

    func dismissInlineDiff(accept: Bool) {
        guard isPresentingDiff else { return }
        cancelIfNeeded()
    }

    func cancelIfNeeded() {
        guard isPresentingDiff else { return }
        isPresentingDiff = false
        editor?.onDiffFinished = nil
        editor?.dismissInlineDiff(accept: false)
        pendingBefore = ""
        onDiffSessionChange?(false, 0)
    }

    func keepAll() {
        editor?.diffKeepAll()
    }

    func undoAll() {
        editor?.diffUndoAll()
    }

    func requestCompletions(
        fileName: String,
        language: String,
        caretPrefix: String,
        fullText: String,
        lineContext: String,
        linePrefix: String,
        completion: @escaping ([String]) -> Void
    ) {
        let model = ConversationStore.shared.currentConversation?.model ?? .deepseekV4Flash
        let ext = (fileName as NSString).pathExtension
        let prompt = ChatMessage(
            role: .user,
            content: """
            Continue the code at the caret for file "\(fileName)" (.\(ext), language=\(language)).
            Use the file extension and full file context. Return ONLY the suffix to insert (a few tokens or lines). No markdown fences.

            ## FILE
            \(fullText)

            ## CURRENT LINE
            \(lineContext)

            ## PREFIX ON CURRENT LINE (before caret)
            \(linePrefix)

            ## PREFIX BEFORE CARET (truncated)
            \(caretPrefix)
            """
        )
        APIClient.shared.complete(messages: [prompt], model: model, maxTokens: 120) { result in
            switch result {
            case .success(let raw):
                let cleaned = CodeEditApplyTools.stripCodeFence(raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                completion(cleaned.isEmpty ? [] : [cleaned])
            case .failure:
                completion([])
            }
        }
    }
}
