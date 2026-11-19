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
        /// Image OCR / vision transcription toggle.
        case imageTranscribe
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
        /// iPhone reader: rotate to landscape / back to portrait.
        case rotate
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
        let key = "v19-\(kind.rawValue)-\(Int(pointSize * 10))-\(color.description)" as NSString
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
            drawSystemSymbol("doc.on.doc", in: r, color: color)

        case .retry:
            drawSystemSymbol("arrow.clockwise", in: r, color: color, weight: .medium)

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
            drawSystemSymbol("arrow.up", in: r, color: color, weight: .bold)

        case .stop:
            drawSystemSymbol("stop.fill", in: r, color: color)

        case .plus, .newChat:
            drawSystemSymbol("plus", in: r, color: color, weight: .semibold)

        case .sidebar:
            drawSystemSymbol("sidebar.left", in: r, color: color)

        case .sidebarOpen:
            drawSystemSymbol("rectangle.lefthalf.inset.filled", in: r, color: color)

        case .more:
            drawSystemSymbol("ellipsis", in: r, color: color, weight: .semibold)

        case .share:
            drawSystemSymbol("square.and.arrow.up", in: r, color: color)

        case .archive:
            drawSystemSymbol("archivebox", in: r, color: color)

        case .settings:
            drawSystemSymbol("gearshape", in: r, color: color)

        case .search:
            drawSystemSymbol("magnifyingglass", in: r, color: color)

        case .globe:
            drawSystemSymbol("globe", in: r, color: color)

        case .think:
            drawSystemSymbol("lightbulb", in: r, color: color)

        case .imageTranscribe:
            drawSystemSymbol("text.viewfinder", in: r, color: color)

        case .ai:
            drawSystemSymbol("sparkles", in: r, color: color)

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
            drawSystemSymbol("brain", in: r, color: color)

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
            drawSystemSymbol("opticaldisc", in: r, color: color)

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
            drawSystemSymbol("pencil", in: r, color: color)

        case .trash:
            drawSystemSymbol("trash", in: r, color: color)

        case .edit:
            drawSystemSymbol("square.and.pencil", in: r, color: color)

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
            drawSystemSymbol("eye", in: r, color: color)

        case .save:
            drawSystemSymbol("square.and.arrow.down", in: r, color: color)

        case .highlighter:
            drawSystemSymbol("highlighter", in: r, color: color)

        case .folder:
            drawSystemSymbol("folder", in: r, color: color)

        case .clock:
            drawSystemSymbol("clock", in: r, color: color)

        case .chevronLeft:
            drawSystemSymbol("chevron.left", in: r, color: color, weight: .semibold)

        case .chevronRight:
            drawSystemSymbol("chevron.right", in: r, color: color, weight: .semibold)

        case .chevronUp:
            drawSystemSymbol("chevron.up", in: r, color: color, weight: .semibold)

        case .chevronDown:
            drawSystemSymbol("chevron.down", in: r, color: color, weight: .semibold)

        case .book:
            drawSystemSymbol("doc.text", in: r, color: color)

        case .docContext:
            drawSystemSymbol("doc", in: r, color: color)

        case .toc:
            drawSystemSymbol("list.bullet", in: r, color: color)

        case .bookmark:
            drawSystemSymbol("bookmark", in: r, color: color)

        case .appearanceSun:
            // Pair with moon: SF Symbol reads clearly at chrome size.
            drawSystemSymbol("sun.max", in: r, color: color)

        case .appearanceMoon:
            // Hand-drawn arcs looked like an abstract blob; SF `moon.fill` is a clear crescent.
            drawSystemSymbol("moon.fill", in: r, color: color)

        case .ask:
            drawSystemSymbol("questionmark.bubble", in: r, color: color)

        case .importFile:
            drawSystemSymbol("tray.and.arrow.down", in: r, color: color)

        case .rotate:
            drawSystemSymbol("rotate.right", in: r, color: color)
        }

        let img = (UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()).withRenderingMode(.alwaysTemplate)
        cache.setObject(img, forKey: key)
        return img
    }

    /// Draw an SF Symbol centered in `rect` (same canvas as hand-drawn glyphs).
    private static func drawSystemSymbol(
        _ name: String,
        in rect: CGRect,
        color: UIColor,
        weight: UIImage.SymbolWeight = .regular
    ) {
        let config = UIImage.SymbolConfiguration(pointSize: rect.width * 0.88, weight: weight)
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
