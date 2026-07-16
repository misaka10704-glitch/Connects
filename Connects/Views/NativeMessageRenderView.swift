import UIKit

struct NativeConfigureResult {
    let height: CGFloat
    /// True while iosMath is still warming; row height must not be cached yet.
    let isProvisional: Bool
}

final class NativeMessageRenderView: UIView {
    var onHeightChange: ((CGFloat) -> Void)?
    /// Return true when a host view controller handled the link internally.
    var onLinkTap: ((URL) -> Bool)?
    private(set) var layout: NativeMessageLayout?
    private var layoutKey: String?
    private var requestKey: String?
    private var renderGeneration = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = true
        // First paint of long replies can hitch the scroll thread; async draw helps iOS 12.
        layer.drawsAsynchronously = true
    }

    @discardableResult
    func configure(content: String,
                   width: CGFloat,
                   fontSize: CGFloat,
                   appearance: String,
                   colors: ThemeColors) -> NativeConfigureResult {
        let style = NativeLayoutStyle(
            width: max(width, 40),
            bodyFontSize: fontSize,
            appearance: appearance,
            colors: colors
        )
        let contentStamp = NativeMarkdownParser.shared.layoutStamp(for: content)
        let nextRequestKey = "\(contentStamp)|\(style.keySuffix)"
        if requestKey == nextRequestKey, let current = layout {
            return NativeConfigureResult(
                height: current.size.height,
                isProvisional: isPreviewLayout(current)
            )
        }
        requestKey = nextRequestKey
        renderGeneration += 1
        let generation = renderGeneration

        if let final = NativeMessageLayouter.shared.cachedLayout(
            contentStamp: contentStamp,
            style: style
        ) {
            apply(final)
            return NativeConfigureResult(height: final.size.height, isProvisional: false)
        }

        let document = NativeMarkdownParser.shared.parse(content)

        let formulas = formulaRequests(document)
        hydrateCachedFormulas(formulas, style: style)

        if formulas.isEmpty || formulas.allSatisfy({ formula in
            formulaIsReady(formula, style: style)
        }) {
            let final = NativeMessageLayouter.shared.layout(document: document, style: style)
            apply(final)
            return NativeConfigureResult(height: final.size.height, isProvisional: false)
        }

        let preview = NativeMessageLayouter.shared.layout(
            document: document,
            style: style,
            renderMissingFormulas: false
        )
        apply(preview)
        let pending = formulas.filter { formula in
            !formulaIsReady(formula, style: style)
        }
        warm(
            formulas: pending,
            index: 0,
            document: document,
            style: style,
            generation: generation
        )
        let current = layout
        return NativeConfigureResult(
            height: current?.size.height ?? preview.size.height,
            isProvisional: isPreviewLayout(current)
        )
    }

    private func formulaIsReady(_ formula: (tex: String, display: Bool),
                                style: NativeLayoutStyle) -> Bool {
        NativeFormulaRenderer.shared.hasMemoryArtifact(
            tex: formula.tex,
            fontSize: style.bodyFontSize * (formula.display ? 1.08 : 1),
            color: style.colors.textPrimary,
            display: formula.display
        )
    }

    private func isPreviewLayout(_ layout: NativeMessageLayout?) -> Bool {
        layout?.key.contains("|preview|") == true
    }

    func clear() {
        renderGeneration += 1
        requestKey = nil
        layoutKey = nil
        layout = nil
        setNeedsDisplay()
        invalidateIntrinsicContentSize()
    }

    private func hydrateCachedFormulas(_ formulas: [(tex: String, display: Bool)],
                                       style: NativeLayoutStyle) {
        for formula in formulas {
            guard NativeFormulaRenderer.shared.hasCachedArtifact(
                tex: formula.tex,
                fontSize: style.bodyFontSize * (formula.display ? 1.08 : 1),
                color: style.colors.textPrimary,
                display: formula.display
            ) else { continue }
            _ = NativeFormulaRenderer.shared.artifact(
                tex: formula.tex,
                fontSize: style.bodyFontSize * (formula.display ? 1.08 : 1),
                color: style.colors.textPrimary,
                display: formula.display
            )
        }
    }

    private func apply(_ result: NativeMessageLayout) {
        guard layoutKey != result.key else { return }
        layoutKey = result.key
        layout = result
        setNeedsDisplay()
        invalidateIntrinsicContentSize()
    }

    private func warm(formulas: [(tex: String, display: Bool)],
                      index: Int,
                      document: NativeMarkdownDocument,
                      style: NativeLayoutStyle,
                      generation: Int) {
        guard renderGeneration == generation else { return }
        guard index < formulas.count else {
            let final = NativeMessageLayouter.shared.layout(document: document, style: style)
            guard renderGeneration == generation else { return }
            apply(final)
            onHeightChange?(final.size.height)
            return
        }
        let formula = formulas[index]
        let fontSize = style.bodyFontSize * (formula.display ? 1.08 : 1)
        let wasCached = NativeFormulaRenderer.shared.hasMemoryArtifact(
            tex: formula.tex,
            fontSize: fontSize,
            color: style.colors.textPrimary,
            display: formula.display
        )
        autoreleasepool {
            _ = NativeFormulaRenderer.shared.artifact(
                tex: formula.tex,
                fontSize: fontSize,
                color: style.colors.textPrimary,
                display: formula.display
            )
        }
        let nextIndex = index + 1
        if wasCached {
            warm(
                formulas: formulas,
                index: nextIndex,
                document: document,
                style: style,
                generation: generation
            )
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.warm(
                    formulas: formulas,
                    index: nextIndex,
                    document: document,
                    style: style,
                    generation: generation
                )
            }
        }
    }

    private func formulaRequests(_ document: NativeMarkdownDocument) -> [(tex: String, display: Bool)] {
        var result = [(tex: String, display: Bool)]()
        var seen = Set<String>()
        func append(_ tex: String, _ display: Bool) {
            let key = "\(display ? "d" : "i")|\(tex)"
            if seen.insert(key).inserted {
                result.append((tex, display))
            }
        }
        func scan(_ inlines: [NativeInline]) {
            for inline in inlines {
                switch inline {
                case .inlineMath(let tex): append(tex, false)
                case .bold(let children), .italic(let children), .link(let children, _):
                    scan(children)
                default: break
                }
            }
        }
        for block in document.blocks {
            switch block {
            case .displayMath(let tex): append(tex, true)
            case .paragraph(let inlines), .heading(_, let inlines), .blockquote(let inlines):
                scan(inlines)
            case .list(_, let items):
                items.forEach(scan)
            case .table(let table):
                table.header.forEach(scan)
                table.rows.flatMap { $0 }.forEach(scan)
            default: break
            }
        }
        return result
    }

    override var intrinsicContentSize: CGSize {
        layout?.size ?? CGSize(width: UIView.noIntrinsicMetric, height: 0)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        layout?.size ?? .zero
    }

    override func draw(_ rect: CGRect) {
        guard let layout = layout,
              let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.clip(to: rect)
        for command in layout.commands {
            switch command {
            case .text(let fragment):
                guard fragment.frame.intersects(rect) else { continue }
                fragment.attributedText.draw(
                    with: fragment.frame,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
            case .image(let image, let frame):
                guard frame.intersects(rect) else { continue }
                image.draw(in: frame)
            case .fill(let frame, let color, let radius):
                guard frame.intersects(rect) else { continue }
                color.setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: radius).fill()
            case .stroke(let frame, let color, let width):
                guard frame.intersects(rect) else { continue }
                color.setStroke()
                let path = UIBezierPath(rect: frame.insetBy(dx: width / 2, dy: width / 2))
                path.lineWidth = width
                path.stroke()
            case .line(let start, let end, let color, let width):
                let bounds = CGRect(
                    x: min(start.x, end.x) - width,
                    y: min(start.y, end.y) - width,
                    width: abs(end.x - start.x) + width * 2,
                    height: abs(end.y - start.y) + width * 2
                )
                guard bounds.intersects(rect) else { continue }
                color.setStroke()
                let path = UIBezierPath()
                path.move(to: start)
                path.addLine(to: end)
                path.lineWidth = width
                path.stroke()
            }
        }
        context.restoreGState()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self),
              let url = layout?.linkRects.first(where: { $0.0.insetBy(dx: -5, dy: -5).contains(point) })?.1 else {
            super.touchesEnded(touches, with: event)
            return
        }
        if onLinkTap?(url) != true {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
