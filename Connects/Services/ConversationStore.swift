import Foundation

extension Notification.Name {
    static let conversationStoreDidUpdate = Notification.Name("ConnectsConversationStoreDidUpdate")
    static let sidebarCollapseDidChange = Notification.Name("ConnectsSidebarCollapseDidChange")
}

final class ConversationStore {
    static let shared = ConversationStore()

    private(set) var conversations: [Conversation] = []
    private(set) var currentConversationID: String?
    private(set) var showArchived = false

    private let storageKey = "connects_conversations_v2"
    private let legacyKey = "connects_conversations"
    private var saveWorkItem: DispatchWorkItem?

    var currentConversation: Conversation? {
        guard let id = currentConversationID else { return nil }
        return conversations.first { $0.id == id }
    }

    func conversation(id: String) -> Conversation? {
        conversations.first { $0.id == id }
    }

    var visibleConversations: [Conversation] {
        conversations
            .filter { showArchived ? $0.isArchived : !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    init() {
        load()
        if conversations.isEmpty {
            let first = Conversation()
            conversations = [first]
            currentConversationID = first.id
            save()
        } else if currentConversationID == nil {
            currentConversationID = visibleConversations.first?.id ?? conversations.first?.id
        }
    }

    func setShowArchived(_ value: Bool) {
        showArchived = value
        if let cur = currentConversation, cur.isArchived != value {
            currentConversationID = visibleConversations.first?.id
        }
        notify()
    }

    func selectConversation(id: String) {
        guard currentConversationID != id else { return }
        currentConversationID = id
        notify(userInfo: ["source": "select"])
    }

    private func notify(userInfo: [AnyHashable: Any]? = nil) {
        NotificationCenter.default.post(name: .conversationStoreDidUpdate, object: nil, userInfo: userInfo)
    }

    @discardableResult
    func createConversation(model: AIModelOption = .deepseekV4Pro) -> Conversation {
        let conversation = Conversation(model: model)
        conversations.insert(conversation, at: 0)
        currentConversationID = conversation.id
        showArchived = false
        save()
        notify()
        return conversation
    }

    func deleteConversation(id: String) {
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty {
            let fresh = Conversation()
            conversations = [fresh]
            currentConversationID = fresh.id
            showArchived = false
        } else if currentConversationID == id {
            currentConversationID = visibleConversations.first?.id ?? conversations.first?.id
        }
        save()
        notify()
    }

    func renameConversation(id: String, title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversations[index].title = String(trimmed.prefix(40))
        conversations[index].titleLocked = true
        conversations[index].updatedAt = Date()
        save()
        notify()
    }

    func setArchived(id: String, archived: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].isArchived = archived
        conversations[index].updatedAt = Date()
        if archived && currentConversationID == id {
            showArchived = false
            currentConversationID = visibleConversations.first?.id ?? id
        }
        save()
        notify()
    }

    @discardableResult
    func forkConversation(id: String, throughMessageID: String? = nil) -> Conversation? {
        guard let source = conversations.first(where: { $0.id == id }) else { return nil }
        var msgs = source.messages
        if let mid = throughMessageID, let end = msgs.firstIndex(where: { $0.id == mid }) {
            msgs = Array(msgs.prefix(through: end))
        }
        // Drop incomplete streaming tail
        msgs = msgs.filter { !$0.isStreaming }
        var copy = Conversation(
            title: source.title + "（分叉）",
            model: source.model,
            messages: msgs.map {
                ChatMessage(
                    role: $0.role,
                    content: $0.content,
                    reasoningContent: $0.reasoningContent,
                    searchProcessContent: $0.searchProcessContent,
                    searchProcessPhase: $0.searchProcessPhase == .idle ? .idle : .done,
                    createdAt: $0.createdAt,
                    imageJPEGBase64: $0.imageJPEGBase64,
                    imageDescription: $0.imageDescription,
                    imageTranscriptionContent: $0.imageTranscriptionContent,
                    imageTranscriptionPhase: $0.imageTranscriptionPhase == .transcribing ? .failed : $0.imageTranscriptionPhase
                )
            },
            forkedFromID: source.id,
            titleLocked: false,
            contextSummary: source.contextSummary,
            contextSummaryThroughMessageID: source.contextSummaryThroughMessageID
        )
        // If forked mid-thread, drop summary unless the covered message is still present.
        if let tid = copy.contextSummaryThroughMessageID,
           !copy.messages.contains(where: { $0.id == tid }) {
            copy.contextSummary = nil
            copy.contextSummaryThroughMessageID = nil
        }
        copy.titleLocked = false
        conversations.insert(copy, at: 0)
        currentConversationID = copy.id
        showArchived = false
        save()
        notify()
        return copy
    }

    /// Immediate title from first user message (ChatGPT-like); AI may refine later.
    func applyProvisionalTitle(id: String, fromUserText text: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        guard !conversations[index].titleLocked else { return }
        let cur = conversations[index].title
        guard cur == "新对话" || cur.hasSuffix("（分叉）") else { return }
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !cleaned.isEmpty, cleaned != "[图片]" else { return }
        conversations[index].title = String(cleaned.prefix(20))
        conversations[index].updatedAt = Date()
        save()
        notify(userInfo: ["source": "title"])
    }

    func applyAITitle(id: String, title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        guard !conversations[index].titleLocked else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "《", with: "")
            .replacingOccurrences(of: "》", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        guard !trimmed.isEmpty else { return }
        // Ignore overly long / prompt-echo responses
        guard trimmed.count <= 30 else { return }
        conversations[index].title = String(trimmed.prefix(24))
        conversations[index].updatedAt = Date()
        save()
        notify(userInfo: ["source": "title"])
    }

    func updateCurrent(_ mutate: (inout Conversation) -> Void) {
        mutateCurrent(mutate)
        save()
        notify()
    }

    func updateCurrentQuietly(_ mutate: (inout Conversation) -> Void) {
        mutateCurrent(mutate)
        scheduleSave()
    }

    func updateConversation(id: String, _ mutate: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var conv = conversations[index]
        mutate(&conv)
        conv.updatedAt = Date()
        conversations[index] = conv
        scheduleSave()
        notify()
    }

    func updateConversationQuietly(id: String, _ mutate: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var conv = conversations[index]
        mutate(&conv)
        conv.updatedAt = Date()
        conversations[index] = conv
        scheduleSave()
    }

    func setModel(_ model: AIModelOption, for conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].model = model
        conversations[index].updatedAt = Date()
        save()
        notify()
    }

