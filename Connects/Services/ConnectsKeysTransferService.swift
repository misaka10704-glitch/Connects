import Foundation

enum ConnectsKeysTransferError: LocalizedError {
    case invalidArchive
    case invalidManifest
    case invalidPreferences

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "不是有效的 Connects Key 设置包。"
        case .invalidManifest: return "Key 设置包清单无效或版本不兼容。"
        case .invalidPreferences: return "Key 设置包中的偏好无法读取。"
        }
    }
}

struct ConnectsKeysTransferSummary: Equatable {
    let createdAt: Date
    let keyCount: Int
    let includesPreferences: Bool
}

enum ConnectsKeysTransferService {
    static let formatID = "connects-keys"
    static let formatVersion = 1
    static let fileExtension = "connectskeys"
    private static let preferencesPrefix = "connects_"

    static func export(to archiveURL: URL) throws -> ConnectsKeysTransferSummary {
        let staging = try BackupBundleHelper.temporaryFolder(prefix: "connects-keys-export")
        defer { BackupBundleHelper.removeIfExists(staging) }

        try BackupBundleHelper.exportUserDefaults(
            prefix: preferencesPrefix,
            to: staging.appendingPathComponent("preferences.plist")
        )

        let snapshot = KeychainHelper.exportSnapshot()
        let keychainData = try JSONSerialization.data(
            withJSONObject: snapshot,
            options: [.prettyPrinted, .sortedKeys]
        )
        try keychainData.write(
            to: staging.appendingPathComponent("keychain.json"),
            options: .atomic
        )

        let createdAt = Date()
        let manifest: [String: Any] = [
            "format": formatID,
            "version": formatVersion,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "keyCount": snapshot.count,
            "includesPreferences": true,
            "includesKeychain": true,
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

        return ConnectsKeysTransferSummary(
            createdAt: createdAt,
            keyCount: snapshot.count,
            includesPreferences: true
        )
    }

    static func importPackage(from archiveURL: URL) throws -> ConnectsKeysTransferSummary {
        let staging = try BackupBundleHelper.temporaryFolder(prefix: "connects-keys-import")
        defer { BackupBundleHelper.removeIfExists(staging) }

        try SimpleZip.unzip(archiveURL: archiveURL, to: staging)
        let manifest = try readManifest(in: staging)

        let preferencesURL = staging.appendingPathComponent("preferences.plist")
        let hasPreferences = FileManager.default.fileExists(atPath: preferencesURL.path)

        var keychainSnapshot: [String: String] = [:]
        let keychainURL = staging.appendingPathComponent("keychain.json")
        if FileManager.default.fileExists(atPath: keychainURL.path),
           let object = try JSONSerialization.jsonObject(with: Data(contentsOf: keychainURL)) as? [String: String] {
            keychainSnapshot = object.filter {
                !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        let createdAt = (manifest["createdAt"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()

        let apply: () throws -> ConnectsKeysTransferSummary = {
            var includesPreferences = false
            if hasPreferences {
                do {
                    try BackupBundleHelper.importUserDefaults(from: preferencesURL)
                    includesPreferences = true
                } catch {
                    throw ConnectsKeysTransferError.invalidPreferences
                }
            }
            KeychainHelper.importSnapshot(keychainSnapshot)
            ProjectStore.shared.reloadAfterBackupImport()
            NotificationCenter.default.post(name: .themeDidChange, object: nil)
            NotificationCenter.default.post(name: .visibleModelsDidChange, object: nil)
            return ConnectsKeysTransferSummary(
                createdAt: createdAt,
                keyCount: keychainSnapshot.count,
                includesPreferences: includesPreferences
            )
        }
        if Thread.isMainThread {
            return try apply()
        }
        return try DispatchQueue.main.sync(execute: apply)
    }

    private static func readManifest(in folder: URL) throws -> [String: Any] {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ConnectsKeysTransferError.invalidManifest
        }
        let data = try Data(contentsOf: manifestURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == formatID,
              let version = object["version"] as? Int,
              version <= formatVersion else {
            throw ConnectsKeysTransferError.invalidManifest
        }
        return object
    }
}
