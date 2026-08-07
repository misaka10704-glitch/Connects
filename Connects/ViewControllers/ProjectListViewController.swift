import UIKit

/// Compact project manager: drag to reorder, color opens a picker page.
final class ProjectSettingsViewController: UIViewController, ThemeRefreshable, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var projects: [Project] = []
    private var suppressReload = false
    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.text = "尚无项目。点右上角「新建」创建第一个项目。"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = DSTheme.bodyFont(size: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "项目"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "新建",
            style: .plain,
            target: self,
            action: #selector(newProjectTapped)
        )

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ProjectSettingsCell.self, forCellReuseIdentifier: ProjectSettingsCell.reuseID)
        tableView.rowHeight = 56
        tableView.keyboardDismissMode = .onDrag
        tableView.allowsSelectionDuringEditing = true
        // Always show reorder grips — the whole point of this screen’s list.
        tableView.setEditing(true, animated: false)
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .projectsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        reloadProjects(reloadTable: true)
        applyTheme()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ProjectSettingsNavBar.applyOpaque(to: navigationController, colors: DSTheme.c)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func applyTheme() {
        let c = DSTheme.c
        view.backgroundColor = c.sidebarBackground
        tableView.backgroundColor = c.sidebarBackground
        emptyLabel.textColor = c.textTertiary
        ProjectSettingsNavBar.applyOpaque(to: navigationController, colors: c)
        tableView.reloadData()
    }

    @objc private func themeChanged() { applyTheme() }

    @objc private func doneTapped() {
        view.endEditing(true)
        dismiss(animated: true)
    }

    @objc private func reload() {
        guard !suppressReload else { return }
        reloadProjects(reloadTable: true)
    }

    private func reloadProjects(reloadTable: Bool) {
        projects = ProjectStore.shared.sortedProjects
        emptyLabel.isHidden = !projects.isEmpty
        tableView.isHidden = projects.isEmpty
        if reloadTable {
            tableView.reloadData()
            if !projects.isEmpty {
                tableView.setEditing(true, animated: false)
            }
        }
    }

    @objc private func newProjectTapped() {
        let alert = UIAlertController(title: "新建项目", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "项目名称" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建", style: .default) { [weak self] _ in
            guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            let project = Project(name: name, colorPreset: ProjectStore.shared.projects.count % 20)
            ProjectStore.shared.upsert(project)
            ConversationStore.shared.setSelectedProjectID(project.id)
            self?.tableView.setContentOffset(.zero, animated: true)
        })
        present(alert, animated: true)
    }

    private func openColorPicker(for project: Project) {
        view.endEditing(true)
        let picker = ProjectColorPickerViewController(projectID: project.id, selectedPreset: project.colorPreset)
        picker.onSelect = { [weak self] preset in
            guard var live = ProjectStore.shared.project(id: project.id) else { return }
            guard live.colorPreset != preset else { return }
            live.colorPreset = preset
            self?.suppressReload = true
            ProjectStore.shared.upsert(live)
            self?.suppressReload = false
            self?.reloadProjects(reloadTable: true)
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func confirmDelete(at index: Int) {
        guard projects.indices.contains(index) else { return }
        let project = projects[index]
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

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { projects.isEmpty ? 0 : 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        projects.count
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard !projects.isEmpty else { return nil }
        return "按右侧把手拖动调整次序。点色点进入选色。左滑删除。修改即时保存。"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ProjectSettingsCell.reuseID, for: indexPath) as! ProjectSettingsCell
        let project = projects[indexPath.row]
        let count = ConversationStore.shared.conversationCount(inProject: project.id)
        cell.configure(project: project, conversationCount: count, theme: DSTheme.c)
        cell.nameField.delegate = self
        cell.nameField.tag = indexPath.row
        cell.onColorTap = { [weak self] in
            self?.openColorPicker(for: project)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 0
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath.section == 0, destinationIndexPath.section == 0 else { return }
        suppressReload = true
        ProjectStore.shared.moveProject(from: sourceIndexPath.row, to: destinationIndexPath.row)
        suppressReload = false
        projects = ProjectStore.shared.sortedProjects
    }

    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        if proposedDestinationIndexPath.section != 0 {
            return IndexPath(row: min(sourceIndexPath.row, max(0, projects.count - 1)), section: 0)
        }
        return proposedDestinationIndexPath
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            self?.confirmDelete(at: indexPath.row)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        let row = textField.tag
        guard projects.indices.contains(row) else { return }
        var project = projects[row]
        let name = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            textField.text = project.name
            return
        }
        guard name != project.name else { return }
        project.name = name
        suppressReload = true
        ProjectStore.shared.upsert(project)
        suppressReload = false
        projects = ProjectStore.shared.sortedProjects
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - Cell

private final class ProjectSettingsCell: UITableViewCell {
    static let reuseID = "ProjectSettingsCell"

    let colorButton = UIButton(type: .system)
    let nameField = UITextField()
    private let metaLabel = UILabel()
    var onColorTap: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        colorButton.translatesAutoresizingMaskIntoConstraints = false
        colorButton.layer.cornerRadius = 12
        colorButton.clipsToBounds = true
        colorButton.accessibilityLabel = "选择颜色"
        colorButton.addTarget(self, action: #selector(colorTapped), for: .touchUpInside)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.borderStyle = .none
        nameField.font = DSTheme.bodyFont(size: 16)
        nameField.returnKeyType = .done
        nameField.clearButtonMode = .whileEditing
        nameField.placeholder = "项目名称"

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = DSTheme.bodyFont(size: 12)

        contentView.addSubview(colorButton)
        contentView.addSubview(nameField)
        contentView.addSubview(metaLabel)
        NSLayoutConstraint.activate([
            colorButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            colorButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            colorButton.widthAnchor.constraint(equalToConstant: 24),
            colorButton.heightAnchor.constraint(equalToConstant: 24),

            nameField.leadingAnchor.constraint(equalTo: colorButton.trailingAnchor, constant: 12),
            nameField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            nameField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            metaLabel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),
            metaLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(project: Project, conversationCount: Int, theme: ThemeColors) {
        let preset = AgentAppearancePreset.preset(project.colorPreset)
        colorButton.backgroundColor = preset.color
        colorButton.setTitle(nil, for: .normal)
        colorButton.layer.borderWidth = 1 / UIScreen.main.scale
        colorButton.layer.borderColor = theme.border.cgColor
        nameField.text = project.name
        nameField.textColor = theme.textPrimary
        nameField.tintColor = theme.accent
        metaLabel.text = "\(conversationCount) 个对话 · \(preset.name)"
        metaLabel.textColor = theme.textTertiary
        backgroundColor = theme.surface
    }

    @objc private func colorTapped() {
        onColorTap?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onColorTap = nil
        nameField.delegate = nil
    }
}

// MARK: - Color picker page

private final class ProjectColorPickerViewController: UIViewController, ThemeRefreshable {
    private let projectID: String
    private var selectedPreset: Int
    var onSelect: ((Int) -> Void)?

    private let scrollView = UIScrollView()
    private let grid = UIStackView()
    private var buttons: [UIButton] = []

    init(projectID: String, selectedPreset: Int) {
        self.projectID = projectID
        self.selectedPreset = selectedPreset
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "选择颜色"
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.axis = .vertical
        grid.spacing = 12
        scrollView.addSubview(grid)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            grid.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            grid.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40)
        ])

        buildGrid()
        applyTheme()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ProjectSettingsNavBar.applyOpaque(to: navigationController, colors: DSTheme.c)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func applyTheme() {
        let c = DSTheme.c
        view.backgroundColor = c.sidebarBackground
        scrollView.backgroundColor = c.sidebarBackground
        ProjectSettingsNavBar.applyOpaque(to: navigationController, colors: c)
        refreshSelectionBorders()
    }

    @objc private func themeChanged() { applyTheme() }

    private func buildGrid() {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        let columns = 5
        let presets = AgentAppearancePreset.all
        var row: UIStackView?
        for (i, preset) in presets.enumerated() {
            if i % columns == 0 {
                row = UIStackView()
                row?.axis = .horizontal
                row?.spacing = 12
                row?.distribution = .fillEqually
                row?.alignment = .center
                grid.addArrangedSubview(row!)
            }
            let button = UIButton(type: .custom)
            button.tag = preset.index
            button.backgroundColor = preset.color
            button.layer.cornerRadius = 22
            button.accessibilityLabel = preset.name
            button.addTarget(self, action: #selector(presetTapped(_:)), for: .touchUpInside)
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            row?.addArrangedSubview(button)
            buttons.append(button)
        }
        // Pad last row so fillEqually stays even.
        if let row = row {
            let remainder = presets.count % columns
            if remainder != 0 {
                for _ in remainder..<columns {
                    let spacer = UIView()
                    spacer.isUserInteractionEnabled = false
                    row.addArrangedSubview(spacer)
                }
            }
        }
        refreshSelectionBorders()
    }

    private func refreshSelectionBorders() {
        let border = DSTheme.c.textPrimary.cgColor
        for button in buttons {
            let selected = button.tag == selectedPreset
            button.layer.borderWidth = selected ? 3 : 0
            button.layer.borderColor = selected ? border : UIColor.clear.cgColor
        }
    }

    @objc private func presetTapped(_ sender: UIButton) {
        selectedPreset = sender.tag
        refreshSelectionBorders()
        onSelect?(sender.tag)
        navigationController?.popViewController(animated: true)
    }
}

// MARK: - Opaque nav bar (iOS 15+ scrollEdge defaults to transparent)

private enum ProjectSettingsNavBar {
    static func applyOpaque(to navigationController: UINavigationController?, colors c: ThemeColors) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = c.sidebarBackground
        appearance.titleTextAttributes = [.foregroundColor: c.textPrimary]
        appearance.largeTitleTextAttributes = [.foregroundColor: c.textPrimary]
        appearance.shadowColor = .clear

        guard let navBar = navigationController?.navigationBar else { return }
        navBar.standardAppearance = appearance
        navBar.scrollEdgeAppearance = appearance
        navBar.compactAppearance = appearance
        if #available(iOS 15.0, *) {
            navBar.compactScrollEdgeAppearance = appearance
        }
        navBar.isTranslucent = false
        navBar.barTintColor = c.sidebarBackground
        navBar.tintColor = c.accent
        navBar.barStyle = c.navBarStyle
        navBar.titleTextAttributes = [.foregroundColor: c.textPrimary]
        navigationController?.view.backgroundColor = c.sidebarBackground
    }
}
