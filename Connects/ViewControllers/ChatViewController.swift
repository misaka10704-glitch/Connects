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
    private var streamUITimer: Timer?
    private var lastStreamMessageID = ""
    private var lastStreamContentBytes = -1
    private var lastStreamReasoningBytes = -1
    private var lastStreamSearchBytes = -1
    private var lastStreamPhase: SearchProcessPhase = .idle
    private var lastStreamProgressAt = Date()
    private var lastStreamLayoutAt = Date.distantPast
    private var streamSpinnerFrame = 0
    private var heightWork: DispatchWorkItem?
    private var pendingHeights: [String: CGFloat] = [:]
    private var chromeWork: DispatchWorkItem?
    /// A vision pass turns attachments into durable text before they enter a conversation.
    private var isTranscribingImages = false
    /// Conversation currently waiting on web search before stream starts.
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
        if WebSearchCoordinator.shared.isSearching(id) { return true }
        if StreamManager.shared.isRunning(id) { return true }
        // Keep chrome/timer alive across the synchronous search → stream
        // handoff. Cold-launch orphan flags are repaired by ConversationStore.
        return ConversationStore.shared.currentConversation?.messages.last?.isStreaming == true
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
        NotificationCenter.default.addObserver(self, selector: #selector(webSearchUpdated(_:)), name: .webSearchDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(imageTranscriptionUpdated(_:)), name: .imageTranscriptionDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(retryImageTranscription(_:)), name: Notification.Name("ConnectsImageTranscriptionRetry"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(thinkingToggled(_:)), name: Notification.Name("ConnectsThinkingToggle"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(thinkingToggled(_:)), name: Notification.Name("ConnectsSearchToggle"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged), name: .chatFontSizeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(renderDebugChanged), name: .renderDebugDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(visibleModelsChanged), name: .visibleModelsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(agentsChanged), name: .agentsDidChange, object: nil)
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
    // v39: native math preview uses TeX fallback instead of blank placeholders.
    private static let renderSchemaVersion = 41
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


    deinit {
        streamUITimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

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
                cell.configure(with: messages[path.row], preferredHeight: nil, layoutWidth: currentRenderWidth())
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

    private func remeasureRowsPreservingViewport(anchorPath: IndexPath? = nil) {
        let anchor = anchorPath ?? tableView.indexPathsForVisibleRows?.first
        guard anchor?.section == 0,
              let anchor = anchor,
              anchor.row < tableView.numberOfRows(inSection: 0) else {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
            return
        }
        let anchorDelta = tableView.rectForRow(at: anchor).minY - tableView.contentOffset.y
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()
            let target = tableView.rectForRow(at: anchor).minY - anchorDelta
            let minOffset = -tableView.adjustedContentInset.top
            let maxOffset = max(
                minOffset,
                tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
            )
            tableView.contentOffset.y = min(max(target, minOffset), maxOffset)
        }
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
        emptyContainer.backgroundColor = c.background
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
        if let source = note.userInfo?["source"] as? String, source == "title" {
            updateTitleFromConversation()
            return
        }
        if let source = note.userInfo?["source"] as? String, source == "streamFinish" {
            updateTitleFromConversation()
            syncStreamingChrome()
            refreshContextUsage(animated: false)
            return
        }
        reloadChat()
    }

    @objc private func streamUpdated(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else { return }
        ensureStreamUITimer()
    }

    @objc private func webSearchUpdated(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else { return }
        syncStreamingChrome()
        ensureStreamUITimer()
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
            let message = messages[row]
            let layoutWidth = currentRenderWidth()
            let isSearch = note.name == Notification.Name("ConnectsSearchToggle")
            UIView.performWithoutAnimation {
                if let cell = tableView.cellForRow(at: path) as? MessageCell {
                    if isSearch {
                        cell.syncSearchPresentation(with: message, layoutWidth: layoutWidth)
                    } else {
                        cell.syncThinkingPresentation(with: message, layoutWidth: layoutWidth)
                    }
                } else {
                    tableView.reloadRows(at: [path], with: .none)
                }
                tableView.layoutIfNeeded()
            }
            DispatchQueue.main.async { [weak self] in
                self?.remeasureRowsPreservingViewport(anchorPath: path)
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

    @objc private func renderDebugChanged() {
        for case let cell as MessageCell in tableView.visibleCells {
            cell.refreshRenderDebugOverlay()
        }
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

    @objc private func agentsChanged() {
        guard let conversation = ConversationStore.shared.currentConversation,
              let selected = conversation.agentID,
              AgentStore.shared.agent(id: selected) == nil else {
            updateAgentButton()
            return
        }
        ConversationStore.shared.setAgent(nil, for: conversation.id)
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

    @objc private func imageTranscriptionUpdated(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else { return }
        contentHeights.removeAll()
        tableView.reloadData()
        refreshContextUsage()
    }

    @objc private func retryImageTranscription(_ note: Notification) {
        guard let assistantID = note.userInfo?["messageID"] as? String,
              let conversation = ConversationStore.shared.currentConversation,
              let assistantIndex = conversation.messages.firstIndex(where: { $0.id == assistantID }),
              assistantIndex > 0 else { return }
        let user = conversation.messages[assistantIndex - 1]
        guard user.role == .user,
              let base64 = user.imageJPEGBase64,
              !base64.isEmpty else {
            showAlert(title: "无法重试", message: "原始图片已不存在，无法重新转写。")
            return
        }
        let model = conversation.model.supportsVision ? conversation.model : AIModelOption.preferredVision
        ImageTranscriptionCoordinator.shared.start(
            conversationID: conversation.id,
            userMessageID: user.id,
            assistantMessageID: assistantID,
            base64: base64,
            model: model
        )
    }

    @objc private func streamFinished(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else { return }
        streamUIWork?.cancel()
        streamUIWork = nil
        stopStreamUITimer()
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
        } else if path.row < tableView.numberOfRows(inSection: 0) {
            UIView.performWithoutAnimation {
                tableView.reloadRows(at: [path], with: .none)
                tableView.layoutIfNeeded()
                if stickToBottom && !readingHistory {
                    scrollToBottom(animated: false, force: true)
                }
            }
        }
        maybeAutoCompactContext()
    }

    private func ensureStreamUITimer() {
        guard streamUITimer == nil, isCurrentStreaming else { return }
        lastStreamMessageID = ""
        lastStreamContentBytes = -1
        lastStreamReasoningBytes = -1
        lastStreamSearchBytes = -1
        lastStreamPhase = .idle
        lastStreamProgressAt = Date()
        lastStreamLayoutAt = .distantPast
        streamSpinnerFrame = 0
        let timer = Timer(timeInterval: 0.04,
                          target: self,
                          selector: #selector(streamUITick),
                          userInfo: nil,
                          repeats: true)
        streamUITimer = timer
        RunLoop.main.add(timer, forMode: .common)
        streamUITick()
    }

    private func stopStreamUITimer() {
        streamUITimer?.invalidate()
        streamUITimer = nil
    }

    @objc private func streamUITick() {
        guard isCurrentStreaming,
              let last = ConversationStore.shared.currentConversation?.messages.last,
              last.isStreaming else {
            stopStreamUITimer()
            return
        }
        // Streams only append text. Comparing whole growing Strings at 25 fps
        // becomes quadratic on long replies and can itself freeze an A7 iPad.
        let contentBytes = last.content.utf8.count
        let reasoningBytes = last.reasoningContent.utf8.count
        let searchBytes = last.searchProcessContent.utf8.count
        let changed = last.id != lastStreamMessageID
            || contentBytes != lastStreamContentBytes
            || reasoningBytes != lastStreamReasoningBytes
            || searchBytes != lastStreamSearchBytes
            || last.searchProcessPhase != lastStreamPhase
        if changed {
            lastStreamMessageID = last.id
            lastStreamContentBytes = contentBytes
            lastStreamReasoningBytes = reasoningBytes
            lastStreamSearchBytes = searchBytes
            lastStreamPhase = last.searchProcessPhase
            lastStreamProgressAt = Date()
            let now = Date()
            // Geometry must keep up even while the user reads history; only
            // auto-scrolling is suppressed in that mode.
            let shouldRelayout = now.timeIntervalSince(lastStreamLayoutAt) >= 0.14
            if shouldRelayout {
                lastStreamLayoutAt = now
            }
            refreshStreamingRow(waitingGlyph: nil, relayout: shouldRelayout)
            return
        }
        // The provider is still connected but has not produced a delta. Animate
        // a small thinking glyph at the visible stream tail instead of looking frozen.
        guard Date().timeIntervalSince(lastStreamProgressAt) >= 0.45 else { return }
        streamSpinnerFrame = (streamSpinnerFrame + 1) % 12
        guard streamSpinnerFrame % 3 == 0 else { return }
        let glyphs = ["◐", "◓", "◑", "◒"]
        refreshStreamingRow(
            waitingGlyph: glyphs[(streamSpinnerFrame / 3) % glyphs.count],
            relayout: false
        )
    }

    private func refreshStreamingRow(waitingGlyph: String?, relayout: Bool) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let last = messages.last, last.isStreaming else {
            return
        }
        let path = IndexPath(row: messages.count - 1, section: 0)
        UIView.performWithoutAnimation {
            var cell = tableView.cellForRow(at: path) as? MessageCell
            if cell == nil, !readingHistory {
                tableView.layoutIfNeeded()
                cell = tableView.cellForRow(at: path) as? MessageCell
            }
            if let cell = cell {
                if !cell.updateStreamingContent(last, waitingGlyph: waitingGlyph) {
                    cell.configure(with: last, preferredHeight: contentHeights[last.id], layoutWidth: currentRenderWidth())
                }
            } else if !readingHistory,
                      path.row < tableView.numberOfRows(inSection: 0) {
                // iOS 12 may not materialize a just-inserted self-sizing row.
                // Reconcile the whole table: reloadRows can throw if the store
                // already has new rows but UITableView's old snapshot does not.
                tableView.reloadData()
                tableView.layoutIfNeeded()
            }
            // UILabel content can grow beyond the existing self-sized row. Merely
            // changing its text leaves the new tail clipped until a conversation
            // reload. Re-measure at a bounded cadence, then follow the live tail.
            if relayout {
                tableView.beginUpdates()
                tableView.endUpdates()
                if stickToBottom && !readingHistory {
                    scrollToBottom(animated: false, force: true)
                }
            }
        }
    }

    private func syncStreamingChrome() {
        let running = isCurrentStreaming
        inputBar.isStreaming = running
        if running {
            ensureStreamUITimer()
        } else {
            stopStreamUITimer()
        }
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
            // Drop in-flight stream paint and nav prompt from the previous chat
            // before the empty/list chrome updates — otherwise iOS 12 leaves
            // "思考中… / 正在生成…" cell ghosts and a gray prompt capsule.
            streamUIWork?.cancel()
            streamUIWork = nil
            stopStreamUITimer()
            clearNavigationPrompt()
        }
        // User rows and reasoning rows must never inherit transient estimates.
        // Reasoning height depends on expanded/collapsed UI state, which is not
        // represented by the persisted message-ID-only cache.
        if let msgs = ConversationStore.shared.currentConversation?.messages {
            for m in msgs where m.role == .user || m.hasReasoning || m.hasSearchProcess {
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
        // Empty/list visibility must be sync: deferred chrome left the previous
        // streaming cell composited under a clear empty overlay.
        updateEmptyState()
        syncStreamingChrome()
        queueLegacyImageTranscriptionIfNeeded()
        if let messages = ConversationStore.shared.currentConversation?.messages {
            MessageCell.prewarmSnapshots(
                for: Array(messages.suffix(4)),
                targetWidth: currentRenderWidth()
            )
        }
        // Defer the rest of chrome so the message list paints first.
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.updateModelButton()
            self.updateAgentButton()
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

    /// Older conversations can still contain an image-only turn. Migrate one
    /// at a time after opening the chat, never in the send path.
    private func queueLegacyImageTranscriptionIfNeeded() {
        guard let conversation = ConversationStore.shared.currentConversation,
              !ImageTranscriptionCoordinator.shared.isTranscribing(conversation.id) else { return }
        for (index, message) in conversation.messages.enumerated()
            where message.role == .user
                && message.hasImage
                && (message.imageDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            guard let base64 = message.imageJPEGBase64,
                  index + 1 < conversation.messages.count,
                  conversation.messages[index + 1].role == .assistant else { continue }
            let assistant = conversation.messages[index + 1]
            guard assistant.imageTranscriptionPhase != .failed else { return }
            let model = conversation.model.supportsVision ? conversation.model : AIModelOption.preferredVision
            ImageTranscriptionCoordinator.shared.start(
                conversationID: conversation.id,
                userMessageID: message.id,
                assistantMessageID: assistant.id,
                base64: base64,
                model: model
            )
            return
        }
    }

    private func clearNavigationPrompt() {
        if navigationItem.prompt != nil {
            navigationItem.prompt = nil
            navigationController?.navigationBar.setNeedsLayout()
            navigationController?.navigationBar.layoutIfNeeded()
        }
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
        updateAgentButton()
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
        // Opaque so recycled streaming cells cannot bleed through on iOS 12.
        emptyContainer.backgroundColor = DSTheme.c.background
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
        let c = DSTheme.c
        emptyContainer.backgroundColor = c.background
        emptyContainer.isHidden = !empty
        tableView.isHidden = empty
        if empty {
            // Cancel any pending stream paint that could reconfigure a recycled cell.
            streamUIWork?.cancel()
            streamUIWork = nil
            clearNavigationPrompt()
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
        layoutEmptyChromeForKeyboard()
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

    private func updateAgentButton() {
        inputBar.setAgent(AgentStore.shared.agent(id: ConversationStore.shared.currentConversation?.agentID))
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
        if StreamManager.shared.isRunning(conv.id) || WebSearchCoordinator.shared.isSearching(conv.id) {
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

    /// Build API messages for a specific conversation — never the "currently visible" one by accident.
    private func apiContext(for model: AIModelOption, conversationID: String) -> [ChatMessage] {
        guard let conv = ConversationStore.shared.conversation(id: conversationID) else { return [] }
        let raw = conv.messages
        let agentPrompt = AgentStore.shared.agent(id: conv.agentID)?.trimmedPrompt
        let memoryBackground = MemoryStore.shared.injectedBackground()
        var keep = ContextBuilder.keepRecentTurns
        var built = ContextBuilder.build(
            from: raw,
            model: model,
            existingSummary: conv.contextSummary,
            existingThroughID: conv.contextSummaryThroughMessageID,
            agentPrompt: agentPrompt,
            memoryBackground: memoryBackground,
            keepRecentTurns: keep
        )
        if built.usage.shouldAutoCompact {
            keep = ContextBuilder.compactKeepRecentTurns
            built = ContextBuilder.build(
                from: raw,
                model: model,
                existingSummary: conv.contextSummary,
                existingThroughID: conv.contextSummaryThroughMessageID,
                agentPrompt: agentPrompt,
                memoryBackground: memoryBackground,
                keepRecentTurns: keep
            )
        }
        // Keep the extractive rolling summary so the next request never has to
        // rebuild (and accidentally truncate) its older context from scratch.
        // The dedicated compactor can still replace this with a richer LLM
        // summary once the soft budget is reached.
        if built.summary != conv.contextSummary || built.summaryThroughMessageID != conv.contextSummaryThroughMessageID {
            ConversationStore.shared.updateConversationQuietly(id: conversationID) { draft in
                draft.contextSummary = built.summary
                draft.contextSummaryThroughMessageID = built.summaryThroughMessageID
            }
        }
        if conversationID == currentConversationID {
            DispatchQueue.main.async { [weak self] in
                self?.refreshContextUsage()
            }
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
        if WebSearchCoordinator.shared.isSearching(conv.id) {
            showAlert(title: "正在联网搜索", message: "当前对话仍在检索网页，请先停止或等待完成。")
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

        ConversationStore.shared.updateConversationQuietly(id: convID) { c in
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

        let target = ConversationStore.shared.conversation(id: convID)
        let model = target?.model ?? conv.model
        let userText = target?.messages[userIndex].content ?? ""
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
                messages: apiContext(for: model, conversationID: convID),
                model: model,
                needsAITitle: needsAITitle
            )
        }
    }

    /// Plan queries from conversation → search → read pages → stream. Shared by send + retry.
    /// Each conversation has its own search generation so parallel chats never cancel or cross-wire.
    private func beginWebSearchThenStream(
        convID: String,
        model: AIModelOption,
        needsAITitle: Bool,
        query: String
    ) {
        let generation = WebSearchCoordinator.shared.begin(convID)
        syncStreamingChrome()
        updateSearchProcess(
            convID: convID,
            phase: .planning,
            body: "正在结合对话上下文规划检索词…\n（会消解「那这个呢」「为什么」等指代，而不是只搜最后一句。）"
        )

        let contextMsgs = apiContext(for: model, conversationID: convID)
        WebSearchService.planSearchQueries(
            contextMessages: contextMsgs,
            model: model,
            fallbackQuery: query
        ) { [weak self] plan in
            guard let self = self else { return }
            guard WebSearchCoordinator.shared.isCurrent(convID, generation: generation) else { return }

            let queries = plan.queries.isEmpty ? [query] : plan.queries
            #if DEBUG
            print("[Connects] web search plan [\(convID.prefix(6))]: \(queries), weights: \(plan.weightedTerms)")
            #endif

            var planLog = "根据对话上下文规划出的检索词：\n"
            for (i, q) in queries.enumerated() {
                planLog += "\(i + 1). \(q)\n"
            }
            if !plan.weightedTerms.isEmpty {
                planLog += "\n文章排序权重：\n"
                for weighted in plan.weightedTerms {
                    planLog += "· \(weighted.term) ×\(weighted.weight)\n"
                }
            }
            self.updateSearchProcess(convID: convID, phase: .searching, body: planLog)

            WebSearchService.searchAndFormat(
                queries: queries,
                weightedTerms: plan.weightedTerms,
                onStatus: { [weak self] status in
                    guard let self = self else { return }
                    guard WebSearchCoordinator.shared.isCurrent(convID, generation: generation) else { return }
                    if status.contains("阅读") {
                        self.updateSearchProcess(convID: convID, phase: .reading)
                    } else {
                        self.updateSearchProcess(convID: convID, phase: .searching)
                    }
                }
            ) { [weak self] result in
                guard let self = self else { return }
                guard WebSearchCoordinator.shared.isCurrent(convID, generation: generation) else { return }
                WebSearchCoordinator.shared.finish(convID, generation: generation)
                if self.currentConversationID == convID, self.navigationItem.prompt != nil {
                    self.navigationItem.prompt = nil
                }
                ConversationStore.shared.updateConversationQuietly(id: convID) { c in
                    guard var last = c.messages.last, last.isStreaming else { return }
                    last.content = ""
                    c.messages[c.messages.count - 1] = last
                }
                // Always rebuild from THIS conversation — never the currently visible chat.
                var msgs = self.apiContext(for: model, conversationID: convID)
                switch result {
                case .success(let bundle):
                    self.updateSearchProcess(
                        convID: convID,
                        phase: .done,
                        body: bundle.processLog
                    )
                    msgs = WebSearchService.inject(into: msgs, bundle: bundle)
                    msgs = WebSearchService.fitInjectedContext(msgs, model: model)
                case .failure(let err):
                    #if DEBUG
                    print("[Connects] web search failed [\(convID.prefix(6))]: \(err.localizedDescription)")
                    #endif
                    self.updateSearchProcess(
                        convID: convID,
                        phase: .done,
                        append: "\n\n检索未成功：\(err.localizedDescription)\n将改为不依赖网页证据直接作答。"
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
        }
    }

    private func updateSearchProcess(
        convID: String,
        phase: SearchProcessPhase,
        body: String? = nil,
        append: String? = nil
    ) {
        if currentConversationID == convID {
            if phase == .done {
                clearNavigationPrompt()
            } else {
                navigationItem.prompt = phase.headerTitle
            }
        }
        ConversationStore.shared.updateConversationQuietly(id: convID) { c in
            guard var last = c.messages.last, last.isStreaming else { return }
            last.searchProcessPhase = phase
            if let body = body {
                last.searchProcessContent = body
            } else if let append = append, !append.isEmpty {
                if last.searchProcessContent.isEmpty {
                    last.searchProcessContent = append.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if !last.searchProcessContent.contains(append.trimmingCharacters(in: CharacterSet.newlines)) {
                    last.searchProcessContent += append
                }
            }
            // Keep the main bubble free of status text — process lives in the collapsible panel.
            if last.content.hasPrefix("正在规划")
                || last.content.hasPrefix("正在搜索")
                || last.content.hasPrefix("正在阅读") {
                last.content = ""
            }
            c.messages[c.messages.count - 1] = last
        }
        if currentConversationID == convID {
            guard let messages = ConversationStore.shared.currentConversation?.messages,
                  !messages.isEmpty else { return }
            let path = IndexPath(row: messages.count - 1, section: 0)
            contentHeights.removeValue(forKey: messages[path.row].id)
            UIView.performWithoutAnimation {
                if let cell = tableView.cellForRow(at: path) as? MessageCell {
                    if !cell.updateStreamingContent(messages[path.row]) {
                        cell.configure(with: messages[path.row], preferredHeight: nil, layoutWidth: currentRenderWidth())
                    }
                } else {
                    tableView.reloadRows(at: [path], with: .none)
                }
                tableView.beginUpdates()
                tableView.endUpdates()
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

    private func agentTapped() {
        guard let conversationID = ConversationStore.shared.currentConversationID else { return }
        let currentID = ConversationStore.shared.currentConversation?.agentID
        var items = [ConnectsMenuItem(title: "不使用智能体", icon: .tshirt, isSelected: currentID == nil) {
            ConversationStore.shared.setAgent(nil, for: conversationID)
        }]
        items += AgentStore.shared.enabledAgents.map { agent in
            ConnectsMenuItem(title: agent.name, customImage: AgentAppearancePreset.avatar(for: agent),
                             isSelected: agent.id == currentID) {
                ConversationStore.shared.setAgent(agent.id, for: conversationID)
            }
        }
        items.append(ConnectsMenuItem(title: "管理智能体", icon: .settings) { [weak self] in
            self?.navigationController?.pushViewController(AgentListViewController(), animated: true)
        })
        ConnectsMenu.present(from: self, title: "本对话智能体", items: items,
                             sourceView: inputBar.agentAnchorView, preferAbove: true)
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

    private static let imageTranscriptionPrompt = """
    把图片转换为可供后续对话长期引用的准确中文文字描述。不要说“图中有公式/乐谱”，要把信息本身写出来。

    - 数学式、物理式、化学式：逐项转写为 LaTex；说明上下标、分式、积分上下限、矩阵、条件与定义。
    - 乐谱：转写标题、调号、拍号、速度、谱表、音高、节奏、临时记号、连线、指法、表情、力度、踏板与反复/段落标记；无法可靠辨识的部分明确标“无法辨识”，不要猜。
    - 图表、代码、表格、笔记：转写所有可辨文字、符号、结构、数据关系与标注。

    只输出“图片文字描述”正文，不要解释你的处理过程。
    """

    /// Convert all persisted image turns (and the pending attachment) into text
    /// before a continuation request. This keeps visual details useful after the
    /// base64 payload has been removed from both storage and later API contexts.
    private func transcribeImagesThenSend(_ text: String,
                                          pendingImageBase64: String?,
                                          conversationID: String) {
        guard let conv = ConversationStore.shared.conversation(id: conversationID) else { return }
        guard !isTranscribingImages else {
            showAlert(title: "正在识别图片", message: "请等待图片转写完成后再发送。")
            return
        }

        let captionModel = conv.model.supportsVision ? conv.model : AIModelOption.preferredVision
        guard SettingsManager.shared.hasAPIKey(for: captionModel.provider) else {
            showAlert(
                title: "缺少视觉模型 Key",
                message: "图片需要先转写为文字。请在设置中填写 \(captionModel.provider.displayName) 的 API Key。"
            )
            return
        }

        var pending = conv.messages.compactMap { message -> (String, String)? in
            guard let base64 = message.imageJPEGBase64, !base64.isEmpty else { return nil }
            return (message.id, base64)
        }
        let pendingAttachmentID = "__pending_image__"
        if let base64 = pendingImageBase64, !base64.isEmpty {
            pending.append((pendingAttachmentID, base64))
        }
        guard !pending.isEmpty else {
            performSend(text, imageBase64: nil, conversationID: conversationID)
            return
        }

        isTranscribingImages = true
        if currentConversationID == conversationID {
            navigationItem.prompt = "正在将图片转写为文字…"
        }
        var descriptions: [String: String] = [:]

        func finish(_ error: Error? = nil) {
            self.isTranscribingImages = false
            if self.currentConversationID == conversationID,
               self.navigationItem.prompt == "正在将图片转写为文字…" {
                self.navigationItem.prompt = nil
            }
            if let error = error {
                self.showAlert(title: "图片转写失败", message: "\(error.localizedDescription)\n图片未发送，请重试。")
                return
            }

            ConversationStore.shared.updateConversation(id: conversationID) { value in
                for i in value.messages.indices {
                    let id = value.messages[i].id
                    guard let description = descriptions[id] else { continue }
                    let block = "【图片文字描述】\n\(description)"
                    if value.messages[i].content == "[图片]" {
                        value.messages[i].content = block
                    } else {
                        value.messages[i].content += "\n\n\(block)"
                    }
                    value.messages[i].imageJPEGBase64 = nil
                }
            }

            let attachmentDescription = descriptions[pendingAttachmentID]
                .map { "【图片文字描述】\n\($0)" } ?? ""
            let combinedText: String
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combinedText = attachmentDescription
            } else if attachmentDescription.isEmpty {
                combinedText = text
            } else {
                combinedText = text + "\n\n" + attachmentDescription
            }
            self.performSend(combinedText, imageBase64: nil, conversationID: conversationID)
        }

        func transcribe(at index: Int) {
            guard index < pending.count else {
                finish()
                return
            }
            let item = pending[index]
            let prompt = ChatMessage(
                role: .user,
                content: Self.imageTranscriptionPrompt,
                imageJPEGBase64: item.1
            )
            APIClient.shared.complete(messages: [prompt], model: captionModel, maxTokens: 2_000) { result in
                switch result {
                case .success(let text):
                    let description = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !description.isEmpty else {
                        finish(APIClientError.decodeError)
                        return
                    }
                    descriptions[item.0] = description
                    transcribe(at: index + 1)
                case .failure(let error):
                    finish(error)
                }
            }
        }

        transcribe(at: 0)
    }

    private func sendMessage(_ text: String, imageBase64: String?) {
        guard var conv = ConversationStore.shared.currentConversation else { return }

        if StreamManager.shared.isRunning(conv.id) {
            showAlert(title: "正在生成", message: "当前对话仍在回复中，请先点停止或等待完成。")
            return
        }
        if WebSearchCoordinator.shared.isSearching(conv.id) {
            showAlert(title: "正在联网搜索", message: "当前对话仍在检索网页，请先点停止或等待完成。")
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
        let intendedConversationID = conv.id
        if usage.shouldAutoCompact {
            contextUsageView.setCompacting(true)
            // Capture and clear now. If the user switches chats while compacting,
            // the callback must neither erase the new chat's draft nor redirect
            // this send to whichever conversation happens to be visible.
            inputBar.clearText()
            ContextCompactor.compactIfNeeded(conversationID: intendedConversationID, force: true) { [weak self] _ in
                guard let self = self else { return }
                self.contextUsageView.setCompacting(false)
                if self.currentConversationID == intendedConversationID {
                    self.refreshContextUsage()
                }
                self.performSend(
                    text,
                    imageBase64: imageBase64,
                    conversationID: intendedConversationID
                )
            }
            return
        }
        performSend(text, imageBase64: imageBase64, conversationID: intendedConversationID)
    }

    private func performSend(_ text: String,
                             imageBase64: String?,
                             conversationID: String) {
        guard let conv = ConversationStore.shared.conversation(id: conversationID) else { return }

        let needsAITitle = (conv.title == "新对话" || conv.title.hasSuffix("（分叉）")) && !conv.titleLocked
        let displayText = text.isEmpty && imageBase64 != nil ? "[图片]" : text
        let userMsg = ChatMessage(role: .user, content: displayText, imageJPEGBase64: imageBase64)
        let searchOn = SettingsManager.shared.webSearchEnabled && !displayText.isEmpty && displayText != "[图片]"
        let assistantMsg = ChatMessage(
            role: .assistant,
            content: "",
            reasoningContent: "",
            searchProcessContent: searchOn ? "正在结合对话上下文规划检索词…" : "",
            searchProcessPhase: searchOn ? .planning : .idle,
            isStreaming: true
        )
        let convID = conv.id
        let model = conv.model
        let firstNewRow = conv.messages.count

        ConversationStore.shared.updateConversationQuietly(id: conversationID) { c in
            c.messages.append(userMsg)
            c.messages.append(assistantMsg)
        }
        var memoryConversation = conv
        memoryConversation.messages.append(userMsg)
        MemoryStore.shared.append(userText: displayText, conversation: memoryConversation)

        if currentConversationID == convID {
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
                tableView.layoutIfNeeded()
            }
            scrollToBottom(animated: true, force: true)
            stickToBottom = true
            refreshContextUsage()
        }
        // This posts a title notification. Do it only after UITableView has
        // consumed the two inserted rows; otherwise syncStreamingChrome can
        // start the stream timer against the table's old zero-row snapshot.
        if needsAITitle {
            ConversationStore.shared.applyProvisionalTitle(id: convID, fromUserText: displayText)
        }

        if searchOn {
            beginWebSearchThenStream(
                convID: convID,
                model: model,
                needsAITitle: needsAITitle,
                query: displayText
            )
        } else {
            if currentConversationID == convID {
                syncStreamingChrome()
            }
            StreamManager.shared.start(
                conversationID: convID,
                messages: apiContext(for: model, conversationID: convID),
                model: model,
                needsAITitle: needsAITitle
            )
        }

        // Do not make a reply wait for OCR/vision extraction. The first request
        // has already captured the image (or will use its finished description);
        // this independent job prepares the compact durable context for later
        // turns and drives the small status label on the companion reply.
        if let imageBase64 = imageBase64, !imageBase64.isEmpty {
            let captionModel = model.supportsVision ? model : AIModelOption.preferredVision
            ImageTranscriptionCoordinator.shared.start(
                conversationID: convID,
                userMessageID: userMsg.id,
                assistantMessageID: assistantMsg.id,
                base64: imageBase64,
                model: captionModel
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
            cell.configure(with: msg, preferredHeight: contentHeights[msg.id], layoutWidth: currentRenderWidth())
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
                if msg.hasSearchProcess { chrome += 44 }
                return layout.size.height + chrome
            }
        }
        let reasoningExpanded = msg.hasReasoning && MessageCell.isThinkingExpanded(messageID: msg.id)
        let reasoningChars = reasoningExpanded
            ? msg.reasoningContent.count
            : (msg.reasoningContent.isEmpty ? 0 : 40)
        let chars = max(msg.content.count, reasoningChars)
        let lines = max(1, chars / 48)
        var rough = CGFloat(36 + lines * 18)
        if msg.hasImage { rough += 168 }
        if msg.hasReasoning {
            rough += reasoningExpanded ? CGFloat(28 + max(1, msg.reasoningContent.count / 48) * 18) : 36
        }
        if msg.hasSearchProcess { rough += 36 }
        if msg.role == .assistant && !msg.isStreaming { rough += 28 }
        if msg.hasReasoning || msg.hasSearchProcess {
            // Oversized estimates leave permanent blank bands above thinking
            // headers until a later remeasure on iOS 12.
            return min(max(rough, 64), 720)
        }
        // Do not cap a completed answer at a small estimate. iOS 12 can retain
        // that estimate during a cross-chat transition, visibly compressing
        // long replies until a later layout pass happens.
        return min(max(rough, 64), 4_000)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let cell = cell as? MessageCell,
              let msg = ConversationStore.shared.currentConversation?.messages[indexPath.row],
              !msg.isStreaming else { return }
        let layoutWidth = currentRenderWidth()
        if msg.role == .assistant {
            cell.ensureNativeLayoutWidth(layoutWidth)
        } else if msg.role == .user {
            cell.syncUserPresentation(with: msg, layoutWidth: layoutWidth)
        }
        cell.refreshRenderDebugOverlay()
        guard msg.role == .user || msg.hasReasoning || msg.hasSearchProcess else { return }
        DispatchQueue.main.async { [weak self, weak cell] in
            guard let self = self,
                  let cell = cell,
                  cell.messageID == msg.id,
                  cell.window != nil,
                  !self.tableView.isDragging,
                  !self.tableView.isDecelerating else { return }
            let height = cell.measuredContentHeight()
            guard height > 40 else { return }
            self.messageCell(cell, didFinishStableRender: height, for: msg.id)
        }
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
        // Streaming text paints at 25 fps, but UITableView self-sizing is much
        // heavier. Limit live geometry updates so they cannot starve token paint.
        let delay: TimeInterval = msg.isStreaming ? 0.14 : (growing ? 0.03 : 0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func messageCell(_ cell: MessageCell, didFinishStableRender height: CGFloat, for messageID: String) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let row = messages.firstIndex(where: { $0.id == messageID }),
              !messages[row].isStreaming else { return }
        let message = messages[row]
        let hasVariableChrome = !message.reasoningContent.isEmpty || message.hasSearchProcess
        if message.role == .user || hasVariableChrome {
            contentHeights.removeValue(forKey: messageID)
        } else {
            contentHeights[messageID] = height
            if let cid = renderedConversationID {
                heightCacheByConversation[cid] = contentHeights
                RenderCacheStore.saveHeights(heightCacheByConversation)
            }
        }
        guard cell.window != nil,
              !tableView.isDragging,
              !tableView.isDecelerating else { return }
        let path = IndexPath(row: row, section: 0)
        let targetRowHeight = height + 20
        guard abs(tableView.rectForRow(at: path).height - targetRowHeight) > 4 else { return }
        if hasVariableChrome || message.role == .user {
            remeasureRowsPreservingViewport(anchorPath: path)
            return
        }
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
        let includesStreamingMessage = pendingHeights.keys.contains { id in
            ConversationStore.shared.currentConversation?.messages.first(where: { $0.id == id })?.isStreaming == true
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
        // Live heights are transient and change several times per second. Keep
        // them in memory only; persist the final stable height after completion.
        if changed, !includesStreamingMessage, let cid = renderedConversationID {
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
    func inputBarDidTapAgent() {
        agentTapped()
    }

    func inputBarDidTapSend(text: String, imageBase64: String?) {
        sendMessage(text, imageBase64: imageBase64)
    }

    func inputBarDidTapStop() {
        guard let id = currentConversationID else { return }
        if WebSearchCoordinator.shared.isSearching(id) {
            WebSearchCoordinator.shared.cancel(id)
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
