import UIKit
import PDFKit

final class PDFReaderViewController: UIViewController {
    private let topBar = UIView()
    private let topBarSeparator = UIView()
    /// Opaque fill for the status-bar band so PDF/overlay pixels cannot show through.
    private let statusBarCover = UIView()
    private let sidebarButton = UIButton(type: .system)
    private let highlightPenButton = UIButton(type: .system)
    private let rotateButton = UIButton(type: .system)
    private let appearanceButton = UIButton(type: .system)
    private let contentsButton = UIButton(type: .system)
    private var rotateButtonWidthConstraint: NSLayoutConstraint!
    private var fileTitleCenterXBar: NSLayoutConstraint!
    private var fileTitleCenterXSlot: NSLayoutConstraint!
    private let titleSlotGuide = UILayoutGuide()
    /// Fit scale captured at rotation start — landscape must not reuse portrait absolute zoom.
    private var rotationBaselineFitScale: CGFloat = 0
    /// Width-fit multiple at rotation start (1 = 贴边). Reapplied on the final bounds.
    private var pendingRotationRelative: CGFloat?
    private let pdfView = StudyPDFView()
    private var isHighlightPenOn = false
    /// White + difference blend → true invert (255 − x). Linear, so anti-aliased
    /// edges do not collapse into dark rings the way difference(#DEDEDE) did.
    private let invertOverlay = PassthroughOverlayView()
    /// After invert: screen with `#212121` so paper matches chrome and gray ink
    /// lifts toward white. (`plusLighter` is not a CA blend and covered the page.)
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
    /// Side panel scans every page; never do that on the box-gesture release path.
    private var contentsPanelNeedsReload = false
    private var contentsReloadWork: DispatchWorkItem?
    private var lastLayoutSize: CGSize = .zero
    private var isRestoringViewport = false
    private var isShellRotating = false
    private var shellRotationProgress: StudyProgress?
    private var readerSurfaceActive = true
    private var pendingViewportProgress: StudyProgress?

    var onPageChanged: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onFileTitleTapped: ((UIView) -> Void)?
    var onToggleReaderLandscape: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DSTheme.c.background

        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.backgroundColor = DSTheme.c.background
        topBar.isOpaque = true
        view.addSubview(topBar)

        statusBarCover.translatesAutoresizingMaskIntoConstraints = false
        statusBarCover.backgroundColor = DSTheme.c.background
        statusBarCover.isOpaque = true
        statusBarCover.isUserInteractionEnabled = false
        view.addSubview(statusBarCover)

        topBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        topBarSeparator.backgroundColor = DSTheme.c.border.withAlphaComponent(0.55)
        view.addSubview(topBarSeparator)

        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarButton.addTarget(self, action: #selector(sidebarTapped), for: .touchUpInside)
        sidebarButton.accessibilityLabel = "打开侧栏"
        topBar.addSubview(sidebarButton)
        updateSidebarToggle(collapsed: true)
        sidebarButtonWidthConstraint = sidebarButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget)

