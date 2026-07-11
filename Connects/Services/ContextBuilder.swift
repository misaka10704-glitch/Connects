import Foundation

/// Builds a ChatGPT-like request context: keep recent turns, drop bloat, respect thinking mode.
enum ContextBuilder {
    /// Soft character budget for serialized text (rough proxy for tokens × ~2).
    static var defaultCharBudget: Int { 48_000 }

    static func messagesForAPI(from messages: [ChatMessage],
                               model: AIModelOption,
                               charBudget: Int = ContextBuilder.defaultCharBudget) -> [ChatMessage] {
        let finished = messages.filter { !$0.isStreaming }
        let thinkingOn = model.supportsThinkingToggle && SettingsManager.shared.thinkingEnabled

        // 1) Keep only the latest image attachment
        var slim = APIClient.slimMessagesForAPI(finished)

        // 2) Optionally strip / cap reasoning in history
        slim = slim.map { msg in
            guard msg.role == .assistant, !msg.reasoningContent.isEmpty else { return msg }
            var m = msg
            if !thinkingOn {
                m.reasoningContent = ""
            } else if m.reasoningContent.count > 6000 {
                m.reasoningContent = String(m.reasoningContent.suffix(6000))
            }
            return m
        }

        // 3) Trim from the oldest until under budget (always keep last user + trailing assistant if any)
        while estimatedChars(slim) > charBudget, slim.count > 2 {
            // Prefer dropping oldest non-image user/assistant pair
            slim.removeFirst()
        }

        // 4) If still over budget, truncate earliest remaining content
        if estimatedChars(slim) > charBudget, var first = slim.first {
            let overflow = estimatedChars(slim) - charBudget
            if first.content.count > overflow + 200 {
                first.content = "…\n" + String(first.content.suffix(max(0, first.content.count - overflow)))
                slim[0] = first
            }
        }

        return slim
    }

    private static func estimatedChars(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { sum, m in
            var n = m.content.count + m.reasoningContent.count
            if let img = m.imageJPEGBase64 { n += min(img.count, 50_000) } // image dominates
            return sum + n + 16
        }
    }
}
