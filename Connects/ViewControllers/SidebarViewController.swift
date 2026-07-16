import UIKit

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebarDidSelectConversation(id: String)
    func sidebarDidRequestNewChat()
    func sidebarDidRequestSettings()
    func sidebarDidRequestMemory()
    func sidebarDidDeleteConversation(id: String)
    func sidebarDidRenameConversation(id: String)
    func sidebarDidForkConversation(id: String)
    func sidebarDidArchiveConversation(id: String, archive: Bool)
    func sidebarDidToggleArchiveFilter()
    func sidebarDidSelectProjectFilter(projectID: String?)
    func sidebarDidRequestNewProject()
    func sidebarDidRequestManageProjects()
    func sidebarDidMoveConversation(id: String, toProject projectID: String?)
}

private enum SidebarRow {
    case project(Project)
    case conversation(Conversation)
}

private enum SidebarSectionKind {
    case projects, chats, archive
}

private struct SidebarSection {
    let kind: SidebarSectionKind
    let title: String
    let rows: [SidebarRow]
}

final class SidebarViewController: UIViewController, ThemeRefreshable, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    weak var delegate: SidebarViewControllerDelegate?

    private let headerBar = UIView()
    private let logoImageView = UIImageView()
    private let brandLabel = UILabel()
    private let newChatButton = UIButton(type: .system)
    private let searchField = UITextField()
    private let memoryButton = UIButton(type: .system)
    private let archiveFilterButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let footerBar = UIView()
    private let settingsButton = UIButton(type: .system)
    private let topDivider = UIView()
    private let bottomDivider = UIView()

    private var sections: [SidebarSection] = []
    private var filterText = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: .conversationStoreDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamFinishedSidebar), name: .streamManagerDidFinish, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamFinishedSidebar), name: .webSearchDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamFinishedSidebar), name: .streamManagerDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(memoryChanged), name: .memoryStoreDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(projectsChanged), name: .projectsDidChange, object: nil)
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
        memoryButton.setTitleColor(c.textPrimary, for: .normal)
        memoryButton.backgroundColor = c.surface
        memoryButton.layer.borderColor = c.border.cgColor
        tableView.reloadData()
        refreshArchiveIcon()
    }

    @objc private func themeChanged() { applyTheme() }
    @objc private func storeChanged(_ note: Notification) {
        let projectFilterOnly = (note.userInfo?["source"] as? String) == "projectFilter"
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if projectFilterOnly {
                self.reloadProjectFilter()
            } else {
                self.reloadData()
            }
        }
    }
    @objc private func memoryChanged() { refreshMemoryButton() }
    @objc private func projectsChanged() { reloadData() }

    func reloadData() {
        refreshArchiveIcon()
        refreshMemoryButton()
        rebuildSections()
        tableView.reloadData()
        highlightCurrentConversation()
    }

    private func reloadProjectFilter() {
        rebuildSections()
        tableView.reloadData()
        highlightCurrentConversation()
    }

    private func highlightCurrentConversation() {
        guard let id = ConversationStore.shared.currentConversationID else {
            tableView.indexPathsForSelectedRows?.forEach { tableView.deselectRow(at: $0, animated: false) }
            return
        }
        for (sectionIndex, section) in sections.enumerated() {
            if let row = section.rows.firstIndex(where: {
                if case .conversation(let conv) = $0 { return conv.id == id }
                return false
            }) {
                guard sectionIndex < tableView.numberOfSections,
                      row < tableView.numberOfRows(inSection: sectionIndex) else { return }
                tableView.selectRow(at: IndexPath(row: row, section: sectionIndex), animated: false, scrollPosition: .none)
                return
            }
        }
        tableView.indexPathsForSelectedRows?.forEach { tableView.deselectRow(at: $0, animated: false) }
    }

    private func refreshArchiveIcon() {
        let showingArchive = ConversationStore.shared.showArchived
        archiveFilterButton.setImage(ActionIconFactory.image(.archive, pointSize: 17), for: .normal)
        archiveFilterButton.setTitle(nil, for: .normal)
        archiveFilterButton.accessibilityLabel = showingArchive ? "返回对话列表" : "归档"
        archiveFilterButton.alpha = showingArchive ? 1.0 : 0.85
    }

    private func refreshMemoryButton() {
        let count = MemoryStore.shared.pendingChanges().count
        memoryButton.setTitle(count > 0 ? "  Memory  · \(count) 项待确认" : "  Memory", for: .normal)
    }

    private func rebuildSections() {
        if ConversationStore.shared.showArchived {
            var list = ConversationStore.shared.visibleConversations
            if !filterText.isEmpty {
                list = list.filter { $0.title.localizedCaseInsensitiveContains(filterText) }
            }
            sections = dateGroupedConversationSections(from: list, kind: .archive)
            return
        }

        let projectRows: [SidebarRow] = ProjectStore.shared.sortedProjects.map { .project($0) }
        let projectSection = SidebarSection(kind: .projects, title: "项目", rows: projectRows)

        var chats = ConversationStore.shared.visibleConversations
        if !filterText.isEmpty {
            chats = chats.filter { $0.title.localizedCaseInsensitiveContains(filterText) }
        }
        let chatSections = dateGroupedConversationSections(from: chats, kind: .chats)
        sections = [projectSection] + chatSections
    }

    private func dateGroupedConversationSections(from list: [Conversation],
                                                 kind: SidebarSectionKind) -> [SidebarSection] {
        guard !list.isEmpty else { return [] }

        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var week: [Conversation] = []
        var older: [Conversation] = []
        for conv in list {
            let updatedStart = cal.startOfDay(for: conv.updatedAt)
            let dayOffset = cal.dateComponents([.day], from: updatedStart, to: todayStart).day ?? 999
            if dayOffset == 0 {
                today.append(conv)
            } else if dayOffset == 1 {
                yesterday.append(conv)
            } else if dayOffset < 7 {
                week.append(conv)
            } else {
                older.append(conv)
            }
        }

        var result: [SidebarSection] = []
        if !today.isEmpty {
            result.append(SidebarSection(kind: kind, title: "今天", rows: today.map { .conversation($0) }))
        }
        if !yesterday.isEmpty {
            result.append(SidebarSection(kind: kind, title: "昨天", rows: yesterday.map { .conversation($0) }))
        }
        if !week.isEmpty {
            result.append(SidebarSection(kind: kind, title: "近 7 天", rows: week.map { .conversation($0) }))
        }
        if !older.isEmpty {
            result.append(SidebarSection(kind: kind, title: "更早", rows: older.map { .conversation($0) }))
        }
        return result
    }

    private func makeProjectSectionHeader(title: String) -> UIView {
        let c = DSTheme.c
        let wrap = UIView()
        wrap.backgroundColor = .clear

        let label = UILabel()
        label.text = title
        label.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = c.textTertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)

        let addButton = UIButton(type: .system)
        addButton.setImage(ActionIconFactory.image(.plus, pointSize: 14, color: c.textSecondary), for: .normal)
        addButton.tintColor = c.textSecondary
        addButton.accessibilityLabel = "新建项目"
        addButton.addTarget(self, action: #selector(newProjectTapped), for: .touchUpInside)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(addButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            addButton.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 28),
            addButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        return wrap
    }

    @objc private func newProjectTapped() {
        delegate?.sidebarDidRequestNewProject()
    }

    private func presentRenameProject(_ project: Project) {
        let alert = UIAlertController(title: "重命名项目", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.text = project.name
            $0.placeholder = "项目名称"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { _ in
            guard var next = ProjectStore.shared.project(id: project.id),
                  let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            next.name = name
            ProjectStore.shared.upsert(next)
        })
        present(alert, animated: true)
    }

    private func presentDeleteProject(_ project: Project) {
        let alert = UIAlertController(
            title: "删除「\(project.name)」？",
            message: "项目内对话将变为未分类，不会被删除。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            ProjectStore.shared.delete(id: project.id)
        })
        present(alert, animated: true)
    }

    private func presentMoveToProjectMenu(for conv: Conversation, sourceView: UIView, sourceRect: CGRect) {
        var items: [ConnectsMenuItem] = [
            ConnectsMenuItem(title: "未分类", isSelected: conv.projectID == nil) { [weak self] in
                self?.delegate?.sidebarDidMoveConversation(id: conv.id, toProject: nil)
            }
        ]
        for project in ProjectStore.shared.sortedProjects {
            items.append(ConnectsMenuItem(
                title: project.name,
                customImage: AgentAppearancePreset.colorBall(for: project, size: 12),
                isSelected: conv.projectID == project.id
            ) { [weak self] in
                self?.delegate?.sidebarDidMoveConversation(id: conv.id, toProject: project.id)
            })
        }
        items.append(ConnectsMenuItem(title: "项目设置…", icon: .folder) { [weak self] in
            self?.delegate?.sidebarDidRequestManageProjects()
        })
        ConnectsMenu.present(
            from: self,
            title: "移动到项目",
            items: items,
            sourceView: sourceView,
            sourceRect: sourceRect,
            preferVertical: true,
            maxHeight: 360
        )
    }

    private func presentProjectMenu(for project: Project, sourceView: UIView, sourceRect: CGRect) {
        ConnectsMenu.present(
            from: self,
            title: project.name,
            items: [
                ConnectsMenuItem(title: "重命名", icon: .rename) { [weak self] in
                    self?.presentRenameProject(project)
                },
                ConnectsMenuItem(title: "项目设置…", icon: .folder) { [weak self] in
                    self?.delegate?.sidebarDidRequestManageProjects()
                },
                ConnectsMenuItem(title: "删除", icon: .trash, isDestructive: true) { [weak self] in
                    self?.presentDeleteProject(project)
                }
            ],
            sourceView: sourceView,
            sourceRect: sourceRect,
            preferVertical: true
        )
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

        memoryButton.translatesAutoresizingMaskIntoConstraints = false
        memoryButton.setTitle("  Memory", for: .normal)
        memoryButton.contentHorizontalAlignment = .left
        memoryButton.titleLabel?.font = DSTheme.bodyFont(size: 14)
        memoryButton.layer.cornerRadius = 10
        memoryButton.layer.borderWidth = 1 / UIScreen.main.scale
        memoryButton.addTarget(self, action: #selector(memoryTapped), for: .touchUpInside)
        view.addSubview(memoryButton)

        tableView.separatorStyle = .none
        tableView.rowHeight = 40
        tableView.sectionHeaderHeight = 30
        tableView.sectionFooterHeight = 4
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SidebarCell")
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

            memoryButton.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 8),
            memoryButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            memoryButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            memoryButton.heightAnchor.constraint(equalToConstant: 34),

            topDivider.topAnchor.constraint(equalTo: memoryButton.bottomAnchor, constant: 8),
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
    @objc private func memoryTapped() { delegate?.sidebarDidRequestMemory() }
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
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard sections[section].kind == .projects else { return nil }
        return makeProjectSectionHeader(title: sections[section].title)
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        30
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard sections[section].kind != .projects else { return nil }
        return sections[section].title
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        header.textLabel?.textColor = DSTheme.c.textTertiary
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SidebarCell", for: indexPath)
        let row = sections[indexPath.section].rows[indexPath.row]
        let c = DSTheme.c
        cell.backgroundColor = .clear
        cell.textLabel?.numberOfLines = 1
        cell.textLabel?.font = DSTheme.bodyFont(size: 14)
        cell.imageView?.image = nil
        cell.accessoryType = .none
        cell.indentationLevel = 0
        cell.indentationWidth = 0

        let selectedBG = UIView()
        selectedBG.backgroundColor = c.surfaceHover
        selectedBG.layer.cornerRadius = 8
        cell.selectedBackgroundView = selectedBG

        switch row {
        case .project(let project):
            let isActive = ConversationStore.shared.selectedProjectID == project.id
            cell.imageView?.image = AgentAppearancePreset.colorBall(for: project, size: 12)
            cell.textLabel?.text = project.name
            cell.textLabel?.textColor = isActive ? c.textPrimary : c.textPrimary
            cell.textLabel?.font = UIFont.systemFont(ofSize: 14, weight: isActive ? .semibold : .regular)
            cell.backgroundColor = isActive ? c.surfaceHover.withAlphaComponent(0.55) : .clear
        case .conversation(let conv):
            let running = StreamManager.shared.isRunning(conv.id) || WebSearchCoordinator.shared.isSearching(conv.id)
            cell.textLabel?.text = running ? "●  \(conv.title)" : conv.title
            cell.textLabel?.textColor = running ? c.accent : c.textPrimary
            cell.textLabel?.font = DSTheme.bodyFont(size: 14)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let row = sections[indexPath.section].rows[indexPath.row]
        switch row {
        case .project(let project):
            let store = ConversationStore.shared
            tableView.deselectRow(at: indexPath, animated: true)
            if store.selectedProjectID == project.id {
                delegate?.sidebarDidSelectProjectFilter(projectID: nil)
            } else {
                delegate?.sidebarDidSelectProjectFilter(projectID: project.id)
            }
        case .conversation(let conv):
            delegate?.sidebarDidSelectConversation(id: conv.id)
        }
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
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = tableView.cellForRow(at: indexPath) ?? tableView
        let local = gesture.location(in: cell)
        let hot = CGRect(x: local.x - 14, y: local.y - 14, width: 28, height: 28)

        switch row {
        case .conversation(let conv):
            tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
            let archiveTitle = conv.isArchived ? "取消归档" : "归档"
            ConnectsMenu.present(
                from: self,
                title: conv.title,
                items: [
                    ConnectsMenuItem(title: "重命名", icon: .rename) { [weak self] in
                        self?.delegate?.sidebarDidRenameConversation(id: conv.id)
                    },
                    ConnectsMenuItem(title: "移动到项目…", icon: .folder) { [weak self] in
                        guard let self = self else { return }
                        self.presentMoveToProjectMenu(for: conv, sourceView: cell, sourceRect: hot)
                    },
                    ConnectsMenuItem(title: "分叉", icon: .fork) { [weak self] in
                        self?.delegate?.sidebarDidForkConversation(id: conv.id)
                    },
                    ConnectsMenuItem(title: archiveTitle, icon: .archive) { [weak self] in
                        self?.delegate?.sidebarDidArchiveConversation(id: conv.id, archive: !conv.isArchived)
                    },
                    ConnectsMenuItem(title: "删除", icon: .trash, isDestructive: true) { [weak self] in
                        self?.delegate?.sidebarDidDeleteConversation(id: conv.id)
                    }
                ],
                sourceView: cell,
                sourceRect: hot,
                preferVertical: true
            )
        case .project(let project):
            presentProjectMenu(for: project, sourceView: cell, sourceRect: hot)
        }
    }
}
