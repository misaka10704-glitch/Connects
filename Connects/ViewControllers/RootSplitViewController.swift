import UIKit

/// Root shell: chat/study is always full-bleed; conversation list is a left-edge overlay drawer
/// (compact Slide Over and wide iPad use the same logic).
final class RootSplitViewController: UIViewController {
    private let sidebarVC = SidebarViewController()
    private let chatNav: UINavigationController
    private let chatVC = ChatViewController()
    private let studyShell: StudyShellViewController

    private let sidebarContainer = UIView()
    private let divider = UIView()
    private let chatContainer = UIView()
    private let dimView = UIView()
    private let launchOverlay = UIView()
    private let launchLogoView = UIImageView()

    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarLeadingWide: NSLayoutConstraint!
    private var sidebarLeadingCompact: NSLayoutConstraint!
    private var chatLeadingWide: NSLayoutConstraint!
    private var chatLeadingCompact: NSLayoutConstraint!
    private var dividerWidthConstraint: NSLayoutConstraint!

    private var isSidebarCollapsed = true
    private var isCompactLayout = false
    private var isDrawerOpen = false
    private var lastNotifiedWidthBucket: Int = 0
    private var didDismissLaunchOverlay = false
    private var didPreloadChat = false
    private var studySessionActive = false

    /// Below this width → Slide Over / 侧拉网课模式.
    private let compactBreakpoint: CGFloat = 520

    init() {
        chatNav = UINavigationController(rootViewController: chatVC)
        studyShell = StudyShellViewController(chatNav: chatNav, chatVC: chatVC)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebarVC.delegate = self
        chatVC.delegate = self
        chatVC.onToggleSidebar = { [weak self] in
            self?.toggleSidebar()
        }
        studyShell.onToggleSidebar = { [weak self] in
            self?.toggleSidebar()
        }

        isSidebarCollapsed = UserDefaults.standard.bool(forKey: "connects_sidebar_collapsed")

        addChild(sidebarVC)
        addChild(studyShell)
        sidebarContainer.addSubview(sidebarVC.view)
        chatContainer.addSubview(studyShell.view)
        sidebarVC.didMove(toParent: self)
        studyShell.didMove(toParent: self)

        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        dimView.alpha = 0
        dimView.isHidden = true
        let tapDim = UITapGestureRecognizer(target: self, action: #selector(dimViewTapped))
        dimView.addGestureRecognizer(tapDim)

        [chatContainer, dimView, sidebarContainer, divider].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        // Drawer above chat; divider only used in wide mode.
        view.bringSubviewToFront(dimView)
        view.bringSubviewToFront(sidebarContainer)

        sidebarVC.view.translatesAutoresizingMaskIntoConstraints = false
        studyShell.view.translatesAutoresizingMaskIntoConstraints = false

        sidebarWidthConstraint = sidebarContainer.widthAnchor.constraint(
            equalToConstant: isSidebarCollapsed ? 0 : DSTheme.sidebarWidth
        )
        sidebarLeadingWide = sidebarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        sidebarLeadingCompact = sidebarContainer.leadingAnchor.constraint(
            equalTo: view.leadingAnchor,
            constant: -DSTheme.sidebarWidth
        )
        chatLeadingWide = chatContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor)
        chatLeadingCompact = chatContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        dividerWidthConstraint = divider.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)

