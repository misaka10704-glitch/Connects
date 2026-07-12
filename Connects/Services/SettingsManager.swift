import Foundation

extension Notification.Name {
    static let chatFontSizeDidChange = Notification.Name("ConnectsChatFontSizeDidChange")
    static let visibleModelsDidChange = Notification.Name("ConnectsVisibleModelsDidChange")
}

final class SettingsManager {
    static let shared = SettingsManager()

    private let enabledModelsKey = "connects_enabled_models"
    private let knownModelsKey = "connects_known_models"

    var deepseekAPIKey: String {
        get { KeychainHelper.load(key: KeychainHelper.Keys.deepseekAPIKey) ?? "" }
        set { persist(key: KeychainHelper.Keys.deepseekAPIKey, value: Self.sanitizeKey(newValue)) }
    }

    var kimiAPIKey: String {
        get { KeychainHelper.load(key: KeychainHelper.Keys.kimiAPIKey) ?? "" }
        set { persist(key: KeychainHelper.Keys.kimiAPIKey, value: Self.sanitizeKey(newValue)) }
    }

    var dashscopeAPIKey: String {
        get { KeychainHelper.load(key: KeychainHelper.Keys.dashscopeAPIKey) ?? "" }
        set { persist(key: KeychainHelper.Keys.dashscopeAPIKey, value: Self.sanitizeKey(newValue)) }
    }

    var zhipuAPIKey: String {
        get { KeychainHelper.load(key: KeychainHelper.Keys.zhipuAPIKey) ?? "" }
        set { persist(key: KeychainHelper.Keys.zhipuAPIKey, value: Self.sanitizeKey(newValue)) }
    }

    var doubaoAPIKey: String {
        get { KeychainHelper.load(key: KeychainHelper.Keys.doubaoAPIKey) ?? "" }
        set { persist(key: KeychainHelper.Keys.doubaoAPIKey, value: Self.sanitizeKey(newValue)) }
    }

    /// 火山方舟接入点 ID（`ep-…`）。填写后覆盖豆包默认 model id。
    var doubaoEndpointID: String {
        get { UserDefaults.standard.string(forKey: "connects_doubao_endpoint") ?? "" }
        set {
            UserDefaults.standard.set(
                newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: "connects_doubao_endpoint"
            )
        }
    }

    var kimiUseChinaEndpoint: Bool {
        get {
            if UserDefaults.standard.object(forKey: "connects_kimi_cn") == nil { return true }
            return UserDefaults.standard.bool(forKey: "connects_kimi_cn")
        }
        set { UserDefaults.standard.set(newValue, forKey: "connects_kimi_cn") }
    }

    var qwenUseChinaEndpoint: Bool {
        get {
            if UserDefaults.standard.object(forKey: "connects_qwen_cn") == nil { return true }
            return UserDefaults.standard.bool(forKey: "connects_qwen_cn")
        }
        set { UserDefaults.standard.set(newValue, forKey: "connects_qwen_cn") }
    }

    var thinkingEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "connects_thinking") == nil { return true }
            return UserDefaults.standard.bool(forKey: "connects_thinking")
        }
        set { UserDefaults.standard.set(newValue, forKey: "connects_thinking") }
    }

    var webSearchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "connects_web_search") }
        set { UserDefaults.standard.set(newValue, forKey: "connects_web_search") }
    }

    var appearanceMode: AppearanceMode {
        get { ThemeManager.shared.mode }
        set { ThemeManager.shared.mode = newValue }
    }

    var chatFontSizeIndex: Int {
        get {
            let v = UserDefaults.standard.object(forKey: "connects_font_size") as? Int
            return min(2, max(0, v ?? 1))
        }
        set {
            UserDefaults.standard.set(min(2, max(0, newValue)), forKey: "connects_font_size")
            NotificationCenter.default.post(name: .chatFontSizeDidChange, object: nil)
        }
    }

    var chatBodyFontSize: CGFloat {
        switch chatFontSizeIndex {
        case 0: return 15
        case 2: return 18
        default: return 16.5
        }
    }

    var chatThinkingFontSize: CGFloat {
        chatBodyFontSize - 1.5
    }

    var enabledModelIDs: Set<String> {
        get {
            ensureModelCatalogSynced()
            if let arr = UserDefaults.standard.array(forKey: enabledModelsKey) as? [String], !arr.isEmpty {
                return Set(arr)
            }
            return Set(AIModelOption.defaultEnabled.map { $0.stableID })
        }
        set {
            var next = newValue
            if next.isEmpty, let first = AIModelOption.defaultEnabled.first {
                next = [first.stableID]
            }
            UserDefaults.standard.set(Array(next), forKey: enabledModelsKey)
            NotificationCenter.default.post(name: .visibleModelsDidChange, object: nil)
        }
    }

    func isModelEnabled(_ model: AIModelOption) -> Bool {
        enabledModelIDs.contains(model.stableID)
    }

    @discardableResult
    func setModelEnabled(_ model: AIModelOption, enabled: Bool) -> Bool {
        var set = enabledModelIDs
        if enabled {
            set.insert(model.stableID)
        } else {
            guard set.count > 1 else { return false }
            set.remove(model.stableID)
        }
        enabledModelIDs = set
        return true
    }

    func ensureModelCatalogSynced() {
        let catalog = AIModelOption.all.map { $0.stableID }
        let known = Set((UserDefaults.standard.array(forKey: knownModelsKey) as? [String]) ?? [])
        let stored = UserDefaults.standard.array(forKey: enabledModelsKey) as? [String]

        var enabled: Set<String>
        if known.isEmpty && stored == nil {
            enabled = Set(AIModelOption.defaultEnabled.map { $0.stableID })
        } else {
            enabled = Set(stored ?? AIModelOption.defaultEnabled.map { $0.stableID })
            enabled = Set(enabled.filter { catalog.contains($0) })
            // 新上架模型默认开启（仅 GLM / 豆包这类精选）
            for id in catalog where !known.contains(id) {
                enabled.insert(id)
            }
            if enabled.isEmpty {
                enabled = Set(AIModelOption.defaultEnabled.map { $0.stableID })
            }
        }
        UserDefaults.standard.set(Array(enabled), forKey: enabledModelsKey)
        UserDefaults.standard.set(catalog, forKey: knownModelsKey)
    }

    func sanitizedAPIKey(for provider: AIProvider) -> String {
        let raw: String
        switch provider {
        case .deepseek: raw = deepseekAPIKey
        case .kimi: raw = kimiAPIKey
        case .qwen: raw = dashscopeAPIKey
        case .zhipu: raw = zhipuAPIKey
        case .doubao: raw = doubaoAPIKey
        }
        return Self.sanitizeKey(raw)
    }

    func apiKey(for provider: AIProvider) -> String { sanitizedAPIKey(for: provider) }

    func hasAPIKey(for provider: AIProvider) -> Bool {
        !sanitizedAPIKey(for: provider).isEmpty
    }

    static func sanitizeKey(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let junk = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}\u{00A0}")
        key = String(key.unicodeScalars.filter { !junk.contains($0) })
        if key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return key
    }

    private func persist(key: String, value: String) {
        if value.isEmpty {
            KeychainHelper.delete(key: key)
        } else {
            _ = KeychainHelper.save(key: key, value: value)
        }
    }
}
