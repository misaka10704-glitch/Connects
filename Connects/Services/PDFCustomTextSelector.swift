import UIKit
import PDFKit

/// Hit-through overlay so compositing layers never steal PDF touches.
final class PassthroughOverlayView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }
}

/// Shared highlighter stroke style (soft translucent yellow + selectable width).
enum PDFHighlightStrokeStyle {
    /// Live preview on the draw overlay (above invert filters).
    static let previewColor = UIColor(red: 1.0, green: 0.92, blue: 0.12, alpha: 0.32)

    /// PDFKit ink. Dark mode stores a pre-invert complementary so difference blend reads yellow.
    static func inkColor(darkInvertActive: Bool) -> UIColor {
        if darkInvertActive {
            return UIColor(red: 0.00, green: 0.10, blue: 0.88, alpha: 0.30)
        }
        return UIColor(red: 1.0, green: 0.92, blue: 0.12, alpha: 0.28)
    }

    enum Width: Int, CaseIterable {
        case thin = 0
        case medium = 1
        case thick = 2

        var title: String {
            switch self {
            case .thin: return "细"
            case .medium: return "中"
            case .thick: return "粗"
            }
        }

        /// Page-space stroke width (PDF points) — kept modest so text stays readable.
        var pagePoints: CGFloat {
            switch self {
            case .thin: return 1.8
            case .medium: return 3.2
            case .thick: return 5.5
            }
        }

        private static let defaultsKey = "connects.pdfHighlight.strokeWidth"

        static var current: Width {
            get {
                let raw = UserDefaults.standard.integer(forKey: defaultsKey)
                return Width(rawValue: raw) ?? .medium
            }
            set {
                UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            }
        }
    }
}

/// Freehand ink highlighter with pause-to-straighten.
/// Live preview + committed strokes are painted on overlays **above** the dark-mode
/// invert stack — PDFKit ink under difference-blend is otherwise invisible after commit.
final class PDFHighlighterTool: NSObject, UIGestureRecognizerDelegate {
    private weak var pdfView: PDFView?
    private let overlay = HighlightDrawOverlay()
    private let committed = CommittedInkOverlay()
    private let pan = UIPanGestureRecognizer()
    private var page: PDFPage?
    private var pagePoints: [CGPoint] = []
    private var overlayPoints: [CGPoint] = []
    private var overlayConstraints: [NSLayoutConstraint] = []
    private var committedConstraints: [NSLayoutConstraint] = []
    private var pauseWorkItem: DispatchWorkItem?
    private var isStraightMode = false
    private var straightStartPage = CGPoint.zero
    private var straightStartOverlay = CGPoint.zero
    private var lastMoveSample = CGPoint.zero
    private var observers: [NSObjectProtocol] = []
    private var scrollObservations: [NSKeyValueObservation] = []
    private var lastObservedScrollViews: [UIScrollView] = []
    private weak var documentScrollView: UIScrollView?
    /// `contentOffset` captured when ink paths were last projected into view space.
    private var inkAnchorOffset: CGPoint = .zero
    private var lastInkLayoutSize: CGSize = .zero
    /// Padded visible page indices at last path rebuild — skip rebuild when unchanged.
    private var lastInkPageIndices: Set<Int> = []
    private var reloadWorkItem: DispatchWorkItem?
    private var scrollIdleReloadWork: DispatchWorkItem?
    private var isMutatingHierarchy = false
    private var isReloadingCommitted = false
    private(set) var isEnabled = false
    private(set) var isActivelyHighlighting = false
    var strokeWidth: PDFHighlightStrokeStyle.Width = .current {
        didSet {
            overlay.lineWidth = strokeWidth.pagePoints * max(pdfView?.scaleFactor ?? 1, 0.5)
        }
    }

    /// Stillness before freehand snaps to a straight ruler segment.
    private let pauseToStraighten: TimeInterval = 0.20
    /// View-space movement below this counts as "stopped".
    private let stillEpsilon: CGFloat = 3.0

    /// Fired after an ink stroke is committed onto the page.
    var onStrokeFinished: ((PDFAnnotation, PDFPage) -> Void)?
    /// When true, PDF-space ink is hidden (invert would ruin it); overlay paints instead.
    var darkInvertActive = false {
        didSet {
            guard oldValue != darkInvertActive else { return }
            DispatchQueue.main.async { [weak self] in
                self?.reloadCommittedInk()
            }
        }
    }

