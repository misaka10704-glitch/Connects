import UIKit

/// Hosts chat + optional document reader (PDF / Markdown) for study sessions.
/// Landscape: reader full screen; AI chat overlays on the right.
/// Portrait: reader full screen; AI chat overlays on the bottom.
/// Stages: full reading ⇄ half/half ⇄ full AI (capsule in input bar; floating chip only when collapsed).
final class StudyShellViewController: UIViewController {
    let chatNav: UINavigationController
    let chatVC: ChatViewController

    private let pdfReaderVC = PDFReaderViewController()
    private let markdownReaderVC = MarkdownReaderViewController()
    private let textEditorVC = TextCodeEditorViewController()
    private var activeReaderKind: StudyDocumentKind = .pdf
    private let readerHost = UIView()
    private let chatHost = UIView()
    /// Vertical ▲/▼ at the old AI-panel handle position (not in the input bar).
    private let panelStageCapsule = StudyPanelStageCapsule()

    private var chatWidthConstraint: NSLayoutConstraint!
    private var portraitChatHeightConstraint: NSLayoutConstraint!
    private var chatLandscapeConstraints: [NSLayoutConstraint] = []
    private var chatPortraitConstraints: [NSLayoutConstraint] = []
    private var chatNavTopBelowSeamSpacer: NSLayoutConstraint!
    private var chatNavLeadingInHost: NSLayoutConstraint!
    private let landscapeStatusSpacer = UIView()
    private var landscapeStatusSpacerHeight: NSLayoutConstraint!
    private let portraitSeamSpacer = UIView()
    private var portraitSeamSpacerHeight: NSLayoutConstraint!
    private var panelCapsuleLandscapeLeadingX: NSLayoutConstraint!
    private var panelCapsuleLandscapeTrailingX: NSLayoutConstraint!
    private var panelCapsuleLandscapeCenterY: NSLayoutConstraint!
    private var panelCapsulePortraitCenterX: NSLayoutConstraint!
    private var panelCapsulePortraitSeamY: NSLayoutConstraint!
    private var panelCapsulePortraitBottomY: NSLayoutConstraint!
    private var panelCapsuleWidthConstraint: NSLayoutConstraint!
    private var panelCapsuleHeightConstraint: NSLayoutConstraint!

    private var landscapeResizePan: UIPanGestureRecognizer!
    private var portraitResizePan: UIPanGestureRecognizer!
    private var loadGeneration: UInt = 0
    private var boundDocumentID: String?
    private var boundConversationID: String?
    private var isReaderVisible = false
    private var chatPanelStage: StudyChatPanelStage = .collapsed
    private var isPortraitMode = false
    /// Half-panel ratio only (full stage always uses 1.0).
    private var landscapeOverlayRatio: CGFloat
    private var portraitOverlayRatio: CGFloat
    /// Same height as input-bar「AI 选项」chip (30pt); landscape applies −90° on the seam.
    private let panelCapsuleHorizontalSize = CGSize(
        width: StudyPanelStageCapsule.chipWidth,
        height: StudyPanelStageCapsule.chipHeight
    )
    private let panelCapsuleSeamSize = CGSize(
        width: StudyPanelStageCapsule.chipWidth,
        height: StudyPanelStageCapsule.chipHeight
    )
    private let collapsedHandleBottomInset: CGFloat = 12
    private let landscapeSeamHitWidth: CGFloat = 28
    /// Clockwise 90°: left▲ → top, right▼ → bottom (portrait chip stood on the vertical seam).
    private let landscapeCapsuleRotation = CGAffineTransform(rotationAngle: -.pi / 2)
    private let studyPanelSeamGap: CGFloat = 8
    private let compactChatBreakpoint: CGFloat = 520
    private let minChatWidth: CGFloat = 220
    private let defaultLandscapeOverlayRatio: CGFloat = 0.45
    private let defaultPortraitOverlayRatio: CGFloat = 0.5
    private let halfOverlayMin: CGFloat = 0.28
    private let halfOverlayMax: CGFloat = 0.72
    private let fullOverlayRatio: CGFloat = 1.0
    private let landscapeOverlayRatioKey = "connects_study_landscape_overlay_ratio"
    private let portraitOverlayRatioKey = "connects_study_portrait_overlay_ratio"
    /// Last posted chat width — skip expensive height rebuilds when only panel height changes.
    private var lastPostedChatWidth: CGFloat = -1

    private var panStartChatLength: CGFloat = 0
    private var landscapeResizeActive = false
    private var portraitResizeActive = false
    private var didSeedPortraitMode = false
    private var isHandlingRotation = false
    private var isAnimatingPanelStage = false

    private var isChatCollapsed: Bool { chatPanelStage == .collapsed }

    var onToggleSidebar: (() -> Void)?

    init(chatNav: UINavigationController, chatVC: ChatViewController) {
        self.chatNav = chatNav
        self.chatVC = chatVC
        landscapeOverlayRatio = StudyShellViewController.loadOverlayRatio(
            key: landscapeOverlayRatioKey,
            legacyKeys: ["connects_study_overlay_ratio", "connects_study_split_ratio"],
            defaultValue: defaultLandscapeOverlayRatio,
            portrait: false
        )
        portraitOverlayRatio = StudyShellViewController.loadOverlayRatio(
            key: portraitOverlayRatioKey,
            legacyKeys: [],
            defaultValue: defaultPortraitOverlayRatio,
            portrait: true
        )
        super.init(nibName: nil, bundle: nil)
    }

    private static func loadOverlayRatio(
        key: String,
        legacyKeys: [String],
        defaultValue: CGFloat,
        portrait: Bool
    ) -> CGFloat {
        if let saved = UserDefaults.standard.object(forKey: key) as? Double {
            return clampOverlayRatio(CGFloat(saved), portrait: portrait)
        }
        for legacyKey in legacyKeys {
            if let legacy = UserDefaults.standard.object(forKey: legacyKey) as? Double {
                let ratio = clampOverlayRatio(CGFloat(legacy), portrait: portrait)
                UserDefaults.standard.set(Double(ratio), forKey: key)
                return ratio
            }
        }
        return defaultValue
    }

