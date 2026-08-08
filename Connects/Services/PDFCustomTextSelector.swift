import UIKit
import PDFKit

/// Hit-through overlay so compositing layers never steal PDF touches.
final class PassthroughOverlayView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }
}

/// Colour of the committed highlight ink, which differs on screen and on disk.
///
/// In Connects the visible stroke is drawn by `CommittedInkOverlay` (it has to sit
/// above the dark-mode invert filter), so PDFKit's own paint is kept near-clear to
/// avoid painting the highlight twice. That near-clear colour used to be what got
/// written to the file as well, which meant a PDF opened in Preview, Acrobat or any
/// other reader showed no highlights at all — the annotations were there, just
/// invisible. Serialization swaps in `inFile` so the marks travel with the document.
enum ConnectsInk {
    static let onScreen = UIColor(red: 1.0, green: 0.92, blue: 0.12, alpha: 0.02)
    static let inFile = UIColor(red: 1.0, green: 0.92, blue: 0.12, alpha: 0.32)

    /// Visible cyan painted by PDFKit so zoom/scroll stay glued to the page.
    /// (Earlier near-clear + overlay frames caused pinch-zoom drift.)
    static let boxOnScreen = UIColor(red: 0.18, green: 0.78, blue: 0.86, alpha: 0.95)
    /// Pre-inverted companion: after white+difference blend ≈ `boxOnScreen` cyan.
    static let boxOnScreenUnderInvert = UIColor(red: 0.82, green: 0.22, blue: 0.14, alpha: 0.95)
    static let boxInFile = UIColor(
        red: ReadingAnnotationStyle.pdfBoxRed.r,
        green: ReadingAnnotationStyle.pdfBoxRed.g,
        blue: ReadingAnnotationStyle.pdfBoxRed.b,
        alpha: ReadingAnnotationStyle.pdfBoxRed.a
    )
    /// Same as on-screen cyan (rubber-band / captions / sidebar).
    static let boxCommitted = boxOnScreen
    static let boxCommittedFill = UIColor(red: 0.18, green: 0.78, blue: 0.86, alpha: 0.10)

    static func boxDisplayColor(darkInvertActive: Bool) -> UIColor {
        darkInvertActive ? boxOnScreenUnderInvert : boxOnScreen
    }

    static func isCommitted(_ annotation: PDFAnnotation) -> Bool {
        annotation.userName == StudyAskSelectionStore.noteAnnotationUserName
    }

    static func isBox(_ annotation: PDFAnnotation) -> Bool {
        if annotation.userName == StudyAskSelectionStore.boxAnnotationUserName { return true }
        return (annotation.type ?? "").lowercased().contains("square")
    }

