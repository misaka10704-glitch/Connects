import UIKit

/// ChatGPT-like template glyphs (drawn at screen scale — never stretch PNG points).
enum ActionIconFactory {
    private static let cache = NSCache<NSString, UIImage>()

    enum Kind: String {
        case copy, retry, fork, send, stop, plus
        case sidebar, sidebarOpen
        case more, share
        case archive, settings, search
        case globe
        case think
        case ai
        case brain, memory, vinyl, tshirt
        case newChat
        case rename, trash
        case edit
        case editMode
        case readMode
        case save
        case highlighter
        case folder
        case chevronLeft, chevronRight, chevronUp, chevronDown
        case book
        case toc, bookmark
        case clock
        /// Selection Ask in the composer (speech-bubble + ?).
        case ask
        /// Import / copy file into workspace.
        case importFile
    }

    static func barItem(kind: Kind, target: Any?, action: Selector, accessibility: String) -> UIBarButtonItem {
        barItem(kind: kind, pointSize: 18, target: target, action: action, accessibility: accessibility)
    }

    static func barItem(kind: Kind, pointSize: CGFloat, target: Any?, action: Selector, accessibility: String) -> UIBarButtonItem {
        let img = image(kind, pointSize: pointSize)
        let item = UIBarButtonItem(image: img, style: .plain, target: target, action: action)
        item.accessibilityLabel = accessibility
        return item
    }

