import Foundation

enum AIProvider: String, Codable, CaseIterable {
    case deepseek
    case kimi
    case qwen
    case zhipu
    case doubao
    case minimax
    case stepfun
    case hunyuan
    case yi
    case siliconflow
    /// User-defined OpenAI-compatible endpoint (BYOK).
    case custom

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi"
        case .qwen: return "Qwen"
        case .zhipu: return "智谱 GLM"
        case .doubao: return "豆包"
        case .minimax: return "MiniMax"
        case .stepfun: return "阶跃星辰"
        case .hunyuan: return "腾讯混元"
        case .yi: return "零一万物"
        case .siliconflow: return "硅基流动"
        case .custom: return L("自定义服务", "Custom")
        }
    }

    /// New catalog models auto-enable on upgrade only for curated providers —
    /// freshly added vendors stay opt-in via「显示的模型」so the picker doesn't
    /// flood with models the user has no key for.
    var autoEnablesNewModels: Bool {
        switch self {
        case .minimax, .stepfun, .hunyuan, .yi, .siliconflow:
            return false
        default:
            return true
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
    /// Set only for BYOK models — identifies which `BYOKProvider` owns this option.
    let customProviderID: String?

    init(provider: AIProvider, modelId: String, displayName: String, baseURL: String,
         supportsVision: Bool, supportsThinkingToggle: Bool, forcesThinking: Bool,
         thinkingStyle: ThinkingPayloadStyle, customProviderID: String? = nil) {
        self.provider = provider
        self.modelId = modelId
        self.displayName = displayName
        self.baseURL = baseURL
        self.supportsVision = supportsVision
        self.supportsThinkingToggle = supportsThinkingToggle
        self.forcesThinking = forcesThinking
        self.thinkingStyle = thinkingStyle
        self.customProviderID = customProviderID
    }

    var stableID: String {
        if provider == .custom, let pid = customProviderID {
            return "custom|\(pid)|\(modelId)"
        }
        return "\(provider.rawValue)|\(modelId)"
    }

    /// Provider label for errors/empty states — BYOK shows the profile name.
    var providerDisplayName: String {
        if provider == .custom, let pid = customProviderID,
           let profile = SettingsManager.shared.customProvider(id: pid) {
            return profile.displayName
        }
        return provider.displayName
    }

    /// Compact label for the composer capsule (vendor prefix dropped when long).
    var chipName: String {
        displayName
            .replacingOccurrences(of: "DeepSeek ", with: "")
            .replacingOccurrences(of: " Vision", with: "")
            .replacingOccurrences(of: " Seed", with: "")
    }

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

    /// 新一代 Pro — 推理旗舰，文本为主。
    static let deepseekV42Pro = AIModelOption(
        provider: .deepseek, modelId: "deepseek-v4.2-pro", displayName: "DeepSeek V4.2 Pro",
        baseURL: "https://api.deepseek.com", supportsVision: false,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )
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

    /// K3.1 — 新一代旗舰，同 K3 的 reasoning_effort 档位协议。
    static let kimiK31 = AIModelOption(
        provider: .kimi, modelId: "kimi-k3.1", displayName: "Kimi K3.1",
        baseURL: "https://api.moonshot.cn/v1", supportsVision: true,
        supportsThinkingToggle: false, forcesThinking: true, thinkingStyle: .reasoningEffort
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

    /// 3.9 系列 — 新一代旗舰/高速档。
    static let qwen39Max = AIModelOption(
        provider: .qwen, modelId: "qwen3.9-max", displayName: "Qwen 3.9 Max",
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .enableThinking
    )

    static let qwen39Flash = AIModelOption(
        provider: .qwen, modelId: "qwen3.9-flash", displayName: "Qwen 3.9 Flash",
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .enableThinking
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

    /// 智谱 5.4 旗舰 — 新一代，思考可关。
    static let glm54 = AIModelOption(
        provider: .zhipu, modelId: "glm-5.4", displayName: "GLM-5.4",
        baseURL: "https://open.bigmodel.cn/api/paas/v4", supportsVision: false,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 智谱 5.4 高速档 — 原生多模态。
    static let glm54Flash = AIModelOption(
        provider: .zhipu, modelId: "glm-5.4-flash", displayName: "GLM-5.4 Flash",
        baseURL: "https://open.bigmodel.cn/api/paas/v4", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
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

    /// 豆包 Seed 2.1 — 新一代旗舰；接入点 `ep-…` 覆盖同上。
    static let doubaoSeed21 = AIModelOption(
        provider: .doubao, modelId: "doubao-seed-2.1-260315", displayName: "Doubao Seed 2.1",
        baseURL: "https://ark.cn-beijing.volces.com/api/v3", supportsVision: true,
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

    /// MiniMax M3 — 新一代旗舰。
    static let minimaxM3 = AIModelOption(
        provider: .minimax, modelId: "MiniMax-M3", displayName: "MiniMax M3",
        baseURL: "https://api.minimaxi.com/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// MiniMax 旗舰 — 长程推理/Agent 强项，文本为主。
    static let minimaxM25 = AIModelOption(
        provider: .minimax, modelId: "MiniMax-M2.5", displayName: "MiniMax M2.5",
        baseURL: "https://api.minimaxi.com/v1", supportsVision: false,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// MiniMax 上代轻量档 — 低延迟日常对话。
    static let minimaxM2 = AIModelOption(
        provider: .minimax, modelId: "MiniMax-M2", displayName: "MiniMax M2",
        baseURL: "https://api.minimaxi.com/v1", supportsVision: false,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 阶跃 Step 4 — 新一代旗舰多模态。
    static let step4 = AIModelOption(
        provider: .stepfun, modelId: "step-4", displayName: "Step 4",
        baseURL: "https://api.stepfun.com/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 阶跃星辰旗舰 — 原生多模态。
    static let step35 = AIModelOption(
        provider: .stepfun, modelId: "step-3.5", displayName: "Step 3.5",
        baseURL: "https://api.stepfun.com/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 阶跃高速档 — 低延迟问答。
    static let step3Flash = AIModelOption(
        provider: .stepfun, modelId: "step-3-flash", displayName: "Step 3 Flash",
        baseURL: "https://api.stepfun.com/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 混元 T3 — 新一代推理旗舰，强制思考。
    static let hunyuanT3 = AIModelOption(
        provider: .hunyuan, modelId: "hunyuan-t3", displayName: "Hunyuan T3",
        baseURL: "https://api.hunyuan.cloud.tencent.com/v1", supportsVision: false,
        supportsThinkingToggle: false, forcesThinking: true, thinkingStyle: .thinkingType
    )

    /// 混元旗舰推理 — T 系列强制思考。
    static let hunyuanT2 = AIModelOption(
        provider: .hunyuan, modelId: "hunyuan-t2", displayName: "Hunyuan T2",
        baseURL: "https://api.hunyuan.cloud.tencent.com/v1", supportsVision: false,
        supportsThinkingToggle: false, forcesThinking: true, thinkingStyle: .thinkingType
    )

    /// 混元高速档 — TurboS 大吞吐。
    static let hunyuanTurboS = AIModelOption(
        provider: .hunyuan, modelId: "hunyuan-turbos-latest", displayName: "Hunyuan TurboS",
        baseURL: "https://api.hunyuan.cloud.tencent.com/v1", supportsVision: false,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 零一 Yi 2.1 — 新一代旗舰多模态。
    static let yi21 = AIModelOption(
        provider: .yi, modelId: "yi-2.1", displayName: "Yi 2.1",
        baseURL: "https://api.lingyiwanwu.com/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 零一万物旗舰 — 多模态。
    static let yi20 = AIModelOption(
        provider: .yi, modelId: "yi-2.0", displayName: "Yi 2.0",
        baseURL: "https://api.lingyiwanwu.com/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 零一高速档 — Lightning 低延迟。
    static let yiLightning = AIModelOption(
        provider: .yi, modelId: "yi-lightning", displayName: "Yi Lightning",
        baseURL: "https://api.lingyiwanwu.com/v1", supportsVision: false,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 硅基流动聚合 — Kimi K3.1 权重。
    static let sfKimiK31 = AIModelOption(
        provider: .siliconflow, modelId: "moonshotai/Kimi-K3.1", displayName: "SF Kimi K3.1",
        baseURL: "https://api.siliconflow.cn/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 硅基流动聚合 — DeepSeek 新一代权重。
    static let sfDeepseekV42 = AIModelOption(
        provider: .siliconflow, modelId: "deepseek-ai/DeepSeek-V4.2", displayName: "SF DeepSeek V4.2",
        baseURL: "https://api.siliconflow.cn/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 硅基流动聚合 — DeepSeek 官方权重，按 token 计费。
    static let sfDeepseekV41 = AIModelOption(
        provider: .siliconflow, modelId: "deepseek-ai/DeepSeek-V4.1", displayName: "SF DeepSeek V4.1",
        baseURL: "https://api.siliconflow.cn/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    /// 硅基流动聚合 — Qwen 旗舰权重。
    static let sfQwen38Max = AIModelOption(
        provider: .siliconflow, modelId: "Qwen/Qwen3.8-Max", displayName: "SF Qwen 3.8 Max",
        baseURL: "https://api.siliconflow.cn/v1", supportsVision: true,
        supportsThinkingToggle: true, forcesThinking: false, thinkingStyle: .thinkingType
    )

    static let all: [AIModelOption] = [
        .deepseekV42Pro, .deepseekV41Flash, .deepseekV4Flash, .deepseekV4Pro,
        .kimiK31, .kimiK27Highspeed, .kimiK3, .kimi26, .kimiK27,
        .qwen39Flash, .qwen39Max, .qwen38Flash, .qwen38Max, .qwen37Flash, .qwen37Plus,
        .glm54Flash, .glm54, .glm53Flash, .glm53, .glm47Flash, .glm52,
        .doubaoSeed21, .doubaoSeed2Mini, .doubaoSeed16,
        .minimaxM3, .minimaxM25, .minimaxM2,
        .step4, .step35, .step3Flash,
        .hunyuanT3, .hunyuanT2, .hunyuanTurboS,
        .yi21, .yi20, .yiLightning,
        .sfKimiK31, .sfDeepseekV42, .sfDeepseekV41, .sfQwen38Max
    ]

    static let defaultEnabled: [AIModelOption] = [
        .deepseekV41Flash, .deepseekV42Pro,
        .kimiK27Highspeed, .kimiK31,
        .qwen39Flash, .qwen39Max,
        .glm54Flash, .glm54,
        .doubaoSeed2Mini, .doubaoSeed21
    ]

    static let unsupportedImageSendMessage = "该模型不支持上传图片"

    /// BYOK models generated from the user's custom providers.
    static var customModels: [AIModelOption] {
        SettingsManager.shared.customProviders.flatMap { profile in
            profile.modelIDs.map { mid in
                AIModelOption(
                    provider: .custom, modelId: mid, displayName: mid,
                    baseURL: profile.chatCompletionsURL, supportsVision: profile.supportsVision,
                    supportsThinkingToggle: false, forcesThinking: false,
                    thinkingStyle: .none, customProviderID: profile.id
                )
            }
        }
    }

    /// Full catalog: built-ins + BYOK models.
    static var catalog: [AIModelOption] { all + customModels }

    static var visible: [AIModelOption] {
        SettingsManager.shared.ensureModelCatalogSynced()
        let enabled = SettingsManager.shared.enabledModelIDs
        let filtered = catalog.filter { enabled.contains($0.stableID) }
        return filtered.isEmpty ? defaultEnabled : filtered
    }

    static var preferredVision: AIModelOption {
        preferredImageTranscription
    }

    /// Default model for PDF screenshots / user uploads → durable text (fast).
    static var preferredImageTranscription: AIModelOption { .kimiK25Vision }

    static func option(stableID: String) -> AIModelOption? {
        if stableID == kimiK25Vision.stableID { return kimiK25Vision }
        return catalog.first { $0.stableID == stableID }
    }
}
