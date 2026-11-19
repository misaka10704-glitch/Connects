import Foundation

enum StudySessionKind: String, Codable, Equatable {
    /// One document bound; no workspace agent workflow.
    case document
    /// Real folder workspace + agent orchestration.
    case workspace
}

enum StudyAgentMode: String, Codable, Equatable {
    case agent
    case plan
    case ask

    /// Product gate: keep Agent (and Plan/Ask chip) off until Study folder UX is solid.
    /// Folder Study uses the same capture / AI-edit path as single-document Study.
    static var isAgentProductEnabled: Bool { false }

    /// Modes shown on the input-bar chip when Agent product is unlocked.
    static var selectableModes: [StudyAgentMode] {
        guard isAgentProductEnabled else { return [] }
        return [.agent, .plan, .ask]
    }

    /// Coerce stored mode while Agent is gated (legacy `.agent` → `.ask`).
    static func coerceForProduct(_ mode: StudyAgentMode) -> StudyAgentMode {
        guard isAgentProductEnabled else { return .ask }
        return mode
    }
}

struct Conversation: Codable, Equatable {
    let id: String
    var title: String
    var model: AIModelOption
    var messages: [ChatMessage]
    var updatedAt: Date
    var isArchived: Bool
    var forkedFromID: String?
    /// true = user renamed; skip AI auto-title
    var titleLocked: Bool
    /// Compact notes for turns that fell out of the API verbatim window.
    var contextSummary: String?
    /// Last original message id covered by `contextSummary`.
    var contextSummaryThroughMessageID: String?
    /// Optional per-conversation custom agent.
    var agentID: String?
    /// Optional project bucket for centralized management.
    var projectID: String?
    /// Bound study PDF document id, if any.
    var studyDocumentID: String?
    /// Study workspace folder id when `studySessionKind == .workspace`.
    var studyWorkspaceID: String?
    /// `.document` = single-file Study; `.workspace` = folder agent session.
    var studySessionKind: StudySessionKind
    /// When true, each send prepends the current PDF page text.
    var studyPageCaptureEnabled: Bool
    /// Agent / Plan / Ask mode for workspace sessions.
    var studyAgentMode: StudyAgentMode

    /// Explicit workspace id only — do **not** fall back to default for single-file chats.
    var activeStudyWorkspaceID: String? {
        guard studySessionKind == .workspace,
              let studyWorkspaceID, !studyWorkspaceID.isEmpty else { return nil }
        return studyWorkspaceID
    }

    var isWorkspaceStudySession: Bool {
        studySessionKind == .workspace && activeStudyWorkspaceID != nil
    }

    /// Agent timeline chrome (Thinking / Explored) — off while Agent product is gated.
    var usesWorkspaceAgentChrome: Bool {
        StudyAgentMode.isAgentProductEnabled && isWorkspaceStudySession
    }

