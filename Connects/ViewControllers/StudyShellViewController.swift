import UIKit

/// Hosts chat + optional PDF reader for study sessions.
/// Landscape: PDF full screen; AI chat overlays on the right.
/// Portrait: PDF full screen; AI chat overlays on the bottom.
final class StudyShellViewController: UIViewController {
    let chatNav: UINavigationController
    let chatVC: ChatViewController

    private let pdfReaderVC = PDFReaderViewController()
    private let readerHost = UIView()
    private let chatHost = UIView()
    private let collapseStrip = UIButton(type: .system)

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
    private var collapseStripLandscapeCenterX: NSLayoutConstraint!
    private var collapseStripLandscapeTrailingX: NSLayoutConstraint!
    private var collapseStripLandscapeCenterY: NSLayoutConstraint!
    private var collapseStripPortraitCenterX: NSLayoutConstraint!
    private var collapseStripPortraitSeamY: NSLayoutConstraint!
    private var collapseStripPortraitBottomY: NSLayoutConstraint!
    private var collapseStripWidthConstraint: NSLayoutConstraint!
    private var collapseStripHeightConstraint: NSLayoutConstraint!

    private var landscapeResizePan: UIPanGestureRecognizer!
    private var loadGeneration: UInt = 0
    private var boundDocumentID: String?
    private var boundConversationID: String?
    private var isReaderVisible = false
    private var isChatCollapsed = false
    private var isPortraitMode = false
    private var landscapeOverlayRatio: CGFloat
    private var portraitOverlayRatio: CGFloat
    private let floatingHandleSize = CGSize(width: 52, height: 22)
    private let collapsedHandleBottomInset: CGFloat = 10
    private let compactChatBreakpoint: CGFloat = 520
    private let minChatWidth: CGFloat = 220
    private let defaultLandscapeOverlayRatio: CGFloat = 0.4
    private let defaultPortraitOverlayRatio: CGFloat = 0.5
    private let maxOverlayRatio: CGFloat = 0.55
    /// Gap between seam handle bottom edge and first AI chrome row (portrait).
    private let studyPanelSeamGap: CGFloat = 8
    private let landscapeOverlayRatioKey = "connects_study_landscape_overlay_ratio"
    private let portraitOverlayRatioKey = "connects_study_portrait_overlay_ratio"

    private var panStartChatWidth: CGFloat = 0
    private var landscapeResizeActive = false
    private var didSeedPortraitMode = false
    private var isHandlingRotation = false

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
        let minRatio: CGFloat = 0.2
        if portrait {
            return min(max(ratio, minRatio), 0.55)
        }
        // Landscape defaults to 40%; clamp legacy saves that were too wide.
        let normalized = ratio > 0.45 ? 0.4 : ratio
        return min(max(normalized, minRatio), 0.55)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        collapseStrip.layer.zPosition = 100
        readerHost.clipsToBounds = false
        chatVC.studyContextProvider = self
        pdfReaderVC.onToggleSidebar = { [weak self] in
            self?.onToggleSidebar?()
        }

        addChild(pdfReaderVC)
        addChild(chatNav)
        pdfReaderVC.didMove(toParent: self)
        chatNav.didMove(toParent: self)

        [readerHost, collapseStrip].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        readerHost.addSubview(pdfReaderVC.view)
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

        landscapeStatusSpacerHeight = landscapeStatusSpacer.heightAnchor.constraint(equalToConstant: 0)
        portraitSeamSpacerHeight = portraitSeamSpacer.heightAnchor.constraint(equalToConstant: 0)

        styleCollapseStrip()
        syncChatPanelChrome()