    /// Runs `body` with every committed ink / box temporarily coloured for the
    /// file, then puts the on-screen colour back.
    static func withFileColors<T>(in document: PDFDocument, _ body: () -> T) -> T {
        var inkTouched: [PDFAnnotation] = []
        var boxTouched: [(PDFAnnotation, UIColor, PDFBorder?)] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                if isCommitted(annotation) {
                    annotation.color = inFile
                    inkTouched.append(annotation)
                } else if isBox(annotation) {
                    boxTouched.append((annotation, annotation.color, annotation.border))
                    annotation.color = boxInFile
                    let border = PDFBorder()
                    border.lineWidth = 1.6
                    border.style = .dashed
                    annotation.border = border
                }
            }
        }
        defer {
            for annotation in inkTouched { annotation.color = onScreen }
            for (annotation, color, border) in boxTouched {
                annotation.color = color
                annotation.border = border
            }
        }
        return body()
    }

    /// Restore on-screen colours after load / theme change. Boxes are painted by
    /// PDFKit (native zoom); ink stays near-clear (overlay paints the yellow stroke).
    static func normalizeForDisplay(in document: PDFDocument, darkInvertActive: Bool = false) {
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                if isCommitted(annotation) {
                    annotation.color = onScreen
                } else if isBox(annotation) {
                    applyBoxDisplayStyle(annotation, darkInvertActive: darkInvertActive)
                }
            }
        }
    }

    static func applyBoxDisplayStyle(_ annotation: PDFAnnotation, darkInvertActive: Bool) {
        annotation.color = boxDisplayColor(darkInvertActive: darkInvertActive)
        let border = PDFBorder()
        border.lineWidth = 1.6
        border.style = .dashed
        annotation.border = border
        annotation.interiorColor = UIColor.clear
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
        annotation.color = ConnectsInk.onScreen
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

/// Dashed square owned by PDFKit (zooms/scrolls with the page). Note captions outside
/// the box are still painted by `BoxNoteCaptionOverlay` (PDFKit clips draw to bounds).
final class ConnectsBoxAnnotation: PDFAnnotation {
    static func make(bounds: CGRect, darkInvertActive: Bool = false) -> ConnectsBoxAnnotation {
        let annotation = ConnectsBoxAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        ConnectsInk.applyBoxDisplayStyle(annotation, darkInvertActive: darkInvertActive)
        annotation.userName = StudyAskSelectionStore.boxAnnotationUserName
        annotation.contents = ""
        annotation.isReadOnly = false
        return annotation
    }

    static func migrate(in document: PDFDocument) {
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let stale = page.annotations.filter { ann in
                !(ann is ConnectsBoxAnnotation)
                    && ann.userName == StudyAskSelectionStore.boxAnnotationUserName
            }
            for ann in stale {
                let neu = ConnectsBoxAnnotation.make(bounds: ann.bounds)
                neu.contents = ann.contents
                neu.color = ann.color
                if let border = ann.border { neu.border = border }
                page.removeAnnotation(ann)
                page.addAnnotation(neu)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override init(bounds: CGRect, forType annotationType: PDFAnnotationSubtype, withProperties properties: [AnyHashable: Any]?) {
        super.init(bounds: bounds, forType: annotationType, withProperties: properties)
    }
}

/// Tiny note previews outside each box (frames themselves are PDFKit annotations).
/// Drawn above the dark-mode invert stack. Scroll-translate while flinging; rebuild on idle/zoom.
private final class BoxNoteCaptionOverlay: UIView {
    private static let captionMaxChars = 18
    private static let fontSize: CGFloat = 7
    private let host = UIView()
    private var anchorOffset: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // Must clip — scroll translation otherwise paints captions into the status bar.
        clipsToBounds = true
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = false
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if host.transform.isIdentity {
            host.frame = bounds
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    func resetScrollAnchor(_ offset: CGPoint) {
        anchorOffset = offset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.transform = .identity
        host.frame = bounds
        CATransaction.commit()
    }

    /// Stick captions to the page by matching the scroller delta (same as ink).
    func applyScrollTranslation(currentOffset: CGPoint) {
        let dx = anchorOffset.x - currentOffset.x
        let dy = anchorOffset.y - currentOffset.y
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.transform = CGAffineTransform(translationX: dx, y: dy)
        CATransaction.commit()
    }

    func reload(from pdfView: PDFView) {
        host.subviews.forEach { $0.removeFromSuperview() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.transform = .identity
        host.frame = bounds
        CATransaction.commit()

        guard let document = pdfView.document else { return }
        if let scroll = pdfView.connectsPrimaryDocumentScrollView {
            anchorOffset = scroll.contentOffset
        }

        let pages: [PDFPage] = {
            var indices = Set<Int>()
            let addNeighbors: (PDFPage) -> Void = { page in
                let i = document.index(for: page)
                guard i != NSNotFound else { return }
                indices.insert(i)
                if i > 0 { indices.insert(i - 1) }
                if i + 1 < document.pageCount { indices.insert(i + 1) }
            }
            if #available(iOS 11.0, *), !pdfView.visiblePages.isEmpty {
                pdfView.visiblePages.forEach(addNeighbors)
            } else if let page = pdfView.currentPage {
                addNeighbors(page)
            } else {
                for i in 0..<min(document.pageCount, 3) { indices.insert(i) }
            }
            return indices.sorted().compactMap { document.page(at: $0) }
        }()

        for page in pages {
            for ann in page.annotations where ConnectsInk.isBox(ann) {
                addCaption(for: ann, page: page, pdfView: pdfView)
            }
        }
    }

    private func addCaption(for ann: PDFAnnotation, page: PDFPage, pdfView: PDFView) {
        let raw = (ann.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        let ink = ConnectsInk.boxCommitted
        let font = UIFont.systemFont(ofSize: Self.fontSize, weight: .medium)
        let caption = Self.captionPreview(raw)
        let b = ann.bounds
        let topLeftPage = CGPoint(x: b.minX, y: b.maxY)
        let inPdf = pdfView.convert(topLeftPage, from: page)
        let corner = convert(inPdf, from: pdfView)

        let label = UILabel()
        label.font = font
        label.textColor = ink
        label.text = caption
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()
        let maxW = max(36, min(label.bounds.width, bounds.width - 8))
        label.frame.size.width = min(label.bounds.width, maxW)

        var origin = CGPoint(x: corner.x, y: corner.y - label.bounds.height - 1)
        if origin.y < 1 {
            origin = CGPoint(
                x: max(2, corner.x - label.bounds.width - 3),
                y: corner.y
            )
        }
        origin.x = min(max(2, origin.x), max(2, bounds.width - label.bounds.width - 2))
        label.frame.origin = origin
        host.addSubview(label)
    }

    private static func captionPreview(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if flat.count <= captionMaxChars { return flat }
        let idx = flat.index(flat.startIndex, offsetBy: captionMaxChars)
        return String(flat[..<idx]) + "…"
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

/// MarginNote-style dashed rectangle selector for scanned PDFs.
final class PDFBoxSelectTool: NSObject, UIGestureRecognizerDelegate {
    /// Resize only — no whole-box move.
    private enum Handle {
        case n, s, e, w, ne, nw, se, sw
    }

    private enum DragMode {
        case none
        case create
        case adjust(annotation: PDFAnnotation, page: PDFPage, handle: Handle, startBounds: CGRect, startPagePoint: CGPoint)
    }

    private weak var pdfView: PDFView?
    private let pan = UIPanGestureRecognizer()
    private let rubberBand = BoxRubberBandOverlay()
    private let captionOverlay = BoxNoteCaptionOverlay()
    private var overlayConstraints: [NSLayoutConstraint] = []
    private var captionConstraints: [NSLayoutConstraint] = []
    private var dragMode: DragMode = .none
    private var createStartPage = CGPoint.zero
    private var createPage: PDFPage?
    /// Large hit target so edges/corners win over accidental new-box gestures.
    private let handleSlopView: CGFloat = 28
    private var scrollEnabledBackup: [ObjectIdentifier: (scroll: Bool, pan: Bool)] = [:]
    private var captionObservers: [NSObjectProtocol] = []
    private var captionScrollObservation: NSKeyValueObservation?
    private var captionRefreshWork: DispatchWorkItem?
    /// Scale rebuilds must not be cancelled by zoom-driven contentOffset churn.
    private var captionScaleWork: DispatchWorkItem?
    private var lastVisiblePageIDs: Set<ObjectIdentifier> = []
    /// View-space frames are only valid at this scale; scroll-translate is forbidden otherwise.
    private var lastPaintedScale: CGFloat = 0
    private var lastScaleRebuildMediaTime: CFTimeInterval = 0

    private(set) var isEnabled = false
    private(set) var isActivelySelecting = false
    /// Mirrors reader dark invert so new boxes use the pre-inverted PDFKit colour.
    var darkInvertActive = false
    /// Finger-up after resize/create often also fires the note tap — suppress briefly.
    private var suppressNoteTapUntil: CFTimeInterval = 0

    var onBoxFinished: ((PDFAnnotation, PDFPage) -> Void)?
    var onBoxAdjusted: ((PDFAnnotation, PDFPage) -> Void)?

    var shouldSuppressNoteTap: Bool {
        CACurrentMediaTime() < suppressNoteTapUntil
    }

    func attach(to pdfView: PDFView) {
        self.pdfView = pdfView
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = self
        pan.isEnabled = false
        pdfView.addGestureRecognizer(pan)

        rubberBand.isHidden = true
        rubberBand.isUserInteractionEnabled = false
        rubberBand.translatesAutoresizingMaskIntoConstraints = false
        captionOverlay.translatesAutoresizingMaskIntoConstraints = false
        installCaptionObservers(on: pdfView)
    }

    deinit {
        captionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        captionScrollObservation?.invalidate()
    }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        pan.isEnabled = on
        setDocumentScrollingEnabled(!on)
        if !on {
            // Unlock scroll immediately. Rebuilding captions here used to hitch the
            // toggle-off path for no reason — labels do not change when the tool
            // is put away.
            cancelSelection()
            return
        }
        ensureOverlayInstalled()
        refreshCaptions()
    }

    /// Re-assert scroll lock after PDFKit rebuilds scroll views.
    func refreshScrollLock() {
        guard isEnabled else { return }
        setDocumentScrollingEnabled(false)
    }

    /// Reload tiny note labels outside each box (call after note save / document load).
    func refreshCaptions() {
        ensureOverlayInstalled()
        guard let pdfView else { return }
        captionScaleWork?.cancel()
        captionRefreshWork?.cancel()
        captionOverlay.layoutIfNeeded()
        captionOverlay.reload(from: pdfView)
        lastPaintedScale = pdfView.scaleFactor
        rebindCaptionScroll(on: pdfView)
    }

    private func scheduleCaptionRebuild(delay: TimeInterval = 0.12) {
        captionRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshCaptions()
        }
        captionRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Pinch zoom changes scale + offset together; scroll-translate on old geometry flies off-screen.
    private func handleCaptionScaleChanged() {
        guard let pdfView else { return }
        // Drop stale transform immediately so boxes do not "fly" with zoom offset deltas.
        if let scroll = pdfView.connectsPrimaryDocumentScrollView {
            captionOverlay.resetScrollAnchor(scroll.contentOffset)
        } else {
            captionOverlay.resetScrollAnchor(.zero)
        }
        // Throttle live rebuilds during a continuous pinch (~30fps).
        let now = CACurrentMediaTime()
        if now - lastScaleRebuildMediaTime >= 0.033 {
            lastScaleRebuildMediaTime = now
            refreshCaptions()
            return
        }
        captionScaleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.lastScaleRebuildMediaTime = CACurrentMediaTime()
            self?.refreshCaptions()
        }
        captionScaleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033, execute: work)
    }

    private func captionScaleIsStale(for pdfView: PDFView) -> Bool {
        guard lastPaintedScale > 0 else { return true }
        return abs(pdfView.scaleFactor - lastPaintedScale) > 0.0005
    }

    private func installCaptionObservers(on pdfView: PDFView) {
        captionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        captionObservers.removeAll()
        let nc = NotificationCenter.default
        captionObservers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.handleCaptionScaleChanged()
        })
        captionObservers.append(nc.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.scheduleCaptionRebuild(delay: 0.05)
        })
        captionObservers.append(nc.addObserver(forName: .PDFViewVisiblePagesChanged, object: pdfView, queue: .main) { [weak self] _ in
            // Fast flings bring new pages on screen — paint immediately (not during scale).
            guard let self, let pdfView = self.pdfView else { return }
            if self.captionScaleIsStale(for: pdfView) {
                self.handleCaptionScaleChanged()
                return
            }
            self.scheduleCaptionRebuild(delay: 0)
        })
        rebindCaptionScroll(on: pdfView)
    }

    private func rebindCaptionScroll(on pdfView: PDFView) {
        captionScrollObservation?.invalidate()
        captionScrollObservation = nil
        lastVisiblePageIDs = visiblePageIDs(in: pdfView)
        guard let scroll = pdfView.connectsPrimaryDocumentScrollView else { return }
        captionOverlay.resetScrollAnchor(scroll.contentOffset)
        captionScrollObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            guard let self else { return }
            // Zoom also moves contentOffset — never translate frames painted at another scale.
            if self.captionScaleIsStale(for: pdfView) {
                self.handleCaptionScaleChanged()
                return
            }
            // Follow the page instantly — do not rebuild mid-fling (that made labels drift).
            self.captionOverlay.applyScrollTranslation(currentOffset: scrollView.contentOffset)
            let ids = self.visiblePageIDs(in: pdfView)
            if ids != self.lastVisiblePageIDs {
                self.lastVisiblePageIDs = ids
                self.refreshCaptions()
                return
            }
            self.captionRefreshWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                if self.captionScaleIsStale(for: pdfView) {
                    self.handleCaptionScaleChanged()
                    return
                }
                if scrollView.isDragging || scrollView.isDecelerating {
                    self.captionOverlay.applyScrollTranslation(currentOffset: scrollView.contentOffset)
                    return
                }
                self.refreshCaptions()
            }
            self.captionRefreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }

    private func visiblePageIDs(in pdfView: PDFView) -> Set<ObjectIdentifier> {
        if #available(iOS 11.0, *) {
            return Set(pdfView.visiblePages.map { ObjectIdentifier($0) })
        }
        if let page = pdfView.currentPage {
            return [ObjectIdentifier(page)]
        }
        return []
    }

    func ensureOverlayInstalled() {
        guard let pdfView = pdfView, let host = pdfView.superview else { return }
        if captionOverlay.superview !== host {
            captionOverlay.removeFromSuperview()
            NSLayoutConstraint.deactivate(captionConstraints)
            host.insertSubview(captionOverlay, aboveSubview: pdfView)
            captionConstraints = [
                captionOverlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
                captionOverlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
                captionOverlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
                captionOverlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor)
            ]
            NSLayoutConstraint.activate(captionConstraints)
        }
        if rubberBand.superview !== host {
            rubberBand.removeFromSuperview()
            NSLayoutConstraint.deactivate(overlayConstraints)
            host.insertSubview(rubberBand, aboveSubview: captionOverlay.superview == host ? captionOverlay : pdfView)
            overlayConstraints = [
                rubberBand.topAnchor.constraint(equalTo: pdfView.topAnchor),
                rubberBand.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
                rubberBand.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
                rubberBand.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor)
            ]
            NSLayoutConstraint.activate(overlayConstraints)
        } else if captionOverlay.superview == host {
            host.insertSubview(rubberBand, aboveSubview: captionOverlay)
        }
    }

    private func setDocumentScrollingEnabled(_ enabled: Bool) {
        guard let pdfView else { return }
        let scrolls = pdfView.connectsEmbeddedScrollViews
        if !enabled {
            for sv in scrolls {
                let id = ObjectIdentifier(sv)
                if scrollEnabledBackup[id] == nil {
                    scrollEnabledBackup[id] = (sv.isScrollEnabled, sv.panGestureRecognizer.isEnabled)
                }
                sv.isScrollEnabled = false
                sv.panGestureRecognizer.isEnabled = false
            }
        } else {
            for sv in scrolls {
                let id = ObjectIdentifier(sv)
                if let bak = scrollEnabledBackup[id] {
                    sv.isScrollEnabled = bak.scroll
                    sv.panGestureRecognizer.isEnabled = bak.pan
                } else {
                    sv.isScrollEnabled = true
                    sv.panGestureRecognizer.isEnabled = true
                }
            }
            scrollEnabledBackup.removeAll()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isEnabled, let pdfView = pdfView else { return }
        let viewPoint = gesture.location(in: pdfView)
        let overlayPoint = gesture.location(in: rubberBand)

        switch gesture.state {
        case .began:
            ensureOverlayInstalled()
            refreshScrollLock()
            if let hit = hitTestExistingBox(at: viewPoint) {
                isActivelySelecting = true
                dragMode = .adjust(
                    annotation: hit.ann,
                    page: hit.page,
                    handle: hit.handle,
                    startBounds: hit.ann.bounds,
                    startPagePoint: pdfView.convert(viewPoint, to: hit.page)
                )
                // Resize in PDFKit itself — no overlay frame (keeps zoom correct).
                rubberBand.clear()
                rubberBand.isHidden = true
            } else if let hitPage = pdfView.page(for: viewPoint, nearest: true) {
                isActivelySelecting = true
                dragMode = .create
                createPage = hitPage
                createStartPage = pdfView.convert(viewPoint, to: hitPage)
                rubberBand.setStyle(.creating)
                rubberBand.isHidden = false
                rubberBand.begin(at: overlayPoint)
            } else {
                cancelSelection()
            }

        case .changed:
            switch dragMode {
            case .create:
                rubberBand.update(to: overlayPoint)
            case .adjust(let ann, let page, let handle, let startBounds, let startPagePoint):
                let cur = pdfView.convert(viewPoint, to: page)
                let dx = cur.x - startPagePoint.x
                let dy = cur.y - startPagePoint.y
                ann.bounds = resizedBounds(startBounds, handle: handle, dx: dx, dy: dy)
            case .none:
                break
            }

        case .ended:
            finishDrag(endView: viewPoint)
        case .cancelled, .failed:
            cancelSelection()
        default:
            break
        }
    }

    private func finishDrag(endView: CGPoint) {
        // Pan end + tap compete; block note sheet until the lift settles.
        suppressNoteTapUntil = CACurrentMediaTime() + 0.45
        defer {
            isActivelySelecting = false
            dragMode = .none
            createPage = nil
        }
        guard let pdfView else {
            rubberBand.clear()
            rubberBand.isHidden = true
            return
        }

        switch dragMode {
        case .create:
            guard let page = createPage else {
                rubberBand.clear()
                rubberBand.isHidden = true
                return
            }
            let endPage = pdfView.convert(endView, to: page)
            let bounds = CGRect(
                x: min(createStartPage.x, endPage.x),
                y: min(createStartPage.y, endPage.y),
                width: abs(endPage.x - createStartPage.x),
                height: abs(endPage.y - createStartPage.y)
            )
            // Require a deliberate drag so edge-adjust near existing boxes isn't a new frame.
            guard bounds.width >= 16, bounds.height >= 16 else {
                rubberBand.clear()
                rubberBand.isHidden = true
                return
            }

            let annotation = makeSquareAnnotation(bounds: bounds)
            // PDFKit owns the visible frame — add immediately so zoom stays native.
            page.addAnnotation(annotation)
            rubberBand.clear()
            rubberBand.isHidden = true
            onBoxFinished?(annotation, page)
            scheduleCaptionRebuild(delay: 0.05)

        case .adjust(let ann, let page, _, let startBounds, _):
            rubberBand.clear()
            rubberBand.isHidden = true
            if ann.bounds.width < 12 || ann.bounds.height < 12 {
                ann.bounds = startBounds
            }
            onBoxAdjusted?(ann, page)
            // Captions (if any) need a reproject; the square itself is already in PDFKit.
            scheduleCaptionRebuild(delay: 0.05)

        case .none:
            rubberBand.clear()
            rubberBand.isHidden = true
        }
    }

    private func makeSquareAnnotation(bounds: CGRect) -> PDFAnnotation {
        ConnectsBoxAnnotation.make(bounds: bounds, darkInvertActive: darkInvertActive)
    }

    private func showRubberBand(for pageBounds: CGRect, on page: PDFPage, pdfView: PDFView) {
        let topLeft = pdfView.convert(CGPoint(x: pageBounds.minX, y: pageBounds.maxY), from: page)
        let bottomRight = pdfView.convert(CGPoint(x: pageBounds.maxX, y: pageBounds.minY), from: page)
        let a = rubberBand.convert(topLeft, from: pdfView)
        let b = rubberBand.convert(bottomRight, from: pdfView)
        let rect = CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
        rubberBand.isHidden = false
        rubberBand.show(rect)
    }

    private func cancelSelection() {
        suppressNoteTapUntil = CACurrentMediaTime() + 0.45
        isActivelySelecting = false
        dragMode = .none
        createPage = nil
        rubberBand.clear()
        rubberBand.isHidden = true
    }

    private func hitTestExistingBox(at viewPoint: CGPoint) -> (ann: PDFAnnotation, page: PDFPage, handle: Handle)? {
        guard let pdfView,
              let page = pdfView.page(for: viewPoint, nearest: true)
        else { return nil }
        let pagePoint = pdfView.convert(viewPoint, to: page)
        let scale = max(pdfView.scaleFactor, 0.2)
        let slop = handleSlopView / scale

        var best: (ann: PDFAnnotation, handle: Handle, score: CGFloat)?
        for ann in page.annotations where isConnectsBox(ann) {
            let b = ann.bounds
            let expanded = b.insetBy(dx: -slop, dy: -slop)
            guard expanded.contains(pagePoint) else { continue }
            // Edges / corners only — no whole-frame drag.
            guard let handle = nearestHandle(in: b, point: pagePoint, slop: slop) else { continue }
            let score = handleDistance(handle, bounds: b, point: pagePoint)
            if best == nil || score < best!.score {
                best = (ann, handle, score)
            }
        }
        guard let best else { return nil }
        return (best.ann, page, best.handle)
    }

    private func isConnectsBox(_ ann: PDFAnnotation) -> Bool {
        ConnectsInk.isBox(ann)
    }

    private func nearestHandle(in bounds: CGRect, point: CGPoint, slop: CGFloat) -> Handle? {
        let corners: [(Handle, CGPoint)] = [
            (.nw, CGPoint(x: bounds.minX, y: bounds.maxY)),
            (.ne, CGPoint(x: bounds.maxX, y: bounds.maxY)),
            (.sw, CGPoint(x: bounds.minX, y: bounds.minY)),
            (.se, CGPoint(x: bounds.maxX, y: bounds.minY)),
        ]
        for (h, p) in corners {
            if hypot(point.x - p.x, point.y - p.y) <= slop { return h }
        }
        // Edges (PDF coords: y grows up)
        if abs(point.y - bounds.maxY) <= slop, point.x >= bounds.minX - slop, point.x <= bounds.maxX + slop { return .n }
        if abs(point.y - bounds.minY) <= slop, point.x >= bounds.minX - slop, point.x <= bounds.maxX + slop { return .s }
        if abs(point.x - bounds.minX) <= slop, point.y >= bounds.minY - slop, point.y <= bounds.maxY + slop { return .w }
        if abs(point.x - bounds.maxX) <= slop, point.y >= bounds.minY - slop, point.y <= bounds.maxY + slop { return .e }
        return nil
    }

    private func handleDistance(_ handle: Handle, bounds: CGRect, point: CGPoint) -> CGFloat {
        let p: CGPoint
        switch handle {
        case .n: p = CGPoint(x: bounds.midX, y: bounds.maxY)
        case .s: p = CGPoint(x: bounds.midX, y: bounds.minY)
        case .e: p = CGPoint(x: bounds.maxX, y: bounds.midY)
        case .w: p = CGPoint(x: bounds.minX, y: bounds.midY)
        case .ne: p = CGPoint(x: bounds.maxX, y: bounds.maxY)
        case .nw: p = CGPoint(x: bounds.minX, y: bounds.maxY)
        case .se: p = CGPoint(x: bounds.maxX, y: bounds.minY)
        case .sw: p = CGPoint(x: bounds.minX, y: bounds.minY)
        }
        return hypot(point.x - p.x, point.y - p.y)
    }

    private func resizedBounds(_ start: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = start.minX
        var maxX = start.maxX
        var minY = start.minY
        var maxY = start.maxY
        switch handle {
        case .n: maxY += dy
        case .s: minY += dy
        case .e: maxX += dx
        case .w: minX += dx
        case .ne: maxX += dx; maxY += dy
        case .nw: minX += dx; maxY += dy
        case .se: maxX += dx; minY += dy
        case .sw: minX += dx; minY += dy
        }
        let out = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                         width: abs(maxX - minX), height: abs(maxY - minY))
        return out
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isEnabled
    }
}

