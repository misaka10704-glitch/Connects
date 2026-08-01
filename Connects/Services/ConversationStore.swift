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
    private(set) var selectedProjectID: String?

    private let storageKey = "connects_conversations_v2"
    private let legacyKey = "connects_conversations"
    private let selectedProjectKey = "connects_selected_project_id"
    private var saveWorkItem: DispatchWorkItem?
    private var saveGeneration: UInt = 0

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
            .filter { conv in
                if showArchived { return true }
                if let pid = selectedProjectID { return conv.projectID == pid }
                return conv.projectID == nil
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func conversationCount(inProject projectID: String?) -> Int {
        conversations.filter {
            !$0.isArchived && $0.projectID == projectID
        }.count
    }

    init() {
        ConnectsPaths.ensureAppFolders()
        let loaded = load()
        selectedProjectID = normalizedProjectID(
            UserDefaults.standard.string(forKey: selectedProjectKey)
        )
        reconcileCurrentConversationAfterLoad(allowBootstrapEmpty: loaded.allowBootstrap)
    }

    /// Restore last opened chat and align sidebar project filter with it.
    /// - Parameter allowBootstrapEmpty: only create a blank conversation on true first launch.
    ///   Never bootstrap (and overwrite disk) when a persistence read failed.
    private func reconcileCurrentConversationAfterLoad(allowBootstrapEmpty: Bool) {
        if let id = currentConversationID,
           let conv = conversations.first(where: { $0.id == id }) {
            if !conv.isArchived {
                alignProjectFilter(with: conv.projectID, persist: true)
            }
            return
        }
        currentConversationID = nil
        if conversations.isEmpty {
            guard allowBootstrapEmpty else { return }
            let first = Conversation()
            conversations = [first]
            currentConversationID = first.id
            save()
            return
        }
        currentConversationID = visibleConversations.first?.id ?? conversations.first?.id
        persistCurrentConversationID()
    }

    private func alignProjectFilter(with projectID: String?, persist: Bool) {
        let target = normalizedProjectID(projectID)
        guard target != selectedProjectID else { return }
        selectedProjectID = target
        guard persist else { return }
        if let projectID = selectedProjectID {
            UserDefaults.standard.set(projectID, forKey: selectedProjectKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedProjectKey)
        }
    }

    private func persistCurrentConversationID() {
        guard let id = currentConversationID else { return }
        UserDefaults.standard.set(id, forKey: storageKey + "_current")
    }

    func setSelectedProjectID(_ projectID: String?) {
        let normalized = normalizedProjectID(projectID)
        guard normalized != selectedProjectID else { return }
        selectedProjectID = normalized
        if let projectID = selectedProjectID {
            UserDefaults.standard.set(projectID, forKey: selectedProjectKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedProjectKey)
        }
        notify(userInfo: ["source": "projectFilter"])
    }

    func setShowArchived(_ value: Bool) {
        guard showArchived != value else { return }
        showArchived = value
        notify(userInfo: ["source": "archiveFilter"])
    }

    func selectConversation(id: String) {
        guard currentConversationID != id else { return }
        guard conversations.contains(where: { $0.id == id }) else { return }
        let priorProject = selectedProjectID
        currentConversationID = id
        if let conv = conversation(id: id), !conv.isArchived {
            alignProjectFilter(with: conv.projectID, persist: true)
        }
        persistCurrentConversationID()
        var userInfo: [AnyHashable: Any] = ["source": "select"]
        if priorProject != selectedProjectID {
            userInfo["projectFilterChanged"] = true
        }
        notify(userInfo: userInfo)
    }

    private func notify(userInfo: [AnyHashable: Any]? = nil) {
        let post = {
            NotificationCenter.default.post(
                name: .conversationStoreDidUpdate,
                object: nil,
                userInfo: userInfo
            )
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    @discardableResult
    func createConversation(
        model: AIModelOption = .deepseekV4Pro,
        projectID: String? = nil,
        studyWorkspaceID: String? = nil,
        studyDocumentID: String? = nil,
        studySessionKind: StudySessionKind = .document,
        studyPageCaptureEnabled: Bool = false,
        studyAgentMode: StudyAgentMode = .ask
    ) -> Conversation {
        let assignedProject = projectID ?? selectedProjectID
        let conversation = Conversation(
            model: model,
            projectID: assignedProject,
            studyDocumentID: studyDocumentID,
            studyWorkspaceID: studyWorkspaceID,
            studySessionKind: studySessionKind,
            studyPageCaptureEnabled: studyPageCaptureEnabled,
            studyAgentMode: studyAgentMode
        )
        conversations.insert(conversation, at: 0)
        currentConversationID = conversation.id
        showArchived = false
        // Never encode the full store on the tap path — UserDefaults JSON can freeze the UI.
        persistCurrentConversationID()
        scheduleSave()
        notify(userInfo: ["source": "select"])
        return conversation
    }

    /// New Study chat in the same document or workspace session.
    @discardableResult
    func createStudyConversation(
        copyingFrom source: Conversation,
        keepActiveDocument: Bool = true
    ) -> Conversation {
        if source.isWorkspaceStudySession {
            return createConversation(
                model: source.model,
                projectID: source.projectID,
                studyWorkspaceID: source.studyWorkspaceID,
                studyDocumentID: keepActiveDocument ? source.studyDocumentID : nil,
                studySessionKind: .workspace,
                studyPageCaptureEnabled: source.studyPageCaptureEnabled,
                studyAgentMode: source.studyAgentMode
            )
        }
        return createConversation(
            model: source.model,
            projectID: source.projectID,
            studyWorkspaceID: nil,
            studyDocumentID: keepActiveDocument ? source.studyDocumentID : nil,
            studySessionKind: .document,
            studyPageCaptureEnabled: source.studyPageCaptureEnabled,
            studyAgentMode: .agent
        )
    }

    /// Legacy alias.
    @discardableResult
    func createStudyConversation(
        copyingWorkspaceFrom source: Conversation,
        keepActiveDocument: Bool = true
    ) -> Conversation {
        createStudyConversation(copyingFrom: source, keepActiveDocument: keepActiveDocument)
    }

    func conversations(inWorkspace workspaceID: String, includeArchived: Bool = false) -> [Conversation] {
        conversations
            .filter { conv in
                if !includeArchived && conv.isArchived { return false }
                return conv.studySessionKind == .workspace
                    && conv.studyWorkspaceID == workspaceID
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Workspace chats that belong to the **same parent folder** as this document.
    /// Matches exact folder workspace id, or any workspace chat whose bound file lives there
    /// (recovers older chats that were wrongly tied to a wide project grant).
    func conversations(sharingParentFolderOfDocument documentID: String, includeArchived: Bool = false) -> [Conversation] {
        guard let parent = StudyWorkspaceStore.shared.parentFolderPath(ofDocumentID: documentID) else {
            return conversations(boundToDocument: documentID, includeArchived: includeArchived)
        }
        let folderWSID = StudyWorkspaceStore.shared.workspaceID(withExactRootPath: parent)
        return conversations
            .filter { conv in
                if !includeArchived && conv.isArchived { return false }
                guard conv.studySessionKind == .workspace else { return false }
                if let folderWSID, conv.studyWorkspaceID == folderWSID {
                    return true
                }
                if let docID = conv.studyDocumentID,
                   let other = StudyWorkspaceStore.shared.parentFolderPath(ofDocumentID: docID),
                   other == parent {
                    return true
                }
                return false
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func conversations(boundToDocument documentID: String, includeArchived: Bool = false) -> [Conversation] {
        conversations
            .filter { conv in
                if !includeArchived && conv.isArchived { return false }
                return conv.studySessionKind == .document
                    && conv.studyDocumentID == documentID
            }
            .sorted { $0.updatedAt > $1.updatedAt }
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
                    hidesAttachedImageInChat: $0.hidesAttachedImageInChat,
                    imageDescription: $0.imageDescription,
                    imageTranscriptionContent: $0.imageTranscriptionContent,
                    imageTranscriptionPhase: $0.imageTranscriptionPhase == .transcribing ? .failed : $0.imageTranscriptionPhase
                )
            },
            forkedFromID: source.id,
            titleLocked: false,
            contextSummary: source.contextSummary,
            contextSummaryThroughMessageID: source.contextSummaryThroughMessageID,
            agentID: source.agentID,
            projectID: source.projectID,
            studyDocumentID: source.studyDocumentID,
            studyWorkspaceID: source.studyWorkspaceID,
            studySessionKind: source.studySessionKind,
            studyPageCaptureEnabled: source.studyPageCaptureEnabled,
            studyAgentMode: source.studyAgentMode
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
        scheduleSave()
        notify(userInfo: ["source": "select"])
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
        scheduleSave()
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
        notify(userInfo: ["source": "model"])
    }

    func setAgent(_ agentID: String?, for conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].agentID = agentID
        conversations[index].updatedAt = Date()
        save()
        notify()
    }

    func setProject(_ projectID: String?, for conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].projectID = projectID
        save()
        notify()
    }

    private func normalizedProjectID(_ projectID: String?) -> String? {
        guard let projectID = projectID else { return nil }
        return ProjectStore.shared.project(id: projectID) == nil ? nil : projectID
    }

    func unassignProject(id projectID: String) {
        var changed = false
        for i in conversations.indices where conversations[i].projectID == projectID {
            conversations[i].projectID = nil
            changed = true
        }
        guard changed else { return }
        save()
        notify()
    }

    func detachStudyDocument(documentID: String) {
        var changed = false
        for i in conversations.indices where conversations[i].studyDocumentID == documentID {
            conversations[i].studyDocumentID = nil
            conversations[i].studyPageCaptureEnabled = false
            changed = true
        }
        guard changed else { return }
        save()
        notify()
    }

    /// Keep assistant transcription panels in sync with durable user `imageDescription`.
    func repairImageTranscriptionDisplays(for conversationID: String? = nil) {
        let targets: [Int]
        if let conversationID = conversationID {
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
                return
            }
            targets = [index]
        } else {
            targets = Array(conversations.indices)
        }
        var changed = false
        for index in targets {
            guard conversations.indices.contains(index) else { continue }
            var msgs = conversations[index].messages
            guard msgs.count > 1 else { continue }
            var localChanged = false
            for j in 1..<msgs.count {
                guard msgs[j].role == .assistant, msgs[j - 1].role == .user else { continue }
                let user = msgs[j - 1]
                let display = msgs[j].imageTranscriptionDisplayText(pairedUser: user)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !display.isEmpty else { continue }
                if display != msgs[j].imageTranscriptionContent.trimmingCharacters(in: .whitespacesAndNewlines) {
                    msgs[j].imageTranscriptionContent = display
                    localChanged = true
                }
                if msgs[j].imageTranscriptionPhase == .idle
                    || msgs[j].imageTranscriptionPhase == .transcribing {
                    msgs[j].imageTranscriptionPhase = .done
                    localChanged = true
                }
            }
            if localChanged {
                conversations[index].messages = msgs
                changed = true
            }
        }
        guard changed else { return }
        save()
        notify()
    }

    /// Append streaming tokens to the last streaming assistant message of any conversation.
    func appendStreamTokens(conversationID: String, reasoning: String, content: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var conv = conversations[index]
        guard let msgIdx = conv.messages.lastIndex(where: { $0.isStreaming }) else { return }
        var last = conv.messages[msgIdx]
        if !reasoning.isEmpty { last.reasoningContent += reasoning }
        if !content.isEmpty { last.content += content }
        conv.messages[msgIdx] = last
        conv.updatedAt = Date()
        conversations[index] = conv
        scheduleSave()
    }

    func finishStreamingMessage(conversationID: String, errorText: String?) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var conv = conversations[index]
        guard let msgIdx = conv.messages.lastIndex(where: { $0.isStreaming }) else { return }
        var last = conv.messages[msgIdx]
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
        conv.messages[msgIdx] = last
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Flush pending encode immediately (background kill / Xcode rebuild).
    func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save(synchronously: true)
    }

    private struct LoadResult {
        var allowBootstrap: Bool
    }

    @discardableResult
    private func load() -> LoadResult {
        let decoder = JSONDecoder()
        func decode(_ data: Data) -> [Conversation]? {
            try? decoder.decode([Conversation].self, from: data)
        }

        var data: Data?
        var source = "none"
        let fileURL = ConnectsPaths.conversationsFileURL
        let bakURL = ConnectsPaths.conversationsBackupFileURL
        if let fileData = try? Data(contentsOf: fileURL), !fileData.isEmpty {
            data = fileData
            source = "file"
        } else if let bakData = try? Data(contentsOf: bakURL), !bakData.isEmpty {
            data = bakData
            source = "bak"
        } else if let ud = UserDefaults.standard.data(forKey: storageKey), !ud.isEmpty {
            data = ud
            source = "userDefaults_v2"
        } else if let legacy = UserDefaults.standard.data(forKey: legacyKey), !legacy.isEmpty {
            data = legacy
            source = "userDefaults_legacy"
        }

        guard let data else {
            // True first launch — no blob on disk.
            return LoadResult(allowBootstrap: true)
        }

        guard let decoded = decode(data) else {
            NSLog("[ConversationStore] decode failed from \(source) (\(data.count) bytes) — refusing to wipe")
            // Keep empty in memory; do NOT bootstrap+save (that would destroy the blob).
            return LoadResult(allowBootstrap: false)
        }

        conversations = decoded
        var repairedInterruptedStream = false
        // No network engine survives an app process restart. Persisted live
        // flags otherwise leave a permanent spinner/stop button on cold launch.
        for i in conversations.indices {
            for j in conversations[i].messages.indices {
                var last = conversations[i].messages[j]
                var changed = false
                if last.isStreaming {
                    last.isStreaming = false
                    changed = true
                }
                if last.agentProcessPhase == .running {
                    last.agentProcessPhase = .done
                    changed = true
                }
                if last.searchProcessPhase != .idle && last.searchProcessPhase != .done {
                    last.searchProcessPhase = .done
                    changed = true
                }
                if changed {
                    if last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !last.hasReasoning,
                       !last.hasSearchProcess,
                       !last.hasAgentProcess {
                        last.content = "上次生成因应用退出而中断，可点「重跑」重新生成。"
                    }
                    last.commitActiveVersion()
                    conversations[i].messages[j] = last
                    repairedInterruptedStream = true
                }
            }
        }
        currentConversationID = UserDefaults.standard.string(forKey: storageKey + "_current")
            ?? UserDefaults.standard.string(forKey: legacyKey + "_current")

        // Migrate UserDefaults blob → Application Support file (and drop huge UD key).
        if source.hasPrefix("userDefaults") || source == "bak" {
            writeConversationsFile((try? JSONEncoder().encode(conversations)) ?? data)
            UserDefaults.standard.removeObject(forKey: storageKey)
            UserDefaults.standard.removeObject(forKey: legacyKey)
        } else if repairedInterruptedStream {
            save()
        }
        return LoadResult(allowBootstrap: true)
    }

    private func writeConversationsFile(_ data: Data) {
        ConnectsPaths.ensureAppFolders()
        let fileURL = ConnectsPaths.conversationsFileURL
        let bakURL = ConnectsPaths.conversationsBackupFileURL
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: bakURL)
            try? fm.copyItem(at: fileURL, to: bakURL)
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[ConversationStore] file save failed: \(error.localizedDescription)")
        }
        // Stop stuffing megabytes into UserDefaults (rebuild / cfprefsd wipe risk).
        if UserDefaults.standard.data(forKey: storageKey) != nil {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        if UserDefaults.standard.data(forKey: legacyKey) != nil {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    private func save(synchronously: Bool = false) {
        // Never persist an empty wipe over a known-good on-disk history.
        if conversations.isEmpty,
           FileManager.default.fileExists(atPath: ConnectsPaths.conversationsFileURL.path)
            || UserDefaults.standard.data(forKey: storageKey) != nil {
            NSLog("[ConversationStore] skip empty save — refusing to overwrite existing history")
            return
        }

        saveGeneration &+= 1
        let generation = saveGeneration
        let snapshot = conversations
        persistCurrentConversationID()

        let encodeAndWrite = {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            if Thread.isMainThread {
                guard generation == self.saveGeneration else { return }
                self.writeConversationsFile(data)
            } else {
                DispatchQueue.main.async {
                    guard generation == self.saveGeneration else { return }
                    self.writeConversationsFile(data)
                }
            }
        }

        if synchronously {
            // Encode on caller thread so Xcode kill / resign doesn't drop the last turn.
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            writeConversationsFile(data)
        } else {
            DispatchQueue.global(qos: .utility).async(execute: encodeAndWrite)
        }
    }

    func reloadAfterBackupImport() {
        let loaded = load()
        selectedProjectID = normalizedProjectID(
            UserDefaults.standard.string(forKey: selectedProjectKey)
        )
        reconcileCurrentConversationAfterLoad(allowBootstrapEmpty: loaded.allowBootstrap)
        NotificationCenter.default.post(name: .conversationStoreDidUpdate, object: nil)
    }
}
