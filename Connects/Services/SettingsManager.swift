import Foundation

extension Notification.Name {
    static let chatFontSizeDidChange = Notification.Name("ConnectsChatFontSizeDidChange")
}

final class SettingsManager {
    static let shared = SettingsManager()

    var deepseekAPIKey: String {
        get { KeychainHelper.load(key: KeychainHelper.Keys.deepseekAPIKey) ?? "" }
        set { persist(key: KeychainHelper.Keys.deepseekAPIKey, value: Self.sanitizeKey(newValue)) }
    }

    var kimiAPIKey: String {
        get { KeychainHelper.load(key: KeychainHelper.Keys.kimiAPIKey) ?? "" }
        set { persist(key: KeychainHelper.Keys.kimiAPIKey, value: Self.sanitizeKey(newValue)) }
    }

    var kimiUseChinaEndpoint: Bool {
        get {
            // Default ON for China users — api.moonshot.ai is often very slow from CN.
            if UserDefaults.standard.object(forKey: "connects_kimi_cn") == nil { return true }
            return UserDefaults.standard.bool(forKey: "connects_kimi_cn")
        }
        set { UserDefaults.standard.set(newValue, forKey: "connects_kimi_cn") }
    }

    /// Shared thinking toggle for DeepSeek V4 / Kimi K2.6 (default ON).
    /// Off = Instant mode — much faster first token, no reasoning stream.
    var thinkingEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "connects_thinking") == nil { return true }
            return UserDefaults.standard.bool(forKey: "connects_thinking")
        }
        set { UserDefaults.standard.set(newValue, forKey: "connects_thinking") }
    }

    /// Input-bar 联网开关：发送前先搜网页再注入上下文（默认关）。
    var webSearchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "connects_web_search") }
        set { UserDefaults.standard.set(newValue, forKey: "connects_web_search") }
    }

    var appearanceMode: AppearanceMode {
        get { ThemeManager.shared.mode }
        set { ThemeManager.shared.mode = newValue }
    }

    /// 0=小 1=中 2=大
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

    func apiKey(for provider: AIProvider) -> String {
        sanitizedAPIKey(for: provider)
    }

    func sanitizedAPIKey(for provider: AIProvider) -> String {
        let raw: String
        switch provider {
        case .deepseek: raw = deepseekAPIKey
        case .kimi: raw = kimiAPIKey
        }
        return Self.sanitizeKey(raw)
    }

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
