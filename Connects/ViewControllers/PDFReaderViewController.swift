import UIKit
import PDFKit

final class PDFReaderViewController: UIViewController {
    private let topBar = UIView()
    private let sidebarButton = UIButton(type: .system)
    private let pdfView = PDFView()
    private let spinner = UIActivityIndicatorView(style: .gray)
    private let pageLabel = UILabel()
    private var progressWorkItem: DispatchWorkItem?
    private var currentDocumentID: String?
    private var loadGeneration: UInt = 0
    private var sidebarButtonWidthConstraint: NSLayoutConstraint!
    private var lastLayoutSize: CGSize = .zero
    private var isRestoringViewport = false
    private var readerSurfaceActive = true
    private var pendingViewportProgress: StudyProgress?

    var onPageChanged: (() -> Void)?
    var onToggleSidebar: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DSTheme.c.background

        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarButton.addTarget(self, action: #selector(sidebarTapped), for: .touchUpInside)
        sidebarButton.accessibilityLabel = "打开侧栏"
        topBar.addSubview(sidebarButton)
        updateSidebarToggle(collapsed: true)
        sidebarButtonWidthConstraint = sidebarButton.widthAnchor.constraint(equalToConstant: 40)

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = DSTheme.c.background
        view.addSubview(pdfView)

        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        pageLabel.textColor = DSTheme.c.textSecondary
        pageLabel.textAlignment = .center
        topBar.addSubview(pageLabel)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 40),

            sidebarButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            sidebarButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            sidebarButtonWidthConstraint,
            sidebarButton.heightAnchor.constraint(equalToConstant: 40),

