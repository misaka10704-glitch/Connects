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
        case .idle: return "图片文字描述"
        case .transcribing: return "正在转写图片…"
        case .done: return "图片文字描述"
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
    /// Durable semantic replacement used after the original image leaves API context.
    var imageDescription: String?
    /// Companion assistant status for the non-blocking image transcription job.
    var imageTranscriptionContent: String
    var imageTranscriptionPhase: ImageTranscriptionPhase
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
         imageDescription: String? = nil,
         imageTranscriptionContent: String = "",
         imageTranscriptionPhase: ImageTranscriptionPhase = .idle,
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
        self.imageDescription = imageDescription
        self.imageTranscriptionContent = imageTranscriptionContent
        self.imageTranscriptionPhase = imageTranscriptionPhase
        self.versions = versions
        self.versionIndex = versionIndex
    }

    var apiRole: String { role.rawValue }

    var hasImage: Bool { imageJPEGBase64 != nil && !(imageJPEGBase64?.isEmpty ?? true) }

    var hasReasoning: Bool {
        !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasSearchProcess: Bool {
        !searchProcessContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (searchProcessPhase != .idle && searchProcessPhase != .done)
    }

    var hasImageTranscription: Bool {
        !imageTranscriptionContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || imageTranscriptionPhase != .idle
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
        case createdAt, isStreaming, imageJPEGBase64, imageDescription
        case imageTranscriptionContent, imageTranscriptionPhase
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
        imageDescription = try c.decodeIfPresent(String.self, forKey: .imageDescription)
        imageTranscriptionContent = try c.decodeIfPresent(String.self, forKey: .imageTranscriptionContent) ?? ""
        imageTranscriptionPhase = try c.decodeIfPresent(ImageTranscriptionPhase.self, forKey: .imageTranscriptionPhase) ?? .idle
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
            if searchProcessContent.isEmpty, !v.searchProcessContent.isEmpty {
                searchProcessContent = v.searchProcessContent
            }
            if searchProcessPhase == .idle, v.searchProcessPhase != .idle {
                searchProcessPhase = v.searchProcessPhase
            }
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
        try c.encodeIfPresent(imageDescription, forKey: .imageDescription)
        if !imageTranscriptionContent.isEmpty || imageTranscriptionPhase != .idle {
            try c.encode(imageTranscriptionContent, forKey: .imageTranscriptionContent)
            try c.encode(imageTranscriptionPhase, forKey: .imageTranscriptionPhase)
        }
        if !versions.isEmpty {
            try c.encode(versions, forKey: .versions)
            try c.encode(versionIndex, forKey: .versionIndex)
        }
    }
}