    func attach(to pdfView: PDFView) {
        self.pdfView = pdfView
        overlay.isHidden = true
        overlay.isUserInteractionEnabled = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.lineWidth = strokeWidth.pagePoints * max(pdfView.scaleFactor, 0.5)
        overlay.strokeColor = PDFHighlightStrokeStyle.previewColor

        committed.isUserInteractionEnabled = false
        committed.translatesAutoresizingMaskIntoConstraints = false
        committed.clipsToBounds = true
        committed.pdfView = pdfView

        overlay.clipsToBounds = true

        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        pan.isEnabled = false
        overlay.addGestureRecognizer(pan)

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.bindScrollObserversIfNeeded()
            self?.scheduleCommittedReload()
        })
        observers.append(nc.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.scheduleCommittedReload()
        })
        if #available(iOS 11.0, *) {
            observers.append(nc.addObserver(forName: .PDFViewVisiblePagesChanged, object: pdfView, queue: .main) { [weak self] _ in
                self?.reloadCommittedInk()
            })
        }
        DispatchQueue.main.async { [weak self] in
            self?.ensureHostOverlaysInstalled()
            self?.bindScrollObserversIfNeeded()
            self?.reloadCommittedInk()
        }
    }

    deinit {
        let nc = NotificationCenter.default
        observers.forEach { nc.removeObserver($0) }
        scrollObservations.forEach { $0.invalidate() }
        scrollObservations.removeAll()
        reloadWorkItem?.cancel()
        scrollIdleReloadWork?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            pan.isEnabled = true
            // Re-arm without tearing down hierarchy — install/reorder is the toggle hitch.
            if overlay.superview != nil {
                overlay.lineWidth = strokeWidth.pagePoints * max(pdfView?.scaleFactor ?? 1, 0.5)
                overlay.strokeColor = PDFHighlightStrokeStyle.previewColor
                overlay.clearStroke()
                overlay.isHidden = false
                overlay.isUserInteractionEnabled = true
                DispatchQueue.main.async { [weak self] in
                    self?.ensureOverlayZOrder()
                }
            } else {
                installDrawOverlay()
            }
        } else {
            // Hide + unlock first so the next touch can hit the top bar immediately.
            pan.isEnabled = false
            overlay.isUserInteractionEnabled = false
            overlay.isHidden = true
            overlay.clearStroke()
            cancelStroke()
        }
    }

    func forceUnlockIfNeeded() {
        cancelStroke()
        if !isEnabled {
            pan.isEnabled = false
            overlay.isUserInteractionEnabled = false
            overlay.isHidden = true
            overlay.clearStroke()
        }
    }

    /// Cancel deferred ink rebuilds (conversation leave / document swap) so they don't hitch UI later.
    func cancelPendingInkWork() {
        reloadWorkItem?.cancel()
        reloadWorkItem = nil
        scrollIdleReloadWork?.cancel()
        scrollIdleReloadWork = nil
    }

    /// True when the draw surface is armed and claiming touches (simulator / QA).
    var isDrawSurfaceArmed: Bool {
        isEnabled && !overlay.isHidden && overlay.isUserInteractionEnabled && overlay.superview != nil
    }

    /// Install committed-ink layer only (never recursively arms the pen overlay).
    func ensureHostOverlaysInstalled() {
        guard !isMutatingHierarchy else { return }
        guard let pdfView = pdfView, let host = pdfView.superview else { return }
        isMutatingHierarchy = true
        defer { isMutatingHierarchy = false }

        if committed.superview !== host {
            NSLayoutConstraint.deactivate(committedConstraints)
            committedConstraints.removeAll()
            committed.removeFromSuperview()
            host.addSubview(committed)
            committedConstraints = [
                committed.topAnchor.constraint(equalTo: pdfView.topAnchor),
                committed.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
                committed.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
                committed.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor)
            ]
            NSLayoutConstraint.activate(committedConstraints)
        }
        placeCommittedAboveInvertIfNeeded(in: host, pdfView: pdfView)
        // Do not rebind scroll KVO or lift chrome here — that hitch is felt on pen toggle.
    }

    private func installDrawOverlay() {
        guard let pdfView = pdfView, let host = pdfView.superview else { return }
        ensureHostOverlaysInstalled()
        guard !isMutatingHierarchy else { return }
        isMutatingHierarchy = true
        defer {
            isMutatingHierarchy = false
            // Defer chrome lift — sync onOverlaysReordered hitchs the pen-arm tap.
            DispatchQueue.main.async { [weak self] in
                self?.onOverlaysReordered?()
            }
        }

        if overlay.superview !== host {
            NSLayoutConstraint.deactivate(overlayConstraints)
            overlayConstraints.removeAll()
            overlay.removeFromSuperview()
            host.addSubview(overlay)
            overlayConstraints = [
                overlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor)
            ]
            NSLayoutConstraint.activate(overlayConstraints)
        }
        placeDrawAboveCommittedIfNeeded(in: host)
        overlay.lineWidth = strokeWidth.pagePoints * max(pdfView.scaleFactor, 0.5)
        overlay.strokeColor = PDFHighlightStrokeStyle.previewColor
        overlay.clearStroke()
        overlay.isHidden = false
        overlay.isUserInteractionEnabled = true
    }

    private func removeDrawOverlay() {
        overlay.clearStroke()
        overlay.isUserInteractionEnabled = false
        overlay.isHidden = true
    }

    /// Fired after ink overlays are inserted so chrome can cover them.
    var onOverlaysReordered: (() -> Void)?

    /// Keep draw + committed above invert/paper-lift, below reader chrome.
    func ensureOverlayZOrder() {
        guard let pdfView = pdfView, let host = pdfView.superview else { return }
        ensureHostOverlaysInstalled()
        guard !isMutatingHierarchy else { return }
        isMutatingHierarchy = true
        defer { isMutatingHierarchy = false }
        placeCommittedAboveInvertIfNeeded(in: host, pdfView: pdfView)
        if isEnabled {
            placeDrawAboveCommittedIfNeeded(in: host)
        }
        // Chrome lift is deferred so callers (pen toggle) stay snappy.
        DispatchQueue.main.async { [weak self] in
            self?.onOverlaysReordered?()
        }
    }

    private func placeCommittedAboveInvertIfNeeded(in host: UIView, pdfView: PDFView) {
        var anchor: UIView = pdfView
        for sub in host.subviews where sub is PassthroughOverlayView {
            anchor = sub
        }
        let subs = host.subviews
        if let cIdx = subs.firstIndex(where: { $0 === committed }),
           let aIdx = subs.firstIndex(where: { $0 === anchor }),
           cIdx == aIdx + 1 {
            return
        }
        host.insertSubview(committed, aboveSubview: anchor)
    }

    private func placeDrawAboveCommittedIfNeeded(in host: UIView) {
        let subs = host.subviews
        if let oIdx = subs.firstIndex(where: { $0 === overlay }),
           let cIdx = subs.firstIndex(where: { $0 === committed }),
           oIdx == cIdx + 1 {
            return
        }
        host.insertSubview(overlay, aboveSubview: committed)
    }

    /// Bounds-size changes only — scrolling is handled via contentOffset transform.
    func noteHostDidLayout() {
        bindScrollObserversIfNeeded()
        let size = pdfView?.bounds.size ?? .zero
        guard abs(size.width - lastInkLayoutSize.width) > 0.5
                || abs(size.height - lastInkLayoutSize.height) > 0.5 else { return }
        lastInkLayoutSize = size
        scheduleCommittedReload(delay: 0.05)
    }

    /// Follow the document scroller with a layer translation (O(1)); rebuild paths when idle.
    private func bindScrollObserversIfNeeded() {
        guard let pdfView = pdfView else { return }
        let primary = pdfView.connectsPrimaryDocumentScrollView
        if primary === documentScrollView, !scrollObservations.isEmpty {
            return
        }
        scrollObservations.forEach { $0.invalidate() }
        scrollObservations.removeAll()
        documentScrollView = primary
        lastObservedScrollViews = primary.map { [$0] } ?? []
        guard let scrollView = primary else { return }
        let obs = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
            self?.noteDocumentScrolled(scroll)
        }
        scrollObservations.append(obs)
        inkAnchorOffset = scrollView.contentOffset
    }

    private func noteDocumentScrolled(_ scrollView: UIScrollView) {
        // Stick ink to the page by matching the scroller delta — never rebuild mid-fling.
        let offset = scrollView.contentOffset
        let dx = inkAnchorOffset.x - offset.x
        let dy = inkAnchorOffset.y - offset.y
        committed.applyScrollTranslation(CGPoint(x: dx, y: dy))

        // Only consider a path rebuild after the scroller fully stops, and only if
        // the visible page set changed (same-page flings stay transform-only).
        scrollIdleReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak scrollView] in
            guard let self = self, let scrollView = scrollView else { return }
            if scrollView.isDragging || scrollView.isDecelerating {
                self.noteDocumentScrolled(scrollView)
                return
            }
            self.reloadCommittedInkIfVisiblePagesChanged()
        }
        scrollIdleReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func scheduleCommittedReload(delay: TimeInterval = 0.03) {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadCommittedInk(force: true)
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reloadCommittedInkIfVisiblePagesChanged() {
        let indices = paddedVisiblePageIndices()
        guard indices != lastInkPageIndices else { return }
        reloadCommittedInk(force: true)
    }

    private func paddedVisiblePageIndices() -> Set<Int> {
        guard let pdfView = pdfView, let document = pdfView.document else { return [] }
        var indices = Set<Int>()
        if #available(iOS 11.0, *), !pdfView.visiblePages.isEmpty {
            for page in pdfView.visiblePages {
                let idx = document.index(for: page)
                indices.insert(idx)
                if idx > 0 { indices.insert(idx - 1) }
                if idx + 1 < document.pageCount { indices.insert(idx + 1) }
            }
        } else if let cur = pdfView.currentPage {
            let idx = document.index(for: cur)
            indices.insert(idx)
        }
        return indices
    }

    func reloadCommittedInk(force: Bool = true) {
        // Critical: do not install/reorder views here — that re-enters layout and freezes the UI.
        guard committed.superview != nil else { return }
        guard !isReloadingCommitted, !isMutatingHierarchy else { return }
        if !force {
            reloadCommittedInkIfVisiblePagesChanged()
            return
        }
        isReloadingCommitted = true
        defer { isReloadingCommitted = false }
        scrollIdleReloadWork?.cancel()
        if let scroll = documentScrollView ?? pdfView?.connectsPrimaryDocumentScrollView {
            documentScrollView = scroll
            inkAnchorOffset = scroll.contentOffset
        }
        lastInkPageIndices = paddedVisiblePageIndices()
        committed.clipsToBounds = true
        committed.reload(darkInvertActive: darkInvertActive)
    }

    /// Add one stroke's overlay path without rebuilding every visible annotation.
    func appendCommittedStroke(_ annotation: PDFAnnotation, on page: PDFPage) {
        guard committed.superview != nil else {
            reloadCommittedInk(force: true)
            return
        }
        // If ink is mid-scroll translated, rebase with a full project instead of double-transforming.
        if !committed.scrollTranslationIsIdentity {
            reloadCommittedInk(force: true)
            return
        }
        if let scroll = documentScrollView ?? pdfView?.connectsPrimaryDocumentScrollView {
            documentScrollView = scroll
            inkAnchorOffset = scroll.contentOffset
        }
        committed.appendStroke(annotation, page: page, darkInvertActive: darkInvertActive)
    }

    /// Drop overlay ink for a removed annotation without a full page scan when possible.
    func removeCommittedStroke(_ annotation: PDFAnnotation) {
        committed.removeStroke(annotation)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isEnabled, let pdfView = pdfView else { return }
        let viewPoint = gesture.location(in: pdfView)
        let overlayPoint = gesture.location(in: overlay)

        switch gesture.state {
        case .began:
            guard let hitPage = pdfView.page(for: viewPoint, nearest: true) else {
                cancelStroke()
                return
            }
            cancelPauseTimer()
            isStraightMode = false
            overlay.lineWidth = strokeWidth.pagePoints * max(pdfView.scaleFactor, 0.5)
            isActivelyHighlighting = true
            page = hitPage
            let pagePoint = pdfView.convert(viewPoint, to: hitPage)
            pagePoints = [pagePoint]
            overlayPoints = [overlayPoint]
            lastMoveSample = overlayPoint
            straightStartPage = pagePoint
            straightStartOverlay = overlayPoint
            overlay.beginStroke(at: overlayPoint)
            schedulePauseCheck()

        case .changed:
            guard isActivelyHighlighting, let page = page else { return }
            let pagePoint = pdfView.convert(viewPoint, to: page)

            if isStraightMode {
                pagePoints = [straightStartPage, pagePoint]
                overlayPoints = [straightStartOverlay, overlayPoint]
                overlay.showStraight(from: straightStartOverlay, to: overlayPoint)
                return
            }

            pagePoints.append(pagePoint)
            overlayPoints.append(overlayPoint)
            overlay.appendStroke(to: overlayPoint)

            let moved = hypot(overlayPoint.x - lastMoveSample.x, overlayPoint.y - lastMoveSample.y)
            if moved > stillEpsilon {
                lastMoveSample = overlayPoint
                schedulePauseCheck()
            }

        case .ended:
            cancelPauseTimer()
            if !isStraightMode, let page = page, shouldStraightenFromStillness() {
                let velocity = gesture.velocity(in: overlay)
                if hypot(velocity.x, velocity.y) < 140 {
                    let endPage = pdfView.convert(viewPoint, to: page)
                    enterStraightMode(endOverlay: overlayPoint, endPage: endPage)
                }
            }
            commitStroke()

        case .cancelled, .failed:
            cancelStroke()

        default:
            break
        }
    }

    private func schedulePauseCheck() {
        cancelPauseTimer()
        let work = DispatchWorkItem { [weak self] in
            self?.handlePauseElapsed()
        }
        pauseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pauseToStraighten, execute: work)
    }

    private func cancelPauseTimer() {
        pauseWorkItem?.cancel()
        pauseWorkItem = nil
    }

    private func handlePauseElapsed() {
        guard isActivelyHighlighting, !isStraightMode, isEnabled else { return }
        guard pan.state == .changed || pan.state == .began else { return }
        guard shouldStraightenFromStillness() else {
            schedulePauseCheck()
            return
        }
        let endOverlay = overlayPoints.last ?? straightStartOverlay
        let endPage = pagePoints.last ?? straightStartPage
        enterStraightMode(endOverlay: endOverlay, endPage: endPage)
    }

    private func shouldStraightenFromStillness() -> Bool {
        guard pagePoints.count >= 2 else { return false }
        let dx = pagePoints.last!.x - straightStartPage.x
        let dy = pagePoints.last!.y - straightStartPage.y
        return hypot(dx, dy) >= 6
    }

    private func enterStraightMode(endOverlay: CGPoint, endPage: CGPoint) {
        isStraightMode = true
        cancelPauseTimer()
        pagePoints = [straightStartPage, endPage]
        overlayPoints = [straightStartOverlay, endOverlay]
        overlay.showStraight(from: straightStartOverlay, to: endOverlay)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func commitStroke() {
        defer {
            cancelPauseTimer()
            isActivelyHighlighting = false
            isStraightMode = false
            page = nil
            pagePoints.removeAll()
            overlayPoints.removeAll()
            overlay.clearStroke()
        }
        guard isActivelyHighlighting,
              pdfView != nil,
              let page = page else { return }

        let points: [CGPoint]
        if isStraightMode, pagePoints.count >= 2 {
            points = [pagePoints.first!, pagePoints.last!]
        } else {
            points = thinned(pagePoints)
        }
        guard points.count >= 2 else { return }

        let lineW = strokeWidth.pagePoints
        let padded = paddedBounds(for: points, padding: max(4, lineW))
        let span = hypot(points.last!.x - points.first!.x, points.last!.y - points.first!.y)
        guard span >= 4 else { return }

        let path = UIBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (idx, pt) in points.enumerated() {
            let local = CGPoint(x: pt.x - padded.minX, y: pt.y - padded.minY)
            if idx == 0 { path.move(to: local) } else { path.addLine(to: local) }
        }

        // Persist as a normal ink annotation (custom SoftInk subclass does not round-trip
        // through dataRepresentation / disk reload reliably). Near-clear color keeps PDFKit's
        // own paint invisible; CommittedInkOverlay draws the visible stroke above invert.
        let annotation = PDFAnnotation(bounds: padded, forType: .ink, withProperties: nil)
        annotation.color = UIColor(red: 1.0, green: 0.92, blue: 0.12, alpha: 0.02)
        annotation.add(path)
        let border = PDFBorder()
        border.lineWidth = lineW
        border.style = .solid
        annotation.border = border
        annotation.userName = StudyAskSelectionStore.noteAnnotationUserName
        annotation.isReadOnly = false
        page.addAnnotation(annotation)
        // Incremental paint — full rebuild here hitchs the next scroll gesture.
        appendCommittedStroke(annotation, on: page)

        let ann = annotation
        let pg = page
        DispatchQueue.main.async { [weak self] in
            self?.onStrokeFinished?(ann, pg)
        }
    }

    private func thinned(_ points: [CGPoint], minDist: CGFloat = 1.2) -> [CGPoint] {
        guard var last = points.first else { return [] }
        var out = [last]
        for p in points.dropFirst() {
            if hypot(p.x - last.x, p.y - last.y) >= minDist {
                out.append(p)
                last = p
            }
        }
        if let end = points.last, out.last != end { out.append(end) }
        return out
    }

    private func cancelStroke() {
        cancelPauseTimer()
        endStrokeVisual()
    }

    private func endStrokeVisual() {
        cancelPauseTimer()
        isActivelyHighlighting = false
        isStraightMode = false
        page = nil
        pagePoints.removeAll()
        overlayPoints.removeAll()
        overlay.clearStroke()
    }

    private func paddedBounds(for points: [CGPoint], padding: CGFloat) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return CGRect(
            x: minX - padding,
            y: minY - padding,
            width: max(2, maxX - minX) + padding * 2,
            height: max(2, maxY - minY) + padding * 2
        )
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

/// Legacy empty-draw ink used before Connects switched to plain `PDFAnnotation`.
/// Kept so any still-open SoftInk instances stay invisible under dark invert; new strokes
/// use standard ink annotations that round-trip through `dataRepresentation`.
final class SoftInkAnnotation: PDFAnnotation {
    private let localPath: UIBezierPath
    private let strokeWidth: CGFloat
    private let strokeColor: UIColor
    private let darkInvertActive: Bool

    init(bounds: CGRect, path: UIBezierPath, lineWidth: CGFloat, color: UIColor, darkInvertActive: Bool) {
        self.localPath = path
        self.strokeWidth = lineWidth
        self.strokeColor = color
        self.darkInvertActive = darkInvertActive
        super.init(bounds: bounds, forType: .ink, withProperties: nil)
        self.color = color
        add(path)
        let border = PDFBorder()
        border.lineWidth = lineWidth
        border.style = .solid
        self.border = border
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        // Invisible under invert; CommittedInkOverlay paints instead.
    }
}

/// Paints note ink above the dark-mode invert stack (sibling of PDFView).
private final class CommittedInkOverlay: UIView {
    weak var pdfView: PDFView?
    private let inkHost = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false
        inkHost.frame = bounds
        layer.addSublayer(inkHost)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let t = inkHost.affineTransform()
        inkHost.setAffineTransform(.identity)
        inkHost.frame = bounds
        inkHost.setAffineTransform(t)
        CATransaction.commit()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    /// Match PDF scroller delta without rebuilding paths (keeps ink glued while flinging).
    func applyScrollTranslation(_ delta: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkHost.setAffineTransform(CGAffineTransform(translationX: delta.x, y: delta.y))
        CATransaction.commit()
    }

    var scrollTranslationIsIdentity: Bool {
        inkHost.affineTransform().isIdentity
    }

    func appendStroke(_ annotation: PDFAnnotation, page: PDFPage, darkInvertActive: Bool) {
        guard let pdfView = pdfView else { return }
        let lineW = max(annotation.border?.lineWidth ?? 3.2, 1.5) * max(pdfView.scaleFactor, 0.5)
        let key = Self.strokeKey(for: annotation)
        let strokeUIColor = PDFHighlightStrokeStyle.previewColor
        let paths = annotation.paths ?? []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, local) in paths.enumerated() {
            guard let viewPath = convertPath(local, annotation: annotation, page: page, pdfView: pdfView) else { continue }
            let shape = CAShapeLayer()
            shape.name = "\(key)#\(i)"
            shape.path = viewPath.cgPath
            shape.strokeColor = strokeUIColor.cgColor
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = lineW
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.opacity = darkInvertActive ? 0.55 : 0.70
            inkHost.addSublayer(shape)
        }
        CATransaction.commit()
    }

    func removeStroke(_ annotation: PDFAnnotation) {
        let prefix = Self.strokeKey(for: annotation) + "#"
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkHost.sublayers?
            .filter { ($0.name ?? "").hasPrefix(prefix) }
            .forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
    }

    private static func strokeKey(for annotation: PDFAnnotation) -> String {
        "ink-\(ObjectIdentifier(annotation))"
    }

    func reload(darkInvertActive: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkHost.setAffineTransform(.identity)
        inkHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()

        guard let pdfView = pdfView, let document = pdfView.document else { return }

        // Pad visible set so ink near the edge appears before scroll-idle rebuild.
        let pages: [PDFPage]
        if #available(iOS 11.0, *), !pdfView.visiblePages.isEmpty {
            var set = Set<ObjectIdentifier>()
            var list: [PDFPage] = []
            func append(_ page: PDFPage?) {
                guard let page = page else { return }
                let id = ObjectIdentifier(page)
                guard !set.contains(id) else { return }
                set.insert(id)
                list.append(page)
            }
            for page in pdfView.visiblePages {
                append(page)
                let idx = document.index(for: page)
                if idx > 0 { append(document.page(at: idx - 1)) }
                if idx + 1 < document.pageCount { append(document.page(at: idx + 1)) }
            }
            pages = list
        } else if let cur = pdfView.currentPage {
            pages = [cur]
        } else {
            pages = (0..<min(document.pageCount, 3)).compactMap { document.page(at: $0) }
        }

        let strokeUIColor = PDFHighlightStrokeStyle.previewColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for page in pages {
            for ann in page.annotations {
                guard isNoteInk(ann) else { continue }
                let lineW = max(ann.border?.lineWidth ?? 3.2, 1.5) * max(pdfView.scaleFactor, 0.5)
                let key = Self.strokeKey(for: ann)
                let paths = ann.paths ?? []
                for (i, local) in paths.enumerated() {
                    guard let viewPath = convertPath(local, annotation: ann, page: page, pdfView: pdfView) else { continue }
                    let shape = CAShapeLayer()
                    shape.name = "\(key)#\(i)"
                    shape.path = viewPath.cgPath
                    shape.strokeColor = strokeUIColor.cgColor
                    shape.fillColor = UIColor.clear.cgColor
                    shape.lineWidth = lineW
                    shape.lineCap = .round
                    shape.lineJoin = .round
                    shape.opacity = darkInvertActive ? 0.55 : 0.70
                    inkHost.addSublayer(shape)
                }
            }
        }
        CATransaction.commit()
    }

    private func isNoteInk(_ ann: PDFAnnotation) -> Bool {
        if ann.userName == StudyAskSelectionStore.noteAnnotationUserName { return true }
        let t = (ann.type ?? "").lowercased()
        return t.contains("ink")
    }

    private func convertPath(_ local: UIBezierPath, annotation: PDFAnnotation, page: PDFPage, pdfView: PDFView) -> UIBezierPath? {
        let out = UIBezierPath()
        var ok = false
        local.cgPath.applyWithBlock { elementPtr in
            let e = elementPtr.pointee
            func toView(_ p: CGPoint) -> CGPoint {
                let pagePt = CGPoint(x: p.x + annotation.bounds.minX, y: p.y + annotation.bounds.minY)
                let inPdf = pdfView.convert(pagePt, from: page)
                return self.convert(inPdf, from: pdfView)
            }
            switch e.type {
            case .moveToPoint:
                out.move(to: toView(e.points[0]))
                ok = true
            case .addLineToPoint:
                out.addLine(to: toView(e.points[0]))
            case .addQuadCurveToPoint:
                out.addQuadCurve(to: toView(e.points[1]), controlPoint: toView(e.points[0]))
            case .addCurveToPoint:
                out.addCurve(to: toView(e.points[2]), controlPoint1: toView(e.points[0]), controlPoint2: toView(e.points[1]))
            case .closeSubpath:
                out.close()
            @unknown default:
                break
            }
        }
        return ok ? out : nil
    }
}

