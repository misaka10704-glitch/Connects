import UIKit
import PDFKit

final class PDFReaderViewController: UIViewController {
    private let topBar = UIView()
    private let topBarSeparator = UIView()
    private let sidebarButton = UIButton(type: .system)
    private let highlightPenButton = UIButton(type: .system)
    private let contentsButton = UIButton(type: .system)
    private let pdfView = StudyPDFView()
    private var isHighlightPenOn = false
    /// White + difference blend → invert PDF page colors in dark mode.
    private let invertOverlay = PassthroughOverlayView()
    /// After invert, lift pure black paper to app dark-gray (softer than #000).
    private let paperLiftOverlay = PassthroughOverlayView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let fileTitleButton = UIButton(type: .system)
    private let contentsPanelHost = UIView()
    private let contentsDim = UIControl()
    private let contentsVC = PDFContentsViewController()
    private var progressWorkItem: DispatchWorkItem?
    private var persistWorkItem: DispatchWorkItem?
    private var isPersistingAnnotations = false
    private var needsAnotherPersist = false
    private var annotationsDirty = false
    private var currentDocumentID: String?
    private var loadGeneration: UInt = 0
    private var sidebarButtonWidthConstraint: NSLayoutConstraint!
    private var contentsPanelWidth: NSLayoutConstraint!
    private var contentsPanelTrailing: NSLayoutConstraint!
    private var isContentsPanelVisible = false
    private let contentsPanelWidthConstant: CGFloat = 220
    private var lastLayoutSize: CGSize = .zero
    private var isRestoringViewport = false
    private var isShellRotating = false
    private var shellRotationProgress: StudyProgress?
    private var readerSurfaceActive = true
    private var pendingViewportProgress: StudyProgress?

