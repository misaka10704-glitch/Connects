import UIKit

struct AgentAppearancePreset {
    let index: Int
    let name: String
    let color: UIColor

    static let all: [AgentAppearancePreset] = [
        (0, "海蓝", 0x3B82F6), (1, "靛蓝", 0x6366F1), (2, "紫罗兰", 0x8B5CF6), (3, "玫红", 0xDB2777),
        (4, "珊瑚", 0xEA580C), (5, "琥珀", 0xD97706), (6, "金黄", 0xCA8A04), (7, "青柠", 0x65A30D),
        (8, "翠绿", 0x16A34A), (9, "青绿", 0x0F766E), (10, "湖蓝", 0x0891B2), (11, "天蓝", 0x0284C7),
        (12, "石墨", 0x475569), (13, "可可", 0x92400E), (14, "酒红", 0xB91C1C), (15, "莓紫", 0x9333EA),
        (16, "薰衣草", 0x7C3AED), (17, "松绿", 0x047857), (18, "橄榄", 0x4D7C0F), (19, "砖红", 0xC2410C)
    ].map { AgentAppearancePreset(index: $0.0, name: $0.1, color: UIColor(rgb: $0.2)) }

    static func preset(_ index: Int) -> AgentAppearancePreset {
        all[max(0, min(all.count - 1, index))]
    }

    static func avatar(for agent: CustomAgent?, size: CGFloat = 30) -> UIImage {
        let preset = preset(agent?.iconPreset ?? 0)
        let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
        UIGraphicsBeginImageContextWithOptions(rect.size, false, 0)
        defer { UIGraphicsEndImageContext() }
        preset.color.setFill()
        UIBezierPath(ovalIn: rect).fill()
        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }

    static func colorBall(for project: Project, size: CGFloat = 12) -> UIImage {
        let preset = preset(project.colorPreset)
        let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
        UIGraphicsBeginImageContextWithOptions(rect.size, false, 0)
        defer { UIGraphicsEndImageContext() }
        preset.color.setFill()
        UIBezierPath(ovalIn: rect).fill()
        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }

    static func projectIcon(for project: Project, size: CGFloat = 28) -> UIImage {
        colorBall(for: project, size: max(10, size * 0.42))
    }
}

private extension UIColor {
    convenience init(rgb: Int) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}
