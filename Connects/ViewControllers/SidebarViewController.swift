import UIKit

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebarDidSelectConversation(id: String)
    func sidebarDidRequestNewChat()
    func sidebarDidRequestSettings()
    func sidebarDidDeleteConversation(id: String)
    func sidebarDidRenameConversation(id: String)
    func sidebarDidForkConversation(id: String)
    func sidebarDidArchiveConversation(id: String, archive: Bool)
    func sidebarDidToggleArchiveFilter()
}

final class SidebarViewController: UIViewController, ThemeRefreshable, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    weak var delegate: SidebarViewControllerDelegate?

    private let headerBar = UIView()
    private let logoImageView = UIImageView()
    private let brandLabel = UILabel()
    private let newChatButton = UIButton(type: .system)
    private let searchField = UITextField()
    private let archiveFilterButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let footerBar = UIView()
    private let settingsButton = UIButton(type: .system)
    private let topDivider = UIView()
    private let bottomDivider = UIView()

    private var sections: [(title: String, items: [Conversation])] = []
    private var filterText = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: .conversationStoreDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamFinishedSidebar), name: .streamManagerDidFinish, object: nil)
        applyTheme()
        reloadData()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func streamFinishedSidebar() { reloadData() }

    func applyTheme() {
        let c = DSTheme.c
        view.backgroundColor = c.sidebarBackground
        headerBar.backgroundColor = c.sidebarBackground
        footerBar.backgroundColor = c.sidebarBackground
        tableView.backgroundColor = c.sidebarBackground
        brandLabel.textColor = c.textPrimary
        newChatButton.setTitleColor(c.textPrimary, for: .normal)
        newChatButton.tintColor = c.textPrimary
        newChatButton.backgroundColor = c.surface
        newChatButton.layer.borderColor = c.border.cgColor
        archiveFilterButton.tintColor = c.textSecondary
        settingsButton.tintColor = c.textSecondary
        settingsButton.setTitleColor(c.textSecondary, for: .normal)
        topDivider.backgroundColor = c.divider
        bottomDivider.backgroundColor = c.divider
        searchField.backgroundColor = c.surface
        searchField.textColor = c.textPrimary
        searchField.tintColor = c.accent
        searchField.attributedPlaceholder = NSAttributedString(
            string: "搜索对话…",
            attributes: [.foregroundColor: c.textTertiary]
        )
        searchField.layer.borderColor = c.border.cgColor
        tableView.reloadData()
        refreshArchiveIcon()
    }

    @objc private func themeChanged() { applyTheme() }
    @objc private func storeChanged() { reloadData() }

    func reloadData() {
        refreshArchiveIcon()
        rebuildSections()
        tableView.reloadData()
        if let id = ConversationStore.shared.currentConversationID {
            for (s, section) in sections.enumerated() {
                if let row = section.items.firstIndex(where: { $0.id == id }) {
                    tableView.selectRow(at: IndexPath(row: row, section: s), animated: false, scrollPosition: .none)
                    break
                }
            }
        }
    }

    private func refreshArchiveIcon() {
        let showingArchive = ConversationStore.shared.showArchived
        archiveFilterButton.setImage(ActionIconFactory.image(.archive, pointSize: 17), for: .normal)
        archiveFilterButton.setTitle(nil, for: .normal)
        archiveFilterButton.accessibilityLabel = showingArchive ? "返回对话列表" : "归档"
        archiveFilterButton.alpha = showingArchive ? 1.0 : 0.85
    }

    private func rebuildSections() {
        var list = ConversationStore.shared.visibleConversations
        if !filterText.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(filterText) }
        }
        let cal = Calendar.current
        let now = Date()
        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var week: [Conversation] = []
        var older: [Conversation] = []
        for conv in list {
            if cal.isDateInToday(conv.updatedAt) {
                today.append(conv)
            } else if cal.isDateInYesterday(conv.updatedAt) {
                yesterday.append(conv)
            } else if let days = cal.dateComponents([.day], from: conv.updatedAt, to: now).day, days < 7 {
                week.append(conv)
            } else {
                older.append(conv)
            }
        }
        sections = []
        if !today.isEmpty { sections.append(("今天", today)) }
        if !yesterday.isEmpty { sections.append(("昨天", yesterday)) }
        if !week.isEmpty { sections.append(("近 7 天", week)) }
        if !older.isEmpty { sections.append(("更早", older)) }
    }

    private func setupLayout() {
        preferredContentSize = CGSize(width: DSTheme.sidebarWidth, height: 0)

        [headerBar, topDivider, tableView, bottomDivider, footerBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.clipsToBounds = true
        logoImageView.layer.cornerRadius = 6
        logoImageView.image = UIImage(named: "Logo-120")
        headerBar.addSubview(logoImageView)

        brandLabel.translatesAutoresizingMaskIntoConstraints = false
        brandLabel.text = "Connects"
        brandLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        headerBar.addSubview(brandLabel)

        archiveFilterButton.translatesAutoresizingMaskIntoConstraints = false
        archiveFilterButton.addTarget(self, action: #selector(archiveFilterTapped), for: .touchUpInside)
        headerBar.addSubview(archiveFilterButton)

        newChatButton.translatesAutoresizingMaskIntoConstraints = false
        newChatButton.setTitle("  新对话", for: .normal)
        newChatButton.setImage(ActionIconFactory.image(.newChat, pointSize: 15), for: .normal)
        newChatButton.titleLabel?.font = DSTheme.bodyFont(size: 15)
        newChatButton.layer.cornerRadius = 12
        newChatButton.layer.borderWidth = 1
        newChatButton.contentHorizontalAlignment = .left
        newChatButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 14)
        newChatButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
        newChatButton.addTarget(self, action: #selector(newChatTapped), for: .touchUpInside)
        headerBar.addSubview(newChatButton)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = DSTheme.bodyFont(size: 14)
        searchField.layer.cornerRadius = 10
        searchField.layer.borderWidth = 1
        let searchIcon = UIImageView(image: ActionIconFactory.image(.search, pointSize: 13))
        searchIcon.tintColor = DSTheme.c.textTertiary
        searchIcon.contentMode = .center
        searchIcon.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        let leftWrap = UIView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        leftWrap.addSubview(searchIcon)
        searchField.leftView = leftWrap
        searchField.leftViewMode = .always
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchField.returnKeyType = .search
        headerBar.addSubview(searchField)

        tableView.separatorStyle = .none
        tableView.rowHeight = DSTheme.rowHeight
        tableView.sectionHeaderHeight = 28
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ConvCell")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.showsVerticalScrollIndicator = false
        if #available(iOS 11.0, *) {
            tableView.contentInsetAdjustmentBehavior = .never
        }

        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.setTitle("  设置", for: .normal)
        settingsButton.setImage(ActionIconFactory.image(.settings, pointSize: 16), for: .normal)
        settingsButton.titleLabel?.font = DSTheme.bodyFont(size: 15)
        settingsButton.contentHorizontalAlignment = .left
        settingsButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 18)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        footerBar.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            logoImageView.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 16),
            logoImageView.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 16),
            logoImageView.widthAnchor.constraint(equalToConstant: 28),
            logoImageView.heightAnchor.constraint(equalToConstant: 28),

            brandLabel.centerYAnchor.constraint(equalTo: logoImageView.centerYAnchor),
            brandLabel.leadingAnchor.constraint(equalTo: logoImageView.trailingAnchor, constant: 10),

            archiveFilterButton.centerYAnchor.constraint(equalTo: logoImageView.centerYAnchor),
            archiveFilterButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -14),

            newChatButton.topAnchor.constraint(equalTo: logoImageView.bottomAnchor, constant: 14),
            newChatButton.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),
            newChatButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12),
            newChatButton.heightAnchor.constraint(equalToConstant: 40),

            searchField.topAnchor.constraint(equalTo: newChatButton.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 34),
            searchField.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: -12),

            topDivider.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            footerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            footerBar.heightAnchor.constraint(equalToConstant: 52),

            settingsButton.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor),
            settingsButton.topAnchor.constraint(equalTo: footerBar.topAnchor),
            settingsButton.bottomAnchor.constraint(equalTo: footerBar.bottomAnchor),

            bottomDivider.bottomAnchor.constraint(equalTo: footerBar.topAnchor),
            bottomDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            tableView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor)
        ])
    }

    @objc private func newChatTapped() { delegate?.sidebarDidRequestNewChat() }
    @objc private func settingsTapped() { delegate?.sidebarDidRequestSettings() }
    @objc private func archiveFilterTapped() { delegate?.sidebarDidToggleArchiveFilter() }
    @objc private func searchChanged() {
        filterText = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        rebuildSections()
        tableView.reloadData()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        header.textLabel?.textColor = DSTheme.c.textTertiary
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ConvCell", for: indexPath)
        let conv = sections[indexPath.section].items[indexPath.row]
        let c = DSTheme.c
        let running = StreamManager.shared.isRunning(conv.id)
        cell.backgroundColor = .clear
        cell.textLabel?.text = running ? "●  \(conv.title)" : conv.title
        cell.textLabel?.font = DSTheme.bodyFont(size: 14)
        cell.textLabel?.textColor = running ? c.accent : c.textPrimary
        cell.textLabel?.numberOfLines = 1
        let selected = UIView()
        selected.backgroundColor = c.surfaceHover
        selected.layer.cornerRadius = 8
        cell.selectedBackgroundView = selected
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let id = sections[indexPath.section].items[indexPath.row].id
        delegate?.sidebarDidSelectConversation(id: id)
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { false }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if tableView.gestureRecognizers?.contains(where: { $0 is UILongPressGestureRecognizer }) != true {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.45
            tableView.addGestureRecognizer(longPress)
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point) else { return }
        let conv = sections[indexPath.section].items[indexPath.row]
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)

        let sheet = UIAlertController(title: conv.title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "重命名", style: .default) { [weak self] _ in
            self?.delegate?.sidebarDidRenameConversation(id: conv.id)
        })
        sheet.addAction(UIAlertAction(title: "分叉", style: .default) { [weak self] _ in
            self?.delegate?.sidebarDidForkConversation(id: conv.id)
        })
        let archiveTitle = conv.isArchived ? "取消归档" : "归档"
        sheet.addAction(UIAlertAction(title: archiveTitle, style: .default) { [weak self] _ in
            self?.delegate?.sidebarDidArchiveConversation(id: conv.id, archive: !conv.isArchived)
        })
        sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.delegate?.sidebarDidDeleteConversation(id: conv.id)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let pop = sheet.popoverPresentationController,
           let cell = tableView.cellForRow(at: indexPath) {
            pop.sourceView = cell
            pop.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }
}
