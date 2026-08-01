import Foundation

struct StudyWorkspace: Codable, Equatable {
    let id: String
    var title: String
    var isDefault: Bool
    /// Security-scoped bookmark for external folders; nil for default / relative Documents paths.
    var rootBookmarkData: Data?
    /// Path relative to App Documents (e.g. `Connects`, `Connects/MyProject`). Nil when using bookmark only.
    var relativePath: String?
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
            documentIDs: [],
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

extension Notification.Name {
    static let studyWorkspacesDidUpdate = Notification.Name("ConnectsStudyWorkspacesDidUpdate")
}