private final class BoxRubberBandOverlay: UIView {
    enum Style {
        case creating
        case committed
    }

    private var start = CGPoint.zero
    private var end = CGPoint.zero
    private let shape = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = true
        shape.lineWidth = 1.5
        shape.lineDashPattern = [5, 3]
        layer.addSublayer(shape)
        setStyle(.creating)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setStyle(_ style: Style) {
        switch style {
        case .creating:
            shape.fillColor = UIColor(red: 0.90, green: 0.18, blue: 0.18, alpha: 0.08).cgColor
            shape.strokeColor = UIColor(red: 0.90, green: 0.18, blue: 0.18, alpha: 0.95).cgColor
        case .committed:
            shape.fillColor = ConnectsInk.boxCommittedFill.cgColor
            shape.strokeColor = ConnectsInk.boxCommitted.cgColor
        }
    }

    func begin(at point: CGPoint) {
        start = point
        end = point
        redraw()
    }

    func update(to point: CGPoint) {
        end = point
        redraw()
    }

    func show(_ rect: CGRect) {
        start = CGPoint(x: rect.minX, y: rect.minY)
        end = CGPoint(x: rect.maxX, y: rect.maxY)
        redraw()
    }

    func clear() {
        start = .zero
        end = .zero
        shape.path = nil
    }

