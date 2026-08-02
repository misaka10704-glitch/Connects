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

    /// True when this generation was not cancelled/replaced (search may already have finished).
    func matchesGeneration(_ conversationID: String, generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generations[conversationID] == generation
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

/// Quiet Kimi K2.5 Vision transcription for image turns (no live token UI — avoids row bounce).
/// - Vision chat models: reply starts immediately; this job prepares durable text.
/// - Non-vision chat models: callers pass `onComplete` and wait before streaming.
final class ImageTranscriptionCoordinator {
    static let shared = ImageTranscriptionCoordinator()

    private let lock = NSLock()
    private var generations: [String: UInt64] = [:]
    private var active: Set<String> = []
    private var completions: [String: (Bool) -> Void] = [:]

    private init() {}

    func isTranscribing(_ conversationID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.contains(conversationID)
    }

    func cancel(_ conversationID: String) {
        lock.lock()
        generations[conversationID] = (generations[conversationID] ?? 0) &+ 1
        let changed = active.remove(conversationID) != nil
        let pending = completions.removeValue(forKey: conversationID)
        lock.unlock()
        pending?(false)
        if changed { postUpdate(conversationID) }
    }

    func start(conversationID: String,
               userMessageID: String,
               assistantMessageID: String,
               base64: String,
               model: AIModelOption = AIModelOption.preferredImageTranscription,
               studyPagePDFText: String? = nil,
               onComplete: ((Bool) -> Void)? = nil) {
        if let onComplete {
            lock.lock()
            completions[conversationID] = onComplete
            lock.unlock()
        }

        guard SettingsManager.shared.hasAPIKey(for: model.provider) else {
            finish(
                conversationID: conversationID,
                userMessageID: userMessageID,
                assistantMessageID: assistantMessageID,
                generation: 0,
                ocrText: nil,
                result: .failure(APIClientError.missingAPIKey(model.provider.displayName)),
                requiresActiveGeneration: false
            )
            return
        }

        let isStudyPage = studyPagePDFText != nil
        // Rich study text already travels as apiContextPrefix — same as standalone
        // text chat. Dumping it into「图片转写」was the Study OCR leak.
        if let studyText = studyPagePDFText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           studyText.count >= 80 {
            ConversationStore.shared.updateConversationQuietly(id: conversationID) { conversation in
                if let i = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }) {
                    conversation.messages[i].imageTranscriptionPhase = .idle
                    conversation.messages[i].imageTranscriptionContent = ""
                }
                // Drop JPEG so non-vision models can proceed on reading-context text alone.
                if let i = conversation.messages.firstIndex(where: { $0.id == userMessageID }) {
                    conversation.messages[i].imageJPEGBase64 = nil
                }
            }
            postUpdate(conversationID)
            invokeCompletion(conversationID, success: true)
            return
        }

        lock.lock()
        let generation = (generations[conversationID] ?? 0) &+ 1
        generations[conversationID] = generation
        active.insert(conversationID)
        lock.unlock()

        // Header-only status (collapsed) — no live body growth that shakes the list.
        updateAssistant(
            conversationID: conversationID,
            messageID: assistantMessageID,
            phase: .transcribing,
            content: isStudyPage
                ? "正在提取页面文字并转写…"
                : "正在转写图片…"
        )
        postUpdate(conversationID)

        if isStudyPage {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let ocr = StudyPageOCRExtractor.extract(
                    pdfText: studyPagePDFText,
                    imageBase64: base64
                )
                DispatchQueue.main.async {
                    guard let self = self, self.isGenerationActive(conversationID, generation) else { return }
                    let ocrText = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !ocrText.isEmpty {
                        self.commitOCR(
                            conversationID: conversationID,
                            userMessageID: userMessageID,
                            assistantMessageID: assistantMessageID,
                            ocrText: ocrText
                        )
                    }
                    self.runVisionTranscription(
                        conversationID: conversationID,
                        userMessageID: userMessageID,
                        assistantMessageID: assistantMessageID,
                        base64: base64,
                        model: model,
                        generation: generation,
                        ocrText: ocrText.isEmpty ? nil : ocrText
                    )
                }
            }
            return
        }

        runVisionTranscription(
            conversationID: conversationID,
            userMessageID: userMessageID,
            assistantMessageID: assistantMessageID,
            base64: base64,
            model: model,
            generation: generation,
            ocrText: nil
        )
    }

    private func invokeCompletion(_ conversationID: String, success: Bool) {
        lock.lock()
        let pending = completions.removeValue(forKey: conversationID)
        lock.unlock()
        pending?(success)
    }

    private func isGenerationActive(_ conversationID: String, _ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active.contains(conversationID) && generations[conversationID] == generation
    }

    private func commitOCR(conversationID: String,
                           userMessageID: String,
                           assistantMessageID: String,
                           ocrText: String) {
        let durable = ImageDurableText.ocrBlock(ocrText)
        ConversationStore.shared.updateConversationQuietly(id: conversationID) { conversation in
            if let i = conversation.messages.firstIndex(where: { $0.id == userMessageID }) {
                conversation.messages[i].imageDescription = durable
                clearStudyApiContextPrefix(on: &conversation.messages[i])
            }
            if let i = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }) {
                conversation.messages[i].imageTranscriptionPhase = .transcribing
                conversation.messages[i].imageTranscriptionContent = "正在转写图片…"
            }
        }
        postUpdate(conversationID)
    }

    private func runVisionTranscription(conversationID: String,
                                        userMessageID: String,
                                        assistantMessageID: String,
                                        base64: String,
                                        model: AIModelOption,
                                        generation: UInt64,
                                        ocrText: String?) {
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
                ocrText: ocrText,
                result: result,
                requiresActiveGeneration: true
            )
        }
    }

    private func finish(conversationID: String,
                        userMessageID: String,
                        assistantMessageID: String,
                        generation: UInt64,
                        ocrText: String?,
                        result: Result<String, Error>,
                        requiresActiveGeneration: Bool) {
        if requiresActiveGeneration {
            lock.lock()
            let current = active.contains(conversationID) && generations[conversationID] == generation
            if current { active.remove(conversationID) }
            lock.unlock()
            // Stale / replaced job — never touch the newer completion handler.
            guard current else { return }
        }

        var success = false
        switch result {
        case .success(let raw):
            let transcription = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcription.isEmpty else {
                finalizePartial(
                    conversationID: conversationID,
                    userMessageID: userMessageID,
                    assistantMessageID: assistantMessageID,
                    ocrText: ocrText,
                    failureMessage: "未获得可用的图片转写。点此可重试。"
                )
                success = !(ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                invokeCompletion(conversationID, success: success)
                postUpdate(conversationID)
                return
            }
            let durable = ImageDurableText.merge(ocr: ocrText, transcription: transcription)
            ConversationStore.shared.updateConversationQuietly(id: conversationID) { conversation in
                if let i = conversation.messages.firstIndex(where: { $0.id == userMessageID }) {
                    conversation.messages[i].imageDescription = durable
                    conversation.messages[i].imageJPEGBase64 = nil
                    clearStudyApiContextPrefix(on: &conversation.messages[i])
                }
                if let i = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }) {
                    conversation.messages[i].imageTranscriptionPhase = .done
                    conversation.messages[i].imageTranscriptionContent = durable
                }
            }
            success = true
        case .failure(let error):
            finalizePartial(
                conversationID: conversationID,
                userMessageID: userMessageID,
                assistantMessageID: assistantMessageID,
                ocrText: ocrText,
                failureMessage: "图片转写失败：\(error.localizedDescription)\n点此可重试。"
            )
            success = !(ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        invokeCompletion(conversationID, success: success)
        postUpdate(conversationID)
    }

    private func finalizePartial(conversationID: String,
                                 userMessageID: String,
                                 assistantMessageID: String,
                                 ocrText: String?,
                                 failureMessage: String) {
        let trimmedOCR = ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedOCR.isEmpty {
            let durable = ImageDurableText.ocrBlock(trimmedOCR)
            ConversationStore.shared.updateConversationQuietly(id: conversationID) { conversation in
                if let i = conversation.messages.firstIndex(where: { $0.id == userMessageID }) {
                    conversation.messages[i].imageDescription = durable
                    conversation.messages[i].imageJPEGBase64 = nil
                    clearStudyApiContextPrefix(on: &conversation.messages[i])
                }
                if let i = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }) {
                    conversation.messages[i].imageTranscriptionPhase = .done
                    conversation.messages[i].imageTranscriptionContent =
                        durable + "\n\n（图片转写未完成）"
                }
            }
            return
        }
        updateAssistant(
            conversationID: conversationID,
            messageID: assistantMessageID,
            phase: .failed,
            content: failureMessage
        )
        ConversationStore.shared.updateConversationQuietly(id: conversationID) { conversation in
            if let i = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }) {
                conversation.messages[i].isStreaming = false
            }
        }
    }

    private func clearStudyApiContextPrefix(on message: inout ChatMessage) {
        guard let prefix = message.apiContextPrefix,
              prefix.contains("[阅读上下文") else { return }
        message.apiContextPrefix = nil
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
