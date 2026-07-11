import UIKit

/// Custom two-pane root (replaces UISplitViewController) — soft divider + collapsible sidebar.
final class RootSplitViewController: UIViewController {
    private let sidebarVC = SidebarViewController()
    private let chatNav: UINavigationController
    private let chatVC = ChatViewController()

    private let sidebarContainer = UIView()
    private let divider = UIView()
    private let chatContainer = UIView()

    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var isSidebarCollapsed = false

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

        [sidebarContainer, divider, chatContainer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        sidebarVC.view.translatesAutoresizingMaskIntoConstraints = false
        chatNav.view.translatesAutoresizingMaskIntoConstraints = false

        sidebarWidthConstraint = sidebarContainer.widthAnchor.constraint(
            equalToConstant: isSidebarCollapsed ? 0 : DSTheme.sidebarWidth
        )

        NSLayoutConstraint.activate([
            sidebarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarContainer.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarWidthConstraint,

            sidebarVC.view.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebarVC.view.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebarVC.view.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            sidebarVC.view.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            chatContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            chatContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chatContainer.topAnchor.constraint(equalTo: view.topAnchor),
            chatContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            chatNav.view.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor),
            chatNav.view.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor),
            chatNav.view.topAnchor.constraint(equalTo: chatContainer.topAnchor),
            chatNav.view.bottomAnchor.constraint(equalTo: chatContainer.bottomAnchor)
        ])

        sidebarContainer.clipsToBounds = true
        applyThemeColors()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        // Ensure chat VC nav items exist before updating toggle title (iOS 12 may not load child view yet)
        chatNav.loadViewIfNeeded()
        chatVC.loadViewIfNeeded()
        chatVC.updateSidebarToggleTitle(collapsed: isSidebarCollapsed)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { applyThemeColors() }

    private func applyThemeColors() {
        let c = DSTheme.c
        view.backgroundColor = c.background
        sidebarContainer.backgroundColor = c.sidebarBackground
        chatContainer.backgroundColor = c.background
        // Soft divider — almost invisible in dark mode
        divider.backgroundColor = c.divider
    }

    private func toggleSidebar() {
        isSidebarCollapsed.toggle()
        UserDefaults.standard.set(isSidebarCollapsed, forKey: "connects_sidebar_collapsed")
        sidebarWidthConstraint.constant = isSidebarCollapsed ? 0 : DSTheme.sidebarWidth
        UIView.animate(withDuration: 0.22) {
            self.view.layoutIfNeeded()
        }
        chatVC.updateSidebarToggleTitle(collapsed: isSidebarCollapsed)
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

extension RootSplitViewController: SidebarViewControllerDelegate {
    func sidebarDidSelectConversation(id: String) {
        ConversationStore.shared.selectConversation(id: id)
        chatVC.reloadChat()
    }

    func sidebarDidRequestNewChat() {
        let model = ConversationStore.shared.currentConversation?.model ?? .deepseekV4Pro
        _ = ConversationStore.shared.createConversation(model: model)
        chatVC.reloadChat()
    }

    func sidebarDidRequestSettings() {
        let settings = SettingsViewController()
        let nav = UINavigationController(rootViewController: settings)
        nav.modalPresentationStyle = .formSheet
        nav.preferredContentSize = CGSize(width: 460, height: 560)
        nav.navigationBar.isTranslucent = false
        present(nav, animated: true)
    }

    func sidebarDidDeleteConversation(id: String) {
        ConversationStore.shared.deleteConversation(id: id)
        chatVC.reloadChat()
    }

    func sidebarDidRenameConversation(id: String) {
        presentRename(id: id)
    }

    func sidebarDidForkConversation(id: String) {
        _ = ConversationStore.shared.forkConversation(id: id)
        chatVC.reloadChat()
    }

    func sidebarDidArchiveConversation(id: String, archive: Bool) {
        ConversationStore.shared.setArchived(id: id, archived: archive)
        chatVC.reloadChat()
    }

    func sidebarDidToggleArchiveFilter() {
        ConversationStore.shared.setShowArchived(!ConversationStore.shared.showArchived)
        chatVC.reloadChat()
    }
}

extension RootSplitViewController: ChatViewControllerDelegate {
    func chatDidUpdateTitle(_ title: String) {}
    func chatDidRequestShare() {
        chatVC.shareCurrentMarkdown()
    }
}
