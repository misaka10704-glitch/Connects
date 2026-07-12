import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

/// One completed (or in-progress) assistant reply attempt.
struct MessageVersion: Codable, Equatable {
    var content: String
    var reasoningContent: String
    var createdAt: Date

    init(content: String = "",
         reasoningContent: String = "",
         createdAt: Date = Date()) {
        self.content = content
        self.reasoningContent = reasoningContent
        self.createdAt = createdAt
    }
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
    /// Assistant regenerations. Empty for legacy / single-shot messages.
    var versions: [MessageVersion]
    /// Index into `versions` when non-empty; mirrors `content` / `reasoningContent`.
    var versionIndex: Int

    init(id: String = UUID().uuidString,
         role: MessageRole,
         content: String,
         reasoningContent: String = "",
         createdAt: Date = Date(),
         isStreaming: Bool = false,
         imageJPEGBase64: String? = nil,
         versions: [MessageVersion] = [],
         versionIndex: Int = 0) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.imageJPEGBase64 = imageJPEGBase64
        self.versions = versions
        self.versionIndex = versionIndex
    }

    var apiRole: String { role.rawValue }

    var hasImage: Bool { imageJPEGBase64 != nil && !(imageJPEGBase64?.isEmpty ?? true) }

    var hasReasoning: Bool {
        !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// Persist current fields into `versions[versionIndex]`.
    mutating func commitActiveVersion() {
        guard role == .assistant else { return }
        let snap = MessageVersion(
            content: content,
            reasoningContent: reasoningContent,
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
            if !content.isEmpty || !reasoningContent.isEmpty {
                versions = [
                    MessageVersion(content: content, reasoningContent: reasoningContent, createdAt: createdAt)
                ]
            }
        } else if versions.indices.contains(versionIndex) {
            versions[versionIndex].content = content
            versions[versionIndex].reasoningContent = reasoningContent
        }
        versions.append(MessageVersion(content: "", reasoningContent: "", createdAt: Date()))
        versionIndex = versions.count - 1
        content = ""
        reasoningContent = ""
        isStreaming = true
    }

    /// Switch visible reply version. Returns false if unchanged / invalid.
    @discardableResult
    mutating func selectVersion(at index: Int) -> Bool {
        guard role == .assistant, versions.count > 1, versions.indices.contains(index) else { return false }
        if versions.indices.contains(versionIndex) {
            versions[versionIndex].content = content
            versions[versionIndex].reasoningContent = reasoningContent
        }
        versionIndex = index
        content = versions[index].content
        reasoningContent = versions[index].reasoningContent
        return true
    }

    @discardableResult
    mutating func shiftVersion(by delta: Int) -> Bool {
        guard versions.count > 1 else { return false }
        let next = min(max(0, versionIndex + delta), versions.count - 1)
        return selectVersion(at: next)
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningContent, createdAt, isStreaming, imageJPEGBase64
        case versions, versionIndex
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
        versions = try c.decodeIfPresent([MessageVersion].self, forKey: .versions) ?? []
        versionIndex = try c.decodeIfPresent(Int.self, forKey: .versionIndex) ?? 0
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
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(reasoningContent, forKey: .reasoningContent)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(isStreaming, forKey: .isStreaming)
        try c.encodeIfPresent(imageJPEGBase64, forKey: .imageJPEGBase64)
        if !versions.isEmpty {
            try c.encode(versions, forKey: .versions)
            try c.encode(versionIndex, forKey: .versionIndex)
        }
    }
}
