import Foundation
import UIKit

/// Bridges chat-finished edit proposals into the Study code editor Diff surface.
final class CodeEditCoordinator: CodeEditorCompletionProviding {
    weak var editor: TextCodeEditorViewController?
    /// Forwards editor Diff session changes to chat InputBar banner.
    var onDiffSessionChange: ((Bool, Int) -> Void)?

    private(set) var isPresentingDiff = false
    private var pendingBefore: String = ""
    private var pendingAssistantMessageID: String?
    private var generation: UInt = 0
    /// Kept edits keyed by assistant message id — used to restore file text on「重跑」.
    private var appliedRollbackByMessageID: [String: (documentID: String, before: String)] = [:]

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
    func presentProposal(_ proposal: CodeEditProposal, assistantMessageID: String = "") -> Bool {
        lastPresentFailure = nil
        guard let editor = editor else {
            lastPresentFailure = .noEditor
            return false
        }

        // Prefer frozen session / Diff baseline over the live textView (which may be a
        // rendered hunk view or an intermediate agent write).
        let docID = editor.activeDocumentID
        let baseline: String = {
            if let docID, let pending = WorkspaceEditSession.shared.pending(documentID: docID) {
                return pending.before
            }
            if let locked = editor.diffSessionBaseline {
                return locked
            }
            return editor.aiEditSnapshot().text
        }()
        let snapRange = editor.aiEditSnapshot().selectedRange
        let range = CodeEditApplyTools.resolveTargetRange(
            text: baseline,
            selectedRange: snapRange,
            kind: proposal.rangeKind
        )
        if proposal.replacement.count > CodeEditApplyTools.maxChars
            || baseline.count > CodeEditApplyTools.maxChars {
            lastPresentFailure = .tooLarge
            ConnectsToast.show("内容过大，请缩小选区后再试", in: editor.view, duration: 1.6)
            return false
        }
        let after = CodeEditApplyTools.composeAfter(
            before: baseline,
            range: range,
            replacement: proposal.replacement
        )
        guard CodeEditApplyTools.validateAlignment(
            before: baseline,
            after: after,
            range: range,
            replacement: proposal.replacement
        ) else {
            lastPresentFailure = .alignment
            return false
        }
        if after == baseline {
            lastPresentFailure = .identical
            ConnectsToast.show("提案与当前文件相同，未打开 Diff", in: editor.view, duration: 1.8)
            return false
        }

        generation &+= 1
        pendingBefore = baseline
        pendingAssistantMessageID = assistantMessageID.isEmpty ? nil : assistantMessageID
        isPresentingDiff = true
        editor.onDiffSessionChange = { [weak self] active, count in
            self?.onDiffSessionChange?(active, count)
        }
        editor.onDiffFinished = { [weak self] finalText in
            self?.finish(finalText: finalText)
        }
        // Legacy callback unused for hunk flow.
        editor.onDiffDecision = nil
        let opened = editor.presentInlineDiff(before: baseline, after: after)
        if !opened {
            // Empty hunk list (should be rare after identical check) — don't leave Diff flagged on.
            isPresentingDiff = false
            editor.onDiffFinished = nil
            pendingBefore = ""
            pendingAssistantMessageID = nil
            lastPresentFailure = .noHunks
            ConnectsToast.show("未检测到可审阅的改动块", in: editor.view, duration: 1.8)
            return false
        }
        if let docID = docID {
            let name = StudyDocumentStore.shared.document(id: docID)?.title
                ?? proposal.targetPath
                ?? "file"
            WorkspaceEditSession.shared.upsert(
                documentID: docID,
                fileName: name,
                before: baseline,
                after: after
            )
        }
        return true
    }

    /// Refresh an open Diff (or open Review) using the cumulative WorkspaceEditSession pair.
    @discardableResult
    func presentCumulativeSessionDiff(documentID: String) -> Bool {
        guard let pending = WorkspaceEditSession.shared.pending(documentID: documentID),
              let editor = editor else { return false }
        if pending.before == pending.after {
            lastPresentFailure = .identical
            return false
        }
        lastPresentFailure = nil
        generation &+= 1
        pendingBefore = pending.before
        pendingAssistantMessageID = nil
        isPresentingDiff = true
        editor.onDiffSessionChange = { [weak self] active, count in
            self?.onDiffSessionChange?(active, count)
        }
        editor.onDiffFinished = { [weak self] finalText in
            self?.finish(finalText: finalText)
        }
        editor.onDiffDecision = nil
        let opened = editor.presentInlineDiff(before: pending.before, after: pending.after)
        if !opened {
            isPresentingDiff = false
            editor.onDiffFinished = nil
            pendingBefore = ""
            lastPresentFailure = .noHunks
            return false
        }
        return true
    }

    private func finish(finalText: String?) {
        guard let editor = editor, isPresentingDiff else { return }
        isPresentingDiff = false
        editor.onDiffFinished = nil
        let before = pendingBefore
        let messageID = pendingAssistantMessageID
        pendingBefore = ""
        pendingAssistantMessageID = nil
        if let final = finalText, final != before {
            if let messageID, let docID = editor.activeDocumentID {
                appliedRollbackByMessageID[messageID] = (docID, before)
            }
            editor.applyResolvedDiffText(final)
            editor.enterReadingModeAfterKeep()
            if let docID = editor.activeDocumentID {
                WorkspaceEditSession.shared.remove(documentID: docID)
            }
            ConnectsToast.show("Kept", in: editor.view, duration: 1.0)
        } else {
            // Editor already restored `before` in finishDiffSession when undoing.
            if let docID = editor.activeDocumentID {
                WorkspaceEditSession.shared.remove(documentID: docID)
            }
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
        pendingAssistantMessageID = nil
        onDiffSessionChange?(false, 0)
    }

    /// On「重跑」: cancel open Diff and/or restore the pre-Keep file for that assistant turn.
    @discardableResult
    func revertForRetry(assistantMessageID: String) -> Bool {
        var didRevert = false
        if isPresentingDiff {
            // Pending review — restore `before` via dismiss.
            cancelIfNeeded()
            didRevert = true
        }
        if let entry = appliedRollbackByMessageID.removeValue(forKey: assistantMessageID) {
            if let editor = editor, editor.activeDocumentID == entry.documentID {
                editor.restoreDocumentText(entry.before)
            } else {
                try? StudyDocumentStore.shared.writeTextContent(entry.before, for: entry.documentID)
                if let editor = editor, editor.activeDocumentID == entry.documentID {
                    editor.restoreDocumentText(entry.before)
                }
            }
            didRevert = true
            if let host = editor?.view {
                ConnectsToast.show("已还原本轮 AI 改动", in: host, duration: 1.4)
            }
        }
        return didRevert
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
