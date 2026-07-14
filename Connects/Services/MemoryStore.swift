import Foundation

extension Notification.Name {
    static let memoryStoreDidUpdate = Notification.Name("ConnectsMemoryStoreDidUpdate")
}

final class MemoryStore {
    static let shared = MemoryStore()

    private let folderName = "ConnectsMemory"
    private let promptPrefix = "connects_memory_prompt_"
    private let queue = DispatchQueue(label: "Connects.MemoryStore", qos: .utility)
    private var didMigrate = false

    private init() {}

    var historicalSummary: String {
        read(backgroundURL())
    }

    func prompt(for kind: MemoryPromptKind) -> String {
        let text = UserDefaults.standard.string(forKey: promptPrefix + kind.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? kind.defaultValue : text
    }

    func setPrompt(_ text: String, for kind: MemoryPromptKind) {
        UserDefaults.standard.set(String(text.prefix(4_000)), forKey: promptPrefix + kind.rawValue)
    }

    func restoreDefaultPrompt(for kind: MemoryPromptKind) {
        UserDefaults.standard.removeObject(forKey: promptPrefix + kind.rawValue)
    }

    func append(userText: String, conversation: Conversation) {
        guard SettingsManager.shared.memoryEnabled else { return }
        let user = String(userText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        guard !user.isEmpty else { return }
        let localSnippet = contextSnippet(conversation)
        let request = """
        \(prompt(for: .capture))

        用户提问：\(user)
        有限上下文：\(localSnippet)
        """
        APIClient.shared.complete(messages: [ChatMessage(role: .user, content: request)],
                                  model: conversation.model,
                                  maxTokens: 280) { [weak self] result in
            guard let self = self, SettingsManager.shared.memoryEnabled else { return }
            let extracted: String
            if case .success(let text) = result, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                extracted = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_200))
            } else {
                extracted = localSnippet
            }
            self.queue.async {
                self.migrateIfNeeded()
                self.appendMarkdown(user: user, extracted: extracted, conversation: conversation)
                self.notify()
                self.scanForCompaction()
            }
        }
    }

    func injectedBackground() -> String {
        guard SettingsManager.shared.memoryEnabled else { return "" }
        return String(historicalSummary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3_200))
    }

    func assembledMarkdown() -> String {
        migrateIfNeeded()
        var result = "# Memory\n\n"
        for date in recentLogDates() {
            result += "## \(date)\n\n\(linkifyLegacyConversationIDs(read(logURL(date))))\n\n"
        }
        result += "---\n\n## 整体背景\n\n"
        result += historicalSummary.isEmpty ? "（尚无已确认的整体背景）\n" : historicalSummary
        return result
    }

    func recentLogDates() -> [String] {
        migrateIfNeeded()
        let formatter = dateFormatter()
        let cutoff = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
        return allLogURLs().compactMap { url -> String? in
            let name = url.deletingPathExtension().lastPathComponent
            guard let date = formatter.date(from: name), date >= cutoff else { return nil }
            return name
        }.sorted(by: >)
    }

    func pendingChanges() -> [PendingMemoryChange] {
        migrateIfNeeded()
        return (try? FileManager.default.contentsOfDirectory(at: pendingFolderURL(), includingPropertiesForKeys: nil))?
            .compactMap { url in try? JSONDecoder().decode(PendingMemoryChange.self, from: Data(contentsOf: url)) }
            .sorted { $0.createdAt > $1.createdAt } ?? []
    }

    func commit(_ pending: PendingMemoryChange) {
        migrateIfNeeded()
        let before = historicalSummary
        write(pending.after, to: backgroundURL())
        appendRevision(kind: "compaction", before: before, after: pending.after)
        for path in pending.sourceLogPaths {
            try? FileManager.default.removeItem(at: folderURL().appendingPathComponent(path))
        }
        try? FileManager.default.removeItem(at: pendingURL(pending.id))
        notify()
    }

    func discard(_ pending: PendingMemoryChange) {
        try? FileManager.default.removeItem(at: pendingURL(pending.id))
        notify()
    }

    func proposeBackgroundUpdate(_ text: String) {
        let next = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6_000))
        guard next != historicalSummary else { return }
        createFolders()
        let change = PendingMemoryChange(id: UUID().uuidString,
                                         createdAt: Date(),
                                         before: historicalSummary,
                                         after: next,
                                         sourceLogPaths: [])
        if let data = try? JSONEncoder().encode(change) {
            try? data.write(to: pendingURL(change.id), options: .atomic)
        }
        notify()
    }

    func applyAutomaticCompaction(sourceURLs: [URL], proposed: String) {
        let before = historicalSummary
        write(proposed, to: backgroundURL())
        appendRevision(kind: "automaticCompaction", before: before, after: proposed)
        for url in sourceURLs { try? FileManager.default.removeItem(at: url) }
        notify()
    }

    func revert(to revision: MemoryRevision) {
        let current = historicalSummary
        write(revision.before, to: backgroundURL())
        appendRevision(kind: "revert", before: current, after: revision.before)
        notify()
    }

    func revisions() -> [MemoryRevision] {
        migrateIfNeeded()
        return (try? FileManager.default.contentsOfDirectory(at: revisionsFolderURL(), includingPropertiesForKeys: nil))?
            .compactMap { try? JSONDecoder().decode(MemoryRevision.self, from: Data(contentsOf: $0)) }
            .sorted { $0.id > $1.id } ?? []
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: folderURL())
        notify()
    }

    func processRetention() {
        guard SettingsManager.shared.memoryEnabled else { return }
        queue.async { [weak self] in
            self?.migrateIfNeeded()
            self?.scanForCompaction()
        }
    }

    func createPendingCompaction(sourceURLs: [URL], proposed: String) {
        guard !sourceURLs.isEmpty else { return }
        let change = PendingMemoryChange(id: UUID().uuidString,
                                         createdAt: Date(),
                                         before: historicalSummary,
                                         after: proposed,
                                         sourceLogPaths: sourceURLs.map { "logs/" + $0.lastPathComponent })
        createFolders()
        if let data = try? JSONEncoder().encode(change) {
            try? data.write(to: pendingURL(change.id), options: .atomic)
        }
        notify()
    }

    fileprivate func expiredLogURLs() -> [URL] {
        migrateIfNeeded()
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: Date()))!
        let formatter = dateFormatter()
        return allLogURLs().filter {
            guard let date = formatter.date(from: $0.deletingPathExtension().lastPathComponent) else { return false }
            return date < cutoff
        }
    }

    func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func appendMarkdown(user: String, extracted: String, conversation: Conversation) {
        let name = dateFormatter().string(from: Date())
        let url = logURL(name)
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        let entry = """
        ### \(time)
        - 会话：[打开聊天](connects://conversation/\(conversation.id))
        - 用户提问：\(user.replacingOccurrences(of: "\n", with: " "))
        - 提炼：\(extracted.replacingOccurrences(of: "\n", with: " "))

        """
        append(entry, to: url)
    }

    private func scanForCompaction() {
        let expired = expiredLogURLs()
        guard !expired.isEmpty else { return }
        MemoryCompactor.shared.compact(fileURLs: expired)
    }

    private func appendRevision(kind: String, before: String, after: String) {
        var manifest = loadManifest()
        let revision = MemoryRevision(id: manifest.nextRevisionID, createdAt: Date(), kind: kind, before: before, after: after)
        manifest.nextRevisionID += 1
        if let data = try? JSONEncoder().encode(revision) {
            try? data.write(to: revisionsFolderURL().appendingPathComponent(String(format: "%06d.json", revision.id)), options: .atomic)
        }
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL(), options: .atomic)
        }
    }

    private func loadManifest() -> MemoryManifest {
        guard let data = try? Data(contentsOf: manifestURL()),
              let manifest = try? JSONDecoder().decode(MemoryManifest.self, from: data) else { return MemoryManifest() }
        return manifest
    }

    private func migrateIfNeeded() {
        guard !didMigrate else { return }
        didMigrate = true
        createFolders()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folderURL(), includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "md" && file.lastPathComponent != "background.md" {
            let destination = logsFolderURL().appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: destination.path) {
                try? fm.moveItem(at: file, to: destination)
            }
        }
    }

    private func createFolders() {
        for url in [folderURL(), logsFolderURL(), revisionsFolderURL(), pendingFolderURL()] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func write(_ text: String, to url: URL) {
        createFolders()
        try? String(text.prefix(6_000)).write(to: url, atomically: true, encoding: .utf8)
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .memoryStoreDidUpdate, object: nil) }
    }

    private func contextSnippet(_ conversation: Conversation) -> String {
        conversation.messages.filter { !$0.isStreaming }.suffix(2).map {
            "\($0.role == .user ? "用户" : "助手")：\(String($0.content.prefix(500)))"
        }.joined(separator: "\n")
    }

    /// Older logs stored a bare conversation UUID. Render those entries as the
    /// same internal link used by new logs so the entire seven-day journal
    /// remains navigable after migration.
    private func linkifyLegacyConversationIDs(_ markdown: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(?m)^-\s*会话[：:]\s*([A-Za-z0-9-]{20,})\s*$"#) else {
            return markdown
        }
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return re.stringByReplacingMatches(in: markdown, options: [], range: range,
                                           withTemplate: "- 会话：[打开聊天](connects://conversation/$1)")
    }

    private func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func folderURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(folderName, isDirectory: true)
    }
    private func logsFolderURL() -> URL { folderURL().appendingPathComponent("logs", isDirectory: true) }
    private func revisionsFolderURL() -> URL { folderURL().appendingPathComponent("revisions", isDirectory: true) }
    private func pendingFolderURL() -> URL { folderURL().appendingPathComponent("pending", isDirectory: true) }
    private func backgroundURL() -> URL { folderURL().appendingPathComponent("background.md") }
    private func manifestURL() -> URL { folderURL().appendingPathComponent("manifest.json") }
    private func logURL(_ date: String) -> URL { logsFolderURL().appendingPathComponent(date + ".md") }
    private func pendingURL(_ id: String) -> URL { pendingFolderURL().appendingPathComponent(id + ".json") }
    private func allLogURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: logsFolderURL(), includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" } ?? []
    }
}