/// Opaque-to-hit-test draw surface. Blocks PDF scroll while the pen is armed.
private final class HighlightDrawOverlay: UIView {
    private let shape = CAShapeLayer()
    private var points: [CGPoint] = []

    var lineWidth: CGFloat = 5 {
        didSet { shape.lineWidth = lineWidth }
    }

    var strokeColor: UIColor = PDFHighlightStrokeStyle.previewColor {
        didSet { shape.strokeColor = strokeColor.cgColor }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = UIColor.clear
        clipsToBounds = true
        isMultipleTouchEnabled = false
        shape.strokeColor = strokeColor.cgColor
        shape.fillColor = UIColor.clear.cgColor
        shape.lineWidth = lineWidth
        shape.lineCap = .round
        shape.lineJoin = .round
        // Preview sits above invert filters — normal alpha yellow is enough.
        layer.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func beginStroke(at point: CGPoint) {
        points = [point]
        rebuildPath()
    }

    func appendStroke(to point: CGPoint) {
        points.append(point)
        rebuildPath()
    }

    func showStraight(from start: CGPoint, to end: CGPoint) {
        points = [start, end]
        rebuildPath()
    }

    func clearStroke() {
        points.removeAll()
        shape.path = nil
    }

    private func rebuildPath() {
        let path = UIBezierPath()
        for (idx, p) in points.enumerated() {
            if idx == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        shape.path = path.cgPath
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.frame = bounds
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // When visible + interactive, claim the entire surface so PDF never scrolls.
        guard !isHidden, isUserInteractionEnabled, bounds.contains(point) else { return nil }
        return self
    }
}

/// Single-tap an existing ink/highlight annotation to open its note editor.
final class PDFHighlightNoteTap: NSObject, UIGestureRecognizerDelegate {
    private weak var pdfView: PDFView?
    private let tap = UITapGestureRecognizer()

    var onTapHighlight: ((PDFAnnotation, PDFPage) -> Void)?

    func attach(to pdfView: PDFView) {
        self.pdfView = pdfView
        tap.addTarget(self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delegate = self
        pdfView.addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let pdfView = pdfView else { return }
        if let study = pdfView as? StudyPDFView, study.highlighter.isEnabled { return }
        // Hit-test only on tap end — never in shouldReceive (that ran on every touch and felt laggy).
        guard let hit = annotationAt(gesture.location(in: pdfView), in: pdfView) else { return }
        onTapHighlight?(hit.ann, hit.page)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let pdfView = pdfView else { return false }
        if let study = pdfView as? StudyPDFView, study.highlighter.isEnabled { return false }
        // Cheap gate only — full annotation scan happens in handleTap.
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Don't fight the PDF scroll pan; tap still fires on a clean touch-up.
        true
    }

    private func annotationAt(_ point: CGPoint, in pdfView: PDFView) -> (ann: PDFAnnotation, page: PDFPage)? {
        guard let page = pdfView.page(for: point, nearest: true) else { return nil }
        let pagePoint = pdfView.convert(point, to: page)
        // Prefer our notes; avoid scanning huge annotation lists more than needed.
        for ann in page.annotations.reversed() {
            guard isMarkupAnnotation(ann) else { continue }
            // Distance-to-segment for ink feels better than fat bounds, but bounds is O(1) and enough.
            if ann.bounds.insetBy(dx: -12, dy: -12).contains(pagePoint) {
                return (ann, page)
            }
        }
        return nil
    }

    private func isMarkupAnnotation(_ ann: PDFAnnotation) -> Bool {
        if ann.userName == StudyAskSelectionStore.noteAnnotationUserName { return true }
        let t = (ann.type ?? "").lowercased()
        return t.contains("ink") || t.contains("highlight")
    }
}

// MARK: - Connects-styled note overlay (no modal presentation — keeps PDF/pen snappy)

enum ConnectsNoteSheet {
    private static weak var activeOverlay: ConnectsNoteOverlayView?

    static var isVisible: Bool { activeOverlay != nil }

    /// Posted after the note sheet is removed (save / delete / cancel).
    static let didDismissNotification = Notification.Name("ConnectsNoteSheetDidDismiss")

    static func present(
        from host: UIViewController,
        title: String,
        message: String?,
        initialText: String,
        confirmTitle: String = "保存",
        deleteTitle: String? = "删除划线",
        onSave: @escaping (String) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        // Prefer the study shell root so the sheet can't leave a stale overlay
        // inside the PDF reader that outlives keyboard teardown.
        let container: UIView = {
            var node: UIView? = host.view
            while let cur = node {
                if cur is StudyShellRootViewMarker { return cur }
                node = cur.superview
            }
            return host.view!
        }()
        // Replace without posting didDismiss — that notification's endEditing
        // raced the new sheet and killed the soft keyboard after a black flash.
        activeOverlay?.teardownSilently()
        activeOverlay = nil
        let overlay = ConnectsNoteOverlayView(
            titleText: title,
            messageText: message,
            initialText: initialText,
            confirmTitle: confirmTitle,
            deleteTitle: deleteTitle,
            onSave: onSave,
            onDelete: onDelete,
            onCancel: onCancel
        )
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        bringToFront(in: container)
        activeOverlay = overlay
        container.layoutIfNeeded()
        overlay.presentAnimated()
    }

    /// Keep the note sheet above study chat chrome while editing.
    static func bringToFront(in container: UIView? = nil) {
        let host = container ?? activeOverlay?.superview
        guard let host = host else { return }
        if let overlay = activeOverlay, overlay.superview === host {
            host.bringSubviewToFront(overlay)
        }
    }

    static func dismissIfNeeded() {
        activeOverlay?.dismissImmediate()
        activeOverlay = nil
    }

    fileprivate static func clearActive(_ overlay: ConnectsNoteOverlayView) {
        if activeOverlay === overlay {
            activeOverlay = nil
        }
    }
}

/// Marker so note sheets can climb to the Study shell root.
protocol StudyShellRootViewMarker: AnyObject {}

/// Marker for note overlays hosted on the study shell (hit-test priority).
protocol ConnectsNoteOverlayHitMarker: AnyObject {}

private final class ConnectsNoteOverlayView: UIView, UITextFieldDelegate, ConnectsNoteOverlayHitMarker {
    private let titleText: String
    private let messageText: String?
    private let initialText: String
    private let confirmTitle: String
    private let deleteTitle: String?
    private let onSave: (String) -> Void
    private let onDelete: (() -> Void)?
    private let onCancel: (() -> Void)?

    private let dimView = UIControl()
    private let card = UIView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let field = UITextField()
    private let buttonRow = UIStackView()
    private var didFinish = false
    private var cardCenterY: NSLayoutConstraint!
    private var keyboardObserver: NSObjectProtocol?

    init(
        titleText: String,
        messageText: String?,
        initialText: String,
        confirmTitle: String,
        deleteTitle: String?,
        onSave: @escaping (String) -> Void,
        onDelete: (() -> Void)?,
        onCancel: (() -> Void)?
    ) {
        self.titleText = titleText
        self.messageText = messageText
        self.initialText = initialText
        self.confirmTitle = confirmTitle
        self.deleteTitle = deleteTitle
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        super.init(frame: .zero)
        build()
        registerKeyboard()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let keyboardObserver = keyboardObserver {
            NotificationCenter.default.removeObserver(keyboardObserver)
        }
    }

    private func build() {
        backgroundColor = .clear

        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        addSubview(dimView)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 14
        addSubview(card)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.text = titleText
        titleLabel.textAlignment = .center
        card.addSubview(titleLabel)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.text = messageText
        messageLabel.isHidden = (messageText?.isEmpty ?? true)
        card.addSubview(messageLabel)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = UIFont.systemFont(ofSize: 15)
        field.placeholder = "输入注释…"
        field.text = initialText
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.delegate = self
        field.layer.cornerRadius = 10
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        field.rightViewMode = .always
        card.addSubview(field)

        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.axis = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually
        card.addSubview(buttonRow)

        let cancel = makeButton(title: "取消", style: .secondary)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        buttonRow.addArrangedSubview(cancel)

        if deleteTitle != nil {
            let del = makeButton(title: deleteTitle ?? "删除", style: .destructive)
            del.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
            buttonRow.addArrangedSubview(del)
        }

        let save = makeButton(title: confirmTitle, style: .primary)
        save.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        buttonRow.addArrangedSubview(save)

        cardCenterY = card.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24)

        NSLayoutConstraint.activate([
            dimView.topAnchor.constraint(equalTo: topAnchor),
            dimView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: trailingAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            cardCenterY,
            card.widthAnchor.constraint(equalToConstant: 340),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            messageLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            messageLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            field.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            field.heightAnchor.constraint(equalToConstant: 42),

            buttonRow.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 14),
            buttonRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            buttonRow.heightAnchor.constraint(equalToConstant: 40)
        ])

        applyTheme()
        card.alpha = 0
        card.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        dimView.alpha = 0
    }

    private func registerKeyboard() {
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.keyboardFrameWillChange(note)
        }
    }