    private static func clampOverlayRatio(_ ratio: CGFloat, portrait: Bool) -> CGFloat {
        // Half-panel only. Legacy saves near/at "full" fall back into the half band.
        let minRatio: CGFloat = 0.28
        let maxRatio: CGFloat = 0.72
        var value = ratio
        if value > 0.85 { value = portrait ? 0.5 : 0.45 }
        return min(max(value, minRatio), maxRatio)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = StudyShellRootView()
        root.stageCapsule = panelStageCapsule
        root.shouldPreferStageHits = { [weak self] in
            self?.isReaderVisible == true
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if view.bounds.width > 1, view.bounds.height > 1 {
            isPortraitMode = view.bounds.height > view.bounds.width
            didSeedPortraitMode = true
        }
        view.backgroundColor = DSTheme.c.background
        chatHost.clipsToBounds = false
        chatHost.backgroundColor = DSTheme.c.background
        panelStageCapsule.layer.zPosition = 100
        readerHost.clipsToBounds = false
        chatVC.studyContextProvider = self
        let toggleSidebar: () -> Void = { [weak self] in
            self?.onToggleSidebar?()
        }
        pdfReaderVC.onToggleSidebar = toggleSidebar
        markdownReaderVC.onToggleSidebar = toggleSidebar
        textEditorVC.onToggleSidebar = toggleSidebar
        let askSelection: (String) -> Void = { [weak self] text in
            self?.handleAskSelection(text)
        }
        // PDF has no Ask (highlighter-only). Code / Markdown keep Ask on selection.
        markdownReaderVC.onAskSelection = askSelection
        textEditorVC.onAskSelection = askSelection
        StudyAskMenu.installIfNeeded()

        addChild(pdfReaderVC)
        addChild(markdownReaderVC)
        addChild(textEditorVC)
        addChild(chatNav)
        pdfReaderVC.didMove(toParent: self)
        markdownReaderVC.didMove(toParent: self)
        textEditorVC.didMove(toParent: self)
        chatNav.didMove(toParent: self)

        [readerHost, panelStageCapsule].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        readerHost.addSubview(pdfReaderVC.view)
        readerHost.addSubview(markdownReaderVC.view)
        readerHost.addSubview(textEditorVC.view)
        markdownReaderVC.view.isHidden = true
        textEditorVC.view.isHidden = true
        landscapeStatusSpacer.translatesAutoresizingMaskIntoConstraints = false
        landscapeStatusSpacer.isUserInteractionEnabled = false
        landscapeStatusSpacer.backgroundColor = .clear
        chatHost.addSubview(landscapeStatusSpacer)
        portraitSeamSpacer.translatesAutoresizingMaskIntoConstraints = false
        portraitSeamSpacer.isUserInteractionEnabled = false
        portraitSeamSpacer.backgroundColor = .clear
        chatHost.addSubview(portraitSeamSpacer)
        chatHost.addSubview(chatNav.view)
        chatNav.view.translatesAutoresizingMaskIntoConstraints = false
        pdfReaderVC.view.translatesAutoresizingMaskIntoConstraints = false
        markdownReaderVC.view.translatesAutoresizingMaskIntoConstraints = false
        textEditorVC.view.translatesAutoresizingMaskIntoConstraints = false

        landscapeStatusSpacerHeight = landscapeStatusSpacer.heightAnchor.constraint(equalToConstant: 0)
        portraitSeamSpacerHeight = portraitSeamSpacer.heightAnchor.constraint(equalToConstant: 0)

        panelStageCapsule.onStepTowardAI = { [weak self] in
            self?.stepPanelTowardAI()
        }
        panelStageCapsule.onStepTowardReading = { [weak self] in
            self?.stepPanelTowardReading()
        }
        syncChatPanelChrome()

        chatWidthConstraint = chatHost.widthAnchor.constraint(equalToConstant: 320)
        portraitChatHeightConstraint = chatHost.heightAnchor.constraint(equalToConstant: 0)
        panelCapsuleLandscapeLeadingX = panelStageCapsule.centerXAnchor.constraint(
            equalTo: chatHost.leadingAnchor,
            constant: 0
        )
        panelCapsuleLandscapeTrailingX = panelStageCapsule.centerXAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.trailingAnchor,
            constant: 0
        )
        panelCapsuleLandscapeCenterY = panelStageCapsule.centerYAnchor.constraint(equalTo: chatHost.centerYAnchor)
        panelCapsulePortraitCenterX = panelStageCapsule.centerXAnchor.constraint(equalTo: chatHost.centerXAnchor)
        // Align with chat nav bar icons (sidebar / ⋯), not chatHost.top — that sat in the
        // status-bar band and looked vertically offset when AI is fully expanded.
        panelCapsulePortraitSeamY = panelStageCapsule.centerYAnchor.constraint(
            equalTo: chatNav.navigationBar.centerYAnchor
        )
        panelCapsulePortraitBottomY = panelStageCapsule.centerYAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: 0
        )
        panelCapsuleWidthConstraint = panelStageCapsule.widthAnchor.constraint(
            equalToConstant: panelCapsuleHorizontalSize.width
        )
        panelCapsuleHeightConstraint = panelStageCapsule.heightAnchor.constraint(
            equalToConstant: panelCapsuleHorizontalSize.height
        )

        NSLayoutConstraint.activate([
            readerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerHost.topAnchor.constraint(equalTo: view.topAnchor),
            readerHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            panelCapsuleWidthConstraint,
            panelCapsuleHeightConstraint,

            pdfReaderVC.view.leadingAnchor.constraint(equalTo: readerHost.leadingAnchor),
            pdfReaderVC.view.trailingAnchor.constraint(equalTo: readerHost.trailingAnchor),
            pdfReaderVC.view.topAnchor.constraint(equalTo: readerHost.topAnchor),
            pdfReaderVC.view.bottomAnchor.constraint(equalTo: readerHost.bottomAnchor),

            markdownReaderVC.view.leadingAnchor.constraint(equalTo: readerHost.leadingAnchor),
            markdownReaderVC.view.trailingAnchor.constraint(equalTo: readerHost.trailingAnchor),
            markdownReaderVC.view.topAnchor.constraint(equalTo: readerHost.topAnchor),
            markdownReaderVC.view.bottomAnchor.constraint(equalTo: readerHost.bottomAnchor),

            textEditorVC.view.leadingAnchor.constraint(equalTo: readerHost.leadingAnchor),
            textEditorVC.view.trailingAnchor.constraint(equalTo: readerHost.trailingAnchor),
            textEditorVC.view.topAnchor.constraint(equalTo: readerHost.topAnchor),
            textEditorVC.view.bottomAnchor.constraint(equalTo: readerHost.bottomAnchor),

            chatNav.view.trailingAnchor.constraint(equalTo: chatHost.trailingAnchor),
            chatNav.view.bottomAnchor.constraint(equalTo: chatHost.bottomAnchor)
        ])

        chatNavTopBelowSeamSpacer = chatNav.view.topAnchor.constraint(
            equalTo: portraitSeamSpacer.bottomAnchor
        )
        chatNavLeadingInHost = chatNav.view.leadingAnchor.constraint(equalTo: chatHost.leadingAnchor)
        chatNavTopBelowSeamSpacer.isActive = true
        chatNavLeadingInHost.isActive = true
        NSLayoutConstraint.activate([
            landscapeStatusSpacer.topAnchor.constraint(equalTo: chatHost.topAnchor),
            landscapeStatusSpacer.leadingAnchor.constraint(equalTo: chatHost.leadingAnchor),
            landscapeStatusSpacer.trailingAnchor.constraint(equalTo: chatHost.trailingAnchor),
            landscapeStatusSpacerHeight,
            portraitSeamSpacer.topAnchor.constraint(equalTo: landscapeStatusSpacer.bottomAnchor),
            portraitSeamSpacer.leadingAnchor.constraint(equalTo: chatHost.leadingAnchor),
            portraitSeamSpacer.trailingAnchor.constraint(equalTo: chatHost.trailingAnchor),
            portraitSeamSpacerHeight
        ])
        panelCapsuleLandscapeLeadingX.isActive = false
        panelCapsuleLandscapeTrailingX.isActive = false
        panelCapsuleLandscapeCenterY.isActive = false
        panelCapsulePortraitCenterX.isActive = false
        panelCapsulePortraitSeamY.isActive = false
        panelCapsulePortraitBottomY.isActive = false

        landscapeResizePan = UIPanGestureRecognizer(target: self, action: #selector(handleLandscapeResizePan(_:)))
        landscapeResizePan.cancelsTouchesInView = false
        landscapeResizePan.delegate = self
        chatHost.addGestureRecognizer(landscapeResizePan)

        portraitResizePan = UIPanGestureRecognizer(target: self, action: #selector(handlePortraitResizePan(_:)))
        portraitResizePan.cancelsTouchesInView = false
        portraitResizePan.delegate = self
        chatHost.addGestureRecognizer(portraitResizePan)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(conversationStoreDidUpdate),
            name: .conversationStoreDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(noteSheetDidDismiss),
            name: ConnectsNoteSheet.didDismissNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reassertStageCapsuleAfterExternalDismiss),
            name: .connectsStudyStageChromeShouldReassert,
            object: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)

        bindCurrentConversation()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        // Always track orientation — even before a document is open. Skipping this left
        // isPortraitMode stale, so landscape kept the top/bottom split and a vertical chip.
        let willBePortrait = Self.isPortraitSize(size)
        guard willBePortrait != isPortraitMode else {
            if isReaderVisible {
                coordinator.animate(alongsideTransition: { _ in
                    self.syncPanelStageCapsuleLayout()
                }, completion: nil)
            }
            return
        }

        let readerSnapshot = isReaderVisible ? captureActiveReaderProgress() : nil
        if isReaderVisible {
            stashDepartingOverlayRatio()
            beginActiveReaderRotation(keeping: readerSnapshot)
        }
        isHandlingRotation = true

