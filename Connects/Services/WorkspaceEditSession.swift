import Foundation

/// Pending multi-file edits for a workspace Study session (Keep / Undo / Review).
final class WorkspaceEditSession {
    static let shared = WorkspaceEditSession()

    struct PendingFile: Equatable {
        var documentID: String
        var fileName: String
        /// Baseline at the *first* edit in this session (frozen across agent rounds).
        var before: String
        /// Latest disk / proposed text.
        var after: String
        var additions: Int
        var deletions: Int
    }

    private(set) var files: [PendingFile] = []
    private var reviewIndex: Int = 0

    var isEmpty: Bool { files.isEmpty }
    var fileCount: Int { files.count }

    func clear() {
        files = []
        reviewIndex = 0
        notify()
    }

    /// Record an edit. Re-edits of the same file keep the original `before` and only
    /// advance `after`, so Review shows a cumulative Myers diff — not a wall of `+++++`
    /// from comparing intermediate agent writes against each other.
    func upsert(documentID: String, fileName: String, before: String, after: String) {
        if let idx = files.firstIndex(where: { $0.documentID == documentID }) {
            let baseline = files[idx].before
            let stats = lightLineStats(before: baseline, after: after)
            files[idx] = PendingFile(
                documentID: documentID,
                fileName: fileName.isEmpty ? files[idx].fileName : fileName,
                before: baseline,
                after: after,
                additions: stats.add,
                deletions: stats.del
            )
        } else {
            let stats = lightLineStats(before: before, after: after)
            files.append(
                PendingFile(
                    documentID: documentID,
                    fileName: fileName,
                    before: before,
                    after: after,
                    additions: stats.add,
                    deletions: stats.del
                )
            )
        }
        notify()
    }

    func remove(documentID: String) {
        files.removeAll { $0.documentID == documentID }
        notify()
    }

    func pending(documentID: String) -> PendingFile? {
        files.first { $0.documentID == documentID }
    }

    func nextReviewDocumentID(after current: String?) -> String? {
        guard !files.isEmpty else { return nil }
        if let current, let idx = files.firstIndex(where: { $0.documentID == current }) {
            let next = idx + 1
            if next < files.count { return files[next].documentID }
            return nil
        }
        return files.first?.documentID
    }

    /// Banner-only estimate — never run full Myers on the main thread (that froze the app).
    func previewLineStats(before: String, after: String) -> (add: Int, del: Int) {
        lightLineStats(before: before, after: after)
    }

    /// Banner-only estimate — never run full Myers on the main thread (that froze the app).
    private func lightLineStats(before: String, after: String) -> (add: Int, del: Int) {
        if before == after { return (0, 0) }
        let a = before.isEmpty ? 0 : before.components(separatedBy: .newlines).count
        let b = after.isEmpty ? 0 : after.components(separatedBy: .newlines).count
        let add = max(0, b - a)
        let del = max(0, a - b)
        if add == 0 && del == 0 { return (1, 1) }
        return (add, del)
    }

    private func notify() {
        NotificationCenter.default.post(name: .workspaceEditSessionDidUpdate, object: nil)
    }
}

extension Notification.Name {
    static let workspaceEditSessionDidUpdate = Notification.Name("ConnectsWorkspaceEditSessionDidUpdate")
}
