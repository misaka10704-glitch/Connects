import UIKit

/// ChatGPT-like template glyphs (drawn at screen scale — never stretch PNG points).
enum ActionIconFactory {
    private static let cache = NSCache<NSString, UIImage>()

    enum Kind {
        case copy, retry, fork, send, stop, plus
        case sidebar, sidebarOpen
        case more, share
        case archive, settings, search
        case newChat
    }

    static func barItem(kind: Kind, target: Any?, action: Selector, accessibility: String) -> UIBarButtonItem {
        let img = image(kind, pointSize: 18)
        let item = UIBarButtonItem(image: img, style: .plain, target: target, action: action)
        item.accessibilityLabel = accessibility
        return item
    }

    static func image(_ kind: Kind, pointSize: CGFloat = 18, color: UIColor = .black) -> UIImage {
        let key = "\(kind)-\(Int(pointSize * 10))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let canvas = ceil(pointSize + 8)
        let size = CGSize(width: canvas, height: canvas)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(1.55)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let inset = (canvas - pointSize) / 2
        let r = CGRect(x: inset, y: inset, width: pointSize, height: pointSize)

        switch kind {
        case .copy:
            let back = CGRect(x: r.minX + 4, y: r.minY + 1.5, width: pointSize - 6, height: pointSize - 6)
            let front = CGRect(x: r.minX + 1.5, y: r.minY + 4, width: pointSize - 6, height: pointSize - 6)
            let pathB = UIBezierPath(roundedRect: back, cornerRadius: 2.2)
            let pathF = UIBezierPath(roundedRect: front, cornerRadius: 2.2)
            pathB.lineWidth = 1.55
            pathF.lineWidth = 1.55
            pathB.stroke()
            ctx.setBlendMode(.clear)
            UIBezierPath(roundedRect: front.insetBy(dx: -0.5, dy: -0.5), cornerRadius: 2.2).fill()
            ctx.setBlendMode(.normal)
            color.setStroke()
            pathF.stroke()

        case .retry:
            let c = CGPoint(x: r.midX, y: r.midY)
            let rad = pointSize * 0.34
            let arc = UIBezierPath(arcCenter: c, radius: rad, startAngle: -.pi * 0.15, endAngle: .pi * 1.35, clockwise: true)
            arc.lineWidth = 1.55
            arc.stroke()
            let tip = CGPoint(x: c.x + rad * cos(-.pi * 0.15), y: c.y + rad * sin(-.pi * 0.15))
            let head = UIBezierPath()
            head.move(to: CGPoint(x: tip.x - 3.2, y: tip.y - 1.2))
            head.addLine(to: tip)
            head.addLine(to: CGPoint(x: tip.x - 1.0, y: tip.y + 3.4))
            head.lineWidth = 1.55
            head.stroke()

        case .fork:
            let left = CGPoint(x: r.minX + pointSize * 0.28, y: r.minY + pointSize * 0.22)
            let mid = CGPoint(x: r.minX + pointSize * 0.28, y: r.midY)
            let bot = CGPoint(x: r.minX + pointSize * 0.28, y: r.maxY - pointSize * 0.18)
            let right = CGPoint(x: r.maxX - pointSize * 0.22, y: r.minY + pointSize * 0.28)
            let path = UIBezierPath()
            path.move(to: left); path.addLine(to: bot)
            path.move(to: mid)
            path.addQuadCurve(to: right, controlPoint: CGPoint(x: mid.x + pointSize * 0.35, y: mid.y - pointSize * 0.05))
            path.lineWidth = 1.55
            path.stroke()
            for p in [left, bot, right] {
                UIBezierPath(ovalIn: CGRect(x: p.x - 2.0, y: p.y - 2.0, width: 4.0, height: 4.0)).fill()
            }

        case .send:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.midX, y: r.minY + 2))
            path.addLine(to: CGPoint(x: r.midX, y: r.maxY - 2))
            path.move(to: CGPoint(x: r.midX - 4.5, y: r.minY + 7))
            path.addLine(to: CGPoint(x: r.midX, y: r.minY + 2))
            path.addLine(to: CGPoint(x: r.midX + 4.5, y: r.minY + 7))
            path.lineWidth = 1.7
            path.stroke()

        case .stop:
            let sq = r.insetBy(dx: pointSize * 0.28, dy: pointSize * 0.28)
            UIBezierPath(roundedRect: sq, cornerRadius: 1.5).fill()

