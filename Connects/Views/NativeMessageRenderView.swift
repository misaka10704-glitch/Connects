import UIKit

struct NativeConfigureResult {
    let height: CGFloat
    /// True while iosMath is still warming; row height must not be cached yet.
    let isProvisional: Bool
}

/// Chat bubble paint: one cached UIImage (origin approach). Scroll only composites a texture.
/// Code fences are compact preview cards; tap opens a keyword-highlighted popup.
final class NativeMessageRenderView: UIView {
    var onHeightChange: ((CGFloat) -> Void)?
    /// Return true when a host view controller handled the link internally.
    var onLinkTap: ((URL) -> Bool)?
    /// Open full code fence (keyword-highlighted popup).
    var onCodeFenceTap: ((NativeCodeFenceHit) -> Void)?

    private let bitmapView = UIImageView()
    private var mathScrollViews: [UIScrollView] = []
    private(set) var layout: NativeMessageLayout?
    private var layoutKey: String?
    private var requestKey: String?
    private var rasterKey: String?
    private var renderGeneration = 0
    /// True while UITableView scroll gesture is active — skip sync CPU rasterize (settle flushes).
    static var suppressSyncRasterize = false

    /// Shared bitmap cache — scrolling back to a tall code bubble must not re-rasterize.
    private static let bitmapCache = NSCache<NSString, UIImage>()

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
        isUserInteractionEnabled = true
        clipsToBounds = true
        layer.drawsAsynchronously = false
        bitmapView.contentMode = .topLeft
        bitmapView.clipsToBounds = true
        bitmapView.isUserInteractionEnabled = false
        bitmapView.backgroundColor = .clear
        addSubview(bitmapView)
        Self.bitmapCache.countLimit = 48
        Self.bitmapCache.totalCostLimit = 96 * 1024 * 1024
    }

    @discardableResult
    func configure(content: String,
                   width: CGFloat,
                   fontSize: CGFloat,
                   appearance: String,
                   colors: ThemeColors) -> NativeConfigureResult {
        let document = NativeMarkdownParser.shared.parse(content)
        let style = NativeLayoutStyle(
            width: max(width, 40),
            bodyFontSize: fontSize,
            appearance: appearance,
            colors: colors
        )
        let nextRequestKey = "\(document.stamp)|\(style.keySuffix)"
        if requestKey == nextRequestKey, let current = layout {
            return NativeConfigureResult(
                height: current.size.height,
                isProvisional: isPreviewLayout(current)
            )
        }
        requestKey = nextRequestKey
        renderGeneration += 1
        let generation = renderGeneration

        if let final = NativeMessageLayouter.shared.cachedLayout(document: document, style: style) {
            apply(final)
            return NativeConfigureResult(height: final.size.height, isProvisional: false)
        }

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
        rasterKey = nil
        layout = nil
        bitmapView.image = nil
        clearMathScrollers()
        invalidateIntrinsicContentSize()
    }

    static func clearBitmapCache() {
        bitmapCache.removeAllObjects()
    }

    /// Bind a warmed layout without parsing markdown — scroll hot path only.
    @discardableResult
    func bindCachedLayoutIfAvailable(content: String,
                                     width: CGFloat,
                                     fontSize: CGFloat,
                                     appearance: String,
                                     colors: ThemeColors) -> CGFloat? {
        guard let document = NativeMarkdownParser.shared.cachedDocument(content) else { return nil }
        let style = NativeLayoutStyle(
            width: max(width, 40),
            bodyFontSize: fontSize,
            appearance: appearance,
            colors: colors
        )
        guard let final = NativeMessageLayouter.shared.cachedLayout(document: document, style: style) else {
            return nil
        }
        let nextRequestKey = "\(document.stamp)|\(style.keySuffix)"
        if requestKey != nextRequestKey {
            requestKey = nextRequestKey
            renderGeneration += 1
            apply(final)
        }
        return final.size.height
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
        invalidateIntrinsicContentSize()
        publishRasterizedBitmap()
        syncMathScrollers(for: result)
    }

    /// One UIImage per layout key. Cache hits make back-and-forth scroll free of re-paint.
    private func publishRasterizedBitmap() {
        guard let layout = layout,
              layout.size.width > 0.5,
              layout.size.height > 0.5 else {
            bitmapView.image = nil
            rasterKey = nil
            return
        }
        guard rasterKey != layout.key else { return }

        let cacheKey = layout.key as NSString
        if let hit = Self.bitmapCache.object(forKey: cacheKey) {
            rasterKey = layout.key
            bitmapView.image = hit
            setNeedsLayout()
            return
        }

        // Finger still down: never sync-rasterize tall fence-heavy bitmaps (main-thread hitch).
        if Self.suppressSyncRasterize {
            #if DEBUG
            ChatHeavyScrollDiagnostics.skippedRasterizeDuringScroll += 1
            #endif
            return
        }

        rasterKey = layout.key
        let size = layout.size
        let scale = UIScreen.main.scale
        // Cap extreme bitmaps: still full content, but avoid multi-ten-MB surfaces on A7.
        // Above ~4096pt we slice into a vertically concatenated image drawn once into cache.
        let image = Self.rasterize(layout: layout, size: size, scale: scale)
        guard let image = image else {
            bitmapView.image = nil
            return
        }
        let cost = Int(size.width * size.height * scale * scale * 4)
        Self.bitmapCache.setObject(image, forKey: cacheKey, cost: max(cost, 1))
        bitmapView.image = image
        setNeedsLayout()
    }

    /// After scroll settle: paint any layout that skipped sync rasterize mid-gesture.
    func flushPendingRasterizeIfNeeded() {
        guard let layout = layout, rasterKey != layout.key else { return }
        let saved = Self.suppressSyncRasterize
        Self.suppressSyncRasterize = false
        publishRasterizedBitmap()
        Self.suppressSyncRasterize = saved
    }

    private static func rasterize(layout: NativeMessageLayout,
                                 size: CGSize,
                                 scale: CGFloat) -> UIImage? {
        let maxTile: CGFloat = 2048
        if size.height <= maxTile {
            UIGraphicsBeginImageContextWithOptions(size, false, scale)
            defer { UIGraphicsEndImageContext() }
            guard let context = UIGraphicsGetCurrentContext() else { return nil }
            NativeMessagePainter.draw(
                layout: layout,
                in: context,
                clipRect: CGRect(origin: .zero, size: size)
            )
            return UIGraphicsGetImageFromCurrentImageContext()
        }

        // Tall: draw strip-by-strip into one context so the cell still hosts a single UIImageView.
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        defer { UIGraphicsEndImageContext() }
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        var y: CGFloat = 0
        while y < size.height {
            let h = min(maxTile, size.height - y)
            let clip = CGRect(x: 0, y: y, width: size.width, height: h)
            NativeMessagePainter.draw(layout: layout, in: context, clipRect: clip)
            y += h
        }
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout = layout else {
            bitmapView.frame = .zero
            clearMathScrollers()
            return
        }
        bitmapView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: layout.size.height)
        for (scroll, band) in zip(mathScrollViews, mathScrollBands(in: layout)) {
            scroll.frame = band.viewportFrame
            if let imageView = scroll.subviews.first as? UIImageView {
                imageView.contentMode = .scaleToFill
                imageView.frame = CGRect(origin: .zero, size: band.contentSize)
            }
            scroll.contentSize = band.contentSize
        }
    }

    private func mathScrollBands(in layout: NativeMessageLayout) -> [NativeMathScrollFragment] {
        layout.commands.compactMap {
            if case .mathScroll(let band) = $0 { return band }
            return nil
        }
    }

    private func clearMathScrollers() {
        mathScrollViews.forEach { $0.removeFromSuperview() }
        mathScrollViews.removeAll()
    }

    private func syncMathScrollers(for layout: NativeMessageLayout) {
        clearMathScrollers()
        for band in mathScrollBands(in: layout) {
            let scroll = MathBandScrollView(frame: band.viewportFrame)
            scroll.backgroundColor = .clear
            scroll.isOpaque = false
            scroll.clipsToBounds = true
            scroll.showsHorizontalScrollIndicator = true
            scroll.showsVerticalScrollIndicator = false
            scroll.alwaysBounceVertical = false
            scroll.alwaysBounceHorizontal = true
            scroll.isDirectionalLockEnabled = true
            scroll.bounces = true
            scroll.decelerationRate = .fast
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.contentSize = band.contentSize
            let imageView = UIImageView(image: band.image)
            // Fill the point-size frame exactly (image may come from disk @3x).
            imageView.contentMode = .scaleToFill
            imageView.clipsToBounds = true
            imageView.frame = CGRect(origin: .zero, size: band.contentSize)
            scroll.addSubview(imageView)
            addSubview(scroll)
            mathScrollViews.append(scroll)
        }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
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
        NativeMessageLayouter.formulaWarmRequests(document: document)
    }

    var paintedLayoutHeight: CGFloat? {
        guard let layout = layout, layout.size.height > 0 else { return nil }
        return layout.size.height
    }

    override var intrinsicContentSize: CGSize {
        layout?.size ?? CGSize(width: UIView.noIntrinsicMetric, height: 0)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        layout?.size ?? .zero
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else {
            super.touchesEnded(touches, with: event)
            return
        }
        if let hit = layout?.codeFenceHits.first(where: { $0.copyFrame.insetBy(dx: -4, dy: -6).contains(point) }) {
            UIPasteboard.general.string = hit.code
            ConnectsToast.show("已复制代码", in: self, duration: 1.2)
            return
        }
        if let hit = layout?.codeFenceHits.first(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(point) }) {
            onCodeFenceTap?(hit)
            return
        }
        if let url = layout?.linkRects.first(where: { $0.0.insetBy(dx: -5, dy: -5).contains(point) })?.1 {
            if onLinkTap?(url) != true {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            return
        }
        super.touchesEnded(touches, with: event)
    }
}

