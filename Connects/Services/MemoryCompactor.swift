import Foundation

/// Merges expired daily logs only while the app is active. A failure leaves the
/// source file untouched so the next foreground run can retry safely.
final class MemoryCompactor {
    static let shared = MemoryCompactor()
    private var inFlight = Set<String>()
    private let lock = NSLock()

    private init() {}

    func compact(fileURLs: [URL]) {
        guard SettingsManager.shared.memoryEnabled else { return }
        let key = fileURLs.map(\.path).joined(separator: "|")
        lock.lock()
        guard !inFlight.contains(key) else {
            lock.unlock()
            return
        }
        inFlight.insert(key)
        lock.unlock()

        let raw = fileURLs.map { MemoryStore.shared.read($0) }.joined(separator: "\n\n")
        guard !raw.isEmpty else {
            finish(key)
            return
        }
        let previous = MemoryStore.shared.historicalSummary
        let prompt = """
        \(MemoryStore.shared.prompt(for: .compaction))

        已有长期背景：
        \(previous.isEmpty ? "（无）" : previous)

        待合并的过期日志：
        \(String(raw.prefix(12_000)))
        """
        let model = AIModelOption.visible.first ?? .deepseekV4Flash
        APIClient.shared.complete(messages: [ChatMessage(role: .user, content: prompt)],
                                  model: model,
                                  maxTokens: 900) { [weak self] result in
            defer { self?.finish(key) }
            guard case .success(let summary) = result else { return }
            let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            MemoryStore.shared.applyAutomaticCompaction(sourceURLs: fileURLs, proposed: cleaned)
        }
    }

    private func finish(_ key: String) {
        lock.lock()
        inFlight.remove(key)
        lock.unlock()
    }
}
