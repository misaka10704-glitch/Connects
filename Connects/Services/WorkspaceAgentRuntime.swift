import Foundation
import UIKit

extension Notification.Name {
    /// Posted after Agent mutate batch flush — StudyShell coalesces editor/webview reload.
    static let workspaceAgentDidMutateDocuments = Notification.Name("ConnectsWorkspaceAgentDidMutateDocuments")
}

/// OpenCode-style Agent mutate pipeline (workspace + Agent mode only).
/// Batches create/edit writes so Diff banner / editor reload once per tool round.
final class WorkspaceAgentRuntime {
    static let shared = WorkspaceAgentRuntime()

    struct PendingEdit {
        var path: String
        var body: String
        var documentID: String
        var fileName: String
        var before: String
        var createdFresh: Bool
    }

    struct FlushResult {
        var cards: [(rootMessageID: String, card: AgentEditCard)]
        var firstDiffDocumentID: String?
        var mutatedDocumentIDs: [String]
    }

    private let lock = NSLock()
    private var pending: [PendingEdit] = []
    private var batchRootMessageID: String?
    private var batchConversationID: String?
    private var batchWorkspaceID: String?

    private init() {}

    func beginEditBatch(conversationID: String, rootMessageID: String, workspaceID: String) {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
        batchConversationID = conversationID
        batchRootMessageID = rootMessageID
        batchWorkspaceID = workspaceID
    }

    /// Safe from tool-loop background queue. Resolves/creates doc + writes disk; UI deferred to flush.
    func enqueueProposedEdit(path: String, body: String) {
        lock.lock()
        let wsID = batchWorkspaceID
        let conversationID = batchConversationID
        lock.unlock()
        guard let wsID else { return }

        // Hard lock: never write a file other than the Study-open document (Plan may stage new plans).
        if let conversationID,
           let conv = ConversationStore.shared.conversation(id: conversationID),
           conv.studyAgentMode != .plan,
           !conv.allowsStudyMutating(path: path) {
            return
        }

        let name = (path as NSString).lastPathComponent
        guard let docID = Self.resolveDocumentID(path: path, workspaceID: wsID) else {
            // Creating a new path is out of Study edit scope (UI + only).
            return
        }

        let diskNow = StudyDocumentStore.shared.textContent(for: docID) ?? ""
        let sessionBefore = WorkspaceEditSession.shared.pending(documentID: docID)?.before
        let before: String
        if let sessionBefore {
            before = sessionBefore
        } else if diskNow == body {
            before = ""
        } else {
            before = diskNow
        }

        // Defer disk write until Keep — session holds before/after for review.
        let fileName = StudyDocumentStore.shared.document(id: docID)?.title ?? name
        lock.lock()
        if let idx = pending.firstIndex(where: { $0.documentID == docID }) {
            pending[idx].body = body
            pending[idx].fileName = fileName
            // Keep first `before` in this batch / session.
        } else {
            pending.append(PendingEdit(
                path: path,
                body: body,
                documentID: docID,
                fileName: fileName,
                before: before,
                createdFresh: false
            ))
        }
        lock.unlock()
    }

    /// Call on main after tool loop finishes the round (continued or not).
    @discardableResult
    func flushEditBatch(
        applyPlanFileEdit: (String, String) -> Void
    ) -> FlushResult {
        assert(Thread.isMainThread)
        lock.lock()
        let edits = pending
        let rootID = batchRootMessageID
        let conversationID = batchConversationID
        pending.removeAll()
        batchRootMessageID = nil
        batchConversationID = nil
        batchWorkspaceID = nil
        lock.unlock()

        guard !edits.isEmpty, let rootID, let conversationID else {
            return FlushResult(cards: [], firstDiffDocumentID: nil, mutatedDocumentIDs: [])
        }

        var cards: [(String, AgentEditCard)] = []
        var mutatedIDs: [String] = []
        for edit in edits {
            if edit.before == edit.body,
               WorkspaceEditSession.shared.pending(documentID: edit.documentID) != nil {
                continue
            }
            let stats = WorkspaceEditSession.shared.previewLineStats(before: edit.before, after: edit.body)
            let snippets = lightDiffSnippets(before: edit.before, after: edit.body)
            WorkspaceEditSession.shared.upsert(
                documentID: edit.documentID,
                fileName: edit.fileName,
                before: edit.before,
                after: edit.body
            )
            let card = AgentEditCard(
                fileName: edit.fileName,
                documentID: edit.documentID,
                additions: stats.add,
                deletions: stats.del,
                snippetMinus: snippets.minus,
                snippetPlus: snippets.plus
            )
            cards.append((rootID, card))
            mutatedIDs.append(edit.documentID)
            applyPlanFileEdit(edit.path, edit.body)
        }

        ConversationStore.shared.updateConversationQuietly(id: conversationID) { draft in
            guard let idx = draft.messages.lastIndex(where: { $0.id == rootID }) else { return }
            for (_, card) in cards {
                if let existing = draft.messages[idx].agentEditCards.firstIndex(where: {
                    $0.documentID == card.documentID || $0.fileName == card.fileName
                }) {
                    draft.messages[idx].agentEditCards[existing] = card
                } else {
                    draft.messages[idx].agentEditCards.append(card)
                }
            }
        }

        if !mutatedIDs.isEmpty {
            NotificationCenter.default.post(
                name: .workspaceAgentDidMutateDocuments,
                object: nil,
                userInfo: ["documentIDs": mutatedIDs]
            )
        }

        return FlushResult(
            cards: cards.map { (rootMessageID: $0.0, card: $0.1) },
            firstDiffDocumentID: edits.first?.documentID,
            mutatedDocumentIDs: mutatedIDs
        )
    }

    func cancelEditBatch() {
        lock.lock()
        pending.removeAll()
        batchRootMessageID = nil
        batchConversationID = nil
        batchWorkspaceID = nil
        lock.unlock()
    }

    static func resolveDocumentID(path: String, workspaceID: String) -> String? {
        let needle = (path as NSString).lastPathComponent
        guard !needle.isEmpty else { return nil }
        guard let ws = StudyWorkspaceStore.shared.workspace(id: workspaceID) else { return nil }
        for id in ws.documentIDs {
            guard let doc = StudyDocumentStore.shared.document(id: id) else { continue }
            if let display = doc.displayPath,
               (display as NSString).lastPathComponent.caseInsensitiveCompare(needle) == .orderedSame {
                return id
            }
            if doc.title.caseInsensitiveCompare(needle) == .orderedSame
                || doc.title.caseInsensitiveCompare((needle as NSString).deletingPathExtension) == .orderedSame {
                return id
            }
            if !doc.localRelativePath.isEmpty,
               (doc.localRelativePath as NSString).lastPathComponent.caseInsensitiveCompare(needle) == .orderedSame {
                return id
            }
        }
        return nil
    }

    private func lightDiffSnippets(before: String, after: String) -> (minus: String, plus: String) {
        let a = before.components(separatedBy: .newlines)
        let b = after.components(separatedBy: .newlines)
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        var j = 0
        while j < (a.count - i), j < (b.count - i),
              a[a.count - 1 - j] == b[b.count - 1 - j] { j += 1 }
        let minusSlice = a.dropFirst(i).dropLast(j)
        let plusSlice = b.dropFirst(i).dropLast(j)
        let minus = minusSlice.prefix(4).joined(separator: "\n")
        let plus = plusSlice.prefix(4).joined(separator: "\n")
        return (String(minus.prefix(280)), String(plus.prefix(280)))
    }
}
