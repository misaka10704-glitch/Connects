import Foundation

extension Notification.Name {
    static let agentsDidChange = Notification.Name("ConnectsAgentsDidChange")
}

final class AgentStore {
    static let shared = AgentStore()

    private let agentsKey = "connects_agents_v1"
    private let migrationKey = "connects_agents_user_rules_migrated_v1"
    private(set) var agents: [CustomAgent] = []

    private init() {
        load()
        migrateLegacyUserRulesIfNeeded()
    }

    var enabledAgents: [CustomAgent] {
        agents.filter(\.isEnabled).sorted { $0.updatedAt > $1.updatedAt }
    }

    func agent(id: String?) -> CustomAgent? {
        guard let id = id else { return nil }
        return agents.first { $0.id == id && $0.isEnabled }
    }

    func upsert(_ agent: CustomAgent) {
        var next = agent
        next.name = String(next.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        next.userRequirements = String(next.userRequirements.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000))
        next.polishedPrompt = String(next.polishedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_400))
        next.iconPreset = max(0, min(19, next.iconPreset))
        next.updatedAt = Date()
        guard !next.name.isEmpty, !next.polishedPrompt.isEmpty else { return }
        if let index = agents.firstIndex(where: { $0.id == next.id }) {
            agents[index] = next
        } else {
            agents.append(next)
        }
        saveAndNotify()
    }

    func delete(id: String) {
        guard agents.contains(where: { $0.id == id }) else { return }
        agents.removeAll { $0.id == id }
        saveAndNotify()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].isEnabled = enabled
        agents[index].updatedAt = Date()
        saveAndNotify()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: agentsKey),
              let decoded = try? JSONDecoder().decode([CustomAgent].self, from: data) else { return }
        agents = decoded
    }

    private func saveAndNotify() {
        if let data = try? JSONEncoder().encode(agents) {
            UserDefaults.standard.set(data, forKey: agentsKey)
        }
        NotificationCenter.default.post(name: .agentsDidChange, object: nil)
    }

    func reloadAfterBackupImport() {
        load()
        NotificationCenter.default.post(name: .agentsDidChange, object: nil)
    }

    private func migrateLegacyUserRulesIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        defer {
            UserDefaults.standard.set(true, forKey: migrationKey)
            SettingsManager.shared.userRulesEnabled = false
            SettingsManager.shared.userRules = ""
        }
        guard SettingsManager.shared.userRulesEnabled else { return }
        let rules = SettingsManager.shared.userRules.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rules.isEmpty else { return }
        agents.append(CustomAgent(
            name: "默认智能体",
            userRequirements: rules,
            polishedPrompt: rules
        ))
        saveAndNotify()
    }
}