/// Horizontal math band: claim pans that are mostly sideways so the chat table keeps vertical scroll.
private final class MathBandScrollView: UIScrollView, UIGestureRecognizerDelegate {
    override init(frame: CGRect) {
        super.init(frame: frame)
        panGestureRecognizer.delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        panGestureRecognizer.delegate = self
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer == panGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = panGestureRecognizer.velocity(in: self)
        return abs(velocity.x) >= abs(velocity.y)
    }
}

// MARK: - Painter

enum NativeMessagePainter {
    static func rasterize(commands: [NativeDrawCommand],
                          size: CGSize,
                          scale: CGFloat) -> UIImage? {
        guard size.width > 0.5, size.height > 0.5 else { return nil }
        let layout = NativeMessageLayout(
            key: "raster-\(size.width)x\(size.height)",
            size: size,
            commands: commands,
            linkRects: [],
            codeFenceHits: []
        )
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        defer { UIGraphicsEndImageContext() }
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        draw(layout: layout, in: context, clipRect: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    static func draw(layout: NativeMessageLayout, in context: CGContext, clipRect: CGRect) {
        context.saveGState()
        context.clip(to: clipRect)
        for command in layout.commands {
            switch command {
            case .text(let fragment):
                guard fragment.frame.intersects(clipRect) else { continue }
                fragment.attributedText.draw(
                    with: fragment.frame,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
            case .codeFence(let fence):
                guard fence.cardFrame.intersects(clipRect) else { continue }
                context.saveGState()
                drawCodeFence(fence, clipRect: clipRect)
                context.restoreGState()
            case .image(let image, let frame):
                guard frame.intersects(clipRect) else { continue }
                image.draw(in: frame)
            case .mathScroll:
                // Interactive MathBandScrollView paints this band; keep the bitmap empty here
                // so horizontal scrolling does not reveal a stale left-edge preview underneath.
                continue
            case .fill(let frame, let color, let radius):
                guard frame.intersects(clipRect) else { continue }
                color.setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: radius).fill()
            case .stroke(let frame, let color, let width):
                guard frame.intersects(clipRect) else { continue }
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
                guard bounds.intersects(clipRect) else { continue }
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

    private static func drawCodeFence(_ fence: NativeCodeFenceFragment, clipRect: CGRect) {
        let card = fence.cardFrame
        guard card.intersects(clipRect) else { return }

        fence.cardFill.setFill()
        UIBezierPath(roundedRect: card, cornerRadius: 12).fill()
        fence.cardBorder.setStroke()
        let border = UIBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 11.5)
        border.lineWidth = 1 / UIScreen.main.scale
        border.stroke()

        let title = fence.languageLabel
        let meta = "\(fence.totalLineCount) lines"
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(12, fence.font.pointSize * 0.95), weight: .semibold),
            .foregroundColor: fence.color
        ]
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(11, fence.font.pointSize * 0.85), weight: .medium),
            .foregroundColor: fence.mutedColor
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttrs)
        let metaSize = (meta as NSString).size(withAttributes: metaAttrs)
        let titleOrigin = CGPoint(
            x: fence.headerFrame.minX,
            y: fence.headerFrame.midY - titleSize.height * 0.5
        )
        (title as NSString).draw(at: titleOrigin, withAttributes: titleAttrs)
        let metaOrigin = CGPoint(
            x: fence.copyFrame.minX - metaSize.width - 8,
            y: fence.headerFrame.midY - metaSize.height * 0.5
        )
        if metaOrigin.x > titleOrigin.x + titleSize.width + 8 {
            (meta as NSString).draw(at: metaOrigin, withAttributes: metaAttrs)
        }

        // "􀉃 复制" pill at the header's trailing edge (hit zone = fence.copyFrame).
        let pill = fence.copyFrame.insetBy(dx: 0, dy: 1)
        let pillPath = UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2)
        fence.cardBorder.withAlphaComponent(0.55).setStroke()
        pillPath.lineWidth = 1 / UIScreen.main.scale
        pillPath.stroke()
        let copyAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(10, fence.font.pointSize * 0.82), weight: .medium),
            .foregroundColor: fence.mutedColor
        ]
        let copyLabel = "复制"
        let labelSize = (copyLabel as NSString).size(withAttributes: copyAttrs)
        let iconConfig = UIImage.SymbolConfiguration(pointSize: max(9, fence.font.pointSize * 0.78), weight: .medium)
        let copyIcon = UIImage(systemName: "doc.on.doc", withConfiguration: iconConfig)?
            .withTintColor(fence.mutedColor, renderingMode: .alwaysOriginal)
        let iconW = copyIcon?.size.width ?? 0
        let gap: CGFloat = 3
        let groupW = iconW + gap + labelSize.width
        var penX = pill.midX - groupW / 2
        if let copyIcon {
            let iconH = copyIcon.size.height
            copyIcon.draw(in: CGRect(x: penX, y: pill.midY - iconH / 2, width: iconW, height: iconH))
            penX += iconW + gap
        }
        (copyLabel as NSString).draw(
            at: CGPoint(x: penX, y: pill.midY - labelSize.height / 2),
            withAttributes: copyAttrs
        )

        let step = max(fence.lineStep, 1)
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.saveGState()
        UIRectClip(fence.previewFrame.intersection(clipRect))
        let plainAttrs: [NSAttributedString.Key: Any] = [
            .font: fence.font,
            .foregroundColor: fence.color
        ]
        for (idx, line) in fence.previewLines.enumerated() {
            let y = fence.previewFrame.minY + CGFloat(idx) * step
            let origin = CGPoint(x: fence.previewFrame.minX, y: y)
            if idx < fence.previewAttributedLines.count {
                fence.previewAttributedLines[idx].draw(at: origin)
            } else {
                let display: String
                if line.count > 96 {
                    display = String(line.prefix(96)) + "…"
                } else {
                    display = line.isEmpty ? " " : line
                }
                (display as NSString).draw(at: origin, withAttributes: plainAttrs)
            }
        }
        ctx?.restoreGState()

        if fence.showsFade {
            let fadeH: CGFloat = 28
            let fade = CGRect(
                x: card.minX + 1,
                y: card.maxY - fadeH - 1,
                width: card.width - 2,
                height: fadeH
            )
            let colors = [
                fence.cardFill.withAlphaComponent(0).cgColor,
                fence.cardFill.cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                ctx?.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: fade.midX, y: fade.minY),
                    end: CGPoint(x: fade.midX, y: fade.maxY),
                    options: []
                )
            }
        }
    }
}

