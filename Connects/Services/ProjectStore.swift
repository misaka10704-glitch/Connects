import Foundation

extension Notification.Name {
    static let projectsDidChange = Notification.Name("ConnectsProjectsDidChange")
}

final class ProjectStore {
    static let shared = ProjectStore()

    private let projectsKey = "connects_projects_v1"
    private(set) var projects: [Project] = []

    private init() { load() }

    var sortedProjects: [Project] {
        projects.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func project(id: String?) -> Project? {
        guard let id = id else { return nil }
        return projects.first { $0.id == id }
    }

    func upsert(_ project: Project) {
        var next = project
        next.name = String(next.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        next.colorPreset = max(0, min(19, next.colorPreset))
        next.updatedAt = Date()
        guard !next.name.isEmpty else { return }
        if let index = projects.firstIndex(where: { $0.id == next.id }) {
            projects[index] = next
        } else {
            next.sortOrder = (projects.map(\.sortOrder).max() ?? -1) + 1
            projects.append(next)
        }
        saveAndNotify()
    }

    func delete(id: String) {
        guard projects.contains(where: { $0.id == id }) else { return }
        projects.removeAll { $0.id == id }
        ConversationStore.shared.unassignProject(id: id)
        if ConversationStore.shared.selectedProjectID == id {
            ConversationStore.shared.setSelectedProjectID(nil)
        }
        saveAndNotify()
    }

    /// Persist list order after drag-reorder in project settings.
    func moveProject(from source: Int, to destination: Int) {
        var sorted = sortedProjects
        guard source >= 0, source < sorted.count,
              destination >= 0, destination < sorted.count,
              source != destination else { return }
        let item = sorted.remove(at: source)
        sorted.insert(item, at: destination)
        for (index, project) in sorted.enumerated() {
            guard let storageIndex = projects.firstIndex(where: { $0.id == project.id }) else { continue }
            projects[storageIndex].sortOrder = index
        }
        saveAndNotify()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: projectsKey),
              let decoded = try? JSONDecoder().decode([Project].self, from: data) else { return }
        projects = decoded
    }

    private func saveAndNotify() {
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: projectsKey)
        }
        NotificationCenter.default.post(name: .projectsDidChange, object: nil)
    }

    func reloadAfterBackupImport() {
        load()
        NotificationCenter.default.post(name: .projectsDidChange, object: nil)
    }
}
