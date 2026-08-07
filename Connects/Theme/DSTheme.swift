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

/// Everforest Dark–aligned reading chrome (Typora). Page `background` stays Connects default.
extension ThemeColors {
    var isLightAppearance: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        if background.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.55
        }
        var w: CGFloat = 0
        if background.getWhite(&w, alpha: &a) { return w > 0.55 }
        return true
    }

    /// Everforest Green — `**bold**` / `\boldsymbol`.
    var mdBoldFg: UIColor {
        isLightAppearance
            ? UIColor(red: 141/255, green: 161/255, blue: 1/255, alpha: 1)   // #8da101
            : UIColor(red: 167/255, green: 192/255, blue: 128/255, alpha: 1) // #a7c080
    }

    /// Everforest Blue — markdown links.
    var mdLinkFg: UIColor {
        isLightAppearance
            ? UIColor(red: 58/255, green: 148/255, blue: 197/255, alpha: 1)  // #3a94c5
            : UIColor(red: 127/255, green: 187/255, blue: 179/255, alpha: 1) // #7fbbb3
    }

    var mdQuoteBar: UIColor { mdLinkFg }

    var mdQuoteFill: UIColor {
        mdLinkFg.withAlphaComponent(isLightAppearance ? 0.08 : 0.11)
    }

    /// Everforest Orange — inline `` `code` ``.
    var mdInlineCodeFg: UIColor {
        isLightAppearance
            ? UIColor(red: 245/255, green: 125/255, blue: 38/255, alpha: 1)  // #f57d26
            : UIColor(red: 230/255, green: 152/255, blue: 117/255, alpha: 1) // #e69875
    }

    var mdInlineCodeFill: UIColor {
        isLightAppearance
            ? UIColor(red: 245/255, green: 125/255, blue: 38/255, alpha: 0.10)
            : UIColor(red: 52/255, green: 63/255, blue: 68/255, alpha: 0.85) // bg1 tint
    }

    /// Code fence panel — everforest bg1/bg2, not page background.
    var mdCodeBlockFill: UIColor {
        isLightAppearance
            ? UIColor(red: 244/255, green: 240/255, blue: 217/255, alpha: 1)
            : UIColor(red: 52/255, green: 63/255, blue: 68/255, alpha: 1)    // #343f44
    }

    var mdCodeBlockBorder: UIColor {
        isLightAppearance
            ? UIColor(red: 147/255, green: 159/255, blue: 145/255, alpha: 0.55)
            : UIColor(red: 79/255, green: 88/255, blue: 94/255, alpha: 1)  // #4f585e
    }

    var mdTableHeaderFill: UIColor {
        mdBoldFg.withAlphaComponent(isLightAppearance ? 0.12 : 0.14)
    }

    var mdTableStripeFill: UIColor {
        isLightAppearance
            ? UIColor(red: 141/255, green: 161/255, blue: 1/255, alpha: 0.05)
            : UIColor(red: 167/255, green: 192/255, blue: 128/255, alpha: 0.05)
    }

    var mdHeadingRule: UIColor {
        isLightAppearance
            ? UIColor(red: 147/255, green: 159/255, blue: 145/255, alpha: 0.65)
            : UIColor(red: 79/255, green: 88/255, blue: 94/255, alpha: 1)  // bg4
    }

    /// Everforest Yellow — `==mark==` / highlight.
    var mdMarkFill: UIColor {
        isLightAppearance
            ? UIColor(red: 223/255, green: 160/255, blue: 0/255, alpha: 0.35)
            : UIColor(red: 219/255, green: 188/255, blue: 127/255, alpha: 0.32) // #dbbc7f
    }

    /// Display-math panel tint (subtle bg2 on existing page).
    var mdMathDisplayFill: UIColor {
        isLightAppearance
            ? UIColor(red: 141/255, green: 161/255, blue: 1/255, alpha: 0.06)
            : UIColor(red: 61/255, green: 72/255, blue: 77/255, alpha: 0.55)  // #3d484d
    }
}

protocol ThemeRefreshable: AnyObject {
    func applyTheme()
}

extension UIButton {
    /// iOS 15+ replacement for deprecated `contentEdgeInsets`.
    func connectsSetContentInsets(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat,
                                  imagePadding: CGFloat? = nil) {
        var config = configuration ?? .plain()
        if let attributed = attributedTitle(for: .normal), attributed.length > 0 {
            config.attributedTitle = AttributedString(attributed)
        } else if let title = currentTitle {
            config.title = title
        }
        if let image = currentImage {
            config.image = image
        }
        if let color = titleColor(for: .normal) {
            config.baseForegroundColor = color
        }
        if let font = titleLabel?.font {
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = font
                return out
            }
        }
        config.contentInsets = NSDirectionalEdgeInsets(
            top: top,
            leading: leading,
            bottom: bottom,
            trailing: trailing
        )
        if let imagePadding {
            config.imagePadding = imagePadding
        }
        configuration = config
    }
}