        coordinator.animate(alongsideTransition: { _ in
            self.isPortraitMode = willBePortrait
            self.didSeedPortraitMode = true
            if self.isReaderVisible {
                self.applyLayoutMode(for: size)
                UIView.performWithoutAnimation {
                    self.syncPanelStageCapsuleLayout()
                    self.updateChatPanelShadowPath()
                    self.view.layoutIfNeeded()
                    self.updateActiveReaderDuringRotation()
                    self.bringChromeToFront()
                }
            }
        }, completion: { _ in
            self.isHandlingRotation = false
            self.isPortraitMode = Self.isPortraitSize(self.view.bounds.size)
            if self.isReaderVisible {
                UIView.performWithoutAnimation {
                    self.applyLayoutMode()
                    self.view.layoutIfNeeded()
                    self.syncPanelStageCapsuleLayout()
                    self.updateChatPanelShadowPath()
                }
                self.finishActiveReaderRotation(using: readerSnapshot)
                self.syncStudyOverlayChrome()
                self.postChatWidthNotification()
                self.bringChromeToFront()
            }
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 1, view.bounds.height > 1 else { return }

        let portrait = currentPortraitLayout()
        if !didSeedPortraitMode {
            didSeedPortraitMode = true
            isPortraitMode = portrait
            if isReaderVisible {
                applyLayoutMode()
            }
        } else if portrait != isPortraitMode, !isHandlingRotation {
            let readerSnapshot = isReaderVisible ? captureActiveReaderProgress() : nil
            if isReaderVisible { stashDepartingOverlayRatio() }
            isPortraitMode = portrait
            if isReaderVisible {
                beginActiveReaderRotation(keeping: readerSnapshot)
                applyLayoutMode()
                UIView.performWithoutAnimation {
                    self.syncPanelStageCapsuleLayout()
                    self.updateChatPanelShadowPath()
                    self.view.layoutIfNeeded()
                    self.updateActiveReaderDuringRotation()
                    self.bringChromeToFront()
                }
                finishActiveReaderRotation(using: readerSnapshot)
                syncStudyOverlayChrome()
                postChatWidthNotification()
            }
        }

        guard isReaderVisible, !isHandlingRotation, !isAnimatingPanelStage else { return }

        // Only touch overlay chrome when length/visibility actually change —
        // layoutSubviews fires often and used to re-reconcile the chat table every time.
        let overlayTouched = isPortraitMode
            ? updatePortraitOverlay()
            : updateLandscapeOverlay()
        if overlayTouched {
            updateChatPanelShadowPath()
            bringChromeToFront()
        } else {
            updateChatPanelShadowPath()
        }
        postChatWidthNotification()
    }

    /// Prefer scene orientation; fall back to bounds aspect.
    private func currentPortraitLayout() -> Bool {
        if #available(iOS 13.0, *) {
            if let orientation = view.window?.windowScene?.interfaceOrientation,
               orientation != .unknown {
                return orientation == .portrait || orientation == .portraitUpsideDown
            }
        }
        return Self.isPortraitSize(view.bounds.size)
    }

    private static func isPortraitSize(_ size: CGSize) -> Bool {
        size.height >= size.width
    }

    private func setChatOnlyLayout(_ chatOnly: Bool) {
        NSLayoutConstraint.deactivate(chatLandscapeConstraints)
        NSLayoutConstraint.deactivate(chatPortraitConstraints)
        if chatOnly {
            readerHost.isHidden = true
            panelStageCapsule.isHidden = true
            chatWidthConstraint.isActive = false
            portraitChatHeightConstraint.isActive = false
            chatVC.setStudyChrome(.none)
            pdfReaderVC.setSidebarButtonHidden(true)
            pdfReaderVC.setReaderSurfaceActive(false)
            pdfReaderVC.prepareForShellLayoutChange()
            markdownReaderVC.setSidebarButtonHidden(true)
            markdownReaderVC.setReaderSurfaceActive(false)
            markdownReaderVC.prepareForShellLayoutChange()
            textEditorVC.setSidebarButtonHidden(true)
            textEditorVC.setReaderSurfaceActive(false)
            textEditorVC.prepareForShellLayoutChange()
        } else {
            readerHost.isHidden = false
        }
    }

    private func captureActiveReaderProgress() -> StudyProgress? {
        switch activeReaderKind {
        case .pdf: return pdfReaderVC.captureReadingProgress()
        case .markdown: return markdownReaderVC.captureReadingProgress()
        case .text: return textEditorVC.captureReadingProgress()
        }
    }

    private func beginActiveReaderRotation(keeping progress: StudyProgress?) {
        switch activeReaderKind {
        case .pdf: pdfReaderVC.beginShellRotation(keeping: progress)
        case .markdown: markdownReaderVC.beginShellRotation(keeping: progress)
        case .text: textEditorVC.beginShellRotation(keeping: progress)
        }
    }

    private func updateActiveReaderDuringRotation() {
        switch activeReaderKind {
        case .pdf: pdfReaderVC.updateDuringShellRotation()
        case .markdown: markdownReaderVC.updateDuringShellRotation()
        case .text: textEditorVC.updateDuringShellRotation()
        }
    }

    private func finishActiveReaderRotation(using progress: StudyProgress?) {
        switch activeReaderKind {
        case .pdf: pdfReaderVC.finishShellRotation(using: progress)
        case .markdown: markdownReaderVC.finishShellRotation(using: progress)
        case .text: textEditorVC.finishShellRotation(using: progress)
        }
    }

    private func showReader(kind: StudyDocumentKind) {
        activeReaderKind = kind
        pdfReaderVC.view.isHidden = kind != .pdf
        markdownReaderVC.view.isHidden = kind != .markdown
        textEditorVC.view.isHidden = kind != .text
        switch kind {
        case .pdf:
            markdownReaderVC.setReaderSurfaceActive(false)
            markdownReaderVC.setSidebarButtonHidden(true)
            textEditorVC.setReaderSurfaceActive(false)
            textEditorVC.setSidebarButtonHidden(true)
        case .markdown:
            pdfReaderVC.setReaderSurfaceActive(false)
            pdfReaderVC.setSidebarButtonHidden(true)
            textEditorVC.setReaderSurfaceActive(false)
            textEditorVC.setSidebarButtonHidden(true)
        case .text:
            pdfReaderVC.setReaderSurfaceActive(false)
            pdfReaderVC.setSidebarButtonHidden(true)
            markdownReaderVC.setReaderSurfaceActive(false)
            markdownReaderVC.setSidebarButtonHidden(true)
        }
    }

    private func isActiveReaderLoaded(documentID: String) -> Bool {
        switch activeReaderKind {
        case .pdf: return pdfReaderVC.isLoaded(documentID: documentID)
        case .markdown: return markdownReaderVC.isLoaded(documentID: documentID)
        case .text: return textEditorVC.isLoaded(documentID: documentID)
        }
    }

    private func loadActiveReader(documentID: String, completion: @escaping (Bool) -> Void) {
        textEditorVC.bindConversationID(boundConversationID)
        switch activeReaderKind {
        case .pdf:
            markdownReaderVC.clearDocument()
            textEditorVC.clearDocument()
            pdfReaderVC.load(documentID: documentID, completion: completion)
        case .markdown:
            pdfReaderVC.clearDocument()
            textEditorVC.clearDocument()
            markdownReaderVC.load(documentID: documentID, completion: completion)
        case .text:
            pdfReaderVC.clearDocument()
            markdownReaderVC.clearDocument()
            textEditorVC.load(documentID: documentID, completion: completion)
        }
    }

    private func saveActiveReaderProgress() {
        switch activeReaderKind {
        case .pdf: pdfReaderVC.saveReadingProgressNow()
        case .markdown: markdownReaderVC.saveReadingProgressNow()
        case .text: textEditorVC.saveReadingProgressNow()
        }
    }

    private func pauseActiveReader() {
        pdfReaderVC.pauseReading()
        markdownReaderVC.pauseReading()
        textEditorVC.pauseReading()
        if let id = boundDocumentID {
            StudyDocumentStore.shared.releaseAccess(forID: id)
        }
    }


    private func stashDepartingOverlayRatio() {
        // Only persist half-panel size; full is always 1.0.
        guard chatPanelStage == .half, let captured = captureDepartingOverlayRatio() else { return }
        if isPortraitMode {
            portraitOverlayRatio = captured
            persistPortraitOverlayRatio()
        } else {
            landscapeOverlayRatio = captured
            persistLandscapeOverlayRatio()
        }
    }

    private func captureDepartingOverlayRatio() -> CGFloat? {
        guard isReaderVisible, chatPanelStage == .half, !chatHost.isHidden else { return nil }
        if isPortraitMode {
            let total = max(view.bounds.height, 1)
            guard portraitChatHeightConstraint.isActive, total > 1 else { return nil }
            return Self.clampOverlayRatio(portraitChatHeightConstraint.constant / total, portrait: true)
        }
        let total = max(view.bounds.width, 1)
        guard chatWidthConstraint.isActive, total > 1 else { return nil }
        return Self.clampOverlayRatio(chatWidthConstraint.constant / total, portrait: false)
    }

