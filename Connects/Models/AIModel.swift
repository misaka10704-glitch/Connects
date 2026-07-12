import Foundation

enum AIProvider: String, Codable, CaseIterable {
    case deepseek
    case kimi
    case qwen
    case zhipu
    case doubao

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi"
        case .qwen: return "Qwen"
        case .zhipu: return "智谱 GLM"
        case .doubao: return "豆包"
        }
    }
}

enum ThinkingPayloadStyle {
    case none
    /// `thinking: { type: enabled|disabled }`
    case thinkingType
    /// `enable_thinking: bool` — DashScope Qwen
    case enableThinking
}

struct AIModelOption: Equatable {
    let provider: AIProvider
    let modelId: String
    let displayName: String
    let baseURL: String
    let supportsVision: Bool
    let supportsThinkingToggle: Bool
    let forcesThinking: Bool
    let thinkingStyle: ThinkingPayloadStyle

    var stableID: String { "\(provider.rawValue)|\(modelId)" }

    /// 豆包可在设置里填方舟接入点 `ep-…` 覆盖 model id。
    var resolvedModelId: String {
        if provider == .doubao {
            let ep = SettingsManager.shared.doubaoEndpointID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !ep.isEmpty { return ep }
        }
        return modelId
    }

    var chatCompletionsURL: String {
        var base = baseURL
        switch provider {
        case .kimi:
            base = SettingsManager.shared.kimiUseChinaEndpoint
                ? "https://api.moonshot.cn/v1"
                : "https://api.moonshot.ai/v1"
        case .qwen:
            base = SettingsManager.shared.qwenUseChinaEndpoint
                ? "https://dashscope.aliyuncs.com/compatible-mode/v1"
                : "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        default:
            break
        }
        if base.hasSuffix("/chat/completions") { return base }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
    }

    var thinkingActive: Bool {
        if forcesThinking { return true }
        return supportsThinkingToggle && SettingsManager.shared.thinkingEnabled
    }

    static let deepseekV4Flash = AIModelOption(
        provider: .deepseek, modelId: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash",
        baseURL: "https://api.deepseek.com", supportsVision: false,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )
    static let deepseekV4Pro = AIModelOption(
        provider: .deepseek, modelId: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro",
        baseURL: "https://api.deepseek.com", supportsVision: false,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    static let kimi26 = AIModelOption(
        provider: .kimi, modelId: "kimi-k2.6", displayName: "Kimi K2.6",
        baseURL: "https://api.moonshot.cn/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    static let qwen37Plus = AIModelOption(
        provider: .qwen, modelId: "qwen3.7-plus", displayName: "Qwen 3.7 Plus",
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .enableThinking
    )

    /// 智谱旗舰：推理强，OpenAI 兼容，思考开关与 DeepSeek 同形。
    static let glm52 = AIModelOption(
        provider: .zhipu, modelId: "glm-5.2", displayName: "GLM-5.2",
        baseURL: "https://open.bigmodel.cn/api/paas/v4", supportsVision: false,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 豆包旗舰：中文对话强；若控制台用接入点，在设置填 `ep-…`。
    static let doubaoSeed16 = AIModelOption(
        provider: .doubao, modelId: "doubao-seed-1-6-251015", displayName: "Doubao Seed 1.6",
        baseURL: "https://ark.cn-beijing.volces.com/api/v3", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    static let all: [AIModelOption] = [
        .deepseekV4Flash, .deepseekV4Pro,
        .kimi26,
        .qwen37Plus,
        .glm52,
        .doubaoSeed16
    ]

    static let defaultEnabled: [AIModelOption] = [
        .deepseekV4Flash, .deepseekV4Pro, .kimi26, .qwen37Plus, .glm52, .doubaoSeed16
    ]

    static var visible: [AIModelOption] {
        SettingsManager.shared.ensureModelCatalogSynced()
        let enabled = SettingsManager.shared.enabledModelIDs
        let filtered = all.filter { enabled.contains($0.stableID) }
        return filtered.isEmpty ? defaultEnabled : filtered
    }

    static var preferredVision: AIModelOption {
        if let v = visible.first(where: { $0.supportsVision }) { return v }
        return all.first(where: { $0.supportsVision }) ?? .kimi26
    }

    static func option(stableID: String) -> AIModelOption? {
        all.first { $0.stableID == stableID }
    }
}