    /// Append streaming tokens to the last streaming assistant message of any conversation.
    func appendStreamTokens(conversationID: String, reasoning: String, content: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var conv = conversations[index]
        guard var last = conv.messages.last, last.isStreaming else { return }
        if !reasoning.isEmpty { last.reasoningContent += reasoning }
        if !content.isEmpty { last.content += content }
        conv.messages[conv.messages.count - 1] = last
        conv.updatedAt = Date()
        conversations[index] = conv
        scheduleSave()
    }

    func finishStreamingMessage(conversationID: String, errorText: String?) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var conv = conversations[index]
        guard var last = conv.messages.last, last.isStreaming else { return }
        last.isStreaming = false
        if let errorText = errorText,
           last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !last.hasReasoning,
           !last.hasSearchProcess {
            last.content = errorText
        } else if last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !last.hasReasoning,
                  !last.hasSearchProcess {
            last.content = "模型未返回内容。可点「重跑」再试。"
        }
        if last.searchProcessPhase != .idle {
            last.searchProcessPhase = .done
        }
        last.commitActiveVersion()
        conv.messages[conv.messages.count - 1] = last
        conv.updatedAt = Date()
        conversations[index] = conv
        save()
        // Do not notify here — StreamManager posts streamManagerDidFinish once to avoid triple reloadData.
    }

    private func mutateCurrent(_ mutate: (inout Conversation) -> Void) {
        guard let id = currentConversationID,
              let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var conv = conversations[index]
        mutate(&conv)
        conv.updatedAt = Date()
        conversations[index] = conv
    }

    /// Persist the raw conversation JSON only. Markdown is generated solely by
    /// the explicit export action in ChatViewController.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func load() {
        let data = UserDefaults.standard.data(forKey: storageKey)
            ?? UserDefaults.standard.data(forKey: legacyKey)
        guard let data = data,
              let decoded = try? JSONDecoder().decode([Conversation].self, from: data) else {
            return
        }
        conversations = decoded
        var repairedInterruptedStream = false
        // No network engine survives an app process restart. Persisted live
        // flags otherwise leave a permanent spinner/stop button on cold launch.
        for i in conversations.indices {
            guard var last = conversations[i].messages.last, last.isStreaming else { continue }
            last.isStreaming = false
            if last.searchProcessPhase != .idle {
                last.searchProcessPhase = .done
            }
            if last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !last.hasReasoning,
               !last.hasSearchProcess {
                last.content = "上次生成因应用退出而中断，可点「重跑」重新生成。"
            }
            last.commitActiveVersion()
            conversations[i].messages[conversations[i].messages.count - 1] = last
            repairedInterruptedStream = true
        }
        currentConversationID = UserDefaults.standard.string(forKey: storageKey + "_current")
            ?? UserDefaults.standard.string(forKey: legacyKey + "_current")
        if repairedInterruptedStream {
            save()
        }
    }

    private func save() {
        // Encode off hot path would be better; keep main for iOS-12 simplicity but avoid during 30Hz UI.
        if let data = try? JSONEncoder().encode(conversations) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        if let id = currentConversationID {
            UserDefaults.standard.set(id, forKey: storageKey + "_current")
        }
    }
}