    private func redraw() {
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        shape.path = UIBezierPath(rect: rect).cgPath
    }
}

/// Single-tap an existing ink/highlight/box annotation to open its note editor.
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
        if let study = pdfView as? StudyPDFView {
            if study.highlighter.isEnabled { return }
            if study.boxSelect.isActivelySelecting || study.boxSelect.shouldSuppressNoteTap { return }
        }
        guard let hit = annotationAt(gesture.location(in: pdfView), in: pdfView) else { return }
        onTapHighlight?(hit.ann, hit.page)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let pdfView = pdfView else { return false }
        if let study = pdfView as? StudyPDFView {
            if study.highlighter.isEnabled { return false }
            if study.boxSelect.isActivelySelecting || study.boxSelect.shouldSuppressNoteTap { return false }
        }
        // Only steal taps that land on a mark/box.
        return annotationAt(touch.location(in: pdfView), in: pdfView) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    private func annotationAt(_ point: CGPoint, in pdfView: PDFView) -> (ann: PDFAnnotation, page: PDFPage)? {
        guard let page = pdfView.page(for: point, nearest: true) else { return nil }
        let pagePoint = pdfView.convert(point, to: page)
        let scale = max(pdfView.scaleFactor, 0.2)
        let pad = 22 / scale
        for ann in page.annotations.reversed() {
            guard isMarkupAnnotation(ann) else { continue }
            if ann.bounds.insetBy(dx: -pad, dy: -pad).contains(pagePoint) {
                return (ann, page)
            }
        }
        return nil
    }

    private func isMarkupAnnotation(_ ann: PDFAnnotation) -> Bool {
        if ann.userName == StudyAskSelectionStore.noteAnnotationUserName { return true }
        if ann.userName == StudyAskSelectionStore.boxAnnotationUserName { return true }
        let t = (ann.type ?? "").lowercased()
        return t.contains("ink") || t.contains("highlight") || t.contains("square")
    }
}