        NSLayoutConstraint.activate([
            sidebarContainer.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarWidthConstraint,
            sidebarLeadingWide,

            sidebarVC.view.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebarVC.view.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebarVC.view.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            sidebarVC.view.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dividerWidthConstraint,

            chatContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chatContainer.topAnchor.constraint(equalTo: view.topAnchor),
            chatContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            chatLeadingWide,

            studyShell.view.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor),
            studyShell.view.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor),
            studyShell.view.topAnchor.constraint(equalTo: chatContainer.topAnchor),
            studyShell.view.bottomAnchor.constraint(equalTo: chatContainer.bottomAnchor),

            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        sidebarContainer.clipsToBounds = true
        applyThemeColors()
        setupLaunchOverlay()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(conversationStoreDidUpdate),
            name: .conversationStoreDidUpdate,
            object: nil
        )

        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        edge.edges = .left
        view.addGestureRecognizer(edge)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDrawerPan(_:)))
        sidebarContainer.addGestureRecognizer(pan)

        applyLayoutMode(animated: false)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        preloadChatIfNeeded()
        let studyNow = isStudySessionActive()
        if studyNow != studySessionActive {
            studySessionActive = studyNow
            if studyNow, isDrawerOpen {
                closeDrawer(animated: true)
            } else {
                applyLayoutMode(animated: false)
            }
        } else {
            studySessionActive = studyNow
        }
    }

    private func preloadChatIfNeeded() {
        guard !didPreloadChat else { return }
        didPreloadChat = true
        chatNav.loadViewIfNeeded()
        chatVC.loadViewIfNeeded()
        syncSidebarToggleUI(collapsed: isSidebarCollapsed)
        #if DEBUG
        ScrollStressHarness.scheduleIfRequested(on: chatVC)
        #endif
    }

    private func syncSidebarToggleUI(collapsed: Bool) {
        studyShell.syncSidebarToggle(collapsed: collapsed)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let compact = view.bounds.width > 0 && view.bounds.width < compactBreakpoint
        if compact != isCompactLayout {
            isCompactLayout = compact
            applyLayoutMode(animated: false)
        }
        // Notify only when width bucket changes (Slide Over drag), not every layout pass.
        let bucket = Int((view.bounds.width / 4).rounded()) * 4
        if bucket > 0, bucket != lastNotifiedWidthBucket {
            lastNotifiedWidthBucket = bucket
            NotificationCenter.default.post(
                name: .connectsChatWidthDidChange,
                object: nil,
                userInfo: ["width": view.bounds.width, "compact": isCompactLayout]
            )
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        view.setNeedsLayout()
    }

    @objc private func themeChanged() { applyThemeColors() }

    @objc private func conversationStoreDidUpdate() {
        let active = isStudySessionActive()
        guard active != studySessionActive else { return }
        studySessionActive = active
        if active, isDrawerOpen {
            closeDrawer(animated: true)
        } else {
            applyLayoutMode(animated: true)
        }
    }

    private func isStudySessionActive() -> Bool {
        ConversationStore.shared.currentConversation?.studyDocumentID != nil
    }

    private func usesOverlaySidebar() -> Bool {
        true
    }

    private func ensureOverlaySidebarConstraints() {
        sidebarLeadingWide.isActive = false
        chatLeadingWide.isActive = false
        sidebarLeadingCompact.isActive = true
        chatLeadingCompact.isActive = true
        chatLeadingCompact.constant = 0
        sidebarWidthConstraint.constant = DSTheme.sidebarWidth
        dividerWidthConstraint.constant = 0
        divider.isHidden = true
    }

    private func setupLaunchOverlay() {
        launchOverlay.translatesAutoresizingMaskIntoConstraints = false
        launchOverlay.backgroundColor = DSTheme.c.background
        launchOverlay.isUserInteractionEnabled = false

        launchLogoView.translatesAutoresizingMaskIntoConstraints = false
        launchLogoView.image = UIImage(named: "Logo-120")
        launchLogoView.contentMode = .scaleAspectFit
        launchOverlay.addSubview(launchLogoView)
        view.addSubview(launchOverlay)
        view.bringSubviewToFront(launchOverlay)

        NSLayoutConstraint.activate([
            launchOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            launchOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            launchOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            launchOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            launchLogoView.centerXAnchor.constraint(equalTo: launchOverlay.centerXAnchor),
            launchLogoView.centerYAnchor.constraint(equalTo: launchOverlay.centerYAnchor),
            launchLogoView.widthAnchor.constraint(equalToConstant: 120),
            launchLogoView.heightAnchor.constraint(equalToConstant: 120)
        ])

        // Safety net if chat bootstrap never reports ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.dismissLaunchOverlayIfNeeded()
        }
    }

    private func dismissLaunchOverlayIfNeeded() {
        guard !didDismissLaunchOverlay else { return }
        didDismissLaunchOverlay = true
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut], animations: {
            self.launchOverlay.alpha = 0
        }, completion: { _ in
            self.launchOverlay.isHidden = true
            self.launchOverlay.removeFromSuperview()
        })
    }

    private func applyThemeColors() {
        let c = DSTheme.c
        view.backgroundColor = c.background
        sidebarContainer.backgroundColor = c.sidebarBackground
        chatContainer.backgroundColor = c.background
        divider.backgroundColor = c.divider
        if isCompactLayout {
            sidebarContainer.layer.shadowColor = UIColor.black.cgColor
            sidebarContainer.layer.shadowOpacity = 0.28
            sidebarContainer.layer.shadowRadius = 10
            sidebarContainer.layer.shadowOffset = CGSize(width: 2, height: 0)
        } else {
            sidebarContainer.layer.shadowColor = UIColor.black.cgColor
            sidebarContainer.layer.shadowOpacity = 0.2
            sidebarContainer.layer.shadowRadius = 12
            sidebarContainer.layer.shadowOffset = CGSize(width: 3, height: 0)
        }
    }

    private func applyLayoutMode(animated: Bool) {
        studySessionActive = isStudySessionActive()
        ensureOverlaySidebarConstraints()

        if isCompactLayout {
            isDrawerOpen = false
            dimView.isHidden = true
            dimView.alpha = 0
            sidebarLeadingCompact.constant = -DSTheme.sidebarWidth
            isSidebarCollapsed = true
            syncSidebarToggleUI(collapsed: true)
            chatVC.setCompactChrome(true)
        } else {
            chatVC.setCompactChrome(false)
            sidebarLeadingCompact.constant = isDrawerOpen ? 0 : -DSTheme.sidebarWidth
            isSidebarCollapsed = !isDrawerOpen
            syncSidebarToggleUI(collapsed: isSidebarCollapsed)
            dimView.isHidden = !isDrawerOpen
            dimView.alpha = isDrawerOpen ? 1 : 0
        }
        applyThemeColors()
        let updates = { self.view.layoutIfNeeded() }
        if animated {
            UIView.animate(withDuration: 0.22, animations: updates)
        } else {
            updates()
        }
    }

    private func toggleSidebar() {
        if isDrawerOpen { closeDrawer() } else { openDrawer() }
    }

    private func openDrawer() {
        guard usesOverlaySidebar() else { return }
        ensureOverlaySidebarConstraints()
        sidebarVC.ensureListLoaded()
        isDrawerOpen = true
        isSidebarCollapsed = false
        dimView.isHidden = false
        sidebarLeadingCompact.constant = 0
        view.bringSubviewToFront(dimView)
        view.bringSubviewToFront(sidebarContainer)
        UIView.animate(withDuration: 0.22) {
            self.dimView.alpha = 1
            self.view.layoutIfNeeded()
        }
        syncSidebarToggleUI(collapsed: false)
    }

    @objc private func dimViewTapped() {
        closeDrawer(animated: true)
    }

    @objc private func closeDrawer(animated: Bool = true) {
        guard usesOverlaySidebar(), isDrawerOpen else { return }
        ensureOverlaySidebarConstraints()

        isDrawerOpen = false
        isSidebarCollapsed = true
        syncSidebarToggleUI(collapsed: true)

        if animated {
            UIView.animate(withDuration: 0.22, animations: {
                self.sidebarLeadingCompact.constant = -DSTheme.sidebarWidth
                self.dimView.alpha = 0
                self.view.layoutIfNeeded()
            }, completion: { _ in
                if !self.isDrawerOpen {
                    self.dimView.isHidden = true
                }
            })
        } else {
            sidebarLeadingCompact.constant = -DSTheme.sidebarWidth
            dimView.alpha = 0
            view.layoutIfNeeded()
            dimView.isHidden = true
        }
    }

    @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard usesOverlaySidebar() else { return }
        let t = gesture.translation(in: view).x
        switch gesture.state {
        case .began:
            ensureOverlaySidebarConstraints()
            dimView.isHidden = false
            view.bringSubviewToFront(dimView)
            view.bringSubviewToFront(sidebarContainer)
        case .changed:
            let x = min(0, max(-DSTheme.sidebarWidth, -DSTheme.sidebarWidth + t))
            sidebarLeadingCompact.constant = x
            let progress = (x + DSTheme.sidebarWidth) / DSTheme.sidebarWidth
            dimView.alpha = progress
            view.layoutIfNeeded()
        case .ended, .cancelled:
            let v = gesture.velocity(in: view).x
            if sidebarLeadingCompact.constant > -DSTheme.sidebarWidth * 0.45 || v > 500 {
                openDrawer()
            } else {
                isDrawerOpen = true // so closeDrawer runs
                closeDrawer()
            }
        default:
            break
        }
    }

    @objc private func handleDrawerPan(_ gesture: UIPanGestureRecognizer) {
        guard usesOverlaySidebar(), isDrawerOpen else { return }
        let t = gesture.translation(in: view).x
        switch gesture.state {
        case .changed:
            let x = min(0, max(-DSTheme.sidebarWidth, t))
            sidebarLeadingCompact.constant = x
            dimView.alpha = (x + DSTheme.sidebarWidth) / DSTheme.sidebarWidth
            view.layoutIfNeeded()
        case .ended, .cancelled:
            let v = gesture.velocity(in: view).x
            if sidebarLeadingCompact.constant < -DSTheme.sidebarWidth * 0.35 || v < -400 {
                closeDrawer()
            } else {
                openDrawer()
            }
        default:
            break
        }
    }

    private func presentRename(id: String) {
        let current = ConversationStore.shared.conversations.first(where: { $0.id == id })?.title ?? ""
        let alert = UIAlertController(title: "重命名对话", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = current; $0.clearButtonMode = .whileEditing }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { _ in
            let text = alert.textFields?.first?.text ?? ""
            ConversationStore.shared.renameConversation(id: id, title: text)
            self.chatVC.reloadChat()
        })
        present(alert, animated: true)
    }

}

