import Foundation

enum ConnectsChatTransferError: LocalizedError {
    case invalidArchive
    case invalidManifest
    case invalidConversations
    case emptyExport

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "不是有效的 Connects 聊天迁移包。"
        case .invalidManifest: return "聊天迁移包清单无效或版本不兼容。"
        case .invalidConversations: return "聊天迁移包中的对话数据无法读取。"
        case .emptyExport: return "没有可导出的对话。"
        }
    }
}

struct ConnectsChatTransferSummary: Equatable {
    let createdAt: Date
    let conversationCount: Int
    let projectCount: Int
    let mergedCount: Int
    let addedCount: Int
}

enum ConnectsChatTransferService {
    static let formatID = "connects-chat"
    static let formatVersion = 1
    static let fileExtension = "connectschat"

    /// Export all conversations (including archived).
    static func exportAll(to archiveURL: URL) throws -> ConnectsChatTransferSummary {
        ConversationStore.shared.flushPendingSave()
        let conversations = ConversationStore.shared.conversations
        guard !conversations.isEmpty else { throw ConnectsChatTransferError.emptyExport }
        return try export(conversations: conversations, to: archiveURL)
    }

    /// Export a single conversation by id.
    static func exportConversation(id: String, to archiveURL: URL) throws -> ConnectsChatTransferSummary {
        ConversationStore.shared.flushPendingSave()
        guard let conversation = ConversationStore.shared.conversation(id: id) else {
            throw ConnectsChatTransferError.emptyExport
        }
        return try export(conversations: [conversation], to: archiveURL)
    }

    static func importPackage(from archiveURL: URL) throws -> ConnectsChatTransferSummary {
        let staging = try BackupBundleHelper.temporaryFolder(prefix: "connects-chat-import")
        defer { BackupBundleHelper.removeIfExists(staging) }

        try SimpleZip.unzip(archiveURL: archiveURL, to: staging)
        let manifest = try readManifest(in: staging)

        let conversationsURL = staging.appendingPathComponent("conversations.json")
        guard FileManager.default.fileExists(atPath: conversationsURL.path) else {
            throw ConnectsChatTransferError.invalidConversations
        }
        let conversationsData = try Data(contentsOf: conversationsURL)
        let decoder = JSONDecoder()
        guard let conversations = try? decoder.decode([Conversation].self, from: conversationsData) else {
            throw ConnectsChatTransferError.invalidConversations
        }

        var projects: [Project] = []
        let projectsURL = staging.appendingPathComponent("projects.json")
        if FileManager.default.fileExists(atPath: projectsURL.path),
           let data = try? Data(contentsOf: projectsURL),
           let decoded = try? decoder.decode([Project].self, from: data) {
            projects = decoded
        }

        let createdAt = (manifest["createdAt"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()

        let apply: () -> ConnectsChatTransferSummary = {
            ProjectStore.shared.mergeImportedProjects(projects)
            let merge = ConversationStore.shared.mergeImportedConversations(conversations)
            return ConnectsChatTransferSummary(
                createdAt: createdAt,
                conversationCount: conversations.count,
                projectCount: projects.count,
                mergedCount: merge.replaced,
                addedCount: merge.added
            )
        }
        if Thread.isMainThread {
            return apply()
        }
        return DispatchQueue.main.sync(execute: apply)
    }

    private static func export(conversations: [Conversation], to archiveURL: URL) throws -> ConnectsChatTransferSummary {
        let staging = try BackupBundleHelper.temporaryFolder(prefix: "connects-chat-export")
        defer { BackupBundleHelper.removeIfExists(staging) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let conversationsData = try encoder.encode(conversations)
        try conversationsData.write(
            to: staging.appendingPathComponent("conversations.json"),
            options: .atomic
        )

        let projectIDs = Set(conversations.compactMap(\.projectID))
        let projects = ProjectStore.shared.projects(withIDs: projectIDs)
        let projectsData = try encoder.encode(projects)
        try projectsData.write(
            to: staging.appendingPathComponent("projects.json"),
            options: .atomic
        )

        let createdAt = Date()
        let manifest: [String: Any] = [
            "format": formatID,
            "version": formatVersion,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "conversationCount": conversations.count,
            "projectCount": projects.count,
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(
            to: staging.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        BackupBundleHelper.removeIfExists(archiveURL)
        try SimpleZip.zip(directory: staging, to: archiveURL)

        return ConnectsChatTransferSummary(
            createdAt: createdAt,
            conversationCount: conversations.count,
            projectCount: projects.count,
            mergedCount: 0,
            addedCount: 0
        )
    }

    private static func readManifest(in folder: URL) throws -> [String: Any] {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ConnectsChatTransferError.invalidManifest
        }
        let data = try Data(contentsOf: manifestURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == formatID,
              let version = object["version"] as? Int,
              version <= formatVersion else {
            throw ConnectsChatTransferError.invalidManifest
        }
        return object
    }
}