// MARK: - Shared reader popup chrome (note sheet ↔ EPUB footnote [1])

/// Shared metrics/colors so annotation notes and EPUB index popups match.
enum ConnectsReaderPopupStyle {
    static let bodyFont = UIFont.systemFont(ofSize: 16)
    static let actionFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    static let cornerRadius: CGFloat = 16
    static let textInset = UIEdgeInsets(top: 16, left: 14, bottom: 12, right: 14)

    static func cardWidth(in container: UIView) -> CGFloat {
        min(380, max(container.bounds.width - 48, 300))
    }

    static func cardHeight(in container: UIView) -> CGFloat {
        min(320, max(container.bounds.height * 0.42, 260))
    }

    static func applyCardChrome(_ card: UIView) {
        card.backgroundColor = DSTheme.reader.surface.withAlphaComponent(0.88)
        card.layer.cornerRadius = cornerRadius
        card.clipsToBounds = true
        card.layer.borderWidth = 1 / UIScreen.main.scale
        card.layer.borderColor = DSTheme.reader.border.withAlphaComponent(0.35).cgColor
        card.layer.shadowOpacity = 0
    }

    static var dimColor: UIColor {
        UIColor.black.withAlphaComponent(0.14)
    }

    static var bodyTextColor: UIColor { DSTheme.reader.textPrimary }
    static var secondaryTextColor: UIColor { DSTheme.reader.textSecondary }
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
        deleteTitle: String? = "删除",
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

/// Marker for EPUB highlight color picker overlays (hit-test priority).
protocol ConnectsHighlightPickerHitMarker: AnyObject {}

private final class ConnectsNoteOverlayView: UIView, UITextViewDelegate, ConnectsNoteOverlayHitMarker {
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
    private let field = UITextView()
    private let placeholderLabel = UILabel()
    private let buttonRow = UIStackView()
    private var didFinish = false
    private var cardCenterY: NSLayoutConstraint!
    private var cardWidthConstraint: NSLayoutConstraint!
    private var cardHeightConstraint: NSLayoutConstraint!
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
        dimView.backgroundColor = ConnectsReaderPopupStyle.dimColor
        dimView.isUserInteractionEnabled = true
        // Blank tap dismisses (replaces 取消).
        dimView.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        addSubview(dimView)

