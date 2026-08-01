import Foundation

/// On-device Documents layout used by Study workspaces (Files.app visible when sharing is on).
enum ConnectsPaths {
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Private app data (not shown in Files). Chat history lives here — UserDefaults is too small.
    static var applicationSupportURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Connects", isDirectory: true)
    }

    /// Default workspace root — appears under Files → On My iPad → Connects.
    static var connectsRootURL: URL {
        documentsURL.appendingPathComponent("Connects", isDirectory: true)
    }

    static var registryURL: URL {
        documentsURL.appendingPathComponent("ConnectsRegistry", isDirectory: true)
    }

    static var workspacesRegistryFileURL: URL {
        registryURL.appendingPathComponent("workspaces.json")
    }

    static var studyRootURL: URL {
        documentsURL.appendingPathComponent("ConnectsStudy", isDirectory: true)
    }

    /// Canonical chat persistence (atomic JSON). Survives rebuilds; avoids UserDefaults size traps.
    static var conversationsFileURL: URL {
        applicationSupportURL.appendingPathComponent("conversations_v2.json")
    }

    static var conversationsBackupFileURL: URL {
        applicationSupportURL.appendingPathComponent("conversations_v2.json.bak")
    }

    @discardableResult
    static func ensureDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func ensureAppFolders() {
        _ = ensureDirectory(applicationSupportURL)
        _ = ensureDirectory(connectsRootURL)
        _ = ensureDirectory(registryURL)
        _ = ensureDirectory(studyRootURL)
    }
}
