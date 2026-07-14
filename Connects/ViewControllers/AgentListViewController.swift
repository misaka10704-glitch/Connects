import UIKit

final class AgentListViewController: UITableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "智能体库"
        tableView.rowHeight = 64
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 62, bottom: 0, right: 16)
        tableView.backgroundColor = DSTheme.c.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addAgent))
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .agentsDidChange, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func reload() { tableView.reloadData() }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { AgentStore.shared.agents.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let agent = AgentStore.shared.agents[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "Agent")
        cell.textLabel?.text = agent.name
        cell.detailTextLabel?.text = "\(agent.isEnabled ? "已启用" : "已停用") · \(DateFormatter.localizedString(from: agent.updatedAt, dateStyle: .short, timeStyle: .short))"
        cell.imageView?.image = AgentAppearancePreset.avatar(for: agent)
        cell.imageView?.layer.cornerRadius = 15
        cell.imageView?.clipsToBounds = true
        cell.accessoryType = .disclosureIndicator
        cell.textLabel?.textColor = agent.isEnabled ? DSTheme.c.textPrimary : DSTheme.c.textTertiary
        cell.detailTextLabel?.textColor = DSTheme.c.textSecondary
        cell.backgroundColor = DSTheme.c.surface
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        navigationController?.pushViewController(AgentEditorViewController(agent: AgentStore.shared.agents[indexPath.row]), animated: true)
    }
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        AgentStore.shared.delete(id: AgentStore.shared.agents[indexPath.row].id)
    }
    @objc private func addAgent() {
        let alert = UIAlertController(title: "新建智能体", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "名称" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建", style: .default) { [weak self] _ in
            guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self?.navigationController?.pushViewController(AgentEditorViewController(agent: CustomAgent(name: name, userRequirements: "", polishedPrompt: "")), animated: true)
        })
        present(alert, animated: true)
    }
}

final class AgentEditorViewController: UIViewController, UITextViewDelegate {
    private var agent: CustomAgent
    private let requirements = UITextView()
    private let prompt = UITextView()
    private let enabled = UISwitch()
    private let nameField = UITextField()
    private let presetScroll = UIScrollView()
    private var colorButtons: [UIButton] = []
    private var editorScroll: UIScrollView?

    init(agent: CustomAgent) { self.agent = agent; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = agent.name
        view.backgroundColor = DSTheme.c.sidebarBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(save))
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16)
        ])
        editorScroll = scroll
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nameField.borderStyle = .roundedRect; nameField.text = agent.name; nameField.placeholder = "智能体名称"
        stack.addArrangedSubview(nameField)
        let row = UIStackView(); row.axis = .horizontal
        let label = UILabel(); label.text = "启用"; label.textColor = DSTheme.c.textPrimary
        row.addArrangedSubview(label); row.addArrangedSubview(enabled); stack.addArrangedSubview(row)
        stack.addArrangedSubview(makeLabel("颜色"))
        presetScroll.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let presetStack = UIStackView(); presetStack.spacing = 8; presetStack.alignment = .center; presetStack.translatesAutoresizingMaskIntoConstraints = false
        presetScroll.addSubview(presetStack)
        NSLayoutConstraint.activate([presetStack.leadingAnchor.constraint(equalTo: presetScroll.leadingAnchor), presetStack.trailingAnchor.constraint(equalTo: presetScroll.trailingAnchor), presetStack.topAnchor.constraint(equalTo: presetScroll.topAnchor), presetStack.bottomAnchor.constraint(equalTo: presetScroll.bottomAnchor), presetStack.heightAnchor.constraint(equalTo: presetScroll.heightAnchor)])
        for preset in AgentAppearancePreset.all {
            let button = UIButton(type: .custom); button.tag = preset.index
            button.backgroundColor = preset.color; button.layer.cornerRadius = 15
            button.layer.borderWidth = 2; button.addTarget(self, action: #selector(selectPreset(_:)), for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            colorButtons.append(button); presetStack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(presetScroll)
        stack.addArrangedSubview(makeLabel("原始要求")); configure(requirements); requirements.heightAnchor.constraint(equalToConstant: 120).isActive = true; stack.addArrangedSubview(requirements)
        stack.addArrangedSubview(makeLabel("实际 system prompt")); configure(prompt); prompt.heightAnchor.constraint(equalToConstant: 220).isActive = true; stack.addArrangedSubview(prompt)
        let polishButton = UIButton(type: .system); polishButton.setTitle("AI 润色", for: .normal); polishButton.addTarget(self, action: #selector(polish), for: .touchUpInside); stack.addArrangedSubview(polishButton)
        requirements.text = agent.userRequirements; prompt.text = agent.polishedPrompt; enabled.isOn = agent.isEnabled
        updateColorSelection()
    }
    private func makeLabel(_ text: String) -> UILabel { let l = UILabel(); l.text = text; l.font = UIFont.systemFont(ofSize: 13, weight: .semibold); l.textColor = DSTheme.c.textSecondary; return l }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func keyboardChanged(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        editorScroll?.contentInset.bottom = overlap + 16
        editorScroll?.scrollIndicatorInsets.bottom = overlap
    }
    private func configure(_ view: UITextView) { view.font = DSTheme.monoFont(size: 14); view.backgroundColor = DSTheme.c.surface; view.textColor = DSTheme.c.textPrimary; view.layer.cornerRadius = 10; view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8); view.delegate = self }
    func textViewDidBeginEditing(_ textView: UITextView) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let rect = textView.convert(textView.bounds, to: self.editorScroll)
            self.editorScroll?.scrollRectToVisible(rect.insetBy(dx: 0, dy: -24), animated: true)
        }
    }
    @objc private func selectPreset(_ sender: UIButton) { agent.iconPreset = sender.tag; updateColorSelection() }
    private func updateColorSelection() {
        for button in colorButtons {
            let selected = button.tag == agent.iconPreset
            button.layer.borderColor = (selected ? DSTheme.c.textPrimary : UIColor.clear).cgColor
            button.transform = selected ? CGAffineTransform(scaleX: 1.14, y: 1.14) : .identity
            button.accessibilityLabel = selected ? "已选择颜色" : "选择颜色"
        }
    }
    @objc private func save() { agent.name = nameField.text ?? agent.name; agent.userRequirements = requirements.text; agent.polishedPrompt = prompt.text; agent.isEnabled = enabled.isOn; AgentStore.shared.upsert(agent); navigationController?.popViewController(animated: true) }
    @objc private func polish() {
        AgentPromptPolisher.polish(requirements: requirements.text, model: ConversationStore.shared.currentConversation?.model ?? .deepseekV4Flash) { [weak self] result in
            guard case .success(let proposal) = result, let self = self else { return }
            DispatchQueue.main.async { self.prompt.text = proposal }
        }
    }
}