        card.translatesAutoresizingMaskIntoConstraints = false
        ConnectsReaderPopupStyle.applyCardChrome(card)
        addSubview(card)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.text = titleText
        titleLabel.textAlignment = .center
        titleLabel.textColor = ConnectsReaderPopupStyle.bodyTextColor
        titleLabel.isHidden = titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        card.addSubview(titleLabel)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.text = messageText
        messageLabel.textColor = ConnectsReaderPopupStyle.secondaryTextColor
        messageLabel.isHidden = (messageText?.isEmpty ?? true)
        card.addSubview(messageLabel)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = ConnectsReaderPopupStyle.bodyFont
        field.text = initialText
        field.delegate = self
        field.backgroundColor = .clear
        field.textColor = ConnectsReaderPopupStyle.bodyTextColor
        field.tintColor = DSTheme.reader.accent
        field.layer.cornerRadius = 0
        field.textContainerInset = ConnectsReaderPopupStyle.textInset
        field.isScrollEnabled = true
        field.returnKeyType = .default
        card.addSubview(field)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = ConnectsReaderPopupStyle.bodyFont
        placeholderLabel.text = "标题 / 理解…"
        placeholderLabel.textColor = ConnectsReaderPopupStyle.secondaryTextColor
        placeholderLabel.isUserInteractionEnabled = false
        field.addSubview(placeholderLabel)
        placeholderLabel.isHidden = !initialText.isEmpty

        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.distribution = .fillEqually
        buttonRow.alignment = .center
        card.addSubview(buttonRow)

