import UIKit

protocol ChatViewControllerDelegate: AnyObject {
    func chatDidUpdateTitle(_ title: String)
    func chatDidRequestShare()
    func chatDidFinishInitialLaunch()
}

final class ChatViewController: UIViewController, ThemeRefreshable, UIImagePickerControllerDelegate, UINavigationControllerDelegate, StudyDocumentPickerDelegate {
    enum StudyChromeMode: Equatable {
        case none
        case documentReader
        case portraitPanel
    }

    weak var delegate: ChatViewControllerDelegate?
    weak var studyContextProvider: StudyReadingContextProviding?
    var onToggleSidebar: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let turnContextBar = TurnContextBarView()
    private let inputBar = InputBarView()
    private let contextUsageView = ContextUsageView()
    private let modelButton = UIButton(type: .custom)
    private let emptyTitleLabel = UILabel()
    private let emptySubtitleLabel = UILabel()
    private let emptyContainer = UIView()
    private var emptyChips: UIStackView?
    private var sidebarToggleItem: UIBarButtonItem?
    private var pendingSidebarCollapsed: Bool?
    private var studyChromeMode: StudyChromeMode = .none
    private var bottomConstraint: NSLayoutConstraint?
    private var composerBottomUsesViewBottom = false
    private var inputSideInsetConstraint: NSLayoutConstraint?
    private var turnContextBarTopToSafe: NSLayoutConstraint!
    private var turnContextBarTopToView: NSLayoutConstraint!
    private var isCompactChrome = false
    private var keyboardVisible = false
    private var isReloadingFromStore = false
    private var needsDeferredStoreReload = false
    private var suppressHeightRemeasure = false
    private let rowHeights = ChatRowHeightResolver()
    private var heightCacheByConversation: [String: [String: CGFloat]] = [:]
    private var renderedConversationID: String?
    private var stickToBottom = true
    /// Set by a user drag away from the latest turn. Unlike `stickToBottom`,
    /// this cannot be changed by WebKit/table layout callbacks.
    private var readingHistory = false
    /// User manually moved the viewport — never auto-scroll to bottom until they return.
    private var viewportPinnedByUser = false
    /// After switching conversations, keep scrolling to the latest turn until layout settles.
    private var pendingOpenAtBottom = false
    /// Bumped on every conversation switch — async open/prewarm must bail when stale.
    private var openGeneration: UInt = 0
    private var contextUserIndex: Int?
    private var contextBarWork: DispatchWorkItem?
    private var contextUsageWork: DispatchWorkItem?
    private var contextUsageCache: [String: ContextBuilder.Usage] = [:]
    private var userTurnRowsCache: (
        conversationID: String?,
        messageCount: Int,
        firstMessageID: String?,
        lastMessageID: String?,
        rows: [Int]
    )?
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
    private var prewarmWork: DispatchWorkItem?
    private var deferredRenderWork: DispatchWorkItem?
    private var openSettleWork: DispatchWorkItem?
    private var openSettleFollowUpWork: DispatchWorkItem?
    private var openCoalesceWork: DispatchWorkItem?
    private static let switchCoalesceDelay: TimeInterval = 0.12
    private var idlePrewarmWork: DispatchWorkItem?
    private var lastScrollOffsetY: CGFloat = 0
    private var scrollBiasUp = false
    private var scrollSettleWork: DispatchWorkItem?
    private var pinnedRemeasureWork: DispatchWorkItem?
    private var jumpAnchorWork: DispatchWorkItem?
    private var heightCacheSaveWork: DispatchWorkItem?
    private var contextBarScrollWork: DispatchWorkItem?
    /// A vision pass turns attachments into durable text before they enter a conversation.
    private var isTranscribingImages = false
    /// Conversation currently waiting on web search before stream starts.
    /// Rounded chat width — heights are invalid across rotation / Slide Over.
    private var layoutWidthBucket: Int = 0
    private var widthInvalidateWork: DispatchWorkItem?
    private static let imageCache = NSCache<NSString, UIImage>()
    private static let attrCache = NSCache<NSString, NSAttributedString>()
    private static let switchPrewarmMessageWindow = 40
    private static let switchPrewarmParseCount = 8
    private static let switchPrewarmLayoutBatch = 3
    private static let switchPrewarmLayoutTotal = 20
    /// How many Q&A turns to layout ahead of the visible viewport.
    private static let turnPrewarmCount = 3

