import Foundation

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

    init(id: String = UUID().uuidString,
         title: String = "新对话",
         model: AIModelOption = .deepseekV4Pro,
         messages: [ChatMessage] = [],
         updatedAt: Date = Date(),
         isArchived: Bool = false,
         forkedFromID: String? = nil,
         titleLocked: Bool = false,
         contextSummary: String? = nil,
         contextSummaryThroughMessageID: String? = nil) {
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
    }

    enum CodingKeys: String, CodingKey {
        case id, title, messages, updatedAt, isArchived, forkedFromID, titleLocked
        case contextSummary, contextSummaryThroughMessageID
        case provider, modelId
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
        let provider = try container.decode(AIProvider.self, forKey: .provider)
        let modelId = try container.decode(String.self, forKey: .modelId)
        model = AIModelOption.all.first { $0.provider == provider && $0.modelId == modelId } ?? .deepseekV4Pro
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
        try container.encode(model.provider, forKey: .provider)
        try container.encode(model.modelId, forKey: .modelId)
    }
}
