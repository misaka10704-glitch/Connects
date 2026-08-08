import UIKit

/// ChatGPT-like template glyphs (drawn at screen scale — never stretch PNG points).
enum ActionIconFactory {
    private static let cache = NSCache<NSString, UIImage>()

    // MARK: - Size tokens (single source of truth)

    /// Reader top bars, floating sidebar, nav bar items.
    static let chromeGlyph: CGFloat = 18
    /// Composer tool row (attach / search / think / Ask / capture).
    static let toolGlyph: CGFloat = 16
    /// ConnectsMenu + compact Study chrome clusters.
    static let menuGlyph: CGFloat = 15
    /// Message copy / retry / fork.
    static let messageActionGlyph: CGFloat = 16
    /// Inline search-field leading icon.
    static let fieldGlyph: CGFloat = 14
    /// Send / stop glyphs inside the circular action button.
    static let sendGlyph: CGFloat = 14
    /// Tiny AI spark on model chip.
    static let chipGlyph: CGFloat = 11
    /// Reader / nav icon button hit target.
    static let hitTarget: CGFloat = 40

    enum Kind: String {
        case copy, retry, fork, send, stop, plus
        case sidebar, sidebarOpen
        case more, share
        case archive, settings, search
        case globe
        case think
        case ai
        case aiEdit
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
        /// Attach / include current document content in the prompt.
        case docContext
        case toc, bookmark
        case clock
        /// Reader appearance toggle — moon for dark mode (tap → light).
        case appearanceMoon
        /// Reader appearance toggle — sun for light mode (tap → dark).
        case appearanceSun
        /// Selection Ask in the composer (speech-bubble + ?).
        case ask
        /// Import / copy file into workspace.
        case importFile
    }

    static func barItem(kind: Kind, target: Any?, action: Selector, accessibility: String) -> UIBarButtonItem {
        barItem(kind: kind, pointSize: chromeGlyph, target: target, action: action, accessibility: accessibility)
    }

    static func barItem(kind: Kind, pointSize: CGFloat, target: Any?, action: Selector, accessibility: String) -> UIBarButtonItem {
        let img = image(kind, pointSize: pointSize)
        let item = UIBarButtonItem(image: img, style: .plain, target: target, action: action)
        item.accessibilityLabel = accessibility
        return item
    }

    /// Apply chrome glyph + centered image mode on a top-bar icon button.
    static func configureChromeButton(_ button: UIButton, kind: Kind, accessibility: String? = nil) {
        button.setImage(image(kind, pointSize: chromeGlyph), for: .normal)
        button.imageView?.contentMode = .center
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        if let accessibility {
            button.accessibilityLabel = accessibility
        }
    }

    static func image(_ kind: Kind, pointSize: CGFloat = chromeGlyph, color: UIColor = .black) -> UIImage {
        let key = "v17-\(kind.rawValue)-\(Int(pointSize * 10))-\(color.description)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let canvas = ceil(pointSize + 8)
        let size = CGSize(width: canvas, height: canvas)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }

        let lw = strokeWidth(for: pointSize)
        let lwThin = max(1.05, lw * 0.82)
        let lwThick = lw * 1.12

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(lw)
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
            pathB.lineWidth = lw
            pathF.lineWidth = lw
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
            arc.lineWidth = lw
            arc.stroke()
            let tip = CGPoint(x: c.x + rad * cos(-.pi * 0.15), y: c.y + rad * sin(-.pi * 0.15))
            let head = UIBezierPath()
            head.move(to: CGPoint(x: tip.x - 3.2, y: tip.y - 1.2))
            head.addLine(to: tip)
            head.addLine(to: CGPoint(x: tip.x - 1.0, y: tip.y + 3.4))
            head.lineWidth = lw
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
            path.lineWidth = lw
            path.stroke()
            let nodeR = max(1.6, pointSize * 0.11)
            for p in [left, bot, right] {
                UIBezierPath(ovalIn: CGRect(x: p.x - nodeR, y: p.y - nodeR, width: nodeR * 2, height: nodeR * 2)).fill()
            }