            pageLabel.leadingAnchor.constraint(equalTo: sidebarButton.trailingAnchor, constant: 4),
            pageLabel.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            pageLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            pdfView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged),
            name: Notification.Name.PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scaleChanged),
            name: Notification.Name.PDFViewScaleChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard readerSurfaceActive, canLayoutViewport else { return }

        if let pending = pendingViewportProgress {
            pendingViewportProgress = nil
            beginViewportRestore(using: pending)
            return
        }

        let size = pdfView.bounds.size
        if size.width > 1, size.height > 1, size != lastLayoutSize {
            lastLayoutSize = size
            if !isRestoringViewport, pdfView.document != nil, !isZoomedIn {
                refitScaleIfNeeded()
            }
        }

        stabilizeViewportIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flushProgressSave()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func isLoaded(documentID: String) -> Bool {
        currentDocumentID == documentID && pdfView.document != nil
    }

    func setReaderSurfaceActive(_ active: Bool) {
        readerSurfaceActive = active
        if !active {
            pendingViewportProgress = nil
        }
    }

    func updateSidebarToggle(collapsed: Bool) {
        let kind: ActionIconFactory.Kind = collapsed ? .sidebar : .sidebarOpen
        sidebarButton.setImage(ActionIconFactory.image(kind, pointSize: 18), for: .normal)
        sidebarButton.tintColor = DSTheme.c.textSecondary
        sidebarButton.accessibilityLabel = collapsed ? "打开侧栏" : "关闭侧栏"
    }

    func setSidebarButtonHidden(_ hidden: Bool) {
        sidebarButton.isHidden = hidden
        sidebarButtonWidthConstraint.constant = hidden ? 0 : 40
    }

    @objc private func sidebarTapped() {
        onToggleSidebar?()
    }

    @objc private func themeChanged() {
        view.backgroundColor = DSTheme.c.background
        topBar.backgroundColor = DSTheme.c.background
        pdfView.backgroundColor = DSTheme.c.background
        pageLabel.textColor = DSTheme.c.textSecondary
        sidebarButton.tintColor = DSTheme.c.textSecondary
    }

    func load(documentID: String, completion: ((Bool) -> Void)? = nil) {
        if currentDocumentID != documentID {
            pdfView.document = nil
        }
        currentDocumentID = documentID
        loadGeneration &+= 1
        let gen = loadGeneration
        spinner.startAnimating()
        pageLabel.text = "加载中…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let document = StudyDocumentStore.shared.cachedPDFDocument(for: documentID)
            DispatchQueue.main.async {
                guard let self = self, gen == self.loadGeneration, self.currentDocumentID == documentID else {
                    completion?(false)
                    return
                }
                self.spinner.stopAnimating()
                guard let document = document else {
                    self.pageLabel.text = "无法打开 PDF"
                    self.pdfView.document = nil
                    self.currentDocumentID = nil
                    completion?(false)
                    return
                }
                self.pdfView.document = document
                self.updatePageLabel()
                completion?(true)
            }
        }
    }

    func pauseReading() {
        saveReadingProgressNow()
    }

    /// Same document still in memory after leaving study — do not reload progress or refit scale.
    func resumeAfterConversationSwitch() {
        guard pdfView.document != nil else { return }
        readerSurfaceActive = true
        isRestoringViewport = true
        view.layoutIfNeeded()
        lastLayoutSize = pdfView.bounds.size
        clearSpuriousContentInsets()
        isRestoringViewport = false
    }

    func prepareForShellLayoutChange() {
        invalidateViewportLayout()
    }

    func realignVisibleViewport(using progress: StudyProgress?) {
        guard pdfView.document != nil else { return }
        guard readerSurfaceActive, canLayoutViewport else {
            pendingViewportProgress = progress
            return
        }
        beginViewportRestore(using: progress)
    }

    func restoreReadingProgress(_ progress: StudyProgress?) {
        realignVisibleViewport(using: progress)
    }

    private var canLayoutViewport: Bool {
        pdfView.bounds.width > 64 && pdfView.bounds.height > 64
    }

    func stabilizeViewportIfNeeded() {
        guard readerSurfaceActive, canLayoutViewport, pdfView.document != nil,
              !isRestoringViewport else { return }
        clearSpuriousContentInsets()
    }

    private func beginViewportRestore(using progress: StudyProgress?) {
        isRestoringViewport = true
        invalidateViewportLayout()
        view.layoutIfNeeded()
        applyFitScale(from: progress)
        updatePageLabel()
        scrollToProgress(progress, in: pdfView.document!)
        clearSpuriousContentInsets()
        lastLayoutSize = pdfView.bounds.size
        isRestoringViewport = false
    }

    private func invalidateViewportLayout() {
        lastLayoutSize = .zero
    }

    func captureReadingProgress() -> StudyProgress? {
        guard currentDocumentID != nil,
              let doc = pdfView.document,
              let page = pdfView.currentPage else { return nil }
        let index = doc.index(for: page)
        let topLeft = pdfView.convert(CGPoint(x: 0, y: 0), to: page)
        let center = pdfView.convert(CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), to: page)
        let zoomed = isZoomedIn
        return StudyProgress(
            pageIndex: max(0, index),
            pageOffsetY: topLeft.y,
            pageOffsetX: zoomed ? topLeft.x : nil,
            anchorX: zoomed ? center.x : nil,
            anchorY: zoomed ? center.y : nil,
            scaleFactor: zoomed ? pdfView.scaleFactor : nil,
            updatedAt: Date()
        )
    }

    func saveReadingProgressNow() {
        progressWorkItem?.cancel()
        flushProgressSave()
    }

    func clearDocument() {
        loadGeneration &+= 1
        saveReadingProgressNow()
        currentDocumentID = nil
        pdfView.document = nil
        pageLabel.text = nil
        pendingViewportProgress = nil
        invalidateViewportLayout()
    }

    func currentPageText() -> String? {
        pdfView.currentPage?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func currentPageLabel() -> String {
        guard let doc = pdfView.document else { return "无文档" }
        let index: Int
        if let page = pdfView.currentPage {
            index = doc.index(for: page)
        } else {
            index = 0
        }
        let page = max(0, index) + 1
        let total = max(doc.pageCount, 1)
        return "第 \(page) / \(total) 页"
    }

    @objc private func pageChanged() {
        updatePageLabel()
        scheduleProgressSave()
        onPageChanged?()
    }

    @objc private func scaleChanged() {
        if !isZoomedIn {
            stabilizeViewportIfNeeded()
        }
        scheduleProgressSave()
    }

    private func updatePageLabel() {
        pageLabel.text = currentPageLabel()
    }

    private var isZoomedIn: Bool {
        let fit = pdfView.scaleFactorForSizeToFit
        guard fit > 0 else { return false }
        return pdfView.scaleFactor > fit * 1.02
    }

    private func applyFitScale(from progress: StudyProgress?) {
        pdfView.autoScales = true
        let fitScale = max(pdfView.scaleFactorForSizeToFit, 0.01)
        pdfView.autoScales = false

        if let saved = progress?.scaleFactor, saved > fitScale * 1.02 {
            pdfView.minScaleFactor = fitScale
            pdfView.maxScaleFactor = max(saved * 2, fitScale * 4)
            pdfView.scaleFactor = saved
        } else {
            pdfView.minScaleFactor = fitScale
            pdfView.maxScaleFactor = fitScale * 4
            pdfView.scaleFactor = fitScale
        }
    }

    private func scrollToProgress(_ progress: StudyProgress?, in document: PDFDocument) {
        guard let progress = progress else { return }
        let pageIndex = min(max(0, progress.pageIndex), max(document.pageCount - 1, 0))
        guard let page = document.page(at: pageIndex) else { return }
        let y = progress.pageOffsetY ?? 0
        let x = progress.pageOffsetX ?? 0
        pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: x, y: y)))
        if let anchorX = progress.anchorX, let anchorY = progress.anchorY, isZoomedIn {
            alignViewport(toPagePoint: CGPoint(x: anchorX, y: anchorY), in: page)
        }
        clearSpuriousContentInsets()
    }

    private func alignViewport(toPagePoint point: CGPoint, in page: PDFPage) {
        let pointInView = pdfView.convert(point, from: page)
        let target = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        let delta = CGPoint(x: target.x - pointInView.x, y: target.y - pointInView.y)
        guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return }
        for scrollView in pdfView.allEmbeddedScrollViews {
            var offset = scrollView.contentOffset
            offset.x -= delta.x
            offset.y -= delta.y
            scrollView.contentOffset = offset
        }
    }

    private func refitScaleIfNeeded() {
        let fitScale = max(pdfView.scaleFactorForSizeToFit, 0.01)
        guard abs(pdfView.scaleFactor - fitScale) > 0.01 else { return }
        pdfView.minScaleFactor = fitScale
        pdfView.maxScaleFactor = fitScale * 4
        pdfView.scaleFactor = fitScale
    }

    private func clearSpuriousContentInsets() {
        for scrollView in pdfView.allEmbeddedScrollViews {
            if #available(iOS 11.0, *) {
                scrollView.contentInsetAdjustmentBehavior = .never
            }
            guard scrollView.contentInset != .zero || scrollView.scrollIndicatorInsets != .zero else { continue }
            var offset = scrollView.contentOffset
            offset.x += scrollView.contentInset.left
            offset.y += scrollView.contentInset.top
            scrollView.contentInset = .zero
            scrollView.scrollIndicatorInsets = .zero
            scrollView.contentOffset = offset
        }
    }

    private func scheduleProgressSave() {
        guard currentDocumentID != nil else { return }
        progressWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushProgressSave()
        }
        progressWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func flushProgressSave() {
        guard let documentID = currentDocumentID,
              let progress = captureReadingProgress() else { return }
        StudyProgressStore.shared.update(documentID: documentID, progress: progress)
    }
}

private extension PDFView {
    var allEmbeddedScrollViews: [UIScrollView] {
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
}
