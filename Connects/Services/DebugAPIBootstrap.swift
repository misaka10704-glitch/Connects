import Foundation

#if DEBUG
enum DebugAPIBootstrap {
    static func loadKimiKeyIfNeeded(logTag: String) {
        if !SettingsManager.shared.kimiAPIKey.isEmpty {
            print("\(logTag) using Kimi key from Keychain")
            return
        }
        if let key = ProcessInfo.processInfo.environment["CONNECTS_KIMI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            SettingsManager.auditKimiAPIKeyOverride = key
            print("\(logTag) using Kimi key from CONNECTS_KIMI_API_KEY")
        }
    }
}
#endif
