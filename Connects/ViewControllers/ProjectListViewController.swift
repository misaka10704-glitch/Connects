import UIKit

/// Modal project manager — same form-sheet pattern as Settings; no nested editor page.
final class ProjectSettingsViewController: UIViewController, ThemeRefreshable, UITextFieldDelegate {
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private var sectionLabels: [UILabel] = []
    private var cards: [UIView] = []
    private var footerLabels: [UILabel] = []
    private var nameFields: [String: UITextField] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "项目"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .projectsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        buildForm()
        applyTheme()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func applyTheme() {
        let c = DSTheme.c
        view.backgroundColor = c.sidebarBackground
        scrollView.backgroundColor = c.sidebarBackground
        navigationController?.navigationBar.barStyle = c.navBarStyle
        navigationController?.navigationBar.tintColor = c.accent
        navigationController?.navigationBar.barTintColor = c.sidebarBackground
        navigationController?.navigationBar.isTranslucent = false
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: c.textPrimary]
        sectionLabels.forEach { $0.textColor = c.textSecondary }
        footerLabels.forEach { $0.textColor = c.textTertiary }
        cards.forEach {
            $0.backgroundColor = c.surface
            $0.layer.borderColor = c.border.cgColor
        }
        nameFields.values.forEach {
            $0.textColor = c.textPrimary
            $0.tintColor = c.accent
        }
    }

    @objc private func themeChanged() { applyTheme() }
    @objc private func doneTapped() {
        view.endEditing(true)
        dismiss(animated: true)
    }

    @objc private func reload() {
        buildForm()
        applyTheme()
    }

    private func buildForm() {
        nameFields.removeAll()
        sectionLabels.removeAll()
        cards.removeAll()
        footerLabels.removeAll()
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if scrollView.superview == nil {
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.alwaysBounceVertical = true
            scrollView.keyboardDismissMode = .onDrag
            view.addSubview(scrollView)
            contentStack.translatesAutoresizingMaskIntoConstraints = false
            contentStack.axis = .vertical
            contentStack.spacing = 8
            contentStack.alignment = .fill
            scrollView.addSubview(contentStack)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
                contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
                contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
                contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
                contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40)
            ])
        }

        let projects = ProjectStore.shared.sortedProjects
        if projects.isEmpty {
            let empty = UILabel()
            empty.text = "尚无项目。在侧栏「项目」旁点 + 新建。"
            empty.numberOfLines = 0
            empty.font = DSTheme.bodyFont(size: 14)
            footerLabels.append(empty)
            contentStack.addArrangedSubview(empty)
            return
        }

        for project in projects {
            contentStack.addArrangedSubview(makeSectionTitle(project.name))
            contentStack.addArrangedSubview(makeProjectCard(project))
            contentStack.setCustomSpacing(14, after: contentStack.arrangedSubviews.last!)
        }

        let tip = UILabel()
        tip.numberOfLines = 0
        tip.font = DSTheme.bodyFont(size: 13)
        tip.text = "修改会即时保存。删除项目后，其中对话会变为未分类。"
        footerLabels.append(tip)
        contentStack.addArrangedSubview(tip)
    }

    private func makeProjectCard(_ project: Project) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10

        let nameField = UITextField()
        nameField.borderStyle = .roundedRect
        nameField.text = project.name
        nameField.placeholder = "项目名称"
        nameField.delegate = self
        nameField.tag = project.colorPreset
        nameField.accessibilityIdentifier = project.id
        nameFields[project.id] = nameField
        stack.addArrangedSubview(nameField)

        let colorRow = UIStackView()
        colorRow.spacing = 8
        colorRow.alignment = .center
        for preset in AgentAppearancePreset.all {
            let button = UIButton(type: .custom)
            button.tag = preset.index
            button.backgroundColor = preset.color
            button.layer.cornerRadius = 14
            button.layer.borderWidth = 2
            button.layer.borderColor = (preset.index == project.colorPreset
                ? DSTheme.c.textPrimary
                : UIColor.clear).cgColor
            button.accessibilityIdentifier = project.id
            button.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            colorRow.addArrangedSubview(button)
        }
        stack.addArrangedSubview(colorRow)

        let count = ConversationStore.shared.conversationCount(inProject: project.id)
        let meta = UILabel()
        meta.font = DSTheme.bodyFont(size: 13)
        meta.text = "\(count) 个对话"
        footerLabels.append(meta)
        stack.addArrangedSubview(meta)

        let deleteButton = UIButton(type: .system)
        deleteButton.setTitle("删除项目", for: .normal)
        if #available(iOS 13.0, *) {
            deleteButton.setTitleColor(.systemRed, for: .normal)
        } else {
            deleteButton.setTitleColor(UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1), for: .normal)
        }
        deleteButton.contentHorizontalAlignment = .left
        deleteButton.accessibilityIdentifier = project.id
        deleteButton.addTarget(self, action: #selector(deleteTapped(_:)), for: .touchUpInside)
        stack.addArrangedSubview(deleteButton)

        return makeCard(embedding: stack, inset: 12)
    }

    private func makeSectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        sectionLabels.append(label)
        return label
    }

    private func makeCard(embedding view: UIView, inset: CGFloat) -> UIView {
        let card = UIView()
        card.layer.cornerRadius = 12
        card.layer.borderWidth = 1 / UIScreen.main.scale
        cards.append(card)
        view.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            view.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            view.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset)
        ])
        return card
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard let id = textField.accessibilityIdentifier,
              var project = ProjectStore.shared.project(id: id) else { return }
        let name = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            textField.text = project.name
            return
        }
        project.name = name
        ProjectStore.shared.upsert(project)
    }

    @objc private func colorTapped(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier,
              var project = ProjectStore.shared.project(id: id) else { return }
        project.colorPreset = sender.tag
        ProjectStore.shared.upsert(project)
    }

    @objc private func deleteTapped(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier,
              let project = ProjectStore.shared.project(id: id) else { return }
        let alert = UIAlertController(
            title: "删除「\(project.name)」？",
            message: "项目内对话将变为未分类，不会被删除。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            ProjectStore.shared.delete(id: id)
        })
        present(alert, animated: true)
    }
}