        // No 取消 — blank dim dismisses. Keep 删除 / 保存 as light text actions.
        if deleteTitle != nil, onDelete != nil {
            let del = makeButton(title: deleteTitle ?? "删除", style: .destructive)
            del.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
            buttonRow.addArrangedSubview(del)
        }

        let save = makeButton(title: confirmTitle, style: .primary)
        save.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        buttonRow.addArrangedSubview(save)

        cardCenterY = card.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0)

        let fieldTop: NSLayoutConstraint
        if !messageLabel.isHidden {
            fieldTop = field.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 4)
        } else if !titleLabel.isHidden {
            fieldTop = field.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6)
        } else {
            fieldTop = field.topAnchor.constraint(equalTo: card.topAnchor, constant: 4)
        }

        let screen = UIScreen.main.bounds
        let cardW = min(380, max(screen.width - 48, 300))
        let cardH = min(320, max(screen.height * 0.42, 260))
        cardWidthConstraint = card.widthAnchor.constraint(equalToConstant: cardW)
        cardHeightConstraint = card.heightAnchor.constraint(equalToConstant: cardH)

        NSLayoutConstraint.activate([
            dimView.topAnchor.constraint(equalTo: topAnchor),
            dimView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: trailingAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            cardCenterY,
            cardWidthConstraint,
            cardHeightConstraint,

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: titleLabel.isHidden ? 0 : 12),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            titleLabel.heightAnchor.constraint(equalToConstant: titleLabel.isHidden ? 0 : 20),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: titleLabel.isHidden ? 0 : 2),
            messageLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            messageLabel.heightAnchor.constraint(equalToConstant: messageLabel.isHidden ? 0 : 18),

            fieldTop,
            field.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            field.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -4),

            placeholderLabel.topAnchor.constraint(equalTo: field.topAnchor, constant: ConnectsReaderPopupStyle.textInset.top),
            placeholderLabel.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: ConnectsReaderPopupStyle.textInset.left + 5),

            buttonRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            buttonRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            buttonRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            buttonRow.heightAnchor.constraint(equalToConstant: 40)
        ])

        card.alpha = 0
        card.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        dimView.alpha = 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        let w = ConnectsReaderPopupStyle.cardWidth(in: self)
        let h = ConnectsReaderPopupStyle.cardHeight(in: self)
        if cardWidthConstraint.constant != w { cardWidthConstraint.constant = w }
        if cardHeightConstraint.constant != h { cardHeightConstraint.constant = h }
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
        // Do not auto-focus — opening a note is browse/record first; keyboard only
        // when the user taps into the text field.
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.dimView.alpha = 1
            self.card.alpha = 1
            self.card.transform = .identity
        } completion: { finished in
            guard finished, !self.didFinish else { return }
            ConnectsNoteSheet.bringToFront()
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
        animateOut {
            self.removeFromSuperview()
            NotificationCenter.default.post(name: ConnectsNoteSheet.didDismissNotification, object: nil)
        }
    }

    private func resignKeyboardInstantly() {
        // Only resign our field — window-wide endEditing poisoned the next note open.
        field.resignFirstResponder()
    }

    private enum ButtonStyle { case primary, destructive }

    private func makeButton(title: String, style: ButtonStyle) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = ConnectsReaderPopupStyle.actionFont
        b.backgroundColor = .clear
        b.layer.cornerRadius = 8
        b.clipsToBounds = true
        b.accessibilityIdentifier = "\(style)"
        switch style {
        case .primary:
            b.setTitleColor(DSTheme.reader.accent, for: .normal)
        case .destructive:
            b.setTitleColor(UIColor.systemRed.withAlphaComponent(0.90), for: .normal)
        }
        return b
    }

    private func finish(_ work: (() -> Void)?) {
        guard !didFinish else { return }
        didFinish = true
        ConnectsNoteSheet.clearActive(self)
        resignKeyboardInstantly()
        isUserInteractionEnabled = false
        animateOut {
            self.removeFromSuperview()
            NotificationCenter.default.post(name: ConnectsNoteSheet.didDismissNotification, object: nil)
            if let work {
                DispatchQueue.main.async(execute: work)
            }
        }
    }

    /// Mirror `presentAnimated` (fade + slight scale) so dismiss doesn't hard-cut.
    private func animateOut(_ done: @escaping () -> Void) {
        UIView.animate(
            withDuration: 0.14,
            delay: 0,
            options: [.curveEaseIn, .allowUserInteraction]
        ) {
            self.dimView.alpha = 0
            self.card.alpha = 0
            self.card.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        } completion: { _ in
            done()
        }
    }

    @objc private func cancelTapped() { finish(onCancel) }
    @objc private func saveTapped() {
        let text = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        finish { self.onSave(text) }
    }
    @objc private func deleteTapped() { finish(onDelete) }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
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

