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
        let size = pdfView.bounds.size
        guard size.width > 1, size.height > 1, size != lastLayoutSize else { return }
        lastLayoutSize = size
        guard !isRestoringViewport else { return }
        resetScrollInsets()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flushProgressSave()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

    func load(documentID: String, restore progress: StudyProgress?) {
        currentDocumentID = documentID
        loadGeneration &+= 1
        let gen = loadGeneration
        spinner.startAnimating()
        pageLabel.text = "加载中…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let document = StudyDocumentStore.shared.cachedPDFDocument(for: documentID)
            DispatchQueue.main.async {
                guard let self = self, gen == self.loadGeneration, self.currentDocumentID == documentID else { return }
                self.spinner.stopAnimating()
                guard let document = document else {
                    self.pageLabel.text = "无法打开 PDF"
                    self.pdfView.document = nil
                    return
                }
                self.pdfView.document = document
                self.invalidateViewportLayout()
                self.restoreProgress(progress, in: document)
                self.updatePageLabel()
                self.resetScrollInsets()
                self.finishViewportLayout(using: progress)
            }
        }
    }

    func prepareForShellLayoutChange() {
        invalidateViewportLayout()
    }

    private func invalidateViewportLayout() {
        lastLayoutSize = .zero
    }

    private func finishViewportLayout(using progress: StudyProgress?) {
        _ = progress
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.view.layoutIfNeeded()
            self.resetScrollInsets()
            self.lastLayoutSize = self.pdfView.bounds.size
        }
    }

    func captureReadingProgress() -> StudyProgress? {
        guard currentDocumentID != nil,
              let doc = pdfView.document,
              let page = pdfView.currentPage else { return nil }
        let index = doc.index(for: page)
        let topLeft = pdfView.convert(CGPoint(x: 0, y: 0), to: page)
        return StudyProgress(
            pageIndex: max(0, index),
            pageOffsetY: topLeft.y,
            pageOffsetX: nil,
            anchorX: nil,
            anchorY: nil,
            scaleFactor: pdfView.scaleFactor,
            updatedAt: Date()
        )
    }

    func restoreReadingProgress(_ progress: StudyProgress?) {
        guard pdfView.document != nil else { return }
        isRestoringViewport = true
        invalidateViewportLayout()
        if let document = pdfView.document {
            restoreProgress(progress, in: document)
        }
        updatePageLabel()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.view.layoutIfNeeded()
            self.resetScrollInsets()
            self.isRestoringViewport = false
            self.lastLayoutSize = self.pdfView.bounds.size
        }
    }

    func saveReadingProgressNow() {
        progressWorkItem?.cancel()
        flushProgressSave()
    }

    func clearDocument() {
        loadGeneration &+= 1
        currentDocumentID = nil
        pdfView.document = nil
        pageLabel.text = nil
        invalidateViewportLayout()
        flushProgressSave()
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
        scheduleProgressSave()
    }

    private func updatePageLabel() {
        pageLabel.text = currentPageLabel()
    }

    private func restoreProgress(_ progress: StudyProgress?, in document: PDFDocument) {
        let hasSavedScale = (progress?.scaleFactor ?? 0) > 0
        if hasSavedScale {
            pdfView.autoScales = false
            if let scale = progress?.scaleFactor {
                pdfView.scaleFactor = scale
            }
        } else {
            pdfView.autoScales = true
            pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
            pdfView.autoScales = false
        }
        guard let progress = progress else { return }
        let pageIndex = min(max(0, progress.pageIndex), max(document.pageCount - 1, 0))
        guard let page = document.page(at: pageIndex) else { return }
        let y = progress.pageOffsetY ?? 0
        pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: y)))
    }

    private func resetScrollInsets() {
        guard let scrollView = pdfView.embeddedScrollView else { return }
        guard scrollView.contentInset != .zero || scrollView.scrollIndicatorInsets != .zero else { return }
        scrollView.contentInset = .zero
        scrollView.scrollIndicatorInsets = .zero
    }

    private func scheduleProgressSave() {
        guard let documentID = currentDocumentID else { return }
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
    var embeddedScrollView: UIScrollView? {
        if let scrollView = subviews.compactMap({ $0 as? UIScrollView }).first {
            return scrollView
        }
        for subview in subviews {
            if let scrollView = subview.subviews.compactMap({ $0 as? UIScrollView }).first {
                return scrollView
            }
        }
        return nil
    }
}
