import UIKit

protocol ChatViewControllerDelegate: AnyObject {
    func chatDidUpdateTitle(_ title: String)
    func chatDidRequestShare()
}

final class ChatViewController: UIViewController, ThemeRefreshable, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    weak var delegate: ChatViewControllerDelegate?
    var onToggleSidebar: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let inputBar = InputBarView()
    private let modelButton = UIButton(type: .system)
    private let emptyTitleLabel = UILabel()
    private let emptySubtitleLabel = UILabel()
    private var sidebarToggleItem: UIBarButtonItem?
    private var pendingSidebarCollapsed: Bool?
    private var bottomConstraint: NSLayoutConstraint?
    private var isReloadingFromStore = false
    private var contentHeights: [String: CGFloat] = [:]
    private var stickToBottom = true
    private var streamUIWork: DispatchWorkItem?

    private var currentConversationID: String? {
        ConversationStore.shared.currentConversationID
    }

    private var isCurrentStreaming: Bool {
        guard let id = currentConversationID else { return false }
        return StreamManager.shared.isRunning(id)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupNavBar()
        setupTable()
        setupInputBar()
        setupEmptyState()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: .conversationStoreDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamUpdated(_:)), name: .streamManagerDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamFinished(_:)), name: .streamManagerDidFinish, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(thinkingToggled), name: Notification.Name("ConnectsThinkingToggle"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged), name: .chatFontSizeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamTTFT(_:)), name: Notification.Name("ConnectsStreamTTFT"), object: nil)
        registerKeyboard()
        applyTheme()
        reloadChat()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func applyTheme() {
        let c = DSTheme.c
        view.backgroundColor = c.background
        tableView.backgroundColor = c.background
        emptyTitleLabel.textColor = c.textPrimary
        emptySubtitleLabel.textColor = c.textSecondary
        modelButton.setTitleColor(c.textPrimary, for: .normal)
        modelButton.backgroundColor = .clear
        modelButton.layer.borderWidth = 0
        modelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        navigationController?.navigationBar.barStyle = c.navBarStyle
        navigationController?.navigationBar.barTintColor = c.background
        navigationController?.navigationBar.tintColor = c.textPrimary
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.isTranslucent = false
        navigationController?.view.backgroundColor = c.background
        setNeedsStatusBarAppearanceUpdate()
        inputBar.applyTheme()
        tableView.reloadData()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { DSTheme.c.statusBarStyle }

    @objc private func themeChanged() { applyTheme() }

    @objc private func storeChanged() {
        guard !isReloadingFromStore else { return }
        reloadChat()
    }

    @objc private func streamUpdated(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else { return }
        scheduleStreamUIRefresh()
    }

    @objc private func thinkingToggled() {
        tableView.reloadData()
    }

    @objc private func fontSizeChanged() {
        contentHeights.removeAll()
        tableView.reloadData()
    }

    @objc private func streamTTFT(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID,
              let ms = note.userInfo?["ms"] as? Int,
              let host = note.userInfo?["host"] as? String else { return }
        // Only surface when it feels stuck — helps diagnose endpoint / history bloat.
        guard ms >= 4000 else { return }
        let think = (note.userInfo?["thinking"] as? Bool) ?? false
        let tip = "首包 \(ms)ms · \(host)\(think ? " · 思考开" : " · Instant")"
        navigationItem.prompt = tip
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.navigationItem.prompt == tip {
                self?.navigationItem.prompt = nil
            }
        }
    }

    @objc private func streamFinished(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else { return }
        streamUIWork?.cancel()
        syncStreamingChrome()
        reloadChat()
    }

    private func scheduleStreamUIRefresh() {
        streamUIWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshStreamingRow()
        }
        streamUIWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func refreshStreamingRow() {
        syncStreamingChrome()
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let last = messages.last, last.isStreaming else {
            tableView.reloadData()
            return
        }
        let path = IndexPath(row: messages.count - 1, section: 0)
        UIView.performWithoutAnimation {
            if let cell = tableView.cellForRow(at: path) as? MessageCell {
                cell.configure(with: last, preferredHeight: contentHeights[last.id])
                tableView.beginUpdates()
                tableView.endUpdates()
            } else {
                tableView.reloadRows(at: [path], with: .none)
            }
            if stickToBottom {
                scrollToBottom(animated: false)
            }
        }
    }

    private func syncStreamingChrome() {
        let running = isCurrentStreaming
        inputBar.isStreaming = running
    }

    func updateSidebarToggleTitle(collapsed: Bool) {
        pendingSidebarCollapsed = collapsed
        guard let item = sidebarToggleItem else { return }
        let kind: ActionIconFactory.Kind = collapsed ? .sidebar : .sidebarOpen
        item.image = ActionIconFactory.image(kind, pointSize: 18)
        item.accessibilityLabel = collapsed ? "打开侧栏" : "关闭侧栏"
    }

    func reloadChat() {
        isReloadingFromStore = true
        tableView.reloadData()
        scrollToBottom(animated: false)
        updateModelButton()
        updateEmptyState()
        updateAttachAvailability()
        updateTitleFromConversation()
        syncStreamingChrome()
        isReloadingFromStore = false
    }

    func shareCurrentMarkdown() {
        guard let conv = ConversationStore.shared.currentConversation else { return }
        guard let url = MarkdownExporter.write(conv) else {
            showAlert(title: "导出失败", message: "无法写入 Markdown 文件。")
            return
        }
        let plain = MarkdownExporter.renderPlain(conv)
        let activity = UIActivityViewController(activityItems: [url, plain], applicationActivities: nil)
        if let pop = activity.popoverPresentationController {
            pop.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(activity, animated: true)
    }

    @objc private func toggleSidebar() { onToggleSidebar?() }

    @objc private func moreTapped() {
        guard let conv = ConversationStore.shared.currentConversation else { return }
        let sheet = UIAlertController(title: conv.title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "分享 / 导出 Markdown", style: .default) { [weak self] _ in
            self?.shareCurrentMarkdown()
        })
        sheet.addAction(UIAlertAction(title: "复制全部对话", style: .default) { [weak self] _ in
            self?.copyEntireConversation()
        })
        sheet.addAction(UIAlertAction(title: "重命名", style: .default) { [weak self] _ in
            self?.presentRename(conv.id, current: conv.title)
        })
        sheet.addAction(UIAlertAction(title: "分叉对话", style: .default) { _ in
            _ = ConversationStore.shared.forkConversation(id: conv.id)
        })
        let archiveTitle = conv.isArchived ? "取消归档" : "归档"
        sheet.addAction(UIAlertAction(title: archiveTitle, style: .default) { _ in
            ConversationStore.shared.setArchived(id: conv.id, archived: !conv.isArchived)
        })
        sheet.addAction(UIAlertAction(title: "重跑上一轮", style: .default) { [weak self] _ in
            self?.retryLastTurn()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(sheet, animated: true)
    }

    private func setupNavBar() {
        modelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        modelButton.addTarget(self, action: #selector(modelTapped), for: .touchUpInside)
        navigationItem.titleView = modelButton

        sidebarToggleItem = ActionIconFactory.barItem(
            kind: .sidebarOpen,
            target: self,
            action: #selector(toggleSidebar),
            accessibility: "关闭侧栏"
        )
        // ChatGPT-style: single overflow on the right (share/export lives inside)
        let moreItem = ActionIconFactory.barItem(
            kind: .more,
            target: self,
            action: #selector(moreTapped),
            accessibility: "更多"
        )
        navigationItem.leftBarButtonItem = sidebarToggleItem
        navigationItem.rightBarButtonItem = moreItem
        if let collapsed = pendingSidebarCollapsed {
            updateSidebarToggleTitle(collapsed: collapsed)
        }

        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
    }

    private func setupTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 80
        tableView.rowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .interactive
        tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseID)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.addSubview(tableView)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleMessageLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        tableView.addGestureRecognizer(longPress)
    }

    private func setupInputBar() {
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.delegate = self
        view.addSubview(inputBar)

        bottomConstraint = inputBar.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: -DSTheme.inputBarBottomPadding
        )

        let inputWidthFill = inputBar.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -DSTheme.contentHorizontalPadding * 2)
        inputWidthFill.priority = UILayoutPriority(999)
        let inputWidthMax = inputBar.widthAnchor.constraint(lessThanOrEqualToConstant: DSTheme.contentMaxWidth)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            inputBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            inputWidthFill,
            inputWidthMax,
            bottomConstraint!,
            inputBar.heightAnchor.constraint(greaterThanOrEqualToConstant: DSTheme.inputBarHeight + 8)
        ])
    }

    private func setupEmptyState() {
        emptyTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyTitleLabel.text = "今天想聊些什么？"
        emptyTitleLabel.textAlignment = .center
        emptyTitleLabel.font = UIFont.systemFont(ofSize: 28, weight: .semibold)
        view.addSubview(emptyTitleLabel)

        emptySubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        emptySubtitleLabel.text = "DeepSeek · Kimi · 支持思考过程与 Markdown"
        emptySubtitleLabel.textAlignment = .center
        emptySubtitleLabel.font = DSTheme.bodyFont(size: 14)
        view.addSubview(emptySubtitleLabel)

        let chips = UIStackView()
        chips.axis = .vertical
        chips.spacing = 10
        chips.translatesAutoresizingMaskIntoConstraints = false
        chips.tag = 8801
        view.addSubview(chips)

        let prompts = [
            "解释一个概念，尽量通俗",
            "帮我写一段清晰的代码",
            "用表格对比几个方案"
        ]
        for p in prompts {
            let b = UIButton(type: .system)
            b.setTitle(p, for: .normal)
            b.titleLabel?.font = DSTheme.bodyFont(size: 14)
            b.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
            b.layer.cornerRadius = 14
            b.layer.borderWidth = 1
            b.addTarget(self, action: #selector(suggestionTapped(_:)), for: .touchUpInside)
            chips.addArrangedSubview(b)
        }

        NSLayoutConstraint.activate([
            emptyTitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyTitleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -90),
            emptySubtitleLabel.topAnchor.constraint(equalTo: emptyTitleLabel.bottomAnchor, constant: 10),
            emptySubtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            chips.topAnchor.constraint(equalTo: emptySubtitleLabel.bottomAnchor, constant: 28),
            chips.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            chips.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
    }

    @objc private func suggestionTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        sendMessage(title, imageBase64: nil)
    }

    private func updateEmptyState() {
        let empty = (ConversationStore.shared.currentConversation?.messages.count ?? 0) == 0
        emptyTitleLabel.isHidden = !empty
        emptySubtitleLabel.isHidden = !empty
        tableView.isHidden = empty
        view.viewWithTag(8801)?.isHidden = !empty
        if empty {
            let c = DSTheme.c
            emptyTitleLabel.textColor = c.textPrimary
            emptySubtitleLabel.textColor = c.textSecondary
            if let chips = view.viewWithTag(8801) as? UIStackView {
                for case let b as UIButton in chips.arrangedSubviews {
                    b.setTitleColor(c.textPrimary, for: .normal)
                    b.backgroundColor = c.surface
                    b.layer.borderColor = c.border.cgColor
                }
            }
        }
    }

    private func updateModelButton() {
        let model = ConversationStore.shared.currentConversation?.model ?? .deepseekV4Pro
        modelButton.setTitle("\(model.displayName) ▾", for: .normal)
        modelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        modelButton.sizeToFit()
    }

    private func updateAttachAvailability() {
        // Always allow picking; send path validates vision support
        inputBar.attachEnabled = true
    }

    private func updateTitleFromConversation() {
        if let title = ConversationStore.shared.currentConversation?.title {
            delegate?.chatDidUpdateTitle(title)
        }
    }

    private func registerKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }
        let converted = view.convert(frame, from: nil)
        let overlap = max(0, view.bounds.maxY - converted.origin.y)
        bottomConstraint?.constant = overlap > 0 ? -overlap - 4 : -DSTheme.inputBarBottomPadding
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    }

    @objc private func handleMessageLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point),
              let msg = ConversationStore.shared.currentConversation?.messages[indexPath.row],
              !msg.isStreaming else { return }

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "复制", style: .default) { _ in
            UIPasteboard.general.string = msg.copyableText
        })
        if msg.role == .assistant || msg.role == .user {
            sheet.addAction(UIAlertAction(title: "重跑", style: .default) { [weak self] _ in
                self?.retryFromMessage(at: indexPath.row)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = sheet.popoverPresentationController,
           let cell = tableView.cellForRow(at: indexPath) {
            pop.sourceView = cell
            pop.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    private func copyEntireConversation() {
        guard let conv = ConversationStore.shared.currentConversation else { return }
        UIPasteboard.general.string = MarkdownExporter.renderPlain(conv)
        showAlert(title: "已复制", message: "全部对话已复制到剪贴板。")
    }

    private func apiContext(for model: AIModelOption) -> [ChatMessage] {
        let raw = ConversationStore.shared.currentConversation?.messages ?? []
        return ContextBuilder.messagesForAPI(from: raw, model: model)
    }

    private func retryLastTurn() {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else {
            showAlert(title: "无法重跑", message: "没有可重跑的用户消息。")
            return
        }
        retryFromMessage(at: lastUserIdx)
    }

    private func retryFromMessage(at index: Int) {
        guard let conv = ConversationStore.shared.currentConversation,
              index >= 0, index < conv.messages.count else { return }
        if StreamManager.shared.isRunning(conv.id) {
            showAlert(title: "正在生成", message: "当前对话仍在回复中，请先停止或等待完成。")
            return
        }

        var userIndex = index
        if conv.messages[index].role == .assistant {
            userIndex = index - 1
            while userIndex >= 0, conv.messages[userIndex].role != .user {
                userIndex -= 1
            }
        }
        guard userIndex >= 0, conv.messages[userIndex].role == .user else {
            showAlert(title: "无法重跑", message: "找不到对应的用户消息。")
            return
        }

        let provider = conv.model.provider
        guard SettingsManager.shared.hasAPIKey(for: provider) else {
            showAlert(title: "缺少 API Key", message: "请先在设置中填写 \(provider.displayName) 的 API Key。")
            return
        }

        let needsAITitle = (conv.title == "新对话" || conv.title.hasSuffix("（分叉）")) && !conv.titleLocked
        let convID = conv.id

        ConversationStore.shared.updateCurrent { c in
            if c.messages.count > userIndex + 1 {
                c.messages.removeSubrange((userIndex + 1)..<c.messages.count)
            }
            c.messages.append(ChatMessage(role: .assistant, content: "", reasoningContent: "", isStreaming: true))
        }

        stickToBottom = true
        updateEmptyState()
        tableView.reloadData()
        scrollToBottom(animated: true)
        syncStreamingChrome()

        let model = ConversationStore.shared.currentConversation?.model ?? conv.model
        StreamManager.shared.start(
            conversationID: convID,
            messages: apiContext(for: model),
            model: model,
            needsAITitle: needsAITitle
        )
    }

    private func presentRename(_ id: String, current: String) {
        let alert = UIAlertController(title: "重命名对话", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = current }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { _ in
            ConversationStore.shared.renameConversation(id: id, title: alert.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    @objc private func modelTapped() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for option in AIModelOption.all {
            sheet.addAction(UIAlertAction(title: option.displayName, style: .default) { [weak self] _ in
                guard let id = ConversationStore.shared.currentConversationID else { return }
                ConversationStore.shared.setModel(option, for: id)
                self?.inputBar.clearAttachment()
                self?.updateModelButton()
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = modelButton
            pop.sourceRect = modelButton.bounds
        }
        present(sheet, animated: true)
    }

    private func presentImagePicker() {
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else {
            showAlert(title: "无法访问相册", message: "请在设置中允许 Connects 访问照片。")
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        picker.allowsEditing = false
        picker.modalPresentationStyle = .popover
        if let pop = picker.popoverPresentationController {
            pop.sourceView = inputBar
            pop.sourceRect = CGRect(x: 20, y: 0, width: 44, height: 44)
            pop.permittedArrowDirections = [.down, .up]
        }
        present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let b64 = ImageAttachmentHelper.prepareJPEGBase64(from: image) else { return }
        if let id = ConversationStore.shared.currentConversationID,
           let conv = ConversationStore.shared.currentConversation,
           !conv.model.supportsVision {
            if SettingsManager.shared.hasAPIKey(for: .kimi) {
                ConversationStore.shared.setModel(.kimi26, for: id)
                updateModelButton()
            } else {
                showAlert(title: "需要 Kimi Key", message: "图片只能发给 Kimi。请先在设置填写 Kimi API Key，再切换到 Kimi K2.6。")
                return
            }
        }
        inputBar.setAttachment(image: image, base64: b64)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    private func scrollToBottom(animated: Bool) {
        guard let conv = ConversationStore.shared.currentConversation, !conv.messages.isEmpty else { return }
        let path = IndexPath(row: conv.messages.count - 1, section: 0)
        tableView.scrollToRow(at: path, at: .bottom, animated: animated)
    }

    private func sendMessage(_ text: String, imageBase64: String?) {
        guard var conv = ConversationStore.shared.currentConversation else { return }

        if StreamManager.shared.isRunning(conv.id) {
            showAlert(title: "正在生成", message: "当前对话仍在回复中，请先点停止或等待完成。")
            return
        }

        if imageBase64 != nil && !conv.model.supportsVision {
            if SettingsManager.shared.hasAPIKey(for: .kimi),
               let id = ConversationStore.shared.currentConversationID {
                ConversationStore.shared.setModel(.kimi26, for: id)
                updateModelButton()
                conv = ConversationStore.shared.currentConversation ?? conv
            } else {
                showAlert(title: "需要 Kimi Key", message: "图片只能发给 Kimi。请先在设置填写 Kimi API Key，并切换到 Kimi K2.6。")
                return
            }
        }

        let provider = conv.model.provider
        guard SettingsManager.shared.hasAPIKey(for: provider) else {
            showAlert(title: "缺少 API Key", message: "请先在设置中填写 \(provider.displayName) 的 API Key。\n当前模型：\(conv.model.displayName)")
            return
        }
        if imageBase64 != nil && !conv.model.supportsVision {
            showAlert(title: "不支持图片", message: "当前模型不支持图片，请切换到 Kimi K2.6。")
            return
        }

        let needsAITitle = (conv.title == "新对话" || conv.title.hasSuffix("（分叉）")) && !conv.titleLocked
        let displayText = text.isEmpty && imageBase64 != nil ? "[图片]" : text
        let userMsg = ChatMessage(role: .user, content: displayText, imageJPEGBase64: imageBase64)
        let assistantMsg = ChatMessage(role: .assistant, content: "", reasoningContent: "", isStreaming: true)
        let convID = conv.id
        let model = conv.model

        ConversationStore.shared.updateCurrent { c in
            c.messages.append(userMsg)
            c.messages.append(assistantMsg)
        }
        if needsAITitle {
            ConversationStore.shared.applyProvisionalTitle(id: convID, fromUserText: displayText)
        }

        inputBar.clearText()
        updateEmptyState()
        tableView.reloadData()
        scrollToBottom(animated: true)
        stickToBottom = true
        syncStreamingChrome()

        StreamManager.shared.start(
            conversationID: convID,
            messages: apiContext(for: model),
            model: model,
            needsAITitle: needsAITitle
        )
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

extension ChatViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        ConversationStore.shared.currentConversation?.messages.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
        cell.cellDelegate = self
        if let msg = ConversationStore.shared.currentConversation?.messages[indexPath.row] {
            cell.configure(with: msg, preferredHeight: contentHeights[msg.id])
        }
        return cell
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let msg = ConversationStore.shared.currentConversation?.messages[indexPath.row],
              let h = contentHeights[msg.id] else { return 100 }
        return h + (msg.role == .assistant && !msg.isStreaming ? 48 : 24)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        stickToBottom = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offsetY = scrollView.contentOffset.y
        let contentH = scrollView.contentSize.height
        let frameH = scrollView.frame.height
        stickToBottom = offsetY + frameH >= contentH - 80
    }
}

extension ChatViewController: MessageCellDelegate {
    func messageCell(_ cell: MessageCell, didUpdateHeight height: CGFloat, for messageID: String) {
        let old = contentHeights[messageID] ?? 0
        guard abs(old - height) > 2 else { return }
        contentHeights[messageID] = height
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            if stickToBottom {
                scrollToBottom(animated: false)
            }
        }
    }

    func messageCellDidTapCopy(_ cell: MessageCell, messageID: String) {
        guard let msg = ConversationStore.shared.currentConversation?.messages.first(where: { $0.id == messageID }) else { return }
        UIPasteboard.general.string = msg.copyableText
    }

    func messageCellDidTapRetry(_ cell: MessageCell, messageID: String) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        retryFromMessage(at: idx)
    }

    func messageCellDidTapFork(_ cell: MessageCell, messageID: String) {
        guard let id = ConversationStore.shared.currentConversationID else { return }
        _ = ConversationStore.shared.forkConversation(id: id, throughMessageID: messageID)
    }
}

extension ChatViewController: InputBarViewDelegate {
    func inputBarDidTapSend(text: String, imageBase64: String?) {
        sendMessage(text, imageBase64: imageBase64)
    }

    func inputBarDidTapStop() {
        guard let id = currentConversationID else { return }
        StreamManager.shared.cancel(id)
        syncStreamingChrome()
    }

    func inputBarDidTapAttach() {
        presentImagePicker()
    }
}
