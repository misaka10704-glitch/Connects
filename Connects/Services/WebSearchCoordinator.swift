import Foundation

extension Notification.Name {
    /// userInfo["conversationID"] = String
    static let webSearchDidUpdate = Notification.Name("ConnectsWebSearchDidUpdate")
}

/// Per-conversation web-search jobs so multiple chats can browse in parallel
/// without cancelling or cross-wiring each other.
final class WebSearchCoordinator {
    static let shared = WebSearchCoordinator()

    private let lock = NSLock()
    /// conversationID → generation (bumped on start / cancel).
    private var generations: [String: UInt64] = [:]
    private var active: Set<String> = []

    private init() {}

    func isSearching(_ conversationID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.contains(conversationID)
    }

    func searchingIDs() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Begin (or replace) search for one conversation only.
    @discardableResult
    func begin(_ conversationID: String) -> UInt64 {
        lock.lock()
        let next = (generations[conversationID] ?? 0) &+ 1
        generations[conversationID] = next
        active.insert(conversationID)
        lock.unlock()
        postUpdate(conversationID)
        return next
    }

    func isCurrent(_ conversationID: String, generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.contains(conversationID) && generations[conversationID] == generation
    }

    func finish(_ conversationID: String, generation: UInt64) {
        lock.lock()
        guard generations[conversationID] == generation else {
            lock.unlock()
            return
        }
        active.remove(conversationID)
        lock.unlock()
        postUpdate(conversationID)
    }

    /// Cancel one conversation's search. In-flight callbacks become no-ops.
    func cancel(_ conversationID: String) {
        lock.lock()
        let next = (generations[conversationID] ?? 0) &+ 1
        generations[conversationID] = next
        let wasActive = active.remove(conversationID) != nil
        lock.unlock()
        if wasActive {
            postUpdate(conversationID)
        }
    }

    private func postUpdate(_ conversationID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .webSearchDidUpdate,
                object: nil,
                userInfo: ["conversationID": conversationID]
            )
        }
    }
}

extension Notification.Name {
    /// userInfo["conversationID"] = String
    static let imageTranscriptionDidUpdate = Notification.Name("ConnectsImageTranscriptionDidUpdate")
}

/// Background semantic extraction for image turns. It intentionally does not
/// gate the main reply: the image is sent once to the active vision model while
/// this job prepares durable text for all later turns.
final class ImageTranscriptionCoordinator {
    static let shared = ImageTranscriptionCoordinator()

    private let lock = NSLock()
    private var generations: [String: UInt64] = [:]
    private var active: Set<String> = []

    private init() {}

    func isTranscribing(_ conversationID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.contains(conversationID)
    }

    func cancel(_ conversationID: String) {
        lock.lock()
        generations[conversationID] = (generations[conversationID] ?? 0) &+ 1
        let changed = active.remove(conversationID) != nil
        lock.unlock()
        if changed { postUpdate(conversationID) }
    }

    func start(conversationID: String,
               userMessageID: String,
               assistantMessageID: String,
               base64: String,
               model: AIModelOption) {
        guard SettingsManager.shared.hasAPIKey(for: model.provider) else {
            finish(
                conversationID: conversationID,
                userMessageID: userMessageID,
                assistantMessageID: assistantMessageID,
                generation: 0,
                result: .failure(APIClientError.missingAPIKey(model.provider.displayName)),
                requiresActiveGeneration: false
            )
            return
        }

        lock.lock()
        let generation = (generations[conversationID] ?? 0) &+ 1
        generations[conversationID] = generation
        active.insert(conversationID)
        lock.unlock()
        updateAssistant(
            conversationID: conversationID,
            messageID: assistantMessageID,
            phase: .transcribing,
            content: "正在将图片转写为文字，主回复不会等待此步骤。"
        )
        postUpdate(conversationID)

        let prompt = ChatMessage(
            role: .user,
            content: """
            把图片转换为供后续对话引用的准确中文文字描述。转写可见文字；数学、物理、化学式必须写成 LaTex；乐谱必须列出调号、拍号、速度、谱表、音高、节奏、临时记号、指法、表情与力度。无法辨识时明确标注，不要猜测。只输出描述正文，控制在 1000 字内。
            """,
            imageJPEGBase64: base64
        )
        APIClient.shared.complete(messages: [prompt], model: model, maxTokens: 1_200, timeout: 180) { [weak self] result in
            self?.finish(
                conversationID: conversationID,
                userMessageID: userMessageID,
                assistantMessageID: assistantMessageID,
                generation: generation,
                result: result,
                requiresActiveGeneration: true
            )
        }
    }

    private func finish(conversationID: String,
                        userMessageID: String,
                        assistantMessageID: String,
                        generation: UInt64,
                        result: Result<String, Error>,
                        requiresActiveGeneration: Bool) {
        if requiresActiveGeneration {
            lock.lock()
            let current = active.contains(conversationID) && generations[conversationID] == generation
            if current { active.remove(conversationID) }
            lock.unlock()
            guard current else { return }
        }

        switch result {
        case .success(let raw):
            let description = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else {
                updateAssistant(
                    conversationID: conversationID,
                    messageID: assistantMessageID,
                    phase: .failed,
                    content: "未获得可用的图片文字描述。点此可重试。"
                )
                postUpdate(conversationID)
                return
            }
            ConversationStore.shared.updateConversationQuietly(id: conversationID) { conversation in
                if let i = conversation.messages.firstIndex(where: { $0.id == userMessageID }) {
                    conversation.messages[i].imageDescription = description
                    // The initial streaming request already captured its image
                    // snapshot. Persist only the compact semantic form after it.
                    conversation.messages[i].imageJPEGBase64 = nil
                }
                if let i = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }) {
                    conversation.messages[i].imageTranscriptionPhase = .done
                    conversation.messages[i].imageTranscriptionContent = description
                }
            }
        case .failure(let error):
            updateAssistant(
                conversationID: conversationID,
                messageID: assistantMessageID,
                phase: .failed,
                content: "图片转写失败：\(error.localizedDescription)\n点此可重试。"
            )
        }
        postUpdate(conversationID)
    }

    private func updateAssistant(conversationID: String,
                                 messageID: String,
                                 phase: ImageTranscriptionPhase,
                                 content: String) {
        ConversationStore.shared.updateConversationQuietly(id: conversationID) { conversation in
            guard let i = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conversation.messages[i].imageTranscriptionPhase = phase
            conversation.messages[i].imageTranscriptionContent = content
        }
    }

    private func postUpdate(_ conversationID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .imageTranscriptionDidUpdate,
                object: nil,
                userInfo: ["conversationID": conversationID]
            )
        }
    }
}
