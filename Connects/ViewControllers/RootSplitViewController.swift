import UIKit

/// Two-pane root with collapsible sidebar.
/// In Slide Over / narrow width: chat is full-bleed; conversation list is an edge-pull drawer
/// so Connects stays usable while watching 网课 fullscreen in another app.
final class RootSplitViewController: UIViewController {
    private let sidebarVC = SidebarViewController()
    private let chatNav: UINavigationController
    private let chatVC = ChatViewController()

    private let sidebarContainer = UIView()
    private let divider = UIView()
    private let chatContainer = UIView()
    private let dimView = UIView()

    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarLeadingWide: NSLayoutConstraint!
    private var sidebarLeadingCompact: NSLayoutConstraint!
    private var chatLeadingWide: NSLayoutConstraint!
    private var chatLeadingCompact: NSLayoutConstraint!
    private var dividerWidthConstraint: NSLayoutConstraint!

    private var isSidebarCollapsed = false
    private var isCompactLayout = false
    private var isDrawerOpen = false

    /// Below this width → Slide Over / 侧拉网课模式.
    private let compactBreakpoint: CGFloat = 520

    init() {
        chatNav = UINavigationController(rootViewController: chatVC)
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

        isSidebarCollapsed = UserDefaults.standard.bool(forKey: "connects_sidebar_collapsed")

        addChild(sidebarVC)
        addChild(chatNav)
        sidebarContainer.addSubview(sidebarVC.view)
        chatContainer.addSubview(chatNav.view)
        sidebarVC.didMove(toParent: self)
        chatNav.didMove(toParent: self)

        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        dimView.alpha = 0
        dimView.isHidden = true
        let tapDim = UITapGestureRecognizer(target: self, action: #selector(closeDrawer))
        dimView.addGestureRecognizer(tapDim)

        [chatContainer, dimView, sidebarContainer, divider].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        // Drawer above chat; divider only used in wide mode.
        view.bringSubviewToFront(dimView)
        view.bringSubviewToFront(sidebarContainer)

        sidebarVC.view.translatesAutoresizingMaskIntoConstraints = false
        chatNav.view.translatesAutoresizingMaskIntoConstraints = false

        sidebarWidthConstraint = sidebarContainer.widthAnchor.constraint(equalToConstant: DSTheme.sidebarWidth)
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

            chatNav.view.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor),
            chatNav.view.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor),
            chatNav.view.topAnchor.constraint(equalTo: chatContainer.topAnchor),
            chatNav.view.bottomAnchor.constraint(equalTo: chatContainer.bottomAnchor),

            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        sidebarContainer.clipsToBounds = true
        applyThemeColors()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)

        chatNav.loadViewIfNeeded()
        chatVC.loadViewIfNeeded()
        chatVC.updateSidebarToggleTitle(collapsed: isSidebarCollapsed)

        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        edge.edges = .left
        view.addGestureRecognizer(edge)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDrawerPan(_:)))
        sidebarContainer.addGestureRecognizer(pan)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let compact = view.bounds.width > 0 && view.bounds.width < compactBreakpoint
        if compact != isCompactLayout {
            isCompactLayout = compact
            applyLayoutMode(animated: false)
        }
        NotificationCenter.default.post(
            name: .connectsCompactLayoutDidChange,
            object: nil,
            userInfo: ["compact": isCompactLayout]
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        view.setNeedsLayout()
    }

    @objc private func themeChanged() { applyThemeColors() }

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
            sidebarContainer.layer.shadowOpacity = 0
        }
    }

    private func applyLayoutMode(animated: Bool) {
        isDrawerOpen = false
        dimView.isHidden = true
        dimView.alpha = 0

        if isCompactLayout {
            // Chat full width; sidebar is an overlay drawer.
            sidebarLeadingWide.isActive = false
            chatLeadingWide.isActive = false
            sidebarLeadingCompact.isActive = true
            chatLeadingCompact.isActive = true
            sidebarLeadingCompact.constant = -DSTheme.sidebarWidth
            sidebarWidthConstraint.constant = DSTheme.sidebarWidth
            dividerWidthConstraint.constant = 0
            divider.isHidden = true
            isSidebarCollapsed = true
            chatVC.updateSidebarToggleTitle(collapsed: true)
            chatVC.setCompactChrome(true)
        } else {
            sidebarLeadingCompact.isActive = false
            chatLeadingCompact.isActive = false
            sidebarLeadingWide.isActive = true
            chatLeadingWide.isActive = true
            dividerWidthConstraint.constant = 1 / UIScreen.main.scale
            divider.isHidden = false
            isSidebarCollapsed = UserDefaults.standard.bool(forKey: "connects_sidebar_collapsed")
            sidebarWidthConstraint.constant = isSidebarCollapsed ? 0 : DSTheme.sidebarWidth
            chatVC.updateSidebarToggleTitle(collapsed: isSidebarCollapsed)
            chatVC.setCompactChrome(false)
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
        if isCompactLayout {
            if isDrawerOpen { closeDrawer() } else { openDrawer() }
            return
        }
        isSidebarCollapsed.toggle()
        UserDefaults.standard.set(isSidebarCollapsed, forKey: "connects_sidebar_collapsed")
        sidebarWidthConstraint.constant = isSidebarCollapsed ? 0 : DSTheme.sidebarWidth
        UIView.animate(withDuration: 0.22) {
            self.view.layoutIfNeeded()
        }
        chatVC.updateSidebarToggleTitle(collapsed: isSidebarCollapsed)
    }

    private func openDrawer() {
        guard isCompactLayout else { return }
        isDrawerOpen = true
        dimView.isHidden = false
        sidebarLeadingCompact.constant = 0
        view.bringSubviewToFront(dimView)
        view.bringSubviewToFront(sidebarContainer)
        UIView.animate(withDuration: 0.22) {
            self.dimView.alpha = 1
            self.view.layoutIfNeeded()
        }
        chatVC.updateSidebarToggleTitle(collapsed: false)
    }

    @objc private func closeDrawer() {
        guard isCompactLayout, isDrawerOpen else { return }
        isDrawerOpen = false
        sidebarLeadingCompact.constant = -DSTheme.sidebarWidth
        UIView.animate(withDuration: 0.22, animations: {
            self.dimView.alpha = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            if !self.isDrawerOpen {
                self.dimView.isHidden = true
            }
        })
        chatVC.updateSidebarToggleTitle(collapsed: true)
    }

    @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard isCompactLayout else { return }
        let t = gesture.translation(in: view).x
        switch gesture.state {
        case .began:
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
        guard isCompactLayout, isDrawerOpen else { return }
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
}

extension RootSplitViewController: SidebarViewControllerDelegate {
    func sidebarDidSelectConversation(id: String) {
        ConversationStore.shared.selectConversation(id: id)
        closeDrawer()
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
}

extension RootSplitViewController: ChatViewControllerDelegate {
    func chatDidUpdateTitle(_ title: String) {}
    func chatDidRequestShare() {
        chatVC.shareCurrentMarkdown()
    }
}
