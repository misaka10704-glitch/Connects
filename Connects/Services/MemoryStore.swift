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
                                  maxTokens: 120) { [weak self] result in
            guard let self = self, SettingsManager.shared.memoryEnabled else { return }
            let extracted: String
            if case .success(let text) = result, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                extracted = self.normalizeCaptureOutput(text, user: user)
            } else {
                extracted = self.fallbackEventLine(user: user)
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
        let bg = String(historicalSummary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_200))
        let events = recentEventsIndex(maxEntries: 20, maxChars: 800)
        var parts: [String] = [prompt(for: .injection)]
        if !bg.isEmpty {
            parts.append("## 稳定背景\n\(bg)")
        }
        if !events.isEmpty {
            parts.append("## 近期事件索引\n\(events)")
        }
        guard parts.count > 1 else { return "" }
        return String(parts.joined(separator: "\n\n").prefix(1_800))
    }

    /// Compact event lines from the last week for API injection (detail via conversation links).
    func recentEventsIndex(maxEntries: Int = 20, maxChars: Int = 800) -> String {
        migrateIfNeeded()
        var lines: [String] = []
        for date in recentLogDates() {
            let raw = linkifyLegacyConversationIDs(read(logURL(date)))
            for block in raw.components(separatedBy: "### ").dropFirst() {
                if let line = compactEventIndexLine(block: block, date: date) {
                    lines.append(line)
                }
                if lines.count >= maxEntries { break }
            }
            if lines.count >= maxEntries { break }
        }
        var out = ""
        for line in lines {
            let next = out.isEmpty ? line : out + "\n" + line
            if next.count > maxChars { break }
            out = next
        }
        return out
    }

    func assembledMarkdown() -> String {
        migrateIfNeeded()
        var result = "# Memory\n\n"
        for date in recentLogDates() {
            result += "## \(date)\n\n\(linkifyLegacyConversationIDs(read(logURL(date))))\n\n"
        }
        result += "---\n\n## 稳定背景\n\n"
        result += historicalSummary.isEmpty ? "（尚无已确认的稳定背景）\n" : historicalSummary
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
        let next = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3_000))
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
        let event = extracted
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = """
        ### \(time)
        - 事件：\(event) | [打开聊天](connects://conversation/\(conversation.id))

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
        try? String(text.prefix(3_000)).write(to: url, atomically: true, encoding: .utf8)
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .memoryStoreDidUpdate, object: nil) }
    }

    private func contextSnippet(_ conversation: Conversation) -> String {
        conversation.messages.filter { !$0.isStreaming }.suffix(2).map {
            let role = $0.role == .user ? "用户" : "助手"
            return "\(role)：\(String($0.content.prefix(160)))"
        }.joined(separator: " | ")
    }

    private func normalizeCaptureOutput(_ raw: String, user: String) -> String {
        let line = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return fallbackEventLine(user: user) }
        return String(line.prefix(120))
    }

    private func fallbackEventLine(user: String) -> String {
        let topic = String(user.replacingOccurrences(of: "\n", with: " ").prefix(48))
        return "用户谈及：\(topic)（详见原会话）"
    }

    private func compactEventIndexLine(block: String, date: String) -> String? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else {
            return nil
        }
        let body = lines.dropFirst().joined(separator: " ")
        let link = extractConversationLink(from: body) ?? extractConversationLink(from: block)
        let summary = extractEventSummary(from: body)
        guard !summary.isEmpty else { return nil }
        if let link = link {
            return "- \(date) \(header) | \(summary) | \(link)"
        }
        return "- \(date) \(header) | \(summary)"
    }

    private func extractConversationLink(from text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"connects://conversation/[A-Za-z0-9-]+"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = re.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        let url = String(text[swiftRange])
        return "[打开聊天](\(url))"
    }

    private func extractEventSummary(from text: String) -> String {
        if let event = capturePrefixedLine(in: text, prefixes: ["事件：", "事件:"]) {
            return truncateEventSummary(stripConversationLink(event))
        }
        if let distilled = capturePrefixedLine(in: text, prefixes: ["提炼：", "提炼:"]) {
            return truncateEventSummary(stripConversationLink(distilled))
        }
        if let question = capturePrefixedLine(in: text, prefixes: ["用户提问：", "用户提问:"]) {
            return truncateEventSummary(question)
        }
        let cleaned = text
            .replacingOccurrences(of: #"\[打开聊天\]\(connects://conversation/[^)]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"connects://conversation/[A-Za-z0-9-]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "- 会话：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncateEventSummary(cleaned)
    }

    private func capturePrefixedLine(in text: String, prefixes: [String]) -> String? {
        for prefix in prefixes {
            if let range = text.range(of: prefix) {
                let tail = text[range.upperBound...]
                if let end = tail.firstIndex(where: { $0 == "\n" }) {
                    return String(tail[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func stripConversationLink(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\[打开聊天\]\(connects://conversation/[^)]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"connects://conversation/[A-Za-z0-9-]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " | ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncateEventSummary(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return String(trimmed.prefix(88))
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
