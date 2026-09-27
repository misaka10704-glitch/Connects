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
    /// `reasoning_effort: low|high|max` — Kimi K3 (user-selectable; app default low)
    case reasoningEffort
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

    /// Current DeepSeek Flash API id (`deepseek-flash` → V4.1-Flash, native multimodal).
    static let deepseekV41Flash = AIModelOption(
        provider: .deepseek, modelId: "deepseek-flash", displayName: "DeepSeek V4.1 Flash",
        baseURL: "https://api.deepseek.com", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )
    /// Legacy id; currently routed to V4.1-Flash.
    static let deepseekV4Flash = AIModelOption(
        provider: .deepseek, modelId: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash",
        baseURL: "https://api.deepseek.com", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )
    static let deepseekV4Pro = AIModelOption(
        provider: .deepseek, modelId: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro",
        baseURL: "https://api.deepseek.com", supportsVision: false,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    static let kimiK3 = AIModelOption(
        provider: .kimi, modelId: "kimi-k3", displayName: "Kimi K3",
        baseURL: "https://api.moonshot.cn/v1", supportsVision: true,
        supportsThinkingToggle: false, forcesThinking: true, thinkingStyle: .reasoningEffort
    )

    static let kimi26 = AIModelOption(
        provider: .kimi, modelId: "kimi-k2.6", displayName: "Kimi K2.6",
        baseURL: "https://api.moonshot.cn/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// Fast multimodal pass for image / PDF-screenshot transcription (not a chat picker default).
    static let kimiK25Vision = AIModelOption(
        provider: .kimi, modelId: "kimi-k2.5", displayName: "Kimi K2.5 Vision",
        baseURL: "https://api.moonshot.cn/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// Kimi K2.7 Code — forces thinking (API rejects disabled).
    static let kimiK27 = AIModelOption(
        provider: .kimi, modelId: "kimi-k2.7-code", displayName: "Kimi K2.7",
        baseURL: "https://api.moonshot.cn/v1", supportsVision: true,
        supportsThinkingToggle: false, forcesThinking: true, thinkingStyle: .thinkingType
    )

    /// Same weights as K2.7 Code, higher throughput serving tier.
    static let kimiK27Highspeed = AIModelOption(
        provider: .kimi, modelId: "kimi-k2.7-code-highspeed", displayName: "Kimi K2.7",
        baseURL: "https://api.moonshot.cn/v1", supportsVision: true,
        supportsThinkingToggle: false, forcesThinking: true, thinkingStyle: .thinkingType
    )

    static let qwen38Max = AIModelOption(
        provider: .qwen, modelId: "qwen3.8-max", displayName: "Qwen 3.8 Max",
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .enableThinking
    )

    static let qwen38Flash = AIModelOption(
        provider: .qwen, modelId: "qwen3.8-flash", displayName: "Qwen 3.8 Flash",
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .enableThinking
    )

    static let qwen37Plus = AIModelOption(
        provider: .qwen, modelId: "qwen3.7-plus", displayName: "Qwen 3.7 Plus",
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .enableThinking
    )

    /// 百炼高速档 — 替代 qwen-turbo，低延迟日常对话。
    static let qwen37Flash = AIModelOption(
        provider: .qwen, modelId: "qwen3.7-flash", displayName: "Qwen 3.7 Flash",
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .enableThinking
    )

    /// 智谱旗舰：强制思考；文本为主。
    static let glm53 = AIModelOption(
        provider: .zhipu, modelId: "glm-5.3", displayName: "GLM-5.3",
        baseURL: "https://open.bigmodel.cn/api/paas/v4", supportsVision: false,
        supportsThinkingToggle: false, forcesThinking: true, thinkingStyle: .thinkingType
    )

    /// 智谱原生多模态高速档。
    static let glm53Flash = AIModelOption(
        provider: .zhipu, modelId: "glm-5.3-flash", displayName: "GLM-5.3 Flash",
        baseURL: "https://open.bigmodel.cn/api/paas/v4", supportsVision: true,
        supportsThinkingToggle: false, forcesThinking: true, thinkingStyle: .thinkingType
    )

    /// 智谱旗舰：推理强，OpenAI 兼容，思考开关与 DeepSeek 同形。
    static let glm52 = AIModelOption(
        provider: .zhipu, modelId: "glm-5.2", displayName: "GLM-5.2",
        baseURL: "https://open.bigmodel.cn/api/paas/v4", supportsVision: false,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 智谱高速档 — 低延迟、高吞吐，适合高频 QA。
    static let glm47Flash = AIModelOption(
        provider: .zhipu, modelId: "glm-4.7-flash", displayName: "GLM-4.7 Flash",
        baseURL: "https://open.bigmodel.cn/api/paas/v4", supportsVision: false,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 豆包旗舰：中文对话强；若控制台用接入点，在设置填 `ep-…`。
    static let doubaoSeed16 = AIModelOption(
        provider: .doubao, modelId: "doubao-seed-1-6-251015", displayName: "Doubao Seed 1.6",
        baseURL: "https://ark.cn-beijing.volces.com/api/v3", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 豆包 2.0 Mini — 速度与成本优先的高速档。
    static let doubaoSeed2Mini = AIModelOption(
        provider: .doubao, modelId: "doubao-seed-2.0-mini-260215", displayName: "Doubao 2.0 Mini",
        baseURL: "https://ark.cn-beijing.volces.com/api/v3", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    static let all: [AIModelOption] = [
        .deepseekV41Flash, .deepseekV4Flash, .deepseekV4Pro,
        .kimiK27Highspeed, .kimiK3, .kimi26, .kimiK27,
        .qwen38Flash, .qwen38Max, .qwen37Flash, .qwen37Plus,
        .glm53Flash, .glm53, .glm47Flash, .glm52,
        .doubaoSeed2Mini, .doubaoSeed16
    ]

    static let defaultEnabled: [AIModelOption] = [
        .deepseekV41Flash, .deepseekV4Pro,
        .kimiK27Highspeed, .kimiK3,
        .qwen38Flash, .qwen38Max,
        .glm53Flash, .glm53,
        .doubaoSeed2Mini, .doubaoSeed16
    ]

    static let unsupportedImageSendMessage = "该模型不支持上传图片"

    static var visible: [AIModelOption] {
        SettingsManager.shared.ensureModelCatalogSynced()
        let enabled = SettingsManager.shared.enabledModelIDs
        let filtered = all.filter { enabled.contains($0.stableID) }
        return filtered.isEmpty ? defaultEnabled : filtered
    }

    static var preferredVision: AIModelOption {
        preferredImageTranscription
    }

    /// Default model for PDF screenshots / user uploads → durable text (fast).
    static var preferredImageTranscription: AIModelOption { .kimiK25Vision }

    static func option(stableID: String) -> AIModelOption? {
        if stableID == kimiK25Vision.stableID { return kimiK25Vision }
        return all.first { $0.stableID == stableID }
    }
}