    var onPageChanged: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onFileTitleTapped: ((UIView) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DSTheme.c.background

        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.backgroundColor = DSTheme.c.background
        topBar.isOpaque = true
        view.addSubview(topBar)

        topBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        topBarSeparator.backgroundColor = DSTheme.c.border.withAlphaComponent(0.55)
        view.addSubview(topBarSeparator)

        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarButton.addTarget(self, action: #selector(sidebarTapped), for: .touchUpInside)
        sidebarButton.accessibilityLabel = "打开侧栏"
        topBar.addSubview(sidebarButton)
        updateSidebarToggle(collapsed: true)
        sidebarButtonWidthConstraint = sidebarButton.widthAnchor.constraint(equalToConstant: 40)

        highlightPenButton.translatesAutoresizingMaskIntoConstraints = false
        highlightPenButton.setImage(ActionIconFactory.image(.highlighter, pointSize: 17), for: .normal)
        highlightPenButton.accessibilityLabel = "高亮笔"
        highlightPenButton.accessibilityHint = "点按开/关；长按选线宽。划线时停住会自动拉直，按住可调角度"
        highlightPenButton.addTarget(self, action: #selector(highlightPenTapped), for: .touchUpInside)
        let penLongPress = UILongPressGestureRecognizer(target: self, action: #selector(highlightPenLongPressed(_:)))
        penLongPress.minimumPressDuration = 0.35
        penLongPress.cancelsTouchesInView = false
        highlightPenButton.addGestureRecognizer(penLongPress)
        topBar.addSubview(highlightPenButton)

        contentsButton.translatesAutoresizingMaskIntoConstraints = false
        contentsButton.setImage(ActionIconFactory.image(.toc, pointSize: 18), for: .normal)
        contentsButton.tintColor = DSTheme.c.textSecondary
        contentsButton.accessibilityLabel = "目录与书签"
        contentsButton.addTarget(self, action: #selector(contentsTapped), for: .touchUpInside)
        topBar.addSubview(contentsButton)

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = DSTheme.c.background
        pdfView.highlighter.strokeWidth = PDFHighlightStrokeStyle.Width.current
        pdfView.highlighter.onStrokeFinished = { [weak self] annotation, page in
            self?.markAnnotationsDirty(persistSoon: false)
            self?.presentNoteEditor(for: annotation, on: page, afterStroke: true)
        }
        pdfView.highlighter.onOverlaysReordered = { [weak self] in
            self?.liftReaderChromeAboveInk()
        }
        pdfView.noteTap.onTapHighlight = { [weak self] annotation, page in
            self?.presentNoteEditor(for: annotation, on: page, afterStroke: false)
        }
        if #available(iOS 11.0, *) {
            pdfView.usePageViewController(false)
        }
        // Keep PDFView free of covering subviews — overlays as children freeze hit-testing/scroll.
        view.addSubview(pdfView)

        invertOverlay.translatesAutoresizingMaskIntoConstraints = false
        invertOverlay.isUserInteractionEnabled = false
        invertOverlay.isHidden = true
        invertOverlay.backgroundColor = .white
        view.addSubview(invertOverlay)

        paperLiftOverlay.translatesAutoresizingMaskIntoConstraints = false
        paperLiftOverlay.isUserInteractionEnabled = false
        paperLiftOverlay.isHidden = true
        paperLiftOverlay.backgroundColor = DSTheme.dark.background
        view.addSubview(paperLiftOverlay)

        fileTitleButton.translatesAutoresizingMaskIntoConstraints = false
        fileTitleButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        fileTitleButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        fileTitleButton.titleLabel?.textAlignment = .center
        fileTitleButton.contentHorizontalAlignment = .center
        fileTitleButton.setTitleColor(DSTheme.c.textPrimary, for: .normal)
        fileTitleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileTitleButton.addTarget(self, action: #selector(fileTitleTapped), for: .touchUpInside)
        fileTitleButton.accessibilityLabel = "切换文件"
        topBar.addSubview(fileTitleButton)
        topBar.bringSubviewToFront(highlightPenButton)
        topBar.bringSubviewToFront(contentsButton)

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

            fileTitleButton.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            fileTitleButton.topAnchor.constraint(equalTo: topBar.topAnchor),
            fileTitleButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            fileTitleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            fileTitleButton.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarButton.trailingAnchor, constant: 4),
            fileTitleButton.trailingAnchor.constraint(lessThanOrEqualTo: highlightPenButton.leadingAnchor, constant: -4),

            contentsButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            contentsButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            contentsButton.widthAnchor.constraint(equalToConstant: 40),
            contentsButton.heightAnchor.constraint(equalToConstant: 40),

            highlightPenButton.trailingAnchor.constraint(equalTo: contentsButton.leadingAnchor, constant: -2),
            highlightPenButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            highlightPenButton.widthAnchor.constraint(equalToConstant: 40),
            highlightPenButton.heightAnchor.constraint(equalToConstant: 40),

            topBarSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarSeparator.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topBarSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            pdfView.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            invertOverlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
            invertOverlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
            invertOverlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
            invertOverlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),

            paperLiftOverlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
            paperLiftOverlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
            paperLiftOverlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
            paperLiftOverlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        installContentsPanel()
        syncContentsOverlayZOrder()
        applyPDFColorInvert()
        updateHighlightPenAppearance()
        // Overlays must never sit above chrome / contents panel for hit testing.
        view.insertSubview(invertOverlay, aboveSubview: pdfView)
        view.insertSubview(paperLiftOverlay, aboveSubview: invertOverlay)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged),
            name: Notification.Name.PDFViewPageChanged,
            object: pdfView
        )
        if #available(iOS 11.0, *) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged),
                name: .PDFViewVisiblePagesChanged,
                object: pdfView
            )
        }
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

        if isShellRotating {
            updateDuringShellRotation()
            return
        }

        if let pending = pendingViewportProgress {
            pendingViewportProgress = nil
            beginViewportRestore(using: pending)
            return
        }

        let size = pdfView.bounds.size
        if size.width > 1, size.height > 1, size != lastLayoutSize {
            lastLayoutSize = size
            if !isRestoringViewport, !isUserInteractingWithPDF, pdfView.document != nil, !isZoomedIn {
                refitScaleIfNeeded()
            }
        }

        if !isUserInteractingWithPDF {
            stabilizeViewportIfNeeded()
        }
        ensureInvertOverlayOnTopIfNeeded()
    }

    private var isUserInteractingWithPDF: Bool {
        pdfView.allEmbeddedScrollViews.contains {
            $0.isTracking || $0.isDragging || $0.isDecelerating
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flushProgressSave()
        if isHighlightPenOn {
            isHighlightPenOn = false
            ConnectsNoteSheet.dismissIfNeeded()
            pdfView.highlighter.setEnabled(false)
            updateHighlightPenAppearance()
        } else {
            pdfView.highlighter.forceUnlockIfNeeded()
            ConnectsNoteSheet.dismissIfNeeded()
        }
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

    @objc private func contentsTapped() {
        if isContentsPanelVisible {
            setContentsPanelVisible(false, animated: true)
        } else {
            refreshContentsPanel()
            setContentsPanelVisible(true, animated: true)
        }
    }

    @objc private func themeChanged() {
        view.backgroundColor = DSTheme.c.background
        topBar.backgroundColor = DSTheme.c.background
        topBar.isOpaque = true
        topBarSeparator.backgroundColor = DSTheme.c.border.withAlphaComponent(0.55)
        fileTitleButton.setTitleColor(DSTheme.c.textPrimary, for: .normal)
        sidebarButton.tintColor = DSTheme.c.textSecondary
        contentsButton.tintColor = DSTheme.c.textSecondary
        updateHighlightPenAppearance()
        contentsPanelHost.backgroundColor = DSTheme.c.background
        contentsPanelHost.layer.borderColor = DSTheme.c.border.cgColor
        applyPDFColorInvert()
        bringHighlightChromeToFront()
    }

    @objc private func highlightPenTapped() {
        // Instant chrome feedback first — never block on PDF serialize / hierarchy reshuffles.
        ConnectsNoteSheet.dismissIfNeeded()
        if isHighlightPenOn {
            turnOffHighlightPen(persistIfDirty: true)
        } else {
            isHighlightPenOn = true
            updateHighlightPenAppearance()
            pdfView.highlighter.strokeWidth = PDFHighlightStrokeStyle.Width.current
            pdfView.highlighter.setEnabled(true)
            // Defer chrome lift — sync ensureOverlayZOrder on the tap frame felt laggy.
            DispatchQueue.main.async { [weak self] in
                self?.bringHighlightChromeToFront()
            }
        }
    }

    /// Leave freehand highlight mode (used after stroke+note, and when toggling the pen off).
    private func turnOffHighlightPen(persistIfDirty: Bool) {
        guard isHighlightPenOn else { return }
        isHighlightPenOn = false
        updateHighlightPenAppearance()
        pdfView.highlighter.setEnabled(false)
        if persistIfDirty, annotationsDirty {
            schedulePersistPDFAnnotations(delay: 1.5)
        }
        // Same recovery as note dismiss — pen-off alone used to leave ▲▼ dead for a beat.
        // Defer a beat so the tap frame stays light.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .connectsStudyStageChromeShouldReassert, object: nil)
        }
    }

    /// Cheap chrome lift used by pen arming. Avoids ensureInvertOverlayOnTopIfNeeded reshuffles.
    private func bringHighlightChromeToFront() {
        // Only lift draw overlay z-order when armed — skip full invert reshuffle.
        pdfView.highlighter.ensureOverlayZOrder()
    }

    /// Top bar / separator / drawer must sit above ink so strokes never paint through chrome.
    private func liftReaderChromeAboveInk() {
        if isContentsPanelVisible {
            view.bringSubviewToFront(contentsDim)
        }
        view.bringSubviewToFront(contentsPanelHost)
        view.bringSubviewToFront(topBar)
        view.bringSubviewToFront(topBarSeparator)
        view.bringSubviewToFront(spinner)
    }

    @objc private func highlightPenLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        ConnectsNoteSheet.dismissIfNeeded()
        let current = PDFHighlightStrokeStyle.Width.current
        let items = PDFHighlightStrokeStyle.Width.allCases.map { width in
            ConnectsMenuItem(
                title: "线宽 · \(width.title)",
                isSelected: width == current
            ) { [weak self] in
                PDFHighlightStrokeStyle.Width.current = width
                self?.pdfView.highlighter.strokeWidth = width
                if self?.isHighlightPenOn != true {
                    self?.isHighlightPenOn = true
                    self?.updateHighlightPenAppearance()
                    self?.pdfView.highlighter.setEnabled(true)
                    self?.bringHighlightChromeToFront()
                }
            }
        }
        ConnectsMenu.present(
            from: self,
            title: "高亮线宽",
            items: items,
            sourceView: highlightPenButton,
            preferAbove: false,
            menuWidth: 200
        )
    }

    private func updateHighlightPenAppearance() {
        let c = DSTheme.c
        highlightPenButton.tintColor = isHighlightPenOn ? c.accent : c.textSecondary
        highlightPenButton.backgroundColor = isHighlightPenOn ? c.accent.withAlphaComponent(0.16) : .clear
        highlightPenButton.layer.cornerRadius = 20
        highlightPenButton.clipsToBounds = true
    }

    private func presentNoteEditor(for annotation: PDFAnnotation, on page: PDFPage, afterStroke: Bool) {
        if ConnectsNoteSheet.isVisible { return }
        // Leave draw mode before the sheet — keeps ink overlay from fighting focus.
        if afterStroke, isHighlightPenOn {
            turnOffHighlightPen(persistIfDirty: false)
        }
        let existing = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // After a new stroke, leave highlight mode once the note sheet closes
        // (save / delete / cancel) so scrolling isn't stuck in pen mode.
        let leaveHighlightAfterNote: () -> Void = { [weak self] in
            guard afterStroke else { return }
            // Pen already off when the sheet opened after a new stroke.
            DispatchQueue.main.async {
                self?.turnOffHighlightPen(persistIfDirty: true)
            }
        }
        ConnectsNoteSheet.present(
            from: self,
            title: afterStroke ? "添加注释" : "编辑注释",
            message: afterStroke ? "可为这条划线写一句说明，也可直接取消。" : "编辑说明，或删除这段划线。",
            initialText: existing,
            confirmTitle: "保存",
            deleteTitle: "删除划线",
            onSave: { [weak self] note in
                annotation.contents = note
                annotation.userName = StudyAskSelectionStore.noteAnnotationUserName
                // Dirty only — serialize on leave / pen-off, never mid-scroll.
                self?.markAnnotationsDirty(persistSoon: false)
                leaveHighlightAfterNote()
            },
            onDelete: { [weak self] in
                page.removeAnnotation(annotation)
                self?.pdfView.highlighter.removeCommittedStroke(annotation)
                self?.markAnnotationsDirty(persistSoon: false)
                leaveHighlightAfterNote()
            },
            onCancel: { [weak self] in
                if afterStroke {
                    self?.markAnnotationsDirty(persistSoon: false)
                }
                leaveHighlightAfterNote()
            }
        )
        // Do not lift PDF chrome here — that layout pass raced the note field's
        // becomeFirstResponder and often swallowed the soft keyboard.
    }

    /// In-memory dirty flag. Optionally schedule a deferred write (never inline with button taps).
    private func markAnnotationsDirty(persistSoon: Bool = false) {
        annotationsDirty = true
        persistWorkItem?.cancel()
        persistWorkItem = nil
        if persistSoon {
            schedulePersistPDFAnnotations(delay: 1.5)
        }
    }

    /// Debounced write — used as a safety net; leave/pause still flushes immediately.
    private func schedulePersistPDFAnnotations(delay: TimeInterval = 6.0) {
        persistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistPDFAnnotationsNow()
        }
        persistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func persistPDFAnnotationsNow() {
        guard annotationsDirty else { return }
        guard let docID = currentDocumentID, let doc = pdfView.document else { return }
        if isPersistingAnnotations {
            needsAnotherPersist = true
            return
        }
        // Never serialize while drawing, editing a note, or actively scrolling.
        let scrolling: Bool = {
            guard let sv = pdfView.allEmbeddedScrollViews.first(where: {
                $0.isDragging || $0.isDecelerating
            }) else { return false }
            return sv.isDragging || sv.isDecelerating
        }()
        if isHighlightPenOn
            || pdfView.highlighter.isActivelyHighlighting
            || ConnectsNoteSheet.isVisible
            || scrolling {
            schedulePersistPDFAnnotations(delay: 2.0)
            return
        }
        isPersistingAnnotations = true
        annotationsDirty = false
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isHighlightPenOn
                || self.pdfView.highlighter.isActivelyHighlighting
                || ConnectsNoteSheet.isVisible {
                self.isPersistingAnnotations = false
                self.annotationsDirty = true
                self.schedulePersistPDFAnnotations(delay: 2.0)
                return
            }
            let data = doc.dataRepresentation()
            DispatchQueue.global(qos: .utility).async {
                var errorMessage: String?
                if let data = data {
                    do {
                        try StudyDocumentStore.shared.writePDFData(data, for: docID, keepingCached: doc)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } else {
                    errorMessage = StudyDocumentError.writeFailed.localizedDescription
                    DispatchQueue.main.async { self.annotationsDirty = true }
                }
                DispatchQueue.main.async {
                    self.isPersistingAnnotations = false
                    if let errorMessage = errorMessage {
                        ConnectsToast.show("保存失败：\(errorMessage)", in: self.view, duration: 2.0)
                    }
                    if self.needsAnotherPersist || self.annotationsDirty {
                        self.needsAnotherPersist = false
                        self.schedulePersistPDFAnnotations(delay: 2.0)
                    }
                }
            }
        }
    }

    /// Flush pending annotation writes. Default is deferred so conversation switches / panel
    /// ops stay snappy — `dataRepresentation()` on a large PDF blocks the main thread hard.
    func flushAnnotationPersistIfNeeded(synchronous: Bool = false) {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        guard annotationsDirty, let docID = currentDocumentID, let doc = pdfView.document else { return }
        annotationsDirty = false

        let writeBlock = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Serialize off the main thread — large PDFs block UI for hundreds of ms.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                guard let data = doc.dataRepresentation() else {
                    DispatchQueue.main.async { self.annotationsDirty = true }
                    return
                }
                do {
                    try StudyDocumentStore.shared.writePDFData(data, for: docID, keepingCached: doc)
                } catch {
                    DispatchQueue.main.async {
                        self.annotationsDirty = true
                    }
                }
            }
        }

        if synchronous {
            writeBlock.perform()
        } else {
            // Let layout / conversation switch / sidebar taps finish before serialize.
            persistWorkItem = writeBlock
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: writeBlock)
        }
    }

    /// Selection text + notes on the visible page (for AI context).
    func selectedTextWithNotes() -> (text: String, notes: String)? {
        var text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var noteLines: [String] = []
        if let page = visibleContentPage() {
            for ann in page.annotations {
                let t = (ann.type ?? "").lowercased()
                let isMarkup = t.contains("highlight") || t.contains("ink")
                    || ann.userName == StudyAskSelectionStore.noteAnnotationUserName
                guard isMarkup else { continue }
                if let c = ann.contents?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                    noteLines.append("• \(c)")
                }
            }
            if text.isEmpty {
                // Prefer the first markup note as focus when no live selection.
                text = page.annotations
                    .compactMap { $0.contents?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty }) ?? ""
            }
        }
        if text.isEmpty && noteLines.isEmpty { return nil }
        return (text, noteLines.joined(separator: "\n"))
    }

    /// Dark theme: invert pages, then lift pure black paper to app dark-gray background.
    private func applyPDFColorInvert() {
        let dark = ThemeManager.shared.mode == .dark
        pdfView.highlighter.darkInvertActive = dark
        if dark {
            // Difference needs a light backdrop; paperLift then raises #000 → DSTheme dark gray.
            pdfView.backgroundColor = .white
            if #available(iOS 12.0, *) {
                pdfView.pageShadowsEnabled = false
            }
            invertOverlay.isHidden = false
            invertOverlay.backgroundColor = .white
            invertOverlay.layer.compositingFilter = "differenceBlendMode"

            paperLiftOverlay.isHidden = false
            paperLiftOverlay.backgroundColor = DSTheme.dark.background
            // lighten(black, darkGray)=darkGray; lighten(white, darkGray)=white → soft paper, keep text.
            paperLiftOverlay.layer.compositingFilter = "lightenBlendMode"
            ensureInvertOverlayOnTopIfNeeded()
        } else {
            pdfView.backgroundColor = DSTheme.c.background
            if #available(iOS 12.0, *) {
                pdfView.pageShadowsEnabled = true
            }
            invertOverlay.isHidden = true
            invertOverlay.layer.compositingFilter = nil
            paperLiftOverlay.isHidden = true
            paperLiftOverlay.layer.compositingFilter = nil
        }
    }

    private func ensureInvertOverlayOnTopIfNeeded() {
        guard ThemeManager.shared.mode == .dark, !invertOverlay.isHidden else {
            pdfView.highlighter.ensureOverlayZOrder()
            return
        }
        // Keep overlays above the PDF surface but below chrome / contents drawer.
        view.insertSubview(invertOverlay, aboveSubview: pdfView)
        view.insertSubview(paperLiftOverlay, aboveSubview: invertOverlay)
        pdfView.highlighter.ensureOverlayZOrder()
        liftReaderChromeAboveInk()
    }

    private func syncContentsOverlayZOrder() {
        ensureInvertOverlayOnTopIfNeeded()
        liftReaderChromeAboveInk()
    }

    private func installContentsPanel() {
        contentsDim.translatesAutoresizingMaskIntoConstraints = false
        contentsDim.backgroundColor = UIColor.black.withAlphaComponent(0.08)
        contentsDim.alpha = 0
        contentsDim.isHidden = true
        contentsDim.addTarget(self, action: #selector(contentsDimTapped), for: .touchUpInside)
        view.addSubview(contentsDim)

        contentsPanelHost.translatesAutoresizingMaskIntoConstraints = false
        contentsPanelHost.backgroundColor = DSTheme.c.background
        contentsPanelHost.layer.shadowColor = UIColor.black.cgColor
        contentsPanelHost.layer.shadowOpacity = 0.12
        contentsPanelHost.layer.shadowRadius = 8
        contentsPanelHost.layer.shadowOffset = CGSize(width: -2, height: 0)
        contentsPanelHost.layer.borderWidth = 1.0 / UIScreen.main.scale
        contentsPanelHost.layer.borderColor = DSTheme.c.border.cgColor
        contentsPanelHost.isHidden = true
        view.addSubview(contentsPanelHost)

        addChild(contentsVC)
        contentsVC.view.translatesAutoresizingMaskIntoConstraints = false
        contentsPanelHost.addSubview(contentsVC.view)
        contentsVC.didMove(toParent: self)

        contentsVC.onSelectDestination = { [weak self] destination in
            guard let self = self else { return }
            self.pdfView.go(to: destination)
            self.setContentsPanelVisible(false, animated: true)
            self.updatePageLabel()
            self.scheduleProgressSave()
        }
        contentsVC.onSelectPageIndex = { [weak self] pageIndex in
            guard let self = self,
                  let document = self.pdfView.document,
                  let page = document.page(at: pageIndex) else { return }
            self.pdfView.go(to: page)
            self.setContentsPanelVisible(false, animated: true)
            self.updatePageLabel()
            self.scheduleProgressSave()
        }
        contentsVC.currentPageIndexProvider = { [weak self] in
            guard let self = self, let doc = self.pdfView.document, let page = self.pdfView.currentPage else {
                return 0
            }
            return doc.index(for: page)
        }
        contentsVC.currentPageLabelProvider = { [weak self] in
            self?.currentPageLabel() ?? ""
        }

        contentsPanelWidth = contentsPanelHost.widthAnchor.constraint(equalToConstant: contentsPanelWidthConstant)
        contentsPanelTrailing = contentsPanelHost.trailingAnchor.constraint(
            equalTo: view.trailingAnchor,
            constant: contentsPanelWidthConstant
        )

        NSLayoutConstraint.activate([
            contentsDim.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            contentsDim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentsDim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentsDim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentsPanelHost.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            contentsPanelHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentsPanelWidth,
            contentsPanelTrailing,

            contentsVC.view.topAnchor.constraint(equalTo: contentsPanelHost.topAnchor),
            contentsVC.view.leadingAnchor.constraint(equalTo: contentsPanelHost.leadingAnchor),
            contentsVC.view.trailingAnchor.constraint(equalTo: contentsPanelHost.trailingAnchor),
            contentsVC.view.bottomAnchor.constraint(equalTo: contentsPanelHost.bottomAnchor)
        ])
    }

    @objc private func contentsDimTapped() {
        setContentsPanelVisible(false, animated: true)
    }

    private func refreshContentsPanel() {
        contentsVC.document = pdfView.document
        contentsVC.documentID = currentDocumentID
        contentsVC.reloadData()
    }

    private func setContentsPanelVisible(_ visible: Bool, animated: Bool) {
        isContentsPanelVisible = visible
        if visible {
            contentsDim.isHidden = false
            syncContentsOverlayZOrder()
        }
        contentsPanelHost.isHidden = false
        contentsPanelTrailing.constant = visible ? 0 : contentsPanelWidthConstant
        let updates = {
            self.view.layoutIfNeeded()
            self.contentsDim.alpha = visible ? 1 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut], animations: updates) { _ in
                self.contentsPanelHost.isHidden = !visible
                if !visible {
                    self.contentsDim.isHidden = true
                }
            }
        } else {
            updates()
            contentsPanelHost.isHidden = !visible
            contentsDim.isHidden = !visible
        }
    }

    func load(documentID: String, completion: ((Bool) -> Void)? = nil) {
        // Same doc already in memory: keep it. Do not rebuild ink or re-serialize inline —
        // that made conversation switches feel stuck.
        if currentDocumentID == documentID, pdfView.document != nil {
            flushAnnotationPersistIfNeeded(synchronous: false)
            pdfView.suppressNativeTextInteraction()
            updatePageLabel()
            completion?(true)
            return
        }
        if currentDocumentID != documentID {
            pdfView.highlighter.cancelPendingInkWork()
            flushAnnotationPersistIfNeeded(synchronous: false)
            pdfView.document = nil
            annotationsDirty = false
        }
        currentDocumentID = documentID
        loadGeneration &+= 1
        let gen = loadGeneration
        spinner.startAnimating()
        fileTitleButton.setTitle("加载中…", for: .normal)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let document = StudyDocumentStore.shared.cachedPDFDocument(for: documentID)
            DispatchQueue.main.async {
                guard let self = self, gen == self.loadGeneration, self.currentDocumentID == documentID else {
                    completion?(false)
                    return
                }
                self.spinner.stopAnimating()
                guard let document = document else {
                    self.fileTitleButton.setTitle("无法打开 PDF", for: .normal)
                    self.pdfView.document = nil
                    self.currentDocumentID = nil
                    completion?(false)
                    return
                }
                self.annotationsDirty = false
                self.pdfView.document = document
                // Document swap reinstalls PDFKit recognizers — kill selection again.
                self.pdfView.suppressNativeTextInteraction()
                self.applyPDFColorInvert()
                self.pdfView.highlighter.ensureHostOverlaysInstalled()
                self.pdfView.highlighter.reloadCommittedInk()
                self.updatePageLabel()
                completion?(true)
            }
        }
    }

    func pauseReading() {
        pdfView.highlighter.cancelPendingInkWork()
        flushAnnotationPersistIfNeeded(synchronous: false)
        saveReadingProgressNow()
        pdfView.highlighter.forceUnlockIfNeeded()
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
        guard !isShellRotating else { return }
        invalidateViewportLayout()
    }

    /// Freeze heavy reflow while the study shell rotates; step scale during the transition.
    func beginShellRotation(keeping progress: StudyProgress?) {
        shellRotationProgress = progress
        isShellRotating = true
        isRestoringViewport = true
    }

    func updateDuringShellRotation() {
        guard isShellRotating, pdfView.document != nil else { return }
        let fitScale = max(pdfView.scaleFactorForSizeToFit, 0.01)
        let progress = shellRotationProgress
        let zoomed = progress?.scaleFactor.map { $0 > fitScale * 1.02 } ?? false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if zoomed, let progress = progress, let scale = progress.scaleFactor, let document = pdfView.document {
            pdfView.minScaleFactor = fitScale
            pdfView.maxScaleFactor = max(scale * 2, fitScale * 4)
            pdfView.scaleFactor = scale
            let pageIndex = min(max(progress.pageIndex, 0), max(document.pageCount - 1, 0))
            if let page = document.page(at: pageIndex),
               let anchorX = progress.anchorX, let anchorY = progress.anchorY {
                alignViewport(toPagePoint: CGPoint(x: anchorX, y: anchorY), in: page)
            }
        } else {
            pdfView.minScaleFactor = fitScale
            pdfView.maxScaleFactor = fitScale * 4
            pdfView.scaleFactor = fitScale
            if let progress = progress, let document = pdfView.document,
               pdfView.bounds.size != lastLayoutSize {
                scrollToProgress(progress, in: document)
            }
        }
        clearSpuriousContentInsets()
        CATransaction.commit()
        lastLayoutSize = pdfView.bounds.size
    }

    /// Single settle pass after rotation — avoids repeated go(to:) during the animation.
    func finishShellRotation(using progress: StudyProgress?) {
        let snapshot = progress ?? shellRotationProgress
        defer {
            isShellRotating = false
            isRestoringViewport = false
            shellRotationProgress = nil
            lastLayoutSize = pdfView.bounds.size
        }
        guard let snapshot = snapshot, let document = pdfView.document else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyFitScale(from: snapshot)
        scrollToProgress(snapshot, in: document)
        clearSpuriousContentInsets()
        CATransaction.commit()
        updatePageLabel()
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
        pdfView.highlighter.cancelPendingInkWork()
        flushAnnotationPersistIfNeeded(synchronous: false)
        loadGeneration &+= 1
        saveReadingProgressNow()
        currentDocumentID = nil
        annotationsDirty = false
        pdfView.document = nil
        fileTitleButton.setTitle(nil, for: .normal)
        pendingViewportProgress = nil
        setContentsPanelVisible(false, animated: false)
        contentsVC.document = nil
        contentsVC.documentID = nil
        contentsVC.reloadData()
        invalidateViewportLayout()
    }

    func currentPageText() -> String? {
        guard let page = visibleContentPage() else { return nil }
        return page.string?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func currentPageLabel() -> String {
        guard let doc = pdfView.document else { return "无文档" }
        let index = resolvedPageIndex() ?? 0
        let page = max(0, index) + 1
        let total = max(doc.pageCount, 1)
        return "第 \(page) / \(total) 页"
    }

    private func currentFileDisplayName() -> String {
        guard let id = currentDocumentID,
              let doc = StudyDocumentStore.shared.document(id: id) else { return "无文档" }
        if let path = doc.displayPath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return doc.title.hasSuffix(".pdf") ? doc.title : "\(doc.title).pdf"
    }

    @objc private func fileTitleTapped() {
        onFileTitleTapped?(fileTitleButton)
    }

    func captureCurrentPageImageJPEG() -> String? {
        // Match Markdown: snapshot the live viewport (zoom + scroll), not a guessed
        // full-page mediaBox — continuous `currentPage` was sending the wrong sheet.
        guard pdfView.document != nil, pdfView.bounds.width > 1, pdfView.bounds.height > 1 else {
            return nil
        }
        let raw = pdfView.bounds
        let maxSide: CGFloat = 1400
        let down = min(1, maxSide / max(raw.width, raw.height))
        let size = CGSize(width: floor(raw.width * down), height: floor(raw.height * down))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.scaleBy(x: down, y: down)
            // false = no layout hitch mid-send; still paints the current scroll position.
            pdfView.drawHierarchy(in: raw, afterScreenUpdates: false)
        }
        return ImageAttachmentHelper.prepareJPEGBase64(from: image)
    }

    /// Continuous-mode `currentPage` often lags the viewport — pick the page covering most of the view.
    private func visibleContentPage() -> PDFPage? {
        guard pdfView.document != nil, pdfView.bounds.width > 1, pdfView.bounds.height > 1 else {
            return pdfView.currentPage
        }
        if #available(iOS 11.0, *), !pdfView.visiblePages.isEmpty {
            var best: PDFPage?
            var bestArea: CGFloat = 0
            for page in pdfView.visiblePages {
                let pageRect = pdfView.convert(page.bounds(for: .cropBox), from: page)
                let inter = pageRect.intersection(pdfView.bounds)
                guard !inter.isNull, !inter.isEmpty else { continue }
                let area = inter.width * inter.height
                if area > bestArea {
                    bestArea = area
                    best = page
                }
            }
            if let best = best { return best }
        }
        // Prefer the page under the upper-middle of the reader (typical reading focus).
        let focus = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.height * 0.28)
        if let page = pdfView.page(for: focus, nearest: true) {
            return page
        }
        let center = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        return pdfView.page(for: center, nearest: true) ?? pdfView.currentPage
    }

    private func resolvedPageIndex() -> Int? {
        guard let doc = pdfView.document else { return nil }
        if let page = visibleContentPage() {
            return doc.index(for: page)
        }
        if let docID = currentDocumentID,
           let progress = StudyProgressStore.shared.progress(for: docID) {
            return min(max(progress.pageIndex, 0), max(doc.pageCount - 1, 0))
        }
        return doc.pageCount > 0 ? 0 : nil
    }

    @objc private func pageChanged() {
        updatePageLabel()
        scheduleProgressSave()
        onPageChanged?()
    }

    @objc private func scaleChanged() {
        if !isZoomedIn, !isUserInteractingWithPDF {
            stabilizeViewportIfNeeded()
        }
        scheduleProgressSave()
    }

    private func updatePageLabel() {
        let file = currentFileDisplayName()
        let page = currentPageLabel()
        if file == "无文档" || page == "无文档" {
            fileTitleButton.setTitle(file, for: .normal)
        } else {
            fileTitleButton.setTitle("\(file) ▾ · \(page)", for: .normal)
        }
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
        guard !isUserInteractingWithPDF else { return }
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
