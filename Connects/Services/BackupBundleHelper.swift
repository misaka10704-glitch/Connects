import Foundation

enum BackupBundleHelper {
    static func temporaryFolder(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeIfExists(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func copyDirectory(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.copyItem(at: source, to: destination)
    }

    static func exportUserDefaults(prefix: String, to url: URL) throws {
        var values: [String: Any] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(prefix) {
            values[key] = value
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .binary,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func importUserDefaults(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let values = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw ConnectsBackupError.invalidPreferences
        }
        for (key, value) in values {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}
