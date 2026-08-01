import Foundation

struct StudyWorkspace: Codable, Equatable {
    let id: String
    var title: String
    var isDefault: Bool
    /// Security-scoped bookmark for external folders; nil for default / relative Documents paths.
    var rootBookmarkData: Data?
    /// Path relative to App Documents (e.g. `Connects`, `Connects/MyProject`). Nil when using bookmark/absolute path.
    var relativePath: String?
    /// Absolute folder path fallback when a directory bookmark cannot be created
    /// (common after opening a single file — only the file is security-scoped).
    var absoluteRootPath: String?
    var documentIDs: [String]
    var createdAt: Date
    var updatedAt: Date

    static let defaultID = "workspace-default"

    static func makeDefault() -> StudyWorkspace {
        StudyWorkspace(
            id: defaultID,
            title: "Connects",
            isDefault: true,
            rootBookmarkData: nil,
            relativePath: "Connects",
            absoluteRootPath: nil,
            documentIDs: [],
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

extension Notification.Name {
    static let studyWorkspacesDidUpdate = Notification.Name("ConnectsStudyWorkspacesDidUpdate")
}
