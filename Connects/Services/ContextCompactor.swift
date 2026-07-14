import Foundation

extension Notification.Name {
    static let contextUsageDidChange = Notification.Name("ConnectsContextUsageDidChange")
    static let contextCompactionDidFinish = Notification.Name("ConnectsContextCompactionDidFinish")
}

/// Auto-compacts a conversation when API context fill crosses ~75%.
enum ContextCompactor {
    private static var inFlight = Set<String>()

    static var isBusy: Bool { !inFlight.isEmpty }

    static func isCompacting(_ conversationID: String) -> Bool {
        inFlight.contains(conversationID)
    }

    /// Compact if usage ≥ threshold. Always safe to call; no-ops when not needed.
    static func compactIfNeeded(conversationID: String,
                                force: Bool = false,
                                completion: ((Bool) -> Void)? = nil) {
        guard let conv = ConversationStore.shared.conversations.first(where: { $0.id == conversationID }) else {
            completion?(false)
            return
        }
        if StreamManager.shared.isRunning(conversationID) {
            completion?(false)
            return
        }
        if inFlight.contains(conversationID) {
            completion?(false)
            return
        }

        let snap = ContextBuilder.build(
            from: conv.messages,
            model: conv.model,
            existingSummary: conv.contextSummary,
            existingThroughID: conv.contextSummaryThroughMessageID
        )
        guard force || snap.usage.shouldAutoCompact else {
            completion?(false)
            return
        }

        let dialogue = conv.messages.filter { !$0.isStreaming && $0.role != .system }
        let keepCount = ContextBuilder.recentVerbatimMessageCount(in: dialogue, turns: ContextBuilder.compactKeepRecentTurns)
        guard dialogue.count > keepCount + 1 else {
            // Nothing older to fold — still tighten builder summary if any.
            applyLocal(conversationID: conversationID, keepTurns: ContextBuilder.compactKeepRecentTurns)
            completion?(true)
            return
        }

        let head = Array(dialogue.prefix(dialogue.count - keepCount))
        let already = conv.contextSummaryThroughMessageID
        var toFold = head
        if let tid = already, let idx = head.firstIndex(where: { $0.id == tid }) {
            toFold = Array(head.suffix(from: idx + 1))
        }
        // If everything older is already summarized but usage still high, re-summarize whole head.
        if toFold.isEmpty {
            toFold = head
        }

        inFlight.insert(conversationID)
        notifyUsage(conversationID: conversationID)

        let extractive = ContextBuilder.makeExtractiveSummary(from: toFold)
        let prior = conv.contextSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard SettingsManager.shared.hasAPIKey(for: conv.model.provider) else {
            finishLocal(conversationID: conversationID,
                        summary: merge(prior, extractive),
                        throughID: head.last?.id)
            completion?(true)
            return
        }

        let transcript = toFold.map { msg -> String in
            let role = msg.role == .user ? "User" : "Assistant"
            var text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 900 { text = String(text.prefix(900)) + "…" }
            if text.isEmpty,
               let description = msg.imageDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                text = "[image description] " + description
            } else if text.isEmpty && msg.hasImage {
                text = "[image]"
            }
            return "\(role): \(text)"
        }.joined(separator: "\n")

        var promptBody = """
        请把下面较早的对话压缩成结构化中文摘要，供后续模型继续聊天使用。
        保留：用户目标、约束、关键事实、已做决定、未决问题、专有名词。
        删除寒暄与重复。控制在 500 字以内。只输出摘要正文。
        """
        if !prior.isEmpty {
            promptBody += "\n\n已有摘要（请合并进新摘要，不要丢失重要点）：\n\(prior)"
        }
        promptBody += "\n\n待压缩对话：\n\(transcript)"

        let prompt = ChatMessage(role: .user, content: promptBody)
        APIClient.shared.complete(messages: [prompt], model: conv.model, maxTokens: 700) { result in
            var summary: String
            switch result {
            case .success(let text):
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                summary = cleaned.isEmpty ? merge(prior, extractive) : cleaned
                if summary.count > ContextBuilder.summaryCap {
                    summary = String(summary.suffix(ContextBuilder.summaryCap))
                }
            case .failure:
                summary = merge(prior, extractive)
            }
            finishLocal(conversationID: conversationID,
                        summary: summary,
                        throughID: head.last?.id)
            completion?(true)
        }
    }

    private static func applyLocal(conversationID: String, keepTurns: Int) {
        guard let conv = ConversationStore.shared.conversations.first(where: { $0.id == conversationID }) else { return }
        let built = ContextBuilder.build(
            from: conv.messages,
            model: conv.model,
            existingSummary: conv.contextSummary,
            existingThroughID: conv.contextSummaryThroughMessageID,
            keepRecentTurns: keepTurns
        )
        ConversationStore.shared.updateConversationQuietly(id: conversationID) { c in
            c.contextSummary = built.summary
            c.contextSummaryThroughMessageID = built.summaryThroughMessageID
        }
        inFlight.remove(conversationID)
        NotificationCenter.default.post(
            name: .contextCompactionDidFinish,
            object: nil,
            userInfo: ["conversationID": conversationID, "ok": true]
        )
        notifyUsage(conversationID: conversationID)
    }

    private static func finishLocal(conversationID: String, summary: String?, throughID: String?) {
        ConversationStore.shared.updateConversationQuietly(id: conversationID) { c in
            c.contextSummary = summary
            c.contextSummaryThroughMessageID = throughID
        }
        inFlight.remove(conversationID)
        NotificationCenter.default.post(
            name: .contextCompactionDidFinish,
            object: nil,
            userInfo: ["conversationID": conversationID, "ok": true]
        )
        notifyUsage(conversationID: conversationID)
    }

    private static func merge(_ prior: String, _ next: String) -> String {
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return prior }
        guard !prior.isEmpty else { return n }
        let merged = prior + "\n" + n
        if merged.count <= ContextBuilder.summaryCap { return merged }
        return String(merged.suffix(ContextBuilder.summaryCap))
    }

    static func notifyUsage(conversationID: String) {
        NotificationCenter.default.post(
            name: .contextUsageDidChange,
            object: nil,
            userInfo: ["conversationID": conversationID]
        )
    }
}