    private func keyboardFrameWillChange(_ note: Notification) {
        guard !didFinish, field.isFirstResponder else { return }
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
            ?? UIView.AnimationCurve.easeInOut.rawValue
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))

        layoutIfNeeded()
        let snap = ConnectsKeyboardGeometry.resolve(screenFrame: frame, in: self)
        let cardH = max(card.bounds.height, 180)
        cardCenterY.constant = ConnectsKeyboardGeometry.noteCardCenterYConstant(
            snapshot: snap,
            in: self,
            cardHeight: cardH,
            restingConstant: -24
        )
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.layoutIfNeeded()
        }
    }

    func presentAnimated() {
        ConnectsNoteSheet.bringToFront()
        focusNoteField(retries: 4)
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.dimView.alpha = 1
            self.card.alpha = 1
            self.card.transform = .identity
        } completion: { finished in
            guard finished, !self.didFinish else { return }
            ConnectsNoteSheet.bringToFront()
            self.focusNoteField(retries: 3)
        }
    }

    private func focusNoteField(retries: Int) {
        guard !didFinish else { return }
        ConnectsNoteSheet.bringToFront()
        guard window != nil else {
            guard retries > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.focusNoteField(retries: retries - 1)
            }
            return
        }
        field.isUserInteractionEnabled = true
        field.isEnabled = true
        if field.isFirstResponder { return }
        if field.becomeFirstResponder() { return }
        guard retries > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.focusNoteField(retries: retries - 1)
        }
    }

    /// Remove without keyboard teardown notification — used when replacing an active sheet.
    fileprivate func teardownSilently() {
        didFinish = true
        if let keyboardObserver = keyboardObserver {
            NotificationCenter.default.removeObserver(keyboardObserver)
            self.keyboardObserver = nil
        }
        field.resignFirstResponder()
        removeFromSuperview()
    }

    func dismissImmediate() {
        ConnectsNoteSheet.clearActive(self)
        resignKeyboardInstantly()
        isUserInteractionEnabled = false
        removeFromSuperview()
        // Match `finish()` so pen-toggle dismiss also re-arms study ▲▼.
        NotificationCenter.default.post(name: ConnectsNoteSheet.didDismissNotification, object: nil)
    }

    private func resignKeyboardInstantly() {
        // Only resign our field — window-wide endEditing poisoned the next note open.
        field.resignFirstResponder()
    }

    private enum ButtonStyle { case primary, secondary, destructive }

    private func makeButton(title: String, style: ButtonStyle) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        b.layer.cornerRadius = 10
        b.clipsToBounds = true
        b.accessibilityIdentifier = "\(style)"
        return b
    }

    private func applyTheme() {
        let c = DSTheme.c
        let dark = ThemeManager.shared.mode == .dark
        dimView.backgroundColor = UIColor.black.withAlphaComponent(dark ? 0.22 : 0.10)
        card.backgroundColor = dark
            ? UIColor(red: 50/255, green: 50/255, blue: 54/255, alpha: 1)
            : UIColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1)
        card.layer.borderWidth = dark ? 0.5 : 1
        card.layer.borderColor = dark
            ? UIColor.white.withAlphaComponent(0.10).cgColor
            : UIColor.black.withAlphaComponent(0.08).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = dark ? 0.40 : 0.12
        card.layer.shadowRadius = dark ? 16 : 12
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        titleLabel.textColor = c.textPrimary
        messageLabel.textColor = c.textSecondary
        field.textColor = c.textPrimary
        field.backgroundColor = c.surfaceHover
        field.tintColor = c.accent
        field.attributedPlaceholder = NSAttributedString(
            string: "输入注释…",
            attributes: [.foregroundColor: c.textTertiary]
        )
        for case let b as UIButton in buttonRow.arrangedSubviews {
            styleButton(b)
        }
    }

    private func styleButton(_ b: UIButton) {
        let c = DSTheme.c
        switch b.accessibilityIdentifier ?? "" {
        case "primary":
            b.backgroundColor = c.accent
            b.setTitleColor(.white, for: .normal)
        case "destructive":
            b.backgroundColor = UIColor.systemRed.withAlphaComponent(0.16)
            b.setTitleColor(.systemRed, for: .normal)
        default:
            b.backgroundColor = c.surfaceHover
            b.setTitleColor(c.textPrimary, for: .normal)
        }
    }

    private func finish(_ work: (() -> Void)?) {
        guard !didFinish else { return }
        didFinish = true
        ConnectsNoteSheet.clearActive(self)
        resignKeyboardInstantly()
        isUserInteractionEnabled = false
        // Instant remove — animated dismiss felt sluggish after typing.
        removeFromSuperview()
        work?()
        NotificationCenter.default.post(name: ConnectsNoteSheet.didDismissNotification, object: nil)
    }

    @objc private func cancelTapped() { finish(onCancel) }
    @objc private func saveTapped() {
        let text = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        finish { self.onSave(text) }
    }
    @objc private func deleteTapped() { finish(onDelete) }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        saveTapped()
        return true
    }
}

private extension PDFView {
    var connectsEmbeddedScrollViews: [UIScrollView] {
        var results: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scrollView = view as? UIScrollView {
                results.append(scrollView)
            }
            for subview in view.subviews {
                walk(subview)
            }
        }
        walk(self)
        return results
    }

    /// The document scroller (largest content) — ignore tiny nested UIScrollViews.
    var connectsPrimaryDocumentScrollView: UIScrollView? {
        connectsEmbeddedScrollViews.max { a, b in
            let areaA = a.contentSize.width * a.contentSize.height
            let areaB = b.contentSize.width * b.contentSize.height
            if areaA != areaB { return areaA < areaB }
            return a.bounds.width * a.bounds.height < b.bounds.width * b.bounds.height
        }
    }
}

