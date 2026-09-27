import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

/// Live / finished phase for the collapsible web-search panel (UI only).
enum SearchProcessPhase: String, Codable {
    case idle
    case planning
    case searching
    case reading
    case done

    var headerTitle: String {
        switch self {
        case .idle: return "已联网检索"
        case .planning: return "规划搜索中…"
        case .searching: return "搜索中…"
        case .reading: return "阅读网页中…"
        case .done: return "已联网检索"
        }
    }
}

/// Local status for the background semantic extraction of an attached image.
enum ImageTranscriptionPhase: String, Codable {
    case idle
    case transcribing
    case done
    case failed

    var headerTitle: String {
        switch self {
        case .idle: return "图片转写"
        case .transcribing: return "图片转写中…"
        case .done: return "图片转写"
        case .failed: return "图片转写失败，可重试"
        }
    }
}

/// One completed (or in-progress) assistant reply attempt.
struct MessageVersion: Codable, Equatable {
    var content: String
    var reasoningContent: String
    var searchProcessContent: String
    var searchProcessPhase: SearchProcessPhase
    var createdAt: Date

    init(content: String = "",
         reasoningContent: String = "",
         searchProcessContent: String = "",
         searchProcessPhase: SearchProcessPhase = .idle,
         createdAt: Date = Date()) {
        self.content = content
        self.reasoningContent = reasoningContent
        self.searchProcessContent = searchProcessContent
        self.searchProcessPhase = searchProcessPhase
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case content, reasoningContent, searchProcessContent, searchProcessPhase, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent) ?? ""
        searchProcessContent = try c.decodeIfPresent(String.self, forKey: .searchProcessContent) ?? ""
        searchProcessPhase = try c.decodeIfPresent(SearchProcessPhase.self, forKey: .searchProcessPhase) ?? .idle
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct ChatMessage: Codable, Equatable {
    let id: String
    let role: MessageRole
    var content: String
    /// Kimi / thinking models stream this before the final reply.
    var reasoningContent: String
    /// Collapsible web-search process log (planning / queries / pages). Local UI only.
    var searchProcessContent: String
    var searchProcessPhase: SearchProcessPhase
    let createdAt: Date
    var isStreaming: Bool
    /// JPEG base64 for Kimi multimodal & local display
    var imageJPEGBase64: String?
    /// When true, keep `imageJPEGBase64` for API /「图片转写」but hide the chat thumbnail.
    var hidesAttachedImageInChat: Bool
    /// Prepended to this user turn when serializing for the API. Not shown in chat bubbles.
    var apiContextPrefix: String?
    /// Durable semantic replacement used after the original image leaves API context.
    var imageDescription: String?
    /// Companion assistant status for the non-blocking image transcription job.
    var imageTranscriptionContent: String
    var imageTranscriptionPhase: ImageTranscriptionPhase
    /// Workspace agent timeline (streaming / finished).
    var agentProcessSteps: [AgentProcessStep]
    var agentProcessPhase: AgentProcessPhase
    /// Wall-clock start for elapsed-time chrome (first tool round or first workspace send).
    var agentProcessStartedAt: Date?
    /// Completed tool rounds for API only — never appended as table rows.
    var agentToolTurns: [AgentToolTurn]
    /// Prose chunks committed between tool rounds (Cursor interleaved narrative).
    var agentProseSegments: [String]
    /// OpenCode-style ordered timeline (preferred paint source; no zip of steps×prose).
    var agentTimelineParts: [AgentTimelinePart]
    /// Inline edit cards shown under the root turn.
    var agentEditCards: [AgentEditCard]
    /// Tool-continuation / internal turns — kept for API, never shown as chat bubbles.
    var isHiddenInTranscript: Bool
    /// Assistant regenerations. Empty for legacy / single-shot messages.
    var versions: [MessageVersion]
    /// Index into `versions` when non-empty; mirrors `content` / `reasoningContent`.
    var versionIndex: Int

    init(id: String = UUID().uuidString,
         role: MessageRole,
         content: String,
         reasoningContent: String = "",
         searchProcessContent: String = "",
         searchProcessPhase: SearchProcessPhase = .idle,
         createdAt: Date = Date(),
         isStreaming: Bool = false,
         imageJPEGBase64: String? = nil,
         hidesAttachedImageInChat: Bool = false,
         apiContextPrefix: String? = nil,
         imageDescription: String? = nil,
         imageTranscriptionContent: String = "",
         imageTranscriptionPhase: ImageTranscriptionPhase = .idle,
         agentProcessSteps: [AgentProcessStep] = [],
         agentProcessPhase: AgentProcessPhase = .idle,
         agentProcessStartedAt: Date? = nil,
         agentToolTurns: [AgentToolTurn] = [],
         agentProseSegments: [String] = [],
         agentTimelineParts: [AgentTimelinePart] = [],
         agentEditCards: [AgentEditCard] = [],
         isHiddenInTranscript: Bool = false,
         versions: [MessageVersion] = [],
         versionIndex: Int = 0) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.searchProcessContent = searchProcessContent
        self.searchProcessPhase = searchProcessPhase
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.imageJPEGBase64 = imageJPEGBase64
        self.hidesAttachedImageInChat = hidesAttachedImageInChat
        self.apiContextPrefix = apiContextPrefix
        self.imageDescription = imageDescription
        self.imageTranscriptionContent = imageTranscriptionContent
        self.imageTranscriptionPhase = imageTranscriptionPhase
        self.agentProcessSteps = agentProcessSteps
        self.agentProcessPhase = agentProcessPhase
        self.agentProcessStartedAt = agentProcessStartedAt
        self.agentToolTurns = agentToolTurns
        self.agentProseSegments = agentProseSegments
        self.agentTimelineParts = agentTimelineParts
        self.agentEditCards = agentEditCards
        self.isHiddenInTranscript = isHiddenInTranscript
        self.versions = versions
        self.versionIndex = versionIndex
        if self.agentTimelineParts.isEmpty {
            rebuildTimelinePartsFromLegacySources()
        }
    }

