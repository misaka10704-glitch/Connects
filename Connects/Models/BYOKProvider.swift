import Foundation

/// User-defined OpenAI-compatible endpoint (BYOK). API key lives in Keychain
/// under `KeychainHelper.Keys.customAPIKey(id)`; this struct is persisted as
/// JSON in UserDefaults.
struct BYOKProvider: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// e.g. `https://api.openai.com/v1` — `/chat/completions` is appended when absent.
    var baseURL: String
    var modelIDs: [String]
    var supportsVision: Bool

    init(
        id: String = UUID().uuidString,
        name: String = "",
        baseURL: String = "",
        modelIDs: [String] = [],
        supportsVision: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.modelIDs = modelIDs
        self.supportsVision = supportsVision
    }

    /// Display name — falls back to the URL host when unnamed.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: baseURL)?.host() { return host }
        return L("自定义服务", "Custom provider")
    }

    /// `/v1/chat/completions`-ready URL built from the user's base URL.
    var chatCompletionsURL: String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.hasSuffix("/chat/completions") { return base }
        return base + "/chat/completions"
    }

    /// `GET {base}/models` — OpenAI-compatible model listing endpoint.
    var modelsListURL: String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.hasSuffix("/chat/completions") {
            return String(base.dropLast("/chat/completions".count)) + "/models"
        }
        return base + "/models"
    }

    /// Splits a comma/whitespace-separated model list into clean ids.
    static func parseModelIDs(_ raw: String) -> [String] {
        raw
            .components(separatedBy: CharacterSet(charactersIn: ",，\n\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func isValidBaseURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host() != nil else { return false }
        return true
    }
}
