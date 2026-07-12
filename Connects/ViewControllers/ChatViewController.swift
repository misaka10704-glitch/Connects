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
    private let modelButton = UIButton(type: .custom)
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
    /// Set by a user drag away from the latest turn. Unlike `stickToBottom`,
    /// this cannot be changed by WebKit/table layout callbacks.
    private var readingHistory = false
    private var streamUIWork: DispatchWorkItem?
    private var heightWork: DispatchWorkItem?
    private var contextUsageWork: DispatchWorkItem?
    private var pendingHeights: [String: CGFloat] = [:]
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
        NotificationCenter.default.addObserver(self, selector: #selector(visibleModelsChanged), name: .visibleModelsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamTTFT(_:)), name: Notification.Name("ConnectsStreamTTFT"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contextUsageChanged(_:)), name: .contextUsageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contextCompactionFinished(_:)), name: .contextCompactionDidFinish, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(chatWidthDidChange(_:)), name: .connectsChatWidthDidChange, object: nil)
        migrateRenderSchemaIfNeeded()
        if !didMigrateRenderSchema {
            heightCacheByConversation = RenderCacheStore.loadHeights()
        }
        registerKeyboard()
        applyTheme()
        reloadChat()
        layoutWidthBucket = widthBucket(for: view.bounds.width)
        if didMigrateRenderSchema {
            didMigrateRenderSchema = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                self.prewarmVisibleRichReplies(for: self.currentRenderWidth())
            }
        }
    }

    /// 1.4.13 briefly routed tables to PlainMarkdown; wipe bad height caches so old chats remasure.
    private static let renderSchemaKey = "connects_render_schema"
    // v34: native layouts use actual split-view width and rebind on resize.
    private static let renderSchemaVersion = 38
    private var didMigrateRenderSchema = false
    private var didPerformColdOpenRescue = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPerformColdOpenRescue else { return }
        didPerformColdOpenRescue = true
        // First appearance after launch — give WKWebView a second chance if the
        // initial inject raced ahead of KaTeX/marked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.rescueBlankRichCells()
        }
    }

    /// If a rich cell is still showing blank WebView / failed inject, rebind it.
    private func rescueBlankRichCells() {
        prewarmVisibleRichReplies(for: currentRenderWidth())
    }

    private func migrateRenderSchemaIfNeeded() {
        let ud = UserDefaults.standard
        let v = ud.integer(forKey: Self.renderSchemaKey)
        guard v < Self.renderSchemaVersion else { return }
        contentHeights.removeAll()
        heightCacheByConversation.removeAll()
        pendingHeights.removeAll()
        PlainMarkdown.clearCache()
        NativeMarkdownParser.shared.clear()
        NativeMessageLayouter.shared.clear()
        NativeFormulaRenderer.shared.clearDisk()
        ChatViewController.attrCache.removeAllObjects()
        RenderCacheStore.clearAll()
        ud.set(Self.renderSchemaVersion, forKey: Self.renderSchemaKey)
        didMigrateRenderSchema = true
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

    /// Snapshot keys include the width bucket. Rebind visible cells to their
    /// matching immutable tiles while retaining the reader's exact viewport.
    private func invalidateHeightsForWidthChange(immediate: Bool) {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let visible = tableView.indexPathsForVisibleRows ?? []
        let anchor = visible.first
        let anchorDelta = anchor.map {
            tableView.rectForRow(at: $0).minY - tableView.contentOffset.y
        }
        contentHeights.removeAll()
        if let cid = renderedConversationID {
            heightCacheByConversation[cid] = [:]
        }
        UIView.performWithoutAnimation {
            tableView.layoutIfNeeded()
            for path in visible where path.row < messages.count {
                guard let cell = tableView.cellForRow(at: path) as? MessageCell else { continue }
                cell.contentView.setNeedsLayout()
                cell.contentView.layoutIfNeeded()
                cell.configure(with: messages[path.row], preferredHeight: nil)
            }
            tableView.beginUpdates()
            tableView.endUpdates()
            if stickToBottom && !readingHistory {
                scrollToBottom(animated: false)
            } else if let anchor = anchor, let anchorDelta = anchorDelta {
                tableView.contentOffset.y = tableView.rectForRow(at: anchor).minY - anchorDelta
            }
        }
        prewarmVisibleRichReplies(for: currentRenderWidth())
        _ = immediate
    }

    private func currentRenderWidth() -> CGFloat {
        min(DSTheme.bubbleMaxWidth, max(tableView.bounds.width - 48, 120))
    }

    private func prewarmVisibleRichReplies(for width: CGFloat) {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let visible = tableView.indexPathsForVisibleRows ?? []
        var rows = Set(visible.map(\.row))
        for row in visible.map(\.row) {
            for nearby in max(0, row - 3)...min(messages.count - 1, row + 3) {
                rows.insert(nearby)
            }
        }
        for row in rows {
            let message = messages[row]
            guard message.role == .assistant,
                  !message.isStreaming else { continue }
            _ = NativeMarkdownParser.shared.parse(message.content)
        }
        _ = width
    }

    private func reloadTablePreservingViewport() {
        let anchor = tableView.indexPathsForVisibleRows?.first
        let oldOffset = tableView.contentOffset
        let anchorDelta: CGFloat
        if let anchor = anchor {
            anchorDelta = tableView.rectForRow(at: anchor).minY - oldOffset.y
        } else {
            anchorDelta = 0
        }
        UIView.performWithoutAnimation {
            tableView.reloadData()
            tableView.layoutIfNeeded()
            if stickToBottom && !readingHistory {
                scrollToBottom(animated: false)
            } else if let anchor = anchor,
                      anchor.section == 0,
                      anchor.row < tableView.numberOfRows(inSection: 0) {
                let target = tableView.rectForRow(at: anchor).minY - anchorDelta
                let maxOffset = max(-tableView.adjustedContentInset.top,
                                    tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
                tableView.contentOffset.y = min(max(target, -tableView.adjustedContentInset.top), maxOffset)
            }
        }
    }

    func applyTheme() {
        applyTheme(reloadMessages: true)
    }

    private func applyTheme(reloadMessages: Bool) {
        let c = DSTheme.c
        view.backgroundColor = c.background
        tableView.backgroundColor = c.background
        emptyTitleLabel.textColor = c.textPrimary
        emptySubtitleLabel.textColor = c.textSecondary
        modelButton.setTitleColor(c.textPrimary, for: .normal)
        modelButton.backgroundColor = c.surfaceHover
        modelButton.layer.borderWidth = 1 / UIScreen.main.scale
        modelButton.layer.borderColor = c.border.cgColor
        modelButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
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
        if reloadMessages {
            reloadTablePreservingViewport()
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { DSTheme.c.statusBarStyle }

    @objc private func themeChanged() {
        applyTheme(reloadMessages: false)
        NativeMessageLayouter.shared.clear()
        NativeFormulaRenderer.shared.clear()
        prewarmVisibleRichReplies(for: currentRenderWidth())
    }

    @objc private func storeChanged(_ note: Notification) {
        guard !isReloadingFromStore else { return }
        if let source = note.userInfo?["source"] as? String,
           source == "streamFinish" || source == "title" {
            updateTitleFromConversation()
            syncStreamingChrome()
            if source == "streamFinish" {
                refreshContextUsage(animated: false)
            }
            return
        }
        reloadChat()
    }

    @objc private func streamUpdated(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else { return }
        scheduleStreamUIRefresh()
        scheduleContextUsageRefresh()
    }

    @objc private func thinkingToggled(_ note: Notification) {
        if let mid = note.userInfo?["messageID"] as? String,
           let messages = ConversationStore.shared.currentConversation?.messages,
           let row = messages.firstIndex(where: { $0.id == mid }) {
            // A cached row height cannot be shared by expanded and collapsed
            // reasoning states. Reusing the expanded height after collapse left
            // several screens of empty space on iOS 12.
            contentHeights.removeValue(forKey: mid)
            pendingHeights.removeValue(forKey: mid)
            if let cid = renderedConversationID {
                heightCacheByConversation[cid] = contentHeights
            }
            let path = IndexPath(row: row, section: 0)
            UIView.performWithoutAnimation {
                tableView.reloadRows(at: [path], with: .none)
                tableView.layoutIfNeeded()
            }
            return
        }
        reloadTablePreservingViewport()
    }

    @objc private func fontSizeChanged() {
        ChatViewController.attrCache.removeAllObjects()
        PlainMarkdown.clearCache()
        NativeMessageLayouter.shared.clear()
        NativeFormulaRenderer.shared.clear()
        contentHeights.removeAll()
        pendingHeights.removeAll()
        if let cid = renderedConversationID {
            heightCacheByConversation[cid] = [:]
        }
        reloadTablePreservingViewport()
        prewarmVisibleRichReplies(for: currentRenderWidth())
    }

    @objc private func visibleModelsChanged() {
        // If current model was hidden, fall back to first visible.
        guard let id = ConversationStore.shared.currentConversationID,
              let conv = ConversationStore.shared.currentConversation else {
            updateModelButton()
            return
        }
        let visible = AIModelOption.visible
        if !visible.contains(where: { $0.stableID == conv.model.stableID }),
           let first = visible.first {
            ConversationStore.shared.setModel(first, for: id)
        }
        updateModelButton()
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
        streamUIWork = nil
        contextUsageWork?.cancel()
        // Streaming stays lightweight; completion performs one deterministic
        // native parse/layout and swaps under the cell snapshot cover.
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let last = messages.last else { return }
        syncStreamingChrome()
        let path = IndexPath(row: messages.count - 1, section: 0)
        // Streaming reasoning is expanded and can be thousands of points tall.
        // Never seed the finished row with that transient geometry.
        contentHeights.removeValue(forKey: last.id)
        pendingHeights.removeValue(forKey: last.id)
        if let visibleCell = tableView.cellForRow(at: path) as? MessageCell,
           visibleCell.messageID == last.id {
            if let measured = visibleCell.transitionToFinishedPlainRendering(
                last,
                preferredHeight: contentHeights[last.id]
            ) {
                contentHeights[last.id] = measured
            }
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
                if stickToBottom && !readingHistory {
                    scrollToBottom(animated: false)
                }
            }
        }
        maybeAutoCompactContext()
    }

    private func scheduleStreamUIRefresh() {
        // Fixed-cadence throttle: continuous notifications must not keep
        // postponing the only visible update until the stream finishes.
        guard streamUIWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.streamUIWork = nil
            self.refreshStreamingRow()
        }
        streamUIWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func refreshStreamingRow() {
        syncStreamingChrome()
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let last = messages.last, last.isStreaming else {
            return
        }
        let path = IndexPath(row: messages.count - 1, section: 0)
        UIView.performWithoutAnimation {
            if let cell = tableView.cellForRow(at: path) as? MessageCell {
                if !cell.updateStreamingContent(last) {
                    cell.configure(with: last, preferredHeight: contentHeights[last.id])
                }
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
        let conversationChanged = newID != renderedConversationID
        if conversationChanged {
            contentHeights = heightCacheByConversation[newID ?? ""] ?? [:]
            pendingHeights.removeAll()
            renderedConversationID = newID
            // A newly selected conversation opens at its latest turn. Subsequent
            // reloads must preserve the reader's manual scroll position.
            stickToBottom = true
            readingHistory = false
        }
        // User rows and reasoning rows must never inherit transient estimates.
        // Reasoning height depends on expanded/collapsed UI state, which is not
        // represented by the persisted message-ID-only cache.
        if let msgs = ConversationStore.shared.currentConversation?.messages {
            for m in msgs where m.role == .user || m.hasReasoning {
                contentHeights.removeValue(forKey: m.id)
            }
        }

        if conversationChanged {
            UIView.performWithoutAnimation {
                tableView.reloadData()
                tableView.layoutIfNeeded()
                scrollToBottom(animated: false)
            }
        } else {
            reloadTablePreservingViewport()
        }
        if let messages = ConversationStore.shared.currentConversation?.messages {
            MessageCell.prewarmSnapshots(
                for: Array(messages.suffix(4)),
                targetWidth: currentRenderWidth()
            )
        }
        // Defer chrome so the message list paints first.
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.updateModelButton()
            self.updateEmptyState()
            self.updateAttachAvailability()
            self.updateTitleFromConversation()
            self.syncStreamingChrome()
            self.refreshContextUsage(animated: false)
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
        let archiveTitle = conv.isArchived ? "取消归档" : "归档"
        ConnectsMenu.present(
            from: self,
            title: conv.title,
            items: [
                ConnectsMenuItem(title: "分享 / 导出 Markdown", icon: .share) { [weak self] in
                    self?.shareCurrentMarkdown()
                },
                ConnectsMenuItem(title: "复制全部对话", icon: .copy) { [weak self] in
                    self?.copyEntireConversation()
                },
                ConnectsMenuItem(title: "重命名", icon: .rename) { [weak self] in
                    self?.presentRename(conv.id, current: conv.title)
                },
                ConnectsMenuItem(title: "分叉对话", icon: .fork) {
                    _ = ConversationStore.shared.forkConversation(id: conv.id)
                },
                ConnectsMenuItem(title: archiveTitle, icon: .archive) {
                    ConversationStore.shared.setArchived(id: conv.id, archived: !conv.isArchived)
                },
                ConnectsMenuItem(title: "重跑上一轮", icon: .retry) { [weak self] in
                    self?.retryLastTurn()
                }
            ],
            barButtonItem: navigationItem.rightBarButtonItem
        )
    }

    private func setupNavBar() {
        // Centered model chip as titleView itself (must report size — a plain wrap
        // collapses to ~0 and draws outside its hit box, so taps never land).
        modelButton.translatesAutoresizingMaskIntoConstraints = true
        modelButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        modelButton.titleLabel?.lineBreakMode = .byTruncatingTail
        modelButton.titleLabel?.textAlignment = .center
        modelButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        modelButton.layer.cornerRadius = 16
        modelButton.clipsToBounds = true
        modelButton.isUserInteractionEnabled = true
        modelButton.addTarget(self, action: #selector(modelTapped), for: .touchUpInside)
        modelButton.accessibilityLabel = "选择模型"
        navigationItem.titleView = modelButton

        sidebarToggleItem = ActionIconFactory.barItem(
            kind: .sidebarOpen,
            target: self,
            action: #selector(toggleSidebar),
            accessibility: "关闭侧栏"
        )
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
        navigationController?.navigationBar.isUserInteractionEnabled = true
        updateModelButton()
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
        tableView.prefetchDataSource = self
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
            inputBar.heightAnchor.constraint(greaterThanOrEqualToConstant: DSTheme.inputBarHeight)
        ])
    }

    private func refreshContextUsage(animated: Bool = false) {
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
        contextUsageView.update(usage: usage, forceVisible: visible, animated: animated)
    }

    private func scheduleContextUsageRefresh() {
        contextUsageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshContextUsage(animated: false)
        }
        contextUsageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func maybeAutoCompactContext() {
        guard let id = ConversationStore.shared.currentConversationID else { return }
        guard let conv = ConversationStore.shared.currentConversation else { return }
        let usage = ContextBuilder.usage(for: conv)
        contextUsageView.update(
            usage: usage,
            forceVisible: ContextBuilder.shouldShowUsage(for: conv),
            animated: false
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
        modelButton.setTitle("\(model.displayName)  ▾", for: .normal)
        modelButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        modelButton.sizeToFit()
        var size = modelButton.bounds.size
        size.width = min(max(size.width, 132), 240)
        size.height = 32
        modelButton.bounds = CGRect(origin: .zero, size: size)
        // Re-assign so UINavigationBar remeasures the titleView hit box.
        navigationItem.titleView = modelButton
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

        // AI replies: actions live in the bottom button row — no long-press menu.
        guard msg.role == .user else { return }

        let cell = tableView.cellForRow(at: indexPath) ?? tableView
        let local = gesture.location(in: cell)
        let hot = CGRect(x: local.x - 12, y: local.y - 12, width: 24, height: 24)
        let items = [
            ConnectsMenuItem(title: "复制", icon: .copy) {
                UIPasteboard.general.string = msg.copyableText
            },
            ConnectsMenuItem(title: "修改", icon: .edit) { [weak self] in
                self?.editUserMessage(at: indexPath.row)
            }
        ]
        ConnectsMenu.present(
            from: self,
            items: items,
            sourceView: cell,
            sourceRect: hot,
            preferVertical: true
        )
    }

    private func editUserMessage(at index: Int) {
        guard let conv = ConversationStore.shared.currentConversation,
              index >= 0, index < conv.messages.count,
              conv.messages[index].role == .user else { return }
        if StreamManager.shared.isRunning(conv.id) || webSearchPendingID == conv.id {
            showAlert(title: "正在生成", message: "请先停止或等待当前回复完成。")
            return
        }
        let original = conv.messages[index].content
        let alert = UIAlertController(title: "修改消息", message: "保存后将从本条重新生成回复。", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = original
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存并重跑", style: .default) { [weak self] _ in
            let text = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            ConversationStore.shared.updateCurrentQuietly { c in
                guard index < c.messages.count, c.messages[index].role == .user else { return }
                c.messages[index].content = text
            }
            self?.retryFromMessage(at: index)
        })
        present(alert, animated: true)
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

        ConversationStore.shared.updateCurrentQuietly { c in
            let assistantIndex = userIndex + 1
            if assistantIndex < c.messages.count, c.messages[assistantIndex].role == .assistant {
                // Keep prior replies as switchable versions; drop later turns.
                if c.messages.count > assistantIndex + 1 {
                    c.messages.removeSubrange((assistantIndex + 1)..<c.messages.count)
                }
                c.contextSummary = nil
                c.contextSummaryThroughMessageID = nil
                var asst = c.messages[assistantIndex]
                asst.beginNewVersion()
                c.messages[assistantIndex] = asst
            } else {
                if c.messages.count > userIndex + 1 {
                    c.messages.removeSubrange((userIndex + 1)..<c.messages.count)
                }
                c.contextSummary = nil
                c.contextSummaryThroughMessageID = nil
                c.messages.append(ChatMessage(role: .assistant, content: "", reasoningContent: "", isStreaming: true))
            }
        }

        stickToBottom = true
        readingHistory = false
        updateEmptyState()
        tableView.reloadData()
        scrollToBottom(animated: true, force: true)
        syncStreamingChrome()

        let model = ConversationStore.shared.currentConversation?.model ?? conv.model
        let userText = ConversationStore.shared.currentConversation?.messages[userIndex].content ?? ""
        let searchOn = SettingsManager.shared.webSearchEnabled
            && !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && userText != "[图片]"

        if searchOn {
            beginWebSearchThenStream(
                convID: convID,
                model: model,
                needsAITitle: needsAITitle,
                query: userText
            )
        } else {
            StreamManager.shared.start(
                conversationID: convID,
                messages: apiContext(for: model),
                model: model,
                needsAITitle: needsAITitle
            )
        }
    }

    /// Search → read pages → stream. Shared by send + retry.
    private func beginWebSearchThenStream(
        convID: String,
        model: AIModelOption,
        needsAITitle: Bool,
        query: String
    ) {
        webSearchPendingID = convID
        syncStreamingChrome()
        setWebSearchStatus(convID: convID, text: "正在搜索…")

        WebSearchService.searchAndFormat(
            query: query,
            onStatus: { [weak self] status in
                guard let self = self, self.webSearchPendingID == convID else { return }
                self.setWebSearchStatus(convID: convID, text: status)
            }
        ) { [weak self] result in
            guard let self = self else { return }
            guard self.webSearchPendingID == convID else { return }
            self.webSearchPendingID = nil
            if self.navigationItem.prompt != nil {
                self.navigationItem.prompt = nil
            }
            ConversationStore.shared.updateConversationQuietly(id: convID) { c in
                guard var last = c.messages.last, last.isStreaming else { return }
                last.content = ""
                c.messages[c.messages.count - 1] = last
            }
            var msgs = self.apiContext(for: model)
            switch result {
            case .success(let block):
                msgs = WebSearchService.inject(into: msgs, searchBlock: block)
                msgs = WebSearchService.fitInjectedContext(msgs, model: model)
            case .failure(let err):
                #if DEBUG
                print("[Connects] web search failed, falling back to regular context: \(err.localizedDescription)")
                #endif
                // Do not inject a "web mode" instruction when no web evidence exists; it
                // creates conflicting guidance and hurts answer quality more than a clean fallback.
                break
            }
            StreamManager.shared.start(
                conversationID: convID,
                messages: msgs,
                model: model,
                needsAITitle: needsAITitle
            )
            self.syncStreamingChrome()
        }
    }

    private func setWebSearchStatus(convID: String, text: String) {
        navigationItem.prompt = text
        ConversationStore.shared.updateConversationQuietly(id: convID) { c in
            guard var last = c.messages.last, last.isStreaming else { return }
            last.content = text
            c.messages[c.messages.count - 1] = last
        }
        if currentConversationID == convID {
            guard let messages = ConversationStore.shared.currentConversation?.messages,
                  !messages.isEmpty else { return }
            let path = IndexPath(row: messages.count - 1, section: 0)
            UIView.performWithoutAnimation {
                if let cell = tableView.cellForRow(at: path) as? MessageCell {
                    if !cell.updateStreamingContent(messages[path.row]) {
                        cell.configure(with: messages[path.row], preferredHeight: contentHeights[messages[path.row].id])
                    }
                } else {
                    tableView.reloadRows(at: [path], with: .none)
                }
            }
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
        let current = ConversationStore.shared.currentConversation?.model
        let pool = AIModelOption.visible
        // Flip chevron while open for capsule-dropdown feel.
        if let title = modelButton.title(for: .normal)?.replacingOccurrences(of: "▾", with: "▴") {
            modelButton.setTitle(title, for: .normal)
        }
        ModelCapsuleDropdown.present(
            from: self,
            anchor: modelButton,
            models: pool,
            selected: current,
            onPick: { [weak self] option in
                guard let self = self else { return }
                guard let id = ConversationStore.shared.currentConversationID else { return }
                ConversationStore.shared.setModel(option, for: id)
                self.inputBar.clearAttachment()
                self.updateAttachAvailability()
            },
            onDismiss: { [weak self] in
                self?.updateModelButton()
            }
        )
    }

    private func presentImagePicker() {
        var items: [ConnectsMenuItem] = [
            ConnectsMenuItem(title: "从相册选择", icon: .plus) { [weak self] in
                self?.openImagePicker(source: .photoLibrary)
            }
        ]
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            items.insert(
                ConnectsMenuItem(title: "拍照", icon: .plus) { [weak self] in
                    self?.openImagePicker(source: .camera)
                },
                at: 0
            )
        }
        if inputBar.hasAttachment {
            items.append(
                ConnectsMenuItem(title: "移除图片", icon: .trash, isDestructive: true) { [weak self] in
                    self?.inputBar.clearAttachment()
                }
            )
        }
        // Anchor after keyboard has settled so the menu sits above the + button.
        view.layoutIfNeeded()
        ConnectsMenu.present(
            from: self,
            title: "添加图片",
            items: items,
            sourceView: inputBar.attachAnchorView,
            sourceRect: inputBar.attachAnchorRect(),
            preferAbove: true
        )
    }

    private func openImagePicker(source: UIImagePickerController.SourceType) {
        guard UIImagePickerController.isSourceTypeAvailable(source) else {
            showAlert(title: "无法打开", message: source == .camera ? "此设备不支持相机。" : "请在设置中允许 Connects 访问照片。")
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = source
        picker.delegate = self
        picker.allowsEditing = false
        if source == .photoLibrary {
            picker.modalPresentationStyle = .popover
            if let pop = picker.popoverPresentationController {
                pop.sourceView = inputBar
                pop.sourceRect = CGRect(x: 8, y: 0, width: 44, height: 44)
                pop.permittedArrowDirections = [.down, .up]
            }
        } else {
            picker.modalPresentationStyle = .fullScreen
        }
        present(picker, animated: true)
    }

    /// Switch to a visible vision model if the current one cannot take images.
    @discardableResult
    private func ensureVisionModelIfNeeded() -> Bool {
        guard let id = ConversationStore.shared.currentConversationID,
              let conv = ConversationStore.shared.currentConversation else { return false }
        if conv.model.supportsVision { return true }
        let target = AIModelOption.preferredVision
        guard SettingsManager.shared.hasAPIKey(for: target.provider) else {
            showAlert(
                title: "需要视觉模型 Key",
                message: "图片可发给 Kimi 或 Qwen。请先在设置填写对应 API Key，并确保该模型已在「显示的模型」中开启。"
            )
            return false
        }
        ConversationStore.shared.setModel(target, for: id)
        updateModelButton()
        return true
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let b64 = ImageAttachmentHelper.prepareJPEGBase64(from: image) else {
            showAlert(title: "无法添加图片", message: "图片处理失败，请换一张再试。")
            return
        }
        guard ensureVisionModelIfNeeded() else { return }
        inputBar.setAttachment(image: image, base64: b64)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    private func scrollToBottom(animated: Bool, force: Bool = false) {
        guard force || !readingHistory else { return }
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
            guard ensureVisionModelIfNeeded() else { return }
            conv = ConversationStore.shared.currentConversation ?? conv
        }

        let provider = conv.model.provider
        guard SettingsManager.shared.hasAPIKey(for: provider) else {
            showAlert(title: "缺少 API Key", message: "请先在设置中填写 \(provider.displayName) 的 API Key。\n当前模型：\(conv.model.displayName)")
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
            content: searchOn ? "正在搜索…" : "",
            reasoningContent: "",
            isStreaming: true
        )
        let convID = conv.id
        let model = conv.model
        let firstNewRow = conv.messages.count

        ConversationStore.shared.updateCurrentQuietly { c in
            c.messages.append(userMsg)
            c.messages.append(assistantMsg)
        }
        if needsAITitle {
            ConversationStore.shared.applyProvisionalTitle(id: convID, fromUserText: displayText)
        }

        inputBar.clearText()
        updateEmptyState()
        readingHistory = false
        UIView.performWithoutAnimation {
            tableView.insertRows(
                at: [
                    IndexPath(row: firstNewRow, section: 0),
                    IndexPath(row: firstNewRow + 1, section: 0)
                ],
                with: .none
            )
        }
        scrollToBottom(animated: true, force: true)
        stickToBottom = true
        refreshContextUsage()

        if searchOn {
            beginWebSearchThenStream(
                convID: convID,
                model: model,
                needsAITitle: needsAITitle,
                query: displayText
            )
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
        guard let msg = ConversationStore.shared.currentConversation?.messages[indexPath.row] else { return 72 }
        // Prefer underestimate — iOS 12 self-sizing with oversized estimates stretches
        // bubbles (user gray empty / assistant gap above thinking) until remasure.
        if msg.role == .user {
            let lines = max(1, msg.content.count / 28)
            return min(CGFloat(52 + lines * 22), 220)
        }
        if let h = contentHeights[msg.id], h > 40, !msg.hasReasoning {
            // Completed raster rows own an immutable height. Feeding the
            // exact value back to UITableView avoids A7 estimate→shrink churn.
            return h + (msg.isStreaming ? 28 : 0)
        }
        if msg.role == .assistant,
           !msg.isStreaming {
            let document = NativeMarkdownParser.shared.parse(msg.content)
            let style = NativeLayoutStyle(
                width: currentRenderWidth(),
                bodyFontSize: SettingsManager.shared.chatBodyFontSize,
                appearance: SettingsManager.shared.appearanceMode.rawValue,
                colors: DSTheme.c
            )
            if let layout = NativeMessageLayouter.shared.cachedLayout(document: document, style: style) {
                var chrome: CGFloat = 48
                if msg.hasImage { chrome += 168 }
                if msg.hasReasoning { chrome += 44 }
                return layout.size.height + chrome
            }
        }
        let chars = max(msg.content.count, msg.reasoningContent.isEmpty ? 0 : 40)
        let lines = max(1, chars / 48)
        var rough = CGFloat(36 + lines * 18)
        if msg.hasImage { rough += 168 }
        if msg.hasReasoning { rough += 36 }
        if msg.role == .assistant && !msg.isStreaming { rough += 28 }
        return min(max(rough, 64), 420)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        stickToBottom = false
        readingHistory = true
        heightWork?.cancel()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Content-size changes from KaTeX/WebKit also trigger this callback.
        // They must not turn sticky mode back on after the user scrolls up.
        guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
        let offsetY = scrollView.contentOffset.y
        let contentH = scrollView.contentSize.height
        let frameH = scrollView.frame.height
        let wasSticking = stickToBottom
        stickToBottom = offsetY + frameH >= contentH - 80
        if stickToBottom && !wasSticking {
            readingHistory = false
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishScrollHeightSettling() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishScrollHeightSettling()
    }

    private func finishScrollHeightSettling() {
        // A settled history scroll must be a no-op for completed replies.
        // Any table height transaction here is visible as the shared
        // “reaches bottom / stops upward scroll” flash on iOS 12.
        guard isCurrentStreaming else { return }
        for case let cell as MessageCell in tableView.visibleCells {
            cell.applyDeferredHeightIfNeeded()
        }
        flushPendingHeights(force: false)
    }
}

extension ChatViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        for path in indexPaths where path.section == 0 && path.row < messages.count {
            let message = messages[path.row]
            guard message.role == .assistant,
                  !message.isStreaming else { continue }
            _ = NativeMarkdownParser.shared.parse(message.content)
        }
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        // Native layouts are immutable cache entries; no cancellation needed.
    }
}

extension ChatViewController: MessageCellDelegate {
    func messageCellShouldFreezeHeight(_ cell: MessageCell) -> Bool {
        tableView.isDragging || tableView.isDecelerating
    }

    func messageCell(_ cell: MessageCell, didUpdateHeight height: CGFloat, for messageID: String) {
        // Preserve the viewport while browsing history. Fixed snapshot height
        // metadata can still be recorded, but it must not trigger a table pass.
        if readingHistory {
            if height > 40 {
                contentHeights[messageID] = height
                if let cid = renderedConversationID {
                    heightCacheByConversation[cid] = contentHeights
                    RenderCacheStore.saveHeights(heightCacheByConversation)
                }
            }
            return
        }
        guard let msg = ConversationStore.shared.currentConversation?.messages.first(where: { $0.id == messageID }) else {
            return
        }
        // Finished rich replies have their own immutable raster height path.
        if (msg.role == .user) || (!msg.isStreaming && MarkdownHTMLRenderer.needsRichMarkdown(msg.content)) {
            contentHeights.removeValue(forKey: messageID)
            return
        }
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

    func messageCell(_ cell: MessageCell, didFinishStableRender height: CGFloat, for messageID: String) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let row = messages.firstIndex(where: { $0.id == messageID }),
              !messages[row].isStreaming else { return }
        contentHeights[messageID] = height
        if let cid = renderedConversationID {
            heightCacheByConversation[cid] = contentHeights
            RenderCacheStore.saveHeights(heightCacheByConversation)
        }
        guard cell.window != nil,
              !tableView.isDragging,
              !tableView.isDecelerating else { return }
        let path = IndexPath(row: row, section: 0)
        let targetRowHeight = height + 20
        guard abs(tableView.rectForRow(at: path).height - targetRowHeight) > 4 else { return }
        let anchor = readingHistory ? tableView.indexPathsForVisibleRows?.first : nil
        let anchorDelta = anchor.map { tableView.rectForRow(at: $0).minY - tableView.contentOffset.y }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            if stickToBottom && !readingHistory {
                scrollToBottom(animated: false)
            } else if let anchor = anchor, let anchorDelta = anchorDelta {
                tableView.contentOffset.y = tableView.rectForRow(at: anchor).minY - anchorDelta
            }
        }
    }

    private func flushPendingHeights(force: Bool = false) {
        if readingHistory {
            pendingHeights.removeAll()
            return
        }
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
            RenderCacheStore.saveHeights(heightCacheByConversation)
        }
        guard changed else { return }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            if stickToBottom && !readingHistory {
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

    func messageCellDidShiftVersion(_ cell: MessageCell, messageID: String, delta: Int) {
        guard let convID = ConversationStore.shared.currentConversationID else { return }
        var changed = false
        ConversationStore.shared.updateConversationQuietly(id: convID) { c in
            guard let idx = c.messages.firstIndex(where: { $0.id == messageID }) else { return }
            changed = c.messages[idx].shiftVersion(by: delta)
        }
        guard changed else { return }
        // Content length can differ a lot across versions — drop cached height.
        contentHeights.removeValue(forKey: messageID)
        if let cid = renderedConversationID {
            heightCacheByConversation[cid] = contentHeights
            RenderCacheStore.saveHeights(heightCacheByConversation)
        }
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let row = messages.firstIndex(where: { $0.id == messageID }) else { return }
        UIView.performWithoutAnimation {
            tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
        }
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
            if navigationItem.prompt != nil {
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
        // Keyboard collapse moves the input bar; wait until layout settles, then
        // anchor the menu above the + button (never leave a floating mid-screen card).
        let waitingForKeyboard = keyboardVisible
        view.endEditing(true)
        let show = { [weak self] in
            self?.view.layoutIfNeeded()
            self?.presentImagePicker()
        }
        if waitingForKeyboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: show)
        } else {
            DispatchQueue.main.async(execute: show)
        }
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
