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
    private let dividerView = UIView()
    private let collapseStrip = UIButton(type: .system)

    private var chatWidthConstraint: NSLayoutConstraint!
    private var portraitChatHeightConstraint: NSLayoutConstraint!
    private var chatLandscapeConstraints: [NSLayoutConstraint] = []
    private var chatPortraitConstraints: [NSLayoutConstraint] = []
    private var chatNavTopInHost: NSLayoutConstraint!
    private var landscapeStripOnTrailing: NSLayoutConstraint!
    private var landscapeStripOnChatLeading: NSLayoutConstraint!
    private var collapseStripLandscapeCenterY: NSLayoutConstraint!
    private var collapseStripPortraitCenterX: NSLayoutConstraint!
    private var collapseStripPortraitCenterY: NSLayoutConstraint!
    private var collapseStripWidthConstraint: NSLayoutConstraint!
    private var collapseStripHeightConstraint: NSLayoutConstraint!

    private var landscapeDividerPan: UIPanGestureRecognizer!
    private var loadGeneration: UInt = 0
    private var boundDocumentID: String?
    private var boundConversationID: String?
    private var isReaderVisible = false
    private var isChatCollapsed = false
    private var isPortraitMode = false
    private var splitRatio: CGFloat
    private let collapsedChatWidth: CGFloat = 18
    private let collapsedChatHeight: CGFloat = 18
    private let landscapeStripSize = CGSize(width: 14, height: 32)
    private let portraitStripSize = CGSize(width: 34, height: 14)
    private let collapseStripPortraitTopExpanded: CGFloat = 10
    private let collapseStripPortraitTopCollapsed: CGFloat = 9
    private let portraitChatTopChromeHeight: CGFloat = 26
    private let compactChatBreakpoint: CGFloat = 520
    private let minChatWidth: CGFloat = 220
    private let halfPortraitChatRatio: CGFloat = 0.52

    private var panStartChatWidth: CGFloat = 0

    var onToggleSidebar: (() -> Void)?

    init(chatNav: UINavigationController, chatVC: ChatViewController) {
        self.chatNav = chatNav
        self.chatVC = chatVC
        let saved = UserDefaults.standard.object(forKey: "connects_study_split_ratio") as? Double
        splitRatio = CGFloat(saved ?? 0.38)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DSTheme.c.background
        chatHost.clipsToBounds = true
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
        chatHost.addSubview(chatNav.view)
        chatNav.view.translatesAutoresizingMaskIntoConstraints = false
        pdfReaderVC.view.translatesAutoresizingMaskIntoConstraints = false

        dividerView.backgroundColor = DSTheme.c.divider
        styleCollapseStrip()

        collapseStrip.addTarget(self, action: #selector(toggleChatCollapse), for: .touchUpInside)

        chatWidthConstraint = chatHost.widthAnchor.constraint(equalToConstant: 320)
        portraitChatHeightConstraint = chatHost.heightAnchor.constraint(equalToConstant: 0)
        landscapeStripOnTrailing = collapseStrip.centerXAnchor.constraint(
            equalTo: view.trailingAnchor,
            constant: -9
        )
        landscapeStripOnChatLeading = collapseStrip.centerXAnchor.constraint(
            equalTo: chatHost.leadingAnchor,
            constant: 10
        )
        collapseStripLandscapeCenterY = collapseStrip.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        collapseStripPortraitCenterX = collapseStrip.centerXAnchor.constraint(equalTo: chatHost.centerXAnchor)
        collapseStripPortraitCenterY = collapseStrip.centerYAnchor.constraint(
            equalTo: chatHost.topAnchor,
            constant: collapseStripPortraitTopExpanded
        )
        collapseStripWidthConstraint = collapseStrip.widthAnchor.constraint(
            equalToConstant: landscapeStripSize.width
        )
        collapseStripHeightConstraint = collapseStrip.heightAnchor.constraint(
            equalToConstant: landscapeStripSize.height
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

            chatNav.view.leadingAnchor.constraint(equalTo: chatHost.leadingAnchor),
            chatNav.view.trailingAnchor.constraint(equalTo: chatHost.trailingAnchor),
            chatNav.view.bottomAnchor.constraint(equalTo: chatHost.bottomAnchor)
        ])

        chatNavTopInHost = chatNav.view.topAnchor.constraint(equalTo: chatHost.topAnchor)
        chatNavTopInHost.isActive = true
        collapseStripLandscapeCenterY.isActive = true
        landscapeStripOnTrailing.isActive = true
        collapseStripPortraitCenterX.isActive = false
        collapseStripPortraitCenterY.isActive = false

        landscapeDividerPan = UIPanGestureRecognizer(target: self, action: #selector(handleLandscapeDividerPan(_:)))
        dividerView.addGestureRecognizer(landscapeDividerPan)
        dividerView.isUserInteractionEnabled = true

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let portrait = view.bounds.height > view.bounds.width
        var rotationSnapshot: StudyProgress?
        if portrait != isPortraitMode {
            rotationSnapshot = pdfReaderVC.captureReadingProgress()
            isPortraitMode = portrait
            pdfReaderVC.prepareForShellLayoutChange()
            applyLayoutMode()
            UIView.animate(withDuration: 0.25) {
                self.syncCollapseStripLayout()
                self.view.layoutIfNeeded()
            }
        }
        if isReaderVisible {
            if isPortraitMode {
                updatePortraitOverlay()
            } else {
                updateLandscapeOverlay()
            }
        }
        if let snapshot = rotationSnapshot {
            view.layoutIfNeeded()
            pdfReaderVC.restoreReadingProgress(snapshot)
        }
        postChatWidthNotification()
        if isReaderVisible {
            bringChromeToFront()
        }
    }

    private func setChatOnlyLayout(_ chatOnly: Bool) {
        NSLayoutConstraint.deactivate(chatLandscapeConstraints)
        NSLayoutConstraint.deactivate(chatPortraitConstraints)
        if chatOnly {
            readerHost.isHidden = true
            dividerView.isHidden = true
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

    private func syncCollapseStripLayout() {
        guard isReaderVisible else {
            collapseStrip.isHidden = true
            return
        }
        collapseStrip.isHidden = false
        let portrait = isPortraitMode
        let chatMounted = chatHost.superview != nil
        collapseStripPortraitCenterX.isActive = portrait && chatMounted
        collapseStripPortraitCenterY.isActive = portrait && chatMounted
        collapseStripLandscapeCenterY.isActive = !portrait
        landscapeStripOnTrailing.isActive = !portrait && !chatMounted
        landscapeStripOnChatLeading.isActive = !portrait && chatMounted
        if portrait && chatMounted {
            collapseStripWidthConstraint.constant = portraitStripSize.width
            collapseStripHeightConstraint.constant = portraitStripSize.height
            collapseStripPortraitCenterY.constant = isChatCollapsed
                ? collapseStripPortraitTopCollapsed
                : collapseStripPortraitTopExpanded
            chatNavTopInHost.constant = isChatCollapsed ? 0 : portraitChatTopChromeHeight
            chatHost.clipsToBounds = !isChatCollapsed
        } else {
            collapseStripWidthConstraint.constant = landscapeStripSize.width
            collapseStripHeightConstraint.constant = landscapeStripSize.height
            chatNavTopInHost.constant = 0
            chatHost.clipsToBounds = true
        }
        styleCollapseStrip()
    }

    private func syncLandscapeDividerPan() {
        landscapeDividerPan.isEnabled = isReaderVisible && !isPortraitMode && !isChatCollapsed
    }

    private func bringChromeToFront() {
        view.bringSubviewToFront(readerHost)
        dividerView.isHidden = isPortraitMode
        view.bringSubviewToFront(chatHost)
        if !isPortraitMode, !isChatCollapsed {
            view.bringSubviewToFront(dividerView)
        }
        view.bringSubviewToFront(collapseStrip)
    }

    private func styleStripButton(_ button: UIButton) {
        let accent = DSTheme.c.accent
        button.tintColor = accent.withAlphaComponent(0.95)
        button.backgroundColor = accent.withAlphaComponent(0.38)
        button.layer.cornerRadius = 5
        button.layer.borderWidth = 0
        button.layer.shadowOpacity = 0
        button.imageEdgeInsets = UIEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
    }

    private func styleCollapseStrip() {
        let kind: ActionIconFactory.Kind
        if isPortraitMode {
            kind = isChatCollapsed ? .chevronUp : .chevronDown
        } else {
            kind = isChatCollapsed ? .chevronLeft : .chevronRight
        }
        collapseStrip.setImage(ActionIconFactory.image(kind, pointSize: 11), for: .normal)
        styleStripButton(collapseStrip)
        collapseStrip.accessibilityLabel = isChatCollapsed ? "展开 AI 对话" : "收起 AI 对话"
    }

    @objc private func themeChanged() {
        view.backgroundColor = DSTheme.c.background
        chatHost.backgroundColor = DSTheme.c.background
        dividerView.backgroundColor = DSTheme.c.divider
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

    private func applyLayoutMode() {
        if !isReaderVisible {
            setChatOnlyLayout(true)
            mountChatFullScreen()
            chatNav.view.isHidden = false
            return
        }

        setChatOnlyLayout(false)
        pdfReaderVC.setSidebarButtonHidden(false)
        chatVC.setStudyChrome(.documentReader)

        if isPortraitMode {
            mountChatInPortraitOverlay()
            updatePortraitOverlay()
        } else {
            mountChatInLandscapeOverlay()
            updateLandscapeOverlay()
        }
        chatVC.refreshStudyComposerLayout()
        syncCollapseStripLayout()
        syncLandscapeDividerPan()
        bringChromeToFront()
    }

    private func mountChatFullScreen() {
        NSLayoutConstraint.deactivate(chatPortraitConstraints)
        NSLayoutConstraint.deactivate(chatLandscapeConstraints)
        if chatHost.superview !== view {
            chatHost.removeFromSuperview()
            view.addSubview(chatHost)
            chatHost.translatesAutoresizingMaskIntoConstraints = false
        }
        if dividerView.superview === view {
            dividerView.removeFromSuperview()
        }
        chatWidthConstraint.isActive = false
        portraitChatHeightConstraint.isActive = false
        chatLandscapeConstraints = [
            chatHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chatHost.topAnchor.constraint(equalTo: view.topAnchor),
            chatHost.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]
        NSLayoutConstraint.activate(chatLandscapeConstraints)
        chatHost.layer.shadowOpacity = 0
        ensureChatNavInHost()
        syncCollapseStripLayout()
    }

    private func mountChatInLandscapeOverlay() {
        NSLayoutConstraint.deactivate(chatPortraitConstraints)
        portraitChatHeightConstraint.isActive = false
        attachChatHostToViewIfNeeded()
        chatWidthConstraint.isActive = true
        NSLayoutConstraint.deactivate(chatLandscapeConstraints)
        let hairline = 1 / UIScreen.main.scale
        chatLandscapeConstraints = [
            chatHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chatHost.topAnchor.constraint(equalTo: view.topAnchor),
            chatHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            chatWidthConstraint,
            dividerView.trailingAnchor.constraint(equalTo: chatHost.leadingAnchor),
            dividerView.topAnchor.constraint(equalTo: view.topAnchor),
            dividerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dividerView.widthAnchor.constraint(equalToConstant: hairline)
        ]
        NSLayoutConstraint.activate(chatLandscapeConstraints)
        chatHost.layer.shadowColor = UIColor.black.cgColor
        chatHost.layer.shadowOpacity = isChatCollapsed ? 0 : 0.08
        chatHost.layer.shadowRadius = 8
        chatHost.layer.shadowOffset = CGSize(width: -2, height: 0)
        ensureChatNavInHost()
        syncCollapseStripLayout()
    }

    private func mountChatInPortraitOverlay() {
        NSLayoutConstraint.deactivate(chatLandscapeConstraints)
        chatWidthConstraint.isActive = false
        attachChatHostToViewIfNeeded()
        if dividerView.superview === view {
            dividerView.removeFromSuperview()
        }
        portraitChatHeightConstraint.isActive = true
        NSLayoutConstraint.deactivate(chatPortraitConstraints)
        chatPortraitConstraints = [
            chatHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chatHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            portraitChatHeightConstraint
        ]
        NSLayoutConstraint.activate(chatPortraitConstraints)
        chatHost.layer.shadowColor = UIColor.black.cgColor
        chatHost.layer.shadowOpacity = isChatCollapsed ? 0 : 0.08
        chatHost.layer.shadowRadius = 8
        chatHost.layer.shadowOffset = CGSize(width: 0, height: -2)
        ensureChatNavInHost()
        syncCollapseStripLayout()
        syncLandscapeDividerPan()
    }

    private func attachChatHostToViewIfNeeded() {
        if chatHost.superview !== view {
            chatHost.removeFromSuperview()
            view.addSubview(chatHost)
            chatHost.translatesAutoresizingMaskIntoConstraints = false
        }
        if dividerView.superview !== view {
            dividerView.removeFromSuperview()
            view.addSubview(dividerView)
            dividerView.translatesAutoresizingMaskIntoConstraints = false
        }
    }

    private func ensureChatNavInHost() {
        guard chatNav.view.superview !== chatHost else { return }
        chatNav.view.removeFromSuperview()
        chatHost.addSubview(chatNav.view)
        chatNav.view.translatesAutoresizingMaskIntoConstraints = false
        if chatNavTopInHost == nil {
            chatNavTopInHost = chatNav.view.topAnchor.constraint(equalTo: chatHost.topAnchor)
        }
        NSLayoutConstraint.activate([
            chatNav.view.leadingAnchor.constraint(equalTo: chatHost.leadingAnchor),
            chatNav.view.trailingAnchor.constraint(equalTo: chatHost.trailingAnchor),
            chatNavTopInHost,
            chatNav.view.bottomAnchor.constraint(equalTo: chatHost.bottomAnchor)
        ])
        chatNav.loadViewIfNeeded()
        chatVC.loadViewIfNeeded()
    }

    private func updateLandscapeOverlay() {
        guard isReaderVisible, !isPortraitMode else { return }
        let total = max(view.bounds.width, 1)

        if isChatCollapsed {
            chatWidthConstraint.constant = collapsedChatWidth
            chatNav.view.isHidden = true
            dividerView.isHidden = true
            chatHost.layer.shadowOpacity = 0
            syncCollapseStripLayout()
            syncLandscapeDividerPan()
            bringChromeToFront()
            return
        }

        chatNav.view.isHidden = false
        dividerView.isHidden = false
        chatHost.layer.shadowOpacity = 0.08
        let chatW = max(minChatWidth, min(total * splitRatio, total * 0.55))
        chatWidthConstraint.constant = chatW
        syncCollapseStripLayout()
        syncLandscapeDividerPan()
        bringChromeToFront()
    }

    private func updatePortraitOverlay() {
        guard isReaderVisible, isPortraitMode else { return }
        let total = max(view.bounds.height, 1)
        dividerView.isHidden = true

        if isChatCollapsed {
            portraitChatHeightConstraint.constant = collapsedChatHeight
            chatNav.view.isHidden = true
            chatHost.layer.shadowOpacity = 0
            syncCollapseStripLayout()
            syncLandscapeDividerPan()
            bringChromeToFront()
            return
        }

        chatNav.view.isHidden = false
        chatHost.layer.shadowOpacity = 0.08
        portraitChatHeightConstraint.constant = total * halfPortraitChatRatio
        syncCollapseStripLayout()
        chatVC.refreshStudyComposerLayout()
        syncLandscapeDividerPan()
        bringChromeToFront()
    }

    @objc private func toggleChatCollapse() {
        guard isReaderVisible else { return }
        if isPortraitMode {
            isChatCollapsed.toggle()
            updatePortraitOverlay()
        } else {
            isChatCollapsed.toggle()
            updateLandscapeOverlay()
        }
        chatVC.refreshStudyComposerLayout()
        syncLandscapeDividerPan()
        UIView.animate(withDuration: 0.22, animations: {
            self.syncCollapseStripLayout()
            self.view.layoutIfNeeded()
        })
        postChatWidthNotification()
    }

    @objc private func handleLandscapeDividerPan(_ gesture: UIPanGestureRecognizer) {
        guard isReaderVisible, !isPortraitMode, !isChatCollapsed else { return }
        let total = view.bounds.width
        switch gesture.state {
        case .began:
            panStartChatWidth = chatWidthConstraint.constant
        case .changed:
            let delta = gesture.translation(in: view).x
            let maxChat = total * 0.55
            let next = min(max(minChatWidth, panStartChatWidth - delta), maxChat)
            chatWidthConstraint.constant = next
            splitRatio = next / total
        case .ended, .cancelled:
            UserDefaults.standard.set(Double(splitRatio), forKey: "connects_study_split_ratio")
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
            width = collapsedChatWidth
        } else {
            width = chatWidthConstraint.constant
        }
        let compact = width < compactChatBreakpoint
        NotificationCenter.default.post(
            name: .connectsChatWidthDidChange,
            object: nil,
            userInfo: ["width": width, "compact": compact]
        )
    }
}

extension StudyShellViewController: StudyReadingContextProviding {
    var managesPortraitKeyboardLayout: Bool { false }

    func captureCurrentStudyPage() -> (label: String, text: String)? {
        guard isReaderVisible else { return nil }
        let label = pdfReaderVC.currentPageLabel()
        let text = pdfReaderVC.currentPageText() ?? ""
        return (label, text)
    }
}
