import Foundation

/// Assembles a high-signal API context (Anthropic / OpenAI style):
/// system pin → session summary → recent verbatim turns, under a practical char budget.
///
/// Sources: Anthropic context engineering (compaction + attention budget),
/// OpenAI session memory (summary + keep last N), production sliding-window + budget allocation.
enum ContextBuilder {
    private static let baseSystemPrompt = """
    You are a precise, context-aware assistant. Answer the latest user message directly and use earlier turns only to resolve intent and references.

    - Match the user's language and requested level of detail.
    - Treat earlier assistant answers as fallible; correct them when the user challenges them.
    - Do not replace the requested explanation with generic disclaimers, slogans, moral judgments, or political boilerplate.
    - For historical, political, or sensitive topics, give a neutral factual explanation of causes, ideas, institutions, chronology, and consequences. Briefly distinguish established facts from interpretation.
    - If a term is genuinely ambiguous, state the likely interpretation or ask one concise clarification instead of answering a different question.
    """

    struct BuildResult {
        let messages: [ChatMessage]
        /// Compact notes for turns that slid out of the verbatim window.
        let summary: String?
        let summaryThroughMessageID: String?
        let droppedCount: Int
        let estimatedChars: Int
        let budget: Int

        var usage: Usage {
            Usage(usedChars: estimatedChars, budgetChars: budget)
        }
    }

    struct Usage {
        let usedChars: Int
        let budgetChars: Int

        var ratio: Double {
            guard budgetChars > 0 else { return 0 }
            return min(1, Double(usedChars) / Double(budgetChars))
        }

        var percent: Int { Int((ratio * 100).rounded()) }
        var percentText: String { String(format: "%.1f%%", ratio * 100) }

        /// Soft visibility floor (0 = rely on `shouldShowUsage` for presence).
        static let visibleThreshold: Double = 0.0
        /// Auto-compact when at/above this fill level.
        static let autoCompactThreshold: Double = 0.75

        var shouldAutoCompact: Bool { ratio >= Self.autoCompactThreshold }

        var level: Level {
            switch ratio {
            case ..<0.5: return .ok
            case ..<0.75: return .warn
            default: return .critical
            }
        }

        enum Level { case ok, warn, critical }
    }

    /// Recent verbatim turns to keep (user↔assistant pairs). Older content becomes summary.
    static let keepRecentTurns = 6
    /// After auto-compact, keep fewer verbatim turns.
    static let compactKeepRecentTurns = 3
    /// Soft cap for a single mid-context message body (chars).
    static let midMessageCap = 4_500
    /// Soft cap for the compacted summary block.
    static let summaryCap = 2_800
    /// Soft cap used only for models that do not require verbatim preserved thinking.
    static let lastReasoningCap = 4_000

    static func messagesForAPI(from messages: [ChatMessage],
                               model: AIModelOption,
                               existingSummary: String? = nil,
                               existingThroughID: String? = nil,
                               agentPrompt: String? = nil,
                               memoryBackground: String? = nil,
                               keepRecentTurns: Int = ContextBuilder.keepRecentTurns) -> [ChatMessage] {
        build(from: messages,
              model: model,
              existingSummary: existingSummary,
              existingThroughID: existingThroughID,
              agentPrompt: agentPrompt,
              memoryBackground: memoryBackground,
              keepRecentTurns: keepRecentTurns).messages
    }

    /// Snapshot of what would be sent for the current conversation (for the usage UI).
    static func usage(for conversation: Conversation) -> Usage {
        build(from: conversation.messages,
              model: conversation.model,
              existingSummary: conversation.contextSummary,
              existingThroughID: conversation.contextSummaryThroughMessageID,
              agentPrompt: AgentStore.shared.agent(id: conversation.agentID)?.trimmedPrompt,
              memoryBackground: MemoryStore.shared.injectedBackground()).usage
    }