    /// Basename of the document currently open in Study (nil if none).
    var studyActiveFileName: String? {
        guard let studyDocumentID,
              let doc = StudyDocumentStore.shared.document(id: studyDocumentID) else { return nil }
        if let path = doc.displayPath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        let title = doc.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Study writes (Agent / CONNECTS_EDIT) may only touch the open file.
    func allowsStudyMutating(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let lower = name.lowercased()
        if lower == "current" || lower == "." || lower == "active" { return true }
        guard let current = studyActiveFileName else { return false }
        return name.caseInsensitiveCompare(current) == .orderedSame
    }

    init(id: String = UUID().uuidString,
         title: String = L("新对话", "New Chat"),
         model: AIModelOption = .deepseekV4Pro,
         messages: [ChatMessage] = [],
         updatedAt: Date = Date(),
         isArchived: Bool = false,
         forkedFromID: String? = nil,
         titleLocked: Bool = false,
         contextSummary: String? = nil,
         contextSummaryThroughMessageID: String? = nil,
         agentID: String? = nil,
         projectID: String? = nil,
         studyDocumentID: String? = nil,
         studyWorkspaceID: String? = nil,
         studySessionKind: StudySessionKind = .document,
         studyPageCaptureEnabled: Bool = false,
         studyAgentMode: StudyAgentMode = .ask) {
        self.id = id
        self.title = title
        self.model = model
        self.messages = messages
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.forkedFromID = forkedFromID
        self.titleLocked = titleLocked
        self.contextSummary = contextSummary
        self.contextSummaryThroughMessageID = contextSummaryThroughMessageID
        self.agentID = agentID
        self.projectID = projectID
        self.studyDocumentID = studyDocumentID
        self.studyWorkspaceID = studyWorkspaceID
        self.studySessionKind = studySessionKind
        self.studyPageCaptureEnabled = studyPageCaptureEnabled
        self.studyAgentMode = studyAgentMode
    }

    /// Untitled / fork-derived names across both UI languages — eligible for AI renaming.
    static func isGenericTitle(_ title: String) -> Bool {
        title == "新对话" || title == "New Chat"
            || title.hasSuffix("（分叉）") || title.hasSuffix(" (Fork)")
    }

    enum CodingKeys: String, CodingKey {
        case id, title, messages, updatedAt, isArchived, forkedFromID, titleLocked
        case contextSummary, contextSummaryThroughMessageID
        case agentID, projectID
        case studyDocumentID, studyWorkspaceID, studySessionKind, studyPageCaptureEnabled, studyAgentMode
        case provider, modelId, customProviderID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        forkedFromID = try container.decodeIfPresent(String.self, forKey: .forkedFromID)
        titleLocked = try container.decodeIfPresent(Bool.self, forKey: .titleLocked) ?? false
        contextSummary = try container.decodeIfPresent(String.self, forKey: .contextSummary)
        contextSummaryThroughMessageID = try container.decodeIfPresent(String.self, forKey: .contextSummaryThroughMessageID)
        agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        studyDocumentID = try container.decodeIfPresent(String.self, forKey: .studyDocumentID)
        studyWorkspaceID = try container.decodeIfPresent(String.self, forKey: .studyWorkspaceID)
        if let kind = try container.decodeIfPresent(StudySessionKind.self, forKey: .studySessionKind) {
            studySessionKind = kind
        } else if let ws = studyWorkspaceID, !ws.isEmpty {
            studySessionKind = .workspace
        } else {
            studySessionKind = .document
        }
        studyPageCaptureEnabled = try container.decodeIfPresent(Bool.self, forKey: .studyPageCaptureEnabled) ?? false
        studyAgentMode = StudyAgentMode.coerceForProduct(
            try container.decodeIfPresent(StudyAgentMode.self, forKey: .studyAgentMode) ?? .ask
        )
        let provider = try container.decode(AIProvider.self, forKey: .provider)
        let modelId = try container.decode(String.self, forKey: .modelId)
        let customProviderID = try container.decodeIfPresent(String.self, forKey: .customProviderID)
        if provider == .custom {
            // BYOK: rebuild the option from the live profile; fall back when deleted.
            if let pid = customProviderID,
               let profile = SettingsManager.shared.customProvider(id: pid),
               profile.modelIDs.contains(modelId) {
                model = AIModelOption(
                    provider: .custom, modelId: modelId, displayName: modelId,
                    baseURL: profile.chatCompletionsURL, supportsVision: profile.supportsVision,
                    supportsThinkingToggle: false, forcesThinking: false,
                    thinkingStyle: .none, customProviderID: pid
                )
            } else {
                model = .deepseekV4Pro
            }
        } else if let available = AIModelOption.all.first(where: { $0.provider == provider && $0.modelId == modelId }) {
            model = available
        } else if provider == .kimi {
            model = .kimiK3
        } else {
            model = .deepseekV4Pro
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(messages, forKey: .messages)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encodeIfPresent(forkedFromID, forKey: .forkedFromID)
        try container.encode(titleLocked, forKey: .titleLocked)
        try container.encodeIfPresent(contextSummary, forKey: .contextSummary)
        try container.encodeIfPresent(contextSummaryThroughMessageID, forKey: .contextSummaryThroughMessageID)
        try container.encodeIfPresent(agentID, forKey: .agentID)
        try container.encodeIfPresent(projectID, forKey: .projectID)
        try container.encodeIfPresent(studyDocumentID, forKey: .studyDocumentID)
        try container.encodeIfPresent(studyWorkspaceID, forKey: .studyWorkspaceID)
        try container.encode(studySessionKind, forKey: .studySessionKind)
        try container.encode(studyPageCaptureEnabled, forKey: .studyPageCaptureEnabled)
        try container.encode(studyAgentMode, forKey: .studyAgentMode)
        try container.encode(model.provider, forKey: .provider)
        try container.encode(model.modelId, forKey: .modelId)
        try container.encodeIfPresent(model.customProviderID, forKey: .customProviderID)
    }
}
