import UIKit

extension UIApplication {
    /// Preferred key window for the active foreground scene.
    static var connectsKeyWindow: UIWindow? {
        if let scene = shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            return scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        }
        return shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? connectsWindows.first
    }

    static var connectsWindows: [UIWindow] {
        shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
    }
}