    static func image(_ kind: Kind, pointSize: CGFloat = 18, color: UIColor = .black) -> UIImage {
        let key = "v3-\(kind.rawValue)-\(Int(pointSize * 10))-\(color.description)" as NSString
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

        case .globe:
            let oval = UIBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
            oval.lineWidth = 1.55
            oval.stroke()
            let midV = UIBezierPath()
            midV.move(to: CGPoint(x: r.midX, y: r.minY + 1.5))
            midV.addLine(to: CGPoint(x: r.midX, y: r.maxY - 1.5))
            midV.lineWidth = 1.2
            midV.stroke()
            let eq = UIBezierPath()
            eq.move(to: CGPoint(x: r.minX + 1.5, y: r.midY))
            eq.addLine(to: CGPoint(x: r.maxX - 1.5, y: r.midY))
            eq.lineWidth = 1.2
            eq.stroke()
            let lat = UIBezierPath(ovalIn: CGRect(x: r.midX - pointSize * 0.18, y: r.minY + 1.5,
                                                  width: pointSize * 0.36, height: pointSize - 3))
            lat.lineWidth = 1.15
            lat.stroke()

        case .think:
            // Lightbulb: deep thinking toggle in the composer.
            let bulb = UIBezierPath(
                ovalIn: CGRect(
                    x: r.midX - pointSize * 0.28,
                    y: r.minY + 1.8,
                    width: pointSize * 0.56,
                    height: pointSize * 0.56
                )
            )
            bulb.lineWidth = 1.55
            bulb.stroke()
            let neck = UIBezierPath(
                roundedRect: CGRect(
                    x: r.midX - pointSize * 0.14,
                    y: r.minY + pointSize * 0.52,
                    width: pointSize * 0.28,
                    height: pointSize * 0.18
                ),
                cornerRadius: 1.2
            )
            neck.lineWidth = 1.35
            neck.stroke()
            let base = UIBezierPath()
            base.move(to: CGPoint(x: r.midX - pointSize * 0.16, y: r.maxY - 3.2))
            base.addLine(to: CGPoint(x: r.midX + pointSize * 0.16, y: r.maxY - 3.2))
            base.lineWidth = 1.45
            base.stroke()
            let filament = UIBezierPath()
            filament.move(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.22))
            filament.addLine(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.42))
            filament.lineWidth = 1.2
            filament.stroke()

        case .ai:
            // Four-point sparkle — model / AI picker.
            let cx = r.midX
            let cy = r.midY
            let spark = UIBezierPath()
            spark.move(to: CGPoint(x: cx, y: r.minY + 1.5))
            spark.addLine(to: CGPoint(x: cx + pointSize * 0.12, y: cy - pointSize * 0.06))
            spark.addLine(to: CGPoint(x: r.maxX - 1.5, y: cy))
            spark.addLine(to: CGPoint(x: cx + pointSize * 0.12, y: cy + pointSize * 0.06))
            spark.addLine(to: CGPoint(x: cx, y: r.maxY - 1.5))
            spark.addLine(to: CGPoint(x: cx - pointSize * 0.12, y: cy + pointSize * 0.06))
            spark.addLine(to: CGPoint(x: r.minX + 1.5, y: cy))
            spark.addLine(to: CGPoint(x: cx - pointSize * 0.12, y: cy - pointSize * 0.06))
            spark.close()
            spark.lineWidth = 1.35
            spark.stroke()
            UIBezierPath(
                ovalIn: CGRect(x: cx - 1.2, y: cy - 1.2, width: 2.4, height: 2.4)
            ).fill()

        case .brain:
            // Memory / knowledge — two lobes + stem.
            let left = UIBezierPath(
                ovalIn: CGRect(
                    x: r.minX + pointSize * 0.08,
                    y: r.minY + pointSize * 0.18,
                    width: pointSize * 0.42,
                    height: pointSize * 0.52
                )
            )
            let right = UIBezierPath(
                ovalIn: CGRect(
                    x: r.midX - pointSize * 0.02,
                    y: r.minY + pointSize * 0.18,
                    width: pointSize * 0.42,
                    height: pointSize * 0.52
                )
            )
            left.lineWidth = 1.5
            right.lineWidth = 1.5
            left.stroke()
            right.stroke()
            let cleft = UIBezierPath()
            cleft.move(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.28))
            cleft.addLine(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.62))
            cleft.lineWidth = 1.2
            cleft.stroke()
            let stem = UIBezierPath()
            stem.move(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.68))
            stem.addLine(to: CGPoint(x: r.midX, y: r.maxY - pointSize * 0.12))
            stem.lineWidth = 1.45
            stem.stroke()

        case .memory:
            // Stacked cards with a bookmark mark.
            let back = UIBezierPath(
                roundedRect: CGRect(
                    x: r.minX + pointSize * 0.22,
                    y: r.minY + pointSize * 0.10,
                    width: pointSize * 0.58,
                    height: pointSize * 0.70
                ),
                cornerRadius: 1.8
            )
            back.lineWidth = 1.3
            back.stroke()
            let front = UIBezierPath(
                roundedRect: CGRect(
                    x: r.minX + pointSize * 0.10,
                    y: r.minY + pointSize * 0.22,
                    width: pointSize * 0.58,
                    height: pointSize * 0.70
                ),
                cornerRadius: 1.8
            )
            front.lineWidth = 1.55
            front.stroke()
            let mark = UIBezierPath()
            mark.move(to: CGPoint(x: r.minX + pointSize * 0.28, y: r.minY + pointSize * 0.34))
            mark.addLine(to: CGPoint(x: r.minX + pointSize * 0.28, y: r.minY + pointSize * 0.72))
            mark.addLine(to: CGPoint(x: r.minX + pointSize * 0.39, y: r.minY + pointSize * 0.64))
            mark.addLine(to: CGPoint(x: r.minX + pointSize * 0.50, y: r.minY + pointSize * 0.72))
            mark.addLine(to: CGPoint(x: r.minX + pointSize * 0.50, y: r.minY + pointSize * 0.34))
            mark.lineWidth = 1.25
            mark.stroke()

        case .vinyl:
            let disc = UIBezierPath(ovalIn: r.insetBy(dx: 1.4, dy: 1.4))
            disc.lineWidth = 1.55; disc.stroke()
            let groove = UIBezierPath(ovalIn: r.insetBy(dx: pointSize * 0.25, dy: pointSize * 0.25))
            groove.lineWidth = 1.15; groove.stroke()
            UIBezierPath(ovalIn: CGRect(x: r.midX - 1.6, y: r.midY - 1.6, width: 3.2, height: 3.2)).fill()

        case .tshirt:
            // Agent: person silhouette inside a soft badge.
            let badge = UIBezierPath(
                roundedRect: r.insetBy(dx: pointSize * 0.08, dy: pointSize * 0.08),
                cornerRadius: pointSize * 0.22
            )
            badge.lineWidth = 1.45
            badge.stroke()
            let head = UIBezierPath(
                ovalIn: CGRect(
                    x: r.midX - pointSize * 0.16,
                    y: r.minY + pointSize * 0.20,
                    width: pointSize * 0.32,
                    height: pointSize * 0.32
                )
            )
            head.lineWidth = 1.4
            head.stroke()
            let shoulders = UIBezierPath(
                arcCenter: CGPoint(x: r.midX, y: r.maxY - pointSize * 0.18),
                radius: pointSize * 0.28,
                startAngle: .pi * 1.12,
                endAngle: .pi * (-0.12),
                clockwise: true
            )
            shoulders.lineWidth = 1.45
            shoulders.stroke()

        case .rename:
            // Pencil
            let body = UIBezierPath()
            body.move(to: CGPoint(x: r.minX + 3.5, y: r.maxY - 4))
            body.addLine(to: CGPoint(x: r.maxX - 5.5, y: r.minY + 4))
            body.lineWidth = 1.55
            body.stroke()
            let tip = UIBezierPath()
            tip.move(to: CGPoint(x: r.maxX - 5.5, y: r.minY + 4))
            tip.addLine(to: CGPoint(x: r.maxX - 3.2, y: r.minY + 6.3))
            tip.addLine(to: CGPoint(x: r.maxX - 5.2, y: r.minY + 8.3))
            tip.close()
            tip.fill()
            let base = UIBezierPath()
            base.move(to: CGPoint(x: r.minX + 2.5, y: r.maxY - 2.8))
            base.addLine(to: CGPoint(x: r.minX + 6.5, y: r.maxY - 2.8))
            base.lineWidth = 1.4
            base.stroke()

        case .trash:
            let lid = UIBezierPath()
            lid.move(to: CGPoint(x: r.minX + 3, y: r.minY + 5))
            lid.addLine(to: CGPoint(x: r.maxX - 3, y: r.minY + 5))
            lid.move(to: CGPoint(x: r.midX - 2.5, y: r.minY + 5))
            lid.addLine(to: CGPoint(x: r.midX - 2.5, y: r.minY + 3.2))
            lid.addLine(to: CGPoint(x: r.midX + 2.5, y: r.minY + 3.2))
            lid.addLine(to: CGPoint(x: r.midX + 2.5, y: r.minY + 5))
            lid.lineWidth = 1.45
            lid.stroke()
            let can = UIBezierPath(roundedRect: CGRect(x: r.minX + 4, y: r.minY + 5.5,
                                                       width: pointSize - 8, height: pointSize - 8.5),
                                   cornerRadius: 1.2)
            can.lineWidth = 1.45
            can.stroke()
            for dx in [-2.0, 0.0, 2.0] as [CGFloat] {
                let slit = UIBezierPath()
                slit.move(to: CGPoint(x: r.midX + dx, y: r.minY + 8))
                slit.addLine(to: CGPoint(x: r.midX + dx, y: r.maxY - 4.5))
                slit.lineWidth = 1.2
                slit.stroke()
            }

        case .edit:
            // Pencil in square — distinct from rename
            let box = UIBezierPath(roundedRect: r.insetBy(dx: 1.8, dy: 1.8), cornerRadius: 2.2)
            box.lineWidth = 1.45
            box.stroke()
            let pen = UIBezierPath()
            pen.move(to: CGPoint(x: r.minX + 5, y: r.maxY - 5.5))
            pen.addLine(to: CGPoint(x: r.maxX - 5.5, y: r.minY + 5))
            pen.lineWidth = 1.55
            pen.stroke()
            let tip = UIBezierPath()
            tip.move(to: CGPoint(x: r.maxX - 5.5, y: r.minY + 5))
            tip.addLine(to: CGPoint(x: r.maxX - 3.5, y: r.minY + 7))
            tip.addLine(to: CGPoint(x: r.maxX - 5.2, y: r.minY + 8.7))
            tip.close()
            tip.fill()

        case .editMode:
            // Document + pencil — clearer “enter edit” than a bare pencil.
            let page = UIBezierPath(
                roundedRect: CGRect(
                    x: r.minX + pointSize * 0.14,
                    y: r.minY + pointSize * 0.10,
                    width: pointSize * 0.52,
                    height: pointSize * 0.78
                ),
                cornerRadius: 1.8
            )
            page.lineWidth = 1.55
            page.stroke()
            let lines = UIBezierPath()
            for yFrac: CGFloat in [0.34, 0.50, 0.66] {
                lines.move(to: CGPoint(x: r.minX + pointSize * 0.24, y: r.minY + pointSize * yFrac))
                lines.addLine(to: CGPoint(x: r.minX + pointSize * 0.52, y: r.minY + pointSize * yFrac))
            }
            lines.lineWidth = 1.2
            lines.stroke()
            let pen = UIBezierPath()
            pen.move(to: CGPoint(x: r.minX + pointSize * 0.48, y: r.maxY - pointSize * 0.22))
            pen.addLine(to: CGPoint(x: r.maxX - pointSize * 0.16, y: r.minY + pointSize * 0.22))
            pen.lineWidth = 1.7
            pen.stroke()
            let tip = UIBezierPath()
            tip.move(to: CGPoint(x: r.maxX - pointSize * 0.16, y: r.minY + pointSize * 0.22))
            tip.addLine(to: CGPoint(x: r.maxX - pointSize * 0.04, y: r.minY + pointSize * 0.30))
            tip.addLine(to: CGPoint(x: r.maxX - pointSize * 0.12, y: r.minY + pointSize * 0.40))
            tip.close()
            tip.fill()

        case .readMode:
            // Eye — same inset envelope as editMode/save (~0.16 padding).
            let eye = UIBezierPath(
                ovalIn: CGRect(x: r.minX + pointSize * 0.18, y: r.minY + pointSize * 0.34,
                               width: pointSize * 0.64, height: pointSize * 0.32)
            )
            eye.lineWidth = 1.55
            eye.stroke()
            UIBezierPath(
                ovalIn: CGRect(x: r.midX - pointSize * 0.09, y: r.midY - pointSize * 0.09,
                               width: pointSize * 0.18, height: pointSize * 0.18)
            ).fill()

        case .save:
            // Floppy — match editMode/readMode stroke weight.
            let body = UIBezierPath(roundedRect: r.insetBy(dx: pointSize * 0.16, dy: pointSize * 0.16), cornerRadius: 1.8)
            body.lineWidth = 1.55
            body.stroke()
            let label = UIBezierPath(
                roundedRect: CGRect(x: r.minX + pointSize * 0.28, y: r.minY + pointSize * 0.18,
                                    width: pointSize * 0.44, height: pointSize * 0.22),
                cornerRadius: 1.0
            )
            label.lineWidth = 1.3
            label.stroke()
            let window = UIBezierPath(
                roundedRect: CGRect(x: r.minX + pointSize * 0.28, y: r.midY + pointSize * 0.02,
                                    width: pointSize * 0.44, height: pointSize * 0.24),
                cornerRadius: 1.0
            )
            window.lineWidth = 1.3
            window.stroke()

        case .highlighter:
            // Angled marker: barrel + chisel tip + ink swipe.
            let barrel = UIBezierPath(
                roundedRect: CGRect(
                    x: r.minX + pointSize * 0.18,
                    y: r.minY + pointSize * 0.28,
                    width: pointSize * 0.52,
                    height: pointSize * 0.28
                ),
                cornerRadius: 1.4
            )
            barrel.lineWidth = 1.5
            barrel.stroke()
            let tip = UIBezierPath()
            tip.move(to: CGPoint(x: r.minX + pointSize * 0.70, y: r.minY + pointSize * 0.28))
            tip.addLine(to: CGPoint(x: r.maxX - pointSize * 0.10, y: r.midY))
            tip.addLine(to: CGPoint(x: r.minX + pointSize * 0.70, y: r.minY + pointSize * 0.56))
            tip.close()
            tip.fill()
            let swipe = UIBezierPath()
            swipe.move(to: CGPoint(x: r.minX + pointSize * 0.12, y: r.maxY - pointSize * 0.18))
            swipe.addLine(to: CGPoint(x: r.maxX - pointSize * 0.22, y: r.maxY - pointSize * 0.18))
            swipe.lineWidth = 2.2
            swipe.stroke()

        case .folder:
            let tab = UIBezierPath()
            tab.move(to: CGPoint(x: r.minX + 2.5, y: r.minY + 5.5))
            tab.addLine(to: CGPoint(x: r.minX + 5.5, y: r.minY + 3))
            tab.addLine(to: CGPoint(x: r.minX + pointSize * 0.48, y: r.minY + 3))
            tab.addLine(to: CGPoint(x: r.minX + pointSize * 0.58, y: r.minY + 5.5))
            tab.lineWidth = 1.45
            tab.stroke()
            let body = UIBezierPath(roundedRect: CGRect(x: r.minX + 2.2, y: r.minY + 5.5,
                                                        width: pointSize - 4.4, height: pointSize - 7.8),
                                     cornerRadius: 1.8)
            body.lineWidth = 1.55
            body.stroke()

        case .clock:
            let c = CGPoint(x: r.midX, y: r.midY)
            let rad = pointSize * 0.38
            let circle = UIBezierPath(arcCenter: c, radius: rad, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            circle.lineWidth = 1.55
            circle.stroke()
            let hands = UIBezierPath()
            hands.move(to: c)
            hands.addLine(to: CGPoint(x: c.x, y: c.y - rad * 0.55))
            hands.move(to: c)
            hands.addLine(to: CGPoint(x: c.x + rad * 0.42, y: c.y + rad * 0.12))
            hands.lineWidth = 1.55
            hands.stroke()

        case .chevronLeft:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.midX + 2.2, y: r.minY + 3.5))
            path.addLine(to: CGPoint(x: r.midX - 2.4, y: r.midY))
            path.addLine(to: CGPoint(x: r.midX + 2.2, y: r.maxY - 3.5))
            path.lineWidth = 1.7
            path.stroke()

        case .chevronRight:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.midX - 2.2, y: r.minY + 3.5))
            path.addLine(to: CGPoint(x: r.midX + 2.4, y: r.midY))
            path.addLine(to: CGPoint(x: r.midX - 2.2, y: r.maxY - 3.5))
            path.lineWidth = 1.7
            path.stroke()

        case .chevronUp:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.minX + 3.5, y: r.midY + 2.2))
            path.addLine(to: CGPoint(x: r.midX, y: r.midY - 2.4))
            path.addLine(to: CGPoint(x: r.maxX - 3.5, y: r.midY + 2.2))
            path.lineWidth = 1.7
            path.stroke()

        case .chevronDown:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.minX + 3.5, y: r.midY - 2.2))
            path.addLine(to: CGPoint(x: r.midX, y: r.midY + 2.4))
            path.addLine(to: CGPoint(x: r.maxX - 3.5, y: r.midY - 2.2))
            path.lineWidth = 1.7
            path.stroke()

        case .book:
            // Document with folded corner (reading context).
            let page = UIBezierPath()
            page.move(to: CGPoint(x: r.minX + pointSize * 0.18, y: r.minY + pointSize * 0.12))
            page.addLine(to: CGPoint(x: r.maxX - pointSize * 0.28, y: r.minY + pointSize * 0.12))
            page.addLine(to: CGPoint(x: r.maxX - pointSize * 0.12, y: r.minY + pointSize * 0.28))
            page.addLine(to: CGPoint(x: r.maxX - pointSize * 0.12, y: r.maxY - pointSize * 0.12))
            page.addLine(to: CGPoint(x: r.minX + pointSize * 0.18, y: r.maxY - pointSize * 0.12))
            page.close()
            page.lineWidth = 1.55
            page.stroke()
            let fold = UIBezierPath()
            fold.move(to: CGPoint(x: r.maxX - pointSize * 0.28, y: r.minY + pointSize * 0.12))
            fold.addLine(to: CGPoint(x: r.maxX - pointSize * 0.28, y: r.minY + pointSize * 0.28))
            fold.addLine(to: CGPoint(x: r.maxX - pointSize * 0.12, y: r.minY + pointSize * 0.28))
            fold.lineWidth = 1.3
            fold.stroke()
            let lines = UIBezierPath()
            for yFrac: CGFloat in [0.42, 0.58, 0.74] {
                lines.move(to: CGPoint(x: r.minX + pointSize * 0.30, y: r.minY + pointSize * yFrac))
                lines.addLine(to: CGPoint(x: r.maxX - pointSize * 0.26, y: r.minY + pointSize * yFrac))
            }
            lines.lineWidth = 1.2
            lines.stroke()

        case .toc:
            // Outline list + bookmark tab.
            let frame = UIBezierPath(
                roundedRect: CGRect(
                    x: r.minX + pointSize * 0.12,
                    y: r.minY + pointSize * 0.10,
                    width: pointSize * 0.58,
                    height: pointSize * 0.80
                ),
                cornerRadius: 1.6
            )
            frame.lineWidth = 1.45
            frame.stroke()
            let lines: [(CGFloat, CGFloat)] = [(0.30, 0.52), (0.48, 0.62), (0.66, 0.48)]
            for (yFrac, wFrac) in lines {
                let y = r.minY + pointSize * yFrac
                let line = UIBezierPath()
                line.move(to: CGPoint(x: r.minX + pointSize * 0.22, y: y))
                line.addLine(to: CGPoint(x: r.minX + pointSize * (0.22 + wFrac), y: y))
                line.lineWidth = 1.35
                line.stroke()
            }
            let tab = UIBezierPath()
            tab.move(to: CGPoint(x: r.maxX - pointSize * 0.22, y: r.minY + pointSize * 0.18))
            tab.addLine(to: CGPoint(x: r.maxX - pointSize * 0.06, y: r.minY + pointSize * 0.18))
            tab.addLine(to: CGPoint(x: r.maxX - pointSize * 0.06, y: r.minY + pointSize * 0.55))
            tab.addLine(to: CGPoint(x: r.maxX - pointSize * 0.14, y: r.minY + pointSize * 0.48))
            tab.addLine(to: CGPoint(x: r.maxX - pointSize * 0.22, y: r.minY + pointSize * 0.55))
            tab.close()
            tab.lineWidth = 1.35
            tab.stroke()

        case .bookmark:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.minX + 5.5, y: r.minY + 2.5))
            path.addLine(to: CGPoint(x: r.maxX - 5.5, y: r.minY + 2.5))
            path.addLine(to: CGPoint(x: r.maxX - 5.5, y: r.maxY - 2.5))
            path.addLine(to: CGPoint(x: r.midX, y: r.maxY - 5.5))
            path.addLine(to: CGPoint(x: r.minX + 5.5, y: r.maxY - 2.5))
            path.close()
            path.lineWidth = 1.55
            path.stroke()
            let notch = UIBezierPath()
            notch.move(to: CGPoint(x: r.midX - 2.2, y: r.minY + 2.5))
            notch.addLine(to: CGPoint(x: r.midX, y: r.minY + 6.5))
            notch.addLine(to: CGPoint(x: r.midX + 2.2, y: r.minY + 2.5))
            notch.lineWidth = 1.45
            notch.stroke()

        case .ask:
            // Speech bubble with question mark — selection Ask.
            let bubble = UIBezierPath(
                roundedRect: CGRect(
                    x: r.minX + pointSize * 0.12,
                    y: r.minY + pointSize * 0.10,
                    width: pointSize * 0.76,
                    height: pointSize * 0.58
                ),
                cornerRadius: pointSize * 0.18
            )
            bubble.lineWidth = 1.5
            bubble.stroke()
            let tail = UIBezierPath()
            tail.move(to: CGPoint(x: r.minX + pointSize * 0.28, y: r.minY + pointSize * 0.64))
            tail.addLine(to: CGPoint(x: r.minX + pointSize * 0.22, y: r.maxY - pointSize * 0.12))
            tail.addLine(to: CGPoint(x: r.minX + pointSize * 0.46, y: r.minY + pointSize * 0.64))
            tail.lineWidth = 1.4
            tail.stroke()
            let mark = NSAttributedString(
                string: "?",
                attributes: [
                    .font: UIFont.systemFont(ofSize: pointSize * 0.42, weight: .bold),
                    .foregroundColor: color
                ]
            )
            let markSize = mark.size()
            mark.draw(at: CGPoint(
                x: r.midX - markSize.width / 2,
                y: r.minY + pointSize * 0.18
            ))

        case .importFile:
            // Tray + downward arrow — import / copy into folder.
            let tray = UIBezierPath()
            tray.move(to: CGPoint(x: r.minX + pointSize * 0.18, y: r.midY + pointSize * 0.08))
            tray.addLine(to: CGPoint(x: r.minX + pointSize * 0.18, y: r.maxY - pointSize * 0.16))
            tray.addLine(to: CGPoint(x: r.maxX - pointSize * 0.18, y: r.maxY - pointSize * 0.16))
            tray.addLine(to: CGPoint(x: r.maxX - pointSize * 0.18, y: r.midY + pointSize * 0.08))
            tray.lineWidth = 1.55
            tray.stroke()
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.12))
            arrow.addLine(to: CGPoint(x: r.midX, y: r.midY + pointSize * 0.18))
            arrow.move(to: CGPoint(x: r.midX - pointSize * 0.18, y: r.midY + pointSize * 0.02))
            arrow.addLine(to: CGPoint(x: r.midX, y: r.midY + pointSize * 0.18))
            arrow.addLine(to: CGPoint(x: r.midX + pointSize * 0.18, y: r.midY + pointSize * 0.02))
            arrow.lineWidth = 1.55
            arrow.stroke()
        }

        let img = (UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()).withRenderingMode(.alwaysTemplate)
        cache.setObject(img, forKey: key)
        return img
    }
}