extension Notification.Name {
    static let connectsCompactLayoutDidChange = Notification.Name("ConnectsCompactLayoutDidChange")
    static let connectsChatWidthDidChange = Notification.Name("ConnectsChatWidthDidChange")
}

extension RootSplitViewController: SidebarViewControllerDelegate {
    func sidebarWillSelectConversation(id: String) {
        chatVC.prepareForConversationSwitch(to: id)
    }

    func sidebarDidRefreshConversationList() {
        chatVC.prewarmRecentConversationTails()
    }

    func sidebarDidSelectConversation(id: String) {
        if chatNav.topViewController !== chatVC {
            chatNav.popToRootViewController(animated: false)
        }
        closeDrawer(animated: true)
        ConversationStore.shared.selectConversation(id: id)
        chatVC.applyConversationSwitchHint()
    }

    func sidebarDidRequestNewChat() {
        let model = ConversationStore.shared.currentConversation?.model ?? .deepseekV4Pro
        _ = ConversationStore.shared.createConversation(model: model)
        closeDrawer()
    }

    func sidebarDidRequestSettings() {
        closeDrawer()
        let settings = SettingsViewController()
        let nav = UINavigationController(rootViewController: settings)
        nav.modalPresentationStyle = .formSheet
        nav.preferredContentSize = CGSize(width: 460, height: 620)
        nav.navigationBar.isTranslucent = false
        present(nav, animated: true)
    }

