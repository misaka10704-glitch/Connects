import UIKit

/// A focused editor for every prompt that affects agents or Memory. Nothing is
/// hidden: users can inspect, edit, restore defaults, and review AI proposals.
final class PromptStudioViewController: UIViewController, UITextViewDelegate {
    private let targetControl = UISegmentedControl(items: ["智能体", "智能体润色", "Memory 记录", "Memory 合并", "Memory 注入"])
    private let titleLabel = UILabel()
    private let requirementsView = UITextView()
    private let promptView = UITextView()
    private let chooseButton = UIButton(type: .system)
    private let polishButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let restoreButton = UIButton(type: .system)
    private var agentID: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Prompt 工作台"
        view.backgroundColor = DSTheme.c.sidebarBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "清空 Memory",
                                                            style: .plain,
                                                            target: self,
                                                            action: #selector(clearMemory))
        build()
        if let first = AgentStore.shared.agents.first {
            agentID = first.id
        }
        loadTarget()
    }

    private func build() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])

        targetControl.selectedSegmentIndex = 0
        targetControl.addTarget(self, action: #selector(targetChanged), for: .valueChanged)
        stack.addArrangedSubview(targetControl)

        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = DSTheme.c.textPrimary
        stack.addArrangedSubview(titleLabel)

        chooseButton.contentHorizontalAlignment = .left
        chooseButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        chooseButton.addTarget(self, action: #selector(chooseAgent), for: .touchUpInside)
        stack.addArrangedSubview(chooseButton)

        let reqLabel = label("原始要求（可选，供 AI 润色）")
        stack.addArrangedSubview(reqLabel)
        configure(requirementsView)
        requirementsView.heightAnchor.constraint(equalToConstant: 105).isActive = true
        stack.addArrangedSubview(requirementsView)

        stack.addArrangedSubview(label("实际使用的 prompt"))
        configure(promptView)
        promptView.heightAnchor.constraint(equalToConstant: 210).isActive = true
        stack.addArrangedSubview(promptView)

        let actions = UIStackView()
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 8
        [polishButton, restoreButton, saveButton].forEach {
            $0.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
            actions.addArrangedSubview($0)
        }
        polishButton.setTitle("AI 润色", for: .normal)
        restoreButton.setTitle("恢复默认", for: .normal)
        saveButton.setTitle("保存", for: .normal)
        polishButton.addTarget(self, action: #selector(polish), for: .touchUpInside)
        restoreButton.addTarget(self, action: #selector(restoreDefault), for: .touchUpInside)
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        stack.addArrangedSubview(actions)
    }

    private func configure(_ view: UITextView) {
        view.font = DSTheme.monoFont(size: 14)
        view.textColor = DSTheme.c.textPrimary
        view.backgroundColor = DSTheme.c.surface
        view.layer.borderColor = DSTheme.c.border.cgColor
        view.layer.borderWidth = 1 / UIScreen.main.scale
        view.layer.cornerRadius = 10
        view.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        view.autocorrectionType = .default
    }

    private func label(_ text: String) -> UILabel {
        let result = UILabel()
        result.text = text
        result.textColor = DSTheme.c.textSecondary
        result.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        return result
    }

    private var selectedMemoryKind: MemoryPromptKind? {
        switch targetControl.selectedSegmentIndex {
        case 2: return .capture
        case 3: return .compaction
        case 4: return .injection
        default: return nil
        }
    }

    private var editingPolisherPrompt: Bool { targetControl.selectedSegmentIndex == 1 }

    @objc private func targetChanged() { loadTarget() }

    @objc private func clearMemory() {
        let alert = UIAlertController(
            title: "清空本机 Memory？",
            message: "将删除长期背景与所有按日日志，无法恢复；不会删除对话记录。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            MemoryStore.shared.clearAll()
            self?.showMessage("Memory 已清空")
        })
        present(alert, animated: true)
    }

    private func loadTarget() {
        let isAgent = selectedMemoryKind == nil && !editingPolisherPrompt
        chooseButton.isHidden = !isAgent
        requirementsView.isHidden = !isAgent
        polishButton.isHidden = !isAgent
        restoreButton.isHidden = isAgent
        if editingPolisherPrompt {
            titleLabel.text = "智能体润色 prompt"
            promptView.text = AgentPromptPolisher.promptTemplate
        } else if let kind = selectedMemoryKind {
            titleLabel.text = kind.title + " prompt"
            promptView.text = MemoryStore.shared.prompt(for: kind)
        } else if let agent = AgentStore.shared.agents.first(where: { $0.id == agentID }) {
            titleLabel.text = "智能体：\(agent.name)"
            chooseButton.setTitle("切换或新建智能体", for: .normal)
            requirementsView.text = agent.userRequirements
            promptView.text = agent.polishedPrompt
        } else {
            titleLabel.text = "新智能体"
            chooseButton.setTitle("新建智能体", for: .normal)
            requirementsView.text = ""
            promptView.text = ""
        }
    }

    @objc private func chooseAgent() {
        let alert = UIAlertController(title: "选择智能体", message: nil, preferredStyle: .actionSheet)
        for agent in AgentStore.shared.agents {
            alert.addAction(UIAlertAction(title: agent.name, style: .default) { [weak self] _ in
                self?.agentID = agent.id
                self?.loadTarget()
            })
        }
        alert.addAction(UIAlertAction(title: "新建智能体", style: .default) { [weak self] _ in
            self?.createAgent()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = chooseButton
            pop.sourceRect = chooseButton.bounds
        }
        present(alert, animated: true)
    }

    private func createAgent() {
        let alert = UIAlertController(title: "新建智能体", message: "输入名称后，可在此编辑要求与 prompt。", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "例如：严谨写作助手" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建", style: .default) { [weak self] _ in
            guard let self = self,
                  let rawName = alert.textFields?.first?.text,
                  let name = Optional(rawName.trimmingCharacters(in: .whitespacesAndNewlines)),
                  !name.isEmpty else { return }
            let agent = CustomAgent(name: name, userRequirements: "", polishedPrompt: "请遵循用户当前请求，保持准确、清晰与简洁。")
            AgentStore.shared.upsert(agent)
            self.agentID = agent.id
            self.loadTarget()
        })
        present(alert, animated: true)
    }

    @objc private func save() {
        let text = promptView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let kind = selectedMemoryKind {
            MemoryStore.shared.setPrompt(text, for: kind)
        } else if editingPolisherPrompt {
            AgentPromptPolisher.setPromptTemplate(text)
        } else if var agent = AgentStore.shared.agents.first(where: { $0.id == agentID }) {
            agent.userRequirements = requirementsView.text
            agent.polishedPrompt = text
            AgentStore.shared.upsert(agent)
        }
        showMessage("已保存")
    }

    @objc private func restoreDefault() {
        if editingPolisherPrompt {
            AgentPromptPolisher.restoreDefaultPrompt()
        } else if let kind = selectedMemoryKind {
            MemoryStore.shared.restoreDefaultPrompt(for: kind)
        } else {
            return
        }
        loadTarget()
    }

    @objc private func polish() {
        guard selectedMemoryKind == nil, !editingPolisherPrompt else { return }
        let requirements = requirementsView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requirements.isEmpty else {
            showMessage("先填写原始要求")
            return
        }
        polishButton.isEnabled = false
        let model = ConversationStore.shared.currentConversation?.model ?? .deepseekV4Flash
        AgentPromptPolisher.polish(requirements: requirements, model: model) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.polishButton.isEnabled = true
                guard case .success(let proposal) = result else {
                    self.showMessage("润色失败，请检查 API Key 后重试")
                    return
                }
                let preview = DiffPreviewViewController(before: self.promptView.text, after: proposal,
                                                        keep: { self.promptView.text = proposal },
                                                        undo: {})
                self.navigationController?.pushViewController(preview, animated: true)
            }
        }
    }

    private func showMessage(_ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { alert.dismiss(animated: true) }
    }
}