#if DEBUG
/// Counters for heavy-transcript scroll diagnosis (fence-dense + post-edit cache miss).
enum ChatHeavyScrollDiagnostics {
    static var skippedRasterizeDuringScroll = 0
    static var scrollFreezeKeptPaint = 0
    static var scrollFreezeBlankShell = 0
    static var midScrollBeginUpdates = 0
    static var midScrollHydrateGrew = 0
    static var gestureDeferredVisiblePeak = 0

    static func resetGesture() {
        skippedRasterizeDuringScroll = 0
        scrollFreezeKeptPaint = 0
        scrollFreezeBlankShell = 0
        midScrollBeginUpdates = 0
        midScrollHydrateGrew = 0
        gestureDeferredVisiblePeak = 0
    }

    static func logConversationProfile(_ messages: [ChatMessage], label: String) {
        var assistants = 0
        var fenceMarks = 0
        var maxBody = 0
        var fenceHeavy = 0
        for msg in messages where msg.role == .assistant && !msg.isStreaming {
            assistants += 1
            let body = msg.chatDisplayBody
            maxBody = max(maxBody, body.utf8.count)
            let marks = AssistantMessageLayout.codeFenceMarkerCount(in: body)
            fenceMarks += marks
            if marks >= 2 { fenceHeavy += 1 }
        }
        print(
            "[ChatHeavyScroll] \(label) assistants=\(assistants) fenceHeavy=\(fenceHeavy) " +
            "fenceMarks=\(fenceMarks) maxBodyUTF8=\(maxBody)"
        )
    }

    static func logGestureSummary(_ label: String) {
        print(
            "[ChatHeavyScroll] \(label) keptPaint=\(scrollFreezeKeptPaint) blankShell=\(scrollFreezeBlankShell) " +
            "skipRaster=\(skippedRasterizeDuringScroll) beginUpdates=\(midScrollBeginUpdates) " +
            "hydrateGrew=\(midScrollHydrateGrew) deferredPeak=\(gestureDeferredVisiblePeak)"
        )
    }
}
#endif