    static func clearTransientRenderCaches() {
        imageCache.removeAllObjects()
        attrCache.removeAllObjects()
    }

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
        setupTurnContextBar()
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
        NotificationCenter.default.addObserver(self, selector: #selector(turnContextBarChanged), name: .turnContextBarDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(visibleModelsChanged), name: .visibleModelsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(agentsChanged), name: .agentsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamTTFT(_:)), name: Notification.Name("ConnectsStreamTTFT"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contextUsageChanged(_:)), name: .contextUsageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contextCompactionFinished(_:)), name: .contextCompactionDidFinish, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(chatWidthDidChange(_:)), name: .connectsChatWidthDidChange, object: nil)
        migrateRenderSchemaIfNeeded()
        if !didMigrateRenderSchema {
            loadLaunchHeightCaches()
        }
        registerKeyboard()
        applyTheme()
        layoutWidthBucket = widthBucket(for: view.bounds.width)
        if didMigrateRenderSchema {
            didMigrateRenderSchema = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                self.prewarmVisibleRichReplies(for: self.currentRenderWidth())
            }
        }
        bootstrapColdLaunchChrome()
    }

    /// Align empty/list chrome with the restored store before the first open bind.
    private func bootstrapColdLaunchChrome() {
        updateEmptyState()
        guard renderedConversationID == nil else { return }
        let hasMessages = !(ConversationStore.shared.currentConversation?.messages.isEmpty ?? true)
        guard hasMessages else { return }
        // Launch overlay covers the chat, but keep the empty-state UI from flashing
        // underneath if the overlay is dismissed early.
        emptyContainer.isHidden = true
        tableView.isHidden = true
    }

    private func loadLaunchHeightCaches() {
        guard let conversationID = ConversationStore.shared.currentConversationID else { return }
        heightCacheByConversation = RenderCacheStore.loadHeights(forConversationID: conversationID)
    }

    private func ensureHeightCacheLoaded(for conversationID: String) {
        let widthPrefix = conversationID + "|w"
        let hasBucket = heightCacheByConversation.keys.contains {
            $0 == conversationID || $0.hasPrefix(widthPrefix)
        }
        guard !hasBucket else { return }
        let loaded = RenderCacheStore.loadHeights(forConversationID: conversationID)
        for (key, map) in loaded {
            heightCacheByConversation[key] = map
        }
    }

    /// 1.4.13 briefly routed tables to PlainMarkdown; wipe bad height caches so old chats remasure.
    private static let renderSchemaKey = "connects_render_schema"
    // v39: native math preview uses TeX fallback instead of blank placeholders.
    // v43: build 131 cheap height seeds clipped rows — remeasure from scratch.
    private static let renderSchemaVersion = 44
    private var didMigrateRenderSchema = false
    private var didPerformColdOpenRescue = false
    private var didNotifyInitialLaunch = false
    private var isPerformingColdLaunchOpen = false
    private static let coldLaunchLayoutProbeRows = 10

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyStudyChrome()
        if renderedConversationID == nil, view.window != nil {
            // Bind the restored conversation as soon as we are in a window —
            // before the first painted frame shows the empty-state chrome.
            reloadChat()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if renderedConversationID == nil, view.window != nil {
            // Root preloads this controller before its navigation view is in a
            // window. UITableView must not lay out/reload its visible rows yet.
            reloadChat()
        }
        if stickToBottom,
           let messages = ConversationStore.shared.currentConversation?.messages,
           !messages.isEmpty {
            // Opening can begin while this controller is still outside the
            // window hierarchy. Pin only after it has real bounds.
            pinOpenViewportToBottom(messages)
        }
        guard !didPerformColdOpenRescue else { return }
        didPerformColdOpenRescue = true
        // First appearance after launch — give WKWebView a second chance if the
        // initial inject raced ahead of KaTeX/marked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.rescueBlankRichCells()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.scheduleIdleConversationPrewarm()
        }
    }

    /// If a rich cell is still showing blank WebView / failed inject, rebind it.
    private func rescueBlankRichCells() {
        // Snap-hold open already paints rich bodies — sync prewarm here only fights the open frame.
        guard !pendingOpenAtBottom, !suppressHeightRemeasure else { return }
        prewarmVisibleRichReplies(for: currentRenderWidth())
    }

    private func migrateRenderSchemaIfNeeded() {
        let ud = UserDefaults.standard
        let v = ud.integer(forKey: Self.renderSchemaKey)
        guard v < Self.renderSchemaVersion else { return }
        rowHeights.clearAll()
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
        RenderCacheStore.widthBucket(for: width)
    }

    private func scheduleInvalidateHeightsForWidthChange() {
        widthInvalidateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.invalidateHeightsForWidthChange(immediate: true)
        }
        widthInvalidateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Width bucket change — rebind visible cells at the new layout width.
    private func invalidateHeightsForWidthChange(immediate: Bool) {
        // Root can calculate its initial split constraints before this child is
        // attached to a window. Defer table work until UIKit has real geometry.
        guard tableView.window != nil else { return }
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let visible = tableView.indexPathsForVisibleRows ?? []
        let anchor = visible.first
        let anchorDelta = anchor.map {
            tableView.rectForRow(at: $0).minY - tableView.contentOffset.y
        }
        // Rebuild in-memory row geometry for the new width. Keep disk maps for other
        // buckets (and this one) — wiping here made the next open use empty cheap estimates.
        let layoutWidth = currentRenderWidth()
        let disk: [String: CGFloat]
        if let cid = renderedConversationID {
            disk = persistedHeights(for: cid)
        } else {
            disk = [:]
        }
        rowHeights.resetForConversation(
            diskCache: disk,
            messages: messages,
            layoutWidth: layoutWidth
        )
        UIView.performWithoutAnimation {
            tableView.layoutIfNeeded()
            for path in visible where path.row < messages.count {
                guard let cell = tableView.cellForRow(at: path) as? MessageCellType else { continue }
                cell.contentView.setNeedsLayout()
                cell.contentView.layoutIfNeeded()
                cell.configure(
                    with: messages[path.row],
                    preferredHeight: rowHeights.displayColumnHeight(for: messages[path.row].id),
                    layoutWidth: layoutWidth
                )
            }
            tableView.beginUpdates()
            tableView.endUpdates()
            if stickToBottom && !isViewportPinned() {
                scrollToBottom(animated: false)
            } else if let anchor = anchor, let anchorDelta = anchorDelta {
                tableView.contentOffset.y = tableView.rectForRow(at: anchor).minY - anchorDelta
            }
        }
        prewarmVisibleRichReplies(for: layoutWidth)
        _ = immediate
    }

    private func currentRenderWidth() -> CGFloat {
        // Table width is authoritative for chat layout. Only fall back to view when
        // the table has not been laid out yet (avoid min(table, view) eating sidebar math).
        let tableW = tableView.bounds.width
        let raw = tableW > 1 ? tableW : max(view.bounds.width, 0)
        return min(DSTheme.bubbleMaxWidth, max(raw - 48, 120))
    }

    /// Latest finished assistant reply — open path sync-paints this row first.
    private func tailAssistantMessageID(in messages: [ChatMessage]) -> String? {
        for msg in messages.reversed() {
            guard msg.role == .assistant, !msg.isStreaming, !msg.content.isEmpty else { continue }
            return msg.id
        }
        return nil
    }

    private func isTailAssistantMessage(_ messageID: String) -> Bool {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let tail = tailAssistantMessageID(in: messages) else { return false }
        return messageID == tail
    }

    /// Heights are width-specific — portrait must not reuse landscape row geometry.
    private func heightCacheStorageKey(for conversationID: String,
                                       width: CGFloat? = nil) -> String {
        RenderCacheStore.heightCacheStorageKey(
            conversationID: conversationID,
            layoutWidth: width ?? currentRenderWidth()
        )
    }

    /// Exact width bucket only — never bootstrap open from landscape/other-bucket heights.
    private func exactPersistedHeights(for conversationID: String) -> [String: CGFloat] {
        heightCacheByConversation[heightCacheStorageKey(for: conversationID)] ?? [:]
    }

    /// Exact width bucket, else nearest other-width / legacy map so first portrait open
    /// still has a non-empty contentSize (empty bucket → mid-screen open).
    private func persistedHeights(for conversationID: String) -> [String: CGFloat] {
        ensureHeightCacheLoaded(for: conversationID)
        return RenderCacheStore.nearestPersistedHeights(
            conversationID: conversationID,
            layoutWidth: currentRenderWidth(),
            cache: heightCacheByConversation
        )
    }

    private func storePersistedHeights(_ map: [String: CGFloat], for conversationID: String) {
        heightCacheByConversation[heightCacheStorageKey(for: conversationID)] = map
    }

    private func prewarmVisibleRichReplies(for width: CGFloat) {
        let visible = tableView.indexPathsForVisibleRows ?? []
        guard !visible.isEmpty else { return }
        applyTurnWindowPrewarm(around: visible.map(\.row))
        _ = width
    }

    private func userTurnStartRows(in messages: [ChatMessage]) -> [Int] {
        let conversationID = currentConversationID
        let firstMessageID = messages.first?.id
        let lastMessageID = messages.last?.id
        if let cache = userTurnRowsCache,
           cache.conversationID == conversationID,
           cache.messageCount == messages.count,
           cache.firstMessageID == firstMessageID,
           cache.lastMessageID == lastMessageID {
            return cache.rows
        }
        let rows = messages.indices.filter { messages[$0].role == .user }
        userTurnRowsCache = (
            conversationID: conversationID,
            messageCount: messages.count,
            firstMessageID: firstMessageID,
            lastMessageID: lastMessageID,
            rows: rows
        )
        return rows
    }

    private func userTurnIndex(containingRow row: Int, in messages: [ChatMessage]) -> Int? {
        let turns = userTurnStartRows(in: messages)
        guard !turns.isEmpty else { return nil }
        for (index, userRow) in turns.enumerated() {
            let end = (index + 1 < turns.count) ? turns[index + 1] : messages.count
            if row >= userRow, row < end {
                return index
            }
        }
        if row < turns[0] { return 0 }
        return turns.count - 1
    }

    /// Up to `turnPrewarmCount` user-turn rows around `anchorRow`, biased by scroll direction.
    private func turnWindowUserRows(around anchorRow: Int, in messages: [ChatMessage]) -> [Int] {
        let turns = userTurnStartRows(in: messages)
        guard !turns.isEmpty else { return [] }
        let turnIndex = userTurnIndex(containingRow: anchorRow, in: messages) ?? (turns.count - 1)
        let start: Int
        if scrollBiasUp {
            start = max(0, turnIndex - (Self.turnPrewarmCount - 1))
        } else {
            start = max(0, min(turnIndex, turns.count - Self.turnPrewarmCount))
        }
        let end = min(turns.count, start + Self.turnPrewarmCount)
        return Array(turns[start..<end])
    }

    private static let syncPrewarmMaxChars = 700
    private static let switchPrewarmTurnPairs = 5
    private static let recentConversationPrewarmLimit = 8

    /// Background layout warm for recent sidebar conversations (one tail each).
    func prewarmRecentConversationTails(limit: Int = recentConversationPrewarmLimit,
                                        skipConversationID: String? = nil) {
        let layoutWidth = currentRenderWidth()
        let skip = skipConversationID ?? renderedConversationID
        var warmed = 0
        for conv in ConversationStore.shared.visibleConversations {
            if conv.id == skip { continue }
            guard !conv.messages.isEmpty else { continue }
            AssistantMessageLayout.prewarmSwitchTailOnBackground(
                messages: conv.messages,
                layoutWidth: layoutWidth,
                turnPairLimit: 1
            )
            warmed += 1
            if warmed >= limit { break }
        }
    }

    private func scheduleIdleConversationPrewarm() {
        idlePrewarmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard !self.tableView.isDragging, !self.tableView.isDecelerating else { return }
            self.prewarmRecentConversationTails()
        }
        idlePrewarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Start layout warm as soon as the user targets a conversation (before store reload).
    func prepareForConversationSwitch(to conversationID: String) {
        guard conversationID != renderedConversationID else { return }
        prewarmConversationSwitch(to: conversationID)
    }

    func prewarmConversationSwitch(to conversationID: String) {
        guard let conv = ConversationStore.shared.conversation(id: conversationID),
              !conv.messages.isEmpty else { return }
        let prewarmGeneration = AssistantMessageLayout.bumpSwitchPrewarmGeneration()
        let layoutWidth = currentRenderWidth()
        let messages = conv.messages
        AssistantMessageLayout.layoutPrewarmQueue.async {
            guard AssistantMessageLayout.isSwitchPrewarmGeneration(prewarmGeneration) else { return }
            AssistantMessageLayout.prewarmSnapshots(
                for: messages,
                targetWidth: layoutWidth,
                parseLimit: 2
            )
        }
        AssistantMessageLayout.prewarmSwitchTailOnBackground(
            messages: messages,
            layoutWidth: layoutWidth,
            turnPairLimit: Self.switchPrewarmTurnPairs,
            generation: prewarmGeneration
        )
    }

    private func applyTurnWindowPrewarm(around anchorRows: [Int],
                                        allowSync: Bool = true,
                                        syncCharLimit: Int = ChatViewController.syncPrewarmMaxChars) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              !anchorRows.isEmpty else { return }
        var userRows = Set<Int>()
        for row in anchorRows where row >= 0 && row < messages.count {
            turnWindowUserRows(around: row, in: messages).forEach { userRows.insert($0) }
        }
        guard !userRows.isEmpty else { return }
        let sortedUserRows = userRows.sorted()
        let layoutWidth = currentRenderWidth()
        var syncTargets: [ChatMessage] = []
        var asyncTargets: [ChatMessage] = []
        for userRow in sortedUserRows {
            let assistantRow = userRow + 1
            guard assistantRow < messages.count else { continue }
            let assistant = messages[assistantRow]
            guard assistant.role == .assistant, !assistant.isStreaming else { continue }
            if AssistantMessageLayout.hasCachedNativeLayout(for: assistant, layoutWidth: layoutWidth) {
                continue
            }
            if allowSync, assistant.content.count <= syncCharLimit, syncTargets.count < 2 {
                syncTargets.append(assistant)
            } else {
                asyncTargets.append(assistant)
            }
        }
        if !syncTargets.isEmpty {
            AssistantMessageLayout.prewarmLayouts(
                for: syncTargets,
                targetWidth: layoutWidth,
                layoutLimit: syncTargets.count
            )
        }
        if !asyncTargets.isEmpty {
            scheduleAsyncLayoutPrewarm(assistants: asyncTargets, layoutWidth: layoutWidth)
        }
    }

    /// Layout replies off the scroll critical path (one assistant per runloop turn).
    private func scheduleAsyncLayoutPrewarm(assistants: [ChatMessage], layoutWidth: CGFloat) {
        guard !assistants.isEmpty else { return }
        let openID = renderedConversationID
        let gen = openGeneration
        var remaining = assistants
        func pump() {
            guard gen == self.openGeneration,
                  openID == self.renderedConversationID,
                  openID == self.currentConversationID,
                  !remaining.isEmpty else { return }
            let scrolling = tableView.isDragging || tableView.isDecelerating
            let nextIndex: Int?
            if scrolling {
                // While scrolling, only warm short replies; defer long ones until idle.
                nextIndex = remaining.firstIndex { $0.content.count <= Self.syncPrewarmMaxChars }
                if nextIndex == nil {
                    let work = DispatchWorkItem { pump() }
                    prewarmWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
                    return
                }
            } else {
                nextIndex = remaining.startIndex
            }
            guard let idx = nextIndex else { return }
            let next = remaining.remove(at: idx)
            guard gen == self.openGeneration else { return }
            AssistantMessageLayout.prewarmLayoutsOnBackground(
                for: [next],
                targetWidth: layoutWidth,
                layoutLimit: 1,
                completion: { [weak self] in
                    guard let self = self,
                          gen == self.openGeneration,
                          openID == self.renderedConversationID,
                          openID == self.currentConversationID else { return }
                    if let messages = ConversationStore.shared.currentConversation?.messages,
                       let row = messages.firstIndex(where: { $0.id == next.id }),
                       !self.rowHeights.isCommitted(next.id),
                       let column = AssistantMessageLayout.estimatedColumnContentHeight(
                           for: next,
                           layoutWidth: layoutWidth,
                           isLastRow: row == messages.count - 1,
                           allowSyncLayout: false
                       ), column > 40 {
                        self.rowHeights.commitMeasured(columnHeight: column, messageID: next.id, allowShrink: true)
                    }
                    if !remaining.isEmpty {
                        let work = DispatchWorkItem { pump() }
                        self.prewarmWork = work
                        DispatchQueue.main.async(execute: work)
                    }
                }
            )
            return
        }
        prewarmWork?.cancel()
        let work = DispatchWorkItem { pump() }
        prewarmWork = work
        DispatchQueue.main.async(execute: work)
    }

    /// Interrupt in-flight open/settle/prewarm/snap-upgrade from the previous conversation.
    private func cancelOpenPipeline() {
        openGeneration &+= 1
        _ = AssistantMessageLayout.bumpSwitchPrewarmGeneration()
        pendingOpenAtBottom = false
        suppressHeightRemeasure = false
        tableView.alpha = 1
        prewarmWork?.cancel()
        prewarmWork = nil
        deferredRenderWork?.cancel()
        deferredRenderWork = nil
        openSettleWork?.cancel()
        openSettleWork = nil
        openSettleFollowUpWork?.cancel()
        openSettleFollowUpWork = nil
        openCoalesceWork?.cancel()
        openCoalesceWork = nil
        idlePrewarmWork?.cancel()
        idlePrewarmWork = nil
        scrollSettleWork?.cancel()
        scrollSettleWork = nil
        pinnedRemeasureWork?.cancel()
        pinnedRemeasureWork = nil
        jumpAnchorWork?.cancel()
        jumpAnchorWork = nil
        chromeWork?.cancel()
        chromeWork = nil
        contextUsageWork?.cancel()
        contextUsageWork = nil
        contextBarWork?.cancel()
        contextBarWork = nil
        contextBarScrollWork?.cancel()
        contextBarScrollWork = nil
        heightWork?.cancel()
        heightWork = nil
        StableRichRenderer.shared.cancelPendingJobs()
    }

    private func paintVisibleOpenHistoryIfCached(messages: [ChatMessage], layoutWidth: CGFloat) {
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let msg = messages.first(where: { $0.id == cell.messageID }),
                  msg.role == .assistant,
                  !msg.isStreaming,
                  !isTailAssistantMessage(msg.id),
                  !cell.hasVisibleNativePaint,
                  AssistantMessageLayout.hasCachedNativeLayout(for: msg, layoutWidth: layoutWidth) else { continue }
            cell.configureForOpenHistory(
                with: msg,
                preferredHeight: rowHeights.committedColumnHeight(for: msg.id),
                layoutWidth: layoutWidth
            )
        }
    }

    private func openPaintStillValid(generation: UInt, openID: String?) -> Bool {
        generation == openGeneration
            && openID != nil
            && openID == renderedConversationID
            && openID == currentConversationID
    }

    private func enqueueOpenTailWork(generation: UInt,
                                     openID: String?,
                                     delay: TimeInterval = 0,
                                     _ body: @escaping () -> Void) {
        openSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.openPaintStillValid(generation: generation, openID: openID) else { return }
            body()
        }
        openSettleWork = work
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func scheduleDeferredOpenSettle(generation: UInt,
                                            openID: String?,
                                            layoutWidth: CGFloat) {
        openSettleFollowUpWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runDeferredOpenSettle(
                generation: generation,
                openID: openID,
                layoutWidth: layoutWidth
            )
        }
        openSettleFollowUpWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Debounce tail upgrade + settle until rapid A→B→C taps finish — only the last conversation paints.
    private func scheduleCoalescedOpenUpgrade() {
        openCoalesceWork?.cancel()
        let gen = openGeneration
        let openID = renderedConversationID
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.openPaintStillValid(generation: gen, openID: openID) else {
                self?.suppressHeightRemeasure = false
                return
            }
            self.scheduleOpenTailPaint(generation: gen)
        }
        openCoalesceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.switchCoalesceDelay, execute: work)
    }

    /// Scroll tail into view, configure, sync-native paint — returns true when body has pixels.
    @discardableResult
    private func materializeAndPaintOpenTail(messages: [ChatMessage],
                                             layoutWidth: CGFloat,
                                             generation: UInt,
                                             openID: String?) -> Bool {
        guard openPaintStillValid(generation: generation, openID: openID) else { return false }
        guard let tailID = tailAssistantMessageID(in: messages),
              let row = messages.firstIndex(where: { $0.id == tailID }) else { return false }
        let tail = messages[row]
        guard AssistantMessageLayout.hasCachedNativeLayout(for: tail, layoutWidth: layoutWidth) else {
            return false
        }
        let path = IndexPath(row: row, section: 0)
        guard tableView.numberOfRows(inSection: 0) > row else { return false }
        guard openPaintStillValid(generation: generation, openID: openID) else { return false }
        tableView.scrollToRow(at: path, at: .bottom, animated: false)
        guard openPaintStillValid(generation: generation, openID: openID) else { return false }
        tableView.layoutIfNeeded()
        snapTableContentOffsetToBottom()
        let preferred = rowHeights.displayColumnHeight(for: tail.id)
            ?? rowHeights.committedColumnHeight(for: tail.id)
        guard openPaintStillValid(generation: generation, openID: openID),
              let cell = tableView.cellForRow(at: path) as? AssistantMessageCell else { return false }
        cell.configureForOpenBottom(with: tail, preferredHeight: preferred, layoutWidth: layoutWidth)
        return cell.hasSubstantialOpenBodyPaint(for: tail)
    }

    /// Force action buttons into layout and grow UITableView rows so they aren't clipped.
    /// Must run on the open critical path (not deferred to settle).
    private func revealVisibleActionChrome(messages: [ChatMessage]) {
        var changed = false
        let openPath = pendingOpenAtBottom || suppressHeightRemeasure
        tableView.layoutIfNeeded()
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let msg = messages.first(where: { $0.id == cell.messageID }),
                  msg.role == .assistant,
                  !msg.isStreaming else { continue }
            cell.ensureActionButtonsVisible(for: msg)
            let measured = cell.measuredContentHeight()
            guard measured > 40 else { continue }
            let prior = rowHeights.bestKnownColumnHeight(for: msg.id)
            if openPath {
                rowHeights.commitMeasured(columnHeight: measured, messageID: msg.id, allowShrink: true)
            } else {
                let target = max(prior, measured)
                rowHeights.commitMeasured(columnHeight: target, messageID: msg.id, allowShrink: false)
            }
            if abs(prior - measured) > 1 { changed = true }
        }
        guard changed else { return }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
        tableView.layoutIfNeeded()
    }

    private func resolvedRowHeight(for msg: ChatMessage, row: Int, messageCount: Int) -> CGFloat {
        rowHeights.rowHeight(
            for: msg,
            row: row,
            messageCount: messageCount,
            layoutWidth: currentRenderWidth()
        )
    }

    /// Row heights stay frozen for the whole gesture — no plain/native mid-scroll swaps.
    private func scrollAwareRowHeight(for msg: ChatMessage, row: Int, messageCount: Int) -> CGFloat {
        resolvedRowHeight(for: msg, row: row, messageCount: messageCount)
    }

    /// Symmetric rows around the viewport — prewarm native layouts before Q↔A enters view.
    private func scrollLookaheadRows(in messages: [ChatMessage]) -> [Int] {
        let visible = tableView.indexPathsForVisibleRows ?? []
        guard !visible.isEmpty else { return [] }
        var rows = Set(visible.map(\.row))
        let span = Self.turnPrewarmCount * 2 + 2
        if let minRow = visible.map(\.row).min(), let maxRow = visible.map(\.row).max() {
            for delta in 1...span {
                rows.insert(max(0, minRow - delta))
                rows.insert(min(messages.count - 1, maxRow + delta))
            }
        }
        return rows.filter { $0 >= 0 && $0 < messages.count }.sorted()
    }

    /// Prewarm Q↔A native layouts at drag start — short sync, long async (no contentSize snap).
    private func prewarmScrollLookahead(messages: [ChatMessage], layoutWidth: CGFloat) {
        var syncBatch: [ChatMessage] = []
        var asyncBatch: [ChatMessage] = []
        for row in scrollLookaheadRows(in: messages) {
            guard row >= 0, row < messages.count else { continue }
            let candidates: [ChatMessage]
            if messages[row].role == .user, row + 1 < messages.count,
               messages[row + 1].role == .assistant, !messages[row + 1].isStreaming {
                candidates = [messages[row + 1]]
            } else if messages[row].role == .assistant, !messages[row].isStreaming {
                candidates = [messages[row]]
            } else {
                continue
            }
            for msg in candidates {
                if AssistantMessageLayout.hasCachedNativeLayout(for: msg, layoutWidth: layoutWidth) {
                    continue
                }
                if msg.content.count <= Self.syncPrewarmMaxChars, syncBatch.count < 1 {
                    syncBatch.append(msg)
                } else {
                    asyncBatch.append(msg)
                }
            }
        }
        if !syncBatch.isEmpty {
            AssistantMessageLayout.prewarmLayouts(
                for: syncBatch,
                targetWidth: layoutWidth,
                layoutLimit: syncBatch.count
            )
        }
        scheduleAsyncLayoutPrewarm(assistants: asyncBatch, layoutWidth: layoutWidth)
    }

    /// Rows about to enter the viewport — `turnPrewarmCount` turns ahead in scroll direction.
    private func lookaheadAnchorRows(in messages: [ChatMessage]) -> [Int] {
        let visible = tableView.indexPathsForVisibleRows ?? []
        guard !visible.isEmpty else { return [] }
        var anchors = Set(visible.map(\.row))
        let span = Self.turnPrewarmCount * 2
        if scrollBiasUp {
            if let minRow = anchors.min() {
                for delta in 1...span {
                    anchors.insert(max(0, minRow - delta))
                }
            }
        } else if let maxRow = anchors.max() {
            for delta in 1...span {
                anchors.insert(min(messages.count - 1, maxRow + delta))
            }
        }
        return anchors.filter { $0 >= 0 && $0 < messages.count }.sorted()
    }

    private func prewarmForIncomingRow(_ row: Int) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              row >= 0, row < messages.count else { return }
        var anchors = [row]
        let span = Self.turnPrewarmCount * 2
        if scrollBiasUp {
            for delta in 1...span { anchors.append(row - delta) }
        } else {
            for delta in 1...span { anchors.append(row + delta) }
        }
        applyTurnWindowPrewarm(around: anchors.filter { $0 >= 0 && $0 < messages.count })
    }

    private func applyLookaheadTurnPrewarm() {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let anchors = lookaheadAnchorRows(in: messages)
        guard !anchors.isEmpty else { return }
        applyTurnWindowPrewarm(around: anchors)
    }

    /// Upgrade one visible fallback per run-loop turn after a fast scroll.
    /// Hydrating every visible native layout in `scrollViewDidEnd…` made the
    /// first resting frame hitch and left cells visibly blank during reuse.
    private func scheduleVisibleDeferredNativeHydration() {
        deferredRenderWork?.cancel()
        let openID = renderedConversationID
        let generation = openGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  !self.tableView.isDragging,
                  !self.tableView.isDecelerating,
                  openID == self.renderedConversationID,
                  generation == self.openGeneration else { return }
            guard self.hydrateOneVisibleDeferredNativeCell() else { return }
            self.scheduleVisibleDeferredNativeHydration()
        }
        deferredRenderWork = work
        DispatchQueue.main.async(execute: work)
    }

    @discardableResult
    private func hydrateOneVisibleDeferredNativeCell() -> Bool {
        var pending: [(row: Int, cell: AssistantMessageCell)] = []
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard cell.hasPendingDeferredNativeRender,
                  let path = tableView.indexPath(for: cell) else { continue }
            pending.append((path.row, cell))
        }
        guard !pending.isEmpty else { return false }
        pending.sort { scrollBiasUp ? $0.row < $1.row : $0.row > $1.row }
        pending[0].cell.applyDeferredNativeRenderIfNeeded()
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
        return pending.count > 1
    }

    private func remeasureRowsPreservingViewport(anchorPath: IndexPath? = nil) {
        let visible = tableView.indexPathsForVisibleRows ?? []
        let anchor = anchorPath ?? visible.min(by: { $0.row < $1.row })
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

    private func isViewportPinned() -> Bool {
        viewportPinnedByUser || readingHistory
    }

    private func schedulePinnedRemeasure() {
        pinnedRemeasureWork?.cancel()
        let anchorRow = contextUserIndex
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isViewportPinned() else { return }
            let anchorPath: IndexPath?
            if let row = anchorRow, row < self.tableView.numberOfRows(inSection: 0) {
                anchorPath = IndexPath(row: row, section: 0)
            } else {
                anchorPath = nil
            }
            self.remeasureRowsPreservingViewport(anchorPath: anchorPath)
            if let row = anchorRow {
                self.applyUserBubbleScrollAnchor(at: row, animated: false)
            }
        }
        pinnedRemeasureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Stop async open/settle work that would pin the viewport to the bottom.
    private func cancelViewportAutoPin() {
        openCoalesceWork?.cancel()
        openCoalesceWork = nil
        openSettleWork?.cancel()
        openSettleWork = nil
        openSettleFollowUpWork?.cancel()
        openSettleFollowUpWork = nil
        pinnedRemeasureWork?.cancel()
        pinnedRemeasureWork = nil
        jumpAnchorWork?.cancel()
        jumpAnchorWork = nil
    }

    /// Only update sticky/bottom mode when the user finishes a scroll gesture.
    private func updateScrollModeAtRest() {
        guard !(ConversationStore.shared.currentConversation?.messages.isEmpty ?? true) else { return }
        let visibleBottom = tableView.contentOffset.y
            + tableView.bounds.height
            - tableView.adjustedContentInset.bottom
        let nearBottom = visibleBottom >= tableView.contentSize.height - 80
        if nearBottom {
            stickToBottom = true
            readingHistory = false
            viewportPinnedByUser = false
        } else {
            stickToBottom = false
            readingHistory = true
            viewportPinnedByUser = true
        }
    }

    /// Pin viewport to the real table content bottom (uses contentSize, not resolver sum).
    private func snapTableContentOffsetToBottom() {
        guard tableView.window != nil else { return }
        let inset = tableView.adjustedContentInset
        let minY = -inset.top
        guard tableView.bounds.height > 1 else { return }
        tableView.layoutIfNeeded()
        let contentH = tableView.contentSize.height
        guard contentH > 1 else { return }
        let viewportH = tableView.bounds.height
        let maxY = max(minY, contentH + inset.bottom - viewportH)
        if abs(tableView.contentOffset.y - maxY) > 0.5 {
            tableView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
        }
    }

    /// One bottom pin for open/settle — avoids scrollToRow + contentOffset fighting.
    private func pinOpenViewportToBottom(_ messages: [ChatMessage]) {
        guard !messages.isEmpty, tableView.window != nil else { return }
        tableView.layoutIfNeeded()
        snapTableContentOffsetToBottom()
    }

    private func scrollToLastRowReliable(_ messages: [ChatMessage]) {
        guard !messages.isEmpty, tableView.window != nil else { return }
        let last = IndexPath(row: messages.count - 1, section: 0)
        let rows = tableView.numberOfRows(inSection: 0)
        guard last.row < rows else { return }
        // scrollToRow first so UITableView materializes the tail even when estimates are short.
        tableView.scrollToRow(at: last, at: .bottom, animated: false)
        tableView.layoutIfNeeded()
        snapTableContentOffsetToBottom()
    }

    /// Scroll so the last row sits flush above the input chrome.
    private func scrollToLastRowBottom() {
        guard !isViewportPinned() else { return }
        guard let messages = ConversationStore.shared.currentConversation?.messages, !messages.isEmpty else { return }
        snapTableContentOffsetToBottom()
        scheduleUpdateTurnContextBar()
    }

    /// Pin heights from layout cache only (never sync-layout). Safe during open / scroll.
    @discardableResult
    private func commitCachedLayoutHeights(messages: [ChatMessage],
                                           layoutWidth: CGFloat,
                                           rows: [Int],
                                           syncLayoutBudget: Int = 0) -> Bool {
        let count = messages.count
        var budget = syncLayoutBudget
        var changed = false
        for row in rows {
            guard row >= 0, row < count else { continue }
            let msg = messages[row]
            guard !msg.isStreaming, !rowHeights.isCommitted(msg.id) else { continue }
            if msg.role == .user,
               let column = ChatRowHeightResolver.estimatedUserColumnContentHeight(
                   for: msg,
                   layoutWidth: layoutWidth
               ), column > 40 {
                rowHeights.commitMeasured(columnHeight: column, messageID: msg.id, allowShrink: true)
                changed = true
                continue
            }
            guard msg.role == .assistant else { continue }
            if AssistantMessageLayout.hasCachedNativeLayout(for: msg, layoutWidth: layoutWidth),
               let column = AssistantMessageLayout.estimatedColumnContentHeight(
                   for: msg,
                   layoutWidth: layoutWidth,
                   isLastRow: row == count - 1,
                   allowSyncLayout: false
               ), column > 40 {
                rowHeights.commitMeasured(columnHeight: column, messageID: msg.id, allowShrink: true)
                changed = true
                continue
            }
            guard budget > 0 else { continue }
            if let column = AssistantMessageLayout.estimatedColumnContentHeight(
                for: msg,
                layoutWidth: layoutWidth,
                isLastRow: row == count - 1,
                allowSyncLayout: true
            ), column > 40 {
                rowHeights.commitMeasured(columnHeight: column, messageID: msg.id, allowShrink: true)
                changed = true
                budget -= 1
            }
        }
        return changed
    }

    /// After first paint: light visible pin + async history warm. Cancellable — must not block switching.
    private func settleOpenConversation(messages: [ChatMessage], layoutWidth: CGFloat) {
        guard !messages.isEmpty,
              !tableView.isDragging,
              !tableView.isDecelerating else { return }
        let visible = tableView.indexPathsForVisibleRows ?? []
        var heightChanged = false
        for path in visible where path.row < messages.count {
            let msg = messages[path.row]
            guard !msg.isStreaming,
                  let cell = tableView.cellForRow(at: path) as? MessageCellType else { continue }
            if let assistant = cell as? AssistantMessageCell {
                assistant.ensureActionButtonsVisible(for: msg)
            }
            let measured = cell.measuredContentHeight()
            guard measured > 40 else { continue }
            let prior = rowHeights.bestKnownColumnHeight(for: msg.id)
            rowHeights.commitMeasured(columnHeight: measured, messageID: msg.id, allowShrink: true)
            if abs(prior - measured) > 3 { heightChanged = true }
        }
        if heightChanged {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
        }
        if stickToBottom {
            pinOpenViewportToBottom(messages)
        }
        if let cid = renderedConversationID {
            storePersistedHeights(rowHeights.exportPersistable(), for: cid)
        }
    }

    private func scheduleOpenTailPaint(generation: UInt) {
        guard let openID = renderedConversationID,
              let messages = openMessages(for: openID),
              !messages.isEmpty else {
            pendingOpenAtBottom = false
            suppressHeightRemeasure = false
            return
        }
        let layoutWidth = currentRenderWidth()
        let tailMessage: ChatMessage? = {
            guard let tailID = tailAssistantMessageID(in: messages) else { return nil }
            return messages.first(where: { $0.id == tailID })
        }()

        let enqueuePaint: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.enqueueOpenTailWork(generation: generation, openID: openID) { [weak self] in
                self?.runOpenTailPaint(generation: generation, openID: openID)
            }
        }

        if let tail = tailMessage,
           !AssistantMessageLayout.hasCachedNativeLayout(for: tail, layoutWidth: layoutWidth) {
            AssistantMessageLayout.prewarmLayoutsOnBackground(
                for: [tail],
                targetWidth: layoutWidth,
                layoutLimit: 1,
                completion: { [weak self] in
                    guard let self = self,
                          self.openPaintStillValid(generation: generation, openID: openID) else { return }
                    enqueuePaint()
                }
            )
        } else {
            enqueuePaint()
        }
    }

    private func finishOpenTailSettle(generation: UInt,
                                      openID: String?,
                                      layoutWidth: CGFloat) {
        guard openPaintStillValid(generation: generation, openID: openID) else { return }
        pendingOpenAtBottom = false
        scheduleDeferredOpenSettle(generation: generation, openID: openID, layoutWidth: layoutWidth)
    }

    /// Heavy open settle — debounced and cancellable so rapid A→B→C never blocks B on A's work.
    private func runDeferredOpenSettle(generation: UInt,
                                       openID: String?,
                                       layoutWidth: CGFloat) {
        guard openPaintStillValid(generation: generation, openID: openID),
              let messages = openMessages(for: openID) else {
            suppressHeightRemeasure = false
            return
        }
        let liveWidth = layoutWidth
        let exactDisk = openID.map { exactPersistedHeights(for: $0) } ?? [:]
        if messages.count >= 2, exactDisk.isEmpty {
            let totalH = rowHeights.totalRowHeight(for: messages, layoutWidth: liveWidth)
            let minPlausible = max(tableView.bounds.height * 0.55, CGFloat(min(messages.count, 8)) * 72)
            if totalH < minPlausible {
                for msg in messages.suffix(8) where !msg.isStreaming {
                    if rowHeights.isCommitted(msg.id) { continue }
                    let cheap = ChatRowHeightResolver.cheapColumnEstimate(
                        for: msg,
                        layoutWidth: liveWidth
                    )
                    let floor = max(cheap * 1.15, msg.role == .assistant ? 96 : 52)
                    rowHeights.updateDisplayEstimate(columnHeight: floor, messageID: msg.id)
                }
                guard openPaintStillValid(generation: generation, openID: openID) else { return }
                UIView.performWithoutAnimation {
                    tableView.beginUpdates()
                    tableView.endUpdates()
                }
                if let live = openMessages(for: openID), !isViewportPinned() {
                    pinOpenViewportToBottom(live)
                }
            }
        }
        guard openPaintStillValid(generation: generation, openID: openID),
              let settledMessages = openMessages(for: openID) else {
            suppressHeightRemeasure = false
            return
        }
        paintVisibleOpenHistoryIfCached(messages: settledMessages, layoutWidth: layoutWidth)
        guard openPaintStillValid(generation: generation, openID: openID) else { return }
        hydrateDeferredNativeRenders(priorityBottomCount: 4)
        guard openPaintStillValid(generation: generation, openID: openID) else { return }
        revealVisibleActionChrome(messages: settledMessages)
        guard openPaintStillValid(generation: generation, openID: openID) else { return }
        reconcileVisibleRowHeights(preserveBottom: !isViewportPinned())
        guard openPaintStillValid(generation: generation, openID: openID) else { return }
        if !isViewportPinned() {
            pinOpenViewportToBottom(settledMessages)
        }
        settleOpenConversation(messages: settledMessages, layoutWidth: layoutWidth)
        suppressHeightRemeasure = false

        let tail = Array(settledMessages.suffix(Self.switchPrewarmMessageWindow))
        let assistants = tail.filter { $0.role == .assistant && !$0.isStreaming }
        if !assistants.isEmpty {
            scheduleAsyncLayoutPrewarm(assistants: assistants, layoutWidth: layoutWidth)
        }
        scheduleIdleConversationPrewarm()
    }

    private func runOpenTailPaint(generation: UInt, openID: String?) {
        guard openPaintStillValid(generation: generation, openID: openID),
              let liveMessages = openMessages(for: openID) else { return }
        let liveWidth = currentRenderWidth()

        continueOpenTailPaint(
            generation: generation,
            openID: openID,
            messages: liveMessages,
            layoutWidth: liveWidth
        )
    }

    private func continueOpenTailPaint(generation: UInt,
                                       openID: String?,
                                       messages: [ChatMessage],
                                       layoutWidth: CGFloat) {
        guard openPaintStillValid(generation: generation, openID: openID),
              let liveMessages = openMessages(for: openID) else { return }

        if let tailID = tailAssistantMessageID(in: liveMessages),
           let tail = liveMessages.first(where: { $0.id == tailID }),
           let row = liveMessages.firstIndex(where: { $0.id == tailID }),
           row < tableView.numberOfRows(inSection: 0),
           let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? AssistantMessageCell,
           cell.hasSubstantialOpenBodyPaint(for: tail) {
            finishOpenTailSettle(
                generation: generation,
                openID: openID,
                layoutWidth: layoutWidth
            )
            return
        }

        if materializeAndPaintOpenTail(
            messages: liveMessages,
            layoutWidth: layoutWidth,
            generation: generation,
            openID: openID
        ) {
            finishOpenTailSettle(
                generation: generation,
                openID: openID,
                layoutWidth: layoutWidth
            )
            return
        }
        guard let tailID = tailAssistantMessageID(in: liveMessages),
              let tail = liveMessages.first(where: { $0.id == tailID }),
              openPaintStillValid(generation: generation, openID: openID) else {
            pendingOpenAtBottom = false
            suppressHeightRemeasure = false
            return
        }
        AssistantMessageLayout.prewarmLayoutsOnBackground(
            for: [tail],
            targetWidth: layoutWidth,
            layoutLimit: 1,
            completion: { [weak self] in
                guard let self = self else { return }
                self.enqueueOpenTailWork(generation: generation, openID: openID) { [weak self] in
                    guard let self = self,
                          self.openPaintStillValid(generation: generation, openID: openID),
                          let finalMessages = self.openMessages(for: openID) else { return }
                    _ = self.materializeAndPaintOpenTail(
                        messages: finalMessages,
                        layoutWidth: layoutWidth,
                        generation: generation,
                        openID: openID
                    )
                    self.finishOpenTailSettle(
                        generation: generation,
                        openID: openID,
                        layoutWidth: layoutWidth
                    )
                }
            }
        )
    }

    private func forceSnapOpenToBottom(_ messages: [ChatMessage]) {
        stickToBottom = true
        readingHistory = false
        viewportPinnedByUser = false
        guard !messages.isEmpty, tableView.bounds.height > 1 else { return }
        tableView.layoutIfNeeded()
        scrollToLastRowReliable(messages)
        // Second pass: first scrollToRow can expand contentSize as the tail lays out.
        tableView.layoutIfNeeded()
        snapTableContentOffsetToBottom()
    }

    private func seedDisplayFromLayoutCache(for message: ChatMessage,
                                            row: Int,
                                            messageCount: Int,
                                            layoutWidth: CGFloat) {
        if message.role == .user,
           let column = ChatRowHeightResolver.estimatedUserColumnContentHeight(
               for: message,
               layoutWidth: layoutWidth
           ), column > 40 {
            rowHeights.updateDisplayEstimate(columnHeight: column, messageID: message.id)
            return
        }
        guard message.role == .assistant, !message.isStreaming else { return }
        if let column = AssistantMessageLayout.estimatedColumnContentHeight(
            for: message,
            layoutWidth: layoutWidth,
            isLastRow: row == messageCount - 1,
            allowSyncLayout: false
        ), column > 40 {
            rowHeights.updateDisplayEstimate(columnHeight: column, messageID: message.id)
        }
    }

    /// Match UITableView row heights to measured column heights (grow or shrink).
    private func reconcileVisibleRowHeights(preserveBottom: Bool) {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let paths = tableView.indexPathsForVisibleRows ?? []
        guard !paths.isEmpty else { return }
        var changed = false
        for path in paths {
            guard path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard !msg.isStreaming else { continue }
            guard let cell = tableView.cellForRow(at: path) as? MessageCellType else { continue }
            let measured = cell.measuredContentHeight()
            guard measured > 40 else { continue }
            let prior = rowHeights.bestKnownColumnHeight(for: msg.id)
            guard abs(prior - measured) > 3 else { continue }
            rowHeights.commitMeasured(columnHeight: measured, messageID: msg.id, allowShrink: true)
            changed = true
        }
        guard changed else { return }
        if let cid = renderedConversationID {
            storePersistedHeights(rowHeights.exportPersistable(), for: cid)
            scheduleHeightCacheSave()
        }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            if preserveBottom, stickToBottom, !isViewportPinned() {
                scrollToLastRowReliable(messages)
            } else if isViewportPinned() {
                schedulePinnedRemeasure()
            }
        }
    }

    /// Pin the table to the real content bottom so action buttons on the last reply stay visible.
    private func snapToTrueBottom(animated: Bool = false) {
        let apply = { self.scrollToLastRowBottom() }
        if animated {
            UIView.animate(withDuration: 0.2, animations: apply)
        } else {
            UIView.performWithoutAnimation(apply)
        }
    }

    private func settleOpenAtBottom() {
        guard stickToBottom, !isViewportPinned() else { return }
        snapToTrueBottom(animated: false)
    }

    private func hydrateDeferredNativeRenders(priorityBottomCount: Int? = nil) {
        var pending: [(row: Int, cell: AssistantMessageCell)] = []
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard cell.hasPendingDeferredNativeRender,
                  let path = tableView.indexPath(for: cell) else { continue }
            pending.append((path.row, cell))
        }
        guard !pending.isEmpty else { return }

        pending.sort { $0.row > $1.row }
        if let limit = priorityBottomCount, limit > 0, pending.count > limit {
            pending = Array(pending.prefix(limit))
        }

        for item in pending {
            item.cell.applyDeferredNativeRenderIfNeeded()
        }
        if isViewportPinned() {
            schedulePinnedRemeasure()
        } else {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
        }
    }

    private func scrollToBottomFast() {
        scrollToLastRowBottom()
    }

    private func persistenceMessageOrder() -> [String: [String]] {
        var order: [String: [String]] = [:]
        if let id = currentConversationID,
           let conv = ConversationStore.shared.currentConversation {
            order[heightCacheStorageKey(for: id)] = conv.messages.map { $0.id }
        }
        for key in heightCacheByConversation.keys {
            guard order[key] == nil else { continue }
            let cid = key.split(separator: "|").first.map(String.init) ?? key
            guard let conv = ConversationStore.shared.conversation(id: cid) else { continue }
            order[key] = conv.messages.map { $0.id }
        }
        return order
    }

    private func saveHeightCaches() {
        RenderCacheStore.saveHeights(
            heightCacheByConversation,
            messageOrder: persistenceMessageOrder()
        )
    }

    private func scheduleHeightCacheSave() {
        heightCacheSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveHeightCaches()
        }
        heightCacheSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func invalidateExpandedChromeHeights() {
        for messageID in AssistantMessageLayout.expandedChromeMessageIDs() {
            rowHeights.invalidate(messageID: messageID)
        }
    }

    private func finishConversationSwitchChrome(layoutWidth: CGFloat) {
        guard let selfID = renderedConversationID,
              selfID == currentConversationID else {
            return
        }
        let gen = openGeneration
        updateEmptyState()
        syncStreamingChrome()
        // Defer chrome that walks the whole transcript (context %) off the open frame.
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  gen == self.openGeneration,
                  selfID == self.currentConversationID,
                  let messages = ConversationStore.shared.currentConversation?.messages else { return }
            self.updateModelButton()
            self.updateAgentButton()
            self.updateAttachAvailability()
            self.updateTitleFromConversation()
            self.refreshSwitchChromeImmediate()
            if self.stickToBottom, !messages.isEmpty {
                self.pinOpenViewportToBottom(messages)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self,
                      gen == self.openGeneration,
                      selfID == self.currentConversationID,
                      let liveMessages = ConversationStore.shared.currentConversation?.messages else { return }
                guard !self.tableView.isDragging, !self.tableView.isDecelerating else { return }
                self.scheduleTailLayoutPrewarm(
                    messages: liveMessages,
                    layoutWidth: layoutWidth,
                    conversationID: selfID
                )
            }
        }
    }

    private func scheduleTailLayoutPrewarm(messages: [ChatMessage],
                                           layoutWidth: CGFloat,
                                           conversationID: String) {
        guard conversationID == renderedConversationID,
              conversationID == currentConversationID else { return }
        let tail = Array(messages.suffix(Self.switchPrewarmMessageWindow))
        let assistants = tail.filter { $0.role == .assistant && !$0.isStreaming }
        guard !assistants.isEmpty else { return }
        // Do not cancel in-flight history warm from settleOpen — merge into the async pump.
        scheduleAsyncLayoutPrewarm(assistants: assistants, layoutWidth: layoutWidth)
    }

    private func scheduleUpdateTurnContextBar() {
        if tableView.isDragging || tableView.isDecelerating {
            contextBarScrollWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.updateTurnContextBar()
            }
            contextBarScrollWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
            return
        }
        contextBarWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateTurnContextBar()
        }
        contextBarWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func refreshSwitchChromeImmediate() {
        refreshContextUsage(animated: false)
        updateTurnContextBar(preferBottom: true)
    }

    private func updateTurnContextBar(preferBottom: Bool = false) {
        guard SettingsManager.shared.turnContextBarEnabled else {
            contextUserIndex = nil
            turnContextBar.update(question: nil, visible: false)
            return
        }

        guard let messages = ConversationStore.shared.currentConversation?.messages,
              !messages.isEmpty else {
            contextUserIndex = nil
            turnContextBar.update(question: nil, visible: false)
            return
        }

        let resolvedUserIndex: Int?
        if preferBottom || (stickToBottom && !isViewportPinned()) {
            resolvedUserIndex = messages.lastIndex(where: { $0.role == .user })
        } else {
            let viewportTop = tableView.contentOffset.y + tableView.adjustedContentInset.top + 2
            let visible = (tableView.indexPathsForVisibleRows ?? []).sorted { $0.row < $1.row }
            var anchorIndex = visible.first?.row ?? (messages.count - 1)
            for path in visible {
                let rect = tableView.rectForRow(at: path)
                if rect.maxY > viewportTop {
                    anchorIndex = path.row
                    break
                }
            }
            resolvedUserIndex = userIndex(forMessageAt: anchorIndex, in: messages)
        }

        guard let resolvedUserIndex = resolvedUserIndex else {
            contextUserIndex = nil
            turnContextBar.update(question: nil, visible: false)
            return
        }

        contextUserIndex = resolvedUserIndex
        turnContextBar.update(
            question: userQuestionPreview(messages[resolvedUserIndex]),
            visible: true
        )
    }

    private func userIndex(forMessageAt index: Int, in messages: [ChatMessage]) -> Int? {
        guard index >= 0, index < messages.count else { return nil }
        if messages[index].role == .user { return index }
        for i in stride(from: index, through: 0, by: -1) where messages[i].role == .user {
            return i
        }
        return nil
    }

    private func userQuestionPreview(_ message: ChatMessage) -> String {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != "[图片]" {
            let singleLine = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            return String(singleLine.prefix(240))
        }
        if message.hasImage { return "📷 图片" }
        return "（空消息）"
    }

    private func jumpToUserQuestion(at index: Int) {
        guard index >= 0,
              index < tableView.numberOfRows(inSection: 0),
              let messages = ConversationStore.shared.currentConversation?.messages,
              index < messages.count else { return }

        cancelViewportAutoPin()
        contextUserIndex = index
        readingHistory = true
        stickToBottom = false
        viewportPinnedByUser = true

        let layoutWidth = currentRenderWidth()
        rowHeights.rebuildDisplayHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            throughRow: index
        )
        let prefixRows = Array(0...index)
        _ = commitCachedLayoutHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: prefixRows,
            syncLayoutBudget: min(16, prefixRows.count)
        )

        let path = IndexPath(row: index, section: 0)
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()

            let gap = tableView.adjustedContentInset.top + 6
            let minY = -tableView.adjustedContentInset.top
            let maxY = max(
                minY,
                tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
            )
            let coarse = contentOffsetForRowTop(index) - gap
            tableView.contentOffset.y = min(max(coarse, minY), maxY)
            tableView.layoutIfNeeded()

            tableView.scrollToRow(at: path, at: .top, animated: false)
            tableView.layoutIfNeeded()
            applyUserBubbleScrollAnchor(at: index, animated: false)
            remeasureRowsPreservingViewport(anchorPath: path)
        }
        scheduleRefinedJumpAnchor(at: index)
    }

    private func scheduleRefinedJumpAnchor(at index: Int) {
        jumpAnchorWork?.cancel()
        let path = IndexPath(row: index, section: 0)

        func refine() {
            guard contextUserIndex == index,
                  index < tableView.numberOfRows(inSection: 0) else { return }
            UIView.performWithoutAnimation {
                tableView.layoutIfNeeded()
                applyUserBubbleScrollAnchor(at: index, animated: false)
                remeasureRowsPreservingViewport(anchorPath: path)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            refine()
            self.scheduleUpdateTurnContextBar()
        }

        let work = DispatchWorkItem { [weak self] in
            self?.refineJumpAnchorIfNeeded(at: index, path: path)
        }
        jumpAnchorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func refineJumpAnchorIfNeeded(at index: Int, path: IndexPath) {
        guard contextUserIndex == index,
              index < tableView.numberOfRows(inSection: 0) else { return }
        UIView.performWithoutAnimation {
            tableView.layoutIfNeeded()
            applyUserBubbleScrollAnchor(at: index, animated: false)
            remeasureRowsPreservingViewport(anchorPath: path)
        }
    }

    /// Scroll so the user input bubble sits just under the context bar.
    private func applyUserBubbleScrollAnchor(at row: Int, animated: Bool) {
        guard row >= 0, row < tableView.numberOfRows(inSection: 0) else { return }
        tableView.layoutIfNeeded()
        let path = IndexPath(row: row, section: 0)
        let gap = tableView.adjustedContentInset.top + 6
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(
            minY,
            tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
        )

        var targetY: CGFloat
        if let cell = tableView.cellForRow(at: path) as? UserMessageCell,
           let bubbleY = cell.userBubbleTop(in: tableView) {
            targetY = bubbleY - gap
        } else {
            let rowRect = tableView.rectForRow(at: path)
            if rowRect.height > 0.5 {
                targetY = rowRect.minY - gap
            } else {
                targetY = contentOffsetForRowTop(row) - gap
            }
        }
        targetY = min(max(targetY, minY), maxY)

        if animated {
            tableView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
        } else {
            tableView.contentOffset.y = targetY
        }
    }

    /// Sum cached/estimated row heights — reliable for far jumps before the cell exists.
    private func contentOffsetForRowTop(_ row: Int) -> CGFloat {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              row > 0 else { return 0 }
        var offset: CGFloat = 0
        let end = min(row, messages.count)
        for i in 0..<end {
            offset += resolvedRowHeight(for: messages[i], row: i, messageCount: messages.count)
        }
        return offset
    }

    private func presentTurnContextPicker() {
        guard SettingsManager.shared.turnContextBarEnabled,
              let messages = ConversationStore.shared.currentConversation?.messages else { return }

        struct UserTurn {
            let index: Int
            let number: Int
            let preview: String
        }

        var turns: [UserTurn] = []
        var turnNumber = 0
        for (index, message) in messages.enumerated() where message.role == .user {
            turnNumber += 1
            turns.append(UserTurn(
                index: index,
                number: turnNumber,
                preview: userQuestionPreview(message)
            ))
        }
        guard !turns.isEmpty else { return }

        let menuItems = turns.reversed().map { turn in
            let title = "\(turn.number). \(turnMenuTitle(turn.preview))"
            return ConnectsMenuItem(
                title: title,
                isSelected: turn.index == contextUserIndex,
                handler: { [weak self] in
                    self?.jumpToUserQuestion(at: turn.index)
                }
            )
        }

        let menuWidth = min(340, max(260, view.bounds.width - DSTheme.contentHorizontalPadding * 2))
        ConnectsMenu.present(
            from: self,
            title: "跳转到问题",
            items: menuItems,
            sourceView: turnContextBar,
            preferVertical: true,
            maxHeight: view.bounds.height * 0.55,
            menuWidth: menuWidth
        )
    }

    private func turnMenuTitle(_ preview: String) -> String {
        String(preview.prefix(64))
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
            if stickToBottom && !isViewportPinned() {
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
        turnContextBar.applyTheme()
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
        if let source = note.userInfo?["source"] as? String, source == "select" {
            let targetID = ConversationStore.shared.currentConversationID
            if let id = targetID {
                switchToConversation(id: id)
            }
            updateTitleFromConversation()
            updateModelButton()
            updateAgentButton()
            updateStudyInputBar()
            updateEmptyState()
            syncStreamingChrome()
            finishConversationSwitchChrome(layoutWidth: currentRenderWidth())
            return
        }
        if isReloadingFromStore {
            needsDeferredStoreReload = true
            return
        }
        if let source = note.userInfo?["source"] as? String, source == "projectFilter" {
            return
        }
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
            rowHeights.invalidate(messageID: mid)
            pendingHeights.removeValue(forKey: mid)
            if let cid = renderedConversationID {
                storePersistedHeights(rowHeights.exportPersistable(), for: cid)
            }
            let path = IndexPath(row: row, section: 0)
            let message = messages[row]
            let layoutWidth = currentRenderWidth()
            let isSearch = note.name == Notification.Name("ConnectsSearchToggle")
            UIView.performWithoutAnimation {
                if let cell = tableView.cellForRow(at: path) as? AssistantMessageCell {
                    cell.finishChromeToggleLayout()
                } else {
                    if isSearch {
                        (tableView.cellForRow(at: path) as? AssistantMessageCell)?.syncSearchPresentation(with: message, layoutWidth: layoutWidth)
                    }
                    tableView.reloadRows(at: [path], with: .none)
                }
                remeasureRowsPreservingViewport(anchorPath: path)
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
        rowHeights.clearAll()
        pendingHeights.removeAll()
        if let cid = renderedConversationID {
            storePersistedHeights([:], for: cid)
        }
        reloadTablePreservingViewport()
        prewarmVisibleRichReplies(for: currentRenderWidth())
    }

    @objc private func renderDebugChanged() {
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            cell.refreshRenderDebugOverlay()
        }
    }

    @objc private func turnContextBarChanged() {
        scheduleUpdateTurnContextBar()
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
        rowHeights.clearAll()
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
        rowHeights.invalidate(messageID: last.id)
        pendingHeights.removeValue(forKey: last.id)
        if let visibleCell = tableView.cellForRow(at: path) as? AssistantMessageCell,
           visibleCell.messageID == last.id {
            if let measured = visibleCell.transitionToFinishedPlainRendering(
                last,
                preferredHeight: rowHeights.committedColumnHeight(for: last.id)
            ) {
                rowHeights.commit(columnHeight: measured, messageID: last.id)
            }
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
                if stickToBottom && !isViewportPinned() {
                    scrollToBottom(animated: false)
                }
            }
        } else if path.row < tableView.numberOfRows(inSection: 0) {
            UIView.performWithoutAnimation {
                tableView.reloadRows(at: [path], with: .none)
                tableView.layoutIfNeeded()
                if stickToBottom && !isViewportPinned() {
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
            var cell = tableView.cellForRow(at: path) as? AssistantMessageCell
            if cell == nil, !readingHistory {
                tableView.layoutIfNeeded()
                cell = tableView.cellForRow(at: path) as? AssistantMessageCell
            }
            if let cell = cell {
                if !cell.updateStreamingContent(last, waitingGlyph: waitingGlyph) {
                    cell.configure(with: last, preferredHeight: rowHeights.committedColumnHeight(for: last.id), layoutWidth: currentRenderWidth())
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
                if stickToBottom && !isViewportPinned() {
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

    func setStudyChrome(_ mode: StudyChromeMode) {
        guard studyChromeMode != mode else {
            refreshStudyComposerLayout()
            return
        }
        studyChromeMode = mode
        applyStudyChrome()
    }

    func refreshStudyComposerLayout() {
        guard isViewLoaded else { return }
        let preserveKeyboardLift = keyboardVisible
        refreshComposerBottomAnchorIfNeeded()
        if !preserveKeyboardLift {
            bottomConstraint?.constant = restingComposerBottomConstant()
        }
    }

    func dismissComposerKeyboard() {
        guard isViewLoaded else { return }
        view.endEditing(true)
        keyboardVisible = false
        bottomConstraint?.constant = restingComposerBottomConstant()
    }

    /// Shell-owned spacers handle top clearance; reset any prior compensation.
    func normalizePortraitPanelSafeArea() {
        guard isViewLoaded else { return }
        if studyChromeMode != .portraitPanel, additionalSafeAreaInsets != .zero {
            additionalSafeAreaInsets = .zero
        }
    }

    private func isStudySessionActive() -> Bool {
        if studyChromeMode != .none { return true }
        return ConversationStore.shared.currentConversation?.studyDocumentID != nil
    }

    private func applyStudyChrome() {
        navigationItem.leftBarButtonItem = isStudySessionActive() ? nil : sidebarToggleItem
        if isViewLoaded, turnContextBarTopToSafe != nil, turnContextBarTopToView != nil {
            let portraitPanel = studyChromeMode == .portraitPanel
            turnContextBarTopToSafe.isActive = !portraitPanel
            turnContextBarTopToView.isActive = portraitPanel
        }
        if isViewLoaded {
            refreshComposerBottomAnchorIfNeeded()
            normalizePortraitPanelSafeArea()
        }
        updateEmptyState()
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
        // Root evaluates compact mode while preloading child controllers.
        // Forcing the table to lay out before it joins a window causes an
        // extra inaccurate pass (and a UIKit warning on recent iOS).
        if view.window != nil {
            view.layoutIfNeeded()
        }
    }

    /// Instant conversation swap — disk heights only; tail paint runs async afterward.
    func switchToConversation(id: String, coldLaunch: Bool = false) {
        guard id != renderedConversationID else { return }
        guard ConversationStore.shared.currentConversationID == id else { return }
        cancelOpenPipeline()
        guard let conv = ConversationStore.shared.conversation(id: id) else { return }

        if let oldID = renderedConversationID {
            storePersistedHeights(rowHeights.exportPersistable(), for: oldID)
            heightCacheSaveWork?.cancel()
            DispatchQueue.main.async { [weak self] in
                self?.saveHeightCaches()
            }
        }

        let messages = conv.messages
        let layoutWidth = currentRenderWidth()
        ensureHeightCacheLoaded(for: id)
        rowHeights.resetForConversation(
            diskCache: persistedHeights(for: id),
            messages: messages,
            layoutWidth: layoutWidth,
            layoutProbeTailRows: coldLaunch ? Self.coldLaunchLayoutProbeRows : nil
        )
        pendingHeights.removeAll()
        renderedConversationID = id
        stickToBottom = true
        readingHistory = false
        viewportPinnedByUser = false
        suppressHeightRemeasure = true

        streamUIWork?.cancel()
        streamUIWork = nil
        stopStreamUITimer()
        clearNavigationPrompt()

        tableView.alpha = 1
        tableView.isHidden = messages.isEmpty
        tableView.reloadData()
        if coldLaunch {
            notifyInitialLaunchIfNeeded()
            if !messages.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self,
                          id == self.renderedConversationID else { return }
                    self.pinOpenViewportToBottom(messages)
                }
            }
        } else if !messages.isEmpty {
            pinOpenViewportToBottom(messages)
        }
        scheduleCoalescedOpenUpgrade()
    }

    private func openMessages(for openID: String?) -> [ChatMessage]? {
        guard let openID = openID,
              openID == renderedConversationID,
              openID == currentConversationID else { return nil }
        return ConversationStore.shared.conversation(id: openID)?.messages
    }

    func applyConversationSwitchHint() {
        updateTitleFromConversation()
        updateModelButton()
        updateAgentButton()
        updateAttachAvailability()
        updateStudyInputBar()
        updateEmptyState()
        refreshSwitchChromeImmediate()
    }

    private func updateStudyInputBar() {
        guard let conv = ConversationStore.shared.currentConversation else {
            inputBar.studyCaptureVisible = false
            inputBar.studyPageCaptureEnabled = false
            return
        }
        inputBar.studyCaptureVisible = conv.studyDocumentID != nil
        inputBar.studyPageCaptureEnabled = conv.studyPageCaptureEnabled
        applyStudyChrome()
    }

    func reloadChat() {
        isReloadingFromStore = true
        let newID = ConversationStore.shared.currentConversationID
        let conversationChanged = newID != renderedConversationID
        let coldLaunch = conversationChanged && !didNotifyInitialLaunch
        isPerformingColdLaunchOpen = coldLaunch
        chromeWork?.cancel()
        prewarmWork?.cancel()
        contextUsageWork?.cancel()

        // Persist heights for the conversation we are leaving (debounced, off hot path).
        if let old = renderedConversationID, !conversationChanged {
            storePersistedHeights(rowHeights.exportPersistable(), for: old)
            DispatchQueue.main.async { [weak self] in
                self?.saveHeightCaches()
            }
        }
        let layoutWidth = currentRenderWidth()
        if !conversationChanged {
            invalidateExpandedChromeHeights()
        }

        if conversationChanged {
            if let id = newID {
                switchToConversation(id: id, coldLaunch: coldLaunch)
            }
            guard newID == ConversationStore.shared.currentConversationID else {
                isReloadingFromStore = false
                isPerformingColdLaunchOpen = false
                reloadChat()
                return
            }
            finishConversationSwitchChrome(layoutWidth: layoutWidth)
        } else {
            reloadTablePreservingViewport()
        }
        // Empty/list visibility must be sync: deferred chrome left the previous
        // streaming cell composited under a clear empty overlay.
        updateEmptyState()
        syncStreamingChrome()
        if coldLaunch {
            notifyInitialLaunchIfNeeded()
        }
        DispatchQueue.main.async { [weak self] in
            self?.queueLegacyImageTranscriptionIfNeeded()
        }
        if !conversationChanged {
            let switchID = newID
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard switchID == self.currentConversationID else { return }
                self.updateModelButton()
                self.updateAgentButton()
                self.updateEmptyState()
                self.updateAttachAvailability()
                self.updateTitleFromConversation()
                self.syncStreamingChrome()
                self.refreshContextUsage(animated: false)
                self.suppressHeightRemeasure = false
                self.hydrateDeferredNativeRenders()
                UIView.performWithoutAnimation {
                    self.tableView.beginUpdates()
                    self.tableView.endUpdates()
                }
            }
            chromeWork = work
            DispatchQueue.main.async(execute: work)
        }
        isReloadingFromStore = false
        if needsDeferredStoreReload {
            needsDeferredStoreReload = false
            reloadChat()
            return
        }
        if !conversationChanged {
            scheduleUpdateTurnContextBar()
        }
        if !coldLaunch {
            notifyInitialLaunchIfNeeded()
        }
        isPerformingColdLaunchOpen = false
    }

    private func notifyInitialLaunchIfNeeded() {
        guard !didNotifyInitialLaunch, view.window != nil else { return }
        didNotifyInitialLaunch = true
        delegate?.chatDidFinishInitialLaunch()
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
        var items: [ConnectsMenuItem] = []
        if let docID = conv.studyDocumentID,
           let doc = StudyDocumentStore.shared.document(id: docID) {
            items.append(ConnectsMenuItem(title: "文档：\(doc.title)", icon: .book) {})
            items.append(ConnectsMenuItem(title: "更换文档", icon: .folder) { [weak self] in
                self?.presentStudyDocumentPicker()
            })
            items.append(ConnectsMenuItem(title: "取消依附", icon: .trash, isDestructive: true) { [weak self] in
                self?.detachStudyDocument()
            })
        } else {
            items.append(ConnectsMenuItem(title: "依附于文档", icon: .book) { [weak self] in
                self?.presentStudyDocumentPicker()
            })
        }
        items.append(contentsOf: [
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
        ])
        ConnectsMenu.present(
            from: self,
            title: conv.title,
            items: items,
            barButtonItem: navigationItem.rightBarButtonItem
        )
    }

    private func presentStudyDocumentPicker() {
        let picker = StudyDocumentPickerViewController()
        picker.delegate = self
        navigationController?.pushViewController(picker, animated: true)
    }

    private func detachStudyDocument() {
        guard let id = currentConversationID else { return }
        ConversationStore.shared.updateConversation(id: id) { draft in
            draft.studyDocumentID = nil
            draft.studyPageCaptureEnabled = false
        }
        updateStudyInputBar()
    }

    func studyDocumentPicker(_ picker: StudyDocumentPickerViewController, didSelect documentID: String) {
        guard let id = currentConversationID else { return }
        ConversationStore.shared.updateConversation(id: id) { draft in
            draft.studyDocumentID = documentID
        }
        updateStudyInputBar()
        if navigationController?.topViewController === picker {
            navigationController?.popViewController(animated: true)
        }
    }

    func studyDocumentPickerDidRequestImport(_ picker: StudyDocumentPickerViewController) {
        picker.presentImportPicker(from: self)
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
        navigationItem.rightBarButtonItem = moreItem
        applyStudyChrome()
        if let collapsed = pendingSidebarCollapsed {
            updateSidebarToggleTitle(collapsed: collapsed)
        }

        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.isUserInteractionEnabled = true
        updateModelButton()
        updateAgentButton()
    }

    private func setupTurnContextBar() {
        turnContextBar.translatesAutoresizingMaskIntoConstraints = false
        turnContextBar.onTap = { [weak self] in
            self?.presentTurnContextPicker()
        }
        view.addSubview(turnContextBar)
        turnContextBarTopToSafe = turnContextBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        turnContextBarTopToView = turnContextBar.topAnchor.constraint(equalTo: view.topAnchor)
        turnContextBarTopToView.isActive = false
        NSLayoutConstraint.activate([
            turnContextBarTopToSafe,
            turnContextBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            turnContextBar.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.rowHeight = 120
        tableView.keyboardDismissMode = .interactive
        tableView.register(UserMessageCell.self, forCellReuseIdentifier: MessageCellReuseID.user)
        tableView.register(AssistantMessageCell.self, forCellReuseIdentifier: MessageCellReuseID.assistant)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 2, right: 0)
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
            tableView.topAnchor.constraint(equalTo: turnContextBar.bottomAnchor),
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
            contextUsageWork?.cancel()
            contextUsageView.setCompacting(false)
            contextUsageView.update(
                usage: ContextBuilder.Usage(usedChars: 0, budgetChars: 1),
                forceVisible: false,
                animated: false
            )
            return
        }

        let convID = conv.id
        let visible = ContextBuilder.shouldShowUsage(for: conv)
        let compacting = ContextCompactor.isCompacting(convID)
        let immediate = contextUsageCache[convID] ?? ContextBuilder.quickUsageEstimate(for: conv)
        contextUsageView.setCompacting(compacting)
        contextUsageView.update(usage: immediate, forceVisible: visible, animated: false)

        contextUsageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let usage = ContextBuilder.usage(for: conv)
            DispatchQueue.main.async {
                guard let self = self, convID == self.currentConversationID else { return }
                self.contextUsageCache[convID] = usage
                self.contextUsageView.setCompacting(ContextCompactor.isCompacting(convID))
                self.contextUsageView.update(usage: usage, forceVisible: visible, animated: animated)
            }
        }
        contextUsageWork = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
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
            contextUserIndex = nil
            turnContextBar.update(question: nil, visible: false)
            // Cancel any pending stream paint that could reconfigure a recycled cell.
            streamUIWork?.cancel()
            streamUIWork = nil
            clearNavigationPrompt()
            emptyTitleLabel.textColor = c.textPrimary
            emptySubtitleLabel.textColor = c.textSecondary
            let hideChips = keyboardVisible
            emptyChips?.isHidden = hideChips
            if let chips = emptyChips, !hideChips {
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
        let hideChips = keyboardVisible
        emptyChips?.isHidden = hideChips
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

        if studyContextProvider?.managesPortraitKeyboardLayout == true {
            applyPortraitStudyComposerBottom(keyboardFrame: frame)
            layoutEmptyChromeForKeyboard()
            animateKeyboard(duration: duration, note: note)
            return
        }

        // Convert keyboard to this VC's view (correct for split detail pane on iPad).
        let converted = view.convert(frame, from: nil)
        let intersection = view.bounds.intersection(converted)
        let overlap = intersection.isNull ? 0 : intersection.height
        // bottomConstraint is vs safeArea.bottom — subtract safe-area inset already baked into that anchor.
        let safePad = view.safeAreaInsets.bottom
        let lift = max(0, overlap - safePad)
        keyboardVisible = lift > 20
        bottomConstraint?.constant = keyboardVisible ? -(lift + 6) : restingComposerBottomConstant()
        layoutEmptyChromeForKeyboard()
        animateKeyboard(duration: duration, note: note)
    }

    private func animateKeyboard(duration: Double, note: Notification) {
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
            ?? UIView.AnimationCurve.easeInOut.rawValue
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
    }

    private func restingComposerBottomConstant() -> CGFloat {
        if studyContextProvider?.managesPortraitKeyboardLayout == true {
            return -(view.safeAreaInsets.bottom + DSTheme.inputBarBottomPadding)
        }
        return -DSTheme.inputBarBottomPadding
    }

    private func applyPortraitStudyComposerBottom(keyboardFrame: CGRect) {
        refreshComposerBottomAnchorIfNeeded()
        let converted = view.convert(keyboardFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - converted.minY)
        keyboardVisible = overlap > 20
        if keyboardVisible {
            bottomConstraint?.constant = -(overlap + DSTheme.inputBarBottomPadding)
        } else {
            bottomConstraint?.constant = restingComposerBottomConstant()
        }
    }

    private func refreshComposerBottomAnchorIfNeeded() {
        let useViewBottom = studyContextProvider?.managesPortraitKeyboardLayout == true
        guard useViewBottom != composerBottomUsesViewBottom else { return }
        composerBottomUsesViewBottom = useViewBottom
        bottomConstraint?.isActive = false
        if useViewBottom {
            bottomConstraint = inputBar.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: restingComposerBottomConstant()
            )
        } else {
            bottomConstraint = inputBar.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: restingComposerBottomConstant()
            )
        }
        bottomConstraint?.isActive = true
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        normalizePortraitPanelSafeArea()
        if studyContextProvider?.managesPortraitKeyboardLayout == true {
            bottomConstraint?.constant = restingComposerBottomConstant()
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
        viewportPinnedByUser = false
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
            body: "正在结合对话上下文推荐查证来源…\n（会消解「那这个呢」「为什么」等指代，并选择百科、知乎、媒体等站点定向检索。）"
        )

        let contextMsgs = apiContext(for: model, conversationID: convID)
        WebSearchService.planSearch(
            contextMessages: contextMsgs,
            model: model,
            fallbackQuery: query
        ) { [weak self] plan in
            guard let self = self else { return }
            guard WebSearchCoordinator.shared.isCurrent(convID, generation: generation) else { return }

            let effectivePlan = plan.targets.isEmpty ? WebSearchService.SearchPlan.fallback(query) : plan
            #if DEBUG
            print("[Connects] web search plan [\(convID.prefix(6))]: topic=\(effectivePlan.topic), targets=\(effectivePlan.targets.count)")
            #endif

            var planLog = "根据对话上下文推荐的查证来源：\n"
            for (i, target) in effectivePlan.targets.enumerated() {
                planLog += "\(i + 1). \(target.name)"
                if let domain = target.domain { planLog += " (\(domain))" }
                planLog += "\n   检索：\(target.query)"
                if let reason = target.reason, !reason.isEmpty {
                    planLog += "\n   原因：\(reason)"
                }
                if let url = target.directURL, !url.isEmpty {
                    planLog += "\n   直达：\(url)"
                }
                planLog += "\n"
            }
            self.updateSearchProcess(convID: convID, phase: .searching, body: planLog)

            WebSearchService.searchAndFormat(
                plan: effectivePlan,
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
            rowHeights.invalidate(messageID: messages[path.row].id)
            UIView.performWithoutAnimation {
                if let cell = tableView.cellForRow(at: path) as? AssistantMessageCell {
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
        guard force || !isViewportPinned() else { return }
        guard ConversationStore.shared.currentConversation?.messages.isEmpty == false else { return }
        if animated {
            snapToTrueBottom(animated: true)
        } else {
            snapToTrueBottom(animated: false)
        }
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

        var studyPrefix: String?
        if conv.studyPageCaptureEnabled,
           let snippet = studyContextProvider?.captureCurrentStudyPage() {
            if snippet.text.isEmpty {
                if conversationID == currentConversationID {
                    navigationItem.prompt = "当前页无可提取文字"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        if self?.navigationItem.prompt == "当前页无可提取文字" {
                            self?.navigationItem.prompt = nil
                        }
                    }
                }
            } else {
                studyPrefix = "[阅读上下文 · \(snippet.label)]\n\(String(snippet.text.prefix(4000)))"
            }
        }

        let needsAITitle = (conv.title == "新对话" || conv.title.hasSuffix("（分叉）")) && !conv.titleLocked
        let displayText = text.isEmpty && imageBase64 != nil ? "[图片]" : text
        let userMsg = ChatMessage(
            role: .user,
            content: displayText,
            imageJPEGBase64: imageBase64,
            apiContextPrefix: studyPrefix
        )
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
            viewportPinnedByUser = false
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
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              indexPath.row < messages.count else {
            return UITableViewCell()
        }
        let msg = messages[indexPath.row]
        let layoutWidth = currentRenderWidth()
        let preferred = rowHeights.displayColumnHeight(for: msg.id)
            ?? rowHeights.committedColumnHeight(for: msg.id)
        if msg.role == .user {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: MessageCellReuseID.user,
                for: indexPath
            ) as! UserMessageCell
            cell.cellDelegate = self
            bindImageCache(to: cell, message: msg)
            cell.configure(with: msg, preferredHeight: preferred, layoutWidth: layoutWidth)
            return cell
        }
        let cell = tableView.dequeueReusableCell(
            withIdentifier: MessageCellReuseID.assistant,
            for: indexPath
        ) as! AssistantMessageCell
        cell.cellDelegate = self
        bindImageCache(to: cell, message: msg)
        cell.configure(with: msg, preferredHeight: preferred, layoutWidth: layoutWidth)
        return cell
    }

    private func bindImageCache(to cell: MessageCellType, message: ChatMessage) {
        guard message.hasImage, let b64 = message.imageJPEGBase64 else { return }
        let key = message.id as NSString
        if let cached = ChatViewController.imageCache.object(forKey: key) {
            cell.setCachedImage(cached)
            return
        }
        let msgID = message.id
        DispatchQueue.global(qos: .utility).async {
            guard let img = ImageAttachmentHelper.image(from: b64) else { return }
            ChatViewController.imageCache.setObject(img, forKey: key)
            DispatchQueue.main.async { [weak cell] in
                guard let cell = cell, cell.messageID == msgID else { return }
                cell.setCachedImage(img)
            }
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              indexPath.row < messages.count else {
            return tableView.estimatedRowHeight
        }
        let msg = messages[indexPath.row]
        if msg.isStreaming { return UITableView.automaticDimension }
        return scrollAwareRowHeight(for: msg, row: indexPath.row, messageCount: messages.count)
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              indexPath.row < messages.count else { return 72 }
        let msg = messages[indexPath.row]
        return scrollAwareRowHeight(for: msg, row: indexPath.row, messageCount: messages.count)
            + (msg.isStreaming ? 28 : 0)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        scheduleUpdateTurnContextBar()
        let scrolling = tableView.isDragging || tableView.isDecelerating
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              indexPath.row < messages.count else { return }
        let msg = messages[indexPath.row]
        guard !msg.isStreaming else { return }
        let layoutWidth = currentRenderWidth()
        if SettingsManager.shared.renderDebugOverlayEnabled,
           let typedCell = cell as? MessageCellType {
            typedCell.refreshRenderDebugOverlay()
        }
        // Open: no sync markdown prewarm on willDisplay.
        if pendingOpenAtBottom || suppressHeightRemeasure {
            return
        }
        if scrolling {
            // Pin from cache only — never sync-layout on willDisplay (long replies hitch hard).
            var pinRows = [indexPath.row]
            if scrollBiasUp {
                for delta in 1...6 { pinRows.append(indexPath.row - delta) }
            } else {
                for delta in 1...6 { pinRows.append(indexPath.row + delta) }
            }
            _ = commitCachedLayoutHeights(
                messages: messages,
                layoutWidth: layoutWidth,
                rows: pinRows,
                syncLayoutBudget: 0
            )
            applyTurnWindowPrewarm(around: [indexPath.row], allowSync: false)
            return
        }
        prewarmForIncomingRow(indexPath.row)
        if msg.role == .user, let userCell = cell as? UserMessageCell {
            userCell.syncUserPresentation(with: msg, layoutWidth: layoutWidth)
            scheduleStableHeightPin(for: userCell, message: msg)
        } else if msg.role == .assistant, let assistantCell = cell as? AssistantMessageCell {
            assistantCell.applyDeferredNativeRenderIfNeeded()
            assistantCell.ensureNativeLayoutWidth(layoutWidth)
            scheduleStableHeightPin(for: assistantCell, message: msg)
        }
    }

    private func scheduleStableHeightPin(for cell: MessageCellType, message: ChatMessage) {
        DispatchQueue.main.async { [weak self, weak cell] in
            guard let self = self,
                  let cell = cell,
                  cell.messageID == message.id,
                  cell.window != nil,
                  !self.tableView.isDragging,
                  !self.tableView.isDecelerating else { return }
            let height = cell.measuredContentHeight()
            guard height > 40 else { return }
            let cached = self.rowHeights.committedColumnHeight(for: message.id) ?? 0
            let pinned = self.rowHeights.isCommitted(message.id)
            guard !pinned || abs(height - cached) > 4 else { return }
            self.messageCell(cell, didFinishStableRender: height, for: message.id)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollSettleWork?.cancel()
        deferredRenderWork?.cancel()
        deferredRenderWork = nil
        pinnedRemeasureWork?.cancel()
        stickToBottom = false
        readingHistory = true
        viewportPinnedByUser = true
        heightWork?.cancel()
        if let messages = ConversationStore.shared.currentConversation?.messages, !messages.isEmpty {
            let layoutWidth = currentRenderWidth()
            // Mutate heights once before freeze — never during the gesture.
            quickCommitVisibleHeights(messages: messages)
            _ = commitCachedLayoutHeights(
                messages: messages,
                layoutWidth: layoutWidth,
                rows: scrollLookaheadRows(in: messages),
                syncLayoutBudget: 0
            )
            rowHeights.beginScrollHeightFreeze(messages: messages, layoutWidth: layoutWidth)
            prewarmScrollLookahead(messages: messages, layoutWidth: layoutWidth)
        }
    }

    /// Pin visible uncommitted rows before the first drag. Avoid beginUpdates unless a visible row changes.
    private func quickCommitVisibleHeights(messages: [ChatMessage]) {
        let paths = tableView.indexPathsForVisibleRows ?? []
        guard !paths.isEmpty else { return }
        var visibleHeightChanged = false
        for path in paths {
            guard path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard !msg.isStreaming, !rowHeights.isCommitted(msg.id),
                  let cell = tableView.cellForRow(at: path) as? MessageCellType else { continue }
            let measured = cell.measuredContentHeight()
            guard measured > 40 else { continue }
            let prior = resolvedRowHeight(for: msg, row: path.row, messageCount: messages.count)
            rowHeights.commitMeasured(columnHeight: measured, messageID: msg.id, allowShrink: true)
            let next = resolvedRowHeight(for: msg, row: path.row, messageCount: messages.count)
            if abs(prior - next) > 3 {
                visibleHeightChanged = true
            }
        }
        guard visibleHeightChanged else { return }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y
        if abs(y - lastScrollOffsetY) > 2 {
            scrollBiasUp = y < lastScrollOffsetY
        }
        lastScrollOffsetY = y
        scheduleUpdateTurnContextBar()
        // Content-size changes from KaTeX/WebKit also trigger this callback.
        // Never change sticky/pinned mode here — only after the gesture ends.
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateScrollModeAtRest()
            scheduleScrollHeightSettling()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateScrollModeAtRest()
        scheduleScrollHeightSettling()
    }

    private func scheduleScrollHeightSettling() {
        scrollSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performScrollHeightSettling()
        }
        scrollSettleWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func performScrollHeightSettling() {
        contextBarScrollWork?.cancel()
        updateTurnContextBar()
        let wasFrozen = rowHeights.isScrollHeightFrozen
        rowHeights.endScrollHeightFreeze()
        rowHeights.publishCommittedToDisplay()
        if wasFrozen {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
        }
        let visible = tableView.indexPathsForVisibleRows ?? []
        if !visible.isEmpty {
            applyLookaheadTurnPrewarm()
        }
        scheduleVisibleDeferredNativeHydration()
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            cell.applyDeferredHeightIfNeeded()
        }
        if !pendingHeights.isEmpty {
            flushPendingHeights()
        }
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let layoutWidth = currentRenderWidth()
        for path in visible where path.row < messages.count {
            seedDisplayFromLayoutCache(
                for: messages[path.row],
                row: path.row,
                messageCount: messages.count,
                layoutWidth: layoutWidth
            )
        }
        reconcileVisibleRowHeights(preserveBottom: false)
        for path in visible {
            guard path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard !rowHeights.isCommitted(msg.id),
                  let typedCell = tableView.cellForRow(at: path) as? MessageCellType else { continue }
            scheduleStableHeightPin(for: typedCell, message: msg)
        }
    }
}

extension ChatViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let scrolling = tableView.isDragging || tableView.isDecelerating
        if scrolling {
            applyTurnWindowPrewarm(around: indexPaths.map(\.row), allowSync: false)
            return
        }
        let layoutWidth = currentRenderWidth()
        let messageCount = messages.count
        var anchors = Set(indexPaths.map(\.row))
        for row in indexPaths.map(\.row) {
            for delta in 1...(Self.turnPrewarmCount * 2) {
                if row - delta >= 0 { anchors.insert(row - delta) }
                if row + delta < messages.count { anchors.insert(row + delta) }
            }
            guard row >= 0, row < messages.count else { continue }
            let msg = messages[row]
            if msg.role == .user {
                seedDisplayFromLayoutCache(
                    for: msg,
                    row: row,
                    messageCount: messageCount,
                    layoutWidth: layoutWidth
                )
                if row + 1 < messages.count {
                    let assistant = messages[row + 1]
                    if assistant.role == .assistant, !assistant.isStreaming {
                        if assistant.content.count <= Self.syncPrewarmMaxChars {
                            AssistantMessageLayout.prewarmLayouts(
                                for: [assistant],
                                targetWidth: layoutWidth,
                                layoutLimit: 1
                            )
                        } else {
                            scheduleAsyncLayoutPrewarm(assistants: [assistant], layoutWidth: layoutWidth)
                        }
                        seedDisplayFromLayoutCache(
                            for: assistant,
                            row: row + 1,
                            messageCount: messageCount,
                            layoutWidth: layoutWidth
                        )
                    }
                }
            }
            if msg.role == .assistant, !msg.isStreaming {
                if msg.content.count <= Self.syncPrewarmMaxChars {
                    AssistantMessageLayout.prewarmLayouts(
                        for: [msg],
                        targetWidth: layoutWidth,
                        layoutLimit: 1
                    )
                } else {
                    scheduleAsyncLayoutPrewarm(assistants: [msg], layoutWidth: layoutWidth)
                }
                seedDisplayFromLayoutCache(
                    for: msg,
                    row: row,
                    messageCount: messageCount,
                    layoutWidth: layoutWidth
                )
            }
        }
        applyTurnWindowPrewarm(around: Array(anchors).sorted())
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        // Native layouts are immutable cache entries; no cancellation needed.
    }
}

extension ChatViewController: MessageCellDelegate {
    func messageCellShouldFreezeHeight(_ cell: MessageCellType) -> Bool {
        // Opening / switching must never take the scroll plain path — causes red flash.
        if pendingOpenAtBottom || suppressHeightRemeasure { return false }
        return tableView.isDragging || tableView.isDecelerating
    }

    func messageCellShouldDeferHeavyRender(_ cell: MessageCellType) -> Bool {
        if pendingOpenAtBottom || suppressHeightRemeasure {
            guard let messages = ConversationStore.shared.currentConversation?.messages,
                  let msg = messages.first(where: { $0.id == cell.messageID }),
                  msg.role == .assistant,
                  !msg.isStreaming else {
                return true
            }
            let layoutWidth = currentRenderWidth()
            if isTailAssistantMessage(cell.messageID) {
                return !AssistantMessageLayout.hasCachedNativeLayout(for: msg, layoutWidth: layoutWidth)
            }
            // History rows: plain text on swap, native upgraded async when warm.
            return true
        }
        guard tableView.isDragging || tableView.isDecelerating else { return false }
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let msg = messages.first(where: { $0.id == cell.messageID }),
              msg.role == .assistant,
              !msg.isStreaming else {
            return false
        }
        // Scroll path: native only when layout cache is warm. Never sync-layout mid-gesture.
        return !AssistantMessageLayout.hasCachedNativeLayout(
            for: msg,
            layoutWidth: currentRenderWidth()
        )
    }

    func messageCellShouldPreserveOpenPaint(_ cell: MessageCellType) -> Bool {
        pendingOpenAtBottom || suppressHeightRemeasure
    }

    func messageCellShouldLayoutActionChromeNow(_ cell: MessageCellType) -> Bool {
        !pendingOpenAtBottom && !suppressHeightRemeasure
    }

    func messageCell(_ cell: MessageCellType, didUpdateHeight height: CGFloat, for messageID: String) {
        if readingHistory {
            if height > 40 {
                rowHeights.recordDiskEstimate(columnHeight: height, messageID: messageID)
                if let cid = renderedConversationID {
                    storePersistedHeights(rowHeights.exportPersistable(), for: cid)
                }
            }
            return
        }
        guard ConversationStore.shared.currentConversation?.messages.first(where: { $0.id == messageID }) != nil else {
            return
        }
        let scrolling = tableView.isDragging || tableView.isDecelerating
        if scrolling {
            if height > 40 {
                pendingHeights[messageID] = max(pendingHeights[messageID] ?? 0, height)
            }
            return
        }
        guard let msg = ConversationStore.shared.currentConversation?.messages.first(where: { $0.id == messageID }) else {
            return
        }
        let old = rowHeights.bestKnownColumnHeight(for: messageID)
        let growing = height > old + 4
        let threshold: CGFloat = growing ? 6 : 8
        guard abs(old - height) > threshold else {
            if old == 0, height > 40 {
                rowHeights.recordDiskEstimate(columnHeight: height, messageID: messageID)
            }
            return
        }
        pendingHeights[messageID] = height
        heightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingHeights()
        }
        heightWork = work
        let delay: TimeInterval = msg.isStreaming ? 0.14 : (growing ? 0.03 : 0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func messageCell(_ cell: MessageCellType, didFinishStableRender height: CGFloat, for messageID: String) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let row = messages.firstIndex(where: { $0.id == messageID }),
              !messages[row].isStreaming else { return }
        let message = messages[row]
        let scrolling = tableView.isDragging || tableView.isDecelerating
        if scrolling {
            if height > 40 {
                pendingHeights[messageID] = max(pendingHeights[messageID] ?? 0, height)
            }
            return
        }
        let hasVariableChrome = !message.reasoningContent.isEmpty || message.hasSearchProcess
        let cached = rowHeights.bestKnownColumnHeight(for: messageID)
        if cell.hasPendingDeferredNativeRender, height + 8 < cached {
            return
        }
        let priorRow = resolvedRowHeight(for: message, row: row, messageCount: messages.count)
        rowHeights.commitMeasured(columnHeight: height, messageID: messageID, allowShrink: true)
        if let cid = renderedConversationID {
            storePersistedHeights(rowHeights.exportPersistable(), for: cid)
            scheduleHeightCacheSave()
        }
        guard cell.window != nil else { return }
        let path = IndexPath(row: row, section: 0)
        let targetRowHeight = resolvedRowHeight(for: message, row: row, messageCount: messages.count)
        let rowNeedsGrow = targetRowHeight > priorRow + 2
            || tableView.rectForRow(at: path).height + 2 < targetRowHeight
        // During open suppress: still expand when growing so action buttons aren't clipped.
        if suppressHeightRemeasure {
            guard rowNeedsGrow else { return }
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
                if stickToBottom {
                    pinOpenViewportToBottom(messages)
                }
            }
            return
        }
        guard abs(priorRow - targetRowHeight) > 4
            || abs(tableView.rectForRow(at: path).height - targetRowHeight) > 4 else { return }
        if isViewportPinned() || hasVariableChrome {
            schedulePinnedRemeasure()
            return
        }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            if stickToBottom, !isViewportPinned() {
                scrollToBottom(animated: false)
            }
        }
    }

    private func flushPendingHeights() {
        guard !pendingHeights.isEmpty else { return }
        if tableView.isDragging || tableView.isDecelerating { return }
        let includesStreamingMessage = pendingHeights.keys.contains { id in
            ConversationStore.shared.currentConversation?.messages.first(where: { $0.id == id })?.isStreaming == true
        }
        var changed = false
        for (id, height) in pendingHeights {
            let old = rowHeights.bestKnownColumnHeight(for: id)
            if abs(old - height) > 3 {
                let streaming = ConversationStore.shared.currentConversation?.messages
                    .first(where: { $0.id == id })?.isStreaming == true
                rowHeights.commitMeasured(
                    columnHeight: height,
                    messageID: id,
                    allowShrink: !streaming
                )
                changed = true
            }
        }
        pendingHeights.removeAll()
        if changed, !includesStreamingMessage, let cid = renderedConversationID {
            storePersistedHeights(rowHeights.exportPersistable(), for: cid)
            scheduleHeightCacheSave()
        }
        guard changed else { return }
        if isViewportPinned() {
            schedulePinnedRemeasure()
        } else {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
                if stickToBottom, !isViewportPinned() {
                    scrollToBottom(animated: false)
                }
            }
        }
    }

    func messageCellDidTapCopy(_ cell: MessageCellType, messageID: String) {
        guard let msg = ConversationStore.shared.currentConversation?.messages.first(where: { $0.id == messageID }) else { return }
        UIPasteboard.general.string = msg.copyableText
        navigationItem.prompt = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.navigationItem.prompt == "已复制" {
                self?.navigationItem.prompt = nil
            }
        }
    }

    func messageCellDidTapRetry(_ cell: MessageCellType, messageID: String) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        retryFromMessage(at: idx)
    }

    func messageCellDidTapFork(_ cell: MessageCellType, messageID: String) {
        guard let id = ConversationStore.shared.currentConversationID else { return }
        _ = ConversationStore.shared.forkConversation(id: id, throughMessageID: messageID)
    }

    func messageCellDidShiftVersion(_ cell: MessageCellType, messageID: String, delta: Int) {
        guard let convID = ConversationStore.shared.currentConversationID else { return }
        var changed = false
        ConversationStore.shared.updateConversationQuietly(id: convID) { c in
            guard let idx = c.messages.firstIndex(where: { $0.id == messageID }) else { return }
            changed = c.messages[idx].shiftVersion(by: delta)
        }
        guard changed else { return }
        // Content length can differ a lot across versions — drop cached height.
        rowHeights.invalidate(messageID: messageID)
        if let cid = renderedConversationID {
            storePersistedHeights(rowHeights.exportPersistable(), for: cid)
            saveHeightCaches()
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

    func inputBarDidToggleStudyCapture(_ enabled: Bool) {
        guard let id = currentConversationID else { return }
        ConversationStore.shared.updateConversation(id: id) { draft in
            draft.studyPageCaptureEnabled = enabled
        }
        inputBar.studyPageCaptureEnabled = enabled
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