    private func overlayLength(for total: CGFloat, portrait: Bool? = nil) -> CGFloat {
        switch chatPanelStage {
        case .collapsed:
            return 0
        case .full:
            return total * fullOverlayRatio
        case .half:
            let usePortrait = portrait ?? isPortraitMode
            let ratio = usePortrait ? portraitOverlayRatio : landscapeOverlayRatio
            let clamped = Self.clampOverlayRatio(ratio, portrait: usePortrait)
            return min(max(total * clamped, minChatWidth), total * halfOverlayMax)
        }
    }

    private func layoutBoundsSize(for size: CGSize? = nil) -> CGSize {
        let raw = size ?? view.bounds.size
        return CGSize(width: max(raw.width, 1), height: max(raw.height, 1))
    }

    private func persistLandscapeOverlayRatio() {
        UserDefaults.standard.set(Double(landscapeOverlayRatio), forKey: landscapeOverlayRatioKey)
    }

    private func persistPortraitOverlayRatio() {
        UserDefaults.standard.set(Double(portraitOverlayRatio), forKey: portraitOverlayRatioKey)
    }

    private func syncPanelStageCapsuleLayout(layoutNow: Bool = true, reconcileChrome: Bool = false) {
        // Portrait half/full: ▲▼ floating over chat nav mid. Landscape: seam / top bar.
        panelCapsulePortraitSeamY.isActive = false

        guard isReaderVisible else {
            panelStageCapsule.isHidden = true
            panelStageCapsule.transform = .identity
            panelCapsulePortraitCenterX.isActive = false
            panelCapsulePortraitBottomY.isActive = false
            panelCapsuleLandscapeCenterY.isActive = false
            panelCapsuleLandscapeLeadingX.isActive = false
            panelCapsuleLandscapeTrailingX.isActive = false
            if reconcileChrome {
                syncStudyOverlayChrome()
            }
            return
        }

        chatVC.syncStudyPanelStageControl()

        let size = panelCapsuleHorizontalSize
        panelCapsuleWidthConstraint.constant = size.width
        panelCapsuleHeightConstraint.constant = size.height
        panelStageCapsule.setAxis(.horizontal)
        panelStageCapsule.setStage(chatPanelStage)
        panelStageCapsule.applyTheme(elevated: false)

        let place = {
            self.panelCapsulePortraitCenterX.isActive = false
            self.panelCapsulePortraitBottomY.isActive = false
            self.panelCapsulePortraitSeamY.isActive = false
            self.panelCapsuleLandscapeCenterY.isActive = false
            self.panelCapsuleLandscapeLeadingX.isActive = false
            self.panelCapsuleLandscapeTrailingX.isActive = false

            if self.isPortraitMode {
                self.panelStageCapsule.transform = .identity
                self.panelStageCapsule.isHidden = false
                self.panelStageCapsule.isUserInteractionEnabled = true
                self.panelStageCapsule.prefersFullBoundsHitTesting = true
                self.panelCapsulePortraitCenterX.isActive = true
                if self.isChatCollapsed {
                    // Full reading: chip centered on the bottom edge.
                    self.panelCapsulePortraitBottomY.isActive = true
                    self.panelCapsulePortraitBottomY.constant = -(size.height / 2 + self.collapsedHandleBottomInset)
                } else {
                    // Half / full AI: same horizontal line as nav sidebar / ⋯.
                    self.panelCapsulePortraitSeamY.isActive = true
                    self.panelCapsulePortraitSeamY.constant = 0
                }
                self.view.bringSubviewToFront(self.chatHost)
                self.view.bringSubviewToFront(self.panelStageCapsule)
            } else {
                // Landscape
                if self.isChatCollapsed {
                    // Collapsed: chip on the trailing edge, −90° like a side tab.
                    self.panelStageCapsule.transform = self.landscapeCapsuleRotation
                    self.panelStageCapsule.isHidden = false
                    self.panelStageCapsule.prefersFullBoundsHitTesting = false
                    self.panelCapsuleLandscapeCenterY.isActive = true
                    let visualHalfWidth = size.height / 2
                    self.panelCapsuleLandscapeTrailingX.isActive = true
                    self.panelCapsuleLandscapeTrailingX.constant = -(visualHalfWidth + self.collapsedHandleBottomInset)
                } else if self.chatPanelStage == .full {
                    // Full AI: same top-bar row as sidebar / ⋯ (not the left seam).
                    self.panelStageCapsule.transform = .identity
                    self.panelStageCapsule.isHidden = false
                    self.panelStageCapsule.prefersFullBoundsHitTesting = true
                    self.panelCapsulePortraitCenterX.isActive = true
                    self.panelCapsulePortraitSeamY.isActive = true
                    self.panelCapsulePortraitSeamY.constant = 0
                } else {
                    // Half: −90° on the reader | AI seam.
                    self.panelStageCapsule.transform = self.landscapeCapsuleRotation
                    self.panelStageCapsule.isHidden = false
                    self.panelStageCapsule.prefersFullBoundsHitTesting = false
                    self.panelCapsuleLandscapeCenterY.isActive = true
                    self.panelCapsuleLandscapeLeadingX.isActive = true
                    self.panelCapsuleLandscapeLeadingX.constant = 0
                }
                self.view.bringSubviewToFront(self.chatHost)
                self.view.bringSubviewToFront(self.panelStageCapsule)
            }
        }

        if layoutNow {
            UIView.performWithoutAnimation {
                place()
                self.view.layoutIfNeeded()
            }
        } else {
            place()
        }
        // Avoid cascading refreshStudyComposerLayout from every layout pass —
        // callers that change stage / orientation pass reconcileChrome: true.
        if reconcileChrome {
            syncStudyOverlayChrome()
        }
    }

    /// Update chat overlay length only — no layoutIfNeeded (caller animates).
    private func applyOverlayLengthForCurrentStage() {
        guard isReaderVisible else { return }
        if isPortraitMode {
            let total = max(view.bounds.height, 1)
            if isChatCollapsed {
                portraitChatHeightConstraint.constant = 0
            } else {
                chatHost.isHidden = false
                chatNav.view.isHidden = false
                portraitChatHeightConstraint.constant = overlayLength(for: total)
            }
        } else {
            let total = max(view.bounds.width, 1)
            if isChatCollapsed {
                chatWidthConstraint.constant = 0
            } else {
                chatHost.isHidden = false
                chatNav.view.isHidden = false
                chatWidthConstraint.constant = overlayLength(for: total)
            }
        }
    }

    private func syncResizePans() {
        landscapeResizePan.isEnabled = isReaderVisible && !isPortraitMode && !isChatCollapsed
        portraitResizePan.isEnabled = isReaderVisible && isPortraitMode && !isChatCollapsed
    }

    private func bringChromeToFront() {
        guard isReaderVisible else { return }
        view.bringSubviewToFront(chatHost)
        // Always keep the stage chip above chatHost — scroll/layout can bury it
        // and make ▲▼ look dead until the next stage sync.
        if !panelStageCapsule.isHidden {
            view.bringSubviewToFront(panelStageCapsule)
        }
        // Note sheet must stay above chat chrome or the panel flash looks like a black screen
        // and steals first responder from the comment field.
        ConnectsNoteSheet.bringToFront(in: view)
    }

    private func syncChatPanelChrome() {
        let overlay = isReaderVisible && chatHost.superview === view

        if overlay && !isChatCollapsed {
            chatHost.backgroundColor = DSTheme.c.background
            chatHost.layer.masksToBounds = false
            chatHost.layer.shadowColor = UIColor.black.cgColor
            chatHost.layer.shadowOpacity = 0.14
            chatHost.layer.shadowRadius = 10
            chatHost.clipsToBounds = false
        } else if overlay {
            chatHost.backgroundColor = DSTheme.c.background
            chatHost.layer.shadowOpacity = 0
            chatHost.layer.shadowPath = nil
            chatHost.clipsToBounds = false
        } else {
            chatHost.backgroundColor = DSTheme.c.background
            chatHost.layer.shadowOpacity = 0
            chatHost.layer.shadowPath = nil
            chatHost.clipsToBounds = true
        }
        updateChatPanelShadowPath()
    }

    private func updateChatPanelShadowPath() {
        guard isReaderVisible, !isChatCollapsed, !chatHost.isHidden,
              chatHost.superview === view else {
            chatHost.layer.shadowPath = nil
            return
        }
        let bounds = chatHost.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        chatHost.layer.shadowPath = UIBezierPath(rect: bounds).cgPath
        chatHost.layer.shadowOffset = isPortraitMode
            ? CGSize(width: 0, height: -3)
            : CGSize(width: -3, height: 0)
    }