        collapseStrip.addTarget(self, action: #selector(toggleChatCollapse), for: .touchUpInside)

        chatWidthConstraint = chatHost.widthAnchor.constraint(equalToConstant: 320)
        portraitChatHeightConstraint = chatHost.heightAnchor.constraint(equalToConstant: 0)
        collapseStripLandscapeCenterX = collapseStrip.centerXAnchor.constraint(
            equalTo: chatHost.leadingAnchor,
            constant: 0
        )
        collapseStripLandscapeTrailingX = collapseStrip.centerXAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.trailingAnchor,
            constant: 0
        )
        collapseStripLandscapeCenterY = collapseStrip.centerYAnchor.constraint(equalTo: chatHost.centerYAnchor)
        collapseStripPortraitCenterX = collapseStrip.centerXAnchor.constraint(equalTo: chatHost.centerXAnchor)
        collapseStripPortraitSeamY = collapseStrip.centerYAnchor.constraint(
            equalTo: chatHost.topAnchor,
            constant: 0
        )
        collapseStripPortraitBottomY = collapseStrip.centerYAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: 0
        )
        collapseStripWidthConstraint = collapseStrip.widthAnchor.constraint(
            equalToConstant: floatingHandleSize.width
        )
        collapseStripHeightConstraint = collapseStrip.heightAnchor.constraint(
            equalToConstant: floatingHandleSize.height
        )

        NSLayoutConstraint.activate([
            readerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerHost.topAnchor.constraint(equalTo: view.topAnchor),
            readerHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            collapseStripWidthConstraint,
            collapseStripHeightConstraint,

            pdfReaderVC.view.leadingAnchor.constraint(equalTo: readerHost.leadingAnchor),
            pdfReaderVC.view.trailingAnchor.constraint(equalTo: readerHost.trailingAnchor),
            pdfReaderVC.view.topAnchor.constraint(equalTo: readerHost.topAnchor),
            pdfReaderVC.view.bottomAnchor.constraint(equalTo: readerHost.bottomAnchor),

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
        collapseStripLandscapeCenterX.isActive = false
        collapseStripLandscapeTrailingX.isActive = false
        collapseStripLandscapeCenterY.isActive = false
        collapseStripPortraitCenterX.isActive = false
        collapseStripPortraitSeamY.isActive = false
        collapseStripPortraitBottomY.isActive = false

        landscapeResizePan = UIPanGestureRecognizer(target: self, action: #selector(handleLandscapeResizePan(_:)))
        chatHost.addGestureRecognizer(landscapeResizePan)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(conversationStoreDidUpdate),
            name: .conversationStoreDidUpdate,
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
        guard isReaderVisible else { return }

        let willBePortrait = size.height > size.width
        guard willBePortrait != isPortraitMode else { return }

        let pdfSnapshot = pdfReaderVC.captureReadingProgress()
        stashDepartingOverlayRatio()
        isHandlingRotation = true
        pdfReaderVC.beginShellRotation(keeping: pdfSnapshot)

        coordinator.animate(alongsideTransition: { _ in
            self.isPortraitMode = willBePortrait
            self.applyLayoutMode(for: size)
            UIView.performWithoutAnimation {
                self.syncCollapseStripLayout()
                self.updateChatPanelShadowPath()
                self.view.layoutIfNeeded()
                self.pdfReaderVC.updateDuringShellRotation()
                self.bringChromeToFront()
            }
        }, completion: { _ in
            self.isHandlingRotation = false
            UIView.performWithoutAnimation {
                self.view.layoutIfNeeded()
                self.syncCollapseStripLayout()
                self.updateChatPanelShadowPath()
            }
            self.pdfReaderVC.finishShellRotation(using: pdfSnapshot)
            self.postChatWidthNotification()
            self.bringChromeToFront()
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 1, view.bounds.height > 1 else { return }

        let portrait = view.bounds.height > view.bounds.width
        if !didSeedPortraitMode {
            didSeedPortraitMode = true
            isPortraitMode = portrait
            if isReaderVisible {
                applyLayoutMode()
            }
        } else if portrait != isPortraitMode, !isHandlingRotation {
            let pdfSnapshot = pdfReaderVC.captureReadingProgress()
            stashDepartingOverlayRatio()
            isPortraitMode = portrait
            pdfReaderVC.beginShellRotation(keeping: pdfSnapshot)
            applyLayoutMode()
            UIView.performWithoutAnimation {
                self.syncCollapseStripLayout()
                self.updateChatPanelShadowPath()
                self.view.layoutIfNeeded()
                self.pdfReaderVC.updateDuringShellRotation()
                self.bringChromeToFront()
            }
            pdfReaderVC.finishShellRotation(using: pdfSnapshot)
        }

        guard isReaderVisible, !isHandlingRotation else { return }

        if isPortraitMode {
            updatePortraitOverlay()
        } else {
            updateLandscapeOverlay()
        }
        updateChatPanelShadowPath()
        bringChromeToFront()
        postChatWidthNotification()
    }

    private func setChatOnlyLayout(_ chatOnly: Bool) {
        NSLayoutConstraint.deactivate(chatLandscapeConstraints)
        NSLayoutConstraint.deactivate(chatPortraitConstraints)
        if chatOnly {
            readerHost.isHidden = true
            collapseStrip.isHidden = true
            chatWidthConstraint.isActive = false
            portraitChatHeightConstraint.isActive = false
            chatVC.setStudyChrome(.none)
            pdfReaderVC.setSidebarButtonHidden(true)
            pdfReaderVC.setReaderSurfaceActive(false)
            pdfReaderVC.prepareForShellLayoutChange()
        } else {
            readerHost.isHidden = false
        }
    }


    private func stashDepartingOverlayRatio() {
        guard let captured = captureDepartingOverlayRatio() else { return }
        if isPortraitMode {
            portraitOverlayRatio = captured
            persistPortraitOverlayRatio()
        } else {
            landscapeOverlayRatio = captured
            persistLandscapeOverlayRatio()
        }
    }

    private func captureDepartingOverlayRatio() -> CGFloat? {
        guard isReaderVisible, !isChatCollapsed, !chatHost.isHidden else { return nil }
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
        let usePortrait = portrait ?? isPortraitMode
        let ratio = usePortrait ? portraitOverlayRatio : landscapeOverlayRatio
        return min(max(total * ratio, minChatWidth), total * maxOverlayRatio)
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

    private func floatingHandleDimensions() -> CGSize {
        if isPortraitMode {
            return floatingHandleSize
        }
        return CGSize(width: floatingHandleSize.height, height: floatingHandleSize.width)
    }

    private func syncCollapseStripLayout() {
        guard isReaderVisible else {
            collapseStrip.isHidden = true
            return
        }
        collapseStrip.isHidden = false
        let portrait = isPortraitMode
        let chatMounted = chatHost.superview === view && isReaderVisible
        let handle = floatingHandleDimensions()

        collapseStripWidthConstraint.constant = handle.width
        collapseStripHeightConstraint.constant = handle.height

        collapseStripPortraitCenterX.isActive = portrait && chatMounted
        collapseStripPortraitSeamY.isActive = portrait && chatMounted && !isChatCollapsed
        collapseStripPortraitBottomY.isActive = portrait && chatMounted && isChatCollapsed
        collapseStripLandscapeCenterY.isActive = !portrait && chatMounted
        collapseStripLandscapeCenterX.isActive = !portrait && chatMounted && !isChatCollapsed
        collapseStripLandscapeTrailingX.isActive = !portrait && chatMounted && isChatCollapsed

        if portrait && chatMounted {
            if isChatCollapsed {
                collapseStripPortraitBottomY.constant = -(handle.height / 2 + collapsedHandleBottomInset)
            } else {
                collapseStripPortraitSeamY.constant = 0
            }
        } else if chatMounted {
            if !isChatCollapsed {
                collapseStripLandscapeCenterX.constant = 0
            } else {
                collapseStripLandscapeTrailingX.constant = -(handle.width / 2 + collapsedHandleBottomInset)
            }
        }

        chatHost.clipsToBounds = false
        collapseStrip.transform = .identity
        styleCollapseStrip()
        syncStudyOverlayChrome()
    }

    private func syncLandscapeResizePan() {
        landscapeResizePan.isEnabled = isReaderVisible && !isPortraitMode && !isChatCollapsed
    }

    private func bringChromeToFront() {
        guard isReaderVisible else { return }
        view.bringSubviewToFront(chatHost)
        view.bringSubviewToFront(collapseStrip)
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

    private func styleFloatingHandle(_ button: UIButton) {
        let c = DSTheme.c
        let handle = floatingHandleDimensions()
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.tintColor = c.accent
        button.backgroundColor = c.surface
        button.layer.cornerRadius = min(handle.width, handle.height) / 2
        button.layer.borderWidth = 1 / UIScreen.main.scale
        button.layer.borderColor = c.border.cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.16
        button.layer.shadowRadius = 8
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.imageEdgeInsets = .zero
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    private func styleCollapseStrip() {
        let kind: ActionIconFactory.Kind
        if isPortraitMode {
            kind = isChatCollapsed ? .chevronUp : .chevronDown
        } else {
            kind = isChatCollapsed ? .chevronLeft : .chevronRight
        }
        collapseStrip.setImage(ActionIconFactory.image(kind, pointSize: 11), for: .normal)
        styleFloatingHandle(collapseStrip)
        collapseStrip.accessibilityLabel = isChatCollapsed ? "展开 AI 对话" : "收起 AI 对话"
    }

    @objc private func themeChanged() {
        view.backgroundColor = DSTheme.c.background
        syncChatPanelChrome()
        styleCollapseStrip()
    }

    @objc private func conversationStoreDidUpdate() {
        bindCurrentConversation()
    }

    func syncSidebarToggle(collapsed: Bool) {
        pdfReaderVC.updateSidebarToggle(collapsed: collapsed)
        if !isReaderVisible {
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
            pdfReaderVC.saveReadingProgressNow()
        }

        boundDocumentID = docID
        boundConversationID = convID
        loadGeneration &+= 1
        let gen = loadGeneration

        if let docID = docID {
            isReaderVisible = true
            if !wasInStudy || docChanged {
                isChatCollapsed = true
            }
        } else {
            isReaderVisible = false
            pdfReaderVC.pauseReading()
            isChatCollapsed = false
        }

        applyLayoutMode()

        if let docID = docID {
            let progress = StudyProgressStore.shared.progress(for: docID)
            let needsLoad = !pdfReaderVC.isLoaded(documentID: docID)
            if needsLoad {
                StudyDocumentStore.shared.touch(documentID: docID)
                pdfReaderVC.load(documentID: docID) { [weak self] ok in
                    guard let self = self, ok, self.loadGeneration == gen else { return }
                    self.commitReaderViewport(progress: progress, generation: gen)
                }
            } else {
                resumeReaderAfterConversationSwitch(generation: gen)
            }
        }
        guard gen == loadGeneration else { return }
        postChatWidthNotification()
    }

    private func commitReaderViewport(progress: StudyProgress?, generation: UInt) {
        guard loadGeneration == generation, isReaderVisible, !readerHost.isHidden else { return }
        pdfReaderVC.setReaderSurfaceActive(true)

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.loadGeneration == generation,
                  self.isReaderVisible, !self.readerHost.isHidden else { return }
            self.view.layoutIfNeeded()
            self.pdfReaderVC.realignVisibleViewport(using: progress)
        }
    }

    private func resumeReaderAfterConversationSwitch(generation: UInt) {
        guard loadGeneration == generation, isReaderVisible, !readerHost.isHidden else { return }
        pdfReaderVC.setReaderSurfaceActive(true)

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.loadGeneration == generation,
                  self.isReaderVisible, !self.readerHost.isHidden else { return }
            self.view.layoutIfNeeded()
            self.pdfReaderVC.resumeAfterConversationSwitch()
        }
    }

    private func applyLayoutMode(for size: CGSize? = nil) {
        if !isReaderVisible {
            setChatOnlyLayout(true)
            mountChatFullScreen()
            return
        }

        setChatOnlyLayout(false)
        pdfReaderVC.setSidebarButtonHidden(false)

        let layoutSize = layoutBoundsSize(for: size)
        if isPortraitMode {
            mountChatInPortraitOverlay(layoutHeight: layoutSize.height)
            updatePortraitOverlay(layoutHeight: layoutSize.height)
        } else {
            mountChatInLandscapeOverlay(layoutWidth: layoutSize.width)
            updateLandscapeOverlay(layoutWidth: layoutSize.width)
        }
        syncCollapseStripLayout()
        syncLandscapeResizePan()
        bringChromeToFront()
    }

    /// Single source of truth for study overlay chrome (spacers, chat mode, composer).
    private func syncStudyOverlayChrome() {
        chatVC.loadViewIfNeeded()
        guard isReaderVisible else {
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
        chatVC.refreshStudyComposerLayout()
    }

    /// Status bar (landscape) and seam handle (portrait) are explicit spacers — nav bar stays at y=0.
    private func applyStudyPanelSpacers(expanded: Bool) {
        let statusBarInset: CGFloat
        if isReaderVisible, !isPortraitMode, expanded {
            statusBarInset = view.safeAreaInsets.top
        } else {
            statusBarInset = 0
        }
        landscapeStatusSpacerHeight.constant = statusBarInset

        let seamInset: CGFloat
        if isReaderVisible, isPortraitMode, expanded {
            let handle = floatingHandleDimensions()
            seamInset = handle.height / 2 + studyPanelSeamGap
        } else {
            seamInset = 0
        }
        portraitSeamSpacerHeight.constant = seamInset
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
        syncCollapseStripLayout()
        view.bringSubviewToFront(chatHost)
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
        syncCollapseStripLayout()
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
        syncCollapseStripLayout()
        syncLandscapeResizePan()
    }

    private func attachChatHostToViewIfNeeded() {
        if chatHost.superview !== view {
            chatHost.removeFromSuperview()
            view.addSubview(chatHost)
            chatHost.translatesAutoresizingMaskIntoConstraints = false
        }
        view.bringSubviewToFront(chatHost)
        view.bringSubviewToFront(collapseStrip)
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

    private func updateLandscapeOverlay(layoutWidth: CGFloat? = nil) {
        guard isReaderVisible, !isPortraitMode else { return }
        let total = layoutWidth ?? max(view.bounds.width, 1)

        if isChatCollapsed {
            chatWidthConstraint.constant = 0
            chatHost.isHidden = true
            chatNav.view.isHidden = true
            syncChatPanelChrome()
            syncCollapseStripLayout()
            syncLandscapeResizePan()
            bringChromeToFront()
            return
        }

        chatHost.isHidden = false
        chatNav.view.isHidden = false
        let chatW = overlayLength(for: total)
        chatWidthConstraint.constant = chatW
        syncChatPanelChrome()
        syncCollapseStripLayout()
        syncLandscapeResizePan()
        bringChromeToFront()
    }

    private func updatePortraitOverlay(layoutHeight: CGFloat? = nil) {
        guard isReaderVisible, isPortraitMode else { return }
        let total = layoutHeight ?? max(view.bounds.height, 1)

        if isChatCollapsed {
            portraitChatHeightConstraint.constant = 0
            chatHost.isHidden = true
            chatNav.view.isHidden = true
            syncChatPanelChrome()
            syncCollapseStripLayout()
            syncLandscapeResizePan()
            bringChromeToFront()
            return
        }

        chatHost.isHidden = false
        chatNav.view.isHidden = false
        portraitChatHeightConstraint.constant = overlayLength(for: total)
        syncChatPanelChrome()
        syncCollapseStripLayout()
        syncLandscapeResizePan()
        bringChromeToFront()
    }

    @objc private func toggleChatCollapse() {
        guard isReaderVisible else { return }
        let collapsing = !isChatCollapsed
        if collapsing {
            chatVC.dismissComposerKeyboard()
        }
        if isPortraitMode {
            isChatCollapsed.toggle()
            updatePortraitOverlay()
        } else {
            isChatCollapsed.toggle()
            updateLandscapeOverlay()
        }
        syncLandscapeResizePan()
        syncChatPanelChrome()
        UIView.animate(withDuration: 0.22, animations: {
            self.syncCollapseStripLayout()
            self.updateChatPanelShadowPath()
            self.view.layoutIfNeeded()
        })
        postChatWidthNotification()
    }

    @objc private func handleLandscapeResizePan(_ gesture: UIPanGestureRecognizer) {
        guard isReaderVisible, !isPortraitMode, !isChatCollapsed else { return }
        let total = view.bounds.width
        switch gesture.state {
        case .began:
            let point = gesture.location(in: chatHost)
            guard point.x <= floatingHandleDimensions().width + 8 else {
                landscapeResizeActive = false
                return
            }
            landscapeResizeActive = true
            panStartChatWidth = chatWidthConstraint.constant
        case .changed:
            guard landscapeResizeActive else { return }
            let delta = gesture.translation(in: view).x
            let maxChat = total * maxOverlayRatio
            let next = min(max(minChatWidth, panStartChatWidth - delta), maxChat)
            chatWidthConstraint.constant = next
            landscapeOverlayRatio = next / total
        case .ended, .cancelled:
            guard landscapeResizeActive else { return }
            landscapeResizeActive = false
            landscapeOverlayRatio = chatWidthConstraint.constant / max(total, 1)
            persistLandscapeOverlayRatio()
            postChatWidthNotification()
        default:
            break
        }
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
        NotificationCenter.default.post(
            name: .connectsChatWidthDidChange,
            object: nil,
            userInfo: ["width": width, "compact": compact]
        )
    }
}

extension StudyShellViewController: StudyReadingContextProviding {
    func captureCurrentStudyPage() -> (label: String, text: String)? {
        guard isReaderVisible else { return nil }
        let label = pdfReaderVC.currentPageLabel()
        let text = pdfReaderVC.currentPageText() ?? ""
        return (label, text)
    }
}