    var apiRole: String { role.rawValue }

    var hasImage: Bool { imageJPEGBase64 != nil && !(imageJPEGBase64?.isEmpty ?? true) }

    /// Whether the chat bubble should render the attached JPEG thumbnail.
    var showsImageInChat: Bool { hasImage && !hidesAttachedImageInChat }

    var hasReasoning: Bool {
        !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasSearchProcess: Bool {
        !searchProcessContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (searchProcessPhase != .idle && searchProcessPhase != .done)
    }

    /// Header for search chrome — done state mirrors Cursor aggregate density.
    var searchProcessSummaryTitle: String {
        switch searchProcessPhase {
        case .planning, .searching, .reading:
            return searchProcessPhase.headerTitle
        case .idle, .done:
            let body = searchProcessContent
            let hitCount: Int = {
                guard let r = body.range(of: #"找到\s+(\d+)\s*条"#, options: .regularExpression) else {
                    return body.components(separatedBy: "\n")
                        .filter { $0.contains("http://") || $0.contains("https://") }
                        .count
                }
                let digits = body[r].filter(\.isNumber)
                return Int(String(digits)) ?? 0
            }()
            let pageCount = body.components(separatedBy: "已阅读网页：").count > 1
                ? max(0, body.components(separatedBy: "\n")
                    .filter { $0.hasPrefix("· ") }.count)
                : 0
            var parts = ["已联网检索"]
            if hitCount > 0 { parts.append("\(hitCount) 条") }
            if pageCount > 0 { parts.append("阅读 \(pageCount) 页") }
            return parts.joined(separator: " · ")
        }
    }

    var hasImageTranscription: Bool { false }

    var hasAgentProcess: Bool {
        if !agentProcessSteps.isEmpty || !agentTimelineParts.isEmpty { return true }
        if !agentToolTurns.isEmpty || !agentProseSegments.isEmpty || !agentEditCards.isEmpty {
            return true
        }
        switch agentProcessPhase {
        case .waitingUser: return true
        case .running:
            // Avoid bulky empty chrome before the first step or timer is seeded.
            return agentProcessStartedAt != nil
        case .done:
            return !agentProcessSteps.isEmpty
                || !agentProseSegments.isEmpty
                || !agentTimelineParts.isEmpty
                || !agentEditCards.isEmpty
        case .idle:
            return false
        }
    }

    /// Visible bubble body for agent turns: prior prose segments + current stream text.
    var agentTimelineBody: String {
        let prior = agentProseSegments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let current = chatDisplayBodyCurrentRound
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if prior.isEmpty { return current }
        if current.isEmpty { return prior.joined(separator: "\n\n") }
        return (prior + [current]).joined(separator: "\n\n")
    }

    /// Current-round body only (no prior prose segments).
    /// Strips complete + open machine blocks so stream paint never shows `<<<`.
    var chatDisplayBodyCurrentRound: String {
        guard role == .assistant else { return content }
        let strippedEdit = CodeEditApplyTools.chatVisibleContent(for: id, raw: content)
        return AgentTools.strippingToolBlocksForDisplay(from: strippedEdit)
    }

    /// Cursor-ordered timeline for chrome / cell (steps + planning + edit headers).
    var agentTimelineSegments: [AgentTimelineSegment] {
        var segs: [AgentTimelineSegment] = []
        for step in agentProcessSteps {
            let line = step.cursorTimelineLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let kind: AgentTimelineSegmentKind
            switch step.kind {
            case .thought: kind = .thought
            case .planned: kind = .planning
            case .edited, .created: kind = .editCard
            case .deleted: kind = .step
            default: kind = .step
            }
            segs.append(AgentTimelineSegment(id: step.id, kind: kind, text: line))
        }
        for card in agentEditCards {
            segs.append(AgentTimelineSegment(
                id: card.id,
                kind: .editCard,
                text: card.headerLine,
                editCard: card
            ))
        }
        return segs
    }

    /// Cursor Explored header: "Explored N files, M searches".
    var agentExploreGroupTitle: String {
        let reads = agentProcessSteps.filter { $0.kind == .read }.count
        let lists = agentProcessSteps.filter {
            $0.kind == .exploring || $0.kind == .subagent
        }.count
        let files = reads + lists
        let searches = agentProcessSteps.filter { $0.kind == .grepped }.count
        var parts: [String] = []
        if files > 0 {
            parts.append(files == 1 ? "Explored 1 file" : "Explored \(files) files")
        }
        if searches > 0 {
            parts.append(searches == 1 ? "1 search" : "\(searches) searches")
        }
        if parts.isEmpty {
            let thoughts = timelinePartsForPaint().filter {
                $0.stepKind == .thought || $0.isExpandableThought || $0.kind == .thinking
            }.count
            let extras = agentProcessSteps.contains {
                $0.kind == .deleted || $0.kind == .planned
            }
            if thoughts > 0 || extras { return "Explored" }
            return ""
        }
        return parts.joined(separator: ", ")
    }

    /// OpenCode/Cursor paint: walk parts in storage order.
    /// Consecutive explore meta → one Explored group; prose/ask inserted in place.
    /// - `defaultExploreExpanded`: used when a group has no user override (running→true, done→false)
    /// - `exploreExpandOverrides`: per-header latch so expanding one group does not open all
    func agentTimelinePaintItems(
        liveOverlay: String? = nil,
        defaultExploreExpanded: Bool,
        exploreExpandOverrides: [String: Bool] = [:]
    ) -> [AgentTimelinePaintItem] {
        let parts = timelinePartsForPaint()
        let hasEditCards = !agentEditCards.isEmpty
        let running = isStreaming || agentProcessPhase == .running
        let phaseDone = agentProcessPhase == .done || agentProcessPhase == .waitingUser

        func isGroupExpanded(_ headerID: String) -> Bool {
            exploreExpandOverrides[headerID] ?? defaultExploreExpanded
        }

        var overlay = (liveOverlay ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for g in ["◐", "◓", "◑", "◒"] {
            overlay = overlay.replacingOccurrences(of: "  \(g)", with: "")
            overlay = overlay.replacingOccurrences(of: g, with: "")
        }
        overlay = overlay.trimmingCharacters(in: .whitespacesAndNewlines)

        var items: [AgentTimelinePaintItem] = []
        var exploreChildren: [AgentTimelinePaintItem] = []
        var exploreGroupIndex = 0
        var sawExploreGroup = false
        var askRows: [AgentTimelinePaintItem] = []

        var lastMetaLine: String?
        var lastMetaKind: AgentStepKind?
        var coalesceCount = 1
        var pending: (id: String, line: String, kind: AgentStepKind?, detail: String)?
        var pendingPlanned: (id: String, line: String)?
        var plannedCoalesce = 1

        func flushPendingChild() {
            guard let p = pending else { return }
            var text = coalesceCount > 1 ? "\(p.line) · ×\(coalesceCount)" : p.line
            if p.kind == .edited || p.kind == .created {
                text = Self.localizedEditTimelineLine(text)
            }
            if AgentTimelinePart.isExploreChild(stepKind: p.kind) {
                let shimmer = running && (p.kind == .edited || p.kind == .created)
                exploreChildren.append(AgentTimelinePaintItem(
                    id: p.id,
                    role: .exploreChild,
                    text: text,
                    detail: coalesceCount > 1 ? "" : p.detail,
                    stepKind: p.kind,
                    shimmer: shimmer,
                    indented: true
                ))
            }
            pending = nil
            coalesceCount = 1
        }

        func flushPlannedChild() {
            guard let p = pendingPlanned else { return }
            let text = plannedCoalesce > 1 ? "\(p.line) · ×\(plannedCoalesce)" : p.line
            exploreChildren.append(AgentTimelinePaintItem(
                id: p.id,
                role: .exploreChild,
                text: text,
                stepKind: .planned,
                indented: true
            ))
            pendingPlanned = nil
            plannedCoalesce = 1
        }

        func flushExploreGroup() {
            flushPendingChild()
            flushPlannedChild()
            lastMetaLine = nil
            lastMetaKind = nil
            guard !exploreChildren.isEmpty else { return }
            sawExploreGroup = true
            exploreGroupIndex += 1
            let headerID = exploreGroupIndex == 1
                ? AgentTimelinePart.exploreHeaderID
                : "\(AgentTimelinePart.exploreHeaderID)-\(exploreGroupIndex)"
            let expanded = isGroupExpanded(headerID)
            let title: String = {
                if exploreGroupIndex == 1 {
                    let t = agentExploreGroupTitle
                    return t.isEmpty ? "Explored" : t
                }
                return "Explored"
            }()
            let chevron = expanded ? " ⌵" : " ›"
            items.append(AgentTimelinePaintItem(
                id: headerID,
                role: .exploreHeader,
                text: title + chevron
            ))
            if expanded {
                items.append(contentsOf: exploreChildren)
            }
            exploreChildren = []
        }

        if agentProcessPhase == .waitingUser {
            // Ask rows collected below; waiting placeholder if none.
        }

        for part in parts {
            if part.id == AgentTimelinePart.liveID { continue }
            if hasEditCards, part.kind == .meta,
               part.stepKind == .edited || part.stepKind == .created {
                continue
            }
            switch part.kind {
            case .thinking:
                flushPendingChild()
                flushPlannedChild()
                lastMetaLine = nil
                lastMetaKind = nil
                let t = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                exploreChildren.append(AgentTimelinePaintItem(
                    id: part.id,
                    role: .exploreChild,
                    text: t,
                    detail: part.detail,
                    stepKind: part.stepKind ?? .thought,
                    indented: true
                ))
            case .meta:
                let line = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                if part.stepKind == .thought || part.isExpandableThought {
                    flushPendingChild()
                    flushPlannedChild()
                    lastMetaLine = nil
                    lastMetaKind = nil
                    exploreChildren.append(AgentTimelinePaintItem(
                        id: part.id,
                        role: .exploreChild,
                        text: line,
                        detail: part.detail,
                        stepKind: .thought,
                        indented: true
                    ))
                    continue
                }
                if part.stepKind == .asked { continue }
                if part.stepKind == .planned {
                    flushPendingChild()
                    lastMetaLine = nil
                    lastMetaKind = nil
                    if let last = pendingPlanned, last.line == line {
                        plannedCoalesce += 1
                        pendingPlanned = (part.id, line)
                    } else {
                        flushPlannedChild()
                        pendingPlanned = (part.id, line)
                        plannedCoalesce = 1
                    }
                    continue
                }
                if !AgentTimelinePart.isExploreChild(stepKind: part.stepKind) {
                    flushPendingChild()
                    flushPlannedChild()
                    lastMetaLine = nil
                    lastMetaKind = nil
                    continue
                }
                flushPlannedChild()
                if let last = lastMetaLine,
                   last == line || (part.stepKind == .read && lastMetaKind == .read) {
                    coalesceCount += 1
                    pending = (part.id, line, part.stepKind, "")
                    lastMetaLine = line
                    lastMetaKind = part.stepKind
                } else {
                    flushPendingChild()
                    pending = (part.id, line, part.stepKind, part.detail)
                    lastMetaLine = line
                    lastMetaKind = part.stepKind
                    coalesceCount = 1
                }
            case .prose:
                flushExploreGroup()
                let t = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                items.append(AgentTimelinePaintItem(id: part.id, role: .prose, text: t))
            case .ask:
                flushExploreGroup()
                let t = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                let row = AgentTimelinePaintItem(id: part.id, role: .ask, text: t)
                askRows.append(row)
                items.append(row)
            }
        }
        flushExploreGroup()

        // Done turn with explore title but no children left after cards filter —
        // keep a collapsed header when title exists.
        if !running, !sawExploreGroup, !agentExploreGroupTitle.isEmpty {
            let headerID = AgentTimelinePart.exploreHeaderID
            let expanded = isGroupExpanded(headerID)
            items.insert(
                AgentTimelinePaintItem(
                    id: headerID,
                    role: .exploreHeader,
                    text: agentExploreGroupTitle + (expanded ? " ⌵" : " ›")
                ),
                at: 0
            )
            sawExploreGroup = true
        }

        if agentProcessPhase == .waitingUser, askRows.isEmpty {
            items.insert(
                AgentTimelinePaintItem(
                    id: "waiting",
                    role: .planned,
                    text: AgentProcessPhase.waitingUser.headerTitle
                ),
                at: 0
            )
        }

        // Live Thinking / Planning — no Exploring… dual header.
        if running {
            let stepRunning = agentProcessSteps.contains { $0.status == .running }
            if !stepRunning {
                if !overlay.isEmpty {
                    items.append(AgentTimelinePaintItem(
                        id: AgentTimelinePart.liveID,
                        role: .live,
                        text: overlay,
                        shimmer: true
                    ))
                } else if !sawExploreGroup {
                    let hasReasoning = !reasoningContent
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    items.append(AgentTimelinePaintItem(
                        id: AgentTimelinePart.liveID,
                        role: .live,
                        text: hasReasoning
                            ? AgentProcessPhase.thinkingText
                            : AgentProcessPhase.planningNextMovesText,
                        shimmer: true
                    ))
                } else if !isStreaming {
                    // Inter-round gap after tools (waiting for next stream): Planning below Explored.
                    items.append(AgentTimelinePaintItem(
                        id: AgentTimelinePart.liveID,
                        role: .live,
                        text: AgentProcessPhase.planningNextMovesText,
                        shimmer: true
                    ))
                }
            }
        }

        // Final-answer "current" prose only after the turn settles (OpenCode: answer once at end).
        let holdCurrentProse = !phaseDone && running
        if !holdCurrentProse {
            let current = chatDisplayBodyCurrentRound
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !current.isEmpty {
                let existingProse = items.compactMap { item -> String? in
                    item.role == .prose || item.role == .ask ? item.text : nil
                }
                let isDup = existingProse.contains { seg in
                    if seg == current { return true }
                    let a = seg.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    let b = current.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    return a == b
                }
                if !isDup {
                    // Near-dup against long prior prose.
                    let nearDup = existingProse.contains { seg in
                        let a = seg.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        let b = current.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        guard a.count > 48, b.count > 48 else { return false }
                        return a.contains(b) || b.contains(a)
                    }
                    if !nearDup {
                        items.append(AgentTimelinePaintItem(id: "current", role: .prose, text: current))
                    }
                }
            }
        }

        // Deduplicate adjacent identical prose blocks (model repeats).
        var deduped: [AgentTimelinePaintItem] = []
        for item in items {
            if item.role == .prose, let last = deduped.last, last.role == .prose {
                let a = last.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                let b = item.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                if a == b { continue }
                if a.count > 48, b.count > 48, a.contains(b) || b.contains(a) { continue }
            }
            deduped.append(item)
        }
        items = deduped

        for card in agentEditCards.suffix(4) {
            items.append(AgentTimelinePaintItem(
                id: "card-\(card.id)",
                role: .card,
                text: card.headerLine,
                detail: card.id
            ))
        }
        return items
    }

    /// Flat blocks for QA / attributed fallback (explore expanded).
    func agentInterleavedBlocks(liveOverlay: String? = nil) -> [(id: String, isMeta: Bool, text: String, detail: String)] {
        agentTimelinePaintItems(liveOverlay: liveOverlay, defaultExploreExpanded: true).map { item in
            let isMeta: Bool = {
                switch item.role {
                case .prose, .ask, .card: return false
                default: return true
                }
            }()
            return (item.id, isMeta, item.text, item.detail)
        }
    }

    // MARK: - Timeline parts (OpenCode-ordered)

    /// Upsert meta row for a tool step (same id → update text in place).
    mutating func upsertMetaPart(from step: AgentProcessStep) {
        if step.kind != .thought {
            sealThoughtFromReasoningIfNeeded()
        }
        let id = AgentTimelinePart.metaID(stepID: step.id)
        let text = step.cursorTimelineLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let i = agentTimelineParts.firstIndex(where: { $0.id == id }) {
            agentTimelineParts[i].text = text
            agentTimelineParts[i].stepKind = step.kind
            agentTimelineParts[i].kind = .meta
        } else {
            agentTimelineParts.append(AgentTimelinePart(id: id, kind: .meta, text: text, stepKind: step.kind))
        }
        // Drop live thinking when real meta arrives.
        agentTimelineParts.removeAll { $0.id == AgentTimelinePart.liveID }
    }

    mutating func appendProsePart(_ text: String) {
        _ = sealThoughtFromReasoningIfNeeded()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if agentTimelineParts.last?.kind == .prose, agentTimelineParts.last?.text == t { return }
        agentProseSegments.append(t)
        agentTimelineParts.append(AgentTimelinePart(id: "prose-\(UUID().uuidString)", kind: .prose, text: t))
        agentTimelineParts.removeAll { $0.id == AgentTimelinePart.liveID }
    }

    mutating func appendAskPart(_ prompt: String) {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Replace prior ask if any (one pending question).
        agentTimelineParts.removeAll { $0.kind == .ask }
        agentTimelineParts.append(AgentTimelinePart(id: "ask-\(UUID().uuidString)", kind: .ask, text: t))
        agentTimelineParts.removeAll { $0.id == AgentTimelinePart.liveID }
    }

    // Live Thinking is paint-overlay only (stream UI); not persisted as a timeline part.

    /// Multiple Thoughts allowed (one per reasoning segment between tools).
    @discardableResult
    mutating func sealThoughtFromReasoningIfNeeded(finishedAt: Date = Date()) -> Bool {
        let reason = reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return false }
        if let last = agentTimelineParts.last(where: {
            $0.stepKind == .thought || $0.isExpandableThought || $0.id.hasPrefix("thought")
        }), last.detail == reason {
            agentTimelineParts.removeAll { $0.id == AgentTimelinePart.liveID }
            return false
        }
        let started = agentProcessStartedAt ?? finishedAt.addingTimeInterval(-1)
        // Prefer duration since last sealed thought / last tool meta.
        let lastAnchor = agentTimelineParts.last(where: {
            $0.stepKind == .thought || AgentTimelinePart.isExploreChild(stepKind: $0.stepKind)
        })
        let thoughtStart: Date = {
            if let last = agentProcessSteps.last(where: { $0.kind == .thought })?.finishedAt {
                return last
            }
            if lastAnchor != nil, let toolStart = agentProcessSteps.last?.finishedAt {
                return toolStart
            }
            return started
        }()
        var step = AgentProcessStep(
            id: UUID().uuidString,
            kind: .thought,
            title: "Thinking",
            detail: reason,
            status: .done,
            startedAt: thoughtStart,
            finishedAt: finishedAt
        )
        step.markDone(at: finishedAt)
        agentProcessSteps.append(step)
        let part = AgentTimelinePart(
            id: "thought-\(step.id)",
            kind: .thinking,
            text: step.cursorTimelineLine,
            stepKind: .thought,
            detail: reason
        )
        agentTimelineParts.removeAll { $0.id == AgentTimelinePart.liveID }
        agentTimelineParts.append(part)
        // Clear so the next Thinking round becomes a separate Thought.
        reasoningContent = ""
        return true
    }

    /// Non-mutating paint source: stored parts, or legacy steps→prose (never zip).
    func timelinePartsForPaint() -> [AgentTimelinePart] {
        if !agentTimelineParts.isEmpty { return agentTimelineParts }
        return Self.buildTimelinePartsFromLegacy(
            steps: agentProcessSteps,
            prose: agentProseSegments,
            editCards: agentEditCards
        )
    }

    mutating func ensureTimelinePartsPopulated() {
        if agentTimelineParts.isEmpty {
            rebuildTimelinePartsFromLegacySources()
        }
    }

    /// Legacy: steps then prose (stable order — never zip alternate).
    mutating func rebuildTimelinePartsFromLegacySources() {
        agentTimelineParts = Self.buildTimelinePartsFromLegacy(
            steps: agentProcessSteps,
            prose: agentProseSegments,
            editCards: agentEditCards
        )
    }

    private static func buildTimelinePartsFromLegacy(
        steps: [AgentProcessStep],
        prose: [String],
        editCards: [AgentEditCard]
    ) -> [AgentTimelinePart] {
        var parts: [AgentTimelinePart] = []
        let hasEditCards = !editCards.isEmpty
        for step in steps {
            if hasEditCards, step.kind == .edited || step.kind == .created { continue }
            let line = step.cursorTimelineLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            parts.append(AgentTimelinePart(
                id: AgentTimelinePart.metaID(stepID: step.id),
                kind: .meta,
                text: line,
                stepKind: step.kind
            ))
        }
        for (i, seg) in prose.enumerated() {
            let t = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            parts.append(AgentTimelinePart(id: "prose-legacy-\(i)", kind: .prose, text: t))
        }
        return parts
    }

    func agentInterleavedAttributedText(
        bodyFont: UIFont,
        metaFont: UIFont,
        primary: UIColor,
        secondary: UIColor,
        liveOverlay: String? = nil
    ) -> NSAttributedString {
        let blocks = agentInterleavedBlocks(liveOverlay: liveOverlay)
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.paragraphSpacing = 6
        for (i, block) in blocks.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: block.isMeta ? metaFont : bodyFont,
                .foregroundColor: block.isMeta ? secondary : primary,
                .paragraphStyle: para
            ]
            out.append(NSAttributedString(string: block.text, attributes: attrs))
        }
        return out
    }

    /// Expand completed tool rounds into API transcript pairs (no table rows).
    static func messagesWithExpandedAgentToolTurns(_ messages: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        out.reserveCapacity(messages.count)
        for msg in messages {
            guard msg.role == .assistant, !msg.agentToolTurns.isEmpty else {
                out.append(msg)
                continue
            }
            for turn in msg.agentToolTurns {
                out.append(ChatMessage(
                    role: .assistant,
                    content: turn.assistantContent,
                    reasoningContent: turn.assistantReasoning,
                    isHiddenInTranscript: true
                ))
                out.append(ChatMessage(
                    role: .user,
                    content: "",
                    apiContextPrefix: turn.toolResults,
                    isHiddenInTranscript: true
                ))
            }
            var live = msg
            live.agentToolTurns = []
            out.append(live)
        }
        return out
    }

    /// Search / transcription / workspace-agent chrome share one process panel.
    var showsProcessChrome: Bool {
        hasSearchProcess || hasImageTranscription || hasAgentProcess
    }

    var agentProcessDisplayText: String {
        agentProcessSteps.map(\.cursorTimelineLine)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func agentProcessElapsedLabel(until end: Date = Date()) -> String? {
        guard let started = agentProcessStartedAt else { return nil }
        let sec = max(0, Int(end.timeIntervalSince(started)))
        if sec < 60 { return "\(sec)s" }
        return "\(sec / 60)m \(sec % 60)s"
    }

    private var agentProcessExploreCount: Int {
        agentProcessSteps.filter {
            $0.kind == .exploring || $0.kind == .subagent || $0.kind == .created
        }.count
    }

    private var agentProcessSearchCount: Int {
        agentProcessSteps.filter { $0.kind == .grepped }.count
    }

    /// Cursor collapsed summary under a turn: "Explored 2 files, 1 search".
    var agentProcessCursorAggregateSummary: String {
        let title = agentExploreGroupTitle
        let edits = agentProcessSteps.filter { $0.kind == .edited }.count
        var parts: [String] = []
        if !title.isEmpty { parts.append(title) }
        if edits > 0 {
            parts.append(edits == 1 ? "1 edit" : "\(edits) edits")
        }
        return parts.joined(separator: ", ")
    }

    var agentProcessSummaryTitle: String {
        switch agentProcessPhase {
        case .idle: return "工作流"
        case .waitingUser: return AgentProcessPhase.waitingUser.headerTitle
        case .running:
            // Cursor-style: elapsed / "Worked for Xs" only after completion.
            // Live progress lives in the 3-line process preview (thought / explored / …).
            return "工作中"
        case .done:
            var parts: [String] = []
            if let elapsed = agentProcessElapsedLabel() {
                parts.append("已工作 \(elapsed)")
            }
            let aggregate = agentProcessCursorAggregateSummary
            if !aggregate.isEmpty {
                parts.append(aggregate)
            }
            if parts.isEmpty { return "已完成" }
            return parts.joined(separator: " · ")
        }
    }

    /// Hide tool-continuation / internal turns from the chat transcript UI.
    var shouldHideInTranscript: Bool {
        if isHiddenInTranscript { return true }
        guard role == .user else { return false }
        let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = apiContextPrefix ?? ""
        let hasToolPrefix = prefix.contains("## TOOL_RESULTS") || prefix.contains("TOOL_RESULTS")
        if hasToolPrefix {
            if c.isEmpty || c == "继续" || c.contains("工具结果") || c.contains("TOOL_RESULTS") {
                return true
            }
        }
        if c.contains("TOOL_RESULTS") || c.contains("工具结果") { return true }
        return false
    }

    func imageTranscriptionDisplayText(pairedUser: ChatMessage?) -> String {
        ImageDurableText.displayBody(
            assistantText: imageTranscriptionContent,
            userDescription: pairedUser?.imageDescription
        )
    }

    var versionCount: Int {
        max(versions.count, (content.isEmpty && reasoningContent.isEmpty && !isStreaming) ? 0 : 1)
    }

    var showsVersionPager: Bool {
        role == .assistant && !isStreaming && versions.count > 1
    }

    var versionPagerText: String {
        guard versions.count > 1 else { return "" }
        let i = min(max(0, versionIndex), versions.count - 1) + 1
        return "\(i)/\(versions.count)"
    }

    /// Text suitable for clipboard.
    var copyableText: String {
        var parts: [String] = []
        let search = searchProcessContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let think = reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            parts.append("【联网检索】\n\(search)")
        }
        if !think.isEmpty {
            parts.append("【思考】\n\(think)")
        }
        if !body.isEmpty {
            parts.append(body)
        } else if hasImage {
            parts.append("[图片]")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Persist current fields into `versions[versionIndex]`.
    mutating func commitActiveVersion() {
        guard role == .assistant else { return }
        let snap = MessageVersion(
            content: content,
            reasoningContent: reasoningContent,
            searchProcessContent: searchProcessContent,
            searchProcessPhase: searchProcessPhase == .idle ? .idle : .done,
            createdAt: versions.indices.contains(versionIndex) ? versions[versionIndex].createdAt : createdAt
        )
        if versions.isEmpty {
            versions = [snap]
            versionIndex = 0
        } else if versions.indices.contains(versionIndex) {
            versions[versionIndex] = snap
        } else {
            versions.append(snap)
            versionIndex = versions.count - 1
        }
    }

    /// Archive current reply and open a fresh empty version for streaming.
    mutating func beginNewVersion() {
        guard role == .assistant else { return }
        if versions.isEmpty {
            if !content.isEmpty || !reasoningContent.isEmpty || !searchProcessContent.isEmpty {
                versions = [
                    MessageVersion(
                        content: content,
                        reasoningContent: reasoningContent,
                        searchProcessContent: searchProcessContent,
                        searchProcessPhase: searchProcessPhase == .idle ? .idle : .done,
                        createdAt: createdAt
                    )
                ]
            }
        } else if versions.indices.contains(versionIndex) {
            versions[versionIndex].content = content
            versions[versionIndex].reasoningContent = reasoningContent
            versions[versionIndex].searchProcessContent = searchProcessContent
            versions[versionIndex].searchProcessPhase = searchProcessPhase == .idle ? .idle : .done
        }
        versions.append(MessageVersion(content: "", reasoningContent: "", createdAt: Date()))
        versionIndex = versions.count - 1
        content = ""
        reasoningContent = ""
        searchProcessContent = ""
        searchProcessPhase = .idle
        isStreaming = true
    }

    /// Switch visible reply version. Returns false if unchanged / invalid.
    @discardableResult
    mutating func selectVersion(at index: Int) -> Bool {
        guard role == .assistant, versions.count > 1, versions.indices.contains(index) else { return false }
        if versions.indices.contains(versionIndex) {
            versions[versionIndex].content = content
            versions[versionIndex].reasoningContent = reasoningContent
            versions[versionIndex].searchProcessContent = searchProcessContent
            versions[versionIndex].searchProcessPhase = searchProcessPhase == .idle ? .idle : .done
        }
        versionIndex = index
        content = versions[index].content
        reasoningContent = versions[index].reasoningContent
        searchProcessContent = versions[index].searchProcessContent
        searchProcessPhase = versions[index].searchProcessPhase
        return true
    }

    @discardableResult
    mutating func shiftVersion(by delta: Int) -> Bool {
        guard versions.count > 1 else { return false }
        let next = min(max(0, versionIndex + delta), versions.count - 1)
        return selectVersion(at: next)
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningContent, searchProcessContent, searchProcessPhase
        case createdAt, isStreaming, imageJPEGBase64, hidesAttachedImageInChat
        case apiContextPrefix, imageDescription
        case imageTranscriptionContent, imageTranscriptionPhase
        case agentProcessSteps, agentProcessPhase, agentProcessStartedAt
        case agentToolTurns, agentProseSegments, agentTimelineParts, agentEditCards, isHiddenInTranscript
        case versions, versionIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(MessageRole.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent) ?? ""
        searchProcessContent = try c.decodeIfPresent(String.self, forKey: .searchProcessContent) ?? ""
        searchProcessPhase = try c.decodeIfPresent(SearchProcessPhase.self, forKey: .searchProcessPhase) ?? .idle
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isStreaming = try c.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        imageJPEGBase64 = try c.decodeIfPresent(String.self, forKey: .imageJPEGBase64)
        hidesAttachedImageInChat = try c.decodeIfPresent(Bool.self, forKey: .hidesAttachedImageInChat) ?? false
        apiContextPrefix = try c.decodeIfPresent(String.self, forKey: .apiContextPrefix)
        imageDescription = try c.decodeIfPresent(String.self, forKey: .imageDescription)
        imageTranscriptionContent = try c.decodeIfPresent(String.self, forKey: .imageTranscriptionContent) ?? ""
        imageTranscriptionPhase = try c.decodeIfPresent(ImageTranscriptionPhase.self, forKey: .imageTranscriptionPhase) ?? .idle
        agentProcessSteps = try c.decodeIfPresent([AgentProcessStep].self, forKey: .agentProcessSteps) ?? []
        agentProcessPhase = try c.decodeIfPresent(AgentProcessPhase.self, forKey: .agentProcessPhase) ?? .idle
        agentProcessStartedAt = try c.decodeIfPresent(Date.self, forKey: .agentProcessStartedAt)
        agentToolTurns = try c.decodeIfPresent([AgentToolTurn].self, forKey: .agentToolTurns) ?? []
        agentProseSegments = try c.decodeIfPresent([String].self, forKey: .agentProseSegments) ?? []
        agentTimelineParts = try c.decodeIfPresent([AgentTimelinePart].self, forKey: .agentTimelineParts) ?? []
        agentEditCards = try c.decodeIfPresent([AgentEditCard].self, forKey: .agentEditCards) ?? []
        isHiddenInTranscript = try c.decodeIfPresent(Bool.self, forKey: .isHiddenInTranscript) ?? false
        versions = try c.decodeIfPresent([MessageVersion].self, forKey: .versions) ?? []
        versionIndex = try c.decodeIfPresent(Int.self, forKey: .versionIndex) ?? 0
        if agentTimelineParts.isEmpty {
            rebuildTimelinePartsFromLegacySources()
        }
        if !versions.isEmpty {
            versionIndex = min(max(0, versionIndex), versions.count - 1)
            // Prefer a version that actually has body text if the selected slot is empty
            // (e.g. app killed mid-regeneration).
            if versions[versionIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let better = versions.lastIndex(where: {
                   !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               }) {
                versionIndex = better
            }
            let v = versions[versionIndex]
            if content.isEmpty, !v.content.isEmpty { content = v.content }
            if reasoningContent.isEmpty, !v.reasoningContent.isEmpty {
                reasoningContent = v.reasoningContent
            }
            if searchProcessContent.isEmpty, !v.searchProcessContent.isEmpty {
                searchProcessContent = v.searchProcessContent
            }
            if searchProcessPhase == .idle, v.searchProcessPhase != .idle {
                searchProcessPhase = v.searchProcessPhase
            }
        }
        // Legacy tool-continuation bubbles → treat as hidden.
        if !isHiddenInTranscript, shouldHideInTranscript {
            isHiddenInTranscript = true
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(reasoningContent, forKey: .reasoningContent)
        if !searchProcessContent.isEmpty || searchProcessPhase != .idle {
            try c.encode(searchProcessContent, forKey: .searchProcessContent)
            try c.encode(searchProcessPhase, forKey: .searchProcessPhase)
        }
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(isStreaming, forKey: .isStreaming)
        try c.encodeIfPresent(imageJPEGBase64, forKey: .imageJPEGBase64)
        if hidesAttachedImageInChat {
            try c.encode(true, forKey: .hidesAttachedImageInChat)
        }
        try c.encodeIfPresent(apiContextPrefix, forKey: .apiContextPrefix)
        try c.encodeIfPresent(imageDescription, forKey: .imageDescription)
        if !imageTranscriptionContent.isEmpty || imageTranscriptionPhase != .idle {
            try c.encode(imageTranscriptionContent, forKey: .imageTranscriptionContent)
            try c.encode(imageTranscriptionPhase, forKey: .imageTranscriptionPhase)
        }
        if !agentProcessSteps.isEmpty || agentProcessPhase != .idle
            || !agentToolTurns.isEmpty || !agentProseSegments.isEmpty
            || !agentTimelineParts.isEmpty || !agentEditCards.isEmpty {
            try c.encode(agentProcessSteps, forKey: .agentProcessSteps)
            try c.encode(agentProcessPhase, forKey: .agentProcessPhase)
            try c.encodeIfPresent(agentProcessStartedAt, forKey: .agentProcessStartedAt)
        }
        if !agentToolTurns.isEmpty {
            try c.encode(agentToolTurns, forKey: .agentToolTurns)
        }
        if !agentProseSegments.isEmpty {
            try c.encode(agentProseSegments, forKey: .agentProseSegments)
        }
        if !agentTimelineParts.isEmpty {
            try c.encode(agentTimelineParts, forKey: .agentTimelineParts)
        }
        if !agentEditCards.isEmpty {
            try c.encode(agentEditCards, forKey: .agentEditCards)
        }
        if isHiddenInTranscript {
            try c.encode(true, forKey: .isHiddenInTranscript)
        }
        if !versions.isEmpty {
            try c.encode(versions, forKey: .versions)
            try c.encode(versionIndex, forKey: .versionIndex)
        }
    }

    /// Bubble / layout body: strips CONNECTS_EDIT / CONNECTS_TOOL machine blocks (assistant only).
    /// Agent turns include prior prose segments so mid-loop narrative is not lost.
    var chatDisplayBody: String {
        guard role == .assistant else { return content }
        if hasAgentProcess || !agentProseSegments.isEmpty || !agentToolTurns.isEmpty {
            return agentTimelineBody
        }
        return chatDisplayBodyCurrentRound
    }

    /// Timeline label for edit/create steps (matches thinking-tag thickness chrome).
    static func localizedEditTimelineLine(_ line: String) -> String {
        if line.hasPrefix("Editing ") {
            return "正在编辑 " + line.dropFirst("Editing ".count)
        }
        if line.hasPrefix("Creating ") {
            return "正在创建 " + line.dropFirst("Creating ".count)
        }
        if line == "Editing…" || line == "Editing..." {
            return "正在编辑…"
        }
        return line
    }
}