    @objc private func themeChanged() {
        view.backgroundColor = DSTheme.c.background
        syncChatPanelChrome()
        panelStageCapsule.applyTheme(elevated: false)
        chatVC.syncStudyPanelStageControl()
    }

    /// After PDF note save/cancel, keyboard teardown used to swallow the next AI-stage tap.
    @objc private func noteSheetDidDismiss() {
        // Defer one turn so dismiss teardown finishes before we endEditing the shell.
        DispatchQueue.main.async { [weak self] in
            self?.reassertStageCapsuleAfterExternalDismiss()
        }
    }

    /// Re-arm ▲▼ after note dismiss / highlight-off / keyboard teardown.
    @objc func reassertStageCapsuleAfterExternalDismiss() {
        // Never endEditing while the note sheet is up — that kills the soft keyboard.
        if ConnectsNoteSheet.isVisible { return }
        chatVC.prepareForStudyPanelControlTap()
        chatVC.dismissComposerKeyboard()
        view.endEditing(true)
        panelStageCapsule.isUserInteractionEnabled = true
        bringChromeToFront()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if ConnectsNoteSheet.isVisible { return }
            self.panelStageCapsule.isUserInteractionEnabled = true
            self.bringChromeToFront()
        }
    }

    @objc private func conversationStoreDidUpdate() {
        bindCurrentConversation()
    }

    func syncSidebarToggle(collapsed: Bool) {
        pdfReaderVC.updateSidebarToggle(collapsed: collapsed)
        markdownReaderVC.updateSidebarToggle(collapsed: collapsed)
        textEditorVC.updateSidebarToggle(collapsed: collapsed)
        if !isReaderVisible || chatPanelStage == .full {
            chatVC.updateSidebarToggleTitle(collapsed: collapsed)
        }
    }

    private func bindCurrentConversation() {
        let conv = ConversationStore.shared.currentConversation
        let docID = conv?.studyDocumentID
        let convID = conv?.id
        let docChanged = docID != boundDocumentID
        let convChanged = convID != boundConversationID
        guard docChanged || convChanged else { return }

        let wasInStudy = boundDocumentID != nil

        if boundDocumentID != nil {
            saveActiveReaderProgress()
        }
        if let previous = boundDocumentID, previous != docID {
            StudyDocumentStore.shared.releaseAccess(forID: previous)
        }
        if docID == nil, let oldConv = boundConversationID {
            StudyFileContextStore.shared.reset(conversationID: oldConv)
        }

        boundDocumentID = docID
        boundConversationID = convID
        loadGeneration &+= 1
        let gen = loadGeneration

        let enteringOrLeavingStudy = (docID != nil) != wasInStudy || docChanged
        if let docID = docID {
            isReaderVisible = true
            if !wasInStudy || docChanged {
                chatPanelStage = .collapsed
            }
            let kind = StudyDocumentStore.shared.document(id: docID)?.kind ?? .pdf
            showReader(kind: kind)
        } else {
            // Always leave study chrome when there is no document — including cold launch /
            // 新对话. Skipping remount here left an empty PDF shell ("无文档") on screen.
            isReaderVisible = false
            chatPanelStage = .collapsed
        }

        // Re-sync orientation when entering study — rotation while chat-only used to skip updates.
        // Chat-only → chat-only switches skip full spacer remount (major switch hitch).
        if enteringOrLeavingStudy || !didSeedPortraitMode {
            isPortraitMode = currentPortraitLayout()
            didSeedPortraitMode = true
            applyLayoutMode()
        }

        if let docID = docID {
            let progress = StudyProgressStore.shared.progress(for: docID)
            let needsLoad = !isActiveReaderLoaded(documentID: docID)
            if needsLoad {
                StudyDocumentStore.shared.touch(documentID: docID)
                loadActiveReader(documentID: docID) { [weak self] ok in
                    guard let self = self, ok, self.loadGeneration == gen else { return }
                    self.commitReaderViewport(progress: progress, generation: gen)
                }
            } else {
                resumeReaderAfterConversationSwitch(generation: gen)
            }
        } else {
            // Pause/flush after chat is full-screen so PDF serialize does not stall 新对话.
            // Give chrome (sidebar toggle) a frame to settle before paying PDFKit cost.
            if wasInStudy {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.pauseActiveReader()
                }
            }
        }
        guard gen == loadGeneration else { return }
        postChatWidthNotification()
    }

    private func commitReaderViewport(progress: StudyProgress?, generation: UInt) {
        guard loadGeneration == generation, isReaderVisible, !readerHost.isHidden else { return }
        switch activeReaderKind {
        case .pdf: pdfReaderVC.setReaderSurfaceActive(true)
        case .markdown: markdownReaderVC.setReaderSurfaceActive(true)
        case .text: textEditorVC.setReaderSurfaceActive(true)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.loadGeneration == generation,
                  self.isReaderVisible, !self.readerHost.isHidden else { return }
            self.view.layoutIfNeeded()
            switch self.activeReaderKind {
            case .pdf: self.pdfReaderVC.realignVisibleViewport(using: progress)
            case .markdown: self.markdownReaderVC.realignVisibleViewport(using: progress)
            case .text: self.textEditorVC.realignVisibleViewport(using: progress)
            }
        }
    }

    private func resumeReaderAfterConversationSwitch(generation: UInt) {
        guard loadGeneration == generation, isReaderVisible, !readerHost.isHidden else { return }
        switch activeReaderKind {
        case .pdf: pdfReaderVC.setReaderSurfaceActive(true)
        case .markdown: markdownReaderVC.setReaderSurfaceActive(true)
        case .text: textEditorVC.setReaderSurfaceActive(true)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.loadGeneration == generation,
                  self.isReaderVisible, !self.readerHost.isHidden else { return }
            self.view.layoutIfNeeded()
            switch self.activeReaderKind {
            case .pdf: self.pdfReaderVC.resumeAfterConversationSwitch()
            case .markdown: self.markdownReaderVC.resumeAfterConversationSwitch()
            case .text: self.textEditorVC.resumeAfterConversationSwitch()
            }
        }
    }

    private func applyLayoutMode(for size: CGSize? = nil) {
        if !isReaderVisible {
            setChatOnlyLayout(true)
            mountChatFullScreen()
            // Belt-and-suspenders: never leave an empty reader shell in front of chat.
            readerHost.isHidden = true
            panelStageCapsule.isHidden = true
            chatHost.isHidden = false
            chatNav.view.isHidden = false
            view.bringSubviewToFront(chatHost)
            return
        }

        setChatOnlyLayout(false)
        switch activeReaderKind {
        case .pdf: pdfReaderVC.setSidebarButtonHidden(false)
        case .markdown: markdownReaderVC.setSidebarButtonHidden(false)
        case .text: textEditorVC.setSidebarButtonHidden(false)
        }

        let layoutSize = layoutBoundsSize(for: size)
        if isPortraitMode {
            mountChatInPortraitOverlay(layoutHeight: layoutSize.height)
            updatePortraitOverlay(layoutHeight: layoutSize.height)
        } else {
            mountChatInLandscapeOverlay(layoutWidth: layoutSize.width)
            updateLandscapeOverlay(layoutWidth: layoutSize.width)
        }
        syncPanelStageCapsuleLayout()
        syncResizePans()
        bringChromeToFront()
    }

    /// Single source of truth for study overlay chrome (spacers, chat mode, composer).
    /// Pass `reconcileContent: false` on the panel-stage hot path so ▲▼ stays tappable
    /// immediately (height / bottom pin work is deferred).
    private func syncStudyOverlayChrome(reconcileContent: Bool = true) {
        chatVC.loadViewIfNeeded()
        guard isReaderVisible else {
            chatVC.setStudyShowsSidebarToggle(false)
            chatVC.setStudyChrome(.none)
            applyStudyPanelSpacers(expanded: false)
            chatNav.additionalSafeAreaInsets = .zero
            return
        }

        let expanded = chatHost.superview === view && !isChatCollapsed
        applyStudyPanelSpacers(expanded: expanded)
        syncStudyNavSafeAreaInsets()

        if isPortraitMode {
            chatVC.setStudyChrome(.portraitPanel)
            chatNavLeadingInHost.constant = 0
            if #available(iOS 11.0, *) {
                chatNav.view.insetsLayoutMarginsFromSafeArea = false
            }
            chatVC.edgesForExtendedLayout = []
            chatVC.extendedLayoutIncludesOpaqueBars = false
        } else {
            chatVC.setStudyChrome(.documentReader)
            chatNavLeadingInHost.constant = 0
            chatVC.edgesForExtendedLayout = .all
            chatVC.extendedLayoutIncludesOpaqueBars = false
        }
        // Full AI covers the document top-bar sidebar; rehost it on chat nav (leading).
        chatVC.setStudyShowsSidebarToggle(chatPanelStage == .full)

        guard reconcileContent, !isAnimatingPanelStage else { return }
        chatVC.refreshStudyComposerLayout(reconcileViewport: reconcileContent)
        if let msgs = ConversationStore.shared.currentConversation?.messages, !msgs.isEmpty {
            chatVC.ensureBottomPinnedIfNeeded(messages: msgs)
        }
    }

    /// Status bar (landscape) and seam capsule clearance (portrait).
    private func applyStudyPanelSpacers(expanded: Bool) {
        let statusBarInset: CGFloat
        if isReaderVisible, !isPortraitMode, expanded {
            statusBarInset = view.safeAreaInsets.top
        } else {
            statusBarInset = 0
        }
        landscapeStatusSpacerHeight.constant = statusBarInset

        // Portrait stage control sits in the nav title — no seam spacer.
        portraitSeamSpacerHeight.constant = 0
    }

    /// Cancel UIKit's internal status-bar padding inside chatNav; we use `landscapeStatusSpacer` instead.
    private func syncStudyNavSafeAreaInsets() {
        guard isReaderVisible, !isPortraitMode else {
            if chatNav.additionalSafeAreaInsets != .zero {
                chatNav.additionalSafeAreaInsets = .zero
            }
            return
        }
        let top = view.safeAreaInsets.top
        let compensation = top > 0.5 ? -top : 0
        let next = UIEdgeInsets(top: compensation, left: 0, bottom: 0, right: 0)
        if chatNav.additionalSafeAreaInsets != next {
            chatNav.additionalSafeAreaInsets = next
        }
    }

    private func applyPortraitSeamLayout(expanded: Bool) {
        applyStudyPanelSpacers(expanded: expanded)
    }

    private func mountChatFullScreen() {
        NSLayoutConstraint.deactivate(chatPortraitConstraints)
        NSLayoutConstraint.deactivate(chatLandscapeConstraints)
        if chatHost.superview !== view {
            chatHost.removeFromSuperview()
            view.addSubview(chatHost)
            chatHost.translatesAutoresizingMaskIntoConstraints = false
        }
        chatHost.isHidden = false
        chatNav.view.isHidden = false
        chatNavLeadingInHost.constant = 0
        chatWidthConstraint.isActive = false
        portraitChatHeightConstraint.isActive = false
        portraitChatHeightConstraint.constant = 0
        chatLandscapeConstraints = [
            chatHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chatHost.topAnchor.constraint(equalTo: view.topAnchor),
            chatHost.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]
        NSLayoutConstraint.activate(chatLandscapeConstraints)
        chatHost.layer.shadowOpacity = 0
        chatHost.layer.shadowPath = nil
        ensureChatNavInHost()
        syncChatPanelChrome()
        syncPanelStageCapsuleLayout()
        bringChromeToFront()
    }

    private func mountChatInLandscapeOverlay(layoutWidth: CGFloat? = nil) {
        NSLayoutConstraint.deactivate(chatPortraitConstraints)
        portraitChatHeightConstraint.isActive = false
        portraitChatHeightConstraint.constant = 0
        attachChatHostToViewIfNeeded()
        chatWidthConstraint.isActive = true
        let total = layoutWidth ?? max(view.bounds.width, 1)
        chatWidthConstraint.constant = overlayLength(for: total, portrait: false)
        NSLayoutConstraint.deactivate(chatLandscapeConstraints)
        chatLandscapeConstraints = [
            chatHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chatHost.topAnchor.constraint(equalTo: view.topAnchor),
            chatHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            chatWidthConstraint
        ]
        NSLayoutConstraint.activate(chatLandscapeConstraints)
        ensureChatNavInHost()
        syncChatPanelChrome()
        syncPanelStageCapsuleLayout()
    }

    private func mountChatInPortraitOverlay(layoutHeight: CGFloat? = nil) {
        NSLayoutConstraint.deactivate(chatLandscapeConstraints)
        chatWidthConstraint.isActive = false
        chatWidthConstraint.constant = 0
        attachChatHostToViewIfNeeded()
        portraitChatHeightConstraint.isActive = true
        let total = layoutHeight ?? max(view.bounds.height, 1)
        portraitChatHeightConstraint.constant = overlayLength(for: total, portrait: true)
        NSLayoutConstraint.deactivate(chatPortraitConstraints)
        chatPortraitConstraints = [
            chatHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chatHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            portraitChatHeightConstraint
        ]
        NSLayoutConstraint.activate(chatPortraitConstraints)
        ensureChatNavInHost()
        syncChatPanelChrome()
        syncPanelStageCapsuleLayout()
        syncResizePans()
        bringChromeToFront()
    }

    private func attachChatHostToViewIfNeeded() {
        if chatHost.superview !== view {
            chatHost.removeFromSuperview()
            view.addSubview(chatHost)
            chatHost.translatesAutoresizingMaskIntoConstraints = false
        }
        view.bringSubviewToFront(chatHost)
        if isReaderVisible, !panelStageCapsule.isHidden {
            view.bringSubviewToFront(panelStageCapsule)
        }
    }

    private func ensureChatNavInHost() {
        guard chatNav.view.superview !== chatHost else { return }
        if landscapeStatusSpacer.superview !== chatHost {
            chatHost.addSubview(landscapeStatusSpacer)
        }
        if portraitSeamSpacer.superview !== chatHost {
            chatHost.addSubview(portraitSeamSpacer)
        }
        chatNav.view.removeFromSuperview()
        chatHost.addSubview(chatNav.view)
        chatNav.view.translatesAutoresizingMaskIntoConstraints = false
        if chatNavTopBelowSeamSpacer == nil {
            chatNavTopBelowSeamSpacer = chatNav.view.topAnchor.constraint(
                equalTo: portraitSeamSpacer.bottomAnchor
            )
        }
        if chatNavLeadingInHost == nil {
            chatNavLeadingInHost = chatNav.view.leadingAnchor.constraint(equalTo: chatHost.leadingAnchor)
        }
        let expanded = isPortraitMode && isReaderVisible && !isChatCollapsed
        NSLayoutConstraint.activate([
            chatNavLeadingInHost,
            chatNavTopBelowSeamSpacer,
            chatNav.view.trailingAnchor.constraint(equalTo: chatHost.trailingAnchor),
            chatNav.view.bottomAnchor.constraint(equalTo: chatHost.bottomAnchor)
        ])
        applyStudyPanelSpacers(expanded: expanded)
        chatNav.loadViewIfNeeded()
        chatVC.loadViewIfNeeded()
    }

    /// Returns true when host length or visibility changed (caller may refresh chrome).
    @discardableResult
    private func updateLandscapeOverlay(layoutWidth: CGFloat? = nil) -> Bool {
        guard isReaderVisible, !isPortraitMode else { return false }
        let total = layoutWidth ?? max(view.bounds.width, 1)
        let target = isChatCollapsed ? 0 : overlayLength(for: total)
        let hideHost = isChatCollapsed
        let lengthChanged = abs(chatWidthConstraint.constant - target) > 0.5
        let visibilityChanged = chatHost.isHidden != hideHost
        guard lengthChanged || visibilityChanged else { return false }

        if hideHost {
            chatWidthConstraint.constant = 0
            chatHost.isHidden = true
            chatNav.view.isHidden = true
        } else {
            chatHost.isHidden = false
            chatNav.view.isHidden = false
            chatWidthConstraint.constant = target
        }
        syncChatPanelChrome()
        syncPanelStageCapsuleLayout(layoutNow: false, reconcileChrome: false)
        syncResizePans()
        return true
    }

    /// Returns true when host length or visibility changed (caller may refresh chrome).
    @discardableResult
    private func updatePortraitOverlay(layoutHeight: CGFloat? = nil) -> Bool {
        guard isReaderVisible, isPortraitMode else { return false }
        let total = layoutHeight ?? max(view.bounds.height, 1)
        let target = isChatCollapsed ? 0 : overlayLength(for: total)
        let hideHost = isChatCollapsed
        let lengthChanged = abs(portraitChatHeightConstraint.constant - target) > 0.5
        let visibilityChanged = chatHost.isHidden != hideHost
        guard lengthChanged || visibilityChanged else { return false }

        if hideHost {
            portraitChatHeightConstraint.constant = 0
            chatHost.isHidden = true
            chatNav.view.isHidden = true
        } else {
            chatHost.isHidden = false
            chatNav.view.isHidden = false
            portraitChatHeightConstraint.constant = target
        }
        syncChatPanelChrome()
        syncPanelStageCapsuleLayout(layoutNow: false, reconcileChrome: false)
        syncResizePans()
        return true
    }

    private func stepPanelTowardAI() {
        guard isReaderVisible else { return }
        chatVC.prepareForStudyPanelControlTap()
        switch chatPanelStage {
        case .collapsed: applyChatPanelStage(.half, animated: true)
        case .half: applyChatPanelStage(.full, animated: true)
        case .full: break
        }
    }

    private func stepPanelTowardReading() {
        guard isReaderVisible else { return }
        chatVC.prepareForStudyPanelControlTap()
        switch chatPanelStage {
        case .full: applyChatPanelStage(.half, animated: true)
        case .half: applyChatPanelStage(.collapsed, animated: true)
        case .collapsed: break
        }
    }

    private func applyChatPanelStage(_ stage: StudyChatPanelStage, animated: Bool) {
        // Never auto-pop the composer keyboard when expanding / collapsing the AI panel.
        // Unhiding chatHost can otherwise restore a previous first-responder and raise the keyboard.
        chatVC.dismissComposerKeyboard()
        view.endEditing(true)

        if stage == .collapsed {
            chatVC.dismissComposerKeyboard()
        } else if chatPanelStage == .half {
            stashDepartingOverlayRatio()
        }

        let wasCollapsed = chatPanelStage == .collapsed
        let becomingCollapsed = stage == .collapsed
        // Capture before animation — resize can briefly flip stick/readingHistory flags.
        let chaseBottomAfterResize = !becomingCollapsed && chatVC.wantsBottomChaseForPanelResize
        chatPanelStage = stage

        // Ensure overlay constraints exist for the current orientation.
        if isPortraitMode {
            if chatPortraitConstraints.isEmpty || !portraitChatHeightConstraint.isActive {
                mountChatInPortraitOverlay()
            }
        } else {
            if chatLandscapeConstraints.isEmpty || !chatWidthConstraint.isActive {
                mountChatInLandscapeOverlay()
            }
        }

        // Expanding from fully reading: show host at length 0 first so width/height can animate open.
        if wasCollapsed, !becomingCollapsed {
            chatHost.isHidden = false
            chatNav.view.isHidden = false
            if isPortraitMode {
                portraitChatHeightConstraint.constant = 0
            } else {
                chatWidthConstraint.constant = 0
            }
            if animated {
                view.layoutIfNeeded()
            }
        }

        applyOverlayLengthForCurrentStage()
        syncResizePans()
        syncChatPanelChrome()
        // Mark animating before chrome sync so we skip heavy table reconcile on the hot path.
        if animated {
            isAnimatingPanelStage = true
        }
        // Place capsule first and keep it interactive; defer heavy chat reconcile.
        syncPanelStageCapsuleLayout(layoutNow: false)
        // Capsule must stay above chatHost for taps (mount brings chatHost forward).
        panelStageCapsule.isUserInteractionEnabled = true
        if !panelStageCapsule.isHidden {
            view.bringSubviewToFront(panelStageCapsule)
        }

        let animations = {
            self.view.layoutIfNeeded()
            self.updateChatPanelShadowPath()
        }
        let finish = {
            if becomingCollapsed {
                self.chatHost.isHidden = true
                self.chatNav.view.isHidden = true
            }
            // UIKit may restore composer first-responder when the host finishes unhiding.
            self.chatVC.dismissComposerKeyboard()
            self.view.endEditing(true)
            self.syncPanelStageCapsuleLayout(layoutNow: false)
            self.bringChromeToFront()
            self.isAnimatingPanelStage = false
            // Defer width/height reconcile so stage buttons accept the next tap immediately.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.syncStudyOverlayChrome(reconcileContent: false)
                self.postChatWidthNotification()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self = self else { return }
                self.syncStudyOverlayChrome(reconcileContent: true)
                if chaseBottomAfterResize {
                    self.chatVC.rePinLatestTurnAfterStudyPanelResize(force: true)
                }
            }
        }

        if animated {
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
                animations: animations,
                completion: { _ in
                    finish()
                }
            )
        } else {
            animations()
            finish()
        }
    }

    @objc private func handleLandscapeResizePan(_ gesture: UIPanGestureRecognizer) {
        guard isReaderVisible, !isPortraitMode, !isChatCollapsed else { return }
        let total = max(view.bounds.width, 1)
        switch gesture.state {
        case .began:
            let pointInView = gesture.location(in: view)
            // Never start a resize on the ▲/▼ controls — that fought highlighter + stage taps.
            if !panelStageCapsule.isHidden,
               panelStageCapsule.containsStageControl(at: pointInView, in: view) {
                landscapeResizeActive = false
                return
            }
            let point = gesture.location(in: chatHost)
            // Hit the seam strip (horizontal capsule straddles leading edge).
            // Rotated chip's on-screen half-width ≈ untransformed height / 2.
            guard point.x <= max(landscapeSeamHitWidth, panelCapsuleHorizontalSize.height / 2) + 12 else {
                landscapeResizeActive = false
                return
            }
            landscapeResizeActive = true
            panStartChatLength = chatWidthConstraint.constant
        case .changed:
            guard landscapeResizeActive else { return }
            let delta = gesture.translation(in: view).x
            let next = min(max(0, panStartChatLength - delta), total)
            chatWidthConstraint.constant = next
        case .ended, .cancelled:
            guard landscapeResizeActive else { return }
            landscapeResizeActive = false
            // Tiny movement = accidental tap near seam; don't snap stages (felt like "卡住").
            if abs(gesture.translation(in: view).x) < 12 {
                chatWidthConstraint.constant = panStartChatLength
                view.layoutIfNeeded()
                return
            }
            snapPanel(fromRatio: chatWidthConstraint.constant / total, animated: true)
        default:
            break
        }
    }

    @objc private func handlePortraitResizePan(_ gesture: UIPanGestureRecognizer) {
        guard isReaderVisible, isPortraitMode, !isChatCollapsed else { return }
        let total = max(view.bounds.height, 1)
        switch gesture.state {
        case .began:
            let pointInView = gesture.location(in: view)
            if let bar = chatNav.navigationBar as UIView?,
               bar.bounds.contains(bar.convert(pointInView, from: view)) {
                portraitResizeActive = false
                return
            }
            let point = gesture.location(in: chatHost)
            guard point.y <= 24 else {
                portraitResizeActive = false
                return
            }
            portraitResizeActive = true
            panStartChatLength = portraitChatHeightConstraint.constant
        case .changed:
            guard portraitResizeActive else { return }
            let delta = gesture.translation(in: view).y
            let next = min(max(0, panStartChatLength - delta), total)
            portraitChatHeightConstraint.constant = next
        case .ended, .cancelled:
            guard portraitResizeActive else { return }
            portraitResizeActive = false
            if abs(gesture.translation(in: view).y) < 12 {
                portraitChatHeightConstraint.constant = panStartChatLength
                view.layoutIfNeeded()
                return
            }
            snapPanel(fromRatio: portraitChatHeightConstraint.constant / total, animated: true)
        default:
            break
        }
    }

    /// Snap a free drag onto collapsed / half / full.
    private func snapPanel(fromRatio ratio: CGFloat, animated: Bool) {
        if ratio < 0.22 {
            applyChatPanelStage(.collapsed, animated: animated)
            return
        }
        if ratio > 0.78 {
            applyChatPanelStage(.full, animated: animated)
            return
        }
        let clamped = Self.clampOverlayRatio(ratio, portrait: isPortraitMode)
        if isPortraitMode {
            portraitOverlayRatio = clamped
            persistPortraitOverlayRatio()
        } else {
            landscapeOverlayRatio = clamped
            persistLandscapeOverlayRatio()
        }
        applyChatPanelStage(.half, animated: animated)
    }

    private func postChatWidthNotification() {
        let width: CGFloat
        if !isReaderVisible {
            width = view.bounds.width
        } else if isPortraitMode {
            width = view.bounds.width
        } else if isChatCollapsed {
            width = 0
        } else {
            width = chatWidthConstraint.constant
        }
        let compact = width < compactChatBreakpoint
        if isReaderVisible {
            chatVC.setCompactChrome(compact)
        }
        // Portrait stage flips change height only — posting width every time rebuilt all row
        // heights and made ▲/▼ feel stuck.
        let bucket = RenderCacheStore.widthBucket(for: max(width, 1))
        let lastBucket = RenderCacheStore.widthBucket(for: max(lastPostedChatWidth, 1))
        guard abs(width - lastPostedChatWidth) > 1 || bucket != lastBucket || lastPostedChatWidth < 0 else {
            return
        }
        lastPostedChatWidth = width
        NotificationCenter.default.post(
            name: .connectsChatWidthDidChange,
            object: nil,
            userInfo: ["width": width, "compact": compact]
        )
    }

    func expandChatPanelIfNeeded() {
        guard isReaderVisible, isChatCollapsed else { return }
        applyChatPanelStage(.half, animated: true)
    }

    private func handleAskSelection(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let convID = boundConversationID ?? ConversationStore.shared.currentConversation?.id
        guard let convID = convID else { return }
        StudyAskSelectionStore.shared.setPending(trimmed, conversationID: convID)
        StudyFileContextStore.shared.setScope(.selection, for: convID)
        ConversationStore.shared.updateConversationQuietly(id: convID) { draft in
            draft.studyPageCaptureEnabled = true
        }
        // Keep reading: do not pop half-AI or steal keyboard — selection stays highlighted.
        switch activeReaderKind {
        case .text: textEditorVC.pinAskSelectionHighlight()
        case .markdown: markdownReaderVC.pinAskSelectionHighlight()
        case .pdf: break
        }
        chatVC.prepareAskAboutSelection(trimmed)
        ConnectsToast.show("已附带选区，打开 AI 后提问", in: view, duration: 1.1)
    }

    func clearAskSelectionHighlightInReader() {
        textEditorVC.clearAskSelectionHighlight()
        markdownReaderVC.clearAskSelectionHighlight()
    }

