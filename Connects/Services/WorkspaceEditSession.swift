import Foundation

/// Pending multi-file edits for a workspace Study session (Keep / Undo / Review).
/// Survives app kill via Application Support JSON keyed by conversation ID.
final class WorkspaceEditSession {
    static let shared = WorkspaceEditSession()

    struct PendingFile: Equatable, Codable {
        var documentID: String
        var fileName: String
        /// Baseline at the *first* edit in this session (frozen across agent rounds).
        var before: String
        /// Latest proposed text (may not be on disk until Keep).
        var after: String
        var additions: Int
        var deletions: Int
        /// True when the agent created this file — Undo deletes it instead of
        /// restoring an empty body.
        var createdFresh: Bool

        enum CodingKeys: String, CodingKey {
            case documentID, fileName, before, after, additions, deletions, createdFresh
        }

        init(documentID: String, fileName: String, before: String, after: String,
             additions: Int, deletions: Int, createdFresh: Bool = false) {
            self.documentID = documentID
            self.fileName = fileName
            self.before = before
            self.after = after
            self.additions = additions
            self.deletions = deletions
            self.createdFresh = createdFresh
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            documentID = try c.decode(String.self, forKey: .documentID)
            fileName = try c.decode(String.self, forKey: .fileName)
            before = try c.decode(String.self, forKey: .before)
            after = try c.decode(String.self, forKey: .after)
            additions = try c.decode(Int.self, forKey: .additions)
            deletions = try c.decode(Int.self, forKey: .deletions)
            createdFresh = try c.decodeIfPresent(Bool.self, forKey: .createdFresh) ?? false
        }
    }

    private struct DiskPayload: Codable {
        var conversationID: String
        var files: [PendingFile]
        var reviewIndex: Int
    }

    private(set) var files: [PendingFile] = []
    private var reviewIndex: Int = 0
    private(set) var boundConversationID: String?
    private var saveWorkItem: DispatchWorkItem?

    var isEmpty: Bool { files.isEmpty }
    var fileCount: Int { files.count }

    private init() {}

    /// Bind to a conversation and restore any persisted pending edits.
    func bind(conversationID: String?) {
        flush()
        if boundConversationID == conversationID, conversationID != nil { return }
        boundConversationID = conversationID
        files = []
        reviewIndex = 0
        guard let conversationID else {
            notify()
            return
        }
        loadFromDisk(conversationID: conversationID)
        notify()
    }

    func clear() {
        files = []
        reviewIndex = 0
        schedulePersist()
        notify()
    }

    /// Record an edit. Re-edits of the same file keep the original `before` and only
    /// advance `after`, so Review shows a cumulative Myers diff — not a wall of `+++++`
    /// from comparing intermediate agent writes against each other.
    func upsert(documentID: String, fileName: String, before: String, after: String,
                createdFresh: Bool = false) {
        if boundConversationID == nil {
            boundConversationID = ConversationStore.shared.currentConversationID
        }
        if let idx = files.firstIndex(where: { $0.documentID == documentID }) {
            let baseline = files[idx].before
            let stats = lightLineStats(before: baseline, after: after)
            files[idx] = PendingFile(
                documentID: documentID,
                fileName: fileName.isEmpty ? files[idx].fileName : fileName,
                before: baseline,
                after: after,
                additions: stats.add,
                deletions: stats.del,
                createdFresh: files[idx].createdFresh || createdFresh
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
                    deletions: stats.del,
                    createdFresh: createdFresh
                )
            )
        }
        schedulePersist()
        notify()
    }

    func remove(documentID: String) {
        files.removeAll { $0.documentID == documentID }
        schedulePersist()
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

    /// Flush pending encode immediately (background kill / Xcode rebuild).
    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        persistNow()
    }

    private func lightLineStats(before: String, after: String) -> (add: Int, del: Int) {
        if before == after { return (0, 0) }
        let a = before.isEmpty ? 0 : before.components(separatedBy: .newlines).count
        let b = after.isEmpty ? 0 : after.components(separatedBy: .newlines).count
        let add = max(0, b - a)
        let del = max(0, a - b)
        if add == 0 && del == 0 { return (1, 1) }
        return (add, del)
    }

    private func schedulePersist() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistNow()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func persistNow() {
        guard let conversationID = boundConversationID else { return }
        let url = Self.fileURL(for: conversationID)
        if files.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        ConnectsPaths.ensureDirectory(ConnectsPaths.workspaceEditSessionsDirectoryURL)
        let payload = DiskPayload(
            conversationID: conversationID,
            files: files,
            reviewIndex: reviewIndex
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadFromDisk(conversationID: String) {
        let url = Self.fileURL(for: conversationID)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(DiskPayload.self, from: data) else {
            files = []
            reviewIndex = 0
            return
        }
        files = payload.files
        reviewIndex = payload.reviewIndex
    }

    private static func fileURL(for conversationID: String) -> URL {
        let safe = conversationID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return ConnectsPaths.workspaceEditSessionsDirectoryURL
            .appendingPathComponent("\(safe).json")
    }

    private func notify() {
        NotificationCenter.default.post(name: .workspaceEditSessionDidUpdate, object: nil)
    }
}

extension Notification.Name {
    static let workspaceEditSessionDidUpdate = Notification.Name("ConnectsWorkspaceEditSessionDidUpdate")
}
