import Foundation

/// App UI language. `.system` follows the device locale; zh/en force a language
/// for US-App-Store users who want English regardless of device language.
enum AppLanguage: String, CaseIterable {
    case system
    case zh
    case en

    var displayName: String {
        switch self {
        case .system: return L("跟随系统", "System")
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

/// Pick the active localized string. Chinese is the app's primary language, so
/// call sites stay `L("中文", "English")` — readable inline, no .strings tables.
func L(_ zh: String, _ en: String) -> String {
    switch SettingsManager.shared.appLanguage {
    case .en: return en
    case .zh: return zh
    case .system:
        let preferred = Locale.preferredLanguages.first ?? "zh"
        return preferred.hasPrefix("en") ? en : zh
    }
}