#if DEBUG
    func debugWaitForStudyCaptureReady(documentID: String, timeout: TimeInterval = 60, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if Date() > deadline {
                completion(false)
                return
            }
            bindCurrentConversation()
            if boundDocumentID == documentID,
               isActiveReaderLoaded(documentID: documentID),
               captureCurrentStudyPage() != nil {
                completion(true)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
    }

    func debugExpandChatPanel() {
        expandChatPanelIfNeeded()
    }
#endif
}

extension StudyShellViewController: StudyReadingContextProviding {
    /// Portrait study panel owns keyboard lift (composer pinned to panel bottom, not full-screen safe area).
    var managesPortraitKeyboardLayout: Bool {
        isReaderVisible && isPortraitMode && !isChatCollapsed
    }

    var studyChatPanelStage: StudyChatPanelStage { chatPanelStage }

    var studyIsPortraitLayout: Bool { isPortraitMode }

    func applyStudyChatPanelStage(_ stage: StudyChatPanelStage, animated: Bool) {
        guard isReaderVisible else { return }
        applyChatPanelStage(stage, animated: animated)
    }

    func captureCurrentStudyPage() -> StudyPageCapture? {
        guard let docID = boundDocumentID else { return nil }
        switch activeReaderKind {
        case .pdf:
            // PDF study mode: screenshot only — never pull the PDF text layer / OCR page string.
            let label = pdfReaderVC.currentPageLabel()
            guard label != "无文档" else { return nil }
            guard let image = pdfReaderVC.captureCurrentPageImageJPEG() else { return nil }
            return StudyPageCapture(
                label: label,
                text: "",
                imageJPEGBase64: image,
                // JPEG feeds「图片转写」only — never the chat bubble thumbnail.
                prefersTextOnly: false,
                hidesImageInChatBubble: true,
                customAPIPrefix: """
                [阅读上下文 · \(label)]
                （本页仅附带截图，不抽取 PDF 文本；截图不在聊天气泡展示，请结合「图片转写」理解。）
                """
            )
        case .markdown:
            let label = markdownReaderVC.currentPageLabel()
            guard label != "无文档" else { return nil }
            let text = markdownReaderVC.currentPageText() ?? ""
            let full = markdownReaderVC.currentFullMarkdown()
            let convID = boundConversationID ?? ""
            let scope = StudyFileContextStore.shared.scope(for: convID)
            let pendingAsk = StudyAskSelectionStore.shared.pendingText(for: convID)
            var prefixParts: [String] = ["[阅读上下文 · \(label)]"]
            if let pendingAsk = pendingAsk, !pendingAsk.isEmpty {
                prefixParts.append("## SELECTION")
                prefixParts.append(String(pendingAsk.prefix(2_000)))
                if let full = full, scope != .selection {
                    prefixParts.append("## SECTION")
                    prefixParts.append(String((text.isEmpty ? full : text).prefix(2_500)))
                }
            } else if scope == .fullFile, let full = full, full.count < 12_000 {
                prefixParts.append(full)
            } else {
                prefixParts.append(String(text.prefix(4_000)))
            }
            let body = pendingAsk ?? text
            let rich = body.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80
                || (pendingAsk?.isEmpty == false)
            return StudyPageCapture(
                label: label,
                text: body,
                imageJPEGBase64: rich ? nil : markdownReaderVC.captureCurrentPageImageJPEG(),
                prefersTextOnly: rich,
                customAPIPrefix: prefixParts.joined(separator: "\n")
            )
        case .text:
            let label = textEditorVC.currentPageLabel()
            guard label != "无文档" else { return nil }
            guard let doc = StudyDocumentStore.shared.document(id: docID) else { return nil }
            let full = textEditorVC.currentPlainText()
            let convID = boundConversationID ?? ""
            let sel = StudyAskSelectionStore.shared.pendingText(for: convID)
                ?? textEditorVC.currentSelectionText()
            let scope = StudyFileContextStore.shared.scope(for: convID)
            let forceFull = scope == .fullFile || scope == .resync
            let prefix = StudyFileContextStore.shared.buildCodeContextPrefix(
                conversationID: convID,
                document: doc,
                fullText: full,
                selection: sel,
                forceFull: forceFull
            )
            return StudyPageCapture(
                label: label,
                text: full,
                imageJPEGBase64: nil,
                prefersTextOnly: true,
                customAPIPrefix: prefix
            )
        }
    }
}