        highlightPenButton.translatesAutoresizingMaskIntoConstraints = false
        highlightPenButton.setImage(ActionIconFactory.image(.highlighter, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        highlightPenButton.accessibilityLabel = "框选标注"
        highlightPenButton.accessibilityHint = "点按开/关。拖出红色虚线方框后可写标题代称"
        highlightPenButton.addTarget(self, action: #selector(highlightPenTapped), for: .touchUpInside)
        topBar.addSubview(highlightPenButton)

        rotateButton.translatesAutoresizingMaskIntoConstraints = false
        rotateButton.setImage(ActionIconFactory.image(.rotate, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        rotateButton.addTarget(self, action: #selector(rotateTapped), for: .touchUpInside)
        topBar.addSubview(rotateButton)
        let phoneRotate = ConnectsPhoneReaderLandscape.isPhone
        rotateButton.isHidden = !phoneRotate
        rotateButtonWidthConstraint = rotateButton.widthAnchor.constraint(
            equalToConstant: phoneRotate ? ActionIconFactory.hitTarget : 0
        )
        updateRotateButtonAppearance()

        contentsButton.translatesAutoresizingMaskIntoConstraints = false
        contentsButton.setImage(ActionIconFactory.image(.toc, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        contentsButton.tintColor = DSTheme.c.textSecondary
        contentsButton.accessibilityLabel = "目录与标注"
        contentsButton.addTarget(self, action: #selector(contentsTapped), for: .touchUpInside)
        topBar.addSubview(contentsButton)

        appearanceButton.translatesAutoresizingMaskIntoConstraints = false
        appearanceButton.addTarget(self, action: #selector(appearanceTapped), for: .touchUpInside)
        topBar.addSubview(appearanceButton)
        updateAppearanceButton()

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = DSTheme.reader.background
        pdfView.clipsToBounds = true
        pdfView.boxSelect.onBoxFinished = { [weak self] _, _ in
            // Keep the box; open the note sheet only when the user taps it.
            // Leave annotation mode immediately to avoid accidental extra boxes.
            self?.markAnnotationsDirty(persistSoon: false)
            self?.scheduleContentsPanelReload()
            self?.turnOffHighlightPen(persistIfDirty: true)
        }
        pdfView.boxSelect.onBoxAdjusted = { [weak self] _, _ in
            self?.markAnnotationsDirty(persistSoon: true)
            self?.scheduleContentsPanelReload()
        }
        // Legacy ink remains visible via overlay; new marks are dashed boxes.
        pdfView.highlighter.onOverlaysReordered = { [weak self] in
            self?.liftReaderChromeAboveInk()
        }
        pdfView.noteTap.onTapHighlight = { [weak self] annotation, page in
            self?.presentNoteEditor(for: annotation, on: page)
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
        topBar.bringSubviewToFront(rotateButton)
        topBar.bringSubviewToFront(appearanceButton)
        topBar.bringSubviewToFront(contentsButton)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            statusBarCover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBarCover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBarCover.topAnchor.constraint(equalTo: view.topAnchor),
            statusBarCover.bottomAnchor.constraint(equalTo: topBar.topAnchor),

            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            sidebarButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            sidebarButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            sidebarButtonWidthConstraint,
            sidebarButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            fileTitleButton.topAnchor.constraint(equalTo: topBar.topAnchor),
            fileTitleButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            fileTitleButton.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarButton.trailingAnchor, constant: 4),
            fileTitleButton.trailingAnchor.constraint(lessThanOrEqualTo: rotateButton.leadingAnchor, constant: -4),

            contentsButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            contentsButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            contentsButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            contentsButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            appearanceButton.trailingAnchor.constraint(equalTo: contentsButton.leadingAnchor, constant: -2),
            appearanceButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            appearanceButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            appearanceButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            highlightPenButton.trailingAnchor.constraint(equalTo: appearanceButton.leadingAnchor, constant: -2),
            highlightPenButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            highlightPenButton.widthAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),
            highlightPenButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

            rotateButton.trailingAnchor.constraint(equalTo: highlightPenButton.leadingAnchor, constant: -2),
            rotateButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            rotateButtonWidthConstraint,
            rotateButton.heightAnchor.constraint(equalToConstant: ActionIconFactory.hitTarget),

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

        topBar.addLayoutGuide(titleSlotGuide)
        NSLayoutConstraint.activate([
            titleSlotGuide.leadingAnchor.constraint(equalTo: sidebarButton.trailingAnchor, constant: 4),
            titleSlotGuide.trailingAnchor.constraint(equalTo: rotateButton.leadingAnchor, constant: -4),
            titleSlotGuide.topAnchor.constraint(equalTo: topBar.topAnchor),
            titleSlotGuide.bottomAnchor.constraint(equalTo: topBar.bottomAnchor)
        ])
        fileTitleCenterXBar = fileTitleButton.centerXAnchor.constraint(equalTo: topBar.centerXAnchor)
        fileTitleCenterXSlot = fileTitleButton.centerXAnchor.constraint(equalTo: titleSlotGuide.centerXAnchor)
        syncFileTitlePlacement()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(phoneReaderLandscapeDidChange),
            name: .connectsPhoneReaderLandscapeDidChange,
            object: nil
        )
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
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .readerThemeDidChange, object: nil)
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
            if !isRestoringViewport, !isUserInteractingWithPDF, pdfView.document != nil {
                if pendingRotationRelative != nil {
                    applyPendingRotationScale()
                } else {
                    refreshMinScaleForCurrentBounds(snapToFitIfNotZoomed: true)
                }
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
            pdfView.boxSelect.setEnabled(false)
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
        sidebarButton.setImage(ActionIconFactory.image(kind, pointSize: ActionIconFactory.chromeGlyph), for: .normal)
        sidebarButton.tintColor = DSTheme.c.textSecondary
        sidebarButton.accessibilityLabel = collapsed ? "打开侧栏" : "关闭侧栏"
    }

    func setSidebarButtonHidden(_ hidden: Bool, animated: Bool = false) {
        let apply = {
            self.sidebarButton.alpha = hidden ? 0 : 1
            self.sidebarButton.isUserInteractionEnabled = !hidden
            self.sidebarButtonWidthConstraint.constant = 40
            self.sidebarButton.isHidden = false
        }
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
    }

    func sidebarButtonAnchorFrame(in target: UIView) -> CGRect {
        guard let bar = sidebarButton.superview else { return .zero }
        bar.layoutIfNeeded()
        // Pre-layout / cold start: zero-height bar makes y = -hitTarget/2 → floats above the screen.
        guard bar.bounds.height > 1, bar.window != nil else { return .zero }
        return sidebarButton.convert(sidebarButton.bounds, to: target)
    }

    @objc private func sidebarTapped() {
        onToggleSidebar?()
    }

    @objc private func contentsTapped() {
        if isContentsPanelVisible {
            setContentsPanelVisible(false, animated: true)
        } else {
            refreshContentsPanelNow()
            setContentsPanelVisible(true, animated: true)
        }
    }

    @objc private func themeChanged() {
        let chrome = DSTheme.c
        view.backgroundColor = chrome.background
        topBar.backgroundColor = chrome.background
        topBar.isOpaque = true
        statusBarCover.backgroundColor = chrome.background
        statusBarCover.isOpaque = true
        topBarSeparator.backgroundColor = chrome.border.withAlphaComponent(0.55)
        fileTitleButton.setTitleColor(chrome.textPrimary, for: .normal)
        sidebarButton.tintColor = chrome.textSecondary
        contentsButton.tintColor = chrome.textSecondary
        updateRotateButtonAppearance()
        updateAppearanceButton()
        updateHighlightPenAppearance()
        contentsPanelHost.backgroundColor = chrome.background
        contentsPanelHost.layer.borderColor = chrome.border.cgColor
        applyPDFColorInvert()
        bringHighlightChromeToFront()
    }

    @objc private func appearanceTapped() {
        ReaderThemeManager.shared.toggle()
    }

    @objc private func rotateTapped() {
        onToggleReaderLandscape?()
    }

    @objc private func phoneReaderLandscapeDidChange() {
        updateRotateButtonAppearance()
        syncFileTitlePlacement()
    }

    func syncRotateButtonAppearance() {
        updateRotateButtonAppearance()
        syncFileTitlePlacement()
    }

    private func syncFileTitlePlacement() {
        let phone = ConnectsPhoneReaderLandscape.isPhone
        let landscape = phone && ConnectsPhoneReaderLandscape.isActive
        fileTitleCenterXBar.isActive = !phone || landscape
        fileTitleCenterXSlot.isActive = phone && !landscape
    }

    private func updateRotateButtonAppearance() {
        guard ConnectsPhoneReaderLandscape.isPhone else {
            rotateButton.isHidden = true
            rotateButtonWidthConstraint?.constant = 0
            return
        }
        let on = ConnectsPhoneReaderLandscape.isActive
        let c = DSTheme.reader
        rotateButton.tintColor = on ? c.accent : c.textSecondary
        rotateButton.backgroundColor = on ? c.accent.withAlphaComponent(0.16) : .clear
        rotateButton.layer.cornerRadius = 20
        rotateButton.clipsToBounds = true
        rotateButton.accessibilityLabel = on ? "退出横屏" : "横屏阅读"
    }

    private func updateAppearanceButton() {
        let dark = ReaderThemeManager.shared.mode == .dark
        let kind: ActionIconFactory.Kind = dark ? .appearanceMoon : .appearanceSun
        appearanceButton.setImage(
            ActionIconFactory.image(kind, pointSize: ActionIconFactory.chromeGlyph),
            for: .normal
        )
        appearanceButton.tintColor = DSTheme.c.textSecondary
        appearanceButton.accessibilityLabel = dark ? "切换到白天模式" : "切换到黑夜模式"
    }

    @objc private func highlightPenTapped() {
        ConnectsNoteSheet.dismissIfNeeded()
        if isHighlightPenOn {
            turnOffHighlightPen(persistIfDirty: true)
        } else {
            isHighlightPenOn = true
            updateHighlightPenAppearance()
            pdfView.highlighter.setEnabled(false)
            pdfView.boxSelect.setEnabled(true)
            pdfView.boxSelect.refreshScrollLock()
            DispatchQueue.main.async { [weak self] in
                self?.bringHighlightChromeToFront()
                self?.pdfView.boxSelect.refreshScrollLock()
            }
        }
    }

    /// Leave box-select mode (used after create+note, and when toggling the tool off).
    private func turnOffHighlightPen(persistIfDirty: Bool) {
        guard isHighlightPenOn else { return }
        isHighlightPenOn = false
        updateHighlightPenAppearance()
        pdfView.boxSelect.setEnabled(false)
        pdfView.highlighter.setEnabled(false)
        if persistIfDirty, annotationsDirty {
            // Short settle so the unlock paint finishes first; serialize itself is
            // off the main thread (see persistPDFAnnotationsNow).
            schedulePersistPDFAnnotations(delay: 0.35)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .connectsStudyStageChromeShouldReassert, object: nil)
        }
    }

    /// Cheap chrome lift used when arming box select.
    private func bringHighlightChromeToFront() {
        pdfView.boxSelect.ensureOverlayInstalled()
        pdfView.highlighter.ensureOverlayZOrder()
        liftReaderChromeAboveInk()
    }

    /// Top bar / separator / drawer must sit above ink so strokes never paint through chrome.
    private func liftReaderChromeAboveInk() {
        if isContentsPanelVisible {
            view.bringSubviewToFront(contentsDim)
        }
        view.bringSubviewToFront(contentsPanelHost)
        view.bringSubviewToFront(statusBarCover)
        view.bringSubviewToFront(topBar)
        view.bringSubviewToFront(topBarSeparator)
        view.bringSubviewToFront(spinner)
    }

    private func updateHighlightPenAppearance() {
        let c = DSTheme.reader
        highlightPenButton.tintColor = isHighlightPenOn ? c.accent : c.textSecondary
        highlightPenButton.backgroundColor = isHighlightPenOn ? c.accent.withAlphaComponent(0.16) : .clear
        highlightPenButton.layer.cornerRadius = 20
        highlightPenButton.clipsToBounds = true
    }

    private func presentNoteEditor(for annotation: PDFAnnotation, on page: PDFPage) {
        if ConnectsNoteSheet.isVisible { return }
        // Stay in box-select mode so the user can keep adjusting frames without re-arming.
        let existing = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isBox = annotation.userName == StudyAskSelectionStore.boxAnnotationUserName
            || (annotation.type ?? "").lowercased().contains("square")
        ConnectsNoteSheet.present(
            from: self,
            title: "",
            message: nil,
            initialText: existing,
            confirmTitle: "保存",
            deleteTitle: "删除",
            onSave: { [weak self] note in
                annotation.contents = note
                if isBox {
                    annotation.userName = StudyAskSelectionStore.boxAnnotationUserName
                } else {
                    annotation.userName = StudyAskSelectionStore.noteAnnotationUserName
                }
                // Force PDFKit to keep the annotation; caption sits outside via overlay.
                if let page = annotation.page {
                    page.removeAnnotation(annotation)
                    page.addAnnotation(annotation)
                }
                self?.pdfView.boxSelect.refreshCaptions()
                self?.markAnnotationsDirty(persistSoon: false)
                self?.scheduleContentsPanelReload()
                self?.pdfView.boxSelect.refreshScrollLock()
            },
            onDelete: { [weak self] in
                page.removeAnnotation(annotation)
                self?.pdfView.highlighter.removeCommittedStroke(annotation)
                self?.pdfView.boxSelect.refreshCaptions()
                self?.markAnnotationsDirty(persistSoon: false)
                self?.scheduleContentsPanelReload()
                self?.pdfView.boxSelect.refreshScrollLock()
            },
            onCancel: { [weak self] in
                self?.pdfView.boxSelect.refreshScrollLock()
            }
        )
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
            || pdfView.boxSelect.isActivelySelecting
            || ConnectsNoteSheet.isVisible
            || scrolling {
            schedulePersistPDFAnnotations(delay: 2.0)
            return
        }
        isPersistingAnnotations = true
        annotationsDirty = false

        // `dataRepresentation()` on a large PDF used to run on the main thread here,
        // which made "turn off 框选标注" freeze the reader for seconds after any
        // new boxes. Keep colour swap + serialize on a utility queue — the flush
        // path already does the same, and the disk write is documented as
        // background-safe.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let data = ConnectsInk.withFileColors(in: doc) { doc.dataRepresentation() }
            var errorMessage: String?
            if let data {
                do {
                    try StudyDocumentStore.shared.writePDFData(data, for: docID, keepingCached: doc)
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else {
                errorMessage = StudyDocumentError.writeFailed.localizedDescription
            }
            DispatchQueue.main.async {
                self.isPersistingAnnotations = false
                if data == nil || errorMessage != nil {
                    self.annotationsDirty = true
                }
                if let errorMessage {
                    ConnectsToast.show("保存失败：\(errorMessage)", in: self.view, duration: 2.0)
                }
                if self.needsAnotherPersist || self.annotationsDirty {
                    self.needsAnotherPersist = false
                    self.schedulePersistPDFAnnotations(delay: 2.0)
                }
            }
        }
    }

    /// Flush pending annotation writes. Default is deferred so conversation switches / panel
    /// ops stay snappy — `dataRepresentation()` on a large PDF is expensive.
    func flushAnnotationPersistIfNeeded(synchronous: Bool = false) {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        guard annotationsDirty, let docID = currentDocumentID, let doc = pdfView.document else { return }
        annotationsDirty = false

        let writeBlock = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let data = ConnectsInk.withFileColors(in: doc) { doc.dataRepresentation() }
                guard let data else {
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

    /// Dark theme: invert, then screen-lift paper to app gray while keeping type bright.
    private func applyPDFColorInvert() {
        let dark = ReaderThemeManager.shared.mode == .dark
        pdfView.highlighter.darkInvertActive = dark
        pdfView.boxSelect.darkInvertActive = dark
        if let document = pdfView.document {
            ConnectsInk.normalizeForDisplay(in: document, darkInvertActive: dark)
        }
        if dark {
            // Backdrop must be white: difference(white, page) == true invert.
            pdfView.backgroundColor = .white
            if #available(iOS 12.0, *) {
                pdfView.pageShadowsEnabled = false
            }
            invertOverlay.isHidden = false
            invertOverlay.backgroundColor = .white
            invertOverlay.layer.compositingFilter = "differenceBlendMode"

            paperLiftOverlay.isHidden = false
            paperLiftOverlay.backgroundColor = DSTheme.dark.background
            // screen is a real CA blend (plusLighter is ignored → opaque #212121, blank pages).
            // screen(x, #212121): paper 0→#212121, white stays white, gray ink lifts toward white.
            paperLiftOverlay.layer.compositingFilter = "screenBlendMode"
            ensureInvertOverlayOnTopIfNeeded()
        } else {
            pdfView.backgroundColor = DSTheme.reader.background
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
        guard ReaderThemeManager.shared.mode == .dark, !invertOverlay.isHidden else {
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
        contentsPanelHost.backgroundColor = DSTheme.reader.background
        contentsPanelHost.layer.shadowColor = UIColor.black.cgColor
        contentsPanelHost.layer.shadowOpacity = 0.12
        contentsPanelHost.layer.shadowRadius = 8
        contentsPanelHost.layer.shadowOffset = CGSize(width: -2, height: 0)
        contentsPanelHost.layer.borderWidth = 1.0 / UIScreen.main.scale
        contentsPanelHost.layer.borderColor = DSTheme.reader.border.cgColor
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
        contentsVC.onSelectAnnotation = { [weak self] annotation, pageIndex in
            guard let self = self,
                  let document = self.pdfView.document,
                  let page = document.page(at: pageIndex) else { return }
            let point = CGPoint(x: annotation.bounds.midX, y: annotation.bounds.maxY)
            self.pdfView.go(to: PDFDestination(page: page, at: point))
            self.setContentsPanelVisible(false, animated: true)
            self.updatePageLabel()
            self.scheduleProgressSave()
        }
        contentsVC.onDeleteAnnotation = { [weak self] annotation, pageIndex in
            guard let self = self,
                  let document = self.pdfView.document,
                  let page = document.page(at: pageIndex) else { return }
            page.removeAnnotation(annotation)
            self.pdfView.highlighter.removeCommittedStroke(annotation)
            self.pdfView.boxSelect.refreshCaptions()
            self.pdfView.boxSelect.refreshScrollLock()
            self.markAnnotationsDirty(persistSoon: true)
            self.scheduleContentsPanelReload()
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

    /// Reload the side panel now (open button / forced). Scans every page — never call
    /// this from the box-gesture release path.
    private func refreshContentsPanelNow() {
        contentsReloadWork?.cancel()
        contentsReloadWork = nil
        contentsVC.document = pdfView.document
        contentsVC.documentID = currentDocumentID
        contentsVC.reloadData()
        contentsPanelNeedsReload = false
    }

    /// Cheap: if the panel is closed, just remember to rebuild when it opens. If it is
    /// open, debounce so a rapid train of box edits does not re-walk the whole PDF.
    private func scheduleContentsPanelReload() {
        guard isContentsPanelVisible else {
            contentsPanelNeedsReload = true
            return
        }
        contentsReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshContentsPanelNow()
        }
        contentsReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private func setContentsPanelVisible(_ visible: Bool, animated: Bool) {
        isContentsPanelVisible = visible
        if visible {
            if contentsPanelNeedsReload {
                refreshContentsPanelNow()
            }
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
                // On disk the ink carries a visible alpha; on screen the overlay draws
                // it, so damp PDFKit's own paint back down or it renders twice.
                ConnectsInk.normalizeForDisplay(
                    in: document,
                    darkInvertActive: ReaderThemeManager.shared.mode == .dark
                )
                ConnectsBoxAnnotation.migrate(in: document)
                // Document swap reinstalls PDFKit recognizers — kill selection again.
                self.pdfView.suppressNativeTextInteraction()
                self.applyPDFColorInvert()
                self.pdfView.highlighter.ensureHostOverlaysInstalled()
                self.pdfView.highlighter.reloadCommittedInk()
                self.pdfView.boxSelect.ensureOverlayInstalled()
                self.pdfView.boxSelect.refreshCaptions()
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
        rotationBaselineFitScale = measureFitScale()
        let rel = pdfView.scaleFactor / max(rotationBaselineFitScale, 0.01)
        pendingRotationRelative = rel <= 1.05 ? 1 : rel
        isShellRotating = true
        isRestoringViewport = true
    }

    func updateDuringShellRotation() {
        guard isShellRotating, pdfView.document != nil else { return }
        lastLayoutSize = pdfView.bounds.size
    }

    /// Single settle pass after rotation — avoids repeated go(to:) during the animation.
    func finishShellRotation(using progress: StudyProgress?) {
        let snapshot = progress ?? shellRotationProgress
        defer {
            isShellRotating = false
            isRestoringViewport = false
            shellRotationProgress = nil
            rotationBaselineFitScale = 0
            lastLayoutSize = .zero
        }
        guard pdfView.document != nil else { return }
        view.layoutIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyPendingRotationScale()
        restorePageAfterRotation(snapshot)
        snapPageToHorizontalEdgesIfAtMinZoom()
        CATransaction.commit()
        updatePageLabel()
    }

    private func applyPendingRotationScale() {
        let relative = pendingRotationRelative ?? 1
        let fitScale = measureFitScale()
        pdfView.autoScales = false
        pdfView.minScaleFactor = fitScale
        pdfView.maxScaleFactor = max(fitScale * 8, 4)
        pdfView.scaleFactor = relative <= 1.05 ? fitScale : fitScale * relative
        pdfView.layoutDocumentView()
        if !isShellRotating {
            pendingRotationRelative = nil
        }
        snapPageToHorizontalEdgesIfAtMinZoom()
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
        fileTitleButton.setTitle(file == "无文档" ? file : "\(file) ▾", for: .normal)
    }

    private var isZoomedIn: Bool {
        let floor = max(pdfView.minScaleFactor, 0.01)
        return pdfView.scaleFactor > floor * 1.02
    }

    /// Width-fit: page left/right flush with the viewer. `scaleFactorForSizeToFit` uses
    /// min(width, height) so landscape height-fit leaks into portrait as side gaps.
    private func measureFitScale() -> CGFloat {
        guard pdfView.bounds.width > 1,
              let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else {
            return 0.01
        }
        let box = page.bounds(for: pdfView.displayBox)
        guard box.width > 1 else { return 0.01 }
        return pdfView.bounds.width / box.width
    }

    private func applyFitScale(from progress: StudyProgress?, relativeToFit oldFit: CGFloat = 0) {
        let fitScale = measureFitScale()
        pdfView.autoScales = false

        let saved = progress?.scaleFactor
        let relative: CGFloat
        if oldFit > 0.01, let saved, saved > oldFit * 1.05 {
            relative = saved / oldFit
        } else {
            relative = 1
        }

        pdfView.minScaleFactor = fitScale
        pdfView.maxScaleFactor = max(fitScale * 8, 4)
        if relative > 1.05 {
            pdfView.scaleFactor = fitScale * relative
        } else {
            pdfView.scaleFactor = fitScale
        }
        pdfView.layoutDocumentView()
        snapPageToHorizontalEdgesIfAtMinZoom()
    }

    /// Bounds change after rotate: always lower min to the new page-fit so pinch can return.
    private func refreshMinScaleForCurrentBounds(snapToFitIfNotZoomed: Bool) {
        let fitScale = measureFitScale()
        pdfView.autoScales = false
        pdfView.minScaleFactor = fitScale
        pdfView.maxScaleFactor = max(pdfView.maxScaleFactor, fitScale * 8)
        if snapToFitIfNotZoomed, pdfView.scaleFactor <= fitScale * 1.05 {
            pdfView.scaleFactor = fitScale
        } else if pdfView.scaleFactor < fitScale {
            pdfView.scaleFactor = fitScale
        }
        pdfView.layoutDocumentView()
        snapPageToHorizontalEdgesIfAtMinZoom()
    }

    /// At min zoom the page must be flush left/right (no leftover landscape letterbox).
    private func snapPageToHorizontalEdgesIfAtMinZoom() {
        guard !isZoomedIn else { return }
        for scrollView in pdfView.allEmbeddedScrollViews {
            if abs(scrollView.contentOffset.x) > 0.5 {
                var offset = scrollView.contentOffset
                offset.x = 0
                scrollView.contentOffset = offset
            }
        }
        clearSpuriousContentInsets()
    }

    /// Fitted rotation: keep the page, not the old top-left in the previous aspect.
    private func restorePageAfterRotation(_ progress: StudyProgress?) {
        guard let progress, let document = pdfView.document else { return }
        let pageIndex = min(max(0, progress.pageIndex), max(document.pageCount - 1, 0))
        guard let page = document.page(at: pageIndex) else { return }
        let box = page.bounds(for: pdfView.displayBox)
        let y = progress.pageOffsetY ?? box.maxY
        pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: box.minX, y: y)))
        let wasUserZoomed: Bool = {
            guard let saved = progress.scaleFactor, rotationBaselineFitScale > 0.01 else { return false }
            return saved > rotationBaselineFitScale * 1.05
        }()
        if wasUserZoomed, let anchorX = progress.anchorX, let anchorY = progress.anchorY {
            alignViewport(toPagePoint: CGPoint(x: anchorX, y: anchorY), in: page)
        }
        clearSpuriousContentInsets()
    }

    private func scrollToProgress(_ progress: StudyProgress?, in document: PDFDocument) {
        guard let progress = progress else { return }
        let pageIndex = min(max(0, progress.pageIndex), max(document.pageCount - 1, 0))
        guard let page = document.page(at: pageIndex) else { return }
        let box = page.bounds(for: pdfView.displayBox)
        let y = progress.pageOffsetY ?? box.maxY
        let x = progress.pageOffsetX ?? box.minX
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
        refreshMinScaleForCurrentBounds(snapToFitIfNotZoomed: true)
    }

    private func clearSpuriousContentInsets() {
        guard !isUserInteractingWithPDF else { return }
        for scrollView in pdfView.allEmbeddedScrollViews {
            if #available(iOS 11.0, *) {
                scrollView.contentInsetAdjustmentBehavior = .never
            }
            guard scrollView.contentInset != .zero
                    || scrollView.verticalScrollIndicatorInsets != .zero
                    || scrollView.horizontalScrollIndicatorInsets != .zero else { continue }
            var offset = scrollView.contentOffset
            offset.x += scrollView.contentInset.left
            offset.y += scrollView.contentInset.top
            scrollView.contentInset = .zero
            scrollView.verticalScrollIndicatorInsets = .zero
            scrollView.horizontalScrollIndicatorInsets = .zero
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
