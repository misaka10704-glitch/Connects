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
    private let contextUsageView = ContextUsageView()
    private let modelButton = UIButton(type: .system)
    private let emptyTitleLabel = UILabel()
    private let emptySubtitleLabel = UILabel()
    private let emptyContainer = UIView()
    private var emptyChips: UIStackView?
    private var sidebarToggleItem: UIBarButtonItem?
    private var pendingSidebarCollapsed: Bool?
    private var bottomConstraint: NSLayoutConstraint?
    private var inputSideInsetConstraint: NSLayoutConstraint?
    private var isCompactChrome = false
    private var keyboardVisible = false
    private var isReloadingFromStore = false
    private var contentHeights: [String: CGFloat] = [:]
    private var heightCacheByConversation: [String: [String: CGFloat]] = [:]
    private var renderedConversationID: String?
    private var stickToBottom = true
    private var streamUIWork: DispatchWorkItem?
    private var heightWork: DispatchWorkItem?
    private var pendingHeights: [String: CGFloat] = [:]
    private var ignoreStoreReloadUntil: TimeInterval = 0
    private var chromeWork: DispatchWorkItem?
    /// Conversation currently waiting on web search before stream starts.
    private var webSearchPendingID: String?
    /// Rounded chat width — heights are invalid across rotation / Slide Over.
    private var layoutWidthBucket: Int = 0
    private var widthInvalidateWork: DispatchWorkItem?
    private static let imageCache = NSCache<NSString, UIImage>()
    private static let attrCache = NSCache<NSString, NSAttributedString>()

    private var currentConversationID: String? {
        ConversationStore.shared.currentConversationID
    }

    private var isCurrentStreaming: Bool {
        guard let id = currentConversationID else { return false }
        if webSearchPendingID == id { return true }
        return StreamManager.shared.isRunning(id)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupNavBar()
        setupTable()
        setupInputBar()
        setupEmptyState()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged(_:)), name: .conversationStoreDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamUpdated(_:)), name: .streamManagerDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamFinished(_:)), name: .streamManagerDidFinish, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(thinkingToggled(_:)), name: Notification.Name("ConnectsThinkingToggle"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged), name: .chatFontSizeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamTTFT(_:)), name: Notification.Name("ConnectsStreamTTFT"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contextUsageChanged(_:)), name: .contextUsageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contextCompactionFinished(_:)), name: .contextCompactionDidFinish, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(chatWidthDidChange(_:)), name: .connectsChatWidthDidChange, object: nil)
        migrateRenderSchemaIfNeeded()
        registerKeyboard()
        applyTheme()
        reloadChat()
        layoutWidthBucket = widthBucket(for: view.bounds.width)
        if didMigrateRenderSchema {
            didMigrateRenderSchema = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.remeasureVisibleRichCells()
            }
        }
    }

    /// 1.4.13 briefly routed tables to PlainMarkdown; wipe bad height caches so old chats remasure.
    private static let renderSchemaKey = "connects_render_schema"
    // v16 measures every Markdown block rather than WebKit's viewport-sized
    // container. Re-measure rows cached by earlier rich-renderer versions.
    private static let renderSchemaVersion = 16
    private var didMigrateRenderSchema = false

    private func migrateRenderSchemaIfNeeded() {
        let ud = UserDefaults.standard
        let v = ud.integer(forKey: Self.renderSchemaKey)
        guard v < Self.renderSchemaVersion else { return }
        contentHeights.removeAll()
        heightCacheByConversation.removeAll()
        pendingHeights.removeAll()
        PlainMarkdown.clearCache()
        ChatViewController.attrCache.removeAllObjects()
        ud.set(Self.renderSchemaVersion, forKey: Self.renderSchemaKey)
        didMigrateRenderSchema = true
    }

    private func remeasureVisibleRichCells() {
        for case let cell as MessageCell in tableView.visibleCells {
            cell.remeasureAfterWidthChange()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.flushPendingHeights(force: true)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bucket = widthBucket(for: tableView.bounds.width)
        guard bucket > 0 else { return }
        if layoutWidthBucket == 0 {
            layoutWidthBucket = bucket
            return
        }
        if bucket != layoutWidthBucket {
            layoutWidthBucket = bucket
            scheduleInvalidateHeightsForWidthChange()
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self = self else { return }
            self.layoutWidthBucket = self.widthBucket(for: self.tableView.bounds.width)
            self.invalidateHeightsForWidthChange(immediate: true)
        }
    }

    @objc private func chatWidthDidChange(_ note: Notification) {
        // Slide Over / split from root — table width may lag one layout pass.
        scheduleInvalidateHeightsForWidthChange()
    }

    private func widthBucket(for width: CGFloat) -> Int {
        guard width > 1 else { return 0 }
        // 4pt buckets absorb sub-pixel noise but catch Slide Over / rotation.
        return Int((width / 4).rounded()) * 4
    }

    private func scheduleInvalidateHeightsForWidthChange() {
        widthInvalidateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.invalidateHeightsForWidthChange(immediate: true)
        }
        widthInvalidateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Drop cached web heights and remasure visible cells after width reflow.
    private func invalidateHeightsForWidthChange(immediate: Bool) {
        contentHeights.removeAll()
        pendingHeights.removeAll()
        if let cid = renderedConversationID {
            heightCacheByConversation[cid] = [:]
        }
        for case let cell as MessageCell in tableView.visibleCells {
            cell.remeasureAfterWidthChange()
        }
        let apply: () -> Void = { [weak self] in
            self?.flushPendingHeights(force: true)
        }
        if immediate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: apply)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: apply)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: apply)
        }
    }

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
        contextUsageView.applyTheme()
        tableView.reloadData()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { DSTheme.c.statusBarStyle }

    @objc private func themeChanged() { applyTheme() }

    @objc private func storeChanged(_ note: Notification) {
        guard !isReloadingFromStore else { return }
        if Date().timeIntervalSince1970 < ignoreStoreReloadUntil { return }
        if let source = note.userInfo?["source"] as? String, source == "streamFinish" {
            updateTitleFromConversation()
            syncStreamingChrome()
            refreshContextUsage()
            return
        }
        reloadChat()
    }

    @objc private func streamUpdated(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else { return }
        scheduleStreamUIRefresh()
        refreshContextUsage()
    }

    @objc private func thinkingToggled(_ note: Notification) {
        if let mid = note.userInfo?["messageID"] as? String,
           let messages = ConversationStore.shared.currentConversation?.messages,
           let row = messages.firstIndex(where: { $0.id == mid }) {
            let path = IndexPath(row: row, section: 0)
            UIView.performWithoutAnimation {
                tableView.reloadRows(at: [path], with: .none)
            }
            return
        }
        tableView.reloadData()
    }

    @objc private func fontSizeChanged() {
        contentHeights.removeAll()
        heightCacheByConversation.removeAll()
        ChatViewController.attrCache.removeAllObjects()
        PlainMarkdown.clearCache()
        tableView.reloadData()
    }

    @objc private func streamTTFT(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID,
              let ms = note.userInfo?["ms"] as? Int,
              let host = note.userInfo?["host"] as? String else { return }
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
        ignoreStoreReloadUntil = Date().timeIntervalSince1970 + 0.35
        syncStreamingChrome()
        reloadChat()
        maybeAutoCompactContext()
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
        if isCompactChrome {
            item.accessibilityLabel = collapsed ? "打开对话列表" : "关闭对话列表"
        } else {
            item.accessibilityLabel = collapsed ? "打开侧栏" : "关闭侧栏"
        }
    }

    /// Slide Over / narrow width: tighter chrome for 网课侧拉.
    func setCompactChrome(_ on: Bool) {
        isCompactChrome = on
        let inset = on ? 12.0 : DSTheme.contentHorizontalPadding
        inputSideInsetConstraint?.constant = -(inset * 2)
        emptyTitleLabel.font = UIFont.systemFont(ofSize: on ? 22 : 28, weight: .semibold)
        emptySubtitleLabel.font = DSTheme.bodyFont(size: on ? 13 : 14)
        if let collapsed = pendingSidebarCollapsed {
            updateSidebarToggleTitle(collapsed: collapsed)
        }
        view.layoutIfNeeded()
    }

    func reloadChat() {
        isReloadingFromStore = true
        chromeWork?.cancel()

        // Persist heights for the conversation we are leaving.
        if let old = renderedConversationID {
            heightCacheByConversation[old] = contentHeights
        }
        let newID = ConversationStore.shared.currentConversationID
        if newID != renderedConversationID {
            contentHeights = heightCacheByConversation[newID ?? ""] ?? [:]
            pendingHeights.removeAll()
            renderedConversationID = newID
        }

        UIView.performWithoutAnimation {
            tableView.reloadData()
            tableView.layoutIfNeeded()
            if stickToBottom || (ConversationStore.shared.currentConversation?.messages.isEmpty == false) {
                scrollToBottom(animated: false)
            }
        }

        // Defer chrome so the message list paints first.
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.updateModelButton()
            self.updateEmptyState()
            self.updateAttachAvailability()
            self.updateTitleFromConversation()
            self.syncStreamingChrome()
            self.refreshContextUsage()
        }
        chromeWork = work
        DispatchQueue.main.async(execute: work)
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
        contextUsageView.translatesAutoresizingMaskIntoConstraints = false
        contextUsageView.delegate = self
        view.addSubview(contextUsageView)

        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.delegate = self
        view.addSubview(inputBar)

        bottomConstraint = inputBar.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: -DSTheme.inputBarBottomPadding
        )

        let inputWidthFill = inputBar.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -DSTheme.contentHorizontalPadding * 2)
        inputWidthFill.priority = UILayoutPriority(999)
        inputSideInsetConstraint = inputWidthFill
        let inputWidthMax = inputBar.widthAnchor.constraint(lessThanOrEqualToConstant: DSTheme.contentMaxWidth)

        let usageWidthFill = contextUsageView.widthAnchor.constraint(equalTo: inputBar.widthAnchor)
        usageWidthFill.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: contextUsageView.topAnchor),

            contextUsageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            usageWidthFill,
            contextUsageView.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -2),

            inputBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            inputWidthFill,
            inputWidthMax,
            bottomConstraint!,
            inputBar.heightAnchor.constraint(greaterThanOrEqualToConstant: DSTheme.inputBarHeight + 8)
        ])
    }

    private func refreshContextUsage() {
        guard let conv = ConversationStore.shared.currentConversation else {
            contextUsageView.setCompacting(false)
            contextUsageView.update(
                usage: ContextBuilder.Usage(usedChars: 0, budgetChars: 1),
                forceVisible: false,
                animated: false
            )
            return
        }
        let usage = ContextBuilder.usage(for: conv)
        let compacting = ContextCompactor.isCompacting(conv.id)
        let visible = ContextBuilder.shouldShowUsage(for: conv)
        contextUsageView.setCompacting(compacting)
        contextUsageView.update(usage: usage, forceVisible: visible, animated: true)
    }

    private func maybeAutoCompactContext() {
        guard let id = ConversationStore.shared.currentConversationID else { return }
        guard let conv = ConversationStore.shared.currentConversation else { return }
        let usage = ContextBuilder.usage(for: conv)
        contextUsageView.update(
            usage: usage,
            forceVisible: ContextBuilder.shouldShowUsage(for: conv),
            animated: true
        )
        guard usage.shouldAutoCompact else { return }
        contextUsageView.setCompacting(true)
        ContextCompactor.compactIfNeeded(conversationID: id, force: false) { [weak self] did in
            self?.refreshContextUsage()
            if did {
                self?.navigationItem.prompt = "已压缩上下文"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                    if self?.navigationItem.prompt == "已压缩上下文" {
                        self?.navigationItem.prompt = nil
                    }
                }
            }
        }
    }

    @objc private func contextUsageChanged(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else {
            refreshContextUsage()
            return
        }
        refreshContextUsage()
    }

    @objc private func contextCompactionFinished(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else { return }
        contextUsageView.setCompacting(false)
        refreshContextUsage()
    }

    private func setupEmptyState() {
        emptyContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyContainer.isUserInteractionEnabled = true
        view.insertSubview(emptyContainer, belowSubview: inputBar)

        emptyTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyTitleLabel.text = "今天想聊些什么？"
        emptyTitleLabel.textAlignment = .center
        emptyTitleLabel.font = UIFont.systemFont(ofSize: 28, weight: .semibold)
        emptyTitleLabel.numberOfLines = 2
        emptyContainer.addSubview(emptyTitleLabel)

        emptySubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        emptySubtitleLabel.text = "选择模型后开始对话"
        emptySubtitleLabel.textAlignment = .center
        emptySubtitleLabel.font = DSTheme.bodyFont(size: 14)
        emptyContainer.addSubview(emptySubtitleLabel)

        let chips = UIStackView()
        chips.axis = .vertical
        chips.spacing = 10
        chips.translatesAutoresizingMaskIntoConstraints = false
        chips.tag = 8801
        emptyContainer.addSubview(chips)
        emptyChips = chips

        let prompts = [
            "解释一个概念，尽量通俗",
            "帮我写一段清晰的代码",
            "用表格对比几个方案"
        ]
        for p in prompts {
            let b = UIButton(type: .system)
            b.setTitle(p, for: .normal)
            b.titleLabel?.font = DSTheme.bodyFont(size: 14)
            b.contentEdgeInsets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
            b.layer.cornerRadius = 18
            b.layer.borderWidth = 0
            b.addTarget(self, action: #selector(suggestionTapped(_:)), for: .touchUpInside)
            chips.addArrangedSubview(b)
        }

        // Center empty chrome in the band above the composer (moves with keyboard).
        NSLayoutConstraint.activate([
            emptyContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyContainer.bottomAnchor.constraint(equalTo: contextUsageView.topAnchor),

            emptyTitleLabel.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptyTitleLabel.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor, constant: -36),
            emptyTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: emptyContainer.leadingAnchor, constant: 24),
            emptyTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: emptyContainer.trailingAnchor, constant: -24),

            emptySubtitleLabel.topAnchor.constraint(equalTo: emptyTitleLabel.bottomAnchor, constant: 10),
            emptySubtitleLabel.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),

            chips.topAnchor.constraint(equalTo: emptySubtitleLabel.bottomAnchor, constant: 24),
            chips.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            chips.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            chips.bottomAnchor.constraint(lessThanOrEqualTo: emptyContainer.bottomAnchor, constant: -12)
        ])

        view.bringSubviewToFront(contextUsageView)
        view.bringSubviewToFront(inputBar)
    }

    @objc private func suggestionTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        sendMessage(title, imageBase64: nil)
    }

    private func updateEmptyState() {
        let empty = (ConversationStore.shared.currentConversation?.messages.count ?? 0) == 0
        emptyContainer.isHidden = !empty
        tableView.isHidden = empty
        layoutEmptyChromeForKeyboard()
        if empty {
            let c = DSTheme.c
            emptyTitleLabel.textColor = c.textPrimary
            emptySubtitleLabel.textColor = c.textSecondary
            if let chips = emptyChips {
                for case let b as UIButton in chips.arrangedSubviews {
                    b.setTitleColor(c.textPrimary, for: .normal)
                    b.backgroundColor = c.surfaceHover
                    b.layer.borderWidth = 0
                }
            }
        }
    }

    /// When keyboard is up, keep title/subtitle above the composer; hide suggestion chips to avoid clutter.
    private func layoutEmptyChromeForKeyboard() {
        guard !emptyContainer.isHidden else { return }
        emptyChips?.isHidden = keyboardVisible
        emptySubtitleLabel.isHidden = keyboardVisible
        // Slightly higher title when keyboard consumes the lower half.
        // (centerY constant is fixed in constraints; hide chips is enough for Air 1 landscape.)
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

        // Convert keyboard to this VC's view (correct for split detail pane on iPad).
        let converted = view.convert(frame, from: nil)
        let intersection = view.bounds.intersection(converted)
        let overlap = intersection.isNull ? 0 : intersection.height
        // bottomConstraint is vs safeArea.bottom — subtract safe-area inset already baked into that anchor.
        let safePad = view.safeAreaInsets.bottom
        let lift = max(0, overlap - safePad)
        keyboardVisible = lift > 20
        bottomConstraint?.constant = keyboardVisible ? -(lift + 6) : -DSTheme.inputBarBottomPadding
        layoutEmptyChromeForKeyboard()

        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
            ?? UIView.AnimationCurve.easeInOut.rawValue
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
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
        let conv = ConversationStore.shared.currentConversation
        let raw = conv?.messages ?? []
        var keep = ContextBuilder.keepRecentTurns
        var built = ContextBuilder.build(
            from: raw,
            model: model,
            existingSummary: conv?.contextSummary,
            existingThroughID: conv?.contextSummaryThroughMessageID,
            keepRecentTurns: keep
        )
        if built.usage.shouldAutoCompact {
            keep = ContextBuilder.compactKeepRecentTurns
            built = ContextBuilder.build(
                from: raw,
                model: model,
                existingSummary: conv?.contextSummary,
                existingThroughID: conv?.contextSummaryThroughMessageID,
                keepRecentTurns: keep
            )
        }
        if built.summary != conv?.contextSummary
            || built.summaryThroughMessageID != conv?.contextSummaryThroughMessageID {
            ConversationStore.shared.updateCurrentQuietly { c in
                c.contextSummary = built.summary
                c.contextSummaryThroughMessageID = built.summaryThroughMessageID
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.refreshContextUsage()
        }
        return built.messages
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
            // Truncation invalidates compaction covering removed turns.
            c.contextSummary = nil
            c.contextSummaryThroughMessageID = nil
            c.messages.append(ChatMessage(role: .assistant, content: "", reasoningContent: "", isStreaming: true))
        }

        stickToBottom = true
        updateEmptyState()
        tableView.reloadData()
        scrollToBottom(animated: true)
        syncStreamingChrome()

        let model = ConversationStore.shared.currentConversation?.model ?? conv.model
        let userText = ConversationStore.shared.currentConversation?.messages[userIndex].content ?? ""
        let searchOn = SettingsManager.shared.webSearchEnabled
            && !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && userText != "[图片]"

        if searchOn {
            ConversationStore.shared.updateConversation(id: convID) { c in
                guard var last = c.messages.last, last.isStreaming else { return }
                last.content = "正在联网搜索…"
                c.messages[c.messages.count - 1] = last
            }
            tableView.reloadData()
            webSearchPendingID = convID
            syncStreamingChrome()
            navigationItem.prompt = "正在联网搜索…"
            WebSearchService.searchAndFormat(query: userText) { [weak self] result in
                guard let self = self else { return }
                guard self.webSearchPendingID == convID else { return }
                self.webSearchPendingID = nil
                if self.navigationItem.prompt == "正在联网搜索…" {
                    self.navigationItem.prompt = nil
                }
                ConversationStore.shared.updateConversation(id: convID) { c in
                    guard var last = c.messages.last, last.isStreaming else { return }
                    last.content = ""
                    c.messages[c.messages.count - 1] = last
                }
                var msgs = self.apiContext(for: model)
                switch result {
                case .success(let block):
                    msgs = WebSearchService.inject(into: msgs, searchBlock: block)
                case .failure(let err):
                    msgs = WebSearchService.inject(
                        into: msgs,
                        searchBlock: "（联网搜索失败：\(err.localizedDescription)。将仅用模型知识回答。）"
                    )
                }
                StreamManager.shared.start(
                    conversationID: convID,
                    messages: msgs,
                    model: model,
                    needsAITitle: needsAITitle
                )
                self.syncStreamingChrome()
            }
        } else {
            StreamManager.shared.start(
                conversationID: convID,
                messages: apiContext(for: model),
                model: model,
                needsAITitle: needsAITitle
            )
        }
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
                ConversationStore.shared.setModel(.preferredVision, for: id)
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
        if ContextCompactor.isCompacting(conv.id) {
            showAlert(title: "正在压缩", message: "上下文压缩完成后即可发送。")
            return
        }

        if imageBase64 != nil && !conv.model.supportsVision {
            if SettingsManager.shared.hasAPIKey(for: .kimi),
               let id = ConversationStore.shared.currentConversationID {
                ConversationStore.shared.setModel(.preferredVision, for: id)
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

        let usage = ContextBuilder.usage(for: conv)
        if usage.shouldAutoCompact {
            contextUsageView.setCompacting(true)
            ContextCompactor.compactIfNeeded(conversationID: conv.id, force: true) { [weak self] _ in
                self?.contextUsageView.setCompacting(false)
                self?.refreshContextUsage()
                self?.performSend(text, imageBase64: imageBase64)
            }
            return
        }
        performSend(text, imageBase64: imageBase64)
    }

    private func performSend(_ text: String, imageBase64: String?) {
        guard let conv = ConversationStore.shared.currentConversation else { return }

        let needsAITitle = (conv.title == "新对话" || conv.title.hasSuffix("（分叉）")) && !conv.titleLocked
        let displayText = text.isEmpty && imageBase64 != nil ? "[图片]" : text
        let userMsg = ChatMessage(role: .user, content: displayText, imageJPEGBase64: imageBase64)
        let searchOn = SettingsManager.shared.webSearchEnabled && !displayText.isEmpty && displayText != "[图片]"
        let assistantMsg = ChatMessage(
            role: .assistant,
            content: searchOn ? "正在联网搜索…" : "",
            reasoningContent: "",
            isStreaming: true
        )
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
        refreshContextUsage()

        if searchOn {
            webSearchPendingID = convID
            syncStreamingChrome()
            navigationItem.prompt = "正在联网搜索…"
            WebSearchService.searchAndFormat(query: displayText) { [weak self] result in
                guard let self = self else { return }
                guard self.webSearchPendingID == convID else { return }
                self.webSearchPendingID = nil
                if self.navigationItem.prompt == "正在联网搜索…" {
                    self.navigationItem.prompt = nil
                }
                // Clear placeholder before tokens arrive (appendStreamTokens concatenates).
                ConversationStore.shared.updateConversation(id: convID) { c in
                    guard var last = c.messages.last, last.isStreaming else { return }
                    last.content = ""
                    c.messages[c.messages.count - 1] = last
                }
                var msgs = self.apiContext(for: model)
                switch result {
                case .success(let block):
                    msgs = WebSearchService.inject(into: msgs, searchBlock: block)
                case .failure(let err):
                    let note = "（联网搜索失败：\(err.localizedDescription)。将仅用模型知识回答。）"
                    msgs = WebSearchService.inject(into: msgs, searchBlock: note)
                }
                StreamManager.shared.start(
                    conversationID: convID,
                    messages: msgs,
                    model: model,
                    needsAITitle: needsAITitle
                )
                self.syncStreamingChrome()
            }
        } else {
            syncStreamingChrome()
            StreamManager.shared.start(
                conversationID: convID,
                messages: apiContext(for: model),
                model: model,
                needsAITitle: needsAITitle
            )
        }
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
            if msg.hasImage, let b64 = msg.imageJPEGBase64 {
                let key = msg.id as NSString
                if let cached = ChatViewController.imageCache.object(forKey: key) {
                    cell.setCachedImage(cached)
                } else if let img = ImageAttachmentHelper.image(from: b64) {
                    ChatViewController.imageCache.setObject(img, forKey: key)
                    cell.setCachedImage(img)
                }
            }
            cell.configure(with: msg, preferredHeight: contentHeights[msg.id])
        }
        return cell
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let msg = ConversationStore.shared.currentConversation?.messages[indexPath.row] else { return 96 }
        if let h = contentHeights[msg.id], h > 40 {
            // Discard suspiciously short cache entries (1.4.12 freeze / 1.4.13 plain-table).
            let chars = max(msg.content.count, 1)
            let floor = CGFloat(min(2800, 48 + chars / 36 * 22))
            let rich = MarkdownHTMLRenderer.needsRichMarkdown(msg.content)
            if rich, h < floor * 0.4 {
                contentHeights.removeValue(forKey: msg.id)
            } else {
                return min(h + (msg.role == .assistant && !msg.isStreaming ? 56 : 28), 8000)
            }
        }
        let chars = max(msg.content.count, msg.reasoningContent.isEmpty ? 0 : 80)
        let lines = max(1, chars / 40)
        var rough = CGFloat(28 + lines * 22)
        if msg.hasImage { rough += 168 }
        if msg.hasReasoning { rough += 40 }
        if msg.role == .assistant && !msg.isStreaming { rough += 36 }
        if MathContentDetector.containsMath(msg.content) { rough *= 1.3 }
        if MarkdownHTMLRenderer.containsGFMTable(msg.content) { rough *= 1.2 }
        return min(max(rough, 64), 2800)
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

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishScrollHeightSettling() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishScrollHeightSettling()
    }

    private func finishScrollHeightSettling() {
        for case let cell as MessageCell in tableView.visibleCells {
            cell.applyDeferredHeightIfNeeded()
        }
        flushPendingHeights(force: false)
    }
}

