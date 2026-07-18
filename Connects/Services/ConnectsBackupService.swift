import Foundation

enum ConnectsBackupError: LocalizedError {
    case invalidArchive
    case invalidManifest
    case invalidPreferences

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "不是有效的 Connects 备份文件。"
        case .invalidManifest: return "备份清单无效或版本不兼容。"
        case .invalidPreferences: return "备份中的偏好设置无法读取。"
        }
    }
}

struct ConnectsBackupSummary: Equatable {
    let createdAt: Date
    let includesPreferences: Bool
    let includesKeychain: Bool
    let includesMemory: Bool
}

enum ConnectsBackupService {
    static let formatID = "connects-backup"
    static let formatVersion = 1
    static let fileExtension = "connectsbackup"
    private static let preferencesPrefix = "connects_"

    static func export(to archiveURL: URL) throws -> ConnectsBackupSummary {
        let staging = BackupBundleHelper.temporaryFolder(prefix: "connects-backup-export")
        defer { BackupBundleHelper.removeIfExists(staging) }

        try BackupBundleHelper.exportUserDefaults(
            prefix: preferencesPrefix,
            to: staging.appendingPathComponent("preferences.plist")
        )

        let keychainData = try JSONSerialization.data(
            withJSONObject: KeychainHelper.exportSnapshot(),
            options: [.prettyPrinted, .sortedKeys]
        )
        try keychainData.write(to: staging.appendingPathComponent("keychain.json"))

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let memorySource = documents.appendingPathComponent("ConnectsMemory", isDirectory: true)
        try BackupBundleHelper.copyDirectory(
            from: memorySource,
            to: staging.appendingPathComponent("ConnectsMemory", isDirectory: true)
        )

        let manifest: [String: Any] = [
            "format": formatID,
            "version": formatVersion,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "includesPreferences": true,
            "includesKeychain": true,
            "includesMemory": FileManager.default.fileExists(atPath: memorySource.path),
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))

        BackupBundleHelper.removeIfExists(archiveURL)
        try SimpleZip.zip(directory: staging, to: archiveURL)

        return ConnectsBackupSummary(
            createdAt: Date(),
            includesPreferences: true,
            includesKeychain: true,
            includesMemory: FileManager.default.fileExists(atPath: memorySource.path)
        )
    }

    static func importBackup(from archiveURL: URL) throws -> ConnectsBackupSummary {
        let staging = BackupBundleHelper.temporaryFolder(prefix: "connects-backup-import")
        defer { BackupBundleHelper.removeIfExists(staging) }

        try SimpleZip.unzip(archiveURL: archiveURL, to: staging)
        let manifest = try readManifest(in: staging)

        let preferencesURL = staging.appendingPathComponent("preferences.plist")
        if FileManager.default.fileExists(atPath: preferencesURL.path) {
            try BackupBundleHelper.importUserDefaults(from: preferencesURL)
        }

        let keychainURL = staging.appendingPathComponent("keychain.json")
        if FileManager.default.fileExists(atPath: keychainURL.path),
           let object = try JSONSerialization.jsonObject(with: Data(contentsOf: keychainURL)) as? [String: String] {
            KeychainHelper.importSnapshot(object)
        }

        let memorySource = staging.appendingPathComponent("ConnectsMemory", isDirectory: true)
        if FileManager.default.fileExists(atPath: memorySource.path) {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try BackupBundleHelper.copyDirectory(
                from: memorySource,
                to: documents.appendingPathComponent("ConnectsMemory", isDirectory: true)
            )
        }

        ConnectsBackupRestoreCoordinator.applyAfterImport()

        let createdAt = (manifest["createdAt"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()

        return ConnectsBackupSummary(
            createdAt: createdAt,
            includesPreferences: FileManager.default.fileExists(atPath: preferencesURL.path),
            includesKeychain: FileManager.default.fileExists(atPath: keychainURL.path),
            includesMemory: FileManager.default.fileExists(atPath: memorySource.path)
        )
    }

    private static func readManifest(in folder: URL) throws -> [String: Any] {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ConnectsBackupError.invalidManifest
        }
        let data = try Data(contentsOf: manifestURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == formatID,
              let version = object["version"] as? Int,
              version <= formatVersion else {
            throw ConnectsBackupError.invalidManifest
        }
        return object
    }
}

enum ConnectsBackupRestoreCoordinator {
    static func applyAfterImport() {
        ConversationStore.shared.reloadAfterBackupImport()
        AgentStore.shared.reloadAfterBackupImport()
        ProjectStore.shared.reloadAfterBackupImport()
        RenderCacheStore.clearAll()
        PlainMarkdown.clearCache()
        NotificationCenter.default.post(name: .memoryStoreDidUpdate, object: nil)
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }
}