        case .send:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.midX, y: r.minY + 2))
            path.addLine(to: CGPoint(x: r.midX, y: r.maxY - 2))
            path.move(to: CGPoint(x: r.midX - 4.5, y: r.minY + 7))
            path.addLine(to: CGPoint(x: r.midX, y: r.minY + 2))
            path.addLine(to: CGPoint(x: r.midX + 4.5, y: r.minY + 7))
            path.lineWidth = lwThick
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
            path.lineWidth = lwThick
            path.stroke()

        case .sidebar:
            // Collapsed → open: empty panel + left rail (outline only).
            let frame = r.insetBy(dx: pointSize * 0.10, dy: pointSize * 0.14)
            let outer = UIBezierPath(roundedRect: frame, cornerRadius: 2.4)
            outer.lineWidth = lw
            outer.stroke()
            let railX = frame.minX + frame.width * 0.34
            let rail = UIBezierPath()
            rail.move(to: CGPoint(x: railX, y: frame.minY))
            rail.addLine(to: CGPoint(x: railX, y: frame.maxY))
            rail.lineWidth = lw
            rail.stroke()

        case .sidebarOpen:
            // Open → close: filled left pane + inward chevron.
            let frame = r.insetBy(dx: pointSize * 0.10, dy: pointSize * 0.14)
            let outer = UIBezierPath(roundedRect: frame, cornerRadius: 2.4)
            outer.lineWidth = lw
            outer.stroke()
            let paneW = frame.width * 0.34
            let pane = UIBezierPath(
                roundedRect: CGRect(x: frame.minX, y: frame.minY, width: paneW, height: frame.height),
                byRoundingCorners: [.topLeft, .bottomLeft],
                cornerRadii: CGSize(width: 2.4, height: 2.4)
            )
            pane.fill()
            let chev = UIBezierPath()
            let cx = frame.minX + frame.width * 0.68
            chev.move(to: CGPoint(x: cx + pointSize * 0.10, y: r.midY - pointSize * 0.18))
            chev.addLine(to: CGPoint(x: cx - pointSize * 0.06, y: r.midY))
            chev.addLine(to: CGPoint(x: cx + pointSize * 0.10, y: r.midY + pointSize * 0.18))
            chev.lineWidth = lw
            color.setStroke()
            chev.stroke()

        case .more:
            let rad = max(1.2, pointSize * 0.075)
            for i in 0..<3 {
                let cx = r.minX + pointSize * (0.22 + CGFloat(i) * 0.28)
                UIBezierPath(ovalIn: CGRect(x: cx - rad, y: r.midY - rad, width: rad * 2, height: rad * 2)).fill()
            }

        case .share:
            // Tray + bold upward arrow (export out).
            let tray = UIBezierPath()
            tray.move(to: CGPoint(x: r.minX + pointSize * 0.16, y: r.midY + pointSize * 0.10))
            tray.addLine(to: CGPoint(x: r.minX + pointSize * 0.16, y: r.maxY - pointSize * 0.14))
            tray.addLine(to: CGPoint(x: r.maxX - pointSize * 0.16, y: r.maxY - pointSize * 0.14))
            tray.addLine(to: CGPoint(x: r.maxX - pointSize * 0.16, y: r.midY + pointSize * 0.10))
            tray.lineWidth = lw
            tray.stroke()
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: r.midX, y: r.maxY - pointSize * 0.28))
            arrow.addLine(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.12))
            arrow.move(to: CGPoint(x: r.midX - pointSize * 0.20, y: r.minY + pointSize * 0.32))
            arrow.addLine(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.12))
            arrow.addLine(to: CGPoint(x: r.midX + pointSize * 0.20, y: r.minY + pointSize * 0.32))
            arrow.lineWidth = lwThick
            arrow.stroke()

        case .archive:
            let lid = UIBezierPath()
            lid.move(to: CGPoint(x: r.minX + 2, y: r.minY + 5.5))
            lid.addLine(to: CGPoint(x: r.minX + 4, y: r.minY + 2.5))
            lid.addLine(to: CGPoint(x: r.maxX - 4, y: r.minY + 2.5))
            lid.addLine(to: CGPoint(x: r.maxX - 2, y: r.minY + 5.5))
            lid.close()
            lid.lineWidth = lw
            lid.stroke()
            let box = UIBezierPath(roundedRect: CGRect(x: r.minX + 2.5, y: r.minY + 5.5, width: pointSize - 5, height: pointSize - 8), cornerRadius: 1.5)
            box.lineWidth = lw
            box.stroke()
            let slit = UIBezierPath()
            slit.move(to: CGPoint(x: r.midX - 2.5, y: r.midY + 1.5))
            slit.addLine(to: CGPoint(x: r.midX + 2.5, y: r.midY + 1.5))
            slit.lineWidth = lw
            slit.stroke()

        case .settings:
            // Proper six-tooth gear (inner hub + outer ring + teeth).
            let c = CGPoint(x: r.midX, y: r.midY)
            let outerR = pointSize * 0.38
            let toothOut = pointSize * 0.48
            let toothHalf = CGFloat.pi / 12
            let gear = UIBezierPath()
            for i in 0..<6 {
                let a = CGFloat(i) * (CGFloat.pi / 3) - CGFloat.pi / 2
                let a0 = a - toothHalf
                let a1 = a + toothHalf
                let next = a + CGFloat.pi / 3
                let pOuter0 = CGPoint(x: c.x + outerR * cos(a0), y: c.y + outerR * sin(a0))
                let pTooth0 = CGPoint(x: c.x + toothOut * cos(a0), y: c.y + toothOut * sin(a0))
                let pTooth1 = CGPoint(x: c.x + toothOut * cos(a1), y: c.y + toothOut * sin(a1))
                let pOuter1 = CGPoint(x: c.x + outerR * cos(a1), y: c.y + outerR * sin(a1))
                if i == 0 {
                    let start = a0 - toothHalf
                    gear.move(to: CGPoint(x: c.x + outerR * cos(start), y: c.y + outerR * sin(start)))
                }
                gear.addLine(to: pOuter0)
                gear.addLine(to: pTooth0)
                gear.addLine(to: pTooth1)
                gear.addLine(to: pOuter1)
                gear.addArc(withCenter: c, radius: outerR, startAngle: a1, endAngle: next - toothHalf, clockwise: true)
            }
            gear.close()
            gear.lineWidth = lw
            gear.stroke()
            let hubR = pointSize * 0.12
            let hub = UIBezierPath(ovalIn: CGRect(x: c.x - hubR, y: c.y - hubR, width: hubR * 2, height: hubR * 2))
            hub.lineWidth = lw
            hub.stroke()

        case .search:
            let circle = UIBezierPath(ovalIn: CGRect(x: r.minX + 2, y: r.minY + 2, width: pointSize * 0.55, height: pointSize * 0.55))
            circle.lineWidth = lw
            circle.stroke()
            let handle = UIBezierPath()
            handle.move(to: CGPoint(x: r.minX + pointSize * 0.55, y: r.minY + pointSize * 0.55))
            handle.addLine(to: CGPoint(x: r.maxX - 2.5, y: r.maxY - 2.5))
            handle.lineWidth = lwThick
            handle.stroke()

        case .globe:
            let oval = UIBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
            oval.lineWidth = lw
            oval.stroke()
            let midV = UIBezierPath()
            midV.move(to: CGPoint(x: r.midX, y: r.minY + 1.5))
            midV.addLine(to: CGPoint(x: r.midX, y: r.maxY - 1.5))
            midV.lineWidth = lwThin
            midV.stroke()
            let eq = UIBezierPath()
            eq.move(to: CGPoint(x: r.minX + 1.5, y: r.midY))
            eq.addLine(to: CGPoint(x: r.maxX - 1.5, y: r.midY))
            eq.lineWidth = lwThin
            eq.stroke()
            let lat = UIBezierPath(ovalIn: CGRect(x: r.midX - pointSize * 0.18, y: r.minY + 1.5,
                                                  width: pointSize * 0.36, height: pointSize - 3))
            lat.lineWidth = lwThin
            lat.stroke()

        case .think:
            let bulb = UIBezierPath(
                ovalIn: CGRect(
                    x: r.midX - pointSize * 0.28,
                    y: r.minY + 1.8,
                    width: pointSize * 0.56,
                    height: pointSize * 0.56
                )
            )
            bulb.lineWidth = lw
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
            neck.lineWidth = lwThin
            neck.stroke()
            let base = UIBezierPath()
            base.move(to: CGPoint(x: r.midX - pointSize * 0.16, y: r.maxY - 3.2))
            base.addLine(to: CGPoint(x: r.midX + pointSize * 0.16, y: r.maxY - 3.2))
            base.lineWidth = lw
            base.stroke()
            let filament = UIBezierPath()
            filament.move(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.22))
            filament.addLine(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.42))
            filament.lineWidth = lwThin
            filament.stroke()

        case .ai:
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
            spark.lineWidth = lwThin
            spark.stroke()
            UIBezierPath(
                ovalIn: CGRect(x: cx - 1.2, y: cy - 1.2, width: 2.4, height: 2.4)
            ).fill()

        case .aiEdit:
            // Composer “AI may edit”: fat diagonal pencil.
            let thick = pointSize * 0.32
            let halfLen = pointSize * 0.38
            ctx.saveGState()
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.rotate(by: -CGFloat.pi / 4)
            // Eraser
            UIBezierPath(
                roundedRect: CGRect(x: -thick / 2, y: -halfLen - pointSize * 0.02, width: thick, height: pointSize * 0.13),
                cornerRadius: thick * 0.22
            ).fill()
            // Body
            UIBezierPath(
                roundedRect: CGRect(x: -thick / 2, y: -halfLen + pointSize * 0.10, width: thick, height: halfLen * 1.15),
                cornerRadius: thick * 0.16
            ).fill()
            // Tip
            let tip = UIBezierPath()
            tip.move(to: CGPoint(x: -thick / 2, y: halfLen * 0.22))
            tip.addLine(to: CGPoint(x: 0, y: halfLen + pointSize * 0.06))
            tip.addLine(to: CGPoint(x: thick / 2, y: halfLen * 0.22))
            tip.close()
            tip.fill()
            // Ferrule line
            let band = UIBezierPath()
            band.move(to: CGPoint(x: -thick / 2, y: halfLen * 0.18))
            band.addLine(to: CGPoint(x: thick / 2, y: halfLen * 0.18))
            band.lineWidth = max(lwThick, 2.0)
            color.setStroke()
            // Draw band as a clear gap then stroke edge for separation.
            ctx.setBlendMode(.clear)
            UIBezierPath(rect: CGRect(x: -thick / 2, y: halfLen * 0.14, width: thick, height: pointSize * 0.07)).fill()
            ctx.setBlendMode(.normal)
            color.setFill()
            tip.fill()
            band.stroke()
            ctx.restoreGState()

        case .brain:
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
            left.lineWidth = lw
            right.lineWidth = lw
            left.stroke()
            right.stroke()
            let cleft = UIBezierPath()
            cleft.move(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.28))
            cleft.addLine(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.62))
            cleft.lineWidth = lwThin
            cleft.stroke()
            let stem = UIBezierPath()
            stem.move(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.68))
            stem.addLine(to: CGPoint(x: r.midX, y: r.maxY - pointSize * 0.12))
            stem.lineWidth = lw
            stem.stroke()

        case .memory:
            let back = UIBezierPath(
                roundedRect: CGRect(
                    x: r.minX + pointSize * 0.22,
                    y: r.minY + pointSize * 0.10,
                    width: pointSize * 0.58,
                    height: pointSize * 0.70
                ),
                cornerRadius: 1.8
            )
            back.lineWidth = lwThin
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
            front.lineWidth = lw
            front.stroke()
            let mark = UIBezierPath()
            mark.move(to: CGPoint(x: r.minX + pointSize * 0.28, y: r.minY + pointSize * 0.34))
            mark.addLine(to: CGPoint(x: r.minX + pointSize * 0.28, y: r.minY + pointSize * 0.72))
            mark.addLine(to: CGPoint(x: r.minX + pointSize * 0.39, y: r.minY + pointSize * 0.64))
            mark.addLine(to: CGPoint(x: r.minX + pointSize * 0.50, y: r.minY + pointSize * 0.72))
            mark.addLine(to: CGPoint(x: r.minX + pointSize * 0.50, y: r.minY + pointSize * 0.34))
            mark.lineWidth = lwThin
            mark.stroke()

        case .vinyl:
            let disc = UIBezierPath(ovalIn: r.insetBy(dx: 1.4, dy: 1.4))
            disc.lineWidth = lw; disc.stroke()
            let groove = UIBezierPath(ovalIn: r.insetBy(dx: pointSize * 0.25, dy: pointSize * 0.25))
            groove.lineWidth = lwThin; groove.stroke()
            UIBezierPath(ovalIn: CGRect(x: r.midX - 1.6, y: r.midY - 1.6, width: 3.2, height: 3.2)).fill()

        case .tshirt:
            let badge = UIBezierPath(
                roundedRect: r.insetBy(dx: pointSize * 0.08, dy: pointSize * 0.08),
                cornerRadius: pointSize * 0.22
            )
            badge.lineWidth = lw
            badge.stroke()
            let head = UIBezierPath(
                ovalIn: CGRect(
                    x: r.midX - pointSize * 0.16,
                    y: r.minY + pointSize * 0.20,
                    width: pointSize * 0.32,
                    height: pointSize * 0.32
                )
            )
            head.lineWidth = lw
            head.stroke()
            let shoulders = UIBezierPath(
                arcCenter: CGPoint(x: r.midX, y: r.maxY - pointSize * 0.18),
                radius: pointSize * 0.28,
                startAngle: .pi * 1.12,
                endAngle: .pi * (-0.12),
                clockwise: true
            )
            shoulders.lineWidth = lw
            shoulders.stroke()

        case .rename:
            let body = UIBezierPath()
            body.move(to: CGPoint(x: r.minX + 3.5, y: r.maxY - 4))
            body.addLine(to: CGPoint(x: r.maxX - 5.5, y: r.minY + 4))
            body.lineWidth = lw
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
            base.lineWidth = lwThin
            base.stroke()

        case .trash:
            let lid = UIBezierPath()
            lid.move(to: CGPoint(x: r.minX + 3, y: r.minY + 5))
            lid.addLine(to: CGPoint(x: r.maxX - 3, y: r.minY + 5))
            lid.move(to: CGPoint(x: r.midX - 2.5, y: r.minY + 5))
            lid.addLine(to: CGPoint(x: r.midX - 2.5, y: r.minY + 3.2))
            lid.addLine(to: CGPoint(x: r.midX + 2.5, y: r.minY + 3.2))
            lid.addLine(to: CGPoint(x: r.midX + 2.5, y: r.minY + 5))
            lid.lineWidth = lw
            lid.stroke()
            let can = UIBezierPath(roundedRect: CGRect(x: r.minX + 4, y: r.minY + 5.5,
                                                       width: pointSize - 8, height: pointSize - 8.5),
                                   cornerRadius: 1.2)
            can.lineWidth = lw
            can.stroke()
            for dx in [-2.0, 0.0, 2.0] as [CGFloat] {
                let slit = UIBezierPath()
                slit.move(to: CGPoint(x: r.midX + dx, y: r.minY + 8))
                slit.addLine(to: CGPoint(x: r.midX + dx, y: r.maxY - 4.5))
                slit.lineWidth = lwThin
                slit.stroke()
            }

        case .edit:
            let box = UIBezierPath(roundedRect: r.insetBy(dx: 1.8, dy: 1.8), cornerRadius: 2.2)
            box.lineWidth = lw
            box.stroke()
            let pen = UIBezierPath()
            pen.move(to: CGPoint(x: r.minX + 5, y: r.maxY - 5.5))
            pen.addLine(to: CGPoint(x: r.maxX - 5.5, y: r.minY + 5))
            pen.lineWidth = lw
            pen.stroke()
            let tip = UIBezierPath()
            tip.move(to: CGPoint(x: r.maxX - 5.5, y: r.minY + 5))
            tip.addLine(to: CGPoint(x: r.maxX - 3.5, y: r.minY + 7))
            tip.addLine(to: CGPoint(x: r.maxX - 5.2, y: r.minY + 8.7))
            tip.close()
            tip.fill()

        case .editMode:
            // File chrome “enter edit”: fat vertical pencil.
            let bodyW = pointSize * 0.34
            let body = UIBezierPath(
                roundedRect: CGRect(
                    x: r.midX - bodyW / 2,
                    y: r.minY + pointSize * 0.14,
                    width: bodyW,
                    height: pointSize * 0.48
                ),
                cornerRadius: bodyW * 0.18
            )
            body.fill()
            // Ferrule (clear band via stroke ring on top of tip join)
            let by = r.minY + pointSize * 0.60
            let ferrule = UIBezierPath(
                rect: CGRect(x: r.midX - bodyW / 2, y: by - pointSize * 0.04, width: bodyW, height: pointSize * 0.08)
            )
            // Punch a light gap: stroke outline only for ferrule separation.
            ctx.setBlendMode(.clear)
            ferrule.fill()
            ctx.setBlendMode(.normal)
            color.setFill()
            color.setStroke()
            let ferruleStroke = UIBezierPath()
            ferruleStroke.move(to: CGPoint(x: r.midX - bodyW / 2, y: by))
            ferruleStroke.addLine(to: CGPoint(x: r.midX + bodyW / 2, y: by))
            ferruleStroke.lineWidth = lwThick
            ferruleStroke.stroke()
            // Tip (down)
            let tip = UIBezierPath()
            tip.move(to: CGPoint(x: r.midX - bodyW / 2, y: by))
            tip.addLine(to: CGPoint(x: r.midX, y: r.maxY - pointSize * 0.08))
            tip.addLine(to: CGPoint(x: r.midX + bodyW / 2, y: by))
            tip.close()
            tip.fill()
            // Eraser cap
            let eraser = UIBezierPath(
                roundedRect: CGRect(
                    x: r.midX - bodyW / 2,
                    y: r.minY + pointSize * 0.06,
                    width: bodyW,
                    height: pointSize * 0.12
                ),
                cornerRadius: bodyW * 0.2
            )
            eraser.fill()

        case .readMode:
            // Eye — “tap to view / preview”. Pairs with the pencil edit glyph.
            let eye = UIBezierPath()
            eye.move(to: CGPoint(x: r.minX + pointSize * 0.12, y: r.midY))
            eye.addQuadCurve(
                to: CGPoint(x: r.maxX - pointSize * 0.12, y: r.midY),
                controlPoint: CGPoint(x: r.midX, y: r.minY + pointSize * 0.18)
            )
            eye.addQuadCurve(
                to: CGPoint(x: r.minX + pointSize * 0.12, y: r.midY),
                controlPoint: CGPoint(x: r.midX, y: r.maxY - pointSize * 0.18)
            )
            eye.close()
            eye.lineWidth = lw
            eye.stroke()
            let irisR = pointSize * 0.14
            let iris = UIBezierPath(ovalIn: CGRect(
                x: r.midX - irisR,
                y: r.midY - irisR,
                width: irisR * 2,
                height: irisR * 2
            ))
            iris.lineWidth = lw
            iris.stroke()
            let pupilR = pointSize * 0.055
            UIBezierPath(ovalIn: CGRect(
                x: r.midX - pupilR,
                y: r.midY - pupilR,
                width: pupilR * 2,
                height: pupilR * 2
            )).fill()

        case .save:
            let body = UIBezierPath(roundedRect: r.insetBy(dx: pointSize * 0.16, dy: pointSize * 0.16), cornerRadius: 1.8)
            body.lineWidth = lw
            body.stroke()
            let label = UIBezierPath(
                roundedRect: CGRect(x: r.minX + pointSize * 0.28, y: r.minY + pointSize * 0.18,
                                    width: pointSize * 0.44, height: pointSize * 0.22),
                cornerRadius: 1.0
            )
            label.lineWidth = lwThin
            label.stroke()
            let window = UIBezierPath(
                roundedRect: CGRect(x: r.minX + pointSize * 0.28, y: r.midY + pointSize * 0.02,
                                    width: pointSize * 0.44, height: pointSize * 0.24),
                cornerRadius: 1.0
            )
            window.lineWidth = lwThin
            window.stroke()

        case .highlighter:
            let barrel = UIBezierPath(
                roundedRect: CGRect(
                    x: r.minX + pointSize * 0.18,
                    y: r.minY + pointSize * 0.28,
                    width: pointSize * 0.52,
                    height: pointSize * 0.28
                ),
                cornerRadius: 1.4
            )
            barrel.lineWidth = lw
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
            swipe.lineWidth = lwThick * 1.2
            swipe.stroke()

        case .folder:
            let tab = UIBezierPath()
            tab.move(to: CGPoint(x: r.minX + 2.5, y: r.minY + 5.5))
            tab.addLine(to: CGPoint(x: r.minX + 5.5, y: r.minY + 3))
            tab.addLine(to: CGPoint(x: r.minX + pointSize * 0.48, y: r.minY + 3))
            tab.addLine(to: CGPoint(x: r.minX + pointSize * 0.58, y: r.minY + 5.5))
            tab.lineWidth = lw
            tab.stroke()
            let body = UIBezierPath(roundedRect: CGRect(x: r.minX + 2.2, y: r.minY + 5.5,
                                                        width: pointSize - 4.4, height: pointSize - 7.8),
                                     cornerRadius: 1.8)
            body.lineWidth = lw
            body.stroke()

        case .clock:
            let c = CGPoint(x: r.midX, y: r.midY)
            let rad = pointSize * 0.38
            let circle = UIBezierPath(arcCenter: c, radius: rad, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            circle.lineWidth = lw
            circle.stroke()
            let hands = UIBezierPath()
            hands.move(to: c)
            hands.addLine(to: CGPoint(x: c.x, y: c.y - rad * 0.55))
            hands.move(to: c)
            hands.addLine(to: CGPoint(x: c.x + rad * 0.42, y: c.y + rad * 0.12))
            hands.lineWidth = lw
            hands.stroke()

        case .chevronLeft:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.midX + 2.2, y: r.minY + 3.5))
            path.addLine(to: CGPoint(x: r.midX - 2.4, y: r.midY))
            path.addLine(to: CGPoint(x: r.midX + 2.2, y: r.maxY - 3.5))
            path.lineWidth = lwThick
            path.stroke()

        case .chevronRight:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.midX - 2.2, y: r.minY + 3.5))
            path.addLine(to: CGPoint(x: r.midX + 2.4, y: r.midY))
            path.addLine(to: CGPoint(x: r.midX - 2.2, y: r.maxY - 3.5))
            path.lineWidth = lwThick
            path.stroke()

        case .chevronUp:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.minX + 3.5, y: r.midY + 2.2))
            path.addLine(to: CGPoint(x: r.midX, y: r.midY - 2.4))
            path.addLine(to: CGPoint(x: r.maxX - 3.5, y: r.midY + 2.2))
            path.lineWidth = lwThick
            path.stroke()

        case .chevronDown:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.minX + 3.5, y: r.midY - 2.2))
            path.addLine(to: CGPoint(x: r.midX, y: r.midY + 2.4))
            path.addLine(to: CGPoint(x: r.maxX - 3.5, y: r.midY - 2.2))
            path.lineWidth = lwThick
            path.stroke()

        case .book:
            // Simple document — file-type / reading label (not the composer context toggle).
            let page = UIBezierPath(
                roundedRect: CGRect(
                    x: r.minX + pointSize * 0.18,
                    y: r.minY + pointSize * 0.10,
                    width: pointSize * 0.64,
                    height: pointSize * 0.80
                ),
                cornerRadius: 1.8
            )
            page.lineWidth = lw
            page.stroke()
            let fold = UIBezierPath()
            fold.move(to: CGPoint(x: r.maxX - pointSize * 0.34, y: r.minY + pointSize * 0.10))
            fold.addLine(to: CGPoint(x: r.maxX - pointSize * 0.34, y: r.minY + pointSize * 0.28))
            fold.addLine(to: CGPoint(x: r.maxX - pointSize * 0.18, y: r.minY + pointSize * 0.28))
            fold.lineWidth = lwThin
            fold.stroke()
            let lines = UIBezierPath()
            for yFrac: CGFloat in [0.42, 0.56, 0.70] {
                lines.move(to: CGPoint(x: r.minX + pointSize * 0.30, y: r.minY + pointSize * yFrac))
                lines.addLine(to: CGPoint(x: r.maxX - pointSize * 0.30, y: r.minY + pointSize * yFrac))
            }
            lines.lineWidth = lwThin
            lines.stroke()

        case .docContext:
            // Composer “include file content”: plain page — nothing else.
            let page = UIBezierPath(
                roundedRect: CGRect(
                    x: r.minX + pointSize * 0.20,
                    y: r.minY + pointSize * 0.12,
                    width: pointSize * 0.60,
                    height: pointSize * 0.76
                ),
                cornerRadius: 2.0
            )
            page.lineWidth = lwThick
            page.stroke()
            let lines = UIBezierPath()
            for yFrac: CGFloat in [0.38, 0.52, 0.66] {
                lines.move(to: CGPoint(x: r.minX + pointSize * 0.32, y: r.minY + pointSize * yFrac))
                lines.addLine(to: CGPoint(x: r.maxX - pointSize * 0.32, y: r.minY + pointSize * yFrac))
            }
            lines.lineWidth = lw
            lines.stroke()

        case .toc:
            // Outline list + left rail (no bookmark corner — distinct from .bookmark).
            let rail = UIBezierPath()
            rail.move(to: CGPoint(x: r.minX + pointSize * 0.18, y: r.minY + pointSize * 0.14))
            rail.addLine(to: CGPoint(x: r.minX + pointSize * 0.18, y: r.maxY - pointSize * 0.14))
            rail.lineWidth = lwThick
            rail.stroke()
            let rows: [(CGFloat, CGFloat)] = [(0.28, 0.70), (0.50, 0.58), (0.72, 0.64)]
            for (yFrac, wFrac) in rows {
                let y = r.minY + pointSize * yFrac
                let bul = UIBezierPath(ovalIn: CGRect(
                    x: r.minX + pointSize * 0.28 - pointSize * 0.045,
                    y: y - pointSize * 0.045,
                    width: pointSize * 0.09,
                    height: pointSize * 0.09
                ))
                bul.fill()
                let line = UIBezierPath()
                line.move(to: CGPoint(x: r.minX + pointSize * 0.38, y: y))
                line.addLine(to: CGPoint(x: r.minX + pointSize * (0.38 + wFrac * 0.52), y: y))
                line.lineWidth = lw
                line.stroke()
            }

        case .bookmark:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: r.minX + 5.5, y: r.minY + 2.5))
            path.addLine(to: CGPoint(x: r.maxX - 5.5, y: r.minY + 2.5))
            path.addLine(to: CGPoint(x: r.maxX - 5.5, y: r.maxY - 2.5))
            path.addLine(to: CGPoint(x: r.midX, y: r.maxY - 5.5))
            path.addLine(to: CGPoint(x: r.minX + 5.5, y: r.maxY - 2.5))
            path.close()
            path.lineWidth = lw
            path.stroke()

        case .appearanceSun:
            // Pair with moon: SF Symbol reads clearly at chrome size.
            drawSystemSymbol("sun.max", in: r, color: color)

        case .appearanceMoon:
            // Hand-drawn arcs looked like an abstract blob; SF `moon.fill` is a clear crescent.
            drawSystemSymbol("moon.fill", in: r, color: color)

        case .ask:
            // Single continuous "?" stroke: bowl → inward curve → stem, then a separate disc.
            let qx = r.midX
            let stroke = pointSize * 0.20
            let path = UIBezierPath()
            // Left of the bowl
            path.move(to: CGPoint(x: qx - pointSize * 0.20, y: r.minY + pointSize * 0.34))
            // Over the top to the right side
            path.addCurve(
                to: CGPoint(x: qx + pointSize * 0.22, y: r.minY + pointSize * 0.36),
                controlPoint1: CGPoint(x: qx - pointSize * 0.22, y: r.minY + pointSize * 0.10),
                controlPoint2: CGPoint(x: qx + pointSize * 0.26, y: r.minY + pointSize * 0.10)
            )
            // Soft turn into the vertical stem (no hard kink)
            path.addCurve(
                to: CGPoint(x: qx, y: r.minY + pointSize * 0.54),
                controlPoint1: CGPoint(x: qx + pointSize * 0.20, y: r.minY + pointSize * 0.50),
                controlPoint2: CGPoint(x: qx, y: r.minY + pointSize * 0.46)
            )
            path.lineWidth = stroke
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
            let dotR = pointSize * 0.115
            let dotCenterY = r.minY + pointSize * 0.80
            color.setFill()
            UIBezierPath(ovalIn: CGRect(
                x: qx - dotR,
                y: dotCenterY - dotR,
                width: dotR * 2,
                height: dotR * 2
            )).fill()

        case .importFile:
            // Tray + bold downward arrow (import in).
            let tray = UIBezierPath()
            tray.move(to: CGPoint(x: r.minX + pointSize * 0.16, y: r.midY + pointSize * 0.06))
            tray.addLine(to: CGPoint(x: r.minX + pointSize * 0.16, y: r.maxY - pointSize * 0.14))
            tray.addLine(to: CGPoint(x: r.maxX - pointSize * 0.16, y: r.maxY - pointSize * 0.14))
            tray.addLine(to: CGPoint(x: r.maxX - pointSize * 0.16, y: r.midY + pointSize * 0.06))
            tray.lineWidth = lw
            tray.stroke()
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: r.midX, y: r.minY + pointSize * 0.10))
            arrow.addLine(to: CGPoint(x: r.midX, y: r.midY + pointSize * 0.22))
            arrow.move(to: CGPoint(x: r.midX - pointSize * 0.20, y: r.midY + pointSize * 0.04))
            arrow.addLine(to: CGPoint(x: r.midX, y: r.midY + pointSize * 0.22))
            arrow.addLine(to: CGPoint(x: r.midX + pointSize * 0.20, y: r.midY + pointSize * 0.04))
            arrow.lineWidth = lwThick
            arrow.stroke()
        }

        let img = (UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()).withRenderingMode(.alwaysTemplate)
        cache.setObject(img, forKey: key)
        return img
    }

    /// Draw an SF Symbol centered in `rect` (same canvas as hand-drawn glyphs).
    private static func drawSystemSymbol(_ name: String, in rect: CGRect, color: UIColor) {
        let config = UIImage.SymbolConfiguration(pointSize: rect.width * 0.88, weight: .regular)
        guard let symbol = UIImage(systemName: name, withConfiguration: config) else { return }
        let tinted = symbol.withTintColor(color, renderingMode: .alwaysOriginal)
        let s = tinted.size
        guard s.width > 0, s.height > 0 else { return }
        let scale = min(rect.width / s.width, rect.height / s.height) * 0.92
        let w = s.width * scale
        let h = s.height * scale
        tinted.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    private static func strokeWidth(for pointSize: CGFloat, base: CGFloat = 1.55) -> CGFloat {
        max(1.1, base * (pointSize / chromeGlyph))
    }
}