    /// Fast estimate for immediate switch UI; `usage(for:)` refines asynchronously.
    static func quickUsageEstimate(for conversation: Conversation) -> Usage {
        let budget = charBudget(for: conversation.model)
        var chars = baseSystemPrompt.count + 400
        let background = MemoryStore.shared.injectedBackground()
        if !background.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chars += min(background.count, 1_800)
        }
        if let agent = AgentStore.shared.agent(id: conversation.agentID)?.trimmedPrompt {
            chars += agent.count
        }
        if let summary = conversation.contextSummary {
            chars += summary.count
        }
        for msg in conversation.messages where !msg.isStreaming {
            chars += msg.content.count + msg.reasoningContent.count + msg.searchProcessContent.count
            if let description = msg.imageDescription {
                chars += description.count
            }
        }
        return Usage(usedChars: chars, budgetChars: budget)
    }

    /// Whether the meter should be visible for this conversation.
    static func shouldShowUsage(for conversation: Conversation) -> Bool {
        conversation.messages.contains { !$0.isStreaming && ($0.role == .user || $0.role == .assistant) }
    }

    static func build(from messages: [ChatMessage],
                      model: AIModelOption,
                      existingSummary: String? = nil,
                      existingThroughID: String? = nil,
                      agentPrompt: String? = nil,
                      memoryBackground: String? = nil,
                      keepRecentTurns: Int = ContextBuilder.keepRecentTurns) -> BuildResult {
        let budget = charBudget(for: model)
        let thinkingOn = model.thinkingActive
        let finished = messages.filter { !$0.isStreaming }

        var working = APIClient.slimMessagesForAPI(finished)
        working = pruneReasoning(
            working,
            // Kimi K2.6 ignores historical thinking unless keep=all. Omitting it
            // from ordinary turns cuts request size and prefill latency.
            thinkingOn: thinkingOn && model.provider != .kimi,
            preserveAllReasoning: false
        )
        working = capMidContextBodies(working)

        // A stable instruction pin prevents sparse/ambiguous contexts from
        // drifting into generic template answers (especially on sensitive history).
        let instructionPin = ChatMessage(role: .system, content: baseSystemPrompt)
        var systems = [instructionPin]
        if let background = memoryBackground?.trimmingCharacters(in: .whitespacesAndNewlines),
           !background.isEmpty {
            systems.append(ChatMessage(
                role: .system,
                content: "[Cross-session user memory]\n\(String(background.prefix(1_800)))"
            ))
        }
        if let prompt = agentPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            systems.append(ChatMessage(role: .system, content: "[Selected user agent]\n\(String(prompt.prefix(2_400)))"))
        }
        systems += working.filter { $0.role == .system }
        let dialogue = working.filter { $0.role != .system }

        // Invalidate stale summary if the covered message disappeared (retry / fork / delete).
        var summary = existingSummary
        var throughID = existingThroughID
        if let tid = throughID, !dialogue.contains(where: { $0.id == tid }) {
            summary = nil
            throughID = nil
        }

        let keepCount = recentVerbatimCount(in: dialogue, turns: keepRecentTurns)
        var head: [ChatMessage] = []
        var tail = dialogue
        if dialogue.count > keepCount {
            head = Array(dialogue.prefix(dialogue.count - keepCount))
            tail = Array(dialogue.suffix(keepCount))
        }

        // Only summarize head turns not already covered by the stored summary.
        var newlyDropped: [ChatMessage] = head
        if let tid = throughID, let idx = head.firstIndex(where: { $0.id == tid }) {
            newlyDropped = Array(head.suffix(from: idx + 1))
        }

        if !newlyDropped.isEmpty {
            let piece = extractiveSummary(from: newlyDropped)
            summary = mergeSummaries(summary, piece)
            throughID = head.last?.id ?? throughID
        } else if !head.isEmpty, summary == nil {
            // First compaction for this conversation
            summary = extractiveSummary(from: head)
            throughID = head.last?.id
        }

        if let s = summary, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary = nil
            throughID = nil
        } else if let s = summary, s.count > summaryCap {
            summary = String(s.suffix(summaryCap))
        }

        var assembled: [ChatMessage] = systems
        if let s = summary, !s.isEmpty {
            assembled.append(ChatMessage(
                role: .system,
                content: wrappedSummary(s)
            ))
        }
        assembled.append(contentsOf: tail)

        var dropped = head.count
        // A previous vision turn can consume the entire Kimi budget by itself.
        // It is optional context for a later text follow-up, while the text
        // dialogue is essential for resolving references. Remove old image
        // payloads before considering removal of any conversation turns.
        let latestUserID = dialogue.last(where: { $0.role == .user })?.id
        if estimatedChars(assembled) > budget {
            for i in assembled.indices {
                guard assembled[i].role == .user,
                      assembled[i].id != latestUserID,
                      assembled[i].hasImage else { continue }
                assembled[i].imageJPEGBase64 = nil
            }
        }

        // Pair-aware budget trim: drop oldest dialogue turns (never the last user turn).
        // Every removed turn is folded into the summary first. The UI retains
        // raw history, but the model must never receive a silent fresh-chat
        // request merely because a short thread contains a large image/reply.
        while estimatedChars(assembled) > budget, assembled.count > systems.count + (summary == nil ? 0 : 1) + 2 {
            let start = systems.count + (summary == nil ? 0 : 1)
            guard start < assembled.count - 1 else { break }
            var removed: [ChatMessage] = []
            // Prefer dropping a user+assistant pair
            if assembled[start].role == .user,
               start + 1 < assembled.count - 1,
               assembled[start + 1].role == .assistant {
                removed.append(assembled.remove(at: start))
                removed.append(assembled.remove(at: start))
                dropped += 2
            } else {
                removed.append(assembled.remove(at: start))
                dropped += 1
            }

            let folded = extractiveSummary(from: removed)
            if !folded.isEmpty {
                summary = mergeSummaries(summary, folded)
                let summaryMessage = ChatMessage(role: .system, content: wrappedSummary(summary!))
                if assembled.indices.contains(systems.count), assembled[systems.count].role == .system {
                    assembled[systems.count] = summaryMessage
                } else {
                    assembled.insert(summaryMessage, at: systems.count)
                }
            }
        }

        // If still over budget, shrink summary first, then truncate oldest remaining body.
        if estimatedChars(assembled) > budget, let rawSummary = summary {
            let overflow = estimatedChars(assembled) - budget
            let idx = systems.count
            if idx < assembled.count, assembled[idx].role == .system {
                var sys = assembled[idx]
                let keep = max(400, rawSummary.count - overflow - 80)
                if keep < rawSummary.count {
                    let shortened = "…\n" + String(rawSummary.suffix(keep))
                    sys.content = wrappedSummary(shortened)
                    assembled[idx] = sys
                    // Persist only the raw summary, never its system-message
                    // wrapper. Persisting the wrapper nested it on every build.
                    summary = shortened
                }
            }
        }

        if estimatedChars(assembled) > budget, var firstDialogue = oldestMutableDialogue(&assembled, afterSystems: systems.count) {
            let overflow = estimatedChars(assembled) - budget
            if firstDialogue.content.count > overflow + 120 {
                firstDialogue.content = "…\n" + String(firstDialogue.content.suffix(max(200, firstDialogue.content.count - overflow)))
                replaceOldestDialogue(&assembled, afterSystems: systems.count, with: firstDialogue)
            }
        }

        // Hard drop image if still huge (vision payloads dominate).
        if estimatedChars(assembled) > budget {
            for i in 0..<assembled.count {
                if assembled[i].hasImage, i < assembled.count - 1 {
                    assembled[i].imageJPEGBase64 = nil
                }
            }
        }

        let chars = estimatedChars(assembled)
        #if DEBUG
        print("[Connects] context build: msgs=\(assembled.count) chars≈\(chars) budget=\(budget) dropped=\(dropped) summary=\(summary != nil)")
        #endif

        return BuildResult(
            messages: assembled,
            summary: summary,
            summaryThroughMessageID: throughID,
            droppedCount: dropped,
            estimatedChars: chars,
            budget: budget
        )
    }

    // MARK: - Budgets

    /// Practical char budgets (≈ 2 chars/token). Leave headroom for `max_tokens` and avoid context rot.
    /// Model windows: DeepSeek V4 ≈ 1M, Kimi K3 ≈ 1M, Kimi K2.6 ≈ 256K — we intentionally stay far below.
    static func charBudget(for model: AIModelOption) -> Int {
        switch model.modelId {
        case AIModelOption.deepseekV4Flash.modelId:
            return 72_000
        case AIModelOption.deepseekV4Pro.modelId:
            return 100_000
        case AIModelOption.kimiK3.modelId:
            return 100_000
        case AIModelOption.kimi26.modelId:
            // Keep prefill small for lower time-to-first-token; older turns are
            // summarized and recent dialogue remains verbatim.
            return 32_000
        default:
            return 72_000
        }
    }

    // MARK: - Prune / cap

    /// Drop historical reasoning_content unless a provider explicitly requires it.
    private static func pruneReasoning(_ messages: [ChatMessage],
                                       thinkingOn: Bool,
                                       preserveAllReasoning: Bool) -> [ChatMessage] {
        if preserveAllReasoning {
            return messages
        }
        let lastAssistant = messages.lastIndex(where: { $0.role == .assistant })
        return messages.enumerated().map { i, msg in
            guard msg.role == .assistant, !msg.reasoningContent.isEmpty else { return msg }
            var m = msg
            if !thinkingOn || i != lastAssistant {
                m.reasoningContent = ""
            } else if m.reasoningContent.count > lastReasoningCap {
                m.reasoningContent = String(m.reasoningContent.suffix(lastReasoningCap))
            }
            return m
        }
    }

    /// Cap bodies outside the last two turns so one long reply cannot monopolize the window.
    private static func capMidContextBodies(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard messages.count > 4 else { return messages }
        let protectFrom = max(0, messages.count - 4)
        return messages.enumerated().map { i, msg in
            guard i < protectFrom, msg.content.count > midMessageCap else { return msg }
            var m = msg
            m.content = String(msg.content.prefix(midMessageCap)) + "\n…[truncated]"
            return m
        }
    }

    private static func recentVerbatimCount(in dialogue: [ChatMessage], turns: Int) -> Int {
        recentVerbatimMessageCount(in: dialogue, turns: turns)
    }

    /// Public for ContextCompactor.
    static func recentVerbatimMessageCount(in dialogue: [ChatMessage], turns: Int) -> Int {
        var count = 0
        var userTurns = 0
        for msg in dialogue.reversed() {
            count += 1
            if msg.role == .user {
                userTurns += 1
                if userTurns >= turns { break }
            }
        }
        return min(dialogue.count, max(count, min(4, dialogue.count)))
    }

    static func makeExtractiveSummary(from messages: [ChatMessage]) -> String {
        extractiveSummary(from: messages)
    }

    // MARK: - Summaries

    private static func extractiveSummary(from messages: [ChatMessage]) -> String {
        var lines: [String] = []
        for msg in messages {
            let text = msg.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
            guard !text.isEmpty || msg.hasImage else { continue }
            switch msg.role {
            case .user:
                let body = text.isEmpty && msg.hasImage ? "[image]" : String(text.prefix(160))
                lines.append("User: \(body)")
            case .assistant:
                guard !text.isEmpty else { continue }
                lines.append("Assistant: \(String(text.prefix(120)))")
            case .system:
                continue
            }
            if lines.joined(separator: "\n").count > summaryCap { break }
        }
        return lines.joined(separator: "\n")
    }

    private static func mergeSummaries(_ previous: String?, _ next: String) -> String {
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return previous ?? "" }
        guard let p = previous?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return n }
        let merged = p + "\n" + n
        if merged.count <= summaryCap { return merged }
        return String(merged.suffix(summaryCap))
    }

    private static func wrappedSummary(_ summary: String) -> String {
        """
        [Earlier conversation summary — compressed for context]
        Keep these facts/constraints in mind; recent turns below are verbatim.

        \(summary)
        """
    }

    // MARK: - Helpers

    static func estimatedChars(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { sum, m in
            var n = m.content.count + m.reasoningContent.count
            if let img = m.imageJPEGBase64 { n += min(img.count, 40_000) }
            return sum + n + 24
        }
    }

    private static func oldestMutableDialogue(_ assembled: inout [ChatMessage], afterSystems: Int) -> ChatMessage? {
        let start = afterSystems
        guard start < assembled.count else { return nil }
        // Skip injected summary system if present
        var i = start
        if i < assembled.count, assembled[i].role == .system { i += 1 }
        guard i < assembled.count - 1 else { return nil }
        return assembled[i]
    }

    private static func replaceOldestDialogue(_ assembled: inout [ChatMessage], afterSystems: Int, with msg: ChatMessage) {
        var i = afterSystems
        if i < assembled.count, assembled[i].role == .system { i += 1 }
        guard i < assembled.count else { return }
        assembled[i] = msg
    }
}