    func sidebarDidRequestMemory() {
        closeDrawer()
        chatNav.pushViewController(MemoryViewController(), animated: true)
    }

    func sidebarDidDeleteConversation(id: String) {
        ConversationStore.shared.deleteConversation(id: id)
    }

    func sidebarDidRenameConversation(id: String) {
        presentRename(id: id)
    }

    func sidebarDidForkConversation(id: String) {
        _ = ConversationStore.shared.forkConversation(id: id)
        closeDrawer()
    }

    func sidebarDidArchiveConversation(id: String, archive: Bool) {
        ConversationStore.shared.setArchived(id: id, archived: archive)
    }

    func sidebarDidToggleArchiveFilter() {
        ConversationStore.shared.setShowArchived(!ConversationStore.shared.showArchived)
    }

    func sidebarDidSelectProjectFilter(projectID: String?) {
        ConversationStore.shared.setSelectedProjectID(projectID)
    }

    func sidebarDidRequestNewProject() {
        let alert = UIAlertController(title: "新建项目", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "项目名称" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建", style: .default) { _ in
            guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            let project = Project(name: name, colorPreset: ProjectStore.shared.projects.count % 20)
            ProjectStore.shared.upsert(project)
            ConversationStore.shared.setSelectedProjectID(project.id)
        })
        present(alert, animated: true)
    }

    func sidebarDidRequestManageProjects() {
        closeDrawer()
        presentProjectSettings()
    }

    func sidebarDidMoveConversation(id: String, toProject projectID: String?) {
        ConversationStore.shared.setProject(projectID, for: id)
        if let projectID = projectID {
            ConversationStore.shared.setSelectedProjectID(projectID)
        }
    }

    private func presentProjectSettings() {
        let settings = ProjectSettingsViewController()
        let nav = UINavigationController(rootViewController: settings)
        nav.modalPresentationStyle = .formSheet
        nav.preferredContentSize = CGSize(width: 460, height: 620)
        nav.navigationBar.isTranslucent = false
        present(nav, animated: true)
    }
}

extension RootSplitViewController: ChatViewControllerDelegate {
    func chatDidUpdateTitle(_ title: String) {}
    func chatDidRequestShare() {
        chatVC.shareCurrentMarkdown()
    }
    func chatDidFinishInitialLaunch() {
        dismissLaunchOverlayIfNeeded()
    }
}
