import UIKit

enum AppearanceMode: String, CaseIterable {
    case light
    case dark

    var displayName: String {
        switch self {
        case .light: return "白天"
        case .dark: return "黑夜"
        }
    }
}

struct ThemeColors {
    let background: UIColor
    let sidebarBackground: UIColor
    let surface: UIColor
    let surfaceHover: UIColor
    let border: UIColor
    let divider: UIColor
    let textPrimary: UIColor
    let textSecondary: UIColor
    let textTertiary: UIColor
    let accent: UIColor
    let userBubble: UIColor
    let assistantBubble: UIColor
    let inputBackground: UIColor
    let inputBorder: UIColor
    let sendEnabled: UIColor
    let sendDisabled: UIColor
    let navBarStyle: UIBarStyle
    let statusBarStyle: UIStatusBarStyle
}

extension Notification.Name {
    static let themeDidChange = Notification.Name("ConnectsThemeDidChange")
}

final class ThemeManager {
    static let shared = ThemeManager()
    private let storageKey = "connects_appearance_mode"

    var mode: AppearanceMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: storageKey),
                  let m = AppearanceMode(rawValue: raw) else { return .dark }
            return m
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
            NotificationCenter.default.post(name: .themeDidChange, object: nil)
        }
    }

    var colors: ThemeColors {
        mode == .light ? DSTheme.light : DSTheme.dark
    }
}

    /// DeepSeek / ChatGPT-like neutrals — roomy, low contrast chrome
    enum DSTheme {
    static let brandCyan = UIColor(red: 16/255, green: 163/255, blue: 127/255, alpha: 1)

    static let dark = ThemeColors(
        background: UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha: 1),
        sidebarBackground: UIColor(red: 23/255, green: 23/255, blue: 23/255, alpha: 1),
        surface: UIColor(red: 44/255, green: 44/255, blue: 44/255, alpha: 1),
        surfaceHover: UIColor(red: 52/255, green: 52/255, blue: 52/255, alpha: 1),
        border: UIColor(red: 64/255, green: 64/255, blue: 64/255, alpha: 1),
        divider: UIColor(red: 40/255, green: 40/255, blue: 40/255, alpha: 1),
        textPrimary: UIColor(red: 236/255, green: 236/255, blue: 241/255, alpha: 1),
        textSecondary: UIColor(red: 172/255, green: 172/255, blue: 182/255, alpha: 1),
        textTertiary: UIColor(red: 120/255, green: 120/255, blue: 130/255, alpha: 1),
        accent: brandCyan,
        userBubble: UIColor(red: 48/255, green: 48/255, blue: 52/255, alpha: 1),
        assistantBubble: UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha: 1),
        inputBackground: UIColor(red: 48/255, green: 48/255, blue: 52/255, alpha: 1),
        inputBorder: UIColor(red: 70/255, green: 70/255, blue: 76/255, alpha: 1),
        sendEnabled: brandCyan,
        sendDisabled: UIColor(red: 80/255, green: 80/255, blue: 86/255, alpha: 1),
        navBarStyle: .black,
        statusBarStyle: .lightContent
    )

    static let light = ThemeColors(
        background: UIColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1),
        sidebarBackground: UIColor(red: 247/255, green: 247/255, blue: 248/255, alpha: 1),
        surface: UIColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1),
        surfaceHover: UIColor(red: 236/255, green: 236/255, blue: 241/255, alpha: 1),
        border: UIColor(red: 226/255, green: 226/255, blue: 232/255, alpha: 1),
        divider: UIColor(red: 235/255, green: 235/255, blue: 240/255, alpha: 1),
        textPrimary: UIColor(red: 13/255, green: 13/255, blue: 13/255, alpha: 1),
        textSecondary: UIColor(red: 90/255, green: 90/255, blue: 98/255, alpha: 1),
        textTertiary: UIColor(red: 142/255, green: 142/255, blue: 150/255, alpha: 1),
        accent: brandCyan,
        userBubble: UIColor(red: 243/255, green: 243/255, blue: 245/255, alpha: 1),
        assistantBubble: UIColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1),
        inputBackground: UIColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1),
        inputBorder: UIColor(red: 210/255, green: 210/255, blue: 218/255, alpha: 1),
        sendEnabled: brandCyan,
        sendDisabled: UIColor(red: 210/255, green: 210/255, blue: 216/255, alpha: 1),
        navBarStyle: .default,
        statusBarStyle: .default
    )

    static var c: ThemeColors { ThemeManager.shared.colors }

    // iPad Air 1 layout — ChatGPT-like reading width
    static let sidebarWidth: CGFloat = 268
    static let contentMaxWidth: CGFloat = 720
    static let contentPadding: CGFloat = 24
    static let contentHorizontalPadding: CGFloat = 24
    static let bubbleMaxWidth: CGFloat = 720
    static let cornerRadius: CGFloat = 22
    static let bubbleCornerRadius: CGFloat = 16
    static let inputBarHeight: CGFloat = 44
    static let inputBarBottomPadding: CGFloat = 10
    static let inputButtonSize: CGFloat = 30
    static let rowHeight: CGFloat = 44

    static func bodyFont(size: CGFloat = 16) -> UIFont {
        UIFont.systemFont(ofSize: size)
    }

    static func titleFont(size: CGFloat = 16) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: .medium)
    }

    static func monoFont(size: CGFloat = 14) -> UIFont {
        UIFont(name: "Menlo-Regular", size: size) ?? UIFont.systemFont(ofSize: size)
    }
}

protocol ThemeRefreshable: AnyObject {
    func applyTheme()
}