extension StudyShellViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // Don't let resize pans steal taps on stage chips / nav chrome / controls.
        guard gestureRecognizer === landscapeResizePan || gestureRecognizer === portraitResizePan else {
            return true
        }
        if let touched = touch.view {
            if touched === panelStageCapsule || touched.isDescendant(of: panelStageCapsule) {
                return false
            }
            if let bar = chatNav.navigationBar as UIView?,
               touched === bar || touched.isDescendant(of: bar) {
                return false
            }
            if touched is UIControl {
                return false
            }
        }
        // Only exclude the real ▲/▼ hit targets — a fat AABB around the chip blocked
        // highlighter strokes along the half-panel seam and made middle taps feel stuck.
        if !panelStageCapsule.isHidden,
           panelStageCapsule.containsStageControl(at: touch.location(in: view), in: view) {
            return false
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let t = pan.translation(in: chatHost)
        if gestureRecognizer === landscapeResizePan {
            return abs(t.x) > abs(t.y) && abs(t.x) > 12
        }
        if gestureRecognizer === portraitResizePan {
            return abs(t.y) > abs(t.x) && abs(t.y) > 12
        }
        return true
    }
}

/// Root view that prefers the floating stage chip for hit-testing so scroll/resize
/// cannot bury ▲▼ taps under chatHost.
private final class StudyShellRootView: UIView, StudyShellRootViewMarker {
    weak var stageCapsule: StudyPanelStageCapsule?
    var shouldPreferStageHits: (() -> Bool)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Note sheet (if any) is a direct subview — keep normal front-to-back hit order
        // so the sheet receives taps while visible; stage chip wins otherwise.
        if let overlay = subviews.reversed().first(where: { $0 is ConnectsNoteOverlayHitMarker }) {
            if let hit = overlay.hitTest(convert(point, to: overlay), with: event) {
                return hit
            }
        }
        if shouldPreferStageHits?() == true,
           let capsule = stageCapsule,
           !capsule.isHidden,
           capsule.isUserInteractionEnabled,
           capsule.containsStageControl(at: point, in: self) {
            let local = capsule.convert(point, from: self)
            if let hit = capsule.hitTest(local, with: event) {
                return hit
            }
        }
        return super.hitTest(point, with: event)
    }
}