        case .plus, .newChat:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.midX, y: r.minY + 3))
            path.addLine(to: CGPoint(x: r.midX, y: r.maxY - 3))
            path.move(to: CGPoint(x: r.minX + 3, y: r.midY))
            path.addLine(to: CGPoint(x: r.maxX - 3, y: r.midY))
            path.lineWidth = 1.7
            path.stroke()

        case .sidebar:
            // Collapsed → open panel (square with left rail)
            let outer = UIBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 2.2), cornerRadius: 2.5)
            outer.lineWidth = 1.55
            outer.stroke()
            let rail = UIBezierPath()
            rail.move(to: CGPoint(x: r.minX + pointSize * 0.38, y: r.minY + 2.2))
            rail.addLine(to: CGPoint(x: r.minX + pointSize * 0.38, y: r.maxY - 2.2))
            rail.lineWidth = 1.55
            rail.stroke()

        case .sidebarOpen:
            // Open → close/collapse (panel with chevron feel: left-pointing bar)
            let outer = UIBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 2.2), cornerRadius: 2.5)
            outer.lineWidth = 1.55
            outer.stroke()
            let rail = UIBezierPath()
            rail.move(to: CGPoint(x: r.minX + pointSize * 0.42, y: r.minY + 2.2))
            rail.addLine(to: CGPoint(x: r.minX + pointSize * 0.42, y: r.maxY - 2.2))
            rail.lineWidth = 1.55
            rail.stroke()
            let chev = UIBezierPath()
            chev.move(to: CGPoint(x: r.midX + 2.5, y: r.midY - 3.5))
            chev.addLine(to: CGPoint(x: r.midX - 1.0, y: r.midY))
            chev.addLine(to: CGPoint(x: r.midX + 2.5, y: r.midY + 3.5))
            chev.lineWidth = 1.55
            chev.stroke()

        case .more:
            for i in 0..<3 {
                let cx = r.minX + pointSize * (0.22 + CGFloat(i) * 0.28)
                UIBezierPath(ovalIn: CGRect(x: cx - 1.35, y: r.midY - 1.35, width: 2.7, height: 2.7)).fill()
            }

        case .share:
            // Upload / share arrow out of tray
            let tray = UIBezierPath()
            tray.move(to: CGPoint(x: r.minX + 3, y: r.midY + 1))
            tray.addLine(to: CGPoint(x: r.minX + 3, y: r.maxY - 2.5))
            tray.addLine(to: CGPoint(x: r.maxX - 3, y: r.maxY - 2.5))
            tray.addLine(to: CGPoint(x: r.maxX - 3, y: r.midY + 1))
            tray.lineWidth = 1.55
            tray.stroke()
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: r.midX, y: r.maxY - 5))
            arrow.addLine(to: CGPoint(x: r.midX, y: r.minY + 2.5))
            arrow.move(to: CGPoint(x: r.midX - 4, y: r.minY + 6.5))
            arrow.addLine(to: CGPoint(x: r.midX, y: r.minY + 2.5))
            arrow.addLine(to: CGPoint(x: r.midX + 4, y: r.minY + 6.5))
            arrow.lineWidth = 1.55
            arrow.stroke()

        case .archive:
            // Box / archive
            let lid = UIBezierPath()
            lid.move(to: CGPoint(x: r.minX + 2, y: r.minY + 5.5))
            lid.addLine(to: CGPoint(x: r.minX + 4, y: r.minY + 2.5))
            lid.addLine(to: CGPoint(x: r.maxX - 4, y: r.minY + 2.5))
            lid.addLine(to: CGPoint(x: r.maxX - 2, y: r.minY + 5.5))
            lid.close()
            lid.lineWidth = 1.55
            lid.stroke()
            let box = UIBezierPath(roundedRect: CGRect(x: r.minX + 2.5, y: r.minY + 5.5, width: pointSize - 5, height: pointSize - 8), cornerRadius: 1.5)
            box.lineWidth = 1.55
            box.stroke()
            let slit = UIBezierPath()
            slit.move(to: CGPoint(x: r.midX - 2.5, y: r.midY + 1.5))
            slit.addLine(to: CGPoint(x: r.midX + 2.5, y: r.midY + 1.5))
            slit.lineWidth = 1.55
            slit.stroke()

        case .settings:
            // Gear (simplified)
            let c = CGPoint(x: r.midX, y: r.midY)
            UIBezierPath(ovalIn: CGRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4)).stroke()
            let outer = UIBezierPath(ovalIn: CGRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11))
            outer.lineWidth = 1.55
            outer.stroke()
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3
                let p0 = CGPoint(x: c.x + 5.2 * cos(a), y: c.y + 5.2 * sin(a))
                let p1 = CGPoint(x: c.x + 7.2 * cos(a), y: c.y + 7.2 * sin(a))
                let tooth = UIBezierPath()
                tooth.move(to: p0); tooth.addLine(to: p1)
                tooth.lineWidth = 1.8
                tooth.stroke()
            }

        case .search:
            let circle = UIBezierPath(ovalIn: CGRect(x: r.minX + 2, y: r.minY + 2, width: pointSize * 0.55, height: pointSize * 0.55))
            circle.lineWidth = 1.55
            circle.stroke()
            let handle = UIBezierPath()
            handle.move(to: CGPoint(x: r.minX + pointSize * 0.55, y: r.minY + pointSize * 0.55))
            handle.addLine(to: CGPoint(x: r.maxX - 2.5, y: r.maxY - 2.5))
            handle.lineWidth = 1.7
            handle.stroke()
        }

        let img = (UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()).withRenderingMode(.alwaysTemplate)
        cache.setObject(img, forKey: key)
        return img
    }
}
