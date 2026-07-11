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
    /// Kimi K2.7 Code: thinking cannot be disabled (API errors if type=disabled).
    let forcesThinking: Bool

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

    /// Effective thinking for this request (forced models ignore the setting).
    var thinkingActive: Bool {
        if forcesThinking { return true }
        return supportsThinkingToggle && SettingsManager.shared.thinkingEnabled
    }

    static let deepseekV4Flash = AIModelOption(
        provider: .deepseek,
        modelId: "deepseek-v4-flash",
        displayName: "DeepSeek V4 Flash",
        baseURL: "https://api.deepseek.com",
        supportsVision: false,
        supportsThinkingToggle: true,
        forcesThinking: false
    )

    static let deepseekV4Pro = AIModelOption(
        provider: .deepseek,
        modelId: "deepseek-v4-pro",
        displayName: "DeepSeek V4 Pro",
        baseURL: "https://api.deepseek.com",
        supportsVision: false,
        supportsThinkingToggle: true,
        forcesThinking: false
    )

    static let kimi26 = AIModelOption(
        provider: .kimi,
        modelId: "kimi-k2.6",
        displayName: "Kimi K2.6",
        // Prefer CN host as default; settings can flip to .ai (intl keys / proxy).
        baseURL: "https://api.moonshot.cn/v1",
        supportsVision: true,
        supportsThinkingToggle: true,
        forcesThinking: false
    )

    /// Official coding model (thinking always on).
    static let kimi27 = AIModelOption(
        provider: .kimi,
        modelId: "kimi-k2.7-code",
        displayName: "Kimi K2.7",
        baseURL: "https://api.moonshot.cn/v1",
        supportsVision: true,
        supportsThinkingToggle: false,
        forcesThinking: true
    )

    /// HighSpeed / Fast variant of K2.7 Code (~180–260 tok/s).
    static let kimi27Fast = AIModelOption(
        provider: .kimi,
        modelId: "kimi-k2.7-code-highspeed",
        displayName: "Kimi K2.7 Fast",
        baseURL: "https://api.moonshot.cn/v1",
        supportsVision: true,
        supportsThinkingToggle: false,
        forcesThinking: true
    )

    static let all: [AIModelOption] = [
        .deepseekV4Flash, .deepseekV4Pro,
        .kimi26, .kimi27, .kimi27Fast
    ]

    static var preferredVision: AIModelOption {
        all.first(where: { $0.supportsVision }) ?? .kimi26
    }
}
