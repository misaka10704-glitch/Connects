import UIKit
import UniformTypeIdentifiers

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
    private let ebookReaderVC = EbookReaderViewController()
    private let codeEditCoordinator = CodeEditCoordinator()
    private var activeReaderKind: StudyDocumentKind = .pdf
    private let readerHost = UIView()
    private let chatHost = UIView()
    /// Vertical ▲/▼ at the old AI-panel handle position (not in the input bar).
    private let panelStageCapsule = StudyPanelStageCapsule()

    private var chatWidthConstraint: NSLayoutConstraint!
    private var portraitChatHeightConstraint: NSLayoutConstraint!
    private var readerHostBottomConstraint: NSLayoutConstraint!
    /// Active chatHost.bottom → view.bottom (portrait / landscape / fullscreen).
    private var chatHostBottomConstraint: NSLayoutConstraint?
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
    private var pendingEditAfterSwitch: (CodeEditProposal, String)?
    private var pendingFolderPick = false
    private var pendingImportWorkspaceID: String?
    /// Free open: folder or any file/PDF (⋯「打开…」 / reader title when unbound).
    private var pendingFreeOpenPick = false
    /// Debounce Agent write → editor reload (avoids multi-file flash).
    private var agentEditorReloadWork: DispatchWorkItem?

    /// Must match `handleAskSelection` — empty string breaks pending Ask lookup on send.
    private func resolvedStudyConversationID() -> String {
        boundConversationID
            ?? ConversationStore.shared.currentConversation?.id
            ?? ""
    }
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
    /// After panel open animation, put keyboard into the AI composer (⌘L / ⌘J).
    private var pendingFocusComposerAfterPanel = false
    /// Docked soft keyboard: raise reader + chat together (not contentInset cover).
    private var shellKeyboardLift: CGFloat = 0

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
        ebookReaderVC.onToggleSidebar = toggleSidebar
        let askSelection: (String) -> Void = { [weak self] text in
            self?.handleAskSelection(text)
        }
        // PDF has no Ask (highlighter-only). Code / Markdown keep Ask on selection.
        markdownReaderVC.onAskSelection = askSelection
        textEditorVC.onAskSelection = askSelection
        codeEditCoordinator.bindEditor(textEditorVC)
        textEditorVC.completionProvider = codeEditCoordinator
        codeEditCoordinator.onDiffSessionChange = { [weak self] active, count in
            guard let self = self else { return }
            if !WorkspaceEditSession.shared.isEmpty {
                self.chatVC.refreshWorkspaceDiffBanner()
            } else {
                self.chatVC.setCodeDiffReviewBanner(visible: active, changeCount: count)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .workspaceEditSessionDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.chatVC.refreshWorkspaceDiffBanner()
        }
        NotificationCenter.default.addObserver(
            forName: .workspaceAgentDidMutateDocuments,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let ids = (note.userInfo?["documentIDs"] as? [String]) ?? []
            self?.scheduleCoalescedAgentEditorReload(documentIDs: ids)
        }
        let fileTitle: (UIView) -> Void = { [weak self] source in
            self?.presentWorkspaceFileMenu(from: source)
        }
        textEditorVC.onFileTitleTapped = fileTitle
        pdfReaderVC.onFileTitleTapped = fileTitle
        markdownReaderVC.onFileTitleTapped = fileTitle
        ebookReaderVC.onFileTitleTapped = fileTitle
        markdownReaderVC.onBuildPlan = { [weak self] in
            guard let self, let docID = self.boundDocumentID else { return }
            if self.chatPanelStage == .collapsed {
                self.applyChatPanelStage(.half, animated: true, focusComposerAfter: true)
            } else {
                self.chatVC.prepareForStudyPanelControlTap()
            }
            self.chatVC.startPlanBuild(documentID: docID)
        }
        StudyAskMenu.installIfNeeded()

        addChild(pdfReaderVC)
        addChild(markdownReaderVC)
        addChild(textEditorVC)
        addChild(ebookReaderVC)
        addChild(chatNav)
        pdfReaderVC.didMove(toParent: self)
        markdownReaderVC.didMove(toParent: self)
        textEditorVC.didMove(toParent: self)
        ebookReaderVC.didMove(toParent: self)
        chatNav.didMove(toParent: self)

        [readerHost, panelStageCapsule].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        readerHost.addSubview(pdfReaderVC.view)
        readerHost.addSubview(markdownReaderVC.view)
        readerHost.addSubview(textEditorVC.view)
        readerHost.addSubview(ebookReaderVC.view)
        markdownReaderVC.view.isHidden = true
        textEditorVC.view.isHidden = true
        ebookReaderVC.view.isHidden = true
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
        ebookReaderVC.view.translatesAutoresizingMaskIntoConstraints = false

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

        readerHostBottomConstraint = readerHost.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            readerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerHost.topAnchor.constraint(equalTo: view.topAnchor),
            readerHostBottomConstraint,

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

            ebookReaderVC.view.leadingAnchor.constraint(equalTo: readerHost.leadingAnchor),
            ebookReaderVC.view.trailingAnchor.constraint(equalTo: readerHost.trailingAnchor),
            ebookReaderVC.view.topAnchor.constraint(equalTo: readerHost.topAnchor),
            ebookReaderVC.view.bottomAnchor.constraint(equalTo: readerHost.bottomAnchor),

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(studyKeyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )

        bindCurrentConversation()
    }

    @objc private func studyKeyboardWillChange(_ note: Notification) {
        if ConnectsNoteSheet.isVisible { return }
        // Chat-only: do not touch Study layout (launch used to freeze on spurious keyboard frames).
        guard isReaderVisible, isViewLoaded, readerHostBottomConstraint != nil else { return }
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        else { return }

        let snap = ConnectsKeyboardGeometry.resolve(screenFrame: frame, in: view)
        let lift: CGFloat
        switch snap.kind {
        case .hidden, .floatingMini:
            lift = 0
        case .docked:
            // Cap lift — full-screen / bogus frames on launch must not crush the UI to 0 height.
            let maxLift = max(120, view.bounds.height * 0.55)
            lift = min(max(0, snap.bottomOverlap), maxLift)
            if snap.bottomOverlap >= view.bounds.height - 40 {
                // Misclassified “keyboard” covering the whole window (common at cold start).
                applyShellKeyboardLiftIfNeeded(0, duration: duration, note: note)
                return
            }
        }
        applyShellKeyboardLiftIfNeeded(lift, duration: duration, note: note)
    }

    /// Raise reader + chat bottoms together so the keyboard never covers prior content.
    private func applyShellKeyboardLift(_ lift: CGFloat) {
        applyShellKeyboardLiftIfNeeded(lift, duration: 0, note: nil)
    }

    private func applyShellKeyboardLiftIfNeeded(_ lift: CGFloat, duration: Double, note: Notification?) {
        guard isViewLoaded, readerHostBottomConstraint != nil else { return }
        let next = max(0, lift)
        let liftChanged = abs(shellKeyboardLift - next) > 0.5
        guard liftChanged else {
            if next == 0 { textEditorVC.applyKeyboardBottomInset(0) }
            return
        }
        shellKeyboardLift = next
        readerHostBottomConstraint.constant = -next
        chatHostBottomConstraint?.constant = -next
        textEditorVC.applyKeyboardBottomInset(0)
        if isPortraitMode, isReaderVisible, !isChatCollapsed, portraitChatHeightConstraint.isActive {
            let available = max(view.bounds.height - next, 1)
            let target = overlayLength(for: available, portrait: true)
            if abs(portraitChatHeightConstraint.constant - target) > 0.5 {
                portraitChatHeightConstraint.constant = target
            }
        }
        guard let note = note, duration > 0 else {
            view.setNeedsLayout()
            return
        }
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
            ?? UIView.AnimationCurve.easeInOut.rawValue
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
    }

    private func makeChatHostBottomConstraint() -> NSLayoutConstraint {
        let c = chatHost.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -shellKeyboardLift)
        chatHostBottomConstraint = c
        return c
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
                self.finishRotationChromeReconcile()
                self.bringChromeToFront()
            }
        })
    }

    /// Defer chat table reconcile until after rotation geometry settles.
    private func finishRotationChromeReconcile() {
        let chaseBottom = chatVC.wantsBottomChaseForPanelResize
        syncStudyOverlayChrome(reconcileContent: false)
        postChatWidthNotification()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self = self else { return }
            self.syncStudyOverlayChrome(reconcileContent: true)
            if chaseBottom {
                self.chatVC.rePinLatestTurnAfterStudyPanelResize(force: true)
            }
        }
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
                finishRotationChromeReconcile()
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
            ebookReaderVC.setSidebarButtonHidden(true)
            ebookReaderVC.setReaderSurfaceActive(false)
            ebookReaderVC.prepareForShellLayoutChange()
        } else {
            readerHost.isHidden = false
        }
    }

    private func captureActiveReaderProgress() -> StudyProgress? {
        switch activeReaderKind {
        case .pdf: return pdfReaderVC.captureReadingProgress()
        case .markdown: return markdownReaderVC.captureReadingProgress()
        case .text: return textEditorVC.captureReadingProgress()
        case .ebook: return ebookReaderVC.captureReadingProgress()
        }
    }

    private func beginActiveReaderRotation(keeping progress: StudyProgress?) {
        switch activeReaderKind {
        case .pdf: pdfReaderVC.beginShellRotation(keeping: progress)
        case .markdown: markdownReaderVC.beginShellRotation(keeping: progress)
        case .text: textEditorVC.beginShellRotation(keeping: progress)
        case .ebook: ebookReaderVC.beginShellRotation(keeping: progress)
        }
    }

    private func updateActiveReaderDuringRotation() {
        switch activeReaderKind {
        case .pdf: pdfReaderVC.updateDuringShellRotation()
        case .markdown: markdownReaderVC.updateDuringShellRotation()
        case .text: textEditorVC.updateDuringShellRotation()
        case .ebook: ebookReaderVC.updateDuringShellRotation()
        }
    }

    private func finishActiveReaderRotation(using progress: StudyProgress?) {
        switch activeReaderKind {
        case .pdf: pdfReaderVC.finishShellRotation(using: progress)
        case .markdown: markdownReaderVC.finishShellRotation(using: progress)
        case .text: textEditorVC.finishShellRotation(using: progress)
        case .ebook: ebookReaderVC.finishShellRotation(using: progress)
        }
    }

    private func showReader(kind: StudyDocumentKind) {
        activeReaderKind = kind
        pdfReaderVC.view.isHidden = kind != .pdf
        markdownReaderVC.view.isHidden = kind != .markdown
        textEditorVC.view.isHidden = kind != .text
        ebookReaderVC.view.isHidden = kind != .ebook
        switch kind {
        case .pdf:
            markdownReaderVC.setReaderSurfaceActive(false)
            markdownReaderVC.setSidebarButtonHidden(true)
            textEditorVC.setReaderSurfaceActive(false)
            textEditorVC.setSidebarButtonHidden(true)
            ebookReaderVC.setReaderSurfaceActive(false)
            ebookReaderVC.setSidebarButtonHidden(true)
        case .markdown:
            pdfReaderVC.setReaderSurfaceActive(false)
            pdfReaderVC.setSidebarButtonHidden(true)
            textEditorVC.setReaderSurfaceActive(false)
            textEditorVC.setSidebarButtonHidden(true)
            ebookReaderVC.setReaderSurfaceActive(false)
            ebookReaderVC.setSidebarButtonHidden(true)
        case .text:
            pdfReaderVC.setReaderSurfaceActive(false)
            pdfReaderVC.setSidebarButtonHidden(true)
            markdownReaderVC.setReaderSurfaceActive(false)
            markdownReaderVC.setSidebarButtonHidden(true)
            ebookReaderVC.setReaderSurfaceActive(false)
            ebookReaderVC.setSidebarButtonHidden(true)
        case .ebook:
            pdfReaderVC.setReaderSurfaceActive(false)
            pdfReaderVC.setSidebarButtonHidden(true)
            markdownReaderVC.setReaderSurfaceActive(false)
            markdownReaderVC.setSidebarButtonHidden(true)
            textEditorVC.setReaderSurfaceActive(false)
            textEditorVC.setSidebarButtonHidden(true)
            ebookReaderVC.setReaderSurfaceActive(true)
            ebookReaderVC.setSidebarButtonHidden(false)
        }
    }

    private func isActiveReaderLoaded(documentID: String) -> Bool {
        switch activeReaderKind {
        case .pdf: return pdfReaderVC.isLoaded(documentID: documentID)
        case .markdown: return markdownReaderVC.isLoaded(documentID: documentID)
        case .text: return textEditorVC.isLoaded(documentID: documentID)
        case .ebook: return ebookReaderVC.isLoaded(documentID: documentID)
        }
    }

    private func loadActiveReader(documentID: String, completion: @escaping (Bool) -> Void) {
        textEditorVC.bindConversationID(boundConversationID)
        switch activeReaderKind {
        case .pdf:
            markdownReaderVC.clearDocument()
            textEditorVC.clearDocument()
            ebookReaderVC.clearDocument()
            pdfReaderVC.load(documentID: documentID, completion: completion)
        case .markdown:
            pdfReaderVC.clearDocument()
            textEditorVC.clearDocument()
            ebookReaderVC.clearDocument()
            markdownReaderVC.load(documentID: documentID, completion: completion)
        case .text:
            pdfReaderVC.clearDocument()
            markdownReaderVC.clearDocument()
            ebookReaderVC.clearDocument()
            textEditorVC.load(documentID: documentID, completion: completion)
        case .ebook:
            pdfReaderVC.clearDocument()
            markdownReaderVC.clearDocument()
            textEditorVC.clearDocument()
            ebookReaderVC.load(documentID: documentID, completion: completion)
        }
    }

    private func saveActiveReaderProgress() {
        switch activeReaderKind {
        case .pdf: pdfReaderVC.saveReadingProgressNow()
        case .markdown: markdownReaderVC.saveReadingProgressNow()
        case .text: textEditorVC.saveReadingProgressNow()
        case .ebook: ebookReaderVC.saveReadingProgressNow()
        }
    }

    private func pauseActiveReader() {
        pdfReaderVC.pauseReading()
        markdownReaderVC.pauseReading()
        textEditorVC.pauseReading()
        ebookReaderVC.pauseReading()
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
        // Portrait half/full: ▲▼ floating over chat nav mid. Landscape: left seam (half/full) or trailing edge (collapsed).
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
                } else {
                    // Half / full: −90° on the chat leading edge (left seam), not the top nav.
                    self.panelStageCapsule.transform = self.landscapeCapsuleRotation
                    self.panelStageCapsule.isHidden = false
                    self.panelStageCapsule.prefersFullBoundsHitTesting = false
                    self.panelCapsuleLandscapeCenterY.isActive = true
                    self.panelCapsuleLandscapeLeadingX.isActive = true
                    // Rotated chip visual width ≈ untransformed height. Half stage
                    // straddles the reader|chat seam (constant 0). Full AI has no
                    // seam — constant 0 would leave ~half the chip off-screen.
                    let visualHalfWidth = size.height / 2
                    if self.chatPanelStage == .full {
                        self.panelCapsuleLandscapeLeadingX.constant =
                            visualHalfWidth + self.collapsedHandleBottomInset
                    } else {
                        self.panelCapsuleLandscapeLeadingX.constant = 0
                    }
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
        ebookReaderVC.updateSidebarToggle(collapsed: collapsed)
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
            let rawKind = StudyDocumentStore.shared.document(id: docID)?.kind ?? .pdf
            // Legacy `.markdown` docs open in the code editor (preview + edit).
            let kind: StudyDocumentKind = (rawKind == .markdown) ? .text : rawKind
            showReader(kind: kind)
            // Keep shell in the responder chain so ⌘ shortcuts work before any text field is focused.
            _ = becomeFirstResponder()
        } else {
            // Always leave study chrome when there is no document — including cold launch /
            // 新对话. Skipping remount here left an empty PDF shell ("无文档") on screen.
            isReaderVisible = false
            chatPanelStage = .collapsed
            applyShellKeyboardLift(0)
        }

        // Re-sync orientation when entering study — rotation while chat-only used to skip updates.
        // Chat-only → chat-only switches skip full spacer remount (major switch hitch).
        if enteringOrLeavingStudy || !didSeedPortraitMode {
            isPortraitMode = currentPortraitLayout()
            didSeedPortraitMode = true
            applyLayoutMode()
        } else if docID == nil, convChanged {
            // 新对话 / chat-only switch: dismiss reader overlay and show full-screen chat.
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
        case .ebook: ebookReaderVC.setReaderSurfaceActive(true)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.loadGeneration == generation,
                  self.isReaderVisible, !self.readerHost.isHidden else { return }
            self.view.layoutIfNeeded()
            switch self.activeReaderKind {
            case .pdf: self.pdfReaderVC.realignVisibleViewport(using: progress)
            case .markdown: self.markdownReaderVC.realignVisibleViewport(using: progress)
            case .text: self.textEditorVC.realignVisibleViewport(using: progress)
            case .ebook: self.ebookReaderVC.realignVisibleViewport(using: progress)
            }
            self.flushPendingEditAfterSwitchIfNeeded()
        }
    }

    private func resumeReaderAfterConversationSwitch(generation: UInt) {
        guard loadGeneration == generation, isReaderVisible, !readerHost.isHidden else { return }
        switch activeReaderKind {
        case .pdf: pdfReaderVC.setReaderSurfaceActive(true)
        case .markdown: markdownReaderVC.setReaderSurfaceActive(true)
        case .text: textEditorVC.setReaderSurfaceActive(true)
        case .ebook: ebookReaderVC.setReaderSurfaceActive(true)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.loadGeneration == generation,
                  self.isReaderVisible, !self.readerHost.isHidden else { return }
            self.view.layoutIfNeeded()
            switch self.activeReaderKind {
            case .pdf: self.pdfReaderVC.resumeAfterConversationSwitch()
            case .markdown: self.markdownReaderVC.resumeAfterConversationSwitch()
            case .text: self.textEditorVC.resumeAfterConversationSwitch()
            case .ebook: self.ebookReaderVC.resumeAfterConversationSwitch()
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
        case .ebook: ebookReaderVC.setSidebarButtonHidden(false)
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
            makeChatHostBottomConstraint()
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
            makeChatHostBottomConstraint(),
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
        let available = max((layoutHeight ?? view.bounds.height) - shellKeyboardLift, 1)
        portraitChatHeightConstraint.constant = overlayLength(for: available, portrait: true)
        NSLayoutConstraint.deactivate(chatPortraitConstraints)
        chatPortraitConstraints = [
            chatHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            makeChatHostBottomConstraint(),
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
        let total = layoutHeight ?? max(view.bounds.height - shellKeyboardLift, 1)
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

    private func applyChatPanelStage(_ stage: StudyChatPanelStage, animated: Bool, focusComposerAfter: Bool = false) {
        pendingFocusComposerAfterPanel = focusComposerAfter && stage != .collapsed
        // Never auto-pop the composer keyboard when expanding / collapsing the AI panel —
        // unless a shortcut asked to focus the composer after opening.
        if !pendingFocusComposerAfterPanel {
            chatVC.dismissComposerKeyboard()
            view.endEditing(true)
        } else {
            // Leave the reader; composer focus is restored in `finish`.
            view.endEditing(true)
        }

        if stage == .collapsed {
            chatVC.dismissComposerKeyboard()
            pendingFocusComposerAfterPanel = false
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
            if self.pendingFocusComposerAfterPanel {
                self.pendingFocusComposerAfterPanel = false
                // UIKit may also try to restore a previous first responder; win the race next tick.
                DispatchQueue.main.async {
                    self.chatVC.focusComposerFromShortcut()
                }
            } else {
                // UIKit may restore composer first-responder when the host finishes unhiding.
                self.chatVC.dismissComposerKeyboard()
                self.view.endEditing(true)
            }
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
        case .pdf, .ebook: break
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
    /// Study shell owns docked-keyboard lift only while a document reader is showing
    /// and the AI panel is open. Chat-only / full-reading must not route through shell lift.
    var managesPortraitKeyboardLayout: Bool {
        isReaderVisible && !isChatCollapsed
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
        case .ebook:
            let label = ebookReaderVC.currentPageLabel()
            guard !label.isEmpty else { return nil }
            guard let image = ebookReaderVC.captureCurrentPageImageJPEG() else { return nil }
            return StudyPageCapture(
                label: label,
                text: "",
                imageJPEGBase64: image,
                prefersTextOnly: false,
                hidesImageInChatBubble: true,
                customAPIPrefix: """
                [阅读上下文 · \(label)]
                （本页仅附带截图；截图不在聊天气泡展示，请结合「图片转写」理解。）
                """
            )
        case .markdown:
            let label = markdownReaderVC.currentPageLabel()
            guard label != "无文档" else { return nil }
            let text = markdownReaderVC.currentPageText() ?? ""
            let full = markdownReaderVC.currentFullMarkdown()
            let convID = resolvedStudyConversationID()
            let scope = StudyFileContextStore.shared.scope(for: convID)
            let pendingAsk = StudyAskSelectionStore.shared.pendingText(for: convID)
                ?? markdownReaderVC.pinnedAskText()
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
            let convID = resolvedStudyConversationID()
            let sel = StudyAskSelectionStore.shared.pendingText(for: convID)
                ?? textEditorVC.pinnedAskText()
                ?? textEditorVC.currentSelectionText()
            let scope = StudyFileContextStore.shared.scope(for: convID)
            let forceFull = scope == .fullFile || scope == .resync
            let workspaceID = ConversationStore.shared.currentConversation?.activeStudyWorkspaceID
            let prefix = StudyFileContextStore.shared.buildCodeContextPrefix(
                conversationID: convID,
                document: doc,
                fullText: full,
                selection: sel,
                forceFull: forceFull,
                workspaceID: workspaceID
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

    var studyCodeAIEditSupported: Bool {
        isReaderVisible && activeReaderKind == .text
    }

    @discardableResult
    func presentStudyCodeEditProposal(_ proposal: CodeEditProposal, assistantMessageID: String) -> Bool {
        // Study edits never auto-switch files — only the currently open document is writable.
        if let raw = proposal.targetPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let lower = raw.lowercased()
            if !(lower == "current" || lower == "." || lower == "active") {
                if let targetID = resolveDocumentID(forEditPath: raw) {
                    if targetID != boundDocumentID {
                        ConnectsToast.show("只能编辑当前打开的文件", in: view, duration: 1.6)
                        return false
                    }
                } else {
                    ConnectsToast.show("只能编辑当前打开的文件", in: view, duration: 1.6)
                    return false
                }
            }
        }
        guard studyCodeAIEditSupported else { return false }
        // Ensure reader is visible for Diff review.
        if chatPanelStage == .full {
            applyChatPanelStage(.half, animated: true)
        }
        return codeEditCoordinator.presentProposal(proposal, assistantMessageID: assistantMessageID)
    }

    func switchActiveDocument(to documentID: String) {
        guard let convID = ConversationStore.shared.currentConversationID else { return }
        let conv = ConversationStore.shared.currentConversation
        if conv?.isWorkspaceStudySession == true {
            // Keep conversation identity on the file's parent folder (not the grant root).
            var folderWSID = conv?.activeStudyWorkspaceID
            if let path = StudyDocumentStore.shared.document(id: documentID)?.displayPath, !path.isEmpty {
                let folderWS = StudyWorkspaceStore.shared.conversationWorkspace(
                    forFileAt: URL(fileURLWithPath: path)
                )
                folderWSID = folderWS.id
                StudyWorkspaceStore.shared.addDocument(documentID, to: folderWS.id)
            } else if let wsID = folderWSID {
                StudyWorkspaceStore.shared.addDocument(documentID, to: wsID)
            }
            ConversationStore.shared.updateConversation(id: convID) { draft in
                draft.studyDocumentID = documentID
                draft.studyWorkspaceID = folderWSID
                draft.studySessionKind = .workspace
                draft.studyPageCaptureEnabled = true
            }
        } else {
            ConversationStore.shared.updateConversation(id: convID) { draft in
                draft.studyDocumentID = documentID
                draft.studyWorkspaceID = nil
                draft.studySessionKind = .document
                draft.studyPageCaptureEnabled = true
            }
        }
    }

    private func resolveDocumentID(forEditPath raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        if lower == "current" || lower == "." || lower == "active" { return nil }
        let needle = (raw as NSString).lastPathComponent
        if let wsID = ConversationStore.shared.currentConversation?.activeStudyWorkspaceID {
            _ = try? StudyWorkspaceStore.shared.scanAndSyncDocuments(workspaceID: wsID)
            if let ws = StudyWorkspaceStore.shared.workspace(id: wsID) {
                for id in ws.documentIDs {
                    guard let doc = StudyDocumentStore.shared.document(id: id) else { continue }
                    if let path = doc.displayPath {
                        if (path as NSString).lastPathComponent.caseInsensitiveCompare(needle) == .orderedSame {
                            return id
                        }
                    }
                    if doc.title.caseInsensitiveCompare(needle) == .orderedSame
                        || doc.title.caseInsensitiveCompare((needle as NSString).deletingPathExtension) == .orderedSame {
                        return id
                    }
                }
            }
        }
        for doc in StudyDocumentStore.shared.recentDocuments(limit: 200) {
            if let path = doc.displayPath,
               (path as NSString).lastPathComponent.caseInsensitiveCompare(needle) == .orderedSame {
                return doc.id
            }
        }
        return nil
    }

    private func flushPendingEditAfterSwitchIfNeeded() {
        guard let pending = pendingEditAfterSwitch else { return }
        guard studyCodeAIEditSupported else { return }
        pendingEditAfterSwitch = nil
        if chatPanelStage == .full {
            applyChatPanelStage(.half, animated: true)
        }
        _ = codeEditCoordinator.presentProposal(pending.0, assistantMessageID: pending.1)
    }

    func presentWorkspaceFileMenu(from sourceView: UIView?) {
        guard let conv = ConversationStore.shared.currentConversation,
              let docID = conv.studyDocumentID else {
            presentStudyOpenFlow()
            return
        }

        // Warm project-folder *authorization* only (security scope). Do NOT rebind the
        // conversation / menu identity to the grant root — that mixes grant with the
        // current file's folder.
        let filePath: String = {
            if let path = StudyDocumentStore.shared.document(id: docID)?.displayPath, !path.isEmpty {
                return path
            }
            if let url = try? StudyDocumentStore.shared.resolvedURL(forID: docID) {
                return url.path
            }
            return ""
        }()
        if !filePath.isEmpty,
           let grant = StudyWorkspaceStore.shared.workspaceWithDirectoryAccess(coveringFilePath: filePath)
            ?? StudyWorkspaceStore.shared.primaryGrantedWorkspace() {
            _ = try? StudyWorkspaceStore.shared.folderURL(for: grant.id)
        }

        // Session workspace is only for agent / bookkeeping — file menu uses the file's parent.
        let sessionWSID = conv.activeStudyWorkspaceID
            ?? StudyWorkspaceStore.shared.defaultWorkspace().id

        // Options = same-directory siblings of the *current file* (not the grant root tree).
        var names = StudyWorkspaceStore.shared.listSiblingFileNames(ofDocumentID: docID, in: sessionWSID)

        if names.isEmpty {
            if let path = StudyDocumentStore.shared.document(id: docID)?.displayPath {
                names = [URL(fileURLWithPath: path).lastPathComponent]
            } else if let resolved = try? StudyDocumentStore.shared.resolvedURL(forID: docID) {
                names = [resolved.lastPathComponent]
            } else {
                names = [StudyDocumentStore.shared.document(id: docID)?.title ?? "当前文件"]
            }
        }

        let activeLeaf: String? = {
            if let path = StudyDocumentStore.shared.document(id: docID)?.displayPath, !path.isEmpty {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return try? StudyDocumentStore.shared.resolvedURL(forID: docID).lastPathComponent
        }()
        let menuTitle: String = {
            if let path = StudyDocumentStore.shared.document(id: docID)?.displayPath, !path.isEmpty {
                return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            }
            if let url = try? StudyDocumentStore.shared.resolvedURL(forID: docID) {
                return url.deletingLastPathComponent().lastPathComponent
            }
            return StudyWorkspaceStore.shared.workspace(id: sessionWSID)?.title ?? "文件"
        }()

        var items: [ConnectsMenuItem] = []
        for name in names {
            let fileName = (name as NSString).lastPathComponent
            let isPDF = fileName.lowercased().hasSuffix(".pdf")
            items.append(ConnectsMenuItem(
                title: fileName,
                icon: isPDF ? .book : .edit,
                isSelected: fileName == activeLeaf,
                longPressHandler: { [weak self] in
                    self?.presentWorkspaceFileActions(named: fileName, workspaceID: sessionWSID)
                },
                handler: { [weak self] in
                    self?.openSiblingFileNamed(fileName)
                }
            ))
        }
        let fallbackRect = CGRect(
            x: max(0, textEditorVC.view.bounds.midX - 60),
            y: textEditorVC.view.safeAreaInsets.top,
            width: 120,
            height: 40
        )
        let screenH = view.bounds.height > 1 ? view.bounds.height : UIScreen.main.bounds.height
        let anchor = sourceView
            ?? (pdfReaderVC.viewIfLoaded.flatMap { $0.isHidden ? nil : $0 })
            ?? (ebookReaderVC.viewIfLoaded.flatMap { $0.isHidden ? nil : $0 })
            ?? textEditorVC.view
        ConnectsMenu.present(
            from: self,
            title: menuTitle,
            items: items,
            sourceView: anchor,
            sourceRect: sourceView?.bounds ?? fallbackRect,
            maxHeight: min(480, max(240, screenH * 0.62)),
            menuWidth: 320,
            titleTap: { [weak self] in
                self?.presentWorkspaceSwitcher()
            },
            headerTrailingActions: [
                ConnectsMenuHeaderAction(icon: .folder, accessibilityLabel: "打开文件 / New File") { [weak self] in
                    self?.presentStudyOpenFlow()
                },
                ConnectsMenuHeaderAction(icon: .importFile, accessibilityLabel: "文件夹授权") { [weak self] in
                    self?.presentFolderWorkspacePicker()
                }
            ]
        )
    }

    /// When workspace bind fails, still allow title-tap to show the current file (no picker).
    private func presentSingleFileFallbackMenu(documentID: String, from sourceView: UIView?) {
        let doc = StudyDocumentStore.shared.document(id: documentID)
        let name = doc.flatMap { d -> String? in
            if let path = d.displayPath, !path.isEmpty {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return d.title.isEmpty ? nil : d.title
        } ?? "当前文件"
        let isPDF = name.lowercased().hasSuffix(".pdf") || doc?.kind == .pdf
        let anchor: UIView = sourceView ?? textEditorVC.view
        let rect = sourceView?.bounds ?? CGRect(x: anchor.bounds.midX, y: 40, width: 1, height: 1)
        ConnectsMenu.present(
            from: self,
            title: "文件",
            items: [
                ConnectsMenuItem(title: name, icon: isPDF ? .book : .edit, isSelected: true, handler: {}),
                ConnectsMenuItem(title: "打开…", icon: .folder) { [weak self] in
                    self?.presentStudyOpenFlow()
                }
            ],
            sourceView: anchor,
            sourceRect: rect
        )
    }

    /// Unified open entry from chat / chrome.
    func presentStudyFreeOpenPicker(from sourceView: UIView?, barButtonItem: UIBarButtonItem? = nil) {
        presentStudyOpenFlow()
    }

    /// Unified open: no project grant → folder picker; otherwise Files browser (New File).
    /// Do NOT skip the picker just because the conversation is bound to some non-default
    /// workspace (SPI_E2E / leaf DSP) — that wrongly blocked real folder authorization.
    private func presentStudyOpenFlow() {
        if StudyWorkspaceStore.shared.hasUsableFolderGrant() {
            presentStudyFilesBrowser()
            return
        }
        presentFolderWorkspacePicker()
    }

    private func presentStudyFilesBrowser() {
        let browser = StudyFilesBrowserController.make()
        browser.modalPresentationStyle = .fullScreen
        browser.onPick = { [weak self] url in
            self?.handleFreeOpenURL(url)
        }
        present(browser, animated: true)
    }

    private func presentFreeFilePicker(from sourceView: UIView?, barButtonItem: UIBarButtonItem? = nil) {
        presentStudyOpenFlow()
    }

    private func presentWorkspaceFileActions(named name: String, workspaceID: String) {
        ConnectsMenu.present(
            from: self,
            title: name,
            items: [
                ConnectsMenuItem(title: "重命名…", icon: .rename) { [weak self] in
                    self?.promptRenameFile(named: name, workspaceID: workspaceID)
                },
                ConnectsMenuItem(title: "删除", icon: .trash, isDestructive: true) { [weak self] in
                    self?.confirmDeleteFile(named: name, workspaceID: workspaceID)
                }
            ],
            sourceView: textEditorVC.view,
            sourceRect: CGRect(x: textEditorVC.view.bounds.midX, y: 40, width: 1, height: 1)
        )
    }

    private func promptRenameFile(named oldName: String, workspaceID: String) {
        let alert = UIAlertController(
            title: "重命名",
            message: "可改文件名或后缀，例如 notes.md → notes.txt",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = oldName
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            guard let self else { return }
            let raw = alert.textFields?.first?.text ?? ""
            do {
                let doc = try StudyWorkspaceStore.shared.renameFile(
                    from: oldName,
                    to: raw,
                    in: workspaceID
                )
                self.reloadAfterWorkspaceFileMutation(activeDocumentID: doc.id)
                ConnectsToast.show("已重命名为 \(doc.displayPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? doc.title)", in: self.view, duration: 1.4)
            } catch {
                ConnectsToast.show(error.localizedDescription, in: self.view, duration: 2.0)
            }
        })
        present(alert, animated: true)
    }

    private func confirmDeleteFile(named name: String, workspaceID: String) {
        let alert = UIAlertController(
            title: "删除文件？",
            message: "将从工作区文件夹中删除「\(name)」。此操作不可撤销。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let wasActive: Bool = {
                guard let docID = ConversationStore.shared.currentConversation?.studyDocumentID,
                      let path = StudyDocumentStore.shared.document(id: docID)?.displayPath else { return false }
                return URL(fileURLWithPath: path).lastPathComponent == name
            }()
            do {
                try StudyWorkspaceStore.shared.deleteFile(named: name, in: workspaceID)
                if wasActive {
                    let next = StudyWorkspaceStore.shared.listFileNames(in: workspaceID).first
                    if let next {
                        self.openWorkspaceFileNamed(next, workspaceID: workspaceID)
                    } else if let convID = ConversationStore.shared.currentConversationID {
                        ConversationStore.shared.updateConversation(id: convID) { draft in
                            draft.studyDocumentID = nil
                            draft.studyPageCaptureEnabled = false
                        }
                        self.forceRebindConversation()
                        self.ensureWorkspaceHasFileIfEmpty(workspaceID: workspaceID)
                    }
                } else {
                    self.forceRebindConversation()
                }
                ConnectsToast.show("已删除 \(name)", in: self.view, duration: 1.4)
            } catch {
                ConnectsToast.show(error.localizedDescription, in: self.view, duration: 2.0)
            }
        })
        present(alert, animated: true)
    }

    private func reloadAfterWorkspaceFileMutation(activeDocumentID: String) {
        if let convID = ConversationStore.shared.currentConversationID {
            ConversationStore.shared.updateConversation(id: convID) { draft in
                draft.studyDocumentID = activeDocumentID
                draft.studyPageCaptureEnabled = true
            }
        }
        forceRebindConversation()
    }

    private func forceRebindConversation() {
        boundDocumentID = nil
        bindCurrentConversation()
    }

    private func presentWorkspaceSwitcher() {
        var items: [ConnectsMenuItem] = []
        let store = StudyWorkspaceStore.shared
        if let grant = store.primaryGrantedWorkspace() {
            let pathHint: String = {
                if let abs = grant.absoluteRootPath, !abs.isEmpty { return abs }
                return grant.title
            }()
            items.append(ConnectsMenuItem(title: "当前授权：\(grant.title)", icon: .folder) { [weak self] in
                guard let self else { return }
                // Warm security scope only — do not bind conversation to the grant root.
                _ = try? StudyWorkspaceStore.shared.folderURL(for: grant.id)
                ConnectsToast.show("已授权：\(pathHint)", in: self.view, duration: 2.2)
            })
        }
        for ws in store.workspaces {
            let mark = ws.isDefault ? "（默认）" : ""
            if let g = store.primaryGrantedWorkspace(), ws.id == g.id { continue }
            items.append(ConnectsMenuItem(title: "\(ws.title)\(mark)", icon: .folder) { [weak self] in
                self?.activateWorkspace(ws.id)
            })
        }
        if store.hasUsableFolderGrant() {
            items.append(ConnectsMenuItem(title: "打开文件 / New File…", icon: .importFile) { [weak self] in
                self?.presentStudyFilesBrowser()
            })
        }
        items.append(ConnectsMenuItem(title: "文件夹授权", icon: .folder) { [weak self] in
            self?.presentFolderWorkspacePicker()
        })
        let title: String = {
            if let label = store.primaryGrantedFolderLabel() {
                return "工程 · \(label)"
            }
            return "切换工作区"
        }()
        ConnectsMenu.present(from: self, title: title, items: items)
    }

    /// Public entry: re-open the system folder picker for project authorization.
    func presentProjectFolderGrantPicker() {
        presentFolderWorkspacePicker()
    }

    private func activateWorkspace(_ workspaceID: String, preferredDocumentID: String? = nil) {
        guard let convID = ConversationStore.shared.currentConversationID else { return }
        // Light ghost cleanup only — never full-tree scan/register.
        _ = try? StudyWorkspaceStore.shared.scanAndSyncDocuments(workspaceID: workspaceID)

        if let preferred = preferredDocumentID {
            StudyWorkspaceStore.shared.addDocument(preferred, to: workspaceID)
        }

        var activeDoc = preferredDocumentID
        if activeDoc == nil {
            activeDoc = StudyWorkspaceStore.shared.primaryDocumentID(in: workspaceID)
        }

        ConversationStore.shared.updateConversation(id: convID) { draft in
            draft.studyWorkspaceID = workspaceID
            draft.studySessionKind = .workspace
            if let preferred = preferredDocumentID {
                draft.studyDocumentID = preferred
            } else if let current = draft.studyDocumentID,
                      StudyWorkspaceStore.shared.containsDocument(current, in: workspaceID) {
                draft.studyDocumentID = current
            } else {
                draft.studyDocumentID = activeDoc
            }
            draft.studyPageCaptureEnabled = draft.studyDocumentID != nil
            draft.studyAgentMode = StudyAgentMode.coerceForProduct(draft.studyAgentMode)
        }
        forceRebindConversation()
        chatVC.refreshStudyBindingChrome()

        // No file open yet → pick one inside the granted folder (New File page).
        // Do not deep-scan for a "first" file.
        if ConversationStore.shared.currentConversation?.studyDocumentID == nil {
            DispatchQueue.main.async { [weak self] in
                self?.presentStudyFilesBrowser()
            }
        }
    }

    private func activateDocumentStudy(documentID: String) {
        guard let convID = ConversationStore.shared.currentConversationID else { return }
        ConversationStore.shared.updateConversation(id: convID) { draft in
            draft.studyDocumentID = documentID
            draft.studyWorkspaceID = nil
            draft.studySessionKind = .document
            draft.studyPageCaptureEnabled = true
            draft.studyAgentMode = StudyAgentMode.coerceForProduct(draft.studyAgentMode)
        }
        forceRebindConversation()
        chatVC.refreshStudyBindingChrome()
    }

    private func handleFreeOpenURL(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let isDirectory: Bool = {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true { return true }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                return isDir.boolValue
            }
            return false
        }()
        if isDirectory {
            do {
                let ws = try StudyWorkspaceStore.shared.openFolderWorkspace(url: url, asProjectGrant: true)
                // Directory pick here is project grant — do not dump all subfolder chats into one bucket.
                StudyWorkspaceStore.shared.markAsProjectFolderGrant(ws.id)
                if let preferred = ConversationStore.shared.currentConversation?.studyDocumentID,
                   let path = StudyDocumentStore.shared.document(id: preferred)?.displayPath,
                   !path.isEmpty {
                    let folderWS = StudyWorkspaceStore.shared.conversationWorkspace(
                        forFileAt: URL(fileURLWithPath: path)
                    )
                    activateWorkspace(folderWS.id, preferredDocumentID: preferred)
                } else {
                    ConnectsToast.show("已授权：\(ws.title)。请打开该目录下的文件。", in: view, duration: 2.0)
                    presentStudyFilesBrowser()
                }
            } catch {
                ConnectsToast.show(error.localizedDescription, in: view, duration: 2.0)
            }
            return
        }
        // File → bind parent directory as workspace so the options menu lists siblings.
        openFileBindingParentWorkspace(fileURL: url)
    }

    /// Open one file and bind conversation identity to its **parent folder**
    /// (same-directory files share workspace chats; other folders stay separate).
    /// Project-folder grant is warmed for security scope only.
    private func openFileBindingParentWorkspace(fileURL: URL, showSwitcher: Bool = false) {
        do {
            let doc: StudyDocument
            if let existing = StudyDocumentStore.shared.documentMatchingPath(fileURL.path) {
                doc = existing
            } else {
                let accessing = fileURL.startAccessingSecurityScopedResource()
                defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
                doc = try StudyDocumentStore.shared.registerFileInPlace(
                    at: fileURL,
                    createEmptyIfNeeded: false
                )
            }

            // Authorization only — never use the grant root as conversation workspace id.
            if let grant = StudyWorkspaceStore.shared.workspaceWithDirectoryAccess(
                coveringFilePath: fileURL.path
            ) ?? StudyWorkspaceStore.shared.bookmarkedWorkspaceCovering(path: fileURL.path) {
                _ = try? StudyWorkspaceStore.shared.folderURL(for: grant.id)
            }

            let folderWS = StudyWorkspaceStore.shared.conversationWorkspace(forFileAt: fileURL)
            StudyWorkspaceStore.shared.addDocument(doc.id, to: folderWS.id)
            activateFolderConversation(workspace: folderWS, documentID: doc.id)

            if showSwitcher {
                DispatchQueue.main.async { [weak self] in
                    self?.presentWorkspaceFileMenu(from: nil)
                }
            }
        } catch {
            do {
                let doc = try StudyDocumentStore.shared.openDocument(from: fileURL, forceText: false)
                activateDocumentStudy(documentID: doc.id)
                if showSwitcher {
                    DispatchQueue.main.async { [weak self] in
                        self?.presentSingleFileFallbackMenu(documentID: doc.id, from: nil)
                    }
                }
            } catch {
                ConnectsToast.show(error.localizedDescription, in: view, duration: 2.0)
            }
        }
    }

    /// Attach the open file to a parent-folder workspace conversation.
    /// Switching folders selects that folder's existing chat (or creates one) so histories stay isolated.
    private func activateFolderConversation(workspace folderWS: StudyWorkspace, documentID: String) {
        let current = ConversationStore.shared.currentConversation
        let currentParent = current?.studyDocumentID.flatMap {
            StudyWorkspaceStore.shared.parentFolderPath(ofDocumentID: $0)
        }
        let targetParent = StudyWorkspaceStore.shared.parentFolderPath(ofDocumentID: documentID)
            ?? folderWS.absoluteRootPath.map { StudyWorkspaceStore.normalizedPath($0) }
        let sameFolder =
            current?.activeStudyWorkspaceID == folderWS.id
            || (currentParent != nil && currentParent == targetParent)

        if sameFolder {
            activateWorkspace(folderWS.id, preferredDocumentID: documentID)
            return
        }

        let peers = ConversationStore.shared.conversations(sharingParentFolderOfDocument: documentID)
        if let peer = peers.first {
            ConversationStore.shared.selectConversation(id: peer.id)
            activateWorkspace(folderWS.id, preferredDocumentID: documentID)
            return
        }

        let model = current?.model ?? .deepseekV4Pro
        _ = ConversationStore.shared.createConversation(
            model: model,
            projectID: current?.projectID,
            studyWorkspaceID: folderWS.id,
            studyDocumentID: documentID,
            studySessionKind: .workspace,
            studyPageCaptureEnabled: true,
            studyAgentMode: StudyAgentMode.coerceForProduct(current?.studyAgentMode ?? .ask)
        )
        forceRebindConversation()
        chatVC.refreshStudyBindingChrome()
    }

    private func presentFolderWorkspacePicker() {
        pendingFolderPick = true
        pendingFreeOpenPick = false
        pendingImportWorkspaceID = nil
        if let label = StudyWorkspaceStore.shared.primaryGrantedFolderLabel() {
            ConnectsToast.show("当前授权：\(label)\n请选择工程根目录", in: view, duration: 2.4)
        } else {
            ConnectsToast.show("请选择工程根目录（如 Workspace）", in: view, duration: 2.0)
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        // Full-screen feels like the main open step (first-time project grant).
        picker.modalPresentationStyle = .fullScreen
        present(picker, animated: true)
    }

    /// Open a leaf file in the *same directory as the current study file*.
    /// Project-folder grant is only used to warm security scope — never as the path root.
    private func openSiblingFileNamed(_ name: String) {
        let leaf = (name as NSString).lastPathComponent
        guard let nearID = ConversationStore.shared.currentConversation?.studyDocumentID else {
            ConnectsToast.show("没有当前文件。", in: view, duration: 1.6)
            return
        }
        let nearURL: URL? = {
            if let path = StudyDocumentStore.shared.document(id: nearID)?.displayPath, !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return try? StudyDocumentStore.shared.resolvedURL(forID: nearID)
        }()
        guard let nearURL else {
            ConnectsToast.show("无法定位当前文件目录。", in: view, duration: 1.8)
            return
        }

        // Authorization only: keep grant access alive if it covers this path.
        if let grant = StudyWorkspaceStore.shared.workspaceWithDirectoryAccess(coveringFilePath: nearURL.path)
            ?? StudyWorkspaceStore.shared.primaryGrantedWorkspace() {
            _ = try? StudyWorkspaceStore.shared.folderURL(for: grant.id)
        }

        let url = nearURL.deletingLastPathComponent().appendingPathComponent(leaf)
        do {
            if let existing = StudyDocumentStore.shared.documentMatchingPath(url.path) {
                if let wsID = ConversationStore.shared.currentConversation?.activeStudyWorkspaceID {
                    StudyWorkspaceStore.shared.addDocument(existing.id, to: wsID)
                }
                switchActiveDocument(to: existing.id)
                return
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                ConnectsToast.show("找不到文件：\(leaf)", in: view, duration: 2.0)
                return
            }
            if FileManager.default.isUbiquitousItem(at: url) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let doc = try StudyDocumentStore.shared.registerFileInPlace(at: url, createEmptyIfNeeded: false)
            if let wsID = ConversationStore.shared.currentConversation?.activeStudyWorkspaceID {
                StudyWorkspaceStore.shared.addDocument(doc.id, to: wsID)
            }
            switchActiveDocument(to: doc.id)
        } catch {
            ConnectsToast.show(error.localizedDescription, in: view, duration: 2.0)
        }
    }

    private func openWorkspaceFileNamed(_ name: String, workspaceID: String) {
        // Legacy entry points (delete-next / long-press) — same rule: sibling of current file.
        _ = workspaceID
        openSiblingFileNamed(name)
    }

    private func promptCreateFile(in workspaceID: String, firstFile: Bool = false) {
        let alert = UIAlertController(
            title: "新建文件",
            message: "任意后缀，例如 notes.md / top.v / a.html",
            preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = firstFile ? "Untitled.md" : "filename.ext" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建", style: .default) { [weak self] _ in
            let name = alert.textFields?.first?.text ?? ""
            do {
                let doc = try StudyWorkspaceStore.shared.createEmptyFile(named: name, in: workspaceID)
                self?.switchActiveDocument(to: doc.id)
            } catch {
                if let view = self?.view {
                    ConnectsToast.show(error.localizedDescription, in: view, duration: 2.0)
                }
            }
        })
        present(alert, animated: true)
    }

    func ensureWorkspaceHasFileIfEmpty(workspaceID: String? = nil) {
        let wsID = workspaceID
            ?? ConversationStore.shared.currentConversation?.activeStudyWorkspaceID
        guard let wsID else { return }
        _ = try? StudyWorkspaceStore.shared.scanAndSyncDocuments(workspaceID: wsID)
        guard StudyWorkspaceStore.shared.isFolderEmptyOfStudyFiles(wsID) else { return }
        presentStudyFilesBrowser()
    }

    private func presentImportIntoWorkspace(_ workspaceID: String) {
        pendingFolderPick = false
        pendingImportWorkspaceID = workspaceID
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [
                .item, .data, .text, .sourceCode, .pdf, .plainText
            ],
            asCopy: false
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func revertStudyCodeEditIfNeeded(forAssistantMessageID id: String) {
        _ = codeEditCoordinator.revertForRetry(assistantMessageID: id)
    }

    func studyCodeDiffKeepAll() {
        let pending = WorkspaceEditSession.shared.files
        guard !pending.isEmpty else {
            codeEditCoordinator.keepAll()
            chatVC.refreshWorkspaceDiffBanner()
            return
        }
        // Always persist `after` and clear session — even when Diff UI was never opened
        // (Agent create_file / propose_edit path).
        for file in pending {
            try? StudyDocumentStore.shared.writeTextContent(file.after, for: file.documentID)
        }
        if codeEditCoordinator.isPresentingDiff {
            codeEditCoordinator.keepAll()
        }
        if let current = pending.first(where: {
            $0.documentID == ConversationStore.shared.currentConversation?.studyDocumentID
        }) {
            textEditorVC.applyResolvedDiffText(current.after)
        } else if let first = pending.first {
            textEditorVC.applyResolvedDiffText(first.after)
        }
        WorkspaceEditSession.shared.clear()
        chatVC.refreshWorkspaceDiffBanner()
        let n = pending.count
        ConnectsToast.show(n == 1 ? "Kept 1 file" : "Kept \(n) files", in: view, duration: 1.4)
    }

    func studyCodeDiffUndoAll() {
        let pending = WorkspaceEditSession.shared.files
        if codeEditCoordinator.isPresentingDiff {
            codeEditCoordinator.undoAll()
        }
        for file in pending {
            try? StudyDocumentStore.shared.writeTextContent(file.before, for: file.documentID)
            if file.documentID == boundDocumentID {
                textEditorVC.applyResolvedDiffText(file.before)
            }
        }
        WorkspaceEditSession.shared.clear()
        chatVC.refreshWorkspaceDiffBanner()
        if !pending.isEmpty {
            ConnectsToast.show("Undone", in: view, duration: 1.2)
        }
    }

    func studyCodeDiffReviewNext() {
        let current = ConversationStore.shared.currentConversation?.studyDocumentID
        if let next = WorkspaceEditSession.shared.nextReviewDocumentID(after: current) {
            studyCodeDiffOpen(documentID: next)
        } else if let first = WorkspaceEditSession.shared.files.first {
            studyCodeDiffOpen(documentID: first.documentID)
        }
    }

    /// Agent batch write finished — reload bound editor once (skip if Diff already owns the surface).
    private func scheduleCoalescedAgentEditorReload(documentIDs: [String]) {
        guard !documentIDs.isEmpty else { return }
        agentEditorReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let bound = self.boundDocumentID, documentIDs.contains(bound) else { return }
            if self.codeEditCoordinator.isPresentingDiff { return }
            guard let pending = WorkspaceEditSession.shared.pending(documentID: bound) else { return }
            // Only refresh the text editor surface for workspace Agent writes.
            if !self.textEditorVC.view.isHidden {
                self.textEditorVC.applyResolvedDiffText(pending.after)
            }
        }
        agentEditorReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func studyCodeDiffOpen(documentID: String) {
        guard let pending = WorkspaceEditSession.shared.pending(documentID: documentID) else {
            switchActiveDocument(to: documentID)
            return
        }
        if boundDocumentID != documentID {
            switchActiveDocument(to: documentID)
        }
        if chatPanelStage == .full {
            applyChatPanelStage(.half, animated: true)
        }
        // Cumulative Diff: frozen session baseline → latest after (multi-round agent safe).
        if codeEditCoordinator.presentCumulativeSessionDiff(documentID: documentID) {
            chatVC.refreshWorkspaceDiffBanner()
            return
        }
        let proposal = CodeEditProposal(
            rangeKind: .full,
            replacement: pending.after,
            displayContent: "（Review \(pending.fileName)）",
            targetPath: pending.fileName
        )
        if textEditorVC.aiEditSnapshot().text != pending.before {
            textEditorVC.applyResolvedDiffText(pending.before)
        }
        _ = codeEditCoordinator.presentProposal(proposal, assistantMessageID: "")
        chatVC.refreshWorkspaceDiffBanner()
    }
}

extension StudyShellViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if pendingFreeOpenPick {
            pendingFreeOpenPick = false
            handleFreeOpenURL(url)
            return
        }
        if pendingFolderPick {
            pendingFolderPick = false
            let preferredDoc = ConversationStore.shared.currentConversation?.studyDocumentID
            do {
                let ws = try StudyWorkspaceStore.shared.openFolderWorkspace(url: url, asProjectGrant: true)
                UserDefaults.standard.set(true, forKey: "Connects.hasProjectFolderGrant")
                StudyWorkspaceStore.shared.markAsProjectFolderGrant(ws.id)
                // Grant ≠ conversation folder. Keep chats scoped to the open file's parent.
                if let preferredDoc,
                   let path = StudyDocumentStore.shared.document(id: preferredDoc)?.displayPath,
                   !path.isEmpty {
                    let folderWS = StudyWorkspaceStore.shared.conversationWorkspace(
                        forFileAt: URL(fileURLWithPath: path)
                    )
                    StudyWorkspaceStore.shared.addDocument(preferredDoc, to: folderWS.id)
                    activateWorkspace(folderWS.id, preferredDocumentID: preferredDoc)
                } else if let preferredDoc {
                    activateDocumentStudy(documentID: preferredDoc)
                }
                if StudyWorkspaceStore.isOverlyBroadFolder(url) {
                    ConnectsToast.show(
                        "已授权。建议选具体工程文件夹（不要选整个 iCloud），选项栏只列同目录文件。",
                        in: view,
                        duration: 3.0
                    )
                } else {
                    ConnectsToast.show("已授权：\(ws.title)", in: view, duration: 1.6)
                }
                // Do not auto-reopen the file menu here — listing may still fail and
                // would bounce straight back into the folder picker.
            } catch {
                ConnectsToast.show(error.localizedDescription, in: view, duration: 2.0)
            }
            return
        }
        if let wsID = pendingImportWorkspaceID {
            pendingImportWorkspaceID = nil
            do {
                let doc = try StudyWorkspaceStore.shared.importFile(from: url, into: wsID)
                switchActiveDocument(to: doc.id)
            } catch {
                ConnectsToast.show(error.localizedDescription, in: view, duration: 2.0)
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingFolderPick = false
        pendingImportWorkspaceID = nil
        pendingFreeOpenPick = false
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

// MARK: - Hardware keyboard shortcuts (iPad ⌘ long-press HUD)

extension StudyShellViewController {
    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        var cmds: [UIKeyCommand] = [
            makeKeyCommand(input: "\r", modifiers: .command, action: #selector(shortcutSend), title: "发送消息")
        ]
        guard isReaderVisible else { return cmds }

        // Panel resize: primary axis matches layout; opposite axis also maps so rotate stays usable.
        cmds += [
            makeKeyCommand(input: UIKeyCommand.inputUpArrow, modifiers: .command,
                           action: #selector(shortcutPanelArrowUp), title: "扩大 AI 面板（竖屏）"),
            makeKeyCommand(input: UIKeyCommand.inputDownArrow, modifiers: .command,
                           action: #selector(shortcutPanelArrowDown), title: "缩小 AI 面板（竖屏）"),
            makeKeyCommand(input: UIKeyCommand.inputLeftArrow, modifiers: .command,
                           action: #selector(shortcutPanelArrowLeft), title: "扩大 AI 面板（横屏）"),
            makeKeyCommand(input: UIKeyCommand.inputRightArrow, modifiers: .command,
                           action: #selector(shortcutPanelArrowRight), title: "缩小 AI 面板（横屏）"),
            // ⌘J — not ⌘` (system window cycle) or ⌘Q (system Quit on Mac).
            makeKeyCommand(input: "j", modifiers: .command, action: #selector(shortcutToggleFocus), title: "切换代码 / AI 输入"),
            makeKeyCommand(input: "1", modifiers: .command, action: #selector(shortcutFocusCode), title: "编辑代码"),
            makeKeyCommand(input: "2", modifiers: .command, action: #selector(shortcutFocusAI), title: "聚焦 AI 输入"),
            makeKeyCommand(input: "s", modifiers: .command, action: #selector(shortcutSave), title: "保存文档"),
            // Code editor zoom (VS Code–style). Multiple + bindings cover = / Shift+= / numpad.
            makeKeyCommand(input: "=", modifiers: .command, action: #selector(shortcutCodeFontLarger), title: "增大代码字号"),
            makeKeyCommand(input: "+", modifiers: .command, action: #selector(shortcutCodeFontLarger), title: "增大代码字号"),
            makeKeyCommand(input: "+", modifiers: [.command, .shift], action: #selector(shortcutCodeFontLarger), title: "增大代码字号"),
            makeKeyCommand(input: "-", modifiers: .command, action: #selector(shortcutCodeFontSmaller), title: "减小代码字号"),
            makeKeyCommand(input: "_", modifiers: [.command, .shift], action: #selector(shortcutCodeFontSmaller), title: "减小代码字号"),
            makeKeyCommand(input: "m", modifiers: .command, action: #selector(shortcutToggleCodeEditMode), title: "切换阅读 / 编辑")
        ]
        return cmds
    }

    private func makeKeyCommand(input: String,
                                modifiers: UIKeyModifierFlags,
                                action: Selector,
                                title: String) -> UIKeyCommand {
        if #available(iOS 13.0, *) {
            let cmd = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
            if #available(iOS 15.0, *) {
                cmd.wantsPriorityOverSystemBehavior = true
            }
            return cmd
        }
        let cmd = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
        cmd.discoverabilityTitle = title
        return cmd
    }

    @objc private func shortcutPanelArrowUp() {
        // Portrait primary: expand. Landscape fallback: same expand (universal).
        shortcutExpandAI()
    }

    @objc private func shortcutPanelArrowDown() {
        shortcutShrinkAI()
    }

    @objc private func shortcutPanelArrowLeft() {
        // Landscape primary: expand. Portrait fallback: same expand (universal).
        shortcutExpandAI()
    }

    @objc private func shortcutPanelArrowRight() {
        shortcutShrinkAI()
    }

    @objc private func shortcutExpandAI() {
        guard isReaderVisible else { return }
        stepPanelTowardAI()
    }

    @objc private func shortcutShrinkAI() {
        guard isReaderVisible else { return }
        stepPanelTowardReading()
    }

    @objc private func shortcutToggleFocus() {
        guard isReaderVisible else {
            chatVC.focusComposerFromShortcut()
            return
        }
        // Prefer "where is the user working" over bare composer first-responder:
        // after panel taps / resize the composer often loses focus while still on AI,
        // and code read-mode is not first-responder — both used to send ⌘J the wrong way.
        if isWorkingInCodeEditor {
            shortcutFocusAI()
        } else {
            focusActiveReaderForEditing()
        }
    }

    @objc private func shortcutFocusCode() {
        guard isReaderVisible else { return }
        focusActiveReaderForEditing()
    }

    /// Code side is the active surface. Composer focus always wins (edit-mode flag alone
    /// can stay true after tapping into AI, which made ⌘J look like a no-op).
    private var isWorkingInCodeEditor: Bool {
        if chatVC.isComposerFirstResponder { return false }
        switch activeReaderKind {
        case .text:
            return textEditorVC.isCodeEditorFirstResponder || textEditorVC.isInEditMode
        case .markdown:
            return markdownReaderVC.isMarkdownEditorFirstResponder
        case .pdf, .ebook:
            return false
        }
    }

    @objc private func shortcutFocusAI() {
        guard isReaderVisible else {
            chatVC.focusComposerFromShortcut()
            return
        }
        // Leave code edit mode so the next ⌘J / ⌘1 clearly re-enters editing.
        if activeReaderKind == .text, textEditorVC.isInEditMode {
            textEditorVC.leaveEditModeFromKeyboardShortcut()
        }
        chatVC.prepareForStudyPanelControlTap()
        if chatPanelStage == .collapsed {
            applyChatPanelStage(.half, animated: true, focusComposerAfter: true)
        } else {
            chatVC.focusComposerFromShortcut()
        }
    }

    @objc private func shortcutSave() {
        guard isReaderVisible else { return }
        switch activeReaderKind {
        case .text:
            textEditorVC.saveFromKeyboardShortcut()
        case .markdown:
            markdownReaderVC.saveFromKeyboardShortcut()
        case .pdf, .ebook:
            ConnectsToast.show("阅读页无需文本保存", in: view, duration: 1.0)
        }
    }

    @objc private func shortcutCodeFontLarger() {
        guard isReaderVisible, activeReaderKind == .text else { return }
        textEditorVC.adjustFontSizeFromKeyboardShortcut(by: 1)
    }

    @objc private func shortcutCodeFontSmaller() {
        guard isReaderVisible, activeReaderKind == .text else { return }
        textEditorVC.adjustFontSizeFromKeyboardShortcut(by: -1)
    }

    @objc private func shortcutToggleCodeEditMode() {
        guard isReaderVisible, activeReaderKind == .text else { return }
        textEditorVC.toggleEditModeFromKeyboardShortcut()
    }

    @objc private func shortcutSend() {
        if isReaderVisible, chatPanelStage == .collapsed {
            applyChatPanelStage(.half, animated: true, focusComposerAfter: false)
        }
        chatVC.sendFromKeyboardShortcut()
    }

    private func focusActiveReaderForEditing() {
        chatVC.dismissComposerKeyboard()
        view.endEditing(true)
        switch activeReaderKind {
        case .text:
            textEditorVC.focusForKeyboardEditing()
        case .markdown:
            markdownReaderVC.focusForKeyboardEditing()
        case .pdf, .ebook:
            ConnectsToast.show("阅读页不支持键盘编辑", in: view, duration: 1.2)
        }
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
