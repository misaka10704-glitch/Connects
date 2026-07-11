import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct ChatMessage: Codable, Equatable {
    let id: String
    let role: MessageRole
    var content: String
    /// Kimi / thinking models stream this before the final reply.
    var reasoningContent: String
    let createdAt: Date
    var isStreaming: Bool
    /// JPEG base64 for Kimi multimodal & local display
    var imageJPEGBase64: String?

    init(id: String = UUID().uuidString,
         role: MessageRole,
         content: String,
         reasoningContent: String = "",
         createdAt: Date = Date(),
         isStreaming: Bool = false,
         imageJPEGBase64: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.imageJPEGBase64 = imageJPEGBase64
    }

    var apiRole: String { role.rawValue }

    var hasImage: Bool { imageJPEGBase64 != nil && !(imageJPEGBase64?.isEmpty ?? true) }

    var hasReasoning: Bool {
        !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Text suitable for clipboard.
    var copyableText: String {
        var parts: [String] = []
        let think = reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
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

    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningContent, createdAt, isStreaming, imageJPEGBase64
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(MessageRole.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isStreaming = try c.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        imageJPEGBase64 = try c.decodeIfPresent(String.self, forKey: .imageJPEGBase64)
    }
}
