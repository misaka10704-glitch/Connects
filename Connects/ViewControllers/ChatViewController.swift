import UIKit

protocol ChatViewControllerDelegate: AnyObject {
    func chatDidUpdateTitle(_ title: String)
    func chatDidRequestShare()
    func chatDidFinishInitialLaunch()
    func chatDidRequestSettings()
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
    private let modelButton = UIButton(type: .custom)
    /// Study nav title: ▲/▼ panel control. Model / AI 选项 only live in the input bar.
    private let studyPanelNavCapsule = StudyPanelStageCapsule()
    private lazy var studyPanelNavHost = StudyPanelNavTitleHost(capsule: studyPanelNavCapsule)
    private let emptyTitleLabel = UILabel()
    private let emptySubtitleLabel = UILabel()
    private let emptyConfigureKeyButton = UIButton(type: .system)
    private let emptyContainer = UIView()
    private var sidebarToggleItem: UIBarButtonItem?
    private var pendingSidebarCollapsed: Bool?
    private var studyChromeMode: StudyChromeMode = .none
    /// When study AI is fully expanded it covers the reader sidebar — show the toggle here.
    private var studyShowsSidebarToggle = false
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
    /// Chrome toggle: skip measuredContentHeight paint clamp in heightForRowAt (very expensive).
    private var suppressRowHeightPaintClamp = false
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
    /// Bottom stick without blocking taps / sidebar — cleared when async settle finishes.
    private var openBottomStickActive = false
    private var lastOpenBottomPinTime: CFTimeInterval = 0
    /// Bumped on every conversation switch — async open/prewarm must bail when stale.
    private var openGeneration: UInt = 0
    private var contextUserIndex: Int?
    private var contextBarWork: DispatchWorkItem?
    private var contextUsageWork: DispatchWorkItem?
    private var contextUsageCache: [String: ContextBuilder.Usage] = [:]
    /// Workspace agent tool-loop rounds per conversation (cap at AgentOrchestrator.maxRounds).
    private var agentToolRoundCounts: [String: Int] = [:]
    /// First assistant in a workspace tool loop — process steps accumulate here across续跑.
    private var agentProcessRootIDs: [String: String] = [:]
    /// Plan markdown being built / executed (workspace Build flow).
    private(set) var activePlanDocumentID: String?
    private var contextBreakdownCache: [String: ContextBuilder.Breakdown] = [:]
    private var userTurnRowsCache: (
        conversationID: String?,
        messageCount: Int,
        firstMessageID: String?,
        lastMessageID: String?,
        rows: [Int]
    )?
    private var streamUIWork: DispatchWorkItem?
    private var streamUITimer: Timer?
    /// Keep the table locked from first stream token until finished paint pins to bottom.
    private var finishViewportLocked = false
    private var lastStreamMessageID = ""
    private var lastStreamContentBytes = -1
    private var lastStreamVisibleBytes = -1
    private var lastStreamReasoningBytes = -1
    private var lastStreamSearchBytes = -1
    private var lastStreamImageTranscriptionBytes = -1
    private var lastStreamPhase: SearchProcessPhase = .idle
    private var lastStreamImageTranscriptionPhase: ImageTranscriptionPhase = .idle
    private var lastStreamProgressAt = Date()
    private var lastStreamLayoutAt = Date.distantPast
    private var streamSpinnerFrame = 0
    /// Throttle agent idle「Planning next moves…」pulses — unthrottled 25fps sync froze taps.
    private var lastAgentPlanningPulseAt = Date.distantPast
    /// Agent root stream: throttle beginUpdates (≥300ms). Unthrottled + chrome collapse froze taps.
    private var lastAgentStreamLayoutAt = Date.distantPast
    private var heightWork: DispatchWorkItem?
    private var pendingHeights: [String: CGFloat] = [:]
    private var chromeWork: DispatchWorkItem?
    private var prewarmWork: DispatchWorkItem?
    private var deferredRenderWork: DispatchWorkItem?
    private var openSettleWork: DispatchWorkItem?
    private var openSettleFollowUpWork: DispatchWorkItem?
    private var openCoalesceWork: DispatchWorkItem?
    private var openBottomPinWork: DispatchWorkItem?
    private var openIdleBackgroundWork: DispatchWorkItem?
    private static let switchCoalesceDelay: TimeInterval = 0.12
    private var idlePrewarmWork: DispatchWorkItem?
    private var lastScrollOffsetY: CGFloat = 0
    private var scrollBiasUp = false
    /// Top visible row + viewport delta — stable remeasure anchor while reading history.
    private var viewportScrollAnchor: (row: Int, deltaY: CGFloat)?
    private var scrollSettleWork: DispatchWorkItem?
    private var scrollFreezeGeometryWork: DispatchWorkItem?
    /// Heavy finger-down prep deferred off the first scroll frames.
    private var scrollBeginPrepWork: DispatchWorkItem?
    /// First-history / study prep deferred until finger lifts (never mid-drag).
    private var pendingFingerDownHeavyPrep: (study: Bool, light: Bool)?
    /// Visible row set last used for history edge pinning (skip per-frame work).
    private var lastHistoryEdgePinVisibleRows: Set<Int> = []
    private var studyFrozenShrinkRemeasureWork: DispatchWorkItem?
    private var isSyncingFrozenAssistantGeometry = false
    private var scrollGestureGeometryFinished = false
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
    /// First scroll after rotation / width bucket change needs full chrome + height commit.
    private var pendingPostWidthChangeSettle = false
    /// While jumping via turn context bar — skip remeasure that would undo the anchor.
    private var isJumpingToTurn = false
    /// User picked a turn from the context bar — keep that question pinned until they drag.
    private var pinnedJumpUserRow: Int?
    private var lastActionChromeRevealTime: CFTimeInterval = 0
    private var formulaRemeasureWork: DispatchWorkItem?
    /// Landscape study split — keeps action chrome off the PDF/chat seam.
    private static let studyPanelLeadingGutter: CGFloat = 18
    /// Formula warm-ups during a scroll gesture — flushed once at settle.
    private var pendingReadingHistoryFormulaSync = false
    /// Batches native hydration — suppress per-row remeasure until the pass completes.
    private var visibleNativeHydrationInProgress = false
    /// Post-scroll anchor captured before row-height relayout (history reading).
    private var pendingScrollSettleAnchor: (path: IndexPath, viewportY: CGFloat)?
    /// Anchor row locked at finger-down — viewport Y updates, row never hops at QA edges.
    private var gestureLockedScrollAnchorRow: Int?
    /// Skip formula-sync remeasure on the frame immediately after history settle.
    private var suppressPostHistorySettleRemeasure = false
    /// Finger-down content offset — detect bubble-edge wiggle (small net displacement).
    private var gestureStartContentOffsetY: CGFloat = 0
    private var gestureMinContentOffsetY: CGFloat = 0
    private var gestureMaxContentOffsetY: CGFloat = 0
    private static let actionChromeHeightSlack = AssistantMessageLayout.actionRowHeight + 6
    #if DEBUG
    var debugLayoutWidthOverride: CGFloat?
    #endif
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
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged), name: .chatFontSizeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(renderDebugChanged), name: .renderDebugDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(turnContextBarChanged), name: .turnContextBarDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(imageTranscriptionSettingChanged), name: .imageTranscriptionDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(nativeFormulaDidRender), name: .nativeFormulaDidRender, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(visibleModelsChanged), name: .visibleModelsDidChange, object: nil)
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
    private static let coldLaunchLayoutProbeRows = 4
    /// Bottom-open → first upward scroll: collapse inflated estimates before height freeze.
    private var needsFirstHistoryScrollPrep = false
    /// After the first history scroll gesture settles, partial freeze is safe again.
    private var hasCompletedFirstHistoryScrollGesture = false
    /// Message count last bound to the table — detects in-place fixture / bulk reload.
    private var renderedMessageCount = 0
    /// One-shot after entering study panel or cold-open in study — not every study scroll.
    private var pendingStudyFirstScrollPrep = false

    private var needsPendingScrollPrep: Bool {
        needsFirstHistoryScrollPrep || pendingStudyFirstScrollPrep
    }
    private var nativeHydrationScrollWork: DispatchWorkItem?
    private static let switchLayoutProbeTailRows = 4
    /// Tail band seeded on open/switch — avoids O(n) walks on long threads.
    private static let openBottomSeedTailRows = 24

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyStudyChrome()
        updateEmptyState()
        if renderedConversationID == nil, view.window != nil {
            // Bind the restored conversation as soon as we are in a window —
            // before the first painted frame shows the empty-state chrome.
            reloadChat()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        repairStuckBlankContentIfNeeded()
        if renderedConversationID == nil, view.window != nil {
            // Root preloads this controller before its navigation view is in a
            // window. UITableView must not lay out/reload its visible rows yet.
            reloadChat()
        }
        ensureBottomPinnedIfNeeded()
        if stickToBottom,
           !needsPendingScrollPrep,
           let messages = ConversationStore.shared.currentConversation?.messages,
           !messages.isEmpty {
            // Opening can begin while this controller is still outside the
            // window hierarchy. Pin only after it has real bounds.
            // Skip when eager open prep is queued — it pins on the next frame.
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
        #if DEBUG
        ScrollStressHarness.scheduleIfRequested(on: self)
        ScrollStressHarness.scheduleThinkingExpandBenchIfRequested(on: self)
        UsageSimulationHarness.startIfRequested(from: self)
        WebSearchDebugHarness.startIfRequested(from: self)
        #endif
    }

    private func repairStuckBlankContentIfNeeded() {
        let empty = (ConversationStore.shared.currentConversation?.messages.isEmpty ?? true)
        if empty {
            if emptyContainer.isHidden {
                updateEmptyState()
            }
            return
        }
        guard tableView.isHidden || tableView.alpha < 0.05 else { return }
        tableView.isHidden = false
        tableView.alpha = 1
        emptyContainer.isHidden = true
        if renderedConversationID == nil, view.window != nil {
            reloadChat()
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
        if navigationItem.titleView === studyPanelNavHost {
            studyPanelNavHost.setNeedsLayout()
        }
        // Keep composer controls above the table after scroll-driven relayout.
        if inputBar.superview === view {
            view.bringSubviewToFront(inputBar)
        }
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
        let prospectiveWidth = size.width > 32 ? size.width : tableView.bounds.width
        let newBucket = widthBucket(for: prospectiveWidth)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self = self else { return }
            guard newBucket > 0, newBucket != self.layoutWidthBucket else { return }
            self.layoutWidthBucket = newBucket
            self.scheduleInvalidateHeightsForWidthChange()
        }
    }

    @objc private func chatWidthDidChange(_ note: Notification) {
        // Study panel height flips used to post this every time and rebuild all row heights.
        let reported = note.userInfo?["width"] as? CGFloat
        let candidate = tableView.bounds.width > 32 ? tableView.bounds.width : (reported ?? 0)
        let bucket = widthBucket(for: candidate)
        guard bucket > 0 else { return }
        if layoutWidthBucket == 0 {
            layoutWidthBucket = bucket
            return
        }
        guard bucket != layoutWidthBucket else { return }
        layoutWidthBucket = bucket
        scheduleInvalidateHeightsForWidthChange()
    }

    /// Fix assistant rows whose UITableView height is clipping action chrome.
    private func repairVisibleAssistantRowClips(messages: [ChatMessage]) {
        guard tableView.window != nil else { return }
        let layoutWidth = currentRenderWidth()
        var changed = false
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let msg = messages.first(where: { $0.id == cell.messageID }),
                  msg.role == .assistant,
                  !msg.isStreaming else { continue }
            cell.applyDeferredNativeRenderIfNeeded(suppressHeightNotify: true)
            if cell.needsNativeRepaint(at: layoutWidth) {
                cell.configureForOpenHistory(
                    with: msg,
                    preferredHeight: rowHeights.displayColumnHeight(for: msg.id)
                        ?? rowHeights.committedColumnHeight(for: msg.id),
                    layoutWidth: layoutWidth
                )
            }
            _ = cell.ensureActionButtonsVisible(for: msg)
            if syncRowHeightToPaint(cell: cell, message: msg, allowShrink: false) {
                changed = true
            }
        }
        guard changed else { return }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
        tableView.layoutIfNeeded()
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
        guard tableView.window != nil, isTableLayoutCommitted(),
              tableView.bounds.width > 32, tableView.bounds.height > 32,
              let messages = renderedConversationMessages() else { return }
        let visible = tableView.indexPathsForVisibleRows ?? []
        viewportScrollAnchor = captureViewportScrollAnchor()
        let frozenAnchor = viewportScrollAnchorPath()
        // Rebuild in-memory row geometry for the new width. Keep disk maps for other
        // buckets (and this one) — wiping here made the next open use empty cheap estimates.
        let layoutWidth = currentRenderWidth()
        let disk: [String: CGFloat]
        if let cid = renderedConversationID {
            disk = sessionPersistedHeights(for: cid)
        } else {
            disk = [:]
        }
        rowHeights.resetForConversation(
            diskCache: disk,
            messages: messages,
            layoutWidth: layoutWidth
        )
        let visibleRows = visible.map(\.row)
        var commitRows = Set(visibleRows)
        if isStudyNarrowPanelActive() || studyChromeMode != .none {
            // Portrait→landscape study: off-screen rows keep stale wide heights → blank gaps.
            let lookahead = scrollLookaheadRowsPrioritized(in: messages)
            commitRows.formUnion(lookahead)
            if let minV = visibleRows.min(), minV > 0 {
                let above = max(0, minV - Self.turnPrewarmCount * 4)
                commitRows.formUnion(above..<minV)
            }
        }
        let sortedCommit = commitRows.filter { $0 >= 0 && $0 < messages.count }.sorted()
        _ = commitCachedLayoutHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: sortedCommit,
            syncLayoutBudget: min(isStudyNarrowPanelActive() ? 16 : 8, sortedCommit.count),
            allowGrowCommitted: true,
            allowShrinkCommitted: isStudyNarrowPanelActive() || studyChromeMode != .none
        )
        if isStudyNarrowPanelActive() || studyChromeMode != .none {
            _ = shrinkInflatedCommittedRows(
                messages: messages,
                rows: sortedCommit,
                layoutWidth: layoutWidth,
                slackThreshold: 12
            )
        }
        rebindRowHeightsAfterWidthChange(messages: messages, layoutWidth: layoutWidth)
        UIView.performWithoutAnimation {
            tableView.layoutIfNeeded()
            for path in visible where path.row < messages.count {
                guard let cell = tableView.cellForRow(at: path) as? MessageCellType else { continue }
                cell.contentView.setNeedsLayout()
                cell.contentView.layoutIfNeeded()
                reconfigureVisibleCell(cell, at: path, messages: messages, layoutWidth: layoutWidth)
            }
            revealVisibleActionChrome(messages: messages)
            for path in visible where path.row < messages.count {
                guard messages[path.row].role == .assistant,
                      let assistant = tableView.cellForRow(at: path) as? AssistantMessageCell else { continue }
                assistant.ensureNativeLayoutWidth(layoutWidth)
            }
            tableView.beginUpdates()
            tableView.endUpdates()
            if stickToBottom && !isViewportPinned() {
                reconcileBottomViewportIfNeeded(messages: messages, layoutWidth: layoutWidth)
            } else {
                remeasureRowsPreservingViewport(anchorPath: frozenAnchor, preferSavedViewportAnchor: true)
            }
            _ = shrinkInflatedVisibleRows(messages: messages)
            repairVisibleAssistantRowClips(messages: messages)
            paintVisibleBlankAssistantsIfNeeded(messages: messages, layoutWidth: layoutWidth)
        }
        prewarmVisibleRichReplies(for: layoutWidth)
        pendingPostWidthChangeSettle = true
        if isStudyNarrowPanelActive() || studyChromeMode != .none {
            pendingStudyFirstScrollPrep = true
        }
        if stickToBottom, !isViewportPinned() {
            DispatchQueue.main.async { [weak self] in
                self?.eagerPreparePendingHistoryHeightsAtBottom()
            }
        } else if isStudyNarrowPanelActive() || studyChromeMode != .none {
            // Not at bottom: still rebind a wider band so the next scroll does not flash blanks.
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let messages = ConversationStore.shared.currentConversation?.messages else { return }
                let layoutWidth = self.currentRenderWidth()
                self.paintVisibleBlankAssistantsIfNeeded(messages: messages, layoutWidth: layoutWidth)
                self.applyTurnWindowPrewarm(
                    around: self.lookaheadAnchorRows(in: messages),
                    allowSync: false
                )
            }
        }
        _ = immediate
    }

    /// Full-width / portrait: rebind visible + tail from layout cache — not every off-screen row.
    private func rebindRowHeightsAfterWidthChange(messages: [ChatMessage], layoutWidth: CGFloat) {
        let visible = tableView.indexPathsForVisibleRows?.map(\.row) ?? []
        let lookahead = scrollLookaheadRowsPrioritized(in: messages)
        var commitRows = Set(visible + lookahead)
        commitRows.formUnion(tailBandRows(in: messages, count: max(Self.switchLayoutProbeTailRows * 3, 12)))
        let sortedCommit = commitRows.filter { $0 >= 0 && $0 < messages.count }.sorted()
        let assistants = sortedCommit.compactMap { row -> ChatMessage? in
            guard row < messages.count else { return nil }
            let msg = messages[row]
            return msg.role == .assistant && !msg.isStreaming ? msg : nil
        }
        guard !assistants.isEmpty else { return }
        let prewarmLimit = min(assistants.count, isStudySessionActive() ? 16 : 12)
        AssistantMessageLayout.prewarmLayouts(
            for: assistants,
            targetWidth: layoutWidth,
            layoutLimit: prewarmLimit
        )
        _ = commitCachedLayoutHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: sortedCommit,
            syncLayoutBudget: min(12, sortedCommit.count),
            allowGrowCommitted: true,
            allowShrinkCommitted: true
        )
        rowHeights.rebuildDisplayHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            layoutProbeTailRows: max(Self.switchLayoutProbeTailRows, min(16, sortedCommit.count))
        )
    }

    private func reconfigureVisibleCell(_ cell: MessageCellType,
                                        at path: IndexPath,
                                        messages: [ChatMessage],
                                        layoutWidth: CGFloat) {
        let msg = messages[path.row]
        let preferred = rowHeights.displayColumnHeight(for: msg.id)
        if let assistant = cell as? AssistantMessageCell, msg.role == .assistant {
            let paired = pairedUserMessage(forAssistantAt: path.row, in: messages)
            assistant.configure(
                with: msg,
                preferredHeight: preferred,
                layoutWidth: layoutWidth,
                pairedUser: paired
            )
        } else {
            cell.configure(with: msg, preferredHeight: preferred, layoutWidth: layoutWidth)
        }
    }

    private func currentRenderWidth() -> CGFloat {
        // Table width is authoritative for chat layout. Only fall back to view when
        // the table has not been laid out yet (avoid min(table, view) eating sidebar math).
        #if DEBUG
        if let override = debugLayoutWidthOverride, override > 1 {
            let gutter = isStudyNarrowPanelActive() ? Self.studyPanelLeadingGutter : 0
            return min(DSTheme.bubbleMaxWidth, max(override - 48 - gutter, 120))
        }
        #endif
        let tableW = tableView.bounds.width
        let raw = tableW > 1 ? tableW : max(view.bounds.width, 0)
        // Match AssistantMessageCell column width: contentView inset 48 + leading gutter (not 2×).
        let gutter = isStudyNarrowPanelActive() ? Self.studyPanelLeadingGutter : 0
        return min(DSTheme.bubbleMaxWidth, max(raw - 48 - gutter, 120))
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

    /// Split-panel narrow chat only — portrait / full-width study still uses nearest bucket.
    private func isStudyNarrowPanelActive() -> Bool {
        studyChromeMode == .documentReader
    }

    /// Any study chrome (portrait panel or landscape reader) — shared height/scroll policy.
    private func usesStudyHeightBucketPolicy() -> Bool {
        studyChromeMode != .none
    }

    private func rowHeightPaintSlackThreshold() -> CGFloat {
        usesStudyHeightBucketPolicy() ? 10 : 24
    }

    /// When tail viewport is authoritative, measured paint may shrink committed heights.
    private func shouldClampCommittedHeightToPaint(for message: ChatMessage) -> Bool {
        if message.isStreaming { return false }
        if tableView.isDragging || tableView.isDecelerating || rowHeights.isScrollHeightFrozen { return false }
        if readingHistory { return false }
        if suppressHeightRemeasure || suppressPostHistorySettleRemeasure { return false }
        return stickToBottom || finishViewportLocked
    }

    /// Single heightForRowAt authority: collapse stale committed height to visible paint (tail only).
    private func rowHeightClampedToVisiblePaint(for msg: ChatMessage,
                                                at indexPath: IndexPath,
                                                resolved: CGFloat) -> CGFloat {
        if suppressRowHeightPaintClamp { return resolved }
        guard let cell = tableView.cellForRow(at: indexPath) as? MessageCellType,
              cell.messageID == msg.id else { return resolved }
        let painted = cell.measuredContentHeight() + ChatRowHeightResolver.cellVerticalMargin
        guard painted > 40 else { return resolved }
        let slack = rowHeightPaintSlackThreshold()
        // Freeze = stable heights. Mid-scroll paint clamp / shrink shifts content above the
        // viewport (fast fling is obvious with code cards). Collapse slack at finger-down
        // and settle instead.
        if rowHeights.isScrollHeightFrozen { return resolved }
        guard shouldClampCommittedHeightToPaint(for: msg) else { return resolved }
        if let assistant = cell as? AssistantMessageCell, msg.role == .assistant {
            if !assistant.hasVisibleBodyPaint, !assistant.hasReservedActionChromeSpace {
                return resolved
            }
        }
        if resolved > painted + slack {
            return painted
        }
        if painted > resolved + slack {
            return painted
        }
        return resolved
    }

    /// Unified tail settle: shrink inflated rows, remeasure table, optionally pin bottom.
    private func reconcileTailViewportToPaint(messages: [ChatMessage],
                                              focusRows: [Int],
                                              pinBottom: Bool,
                                              unlockScroll: Bool = false) {
        let slack = rowHeightPaintSlackThreshold()
        let layoutWidth = currentRenderWidth()
        for row in focusRows where row >= 0 && row < messages.count {
            let msg = messages[row]
            guard !msg.isStreaming else { continue }
            let path = IndexPath(row: row, section: 0)
            if let cell = tableView.cellForRow(at: path) as? AssistantMessageCell,
               cell.messageID == msg.id {
                _ = cell.syncNativeBodyHeightToLayout()
                let fitted = max(cell.fittedColumnContentHeight(), cell.measuredContentHeight())
                if fitted > 40 {
                    rowHeights.commitMeasured(
                        columnHeight: fitted,
                        messageID: msg.id,
                        allowShrink: shouldClampCommittedHeightToPaint(for: msg)
                    )
                }
            }
        }
        _ = shrinkInflatedCommittedRows(
            messages: messages,
            rows: focusRows,
            layoutWidth: layoutWidth,
            slackThreshold: slack
        )
        _ = syncVisibleRowHeightsToPaint(
            messages: messages,
            allowShrink: true,
            allowTableUpdates: false
        )
        _ = shrinkInflatedVisibleRows(messages: messages, slackThreshold: slack)
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()
        }
        if pinBottom {
            pinToFinishedTurnBottom(unlockScroll: unlockScroll)
        }
    }

    private func sessionPersistedHeights(for conversationID: String) -> [String: CGFloat] {
        ensureHeightCacheLoaded(for: conversationID)
        // Study panels must not bootstrap from full-width buckets — that leaves tall blank rows.
        if usesStudyHeightBucketPolicy() {
            return exactPersistedHeights(for: conversationID)
        }
        return persistedHeights(for: conversationID)
    }

    /// Grow/shrink visible rows to match painted content after scroll freeze lifts.
    private func finalizeScrollSettleLayout(messages: [ChatMessage],
                                          anchorPath: IndexPath? = nil,
                                          fixedViewportY: CGFloat? = nil) {
        repairVisibleAssistantRowClips(messages: messages)
        // History settle: grow/clip only — shrinking remounts chrome mid-rest (QA-edge flicker).
        var changed = false
        if !readingHistory {
            changed = shrinkInflatedVisibleRows(messages: messages)
        }
        if syncVisibleRowHeightsToPaint(
            messages: messages,
            allowShrink: !readingHistory,
            allowTableUpdates: false
        ) {
            changed = true
        }
        if shrinkPaintedActionRowsAtRest(messages: messages) {
            changed = true
        }
        if debugVisibleRowClipCount() > 0 {
            repairVisibleAssistantRowClips(messages: messages)
            changed = true
        }
        if changed {
            remeasureRowsPreservingViewport(
                anchorPath: anchorPath,
                preferSavedViewportAnchor: fixedViewportY != nil,
                fixedViewportY: fixedViewportY
            )
        }
        repairTopViewportMidLineClip()
    }

    /// Collapse small post-action slack once body + 三大按钮 are painted and scrolling is at rest.
    @discardableResult
    private func shrinkPaintedActionRowsAtRest(messages: [ChatMessage]) -> Bool {
        guard !tableView.isDragging,
              !tableView.isDecelerating,
              !rowHeights.isScrollHeightFrozen else { return false }
        return shrinkInflatedVisibleRows(messages: messages, slackThreshold: 10)
    }

    /// When a row straddles the table top by less than ~one line, snap so the bar edge
    /// does not cut glyphs in half (looks like the turn-context bar "ate" the text).
    @discardableResult
    private func repairTopViewportMidLineClip() -> Bool {
        guard tableView.window != nil,
              !tableView.isDragging,
              !tableView.isDecelerating,
              !rowHeights.isScrollHeightFrozen else { return false }
        tableView.layoutIfNeeded()
        let topY = tableView.contentOffset.y
        let maxHalfLine = SettingsManager.shared.chatBodyFontSize + 4
        guard let paths = tableView.indexPathsForVisibleRows, !paths.isEmpty else { return false }
        for path in paths {
            let rowRect = tableView.rectForRow(at: path)
            guard rowRect.minY < topY + 0.5, rowRect.maxY > topY + 0.5 else { continue }
            let clipped = topY - rowRect.minY
            guard clipped > 6, clipped < maxHalfLine else { return false }
            let minOffset = -tableView.adjustedContentInset.top
            let maxOffset = max(
                minOffset,
                tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
            )
            let target = min(max(rowRect.minY, minOffset), maxOffset)
            guard abs(tableView.contentOffset.y - target) > 0.5 else { return false }
            UIView.performWithoutAnimation {
                tableView.contentOffset.y = target
            }
            return true
        }
        return false
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
        let rows = messages.indices.filter {
            messages[$0].role == .user && !messages[$0].shouldHideInTranscript
        }
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

    /// Long threads (12+ turns): lighter finger-down / scroll prewarm to avoid QA-edge hitch.
    private func isLongContextThread(messageCount: Int? = nil) -> Bool {
        let count = messageCount ?? ConversationStore.shared.currentConversation?.messages.count ?? 0
        return count >= 24
    }
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
                let syncCap = (isLongContextThread(messageCount: messages.count)
                    && hasCompletedFirstHistoryScrollGesture
                    && (tableView.isDragging || tableView.isDecelerating)) ? 1 : 2
                if syncTargets.count < syncCap {
                    syncTargets.append(assistant)
                }
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
                        if self.rowHeights.isScrollHeightFrozen
                            || self.tableView.isDragging
                            || self.tableView.isDecelerating {
                            self.rowHeights.recordDiskEstimate(columnHeight: column, messageID: next.id)
                        } else {
                            self.rowHeights.commitMeasured(columnHeight: column, messageID: next.id, allowShrink: true)
                        }
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
        openBottomStickActive = false
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
        openBottomPinWork?.cancel()
        openBottomPinWork = nil
        openIdleBackgroundWork?.cancel()
        openIdleBackgroundWork = nil
        idlePrewarmWork?.cancel()
        idlePrewarmWork = nil
        scrollSettleWork?.cancel()
        scrollFreezeGeometryWork?.cancel()
        scrollFreezeGeometryWork = nil
        scrollBeginPrepWork?.cancel()
        scrollBeginPrepWork = nil
        pendingFingerDownHeavyPrep = nil
        scrollSettleWork = nil
        lastHistoryEdgePinVisibleRows = []
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
        formulaRemeasureWork?.cancel()
        formulaRemeasureWork = nil
        widthInvalidateWork?.cancel()
        widthInvalidateWork = nil
        pendingReadingHistoryFormulaSync = false
        visibleNativeHydrationInProgress = false
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

    /// UITableView mutations are unsafe while the store selection differs from the rendered transcript.
    private func isTableLayoutCommitted() -> Bool {
        guard let rendered = renderedConversationID else { return false }
        return rendered == currentConversationID
    }

    private func renderedConversationMessages() -> [ChatMessage]? {
        guard isTableLayoutCommitted(),
              let id = renderedConversationID,
              let conv = ConversationStore.shared.conversation(id: id) else { return nil }
        return conv.messages
    }

    private func tableMatchesMessages(_ messages: [ChatMessage]) -> Bool {
        guard isTableLayoutCommitted(), tableView.window != nil else { return false }
        return tableView.numberOfRows(inSection: 0) == messages.count
    }

    /// Live generate / stream may pin before every guard in `tableMatchesMessages` is warm.
    private func canPinViewport(for messages: [ChatMessage]) -> Bool {
        guard tableView.window != nil, !messages.isEmpty else { return false }
        if tableMatchesMessages(messages) { return true }
        guard finishViewportLocked || isCurrentStreaming else { return false }
        return tableView.numberOfRows(inSection: 0) == messages.count
    }

    /// Visible bottom of the table viewport in table coordinates (input bar sits below).
    private func tableViewportVisibleBottomY() -> CGFloat {
        tableView.bounds.height - 6
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
        let tailReady = openID.flatMap { id in
            openMessages(for: id).map { openTailHasSubstantialPaint(in: $0) }
        } ?? false
        let settleDelay: TimeInterval = tailReady
            ? 0.06
            : (openTailLayoutIsWarm(for: openID) ? 0.05 : 0.15)
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
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
            if let messages = self.openMessages(for: openID),
               self.openTailHasSubstantialPaint(in: messages) {
                self.scheduleDeferredOpenSettle(
                    generation: gen,
                    openID: openID,
                    layoutWidth: self.currentRenderWidth()
                )
                return
            }
            self.scheduleOpenTailPaint(generation: gen)
        }
        openCoalesceWork = work
        if openTailLayoutIsWarm(for: openID) {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.switchCoalesceDelay, execute: work)
        }
    }

    private func openTailLayoutIsWarm(for openID: String?) -> Bool {
        guard let openID = openID,
              let messages = ConversationStore.shared.conversation(id: openID)?.messages,
              let tailID = tailAssistantMessageID(in: messages),
              let tail = messages.first(where: { $0.id == tailID }) else {
            return false
        }
        return AssistantMessageLayout.hasCachedNativeLayout(
            for: tail,
            layoutWidth: currentRenderWidth()
        )
    }

    private func openTailHasSubstantialPaint(in messages: [ChatMessage]) -> Bool {
        guard tableMatchesMessages(messages),
              let tailID = tailAssistantMessageID(in: messages),
              let row = messages.firstIndex(where: { $0.id == tailID }),
              row < tableView.numberOfRows(inSection: 0),
              let tail = messages.first(where: { $0.id == tailID }),
              let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? AssistantMessageCell else {
            return false
        }
        return cell.hasSubstantialOpenBodyPaint(for: tail)
    }

    /// True only while the open critical path holds the viewport (alpha=0 finalize).
    /// `openBottomStickActive` is separate — it re-pins without blocking scroll or sidebar.
    private func isOpenPresentationActive() -> Bool {
        pendingOpenAtBottom || suppressHeightRemeasure
    }

    private func releaseOpenInteractionLock() {
        pendingOpenAtBottom = false
        suppressHeightRemeasure = false
    }

    /// Nudge scroll so tail action chrome sits above the input bar (not underneath it).
    private func nudgeViewportToClearTailActionChrome(messages: [ChatMessage]) {
        guard let tailID = tailAssistantMessageID(in: messages),
              let row = messages.firstIndex(where: { $0.id == tailID }),
              row < tableView.numberOfRows(inSection: 0),
              let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? AssistantMessageCell,
              cell.hasVisibleActionButtons,
              let actionTop = cell.debugActionRowViewportY(in: tableView) else { return }
        let visibleBottom = tableViewportVisibleBottomY()
        let chromeBottom = actionTop + AssistantMessageLayout.actionRowHeight
        if chromeBottom > visibleBottom {
            let inset = tableView.adjustedContentInset
            let minY = -inset.top
            let maxY = max(
                minY,
                tableView.contentSize.height + inset.bottom - tableView.bounds.height
            )
            var targetY = tableView.contentOffset.y + chromeBottom - visibleBottom
            targetY = min(max(targetY, minY), max(maxY, targetY))
            if abs(tableView.contentOffset.y - targetY) > 0.5 {
                tableView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            }
        }
    }

    /// Seed row-height map so the first reload can scroll to the true bottom (not mid-thread).
    private func seedOpenBottomViewportHeights(messages: [ChatMessage], layoutWidth: CGFloat) {
        guard !messages.isEmpty else { return }
        let tailStart = max(0, messages.count - Self.openBottomSeedTailRows)
        for row in tailStart..<messages.count {
            let msg = messages[row]
            guard !msg.isStreaming else { continue }
            if rowHeights.isCommitted(msg.id) { continue }
            let known = rowHeights.bestKnownColumnHeight(for: msg.id)
            if known > 40 { continue }
            if msg.role == .user,
               let column = ChatRowHeightResolver.estimatedUserColumnContentHeight(
                   for: msg,
                   layoutWidth: layoutWidth
               ), column > 40 {
                rowHeights.updateDisplayEstimate(columnHeight: column, messageID: msg.id)
                continue
            }
            let cheap = ChatRowHeightResolver.cheapColumnEstimate(for: msg, layoutWidth: layoutWidth)
            let floor = max(cheap, msg.role == .assistant ? 80 : 52)
            rowHeights.updateDisplayEstimate(columnHeight: floor, messageID: msg.id)
        }
        let tailSlice = Array(messages[tailStart...])
        let tailH = tailSlice.enumerated().reduce(into: CGFloat(0)) { sum, item in
            let row = tailStart + item.offset
            sum += rowHeights.rowHeight(
                for: item.element,
                row: row,
                messageCount: messages.count,
                layoutWidth: layoutWidth
            )
        }
        let minTailPlausible = max(tableView.bounds.height * 0.55, CGFloat(tailSlice.count) * 60)
        guard tailH < minTailPlausible else {
            if let tailID = tailAssistantMessageID(in: messages),
               let tail = messages.first(where: { $0.id == tailID }) {
                let slack = AssistantMessageLayout.actionRowReservedHeight + 8
                let prior = rowHeights.bestKnownColumnHeight(for: tailID)
                rowHeights.updateDisplayEstimate(columnHeight: prior + slack, messageID: tail.id)
            }
            return
        }
        for row in tailStart..<messages.count {
            let msg = messages[row]
            guard !msg.isStreaming else { continue }
            let cheap = ChatRowHeightResolver.cheapColumnEstimate(for: msg, layoutWidth: layoutWidth)
            let inflated = max(
                cheap * 1.18,
                rowHeights.bestKnownColumnHeight(for: msg.id),
                msg.role == .assistant ? 96 : 56
            )
            rowHeights.updateDisplayEstimate(columnHeight: inflated, messageID: msg.id)
        }
        if let tailID = tailAssistantMessageID(in: messages),
           let tail = messages.first(where: { $0.id == tailID }) {
            let slack = AssistantMessageLayout.actionRowReservedHeight + 8
            let prior = rowHeights.bestKnownColumnHeight(for: tailID)
            rowHeights.updateDisplayEstimate(columnHeight: prior + slack, messageID: tail.id)
        }
    }

    private func resolvedScrollOffsetYToBottom(_ messages: [ChatMessage], layoutWidth: CGFloat) -> CGFloat {
        let inset = tableView.adjustedContentInset
        return rowHeights.scrollOffsetYToBottom(
            messages: messages,
            layoutWidth: layoutWidth,
            contentInsetTop: inset.top,
            contentInsetBottom: inset.bottom,
            viewportHeight: max(tableView.bounds.height, 1)
        )
    }

    /// Pin viewport to the latest turn: sync tail paint → relayout → max(contentSize, tail rect).
    private func pinOpenViewportToBottom(_ messages: [ChatMessage], layoutWidth: CGFloat? = nil) {
        guard canPinViewport(for: messages), tableView.bounds.height > 1 else { return }
        let width = layoutWidth ?? currentRenderWidth()
        stickToBottom = true
        readingHistory = false
        viewportPinnedByUser = false
        syncLiveTailRowGeometry(messages: messages)
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()
        }
        applyViewportOffsetPinningToLiveTail(messages: messages, layoutWidth: width)
        nudgeViewportToClearTailActionChrome(messages: messages)
    }

    /// Offset so the last row's bottom sits at the table viewport bottom.
    private func applyViewportOffsetPinningToLiveTail(messages: [ChatMessage], layoutWidth: CGFloat) {
        let inset = tableView.adjustedContentInset
        let viewportH = tableView.bounds.height
        let minY = -inset.top
        var targetY = max(minY, tableView.contentSize.height + inset.bottom - viewportH)
        if let lastRow = messages.indices.last,
           lastRow < tableView.numberOfRows(inSection: 0) {
            let cellBottom = tableView.rectForRow(at: IndexPath(row: lastRow, section: 0)).maxY
            if cellBottom > 1 {
                targetY = max(targetY, cellBottom - viewportH + inset.bottom)
            }
        }
        let resolverY = resolvedScrollOffsetYToBottom(messages, layoutWidth: layoutWidth)
        targetY = max(targetY, resolverY)
        let scrollMaxY = max(targetY, tableView.contentSize.height + inset.bottom - viewportH)
        targetY = min(max(targetY, minY), scrollMaxY)
        if abs(tableView.contentOffset.y - targetY) > 0.5 {
            tableView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        }
    }

    /// Commit visible tail row paint before UITableView measures contentSize.
    private func syncLiveTailRowGeometry(messages: [ChatMessage]) {
        guard let last = messages.last else { return }
        let path = IndexPath(row: messages.count - 1, section: 0)
        if last.isStreaming {
            syncStreamingTailPaint(messages: messages)
            return
        }
        guard let cell = tableView.cellForRow(at: path) as? AssistantMessageCell,
              cell.messageID == last.id else { return }
        _ = cell.syncNativeBodyHeightToLayout()
        let fitted = max(cell.fittedColumnContentHeight(), cell.measuredContentHeight())
        if fitted > 40 {
            rowHeights.commitMeasured(
                columnHeight: fitted,
                messageID: last.id,
                allowShrink: shouldClampCommittedHeightToPaint(for: last)
            )
        }
    }

    /// Finished reply: grow tail row, pin, reveal action chrome (post-stream / native layout).
    private func pinFinishedTailViewport(messages: [ChatMessage],
                                         layoutWidth: CGFloat? = nil,
                                         unlockScroll: Bool = false) {
        guard canPinViewport(for: messages) else {
            if unlockScroll { unlockScrollAfterFinishPin() }
            return
        }
        let width = layoutWidth ?? currentRenderWidth()
        stickToBottom = true
        readingHistory = false
        viewportPinnedByUser = false
        UIView.performWithoutAnimation {
            syncLiveTailRowGeometry(messages: messages)
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()
            applyViewportOffsetPinningToLiveTail(messages: messages, layoutWidth: width)
            finalizeOpenBottomViewport(messages: messages, layoutWidth: width)
        }
        if unlockScroll {
            unlockScrollAfterFinishPin()
        }
    }
    private func tailActionChromeOverlapsInputBar(messages: [ChatMessage]) -> Bool {
        guard tableMatchesMessages(messages),
              let tailID = tailAssistantMessageID(in: messages),
              let row = messages.firstIndex(where: { $0.id == tailID }),
              row < tableView.numberOfRows(inSection: 0),
              let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? AssistantMessageCell,
              cell.hasVisibleActionButtons,
              let actionTop = cell.debugActionRowViewportY(in: tableView) else { return false }
        let inputTop = tableViewportVisibleBottomY()
        let chromeBottom = actionTop + AssistantMessageLayout.actionRowHeight
        return chromeBottom > inputTop
    }

    /// Grow tail row + pin until action chrome clears the input bar — runs while alpha is still 0.
    private func finalizeOpenBottomViewport(messages: [ChatMessage], layoutWidth: CGFloat) {
        guard tableMatchesMessages(messages) else { return }
        let passes = openTailLayoutIsWarm(for: renderedConversationID) ? 1 : 2
        for _ in 0..<passes {
            guard tableMatchesMessages(messages) else { return }
            showOpenTailActionChromeIfAligned(messages: messages, layoutWidth: layoutWidth)
            if let tailID = tailAssistantMessageID(in: messages),
               let tail = messages.first(where: { $0.id == tailID }),
               let row = messages.firstIndex(where: { $0.id == tailID }),
               row < tableView.numberOfRows(inSection: 0),
               let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? AssistantMessageCell {
                let measured = cell.measuredContentHeight()
                if measured > 40 {
                    rowHeights.commitMeasured(columnHeight: measured, messageID: tail.id, allowShrink: true)
                }
            }
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
            tableView.layoutIfNeeded()
            pinOpenViewportToBottom(messages, layoutWidth: layoutWidth)
            if !tailActionChromeOverlapsInputBar(messages: messages) { break }
        }
    }

    /// Shared bottom pin + tail action chrome — study width/orientation changes use the same path as chat open.
    private func reconcileBottomViewportIfNeeded(messages: [ChatMessage], layoutWidth: CGFloat) {
        guard tableMatchesMessages(messages), stickToBottom, !isViewportPinned() else { return }
        UIView.performWithoutAnimation {
            pinOpenViewportToBottom(messages, layoutWidth: layoutWidth)
            finalizeOpenBottomViewport(messages: messages, layoutWidth: layoutWidth)
        }
    }

    private func scheduleOpenBottomPin(messages: [ChatMessage]) {
        guard openBottomStickActive else { return }
        guard stickToBottom, !isViewportPinned() else { return }
        let now = CACurrentMediaTime()
        guard now - lastOpenBottomPinTime > 0.048 else { return }
        lastOpenBottomPinTime = now
        openBottomPinWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.openBottomStickActive,
                  self.stickToBottom, !self.isViewportPinned(),
                  let live = self.openMessages(for: self.renderedConversationID) else { return }
            self.pinOpenViewportToBottom(live, layoutWidth: self.currentRenderWidth())
        }
        openBottomPinWork = work
        DispatchQueue.main.async(execute: work)
    }

    /// Seed tail row height from layout cache only — never sync-layout on the switch hot path.
    private func seedTailOpenLayoutFromCache(messages: [ChatMessage], layoutWidth: CGFloat) {
        guard let tailID = tailAssistantMessageID(in: messages),
              let row = messages.firstIndex(where: { $0.id == tailID }) else { return }
        let tail = messages[row]
        guard AssistantMessageLayout.hasCachedNativeLayout(for: tail, layoutWidth: layoutWidth),
              let column = AssistantMessageLayout.estimatedColumnContentHeight(
                  for: tail,
                  layoutWidth: layoutWidth,
                  isLastRow: row == messages.count - 1,
                  allowSyncLayout: false
              ), column > 40 else { return }
        rowHeights.commitMeasured(columnHeight: column, messageID: tail.id, allowShrink: false)
        rowHeights.updateDisplayEstimate(columnHeight: column, messageID: tail.id)
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
        if cell.hasSubstantialOpenBodyPaint(for: tail) {
            _ = cell.ensureActionButtonsVisible(for: tail, requireBodyAlignment: true)
            _ = syncRowHeightToPaint(cell: cell, message: tail, allowShrink: true)
        }
        return cell.hasSubstantialOpenBodyPaint(for: tail)
    }

    /// Force action buttons into layout and grow UITableView rows so they aren't clipped.
    /// Must run on the open critical path (not deferred to settle).
    private func showVisibleActionChrome(messages: [ChatMessage], requireBodyAlignment: Bool = false) {
        tableView.layoutIfNeeded()
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let msg = messages.first(where: { $0.id == cell.messageID }),
                  msg.role == .assistant,
                  !msg.isStreaming else { continue }
            cell.ensureActionButtonsVisible(for: msg, requireBodyAlignment: requireBodyAlignment)
        }
        _ = syncVisibleRowHeightsToPaint(messages: messages, allowShrink: true)
    }

    private func showOpenTailActionChromeIfAligned(messages: [ChatMessage], layoutWidth: CGFloat) {
        guard let tailID = tailAssistantMessageID(in: messages),
              let row = messages.firstIndex(where: { $0.id == tailID }),
              row < tableView.numberOfRows(inSection: 0),
              let tail = messages.first(where: { $0.id == tailID }),
              let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? AssistantMessageCell else {
            return
        }
        guard cell.hasSubstantialOpenBodyPaint(for: tail) else { return }
        guard cell.ensureActionButtonsVisible(for: tail, requireBodyAlignment: true) else { return }
        _ = syncRowHeightToPaint(cell: cell, message: tail, allowShrink: true)
    }

    /// First-open rows: sync-layout probe before UITableView allocates the row frame.
    private func pregrowFrozenAssistantRowIfNeeded(for message: ChatMessage,
                                                   row: Int,
                                                   messageCount: Int,
                                                   layoutWidth: CGFloat) {
        guard rowHeights.isScrollHeightFrozen,
              message.role == .assistant,
              !message.isStreaming,
              !rowHeights.isCommitted(message.id) else { return }
        let column = AssistantMessageLayout.estimatedColumnContentHeight(
            for: message,
            layoutWidth: layoutWidth,
            isLastRow: row == messageCount - 1,
            allowSyncLayout: false
        ) ?? AssistantMessageLayout.plainFallbackColumnContentHeight(
            for: message,
            layoutWidth: layoutWidth
        )
        guard let column, column > 40 else { return }
        _ = rowHeights.growFrozenRowHeightIfNeeded(messageID: message.id, columnHeight: column)
    }

    /// Grow frozen row map from layout cache — safe mid-scroll (no beginUpdates).
    @discardableResult
    private func seedFrozenRowHeightsFromCache(messages: [ChatMessage],
                                               layoutWidth: CGFloat,
                                               rows: [Int]) -> Bool {
        guard rowHeights.isScrollHeightFrozen else { return false }
        let count = messages.count
        var changed = false
        for row in rows {
            guard row >= 0, row < count else { continue }
            let msg = messages[row]
            guard msg.role == .assistant, !msg.isStreaming else { continue }
            guard let column = AssistantMessageLayout.estimatedColumnContentHeight(
                for: msg,
                layoutWidth: layoutWidth,
                isLastRow: row == count - 1,
                allowSyncLayout: false
            ), column > 40 else { continue }
            if rowHeights.growFrozenRowHeightIfNeeded(messageID: msg.id, columnHeight: column) {
                changed = true
            }
        }
        return changed
    }

    /// Finger-down sync pin: height map only — no chrome paint or cell measurement.
    private func pinVisibleFrozenRowsFromHeightMap(messages: [ChatMessage]) {
        guard rowHeights.isScrollHeightFrozen else { return }
        var pinnedIDs = Set<String>()
        for case let cell as MessageCellType in tableView.visibleCells {
            guard let msg = messages.first(where: { $0.id == cell.messageID }),
                  !msg.isStreaming else { continue }
            let known = rowHeights.bestKnownColumnHeight(for: msg.id)
            guard known > 40 else { continue }
            rowHeights.pinFrozenRowHeight(messageID: msg.id, columnHeight: known)
            pinnedIDs.insert(msg.id)
        }
        rowHeights.setGesturePinnedFrozenMessages(pinnedIDs)
    }

    /// Freeze visible (±pad) rows to live UITableView geometry — avoids press→teleport.
    private func beginScrollHeightFreezeMatchingTable(messages: [ChatMessage],
                                                      rows: [Int],
                                                      layoutWidth: CGFloat) {
        let margin = ChatRowHeightResolver.cellVerticalMargin
        var heights: [String: CGFloat] = [:]
        heights.reserveCapacity(rows.count)
        let count = messages.count
        for row in rows where row >= 0 && row < count {
            let msg = messages[row]
            let path = IndexPath(row: row, section: 0)
            let tableH = tableView.rectForRow(at: path).height
            if tableH > 40 {
                heights[msg.id] = tableH
            } else {
                let known = rowHeights.bestKnownColumnHeight(for: msg.id)
                heights[msg.id] = known > 40
                    ? known + margin
                    : rowHeights.rowHeight(
                        for: msg,
                        row: row,
                        messageCount: count,
                        layoutWidth: layoutWidth
                    )
            }
        }
        rowHeights.beginScrollHeightFreeze(
            preservingRowHeights: heights,
            deferLiveFrozenMapUpdates: true
        )
        // Pin gesture IDs without rewriting heights (already match the table).
        rowHeights.setGesturePinnedFrozenMessages(Set(heights.keys))
    }

    /// Additive freeze expand only — never replace the live frozen map mid-drag.
    private func expandFrozenScrollRowsIfNeeded(messages: [ChatMessage],
                                                rows: [Int],
                                                layoutWidth: CGFloat) {
        guard rowHeights.isScrollHeightFrozen else { return }
        let count = messages.count
        for row in rows where row >= 0 && row < count {
            let msg = messages[row]
            guard !msg.isStreaming else { continue }
            rowHeights.freezeRowHeightIfNeeded(
                for: msg,
                row: row,
                messageCount: count,
                layoutWidth: layoutWidth
            )
        }
    }

    /// Study / first-history prep that must not run while the finger is down.
    private func runPendingFingerDownHeavyPrepIfNeeded() {
        guard let pending = pendingFingerDownHeavyPrep else { return }
        pendingFingerDownHeavyPrep = nil
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              !messages.isEmpty else { return }
        let layoutWidth = currentRenderWidth()
        if pending.study {
            prepareStudyNarrowTailFromOpen(messages: messages, layoutWidth: layoutWidth)
            lightweightFingerDownHistoryPrep(messages: messages, layoutWidth: layoutWidth)
        } else if pending.light {
            lightweightFingerDownHistoryPrep(messages: messages, layoutWidth: layoutWidth)
        }
    }

    /// Visible rows keep painted geometry when a scroll gesture begins.
    private func pinVisibleFrozenRowsForScrollFreeze(messages: [ChatMessage]) {
        guard rowHeights.isScrollHeightFrozen else { return }
        let layoutWidth = currentRenderWidth()
        var pinnedIDs = Set<String>()
        for case let cell as MessageCellType in tableView.visibleCells {
            guard let msg = messages.first(where: { $0.id == cell.messageID }),
                  !msg.isStreaming else { continue }
            if let assistant = cell as? AssistantMessageCell, msg.role == .assistant {
                // Avoid layoutIfNeeded here — it stalls the first drag frames.
                assistant.showCommittedActionIconsDuringScroll(for: msg)
            }
            let columnH: CGFloat
            if let assistant = cell as? AssistantMessageCell, msg.role == .assistant {
                columnH = frozenScrollColumnHeight(
                    for: assistant,
                    message: msg,
                    layoutWidth: layoutWidth
                )
            } else {
                let known = rowHeights.bestKnownColumnHeight(for: msg.id)
                columnH = known > 40 ? known : cell.measuredContentHeight()
            }
            guard columnH > 40 else { continue }
            rowHeights.pinFrozenRowHeight(messageID: msg.id, columnHeight: columnH)
            pinnedIDs.insert(msg.id)
        }
        rowHeights.setGesturePinnedFrozenMessages(pinnedIDs)
    }

    /// Pin painted geometry for a visible row during a frozen history gesture.
    private func pinFrozenHistoryRowFromCell(_ cell: MessageCellType, message: ChatMessage) {
        guard rowHeights.isScrollHeightFrozen, !message.isStreaming else { return }
        let layoutWidth = currentRenderWidth()
        let columnH: CGFloat
        if let assistant = cell as? AssistantMessageCell, message.role == .assistant {
            columnH = frozenScrollColumnHeight(for: assistant, message: message, layoutWidth: layoutWidth)
        } else {
            let known = rowHeights.bestKnownColumnHeight(for: message.id)
            columnH = known > 40 ? known : cell.measuredContentHeight()
        }
        guard columnH > 40 else { return }
        rowHeights.pinFrozenRowHeight(messageID: message.id, columnHeight: columnH)
        rowHeights.addGesturePinnedFrozenMessages([message.id])
    }

    /// Rows straddling the viewport edge — pin so deferred grows cannot snap them on release.
    private func refreshHistoryEdgePinnedRows() {
        guard readingHistory,
              rowHeights.isScrollHeightFrozen,
              let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let edge = debugVisibleQAEdgeState(edgeBand: 44)
        let edgeRows = Set(
            edge.userRowsAtTopEdge + edge.userRowsAtBottomEdge + edge.assistantRowsNearUserEdge
        )
        guard !edgeRows.isEmpty else { return }
        var pinIDs = Set<String>()
        for row in edgeRows where row >= 0 && row < messages.count {
            let msg = messages[row]
            guard !msg.isStreaming else { continue }
            pinIDs.insert(msg.id)
            let path = IndexPath(row: row, section: 0)
            guard let cell = tableView.cellForRow(at: path) as? MessageCellType else { continue }
            pinFrozenHistoryRowFromCell(cell, message: msg)
        }
        rowHeights.addGesturePinnedFrozenMessages(pinIDs)
    }

    /// Prefer the bubble whose top kisses the viewport top — release jump hotspot.
    private func historyEdgeSettleAnchor() -> (row: Int, viewportY: CGFloat)? {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return nil }
        let topInset = tableView.adjustedContentInset.top
        let band: CGFloat = 56
        var best: (row: Int, viewportY: CGFloat)?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for path in tableView.indexPathsForVisibleRows ?? [] {
            guard path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard !msg.isStreaming else { continue }
            let frame = tableView.rectForRow(at: path)
            let minY = frame.minY - tableView.contentOffset.y
            let maxY = frame.maxY - tableView.contentOffset.y
            let score: CGFloat
            switch msg.role {
            case .assistant:
                let topDist = abs(minY - topInset)
                guard topDist < band || (minY < topInset + band && maxY > topInset) else { continue }
                score = topDist
            case .user:
                let topDist = abs(minY - topInset)
                guard topDist < band || (minY < topInset + band && maxY > topInset) else { continue }
                score = topDist + 6
            default:
                continue
            }
            if score < bestScore {
                bestScore = score
                best = (path.row, minY)
            }
        }
        return best
    }

    private func pinAllVisibleFrozenRowsAtHistorySettle(messages: [ChatMessage]) {
        guard rowHeights.isScrollHeightFrozen else { return }
        for case let cell as MessageCellType in tableView.visibleCells {
            guard let msg = messages.first(where: { $0.id == cell.messageID }),
                  !msg.isStreaming else { continue }
            pinFrozenHistoryRowFromCell(cell, message: msg)
        }
    }

    /// Mid-scroll height: keep committed floor on revisit; cold rows still bump with projected.
    private func frozenScrollColumnHeight(for cell: AssistantMessageCell,
                                          message: ChatMessage,
                                          layoutWidth: CGFloat) -> CGFloat {
        let measured = cell.measuredContentHeight()
        let committed = rowHeights.committedColumnHeight(for: message.id) ?? 0
        if cell.hasVisibleBodyPaint {
            return committed > 40 ? max(measured, committed) : measured
        }
        let projected = cell.projectedColumnHeight(for: message, layoutWidth: layoutWidth)
        return max(measured, committed > 40 ? committed : 0, projected)
    }

    /// Grow frozen map before UITableView lays out an incoming assistant row (cache read only — no sync layout).
    private func primeFrozenAssistantHeight(for message: ChatMessage,
                                            row: Int,
                                            messageCount: Int,
                                            layoutWidth: CGFloat,
                                            cell: AssistantMessageCell? = nil,
                                            messages: [ChatMessage]? = nil) {
        guard rowHeights.isScrollHeightFrozen,
              message.role == .assistant,
              !message.isStreaming else { return }
        rowHeights.freezeRowHeightIfNeeded(
            for: message,
            row: row,
            messageCount: messageCount,
            layoutWidth: layoutWidth
        )
        if readingHistory {
            // Do not shrink the frozen map mid-fling (Study + code cards). Finger-down
            // prep already collapsed inflated rows; settle shrinks with viewport preserve.
            return
        }
        if let committed = rowHeights.committedColumnHeight(for: message.id), committed > 40 {
            if rowHeights.growFrozenRowHeightIfNeeded(messageID: message.id, columnHeight: committed) {
                scheduleFrozenAssistantGeometrySync()
            }
            return
        }
        let thread = messages ?? ConversationStore.shared.currentConversation?.messages ?? []
        let pairedUser = pairedUserMessage(forAssistantAt: row, in: thread)
        let allowSync = AssistantMessageLayout.hasCachedNativeLayout(
            for: message,
            layoutWidth: layoutWidth
        )
        guard let column = AssistantMessageLayout.estimatedColumnContentHeight(
            for: message,
            layoutWidth: layoutWidth,
            isLastRow: row == messageCount - 1,
            allowSyncLayout: allowSync,
            pairedUser: pairedUser
        ), column > 40 else { return }
        if rowHeights.growFrozenRowHeightIfNeeded(messageID: message.id, columnHeight: column) {
            scheduleFrozenAssistantGeometrySync()
        }
        _ = cell
    }

    /// Paint deferred action icons after row height catches up (scroll-freeze path).
    private func revealDeferredActionChromeOnVisibleAssistants(messages: [ChatMessage]) {
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard msg.role == .assistant, !msg.isStreaming else { continue }
            if cell.hasVisibleActionButtons { continue }
            if cell.hasVisibleBodyPaint {
                cell.showCommittedActionIconsDuringScroll(for: msg)
                if !cell.hasVisibleActionButtons {
                    cell.revealActionChromeIfBodyPainted(for: msg)
                }
            }
        }
    }

    /// After scroll unfreeze: paint reserved action icons on visible assistants.
    private func paintVisibleActionChromeAfterScrollUnfreeze(messages: [ChatMessage]) {
        guard !rowHeights.isScrollHeightFrozen else { return }
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let msg = messages.first(where: { $0.id == cell.messageID }),
                  msg.role == .assistant,
                  !msg.isStreaming else { continue }
            if readingHistory {
                // History: paint-only — ensureActionButtonsVisible runs syncNativeBodyHeightToLayout
                // + syncRowHeightToPaint and shifts the viewport on the release frame.
                cell.showCommittedActionIconsDuringScroll(for: msg)
                if !cell.hasVisibleActionButtons {
                    _ = cell.revealReservedActionChromeIfRoom(for: msg)
                }
                continue
            }
            if !cell.hasVisibleActionButtons {
                cell.showCommittedActionIconsDuringScroll(for: msg)
            }
            if cell.hasVisibleActionButtons { continue }
            _ = cell.ensureActionButtonsVisible(for: msg)
        }
    }

    /// Grow frozen/display row heights for visible assistants before async settle (avoids button clip flash).
    private func presettleVisibleAssistantRows() {
        guard rowHeights.isScrollHeightFrozen,
              let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let layoutWidth = currentRenderWidth()
        var changed = false
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard msg.role == .assistant, !msg.isStreaming else { continue }
            cell.contentView.layoutIfNeeded()
            let measured = cell.measuredContentHeight()
            let projected = cell.projectedColumnHeight(for: msg, layoutWidth: layoutWidth)
            let columnH = max(measured, projected)
            guard columnH > 40 else { continue }
            let rowFrame = tableView.rectForRow(at: path)
            let required = columnH + ChatRowHeightResolver.cellVerticalMargin
            guard required > rowFrame.height + 2 else { continue }
            if rowHeights.growFrozenRowHeightIfNeeded(messageID: msg.id, columnHeight: columnH) {
                changed = true
            }
        }
        guard changed else { return }
        applyFrozenRelayoutPreservingLockedAnchor()
    }

    /// Single beginUpdates + offset fix using the gesture-locked anchor row.
    private func applyFrozenRelayoutPreservingLockedAnchor() {
        guard rowHeights.isScrollHeightFrozen else { return }
        // History: mid-gesture relayout near a bubble wiggles the viewport — settle once at rest.
        guard !readingHistory else { return }
        guard let anchor = lockedScrollViewportAnchor() else { return }
        let viewportY = anchor.viewportY
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()
            let target = tableView.rectForRow(at: anchor.path).minY - viewportY
            let minOffset = -tableView.adjustedContentInset.top
            let maxOffset = max(
                minOffset,
                tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
            )
            tableView.contentOffset.y = min(max(target, minOffset), maxOffset)
            viewportScrollAnchor = (anchor.path.row, viewportY)
            pendingScrollSettleAnchor = (anchor.path, viewportY)
        }
    }

    /// Coalesce study-panel frozen-height shrinks into one anchor-preserving remeasure per scroll frame.
    private func scheduleStudyFrozenShrinkRemeasure() {
        guard usesStudyHeightBucketPolicy(), readingHistory else { return }
        guard rowHeights.isScrollHeightFrozen else { return }
        guard studyFrozenShrinkRemeasureWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.studyFrozenShrinkRemeasureWork = nil
            guard self.rowHeights.isScrollHeightFrozen,
                  self.tableView.isDragging || self.tableView.isDecelerating else { return }
            let anchor: (IndexPath, CGFloat)?
            if let stored = self.pendingScrollSettleAnchor {
                anchor = stored
            } else if let captured = self.captureViewportScrollAnchor() {
                anchor = (IndexPath(row: captured.0, section: 0), captured.1)
            } else {
                anchor = nil
            }
            UIView.performWithoutAnimation {
                self.tableView.beginUpdates()
                self.tableView.endUpdates()
                if let anchor {
                    self.remeasureRowsPreservingViewport(
                        anchorPath: anchor.0,
                        preferSavedViewportAnchor: true,
                        fixedViewportY: anchor.1
                    )
                }
            }
        }
        studyFrozenShrinkRemeasureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.032, execute: work)
    }

    /// Grow frozen rows while the finger is down — Air 1–slow scroll exposes clip if we only fix at gesture end.
    private func scheduleFrozenAssistantGeometrySync() {
        // Mid-scroll geometry sync + beginUpdates causes whole-page hitch on fence-dense threads.
        // Queued grows apply in performScrollHeightSettling / finalizeFrozenHistoryScrollSettle.
        guard rowHeights.isScrollHeightFrozen else { return }
        guard !tableView.isDragging, !tableView.isDecelerating else { return }
        guard !readingHistory else { return }
        guard scrollFreezeGeometryWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.scrollFreezeGeometryWork = nil
            self.syncVisibleFrozenAssistantGeometryDuringScroll()
        }
        scrollFreezeGeometryWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func syncVisibleFrozenAssistantGeometryDuringScroll() {
        guard rowHeights.isScrollHeightFrozen,
              !isSyncingFrozenAssistantGeometry,
              let messages = ConversationStore.shared.currentConversation?.messages else { return }
        isSyncingFrozenAssistantGeometry = true
        defer { isSyncingFrozenAssistantGeometry = false }
        let layoutWidth = currentRenderWidth()
        var changed = false
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard msg.role == .assistant, !msg.isStreaming else { continue }
            let columnH: CGFloat
            if readingHistory {
                if cell.hasVisibleBodyPaint {
                    columnH = frozenScrollColumnHeight(for: cell, message: msg, layoutWidth: layoutWidth)
                } else if let committed = rowHeights.committedColumnHeight(for: msg.id), committed > 40 {
                    columnH = committed
                } else if let est = AssistantMessageLayout.estimatedColumnContentHeight(
                    for: msg,
                    layoutWidth: layoutWidth,
                    isLastRow: path.row == messages.count - 1,
                    allowSyncLayout: AssistantMessageLayout.hasCachedNativeLayout(
                        for: msg,
                        layoutWidth: layoutWidth
                    ),
                    pairedUser: pairedUserMessage(forAssistantAt: path.row, in: messages)
                ), est > 40 {
                    columnH = est
                } else {
                    continue
                }
            } else {
                cell.contentView.layoutIfNeeded()
                columnH = frozenScrollColumnHeight(
                    for: cell,
                    message: msg,
                    layoutWidth: layoutWidth
                )
            }
            guard columnH > 40 else { continue }
            if rowHeights.growFrozenRowHeightIfNeeded(messageID: msg.id, columnHeight: columnH) {
                changed = true
            }
            // Mid-scroll Study shrink removed — it remeasures during fling and jumps the viewport.
            // Inflated slack is handled at finger-down prep and history settle.
        }
        if changed, readingHistory { return }
        // Avoid per-frame chrome refresh — it hitchs when crossing short QA turns.
        let paths = (tableView.indexPathsForVisibleRows ?? []).filter { path in
            path.row < messages.count && messages[path.row].role == .assistant
        }
        if changed, !paths.isEmpty {
            // Only relayout mid-scroll for meaningful growth — micro grows cause QA-edge hitch/jump.
            let slackThreshold: CGFloat = readingHistory ? 24 : 12
            let significant = paths.contains { path in
                guard path.row < messages.count else { return false }
                let msg = messages[path.row]
                let known = rowHeights.bestKnownColumnHeight(for: msg.id)
                let frame = tableView.rectForRow(at: path).height
                return abs(known + ChatRowHeightResolver.cellVerticalMargin - frame) > slackThreshold
            }
            guard significant else { return }
            if readingHistory {
                return
            } else {
                #if DEBUG
                ChatHeavyScrollDiagnostics.midScrollBeginUpdates += 1
                #endif
                UIView.performWithoutAnimation {
                    tableView.beginUpdates()
                    tableView.endUpdates()
                    tableView.layoutIfNeeded()
                }
            }
        }
    }

    private func revealActionChromeIfBodyPainted(messages: [ChatMessage]) {
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            cell.revealActionChromeIfBodyPainted(for: messages[path.row])
        }
    }

    private func setVisibleNativeScrollRasterization(_ enabled: Bool) {
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            cell.setNativeScrollRasterization(enabled)
            if !enabled {
                cell.pinActionRowBelowColumnForScrollFreeze(false)
            }
        }
    }

    /// Rows whose heights must be true before the first history scroll freeze.
    private func firstHistoryScrollPrepRows(in messages: [ChatMessage]) -> [Int] {
        let visible = tableView.indexPathsForVisibleRows?.map(\.row) ?? []
        guard !visible.isEmpty else { return Array(0..<messages.count) }
        let minVisible = visible.min() ?? 0
        let maxVisible = visible.max() ?? minVisible
        let tailPad = Self.turnPrewarmCount * 2 + 4
        var rows = Set<Int>()
        if minVisible > 0 {
            rows.formUnion(0..<minVisible)
        }
        rows.formUnion(visible)
        let tailStart = max(0, maxVisible - tailPad)
        if tailStart < messages.count {
            rows.formUnion(tailStart..<messages.count)
        }
        return rows.filter { $0 >= 0 && $0 < messages.count }.sorted()
    }

    /// Collapse committed heights that dwarf layout-cache estimates (off-screen inflated rows).
    @discardableResult
    private func shrinkInflatedCommittedRows(messages: [ChatMessage],
                                             rows: [Int],
                                             layoutWidth: CGFloat,
                                             slackThreshold: CGFloat? = nil) -> Bool {
        let threshold = slackThreshold ?? (isStudyNarrowPanelActive() ? 12 : 24)
        var changed = false
        let count = messages.count
        for row in rows {
            guard row >= 0, row < count else { continue }
            let msg = messages[row]
            guard !msg.isStreaming else { continue }
            let known = rowHeights.bestKnownColumnHeight(for: msg.id)
            guard known > 40 else { continue }
            let estimated: CGFloat?
            if msg.role == .user {
                estimated = ChatRowHeightResolver.estimatedUserColumnContentHeight(
                    for: msg,
                    layoutWidth: layoutWidth
                )
            } else if msg.role == .assistant {
                let allowSync = AssistantMessageLayout.hasCachedNativeLayout(
                    for: msg,
                    layoutWidth: layoutWidth
                )
                estimated = AssistantMessageLayout.estimatedColumnContentHeight(
                    for: msg,
                    layoutWidth: layoutWidth,
                    isLastRow: row == count - 1,
                    allowSyncLayout: allowSync
                )
            } else {
                continue
            }
            guard let est = estimated, est > 40, known > est + threshold else { continue }
            rowHeights.commitMeasured(columnHeight: est, messageID: msg.id, allowShrink: true)
            changed = true
        }
        return changed
    }

    /// First-open / study-first scroll: hydrate deferred native while the finger is still down.
    private func maybeHydrateDeferredNativeWhileScrolling() {
        guard rowHeights.isScrollHeightFrozen else { return }
        // Programmatic stress scrolls set readingHistory + freeze without UIKit isDragging.
        guard tableView.isDragging || tableView.isDecelerating || readingHistory else { return }
        guard usesStudyHeightBucketPolicy() || needsPendingScrollPrep || readingHistory else { return }
        guard nativeHydrationScrollWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.nativeHydrationScrollWork = nil
            guard self.rowHeights.isScrollHeightFrozen,
                  self.tableView.isDragging
                    || self.tableView.isDecelerating
                    || self.readingHistory else { return }
            guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
            let budget: Int
            if self.readingHistory {
                budget = 1
            } else if self.needsPendingScrollPrep {
                budget = 2
            } else if self.usesStudyHeightBucketPolicy() {
                budget = 1
            } else {
                budget = 1
            }
            if self.hydrateVisibleDeferredNativeCells(maxCount: budget) {
                self.scheduleFrozenAssistantGeometrySync()
            }
            // History scroll: also fill blank assistants + restore missing action chrome.
            if self.needsPendingScrollPrep || self.usesStudyHeightBucketPolicy() || self.readingHistory {
                self.paintVisibleBlankAssistantsIfNeeded(
                    messages: messages,
                    layoutWidth: self.currentRenderWidth()
                )
                self.revealDeferredActionChromeOnVisibleAssistants(messages: messages)
            }
            if !self.needsPendingScrollPrep, self.usesStudyHeightBucketPolicy(), !self.readingHistory {
                self.applyTurnWindowPrewarm(
                    around: self.lookaheadAnchorRows(in: messages),
                    allowSync: false
                )
            }
        }
        nativeHydrationScrollWork = work
        DispatchQueue.main.async(execute: work)
    }

    /// Row indices in the tail band used for open / switch height seeding.
    private func tailBandRows(in messages: [ChatMessage], count: Int = 24) -> [Int] {
        let n = messages.count
        guard n > 0 else { return [] }
        let start = max(0, n - count)
        return Array(start..<n)
    }

    /// Visible + first QA turns above bottom — avoids `0..<minVisible` on cold open.
    private func lightOpenBottomPrepRows(in messages: [ChatMessage]) -> [Int] {
        let visible = tableView.indexPathsForVisibleRows?.map(\.row) ?? []
        let minVisible = visible.min() ?? max(0, messages.count - 1)
        let maxVisible = visible.max() ?? minVisible
        var rows = Set(visible)
        let bandStart = max(0, minVisible - (Self.turnPrewarmCount * 4 + 2))
        if bandStart <= maxVisible {
            rows.formUnion(bandStart...min(messages.count - 1, maxVisible))
        }
        rows.formUnion(firstQAEdgeWarmRows(in: messages, aboveVisibleMin: minVisible))
        return rows.filter { $0 >= 0 && $0 < messages.count }.sorted()
    }

    /// Collapse cheap tail estimates and paint visible rows before the first history freeze.
    /// - Parameter atBottom: lighter path after cold open — full estimate commit + targeted QA sync (no full-history layout storm).
    private func prepareFirstHistoryScrollFromOpen(messages: [ChatMessage],
                                                   layoutWidth: CGFloat,
                                                   atBottom: Bool = false,
                                                   preserveViewport: Bool = false) {
        let openGen = openGeneration
        let visibleMin = tableView.indexPathsForVisibleRows?.map(\.row).min()
            ?? max(0, messages.count - 1)
        let edgeRows = firstQAEdgeWarmRows(in: messages, aboveVisibleMin: visibleMin)
        let prepRows = atBottom
            ? lightOpenBottomPrepRows(in: messages)
            : firstHistoryScrollPrepRows(in: messages)
        guard !prepRows.isEmpty || atBottom else { return }
        guard openGen == openGeneration else { return }
        let anchorPath = viewportScrollAnchorPath()
        let anchorY = anchorPath.map { path in
            tableView.rectForRow(at: path).minY - tableView.contentOffset.y
        }
        if let path = anchorPath, let y = anchorY {
            pendingScrollSettleAnchor = (path, y)
        }
        // Full-list display estimates keep contentSize sane — but never force
        // full-history native probe on the open frame (see atBottom branch).
        if !atBottom {
            rowHeights.rebuildDisplayHeights(
                messages: messages,
                layoutWidth: layoutWidth,
                throughRow: messages.count - 1,
                layoutProbeTailRows: messages.count
            )
        }
        if atBottom {
            // Visible + first QA edge + small tail only. `throughRow: count-1` used to
            // force full-history native resolve on every cold open / conversation switch.
            let minPrep = prepRows.min() ?? max(0, messages.count - 8)
            let probeTail = min(
                messages.count,
                max(Self.switchLayoutProbeTailRows, messages.count - minPrep)
            )
            rowHeights.rebuildDisplayHeights(
                messages: messages,
                layoutWidth: layoutWidth,
                throughRow: nil,
                layoutProbeTailRows: probeTail
            )
            // Commit tail + prep band from cache only — display map already has cheap head estimates.
            var baselineRows = Set(prepRows)
            baselineRows.formUnion(tailBandRows(in: messages))
            _ = commitCachedLayoutHeights(
                messages: messages,
                layoutWidth: layoutWidth,
                rows: baselineRows.sorted(),
                syncLayoutBudget: 0,
                allowGrowCommitted: true,
                allowShrinkCommitted: true
            )
            // Sync-layout only the QA edge the finger will hit first — rest warms async.
            let syncEdge = edgeRows.isEmpty ? prepRows : edgeRows
            let syncBudget = min(
                isStudyNarrowPanelActive() ? 6 : 4,
                messages.filter { $0.role == .assistant && !$0.isStreaming }.count
            )
            prewarmScrollLookahead(
                messages: messages,
                layoutWidth: layoutWidth,
                rows: syncEdge,
                aggressive: false,
                syncLimit: min(syncBudget, max(syncEdge.count, 1))
            )
            _ = commitCachedLayoutHeights(
                messages: messages,
                layoutWidth: layoutWidth,
                rows: syncEdge.reversed(),
                syncLayoutBudget: syncBudget,
                allowGrowCommitted: true,
                allowShrinkCommitted: true
            )
            _ = shrinkInflatedCommittedRows(
                messages: messages,
                rows: syncEdge,
                layoutWidth: layoutWidth,
                slackThreshold: isStudyNarrowPanelActive() ? 10 : 20
            )
        } else {
            let syncBudget = min(prepRows.count, isStudyNarrowPanelActive() ? 24 : 18)
            prewarmScrollLookahead(
                messages: messages,
                layoutWidth: layoutWidth,
                rows: prepRows,
                aggressive: true,
                syncLimit: syncBudget
            )
            _ = commitCachedLayoutHeights(
                messages: messages,
                layoutWidth: layoutWidth,
                rows: prepRows,
                syncLayoutBudget: syncBudget,
                allowGrowCommitted: true,
                allowShrinkCommitted: true
            )
        _ = shrinkInflatedCommittedRows(
            messages: messages,
            rows: Array(0..<messages.count),
            layoutWidth: layoutWidth,
            slackThreshold: 8
        )
        paintVisibleBlankAssistantsIfNeeded(messages: messages, layoutWidth: layoutWidth)
        _ = shrinkInflatedVisibleRows(messages: messages, slackThreshold: 10)
        _ = syncVisibleRowHeightsToPaint(messages: messages, allowShrink: true, allowTableUpdates: false)
        }
        paintVisibleBlankAssistantsIfNeeded(messages: messages, layoutWidth: layoutWidth)
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            if cell.hasPendingDeferredNativeRender {
                cell.applyDeferredNativeRenderIfNeeded(suppressHeightNotify: true)
            }
        }
        _ = shrinkInflatedVisibleRows(
            messages: messages,
            slackThreshold: isStudyNarrowPanelActive() ? 12 : 32
        )
        _ = syncVisibleRowHeightsToPaint(messages: messages, allowShrink: true, allowTableUpdates: false)
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()
            if atBottom, !preserveViewport {
                scrollToLastRowReliable(messages)
            } else if let path = anchorPath, let y = anchorY {
                remeasureRowsPreservingViewport(
                    anchorPath: path,
                    preferSavedViewportAnchor: true,
                    fixedViewportY: y
                )
            }
        }
        viewportScrollAnchor = atBottom ? nil : captureViewportScrollAnchor()
        guard openGen == openGeneration else { return }
        if atBottom {
            scheduleFirstQAEdgeWarmAfterOpen(messages: messages, layoutWidth: layoutWidth)
        }
    }

    /// Narrow study panel: warm visible + lookahead without repeating full open prep.
    private func prepareStudyNarrowTailFromOpen(messages: [ChatMessage], layoutWidth: CGFloat) {
        let visible = tableView.indexPathsForVisibleRows?.map(\.row) ?? []
        let lookahead = scrollLookaheadRowsPrioritized(in: messages)
        let prepRows = Array(Set(visible + lookahead + tailBandRows(in: messages, count: 12))).sorted()
        guard !prepRows.isEmpty else { return }
        let assistants = prepRows.compactMap { row -> ChatMessage? in
            guard row < messages.count else { return nil }
            let msg = messages[row]
            return msg.role == .assistant && !msg.isStreaming ? msg : nil
        }
        if !assistants.isEmpty {
            AssistantMessageLayout.prewarmLayouts(
                for: assistants,
                targetWidth: layoutWidth,
                layoutLimit: min(assistants.count, 10)
            )
        }
        _ = commitCachedLayoutHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: prepRows,
            syncLayoutBudget: min(10, prepRows.count),
            allowGrowCommitted: true,
            allowShrinkCommitted: true
        )
        paintVisibleBlankAssistantsIfNeeded(messages: messages, layoutWidth: layoutWidth)
    }

    /// Assistants just above the open viewport — first QA crosses the user will hit.
    private func firstQAEdgeWarmRows(in messages: [ChatMessage], aboveVisibleMin: Int) -> [Int] {
        let turns = userTurnStartRows(in: messages)
        guard !turns.isEmpty else { return [] }
        let edgeTurns = turns.filter { $0 < aboveVisibleMin }.suffix(Self.turnPrewarmCount + 1)
        var rows = Set<Int>()
        for userRow in edgeTurns {
            rows.insert(userRow)
            if userRow + 1 < messages.count, messages[userRow + 1].role == .assistant {
                rows.insert(userRow + 1)
            }
        }
        return rows.sorted()
    }

    /// Background-warm native layouts for the first few QA pairs above bottom after cold open.
    private func scheduleFirstQAEdgeWarmAfterOpen(messages: [ChatMessage], layoutWidth: CGFloat) {
        let visibleMin = tableView.indexPathsForVisibleRows?.map(\.row).min() ?? max(0, messages.count - 1)
        let warmRows = firstQAEdgeWarmRows(in: messages, aboveVisibleMin: visibleMin)
        guard !warmRows.isEmpty else { return }
        let assistants = warmRows.compactMap { row -> ChatMessage? in
            guard row < messages.count else { return nil }
            let msg = messages[row]
            guard msg.role == .assistant, !msg.isStreaming else { return nil }
            guard !AssistantMessageLayout.hasCachedNativeLayout(for: msg, layoutWidth: layoutWidth) else {
                return nil
            }
            return msg
        }
        let openID = renderedConversationID
        let gen = openGeneration
        if !assistants.isEmpty {
            scheduleAsyncLayoutPrewarm(assistants: assistants, layoutWidth: layoutWidth)
        }
        // After a short idle, commit any newly cached heights so the first QA fling stays smooth.
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  gen == self.openGeneration,
                  openID == self.renderedConversationID,
                  self.stickToBottom, !self.isViewportPinned(),
                  let live = ConversationStore.shared.currentConversation?.messages,
                  !live.isEmpty else { return }
            let width = self.currentRenderWidth()
            _ = self.commitCachedLayoutHeights(
                messages: live,
                layoutWidth: width,
                rows: warmRows.filter { $0 < live.count },
                syncLayoutBudget: 0,
                allowGrowCommitted: true,
                allowShrinkCommitted: true
            )
            self.paintVisibleBlankAssistantsIfNeeded(messages: live, layoutWidth: width)
            if self.stickToBottom, !self.isViewportPinned() {
                self.scrollToLastRowReliable(live)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Study panel first scroll: prewarm narrow-width layouts + shrink stale committed (no beginUpdates).
    private func prepareStudyFirstScrollFromOpen(messages: [ChatMessage], layoutWidth: CGFloat) {
        prepareStudyNarrowTailFromOpen(messages: messages, layoutWidth: layoutWidth)
        let visible = tableView.indexPathsForVisibleRows?.map(\.row) ?? []
        let prepRows = Array(Set(visible + scrollLookaheadRowsPrioritized(in: messages))).sorted()
        guard !prepRows.isEmpty else { return }
        if let path = viewportScrollAnchorPath() {
            let y = tableView.rectForRow(at: path).minY - tableView.contentOffset.y
            pendingScrollSettleAnchor = (path, y)
        }
        _ = shrinkInflatedCommittedRows(
            messages: messages,
            rows: prepRows,
            layoutWidth: layoutWidth,
            slackThreshold: 12
        )
        let assistants = prepRows.compactMap { row -> ChatMessage? in
            guard row < messages.count else { return nil }
            let msg = messages[row]
            return msg.role == .assistant && !msg.isStreaming ? msg : nil
        }
        if !assistants.isEmpty {
            AssistantMessageLayout.prewarmLayouts(
                for: assistants,
                targetWidth: layoutWidth,
                layoutLimit: min(8, assistants.count)
            )
        }
        prewarmScrollLookahead(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: prepRows,
            aggressive: false,
            syncLimit: min(6, prepRows.count)
        )
        _ = commitCachedLayoutHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: prepRows,
            syncLayoutBudget: min(4, prepRows.count),
            allowGrowCommitted: true,
            allowShrinkCommitted: false
        )
        let inflated = prepRows.contains { row in
            guard row < messages.count else { return false }
            let path = IndexPath(row: row, section: 0)
            guard let cell = tableView.cellForRow(at: path) as? MessageCellType else { return false }
            let rowH = tableView.rectForRow(at: path).height
            let painted = cell.measuredContentHeight() + ChatRowHeightResolver.cellVerticalMargin
            return rowH > painted + 36
        }
        guard inflated else { return }
        _ = shrinkInflatedVisibleRows(messages: messages, slackThreshold: 12)
        _ = syncVisibleRowHeightsToPaint(messages: messages, allowShrink: true, allowTableUpdates: false)
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            if let path = viewportScrollAnchorPath() {
                let y = tableView.rectForRow(at: path).minY - tableView.contentOffset.y
                remeasureRowsPreservingViewport(
                    anchorPath: path,
                    preferSavedViewportAnchor: true,
                    fixedViewportY: y
                )
            }
        }
    }

    /// Sync native layout cache for the first QA pairs above bottom — avoids cold bind on first upward fling.
    private func syncPrewarmFirstQAEdgeAtBottom(messages: [ChatMessage], layoutWidth: CGFloat) {
        let visibleMin = tableView.indexPathsForVisibleRows?.map(\.row).min()
            ?? max(0, messages.count - 1)
        let edgeRows = firstQAEdgeWarmRows(in: messages, aboveVisibleMin: visibleMin)
        guard !edgeRows.isEmpty else { return }
        prewarmScrollLookahead(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: edgeRows,
            aggressive: false,
            syncLimit: min(8, edgeRows.count)
        )
        _ = commitCachedLayoutHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: edgeRows,
            syncLayoutBudget: min(8, edgeRows.count),
            allowGrowCommitted: true,
            allowShrinkCommitted: true
        )
    }

    /// Finger-down fallback when eager open prep did not run — no full-table rebuild / beginUpdates.
    private func lightweightFingerDownHistoryPrep(messages: [ChatMessage], layoutWidth: CGFloat) {
        let visibleMin = tableView.indexPathsForVisibleRows?.map(\.row).min()
            ?? max(0, messages.count - 1)
        var rows = Set(firstQAEdgeWarmRows(in: messages, aboveVisibleMin: visibleMin))
        rows.formUnion(scrollLookaheadRowsPrioritized(in: messages))
        let rowList = rows.filter { $0 >= 0 && $0 < messages.count }.sorted()
        guard !rowList.isEmpty else { return }
        let assistants = rowList.compactMap { row -> ChatMessage? in
            guard row < messages.count else { return nil }
            let msg = messages[row]
            return msg.role == .assistant && !msg.isStreaming ? msg : nil
        }
        if !assistants.isEmpty {
            AssistantMessageLayout.prewarmLayouts(
                for: assistants,
                targetWidth: layoutWidth,
                layoutLimit: assistants.count
            )
        }
        prewarmScrollLookahead(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: rowList,
            aggressive: false,
            syncLimit: min(10, rowList.count)
        )
        _ = commitCachedLayoutHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: rowList,
            syncLayoutBudget: min(10, rowList.count),
            allowGrowCommitted: true
        )
    }

    /// Run pending first-scroll height prep while still pinned to bottom (cold open / study enter).
    /// Avoids the finger-down jump when prep would otherwise mutate heights mid-drag.
    private func eagerPreparePendingHistoryHeightsAtBottom() {
        guard needsPendingScrollPrep else { return }
        guard stickToBottom, !isViewportPinned() else { return }
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              !messages.isEmpty else { return }
        let layoutWidth = currentRenderWidth()
        let openGen = openGeneration
        // At bottom: light height prep + async first-QA warm (full sync layout waits for first drag if needed).
        if pendingStudyFirstScrollPrep {
            if needsFirstHistoryScrollPrep {
                prepareFirstHistoryScrollFromOpen(messages: messages, layoutWidth: layoutWidth, atBottom: true)
                needsFirstHistoryScrollPrep = false
            }
            guard openGen == openGeneration else { return }
            prepareStudyNarrowTailFromOpen(messages: messages, layoutWidth: layoutWidth)
            pendingStudyFirstScrollPrep = false
        } else if needsFirstHistoryScrollPrep {
            prepareFirstHistoryScrollFromOpen(messages: messages, layoutWidth: layoutWidth, atBottom: true)
            guard openGen == openGeneration else { return }
            syncPrewarmFirstQAEdgeAtBottom(messages: messages, layoutWidth: layoutWidth)
            needsFirstHistoryScrollPrep = false
        }
        guard openGen == openGeneration else { return }
        isPerformingColdLaunchOpen = false
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()
            scrollToLastRowReliable(messages)
        }
        viewportScrollAnchor = nil
        pendingScrollSettleAnchor = nil
    }

    /// Grow committed/display heights when painted cells exceed frozen row geometry.
    @discardableResult
    private func syncVisibleRowHeightsToPaint(messages: [ChatMessage],
                                              allowShrink: Bool = false,
                                              allowTableUpdates: Bool = true) -> Bool {
        var changed = false
        for case let cell as MessageCellType in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            if syncRowHeightToPaint(cell: cell, message: messages[path.row], allowShrink: allowShrink) {
                changed = true
            }
        }
        guard changed, allowTableUpdates else { return changed }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
        return changed
    }

    @discardableResult
    private func syncRowHeightToPaint(cell: MessageCellType,
                                      message: ChatMessage,
                                      allowShrink: Bool = false) -> Bool {
        guard !message.isStreaming else { return false }
        cell.contentView.layoutIfNeeded()
        var measured = cell.measuredContentHeight()
        if let assistant = cell as? AssistantMessageCell, message.role == .assistant {
            let layoutWidth = currentRenderWidth()
            let paintedFrozen = rowHeights.isScrollHeightFrozen
                && rowHeights.isCommitted(message.id)
                && assistant.hasVisibleBodyPaint
            if !paintedFrozen {
                let projected = assistant.projectedColumnHeight(
                    for: message,
                    layoutWidth: layoutWidth
                )
                if !assistant.hasVisibleBodyPaint {
                    measured = max(measured, projected)
                } else if measured + 6 < projected,
                          let path = tableView.indexPath(for: assistant) {
                    let rowFrame = tableView.rectForRow(at: path)
                    if measured + ChatRowHeightResolver.cellVerticalMargin > rowFrame.height + 2 {
                        measured = max(measured, projected)
                    }
                }
            }
        }
        guard measured > 40 else { return false }
        let prior = rowHeights.bestKnownColumnHeight(for: message.id)
        if rowHeights.isScrollHeightFrozen,
           rowHeights.isCommitted(message.id),
           let assistant = cell as? AssistantMessageCell,
           assistant.hasVisibleBodyPaint,
           !allowShrink,
           measured <= prior + 8 {
            return false
        }
        rowHeights.commitMeasured(columnHeight: measured, messageID: message.id, allowShrink: allowShrink)
        return rowHeights.growFrozenRowHeightIfNeeded(messageID: message.id, columnHeight: measured)
            || (allowShrink ? abs(prior - measured) > 2 : measured > prior + 2)
    }

    private func revealVisibleActionChrome(messages: [ChatMessage]) {
        let openPath = pendingOpenAtBottom || suppressHeightRemeasure
        showVisibleActionChrome(messages: messages, requireBodyAlignment: openPath)
        var changed = false
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let msg = messages.first(where: { $0.id == cell.messageID }),
                  msg.role == .assistant,
                  !msg.isStreaming else { continue }
            let measured = cell.measuredContentHeight()
            guard measured > 40 else { continue }
            let prior = rowHeights.bestKnownColumnHeight(for: msg.id)
            guard measured > prior + 2 else { continue }
            if openPath {
                rowHeights.commitMeasured(columnHeight: measured, messageID: msg.id, allowShrink: true)
            } else {
                rowHeights.commitMeasured(columnHeight: max(prior, measured), messageID: msg.id, allowShrink: false)
            }
            changed = true
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

    /// Rows about to enter the viewport first — history reading is usually scroll-up.
    private func scrollLookaheadRowsPrioritized(in messages: [ChatMessage]) -> [Int] {
        let visible = tableView.indexPathsForVisibleRows?.map(\.row) ?? []
        guard !visible.isEmpty else { return [] }
        let biasUp = readingHistory || scrollBiasUp
        let span = Self.turnPrewarmCount * 2 + 2
        var incoming: [Int] = []
        if biasUp, let minRow = visible.min() {
            for delta in 1...span {
                let row = minRow - delta
                if row >= 0 { incoming.append(row) }
            }
        } else if let maxRow = visible.max() {
            for delta in 1...span {
                let row = maxRow + delta
                if row < messages.count { incoming.append(row) }
            }
        }
        let visibleSet = Set(visible)
        let symmetric = scrollLookaheadRows(in: messages).filter { !visibleSet.contains($0) && !incoming.contains($0) }
        return visible.sorted() + incoming + symmetric
    }

    /// Prewarm Q↔A native layouts at drag start — short sync, long async (no contentSize snap).
    private func prewarmScrollLookahead(messages: [ChatMessage],
                                        layoutWidth: CGFloat,
                                        rows: [Int]? = nil,
                                        aggressive: Bool = false,
                                        syncLimit: Int? = nil) {
        let rowList = rows ?? scrollLookaheadRows(in: messages)
        let resolvedSyncLimit = syncLimit ?? (aggressive ? 6 : 2)
        let charLimit = aggressive ? 4_000 : Self.syncPrewarmMaxChars
        var syncBatch: [ChatMessage] = []
        var asyncBatch: [ChatMessage] = []
        for row in rowList {
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
                if msg.content.count <= charLimit, syncBatch.count < resolvedSyncLimit {
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
        if aggressive {
            return
        }
        scheduleAsyncLayoutPrewarm(assistants: asyncBatch, layoutWidth: layoutWidth)
    }

    /// Sync-layout lookahead assistants at the current width before row heights freeze.
    private func prepareScrollGestureHeights(messages: [ChatMessage],
                                           layoutWidth: CGFloat,
                                           excludeRows: Set<Int> = []) {
        var rowSet = Set(scrollLookaheadRowsPrioritized(in: messages))
        if readingHistory {
            let visibleMin = tableView.indexPathsForVisibleRows?.map(\.row).min()
                ?? max(0, messages.count - 1)
            rowSet.formUnion(firstQAEdgeWarmRows(in: messages, aboveVisibleMin: visibleMin))
        }
        let lookahead = rowSet.filter { !excludeRows.contains($0) }.sorted()
        guard !lookahead.isEmpty else { return }
        let seasonedLong = isLongContextThread(messageCount: messages.count)
            && hasCompletedFirstHistoryScrollGesture
        let syncCap = seasonedLong ? 2 : (readingHistory ? min(6, lookahead.count) : nil)
        prewarmScrollLookahead(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: lookahead,
            aggressive: false,
            syncLimit: syncCap
        )
        let layoutBudget = seasonedLong
            ? 2
            : (readingHistory
                ? min(6, lookahead.count)
                : (isStudyNarrowPanelActive() ? min(4, lookahead.count) : min(3, lookahead.count)))
        _ = commitCachedLayoutHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: lookahead,
            syncLayoutBudget: layoutBudget,
            allowGrowCommitted: true
        )
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

    @discardableResult
    private func hydrateVisibleDeferredNativeCells(maxCount: Int = 1) -> Bool {
        var pending: [(row: Int, cell: AssistantMessageCell)] = []
        let layoutWidth = currentRenderWidth()
        let scrolling = tableView.isDragging || tableView.isDecelerating
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard cell.hasPendingDeferredNativeRender,
                  let path = tableView.indexPath(for: cell) else { continue }
            // Mid-scroll: only hydrate when layout is already warm (no sync layout+rasterize hitch).
            if scrolling,
               let messages = ConversationStore.shared.currentConversation?.messages,
               path.row < messages.count,
               !AssistantMessageLayout.hasCachedNativeLayout(
                   for: messages[path.row],
                   layoutWidth: layoutWidth
               ) {
                continue
            }
            pending.append((path.row, cell))
        }
        #if DEBUG
        ChatHeavyScrollDiagnostics.gestureDeferredVisiblePeak = max(
            ChatHeavyScrollDiagnostics.gestureDeferredVisiblePeak,
            pending.count
        )
        #endif
        guard !pending.isEmpty else { return false }
        pending.sort { scrollBiasUp ? $0.row > $1.row : $0.row < $1.row }
        let batch = pending.prefix(max(1, maxCount))
        var grew = false
        for item in batch {
            item.cell.applyDeferredNativeRenderIfNeeded(suppressHeightNotify: true)
            guard let messages = ConversationStore.shared.currentConversation?.messages,
                  item.row < messages.count else { continue }
            let msg = messages[item.row]
            let measured = item.cell.measuredContentHeight()
            if measured > 40 {
                let prior = rowHeights.bestKnownColumnHeight(for: msg.id)
                if measured > prior + 2 {
                    rowHeights.commitMeasured(columnHeight: measured, messageID: msg.id, allowShrink: false)
                    if rowHeights.growFrozenRowHeightIfNeeded(messageID: msg.id, columnHeight: measured) {
                        grew = true
                        #if DEBUG
                        ChatHeavyScrollDiagnostics.midScrollHydrateGrew += 1
                        #endif
                    }
                }
            }
            // Always paint icons after body hydrate — room-check reveal can leave them missing.
            item.cell.showCommittedActionIconsDuringScroll(for: msg)
            if !item.cell.hasVisibleActionButtons {
                item.cell.revealActionChromeIfBodyPainted(for: msg)
            }
            if !item.cell.hasVisibleActionButtons {
                _ = item.cell.ensureActionButtonsVisible(for: msg)
            }
        }
        // Never beginUpdates / remasure while the finger is still moving.
        if grew, !scrolling {
            if !readingHistory {
                applyFrozenRelayoutPreservingLockedAnchor()
            } else {
                remeasureRowsPreservingViewport(anchorPath: viewportScrollAnchorPath())
            }
        }
        return pending.count > batch.count
    }

    /// Upgrade one visible fallback per run-loop turn after a fast scroll.
    /// Hydrating every visible native layout in `scrollViewDidEnd…` made the
    /// first resting frame hitch and left cells visibly blank during reuse.
    private func scheduleVisibleDeferredNativeHydration() {
        deferredRenderWork?.cancel()
        visibleNativeHydrationInProgress = true
        let openID = renderedConversationID
        let generation = openGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  !self.tableView.isDragging,
                  !self.tableView.isDecelerating,
                  openID == self.renderedConversationID,
                  generation == self.openGeneration else {
                self?.visibleNativeHydrationInProgress = false
                return
            }
            if self.hydrateOneVisibleDeferredNativeCell() {
                self.scheduleVisibleDeferredNativeHydration()
                return
            }
            if self.hasVisiblePendingDeferredNative() {
                self.scheduleVisibleDeferredNativeHydration()
            } else if self.readingHistory && !self.isJumpingToTurn,
                      let messages = ConversationStore.shared.currentConversation?.messages {
                self.visibleNativeHydrationInProgress = false
                if self.needsReadingHistoryLayoutRepair(messages: messages) {
                    self.flushReadingHistoryFormulaSync(messages: messages)
                } else {
                    let anchor = self.pendingScrollSettleAnchor
                    self.pendingScrollSettleAnchor = nil
                    self.finalizeScrollSettleLayout(
                        messages: messages,
                        anchorPath: anchor?.path,
                        fixedViewportY: anchor?.viewportY
                    )
                }
            } else {
                self.visibleNativeHydrationInProgress = false
            }
        }
        deferredRenderWork = work
        DispatchQueue.main.async(execute: work)
    }

    @discardableResult
    private func hydrateOneVisibleDeferredNativeCell() -> Bool {
        let budget: Int
        if readingHistory, !tableView.isDragging, !tableView.isDecelerating {
            budget = 8
        } else if tableView.isDecelerating, !tableView.isDragging {
            budget = 3
        } else if tableView.isDragging {
            if needsPendingScrollPrep {
                budget = 2
            } else if isStudyNarrowPanelActive() {
                budget = 2
            } else {
                budget = 1
            }
        } else {
            budget = 1
        }
        return hydrateVisibleDeferredNativeCells(maxCount: budget)
    }

    /// Anchor remeasure to the user bubble of the current turn while reading history.
    private func historyScrollAnchorPath() -> IndexPath? {
        guard readingHistory, let row = contextUserIndex,
              row >= 0, row < tableView.numberOfRows(inSection: 0) else { return nil }
        return IndexPath(row: row, section: 0)
    }

    private func captureViewportScrollAnchor() -> (row: Int, deltaY: CGFloat)? {
        guard let live = liveScrollViewportAnchor() else { return nil }
        return (live.path.row, live.viewportY)
    }

    /// Top visible row by geometry — not min(row), which picks a clipped row above the bubble.
    private func liveScrollViewportAnchor() -> (path: IndexPath, viewportY: CGFloat)? {
        guard let visible = tableView.indexPathsForVisibleRows, !visible.isEmpty else { return nil }
        let viewportTop = tableView.contentOffset.y
        var bestPath: IndexPath?
        var bestViewportY: CGFloat = 0
        var bestScore = CGFloat.greatestFiniteMagnitude
        for path in visible {
            guard path.row >= 0, path.row < tableView.numberOfRows(inSection: 0) else { continue }
            let rowMinY = tableView.rectForRow(at: path).minY
            let viewportY = rowMinY - viewportTop
            let score: CGFloat
            if viewportY >= -6, viewportY <= 56 {
                score = abs(viewportY)
            } else {
                score = abs(viewportY) + 2_000
            }
            if score < bestScore {
                bestScore = score
                bestPath = path
                bestViewportY = viewportY
            }
        }
        guard let path = bestPath else { return nil }
        return (path, bestViewportY)
    }

    /// Gesture-locked anchor — same row for the whole drag; only Y is resampled.
    private func lockedScrollViewportAnchor() -> (path: IndexPath, viewportY: CGFloat)? {
        if let row = gestureLockedScrollAnchorRow,
           row >= 0, row < tableView.numberOfRows(inSection: 0) {
            let path = IndexPath(row: row, section: 0)
            let viewportY = tableView.rectForRow(at: path).minY - tableView.contentOffset.y
            return (path, viewportY)
        }
        return liveScrollViewportAnchor()
    }

    private func refreshLiveHistoryScrollAnchor() {
        guard readingHistory, rowHeights.isScrollHeightFrozen,
              tableView.isDragging || tableView.isDecelerating else { return }
        guard let locked = lockedScrollViewportAnchor() else { return }
        viewportScrollAnchor = (locked.path.row, locked.viewportY)
    }

    /// Finger-up / deceleration-end anchor — never retarget to a different row mid-gesture.
    private func captureReleaseScrollSettleAnchor() {
        guard rowHeights.isScrollHeightFrozen else { return }
        refreshHistoryEdgePinnedRows()
        if let edge = historyEdgeSettleAnchor() {
            gestureLockedScrollAnchorRow = edge.row
            let path = IndexPath(row: edge.row, section: 0)
            pendingScrollSettleAnchor = (path, edge.viewportY)
            viewportScrollAnchor = (edge.row, edge.viewportY)
            return
        }
        if let locked = lockedScrollViewportAnchor() {
            pendingScrollSettleAnchor = (locked.path, locked.viewportY)
            viewportScrollAnchor = (locked.path.row, locked.viewportY)
            return
        }
        refreshViewportScrollAnchorForCurrentRow()
        if let anchor = viewportScrollAnchor {
            pendingScrollSettleAnchor = (
                IndexPath(row: anchor.row, section: 0),
                anchor.deltaY
            )
        }
    }

    /// After row-height mutations: anchor to whatever is top-visible now and sample Y live.
    private func remeasureRowsPreservingLiveViewport(preferredPath: IndexPath? = nil) {
        tableView.layoutIfNeeded()
        let path: IndexPath
        if let locked = lockedScrollViewportAnchor() {
            path = locked.path
        } else if let live = liveScrollViewportAnchor() {
            path = live.path
        } else if let preferredPath = preferredPath,
                  preferredPath.row >= 0,
                  preferredPath.row < tableView.numberOfRows(inSection: 0) {
            path = preferredPath
        } else if let fallback = viewportScrollAnchorPath() {
            path = fallback
        } else if let visible = tableView.indexPathsForVisibleRows?.min(by: { $0.row < $1.row }),
                  visible.row < tableView.numberOfRows(inSection: 0) {
            path = visible
        } else {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
            return
        }
        let y = tableView.rectForRow(at: path).minY - tableView.contentOffset.y
        remeasureRowsPreservingViewport(
            anchorPath: path,
            preferSavedViewportAnchor: false,
            fixedViewportY: y
        )
        if readingHistory {
            viewportScrollAnchor = (path.row, y)
            pendingScrollSettleAnchor = (path, y)
        }
    }

    /// Keep the same anchor row across a history scroll gesture; only refresh its viewport Y.
    private func refreshViewportScrollAnchorForCurrentRow() {
        if let anchor = viewportScrollAnchor,
           anchor.row >= 0, anchor.row < tableView.numberOfRows(inSection: 0) {
            let path = IndexPath(row: anchor.row, section: 0)
            viewportScrollAnchor = (anchor.row, tableView.rectForRow(at: path).minY - tableView.contentOffset.y)
        } else {
            viewportScrollAnchor = captureViewportScrollAnchor()
        }
    }

    private func viewportScrollAnchorPath() -> IndexPath? {
        if let anchor = viewportScrollAnchor,
           anchor.row >= 0, anchor.row < tableView.numberOfRows(inSection: 0) {
            return IndexPath(row: anchor.row, section: 0)
        }
        return tableView.indexPathsForVisibleRows?.min(by: { $0.row < $1.row })
    }

    private func hasVisiblePendingDeferredNative() -> Bool {
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            if cell.hasPendingDeferredNativeRender { return true }
        }
        return false
    }

    private func remeasureRowsPreservingViewport(anchorPath: IndexPath? = nil,
                                                 preferSavedViewportAnchor: Bool = true,
                                                 fixedViewportY: CGFloat? = nil) {
        let visible = tableView.indexPathsForVisibleRows ?? []
        if let pinned = pinnedJumpUserRow,
           pinned >= 0, pinned < tableView.numberOfRows(inSection: 0) {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
                tableView.layoutIfNeeded()
                applyUserQuestionPinnedToTop(at: pinned, animated: false)
                let path = IndexPath(row: pinned, section: 0)
                viewportScrollAnchor = (pinned, tableView.rectForRow(at: path).minY - tableView.contentOffset.y)
            }
            return
        }
        let anchor: IndexPath
        if let path = anchorPath,
           fixedViewportY != nil,
           path.section == 0,
           path.row < tableView.numberOfRows(inSection: 0) {
            anchor = path
        } else if readingHistory,
                  rowHeights.isScrollHeightFrozen,
                  anchorPath == nil,
                  let locked = lockedScrollViewportAnchor() {
            anchor = locked.path
        } else if preferSavedViewportAnchor,
           let saved = viewportScrollAnchor,
           saved.row >= 0, saved.row < tableView.numberOfRows(inSection: 0) {
            anchor = IndexPath(row: saved.row, section: 0)
        } else if let path = anchorPath ?? viewportScrollAnchorPath(),
                  path.section == 0,
                  path.row < tableView.numberOfRows(inSection: 0) {
            anchor = path
        } else if let fallback = visible.min(by: { $0.row < $1.row }),
                  fallback.row < tableView.numberOfRows(inSection: 0) {
            anchor = fallback
        } else {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
            return
        }
        tableView.layoutIfNeeded()
        let liveViewportY: CGFloat
        if let y = fixedViewportY {
            liveViewportY = y
        } else if readingHistory,
                  rowHeights.isScrollHeightFrozen,
                  let locked = lockedScrollViewportAnchor(),
                  locked.path == anchor {
            liveViewportY = locked.viewportY
        } else {
            liveViewportY = tableView.rectForRow(at: anchor).minY - tableView.contentOffset.y
        }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()
            let target = tableView.rectForRow(at: anchor).minY - liveViewportY
            let minOffset = -tableView.adjustedContentInset.top
            let maxOffset = max(
                minOffset,
                tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
            )
            tableView.contentOffset.y = min(max(target, minOffset), maxOffset)
            if readingHistory {
                refreshViewportScrollAnchorForCurrentRow()
            } else {
                viewportScrollAnchor = captureViewportScrollAnchor()
            }
        }
    }

    private func isViewportPinned() -> Bool {
        viewportPinnedByUser || readingHistory
    }

    private func schedulePinnedRemeasure() {
        pinnedRemeasureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isViewportPinned() else { return }
            let anchorPath = self.historyScrollAnchorPath()
            self.remeasureRowsPreservingViewport(anchorPath: anchorPath)
            // Only re-pin after an explicit turn jump — manual history scroll must keep finger position.
            if let pinned = self.pinnedJumpUserRow {
                self.applyUserBubbleScrollAnchor(at: pinned, animated: false)
            }
        }
        pinnedRemeasureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Reveal 复制/重跑/分叉 immediately after scroll freeze ends — before native hydrate.
    private func revealVisibleActionChrome() {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        showVisibleActionChrome(messages: messages)
    }

    private func menuPresentingViewController() -> UIViewController {
        navigationController ?? self
    }

    /// After scroll settles, upgrade every visible assistant row and restore action chrome.
    private func upgradeVisibleAssistantRendering() {
        guard !tableView.isDragging, !tableView.isDecelerating else { return }
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let layoutWidth = currentRenderWidth()
        let visibleRows = (tableView.indexPathsForVisibleRows ?? []).map(\.row)
        if !visibleRows.isEmpty {
            _ = commitCachedLayoutHeights(
                messages: messages,
                layoutWidth: layoutWidth,
                rows: visibleRows,
                syncLayoutBudget: min(3, visibleRows.count)
            )
        }
        var needsRemeasure = false
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard msg.role == .assistant, !msg.isStreaming else { continue }
            let prior = rowHeights.bestKnownColumnHeight(for: msg.id)
            if cell.hasPendingDeferredNativeRender {
                cell.applyDeferredNativeRenderIfNeeded(suppressHeightNotify: true)
            } else if !cell.hasVisibleBodyPaint,
                      !msg.content.isEmpty {
                cell.configureForOpenHistory(
                    with: msg,
                    preferredHeight: rowHeights.committedColumnHeight(for: msg.id),
                    layoutWidth: layoutWidth
                )
            }
            cell.ensureActionButtonsVisible(for: msg)
            _ = cell.revealReservedActionChromeIfRoom(for: msg)
            let measured = cell.measuredContentHeight()
            if measured > 40 {
                rowHeights.commitMeasured(
                    columnHeight: measured,
                    messageID: msg.id,
                    allowShrink: isStudyNarrowPanelActive() || readingHistory
                )
                if abs(prior - measured) > 1 { needsRemeasure = true }
            }
        }
        if shrinkInflatedVisibleRows(messages: messages) {
            needsRemeasure = true
        }
        if readingHistory {
            if needsRemeasure || needsReadingHistoryLayoutRepair(messages: messages) {
                scheduleFormulaHeightSyncWhileReading()
            }
        } else if needsRemeasure, !isJumpingToTurn {
            remeasureRowsPreservingViewport(preferSavedViewportAnchor: true)
        }
    }

    /// Paint visible assistant rows that still show an empty body shell.
    private func paintVisibleBlankAssistantsIfNeeded(messages: [ChatMessage], layoutWidth: CGFloat) {
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard msg.role == .assistant,
                  !msg.isStreaming,
                  !msg.content.isEmpty,
                  !cell.hasVisibleBodyPaint else { continue }
            cell.configureForOpenHistory(
                with: msg,
                preferredHeight: rowHeights.committedColumnHeight(for: msg.id),
                layoutWidth: layoutWidth
            )
            if cell.hasVisibleBodyPaint, !cell.hasVisibleActionButtons {
                cell.revealActionChromeIfBodyPainted(for: msg)
            }
        }
    }

    /// Slack above painted body; excludes action-chrome reserve so settle does not over-shrink.
    private func meaningfulVisibleRowSlack(for cell: MessageCellType,
                                           at path: IndexPath,
                                           messages: [ChatMessage],
                                           threshold: CGFloat) -> CGFloat? {
        guard path.row < messages.count else { return nil }
        let msg = messages[path.row]
        guard !msg.isStreaming else { return nil }
        cell.contentView.layoutIfNeeded()
        let measured = cell.measuredContentHeight()
        guard measured > 40 else { return nil }
        let rowFrame = tableView.rectForRow(at: path)
        var slack = rowFrame.height - (measured + ChatRowHeightResolver.cellVerticalMargin)
        if let assistant = cell as? AssistantMessageCell,
           msg.role == .assistant,
           assistant.hasReservedActionChromeSpace,
           !assistant.hasVisibleActionButtons {
            slack -= Self.actionChromeHeightSlack
        }
        return slack > threshold ? slack : nil
    }

    private func needsReadingHistoryLayoutRepair(messages: [ChatMessage]) -> Bool {
        if pendingReadingHistoryFormulaSync { return true }
        if debugVisibleRowClipCount() > 0 { return true }
        let threshold: CGFloat = isStudyNarrowPanelActive() ? 14 : 28
        for case let cell as MessageCellType in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            if msg.role == .assistant,
               !msg.isStreaming,
               !msg.content.isEmpty,
               let assistant = cell as? AssistantMessageCell,
               !assistant.hasVisibleBodyPaint {
                return true
            }
            if meaningfulVisibleRowSlack(for: cell, at: path, messages: messages, threshold: threshold) != nil {
                return true
            }
        }
        return false
    }

    /// Collapse rows whose allocated height dwarfs painted content (cross-bucket stale geometry).
    @discardableResult
    private func shrinkInflatedVisibleRows(messages: [ChatMessage],
                                           slackThreshold: CGFloat? = nil) -> Bool {
        let threshold = slackThreshold ?? (isStudySessionActive() ? 12 : 72)
        var changed = false
        for case let cell as MessageCellType in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard !msg.isStreaming else { continue }
            guard meaningfulVisibleRowSlack(for: cell, at: path, messages: messages, threshold: threshold) != nil else {
                continue
            }
            cell.contentView.layoutIfNeeded()
            let measured = cell.measuredContentHeight()
            let prior = rowHeights.bestKnownColumnHeight(for: msg.id)
            rowHeights.commitMeasured(columnHeight: measured, messageID: msg.id, allowShrink: true)
            if abs(prior - measured) > 1 { changed = true }
        }
        return changed
    }

    /// Show 复制/重跑/分叉 only after scroll settles on the focused history turn.
    private func revealActionChromeForVisibleHistoryTurn() {
        upgradeVisibleAssistantRendering()
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
            viewportScrollAnchor = nil
            for case let cell as AssistantMessageCell in tableView.visibleCells {
                cell.pinActionRowBelowColumnForScrollFreeze(false)
            }
            repairTopViewportMidLineClip()
        } else {
            stickToBottom = false
            readingHistory = true
            viewportPinnedByUser = true
            repairTopViewportMidLineClip()
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

    /// Tail configure + bottom pin + action chrome on the open critical path (no coalesce wait).
    private func primeOpenBottomPresentation(messages: [ChatMessage], layoutWidth: CGFloat) {
        guard tableMatchesMessages(messages) else { return }
        UIView.performWithoutAnimation {
            pinOpenViewportToBottom(messages, layoutWidth: layoutWidth)
            if let tailID = tailAssistantMessageID(in: messages),
               let row = messages.firstIndex(where: { $0.id == tailID }),
               row < tableView.numberOfRows(inSection: 0),
               let tail = messages.first(where: { $0.id == tailID }),
               let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? AssistantMessageCell {
                let preferred = rowHeights.displayColumnHeight(for: tail.id)
                    ?? rowHeights.committedColumnHeight(for: tail.id)
                cell.configureForOpenBottom(
                    with: tail,
                    preferredHeight: preferred,
                    layoutWidth: layoutWidth
                )
            }
            finalizeOpenBottomViewport(messages: messages, layoutWidth: layoutWidth)
        }
    }

    /// Native open path: disk heights + tail pin. No snapshot tiles.
    private func openConversationAtBottom(messages: [ChatMessage], layoutWidth: CGFloat) {
        guard !messages.isEmpty else {
            pendingOpenAtBottom = false
            suppressHeightRemeasure = false
            readingHistory = false
            viewportPinnedByUser = false
            viewportScrollAnchor = nil
            pinnedJumpUserRow = nil
            finishViewportLocked = false
            tableView.isScrollEnabled = true
            // Must reload before hiding — stale visible cells from the prior
            // conversation crash UITableView when numberOfRows becomes 0.
            tableView.reloadData()
            tableView.layoutIfNeeded()
            tableView.alpha = 1
            updateEmptyState()
            return
        }
        pendingOpenAtBottom = true
        suppressHeightRemeasure = true

        seedTailOpenLayoutFromCache(messages: messages, layoutWidth: layoutWidth)
        seedOpenBottomViewportHeights(messages: messages, layoutWidth: layoutWidth)
        let tailStart = max(0, messages.count - 8)
        let commitRows = Array(tailStart..<messages.count)
        _ = commitCachedLayoutHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            rows: commitRows,
            syncLayoutBudget: 0
        )

        tableView.alpha = 0
        tableView.isHidden = false
        tableView.reloadData()
        tableView.layoutIfNeeded()
        primeOpenBottomPresentation(messages: messages, layoutWidth: layoutWidth)
        tableView.alpha = 1
        releaseOpenInteractionLock()
        openBottomStickActive = tailActionChromeOverlapsInputBar(messages: messages)
        needsFirstHistoryScrollPrep = true
        hasCompletedFirstHistoryScrollGesture = false
        scheduleCoalescedOpenUpgrade()
        // Heavy first-scroll height prep must not run on the same turn as reload+pin —
        // that is the cold-open / conversation-switch hitch.
        let openGen = openGeneration
        let openID = renderedConversationID
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  openGen == self.openGeneration,
                  openID == self.renderedConversationID else { return }
            self.eagerPreparePendingHistoryHeightsAtBottom()
            self.prewarmFenceHeavyLayoutsForCurrentConversation()
        }
    }

    /// Fence-dense transcripts: warm layout cache before the first upward scroll.
    private func prewarmFenceHeavyLayoutsForCurrentConversation() {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              !messages.isEmpty else { return }
        let layoutWidth = currentRenderWidth()
        #if DEBUG
        ChatHeavyScrollDiagnostics.logConversationProfile(messages, label: "open")
        #endif
        let fenceHeavy = messages.filter {
            $0.role == .assistant
                && !$0.isStreaming
                && AssistantMessageLayout.codeFenceMarkerCount(in: $0.chatDisplayBody) >= 2
        }
        guard !fenceHeavy.isEmpty else { return }
        // Sync a small batch so the first visible cards bind from cache; rest async.
        let syncBatch = Array(fenceHeavy.suffix(8))
        AssistantMessageLayout.prewarmFenceHeavyLayouts(
            for: syncBatch,
            targetWidth: layoutWidth,
            layoutLimit: syncBatch.count
        )
        let asyncBatch = fenceHeavy.filter { msg in !syncBatch.contains(where: { $0.id == msg.id }) }
        if !asyncBatch.isEmpty {
            scheduleAsyncLayoutPrewarm(assistants: Array(asyncBatch.prefix(24)), layoutWidth: layoutWidth)
        }
        // Fill deferred paints on visible rows without waiting for finger-down.
        _ = hydrateVisibleDeferredNativeCells(maxCount: 4)
    }

    /// Live-tail chase: relayout table, then pin to content + tail cell bottom.
    private func chaseLiveTailToBottom(messages: [ChatMessage],
                                       layoutWidth: CGFloat? = nil,
                                       unlockScroll: Bool = false) {
        remeasureAndPinLiveTail(
            messages: messages,
            layoutWidth: layoutWidth,
            unlockScroll: unlockScroll
        )
    }

    /// Agent process card: offset-only pin — skip `pinOpenViewportToBottom`’s beginUpdates storm.
    private func lightChaseAgentLiveTail() {
        guard tableView.window != nil, tableView.bounds.height > 1 else { return }
        let inset = tableView.adjustedContentInset
        let minY = -inset.top
        let contentH = tableView.contentSize.height
        guard contentH > 1 else { return }
        let maxY = max(minY, contentH + inset.bottom - tableView.bounds.height)
        if abs(tableView.contentOffset.y - maxY) > 0.5 {
            tableView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
        }
    }

    /// Study / live-tail: UITableView must relayout before contentSize reflects new rows.
    private func remeasureAndPinLiveTail(messages: [ChatMessage],
                                         layoutWidth: CGFloat? = nil,
                                         unlockScroll: Bool = false) {
        guard canPinViewport(for: messages) else {
            if unlockScroll { unlockScrollAfterFinishPin() }
            return
        }
        pinOpenViewportToBottom(messages, layoutWidth: layoutWidth)
        if unlockScroll {
            unlockScrollAfterFinishPin()
        }
    }

    /// Commit visible streaming tail paint so heightForRowAt / contentSize stay in sync.
    private func syncStreamingTailPaint(messages: [ChatMessage]) {
        guard let last = messages.last, last.isStreaming else { return }
        let path = IndexPath(row: messages.count - 1, section: 0)
        guard let cell = tableView.cellForRow(at: path) as? AssistantMessageCell,
              cell.messageID == last.id else { return }
        let fitted = cell.fittedStreamingRowHeight() - ChatRowHeightResolver.cellVerticalMargin
        if fitted > 40 {
            rowHeights.commitMeasured(columnHeight: fitted, messageID: last.id, allowShrink: false)
        }
    }

    /// Re-pin after study chrome / width / deferred layout when we should open at the latest turn.
    func ensureBottomPinnedIfNeeded(messages: [ChatMessage]? = nil) {
        guard stickToBottom || finishViewportLocked || isCurrentStreaming else { return }
        guard finishViewportLocked || isCurrentStreaming || !isViewportPinned() else { return }
        let msgs = messages ?? renderedConversationMessages()
        guard let msgs = msgs, !msgs.isEmpty, tableView.window != nil else { return }
        if isCurrentStreaming || finishViewportLocked {
            chaseLiveTailToBottom(messages: msgs, layoutWidth: currentRenderWidth())
        } else {
            pinFinishedTailViewport(messages: msgs, layoutWidth: currentRenderWidth())
        }
    }

    /// Whether the chat was following the live/latest turn (capture before panel animation).
    var wantsBottomChaseForPanelResize: Bool {
        stickToBottom || finishViewportLocked || isCurrentStreaming
    }

    /// After half↔full length change: force chase bottom if we were sticking / streaming.
    /// Panel animation can briefly desync contentOffset vs bounds and mark readingHistory.
    func rePinLatestTurnAfterStudyPanelResize(force: Bool = false) {
        guard isViewLoaded, tableView.window != nil else { return }
        guard force || stickToBottom || finishViewportLocked || isCurrentStreaming else { return }
        stickToBottom = true
        readingHistory = false
        viewportPinnedByUser = false
        viewportScrollAnchor = nil
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              !messages.isEmpty else {
            snapTableContentOffsetToBottom()
            return
        }
        let layoutWidth = currentRenderWidth()
        chaseLiveTailToBottom(messages: messages, layoutWidth: layoutWidth)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.stickToBottom || self.finishViewportLocked || self.isCurrentStreaming else { return }
            guard let live = self.renderedConversationMessages(), !live.isEmpty else { return }
            self.chaseLiveTailToBottom(messages: live, layoutWidth: self.currentRenderWidth())
        }
    }

    private func scrollToLastRowReliable(_ messages: [ChatMessage]) {
        guard !messages.isEmpty, tableView.window != nil else { return }
        if isCurrentStreaming || finishViewportLocked {
            chaseLiveTailToBottom(messages: messages, layoutWidth: currentRenderWidth())
        } else {
            pinOpenViewportToBottom(messages, layoutWidth: currentRenderWidth())
        }
    }

    /// Scroll so the last row sits flush above the input chrome.
    private func scrollToLastRowBottom(force: Bool = false) {
        guard force || !isViewportPinned() else { return }
        guard let messages = ConversationStore.shared.currentConversation?.messages, !messages.isEmpty else { return }
        snapTableContentOffsetToBottom()
        scheduleUpdateTurnContextBar()
    }

    /// Pin heights from layout cache only (never sync-layout). Safe during open / scroll.
    @discardableResult
    private func commitCachedLayoutHeights(messages: [ChatMessage],
                                           layoutWidth: CGFloat,
                                           rows: [Int],
                                           syncLayoutBudget: Int = 0,
                                           allowGrowCommitted: Bool = false,
                                           allowShrinkCommitted: Bool = false) -> Bool {
        let count = messages.count
        var budget = syncLayoutBudget
        var changed = false
        for row in rows {
            guard row >= 0, row < count else { continue }
            let msg = messages[row]
            guard !msg.isStreaming else { continue }
            if msg.role == .user {
                guard !rowHeights.isCommitted(msg.id) || allowGrowCommitted || allowShrinkCommitted else { continue }
                if let column = ChatRowHeightResolver.estimatedUserColumnContentHeight(
                    for: msg,
                    layoutWidth: layoutWidth
                ), column > 40 {
                    let prior = rowHeights.bestKnownColumnHeight(for: msg.id)
                    if allowShrinkCommitted {
                        guard abs(prior - column) > 2 else { continue }
                        rowHeights.commitMeasured(columnHeight: column, messageID: msg.id, allowShrink: true)
                        changed = true
                    } else {
                        guard !allowGrowCommitted || prior == 0 || column > prior + 3 else { continue }
                        rowHeights.commitMeasured(columnHeight: column, messageID: msg.id, allowShrink: false)
                        changed = true
                    }
                }
                continue
            }
            guard msg.role == .assistant else { continue }
            if AssistantMessageLayout.hasCachedNativeLayout(for: msg, layoutWidth: layoutWidth),
               let column = AssistantMessageLayout.estimatedColumnContentHeight(
                   for: msg,
                   layoutWidth: layoutWidth,
                   isLastRow: row == count - 1,
                   allowSyncLayout: true
               ), column > 40 {
                if rowHeights.isCommitted(msg.id), !allowGrowCommitted, !allowShrinkCommitted { continue }
                let prior = rowHeights.bestKnownColumnHeight(for: msg.id)
                if allowShrinkCommitted {
                    guard abs(prior - column) > 2 else { continue }
                    rowHeights.commitMeasured(columnHeight: column, messageID: msg.id, allowShrink: true)
                    changed = true
                } else {
                    guard !allowGrowCommitted || prior == 0 || column > prior + 3 else { continue }
                    rowHeights.commitMeasured(columnHeight: column, messageID: msg.id, allowShrink: false)
                    changed = true
                }
                if rowHeights.isScrollHeightFrozen {
                    _ = rowHeights.growFrozenRowHeightIfNeeded(messageID: msg.id, columnHeight: column)
                }
                continue
            }
            guard !rowHeights.isCommitted(msg.id) else { continue }
            guard budget > 0 else { continue }
            if let column = AssistantMessageLayout.estimatedColumnContentHeight(
                for: msg,
                layoutWidth: layoutWidth,
                isLastRow: row == count - 1,
                allowSyncLayout: true
            ), column > 40 {
                rowHeights.commitMeasured(columnHeight: column, messageID: msg.id, allowShrink: false)
                if rowHeights.isScrollHeightFrozen {
                    _ = rowHeights.growFrozenRowHeightIfNeeded(messageID: msg.id, columnHeight: column)
                }
                changed = true
                budget -= 1
            }
        }
        return changed
    }

    /// After first paint: light visible pin + async history warm. Cancellable — must not block switching.
    private func settleOpenConversation(messages: [ChatMessage], layoutWidth: CGFloat) {
        guard tableMatchesMessages(messages),
              !tableView.isDragging,
              !tableView.isDecelerating else { return }
        let visible = tableView.indexPathsForVisibleRows ?? []
        var heightChanged = false
        for path in visible where path.row < messages.count {
            let msg = messages[path.row]
            guard !msg.isStreaming,
                  let cell = tableView.cellForRow(at: path) as? MessageCellType else { continue }
            if let assistant = cell as? AssistantMessageCell {
                assistant.ensureActionButtonsVisible(for: msg, requireBodyAlignment: true)
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
            eagerPreparePendingHistoryHeightsAtBottom()
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
        openBottomStickActive = false
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
        let tailAlreadyAligned = !tailActionChromeOverlapsInputBar(messages: settledMessages)
        if !tailAlreadyAligned {
            revealVisibleActionChrome(messages: settledMessages)
            guard openPaintStillValid(generation: generation, openID: openID) else { return }
            reconcileVisibleRowHeights(preserveBottom: !isViewportPinned())
            if shrinkInflatedVisibleRows(messages: settledMessages) {
                UIView.performWithoutAnimation {
                    tableView.beginUpdates()
                    tableView.endUpdates()
                }
            }
            guard openPaintStillValid(generation: generation, openID: openID) else { return }
            if !isViewportPinned() {
                pinOpenViewportToBottom(settledMessages)
            }
        }
        scheduleIdleOpenBackgroundWork(
            generation: generation,
            openID: openID,
            layoutWidth: layoutWidth,
            tailAligned: tailAlreadyAligned
        )
    }

    /// Paint history / hydrate native / prewarm — only after scroll and sidebar can respond.
    private func scheduleIdleOpenBackgroundWork(generation: UInt,
                                                openID: String?,
                                                layoutWidth: CGFloat,
                                                tailAligned: Bool) {
        openIdleBackgroundWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.tableView.isDragging || self.tableView.isDecelerating {
                self.scheduleIdleOpenBackgroundWork(
                    generation: generation,
                    openID: openID,
                    layoutWidth: layoutWidth,
                    tailAligned: tailAligned
                )
                return
            }
            guard self.openPaintStillValid(generation: generation, openID: openID),
                  let messages = self.openMessages(for: openID) else { return }
            self.runIdleOpenBackgroundWork(
                messages: messages,
                layoutWidth: layoutWidth,
                generation: generation,
                openID: openID,
                tailAligned: tailAligned
            )
        }
        openIdleBackgroundWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func runIdleOpenBackgroundWork(messages: [ChatMessage],
                                           layoutWidth: CGFloat,
                                           generation: UInt,
                                           openID: String?,
                                           tailAligned: Bool) {
        guard openPaintStillValid(generation: generation, openID: openID) else { return }
        paintVisibleOpenHistoryIfCached(messages: messages, layoutWidth: layoutWidth)
        guard openPaintStillValid(generation: generation, openID: openID) else { return }
        hydrateDeferredNativeRendersIncremental(
            priorityBottomCount: 2,
            generation: generation,
            openID: openID
        )
        guard openPaintStillValid(generation: generation, openID: openID) else { return }
        if !tailAligned {
            settleOpenConversation(messages: messages, layoutWidth: layoutWidth)
        }
        let tail = Array(messages.suffix(Self.switchPrewarmMessageWindow))
        let assistants = tail.filter { $0.role == .assistant && !$0.isStreaming }
        if !assistants.isEmpty {
            scheduleAsyncLayoutPrewarm(assistants: assistants, layoutWidth: layoutWidth)
        }
        scheduleIdleConversationPrewarm()
    }

    /// One visible cell per runloop turn — avoids freezing scroll / sidebar on iOS 12.
    private func hydrateDeferredNativeRendersIncremental(priorityBottomCount: Int?,
                                                         generation: UInt,
                                                         openID: String?) {
        guard openPaintStillValid(generation: generation, openID: openID) else { return }
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
        let item = pending[0]
        item.cell.applyDeferredNativeRenderIfNeeded()
        if pending.count > 1, !tableView.isDragging, !tableView.isDecelerating {
            DispatchQueue.main.async { [weak self] in
                self?.hydrateDeferredNativeRendersIncremental(
                    priorityBottomCount: max((priorityBottomCount ?? pending.count) - 1, 1),
                    generation: generation,
                    openID: openID
                )
            }
        } else if !isViewportPinned() {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
        }
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

    private func forceSnapOpenToBottom(_ messages: [ChatMessage], layoutWidth: CGFloat? = nil) {
        pinOpenViewportToBottom(messages, layoutWidth: layoutWidth)
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
        if preserveBottom, stickToBottom, !isViewportPinned() {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
                scrollToLastRowReliable(messages)
            }
        } else {
            let anchor = tableView.indexPathsForVisibleRows?.min(by: { $0.row < $1.row })
            remeasureRowsPreservingViewport(anchorPath: anchor)
            if isViewportPinned() {
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
            self.updateAttachAvailability()
            self.updateTitleFromConversation()
            self.refreshSwitchChromeImmediate()
            if self.stickToBottom, !messages.isEmpty, !self.openTailHasSubstantialPaint(in: messages) {
                self.primeOpenBottomPresentation(messages: messages, layoutWidth: layoutWidth)
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
            resolvedUserIndex = userTurnStartRows(in: messages).last
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
            resolvedUserIndex = visibleUserIndex(forMessageAt: anchorIndex, in: messages)
        }

        guard let resolvedUserIndex = resolvedUserIndex else {
            contextUserIndex = nil
            turnContextBar.update(question: nil, visible: false)
            return
        }

        if isJumpingToTurn || pinnedJumpUserRow != nil,
           let locked = contextUserIndex,
           locked >= 0, locked < messages.count,
           messages[locked].role == .user,
           !messages[locked].shouldHideInTranscript,
           locked == resolvedUserIndex {
            turnContextBar.update(
                question: userQuestionPreview(messages[locked]),
                visible: true
            )
            return
        }

        contextUserIndex = resolvedUserIndex
        turnContextBar.update(
            question: userQuestionPreview(messages[resolvedUserIndex]),
            visible: true
        )
    }

    /// Nearest visible (non-hidden) user turn at or before `index`.
    private func visibleUserIndex(forMessageAt index: Int, in messages: [ChatMessage]) -> Int? {
        let turns = userTurnStartRows(in: messages)
        guard !turns.isEmpty else { return nil }
        guard index >= 0 else { return turns.first }
        if let exact = turns.last(where: { $0 <= index }) { return exact }
        return turns.first
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

        isJumpingToTurn = true
        cancelViewportAutoPin()
        contextUserIndex = index
        pinnedJumpUserRow = index
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
            syncLayoutBudget: min(4, prefixRows.count)
        )

        let path = IndexPath(row: index, section: 0)
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()
            tableView.scrollToRow(at: path, at: .top, animated: false)
            tableView.layoutIfNeeded()
            applyUserQuestionPinnedToTop(at: index, animated: false)
            viewportScrollAnchor = (index, tableView.rectForRow(at: path).minY - tableView.contentOffset.y)
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
                applyUserQuestionPinnedToTop(at: index, animated: false)
                let path = IndexPath(row: index, section: 0)
                viewportScrollAnchor = (index, tableView.rectForRow(at: path).minY - tableView.contentOffset.y)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            refine()
            self.scheduleUpdateTurnContextBar()
        }

        let work = DispatchWorkItem { [weak self] in
            self?.refineJumpAnchorIfNeeded(at: index, path: path)
            self?.isJumpingToTurn = false
        }
        jumpAnchorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func refineJumpAnchorIfNeeded(at index: Int, path: IndexPath) {
        guard contextUserIndex == index,
              index < tableView.numberOfRows(inSection: 0) else { return }
        UIView.performWithoutAnimation {
            tableView.layoutIfNeeded()
            applyUserQuestionPinnedToTop(at: index, animated: false)
            viewportScrollAnchor = (index, tableView.rectForRow(at: path).minY - tableView.contentOffset.y)
        }
    }

    /// Pin the user question row flush to the top of the chat viewport (below turn context bar).
    private func applyUserQuestionPinnedToTop(at row: Int, animated: Bool) {
        guard row >= 0, row < tableView.numberOfRows(inSection: 0) else { return }
        tableView.layoutIfNeeded()
        let path = IndexPath(row: row, section: 0)
        let insetTop = tableView.adjustedContentInset.top
        let minY = -insetTop
        let maxY = max(
            minY,
            tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
        )

        let rowRect = tableView.rectForRow(at: path)
        var targetY = rowRect.minY - insetTop
        if let cell = tableView.cellForRow(at: path) as? UserMessageCell,
           let bubbleY = cell.userBubbleTop(in: tableView) {
            targetY = bubbleY - insetTop
        }
        targetY = min(max(targetY, minY), maxY)

        if animated {
            tableView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
        } else {
            tableView.contentOffset.y = targetY
        }
    }

    /// Scroll so the user input bubble sits just under the context bar.
    private func applyUserBubbleScrollAnchor(at row: Int, animated: Bool) {
        applyUserQuestionPinnedToTop(at: row, animated: animated)
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
        for (number, index) in userTurnStartRows(in: messages).enumerated() {
            guard messages.indices.contains(index) else { continue }
            turns.append(UserTurn(
                index: index,
                number: number + 1,
                preview: userQuestionPreview(messages[index])
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
            from: menuPresentingViewController(),
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

    /// Same conversation, bulk new messages (fixture / store reload): reset history-scroll session.
    private func prepareInPlaceThreadContentRefresh(messages: [ChatMessage], layoutWidth: CGFloat) {
        if rowHeights.isScrollHeightFrozen {
            rowHeights.endScrollHeightFreeze()
        }
        readingHistory = false
        stickToBottom = true
        viewportPinnedByUser = false
        gestureLockedScrollAnchorRow = nil
        needsFirstHistoryScrollPrep = true
        hasCompletedFirstHistoryScrollGesture = false
        if usesStudyHeightBucketPolicy() {
            pendingStudyFirstScrollPrep = true
        }
        rowHeights.rebuildDisplayHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            layoutProbeTailRows: min(messages.count, 40)
        )
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
        if reloadMessages {
            reloadTablePreservingViewport()
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { DSTheme.c.statusBarStyle }

    @objc private func themeChanged() {
        ChatViewController.attrCache.removeAllObjects()
        PlainMarkdown.clearCache()
        NativeMessageLayouter.shared.clear()
        NativeFormulaRenderer.shared.clear()
        applyTheme(reloadMessages: true)
        prewarmVisibleRichReplies(for: currentRenderWidth())
    }

    @objc private func storeChanged(_ note: Notification) {
        if let source = note.userInfo?["source"] as? String, source == "select" {
            let targetID = ConversationStore.shared.currentConversationID
            let layoutWidth = currentRenderWidth()
            updateTitleFromConversation()
            updateModelButton()
            updateEmptyState()
            syncStreamingChrome()
            // Empty "新对话" can bind immediately — deferring a runloop felt like a stuck window.
            let messagesEmpty = ConversationStore.shared.currentConversation?.messages.isEmpty == true
            let bind = { [weak self] in
                guard let self = self, targetID == self.currentConversationID else { return }
                if let id = targetID, id != self.renderedConversationID {
                    self.switchToConversation(id: id)
                }
                self.updateStudyInputBar()
                self.finishConversationSwitchChrome(layoutWidth: layoutWidth)
            }
            if messagesEmpty {
                bind()
            } else {
                DispatchQueue.main.async(execute: bind)
            }
            return
        }
        if isReloadingFromStore {
            needsDeferredStoreReload = true
            return
        }
        if let source = note.userInfo?["source"] as? String, source == "projectFilter" {
            return
        }
        if let source = note.userInfo?["source"] as? String, source == "archiveFilter" {
            return
        }
        if let source = note.userInfo?["source"] as? String, source == "title" {
            updateTitleFromConversation()
            return
        }
        if let source = note.userInfo?["source"] as? String, source == "model" {
            updateModelButton()
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
        if finishViewportLocked || stickToBottom {
            followStreamingViewportToBottom()
        }
    }

    @objc private func webSearchUpdated(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else { return }
        syncStreamingChrome()
        ensureStreamUITimer()
    }

    func messageCellDidTapChromeViewer(_ cell: MessageCellType,
                                       messageID: String,
                                       kind: MessageExpandableChromeKind) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let row = messages.firstIndex(where: { $0.id == messageID }),
              messages[row].role == .assistant else {
            reloadTablePreservingViewport()
            return
        }
        let message = messages[row]
        let pairedUser = pairedUserMessage(forAssistantAt: row, in: messages)
        let title: String
        let body: String
        switch kind {
        case .thinking:
            title = "深度思考"
            body = message.reasoningContent
        case .search:
            if message.hasImageTranscription {
                title = message.imageTranscriptionPhase.headerTitle
                body = message.imageTranscriptionDisplayText(pairedUser: pairedUser)
            } else if message.hasAgentProcess {
                title = "工作流"
                body = message.agentProcessDisplayText
            } else {
                title = "搜索过程"
                body = message.searchProcessContent
            }
        }
        let sourceView = cell.contentView
        MessageChromeViewerViewController.present(
            from: self,
            title: title,
            body: body,
            sourceView: sourceView
        )
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

    @objc private func imageTranscriptionSettingChanged() {
        inputBar.syncToolTogglesFromSettings()
        if SettingsManager.shared.imageTranscriptionEnabled {
            queueLegacyImageTranscriptionIfNeeded()
        }
    }

    @objc private func nativeFormulaDidRender() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyNativeFormulaRerender), object: nil)
        perform(#selector(applyNativeFormulaRerender), with: nil, afterDelay: 0.05)
    }

    @objc private func applyNativeFormulaRerender() {
        NativeMessageLayouter.shared.clear()
        guard let messages = renderedConversationMessages() else { return }
        let width = currentRenderWidth()
        for path in tableView.indexPathsForVisibleRows ?? [] {
            guard path.row < messages.count,
                  let cell = tableView.cellForRow(at: path) as? MessageCellType else { continue }
            reconfigureVisibleCell(cell, at: path, messages: messages, layoutWidth: width)
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

    @objc private func streamTTFT(_ note: Notification) {
        #if DEBUG
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID,
              let ms = note.userInfo?["ms"] as? Int,
              let host = note.userInfo?["host"] as? String else { return }
        guard ms >= 4000 else { return }
        let think = (note.userInfo?["thinking"] as? Bool) ?? false
        let tip = "首包 \(ms)ms · \(host)\(think ? " · 思考开" : " · Instant")"
        ConnectsToast.show(tip, in: view, duration: 2.2)
        #endif
    }

    @objc private func imageTranscriptionUpdated(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else { return }
        ConversationStore.shared.repairImageTranscriptionDisplays(for: id)
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let layoutWidth = currentRenderWidth()
        UIView.performWithoutAnimation {
            for (row, message) in messages.enumerated() where message.role == .assistant && message.hasImageTranscription {
                let path = IndexPath(row: row, section: 0)
                rowHeights.invalidate(messageID: message.id)
                let pairedUser = pairedUserMessage(forAssistantAt: row, in: messages)
                if let cell = tableView.cellForRow(at: path) as? AssistantMessageCell {
                    if message.isStreaming {
                        if !cell.updateStreamingContent(message) {
                            cell.configure(
                                with: message,
                                preferredHeight: nil,
                                layoutWidth: layoutWidth,
                                pairedUser: pairedUser
                            )
                        }
                    } else {
                        cell.syncSearchPresentation(with: message, layoutWidth: layoutWidth, pairedUser: pairedUser)
                    }
                } else {
                    tableView.reloadRows(at: [path], with: .none)
                }
            }
            tableView.beginUpdates()
            tableView.endUpdates()
        }
        refreshContextUsage()
    }

    private func pairedUserMessage(forAssistantAt row: Int, in messages: [ChatMessage]) -> ChatMessage? {
        guard row > 0,
              messages[row].role == .assistant,
              messages[row - 1].role == .user else { return nil }
        return messages[row - 1]
    }

    @objc private func retryImageTranscription(_ note: Notification) {
        guard SettingsManager.shared.imageTranscriptionEnabled else {
            showAlert(title: "图片转写已关闭", message: "可在设置或输入栏取景框图标重新开启。")
            return
        }
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
        // Study turns with reading context already carry durable page text —
        // do not re-run OCR (it would leak source into「图片转写」).
        if user.apiContextPrefix?.contains("[阅读上下文") == true {
            showAlert(title: "无需转写", message: "该消息已附带阅读页文字，不必再做图片转写。")
            return
        }
        let model = AIModelOption.preferredImageTranscription
        ImageTranscriptionCoordinator.shared.start(
            conversationID: conversation.id,
            userMessageID: user.id,
            assistantMessageID: assistantID,
            base64: base64,
            model: model,
            studyPagePDFText: nil
        )
    }

    /// After stream ends: collapse chrome, shrink stale streaming heights, chase bottom
    /// while native body/layout finishes (study half + full AI panels).
    private func settleFinishedStreamViewport(finishedMessageID: String,
                                              conversationID: String,
                                              unlockScrollWhenDone: Bool) {
        let settleDelays: [TimeInterval] = [0.1, 0.28, 0.58, 1.0, 1.6]

        func pass(unlock: Bool) {
            guard currentConversationID == conversationID,
                  let messages = ConversationStore.shared.conversation(id: conversationID)?.messages,
                  let row = messages.firstIndex(where: { $0.id == finishedMessageID }),
                  row < messages.count,
                  !messages[row].isStreaming else {
                if unlock { unlockScrollAfterFinishPin() }
                return
            }
            pinFinishedTailViewport(
                messages: messages,
                layoutWidth: currentRenderWidth(),
                unlockScroll: unlock
            )
        }

        pass(unlock: false)
        for (i, delay) in settleDelays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self != nil else { return }
                let unlock = unlockScrollWhenDone && i == settleDelays.count - 1
                pass(unlock: unlock)
            }
        }
        if !unlockScrollWhenDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelays.last! + 0.08) { [weak self] in
                self?.unlockScrollAfterFinishPin()
            }
        }
    }

    @objc private func streamFinished(_ note: Notification) {
        guard let id = note.userInfo?["conversationID"] as? String,
              id == currentConversationID else { return }
        streamUIWork?.cancel()
        streamUIWork = nil
        stopStreamUITimer()
        // Streaming stays lightweight; completion performs one deterministic
        // native parse/layout and swaps under the cell snapshot cover.
        let repairID = id
        DispatchQueue.main.async {
            ConversationStore.shared.repairImageTranscriptionDisplays(for: repairID)
        }
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let last = messages.last else { return }
        syncStreamingChrome()
        let path = IndexPath(row: messages.count - 1, section: 0)
        let pairedUser = pairedUserMessage(forAssistantAt: path.row, in: messages)
        rowHeights.invalidate(messageID: last.id)
        pendingHeights.removeValue(forKey: last.id)
        let finishedID = last.id
        if let visibleCell = tableView.cellForRow(at: path) as? AssistantMessageCell,
           visibleCell.messageID == last.id {
            let layoutWidth = currentRenderWidth()
            visibleCell.syncThinkingPresentation(with: last, layoutWidth: layoutWidth)
            visibleCell.syncSearchPresentation(with: last, layoutWidth: layoutWidth, pairedUser: pairedUser)
            visibleCell.finalizeStreamingPresentation(last)
            visibleCell.finishChromeToggleLayout()
            let measured = visibleCell.transitionToFinishedPlainRendering(
                last,
                preferredHeight: nil,
                pairedUser: pairedUser
            )
            if let measured = measured, measured > 40 {
                rowHeights.commitMeasured(columnHeight: measured, messageID: last.id, allowShrink: true)
            } else {
                let projected = visibleCell.projectedColumnHeight(for: last, layoutWidth: layoutWidth)
                if projected > 40 {
                    rowHeights.commitMeasured(columnHeight: projected, messageID: last.id, allowShrink: true)
                }
            }
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
                tableView.layoutIfNeeded()
            }
            settleFinishedStreamViewport(
                finishedMessageID: finishedID,
                conversationID: id,
                unlockScrollWhenDone: true
            )
        } else if path.row < tableView.numberOfRows(inSection: 0) {
            UIView.performWithoutAnimation {
                tableView.reloadRows(at: [path], with: .none)
                tableView.layoutIfNeeded()
            }
            settleFinishedStreamViewport(
                finishedMessageID: finishedID,
                conversationID: id,
                unlockScrollWhenDone: true
            )
        } else {
            unlockScrollAfterFinishPin()
        }
        maybeAutoCompactContext()
        handleWorkspaceAgentIfNeeded(conversationID: id, finishedMessage: last)
    }

    private func handleWorkspaceAgentIfNeeded(conversationID: String, finishedMessage: ChatMessage) {
        guard finishedMessage.role == .assistant, !finishedMessage.isStreaming,
              StudyAgentMode.isAgentProductEnabled,
              let conv = ConversationStore.shared.conversation(id: conversationID),
              conv.isWorkspaceStudySession,
              let wsID = conv.activeStudyWorkspaceID else {
            agentToolRoundCounts[conversationID] = 0
            agentProcessRootIDs[conversationID] = nil
            handleCodeEditProposalIfNeeded(conversationID: conversationID, finishedMessage: finishedMessage)
            return
        }

        let raw = finishedMessage.content
        let visible = AgentTools.strippingToolBlocksForDisplay(
            from: CodeEditApplyTools.chatVisibleContent(raw)
        )
        let rootIDHint = agentProcessRootIDs[conversationID] ?? finishedMessage.id
        if visible != raw {
            let isRoot = finishedMessage.id == rootIDHint
            let cleaned: String
            if visible.isEmpty || visible == "（工具步骤已执行）" {
                // Root keeps process chrome only; mid-loop shells stay empty for later hide.
                cleaned = ""
            } else {
                cleaned = visible
            }
            persistStrippedEditMessage(
                conversationID: conversationID,
                messageID: finishedMessage.id,
                content: cleaned
            )
            _ = isRoot
        }

        // Seed process chrome on the root only (not mid-loop assistants).
        let calls = AgentTools.parseToolCalls(from: raw)
        if !calls.isEmpty {
            ConversationStore.shared.updateConversationQuietly(id: conversationID) { draft in
                let rootSeed = self.agentProcessRootIDs[conversationID] ?? finishedMessage.id
                guard let idx = draft.messages.lastIndex(where: { $0.id == rootSeed }) else { return }
                if draft.messages[idx].agentProcessPhase == .idle {
                    draft.messages[idx].agentProcessPhase = .running
                }
                if draft.messages[idx].agentProcessStartedAt == nil {
                    draft.messages[idx].agentProcessStartedAt = Date()
                }
            }
        }

        let round = agentToolRoundCounts[conversationID, default: 0]
        if AgentOrchestrator.shared.currentRoundCapReached(count: round) {
            let cappedRoot = agentProcessRootIDs[conversationID] ?? finishedMessage.id
            ConversationStore.shared.updateConversationQuietly(id: conversationID) { draft in
                if let idx = draft.messages.lastIndex(where: { $0.id == cappedRoot }) {
                    draft.messages[idx].agentProcessPhase = .done
                }
            }
            agentToolRoundCounts[conversationID] = 0
            agentProcessRootIDs[conversationID] = nil
            stopStreamUITimer()
            handleCodeEditProposalIfNeeded(conversationID: conversationID, finishedMessage: finishedMessage)
            if renderedConversationID == conversationID {
                refreshAssistantRowAfterEditStrip(messageID: cappedRoot)
                if finishedMessage.id != cappedRoot {
                    refreshAssistantRowAfterEditStrip(messageID: finishedMessage.id)
                }
                ConnectsToast.show("已达本回合工具上限，已停止", in: view, duration: 2.0)
            }
            return
        }

        let rootID = agentProcessRootIDs[conversationID] ?? finishedMessage.id
        agentProcessRootIDs[conversationID] = rootID

        // If Build plan is already fully checked off, stop — don't keep looping.
        if let planID = activePlanDocumentID,
           let text = StudyDocumentStore.shared.textContent(for: planID) {
            let plan = StudyPlanDocument.parse(text)
            if !plan.todos.isEmpty, plan.todos.allSatisfy(\.done) {
                finishWorkspaceAgentTurn(
                    conversationID: conversationID,
                    rootID: rootID,
                    finishedMessage: finishedMessage,
                    waiting: false
                )
                ConnectsToast.show("计划已全部完成", in: view, duration: 1.8)
                return
            }
        }

        // Tool I/O off the main thread — sync execute was freezing the whole app.
        let mode = conv.studyAgentMode
        let roundCapture = round
        let isAgentMode = mode == .agent
        if isAgentMode {
            WorkspaceAgentRuntime.shared.beginEditBatch(
                conversationID: conversationID,
                rootMessageID: rootID,
                workspaceID: wsID
            )
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let continued = AgentOrchestrator.shared.handleAssistantFinished(
                conversationID: conversationID,
                assistantMessageID: finishedMessage.id,
                content: raw,
                workspaceID: wsID,
                mode: mode,
                model: streamModel(for: conv.model, hasImages: false),
                appendStep: { [weak self] step in
                    DispatchQueue.main.async {
                        self?.mutateAgentSteps(conversationID: conversationID, messageID: rootID) { msg in
                            msg.agentProcessPhase = .running
                            msg.agentProcessSteps.append(step)
                            msg.upsertMetaPart(from: step)
                        }
                    }
                },
                updateStep: { [weak self] step in
                    DispatchQueue.main.async {
                        self?.mutateAgentSteps(conversationID: conversationID, messageID: rootID) { msg in
                            if let i = msg.agentProcessSteps.firstIndex(where: { $0.id == step.id }) {
                                msg.agentProcessSteps[i] = step
                            } else {
                                msg.agentProcessSteps.append(step)
                            }
                            msg.upsertMetaPart(from: step)
                        }
                    }
                },
                onProposeEdit: { path, body in
                    if isAgentMode {
                        WorkspaceAgentRuntime.shared.enqueueProposedEdit(path: path, body: body)
                    } else {
                        DispatchQueue.main.async { [weak self] in
                            self?.presentAgentProposedEdit(
                                path: path,
                                body: body,
                                assistantMessageID: finishedMessage.id
                            )
                        }
                    }
                },
                onPlanUpdate: { [weak self] planMarkdown in
                    DispatchQueue.main.async {
                        if mode == .plan || self?.activePlanDocumentID != nil {
                            self?.syncActivePlanFile(planMarkdown: planMarkdown)
                        }
                    }
                },
                requestContinuation: { [weak self] toolResults in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if isAgentMode {
                            self.flushAgentEditBatchAndPresentDiff(rootID: rootID)
                        }
                        self.agentToolRoundCounts[conversationID] = roundCapture + 1
                        self.continueWorkspaceAgent(
                            conversationID: conversationID,
                            priorAssistantID: finishedMessage.id,
                            rootAssistantID: rootID,
                            priorAssistantRaw: raw,
                            priorAssistantReasoning: finishedMessage.reasoningContent,
                            toolResults: toolResults
                        )
                    }
                }
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if isAgentMode, !continued {
                    self.flushAgentEditBatchAndPresentDiff(rootID: rootID)
                }
                if continued {
                    // Keep a light planning pulse until the next stream starts.
                    self.ensureStreamUITimer()
                    return
                }
                let waiting = AgentOrchestrator.shared.waitingAskPrompt != nil
                self.finishWorkspaceAgentTurn(
                    conversationID: conversationID,
                    rootID: rootID,
                    finishedMessage: finishedMessage,
                    waiting: waiting
                )
                if let prompt = AgentOrchestrator.shared.waitingAskPrompt {
                    ConversationStore.shared.updateConversationQuietly(id: conversationID) { draft in
                        guard let idx = draft.messages.lastIndex(where: { $0.id == rootID }) else { return }
                        draft.messages[idx].appendAskPart(String(prompt))
                        draft.messages[idx].agentProcessPhase = .waitingUser
                    }
                    self.refreshAgentProcessChrome(messageID: rootID)
                    ConnectsToast.show("Agent 提问：\(prompt.prefix(80))", in: self.view, duration: 2.4)
                }
            }
        }
    }

    /// One Diff open + banner refresh per tool batch (Agent mode).
    private func flushAgentEditBatchAndPresentDiff(rootID: String) {
        let result = WorkspaceAgentRuntime.shared.flushEditBatch { [weak self] path, body in
            self?.applyPlanFileEditIfNeeded(path: path, body: body)
        }
        refreshWorkspaceDiffBanner()
        if let docID = result.firstDiffDocumentID {
            studyContextProvider?.studyCodeDiffOpen(documentID: docID)
        }
        if renderedConversationID != nil {
            refreshAgentProcessChrome(messageID: rootID)
        }
    }

        private func finishWorkspaceAgentTurn(conversationID: String,
                                          rootID: String,
                                          finishedMessage: ChatMessage,
                                          waiting: Bool) {
        ConversationStore.shared.updateConversationQuietly(id: conversationID) { draft in
            if let idx = draft.messages.lastIndex(where: { $0.id == rootID }) {
                draft.messages[idx].agentProcessPhase = waiting ? .waitingUser : .done
                if waiting, let prompt = AgentOrchestrator.shared.waitingAskPrompt {
                    draft.messages[idx].appendAskPart(prompt)
                }
                draft.messages[idx].sealThoughtFromReasoningIfNeeded()
                // Commit final-round prose into timeline parts (OpenCode: answer once at done).
                let visible = AgentTools.strippingToolBlocksForDisplay(
                    from: CodeEditApplyTools.chatVisibleContent(draft.messages[idx].content)
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !visible.isEmpty, visible != "（工具步骤已执行）" {
                    let lastPart = draft.messages[idx].agentTimelineParts.last(where: { $0.kind == .prose })?.text
                    if lastPart != visible {
                        draft.messages[idx].appendProsePart(visible)
                    }
                }
            }
            // Legacy mid-loop shells: fold prose into root and hide.
            if finishedMessage.id != rootID,
               let idx = draft.messages.lastIndex(where: { $0.id == finishedMessage.id }) {
                let rawBody = draft.messages[idx].content
                let visible = AgentTools.strippingToolBlocksForDisplay(
                    from: CodeEditApplyTools.chatVisibleContent(rawBody)
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if let rootIdx = draft.messages.lastIndex(where: { $0.id == rootID }),
                   !visible.isEmpty,
                   visible != "（工具步骤已执行）" {
                    let last = draft.messages[rootIdx].agentProseSegments.last
                    if last != visible {
                        draft.messages[rootIdx].agentProseSegments.append(visible)
                        draft.messages[rootIdx].appendProsePart(visible)
                    }
                    if draft.messages[rootIdx].content
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        draft.messages[rootIdx].content = visible
                    }
                }
                draft.messages[idx].isHiddenInTranscript = true
                draft.messages[idx].content = ""
                draft.messages[idx].reasoningContent = ""
                draft.messages[idx].agentProcessSteps = []
                draft.messages[idx].agentProcessPhase = .idle
                draft.messages[idx].agentProcessStartedAt = nil
            }
        }
        agentToolRoundCounts[conversationID] = 0
        if !waiting {
            agentProcessRootIDs[conversationID] = nil
            AgentOrchestrator.shared.endTurnDedup(for: conversationID)
            stopStreamUITimer()
        }
        handleCodeEditProposalIfNeeded(conversationID: conversationID, finishedMessage: finishedMessage)
        if renderedConversationID == conversationID {
            refreshAssistantRowAfterEditStrip(messageID: rootID)
            if finishedMessage.id != rootID {
                refreshAssistantRowAfterEditStrip(messageID: finishedMessage.id)
            }
            refreshBuildTodoChrome()
        }
    }

    private func mutateAgentSteps(
        conversationID: String,
        messageID: String,
        _ body: (inout ChatMessage) -> Void
    ) {
        ConversationStore.shared.updateConversationQuietly(id: conversationID) { draft in
            guard let idx = draft.messages.lastIndex(where: { $0.id == messageID }) else { return }
            body(&draft.messages[idx])
        }
        if renderedConversationID == conversationID {
            refreshAgentProcessChrome(messageID: messageID)
        }
    }

    /// Paint agent timeline chrome without rematerializing the whole assistant row.
    private func refreshAgentProcessChrome(messageID: String) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let row = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = messages[row]
        guard message.hasAgentProcess || message.showsProcessChrome else { return }
        let path = IndexPath(row: row, section: 0)
        let layoutWidth = currentRenderWidth()
        let agentLive = message.isStreaming
            || message.agentProcessPhase == .running
            || message.agentProcessPhase == .waitingUser
        let liveOverlay: String? = {
            guard agentLive, message.agentProcessPhase != .waitingUser else { return nil }
            let reason = message.reasoningContent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isStreaming {
                return reason.isEmpty
                    ? AgentProcessPhase.planningNextMovesText
                    : AgentProcessPhase.thinkingText
            }
            // Inter-round gap (tools finished, next stream not yet streaming).
            return AgentProcessPhase.planningNextMovesText
        }()
        UIView.performWithoutAnimation {
            if let cell = tableView.cellForRow(at: path) as? AssistantMessageCell,
               cell.messageID == message.id {
                _ = cell.syncAgentProcessPresentation(
                    with: message,
                    layoutWidth: layoutWidth,
                    liveOverlayText: liveOverlay
                )
                // Mid-tool-loop root is NOT streaming — still forbid beginUpdates here.
                // That path was freezing the whole app on every Explored/Edited step.
                if agentLive {
                    let prior = rowHeights.committedColumnHeight(for: message.id) ?? 0
                    let fitted = cell.fittedStreamingRowHeight()
                        - ChatRowHeightResolver.cellVerticalMargin
                    if fitted > 40 {
                        rowHeights.commitMeasured(
                            columnHeight: fitted,
                            messageID: message.id,
                            allowShrink: false
                        )
                    }
                    // Only chase when the row actually grew — avoids full-page flash.
                    if fitted > prior + 2 {
                        lightChaseAgentLiveTail()
                    }
                    return
                }
                // Off-screen / settled: commit height without chasing — avoid beginUpdates flash.
                let next = cell.fittedColumnContentHeight()
                if next > 40 {
                    rowHeights.commitMeasured(
                        columnHeight: next,
                        messageID: message.id,
                        allowShrink: false
                    )
                }
            }
            // Off-screen: do nothing — avoid reloadRows rematerialize storms.
        }
    }

    private func presentAgentProposedEdit(path: String, body: String, assistantMessageID: String) {
        // Workspace Agent: write + banner + Diff review. Keep All lives on the input bar.
        guard let conv = ConversationStore.shared.currentConversation,
              conv.isWorkspaceStudySession,
              let wsID = conv.activeStudyWorkspaceID else {
            refreshWorkspaceDiffBanner()
            return
        }
        // Study lock: Agent writes only the open file (Plan may stage new plan markdown).
        if conv.studyAgentMode != .plan, !conv.allowsStudyMutating(path: path) {
            ConnectsToast.show("只能编辑当前打开的文件", in: view, duration: 1.6)
            refreshWorkspaceDiffBanner()
            return
        }
        // New-file create only in Plan mode; Agent must edit an already-open document.
        var docID = resolveWorkspaceDocumentID(path: path, workspaceID: wsID)
        var createdFresh = false
        if docID == nil {
            guard conv.studyAgentMode == .plan else {
                refreshWorkspaceDiffBanner()
                return
            }
            let name = (path as NSString).lastPathComponent
            if let created = try? StudyWorkspaceStore.shared.createFile(
                named: name,
                content: "",
                in: wsID
            ) {
                docID = created.id
                createdFresh = true
            }
        }
        guard let docID else {
            refreshWorkspaceDiffBanner()
            return
        }
        let diskNow = StudyDocumentStore.shared.textContent(for: docID) ?? ""
        // Baseline for Keep/Undo:
        // - New file (or create_file already wrote body): empty → body
        // - Existing session entry: freeze original before
        // - Else: disk before this write
        let sessionBefore = WorkspaceEditSession.shared.pending(documentID: docID)?.before
        let before: String
        if let sessionBefore {
            before = sessionBefore
        } else if createdFresh || diskNow == body {
            // create_file already wrote identical content — still reviewable as new file.
            before = ""
        } else {
            before = diskNow
        }
        if before == body, WorkspaceEditSession.shared.pending(documentID: docID) != nil {
            refreshWorkspaceDiffBanner()
            return
        }
        let name = StudyDocumentStore.shared.document(id: docID)?.title
            ?? (path as NSString).lastPathComponent
        let rootID = agentProcessRootIDs[conv.id] ?? assistantMessageID
        let snippets = Self.lightDiffSnippets(before: before, after: body)
        let stats = WorkspaceEditSession.shared.previewLineStats(before: before, after: body)
        // Defer disk write until Keep — session + Diff hold the proposal.
        WorkspaceEditSession.shared.upsert(
            documentID: docID,
            fileName: name,
            before: before,
            after: body
        )
        let card = AgentEditCard(
            fileName: name,
            documentID: docID,
            additions: stats.add,
            deletions: stats.del,
            snippetMinus: snippets.minus,
            snippetPlus: snippets.plus
        )
        ConversationStore.shared.updateConversationQuietly(id: conv.id) { draft in
            guard let idx = draft.messages.lastIndex(where: { $0.id == rootID }) else { return }
            if let existing = draft.messages[idx].agentEditCards.firstIndex(where: {
                $0.documentID == docID || $0.fileName == name
            }) {
                draft.messages[idx].agentEditCards[existing] = card
            } else {
                draft.messages[idx].agentEditCards.append(card)
            }
        }
        applyPlanFileEditIfNeeded(path: path, body: body)
        refreshWorkspaceDiffBanner()
        studyContextProvider?.studyCodeDiffOpen(documentID: docID)
        if renderedConversationID == conv.id {
            refreshAgentProcessChrome(messageID: rootID)
        }
    }

    /// Prefer patch-oriented snippets when before/after share a long common prefix.
    private static func lightDiffSnippets(before: String, after: String) -> (minus: String, plus: String) {
        let a = before.components(separatedBy: .newlines)
        let b = after.components(separatedBy: .newlines)
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        var j = 0
        while j < (a.count - i), j < (b.count - i),
              a[a.count - 1 - j] == b[b.count - 1 - j] { j += 1 }
        let minusSlice = a.dropFirst(i).dropLast(j)
        let plusSlice = b.dropFirst(i).dropLast(j)
        let minus = minusSlice.prefix(4).joined(separator: "\n")
        let plus = plusSlice.prefix(4).joined(separator: "\n")
        return (String(minus.prefix(280)), String(plus.prefix(280)))
    }

    private func continueWorkspaceAgent(
        conversationID: String,
        priorAssistantID: String,
        rootAssistantID: String,
        priorAssistantRaw: String,
        priorAssistantReasoning: String,
        toolResults: String
    ) {
        guard let conv = ConversationStore.shared.conversation(id: conversationID),
              let model = streamModel(for: conv.model, hasImages: false) else { return }

        agentProcessRootIDs[conversationID] = rootAssistantID

        let oldRows = currentConversationID == conversationID
            ? tableView.numberOfRows(inSection: 0)
            : 0

        ConversationStore.shared.updateConversationQuietly(id: conversationID) { draft in
            // Drop legacy mid-loop hidden shells after the root — single visible turn.
            if let rootIdx = draft.messages.lastIndex(where: { $0.id == rootAssistantID }) {
                if rootIdx + 1 < draft.messages.count {
                    draft.messages.removeSubrange((rootIdx + 1)..<draft.messages.count)
                }
            }
            guard let idx = draft.messages.lastIndex(where: { $0.id == rootAssistantID }) else { return }

            draft.messages[idx].agentProcessPhase = .running
            if draft.messages[idx].agentProcessStartedAt == nil {
                draft.messages[idx].agentProcessStartedAt = Date()
            }

            // Seal reasoning before committing mid-round prose / clearing the stream buffers.
            _ = draft.messages[idx].sealThoughtFromReasoningIfNeeded()

            // Mid-loop: keep only short status prose in the timeline; long answers wait for done.
            let proseSource: String = {
                if priorAssistantID == rootAssistantID {
                    return draft.messages[idx].content
                }
                if let priorIdx = draft.messages.lastIndex(where: { $0.id == priorAssistantID }) {
                    return draft.messages[priorIdx].content
                }
                return priorAssistantRaw
            }()
            let stripped = AgentTools.strippingToolBlocksForDisplay(
                from: CodeEditApplyTools.chatVisibleContent(proseSource)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty, stripped != "（工具步骤已执行）" {
                let shortStatus = stripped.count <= 160 && !stripped.contains("\n\n")
                if shortStatus {
                    let lastSeg = draft.messages[idx].agentProseSegments.last
                    if lastSeg != stripped {
                        draft.messages[idx].appendProsePart(stripped)
                    }
                }
            }

            // API-only tool round — never insert table rows.
            let rawForAPI = priorAssistantRaw.isEmpty ? proseSource : priorAssistantRaw
            draft.messages[idx].agentToolTurns.append(
                AgentToolTurn(
                    assistantContent: rawForAPI,
                    assistantReasoning: priorAssistantReasoning,
                    toolResults: toolResults
                )
            )

            // Stream the next round onto the same root bubble.
            draft.messages[idx].content = ""
            draft.messages[idx].reasoningContent = ""
            draft.messages[idx].isStreaming = true
            draft.messages[idx].isHiddenInTranscript = false

            // Hide any leftover prior shell if it still exists (legacy threads).
            if priorAssistantID != rootAssistantID,
               let priorIdx = draft.messages.lastIndex(where: { $0.id == priorAssistantID }) {
                draft.messages[priorIdx].isHiddenInTranscript = true
                draft.messages[priorIdx].content = ""
                draft.messages[priorIdx].reasoningContent = ""
                draft.messages[priorIdx].isStreaming = false
                draft.messages[priorIdx].agentProcessSteps = []
                draft.messages[priorIdx].agentProcessPhase = .idle
            }
        }

        if currentConversationID == conversationID {
            let newCount = ConversationStore.shared.currentConversation?.messages.count ?? oldRows
            syncTableRowCount(from: oldRows, to: newCount)
            refreshAgentProcessChrome(messageID: rootAssistantID)
            syncStreamingChrome()
        }

        buildAPIContextAsync(for: model, conversationID: conversationID) { [weak self] messages in
            self?.startStream(
                conversationID: conversationID,
                messages: messages,
                model: model,
                needsAITitle: false
            )
        }
    }

    /// Keep UITableView row count in lockstep with the data source. Never call
    /// `reloadRows` in the same beat as a count change (that crashes with
    /// NSInternalInconsistencyException).
    private func syncTableRowCount(from oldCount: Int, to newCount: Int) {
        guard oldCount != newCount else { return }
        renderedMessageCount = newCount
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            if newCount > oldCount {
                let paths = (oldCount..<newCount).map { IndexPath(row: $0, section: 0) }
                tableView.insertRows(at: paths, with: .none)
            } else {
                let paths = (newCount..<oldCount).map { IndexPath(row: $0, section: 0) }
                tableView.deleteRows(at: paths, with: .none)
            }
            tableView.endUpdates()
        }
    }

    private func resolveWorkspaceDocumentID(path: String, workspaceID: String) -> String? {
        let needle = (path as NSString).lastPathComponent
        guard !needle.isEmpty else { return nil }
        // Never scanAndSyncDocuments on the agent edit hot path — folder walks freeze UI.
        guard let ws = StudyWorkspaceStore.shared.workspace(id: workspaceID) else { return nil }
        for id in ws.documentIDs {
            guard let doc = StudyDocumentStore.shared.document(id: id) else { continue }
            if let display = doc.displayPath,
               (display as NSString).lastPathComponent.caseInsensitiveCompare(needle) == .orderedSame {
                return id
            }
            if doc.title.caseInsensitiveCompare(needle) == .orderedSame
                || doc.title.caseInsensitiveCompare((needle as NSString).deletingPathExtension) == .orderedSame {
                return id
            }
            if !doc.localRelativePath.isEmpty,
               (doc.localRelativePath as NSString).lastPathComponent.caseInsensitiveCompare(needle) == .orderedSame {
                return id
            }
        }
        return nil
    }

    /// Begin executing a workspace plan document (Build button in reader).
    func startPlanBuild(documentID: String) {
        guard StudyAgentMode.isAgentProductEnabled else {
            ConnectsToast.show("Agent 模式暂未开放 — 先用 Study 编辑当前文件", in: view, duration: 2.0)
            return
        }
        activePlanDocumentID = documentID
        guard let id = currentConversationID else {
            refreshBuildTodoChrome()
            return
        }
        ConversationStore.shared.updateConversation(id: id) { draft in
            draft.studyAgentMode = .agent
            draft.studyDocumentID = documentID
        }
        inputBar.setStudyAgentMode(.agent, notify: false)
        refreshBuildTodoChrome()
        updateStudyInputBar()

        let name = StudyDocumentStore.shared.document(id: documentID)?.title ?? "plan.md"
        let prompt = """
        按工作区计划文件「\(name)」执行：完成全部未勾选 todos；每完成一项用 propose_edit 把该文件中对应 `- [ ]` 改为 `- [x]`（或用 update_plan 同步全文）。先 read_file 该计划，再逐项落地改文件。
        """
        performSend(prompt, imageBase64: nil, conversationID: id)
    }

    func refreshBuildTodoChrome() {
        guard isViewLoaded else { return }
        guard let docID = activePlanDocumentID,
              let text = StudyDocumentStore.shared.textContent(for: docID) else {
            inputBar.setBuildTodoProgress(visible: false)
            return
        }
        let plan = StudyPlanDocument.parse(text)
        let done = plan.todos.filter(\.done).count
        let total = plan.todos.count
        let current = plan.todos.first(where: { !$0.done })?.title
        inputBar.setBuildTodoProgress(
            done: done,
            total: total,
            currentTitle: current,
            visible: total > 0
        )
        if total > 0, done >= total {
            // Plan finished — stop agent loop if it is still spinning.
            if let cid = currentConversationID,
               let rootID = agentProcessRootIDs[cid] {
                ConversationStore.shared.updateConversationQuietly(id: cid) { draft in
                    if let idx = draft.messages.lastIndex(where: { $0.id == rootID }) {
                        draft.messages[idx].agentProcessPhase = .done
                    }
                }
                agentProcessRootIDs[cid] = nil
                agentToolRoundCounts[cid] = 0
                stopStreamUITimer()
                refreshAssistantRowAfterEditStrip(messageID: rootID)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.activePlanDocumentID == docID else { return }
                let again = StudyPlanDocument.parse(
                    StudyDocumentStore.shared.textContent(for: docID) ?? ""
                )
                if !again.todos.isEmpty, again.todos.allSatisfy(\.done) {
                    self.inputBar.setBuildTodoProgress(visible: false)
                    self.activePlanDocumentID = nil
                }
            }
        }
    }

    private func syncActivePlanFile(planMarkdown: String) {
        let wrapped = StudyPlanDocument.wrapAsPlan(planMarkdown)
        if let docID = activePlanDocumentID {
            try? StudyDocumentStore.shared.writeTextContent(wrapped, for: docID)
            refreshBuildTodoChrome()
            return
        }
        guard let conv = ConversationStore.shared.currentConversation,
              let wsID = conv.activeStudyWorkspaceID else {
            refreshBuildTodoChrome()
            return
        }
        let stamp = Int(Date().timeIntervalSince1970) % 100_000
        let name = "plan-\(stamp).md"
        if let doc = try? StudyWorkspaceStore.shared.createFile(named: name, content: wrapped, in: wsID) {
            activePlanDocumentID = doc.id
            ConversationStore.shared.updateConversationQuietly(id: conv.id) { draft in
                draft.studyDocumentID = doc.id
            }
        }
        refreshBuildTodoChrome()
    }

    /// When Build is active, auto-apply propose_edit that targets the plan markdown (checkbox updates).
    private func applyPlanFileEditIfNeeded(path: String, body: String) {
        guard let docID = activePlanDocumentID,
              let doc = StudyDocumentStore.shared.document(id: docID) else { return }
        let target = (path as NSString).lastPathComponent.lowercased()
        var names = [doc.title.lowercased()]
        if let display = doc.displayPath {
            names.append((display as NSString).lastPathComponent.lowercased())
        }
        if !doc.localRelativePath.isEmpty {
            names.append((doc.localRelativePath as NSString).lastPathComponent.lowercased())
        }
        guard names.contains(where: { !$0.isEmpty && ($0 == target || target.hasSuffix($0) || $0.hasSuffix(target)) }) else {
            return
        }
        let wrapped = StudyPlanDocument.parse(body).isPlan ? body : StudyPlanDocument.wrapAsPlan(body)
        try? StudyDocumentStore.shared.writeTextContent(wrapped, for: docID)
        refreshBuildTodoChrome()
    }

    private func startStream(
        conversationID: String,
        messages: [ChatMessage],
        model: AIModelOption,
        needsAITitle: Bool
    ) {
        StreamManager.shared.start(
            conversationID: conversationID,
            messages: messages,
            model: model,
            needsAITitle: needsAITitle
        )
        syncStreamingChrome()
    }

    /// Strip CONNECTS_EDIT from the chat bubble; present Diff only when「AI 编辑」is on.
    /// Always strip on finish — otherwise `chatVisibleContent` keeps showing a fake “proposed edit”
    /// even when the toggle is off and the file never changes.
    private func handleCodeEditProposalIfNeeded(conversationID: String, finishedMessage: ChatMessage) {
        guard finishedMessage.role == .assistant,
              !finishedMessage.isStreaming else { return }
        let raw = finishedMessage.content
        let mentionsEdit = raw.range(of: "CONNECTS_EDIT", options: .caseInsensitive) != nil
        guard mentionsEdit else { return }

        let editEnabled = inputBar.codeAIEditEnabled
        let proposal = CodeEditApplyTools.parseEditBlock(from: raw)

        if !editEnabled {
            let prose = (proposal?.displayContent ?? CodeEditApplyTools.chatVisibleContent(raw))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let note = "（未开启「AI 编辑」，编辑块已忽略，文件未改）"
            let persisted = (prose.isEmpty || prose == "（文件编辑内容已隐藏）" || prose == "（已提出文件编辑）")
                ? note
                : prose + "\n\n" + note
            persistStrippedEditMessage(
                conversationID: conversationID,
                messageID: finishedMessage.id,
                content: persisted
            )
            return
        }

        guard let proposal else {
            let cleaned = CodeEditApplyTools.chatVisibleContent(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let note = CodeEditApplyTools.hasIncompleteEditBlock(raw)
                ? "（编辑块被截断未闭合，文件未改 — 可点重跑）"
                : "（编辑提案格式无效，未改文件）"
            let persisted = (cleaned.isEmpty
                             || cleaned == "（文件编辑内容已隐藏）"
                             || cleaned == "（已提出文件编辑）")
                ? note
                : cleaned + "\n\n" + note
            persistStrippedEditMessage(
                conversationID: conversationID,
                messageID: finishedMessage.id,
                content: persisted
            )
            ConnectsToast.show("编辑提案不完整（CONNECTS_EDIT 未闭合或格式错误）。可点重跑，或再发一次「继续」。", in: view, duration: 2.6)
            return
        }

        let presented = studyContextProvider?.presentStudyCodeEditProposal(
            proposal,
            assistantMessageID: finishedMessage.id
        ) ?? false
        let prose = proposal.displayContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let emptyProse = prose.isEmpty
            || prose == "（文件编辑内容已隐藏）"
            || prose == "（已提出文件编辑）"
        let persisted: String
        if presented {
            // Diff is the real product; don't claim “已提出” with an empty bubble.
            persisted = emptyProse ? "（已打开 Diff，请在阅读器中按块保留或撤销）" : prose
            ConnectsToast.show("Diff 已打开 — 可按块保留/撤销，或用输入栏全部保留", in: view, duration: 1.6)
        } else if studyContextProvider?.studyCodeAIEditSupported != true {
            persisted = emptyProse
                ? "（已生成编辑提案，但当前不是代码/文本页，未改文件）"
                : prose + "\n\n（当前不是代码/文本页，未打开 Diff）"
            ConnectsToast.show("请先打开代码或文本文件，再让 AI 编辑", in: view, duration: 2.2)
        } else {
            persisted = emptyProse
                ? "（编辑提案未打开 Diff，文件未改）"
                : prose + "\n\n（Diff 未打开，文件未改）"
        }
        persistStrippedEditMessage(
            conversationID: conversationID,
            messageID: finishedMessage.id,
            content: persisted
        )
    }

    private func persistStrippedEditMessage(conversationID: String, messageID: String, content: String) {
        ConversationStore.shared.updateConversationQuietly(id: conversationID) { conv in
            guard let idx = conv.messages.lastIndex(where: { $0.id == messageID }) else { return }
            conv.messages[idx].content = content
            if !conv.messages[idx].versions.isEmpty,
               conv.messages[idx].versions.indices.contains(conv.messages[idx].versionIndex) {
                conv.messages[idx].versions[conv.messages[idx].versionIndex].content = content
            }
        }
        if renderedConversationID == conversationID {
            refreshAssistantRowAfterEditStrip(messageID: messageID)
        }
    }

    private func refreshAssistantRowAfterEditStrip(messageID: String) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let row = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = messages[row]
        rowHeights.invalidate(messageID: messageID)
        let path = IndexPath(row: row, section: 0)
        let layoutWidth = currentRenderWidth()
        // Rebuild layout/bitmap for the rewritten body before the next scroll freeze.
        AssistantMessageLayout.rematerializeLayout(for: message, layoutWidth: layoutWidth)
        let pairedUser = pairedUserMessage(forAssistantAt: row, in: messages)
        UIView.performWithoutAnimation {
            if let cell = tableView.cellForRow(at: path) as? AssistantMessageCell {
                cell.configure(
                    with: message,
                    preferredHeight: nil,
                    layoutWidth: layoutWidth,
                    pairedUser: pairedUser
                )
                tableView.beginUpdates()
                tableView.endUpdates()
            } else if path.row < tableView.numberOfRows(inSection: 0) {
                tableView.reloadRows(at: [path], with: .none)
            }
        }
    }

    private func ensureStreamUITimer() {
        let agentRunning = isAgentTurnActivelyRunning
        guard streamUITimer == nil, isCurrentStreaming || agentRunning else { return }
        lastStreamMessageID = ""
        lastStreamContentBytes = -1
        lastStreamVisibleBytes = -1
        lastStreamReasoningBytes = -1
        lastStreamSearchBytes = -1
        lastStreamImageTranscriptionBytes = -1
        lastStreamPhase = .idle
        lastStreamImageTranscriptionPhase = .idle
        lastStreamProgressAt = Date()
        lastStreamLayoutAt = .distantPast
        lastAgentStreamLayoutAt = .distantPast
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

    /// Root agent card still running across tool-round gaps (no live stream tokens).
    private var isAgentTurnActivelyRunning: Bool {
        guard let cid = currentConversationID,
              let rootID = agentProcessRootIDs[cid],
              let msgs = ConversationStore.shared.currentConversation?.messages,
              let root = msgs.first(where: { $0.id == rootID }) else { return false }
        return root.agentProcessPhase == .running
    }

    private func stopStreamUITimer() {
        streamUITimer?.invalidate()
        streamUITimer = nil
    }

    @objc private func streamUITick() {
        let msgs = ConversationStore.shared.currentConversation?.messages
        let streamingLast = msgs?.last(where: { $0.isStreaming }) ?? msgs?.last
        if !isCurrentStreaming || streamingLast?.isStreaming != true {
            if isAgentTurnActivelyRunning {
                pulseAgentPlanningChrome()
                return
            }
            stopStreamUITimer()
            return
        }
        guard let last = streamingLast else {
            stopStreamUITimer()
            return
        }
        // Streams only append text. Comparing whole growing Strings at 25 fps
        // becomes quadratic on long replies and can itself freeze an A7 iPad.
        let contentBytes = last.content.utf8.count
        let visibleBytes = last.chatDisplayBody.utf8.count
        let reasoningBytes = last.reasoningContent.utf8.count
        let searchBytes = last.searchProcessContent.utf8.count
        let imageTranscriptionBytes = last.imageTranscriptionContent.utf8.count
        let idChanged = last.id != lastStreamMessageID
        let contentChanged = contentBytes != lastStreamContentBytes
        let visibleChanged = visibleBytes != lastStreamVisibleBytes || idChanged
        let chromeChanged = reasoningBytes != lastStreamReasoningBytes
            || searchBytes != lastStreamSearchBytes
            || imageTranscriptionBytes != lastStreamImageTranscriptionBytes
            || last.searchProcessPhase != lastStreamPhase
            || last.imageTranscriptionPhase != lastStreamImageTranscriptionPhase
        let changed = idChanged || contentChanged || chromeChanged || visibleChanged
        if changed {
            // Hidden CONNECTS_EDIT payload used to skip UI while the bubble stayed
            // on a static「正在生成文件编辑…」. Live stats/tail now change `visibleBytes`.
            if contentChanged, !visibleChanged, !chromeChanged, !idChanged {
                lastStreamContentBytes = contentBytes
                lastStreamProgressAt = Date()
                return
            }
            let visibleGrew = visibleChanged
            lastStreamMessageID = last.id
            lastStreamContentBytes = contentBytes
            lastStreamVisibleBytes = visibleBytes
            lastStreamReasoningBytes = reasoningBytes
            lastStreamSearchBytes = searchBytes
            lastStreamImageTranscriptionBytes = imageTranscriptionBytes
            lastStreamPhase = last.searchProcessPhase
            lastStreamImageTranscriptionPhase = last.imageTranscriptionPhase
            lastStreamProgressAt = Date()
            let now = Date()
            // Otherwise throttle relayout (~0.15s) even while stick-to-bottom.
            // Edit-stream status/tail updates often — keep the same throttle as prose.
            let shouldRelayout = visibleGrew && (
                now.timeIntervalSince(lastStreamLayoutAt) >= 0.15
                    || lastStreamLayoutAt == .distantPast
            )
            if shouldRelayout {
                lastStreamLayoutAt = now
            }
            refreshStreamingRow(
                waitingGlyph: nil,
                relayout: shouldRelayout,
                chaseViewport: shouldRelayout
            )
            return
        }
        // The provider is still connected but has not produced a delta.
        // Keep shimmer alive — never append ◐◓ spinner glyphs (they kill the
        // left→right sweep and make meta/prose jump every tick).
        guard Date().timeIntervalSince(lastStreamProgressAt) >= 0.45 else { return }
        streamSpinnerFrame = (streamSpinnerFrame + 1) % 12
        guard streamSpinnerFrame % 6 == 0 else { return }
        refreshStreamingRow(
            waitingGlyph: nil,
            relayout: false,
            chaseViewport: false
        )
    }

    /// Inter-round / TTFT gap: keep「Planning next moves…」/ Thinking shimmer alive on the root card.
    private func pulseAgentPlanningChrome() {
        // ≤1 Hz — never layout-storm the main runloop (was freezing the whole app).
        guard Date().timeIntervalSince(lastAgentPlanningPulseAt) >= 1.0 else { return }
        lastAgentPlanningPulseAt = Date()
        guard let cid = currentConversationID,
              let rootID = agentProcessRootIDs[cid],
              isAgentTurnActivelyRunning else {
            stopStreamUITimer()
            return
        }
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let rootRow = messages.firstIndex(where: { $0.id == rootID }) else { return }
        let root = messages[rootRow]
        let path = IndexPath(row: rootRow, section: 0)
        UIView.performWithoutAnimation {
            guard let cell = tableView.cellForRow(at: path) as? AssistantMessageCell,
                  cell.messageID == root.id else { return }
            // Stable overlay text + shimmer only — no full timeline rebuild (anti-flash).
            let hasReasoning = !root.reasoningContent
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let overlay = hasReasoning
                ? AgentProcessPhase.thinkingText
                : AgentProcessPhase.planningNextMovesText
            cell.keepAgentLiveShimmerAlive()
            _ = cell.syncAgentProcessPresentation(
                with: root,
                layoutWidth: currentRenderWidth(),
                liveOverlayText: overlay
            )
        }
    }

    private func refreshStreamingRow(waitingGlyph: String?,
                                     relayout: Bool,
                                     chaseViewport: Bool = true) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let last = messages.last(where: { $0.isStreaming }) ?? messages.last,
              last.isStreaming else {
            return
        }
        // Single-root agent turn: always paint the root card (stream tokens land there).
        if let cid = currentConversationID,
           let rootID = agentProcessRootIDs[cid],
           last.id == rootID || messages.contains(where: { $0.id == rootID }) {
            if last.id != rootID {
                refreshAgentRootStreamingTurn(
                    rootID: rootID,
                    streaming: last,
                    waitingGlyph: waitingGlyph,
                    relayout: relayout,
                    chaseViewport: chaseViewport
                )
                return
            }
        }
        guard let row = messages.firstIndex(where: { $0.id == last.id }) else { return }
        let path = IndexPath(row: row, section: 0)
        let agentLive = last.hasAgentProcess || last.agentProcessPhase == .running
        UIView.performWithoutAnimation {
            var cell = tableView.cellForRow(at: path) as? AssistantMessageCell
            if cell == nil, !readingHistory {
                tableView.layoutIfNeeded()
                cell = tableView.cellForRow(at: path) as? AssistantMessageCell
            }
            if let cell = cell {
                if agentLive {
                    // Stable overlay only — never append spinner glyphs.
                    let hasReasoning = !last.reasoningContent
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let overlay = hasReasoning
                        ? AgentProcessPhase.thinkingText
                        : AgentProcessPhase.planningNextMovesText
                    _ = cell.syncAgentProcessPresentation(
                        with: last,
                        layoutWidth: currentRenderWidth(),
                        liveOverlayText: overlay
                    )
                    cell.keepAgentLiveShimmerAlive()
                } else if !cell.updateStreamingContent(last, waitingGlyph: nil) {
                    let pairedUser = pairedUserMessage(forAssistantAt: path.row, in: messages)
                    cell.configure(
                        with: last,
                        preferredHeight: rowHeights.committedColumnHeight(for: last.id),
                        layoutWidth: currentRenderWidth(),
                        pairedUser: pairedUser
                    )
                }
                if agentLive, relayout {
                    commitAgentStreamingRowHeight(cell: cell, messageID: last.id)
                }
            }
            // Agent: never reloadData / layoutIfNeeded on the stream tick — that froze taps.
            if chaseViewport, (finishViewportLocked || isCurrentStreaming) {
                if agentLive || isAgentTurnActivelyRunning {
                    lightChaseAgentLiveTail()
                } else {
                    chaseLiveTailToBottom(messages: messages, layoutWidth: currentRenderWidth())
                }
            } else if relayout, stickToBottom, !isViewportPinned(), !agentLive {
                scrollToBottom(animated: false, force: true)
            }
        }
    }

    /// Feed heightForRow from fitted height. Agent turns: never shrink, rarely beginUpdates.
    private func commitAgentStreamingRowHeight(cell: AssistantMessageCell, messageID: String) {
        let fitted = cell.fittedStreamingRowHeight() - ChatRowHeightResolver.cellVerticalMargin
        let meta = SettingsManager.shared.chatThinkingFontSize
        let minChrome = ceil(UIFont.systemFont(ofSize: meta).lineHeight) + 8
        let column = max(fitted, minChrome)
        rowHeights.commitMeasured(
            columnHeight: column,
            messageID: messageID,
            allowShrink: false
        )
        let now = Date()
        guard now.timeIntervalSince(lastAgentStreamLayoutAt) >= 0.35
                || lastAgentStreamLayoutAt == .distantPast else {
            lightChaseAgentLiveTail()
            return
        }
        lastAgentStreamLayoutAt = now
        tableView.beginUpdates()
        tableView.endUpdates()
        lightChaseAgentLiveTail()
    }

    /// Paint mid-loop tokens into the root interleaved timeline (no process box).
    private func refreshAgentRootStreamingTurn(rootID: String,
                                               streaming: ChatMessage,
                                               waitingGlyph: String?,
                                               relayout: Bool,
                                               chaseViewport: Bool) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let rootRow = messages.firstIndex(where: { $0.id == rootID }) else {
            return
        }
        var root = messages[rootRow]
        // Merge live mid-loop tokens into root for interleaved paint.
        let body = streaming.chatDisplayBodyCurrentRound
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            root.content = streaming.content
        }
        let path = IndexPath(row: rootRow, section: 0)
        let layoutWidth = currentRenderWidth()
        UIView.performWithoutAnimation {
            if let cell = tableView.cellForRow(at: path) as? AssistantMessageCell,
               cell.messageID == root.id {
                let reason = streaming.reasoningContent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let overlay: String = {
                    if !reason.isEmpty { return AgentProcessPhase.thinkingText }
                    return AgentProcessPhase.planningNextMovesText
                }()
                _ = cell.syncAgentProcessPresentation(
                    with: root,
                    layoutWidth: layoutWidth,
                    liveOverlayText: overlay
                )
                cell.keepAgentLiveShimmerAlive()
                if relayout {
                    commitAgentStreamingRowHeight(cell: cell, messageID: root.id)
                }
            }
            if chaseViewport, (finishViewportLocked || isCurrentStreaming) {
                lightChaseAgentLiveTail()
            }
        }
    }

    /// Keep the live stream tail in view while scroll is frozen (send → finish pin).
    private func followStreamingViewportToBottom() {
        guard finishViewportLocked || isCurrentStreaming else { return }
        stickToBottom = true
        readingHistory = false
        viewportPinnedByUser = false
        if isAgentTurnActivelyRunning {
            lightChaseAgentLiveTail()
            return
        }
        if let messages = ConversationStore.shared.currentConversation?.messages,
           !messages.isEmpty {
            chaseLiveTailToBottom(messages: messages, layoutWidth: currentRenderWidth())
            return
        }
        tableView.layoutIfNeeded()
        snapTableContentOffsetToBottom()
    }

    private func syncStreamingChrome() {
        let running = isCurrentStreaming
        let tokenStreaming: Bool = {
            guard let id = currentConversationID else { return false }
            return StreamManager.shared.isRunning(id)
        }()
        inputBar.isStreaming = running
        if tokenStreaming {
            if rowHeights.isScrollHeightFrozen {
                rowHeights.endScrollHeightFreeze()
            }
            // Lock only while tokens are arriving — not during web-search planning.
            finishViewportLocked = true
            tableView.isScrollEnabled = false
            stickToBottom = true
            readingHistory = false
            viewportPinnedByUser = false
            followStreamingViewportToBottom()
            ensureStreamUITimer()
        } else if running {
            // Search / transcription chrome: keep Stop enabled, but allow scroll.
            finishViewportLocked = false
            tableView.isScrollEnabled = true
            ensureStreamUITimer()
        } else if isAgentTurnActivelyRunning {
            // Tool-round gap: keep a throttled Planning pulse, do not lock scroll.
            finishViewportLocked = false
            tableView.isScrollEnabled = true
            ensureStreamUITimer()
        } else {
            stopStreamUITimer()
            // Unlock only after pinToFinishedTurnBottom; stay locked meanwhile.
            if !finishViewportLocked {
                tableView.isScrollEnabled = true
            }
        }
    }

    private func unlockScrollAfterFinishPin() {
        finishViewportLocked = false
        if !isCurrentStreaming {
            tableView.isScrollEnabled = true
        }
        guard stickToBottom,
              let messages = ConversationStore.shared.currentConversation?.messages,
              !messages.isEmpty else { return }
        let width = currentRenderWidth()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pinFinishedTailViewport(messages: messages, layoutWidth: width)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self,
                  self.stickToBottom,
                  let live = ConversationStore.shared.currentConversation?.messages,
                  !live.isEmpty else { return }
            self.pinFinishedTailViewport(messages: live, layoutWidth: self.currentRenderWidth())
        }
    }

    func updateSidebarToggleTitle(collapsed: Bool) {
        pendingSidebarCollapsed = collapsed
        guard let item = sidebarToggleItem else { return }
        let kind: ActionIconFactory.Kind = collapsed ? .sidebar : .sidebarOpen
        item.image = ActionIconFactory.image(kind, pointSize: ActionIconFactory.chromeGlyph)
        if isCompactChrome {
            item.accessibilityLabel = collapsed ? "打开对话列表" : "关闭对话列表"
        } else {
            item.accessibilityLabel = collapsed ? "打开侧栏" : "关闭侧栏"
        }
    }

    func setStudyChrome(_ mode: StudyChromeMode) {
        guard studyChromeMode != mode else { return }
        studyChromeMode = mode
        if mode == .none {
            studyShowsSidebarToggle = false
        }
        applyStudyChrome()
        updateStudyInputBar()
        if mode == .documentReader || mode == .portraitPanel {
            pendingStudyFirstScrollPrep = true
        }
        if mode != .none {
            scheduleInvalidateHeightsForWidthChange()
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      self.isTableLayoutCommitted(),
                      let messages = self.renderedConversationMessages(),
                      !messages.isEmpty else { return }
                self.reconcileBottomViewportIfNeeded(
                    messages: messages,
                    layoutWidth: self.currentRenderWidth()
                )
            }
        }
    }

    /// Legacy hook — Study now uses a shell floating sidebar; callers always pass `false`.
    func setStudyShowsSidebarToggle(_ visible: Bool) {
        guard studyShowsSidebarToggle != visible else { return }
        studyShowsSidebarToggle = visible
        applyStudyChrome()
    }

    func refreshStudyComposerLayout(reconcileViewport: Bool = true) {
        guard isViewLoaded else { return }
        let preserveKeyboardLift = keyboardVisible
        refreshComposerBottomAnchorIfNeeded()
        if !preserveKeyboardLift {
            bottomConstraint?.constant = restingComposerBottomConstant()
        }
        view.layoutIfNeeded()
        guard reconcileViewport,
              let messages = renderedConversationMessages(), !messages.isEmpty else { return }
        reconcileBottomViewportIfNeeded(messages: messages, layoutWidth: currentRenderWidth())
    }

    func dismissComposerKeyboard() {
        guard isViewLoaded else { return }
        guard !ConnectsNoteSheet.isVisible else { return }
        view.endEditing(true)
        keyboardVisible = false
        bottomConstraint?.constant = restingComposerBottomConstant()
    }

    var isComposerFirstResponder: Bool {
        isViewLoaded && inputBar.isComposerFirstResponder
    }

    func focusComposerFromShortcut() {
        guard isViewLoaded else { return }
        inputBar.focusComposer()
        view.bringSubviewToFront(inputBar)
    }

    func sendFromKeyboardShortcut() {
        guard isViewLoaded, !isCurrentStreaming else { return }
        inputBar.sendFromKeyboardShortcut()
    }

    /// Cancel scroll-settle / deceleration work so stage & input controls respond immediately.
    func prepareForStudyPanelControlTap() {
        guard isViewLoaded else { return }
        scrollSettleWork?.cancel()
        scrollSettleWork = nil
        scrollFreezeGeometryWork?.cancel()
        scrollFreezeGeometryWork = nil
        scrollBeginPrepWork?.cancel()
        scrollBeginPrepWork = nil
        studyFrozenShrinkRemeasureWork?.cancel()
        studyFrozenShrinkRemeasureWork = nil
        nativeHydrationScrollWork?.cancel()
        nativeHydrationScrollWork = nil
        deferredRenderWork?.cancel()
        deferredRenderWork = nil
        if tableView.isDragging || tableView.isDecelerating {
            tableView.setContentOffset(tableView.contentOffset, animated: false)
        }
        view.bringSubviewToFront(inputBar)
    }

    /// Study Ask: stash selection as hidden API context. Does not open the panel or focus the composer —
    /// the reader keeps the highlight until the user opens AI themselves.
    func prepareAskAboutSelection(_ text: String) {
        loadViewIfNeeded()
        _ = text
        inputBar.studyCaptureVisible = true
        inputBar.studyPageCaptureEnabled = true
        if let id = currentConversationID {
            ConversationStore.shared.updateConversationQuietly(id: id) { draftConv in
                draftConv.studyPageCaptureEnabled = true
            }
        }
        inputBar.onClearAskSelection = { [weak self] in
            guard let id = self?.currentConversationID else { return }
            StudyAskSelectionStore.shared.clear(conversationID: id)
            self?.studyContextProvider?.clearAskSelectionHighlightInReader()
        }
        inputBar.setAskSelectionArmed(true)
        refreshComposerBottomAnchorIfNeeded()
    }

    func clearAskSelectionChip() {
        inputBar.setAskSelectionArmed(false)
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
        let conv = ConversationStore.shared.currentConversation
        return conv?.studyDocumentID != nil || conv?.isWorkspaceStudySession == true
    }

    private func applyStudyChrome() {
        // Sidebar button visibility must follow the *conversation*, not stale study chrome.
        // After「新对话」the document is already nil while studyChromeMode can lag one frame —
        // that previously hid the toggle until the next chrome sync.
        let hasStudyDoc = ConversationStore.shared.currentConversation?.studyDocumentID != nil
        let isWorkspace = ConversationStore.shared.currentConversation?.isWorkspaceStudySession == true
        if !hasStudyDoc, !isWorkspace, studyChromeMode != .none {
            studyChromeMode = .none
            studyShowsSidebarToggle = false
        }
        // Study: shell owns the single floating sidebar key — never put one on chat nav.
        // Non-Study: normal chat sidebar on the leading edge.
        let inStudy = hasStudyDoc || isWorkspace || studyChromeMode != .none
        if !inStudy {
            navigationItem.leftBarButtonItems = nil
            navigationItem.leftBarButtonItem = sidebarToggleItem
        } else {
            // Clear leading so + / history can live on trailing without a second sidebar key.
            navigationItem.leftBarButtonItem = nil
            navigationItem.leftBarButtonItems = nil
        }
        if isViewLoaded, turnContextBarTopToSafe != nil, turnContextBarTopToView != nil {
            let portraitPanel = studyChromeMode == .portraitPanel
            turnContextBarTopToSafe.isActive = !portraitPanel
            turnContextBarTopToView.isActive = portraitPanel
        }
        if isViewLoaded {
            refreshComposerBottomAnchorIfNeeded()
            normalizePortraitPanelSafeArea()
        }
        updateModelButton()
        updateEmptyState()
        refreshRightBarButtons()
    }

    func syncStudyPanelStageControl() {
        // ▲▼ stay on the shell floating chip (stable placement). Never install
        // them as nav titleView — that rode the animating chatHost and looked
        // like the control was flying up/down the screen.
        if navigationItem.titleView === studyPanelNavHost
            || navigationItem.titleView === modelButton {
            navigationItem.titleView = nil
        }
    }

    /// Custom view used to align the floating ▲▼ chip with + / history / ⋯.
    func studyChromeAlignView() -> UIView? {
        let items =
            (navigationItem.leftBarButtonItems ?? [])
            + (navigationItem.rightBarButtonItems ?? [])
        for item in items {
            if let view = item.customView, view.bounds.height > 1, view.window != nil {
                return view
            }
        }
        return nil
    }

    /// Slide Over / narrow width: tighter chrome for 网课侧拉.
    func setCompactChrome(_ on: Bool) {
        let inset = on ? 12.0 : DSTheme.contentHorizontalPadding
        let side = -(inset * 2)
        if isCompactChrome == on, inputSideInsetConstraint?.constant == side {
            return
        }
        isCompactChrome = on
        inputSideInsetConstraint?.constant = side
        emptyTitleLabel.font = UIFont.systemFont(ofSize: on ? 22 : 28, weight: .semibold)
        emptySubtitleLabel.font = DSTheme.bodyFont(size: on ? 13 : 14)
        if let collapsed = pendingSidebarCollapsed {
            updateSidebarToggleTitle(collapsed: collapsed)
        }
        refreshRightBarButtons()
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
        tableView.alpha = 0

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
            diskCache: sessionPersistedHeights(for: id),
            messages: messages,
            layoutWidth: layoutWidth,
            layoutProbeTailRows: Self.switchLayoutProbeTailRows
        )
        pendingHeights.removeAll()
        renderedConversationID = id
        renderedMessageCount = messages.count
        stickToBottom = true
        readingHistory = false
        viewportPinnedByUser = false

        CodeEditApplyTools.clearVisibleCache()

        streamUIWork?.cancel()
        streamUIWork = nil
        stopStreamUITimer()
        unlockScrollAfterFinishPin()
        clearNavigationPrompt()

        if coldLaunch {
            notifyInitialLaunchIfNeeded()
        }
        openConversationAtBottom(messages: messages, layoutWidth: layoutWidth)
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
        updateAttachAvailability()
        updateStudyInputBar()
        updateEmptyState()
        refreshSwitchChromeImmediate()
    }

    private func updateStudyInputBar() {
        guard let conv = ConversationStore.shared.currentConversation else {
            inputBar.studyCaptureVisible = false
            inputBar.studyPageCaptureEnabled = false
            inputBar.setAskSelectionSlotVisible(false)
            inputBar.codeAIEditVisible = false
            inputBar.studyAgentModeVisible = false
            return
        }
        let isWorkspace = conv.isWorkspaceStudySession
        let agentProduct = StudyAgentMode.isAgentProductEnabled
        // Folder Study (Agent gated): same capture / AI-edit toggles as single-document Study.
        // When Agent product unlocks, workspace hides legacy toggles and uses tool chrome instead.
        if isWorkspace, agentProduct {
            inputBar.studyCaptureVisible = false
            inputBar.studyPageCaptureEnabled = false
            inputBar.codeAIEditVisible = false
            inputBar.setCodeAIEditEnabled(false, notify: false)
        } else {
            let hasDoc = conv.studyDocumentID != nil
            inputBar.studyCaptureVisible = hasDoc
            inputBar.studyPageCaptureEnabled = conv.studyPageCaptureEnabled
            let codeEditSupported: Bool = {
                guard let docID = conv.studyDocumentID,
                      let kind = StudyDocumentStore.shared.document(id: docID)?.kind else { return false }
                return kind == .text
            }()
            inputBar.codeAIEditVisible = codeEditSupported
        }
        // Ask is for markdown / code (text); PDF is highlighter-only.
        let askSupported: Bool = {
            guard let docID = conv.studyDocumentID,
                  let kind = StudyDocumentStore.shared.document(id: docID)?.kind else { return false }
            return kind == .markdown || kind == .text
        }()
        inputBar.setAskSelectionSlotVisible(askSupported)
        inputBar.studyAgentModeVisible = isWorkspace && agentProduct
        if isWorkspace {
            let mode = StudyAgentMode.coerceForProduct(conv.studyAgentMode)
            if mode != conv.studyAgentMode, let id = currentConversationID {
                ConversationStore.shared.updateConversationQuietly(id: id) { draft in
                    draft.studyAgentMode = mode
                }
            }
            inputBar.setStudyAgentMode(mode, notify: false)
            // Strip empty Agent chrome shells left over while product is gated.
            if !agentProduct, let id = currentConversationID {
                agentProcessRootIDs[id] = nil
                var demoted = false
                ConversationStore.shared.updateConversationQuietly(id: id) { draft in
                    for i in draft.messages.indices where draft.messages[i].role == .assistant {
                        let m = draft.messages[i]
                        let emptyShell = m.agentProcessSteps.isEmpty
                            && m.agentTimelineParts.isEmpty
                            && m.agentProseSegments.isEmpty
                            && m.agentEditCards.isEmpty
                            && m.agentToolTurns.isEmpty
                        if emptyShell,
                           m.agentProcessPhase == .running || m.agentProcessPhase == .waitingUser {
                            draft.messages[i].agentProcessPhase = .idle
                            draft.messages[i].agentProcessStartedAt = nil
                            demoted = true
                        }
                    }
                }
                if demoted, isViewLoaded {
                    tableView.reloadData()
                }
            }
        }
        let armed = askSupported
            && StudyAskSelectionStore.shared.pendingText(for: conv.id) != nil
        inputBar.setAskSelectionArmed(armed)
        inputBar.onClearAskSelection = { [weak self] in
            guard let id = self?.currentConversationID else { return }
            StudyAskSelectionStore.shared.clear(conversationID: id)
            self?.studyContextProvider?.clearAskSelectionHighlightInReader()
        }
        applyStudyChrome()
        refreshWorkspaceDiffBanner()
        refreshBuildTodoChrome()
    }

    /// Whether the InputBar「AI 编辑」toggle is on (permission only).
    var inputBarCodeAIEditEnabled: Bool { inputBar.codeAIEditEnabled }

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
                // Repair off the open frame — string sync + rare save must not stall switch.
                DispatchQueue.main.async {
                    ConversationStore.shared.repairImageTranscriptionDisplays(for: id)
                }
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
            let messages = ConversationStore.shared.currentConversation?.messages ?? []
            let countDelta = messages.count - renderedMessageCount
            let bulkContentChange = countDelta < 0 || countDelta > 2
            if bulkContentChange {
                prepareInPlaceThreadContentRefresh(messages: messages, layoutWidth: layoutWidth)
            }
            reloadTablePreservingViewport()
            renderedMessageCount = messages.count
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

    /// Older conversations can still contain an image-only turn. Transcribe-on-open is retired.
    private func queueLegacyImageTranscriptionIfNeeded() {}

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

    func shareCurrentChatTransfer() {
        guard let conv = ConversationStore.shared.currentConversation else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("connects-chat-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "")
                let url = folder.appendingPathComponent(
                    "ConnectsChat_\(stamp).\(ConnectsChatTransferService.fileExtension)"
                )
                _ = try ConnectsChatTransferService.exportConversation(id: conv.id, to: url)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    activity.completionWithItemsHandler = { _, _, _, _ in
                        try? FileManager.default.removeItem(at: folder)
                    }
                    if let pop = activity.popoverPresentationController {
                        pop.barButtonItem = self.studyBarButtonItem(matching: #selector(self.moreTapped))
                            ?? self.navigationItem.rightBarButtonItem
                    }
                    self.present(activity, animated: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showAlert(title: "导出失败", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func toggleChatSidebar() { onToggleSidebar?() }

    /// Prefer matching by action — `rightBarButtonItems` order is rightmost-first and fragile.
    private func studyBarButtonItem(matching action: Selector) -> UIBarButtonItem? {
        if let item = navigationItem.rightBarButtonItems?.first(where: { $0.action == action }) {
            return item
        }
        if let item = navigationItem.leftBarButtonItems?.first(where: { $0.action == action }) {
            return item
        }
        if navigationItem.leftBarButtonItem?.action == action {
            return navigationItem.leftBarButtonItem
        }
        return nil
    }

    @objc private func moreTapped() {
        guard let conv = ConversationStore.shared.currentConversation else { return }
        let archiveTitle = conv.isArchived ? "取消归档" : "归档"
        var items: [ConnectsMenuItem] = []
        if conv.isWorkspaceStudySession {
            let wsName = conv.activeStudyWorkspaceID.flatMap {
                StudyWorkspaceStore.shared.workspace(id: $0)?.title
            } ?? "工作区"
            let fileHint = conv.studyActiveFileName.map { " · \($0)" } ?? ""
            items.append(ConnectsMenuItem(title: "\(wsName)\(fileHint)", icon: .folder) {})
        } else if conv.studyDocumentID != nil,
                  let doc = StudyDocumentStore.shared.document(id: conv.studyDocumentID!) {
            items.append(ConnectsMenuItem(title: "文档：\(doc.title)", icon: .book) {})
        }
        let moreItem = studyBarButtonItem(matching: #selector(moreTapped))
            ?? navigationItem.rightBarButtonItems?.first
        items.append(ConnectsMenuItem(title: "打开…", icon: .book) { [weak self] in
            guard let self else { return }
            if let shell = self.studyContextProvider {
                shell.presentStudyFreeOpenPicker(from: nil, barButtonItem: moreItem)
            } else {
                self.presentStudyDocumentPicker()
            }
        })
        if let shell = studyContextProvider {
            items.append(ConnectsMenuItem(title: "文件夹授权", icon: .folder) {
                shell.presentProjectFolderGrantPicker()
            })
        }
        if conv.studyDocumentID != nil || conv.isWorkspaceStudySession {
            items.append(ConnectsMenuItem(title: "取消依附", icon: .trash, isDestructive: true) { [weak self] in
                self?.detachStudyDocument()
            })
        }
        items.append(contentsOf: [
                ConnectsMenuItem(title: "分享 / 导出 Markdown", icon: .share) { [weak self] in
                    self?.shareCurrentMarkdown()
                },
                ConnectsMenuItem(title: "导出可迁移包", icon: .share) { [weak self] in
                    self?.shareCurrentChatTransfer()
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
                },
                ConnectsMenuItem(title: "删除对话", icon: .trash, isDestructive: true) { [weak self] in
                    self?.confirmDeleteConversation(id: conv.id, title: conv.title)
                }
        ])
        ConnectsMenu.present(
            from: self,
            title: conv.title,
            items: items,
            barButtonItem: moreItem
        )
    }

    func presentStudyDocumentPickerPublic() {
        // Prefer free system picker via Study shell when available.
        if let shell = studyContextProvider {
            shell.presentStudyFreeOpenPicker(
                from: nil,
                barButtonItem: studyBarButtonItem(matching: #selector(moreTapped))
            )
            return
        }
        presentStudyDocumentPicker()
    }

    /// Called by StudyShell after binding a folder or file.
    func refreshStudyBindingChrome() {
        updateStudyInputBar()
        applyStudyChrome()
        refreshRightBarButtons()
    }

    private func presentStudyDocumentPicker() {
        let picker = StudyDocumentPickerViewController()
        picker.delegate = self
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .formSheet
        if #available(iOS 13.0, *) {
            nav.isModalInPresentation = false
        }
        present(nav, animated: true)
    }

    private func detachStudyDocument() {
        guard let id = currentConversationID else { return }
        ConversationStore.shared.updateConversation(id: id) { draft in
            draft.studyDocumentID = nil
            draft.studyWorkspaceID = nil
            draft.studySessionKind = .document
            draft.studyPageCaptureEnabled = false
            draft.studyAgentMode = StudyAgentMode.coerceForProduct(draft.studyAgentMode)
        }
        updateStudyInputBar()
    }

    func studyDocumentPicker(_ picker: StudyDocumentPickerViewController, didSelect documentID: String) {
        guard let id = currentConversationID else { return }
        ConversationStore.shared.updateConversation(id: id) { draft in
            draft.studyDocumentID = documentID
            draft.studyWorkspaceID = nil
            draft.studySessionKind = .document
            draft.studyPageCaptureEnabled = true
            draft.studyAgentMode = StudyAgentMode.coerceForProduct(draft.studyAgentMode)
        }
        updateStudyInputBar()
        if navigationController?.topViewController === picker {
            navigationController?.popViewController(animated: true)
        } else {
            picker.dismiss(animated: true)
        }
    }

    func studyDocumentPicker(_ picker: StudyDocumentPickerViewController, didSelectWorkspace workspaceID: String) {
        guard let id = currentConversationID else { return }
        _ = try? StudyWorkspaceStore.shared.scanAndSyncDocuments(workspaceID: workspaceID)
        var firstDoc = StudyWorkspaceStore.shared.primaryDocumentID(in: workspaceID)
        if firstDoc == nil,
           let name = StudyWorkspaceStore.shared.listFileNames(in: workspaceID).first,
           let url = try? StudyWorkspaceStore.shared.fileURL(relativePath: name, in: workspaceID),
           let doc = try? StudyDocumentStore.shared.registerFileInPlace(
            at: url,
            createEmptyIfNeeded: false
           ) {
            StudyWorkspaceStore.shared.addDocument(doc.id, to: workspaceID)
            _ = try? StudyWorkspaceStore.shared.scanAndSyncDocuments(workspaceID: workspaceID)
            firstDoc = StudyWorkspaceStore.shared.primaryDocumentID(in: workspaceID) ?? doc.id
        }
        ConversationStore.shared.updateConversation(id: id) { draft in
            draft.studyWorkspaceID = workspaceID
            draft.studySessionKind = .workspace
            let active = StudyWorkspaceStore.shared.lastOpenedDocumentID(in: workspaceID)
                ?? {
                    if let current = draft.studyDocumentID,
                       StudyWorkspaceStore.shared.containsDocument(current, in: workspaceID) {
                        return current
                    }
                    return firstDoc
                }()
            draft.studyDocumentID = active
            if let active {
                StudyWorkspaceStore.shared.setLastOpenedDocument(active, in: workspaceID)
            }
            draft.studyPageCaptureEnabled = draft.studyDocumentID != nil
            // Keep current Study posture — do not jump into Agent.
            draft.studyAgentMode = StudyAgentMode.coerceForProduct(draft.studyAgentMode)
        }
        updateStudyInputBar()
        if navigationController?.topViewController === picker {
            navigationController?.popViewController(animated: true)
        } else {
            picker.dismiss(animated: true)
        }
        if StudyWorkspaceStore.shared.isFolderEmptyOfStudyFiles(workspaceID) {
            DispatchQueue.main.async { [weak self] in
                self?.studyContextProvider?.ensureWorkspaceHasFileIfEmpty(workspaceID: workspaceID)
            }
        }
    }

    private func setupNavBar() {
        // Kept for legacy picker anchors; model / AI 选项 UI is input-bar only.
        modelButton.translatesAutoresizingMaskIntoConstraints = true
        modelButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        modelButton.titleLabel?.lineBreakMode = .byTruncatingTail
        modelButton.titleLabel?.textAlignment = .center
        modelButton.connectsSetContentInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        modelButton.layer.cornerRadius = 16
        modelButton.clipsToBounds = true
        modelButton.isUserInteractionEnabled = true
        modelButton.addTarget(self, action: #selector(modelTapped), for: .touchUpInside)
        modelButton.accessibilityLabel = "选择模型"
        modelButton.isHidden = true

        studyPanelNavCapsule.setAxis(.horizontal)
        studyPanelNavCapsule.onStepTowardAI = { [weak self] in
            self?.stepStudyPanel(towardAI: true)
        }
        studyPanelNavCapsule.onStepTowardReading = { [weak self] in
            self?.stepStudyPanel(towardAI: false)
        }
        // Default: no nav model chip. Portrait study half/full installs ▲▼ via sync.
        navigationItem.titleView = nil

        sidebarToggleItem = ActionIconFactory.barItem(
            kind: .sidebarOpen,
            target: self,
            action: #selector(toggleChatSidebar),
            accessibility: "关闭侧栏"
        )
        refreshRightBarButtons()
        applyStudyChrome()
        if let collapsed = pendingSidebarCollapsed {
            updateSidebarToggleTitle(collapsed: collapsed)
        }

        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.isUserInteractionEnabled = true
        updateModelButton()
    }

    /// iPhone / Slide Over: tighter Study chrome (no iOS 26 glass pills).
    /// Placement is always trailing — leading stays clear for the shell’s single sidebar key.
    private var prefersCompactStudyChrome: Bool {
        if isCompactChrome { return true }
        if UIDevice.current.userInterfaceIdiom == .phone { return true }
        let width = view.window?.bounds.width ?? view.bounds.width
        return width > 0 && width < 520
    }

    private func refreshRightBarButtons() {
        // Compact Study chrome: hide oversized iOS 26 glass frames around + / history / ⋯.
        let compactChrome = prefersCompactStudyChrome
        let moreItem = compactChrome
            ? Self.compactStudyBarItem(
                kind: .more,
                target: self,
                action: #selector(moreTapped),
                accessibility: "更多"
            )
            : ActionIconFactory.barItem(
                kind: .more,
                target: self,
                action: #selector(moreTapped),
                accessibility: "更多"
            )
        Self.hideBarItemGlass(moreItem)

        guard isStudySessionActive() else {
            navigationItem.leftBarButtonItems = nil
            if let sidebar = sidebarToggleItem {
                Self.hideBarItemGlass(sidebar)
            }
            navigationItem.leftBarButtonItem = sidebarToggleItem
            navigationItem.rightBarButtonItems = [moreItem]
            return
        }

        let conv = ConversationStore.shared.currentConversation
        let isWorkspace = conv?.isWorkspaceStudySession == true
        let historyA11y = isWorkspace ? "同工作区对话" : "同文件对话"
        let newChatA11y = isWorkspace ? "同工作区新对话" : "同文件新对话"

        let historyItem = compactChrome
            ? Self.compactStudyBarItem(
                kind: .clock,
                target: self,
                action: #selector(studyHistoryTapped),
                accessibility: historyA11y
            )
            : ActionIconFactory.barItem(
                kind: .clock,
                target: self,
                action: #selector(studyHistoryTapped),
                accessibility: historyA11y
            )
        let newChatItem = compactChrome
            ? Self.compactStudyBarItem(
                kind: .plus,
                target: self,
                action: #selector(studyNewChatTapped),
                accessibility: newChatA11y
            )
            : ActionIconFactory.barItem(
                kind: .plus,
                target: self,
                action: #selector(studyNewChatTapped),
                accessibility: newChatA11y
            )
        Self.hideBarItemGlass(historyItem)
        Self.hideBarItemGlass(newChatItem)

        // Study: never host a sidebar key on chat nav (shell floating control only).
        // Workspace + / history stay on trailing with ⋯ — iPhone included.
        navigationItem.leftBarButtonItem = nil
        navigationItem.leftBarButtonItems = nil
        if compactChrome {
            // One cluster for + / history / ⋯ so spacing is even and iOS 26 won’t
            // glass-wrap only part of the group.
            let cluster = Self.compactStudyTrailingCluster(
                target: self,
                newChatAction: #selector(studyNewChatTapped),
                historyAction: #selector(studyHistoryTapped),
                moreAction: #selector(moreTapped),
                newChatAccessibility: newChatA11y,
                historyAccessibility: historyA11y,
                moreAccessibility: "更多"
            )
            Self.hideBarItemGlass(cluster)
            navigationItem.rightBarButtonItems = [cluster]
        } else {
            // UIKit: first right item is rightmost → ⋯ | history | +
            navigationItem.rightBarButtonItems = [moreItem, historyItem, newChatItem]
        }
    }

    /// Compact chrome next to the stage ▲▼ chip — same 30pt height as the capsule.
    private static func compactStudyBarItem(
        kind: ActionIconFactory.Kind,
        target: Any?,
        action: Selector,
        accessibility: String
    ) -> UIBarButtonItem {
        let side = StudyPanelStageCapsule.chipHeight
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 0, y: 0, width: side, height: side)
        button.setImage(ActionIconFactory.image(kind, pointSize: ActionIconFactory.menuGlyph), for: .normal)
        button.tintColor = DSTheme.c.textSecondary
        button.accessibilityLabel = accessibility
        if let target {
            button.addTarget(target, action: action, for: .touchUpInside)
        }
        let item = UIBarButtonItem(customView: button)
        item.accessibilityLabel = accessibility
        item.target = target as AnyObject?
        item.action = action
        return item
    }

    /// + / history / ⋯ in one custom view — equal spacing, no mixed bar-item gaps.
    private static func compactStudyTrailingCluster(
        target: Any?,
        newChatAction: Selector,
        historyAction: Selector,
        moreAction: Selector,
        newChatAccessibility: String,
        historyAccessibility: String,
        moreAccessibility: String
    ) -> UIBarButtonItem {
        let side = StudyPanelStageCapsule.chipHeight
        let spacing: CGFloat = 4
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = spacing
        stack.isUserInteractionEnabled = true

        func makeButton(kind: ActionIconFactory.Kind, action: Selector, a11y: String) -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(ActionIconFactory.image(kind, pointSize: ActionIconFactory.menuGlyph), for: .normal)
            button.tintColor = DSTheme.c.textSecondary
            button.accessibilityLabel = a11y
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: side),
                button.heightAnchor.constraint(equalToConstant: side)
            ])
            if let target {
                button.addTarget(target, action: action, for: .touchUpInside)
            }
            return button
        }

        // Visual L→R: + | history | ⋯ (⋯ sits at the trailing edge).
        let plus = makeButton(kind: .plus, action: newChatAction, a11y: newChatAccessibility)
        let clock = makeButton(kind: .clock, action: historyAction, a11y: historyAccessibility)
        let more = makeButton(kind: .more, action: moreAction, a11y: moreAccessibility)
        stack.addArrangedSubview(plus)
        stack.addArrangedSubview(clock)
        stack.addArrangedSubview(more)
        let count = 3
        stack.frame = CGRect(x: 0, y: 0, width: side * CGFloat(count) + spacing * CGFloat(count - 1), height: side)

        let item = UIBarButtonItem(customView: stack)
        item.accessibilityLabel = "\(newChatAccessibility)，\(historyAccessibility)，\(moreAccessibility)"
        // Menu / toast anchors prefer the more control (rightmost).
        item.target = target as AnyObject?
        item.action = moreAction
        return item
    }

    private static func hideBarItemGlass(_ item: UIBarButtonItem) {
        if #available(iOS 26.0, *) {
            item.hidesSharedBackground = true
        }
    }

    @objc private func studyNewChatTapped() {
        guard let source = ConversationStore.shared.currentConversation else { return }
        _ = ConversationStore.shared.createStudyConversation(copyingFrom: source, keepActiveDocument: true)
    }

    @objc private func studyHistoryTapped() {
        guard let source = ConversationStore.shared.currentConversation else { return }
        let list: [Conversation]
        let title: String
        if source.isWorkspaceStudySession {
            if let wsID = source.activeStudyWorkspaceID {
                var folderChats = ConversationStore.shared.conversations(inWorkspace: wsID)
                if folderChats.isEmpty, let docID = source.studyDocumentID {
                    folderChats = ConversationStore.shared.conversations(sharingParentFolderOfDocument: docID)
                }
                list = folderChats
            } else if let docID = source.studyDocumentID {
                list = ConversationStore.shared.conversations(sharingParentFolderOfDocument: docID)
            } else {
                ConnectsToast.show("暂无相关对话", in: view, duration: 1.4)
                return
            }
            title = "工作区对话"
        } else if let docID = source.studyDocumentID {
            list = ConversationStore.shared.conversations(boundToDocument: docID)
            title = "同文件对话"
        } else {
            ConnectsToast.show("暂无相关对话", in: view, duration: 1.4)
            return
        }
        guard !list.isEmpty else {
            ConnectsToast.show("暂无相关对话", in: view, duration: 1.4)
            return
        }
        let folderWSID = source.activeStudyWorkspaceID
        let items = list.prefix(20).map { conv -> ConnectsMenuItem in
            let mark = conv.id == source.id ? " ✓" : ""
            return ConnectsMenuItem(
                title: "\(conv.title)\(mark)",
                icon: conv.isWorkspaceStudySession ? .folder : .book,
                longPressHandler: { [weak self] in
                    self?.presentStudyConversationManageMenu(for: conv)
                }
            ) {
                ConversationStore.shared.selectConversation(id: conv.id)
                // Same-folder switch: keep reader on folder lastOpened (not the peer's stale file).
                if let folderWSID,
                   let last = StudyWorkspaceStore.shared.lastOpenedDocumentID(in: folderWSID)
                    ?? source.studyDocumentID {
                    StudyWorkspaceStore.shared.setLastOpenedDocument(last, in: folderWSID)
                    ConversationStore.shared.updateConversation(id: conv.id) { draft in
                        draft.studyWorkspaceID = folderWSID
                        draft.studySessionKind = .workspace
                        draft.studyDocumentID = last
                        draft.studyPageCaptureEnabled = true
                    }
                }
            }
        }
        ConnectsMenu.present(
            from: self,
            title: title,
            items: Array(items),
            barButtonItem: studyBarButtonItem(matching: #selector(studyHistoryTapped))
                ?? studyBarButtonItem(matching: #selector(moreTapped))
                ?? navigationItem.rightBarButtonItems?.first
        )
    }

    private func presentStudyConversationManageMenu(for conv: Conversation) {
        let archiveTitle = conv.isArchived ? "取消归档" : "归档"
        ConnectsMenu.present(
            from: self,
            title: conv.title,
            items: [
                ConnectsMenuItem(title: "打开", icon: .book) {
                    ConversationStore.shared.selectConversation(id: conv.id)
                },
                ConnectsMenuItem(title: archiveTitle, icon: .archive) {
                    ConversationStore.shared.setArchived(id: conv.id, archived: !conv.isArchived)
                },
                ConnectsMenuItem(title: "删除", icon: .trash, isDestructive: true) { [weak self] in
                    self?.confirmDeleteConversation(id: conv.id, title: conv.title)
                }
            ],
            barButtonItem: studyBarButtonItem(matching: #selector(studyHistoryTapped))
                ?? studyBarButtonItem(matching: #selector(moreTapped))
                ?? navigationItem.rightBarButtonItems?.first,
            preferVertical: true
        )
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
        view.bringSubviewToFront(turnContextBar)
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

        setupKeyboardDismissTap()
    }

    /// Tap anywhere outside the composer (messages / empty state / chrome) to put the keyboard away.
    private func setupKeyboardDismissTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboardFromOutsideTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc private func dismissKeyboardFromOutsideTap(_ gesture: UITapGestureRecognizer) {
        guard isComposerFirstResponder || keyboardVisible else { return }
        guard !ConnectsNoteSheet.isVisible else { return }
        let point = gesture.location(in: view)
        if inputBar.bounds.contains(inputBar.convert(point, from: view)) { return }
        dismissComposerKeyboard()
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
        inputSideInsetConstraint = inputWidthFill
        let inputWidthMax = inputBar.widthAnchor.constraint(lessThanOrEqualToConstant: DSTheme.contentMaxWidth)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: turnContextBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -4),

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
            inputBar.setContextUsageCompacting(false)
            inputBar.updateContextUsage(
                ContextBuilder.Usage(usedChars: 0, budgetChars: 1),
                visible: false,
                animated: false
            )
            return
        }

        let convID = conv.id
        // Always reserve the ring placeholder so the tool row layout stays stable.
        let visible = true
        let compacting = ContextCompactor.isCompacting(convID)
        let immediate = contextUsageCache[convID] ?? ContextBuilder.quickUsageEstimate(for: conv)
        inputBar.setContextUsageCompacting(compacting)
        inputBar.updateContextUsage(immediate, visible: visible, animated: false)

        contextUsageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let breakdown = ContextBuilder.breakdown(for: conv)
            DispatchQueue.main.async {
                guard let self = self, convID == self.currentConversationID else { return }
                self.contextUsageCache[convID] = breakdown.usage
                self.contextBreakdownCache[convID] = breakdown
                self.inputBar.setContextUsageCompacting(ContextCompactor.isCompacting(convID))
                self.inputBar.updateContextUsage(
                    breakdown.usage,
                    visible: visible,
                    animated: animated
                )
            }
        }
        contextUsageWork = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    private func maybeAutoCompactContext() {
        guard let id = ConversationStore.shared.currentConversationID else { return }
        guard let conv = ConversationStore.shared.currentConversation else { return }
        let usage = ContextBuilder.usage(for: conv)
        inputBar.updateContextUsage(
            usage,
            visible: true,
            animated: false
        )
        guard usage.shouldAutoCompact else { return }
        inputBar.setContextUsageCompacting(true)
        ContextCompactor.compactIfNeeded(conversationID: id, force: false) { [weak self] did in
            self?.refreshContextUsage()
            if did, let host = self?.view {
                ConnectsToast.show("已压缩上下文", in: host, duration: 1.4)
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
        inputBar.setContextUsageCompacting(false)
        refreshContextUsage()
    }

    private func confirmDeleteConversation(id: String, title: String) {
        let alert = UIAlertController(
            title: "删除对话？",
            message: "将永久删除「\(title)」。此操作不可撤销。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            ConversationStore.shared.deleteConversation(id: id)
        })
        present(alert, animated: true)
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
        emptySubtitleLabel.numberOfLines = 0
        emptyContainer.addSubview(emptySubtitleLabel)

        emptyConfigureKeyButton.translatesAutoresizingMaskIntoConstraints = false
        emptyConfigureKeyButton.setTitle("配置 API Key", for: .normal)
        emptyConfigureKeyButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        emptyConfigureKeyButton.addTarget(self, action: #selector(emptyConfigureKeyTapped), for: .touchUpInside)
        emptyConfigureKeyButton.isHidden = true
        emptyContainer.addSubview(emptyConfigureKeyButton)

        // Center empty chrome in the band above the composer (moves with keyboard).
        NSLayoutConstraint.activate([
            emptyContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyContainer.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            emptyTitleLabel.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptyTitleLabel.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor, constant: -10),
            emptyTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: emptyContainer.leadingAnchor, constant: 24),
            emptyTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: emptyContainer.trailingAnchor, constant: -24),

            emptySubtitleLabel.topAnchor.constraint(equalTo: emptyTitleLabel.bottomAnchor, constant: 10),
            emptySubtitleLabel.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptySubtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: emptyContainer.leadingAnchor, constant: 28),
            emptySubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: emptyContainer.trailingAnchor, constant: -28),

            emptyConfigureKeyButton.topAnchor.constraint(equalTo: emptySubtitleLabel.bottomAnchor, constant: 18),
            emptyConfigureKeyButton.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor)
        ])

        view.bringSubviewToFront(inputBar)
    }

    @objc private func emptyConfigureKeyTapped() {
        delegate?.chatDidRequestSettings()
    }

    private func updateEmptyState() {
        let empty = (ConversationStore.shared.currentConversation?.messages.count ?? 0) == 0
        let c = DSTheme.c
        emptyContainer.backgroundColor = c.background
        emptyContainer.isHidden = !empty
        tableView.isHidden = empty
        if !empty {
            // Leaving empty chrome must restore opacity — new-chat open can leave
            // alpha at 0 while isHidden flips false on the first send.
            tableView.alpha = 1
        }
        if empty {
            contextUserIndex = nil
            turnContextBar.update(question: nil, visible: false)
            // Cancel any pending stream paint that could reconfigure a recycled cell.
            streamUIWork?.cancel()
            streamUIWork = nil
            clearNavigationPrompt()
            emptyTitleLabel.textColor = c.textPrimary
            emptySubtitleLabel.textColor = c.textSecondary
            emptyConfigureKeyButton.setTitleColor(c.accent, for: .normal)
            refreshEmptyOnboardingCopy()
        } else {
            emptyConfigureKeyButton.isHidden = true
        }
        layoutEmptyChromeForKeyboard()
    }

    /// Cold-start / missing-key empty state vs normal suggestions.
    private func refreshEmptyOnboardingCopy() {
        let model = ConversationStore.shared.currentConversation?.model ?? .deepseekV4Pro
        let hasKey = SettingsManager.shared.hasAPIKey(for: model.provider)
        emptyConfigureKeyButton.isHidden = hasKey
        if hasKey {
            emptyTitleLabel.text = "今天想聊些什么？"
            emptySubtitleLabel.text = "试试：解释当前文档 · 总结要点 · 帮我改一处代码"
        } else {
            emptyTitleLabel.text = "先配置 API Key"
            emptySubtitleLabel.text = "在设置中填写 \(model.provider.displayName) 密钥后即可开始对话。点右上角「完成」才会保存。"
        }
    }

    /// When keyboard is up, keep title above the composer; hide subtitle to avoid clutter.
    private func layoutEmptyChromeForKeyboard() {
        guard !emptyContainer.isHidden else { return }
        emptySubtitleLabel.isHidden = keyboardVisible
        if keyboardVisible {
            emptyConfigureKeyButton.isHidden = true
        } else {
            let model = ConversationStore.shared.currentConversation?.model ?? .deepseekV4Pro
            emptyConfigureKeyButton.isHidden = SettingsManager.shared.hasAPIKey(for: model.provider)
        }
    }

    private func updateModelButton() {
        let model = ConversationStore.shared.currentConversation?.model ?? .deepseekV4Pro
        // Single source of truth: input-bar AI 选项. Do not also mount a nav model chip.
        inputBar.setModelChip(title: model.displayName)
        inputBar.modelSupportsVision = model.supportsVision
        if !model.supportsVision, let id = ConversationStore.shared.currentConversationID {
            let kind = ConversationStore.shared.conversation(id: id).flatMap { conv in
                conv.studyDocumentID.flatMap { StudyDocumentStore.shared.document(id: $0)?.kind }
            }
            if kind == .pdf || kind == .ebook, inputBar.studyPageCaptureEnabled {
                ConversationStore.shared.updateConversation(id: id) { draft in
                    draft.studyPageCaptureEnabled = false
                }
                inputBar.studyPageCaptureEnabled = false
            }
        }
        modelButton.setTitle("\(model.displayName)  ▾", for: .normal)
        syncStudyPanelStageControl()
        if (ConversationStore.shared.currentConversation?.messages.count ?? 0) == 0 {
            refreshEmptyOnboardingCopy()
            layoutEmptyChromeForKeyboard()
        }
    }

    private func stepStudyPanel(towardAI: Bool) {
        guard let provider = studyContextProvider else { return }
        // Stage chips only change layout — never focus the composer.
        prepareForStudyPanelControlTap()
        dismissComposerKeyboard()
        let current = provider.studyChatPanelStage
        let next: StudyChatPanelStage?
        if towardAI {
            switch current {
            case .collapsed: next = .half
            case .half: next = .full
            case .full: next = nil
            }
        } else {
            switch current {
            case .full: next = .half
            case .half: next = .collapsed
            case .collapsed: next = nil
            }
        }
        guard let next = next else { return }
        provider.applyStudyChatPanelStage(next, animated: true)
    }

    private func presentModelPicker(anchor: UIView) {
        view.layoutIfNeeded()
        inputBar.layoutIfNeeded()
        anchor.layoutIfNeeded()
        let current = ConversationStore.shared.currentConversation?.model
        let pool = AIModelOption.visible
        ModelCapsuleDropdown.present(
            from: self,
            anchor: anchor,
            models: pool,
            selected: current,
            onPick: { [weak self] option in
                guard let self = self else { return }
                guard let id = ConversationStore.shared.currentConversationID else { return }
                ConversationStore.shared.setModel(option, for: id)
                self.inputBar.clearAttachment()
                self.updateAttachAvailability()
                self.updateModelButton()
            },
            onDismiss: { [weak self] in
                self?.updateModelButton()
            }
        )
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
        // Note sheet owns the soft keyboard — don't lift the chat composer under it.
        if ConnectsNoteSheet.isVisible { return }
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }

        if studyContextProvider?.managesPortraitKeyboardLayout == true {
            applyPortraitStudyComposerBottom(keyboardFrame: frame)
            layoutEmptyChromeForKeyboard()
            animateKeyboard(duration: duration, note: note)
            return
        }

        // Classify docked vs floating/mini so landscape undocked keyboards don't yank the composer.
        let snap = ConnectsKeyboardGeometry.resolve(screenFrame: frame, in: view)
        let safeAreaInAnchor = !composerBottomUsesViewBottom
        let lift = ConnectsKeyboardGeometry.composerLift(
            snapshot: snap,
            in: view,
            safeAreaAlreadyInAnchor: safeAreaInAnchor
        )
        switch snap.kind {
        case .hidden:
            bottomConstraint?.constant = restingComposerBottomConstant()
            keyboardVisible = false
        case .docked:
            keyboardVisible = lift > 20
            bottomConstraint?.constant = keyboardVisible ? -(lift + 6) : restingComposerBottomConstant()
        case .floatingMini:
            // Only lift when the mini keyboard covers the composer band; otherwise stay put.
            keyboardVisible = lift > 12
            bottomConstraint?.constant = keyboardVisible
                ? -(lift + DSTheme.inputBarBottomPadding)
                : restingComposerBottomConstant()
        }
        layoutEmptyChromeForKeyboard()
        animateKeyboard(duration: duration, note: note)
    }

    private func animateKeyboard(duration: Double, note: Notification) {
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
            ?? UIView.AnimationCurve.easeInOut.rawValue
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))
        UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
            self.view.layoutIfNeeded()
            // Send resigns the keyboard after rows insert + scroll lock; without
            // re-pinning here the viewport stays above the new bubbles.
            if self.finishViewportLocked || (self.isCurrentStreaming && self.stickToBottom) {
                self.snapTableContentOffsetToBottom()
            }
        }, completion: { _ in
            if self.finishViewportLocked || (self.isCurrentStreaming && self.stickToBottom) {
                self.followStreamingViewportToBottom()
            }
        })
    }

    private func restingComposerBottomConstant() -> CGFloat {
        if studyContextProvider?.managesPortraitKeyboardLayout == true {
            return -(view.safeAreaInsets.bottom + DSTheme.inputBarBottomPadding)
        }
        return -DSTheme.inputBarBottomPadding
    }

    private func applyPortraitStudyComposerBottom(keyboardFrame: CGRect) {
        refreshComposerBottomAnchorIfNeeded()
        let snap = ConnectsKeyboardGeometry.resolve(screenFrame: keyboardFrame, in: view)
        switch snap.kind {
        case .hidden, .docked:
            // Docked: StudyShell already raised reader + chat above the keyboard.
            // Keep composer at the panel bottom — do not lift again inside the panel.
            keyboardVisible = false
            bottomConstraint?.constant = restingComposerBottomConstant()
        case .floatingMini:
            let lift = ConnectsKeyboardGeometry.composerLift(
                snapshot: snap,
                in: view,
                safeAreaAlreadyInAnchor: false
            )
            keyboardVisible = lift > 12
            bottomConstraint?.constant = keyboardVisible
                ? -(lift + DSTheme.inputBarBottomPadding)
                : restingComposerBottomConstant()
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
        ConnectsToast.show("已复制全部对话", in: view)
    }

    /// Build API messages for a specific conversation — never the "currently visible" one by accident.
    /// Pass `studyCapture` from `performSend` to avoid a second PDF screenshot on the hot path.
    private func apiContext(
        for model: AIModelOption,
        conversationID: String,
        studyCapture: StudyPageCapture? = nil
    ) -> [ChatMessage] {
        guard let conv = ConversationStore.shared.conversation(id: conversationID) else { return [] }
        var working = conv
        applyStudyCaptureToLastUserMessage(
            in: &working.messages,
            conversationID: conversationID,
            persist: false,
            capture: studyCapture
        )
        applyCodeAIEditAuthorization(
            in: &working.messages,
            conversationID: conversationID,
            persist: false
        )
        applyWorkspaceAgentAuthorization(
            in: &working.messages,
            conversationID: conversationID,
            persist: false
        )
        let built = Self.buildContextResult(from: working, model: model)
        if conversationID == currentConversationID {
            DispatchQueue.main.async { [weak self] in
                self?.refreshContextUsage()
            }
        }
        return built.messages
    }

    /// Pick keep-recent window once via a cheap estimate, then build a single context.
    /// `conv.messages` should already include study/JPEG/auth for this request (memory copy).
    private static func buildContextResult(
        from conv: Conversation,
        model: AIModelOption
    ) -> ContextBuilder.BuildResult {
        let keep = ContextBuilder.keepRecentTurns(for: conv)
        return ContextBuilder.build(
            from: conv.messages,
            model: model,
            existingSummary: conv.contextSummary,
            existingThroughID: conv.contextSummaryThroughMessageID,
            keepRecentTurns: keep
        )
    }

    /// Snapshot on main, assemble on a background queue, then apply study capture on main.
    private func buildAPIContextAsync(
        for model: AIModelOption,
        conversationID: String,
        studyCapture: StudyPageCapture? = nil,
        completion: @escaping ([ChatMessage]) -> Void
    ) {
        guard let conv = ConversationStore.shared.conversation(id: conversationID) else {
            completion([])
            return
        }
        // Inject study/JPEG/auth on a value copy *before* budget so fill math matches the request.
        // persist:false — first send already wrote the user bubble; retry/rebuild must not mutate history.
        var snapshot = conv
        applyStudyCaptureToLastUserMessage(
            in: &snapshot.messages,
            conversationID: conversationID,
            persist: false,
            capture: studyCapture
        )
        applyCodeAIEditAuthorization(
            in: &snapshot.messages,
            conversationID: conversationID,
            persist: false
        )
        applyWorkspaceAgentAuthorization(
            in: &snapshot.messages,
            conversationID: conversationID,
            persist: false
        )
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.buildContextResult(from: snapshot, model: model)
            DispatchQueue.main.async {
                if conversationID == self?.currentConversationID {
                    self?.refreshContextUsage()
                }
                completion(result.messages)
            }
        }
    }

    /// Re-inject「AI 编辑」permission on the last user turn (send + retry share this path).
    /// Independent of 深度思考 — only `inputBar.codeAIEditEnabled` matters.
    private func applyCodeAIEditAuthorization(
        in messages: inout [ChatMessage],
        conversationID: String,
        persist: Bool
    ) {
        guard conversationID == currentConversationID,
              inputBar.codeAIEditEnabled,
              let idx = messages.lastIndex(where: { $0.role == .user }) else { return }
        var msg = messages[idx]
        let auth = CodeEditApplyTools.authorizationPrefix
        let rest = CodeEditApplyTools.strippingAuthorization(from: msg.apiContextPrefix ?? "")
        let next = rest.isEmpty ? auth : auth + "\n\n" + rest
        guard msg.apiContextPrefix != next else { return }
        msg.apiContextPrefix = next
        messages[idx] = msg
        guard persist else { return }
        ConversationStore.shared.updateConversationQuietly(id: conversationID) { draft in
            guard let storeIdx = draft.messages.lastIndex(where: { $0.id == msg.id })
                    ?? draft.messages.lastIndex(where: { $0.role == .user }) else { return }
            draft.messages[storeIdx].apiContextPrefix = next
        }
    }

    /// Re-inject workspace agent tool protocol on the last user turn.
    private func applyWorkspaceAgentAuthorization(
        in messages: inout [ChatMessage],
        conversationID: String,
        persist: Bool
    ) {
        guard StudyAgentMode.isAgentProductEnabled,
              let conv = ConversationStore.shared.conversation(id: conversationID),
              conv.isWorkspaceStudySession,
              let wsID = conv.activeStudyWorkspaceID,
              let idx = messages.lastIndex(where: { $0.role == .user }) else { return }
        var msg = messages[idx]
        let listing = StudyWorkspaceStore.shared.listFileNames(in: wsID).joined(separator: "\n")
        let agent = AgentOrchestrator.shared.apiPrefix(for: conv, workspaceListing: listing)
        let prefix = msg.apiContextPrefix ?? ""
        let withoutAgent: String = {
            if let r = prefix.range(of: "## CONNECTS_WORKSPACE_AGENT") {
                // Drop previous agent block through next blank-blank if possible.
                return String(prefix[prefix.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return prefix
        }()
        let next = withoutAgent.isEmpty ? agent : agent + "\n\n" + withoutAgent
        guard msg.apiContextPrefix != next else { return }
        msg.apiContextPrefix = next
        messages[idx] = msg
        guard persist else { return }
        ConversationStore.shared.updateConversationQuietly(id: conversationID) { draft in
            guard let storeIdx = draft.messages.lastIndex(where: { $0.id == msg.id })
                    ?? draft.messages.lastIndex(where: { $0.role == .user }) else { return }
            draft.messages[storeIdx].apiContextPrefix = next
        }
    }

    private func isStudyPageCaptureEnabled(for conversationID: String) -> Bool {
        guard let conv = ConversationStore.shared.conversation(id: conversationID),
              conv.studyDocumentID != nil else { return false }
        if conv.studyPageCaptureEnabled { return true }
        return conversationID == currentConversationID && inputBar.studyPageCaptureEnabled
    }

    private func studyPageCapturePayload() -> StudyPageCapture? {
        studyContextProvider?.captureCurrentStudyPage()
    }

    /// Inject study prefix/JPEG onto the last user turn of a *working copy*.
    /// `persist` should be true only if the caller has not already written the bubble
    /// (normal send writes it in `performSend`; API rebuilds pass false).
    private func applyStudyCaptureToLastUserMessage(
        in messages: inout [ChatMessage],
        conversationID: String,
        persist: Bool,
        capture: StudyPageCapture? = nil
    ) {
        let resolvedCapture: StudyPageCapture?
        if let capture = capture {
            resolvedCapture = capture
        } else if inputBar.codeAIEditEnabled, conversationID == currentConversationID {
            // Retry / async rebuild: AI edit always needs a fresh file snapshot.
            resolvedCapture = studyPageCapturePayload()
        } else if isStudyPageCaptureEnabled(for: conversationID) {
            resolvedCapture = studyPageCapturePayload()
        } else {
            resolvedCapture = nil
        }
        guard let capture = resolvedCapture,
              let idx = messages.lastIndex(where: { $0.role == .user }) else { return }
        var msg = messages[idx]
        let prefix = capture.apiContextPrefix()
        let hasDescription = !(msg.imageDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        // Only keep JPEG when this turn still needs vision and no durable text exists.
        // Rich text pages and already-transcribed turns must not re-inject screenshots.
        let attachJPEG = convModelSupportsVision(conversationID: conversationID)
            && capture.imageJPEGBase64 != nil
            && !capture.prefersTextOnly
            && !hasDescription
        let jpeg = attachJPEG ? capture.imageJPEGBase64 : nil
        let hideBubble = attachJPEG ? capture.hidesImageInChatBubble : msg.hidesAttachedImageInChat
        let changed = msg.apiContextPrefix != prefix
            || msg.imageJPEGBase64 != jpeg
            || (attachJPEG && msg.hidesAttachedImageInChat != hideBubble)
            || (!attachJPEG && msg.imageJPEGBase64 != nil && (hasDescription || capture.hasRichExtractableText))
        guard changed else { return }
        msg.apiContextPrefix = prefix
        msg.imageJPEGBase64 = jpeg
        if attachJPEG {
            msg.hidesAttachedImageInChat = hideBubble
        }
        messages[idx] = msg
        guard persist else { return }
        let messageID = msg.id
        ConversationStore.shared.updateConversationQuietly(id: conversationID) { draft in
            guard let i = draft.messages.firstIndex(where: { $0.id == messageID }) else { return }
            draft.messages[i].apiContextPrefix = prefix
            draft.messages[i].imageJPEGBase64 = jpeg
            if attachJPEG {
                draft.messages[i].hidesAttachedImageInChat = hideBubble
            }
        }
    }

    private func convModelSupportsVision(conversationID: String) -> Bool {
        ConversationStore.shared.conversation(id: conversationID)?.model.supportsVision ?? false
    }

    private func notifyUnsupportedImageSend() {
        ConnectsToast.show(AIModelOption.unsupportedImageSendMessage, in: view, duration: 1.8)
    }

    private func notifyStudyCaptureFailure(for conversationID: String) {
        guard conversationID == currentConversationID else { return }
        let message: String
        if studyContextProvider == nil {
            message = "无法读取文档（学习模式未就绪）"
        } else if ConversationStore.shared.conversation(id: conversationID)?.studyDocumentID == nil {
            message = "当前对话未依附文档"
        } else {
            message = "无法截取当前阅读位置"
        }
        ConnectsToast.show(message, in: view, duration: 2.0)
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

        let userMessage = conv.messages[userIndex]
        let hasImages = userMessage.imageJPEGBase64?.isEmpty == false
        guard let model = streamModel(for: conv.model, hasImages: hasImages) else {
            showAlert(
                title: "缺少 API Key",
                message: streamModelMissingKeyMessage(for: conv.model, hasImages: hasImages),
                offerSettings: true
            )
            return
        }

        let needsAITitle = (conv.title == "新对话" || conv.title.hasSuffix("（分叉）")) && !conv.titleLocked
        let convID = conv.id
        let oldRowCount = tableView.numberOfRows(inSection: 0)

        // Restore file text from before this assistant turn's Keep (or cancel open Diff).
        let assistantIndex = userIndex + 1
        if assistantIndex < conv.messages.count, conv.messages[assistantIndex].role == .assistant {
            studyContextProvider?.revertStudyCodeEditIfNeeded(
                forAssistantMessageID: conv.messages[assistantIndex].id
            )
        } else {
            // No assistant yet — still clear a stray open Diff from a prior attempt.
            studyContextProvider?.revertStudyCodeEditIfNeeded(forAssistantMessageID: "")
        }

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

        applyRetryThreadUI(oldRowCount: oldRowCount, userIndex: userIndex)

        let target = ConversationStore.shared.conversation(id: convID)
        let userText = target?.messages[userIndex].content ?? userMessage.content
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
            buildAPIContextAsync(for: model, conversationID: convID) { [weak self] messages in
                self?.startStream(
                    conversationID: convID,
                    messages: messages,
                    model: model,
                    needsAITitle: needsAITitle
                )
            }
        }
    }

    private func applyRetryThreadUI(oldRowCount: Int, userIndex: Int) {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let newCount = messages.count
        let assistantIndex = userIndex + 1
        let layoutWidth = currentRenderWidth()

        stickToBottom = true
        readingHistory = false
        viewportPinnedByUser = false
        updateEmptyState()

        if rowHeights.isScrollHeightFrozen {
            rowHeights.endScrollHeightFreeze()
        }

        if assistantIndex < messages.count {
            let assistant = messages[assistantIndex]
            rowHeights.invalidate(messageID: assistant.id)
            pendingHeights.removeValue(forKey: assistant.id)
            let streamingFloor = max(
                ChatRowHeightResolver.cheapColumnEstimate(for: assistant, layoutWidth: layoutWidth),
                96
            )
            rowHeights.commitMeasured(
                columnHeight: streamingFloor,
                messageID: assistant.id,
                allowShrink: true
            )
        }

        renderedMessageCount = newCount

        UIView.performWithoutAnimation {
            syncTableRowCount(from: oldRowCount, to: newCount)
            if assistantIndex < tableView.numberOfRows(inSection: 0) {
                // Content-only refresh after count is already synced.
                if let cell = tableView.cellForRow(at: IndexPath(row: assistantIndex, section: 0))
                    as? AssistantMessageCell,
                   assistantIndex < messages.count {
                    let assistant = messages[assistantIndex]
                    cell.configure(
                        with: assistant,
                        preferredHeight: rowHeights.committedColumnHeight(for: assistant.id),
                        layoutWidth: layoutWidth,
                        pairedUser: pairedUserMessage(forAssistantAt: assistantIndex, in: messages)
                    )
                }
            }
            tableView.layoutIfNeeded()
        }

        if let live = ConversationStore.shared.currentConversation?.messages, !live.isEmpty {
            chaseLiveTailToBottom(messages: live, layoutWidth: layoutWidth)
        } else {
            scrollToBottom(animated: false, force: true)
        }
        syncStreamingChrome()
        refreshStreamingRow(waitingGlyph: nil, relayout: true)
        followStreamingViewportToBottom()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.followStreamingViewportToBottom()
            if let live = ConversationStore.shared.currentConversation?.messages, !live.isEmpty {
                self.chaseLiveTailToBottom(messages: live, layoutWidth: self.currentRenderWidth())
            }
        }
    }

    /// Plan queries from conversation → search → read pages → stream. Shared by send + retry.
    /// Each conversation has its own search generation so parallel chats never cancel or cross-wire.
    private func beginWebSearchThenStream(
        convID: String,
        model: AIModelOption,
        needsAITitle: Bool,
        query: String,
        studyCapture: StudyPageCapture? = nil
    ) {
        let generation = WebSearchCoordinator.shared.begin(convID)
        syncStreamingChrome()
        updateSearchProcess(
            convID: convID,
            phase: .planning,
            body: "正在结合对话上下文推荐查证来源…\n（会消解「那这个呢」「为什么」等指代，并选择百科、知乎、媒体等站点定向检索。）"
        )

        // Lightweight transcript only — planSearch truncates to ~3.5k chars.
        // Avoid a full ContextBuilder pass before search (was blocking TTFT).
        let planningMsgs = Self.planningMessages(for: convID)
        WebSearchService.planSearch(
            contextMessages: planningMsgs,
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
                    let phase: SearchProcessPhase =
                        (status.contains("阅读") || status.contains("已读")) ? .reading : .searching
                    self.updateSearchProcess(
                        convID: convID,
                        phase: phase,
                        append: "\n" + status
                    )
                }
            ) { [weak self] result in
                guard let self = self else { return }
                guard WebSearchCoordinator.shared.isCurrent(convID, generation: generation) else { return }
                WebSearchCoordinator.shared.finish(convID, generation: generation)
                ConversationStore.shared.updateConversationQuietly(id: convID) { c in
                    guard var last = c.messages.last, last.isStreaming else { return }
                    last.content = ""
                    c.messages[c.messages.count - 1] = last
                }
                // Single ContextBuilder pass after search, off the main-thread hot path.
                self.buildAPIContextAsync(
                    for: model,
                    conversationID: convID,
                    studyCapture: studyCapture
                ) { msgs in
                    guard WebSearchCoordinator.shared.matchesGeneration(convID, generation: generation) else { return }
                    var apiMsgs = msgs
                    switch result {
                    case .success(let bundle):
                        self.updateSearchProcess(
                            convID: convID,
                            phase: .done,
                            body: bundle.processLog
                        )
                        apiMsgs = WebSearchService.inject(into: apiMsgs, bundle: bundle)
                        apiMsgs = WebSearchService.fitInjectedContext(apiMsgs, model: model)
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
                    self.startStream(
                        conversationID: convID,
                        messages: apiMsgs,
                        model: model,
                        needsAITitle: needsAITitle
                    )
                }
            }
        }
    }

    /// Recent finished turns for web-search planning (no ContextBuilder / no images).
    private static func planningMessages(for conversationID: String) -> [ChatMessage] {
        guard let conv = ConversationStore.shared.conversation(id: conversationID) else { return [] }
        let finished = conv.messages.filter {
            !$0.isStreaming && ($0.role == .user || $0.role == .assistant)
        }
        return Array(finished.suffix(12)).map { msg in
            var copy = msg
            copy.imageJPEGBase64 = nil
            return copy
        }
    }

    private func updateSearchProcess(
        convID: String,
        phase: SearchProcessPhase,
        body: String? = nil,
        append: String? = nil
    ) {
        // Status lives only in the assistant bubble's search tag — never in
        // UINavigationItem.prompt (which sits above the model capsule).
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
        if let title = modelButton.title(for: .normal)?.replacingOccurrences(of: "▾", with: "▴") {
            modelButton.setTitle(title, for: .normal)
        }
        presentModelPicker(anchor: modelButton)
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

    /// Pick the model for one API request. Never mutates the conversation's stored choice.
    /// Images on non-vision models are transcribed with Kimi K2.5 Vision first; this
    /// always returns the conversation model for the actual reply.
    private func streamModel(for conversationModel: AIModelOption, hasImages: Bool) -> AIModelOption? {
        _ = hasImages
        guard SettingsManager.shared.hasAPIKey(for: conversationModel.provider) else { return nil }
        return conversationModel
    }

    private func streamModelMissingKeyMessage(for conversationModel: AIModelOption, hasImages: Bool) -> String {
        _ = hasImages
        return "请先在设置中填写 \(conversationModel.provider.displayName) 的 API Key。\n当前模型：\(conversationModel.displayName)"
    }

    private func imageTranscriptionModel() -> AIModelOption? {
        let vision = AIModelOption.preferredImageTranscription
        guard SettingsManager.shared.hasAPIKey(for: vision.provider) else { return nil }
        return vision
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let b64 = ImageAttachmentHelper.prepareJPEGBase64(from: image) else {
            showAlert(title: "无法添加图片", message: "图片处理失败，请换一张再试。")
            return
        }
        inputBar.setAttachment(image: image, base64: b64)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    /// After paint: jump contentOffset to the table bottom (no fancy settle).
    private func pinToFinishedTurnBottom(unlockScroll: Bool = false) {
        if let messages = ConversationStore.shared.currentConversation?.messages,
           !messages.isEmpty {
            pinFinishedTailViewport(
                messages: messages,
                layoutWidth: currentRenderWidth(),
                unlockScroll: unlockScroll
            )
        } else {
            stickToBottom = true
            readingHistory = false
            viewportPinnedByUser = false
            UIView.performWithoutAnimation {
                tableView.layoutIfNeeded()
                snapTableContentOffsetToBottom()
            }
            if unlockScroll {
                unlockScrollAfterFinishPin()
            }
        }
    }

    private func scrollToBottom(animated: Bool, force: Bool = false) {
        guard force || !isViewportPinned() else { return }
        guard ConversationStore.shared.currentConversation?.messages.isEmpty == false else { return }
        let apply = { self.scrollToLastRowBottom(force: force) }
        if animated {
            UIView.animate(withDuration: 0.2, animations: apply)
        } else {
            UIView.performWithoutAnimation(apply)
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

        guard let captionModel = imageTranscriptionModel() else {
            showAlert(
                title: "缺少视觉模型 Key",
                message: streamModelMissingKeyMessage(for: conv.model, hasImages: true),
                offerSettings: true
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
        var descriptions: [String: String] = [:]

        func finish(_ error: Error? = nil) {
            self.isTranscribingImages = false
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
        guard let conv = ConversationStore.shared.currentConversation else { return }

        if let imageBase64, !imageBase64.isEmpty, !conv.model.supportsVision {
            notifyUnsupportedImageSend()
            return
        }

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

        let usage = ContextBuilder.quickUsageEstimate(for: conv)
        let intendedConversationID = conv.id
        if usage.shouldAutoCompact {
            inputBar.setContextUsageCompacting(true)
            // Capture and clear now. If the user switches chats while compacting,
            // the callback must neither erase the new chat's draft nor redirect
            // this send to whichever conversation happens to be visible.
            inputBar.clearText()
            ContextCompactor.compactIfNeeded(conversationID: intendedConversationID, force: true) { [weak self] _ in
                guard let self = self else { return }
                self.inputBar.setContextUsageCompacting(false)
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

        let resolvedStudyCapture: StudyPageCapture?
        var shouldClearAskChrome = false
        if inputBar.codeAIEditEnabled {
            // AI 编辑 must see the live file. Don't depend on the separate「文档」toggle —
            // users often arm AI edit then turn document context off, and the first write
            // then emits an empty/useless CONNECTS_EDIT.
            guard let capture = studyPageCapturePayload() else {
                notifyStudyCaptureFailure(for: conversationID)
                ConnectsToast.show("AI 编辑需要可读的代码/文本文件", in: view, duration: 2.0)
                return
            }
            resolvedStudyCapture = capture
            _ = StudyAskSelectionStore.shared.consume(for: conversationID)
            shouldClearAskChrome = true
        } else if isStudyPageCaptureEnabled(for: conversationID) {
            if let capture = studyPageCapturePayload() {
                resolvedStudyCapture = capture
                _ = StudyAskSelectionStore.shared.consume(for: conversationID)
                shouldClearAskChrome = true
            } else {
                notifyStudyCaptureFailure(for: conversationID)
                return
            }
        } else {
            resolvedStudyCapture = nil
            // Keep pending Ask when page sync is off — it was not injected into this turn.
        }
        if currentConversationID == conversationID, shouldClearAskChrome {
            clearAskSelectionChip()
            studyContextProvider?.clearAskSelectionHighlightInReader()
        }

        let finalImage: String?
        if let jpeg = resolvedStudyCapture?.imageJPEGBase64 ?? imageBase64, !jpeg.isEmpty {
            if conv.model.supportsVision {
                finalImage = jpeg
            } else if resolvedStudyCapture?.prefersTextOnly == true
                        || resolvedStudyCapture?.hasRichExtractableText == true {
                finalImage = nil
            } else {
                notifyUnsupportedImageSend()
                return
            }
        } else {
            finalImage = nil
        }
        var studyPrefix = resolvedStudyCapture?.apiContextPrefix()
        // Auth is also re-applied in buildAPIContextAsync (covers retry). Keep here for
        // the persisted user message on first send.
        if inputBar.codeAIEditEnabled {
            let auth = CodeEditApplyTools.authorizationPrefix
            let rest = CodeEditApplyTools.strippingAuthorization(from: studyPrefix ?? "")
            studyPrefix = rest.isEmpty ? auth : auth + "\n\n" + rest
        }
        if StudyAgentMode.isAgentProductEnabled,
           conv.isWorkspaceStudySession,
           let wsID = conv.activeStudyWorkspaceID {
            AgentOrchestrator.shared.clearPendingAsk(for: conv.id)
            let listing = StudyWorkspaceStore.shared.listFileNames(in: wsID).joined(separator: "\n")
            let agent = AgentOrchestrator.shared.apiPrefix(for: conv, workspaceListing: listing)
            if let existing = studyPrefix, !existing.isEmpty {
                studyPrefix = agent + "\n\n" + existing
            } else {
                studyPrefix = agent
            }
            agentToolRoundCounts[conv.id] = 0
            // Root assistant id is assigned below once the message exists.
            agentProcessRootIDs[conv.id] = nil
        } else if conv.isWorkspaceStudySession, let wsID = conv.activeStudyWorkspaceID {
            // Folder Study (Agent gated): light listing only — no tool protocol.
            let listing = StudyWorkspaceStore.shared.listFileNames(in: wsID).joined(separator: "\n")
            let active = conv.studyActiveFileName ?? "(none)"
            let folderCtx = """
            ## WORKSPACE FILES
            \(listing.isEmpty ? "(empty folder)" : listing)

            ## ACTIVE FILE
            \(active)
            Edits (CONNECTS_EDIT) apply only to the active file. Switch files in the reader title to change the target.
            """
            if let existing = studyPrefix, !existing.isEmpty {
                studyPrefix = folderCtx + "\n\n" + existing
            } else {
                studyPrefix = folderCtx
            }
        }
        let trimmedUserText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let needsAITitle = (conv.title == "新对话" || conv.title.hasSuffix("（分叉）")) && !conv.titleLocked
        let displayText: String
        if !trimmedUserText.isEmpty {
            displayText = text
        } else if finalImage != nil {
            displayText = resolvedStudyCapture.map { "[\($0.label)]" } ?? "[图片]"
        } else {
            displayText = text
        }
        let userMsg = ChatMessage(
            role: .user,
            content: displayText,
            imageJPEGBase64: finalImage,
            hidesAttachedImageInChat: resolvedStudyCapture?.hidesImageInChatBubble ?? false,
            apiContextPrefix: studyPrefix
        )
        let hasImageAttachment = finalImage != nil && !(finalImage?.isEmpty ?? true)
        guard let model = streamModel(for: conv.model, hasImages: hasImageAttachment) else {
            if currentConversationID == conversationID {
                showAlert(
                    title: "缺少 API Key",
                    message: streamModelMissingKeyMessage(for: conv.model, hasImages: hasImageAttachment),
                    offerSettings: true
                )
            }
            return
        }
        if hasImageAttachment, !conv.model.supportsVision {
            notifyUnsupportedImageSend()
            return
        }

        let searchOn = SettingsManager.shared.webSearchEnabled && !trimmedUserText.isEmpty
        let useAgentChrome = conv.usesWorkspaceAgentChrome
        let assistantMsg = ChatMessage(
            role: .assistant,
            content: "",
            reasoningContent: "",
            searchProcessContent: searchOn ? "正在结合对话上下文规划检索词…" : "",
            searchProcessPhase: searchOn ? .planning : .idle,
            isStreaming: true,
            agentProcessSteps: [],
            agentProcessPhase: useAgentChrome ? .running : .idle,
            agentProcessStartedAt: useAgentChrome ? Date() : nil
        )
        if useAgentChrome {
            agentProcessRootIDs[conv.id] = assistantMsg.id
            AgentOrchestrator.shared.resetTurnDedup(for: conv.id)
        } else {
            agentProcessRootIDs[conv.id] = nil
        }
        let convID = conv.id
        let firstNewRow = conv.messages.count
        // Drop width-bucket stale heights so study half-panel rows don't open squashed or hollow.
        rowHeights.invalidate(messageID: userMsg.id)
        rowHeights.invalidate(messageID: assistantMsg.id)
        pendingHeights.removeValue(forKey: userMsg.id)
        pendingHeights.removeValue(forKey: assistantMsg.id)
        if isStudySessionActive() {
            let layoutWidth = currentRenderWidth()
            if let userH = ChatRowHeightResolver.estimatedUserColumnContentHeight(
                for: userMsg,
                layoutWidth: layoutWidth
            ), userH > 40 {
                rowHeights.commitMeasured(columnHeight: userH, messageID: userMsg.id, allowShrink: true)
            }
            let streamingFloor: CGFloat
            if assistantMsg.hasAgentProcess {
                // Cursor: one muted status line (Thinking / Planning) — never a boxed chrome shell.
                let meta = SettingsManager.shared.chatThinkingFontSize
                let line = ceil(UIFont.systemFont(ofSize: meta).lineHeight) + 8
                streamingFloor = max(line, 28)
            } else {
                streamingFloor = max(
                    ChatRowHeightResolver.cheapColumnEstimate(for: assistantMsg, layoutWidth: layoutWidth),
                    96
                )
            }
            rowHeights.commitMeasured(
                columnHeight: streamingFloor,
                messageID: assistantMsg.id,
                allowShrink: !assistantMsg.hasAgentProcess
            )
        }

        ConversationStore.shared.updateConversationQuietly(id: conversationID) { c in
            c.messages.append(userMsg)
            c.messages.append(assistantMsg)
        }
        if currentConversationID == convID {
            inputBar.clearText()
            updateEmptyState()
            readingHistory = false
            viewportPinnedByUser = false
            stickToBottom = true
            if rowHeights.isScrollHeightFrozen {
                rowHeights.endScrollHeightFreeze()
            }
            // First turn in a brand-new chat: ensure the table is actually visible
            // (empty open left alpha=0; only isHidden was cleared above).
            tableView.alpha = 1
            tableView.isHidden = false
            UIView.performWithoutAnimation {
                if firstNewRow == 0 {
                    // Prefer insertRows once the empty table is visible; reload only if
                    // the table already has a stale snapshot (iOS 12 edge cases).
                    if tableView.numberOfRows(inSection: 0) == 0 {
                        tableView.insertRows(
                            at: [
                                IndexPath(row: 0, section: 0),
                                IndexPath(row: 1, section: 0)
                            ],
                            with: .none
                        )
                    } else {
                        tableView.reloadData()
                    }
                } else {
                    tableView.insertRows(
                        at: [
                            IndexPath(row: firstNewRow, section: 0),
                            IndexPath(row: firstNewRow + 1, section: 0)
                        ],
                        with: .none
                    )
                }
                tableView.layoutIfNeeded()
            }
            stickToBottom = true
            if let live = ConversationStore.shared.currentConversation?.messages,
               !live.isEmpty {
                chaseLiveTailToBottom(messages: live, layoutWidth: currentRenderWidth())
                let last = IndexPath(row: live.count - 1, section: 0)
                if last.row < tableView.numberOfRows(inSection: 0) {
                    tableView.scrollToRow(at: last, at: .bottom, animated: false)
                }
                snapTableContentOffsetToBottom()
            } else {
                scrollToBottom(animated: false, force: true)
            }
            refreshContextUsage()
            updateTurnContextBar(preferBottom: true)
            // Paint the streaming shell immediately — don't wait for the first
            // stream tick (thinking/search tags should show on send).
            syncStreamingChrome()
            refreshStreamingRow(waitingGlyph: nil, relayout: true)
            followStreamingViewportToBottom()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.readingHistory = false
                self.viewportPinnedByUser = false
                self.stickToBottom = true
                self.followStreamingViewportToBottom()
                if let live = ConversationStore.shared.currentConversation?.messages,
                   !live.isEmpty {
                    self.chaseLiveTailToBottom(messages: live, layoutWidth: self.currentRenderWidth())
                    // Study narrow panel: heights often settle one frame late — re-pin.
                    if self.isStudyNarrowPanelActive() || self.studyChromeMode != .none {
                        self.pinOpenViewportToBottom(live, layoutWidth: self.currentRenderWidth())
                    }
                }
            }
            if isStudyNarrowPanelActive() || studyChromeMode != .none {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self = self else { return }
                    guard self.stickToBottom else { return }
                    self.readingHistory = false
                    self.viewportPinnedByUser = false
                    if let live = ConversationStore.shared.currentConversation?.messages,
                       !live.isEmpty {
                        self.pinOpenViewportToBottom(live, layoutWidth: self.currentRenderWidth())
                    }
                }
            }
        }
        // This posts a title notification. Do it only after UITableView has
        // consumed the two inserted rows; otherwise syncStreamingChrome can
        // start the stream timer against the table's old zero-row snapshot.
        if needsAITitle {
            ConversationStore.shared.applyProvisionalTitle(id: convID, fromUserText: displayText)
        }

        // Phase B: start the reply. Vision models stream immediately (image uploaded).
        let captureForAPI = resolvedStudyCapture
        let startReply = { [weak self] in
            guard let self = self else { return }
            if searchOn {
                self.beginWebSearchThenStream(
                    convID: convID,
                    model: model,
                    needsAITitle: needsAITitle,
                    query: displayText,
                    studyCapture: captureForAPI
                )
            } else {
                self.buildAPIContextAsync(
                    for: model,
                    conversationID: convID,
                    studyCapture: captureForAPI
                ) { messages in
                    self.startStream(
                        conversationID: convID,
                        messages: messages,
                        model: model,
                        needsAITitle: needsAITitle
                    )
                }
            }
        }

        DispatchQueue.main.async(execute: startReply)
    }

    private func showAlert(title: String, message: String, offerSettings: Bool = false) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if offerSettings {
            alert.addAction(UIAlertAction(title: "去设置", style: .default) { [weak self] _ in
                self?.delegate?.chatDidRequestSettings()
            })
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        } else {
            alert.addAction(UIAlertAction(title: "好", style: .default))
        }
        present(alert, animated: true)
    }

    #if DEBUG
    func debugBenchThinkingExpand(iterations: Int = 1) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let row = messages.lastIndex(where: { $0.role == .assistant }) else {
            NSLog("[ChromeViewerBench] no assistant row")
            return
        }
        let path = IndexPath(row: row, section: 0)
        tableView.scrollToRow(at: path, at: .bottom, animated: false)
        tableView.layoutIfNeeded()
        guard let cell = tableView.cellForRow(at: path) as? AssistantMessageCell else {
            NSLog("[ChromeViewerBench] cell not visible")
            return
        }
        let count = max(1, iterations)
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) { [weak self, weak cell] in
                NSLog("[ChromeViewerBench] open #%d", i + 1)
                cell?.debugPerformThinkingChromeTap()
                self?.dismiss(animated: false)
            }
        }
    }
    #endif
}

extension ChatViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard isComposerFirstResponder || keyboardVisible else { return false }
        guard !ConnectsNoteSheet.isVisible else { return false }
        guard let touched = touch.view else { return true }
        // Keep taps on the composer (chips / model / send) from dismissing.
        if touched === inputBar || touched.isDescendant(of: inputBar) { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
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
        if rowHeights.isScrollHeightFrozen {
            ensureFrozenRowHeightFromCache(
                for: msg,
                row: indexPath.row,
                messageCount: messages.count,
                layoutWidth: layoutWidth
            )
            if msg.role == .assistant, !msg.isStreaming {
                pregrowFrozenAssistantRowIfNeeded(
                    for: msg,
                    row: indexPath.row,
                    messageCount: messages.count,
                    layoutWidth: layoutWidth
                )
            }
        }
        if msg.role == .user {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: MessageCellReuseID.user,
                for: indexPath
            ) as! UserMessageCell
            if msg.shouldHideInTranscript {
                cell.contentView.isHidden = true
                cell.isUserInteractionEnabled = false
                cell.accessibilityElementsHidden = true
                return cell
            }
            cell.contentView.isHidden = false
            cell.isUserInteractionEnabled = true
            cell.accessibilityElementsHidden = false
            cell.cellDelegate = self
            bindImageCache(to: cell, message: msg)
            cell.configure(with: msg, preferredHeight: preferred, layoutWidth: layoutWidth)
            return cell
        }
        let cell = tableView.dequeueReusableCell(
            withIdentifier: MessageCellReuseID.assistant,
            for: indexPath
        ) as! AssistantMessageCell
        if msg.shouldHideInTranscript {
            cell.contentView.isHidden = true
            cell.isUserInteractionEnabled = false
            cell.accessibilityElementsHidden = true
            return cell
        }
        cell.contentView.isHidden = false
        cell.isUserInteractionEnabled = true
        cell.accessibilityElementsHidden = false
        cell.cellDelegate = self
        bindImageCache(to: cell, message: msg)
        let pairedUser = pairedUserMessage(forAssistantAt: indexPath.row, in: messages)
        if (pendingOpenAtBottom || suppressHeightRemeasure),
           !msg.isStreaming,
           isTailAssistantMessage(msg.id) {
            cell.configureForOpenBottom(
                with: msg,
                preferredHeight: preferred,
                layoutWidth: layoutWidth
            )
            return cell
        }
        let needsFrozenHistoryPaint = rowHeights.isScrollHeightFrozen
            && readingHistory
            && !msg.isStreaming
            && !msg.content.isEmpty
            && !cell.hasVisibleBodyPaint
        if needsFrozenHistoryPaint {
            let row = indexPath.row
            let count = messages.count
            primeFrozenAssistantHeight(
                for: msg,
                row: row,
                messageCount: count,
                layoutWidth: layoutWidth,
                messages: messages
            )
            cell.configureForOpenHistory(
                with: msg,
                preferredHeight: preferred,
                layoutWidth: layoutWidth
            )
            if cell.hasVisibleBodyPaint {
                pinFrozenHistoryRowFromCell(cell, message: msg)
            }
        } else {
            cell.configure(with: msg, preferredHeight: preferred, layoutWidth: layoutWidth, pairedUser: pairedUser)
            if rowHeights.isScrollHeightFrozen,
               !msg.isStreaming,
               !msg.content.isEmpty,
               !cell.hasVisibleBodyPaint,
               (needsPendingScrollPrep || isStudyNarrowPanelActive()) {
                cell.configureForOpenHistory(
                    with: msg,
                    preferredHeight: preferred,
                    layoutWidth: layoutWidth
                )
            }
        }
        return cell
    }

    private func bindImageCache(to cell: MessageCellType, message: ChatMessage) {
        // PDF study screenshots keep JPEG for API/图片转写 but must never paint in the bubble.
        guard message.showsImageInChat, let b64 = message.imageJPEGBase64 else {
            cell.setCachedImage(nil)
            return
        }
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
                guard let live = ConversationStore.shared.currentConversation?.messages
                    .first(where: { $0.id == msgID }),
                      live.showsImageInChat else { return }
                cell.setCachedImage(img)
                if let userCell = cell as? UserMessageCell {
                    userCell.applyCachedImageIfNeeded()
                } else if let assistantCell = cell as? AssistantMessageCell {
                    assistantCell.applyCachedImageIfNeeded()
                }
            }
        }
    }

    /// Ensure frozen map has layout-cache height before UITableView asks for row geometry.
    private func ensureFrozenRowHeightFromCache(for message: ChatMessage,
                                                row: Int,
                                                messageCount: Int,
                                                layoutWidth: CGFloat) {
        guard rowHeights.isScrollHeightFrozen else { return }
        rowHeights.freezeRowHeightIfNeeded(
            for: message,
            row: row,
            messageCount: messageCount,
            layoutWidth: layoutWidth
        )
        guard message.role == .assistant, !message.isStreaming else { return }
        primeFrozenAssistantHeight(
            for: message,
            row: row,
            messageCount: messageCount,
            layoutWidth: layoutWidth
        )
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              indexPath.row < messages.count else {
            return tableView.estimatedRowHeight
        }
        let msg = messages[indexPath.row]
        if msg.shouldHideInTranscript {
            return 0.01
        }
        if msg.isStreaming {
            // iOS 12 `automaticDimension` fills the prior/estimated frame via the
            // cell's bottom pins, then measures that fill as the row height —
            // first-turn blanks with tags scrolled off-screen. Use fitted height.
            if let cell = tableView.cellForRow(at: indexPath) as? AssistantMessageCell,
               cell.messageID == msg.id {
                return cell.fittedStreamingRowHeight()
            }
            return streamingPlaceholderRowHeight(for: msg)
        }
        let layoutWidth = currentRenderWidth()
        let messageCount = messages.count
        if rowHeights.isScrollHeightFrozen {
            rowHeights.freezeRowHeightIfNeeded(
                for: msg,
                row: indexPath.row,
                messageCount: messageCount,
                layoutWidth: layoutWidth
            )
            if msg.role == .assistant, !msg.isStreaming {
                let cell = tableView.cellForRow(at: indexPath) as? AssistantMessageCell
                primeFrozenAssistantHeight(
                    for: msg,
                    row: indexPath.row,
                    messageCount: messageCount,
                    layoutWidth: layoutWidth,
                    cell: cell,
                    messages: messages
                )
            }
        }
        let resolved = scrollAwareRowHeight(for: msg, row: indexPath.row, messageCount: messageCount)
        return rowHeightClampedToVisiblePaint(for: msg, at: indexPath, resolved: resolved)
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              indexPath.row < messages.count else { return 72 }
        let msg = messages[indexPath.row]
        if msg.shouldHideInTranscript { return 0.01 }
        if msg.isStreaming {
            return streamingPlaceholderRowHeight(for: msg)
        }
        return scrollAwareRowHeight(for: msg, row: indexPath.row, messageCount: messages.count)
    }

    /// Compact live-row estimate: collapsed chrome tags + body, never multi-screen.
    private func streamingPlaceholderRowHeight(for msg: ChatMessage) -> CGFloat {
        var h = ChatRowHeightResolver.cellVerticalMargin
        if msg.hasSearchProcess || msg.hasImageTranscription || msg.hasAgentProcess {
            h += 40
        }
        let reasoning = msg.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reasoning.isEmpty {
            h += 40
        }
        let body = msg.content
        if !body.isEmpty {
            let font = UIFont.systemFont(ofSize: SettingsManager.shared.chatBodyFontSize)
            let width = max(currentRenderWidth() - 48, 120)
            let textH = ceil(
                (body as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).height
            )
            h += 10 + min(textH, 2_400)
        } else if reasoning.isEmpty,
                  !msg.hasSearchProcess,
                  !msg.hasImageTranscription,
                  !msg.hasAgentProcess {
            h += max(fontLineHeightPlaceholder(), 22)
        }
        return max(ceil(h), 52)
    }

    private func fontLineHeightPlaceholder() -> CGFloat {
        UIFont.systemFont(ofSize: SettingsManager.shared.chatBodyFontSize).lineHeight
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let scrolling = tableView.isDragging || tableView.isDecelerating || rowHeights.isScrollHeightFrozen
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              indexPath.row < messages.count else { return }
        let msg = messages[indexPath.row]
        guard !msg.isStreaming else { return }
        let layoutWidth = currentRenderWidth()
        if SettingsManager.shared.renderDebugOverlayEnabled,
           let typedCell = cell as? MessageCellType {
            typedCell.refreshRenderDebugOverlay()
        }
        // Open: tail paint is handled in cellForRow / primeOpenBottom — avoid per-row layout storms here.
        if isOpenPresentationActive() {
            return
        }
        if scrolling {
            if let assistantCell = cell as? AssistantMessageCell {
                assistantCell.setNativeScrollRasterization(true)
                assistantCell.pinActionRowBelowColumnForScrollFreeze(true)
            }
            rowHeights.freezeRowHeightIfNeeded(
                for: msg,
                row: indexPath.row,
                messageCount: messages.count,
                layoutWidth: layoutWidth
            )
            if msg.role == .assistant {
                if let assistantCell = cell as? AssistantMessageCell {
                    primeFrozenAssistantHeight(
                        for: msg,
                        row: indexPath.row,
                        messageCount: messages.count,
                        layoutWidth: layoutWidth,
                        cell: assistantCell,
                        messages: messages
                    )
                    let needsBody = !msg.content.isEmpty && !assistantCell.hasVisibleBodyPaint
                    if needsBody {
                        // Warm-cache fill even while readingHistory — blank bodies skip action paint.
                        let canFill = !readingHistory
                            || AssistantMessageLayout.hasCachedNativeLayout(
                                for: msg,
                                layoutWidth: layoutWidth
                            )
                        if canFill {
                            assistantCell.configureForOpenHistory(
                                with: msg,
                                preferredHeight: rowHeights.committedColumnHeight(for: msg.id),
                                layoutWidth: layoutWidth
                            )
                            if assistantCell.hasVisibleBodyPaint {
                                let measured = assistantCell.measuredContentHeight()
                                let frozen = rowHeights.frozenRowHeight(for: msg.id) ?? 0
                                if measured > 40,
                                   measured + ChatRowHeightResolver.cellVerticalMargin > frozen + 12,
                                   rowHeights.growFrozenRowHeightIfNeeded(
                                       messageID: msg.id,
                                       columnHeight: measured
                                   ) {
                                    scheduleFrozenAssistantGeometrySync()
                                }
                            }
                        }
                    }
                    // Prefer icon paint over reserve-only — reserveActionChromeHeightOnly hides buttons.
                    if assistantCell.hasVisibleBodyPaint {
                        assistantCell.showCommittedActionIconsDuringScroll(for: msg)
                        if !assistantCell.hasVisibleActionButtons {
                            assistantCell.revealActionChromeIfBodyPainted(for: msg)
                        }
                    } else {
                        assistantCell.refreshActionChrome(for: msg, streaming: false, colors: DSTheme.c)
                    }
                }
            }
            return
        }
        scheduleUpdateTurnContextBar()
        prewarmForIncomingRow(indexPath.row)
        if msg.role == .user, let userCell = cell as? UserMessageCell {
            userCell.syncUserPresentation(with: msg, layoutWidth: layoutWidth)
            scheduleStableHeightPin(for: userCell, message: msg)
        } else if msg.role == .assistant, let assistantCell = cell as? AssistantMessageCell {
            assistantCell.applyDeferredNativeRenderIfNeeded()
            if assistantCell.needsNativeRepaint(at: layoutWidth) {
                assistantCell.configureForOpenHistory(
                    with: msg,
                    preferredHeight: rowHeights.displayColumnHeight(for: msg.id)
                        ?? rowHeights.committedColumnHeight(for: msg.id),
                    layoutWidth: layoutWidth
                )
            } else if !assistantCell.hasVisibleBodyPaint,
               !msg.content.isEmpty {
                assistantCell.configureForOpenHistory(
                    with: msg,
                    preferredHeight: rowHeights.committedColumnHeight(for: msg.id),
                    layoutWidth: layoutWidth
                )
            }
            assistantCell.ensureActionButtonsVisible(for: msg)
            assistantCell.ensureNativeLayoutWidth(layoutWidth)
            if !tableView.isDragging, !tableView.isDecelerating {
                _ = syncRowHeightToPaint(cell: assistantCell, message: msg)
            }
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
        scrollFreezeGeometryWork?.cancel()
        scrollFreezeGeometryWork = nil
        scrollBeginPrepWork?.cancel()
        scrollBeginPrepWork = nil
        studyFrozenShrinkRemeasureWork?.cancel()
        studyFrozenShrinkRemeasureWork = nil
        nativeHydrationScrollWork?.cancel()
        nativeHydrationScrollWork = nil
        scrollGestureGeometryFinished = false
        formulaRemeasureWork?.cancel()
        formulaRemeasureWork = nil
        pendingReadingHistoryFormulaSync = false
        visibleNativeHydrationInProgress = false
        deferredRenderWork?.cancel()
        deferredRenderWork = nil
        pinnedRemeasureWork?.cancel()
        pinnedJumpUserRow = nil
        stickToBottom = false
        readingHistory = true
        viewportPinnedByUser = true
        viewportScrollAnchor = captureViewportScrollAnchor()
        gestureLockedScrollAnchorRow = liveScrollViewportAnchor()?.path.row
        gestureStartContentOffsetY = scrollView.contentOffset.y
        gestureMinContentOffsetY = scrollView.contentOffset.y
        gestureMaxContentOffsetY = scrollView.contentOffset.y
        pendingScrollSettleAnchor = nil
        heightWork?.cancel()

        // Press→start: freeze to live table geometry only. Never rewrite heights mid-drag
        // (that freezes the UI then teleports when the main thread catches up).
        #if DEBUG
        ChatHeavyScrollDiagnostics.resetGesture()
        #endif
        NativeMessageRenderView.suppressSyncRasterize = true

        if let messages = ConversationStore.shared.currentConversation?.messages, !messages.isEmpty {
            let layoutWidth = currentRenderWidth()
            let shouldStudyPrep = pendingStudyFirstScrollPrep
            let shouldLightPrep = needsFirstHistoryScrollPrep && !shouldStudyPrep
            pendingStudyFirstScrollPrep = false
            needsFirstHistoryScrollPrep = false
            if shouldStudyPrep || shouldLightPrep {
                pendingFingerDownHeavyPrep = (study: shouldStudyPrep, light: shouldLightPrep)
            } else {
                pendingFingerDownHeavyPrep = nil
            }

            let visibleRows = Set((tableView.indexPathsForVisibleRows ?? []).map(\.row))
            let visibleMin = tableView.indexPathsForVisibleRows?.map(\.row).min()
                ?? max(0, messages.count - 1)
            let visibleMax = tableView.indexPathsForVisibleRows?.map(\.row).max() ?? visibleMin
            let syncPad = 2
            let syncFloor = max(0, visibleMin - syncPad)
            let syncCeil = min(messages.count, visibleMax + syncPad + 1)
            var syncFreezeRows = visibleRows
            if syncFloor < syncCeil {
                syncFreezeRows.formUnion(syncFloor..<syncCeil)
            }
            let syncRows = syncFreezeRows.filter { $0 >= 0 && $0 < messages.count }.sorted()

            beginScrollHeightFreezeMatchingTable(
                messages: messages,
                rows: syncRows,
                layoutWidth: layoutWidth
            )
            lastHistoryEdgePinVisibleRows = visibleRows

            let prepWork = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.rowHeights.isScrollHeightFrozen else { return }
                self.scrollBeginPrepWork = nil

                // While dragging: additive freeze + async prewarm only.
                // No map replace, shrink, sync layout, or measured chrome pin.
                let liveVisible = Set((self.tableView.indexPathsForVisibleRows ?? []).map(\.row))
                let liveMin = self.tableView.indexPathsForVisibleRows?.map(\.row).min()
                    ?? max(0, messages.count - 1)
                let liveMax = self.tableView.indexPathsForVisibleRows?.map(\.row).max() ?? liveMin
                let prioritized = self.scrollLookaheadRowsPrioritized(in: messages)
                var expandRows = Set(prioritized + liveVisible)
                let bandPad = Self.turnPrewarmCount * 2 + 4
                let bandFloor = max(0, liveMin - bandPad)
                let bandCeil = min(messages.count, liveMax + bandPad + 1)
                if bandFloor < bandCeil {
                    expandRows.formUnion(bandFloor..<bandCeil)
                }
                let lookahead = expandRows.filter { $0 >= 0 && $0 < messages.count }.sorted()
                self.expandFrozenScrollRowsIfNeeded(
                    messages: messages,
                    rows: lookahead,
                    layoutWidth: layoutWidth
                )
                self.scheduleAsyncLayoutPrewarm(
                    assistants: self.assistantMessagesAhead(in: messages, rows: lookahead),
                    layoutWidth: layoutWidth
                )

                if !self.tableView.isDragging {
                    self.runPendingFingerDownHeavyPrepIfNeeded()
                    self.pinVisibleFrozenRowsForScrollFreeze(messages: messages)
                    self.lastHistoryEdgePinVisibleRows = liveVisible
                    self.refreshHistoryEdgePinnedRows()
                }
            }
            scrollBeginPrepWork = prepWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: prepWork)
        }
    }

    private func assistantMessagesAhead(in messages: [ChatMessage], rows: [Int]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var seen = Set<String>()
        for row in rows {
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
            for msg in candidates where seen.insert(msg.id).inserted {
                guard !AssistantMessageLayout.hasCachedNativeLayout(
                    for: msg,
                    layoutWidth: currentRenderWidth()
                ) else { continue }
                result.append(msg)
            }
        }
        return result
    }

    /// Pin visible uncommitted rows before the first drag. Avoid beginUpdates unless a visible row changes.
    private func quickCommitVisibleHeights(messages: [ChatMessage], allowTableUpdates: Bool = true) {
        let paths = tableView.indexPathsForVisibleRows ?? []
        guard !paths.isEmpty else { return }
        var visibleHeightChanged = false
        for path in paths {
            guard path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard !msg.isStreaming,
                  let cell = tableView.cellForRow(at: path) as? MessageCellType else { continue }
            let measured = cell.measuredContentHeight()
            guard measured > 40 else { continue }
            let prior = resolvedRowHeight(for: msg, row: path.row, messageCount: messages.count)
            let known = rowHeights.bestKnownColumnHeight(for: msg.id)
            if rowHeights.isCommitted(msg.id) {
                guard measured > known + 2 else { continue }
                rowHeights.commitMeasured(columnHeight: measured, messageID: msg.id, allowShrink: false)
            } else {
                rowHeights.commitMeasured(columnHeight: measured, messageID: msg.id, allowShrink: true)
            }
            let next = resolvedRowHeight(for: msg, row: path.row, messageCount: messages.count)
            if abs(prior - next) > 3 {
                visibleHeightChanged = true
            }
        }
        guard visibleHeightChanged, allowTableUpdates else { return }
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
        if rowHeights.isScrollHeightFrozen {
            gestureMinContentOffsetY = min(gestureMinContentOffsetY, y)
            gestureMaxContentOffsetY = max(gestureMaxContentOffsetY, y)
            let visible = Set((tableView.indexPathsForVisibleRows ?? []).map(\.row))
            if visible != lastHistoryEdgePinVisibleRows {
                lastHistoryEdgePinVisibleRows = visible
                refreshHistoryEdgePinnedRows()
                if let messages = ConversationStore.shared.currentConversation?.messages {
                    revealDeferredActionChromeOnVisibleAssistants(messages: messages)
                }
            }
        }
        refreshLiveHistoryScrollAnchor()
        guard rowHeights.isScrollHeightFrozen else { return }
        // Geometry sync is scheduled from willDisplay when a row actually needs grow.
        // Hydrate at most once per ~2 runloop turns while dragging.
        maybeHydrateDeferredNativeWhileScrolling()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if decelerate { return }
        let historyFrozenSettle = rowHeights.isScrollHeightFrozen
            && (readingHistory || gestureLockedScrollAnchorRow != nil)
        if historyFrozenSettle {
            captureReleaseScrollSettleAnchor()
        }
        finishScrollGestureRowGeometry()
        if historyFrozenSettle {
            scrollSettleWork?.cancel()
            performScrollHeightSettling()
        } else {
            updateScrollModeAtRest()
            scheduleScrollHeightSettling()
        }
        if historyFrozenSettle {
            updateScrollModeAtRest()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let historyFrozenSettle = rowHeights.isScrollHeightFrozen
            && (readingHistory || gestureLockedScrollAnchorRow != nil)
        if historyFrozenSettle {
            captureReleaseScrollSettleAnchor()
        }
        finishScrollGestureRowGeometry()
        if historyFrozenSettle {
            scrollSettleWork?.cancel()
            performScrollHeightSettling()
            updateScrollModeAtRest()
        } else {
            updateScrollModeAtRest()
            scheduleScrollHeightSettling()
        }
    }

    /// Finger-up / deceleration-end: paint chrome only — row relayout runs in async settle (avoids release-frame jump).
    private func finishScrollGestureRowGeometry() {
        guard !scrollGestureGeometryFinished else { return }
        scrollGestureGeometryFinished = true
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        // Allow pending bitmaps to paint once the finger lifts (before async settle).
        NativeMessageRenderView.suppressSyncRasterize = false
        // Heavy first-scroll prep off the release frame — was causing press→teleport mid-drag.
        if pendingFingerDownHeavyPrep != nil {
            DispatchQueue.main.async { [weak self] in
                self?.runPendingFingerDownHeavyPrepIfNeeded()
            }
        }
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            if cell.hasPendingDeferredNativeRender {
                cell.applyDeferredNativeRenderIfNeeded(suppressHeightNotify: true)
            } else {
                cell.flushDeferredNativeRasterizeIfNeeded()
            }
        }
        if readingHistory {
            for case let cell as AssistantMessageCell in tableView.visibleCells {
                guard let msg = messages.first(where: { $0.id == cell.messageID }),
                      msg.role == .assistant, !msg.isStreaming else { continue }
                cell.showCommittedActionIconsDuringScroll(for: msg)
            }
            return
        }
        let layoutWidth = currentRenderWidth()
        var changed = false
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard msg.role == .assistant, !msg.isStreaming else { continue }
            cell.contentView.layoutIfNeeded()
            let columnH = max(
                cell.measuredContentHeight(),
                cell.projectedColumnHeight(for: msg, layoutWidth: layoutWidth)
            )
            guard columnH > 40 else { continue }
            if rowHeights.growFrozenRowHeightIfNeeded(messageID: msg.id, columnHeight: columnH) {
                changed = true
            }
            if syncRowHeightToPaint(cell: cell, message: msg, allowShrink: false) {
                changed = true
            }
        }
        guard rowHeights.isScrollHeightFrozen else { return }
        if changed {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
                tableView.layoutIfNeeded()
            }
        }
        if let stored = pendingScrollSettleAnchor {
            remeasureRowsPreservingViewport(
                anchorPath: stored.path,
                preferSavedViewportAnchor: true,
                fixedViewportY: stored.viewportY
            )
            revealDeferredActionChromeOnVisibleAssistants(messages: messages)
        }
    }

    private func scheduleScrollHeightSettling() {
        scrollSettleWork?.cancel()
        scrollFreezeGeometryWork?.cancel()
        scrollFreezeGeometryWork = nil
        let work = DispatchWorkItem { [weak self] in
            self?.performScrollHeightSettling()
        }
        scrollSettleWork = work
        DispatchQueue.main.async(execute: work)
    }

    /// Clear mid-scroll rasterize suppression and paint any deferred/skipped bitmaps.
    private func endScrollGesturePaintSuppression() {
        NativeMessageRenderView.suppressSyncRasterize = false
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            if cell.hasPendingDeferredNativeRender {
                cell.applyDeferredNativeRenderIfNeeded(suppressHeightNotify: true)
            } else {
                cell.flushDeferredNativeRasterizeIfNeeded()
            }
        }
        #if DEBUG
        ChatHeavyScrollDiagnostics.logGestureSummary("settle")
        #endif
    }

    private func viewportYForAnchorRow(_ row: Int) -> CGFloat? {
        let path = IndexPath(row: row, section: 0)
        guard row >= 0, row < tableView.numberOfRows(inSection: 0) else { return nil }
        if let cell = tableView.cellForRow(at: path) {
            return cell.convert(cell.bounds, to: tableView).minY - tableView.contentOffset.y
        }
        return tableView.rectForRow(at: path).minY - tableView.contentOffset.y
    }

    /// Bubble/user row straddling the top edge — post-release jump hotspot.
    private func isHistoryBubbleEdgeRelease() -> Bool {
        let edge = debugVisibleQAEdgeState(edgeBand: 56)
        return !edge.assistantRowsNearUserEdge.isEmpty || !edge.userRowsAtTopEdge.isEmpty
    }

    private func isHistoryOscillationSettle() -> Bool {
        let range = gestureMaxContentOffsetY - gestureMinContentOffsetY
        guard range > 44 else { return false }
        let net = abs(tableView.contentOffset.y - gestureStartContentOffsetY)
        return net < range * 0.55
    }

    private func remeasureLockedHistoryViewportAtSettle() {
        tableView.layoutIfNeeded()
        if let row = gestureLockedScrollAnchorRow,
           row >= 0, row < tableView.numberOfRows(inSection: 0) {
            let path = IndexPath(row: row, section: 0)
            let y = tableView.rectForRow(at: path).minY - tableView.contentOffset.y
            remeasureRowsPreservingViewport(
                anchorPath: path,
                preferSavedViewportAnchor: false,
                fixedViewportY: y
            )
            return
        }
        remeasureRowsPreservingLiveViewport()
    }

    /// One layout pass while still frozen, then unfreeze — never remeasure after endScrollHeightFreeze.
    private func finalizeFrozenHistoryScrollSettle() {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              !messages.isEmpty,
              rowHeights.isScrollHeightFrozen else { return }
        refreshHistoryEdgePinnedRows()
        let firstGesture = !hasCompletedFirstHistoryScrollGesture
        let nearEdge = isHistoryBubbleEdgeRelease()
        let oscillation = isHistoryOscillationSettle()
        let studyLightSettle = usesStudyHeightBucketPolicy()
        let lightSettle = firstGesture || nearEdge || oscillation || studyLightSettle
        let slackThreshold: CGFloat = lightSettle ? 64 : 32
        var mapChanged = false
        if lightSettle {
            rowHeights.discardDeferredFrozenRowGrows()
            // Study: one settle-time shrink with viewport lock (never mid-fling).
            if studyLightSettle {
                for case let cell as AssistantMessageCell in tableView.visibleCells {
                    guard let path = tableView.indexPath(for: cell),
                          path.row < messages.count else { continue }
                    let msg = messages[path.row]
                    guard msg.role == .assistant, !msg.isStreaming, cell.hasVisibleBodyPaint else { continue }
                    let columnH = frozenScrollColumnHeight(for: cell, message: msg, layoutWidth: currentRenderWidth())
                    guard columnH > 40 else { continue }
                    let rowH = tableView.rectForRow(at: path).height
                    var slack = rowH - (columnH + ChatRowHeightResolver.cellVerticalMargin)
                    if cell.hasReservedActionChromeSpace, !cell.hasVisibleActionButtons {
                        slack -= Self.actionChromeHeightSlack
                    }
                    if slack > 28,
                       rowHeights.shrinkFrozenRowHeightIfNeeded(messageID: msg.id, columnHeight: columnH) {
                        mapChanged = true
                    }
                }
            }
        } else {
            mapChanged = rowHeights.beginFrozenHistorySettle(
                minDeferredSlack: slackThreshold,
                skipPinnedDeferred: true
            )
            for case let cell as AssistantMessageCell in tableView.visibleCells {
                guard let path = tableView.indexPath(for: cell),
                      path.row < messages.count else { continue }
                let msg = messages[path.row]
                guard msg.role == .assistant, !msg.isStreaming else { continue }
                if rowHeights.isGesturePinnedFrozenMessage(msg.id) { continue }
                cell.contentView.layoutIfNeeded()
                let measured = cell.measuredContentHeight()
                guard measured > 40 else { continue }
                let frozen = rowHeights.frozenRowHeight(for: msg.id) ?? 0
                let frameH = tableView.rectForRow(at: path).height
                guard measured + ChatRowHeightResolver.cellVerticalMargin > frozen + slackThreshold,
                      measured + ChatRowHeightResolver.cellVerticalMargin > frameH + slackThreshold else { continue }
                if rowHeights.growFrozenRowHeightIfNeeded(messageID: msg.id, columnHeight: measured) {
                    mapChanged = true
                }
            }
        }
        pinAllVisibleFrozenRowsAtHistorySettle(messages: messages)
        if mapChanged {
            if let edge = historyEdgeSettleAnchor() {
                gestureLockedScrollAnchorRow = edge.row
            }
            remeasureLockedHistoryViewportAtSettle()
        }
        suppressPostHistorySettleRemeasure = true
        pendingScrollSettleAnchor = nil
        gestureLockedScrollAnchorRow = nil
        let deferFormulaSync = lightSettle
        if !deferFormulaSync {
            pendingReadingHistoryFormulaSync = false
        }
        rowHeights.commitFrozenHeightsBeforeUnfreeze()
        endScrollGesturePaintSuppression()
        rowHeights.endScrollHeightFreeze()
        rowHeights.publishCommittedToDisplay()
        setVisibleNativeScrollRasterization(false)
        paintVisibleActionChromeAfterScrollUnfreeze(messages: messages)
        repairVisibleAssistantRowClips(messages: messages)
        var heightChanged = shrinkPaintedActionRowsAtRest(messages: messages)
        if debugVisibleRowClipCount() > 0 {
            repairVisibleAssistantRowClips(messages: messages)
            heightChanged = true
        }
        if heightChanged {
            remeasureRowsPreservingViewport(preferSavedViewportAnchor: true)
        }
        repairTopViewportMidLineClip()
        hasCompletedFirstHistoryScrollGesture = true
        if hasVisiblePendingDeferredNative() {
            scheduleVisibleDeferredNativeHydration()
        }
        let settleSuppressDelay: TimeInterval = deferFormulaSync ? 0.38 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSuppressDelay) { [weak self] in
            guard let self else { return }
            self.suppressPostHistorySettleRemeasure = false
            guard deferFormulaSync,
                  self.pendingReadingHistoryFormulaSync,
                  let messages = ConversationStore.shared.currentConversation?.messages else { return }
            self.pendingReadingHistoryFormulaSync = false
            self.flushReadingHistoryFormulaSync(messages: messages)
        }
    }

    private func performScrollHeightSettling() {
        contextBarScrollWork?.cancel()
        if pendingPostWidthChangeSettle,
           let messages = ConversationStore.shared.currentConversation?.messages {
            pendingPostWidthChangeSettle = false
            revealVisibleActionChrome(messages: messages)
            repairVisibleAssistantRowClips(messages: messages)
        }
        updateTurnContextBar()
        tableView.layoutIfNeeded()
        let wasFrozen = rowHeights.isScrollHeightFrozen
        if wasFrozen, readingHistory || gestureLockedScrollAnchorRow != nil {
            finalizeFrozenHistoryScrollSettle()
            if let pinned = pinnedJumpUserRow {
                applyUserQuestionPinnedToTop(at: pinned, animated: false)
                let path = IndexPath(row: pinned, section: 0)
                viewportScrollAnchor = (pinned, tableView.rectForRow(at: path).minY - tableView.contentOffset.y)
            }
            return
        }
        if wasFrozen {
            presettleVisibleAssistantRows()
        }
        if wasFrozen {
            rowHeights.commitFrozenHeightsBeforeUnfreeze()
        }
        endScrollGesturePaintSuppression()
        rowHeights.endScrollHeightFreeze()
        rowHeights.publishCommittedToDisplay()
        setVisibleNativeScrollRasterization(false)
        if let messages = ConversationStore.shared.currentConversation?.messages,
           !messages.isEmpty {
            paintVisibleActionChromeAfterScrollUnfreeze(messages: messages)
        }
        if let messages = ConversationStore.shared.currentConversation?.messages,
           !messages.isEmpty,
           !readingHistory {
            finalizeScrollSettleLayout(
                messages: messages,
                anchorPath: viewportScrollAnchorPath(),
                fixedViewportY: nil
            )
        }
        if let pinned = pinnedJumpUserRow {
            applyUserQuestionPinnedToTop(at: pinned, animated: false)
            let path = IndexPath(row: pinned, section: 0)
            viewportScrollAnchor = (pinned, tableView.rectForRow(at: path).minY - tableView.contentOffset.y)
        } else if !readingHistory {
            viewportScrollAnchor = captureViewportScrollAnchor()
        }
        if wasFrozen, !readingHistory {
            remeasureRowsPreservingLiveViewport()
        } else if wasFrozen, readingHistory {
            return
        }
        let visible = tableView.indexPathsForVisibleRows ?? []
        if !visible.isEmpty, !tableView.isDragging, !tableView.isDecelerating, !readingHistory {
            applyLookaheadTurnPrewarm()
        }
        if readingHistory {
            scheduleVisibleDeferredNativeHydration()
            return
        }
        scheduleVisibleDeferredNativeHydration()
        if !readingHistory {
            for case let cell as AssistantMessageCell in tableView.visibleCells {
                cell.applyDeferredHeightIfNeeded()
            }
        }
        if !readingHistory, !pendingHeights.isEmpty {
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
    }
}

extension ChatViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let scrolling = tableView.isDragging || tableView.isDecelerating
        if scrolling {
            applyTurnWindowPrewarm(
                around: indexPaths.map(\.row),
                allowSync: needsPendingScrollPrep && isStudyNarrowPanelActive()
            )
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
    func messageCellStudyContentLeadingGutter() -> CGFloat {
        isStudyNarrowPanelActive() ? Self.studyPanelLeadingGutter : 0
    }

    func messageCellShouldFreezeHeight(_ cell: MessageCellType) -> Bool {
        // Opening / switching must never take the scroll plain path — causes red flash.
        if pendingOpenAtBottom || suppressHeightRemeasure { return false }
        return rowHeights.isScrollHeightFrozen
            || tableView.isDragging
            || tableView.isDecelerating
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
        guard tableView.isDragging || tableView.isDecelerating || rowHeights.isScrollHeightFrozen else {
            return false
        }
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              let msg = messages.first(where: { $0.id == cell.messageID }),
              msg.role == .assistant,
              !msg.isStreaming else {
            return false
        }
        let layoutWidth = currentRenderWidth()
        if isStudyNarrowPanelActive(),
           AssistantMessageLayout.hasCachedNativeLayout(for: msg, layoutWidth: layoutWidth) {
            return false
        }
        // Scroll path: native only when layout cache is warm. Never sync-layout mid-gesture.
        return !AssistantMessageLayout.hasCachedNativeLayout(
            for: msg,
            layoutWidth: layoutWidth
        )
    }

    func messageCellShouldTruncatePlainBody(_ cell: MessageCellType) -> Bool {
        tableView.isDragging
    }

    func messageCellDidPaintContent(_ cell: MessageCellType) {
        guard rowHeights.isScrollHeightFrozen,
              let assistant = cell as? AssistantMessageCell,
              let messages = ConversationStore.shared.currentConversation?.messages,
              let msg = messages.first(where: { $0.id == assistant.messageID }),
              msg.role == .assistant, !msg.isStreaming else { return }
        let allowShrink = isOpenPresentationActive()
        if readingHistory {
            assistant.showCommittedActionIconsDuringScroll(for: msg)
            _ = assistant.revealReservedActionChromeIfRoom(for: msg)
            return
        }
        guard syncRowHeightToPaint(cell: assistant, message: msg, allowShrink: allowShrink) else { return }
        if pendingOpenAtBottom || suppressHeightRemeasure { return }
        if rowHeights.isScrollHeightFrozen { return }
        if openBottomStickActive,
           stickToBottom, !isViewportPinned(),
           isTailAssistantMessage(assistant.messageID),
           let messages = ConversationStore.shared.currentConversation?.messages,
           tailActionChromeOverlapsInputBar(messages: messages) {
            scheduleOpenBottomPin(messages: messages)
            return
        }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }

    func messageCellShouldPreserveOpenPaint(_ cell: MessageCellType) -> Bool {
        isOpenPresentationActive()
    }

    func messageCellShouldLayoutActionChromeNow(_ cell: MessageCellType) -> Bool {
        if rowHeights.isScrollHeightFrozen { return false }
        if readingHistory { return false }
        if pendingOpenAtBottom || suppressHeightRemeasure { return true }
        if tableView.isDragging { return false }
        if tableView.isDecelerating { return false }
        return true
    }

    func messageCellRowHasRoomForActionChrome(_ cell: MessageCellType) -> Bool {
        guard let path = tableView.indexPath(for: cell) else { return true }
        let rowFrame = tableView.rectForRow(at: path)
        cell.contentView.layoutIfNeeded()
        let required = cell.measuredContentHeight() + ChatRowHeightResolver.cellVerticalMargin
        return required <= rowFrame.height + 2.5
    }

    func messageCellShouldDeferActionChromeUntilBodyPaint(_ cell: MessageCellType) -> Bool {
        guard let assistant = cell as? AssistantMessageCell,
              let messages = ConversationStore.shared.currentConversation?.messages,
              let msg = messages.first(where: { $0.id == assistant.messageID }),
              msg.role == .assistant,
              !msg.isStreaming else { return false }
        let scrolling = rowHeights.isScrollHeightFrozen
            || tableView.isDragging
            || tableView.isDecelerating
        guard scrolling else { return false }
        return !rowHeights.isCommitted(msg.id) && !assistant.hasVisibleBodyPaint
    }

    private func clearFirstHistoryScrollPrepIfNeeded() {
        needsFirstHistoryScrollPrep = false
        pendingStudyFirstScrollPrep = false
        isPerformingColdLaunchOpen = false
    }

    private func scheduleFormulaHeightSyncWhileReading() {
        guard readingHistory else { return }
        if tableView.isDragging || tableView.isDecelerating || rowHeights.isScrollHeightFrozen
            || visibleNativeHydrationInProgress {
            pendingReadingHistoryFormulaSync = true
            return
        }
        formulaRemeasureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.formulaRemeasureWork = nil
            guard self.readingHistory else { return }
            if self.tableView.isDragging || self.tableView.isDecelerating || self.rowHeights.isScrollHeightFrozen {
                self.pendingReadingHistoryFormulaSync = true
                return
            }
            guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
            self.flushReadingHistoryFormulaSync(messages: messages)
        }
        formulaRemeasureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func flushReadingHistoryFormulaSync(messages: [ChatMessage]) {
        pendingReadingHistoryFormulaSync = false
        let layoutWidth = currentRenderWidth()
        let stored = pendingScrollSettleAnchor
        pendingScrollSettleAnchor = nil
        let anchorPath = stored?.path
            ?? (gestureLockedScrollAnchorRow.map { IndexPath(row: $0, section: 0) })
            ?? viewportScrollAnchorPath()
        let viewportY: CGFloat? = stored?.viewportY ?? anchorPath.map { path in
            tableView.layoutIfNeeded()
            return tableView.rectForRow(at: path).minY - tableView.contentOffset.y
        }
        UIView.performWithoutAnimation {
            paintVisibleBlankAssistantsIfNeeded(messages: messages, layoutWidth: layoutWidth)
            repairVisibleAssistantRowClips(messages: messages)
            var changed = shrinkInflatedVisibleRows(messages: messages)
            if syncVisibleRowHeightsToPaint(messages: messages, allowShrink: true, allowTableUpdates: false) {
                changed = true
            }
            if !suppressPostHistorySettleRemeasure,
               (changed || debugVisibleRowClipCount() > 0) {
                remeasureRowsPreservingViewport(
                    anchorPath: anchorPath,
                    preferSavedViewportAnchor: viewportY != nil,
                    fixedViewportY: viewportY
                )
            }
        }
        if let cid = renderedConversationID {
            storePersistedHeights(rowHeights.exportPersistable(), for: cid)
        }
        revealDeferredActionChromeOnVisibleAssistants(messages: messages)
        clearFirstHistoryScrollPrepIfNeeded()
    }

    private func commitReadingHistoryRowGrowth(for message: ChatMessage,
                                               row: Int,
                                               columnHeight: CGFloat) {
        rowHeights.commitMeasured(columnHeight: columnHeight, messageID: message.id, allowShrink: false)
        let scrolling = tableView.isDragging || tableView.isDecelerating || rowHeights.isScrollHeightFrozen
        if rowHeights.isScrollHeightFrozen {
            let visible = tableView.indexPathsForVisibleRows?.contains { path in
                path.row == row
            } ?? false
            if visible {
                rowHeights.pinFrozenRowHeight(messageID: message.id, columnHeight: columnHeight)
                rowHeights.addGesturePinnedFrozenMessages([message.id])
                pendingReadingHistoryFormulaSync = true
                return
            }
        }
        _ = rowHeights.growFrozenRowHeightIfNeeded(messageID: message.id, columnHeight: columnHeight)
        if scrolling || visibleNativeHydrationInProgress {
            pendingReadingHistoryFormulaSync = true
        } else {
            scheduleFormulaHeightSyncWhileReading()
        }
    }

    func messageCell(_ cell: MessageCellType, didUpdateHeight height: CGFloat, for messageID: String) {
        if readingHistory {
            if height > 40 {
                rowHeights.recordDiskEstimate(columnHeight: height, messageID: messageID)
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
        if readingHistory {
            guard height > 40 else { return }
            let prior = rowHeights.bestKnownColumnHeight(for: messageID)
            let growthThreshold: CGFloat = rowHeights.isCommitted(messageID) ? 8 : 2
            guard height > prior + growthThreshold else {
                rowHeights.recordDiskEstimate(columnHeight: height, messageID: messageID)
                return
            }
            commitReadingHistoryRowGrowth(for: message, row: row, columnHeight: height)
            if scrolling {
                pendingHeights[messageID] = max(pendingHeights[messageID] ?? 0, height)
            }
            return
        }
        if scrolling {
            if height > 40 {
                pendingHeights[messageID] = max(pendingHeights[messageID] ?? 0, height)
            }
            return
        }
        let cached = rowHeights.bestKnownColumnHeight(for: messageID)
        if cell.hasPendingDeferredNativeRender, height + 8 < cached {
            return
        }
        let priorRow = resolvedRowHeight(for: message, row: row, messageCount: messages.count)
        let allowShrink = shouldClampCommittedHeightToPaint(for: message)
        rowHeights.commitMeasured(columnHeight: height, messageID: messageID, allowShrink: allowShrink)
        if let cid = renderedConversationID {
            storePersistedHeights(rowHeights.exportPersistable(), for: cid)
            scheduleHeightCacheSave()
        }
        guard cell.window != nil else { return }
        let path = IndexPath(row: row, section: 0)
        let targetRowHeight = resolvedRowHeight(for: message, row: row, messageCount: messages.count)
        let rowNeedsGrow = targetRowHeight > priorRow + 2
            || tableView.rectForRow(at: path).height + 2 < targetRowHeight
        // During open finalize: record height only — host batches table updates before reveal.
        if suppressHeightRemeasure {
            return
        }
        // During open stick: grow rows and re-pin only when chrome still overlaps the input bar.
        if openBottomStickActive {
            guard rowNeedsGrow, tailActionChromeOverlapsInputBar(messages: messages) else { return }
            scheduleOpenBottomPin(messages: messages)
            return
        }
        guard abs(priorRow - targetRowHeight) > 4
            || abs(tableView.rectForRow(at: path).height - targetRowHeight) > 4 else { return }
        // Stick-to-bottom finished reply: apply growth immediately.
        // (hasVariableChrome used to divert into schedulePinnedRemeasure, which
        // no-ops unless the viewport is pinned — thinking replies stayed clipped.)
        if (stickToBottom && !isViewportPinned()) || finishViewportLocked {
            pinToFinishedTurnBottom()
            return
        }
        if isViewportPinned() {
            schedulePinnedRemeasure()
            return
        }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            if stickToBottom {
                pinToFinishedTurnBottom()
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
                let msg = ConversationStore.shared.currentConversation?.messages
                    .first(where: { $0.id == id })
                let streaming = msg?.isStreaming == true
                let allowShrink = !streaming && (msg.map { shouldClampCommittedHeightToPaint(for: $0) } ?? stickToBottom)
                rowHeights.commitMeasured(
                    columnHeight: height,
                    messageID: id,
                    allowShrink: allowShrink
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
        ConnectsToast.show("已复制", in: view)
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
    func inputBarDidToggleStudyCapture(_ enabled: Bool) {
        guard let id = currentConversationID else { return }
        let model = ConversationStore.shared.conversation(id: id)?.model
        let kind = ConversationStore.shared.conversation(id: id).flatMap { conv in
            conv.studyDocumentID.flatMap { StudyDocumentStore.shared.document(id: $0)?.kind }
        }
        if enabled, model?.supportsVision == false, kind == .pdf || kind == .ebook {
            ConversationStore.shared.updateConversation(id: id) { draft in
                draft.studyPageCaptureEnabled = false
            }
            inputBar.studyPageCaptureEnabled = false
            notifyUnsupportedImageSend()
            return
        }
        ConversationStore.shared.updateConversation(id: id) { draft in
            draft.studyPageCaptureEnabled = enabled
        }
        inputBar.studyPageCaptureEnabled = enabled
        if enabled {
            let tip: String
            switch kind {
            case .text?: tip = "发送时将附带代码全文上下文（无截图）"
            case .markdown?: tip = "发送时将附带当前 Markdown 上下文"
            case .pdf?: tip = "发送时将附带当前页截图（不抽取 PDF 文本）"
            case .ebook?: tip = "发送时将附带当前页截图"
            default: tip = "发送时将附带当前阅读上下文"
            }
            ConnectsToast.show(tip, in: view, duration: 1.6)
        }
    }

    func inputBarDidToggleCodeAIEdit(_ enabled: Bool) {
        if enabled {
            ConnectsToast.show("已授权可改代码（与深度思考无关；重跑也会带上权限）", in: view, duration: 1.8)
        }
    }

    func inputBarDidTapDiffUndoAll() {
        if !WorkspaceEditSession.shared.isEmpty {
            studyContextProvider?.studyCodeDiffUndoAll()
            WorkspaceEditSession.shared.clear()
            refreshWorkspaceDiffBanner()
            return
        }
        studyContextProvider?.studyCodeDiffUndoAll()
    }

    func inputBarDidTapDiffKeepAll() {
        studyContextProvider?.studyCodeDiffKeepAll()
        // Session may still hold other files; refresh after keep.
        DispatchQueue.main.async { [weak self] in
            self?.refreshWorkspaceDiffBanner()
        }
    }

    func inputBarDidTapDiffReview() {
        studyContextProvider?.studyCodeDiffReviewNext()
    }

    func inputBarDidSelectDiffFile(documentID: String) {
        studyContextProvider?.studyCodeDiffOpen(documentID: documentID)
    }

    func inputBarDidChangeStudyAgentMode(_ mode: StudyAgentMode) {
        guard let id = currentConversationID else { return }
        let coerced = StudyAgentMode.coerceForProduct(mode)
        ConversationStore.shared.updateConversation(id: id) { draft in
            draft.studyAgentMode = coerced
        }
        guard StudyAgentMode.isAgentProductEnabled else { return }
        let tip: String
        switch coerced {
        case .agent: tip = "Agent：可探索并提案编辑"
        case .plan: tip = "Plan：只读 + 计划清单"
        case .ask: tip = "Ask：只读 + 可提问澄清"
        }
        ConnectsToast.show(tip, in: view, duration: 1.4)
    }

    /// Slim Keep strip inside the composer while a Study Diff session is active.
    func setCodeDiffReviewBanner(visible: Bool, changeCount: Int) {
        guard isViewLoaded else { return }
        if visible, !WorkspaceEditSession.shared.isEmpty {
            refreshWorkspaceDiffBanner()
            return
        }
        inputBar.setDiffReviewBanner(visible: visible, changeCount: changeCount)
        if visible {
            view.bringSubviewToFront(inputBar)
        }
    }

    func refreshWorkspaceDiffBanner() {
        guard isViewLoaded else { return }
        let session = WorkspaceEditSession.shared
        if !session.isEmpty {
            let files = session.files.map {
                (documentID: $0.documentID, fileName: $0.fileName, additions: $0.additions, deletions: $0.deletions)
            }
            inputBar.setDiffReviewBanner(visible: true, files: files, multifile: true)
            view.bringSubviewToFront(inputBar)
            // Ensure banner isn't zero-height under Build todo strip.
            view.setNeedsLayout()
            return
        }
        inputBar.setDiffReviewBanner(visible: false, files: [], multifile: false)
    }

    func inputBarDidTapAIOptions() {
        prepareForStudyPanelControlTap()
        let keepKeyboard = inputBar.isComposerFirstResponder
        presentModelPicker(anchor: inputBar.aiOptionsAnchorView)
        if keepKeyboard {
            // Modal-less overlay + re-focus so layout/keyboard don't jump under the menu.
            DispatchQueue.main.async { [weak self] in
                self?.inputBar.focusComposer()
            }
        }
    }

    func inputBarDidRequestStudyContextScope(from sourceView: UIView) {
        guard let id = currentConversationID else { return }
        let current = StudyFileContextStore.shared.scope(for: id)
        func mark(_ scope: StudyContextScope, title: String) -> String {
            current == scope ? "✓ \(title)" : title
        }
        ConnectsMenu.present(
            from: self,
            title: "文档上下文范围",
            items: [
                ConnectsMenuItem(title: mark(.auto, title: "智能（默认）"), icon: .book) { [weak self] in
                    guard let self = self else { return }
                    StudyFileContextStore.shared.setScope(.auto, for: id)
                    ConnectsToast.show("上下文：智能", in: self.view, duration: 1.2)
                },
                ConnectsMenuItem(title: mark(.fullFile, title: "全文 / 文件"), icon: .book) { [weak self] in
                    guard let self = self else { return }
                    StudyFileContextStore.shared.setScope(.fullFile, for: id)
                    ConnectsToast.show("上下文：全文", in: self.view, duration: 1.2)
                },
                ConnectsMenuItem(title: mark(.selection, title: "选区"), icon: .edit) { [weak self] in
                    guard let self = self else { return }
                    StudyFileContextStore.shared.setScope(.selection, for: id)
                    ConnectsToast.show("上下文：选区", in: self.view, duration: 1.2)
                },
                ConnectsMenuItem(title: mark(.sectionOrPage, title: "节 / 页"), icon: .toc) { [weak self] in
                    guard let self = self else { return }
                    StudyFileContextStore.shared.setScope(.sectionOrPage, for: id)
                    ConnectsToast.show("上下文：节/页", in: self.view, duration: 1.2)
                },
                ConnectsMenuItem(title: "重新同步全文", icon: .retry) { [weak self] in
                    guard let self = self else { return }
                    StudyFileContextStore.shared.setScope(.resync, for: id)
                    ConnectsToast.show("下一条将重新钉住全文", in: self.view, duration: 1.4)
                }
            ],
            sourceView: sourceView,
            sourceRect: sourceView.bounds
        )
    }

    func inputBarDidRequestReasoningEffort(from sourceView: UIView) {
        let current = SettingsManager.shared.reasoningEffort
        func mark(_ level: ReasoningEffortLevel) -> String {
            current == level ? "✓ \(level.displayName)" : level.displayName
        }
        ConnectsMenu.present(
            from: self,
            title: "Kimi K3 思考程度",
            items: ReasoningEffortLevel.allCases.map { level in
                ConnectsMenuItem(title: mark(level), isSelected: current == level) { [weak self] in
                    guard let self = self else { return }
                    SettingsManager.shared.reasoningEffort = level
                    ConnectsToast.show("思考程度：\(level.displayName)", in: self.view, duration: 1.2)
                }
            },
            sourceView: sourceView,
            sourceRect: sourceView.bounds,
            preferAbove: true
        )
    }

    func inputBarDidTapSend(text: String, imageBase64: String?) {
        sendMessage(text, imageBase64: imageBase64)
    }

    func inputBarDidRejectUnsupportedImage() {
        notifyUnsupportedImageSend()
    }

    func inputBarDidTapStop() {
        guard let id = currentConversationID else { return }
        if WebSearchCoordinator.shared.isSearching(id) {
            WebSearchCoordinator.shared.cancel(id)
            ConversationStore.shared.finishStreamingMessage(
                conversationID: id,
                errorText: "已取消联网搜索。"
            )
            reloadChat()
        }
        if ImageTranscriptionCoordinator.shared.isTranscribing(id) {
            ImageTranscriptionCoordinator.shared.cancel(id)
            ConversationStore.shared.updateConversationQuietly(id: id) { draft in
                if let i = draft.messages.lastIndex(where: { $0.role == .assistant }) {
                    draft.messages[i].isStreaming = false
                    if draft.messages[i].imageTranscriptionPhase == .transcribing {
                        draft.messages[i].imageTranscriptionPhase = .failed
                        draft.messages[i].imageTranscriptionContent = "已取消图片转写。"
                    }
                }
            }
            NotificationCenter.default.post(
                name: .imageTranscriptionDidUpdate,
                object: nil,
                userInfo: ["conversationID": id]
            )
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

    func inputBarDidTapContextUsage() {
        guard let conv = ConversationStore.shared.currentConversation else { return }
        let breakdown = contextBreakdownCache[conv.id] ?? ContextBuilder.breakdown(for: conv)
        contextBreakdownCache[conv.id] = breakdown
        contextUsageCache[conv.id] = breakdown.usage

        let detail = ContextUsageDetailViewController(breakdown: breakdown)
        detail.setCompacting(ContextCompactor.isCompacting(conv.id))
        detail.onCompact = { [weak self, weak detail] in
            self?.compactContextFromDetail(conversationID: conv.id, detail: detail)
        }

        let nav = UINavigationController(rootViewController: detail)
        nav.modalPresentationStyle = .formSheet
        nav.preferredContentSize = CGSize(width: 420, height: 520)
        present(nav, animated: true)
    }

    private func compactContextFromDetail(conversationID: String,
                                          detail: ContextUsageDetailViewController?) {
        if StreamManager.shared.isRunning(conversationID) {
            showAlert(title: "正在生成", message: "请先停止或等待回复完成，再压缩上下文。")
            return
        }
        inputBar.setContextUsageCompacting(true)
        detail?.setCompacting(true)
        ContextCompactor.compactIfNeeded(conversationID: conversationID, force: true) { [weak self] did in
            guard let self = self else { return }
            self.inputBar.setContextUsageCompacting(false)
            self.refreshContextUsage()
            if did {
                if let host = self.view {
                    ConnectsToast.show("已压缩上下文", in: host, duration: 1.4)
                }
                detail?.dismiss(animated: true)
            } else {
                detail?.setCompacting(false)
                self.showAlert(title: "无需压缩", message: "当前上下文占用不高，或已在压缩中。")
            }
        }
    }
}

extension ChatViewController {
    struct DebugQAEdgeState {
        let userRowsAtTopEdge: [Int]
        let userRowsAtBottomEdge: [Int]
        let assistantRowsNearUserEdge: [Int]
        let uncommittedAssistantsNearEdge: Int
    }

    /// User bubbles straddling the viewport band — used by scroll repair and stress harness.
    func debugVisibleQAEdgeState(edgeBand: CGFloat = 52) -> DebugQAEdgeState {
        guard let messages = ConversationStore.shared.currentConversation?.messages else {
            return DebugQAEdgeState(
                userRowsAtTopEdge: [],
                userRowsAtBottomEdge: [],
                assistantRowsNearUserEdge: [],
                uncommittedAssistantsNearEdge: 0
            )
        }
        let topLimit = tableView.adjustedContentInset.top + edgeBand
        let bottomLimit = tableView.bounds.height - tableView.adjustedContentInset.bottom - edgeBand
        var topUsers: [Int] = []
        var bottomUsers: [Int] = []
        var nearAssistants: [Int] = []
        var uncommittedNearEdge = 0
        for path in tableView.indexPathsForVisibleRows ?? [] {
            guard path.row < messages.count else { continue }
            let msg = messages[path.row]
            let frame = tableView.rectForRow(at: path)
            let minY = frame.minY - tableView.contentOffset.y
            let maxY = frame.maxY - tableView.contentOffset.y
            let nearTop = minY < topLimit && maxY > topLimit - edgeBand
            let nearBottom = maxY > bottomLimit && minY < bottomLimit + edgeBand
            if msg.role == .user {
                if nearTop { topUsers.append(path.row) }
                if nearBottom { bottomUsers.append(path.row) }
            } else if msg.role == .assistant, !msg.isStreaming, (nearTop || nearBottom) {
                nearAssistants.append(path.row)
                if !rowHeights.isCommitted(msg.id) { uncommittedNearEdge += 1 }
            }
        }
        return DebugQAEdgeState(
            userRowsAtTopEdge: topUsers,
            userRowsAtBottomEdge: bottomUsers,
            assistantRowsNearUserEdge: nearAssistants,
            uncommittedAssistantsNearEdge: uncommittedNearEdge
        )
    }

    /// Visible assistant rows whose action chrome extends past the allocated row frame.
    func debugVisibleRowClipCount() -> Int {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return 0 }
        var clipped = 0
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard msg.role == .assistant, !msg.isStreaming else { continue }
            let rowFrame = tableView.rectForRow(at: path)
            if cell.hasVisibleActionButtons,
               let actionTop = cell.debugActionRowViewportY(in: tableView) {
                let actionBottom = actionTop + AssistantMessageLayout.actionRowHeight
                let rowBottom = rowFrame.maxY - tableView.contentOffset.y
                if actionBottom > rowBottom + 2 {
                    clipped += 1
                    continue
                }
            }
            let contentH = cell.measuredContentHeight() + ChatRowHeightResolver.cellVerticalMargin
            if contentH > rowFrame.height + 6 {
                clipped += 1
            }
        }
        return clipped
    }
}

#if DEBUG
extension ChatViewController {
    struct DebugScrollAnchor {
        let row: Int
        let viewportY: CGFloat
    }

    /// Small scroll-up delta that moves the next user bubble into the edge band (QA crossing).
    func debugSuggestedQAEdgeScrollDelta(maxScan: CGFloat = 220, edgeBand: CGFloat = 52) -> CGFloat? {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return nil }
        let topLimit = tableView.adjustedContentInset.top + edgeBand
        let step: CGFloat = 8
        var offset = tableView.contentOffset.y
        let minY = -tableView.adjustedContentInset.top
        let saved = offset
        var best: CGFloat?
        var scan: CGFloat = 0
        while scan < maxScan {
            offset = max(minY, saved - scan)
            tableView.contentOffset.y = offset
            tableView.layoutIfNeeded()
            let edge = debugVisibleQAEdgeState(edgeBand: edgeBand)
            if !edge.userRowsAtTopEdge.isEmpty || !edge.userRowsAtBottomEdge.isEmpty {
                best = scan
                break
            }
            for path in tableView.indexPathsForVisibleRows ?? [] {
                guard path.row < messages.count, messages[path.row].role == .user else { continue }
                let frame = tableView.rectForRow(at: path)
                let minY = frame.minY - tableView.contentOffset.y
                if minY > topLimit + 4, minY < topLimit + edgeBand + 80 {
                    best = scan
                    break
                }
            }
            if best != nil { break }
            scan += step
        }
        tableView.contentOffset.y = saved
        tableView.layoutIfNeeded()
        guard let best, best > 4 else { return nil }
        return best
    }

    struct DebugScrollJump {
        let row: Int
        let delta: CGFloat
    }

    func debugScrollAnchorSnapshot() -> DebugScrollAnchor? {
        guard let path = tableView.indexPathsForVisibleRows?.sorted(by: { $0.row < $1.row }).first,
              let cell = tableView.cellForRow(at: path) else { return nil }
        let viewportY = cell.convert(cell.bounds, to: tableView).minY - tableView.contentOffset.y
        return DebugScrollAnchor(row: path.row, viewportY: viewportY)
    }

    func debugScrollJumpSince(anchor: DebugScrollAnchor?, maxAllowed: CGFloat) -> DebugScrollJump? {
        guard let anchor = anchor,
              let path = tableView.indexPathsForVisibleRows?.first(where: { $0.row == anchor.row }),
              let cell = tableView.cellForRow(at: path) else { return nil }
        let viewportY = cell.convert(cell.bounds, to: tableView).minY - tableView.contentOffset.y
        let delta = abs(viewportY - anchor.viewportY)
        guard delta > maxAllowed else { return nil }
        return DebugScrollJump(row: anchor.row, delta: delta)
    }

    /// Drift of a row from its expected viewport Y after an intentional scroll + render settle.
    func debugViewportDrift(row: Int, expectedY: CGFloat, maxAllowed: CGFloat) -> CGFloat? {
        let path = IndexPath(row: row, section: 0)
        guard row >= 0, row < tableView.numberOfRows(inSection: 0),
              let cell = tableView.cellForRow(at: path) else { return nil }
        let viewportY = cell.convert(cell.bounds, to: tableView).minY - tableView.contentOffset.y
        let drift = abs(viewportY - expectedY)
        return drift > maxAllowed ? drift : nil
    }

    func debugRowViewportY(row: Int) -> CGFloat? {
        let path = IndexPath(row: row, section: 0)
        guard row >= 0, row < tableView.numberOfRows(inSection: 0),
              let cell = tableView.cellForRow(at: path) else { return nil }
        return cell.convert(cell.bounds, to: tableView).minY - tableView.contentOffset.y
    }

    func debugFirstUserRowIndex() -> Int? {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return nil }
        return messages.firstIndex(where: { $0.role == .user })
    }

    /// Scroll up in chunks until the first user bubble straddles the top edge band.
    func debugScrollUntilFirstUserAtTopEdge(maxSteps: Int = 48,
                                            stepDistance: CGFloat = 140,
                                            completion: @escaping (Bool) -> Void) {
        guard let firstUser = debugFirstUserRowIndex() else {
            completion(false)
            return
        }
        var step = 0
        func attempt() {
            let edge = debugVisibleQAEdgeState()
            if edge.userRowsAtTopEdge.contains(firstUser) {
                completion(true)
                return
            }
            guard step < maxSteps else {
                completion(false)
                return
            }
            step += 1
            let minY = -tableView.adjustedContentInset.top
            let remaining = tableView.contentOffset.y - minY
            let distance = min(stepDistance, max(0, remaining))
            guard distance > 4 else {
                completion(edge.userRowsAtTopEdge.contains(firstUser))
                return
            }
            debugSimulateSlowScrollUp(distance: distance, duration: 0.28) {
                attempt()
            }
        }
        attempt()
    }

    func debugSimulateScrollUp(distance: CGFloat, completion: @escaping () -> Void) {
        debugSimulateSlowScrollUp(distance: distance, duration: 0.32, completion: completion)
    }

    /// Stepped scroll — mimics slow finger drag on iPad Air 1 so Mac M-series does not mask jank.
    func debugSimulateSlowScrollUp(distance: CGFloat,
                                   duration: TimeInterval = 1.85,
                                   completion: @escaping () -> Void) {
        scrollViewWillBeginDragging(tableView)
        let minY = -tableView.adjustedContentInset.top
        let startY = tableView.contentOffset.y
        let targetY = max(minY, startY - distance)
        let steps = max(24, Int(duration * 60))
        var frame = 0
        let timer = Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            frame += 1
            let t = min(1, CGFloat(frame) / CGFloat(steps))
            let eased = 1 - pow(1 - t, 3)
            let y = startY + (targetY - startY) * eased
            self.tableView.contentOffset = CGPoint(x: 0, y: y)
            self.scrollViewDidScroll(self.tableView)
            if frame >= steps {
                timer.invalidate()
                self.scrollViewDidEndDragging(self.tableView, willDecelerate: false)
                completion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Oscillate near the current viewport — reproduces bubble-edge wiggle (single drag gesture).
    func debugSimulateBubbleWiggle(amplitude: CGFloat = 56,
                                     halfCycles: Int = 4,
                                     halfDuration: TimeInterval = 0.18,
                                     completion: @escaping () -> Void) {
        scrollViewWillBeginDragging(tableView)
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(
            minY,
            tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
        )
        let originY = tableView.contentOffset.y
        let stepsPerHalf = max(14, Int(halfDuration * 60))
        var halfIndex = 0
        var frame = 0
        var segmentStartY = originY
        var segmentEndY = max(minY, originY - amplitude)

        let timer = Timer.scheduledTimer(withTimeInterval: halfDuration / Double(stepsPerHalf), repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            frame += 1
            let t = min(1, CGFloat(frame) / CGFloat(stepsPerHalf))
            let y = segmentStartY + (segmentEndY - segmentStartY) * t
            self.tableView.contentOffset.y = min(max(y, minY), maxY)
            self.scrollViewDidScroll(self.tableView)
            guard frame >= stepsPerHalf else { return }
            frame = 0
            halfIndex += 1
            guard halfIndex < halfCycles else {
                timer.invalidate()
                self.scrollViewDidEndDragging(self.tableView, willDecelerate: false)
                completion()
                return
            }
            segmentStartY = self.tableView.contentOffset.y
            let up = halfIndex % 2 == 0
            segmentEndY = up ? max(minY, originY - amplitude) : originY
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    struct DebugActionChromeSnapshot {
        let missingButtons: Int
        /// Absolute viewport Y of painted action buttons.
        let buttonViewportY: [Int: CGFloat]
        /// Button Y relative to the host row top (stable when above-row heights remount).
        let buttonRowRelativeY: [Int: CGFloat]
    }

    func debugVisibleActionChromeSnapshot() -> DebugActionChromeSnapshot {
        guard let messages = ConversationStore.shared.currentConversation?.messages else {
            return DebugActionChromeSnapshot(missingButtons: 0, buttonViewportY: [:], buttonRowRelativeY: [:])
        }
        var missing = 0
        var positions: [Int: CGFloat] = [:]
        var relative: [Int: CGFloat] = [:]
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard msg.role == .assistant, !msg.isStreaming else { continue }
            let hasBody = !msg.content.isEmpty
                || !msg.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || msg.hasSearchProcess
                || msg.hasImageTranscription
            guard hasBody else { continue }
            let chromeOK = rowHeights.isScrollHeightFrozen
                ? cell.hasAccommodatedActionChrome
                : cell.hasVisibleActionButtons
            if !chromeOK {
                missing += 1
            } else if let y = cell.debugActionRowViewportY(in: tableView) {
                // Only record painted button Y — reserved-slot estimates false-fail chrome-shift.
                positions[path.row] = y
                let rowTop = tableView.rectForRow(at: path).minY - tableView.contentOffset.y
                relative[path.row] = y - rowTop
            } else if rowHeights.isScrollHeightFrozen, cell.hasReservedActionChromeSpace {
                // Reserved but icons not painted yet: count as present for chrome-late,
                // but omit from position map (no stable Y to compare across settle).
                continue
            }
        }
        return DebugActionChromeSnapshot(
            missingButtons: missing,
            buttonViewportY: positions,
            buttonRowRelativeY: relative
        )
    }

    func debugContentOffsetY() -> CGFloat {
        tableView.contentOffset.y
    }

    func debugLayoutContentWidth() -> CGFloat {
        currentRenderWidth()
    }

    /// Wait until deferred native hydration + formula remeasure finish, then pin viewport.
    func debugWaitForReadingHistoryStable(maxAttempts: Int = 500, completion: @escaping () -> Void) {
        var stableTicks = 0
        func tick(_ attempt: Int) {
            guard attempt < maxAttempts else {
                completion()
                return
            }
            let pendingNative = tableView.visibleCells.contains { cell in
                (cell as? AssistantMessageCell)?.hasPendingDeferredNativeRender == true
            }
            let busy = pendingNative
                || formulaRemeasureWork != nil
                || pendingReadingHistoryFormulaSync
                || deferredRenderWork != nil
                || visibleNativeHydrationInProgress
            if busy {
                stableTicks = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    tick(attempt + 1)
                }
                return
            }
            stableTicks += 1
            guard stableTicks >= 4 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    tick(attempt + 1)
                }
                return
            }
            if let messages = ConversationStore.shared.currentConversation?.messages {
                if needsReadingHistoryLayoutRepair(messages: messages), !suppressPostHistorySettleRemeasure {
                    flushReadingHistoryFormulaSync(messages: messages)
                }
            } else {
                UIView.performWithoutAnimation {
                    tableView.beginUpdates()
                    tableView.endUpdates()
                    tableView.layoutIfNeeded()
                    remeasureRowsPreservingViewport(preferSavedViewportAnchor: true)
                }
            }
            completion()
        }
        tick(0)
    }

    /// Seed committed row heights from layout cache before scroll stress (math/code-heavy).
    /// `allowShrink: true` so narrow Study panels can drop stale full-width heights (code cards).
    func debugSeedCommittedHeightsFromLayoutCache() {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return }
        let layoutWidth = currentRenderWidth()
        let count = messages.count
        for (row, msg) in messages.enumerated() {
            guard msg.role == .assistant, !msg.isStreaming else { continue }
            guard let column = AssistantMessageLayout.estimatedColumnContentHeight(
                for: msg,
                layoutWidth: layoutWidth,
                isLastRow: row == count - 1,
                allowSyncLayout: true
            ), column > 40 else { continue }
            rowHeights.commitMeasured(columnHeight: column, messageID: msg.id, allowShrink: true)
        }
        rowHeights.publishCommittedToDisplay()
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()
        }
    }

    /// Simulate portrait ↔ landscape table width without resizing the Mac window.
    func debugSimulateLayoutWidthChange(tableWidth: CGFloat, completion: @escaping () -> Void) {
        debugLayoutWidthOverride = tableWidth
        layoutWidthBucket = widthBucket(for: tableWidth)
        invalidateHeightsForWidthChange(immediate: true)
        DispatchQueue.main.async(execute: completion)
    }

    func debugClearLayoutWidthOverride() {
        debugLayoutWidthOverride = nil
        layoutWidthBucket = widthBucket(for: tableView.bounds.width)
    }

    /// Snapshot committed heights into the current width bucket (simulates prior full-width chat).
    func debugPersistHeightCacheForCurrentWidth() {
        guard let cid = renderedConversationID else { return }
        storePersistedHeights(rowHeights.exportPersistable(), for: cid)
        saveHeightCaches()
    }

    /// Simulate first-open: no persisted heights, no layout cache, reload at bottom.
    func debugSimulateColdOpen(completion: @escaping () -> Void) {
        guard let cid = renderedConversationID ?? currentConversationID,
              let messages = ConversationStore.shared.currentConversation?.messages else {
            completion()
            return
        }
        NativeMessageLayouter.shared.clear()
        NativeFormulaRenderer.shared.clear()
        PlainMarkdown.clearCache()
        ChatViewController.clearTransientRenderCaches()
        rowHeights.clearAll()
        pendingHeights.removeAll()
        storePersistedHeights([:], for: cid)
        RenderCacheStore.clearHeights()
        let layoutWidth = currentRenderWidth()
        rowHeights.resetForConversation(
            diskCache: [:],
            messages: messages,
            layoutWidth: layoutWidth,
            layoutProbeTailRows: messages.count
        )
        isPerformingColdLaunchOpen = true
        if studyChromeMode != .none {
            pendingStudyFirstScrollPrep = true
        } else {
            needsFirstHistoryScrollPrep = true
        hasCompletedFirstHistoryScrollGesture = false
        }
        readingHistory = false
        stickToBottom = true
        viewportPinnedByUser = false
        tableView.reloadData()
        tableView.layoutIfNeeded()
        scrollToLastRowReliable(messages)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion()
                return
            }
            self.tableView.layoutIfNeeded()
            self.eagerPreparePendingHistoryHeightsAtBottom()
            completion()
        }
    }

    /// Visible assistant rows with action chrome in partial-hide flicker state.
    func debugVisibleActionChromeFlickerCount() -> Int {
        guard let messages = ConversationStore.shared.currentConversation?.messages else { return 0 }
        var flicker = 0
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard msg.role == .assistant, !msg.isStreaming else { continue }
            if cell.isActionChromeFlickering { flicker += 1 }
        }
        return flicker
    }

    struct DebugStudyBlankState {
        let unrenderedAssistants: Int
        let inflatedRows: Int
        let maxRowSlackPt: CGFloat
        let interRowGaps: Int
        let maxInterRowGapPt: CGFloat
    }

    /// Visible rows with empty slack (row taller than painted content) or unpainted assistant bodies.
    func debugVisibleStudyBlankState(rowSlackThreshold: CGFloat? = nil,
                                     interRowGapThreshold: CGFloat = 28) -> DebugStudyBlankState {
        let slackThreshold = rowSlackThreshold ?? (usesStudyHeightBucketPolicy() ? 28 : 72)
        guard let messages = ConversationStore.shared.currentConversation?.messages else {
            return DebugStudyBlankState(
                unrenderedAssistants: 0,
                inflatedRows: 0,
                maxRowSlackPt: 0,
                interRowGaps: 0,
                maxInterRowGapPt: 0
            )
        }
        var unrendered = 0
        var inflated = 0
        var maxSlack: CGFloat = 0
        var interRowGaps = 0
        var maxInterRowGap: CGFloat = 0
        for case let cell as MessageCellType in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            let rowFrame = tableView.rectForRow(at: path)
            let contentH = cell.measuredContentHeight() + ChatRowHeightResolver.cellVerticalMargin
            var slack = rowFrame.height - contentH
            if let assistant = cell as? AssistantMessageCell,
               msg.role == .assistant,
               assistant.hasReservedActionChromeSpace,
               !assistant.hasVisibleActionButtons {
                slack -= Self.actionChromeHeightSlack
            }
            if slack > maxSlack { maxSlack = slack }
            if slack > slackThreshold { inflated += 1 }
            if let assistant = cell as? AssistantMessageCell,
               msg.role == .assistant,
               !msg.isStreaming,
               !msg.content.isEmpty,
               !assistant.hasVisibleBodyPaint {
                unrendered += 1
            }
            if msg.role == .assistant, path.row + 1 < messages.count {
                let nextPath = IndexPath(row: path.row + 1, section: 0)
                let nextTop = tableView.rectForRow(at: nextPath).minY
                let gap = nextTop - rowFrame.maxY
                if gap > maxInterRowGap { maxInterRowGap = gap }
                if gap > interRowGapThreshold { interRowGaps += 1 }
            }
        }
        return DebugStudyBlankState(
            unrenderedAssistants: unrendered,
            inflatedRows: inflated,
            maxRowSlackPt: maxSlack,
            interRowGaps: interRowGaps,
            maxInterRowGapPt: maxInterRowGap
        )
    }

    /// Enter study document-reader chrome at a narrow table width (iPad split-chat panel).
    func debugEnterStudyPanel(tableWidth: CGFloat, completion: @escaping () -> Void) {
        setStudyChrome(.documentReader)
        debugSimulateLayoutWidthChange(tableWidth: tableWidth, completion: completion)
    }

    /// Enter study portrait overlay (full-width chat above PDF).
    func debugEnterStudyPortraitPanel(tableWidth: CGFloat, completion: @escaping () -> Void) {
        setStudyChrome(.portraitPanel)
        debugSimulateLayoutWidthChange(tableWidth: tableWidth, completion: completion)
    }

    func debugWaitForStudyRelayoutStable(completion: @escaping () -> Void) {
        if let messages = ConversationStore.shared.currentConversation?.messages {
            let assistants = messages.filter { $0.role == .assistant && !$0.isStreaming }
            AssistantMessageLayout.prewarmLayouts(
                for: assistants,
                targetWidth: currentRenderWidth(),
                layoutLimit: assistants.count
            )
        }
        func tick(_ attempt: Int) {
            guard attempt < 400 else {
                completion()
                return
            }
            let pendingNative = tableView.visibleCells.contains { cell in
                (cell as? AssistantMessageCell)?.hasPendingDeferredNativeRender == true
            }
            if pendingNative || formulaRemeasureWork != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    tick(attempt + 1)
                }
                return
            }
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
                tableView.layoutIfNeeded()
            }
            completion()
        }
        tick(0)
    }

    func debugPinToBottom(completion: @escaping () -> Void) {
        guard let messages = ConversationStore.shared.currentConversation?.messages, !messages.isEmpty else {
            completion()
            return
        }
        scrollToLastRowReliable(messages)
        DispatchQueue.main.async(execute: completion)
    }

    /// Visual QA: append a finished user+assistant turn and force Study send-path pin-to-bottom.
    func debugVisualAppendOutgoingTurn(user: String,
                                       assistant: String,
                                       completion: @escaping () -> Void) {
        guard let convID = ConversationStore.shared.currentConversation?.id else {
            completion()
            return
        }
        let userMsg = ChatMessage(role: .user, content: user)
        let assistantMsg = ChatMessage(role: .assistant, content: assistant, isStreaming: false)
        let firstNewRow = ConversationStore.shared.currentConversation?.messages.count ?? 0
        let layoutWidth = currentRenderWidth()
        if let userH = ChatRowHeightResolver.estimatedUserColumnContentHeight(
            for: userMsg,
            layoutWidth: layoutWidth
        ), userH > 40 {
            rowHeights.commitMeasured(columnHeight: userH, messageID: userMsg.id, allowShrink: true)
        }
        let assistantFloor = max(
            ChatRowHeightResolver.cheapColumnEstimate(for: assistantMsg, layoutWidth: layoutWidth),
            120
        )
        rowHeights.commitMeasured(
            columnHeight: assistantFloor,
            messageID: assistantMsg.id,
            allowShrink: true
        )
        ConversationStore.shared.updateConversationQuietly(id: convID) { c in
            c.messages.append(userMsg)
            c.messages.append(assistantMsg)
        }
        readingHistory = false
        viewportPinnedByUser = false
        stickToBottom = true
        finishViewportLocked = false
        if rowHeights.isScrollHeightFrozen {
            rowHeights.endScrollHeightFreeze()
        }
        let expectedRows = firstNewRow + 2
        UIView.performWithoutAnimation {
            if tableView.numberOfRows(inSection: 0) == firstNewRow {
                tableView.insertRows(
                    at: [
                        IndexPath(row: firstNewRow, section: 0),
                        IndexPath(row: firstNewRow + 1, section: 0)
                    ],
                    with: .none
                )
            } else {
                tableView.reloadData()
            }
            tableView.layoutIfNeeded()
        }
        stickToBottom = true
        readingHistory = false
        viewportPinnedByUser = false
        if let live = ConversationStore.shared.currentConversation?.messages, !live.isEmpty {
            pinOpenViewportToBottom(live, layoutWidth: layoutWidth)
            let last = IndexPath(row: max(0, live.count - 1), section: 0)
            if last.row < tableView.numberOfRows(inSection: 0) {
                tableView.scrollToRow(at: last, at: .bottom, animated: false)
            }
            snapTableContentOffsetToBottom()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion()
                return
            }
            self.stickToBottom = true
            self.readingHistory = false
            self.viewportPinnedByUser = false
            if let live = ConversationStore.shared.currentConversation?.messages, !live.isEmpty {
                self.pinOpenViewportToBottom(live, layoutWidth: self.currentRenderWidth())
                let last = IndexPath(row: max(0, live.count - 1), section: 0)
                if last.row < self.tableView.numberOfRows(inSection: 0) {
                    self.tableView.scrollToRow(at: last, at: .bottom, animated: false)
                }
                self.snapTableContentOffsetToBottom()
            }
            _ = expectedRows
            completion()
        }
    }

    /// Whether the last assistant row's bottom edge sits near the table viewport bottom.
    func debugLastAssistantNearBottom(tolerance: CGFloat) -> Bool {
        let rows = tableView.numberOfRows(inSection: 0)
        guard rows > 0 else { return false }
        let path = IndexPath(row: rows - 1, section: 0)
        tableView.layoutIfNeeded()
        let rowRect = tableView.rectForRow(at: path)
        guard rowRect.height > 1 else { return false }
        let visibleBottom = tableView.contentOffset.y
            + tableView.bounds.height
            - tableView.adjustedContentInset.bottom
        let rowBottom = rowRect.maxY
        return abs(rowBottom - visibleBottom) <= tolerance || rowBottom <= visibleBottom + tolerance
    }

    /// One history walk + seed so narrow Study + code-card paint matches committed heights
    /// before CrossQA jump steps (avoids mid-scroll estimate→paint collapse).
    func debugWarmScrollHeightsThenPin(completion: @escaping () -> Void) {
        func walkUp() {
            let minY = -tableView.adjustedContentInset.top
            let remaining = tableView.contentOffset.y - minY
            if remaining < 48 {
                debugSeedCommittedHeightsFromLayoutCache()
                if let messages = ConversationStore.shared.currentConversation?.messages {
                    _ = syncVisibleRowHeightsToPaint(messages: messages, allowShrink: true)
                    UIView.performWithoutAnimation {
                        tableView.beginUpdates()
                        tableView.endUpdates()
                        tableView.layoutIfNeeded()
                    }
                }
                debugPinToBottom(completion: completion)
                return
            }
            let distance = min(420, remaining)
            debugSimulateSlowScrollUp(distance: distance, duration: 0.22) { [weak self] in
                guard let self = self else {
                    completion()
                    return
                }
                self.debugSeedCommittedHeightsFromLayoutCache()
                if let messages = ConversationStore.shared.currentConversation?.messages {
                    _ = self.syncVisibleRowHeightsToPaint(messages: messages, allowShrink: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    walkUp()
                }
            }
        }
        debugSeedCommittedHeightsFromLayoutCache()
        walkUp()
    }

    func debugScrollToRow(_ row: Int, completion: @escaping () -> Void) {
        guard row >= 0, row < tableView.numberOfRows(inSection: 0) else {
            completion()
            return
        }
        let path = IndexPath(row: row, section: 0)
        tableView.scrollToRow(at: path, at: .middle, animated: false)
        tableView.layoutIfNeeded()
        DispatchQueue.main.async(execute: completion)
    }

    struct DebugVisibleCrossQAState {
        let unrenderedAssistants: Int
        let missingActionButtons: Int
    }

    func debugVisibleCrossQAState() -> DebugVisibleCrossQAState {
        guard let messages = ConversationStore.shared.currentConversation?.messages else {
            return DebugVisibleCrossQAState(unrenderedAssistants: 0, missingActionButtons: 0)
        }
        var unrendered = 0
        var missingActions = 0
        for case let cell as AssistantMessageCell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell),
                  path.row < messages.count else { continue }
            let msg = messages[path.row]
            guard msg.role == .assistant, !msg.isStreaming else { continue }
            let hasBody = !msg.content.isEmpty
                || !msg.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || msg.hasSearchProcess
                || msg.hasImageTranscription
            guard hasBody else { continue }
            if !cell.hasVisibleNativePaint {
                unrendered += 1
            }
            let chromeOK = rowHeights.isScrollHeightFrozen
                ? cell.hasAccommodatedActionChrome
                : cell.hasVisibleActionButtons
            if !chromeOK {
                missingActions += 1
            }
        }
        return DebugVisibleCrossQAState(unrenderedAssistants: unrendered, missingActionButtons: missingActions)
    }

    func debugSetStudyCaptureEnabled(_ enabled: Bool) {
        inputBarDidToggleStudyCapture(enabled)
    }

    func debugAttachStudyDocument(documentID: String) {
        guard let id = currentConversationID else { return }
        ConversationStore.shared.updateConversation(id: id) { draft in
            draft.studyDocumentID = documentID
            draft.studyWorkspaceID = nil
            draft.studySessionKind = .document
            draft.studyPageCaptureEnabled = true
            draft.studyAgentMode = StudyAgentMode.coerceForProduct(draft.studyAgentMode)
        }
        reloadChat()
    }

    func debugSendUserMessage(
        _ text: String,
        imageBase64: String? = nil,
        studyCaptureEnabled: Bool? = nil,
        timeout: TimeInterval = 180,
        completion: @escaping (Bool) -> Void
    ) {
        guard let convID = currentConversationID else {
            completion(false)
            return
        }
        if let enabled = studyCaptureEnabled {
            debugSetStudyCaptureEnabled(enabled)
        }
        final class ObserverBox {
            var observer: NSObjectProtocol?
        }
        let box = ObserverBox()
        let timeoutWork = DispatchWorkItem {
            if let observer = box.observer {
                NotificationCenter.default.removeObserver(observer)
                box.observer = nil
            }
            completion(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        box.observer = NotificationCenter.default.addObserver(
            forName: .streamManagerDidFinish,
            object: nil,
            queue: .main
        ) { note in
            guard let id = note.userInfo?["conversationID"] as? String, id == convID else { return }
            if let observer = box.observer {
                NotificationCenter.default.removeObserver(observer)
                box.observer = nil
            }
            timeoutWork.cancel()
            completion(true)
        }
        sendMessage(text, imageBase64: imageBase64)
    }

    /// No-network stress: agent chrome + body growth without beginUpdates storms.
    /// Launch via `-AgentFreezeQA`.
    func debugAgentFreezeBurst(iterations: Int = 80, completion: @escaping ([String]) -> Void) {
        guard let convID = currentConversationID else {
            completion(["no conversation"])
            return
        }
        let rootID: String = {
            if let existing = ConversationStore.shared.conversation(id: convID)?
                .messages.last(where: { $0.role == .assistant })?.id {
                return existing
            }
            let root = ChatMessage(
                role: .assistant,
                content: "",
                isStreaming: false,
                agentProcessPhase: .running,
                agentProcessStartedAt: Date()
            )
            ConversationStore.shared.updateConversationQuietly(id: convID) { draft in
                draft.messages.append(root)
            }
            return root.id
        }()
        agentProcessRootIDs[convID] = rootID
        ConversationStore.shared.updateConversationQuietly(id: convID) { draft in
            guard let idx = draft.messages.lastIndex(where: { $0.id == rootID }) else { return }
            draft.messages[idx].agentProcessPhase = .running
            draft.messages[idx].agentProcessStartedAt = Date()
            draft.messages[idx].isStreaming = false
            draft.messages[idx].content = ""
        }
        reloadChat()

        var issues: [String] = []
        var lastPing = Date()
        let watch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let gap = Date().timeIntervalSince(lastPing)
            lastPing = Date()
            if gap > 1.0 {
                issues.append(String(format: "main stall %.2fs", gap))
            }
            func walk(_ v: UIView) {
                if let b = v as? UIButton {
                    let t = b.title(for: .normal) ?? ""
                    if t.contains("工作中"), b.bounds.height > 0, b.bounds.height < 20 {
                        issues.append("工作中 crushed h=\(Int(b.bounds.height))")
                    }
                }
                for c in v.subviews { walk(c) }
            }
            walk(self.view)
        }
        RunLoop.main.add(watch, forMode: .common)

        var i = 0
        let baselineRows = tableView.numberOfRows(inSection: 0)
        func tick() {
            guard i < iterations else {
                watch.invalidate()
                ConversationStore.shared.updateConversationQuietly(id: convID) { draft in
                    guard let idx = draft.messages.lastIndex(where: { $0.id == rootID }) else { return }
                    draft.messages[idx].agentProcessPhase = .done
                    draft.messages[idx].content = "合成压力测试完成。"
                }
                refreshAgentProcessChrome(messageID: rootID)
                let finalRows = tableView.numberOfRows(inSection: 0)
                if finalRows != baselineRows {
                    issues.append("row count drifted \(baselineRows)→\(finalRows)")
                }
                completion(Array(Set(issues)))
                return
            }
            i += 1
            let stepKinds: [AgentStepKind] = [.exploring, .grepped, .read, .edited]
            let kind = stepKinds[i % stepKinds.count]
            var step = AgentProcessStep(
                kind: kind,
                title: kind == .edited ? "Editing Foo.swift" : "\(kind.displayTitle)…",
                detail: kind == .edited ? "Edited Foo.swift +\(i)" : "Explored \(i) files",
                status: .done
            )
            step.markDone()
            mutateAgentSteps(conversationID: convID, messageID: rootID) { msg in
                msg.agentProcessSteps.append(step)
                msg.upsertMetaPart(from: step)
                if i % 7 == 0 {
                    // Simulate first body sentence appearing mid-run.
                    msg.content = "这是正文第 \(i) 句。继续保持过程条可见。"
                }
                // Simulate tool-continue without inserting table rows.
                if i % 11 == 0 {
                    msg.agentToolTurns.append(
                        AgentToolTurn(
                            assistantContent: "tool_round_\(i)",
                            toolResults: "## TOOL_RESULTS\nok"
                        )
                    )
                    msg.agentProseSegments.append("段落 \(i)")
                    msg.appendProsePart("段落 \(i)")
                    msg.content = ""
                    msg.agentEditCards = [
                        AgentEditCard(
                            fileName: "Foo.swift",
                            additions: i,
                            deletions: 1,
                            snippetMinus: "old",
                            snippetPlus: "new"
                        )
                    ]
                }
            }
            if tableView.numberOfRows(inSection: 0) != baselineRows {
                issues.append("row grew at i=\(i)")
            }
            // Also paint body via root streaming path.
            if i % 5 == 0, let messages = ConversationStore.shared.currentConversation?.messages,
               let rootRow = messages.firstIndex(where: { $0.id == rootID }),
               let cell = tableView.cellForRow(at: IndexPath(row: rootRow, section: 0)) as? AssistantMessageCell {
                cell.applyAgentTurnStreamingBody(messages[rootRow].chatDisplayBody)
                commitAgentStreamingRowHeight(cell: cell, messageID: rootID)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: tick)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: tick)
    }
}
#endif