extension ChatViewController: MessageCellDelegate {
    func messageCellShouldFreezeHeight(_ cell: MessageCell) -> Bool {
        tableView.isDragging || tableView.isDecelerating
    }

    func messageCell(_ cell: MessageCell, didUpdateHeight height: CGFloat, for messageID: String) {
        let old = contentHeights[messageID] ?? 0
        let scrolling = tableView.isDragging || tableView.isDecelerating
        let growing = height > old + 4
        // Micro-jitter while scrolling: ignore tiny shrinks only.
        let threshold: CGFloat = scrolling ? (growing ? 6 : 32) : 8
        guard abs(old - height) > threshold else {
            if old == 0, height > 40 {
                contentHeights[messageID] = height
            }
            return
        }
        pendingHeights[messageID] = height
        heightWork?.cancel()
        // ChatGPT-style: never leave content clipped — apply growth even mid-scroll.
        if scrolling && !growing {
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingHeights(force: scrolling && growing)
        }
        heightWork = work
        let delay: TimeInterval = growing ? 0.03 : 0.18
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flushPendingHeights(force: Bool = false) {
        guard !pendingHeights.isEmpty else { return }
        let scrolling = tableView.isDragging || tableView.isDecelerating
        if !force, scrolling {
            // Drop shrinks while scrolling; keep growth entries.
            pendingHeights = pendingHeights.filter { entry in
                entry.value > (contentHeights[entry.key] ?? 0) + 4
            }
            guard !pendingHeights.isEmpty else { return }
        }
        var changed = false
        for (id, height) in pendingHeights {
            let old = contentHeights[id] ?? 0
            if abs(old - height) > 3 {
                contentHeights[id] = height
                changed = true
            }
        }
        pendingHeights.removeAll()
        if changed, let cid = renderedConversationID {
            heightCacheByConversation[cid] = contentHeights
        }
        guard changed else { return }
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
        navigationItem.prompt = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.navigationItem.prompt == "已复制" {
                self?.navigationItem.prompt = nil
            }
        }
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
        if webSearchPendingID == id {
            webSearchPendingID = nil
            if navigationItem.prompt == "正在联网搜索…" {
                navigationItem.prompt = nil
            }
            ConversationStore.shared.finishStreamingMessage(
                conversationID: id,
                errorText: "已取消联网搜索。"
            )
            reloadChat()
        }
        StreamManager.shared.cancel(id)
        syncStreamingChrome()
    }

    func inputBarDidTapAttach() {
        presentImagePicker()
    }
}

extension ChatViewController: ContextUsageViewDelegate {
    func contextUsageViewDidTapCompact(_ view: ContextUsageView) {
        guard let id = currentConversationID else { return }
        if StreamManager.shared.isRunning(id) {
            showAlert(title: "正在生成", message: "请先停止或等待回复完成，再压缩上下文。")
            return
        }
        contextUsageView.setCompacting(true)
        ContextCompactor.compactIfNeeded(conversationID: id, force: true) { [weak self] did in
            self?.contextUsageView.setCompacting(false)
            self?.refreshContextUsage()
            if did {
                self?.navigationItem.prompt = "已压缩上下文"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                    if self?.navigationItem.prompt == "已压缩上下文" {
                        self?.navigationItem.prompt = nil
                    }
                }
            } else {
                self?.showAlert(title: "无需压缩", message: "当前上下文占用不高，或已在压缩中。")
            }
        }
    }
}
