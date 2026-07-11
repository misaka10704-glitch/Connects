import Foundation

enum AIProvider: String, Codable, CaseIterable {
    case deepseek
    case kimi

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi"
        }
    }
}

struct AIModelOption: Equatable {
    let provider: AIProvider
    let modelId: String
    let displayName: String
    let baseURL: String
    let supportsVision: Bool
    /// Models that honor `thinking: {type: enabled|disabled}` in the request body.
    let supportsThinkingToggle: Bool

    var chatCompletionsURL: String {
        var base = baseURL
        if provider == .kimi {
            // Explicit setting always wins
            base = SettingsManager.shared.kimiUseChinaEndpoint
                ? "https://api.moonshot.cn/v1"
                : "https://api.moonshot.ai/v1"
        }
        if base.hasSuffix("/chat/completions") { return base }
        return base + "/chat/completions"
    }

    static let deepseekV4Flash = AIModelOption(
        provider: .deepseek,
        modelId: "deepseek-v4-flash",
        displayName: "DeepSeek V4 Flash",
        baseURL: "https://api.deepseek.com",
        supportsVision: false,
        supportsThinkingToggle: true
    )

    static let deepseekV4Pro = AIModelOption(
        provider: .deepseek,
        modelId: "deepseek-v4-pro",
        displayName: "DeepSeek V4 Pro",
        baseURL: "https://api.deepseek.com",
        supportsVision: false,
        supportsThinkingToggle: true
    )

    static let kimi26 = AIModelOption(
        provider: .kimi,
        modelId: "kimi-k2.6",
        displayName: "Kimi K2.6",
        // Prefer CN host as default; settings can flip to .ai (intl keys / proxy).
        baseURL: "https://api.moonshot.cn/v1",
        supportsVision: true,
        supportsThinkingToggle: true
    )

    static let all: [AIModelOption] = [.deepseekV4Flash, .deepseekV4Pro, .kimi26]
}
