import UIKit
import ObjectiveC

/// Assistant reply row: native markdown, thinking/search chrome, action row.
final class AssistantMessageCell: UITableViewCell, MessageCellType {
    static let reuseID = MessageCellReuseID.assistant
    private static let actionRowVisibleHeight: CGFloat = 36

    weak var cellDelegate: MessageCellDelegate?
    private(set) var messageID: String = ""

    private let column = UIView()
    private let roleLabel = UILabel()
    private let imageViewMsg = UIImageView()
    private let imageStripView = MessageImageStripView()

    private let thinkingHeader = UIButton(type: .system)
    private let thinkingBody = UILabel()
    private let thinkingBox = UIView()

    private let searchHeader = UIButton(type: .system)
    private let searchBody = UILabel()
    private let searchBox = UIView()
    /// Cursor-style inline edit cards under the process chrome.
    private let agentEditCardsStack = UIStackView()
    /// Vertical steps stack (meta / prose / edit) — Cursor `flex column` + step gap.
    private let agentTimelineStack = UIStackView()
    /// Stable id → view for incremental timeline paint (keeps shimmer alive).
    private var agentTimelineViewsByID: [String: UIView] = [:]
    private var agentTimelineOrder: [String] = []
    private weak var agentLiveShimmerLabel: ConnectsShimmerLabel?
    /// Explicit Explored expand overrides keyed by header id (`explore-header`, `explore-header-2`, …).
    /// Missing key → auto: expanded while running, collapsed when done.
    private var agentExploreExpandOverride: [String: Bool] = [:]
    private var agentThoughtExpandedIDs = Set<String>()
    private var agentPaintLayoutWidth: CGFloat = 0
    private static let agentExploreChildIndent: CGFloat = 12

    private let assistantLabel = UILabel()
    private let nativeRenderView = NativeMessageRenderView()
    private let actionRow = UIView()
    /// Single stack so version pager + copy/retry/fork never share leading constraints.
    private let actionChromeStack = UIStackView()
    private let versionCluster = UIStackView()
    private let versionPrevButton = UIButton(type: .system)
    private let versionNextButton = UIButton(type: .system)
    private let versionLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let forkButton = UIButton(type: .system)

    private var columnWidthFill: NSLayoutConstraint!
    private var columnWidthMax: NSLayoutConstraint!
    private var columnCenterX: NSLayoutConstraint!
    /// Extra left bias in landscape study split — keeps action chrome off the seam handle.
    var studyContentLeadingGutter: CGFloat = 0 {
        didSet { applyColumnContentGutter() }
    }
    private var imageHeight: NSLayoutConstraint!
    private var actionHeight: NSLayoutConstraint!
    private var thinkingHeaderH: NSLayoutConstraint!
    private var thinkingBoxH: NSLayoutConstraint!
    private var thinkingBodyH: NSLayoutConstraint!
    private var searchBodyH: NSLayoutConstraint!
    private var thinkingToHeader: NSLayoutConstraint!
    private var thinkingToBody: NSLayoutConstraint!
    private var searchHeaderH: NSLayoutConstraint!
    private var searchBoxH: NSLayoutConstraint!
    private var searchToHeader: NSLayoutConstraint!
    private var searchToBody: NSLayoutConstraint!
    private var searchTop: NSLayoutConstraint!
    private var agentEditCardsTop: NSLayoutConstraint!
    private var agentEditCardsHeight: NSLayoutConstraint!
    private var assistantTopToRole: NSLayoutConstraint!
    private var assistantTopToImage: NSLayoutConstraint!
    private var assistantTopToThink: NSLayoutConstraint!
    private var assistantTopToEditCards: NSLayoutConstraint!
    private var timelineTopToRole: NSLayoutConstraint!
    private var timelineTopToImage: NSLayoutConstraint!
    private var columnBottomToTimeline: NSLayoutConstraint!
    private var thinkingTop: NSLayoutConstraint!
    private var labelBottom: NSLayoutConstraint!
    private var labelBottomFloor: NSLayoutConstraint!
    private var nativeHeight: NSLayoutConstraint!
    private var nativeTopToRole: NSLayoutConstraint!
    private var nativeTopToImage: NSLayoutConstraint!
    private var nativeTopToThink: NSLayoutConstraint!
    private var nativeTopToEditCards: NSLayoutConstraint!
    private var nativeBottom: NSLayoutConstraint!
    private var columnBottomPin: NSLayoutConstraint!
    /// Action chrome overlays contentView bottom — not in column stack (avoids body jump on icon restore).
    private var actionRowBottomToContent: NSLayoutConstraint!
    private var actionGapFromColumn: NSLayoutConstraint!
    private var actionRowPinnedBelowColumn = false
    private var columnBottomToNative: NSLayoutConstraint!
    private var columnBottomToLabel: NSLayoutConstraint!

    private var heightNotifyWork: DispatchWorkItem?
    private var hasThinking = false
    private var thinkingExpanded = false
    private var hasSearch = false
    private var searchExpanded = false
    private var imageTranscriptionFailed = false
    private var streamingPresentation = false
    /// Live「思考中」preview uses a fixed 3-line slot so the row does not bob.
    private var thinkingLivePreviewMode = false
    private var searchLivePreviewMode = false
    /// Native markdown can be configured before UITableView assigns its final
    /// width when switching chats. Keep the source for one deferred remeasure.
    private var cachedReasoningText = ""
    private var cachedSearchText = ""
    private var cachedSearchTitleCore = ""
    private var cachedImageActivity = false
    private var cachedImageTranscriptionPhase: ImageTranscriptionPhase = .idle
    private var pairedUserMessage: ChatMessage?
    private var cachedThinkingFontSize: CGFloat = 14
    private var cachedThemeColors: ThemeColors?
    private var preferredLayoutWidth: CGFloat = 0
    private var configuredPreferredHeight: CGFloat?
    private var deferredNativeBind: DeferredNativeBind?
    private var nativeMessageForRemeasure: ChatMessage?
    private var lastActionRowSignature = ""
    private var lastChromeActionKey = ""
    private static let chromeHeaderFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
    private var cachedThinkingExpandDelta: CGFloat = 0
    private var cachedSearchExpandDelta: CGFloat = 0

    private struct DeferredNativeBind {
        let message: ChatMessage
        let hasThinking: Bool
        let hasSearch: Bool
        let hasImage: Bool
        let font: CGFloat
        let colors: ThemeColors
        let layoutWidth: CGFloat
    }
    private var lastNativeLayoutWidth: CGFloat = 0

    var hasPendingDeferredNativeRender: Bool {
        deferredNativeBind != nil
    }

    /// True while native rich body is the live paint (not plain/empty).
    var hasVisibleNativePaint: Bool {
        !nativeRenderView.isHidden
    }

    var hasVisibleBodyPaint: Bool {
        if hasVisibleNativePaint { return true }
        if !assistantLabel.isHidden {
            let text = assistantLabel.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !text.isEmpty
        }
        return false
    }

    /// Show action chrome in the same pass as body paint (history scroll).
    func revealActionChromeIfBodyPainted(for message: ChatMessage) {
        guard message.id == messageID || messageID.isEmpty else { return }
        guard Self.shouldShowActionButtons(for: message, streaming: false) else { return }
        guard hasVisibleBodyPaint else { return }
        if hasVisibleActionButtons { return }
        if revealReservedActionChromeIfRoom(for: message) { return }
        // Room check can fail on short frozen rows — still paint icons (may clip slightly).
        paintActionIconsWithoutLayout(for: message, colors: cachedThemeColors ?? DSTheme.c)
    }

    /// Paint reserved action icons once the host row is tall enough — avoids clip-then-shift.
    @discardableResult
    func revealReservedActionChromeIfRoom(for message: ChatMessage) -> Bool {
        guard message.id == messageID || messageID.isEmpty else { return false }
        guard Self.shouldShowActionButtons(for: message, streaming: false) else { return false }
        guard hasReservedActionChromeSpace, !hasVisibleActionButtons else { return false }
        guard cellDelegate?.messageCellRowHasRoomForActionChrome(self) != false else { return false }
        let pager = message.showsVersionPager
        showActions(
            true,
            versionText: pager ? message.versionPagerText : nil,
            canPrev: pager && message.versionIndex > 0,
            canNext: pager && message.versionIndex < message.versions.count - 1
        )
        actionRow.alpha = 1
        styleActionIcons(cachedThemeColors ?? DSTheme.c)
        lastChromeActionKey = "\(message.id)|true|\(pager)|\(message.versionIndex)|\(message.versions.count)"
        return true
    }

    /// Open critical path: force sync native — never leave empty/plain on first frame.
    func paintOpenCriticalBodyIfNeeded(with message: ChatMessage, layoutWidth: CGFloat) {
        guard message.role == .assistant,
              !message.isStreaming,
              message.id == messageID else { return }
        if !hasVisibleNativePaint {
            paintOpenHistoryBody(with: message, layoutWidth: layoutWidth)
        }
    }

    /// Tail-only open configure — no early returns, no plain placeholder.
    func configureForOpenBottom(with message: ChatMessage,
                                preferredHeight: CGFloat?,
                                layoutWidth: CGFloat) {
        studyContentLeadingGutter = cellDelegate?.messageCellStudyContentLeadingGutter() ?? 0
        messageID = message.id
        preferredLayoutWidth = layoutWidth
        configuredPreferredHeight = preferredHeight
        guard message.role == .assistant, !message.isStreaming else { return }
        showsImageInBubble = message.showsImageInChat
        roleLabel.isHidden = true
        roleLabel.text = nil
        applyMessageImages(to: message, deferHeavyRender: true)
        forcePaintOpenTailBody(with: message, layoutWidth: layoutWidth)
    }

    /// History assistant rows on open — sync native only when layout is already warm.
    func configureForOpenHistory(with message: ChatMessage,
                                 preferredHeight: CGFloat?,
                                 layoutWidth: CGFloat) {
        studyContentLeadingGutter = cellDelegate?.messageCellStudyContentLeadingGutter() ?? 0
        messageID = message.id
        preferredLayoutWidth = layoutWidth
        configuredPreferredHeight = preferredHeight
        guard message.role == .assistant, !message.isStreaming else { return }
        showsImageInBubble = message.showsImageInChat
        primeFinishedActionChromeSlot(for: message)
        if Self.shouldShowActionButtons(for: message, streaming: false),
           !hasVisibleActionButtons {
            paintActionIconsWithoutLayout(for: message, colors: DSTheme.c)
        }
        if hasVisibleNativePaint {
            if !assistantChromeMatches(message) {
                let c = DSTheme.c
                let thinkFont = SettingsManager.shared.chatThinkingFontSize
                applyAssistantChrome(
                    message: message,
                    colors: c,
                    thinkFont: thinkFont,
                    streaming: false,
                    lightweightBodies: true,
                    refreshActions: false
                )
                bindNativeBodyLayout(
                    hasThinking: hasThinking,
                    hasSearch: hasSearch,
                    hasImage: !imageViewMsg.isHidden
                )
            }
            return
        }
        paintOpenHistoryBody(with: message, layoutWidth: layoutWidth)
    }

    private func paintOpenHistoryBody(with message: ChatMessage, layoutWidth: CGFloat) {
        showsImageInBubble = message.showsImageInChat
        let c = DSTheme.c
        let font = SettingsManager.shared.chatBodyFontSize
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        roleLabel.isHidden = true
        roleLabel.text = nil
        applyMessageImages(to: message, deferHeavyRender: false)
        let hasImage = !imageViewMsg.isHidden
        hasThinking = !message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hasSearch = message.showsProcessChrome
        deferredNativeBind = DeferredNativeBind(
            message: message,
            hasThinking: hasThinking,
            hasSearch: hasSearch,
            hasImage: hasImage,
            font: font,
            colors: c,
            layoutWidth: layoutWidth
        )
        guard !message.content.isEmpty else {
            applyAssistantChrome(
                message: message,
                colors: c,
                thinkFont: thinkFont,
                streaming: false,
                lightweightBodies: true
            )
            updateRenderDebugOverlay()
            return
        }
        applyAssistantChrome(
            message: message,
            colors: c,
            thinkFont: thinkFont,
            streaming: false,
            lightweightBodies: true,
            refreshActions: false
        )
        paintOpenNativeBody(
            message: message,
            hasThinking: hasThinking,
            hasSearch: hasSearch,
            hasImage: hasImage,
            font: font,
            colors: c,
            layoutWidth: layoutWidth
        )
        if cellDelegate?.messageCellShouldLayoutActionChromeNow(self) != false {
            ensureActionButtonsVisible(for: message, requireBodyAlignment: true)
        } else {
            refreshActionChrome(for: message, streaming: false, colors: c)
        }
        updateRenderDebugOverlay()
    }

    /// True when open can reveal the table — body has real pixels, not an empty shell.
    func hasSubstantialOpenBodyPaint(for message: ChatMessage) -> Bool {
        if hasVisibleNativePaint {
            return (nativeHeight?.constant ?? 0) > 36
        }
        return false
    }

    func forcePaintOpenTailBody(with message: ChatMessage, layoutWidth: CGFloat) {
        let c = DSTheme.c
        let font = SettingsManager.shared.chatBodyFontSize
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        let hasImage = !imageViewMsg.isHidden
        hasThinking = !message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hasSearch = message.showsProcessChrome
        deferredNativeBind = DeferredNativeBind(
            message: message,
            hasThinking: hasThinking,
            hasSearch: hasSearch,
            hasImage: hasImage,
            font: font,
            colors: c,
            layoutWidth: layoutWidth
        )
        applyAssistantChrome(
            message: message,
            colors: c,
            thinkFont: thinkFont,
            streaming: false,
            lightweightBodies: true
        )
        paintOpenNativeBody(
            message: message,
            hasThinking: hasThinking,
            hasSearch: hasSearch,
            hasImage: hasImage,
            font: font,
            colors: c,
            layoutWidth: layoutWidth
        )
        ensureActionButtonsVisible(for: message, requireBodyAlignment: true)
        updateRenderDebugOverlay()
    }

    /// Sync native on open — disables async layer draw so the first frame has pixels.
    private func paintOpenNativeBody(message: ChatMessage,
                                     hasThinking: Bool,
                                     hasSearch: Bool,
                                     hasImage: Bool,
                                     font: CGFloat,
                                     colors: ThemeColors,
                                     layoutWidth: CGFloat) {
        let scrollFrozen = cellDelegate?.messageCellShouldFreezeHeight(self) == true
        nativeRenderView.layer.drawsAsynchronously = false
        configureNative(
            message: message,
            hasThinking: hasThinking,
            hasSearch: hasSearch,
            hasImage: hasImage,
            font: font,
            colors: colors,
            layoutWidth: layoutWidth,
            allowDefer: scrollFrozen
        )
        if scrollFrozen {
            return
        }
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        nativeRenderView.layer.displayIfNeeded()
    }

    /// During scroll-freeze with inflated UITableView rows, keep action chrome under the column — not cell bottom.
    func pinActionRowBelowColumnForScrollFreeze(_ pinned: Bool) {
        guard actionRowPinnedBelowColumn != pinned else { return }
        actionRowPinnedBelowColumn = pinned
        actionRowBottomToContent.isActive = !pinned
    }

    /// Keep 复制/重跑/分叉 visible on committed rows while scroll-frozen — no layoutIfNeeded.
    func showCommittedActionIconsDuringScroll(for message: ChatMessage) {
        guard message.id == messageID || messageID.isEmpty else { return }
        guard Self.shouldShowActionButtons(for: message, streaming: false) else { return }
        guard hasVisibleBodyPaint else { return }
        guard !hasVisibleActionButtons else { return }
        paintActionIconsWithoutLayout(for: message, colors: cachedThemeColors ?? DSTheme.c)
    }

    /// Scroll-frozen row entering view: bind cached native + chrome without full configure teardown.
    func primeFrozenScrollAssistant(with message: ChatMessage, layoutWidth: CGFloat) {
        configureWhileScrolling(message: message, layoutWidth: layoutWidth)
    }

    func syncThinkingPresentation(with message: ChatMessage, layoutWidth: CGFloat) {
        guard messageID == message.id else { return }
        preferredLayoutWidth = layoutWidth
        let c = DSTheme.c
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        cachedThinkingFontSize = thinkFont
        cachedThemeColors = c
        let think = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedReasoningText = message.reasoningContent
        // Agent timeline owns chrome (Cursor-style). Never re-paint 「已深度思考」on top.
        if Self.shouldSuppressThinkingChrome(for: message) {
            hasThinking = false
            setThinking(visible: false, expanded: false)
            return
        }
        hasThinking = !think.isEmpty
        guard hasThinking else {
            setThinking(visible: false, expanded: false)
            return
        }
        thinkingExpanded = false
        populateThinkingBody(expanded: false, colors: c, thinkFont: thinkFont)
        setThinking(visible: true, expanded: false)
        let title = (message.isStreaming || streamingPresentation) ? "思考中…" : "已深度思考"
        applyChromeHeaderTitle(thinkingHeader, title: title, color: c.textSecondary)
        updateThinkingHeaderInteraction(messageIsStreaming: message.isStreaming)
    }

    /// Workspace agent turn: one process chrome, no stacked thinking strip.
    private static func shouldSuppressThinkingChrome(for message: ChatMessage) -> Bool {
        if message.hasAgentProcess { return true }
        guard StudyAgentMode.isAgentProductEnabled else { return false }
        guard let conv = ConversationStore.shared.currentConversation else { return false }
        return conv.messages.contains {
            $0.id != message.id
                && ($0.agentProcessPhase == .running || $0.agentProcessPhase == .waitingUser)
        }
    }

    private func updateThinkingHeaderInteraction(messageIsStreaming: Bool) {
        guard hasThinking else {
            thinkingHeader.isUserInteractionEnabled = false
            return
        }
        let hasBody = !cachedReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        thinkingHeader.isEnabled = true
        thinkingHeader.isUserInteractionEnabled = hasBody
    }

    func syncSearchPresentation(with message: ChatMessage, layoutWidth: CGFloat, pairedUser: ChatMessage? = nil) {
        guard messageID == message.id else { return }
        if let pairedUser = pairedUser {
            pairedUserMessage = pairedUser
        }
        preferredLayoutWidth = layoutWidth
        let c = DSTheme.c
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        cachedThinkingFontSize = thinkFont
        cachedThemeColors = c
        let imageActivity = message.hasImageTranscription
        let agentActivity = message.hasAgentProcess && !imageActivity
        let search: String
        if imageActivity {
            search = message.imageTranscriptionDisplayText(pairedUser: pairedUserMessage)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if agentActivity {
            search = message.agentProcessDisplayText
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            search = message.searchProcessContent
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        cachedSearchText = search
        cachedImageActivity = imageActivity
        cachedImageTranscriptionPhase = message.imageTranscriptionPhase
        if agentActivity {
            hasSearch = false
            setSearch(visible: false, expanded: false)
            paintAgentInterleavedFlow(message)
            setContentTops(hasThinking: false, hasSearch: false, hasImage: !imageViewMsg.isHidden)
            return
        }
        hasSearch = message.showsProcessChrome
        guard hasSearch else {
            setSearch(visible: false, expanded: false)
            return
        }
        searchExpanded = false
        if imageActivity {
            cachedSearchTitleCore = message.imageTranscriptionPhase.headerTitle
        } else {
            cachedSearchTitleCore = message.searchProcessSummaryTitle
        }
        // Keep finished / idle search chrome header-only — body opens via chrome viewer.
        populateSearchBody(expanded: false, colors: c, thinkFont: thinkFont)
        setSearch(visible: true, expanded: false)
        applyChromeHeaderTitle(searchHeader, title: cachedSearchTitleCore, color: c.textSecondary)
        updateSearchHeaderInteraction(messageIsStreaming: message.isStreaming)
    }

    /// Lightweight agent timeline paint — Cursor-style interleaved meta+prose (no chrome box).
    /// Returns true when the content height likely changed (host may beginUpdates).
    @discardableResult
    func syncAgentProcessPresentation(with message: ChatMessage,
                                      layoutWidth: CGFloat? = nil,
                                      liveOverlayText: String? = nil) -> Bool {
        guard messageID == message.id else { return false }
        if let layoutWidth = layoutWidth {
            preferredLayoutWidth = layoutWidth
        }
        let imageActivity = message.hasImageTranscription
        guard !imageActivity, message.hasAgentProcess else {
            if hasSearch, !message.showsProcessChrome {
                setSearch(visible: false, expanded: false)
                hasSearch = false
                syncAgentEditCards([])
                clearAgentTimeline()
                return true
            }
            return false
        }
        // Agent: never use the web-search rounded box — status lines sit in the body column.
        if !searchBox.isHidden || hasSearch {
            setSearch(visible: false, expanded: false)
            hasSearch = false
        }
        let beforeH = agentTimelineStack.bounds.height
        paintAgentInterleavedFlow(message, liveOverlayText: liveOverlayText)
        setContentTops(
            hasThinking: false,
            hasSearch: false,
            hasImage: !imageViewMsg.isHidden
        )
        contentView.layoutIfNeeded()
        return abs(agentTimelineStack.bounds.height - beforeH) > 1
            || !agentTimelineStack.isHidden
    }

    /// Keep the live meta shimmer sweeping without changing text (avoids jump / kills ◐ spinner).
    #if DEBUG
    /// Visual QA: force Explored / Thought expand without ConversationStore.
    func qaPaintAgentTimeline(
        message: ChatMessage,
        layoutWidth: CGFloat,
        exploreExpanded: Bool? = nil,
        thoughtExpandedIDs: Set<String> = []
    ) {
        messageID = message.id
        preferredLayoutWidth = layoutWidth
        if let exploreExpanded {
            // Force every known explore header the same way for gallery frames.
            agentExploreExpandOverride = [
                AgentTimelinePart.exploreHeaderID: exploreExpanded,
                "\(AgentTimelinePart.exploreHeaderID)-2": exploreExpanded,
                "\(AgentTimelinePart.exploreHeaderID)-3": exploreExpanded,
                "\(AgentTimelinePart.exploreHeaderID)-4": exploreExpanded
            ]
        }
        agentThoughtExpandedIDs = thoughtExpandedIDs
        paintAgentInterleavedFlow(message)
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
    }

    var qaIsAssistantLabelSuppressed: Bool {
        if assistantLabel.isHidden || assistantLabel.alpha < 0.05 { return true }
        let plainEmpty = assistantLabel.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let attrEmpty = (assistantLabel.attributedText?.length ?? 0) == 0
        return plainEmpty && attrEmpty
    }

    var qaAgentTimelineChildCount: Int {
        agentTimelineOrder.filter {
            $0 != AgentTimelinePart.exploreHeaderID && !$0.hasPrefix("card-")
                && $0 != AgentTimelinePart.liveID && !$0.hasPrefix("prose")
                && !$0.hasPrefix("ask-") && $0 != "current" && $0 != "waiting"
        }.count
    }

    func qaSizeToFittedHeight(minHeight: CGFloat = 80) {
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        let fitted = max(measuredContentHeight(), minHeight)
        var f = frame
        f.size.height = ceil(fitted)
        frame = f
        contentView.frame = bounds
        contentView.layoutIfNeeded()
    }
    #endif

    func keepAgentLiveShimmerAlive() {
        if let shimmer = agentLiveShimmerLabel {
            shimmer.setShimmerEnabled(true)
            return
        }
        // Prefer live Thinking row; else last meta shimmer in the stack.
        if let live = agentTimelineViewsByID[AgentTimelinePart.liveID] as? ConnectsShimmerLabel {
            live.setShimmerEnabled(true)
            agentLiveShimmerLabel = live
            return
        }
        if let overlay = agentTimelineViewsByID["overlay"] as? ConnectsShimmerLabel {
            overlay.setShimmerEnabled(true)
            agentLiveShimmerLabel = overlay
            return
        }
        for id in agentTimelineOrder.reversed() {
            if let s = agentTimelineViewsByID[id] as? ConnectsShimmerLabel {
                s.setShimmerEnabled(true)
                agentLiveShimmerLabel = s
                return
            }
        }
    }

    /// Cursor composer: Explored group + indented Thought/Read/Grep + prose.
    private func paintAgentInterleavedFlow(_ message: ChatMessage, liveOverlayText: String? = nil) {
        hideNativeRender()
        // Resolve layout width before any preferredMaxLayoutWidth assignment (cold reopen).
        var layoutW = preferredLayoutWidth
        if layoutW < 1 {
            layoutW = max(column.bounds.width, bounds.width - 32, contentView.bounds.width - 32, 120)
            preferredLayoutWidth = layoutW
        }
        applyAssistantLayoutWidth()
        syncAgentEditCards([])
        // Timeline owns the body — never dual-paint with assistantLabel (reopen overlap).
        assistantLabel.isHidden = true
        assistantLabel.attributedText = nil
        assistantLabel.text = nil
        assistantLabel.alpha = 0
        assistantLabel.preferredMaxLayoutWidth = layoutW
        agentTimelineStack.isHidden = false
        agentTimelineStack.alpha = 1
        agentTimelineStack.clipsToBounds = true

        let colors = cachedThemeColors ?? DSTheme.c
        cachedThemeColors = colors
        let bodySize = SettingsManager.shared.chatBodyFontSize
        let metaSize = cachedThinkingFontSize > 0
            ? cachedThinkingFontSize
            : SettingsManager.shared.chatThinkingFontSize
        let bodyFont = UIFont.systemFont(ofSize: bodySize)
        let metaFont = UIFont.systemFont(ofSize: metaSize)
        agentPaintLayoutWidth = layoutW

        let running = message.isStreaming || message.agentProcessPhase == .running
        let items = message.agentTimelinePaintItems(
            liveOverlay: liveOverlayText,
            defaultExploreExpanded: running,
            exploreExpandOverrides: agentExploreExpandOverride
        )

        let desiredIDs = Set(items.map(\.id))
        for id in agentTimelineOrder where !desiredIDs.contains(id) {
            if let v = agentTimelineViewsByID.removeValue(forKey: id) {
                if let s = v as? ConnectsShimmerLabel { s.setShimmerEnabled(false) }
                agentTimelineStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
        }
        agentTimelineOrder = agentTimelineOrder.filter { desiredIDs.contains($0) }

        // Do NOT blanket-disable live shimmer every paint (that flashed the whole page).
        var nextLive: ConnectsShimmerLabel?

        for (idx, item) in items.enumerated() {
            let wantThoughtExpanded = agentThoughtExpandedIDs.contains(item.id)
            if let existing = agentTimelineViewsByID[item.id] {
                let needsReplace = agentTimelineViewNeedsReplace(existing, for: item)
                if needsReplace {
                    if let s = existing as? ConnectsShimmerLabel { s.setShimmerEnabled(false) }
                    agentTimelineStack.removeArrangedSubview(existing)
                    existing.removeFromSuperview()
                    agentTimelineViewsByID.removeValue(forKey: item.id)
                } else {
                    updateAgentTimelineView(
                        existing,
                        item: item,
                        bodyFont: bodyFont,
                        metaFont: metaFont,
                        colors: colors,
                        layoutW: layoutW,
                        thoughtExpanded: wantThoughtExpanded
                    )
                    if item.shimmer, let s = agentShimmer(in: existing) {
                        nextLive = s
                    }
                    if let arrangedIdx = agentTimelineStack.arrangedSubviews.firstIndex(of: existing),
                       arrangedIdx != idx {
                        agentTimelineStack.removeArrangedSubview(existing)
                        agentTimelineStack.insertArrangedSubview(
                            existing,
                            at: min(idx, agentTimelineStack.arrangedSubviews.count)
                        )
                    }
                    continue
                }
            }
            let view = makeAgentTimelinePaintView(
                item: item,
                bodyFont: bodyFont,
                metaFont: metaFont,
                colors: colors,
                layoutW: layoutW,
                thoughtExpanded: wantThoughtExpanded
            )
            if item.shimmer, let s = agentShimmer(in: view) {
                nextLive = s
            }
            agentTimelineViewsByID[item.id] = view
            view.setContentHuggingPriority(.required, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
            agentTimelineStack.insertArrangedSubview(
                view,
                at: min(idx, agentTimelineStack.arrangedSubviews.count)
            )
        }
        agentTimelineOrder = items.map(\.id)

        if agentLiveShimmerLabel !== nextLive {
            if nextLive == nil {
                agentLiveShimmerLabel?.setShimmerEnabled(false)
            }
            agentLiveShimmerLabel = nextLive
            nextLive?.setShimmerEnabled(true)
        } else {
            nextLive?.setShimmerEnabled(true)
        }

        for view in agentTimelineStack.arrangedSubviews where view.tag != 7211 {
            view.setContentHuggingPriority(.required, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        ensureAgentTimelineStretchSpacer()

        pinTimelineToColumnContent()
        cachedSearchTitleCore = message.agentProcessSummaryTitle
        cachedSearchText = message.agentProcessDisplayText
    }

    /// Trailing low-hug spacer so oversized cell estimates expand below content,
    /// not between Thought / Read / Deleted rows.
    private func ensureAgentTimelineStretchSpacer() {
        let stretchID = "timeline-stretch"
        let spacer: UIView
        if let existing = agentTimelineViewsByID[stretchID] {
            spacer = existing
        } else {
            let v = UIView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.tag = 7211
            v.accessibilityIdentifier = stretchID
            v.isUserInteractionEnabled = false
            v.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
            v.setContentCompressionResistancePriority(UILayoutPriority(1), for: .vertical)
            agentTimelineViewsByID[stretchID] = v
            spacer = v
        }
        if agentTimelineStack.arrangedSubviews.last === spacer { return }
        if spacer.superview != nil {
            agentTimelineStack.removeArrangedSubview(spacer)
            spacer.removeFromSuperview()
        }
        agentTimelineStack.addArrangedSubview(spacer)
    }

    private func agentTimelineViewNeedsReplace(_ existing: UIView, for item: AgentTimelinePaintItem) -> Bool {
        switch item.role {
        case .exploreHeader:
            return existing.viewWithTag(7201) == nil
        case .exploreChild where item.stepKind == .thought && !item.detail.isEmpty:
            return existing.viewWithTag(7202) == nil
        case .live:
            return !(existing is ConnectsShimmerLabel)
        case .prose, .ask:
            return !(existing is UILabel) || existing.viewWithTag(7201) != nil || existing.tag == 7210
        case .card:
            return existing.viewWithTag(7101) == nil
        case .planned, .exploreChild:
            if existing.tag == 7210 { return false }
            return !(existing is ConnectsShimmerLabel)
        }
    }

    private func agentShimmer(in view: UIView) -> ConnectsShimmerLabel? {
        if let s = view as? ConnectsShimmerLabel { return s }
        for sub in view.subviews {
            if let found = agentShimmer(in: sub) { return found }
        }
        return nil
    }

    private func updateAgentTimelineView(
        _ existing: UIView,
        item: AgentTimelinePaintItem,
        bodyFont: UIFont,
        metaFont: UIFont,
        colors: ThemeColors,
        layoutW: CGFloat,
        thoughtExpanded: Bool
    ) {
        switch item.role {
        case .exploreHeader:
            if let btn = existing.viewWithTag(7201) as? UIButton {
                btn.setTitle(item.text, for: .normal)
                btn.setTitleColor(colors.textSecondary, for: .normal)
                btn.accessibilityIdentifier = item.id
            }
        case .exploreChild where item.stepKind == .thought && !item.detail.isEmpty:
            if let btn = existing.viewWithTag(7202) as? UIButton {
                let base = item.text
                    .replacingOccurrences(of: " ⌵", with: "")
                    .replacingOccurrences(of: " ›", with: "")
                btn.setTitle(base + (thoughtExpanded ? " ⌵" : " ›"), for: .normal)
            }
            if let body = existing.viewWithTag(7203) as? UILabel {
                body.text = item.detail
                body.isHidden = !thoughtExpanded
                body.preferredMaxLayoutWidth = max(layoutW - Self.agentExploreChildIndent, 1)
            }
        case .card:
            if let label = existing.viewWithTag(7101) as? UILabel {
                label.text = "▾  \(item.text)"
            }
        case .prose, .ask:
            if let label = existing as? UILabel {
                label.font = item.role == .ask
                    ? UIFont.systemFont(ofSize: bodyFont.pointSize, weight: .medium)
                    : bodyFont
                label.textColor = colors.textPrimary
                label.preferredMaxLayoutWidth = layoutW
                label.numberOfLines = 0
                if label.text != item.text { label.text = item.text }
            }
        case .live, .planned, .exploreChild:
            if let shimmer = agentShimmer(in: existing) {
                shimmer.font = metaFont
                shimmer.textColor = colors.textSecondary
                shimmer.preferredMaxLayoutWidth = item.indented
                    ? max(layoutW - Self.agentExploreChildIndent, 1)
                    : layoutW
                shimmer.numberOfLines = 0
                if shimmer.text != item.text { shimmer.text = item.text }
                shimmer.setShimmerEnabled(item.shimmer)
            }
        }
    }

    private func makeAgentTimelinePaintView(
        item: AgentTimelinePaintItem,
        bodyFont: UIFont,
        metaFont: UIFont,
        colors: ThemeColors,
        layoutW: CGFloat,
        thoughtExpanded: Bool
    ) -> UIView {
        switch item.role {
        case .exploreHeader:
            return makeExploreHeaderRow(item: item, metaFont: metaFont, colors: colors, layoutW: layoutW)
        case .exploreChild where item.stepKind == .thought && !item.detail.isEmpty:
            return makeThoughtChildRow(
                item: item,
                metaFont: metaFont,
                colors: colors,
                layoutW: layoutW,
                expanded: thoughtExpanded
            )
        case .card:
            // Resolve full card when possible; header text is already in item.text.
            let stub = AgentEditCard(fileName: item.text, additions: 0, deletions: 0)
            let box = makeAgentEditCardView(stub, colors: colors)
            if let btn = box.viewWithTag(7101) as? UIButton {
                btn.setTitle("  \(item.text)", for: .normal)
            }
            return box
        case .prose, .ask:
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.accessibilityIdentifier = item.id
            label.font = item.role == .ask
                ? UIFont.systemFont(ofSize: bodyFont.pointSize, weight: .medium)
                : bodyFont
            label.textColor = colors.textPrimary
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.preferredMaxLayoutWidth = layoutW
            label.text = item.text
            label.clipsToBounds = true
            label.setContentHuggingPriority(.required, for: .vertical)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            return label
        case .live, .planned, .exploreChild:
            let label = ConnectsShimmerLabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.accessibilityIdentifier = item.id
            label.font = metaFont
            label.textColor = colors.textSecondary
            label.highlightColor = UIColor.white.withAlphaComponent(0.92)
            label.numberOfLines = 0
            label.preferredMaxLayoutWidth = item.indented
                ? max(layoutW - Self.agentExploreChildIndent, 1)
                : layoutW
            label.text = item.text
            label.setShimmerEnabled(item.shimmer)
            label.clipsToBounds = true
            if item.indented {
                return wrapIndented(label, indent: Self.agentExploreChildIndent)
            }
            label.setContentHuggingPriority(.required, for: .vertical)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            return label
        }
    }

    private func wrapIndented(_ inner: UIView, indent: CGFloat) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.tag = 7210
        inner.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: wrap.topAnchor),
            inner.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: indent),
            inner.trailingAnchor.constraint(equalTo: wrap.trailingAnchor)
        ])
        wrap.setContentHuggingPriority(.required, for: .vertical)
        wrap.setContentCompressionResistancePriority(.required, for: .vertical)
        return wrap
    }

    private func makeExploreHeaderRow(
        item: AgentTimelinePaintItem,
        metaFont: UIFont,
        colors: ThemeColors,
        layoutW: CGFloat
    ) -> UIView {
        let btn = UIButton(type: .custom)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.tag = 7201
        btn.accessibilityIdentifier = item.id
        btn.isUserInteractionEnabled = true
        btn.contentHorizontalAlignment = .left
        btn.connectsSetContentInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        btn.titleLabel?.font = metaFont
        btn.titleLabel?.numberOfLines = 1
        btn.setTitle(item.text, for: .normal)
        btn.setTitleColor(colors.textSecondary, for: .normal)
        btn.addTarget(self, action: #selector(toggleAgentExploreGroup(_:)), for: .touchUpInside)
        btn.setContentHuggingPriority(.required, for: .vertical)
        btn.setContentCompressionResistancePriority(.required, for: .vertical)
        btn.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        _ = layoutW
        return btn
    }

    private func makeThoughtChildRow(
        item: AgentTimelinePaintItem,
        metaFont: UIFont,
        colors: ThemeColors,
        layoutW: CGFloat,
        expanded: Bool
    ) -> UIView {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 4
        stack.alignment = .fill

        // .custom avoids system button leading inset drift vs Read shimmer rows.
        let btn = UIButton(type: .custom)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.tag = 7202
        btn.accessibilityIdentifier = item.id
        btn.isUserInteractionEnabled = true
        btn.contentHorizontalAlignment = .left
        btn.connectsSetContentInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        btn.titleLabel?.font = metaFont
        btn.titleLabel?.textAlignment = .left
        let chevron = expanded ? " ⌵" : " ›"
        btn.setTitle(item.text + chevron, for: .normal)
        btn.setTitleColor(colors.textSecondary, for: .normal)
        btn.addTarget(self, action: #selector(toggleAgentThought(_:)), for: .touchUpInside)
        btn.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

        let body = UILabel()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.tag = 7203
        body.font = metaFont
        body.textColor = colors.textSecondary
        body.numberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        body.preferredMaxLayoutWidth = max(layoutW - Self.agentExploreChildIndent, 1)
        body.text = item.detail
        body.isHidden = !expanded

        stack.addArrangedSubview(btn)
        stack.addArrangedSubview(body)
        return wrapIndented(stack, indent: Self.agentExploreChildIndent)
    }

    @objc private func toggleAgentExploreGroup(_ sender: UIButton) {
        let headerID = sender.accessibilityIdentifier ?? AgentTimelinePart.exploreHeaderID
        guard !headerID.isEmpty else { return }
        guard !messageID.isEmpty,
              let msg = ConversationStore.shared.currentConversation?.messages
                .first(where: { $0.id == messageID }) else { return }
        let running = msg.isStreaming || msg.agentProcessPhase == .running
        let current = agentExploreExpandOverride[headerID] ?? running
        agentExploreExpandOverride[headerID] = !current
        repaintAgentTimelineFromStore()
    }

    @objc private func toggleAgentThought(_ sender: UIButton) {
        let id = sender.accessibilityIdentifier ?? ""
        guard !id.isEmpty else { return }
        if agentThoughtExpandedIDs.contains(id) {
            agentThoughtExpandedIDs.remove(id)
        } else {
            agentThoughtExpandedIDs.insert(id)
        }
        repaintAgentTimelineFromStore()
    }

    private func repaintAgentTimelineFromStore() {
        guard !messageID.isEmpty,
              let msg = ConversationStore.shared.currentConversation?.messages
                .first(where: { $0.id == messageID }) else { return }
        paintAgentInterleavedFlow(msg)
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        scheduleMeasuredHeightNotify(for: messageID)
        cellDelegate?.messageCellDidPaintContent(self)
    }

    private func clearAgentTimeline() {
        agentLiveShimmerLabel?.setShimmerEnabled(false)
        agentLiveShimmerLabel = nil
        for v in agentTimelineStack.arrangedSubviews {
            if let s = v as? ConnectsShimmerLabel {
                s.setShimmerEnabled(false)
            }
            agentTimelineStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        agentTimelineViewsByID.removeAll()
        agentTimelineOrder = []
        agentTimelineStack.isHidden = true
        columnBottomToTimeline.isActive = false
        // Visibility of assistantLabel is owned by configure / paint — forcing
        // alpha=1 here flashed plain body under the agent timeline for a frame.
    }

    // Legacy stub removed — paint uses makeAgentTimelinePaintView.

    private func syncAgentEditCards(_ cards: [AgentEditCard]) {
        let existing = agentEditCardsStack.arrangedSubviews
        for v in existing { v.removeFromSuperview() }
        guard !cards.isEmpty else {
            agentEditCardsStack.isHidden = true
            agentEditCardsHeight.constant = 0
            return
        }
        agentEditCardsStack.isHidden = false
        let colors = cachedThemeColors ?? DSTheme.c
        var totalH: CGFloat = 0
        for card in cards.suffix(4) {
            let view = makeAgentEditCardView(card, colors: colors)
            agentEditCardsStack.addArrangedSubview(view)
            totalH += MessageChromeStyle.collapsedRowHeight
        }
        agentEditCardsHeight.constant = totalH + CGFloat(max(0, min(cards.count, 4) - 1) * 8)
    }

    private func makeAgentEditCardView(_ card: AgentEditCard, colors: ThemeColors) -> UIView {
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.backgroundColor = colors.surface.withAlphaComponent(MessageChromeStyle.surfaceAlpha)
        box.layer.cornerRadius = MessageChromeStyle.cornerRadius
        box.layer.borderWidth = MessageChromeStyle.borderWidth
        box.clipsToBounds = true
        box.accessibilityIdentifier = card.documentID

        let header = UIButton(type: .system)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.contentHorizontalAlignment = .left
        header.titleLabel?.font = MessageChromeStyle.headerFont
        header.setTitleColor(colors.textPrimary, for: .normal)
        header.setTitle("  \(card.headerLine)", for: .normal)
        header.tag = 7101
        header.contentEdgeInsets = UIEdgeInsets(
            top: 0,
            left: MessageChromeStyle.horizontalPadding,
            bottom: 0,
            right: MessageChromeStyle.horizontalPadding
        )

        let body = UILabel()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        body.numberOfLines = 3
        body.textColor = colors.textSecondary
        body.tag = 7102
        body.isHidden = true
        var lines: [String] = []
        if !card.snippetMinus.isEmpty {
            lines.append(card.snippetMinus.split(separator: "\n").prefix(2).map { "− \($0)" }.joined(separator: "\n"))
        }
        if !card.snippetPlus.isEmpty {
            lines.append(card.snippetPlus.split(separator: "\n").prefix(2).map { "+ \($0)" }.joined(separator: "\n"))
        }
        body.text = lines.joined(separator: "\n")

        box.addSubview(header)
        box.addSubview(body)
        let collapsedH = header.heightAnchor.constraint(equalToConstant: MessageChromeStyle.headerHeight)
        let bodyBottom = body.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8)
        bodyBottom.isActive = false
        let headerBottom = header.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: box.topAnchor),
            header.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            collapsedH,
            headerBottom,
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: MessageChromeStyle.horizontalPadding),
            body.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -MessageChromeStyle.horizontalPadding),
            box.heightAnchor.constraint(greaterThanOrEqualToConstant: MessageChromeStyle.headerHeight)
        ])

        header.addTarget(self, action: #selector(agentEditCardHeaderTapped(_:)), for: .touchUpInside)
        // Stash constraints via associated tags on the button for toggle.
        objc_setAssociatedObject(header, AssociatedKeys.editCardHeaderBottom, headerBottom, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(header, AssociatedKeys.editCardBodyBottom, bodyBottom, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(header, AssociatedKeys.editCardTitle, card.headerLine as NSString, .OBJC_ASSOCIATION_COPY_NONATOMIC)

        return box
    }

    private struct AssociatedKeys {
        static let editCardHeaderBottom = UnsafeRawPointer(bitPattern: 7_101)!
        static let editCardBodyBottom = UnsafeRawPointer(bitPattern: 7_102)!
        static let editCardTitle = UnsafeRawPointer(bitPattern: 7_103)!
    }

    @objc private func agentEditCardHeaderTapped(_ sender: UIButton) {
        guard let box = sender.superview,
              let body = box.viewWithTag(7102) as? UILabel,
              let headerBottom = objc_getAssociatedObject(sender, AssociatedKeys.editCardHeaderBottom) as? NSLayoutConstraint,
              let bodyBottom = objc_getAssociatedObject(sender, AssociatedKeys.editCardBodyBottom) as? NSLayoutConstraint,
              let title = objc_getAssociatedObject(sender, AssociatedKeys.editCardTitle) as? String
        else { return }
        let expanding = body.isHidden
        body.isHidden = !expanding
        headerBottom.isActive = !expanding
        bodyBottom.isActive = expanding
        sender.setTitle(expanding ? "▾  \(title)" : "  \(title)", for: .normal)
        UIView.animate(withDuration: 0.18) {
            box.superview?.layoutIfNeeded()
        }
    }

    private func updateSearchHeaderInteraction(messageIsStreaming: Bool) {
        guard hasSearch else {
            searchHeader.isUserInteractionEnabled = false
            return
        }
        let body = cachedSearchText.isEmpty ? cachedSearchTitleCore : cachedSearchText
        let hasBody = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        searchHeader.isEnabled = true
        searchHeader.isUserInteractionEnabled = hasBody && !imageTranscriptionFailed
    }

    func needsNativeRepaint(at layoutWidth: CGFloat) -> Bool {
        guard hasVisibleNativePaint else { return false }
        return abs(lastNativeLayoutWidth - nativeLayoutWidth(for: layoutWidth)) > 1
    }

    func ensureNativeLayoutWidth(_ layoutWidth: CGFloat) {
        guard !nativeRenderView.isHidden,
              let message = nativeMessageForRemeasure,
              abs(nativeLayoutWidth(for: layoutWidth) - lastNativeLayoutWidth) > 1 else { return }
        configureNative(
            message: message,
            hasThinking: hasThinking,
            hasSearch: hasSearch,
            hasImage: !imageViewMsg.isHidden,
            font: SettingsManager.shared.chatBodyFontSize,
            colors: DSTheme.c,
            layoutWidth: layoutWidth
        )
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if cellDelegate?.messageCellShouldPreserveOpenPaint(self) == true,
           hasVisibleNativePaint {
            // Height-only relayout during open — never wipe native mid-pipeline.
            lastChromeActionKey = ""
            lastActionRowSignature = ""
            return
        }
        if cellDelegate?.messageCellShouldFreezeHeight(self) == true {
            // Keep messageID + native paint during scroll reuse so the same row
            // can skip teardown when it scrolls back without a full reconfigure.
            lastChromeActionKey = ""
            lastActionRowSignature = ""
            return
        }
        messageID = ""
        pairedUserMessage = nil
        streamingPresentation = false
        heightNotifyWork?.cancel()
        heightNotifyWork = nil
        nativeMessageForRemeasure = nil
        lastNativeLayoutWidth = 0
        assistantLabel.attributedText = nil
        assistantLabel.text = nil
        thinkingBody.text = nil
        searchBody.attributedText = nil
        searchBody.text = nil
        thinkingLivePreviewMode = false
        searchLivePreviewMode = false
        clearMessageImages()
        cachedImages = []
        showsImageInBubble = false
        showActions(false)
        setThinking(visible: false, expanded: false)
        setSearch(visible: false, expanded: false)
        syncAgentEditCards([])
        clearAgentTimeline()
        agentExploreExpandOverride.removeAll()
        agentThoughtExpandedIDs.removeAll()
        agentPaintLayoutWidth = 0
        assistantLabel.isHidden = true
        hideNativeRender()
        cachedImage = nil
        imageTranscriptionFailed = false
        column.layer.borderWidth = 0
        nativeRenderView.layer.borderWidth = 0
        deferredNativeBind = nil
        lastActionRowSignature = ""
        lastChromeActionKey = ""
        configuredPreferredHeight = nil
        cachedReasoningText = ""
        cachedSearchText = ""
        cachedSearchTitleCore = ""
        cachedImageActivity = false
        cachedThemeColors = nil
        preferredLayoutWidth = 0
        cachedThinkingExpandDelta = 0
        cachedSearchExpandDelta = 0
        thinkingBody.attributedText = nil
        thinkingBody.text = nil
    }

    private func applyChromeHeaderTitle(_ button: UIButton, title: String, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.chromeHeaderFont,
            .foregroundColor: color
        ]
        let attributed = NSAttributedString(string: title, attributes: attrs)
        button.setAttributedTitle(attributed, for: .normal)
        button.setAttributedTitle(attributed, for: .disabled)
        button.setAttributedTitle(attributed, for: .highlighted)
        button.titleLabel?.font = Self.chromeHeaderFont
    }

    private var cachedImage: UIImage?
    private var cachedImages: [UIImage] = []
    private var showsImageInBubble = false

    func setCachedImage(_ image: UIImage?) {
        cachedImage = image
        cachedImages = image.map { [$0] } ?? []
    }

    func setCachedImages(_ images: [UIImage]?) {
        cachedImages = images ?? []
        cachedImage = cachedImages.first
    }

    private func presentMessageImages(_ images: [UIImage]) {
        guard !images.isEmpty else {
            clearMessageImages()
            return
        }
        imageViewMsg.isHidden = false
        imageHeight.constant = 160
        if images.count > 1 {
            imageViewMsg.image = nil
            imageStripView.setImages(images)
            imageStripView.isHidden = false
        } else {
            imageStripView.clear()
            imageStripView.isHidden = true
            imageViewMsg.image = images[0]
        }
    }

    private func clearMessageImages() {
        imageViewMsg.image = nil
        imageViewMsg.isHidden = true
        imageHeight.constant = 0
        imageStripView.clear()
        imageStripView.isHidden = true
    }

    private func applyMessageImages(to message: ChatMessage, deferHeavyRender: Bool) {
        guard message.showsImageInChat else {
            clearMessageImages()
            cachedImage = nil
            cachedImages = []
            return
        }
        let expectedCount = max(1, message.imageCount)
        let usableCache = cachedImages.count == expectedCount && !cachedImages.isEmpty
        let images: [UIImage]
        if deferHeavyRender {
            images = usableCache ? cachedImages : []
        } else if usableCache {
            images = cachedImages
        } else {
            images = message.allImageBase64.compactMap { ImageAttachmentHelper.thumbnail(from: $0) }
        }
        presentMessageImages(images)
    }

    func applyCachedImageIfNeeded() {
        guard showsImageInBubble else { return }
        let images = !cachedImages.isEmpty ? cachedImages : (cachedImage.map { [$0] } ?? [])
        guard !images.isEmpty else { return }
        presentMessageImages(images)
        scheduleMeasuredHeightNotify(for: messageID)
    }

    /// Row-height authority when UITableView is still clipping the expanded chrome.
    func projectedColumnHeight(for message: ChatMessage, layoutWidth: CGFloat) -> CGFloat {
        if let estimated = AssistantMessageLayout.estimatedColumnContentHeight(
            for: message,
            layoutWidth: layoutWidth,
            isLastRow: false,
            allowSyncLayout: true,
            pairedUser: pairedUserMessage
        ), estimated > 40 {
            return estimated
        }
        return measuredColumnHeight()
    }

    func refreshRenderDebugOverlay() {
        updateRenderDebugOverlay()
    }

    func applyDeferredNativeRenderIfNeeded(suppressHeightNotify: Bool = false) {
        guard let bind = deferredNativeBind, bind.message.id == messageID else { return }
        deferredNativeBind = nil
        configureNative(
            message: bind.message,
            hasThinking: bind.hasThinking,
            hasSearch: bind.hasSearch,
            hasImage: bind.hasImage,
            font: bind.font,
            colors: bind.colors,
            layoutWidth: bind.layoutWidth,
            allowDefer: false
        )
        nativeRenderView.flushPendingRasterizeIfNeeded()
        if cellDelegate?.messageCellShouldLayoutActionChromeNow(self) != false {
            ensureActionButtonsVisible(for: bind.message)
        } else {
            refreshActionChrome(
                for: bind.message,
                streaming: false,
                colors: bind.colors
            )
        }
        if !suppressHeightNotify {
            scheduleMeasuredHeightNotify(for: messageID)
        }
    }

    /// Settle path: paint bitmaps skipped while `suppressSyncRasterize` was on.
    func flushDeferredNativeRasterizeIfNeeded() {
        nativeRenderView.flushPendingRasterizeIfNeeded()
    }

    /// Cached expand delta — avoids boundingRect on the tap path when prewarm ran.
    func thinkingExpandHeightDelta(layoutWidth: CGFloat) -> CGFloat {
        if cachedThinkingExpandDelta > 1 { return cachedThinkingExpandDelta }
        let delta = AssistantMessageLayout.thinkingExpandHeightDelta(
            reasoning: cachedReasoningText,
            messageID: messageID,
            layoutWidth: layoutWidth
        )
        cachedThinkingExpandDelta = delta
        return delta
    }

    func searchExpandHeightDelta(layoutWidth: CGFloat) -> CGFloat {
        if cachedSearchExpandDelta > 1 { return cachedSearchExpandDelta }
        let body = cachedSearchText.isEmpty ? cachedSearchTitleCore : cachedSearchText
        let delta = AssistantMessageLayout.searchExpandHeightDelta(
            text: body,
            messageID: messageID,
            layoutWidth: layoutWidth
        )
        cachedSearchExpandDelta = delta
        return delta
    }

    func chromeExpandHeightDelta(kind: MessageExpandableChromeKind, layoutWidth: CGFloat) -> CGFloat {
        switch kind {
        case .thinking:
            return thinkingExpandHeightDelta(layoutWidth: layoutWidth)
        case .search:
            return searchExpandHeightDelta(layoutWidth: layoutWidth)
        }
    }

    func finishChromeToggleLayout() {
        contentView.setNeedsLayout()
    }

    func configure(with message: ChatMessage, preferredHeight: CGFloat?, layoutWidth: CGFloat) {
        configure(with: message, preferredHeight: preferredHeight, layoutWidth: layoutWidth, pairedUser: nil)
    }

    func configure(with message: ChatMessage, preferredHeight: CGFloat?, layoutWidth: CGFloat, pairedUser: ChatMessage?) {
        let previousMessageID = messageID
        pairedUserMessage = pairedUser
        let freezeLayout = cellDelegate?.messageCellShouldFreezeHeight(self) == true
        studyContentLeadingGutter = cellDelegate?.messageCellStudyContentLeadingGutter() ?? 0
        messageID = message.id
        preferredLayoutWidth = layoutWidth
        configuredPreferredHeight = preferredHeight

        guard message.role == .assistant else { return }
        showsImageInBubble = message.showsImageInChat

        if !message.isStreaming {
            primeFinishedActionChromeSlot(for: message)
        }

        // Same row already painted native: skip teardown — kills Q↔A re-render flash.
        if !message.isStreaming,
           previousMessageID == message.id,
           hasVisibleNativePaint,
           freezeLayout,
           abs(lastNativeLayoutWidth - nativeLayoutWidth(for: layoutWidth)) < 1 {
            if !assistantChromeMatches(message) {
                let thinkFont = SettingsManager.shared.chatThinkingFontSize
                applyAssistantChrome(
                    message: message,
                    colors: DSTheme.c,
                    thinkFont: thinkFont,
                    streaming: false,
                    lightweightBodies: true,
                    refreshActions: false
                )
                bindNativeBodyLayout(
                    hasThinking: hasThinking,
                    hasSearch: hasSearch,
                    hasImage: !imageViewMsg.isHidden
                )
            }
            updateThinkingHeaderInteraction(messageIsStreaming: message.isStreaming)
            updateSearchHeaderInteraction(messageIsStreaming: message.isStreaming)
            updateRenderDebugOverlay()
            return
        }

        // Mid-scroll reuse into a different assistant: use cached native when warm.
        if !message.isStreaming, freezeLayout, previousMessageID != message.id {
            configureWhileScrolling(message: message, layoutWidth: layoutWidth)
            return
        }

        let deferHeavyRender = cellDelegate?.messageCellShouldDeferHeavyRender(self) == true
        streamingPresentation = message.isStreaming
        let c = DSTheme.c
        let font = SettingsManager.shared.chatBodyFontSize
        let thinkFont = SettingsManager.shared.chatThinkingFontSize

        roleLabel.isHidden = true
        roleLabel.text = nil

        applyMessageImages(to: message, deferHeavyRender: deferHeavyRender)
        let hasImage = !imageViewMsg.isHidden
        hasThinking = !message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hasSearch = message.showsProcessChrome
        deferredNativeBind = DeferredNativeBind(
            message: message,
            hasThinking: hasThinking,
            hasSearch: hasSearch,
            hasImage: hasImage,
            font: font,
            colors: c,
            layoutWidth: layoutWidth
        )

        applyAssistantChrome(
            message: message,
            colors: c,
            thinkFont: thinkFont,
            streaming: message.isStreaming,
            lightweightBodies: deferHeavyRender,
            refreshActions: message.isStreaming || message.content.isEmpty
        )

        let agentActivity = message.hasAgentProcess && !message.hasImageTranscription
        if agentActivity {
            // Timeline already painted in applyAssistantChrome — don't clobber with raw body.
            setContentTops(hasThinking: false, hasSearch: false, hasImage: hasImage)
        } else if message.isStreaming || message.content.isEmpty {
            clearAgentTimeline()
            hideNativeRender()
            applyAssistantLayoutWidth()
            assistantLabel.isHidden = false
            assistantLabel.alpha = 1
            // Hug content — never stretch the empty body into the UITableView's
            // allocated/estimated frame. That fill-loop scrolled tags off-screen
            // on first turn ("完全空白") and left a giant gap after finish.
            pinPlainBodyToColumnContent()
            setContentTops(hasThinking: hasThinking, hasSearch: hasSearch, hasImage: hasImage)
            if message.content.isEmpty && !hasThinking && !hasSearch {
                assistantLabel.attributedText = nil
                assistantLabel.textColor = c.textPrimary
                assistantLabel.font = UIFont.systemFont(ofSize: font)
                assistantLabel.text = nil
            } else if message.isStreaming {
                assistantLabel.attributedText = nil
                assistantLabel.textColor = c.textPrimary
                assistantLabel.font = UIFont.systemFont(ofSize: font)
                assistantLabel.text = message.content.isEmpty ? nil : message.chatDisplayBody
            } else if message.content.isEmpty, hasThinking || hasSearch {
                assistantLabel.attributedText = nil
                assistantLabel.textColor = c.textSecondary
                assistantLabel.font = UIFont.systemFont(ofSize: font)
                assistantLabel.text = hasThinking
                    ? "（思考完成，无正文。可点「重跑」。）"
                    : nil
            } else {
                assistantLabel.attributedText = nil
                assistantLabel.text = nil
            }
        } else {
            clearAgentTimeline()
            configureNative(
                message: message,
                hasThinking: hasThinking,
                hasSearch: hasSearch,
                hasImage: hasImage,
                font: font,
                colors: c,
                layoutWidth: layoutWidth,
                allowDefer: !deferHeavyRender
            )
        }
        if !message.isStreaming {
            ensureActionButtonsVisible(for: message)
        }
        updateRenderDebugOverlay()
    }

    /// Lightweight path for UITableView reuse while the finger is down.
    private func configureWhileScrolling(message: ChatMessage, layoutWidth: CGFloat) {
        streamingPresentation = false
        showsImageInBubble = message.showsImageInChat
        studyContentLeadingGutter = cellDelegate?.messageCellStudyContentLeadingGutter() ?? 0
        primeFinishedActionChromeSlot(for: message)
        let c = DSTheme.c
        let font = SettingsManager.shared.chatBodyFontSize
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        roleLabel.isHidden = true
        roleLabel.text = nil

        applyMessageImages(to: message, deferHeavyRender: true)
        let hasImage = !imageViewMsg.isHidden
        hasThinking = !message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hasSearch = message.showsProcessChrome

        if hasVisibleNativePaint,
           nativeMessageForRemeasure?.id == message.id,
           assistantChromeMatches(message),
           abs(lastNativeLayoutWidth - nativeLayoutWidth(for: layoutWidth)) < 1 {
            if Self.shouldShowActionButtons(for: message, streaming: false) {
                paintActionIconsWithoutLayout(for: message, colors: c)
            }
            updateThinkingHeaderInteraction(messageIsStreaming: false)
            updateSearchHeaderInteraction(messageIsStreaming: false)
            return
        }

        if assistantChromeMatches(message) {
            applyThinkingLayoutWidth()
        } else {
            applyAssistantChrome(
                message: message,
                colors: c,
                thinkFont: thinkFont,
                streaming: false,
                lightweightBodies: true,
                refreshActions: false
            )
        }

        deferredNativeBind = DeferredNativeBind(
            message: message,
            hasThinking: hasThinking,
            hasSearch: hasSearch,
            hasImage: hasImage,
            font: font,
            colors: c,
            layoutWidth: layoutWidth
        )
        // Warm native cache: bind cached layout (no sync layout). Cold cache: plain text body.
        configureNative(
            message: message,
            hasThinking: hasThinking,
            hasSearch: hasSearch,
            hasImage: hasImage,
            font: font,
            colors: c,
            layoutWidth: layoutWidth,
            allowDefer: true
        )
        if Self.shouldShowActionButtons(for: message, streaming: false) {
            paintActionIconsWithoutLayout(for: message, colors: c)
        }
        updateThinkingHeaderInteraction(messageIsStreaming: false)
        updateSearchHeaderInteraction(messageIsStreaming: false)
    }

    private func assistantChromeMatches(_ message: ChatMessage) -> Bool {
        if let cached = cachedThemeColors, cached.isLightAppearance != DSTheme.c.isLightAppearance {
            return false
        }
        let think = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsThinking = !think.isEmpty
        let wantsSearch = message.showsProcessChrome
        guard hasThinking == wantsThinking, hasSearch == wantsSearch else { return false }
        if wantsThinking {
            guard cachedReasoningText == think,
                  !thinkingBox.isHidden else { return false }
        } else if !thinkingBox.isHidden {
            return false
        }
        if wantsSearch {
            guard !searchBox.isHidden else { return false }
        } else if !searchBox.isHidden {
            return false
        }
        return true
    }

    private func applyAssistantChrome(message: ChatMessage,
                                      colors: ThemeColors,
                                      thinkFont: CGFloat,
                                      streaming: Bool,
                                      lightweightBodies: Bool = false,
                                      refreshActions: Bool = true) {
        let imageActivity = message.hasImageTranscription
        let agentActivity = message.hasAgentProcess && !imageActivity
        let search: String
        if imageActivity {
            search = message.imageTranscriptionDisplayText(pairedUser: pairedUserMessage)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if agentActivity {
            search = message.agentProcessDisplayText
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            search = message.searchProcessContent
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        cachedSearchText = search
        cachedImageActivity = imageActivity
        cachedImageTranscriptionPhase = message.imageTranscriptionPhase
        // Agent timeline is interleaved in the body column (Cursor steps[]), not the search box.
        if agentActivity {
            hasSearch = false
            setSearch(visible: false, expanded: false)
            paintAgentInterleavedFlow(message)
        } else {
            clearAgentTimeline()
            hasSearch = message.showsProcessChrome
            if hasSearch {
                let liveSearchActivity = !imageActivity && streaming && message.searchProcessPhase != .done
                searchExpanded = false
                if imageActivity {
                    cachedSearchTitleCore = message.imageTranscriptionPhase.headerTitle
                    populateSearchBody(expanded: false, colors: colors, thinkFont: thinkFont)
                    setSearch(visible: true, expanded: false)
                } else {
                    syncAgentEditCards([])
                    cachedSearchTitleCore = liveSearchActivity
                        ? message.searchProcessPhase.headerTitle
                        : message.searchProcessSummaryTitle
                    if liveSearchActivity {
                        applySearchLivePreview(
                            text: search,
                            colors: colors,
                            thinkFont: thinkFont,
                            preferLatestLines: true
                        )
                    } else {
                        populateSearchBody(expanded: false, colors: colors, thinkFont: thinkFont)
                        setSearch(visible: true, expanded: false)
                    }
                }
                applyChromeHeaderTitle(searchHeader, title: cachedSearchTitleCore, color: colors.textSecondary)
                updateSearchHeaderInteraction(messageIsStreaming: streaming)
                searchBox.backgroundColor = colors.surface.withAlphaComponent(MessageChromeStyle.surfaceAlpha)
                searchBox.layer.borderWidth = 0
            } else {
                setSearch(visible: false, expanded: false)
                syncAgentEditCards([])
            }
        }

        let think = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedReasoningText = message.reasoningContent
        cachedThinkingFontSize = thinkFont
        cachedThemeColors = colors
        // Workspace agent timeline owns the chrome — hide deep-thinking strip to avoid
        // 「已工作」/「已深度思考」 double headers stacking out of alignment.
        let suppressThinking = Self.shouldSuppressThinkingChrome(for: message)
        hasThinking = !think.isEmpty && !suppressThinking
        if hasThinking {
            // Streaming: keep full expand locked, but show a short live preview
            // under the tag so the turn does not look frozen.
            thinkingExpanded = false
            if streaming, message.content.isEmpty {
                if !think.isEmpty {
                    applyThinkingLivePreview(
                        reasoning: message.reasoningContent,
                        colors: colors,
                        thinkFont: thinkFont
                    )
                } else {
                    setThinking(visible: true, expanded: false)
                }
                applyChromeHeaderTitle(thinkingHeader, title: "思考中…", color: colors.textSecondary)
            } else {
                populateThinkingBody(expanded: false, colors: colors, thinkFont: thinkFont)
                setThinking(visible: true, expanded: false)
            }
            let title = streaming && message.content.isEmpty
                ? "思考中…"
                : "已深度思考"
            applyChromeHeaderTitle(thinkingHeader, title: title, color: colors.textSecondary)
            updateThinkingHeaderInteraction(messageIsStreaming: streaming)
            thinkingBox.backgroundColor = colors.surface.withAlphaComponent(MessageChromeStyle.surfaceAlpha)
            thinkingBox.layer.borderWidth = MessageChromeStyle.borderWidth
        } else {
            setThinking(visible: false, expanded: false)
        }

        if refreshActions {
            refreshActionChrome(for: message, streaming: streaming, colors: colors)
        }
    }

    /// Keep 复制/重跑/分叉 on the first paint (including snap-hold early returns).
    func refreshActionChrome(for message: ChatMessage,
                                     streaming: Bool? = nil,
                                     colors: ThemeColors? = nil) {
        let isStreaming = streaming ?? message.isStreaming
        let c = colors ?? cachedThemeColors ?? DSTheme.c
        let showAct = Self.shouldShowActionButtons(for: message, streaming: isStreaming)
        let layoutNow = cellDelegate?.messageCellShouldLayoutActionChromeNow(self) != false
        if !layoutNow {
            if showAct {
                if cellDelegate?.messageCellShouldDeferActionChromeUntilBodyPaint(self) == true {
                    reserveActionChromeHeightOnly()
                    lastChromeActionKey = "\(message.id)|scroll|deferred"
                } else if hasVisibleBodyPaint {
                    paintActionIconsWithoutLayout(for: message, colors: c)
                    lastChromeActionKey = "\(message.id)|scroll|icons"
                } else {
                    reserveActionChromeSpace()
                    lastChromeActionKey = "\(message.id)|scroll|reserved"
                }
            } else if !actionRow.isHidden || actionHeight.constant > 0.5 {
                showActions(false, versionText: nil, canPrev: false, canNext: false)
                lastChromeActionKey = "\(message.id)|scroll|hidden"
            }
            return
        }
        let pager = message.showsVersionPager
        let chromeKey = "\(message.id)|\(showAct)|\(pager)|\(message.versionIndex)|\(message.versions.count)"
        let needsActionRefresh = chromeKey != lastChromeActionKey
            || (showAct && (actionRow.isHidden || actionHeight.constant < 1 || copyButton.image(for: .normal) == nil))
        if needsActionRefresh {
            showActions(
                showAct,
                versionText: pager ? message.versionPagerText : nil,
                canPrev: pager && message.versionIndex > 0,
                canNext: pager && message.versionIndex < message.versions.count - 1
            )
            if showAct {
                styleActionIcons(c)
            }
            lastChromeActionKey = chromeKey
        }
    }

    private static func shouldShowActionButtons(for message: ChatMessage, streaming: Bool) -> Bool {
        guard !streaming else { return false }
        // Mid-agent loop / process-only chrome: no Copy / Retry / Fork.
        if message.agentProcessPhase == .running || message.agentProcessPhase == .waitingUser {
            return false
        }
        let body = message.chatDisplayBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoning = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return !body.isEmpty || !reasoning.isEmpty || message.hasImageTranscription
    }

    /// Reserve 28pt action slot before body paint — actionHeight 0→28 was shifting native text via nativeBottom.
    private func primeFinishedActionChromeSlot(for message: ChatMessage) {
        guard Self.shouldShowActionButtons(for: message, streaming: false) else { return }
        if actionHeight.constant < Self.actionRowVisibleHeight - 0.5 {
            actionHeight.constant = Self.actionRowVisibleHeight
        }
        actionRow.isHidden = false
    }

    /// True when the native body constraint matches the painted layout height.
    var isNativeBodyHeightAligned: Bool {
        guard !nativeRenderView.isHidden else { return true }
        guard let painted = nativeRenderView.paintedLayoutHeight, painted > 1 else { return false }
        return abs(nativeHeight.constant - ceil(painted)) <= 1.5
    }

    /// Pin native body height to the painted layout so action chrome sits flush under text.
    @discardableResult
    func syncNativeBodyHeightToLayout() -> Bool {
        guard !nativeRenderView.isHidden else { return false }
        guard let painted = nativeRenderView.paintedLayoutHeight, painted > 1 else { return false }
        let target = ceil(painted)
        guard abs(nativeHeight.constant - target) > 0.5 else { return false }
        nativeHeight.constant = target
        return true
    }

    private func reconcileColumnBottomPinIfNeeded() {
        guard cellDelegate?.messageCellShouldFreezeHeight(self) != true else { return }
        columnBottomPin.priority = UILayoutPriority(250)
    }

    /// Constraint-sum column stack height (excludes overlay action row).
    private func intrinsicColumnStackHeight() -> CGFloat {
        var total: CGFloat = 0
        let stackWidth = max(column.bounds.width, preferredLayoutWidth, 120)
        if !imageViewMsg.isHidden, imageHeight.constant > 0.5 {
            total += imageHeight.constant
            if !nativeRenderView.isHidden || !assistantLabel.isHidden || !agentTimelineStack.isHidden {
                total += 10
            }
        }
        if !searchBox.isHidden {
            let searchH: CGFloat
            if !searchBody.isHidden {
                let bodyW = max(stackWidth - 24, 80)
                let bodyH: CGFloat
                if searchLivePreviewMode, searchBodyH.isActive {
                    bodyH = searchBodyH.constant
                } else {
                let layoutW = preferredLayoutWidth > 0 ? preferredLayoutWidth : stackWidth
                let searchBodyText = cachedSearchText.isEmpty ? cachedSearchTitleCore : cachedSearchText
                let utf8Count = searchBodyText.utf8.count
                if !messageID.isEmpty,
                   let cached = AssistantMessageLayout.lookupSearchBodyHeight(
                       messageID: messageID,
                       layoutWidth: layoutW,
                       utf8Count: utf8Count
                   ), cached > 0 {
                    bodyH = cached
                } else {
                    bodyH = searchBody.sizeThatFits(
                        CGSize(width: bodyW, height: .greatestFiniteMagnitude)
                    ).height
                    if bodyH > 0, !messageID.isEmpty {
                        AssistantMessageLayout.storeSearchBodyHeight(
                            ceil(bodyH),
                            messageID: messageID,
                            layoutWidth: layoutW,
                            utf8Count: utf8Count
                        )
                    }
                }
                }
                searchH = searchTop.constant + searchHeaderH.constant + 4 + bodyH + 10
            } else if searchBoxH.isActive, searchBoxH.constant > 0.5 {
                searchH = searchBoxH.constant
            } else {
                searchH = searchTop.constant + searchHeaderH.constant
            }
            if searchH > 0.5 {
                total += searchH
                if !thinkingBox.isHidden || !nativeRenderView.isHidden || !assistantLabel.isHidden {
                    total += 10
                }
            }
        }
        if !thinkingBox.isHidden {
            let thinkH: CGFloat
            // Use body visibility (live preview sets body visible while
            // thinkingExpanded stays false until the turn finishes).
            if !thinkingBody.isHidden {
                let bodyW = max(stackWidth - 24, 80)
                let bodyH: CGFloat
                if thinkingLivePreviewMode, thinkingBodyH.isActive {
                    bodyH = thinkingBodyH.constant
                } else {
                    let layoutW = preferredLayoutWidth > 0 ? preferredLayoutWidth : stackWidth
                    let utf8Count = cachedReasoningText.utf8.count
                    if !messageID.isEmpty,
                       let cached = AssistantMessageLayout.lookupThinkingBodyHeight(
                           messageID: messageID,
                           layoutWidth: layoutW,
                           utf8Count: utf8Count
                       ), cached > 0 {
                        bodyH = cached
                    } else {
                        bodyH = thinkingBody.sizeThatFits(
                            CGSize(width: bodyW, height: .greatestFiniteMagnitude)
                        ).height
                        if bodyH > 0, !messageID.isEmpty {
                            AssistantMessageLayout.storeThinkingBodyHeight(
                                ceil(bodyH),
                                messageID: messageID,
                                layoutWidth: layoutW,
                                utf8Count: utf8Count
                            )
                        }
                    }
                }
                thinkH = thinkingTop.constant + thinkingHeaderH.constant + 4 + bodyH + 10
            } else if thinkingBoxH.isActive, thinkingBoxH.constant > 0.5 {
                thinkH = thinkingBoxH.constant
            } else {
                thinkH = thinkingTop.constant + thinkingHeaderH.constant
            }
            if thinkH > 0.5 {
                total += thinkH
                if !nativeRenderView.isHidden || !assistantLabel.isHidden || !agentTimelineStack.isHidden {
                    total += 10
                }
            }
        }
        if !agentEditCardsStack.isHidden, agentEditCardsHeight.constant > 0.5 {
            total += agentEditCardsHeight.constant
            if !agentTimelineStack.isHidden || !assistantLabel.isHidden || !nativeRenderView.isHidden {
                total += 10
            }
        }
        if !nativeRenderView.isHidden, nativeHeight.constant > 0.5 {
            total += nativeHeight.constant
        } else if !agentTimelineStack.isHidden {
            let timelineH = agentTimelineStack.systemLayoutSizeFitting(
                CGSize(width: stackWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            if timelineH > 0.5 { total += timelineH }
        } else if !assistantLabel.isHidden {
            let plain = assistantLabel.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Empty UILabel still reports a line-height — skip it so collapsed
            // thinking/search tags don't leave a phantom blank under the header.
            if !plain.isEmpty {
                let labelH = assistantLabel.sizeThatFits(
                    CGSize(width: stackWidth, height: .greatestFiniteMagnitude)
                ).height
                if labelH > 0.5 { total += labelH }
            }
        }
        return total
    }

    /// Column + overlay action gap — matches contentView Auto Layout.
    private func paintedStackHeight() -> CGFloat {
        var h = column.bounds.height
        if h < 1 {
            h = intrinsicColumnStackHeight()
        }
        guard !actionRow.isHidden, actionHeight.constant > 0.5 else { return h }
        return h + 4 + actionHeight.constant
    }

    /// Force-show 复制/重跑/分叉 on the open path (ignores chrome-key short-circuit).
    /// Row-height clipping is fixed by the host; this guarantees the buttons exist in-layout.
    @discardableResult
    func ensureActionButtonsVisible(for message: ChatMessage,
                                    requireBodyAlignment: Bool = false) -> Bool {
        guard messageID.isEmpty || messageID == message.id else { return false }
        guard Self.shouldShowActionButtons(for: message, streaming: message.isStreaming) else {
            showActions(false)
            return false
        }
        primeFinishedActionChromeSlot(for: message)
        let c = cachedThemeColors ?? DSTheme.c
        if requireBodyAlignment,
           !nativeRenderView.isHidden,
           !isNativeBodyHeightAligned {
            syncNativeBodyHeightToLayout()
            if !isNativeBodyHeightAligned {
                paintActionIconsWithoutLayout(for: message, colors: c)
                return hasVisibleActionButtons
            }
        }
        paintActionIconsWithoutLayout(for: message, colors: c)
        if cellDelegate?.messageCellShouldLayoutActionChromeNow(self) == false {
            return hasVisibleActionButtons
        }
        syncNativeBodyHeightToLayout()
        lastChromeActionKey = chromeKey(for: message, showAct: true)
        cellDelegate?.messageCellDidPaintContent(self)
        return true
    }

    private func chromeKey(for message: ChatMessage, showAct: Bool) -> String {
        let pager = message.showsVersionPager
        return "\(message.id)|\(showAct)|\(pager)|\(message.versionIndex)|\(message.versions.count)"
    }

    /// True when finished-message action chrome is on and laid out.
    var hasVisibleActionButtons: Bool {
        !actionRow.isHidden && actionHeight.constant >= Self.actionRowVisibleHeight - 0.5
            && copyButton.image(for: .normal) != nil
            && !copyButton.isHidden
            && actionRow.alpha > 0.1
    }

    /// Scroll-freeze path: row holds action-row height (icons may be pre-painted).
    var hasReservedActionChromeSpace: Bool {
        !actionRow.isHidden && actionHeight.constant >= Self.actionRowVisibleHeight - 0.5
    }

    var hasAccommodatedActionChrome: Bool {
        hasVisibleActionButtons || hasReservedActionChromeSpace
    }

    func debugActionRowViewportY(in tableView: UITableView) -> CGFloat? {
        guard hasVisibleActionButtons else { return nil }
        contentView.layoutIfNeeded()
        return actionRow.convert(actionRow.bounds, to: tableView).minY - tableView.contentOffset.y
    }

    func isActionChromeClipped(in tableView: UITableView, at path: IndexPath) -> Bool {
        guard hasVisibleActionButtons,
              let actionTop = debugActionRowViewportY(in: tableView) else { return false }
        let rowFrame = tableView.rectForRow(at: path)
        let actionBottom = actionTop + Self.actionRowVisibleHeight
        let rowBottom = rowFrame.maxY - tableView.contentOffset.y
        return actionBottom > rowBottom + 1.5
    }

    private func populateSearchBody(expanded: Bool,
                                    colors: ThemeColors,
                                    thinkFont: CGFloat) {
        applySearchLayoutWidth()
        setSearchLivePreviewMode(false, thinkFont: thinkFont)
        searchBody.attributedText = nil
        searchBody.textColor = colors.textSecondary
        searchBody.font = UIFont.systemFont(ofSize: thinkFont)
        guard expanded else {
            searchBody.text = nil
            return
        }
        let body = cachedSearchText.isEmpty ? cachedSearchTitleCore : cachedSearchText
        searchBody.text = body.isEmpty ? nil : body
    }

    func fillExpandedSearchBodyIfNeeded() {
        guard searchExpanded, !searchBody.isHidden else { return }
        guard searchBody.text?.isEmpty != false else { return }
        let c = cachedThemeColors ?? DSTheme.c
        let thinkFont = cachedThinkingFontSize > 0
            ? cachedThinkingFontSize
            : SettingsManager.shared.chatThinkingFontSize
        populateSearchBody(expanded: true, colors: c, thinkFont: thinkFont)
    }

    func measuredColumnHeight() -> CGFloat {
        contentView.layoutIfNeeded()
        return paintedStackHeight()
    }

    private func applySearchLayoutWidth() {
        let width = max(column.bounds.width - 24, 80)
        if abs(searchBody.preferredMaxLayoutWidth - width) > 0.5 {
            searchBody.preferredMaxLayoutWidth = width
        }
    }

    /// Fixed 3-line rolling snippet under「思考中」— height stays constant so
    /// the stream does not keep lifting / dropping the table.
    private static let thinkingLivePreviewLineCount = 3
    private static func thinkingLivePreview(_ reasoning: String, limit: Int = 90) -> String {
        let trimmed = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= limit { return trimmed }
        return "…" + String(trimmed.suffix(limit))
    }

    /// Cursor-style process strip: show the *latest* N step lines (not the first).
    private static func agentProcessLivePreview(_ text: String, maxLines: Int = thinkingLivePreviewLineCount) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        if lines.count <= maxLines { return lines.joined(separator: "\n") }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private func thinkingLivePreviewBodyHeight(fontSize: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize)
        return ceil(font.lineHeight * CGFloat(Self.thinkingLivePreviewLineCount))
    }

    private func setThinkingLivePreviewMode(_ on: Bool, thinkFont: CGFloat) {
        if on {
            thinkingLivePreviewMode = true
            thinkingBody.numberOfLines = Self.thinkingLivePreviewLineCount
            thinkingBody.lineBreakMode = .byTruncatingTail
            thinkingBodyH.constant = thinkingLivePreviewBodyHeight(fontSize: thinkFont)
            thinkingBodyH.isActive = true
        } else {
            thinkingLivePreviewMode = false
            thinkingBody.numberOfLines = 0
            thinkingBody.lineBreakMode = .byWordWrapping
            thinkingBodyH.isActive = false
        }
    }

    private func setSearchLivePreviewMode(_ on: Bool, thinkFont: CGFloat, lineCount: Int? = nil) {
        if on {
            searchLivePreviewMode = true
            let lines = max(1, lineCount ?? Self.thinkingLivePreviewLineCount)
            searchBody.numberOfLines = lines
            searchBody.lineBreakMode = .byTruncatingTail
            let font = UIFont.systemFont(ofSize: thinkFont)
            searchBodyH.constant = ceil(font.lineHeight * CGFloat(lines))
            searchBodyH.isActive = true
        } else {
            searchLivePreviewMode = false
            searchBody.numberOfLines = 0
            searchBody.lineBreakMode = .byWordWrapping
            searchBodyH.isActive = false
        }
    }

    private func applySearchLivePreview(text: String,
                                        colors: ThemeColors,
                                        thinkFont: CGFloat,
                                        waitingGlyph: String? = nil,
                                        compactLines: Int? = nil,
                                        preferLatestLines: Bool = false) {
        let isPlanning = text == AgentProcessPhase.planningNextMovesText
            || text.hasPrefix(AgentProcessPhase.planningNextMovesText)
        let preview: String
        if preferLatestLines, !isPlanning {
            preview = Self.agentProcessLivePreview(text)
        } else {
            preview = Self.thinkingLivePreview(text)
        }
        applySearchLayoutWidth()
        setSearchLivePreviewMode(
            true,
            thinkFont: thinkFont,
            lineCount: compactLines ?? (isPlanning ? 1 : nil)
        )
        searchBody.textColor = colors.textSecondary
        searchBody.font = UIFont.systemFont(ofSize: thinkFont)
        if preview.isEmpty {
            searchBody.text = waitingGlyph
        } else {
            searchBody.text = waitingGlyph.map { preview + "  " + $0 } ?? preview
        }
        setSearch(visible: true, expanded: true)
    }

    private func applyThinkingLivePreview(reasoning: String,
                                          colors: ThemeColors,
                                          thinkFont: CGFloat,
                                          waitingGlyph: String? = nil) {
        let preview = Self.thinkingLivePreview(reasoning)
        applyThinkingLayoutWidth()
        setThinkingLivePreviewMode(true, thinkFont: thinkFont)
        thinkingBody.textColor = colors.textSecondary
        thinkingBody.font = UIFont.systemFont(ofSize: thinkFont)
        if preview.isEmpty {
            thinkingBody.text = waitingGlyph
        } else {
            thinkingBody.text = waitingGlyph.map { preview + "  " + $0 } ?? preview
        }
        // Fixed 3-line slot under the tag; full expand stays locked until finish.
        setThinking(visible: true, expanded: true)
    }

    private func populateThinkingBody(expanded: Bool,
                                      colors: ThemeColors,
                                      thinkFont: CGFloat) {
        applyThinkingLayoutWidth()
        setThinkingLivePreviewMode(false, thinkFont: thinkFont)
        thinkingBody.attributedText = nil
        thinkingBody.textColor = colors.textSecondary
        thinkingBody.font = UIFont.systemFont(ofSize: thinkFont)
        guard expanded else {
            thinkingBody.text = nil
            return
        }
        let body = cachedReasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
        thinkingBody.text = body.isEmpty ? nil : cachedReasoningText
    }

    /// Called by host after row height grows — avoids blocking the tap on UILabel layout.
    func fillExpandedThinkingBodyIfNeeded() {
        guard thinkingExpanded, !thinkingBody.isHidden else { return }
        guard thinkingBody.text?.isEmpty != false else { return }
        let c = cachedThemeColors ?? DSTheme.c
        let thinkFont = cachedThinkingFontSize > 0
            ? cachedThinkingFontSize
            : SettingsManager.shared.chatThinkingFontSize
        populateThinkingBody(expanded: true, colors: c, thinkFont: thinkFont)
    }

    /// Host recovery check — true when cell chrome disagrees with the expand store.
    func thinkingExpandedMismatch(wantExpanded: Bool) -> Bool {
        guard hasThinking else { return false }
        return thinkingExpanded != wantExpanded || (wantExpanded && thinkingBody.isHidden)
    }

    func searchExpandedMismatch(wantExpanded: Bool) -> Bool {
        guard hasSearch else { return false }
        return searchExpanded != wantExpanded || (wantExpanded && searchBody.isHidden)
    }

    private func applyThinkingLayoutWidth() {
        let width = max(nativeLayoutWidth() - 24, 80)
        if abs(thinkingBody.preferredMaxLayoutWidth - width) > 0.5 {
            thinkingBody.preferredMaxLayoutWidth = width
        }
    }

    private func nativeLayoutWidth(for layoutWidth: CGFloat? = nil) -> CGFloat {
        let reference = max(layoutWidth ?? preferredLayoutWidth, 120)
        // Host passes content width already. Prefer live column once laid out.
        let columnW = column.bounds.width
        if columnW > 1 {
            return min(DSTheme.bubbleMaxWidth, max(columnW, 120))
        }
        let cellW = max(contentView.bounds.width, bounds.width)
        if cellW > 1 {
            return min(DSTheme.bubbleMaxWidth, max(cellW - 48, 120))
        }
        return RenderCacheStore.contentWidth(for: reference)
    }

    /// Flatten native bitmap while scrolling on iOS 12 — reduces compositor shimmer.
    func setNativeScrollRasterization(_ enabled: Bool) {
        nativeRenderView.layer.drawsAsynchronously = false
        if #available(iOS 13, *) {
            nativeRenderView.layer.shouldRasterize = false
            return
        }
        nativeRenderView.layer.shouldRasterize = enabled
        if enabled {
            nativeRenderView.layer.rasterizationScale = UIScreen.main.scale
        }
    }

    private func configureNative(message: ChatMessage,
                                 hasThinking: Bool,
                                 hasSearch: Bool = false,
                                 hasImage: Bool,
                                 font: CGFloat,
                                 colors: ThemeColors,
                                 layoutWidth: CGFloat,
                                 allowDefer: Bool = true) {
        let width = nativeLayoutWidth(for: layoutWidth)
        let scrollFrozen = allowDefer && cellDelegate?.messageCellShouldFreezeHeight(self) == true
        if scrollFrozen {
            let hasCachedLayout = AssistantMessageLayout.hasCachedNativeLayout(
                for: message,
                layoutWidth: width
            )
            if hasCachedLayout,
               let height = nativeRenderView.bindCachedLayoutIfAvailable(
                   content: message.chatDisplayBody,
                   width: width,
                   fontSize: font,
                   appearance: SettingsManager.shared.appearanceMode.rawValue,
                   colors: colors
               ) {
                bindNativeBodyLayout(hasThinking: hasThinking, hasSearch: hasSearch, hasImage: hasImage)
                nativeMessageForRemeasure = message
                lastNativeLayoutWidth = width
                nativeHeight.constant = ceil(height)
                nativeRenderView.isHidden = false
                assistantLabel.isHidden = true
                assistantLabel.text = nil
                assistantLabel.attributedText = nil
                return
            }
            deferredNativeBind = DeferredNativeBind(
                message: message,
                hasThinking: hasThinking,
                hasSearch: hasSearch,
                hasImage: hasImage,
                font: font,
                colors: colors,
                layoutWidth: layoutWidth
            )
            bindNativeBodyLayout(hasThinking: hasThinking, hasSearch: hasSearch, hasImage: hasImage)
            lastNativeLayoutWidth = width
            let keepH = max(nativeHeight.constant, configuredPreferredHeight ?? 0, 64)
            // Same message already painted: keep bitmap (no blank-out → hydrate → grow hitch).
            if hasVisibleNativePaint, nativeMessageForRemeasure?.id == message.id {
                nativeMessageForRemeasure = message
                nativeHeight.constant = max(keepH, nativeHeight.constant)
                nativeRenderView.isHidden = false
                assistantLabel.isHidden = true
                assistantLabel.text = nil
                assistantLabel.attributedText = nil
                #if DEBUG
                ChatHeavyScrollDiagnostics.scrollFreezeKeptPaint += 1
                #endif
                return
            }
            nativeMessageForRemeasure = message
            // Recycled onto a different message without cache: hide wrong paint, keep height slot.
            // Do not sync-layout/plain-fallback during freeze (contentSize thrash).
            nativeRenderView.clear()
            nativeRenderView.isHidden = true
            nativeHeight.constant = keepH
            assistantLabel.isHidden = true
            assistantLabel.text = nil
            assistantLabel.attributedText = nil
            #if DEBUG
            ChatHeavyScrollDiagnostics.scrollFreezeBlankShell += 1
            #endif
            return
        }
        deferredNativeBind = nil
        bindNativeBodyLayout(hasThinking: hasThinking, hasSearch: hasSearch, hasImage: hasImage)
        nativeMessageForRemeasure = message
        lastNativeLayoutWidth = width
        let renderResult = nativeRenderView.configure(
            content: message.chatDisplayBody,
            width: width,
            fontSize: font,
            appearance: SettingsManager.shared.appearanceMode.rawValue,
            colors: colors
        )
        nativeHeight.constant = renderResult.height
        syncNativeBodyHeightToLayout()
        nativeRenderView.isHidden = false
        if !renderResult.isProvisional {
            scheduleMeasuredHeightNotify(for: message.id)
        }
        refreshActionChrome(for: message, streaming: false, colors: colors)
        contentView.layoutIfNeeded()
        cellDelegate?.messageCellDidPaintContent(self)
    }

    private func bindNativeBodyLayout(hasThinking: Bool, hasSearch: Bool, hasImage: Bool) {
        assistantLabel.isHidden = true
        assistantLabel.attributedText = nil
        assistantLabel.text = nil
        labelBottom.isActive = false
        labelBottomFloor.isActive = false
        assistantTopToRole.isActive = false
        assistantTopToImage.isActive = false
        assistantTopToThink.isActive = false
        assistantTopToEditCards.isActive = false
        nativeTopToRole.isActive = false
        nativeTopToImage.isActive = false
        nativeTopToThink.isActive = false
        nativeTopToEditCards.isActive = false
        nativeBottom.isActive = false
        columnBottomToLabel.isActive = false
        columnBottomToNative.isActive = true
        let hasEditCards = !agentEditCardsStack.isHidden && agentEditCardsHeight.constant > 1
        if hasEditCards { nativeTopToEditCards.isActive = true }
        else if hasThinking || hasSearch { nativeTopToThink.isActive = true }
        else if hasImage { nativeTopToImage.isActive = true }
        else { nativeTopToRole.isActive = true }
    }

    func debugPaintKind() -> String {
        if !nativeRenderView.isHidden { return "native" }
        if !assistantLabel.isHidden {
            let t = assistantLabel.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !t.isEmpty { return "plain" }
        }
        return "empty"
    }

    func debugPaintMetrics() -> [String: Any] {
        [
            "colH": Int(column.bounds.height),
            "prefH": Int(configuredPreferredHeight ?? 0)
        ]
    }

    private func configurePlainFallback(message: ChatMessage,
                                        hasThinking: Bool,
                                        hasSearch: Bool,
                                        hasImage: Bool,
                                        font: CGFloat,
                                        colors: ThemeColors,
                                        scheduleHeightNotify: Bool = true,
                                        allowTruncate: Bool = true) {
        hideNativeRender()
        assistantLabel.isHidden = false
        assistantLabel.alpha = 1
        labelBottom.isActive = true
        labelBottomFloor.isActive = true
        columnBottomToNative.isActive = false
        columnBottomToLabel.isActive = true
        assistantTopToRole.isActive = false
        assistantTopToImage.isActive = false
        assistantTopToThink.isActive = false
        setContentTops(hasThinking: hasThinking, hasSearch: hasSearch, hasImage: hasImage)
        assistantLabel.attributedText = nil
        assistantLabel.textColor = colors.textPrimary
        assistantLabel.font = UIFont.systemFont(ofSize: font)
        // Long plain UILabel layout hitches scroll; truncate only on the deferred path.
        let content = message.chatDisplayBody
        if allowTruncate, !scheduleHeightNotify, content.count > 900 {
            assistantLabel.text = String(content.prefix(900)) + "\n…"
        } else {
            assistantLabel.text = content
        }
        applyAssistantLayoutWidth()
        if scheduleHeightNotify {
            scheduleMeasuredHeightNotify(for: message.id)
        }
        refreshActionChrome(for: message, streaming: false, colors: colors)
        contentView.layoutIfNeeded()
        cellDelegate?.messageCellDidPaintContent(self)
    }

    /// Push the column's intrinsic height back to the table. iOS 12 can keep an
    /// oversized estimated row and stretch this cell unless we remeasure after
    /// configure — especially for reasoning/search chrome and user bubbles.
    /// Column content height used for UITableView self-sizing.
    func measuredContentHeight() -> CGFloat {
        contentView.layoutIfNeeded()
        let intrinsic = intrinsicColumnStackHeight()
        var intrinsicStack = intrinsic
        if !actionRow.isHidden, actionHeight.constant > 0.5 {
            intrinsicStack += 4 + actionHeight.constant
        }
        let boundsH = column.bounds.height
        // Inflated table estimate: prefer constraint-sum (deflate).
        if intrinsic > 1, boundsH > intrinsic + 12 {
            return intrinsicStack
        }
        // Clipped row (native taller than cell frame): prefer constraint-sum
        // (grow). Trusting painted bounds here re-committed the short preview
        // height and left finished replies truncated mid-glyph.
        if intrinsic > 1, intrinsic > boundsH + 4 {
            return max(intrinsicStack, 44)
        }
        return paintedStackHeight()
    }

    /// Constraint-sum column height ignoring the current (possibly clipped) frame.
    func fittedColumnContentHeight() -> CGFloat {
        var h = intrinsicColumnStackHeight()
        if !actionRow.isHidden, actionHeight.constant > 0.5 {
            h += 4 + actionHeight.constant
        }
        return max(ceil(h), 44)
    }

    /// Explicit streaming row height — avoids iOS 12 `automaticDimension` fill.
    func fittedStreamingRowHeight() -> CGFloat {
        contentView.layoutIfNeeded()
        var h = intrinsicColumnStackHeight()
        if h < 1 {
            h = 22
        }
        h += ChatRowHeightResolver.cellVerticalMargin
        if !actionRow.isHidden, actionHeight.constant > 0.5 {
            h += 4 + actionHeight.constant
        }
        return max(ceil(h), 44)
    }

    /// Pin assistantLabel to column edges without stretching into spare cell space.
    private func pinPlainBodyToColumnContent() {
        labelBottom.isActive = false
        labelBottomFloor.isActive = true
        columnBottomToNative.isActive = false
        columnBottomToTimeline.isActive = false
        columnBottomToLabel.isActive = true
    }

    private func pinTimelineToColumnContent() {
        labelBottom.isActive = false
        labelBottomFloor.isActive = false
        columnBottomToNative.isActive = false
        columnBottomToLabel.isActive = false
        columnBottomToTimeline.isActive = true
    }

    private func scheduleMeasuredHeightNotify(for messageID: String,
                                              allowWhileProvisional: Bool = true) {
        guard allowWhileProvisional else { return }
        guard cellDelegate?.messageCellShouldFreezeHeight(self) != true else { return }
        let id = messageID
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.messageID == id else { return }
            self.contentView.setNeedsLayout()
            self.contentView.layoutIfNeeded()
            let height = self.measuredContentHeight()
            guard height > 40 else { return }
            self.cellDelegate?.messageCell(self, didFinishStableRender: height, for: id)
        }
    }

    private func updateRenderDebugOverlay() {
        let on = SettingsManager.shared.renderDebugOverlayEnabled
        guard on else {
            column.layer.borderWidth = 0
            nativeRenderView.layer.borderWidth = 0
            return
        }
        let hair = 1 / UIScreen.main.scale
        if !nativeRenderView.isHidden {
            let green: UIColor
            if #available(iOS 13.0, *) { green = .systemGreen }
            else { green = UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1) }
            column.layer.borderWidth = hair
            column.layer.borderColor = green.withAlphaComponent(0.55).cgColor
            nativeRenderView.layer.borderWidth = hair
            nativeRenderView.layer.borderColor = green.withAlphaComponent(0.55).cgColor
        } else if !assistantLabel.isHidden {
            let plain = assistantLabel.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !plain.isEmpty {
                let yellow: UIColor
                if #available(iOS 13.0, *) { yellow = .systemYellow }
                else { yellow = UIColor(red: 1, green: 0.8, blue: 0, alpha: 1) }
                column.layer.borderWidth = hair
                column.layer.borderColor = yellow.withAlphaComponent(0.55).cgColor
                nativeRenderView.layer.borderWidth = 0
                return
            }
        } else {
            let red: UIColor
            if #available(iOS 13.0, *) { red = .systemRed }
            else { red = UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1) }
            column.layer.borderWidth = hair
            column.layer.borderColor = red.withAlphaComponent(0.55).cgColor
            nativeRenderView.layer.borderWidth = 0
        }
    }

    private func hideNativeRender() {
        nativeRenderView.isHidden = true
        nativeRenderView.clear()
        nativeHeight?.constant = 0
        nativeTopToRole?.isActive = false
        nativeTopToImage?.isActive = false
        nativeTopToThink?.isActive = false
        nativeBottom?.isActive = false
        columnBottomToNative?.isActive = false
    }

    /// Updates the already-bound streaming view without resetting constraints,
    /// renderer state, or action visibility on every token batch.
    @discardableResult
    func updateStreamingContent(_ message: ChatMessage, waitingGlyph: String? = nil) -> Bool {
        let thinkEmpty = message.reasoningContent.isEmpty
        let wantsSearchChrome = message.showsProcessChrome
        guard messageID == message.id,
              message.isStreaming else {
            return false
        }
        if wantsSearchChrome && searchBox.isHidden {
            return false
        }
        if !thinkEmpty && thinkingBox.isHidden {
            return false
        }
        guard !assistantLabel.isHidden,
              (thinkingBox.isHidden == thinkEmpty),
              (searchBox.isHidden == !wantsSearchChrome) else {
            return false
        }
        streamingPresentation = true
        let content = message.chatDisplayBody
        assistantLabel.attributedText = nil
        assistantLabel.text = content.isEmpty
            ? nil
            : content
        if !searchBox.isHidden {
            let imageActivity = message.hasImageTranscription
            let agentActivity = message.hasAgentProcess && !imageActivity
            let search: String
            if imageActivity {
                search = message.imageTranscriptionDisplayText(pairedUser: pairedUserMessage)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if agentActivity {
                search = message.agentProcessDisplayText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                search = message.searchProcessContent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            cachedSearchText = search
            searchExpanded = false
            let titleCore: String
            if imageActivity {
                titleCore = message.imageTranscriptionPhase.headerTitle
            } else if agentActivity {
                titleCore = message.agentProcessSummaryTitle
            } else {
                titleCore = message.searchProcessPhase != .done
                    ? message.searchProcessPhase.headerTitle
                    : message.searchProcessSummaryTitle
            }
            cachedSearchTitleCore = titleCore
            let colors = cachedThemeColors ?? DSTheme.c
            let thinkFont = cachedThinkingFontSize > 0
                ? cachedThinkingFontSize
                : SettingsManager.shared.chatThinkingFontSize
            let liveSearch = !imageActivity && !agentActivity
                && message.searchProcessPhase != .done
                && message.searchProcessPhase != .idle
            if agentActivity, message.agentProcessPhase == .running {
                let hasReasoning = !message.reasoningContent
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // Body may stream in — never collapse the process strip; never dump reasoning.
                let previewSource: String
                if !search.isEmpty {
                    previewSource = search
                } else if hasReasoning {
                    previewSource = AgentProcessPhase.thinkingText
                } else {
                    previewSource = AgentProcessPhase.planningNextMovesText
                }
                applySearchLivePreview(
                    text: previewSource,
                    colors: colors,
                    thinkFont: thinkFont,
                    compactLines: Self.thinkingLivePreviewLineCount,
                    preferLatestLines: true
                )
            } else if liveSearch {
                applySearchLivePreview(
                    text: search,
                    colors: colors,
                    thinkFont: thinkFont,
                    preferLatestLines: true
                )
            } else {
                searchBody.attributedText = nil
                searchBody.text = nil
                setSearch(visible: true, expanded: false)
            }
            applyChromeHeaderTitle(searchHeader, title: titleCore, color: colors.textSecondary)
            updateSearchHeaderInteraction(messageIsStreaming: true)
        }
        if !thinkingBox.isHidden {
            // Prefer agent process chrome alone when both are present mid-stream.
            if Self.shouldSuppressThinkingChrome(for: message) {
                setThinking(visible: false, expanded: false)
                hasThinking = false
            } else {
            cachedReasoningText = message.reasoningContent
            thinkingExpanded = false
            let colors = cachedThemeColors ?? DSTheme.c
            let thinkFont = cachedThinkingFontSize > 0
                ? cachedThinkingFontSize
                : SettingsManager.shared.chatThinkingFontSize
            if content.isEmpty {
                let reasoning = message.reasoningContent
                if reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    thinkingBody.text = nil
                    setThinking(visible: true, expanded: false)
                } else {
                    applyThinkingLivePreview(
                        reasoning: reasoning,
                        colors: colors,
                        thinkFont: thinkFont
                    )
                }
                applyChromeHeaderTitle(thinkingHeader, title: "思考中…", color: colors.textSecondary)
            } else {
                thinkingBody.text = nil
                setThinking(visible: true, expanded: false)
                applyChromeHeaderTitle(thinkingHeader, title: "已深度思考", color: colors.textSecondary)
            }
            updateThinkingHeaderInteraction(messageIsStreaming: true)
            }
        }
        pinPlainBodyToColumnContent()
        // Deliberately ignore waitingGlyph (◐◓◑◒). Those glyphs fought the
        // Thinking left→right shimmer and made body/meta jump every tick.
        _ = waitingGlyph
        schedulePlainHeightNotify()
        return true
    }

    /// Cursor-style: interleaved meta + body in one column (no process box).
    /// Fallback when host cannot rebuild from a full `ChatMessage` — prefer `syncAgentProcessPresentation`.
    /// Fallback only — never tears down the timeline (that killed shimmer / caused flicker).
    /// Prefer `syncAgentProcessPresentation` from the host.
    func applyAgentTurnStreamingBody(_ text: String?, waitingGlyph: String? = nil) {
        hideNativeRender()
        applyAssistantLayoutWidth()
        assistantLabel.isHidden = true
        assistantLabel.text = nil
        assistantLabel.attributedText = nil
        agentTimelineStack.isHidden = false
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Ignore waitingGlyph — moon spinners caused jump + killed shimmer.
        if let prose = agentTimelineViewsByID["current"] as? UILabel, prose.text != trimmed {
            prose.text = trimmed
        }
        let overlay = AgentProcessPhase.planningNextMovesText
        if let shimmer = agentLiveShimmerLabel ?? agentTimelineViewsByID["overlay"] as? ConnectsShimmerLabel {
            if shimmer.text != overlay { shimmer.text = overlay }
            shimmer.setShimmerEnabled(true)
            agentLiveShimmerLabel = shimmer
        }
        pinTimelineToColumnContent()
        setContentTops(hasThinking: false, hasSearch: false, hasImage: !imageViewMsg.isHidden)
    }

    /// Ends the live state without changing the renderer currently visible in
    /// this cell. Rich tiles are adopted only on a later normal cell binding,
    /// after they are already available synchronously.
    func finalizeStreamingPresentation(_ message: ChatMessage) {
        guard messageID == message.id else { return }
        streamingPresentation = false
        let c = DSTheme.c
        let imageActivity = message.hasImageTranscription
        let agentActivity = message.hasAgentProcess && !imageActivity
        let search: String
        if imageActivity {
            search = message.imageTranscriptionDisplayText(pairedUser: pairedUserMessage)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if agentActivity {
            search = message.agentProcessDisplayText
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            search = message.searchProcessContent
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if agentActivity {
            setSearch(visible: false, expanded: false)
            hasSearch = false
            paintAgentInterleavedFlow(message)
            setContentTops(hasThinking: false, hasSearch: false, hasImage: !imageViewMsg.isHidden)
        } else if !searchBox.isHidden {
            let title: String
            if imageActivity {
                title = message.imageTranscriptionPhase.headerTitle
            } else {
                title = message.searchProcessSummaryTitle
            }
            applyChromeHeaderTitle(searchHeader, title: title, color: c.textSecondary)
            let thinkFont = cachedThinkingFontSize > 0
                ? cachedThinkingFontSize
                : SettingsManager.shared.chatThinkingFontSize
            cachedSearchText = search
            populateSearchBody(expanded: false, colors: c, thinkFont: thinkFont)
            setSearch(visible: true, expanded: false)
        }
        let think = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !think.isEmpty {
            applyChromeHeaderTitle(
                thinkingHeader,
                title: "已深度思考",
                color: c.textSecondary
            )
            updateThinkingHeaderInteraction(messageIsStreaming: false)
        }
        if !searchBox.isHidden {
            updateSearchHeaderInteraction(messageIsStreaming: false)
        }
        let pager = message.showsVersionPager
        showActions(
            !message.chatDisplayBody.isEmpty || !think.isEmpty || !search.isEmpty,
            versionText: pager ? message.versionPagerText : nil,
            canPrev: pager && message.versionIndex > 0,
            canNext: pager && message.versionIndex < message.versions.count - 1
        )
        styleActionIcons(c)
        schedulePlainHeightNotify()
    }

    @discardableResult
    func transitionToFinishedPlainRendering(_ message: ChatMessage,
                                            preferredHeight: CGFloat?,
                                            pairedUser: ChatMessage? = nil) -> CGFloat? {
        guard messageID == message.id,
              !message.isStreaming else { return nil }
        if let pairedUser = pairedUser {
            pairedUserMessage = pairedUser
        }
        // Keep image transcription collapsed by default (same as thinking).
        let cover = contentView.snapshotView(afterScreenUpdates: false)
        if let cover = cover {
            cover.frame = contentView.bounds
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.isUserInteractionEnabled = false
            contentView.addSubview(cover)
        }
        configure(
            with: message,
            preferredHeight: preferredHeight,
            layoutWidth: preferredLayoutWidth > 0 ? preferredLayoutWidth : nativeLayoutWidth(),
            pairedUser: pairedUserMessage
        )
        syncNativeBodyHeightToLayout()
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        let measured = measuredColumnHeight()
        if let cover = cover {
            UIView.animate(
                withDuration: 0.12,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction],
                animations: { cover.alpha = 0 },
                completion: { _ in cover.removeFromSuperview() }
            )
        }
        return measured > 40 ? measured : nil
    }

    /// PlainMarkdown rows don't go through web height JS — push measured height so estimates settle.
    private func schedulePlainHeightNotify() {
        // ChatVC owns bounded live-row remeasurement. A second per-cell height
        // loop caused duplicate beginUpdates passes and visible token stalls.
        guard !streamingPresentation else { return }
        // Fixed-cadence height updates. A debounce is starved by a continuous
        // token stream; updating on every frame makes UITableView relayout jank.
        guard heightNotifyWork == nil else { return }
        let id = messageID
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.heightNotifyWork = nil
            guard self.messageID == id else { return }
            self.contentView.layoutIfNeeded()
            let h = self.column.bounds.height
            guard h > 40 else { return }
            self.cellDelegate?.messageCell(self, didUpdateHeight: h, for: id)
        }
        heightNotifyWork = work
        // Row geometry does not need to follow the 25 fps text clock. A slower
        // cadence keeps self-sizing table passes from blocking token painting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    private func applyColumnContentGutter() {
        let gutter = max(studyContentLeadingGutter, 0)
        columnCenterX.constant = gutter / 2
        columnWidthFill.constant = -(48 + gutter)
    }

    private func applyAssistantLayoutWidth() {
        let screen = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let fallback = min(DSTheme.bubbleMaxWidth, screen - 56)
        let w = max(column.bounds.width, bounds.width - 48, fallback * 0.55, 280)
        if abs(assistantLabel.preferredMaxLayoutWidth - w) > 0.5 {
            assistantLabel.preferredMaxLayoutWidth = w
        }
        applyThinkingLayoutWidth()
        if abs(searchBody.preferredMaxLayoutWidth - max(w - 24, 1)) > 0.5 {
            searchBody.preferredMaxLayoutWidth = max(w - 24, 1)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.bringSubviewToFront(actionRow)
        let w = max(column.bounds.width, 1)
        if abs(assistantLabel.preferredMaxLayoutWidth - w) > 0.5 {
            assistantLabel.preferredMaxLayoutWidth = w
        }
        applyThinkingLayoutWidth()
        if abs(searchBody.preferredMaxLayoutWidth - max(w - 24, 1)) > 0.5 {
            searchBody.preferredMaxLayoutWidth = max(w - 24, 1)
        }
        let desiredNativeWidth = nativeLayoutWidth()
        if !nativeRenderView.isHidden,
           let message = nativeMessageForRemeasure,
           abs(desiredNativeWidth - lastNativeLayoutWidth) > 1,
           cellDelegate?.messageCellShouldFreezeHeight(self) != true {
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      self.messageID == message.id,
                      !self.nativeRenderView.isHidden else { return }
                self.configureNative(
                    message: message,
                    hasThinking: self.hasThinking,
                    hasSearch: self.hasSearch,
                    hasImage: !self.imageViewMsg.isHidden,
                    font: SettingsManager.shared.chatBodyFontSize,
                    colors: DSTheme.c,
                    layoutWidth: self.preferredLayoutWidth
                )
            }
        }
        reconcileColumnBottomPinIfNeeded()
        updateRenderDebugOverlay()
        // Width remasure is owned by ChatVC (rotation / Slide Over) — not here.
        // layoutSubviews fires constantly while scrolling and was causing height thrash.
    }

    private func styleActionIcons(_ c: ThemeColors) {
        styleActionButton(versionPrevButton, kind: .chevronLeft, label: "上一版", color: c)
        styleActionButton(versionNextButton, kind: .chevronRight, label: "下一版", color: c)
        versionLabel.textColor = c.textSecondary
        styleActionButton(copyButton, kind: .copy, label: "复制", color: c)
        styleActionButton(retryButton, kind: .retry, label: "重跑", color: c)
        styleActionButton(forkButton, kind: .fork, label: "分叉", color: c)
    }

    private func styleActionButton(_ button: UIButton, kind: ActionIconFactory.Kind, label: String, color: ThemeColors) {
        let img = ActionIconFactory.image(kind, pointSize: ActionIconFactory.messageActionGlyph)
        button.setImage(img, for: .normal)
        button.setTitle(nil, for: .normal)
        button.tintColor = color.textSecondary
        button.backgroundColor = .clear
        button.accessibilityLabel = label
        button.imageView?.contentMode = .scaleAspectFit
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        if #available(iOS 13.0, *) {
            button.adjustsImageSizeForAccessibilityContentSizeCategory = false
        }
    }

    private func actionSignature(on: Bool, versionText: String?, canPrev: Bool, canNext: Bool) -> String {
        "\(on)|\(versionText ?? "")|\(canPrev)|\(canNext)"
    }

    private func paintActionIconsWithoutLayout(for message: ChatMessage, colors: ThemeColors) {
        primeFinishedActionChromeSlot(for: message)
        actionRow.alpha = 1
        let pager = message.showsVersionPager
        showActions(
            true,
            versionText: pager ? message.versionPagerText : nil,
            canPrev: pager && message.versionIndex > 0,
            canNext: pager && message.versionIndex < message.versions.count - 1
        )
        styleActionIcons(colors)
        lastChromeActionKey = "\(message.id)|true|\(pager)|\(message.versionIndex)|\(message.versions.count)"
    }

    /// Hold action-row height during scroll; paint icons only when the row won't clip them.
    private func reserveActionChromeHeightOnly() {
        if actionHeight.constant < Self.actionRowVisibleHeight - 0.5 {
            actionHeight.constant = Self.actionRowVisibleHeight
        }
        actionRow.isHidden = false
        copyButton.isHidden = true
        retryButton.isHidden = true
        forkButton.isHidden = true
        versionCluster.isHidden = true
        versionPrevButton.isHidden = true
        versionNextButton.isHidden = true
        versionLabel.isHidden = true
        actionRow.alpha = 1
        lastActionRowSignature = actionSignature(on: true, versionText: nil, canPrev: false, canNext: false)
    }

    private func reserveActionChromeSpace() {
        if actionHeight.constant < Self.actionRowVisibleHeight - 0.5 {
            actionHeight.constant = Self.actionRowVisibleHeight
        }
        actionRow.isHidden = false
        if hasVisibleActionButtons {
            actionRow.alpha = 1
            return
        }
        // Scroll-freeze: height slot only — layoutIfNeeded here shoves QA body + leaves button flash.
        if cellDelegate?.messageCellShouldLayoutActionChromeNow(self) == false {
            reserveActionChromeHeightOnly()
            return
        }
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        guard cellDelegate?.messageCellRowHasRoomForActionChrome(self) != false else {
            copyButton.isHidden = true
            retryButton.isHidden = true
            forkButton.isHidden = true
            versionCluster.isHidden = true
            versionPrevButton.isHidden = true
            versionNextButton.isHidden = true
            versionLabel.isHidden = true
            actionRow.alpha = 1
            lastActionRowSignature = actionSignature(on: true, versionText: nil, canPrev: false, canNext: false)
            return
        }
        let c = cachedThemeColors ?? DSTheme.c
        copyButton.isHidden = false
        retryButton.isHidden = false
        forkButton.isHidden = false
        versionCluster.isHidden = true
        versionPrevButton.isHidden = true
        versionNextButton.isHidden = true
        versionLabel.isHidden = true
        actionRow.alpha = 1
        styleActionIcons(c)
        lastActionRowSignature = actionSignature(on: true, versionText: nil, canPrev: false, canNext: false)
    }

    /// Partial hide (alpha≈0) while row still allocates chrome — scroll flicker signal.
    var isActionChromeFlickering: Bool {
        guard !actionRow.isHidden, actionHeight.constant >= Self.actionRowVisibleHeight - 0.5 else { return false }
        return !hasVisibleActionButtons && actionRow.alpha < 0.9
    }

    private func showActions(_ on: Bool, versionText: String? = nil, canPrev: Bool = false, canNext: Bool = false) {
        let signature = actionSignature(on: on, versionText: versionText, canPrev: canPrev, canNext: canNext)
        if signature == lastActionRowSignature,
           actionRow.isHidden == !on,
           abs(actionHeight.constant - (on ? Self.actionRowVisibleHeight : 0)) < 0.5 {
            // Height-only scroll reserve matches signature but leaves icons hidden.
            if !(on && !hasVisibleActionButtons) {
                return
            }
        }
        lastActionRowSignature = signature
        actionRow.isHidden = !on
        let targetHeight = on ? Self.actionRowVisibleHeight : 0
        if abs(actionHeight.constant - targetHeight) > 0.5 {
            actionHeight.constant = targetHeight
        }
        actionRow.alpha = 1
        copyButton.isHidden = !on
        retryButton.isHidden = !on
        forkButton.isHidden = !on
        let showPager = on && !(versionText ?? "").isEmpty
        versionCluster.isHidden = !showPager
        versionPrevButton.isHidden = !showPager
        versionNextButton.isHidden = !showPager
        versionLabel.isHidden = !showPager
        versionLabel.text = versionText
        versionPrevButton.isEnabled = showPager && canPrev
        versionNextButton.isEnabled = showPager && canNext
        versionPrevButton.alpha = versionPrevButton.isEnabled ? 1 : 0.35
        versionNextButton.alpha = versionNextButton.isEnabled ? 1 : 0.35
    }

    private func setThinking(visible: Bool, expanded: Bool) {
        thinkingBox.isHidden = !visible
        thinkingHeader.isHidden = !visible
        thinkingHeaderH.constant = visible ? MessageChromeStyle.headerHeight : 0
        thinkingTop.constant = visible ? 8 : 0
        if visible {
            thinkingBoxH.isActive = false
            if expanded {
                thinkingToBody.isActive = true
                thinkingToHeader.isActive = false
                thinkingBody.isHidden = false
            } else {
                setThinkingLivePreviewMode(false, thinkFont: cachedThinkingFontSize > 0
                    ? cachedThinkingFontSize
                    : SettingsManager.shared.chatThinkingFontSize)
                thinkingBody.isHidden = true
                thinkingToHeader.isActive = true
                thinkingToBody.isActive = false
            }
        } else {
            setThinkingLivePreviewMode(false, thinkFont: cachedThinkingFontSize > 0
                ? cachedThinkingFontSize
                : SettingsManager.shared.chatThinkingFontSize)
            thinkingBody.isHidden = true
            thinkingToHeader.isActive = false
            thinkingToBody.isActive = false
            thinkingBoxH.constant = 0
            thinkingBoxH.isActive = true
            thinkingBody.text = nil
        }
    }

    private func setSearch(visible: Bool, expanded: Bool) {
        searchBox.isHidden = !visible
        searchHeader.isHidden = !visible
        searchHeaderH.constant = visible ? MessageChromeStyle.headerHeight : 0
        searchTop.constant = visible ? 8 : 0
        if visible {
            searchBoxH.isActive = false
            if expanded {
                searchToBody.isActive = true
                searchToHeader.isActive = false
                searchBody.isHidden = false
            } else {
                setSearchLivePreviewMode(false, thinkFont: cachedThinkingFontSize > 0
                    ? cachedThinkingFontSize
                    : SettingsManager.shared.chatThinkingFontSize)
                searchBody.isHidden = true
                searchToHeader.isActive = true
                searchToBody.isActive = false
            }
        } else {
            setSearchLivePreviewMode(false, thinkFont: cachedThinkingFontSize > 0
                ? cachedThinkingFontSize
                : SettingsManager.shared.chatThinkingFontSize)
            searchBody.isHidden = true
            searchToHeader.isActive = false
            searchToBody.isActive = false
            searchBoxH.constant = 0
            searchBoxH.isActive = true
            searchBody.attributedText = nil
            searchBody.text = nil
        }
    }

    private func setContentTops(hasThinking: Bool, hasSearch: Bool = false, hasImage: Bool) {
        assistantTopToRole.isActive = false
        assistantTopToImage.isActive = false
        assistantTopToThink.isActive = false
        assistantTopToEditCards.isActive = false
        timelineTopToRole.isActive = false
        timelineTopToImage.isActive = false
        nativeTopToRole.isActive = false
        nativeTopToImage.isActive = false
        nativeTopToThink.isActive = false
        nativeTopToEditCards.isActive = false

        let usesTimeline = !agentTimelineStack.isHidden
        let hasEditCards = !usesTimeline
            && !agentEditCardsStack.isHidden
            && agentEditCardsHeight.constant > 1
        if usesTimeline {
            if hasImage {
                timelineTopToImage.isActive = true
            } else {
                timelineTopToRole.isActive = true
            }
            // Native unused while timeline is showing.
        } else if hasEditCards {
            assistantTopToEditCards.isActive = true
            nativeTopToEditCards.isActive = true
        } else if hasThinking || hasSearch {
            assistantTopToThink.isActive = true
            nativeTopToThink.isActive = true
        } else if hasImage {
            assistantTopToImage.isActive = true
            nativeTopToImage.isActive = true
        } else {
            assistantTopToRole.isActive = true
            nativeTopToRole.isActive = true
        }
    }

    func applyDeferredHeightIfNeeded() {
        guard !messageID.isEmpty, !nativeRenderView.isHidden else { return }
        guard cellDelegate?.messageCellShouldFreezeHeight(self) != true else { return }
        contentView.layoutIfNeeded()
        let measured = column.bounds.height
        guard measured > 40 else { return }
        let cached = configuredPreferredHeight ?? 0
        guard cached == 0 || abs(measured - cached) > 4 else { return }
        scheduleMeasuredHeightNotify(for: messageID)
    }

    @objc private func openThinkingChrome() {
        guard hasThinking else { return }
        streamingPresentation = false
        guard !cachedReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cellDelegate?.messageCellDidTapChromeViewer(
            self,
            messageID: messageID,
            kind: .thinking
        )
    }

    #if DEBUG
    func debugPerformThinkingChromeTap() {
        openThinkingChrome()
    }
    #endif

    @objc private func openSearchChrome() {
        guard hasSearch else { return }
        streamingPresentation = false
        if imageTranscriptionFailed {
            NotificationCenter.default.post(
                name: Notification.Name("ConnectsImageTranscriptionRetry"),
                object: nil,
                userInfo: ["messageID": messageID]
            )
            return
        }
        let body = cachedSearchText.isEmpty ? cachedSearchTitleCore : cachedSearchText
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cellDelegate?.messageCellDidTapChromeViewer(
            self,
            messageID: messageID,
            kind: .search
        )
    }

    @objc private func copyTapped() { cellDelegate?.messageCellDidTapCopy(self, messageID: messageID) }
    @objc private func retryTapped() { cellDelegate?.messageCellDidTapRetry(self, messageID: messageID) }
    @objc private func forkTapped() { cellDelegate?.messageCellDidTapFork(self, messageID: messageID) }
    @objc private func versionPrevTapped() { cellDelegate?.messageCellDidShiftVersion(self, messageID: messageID, delta: -1) }
    @objc private func versionNextTapped() { cellDelegate?.messageCellDidShiftVersion(self, messageID: messageID, delta: 1) }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        // Clip body overflow, but action icons are inside column — short UITableView
        // rows were hiding 复制/重跑/分叉 until height settle. Host now expands rows
        // on open; keep clips so snap/native don't paint outside the bubble column.
        contentView.clipsToBounds = true
        clipsToBounds = true

        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)

        roleLabel.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(roleLabel)

        imageViewMsg.translatesAutoresizingMaskIntoConstraints = false
        imageViewMsg.contentMode = .scaleAspectFill
        imageViewMsg.clipsToBounds = true
        imageViewMsg.layer.cornerRadius = 12
        imageViewMsg.isHidden = true
        imageViewMsg.isUserInteractionEnabled = true
        column.addSubview(imageViewMsg)

        imageStripView.translatesAutoresizingMaskIntoConstraints = false
        imageStripView.isHidden = true
        imageViewMsg.addSubview(imageStripView)

        searchBox.translatesAutoresizingMaskIntoConstraints = false
        searchBox.layer.cornerRadius = MessageChromeStyle.cornerRadius
        searchBox.layer.borderWidth = 0
        searchBox.clipsToBounds = true
        searchBox.isHidden = true
        column.addSubview(searchBox)

        searchHeader.translatesAutoresizingMaskIntoConstraints = false
        searchHeader.contentHorizontalAlignment = .left
        searchHeader.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        searchHeader.titleLabel?.lineBreakMode = .byTruncatingTail
        searchHeader.setContentCompressionResistancePriority(.required, for: .vertical)
        searchHeader.connectsSetContentInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        searchHeader.addTarget(self, action: #selector(openSearchChrome), for: .touchUpInside)
        searchBox.addSubview(searchHeader)

        searchBody.translatesAutoresizingMaskIntoConstraints = false
        searchBody.numberOfLines = 0
        searchBody.isHidden = true
        searchBox.addSubview(searchBody)

        agentEditCardsStack.translatesAutoresizingMaskIntoConstraints = false
        agentEditCardsStack.axis = .vertical
        agentEditCardsStack.spacing = 8
        agentEditCardsStack.isHidden = true
        column.addSubview(agentEditCardsStack)

        agentTimelineStack.translatesAutoresizingMaskIntoConstraints = false
        agentTimelineStack.axis = .vertical
        agentTimelineStack.alignment = .fill
        // Never stretch children into spare cell height (half-screen jump / huge gaps).
        agentTimelineStack.distribution = .fill
        agentTimelineStack.spacing = 6
        agentTimelineStack.isHidden = true
        agentTimelineStack.clipsToBounds = true
        agentTimelineStack.setContentHuggingPriority(.required, for: .vertical)
        agentTimelineStack.setContentCompressionResistancePriority(.required, for: .vertical)
        column.addSubview(agentTimelineStack)

        thinkingBox.translatesAutoresizingMaskIntoConstraints = false
        thinkingBox.layer.cornerRadius = MessageChromeStyle.cornerRadius
        thinkingBox.layer.borderWidth = MessageChromeStyle.borderWidth
        thinkingBox.clipsToBounds = true
        thinkingBox.isHidden = true
        column.addSubview(thinkingBox)

        thinkingHeader.translatesAutoresizingMaskIntoConstraints = false
        thinkingHeader.contentHorizontalAlignment = .left
        thinkingHeader.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        thinkingHeader.connectsSetContentInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        thinkingHeader.addTarget(self, action: #selector(openThinkingChrome), for: .touchUpInside)
        thinkingBox.addSubview(thinkingHeader)

        thinkingBody.translatesAutoresizingMaskIntoConstraints = false
        thinkingBody.numberOfLines = 0
        thinkingBody.isHidden = true
        thinkingBox.addSubview(thinkingBody)


        assistantLabel.translatesAutoresizingMaskIntoConstraints = false
        assistantLabel.numberOfLines = 0
        assistantLabel.isHidden = true
        column.addSubview(assistantLabel)

        nativeRenderView.translatesAutoresizingMaskIntoConstraints = false
        nativeRenderView.isHidden = true
        nativeRenderView.onCodeFenceTap = { [weak self] hit in
            guard let self = self else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let vc = current as? UIViewController {
                    ChatCodeFencePopupViewController.present(
                        from: vc,
                        code: hit.code,
                        language: hit.language,
                        title: hit.title
                    )
                    return
                }
                responder = current.next
            }
        }
        nativeRenderView.onHeightChange = { [weak self] height in
            guard let self = self, !self.messageID.isEmpty else { return }
            let target = ceil(height)
            let scrollFrozen = self.cellDelegate?.messageCellShouldFreezeHeight(self) == true
            if scrollFrozen {
                var columnH = self.intrinsicColumnStackHeight()
                if !self.nativeRenderView.isHidden {
                    columnH = columnH - self.nativeHeight.constant + target
                }
                if !self.actionRow.isHidden, self.actionHeight.constant > 0.5 {
                    columnH += 4 + self.actionHeight.constant
                }
                guard columnH > 40 else { return }
                self.cellDelegate?.messageCell(self, didFinishStableRender: columnH, for: self.messageID)
                return
            }
            self.nativeHeight.constant = target
            // Do not measure clipped bounds — report the post-render stack height.
            let columnH = self.fittedColumnContentHeight()
            guard columnH > 40 else { return }
            self.cellDelegate?.messageCell(self, didFinishStableRender: columnH, for: self.messageID)
        }
        column.addSubview(nativeRenderView)

        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionRow.isHidden = true
        contentView.addSubview(actionRow)

        actionChromeStack.translatesAutoresizingMaskIntoConstraints = false
        actionChromeStack.axis = .horizontal
        actionChromeStack.spacing = 14
        actionChromeStack.alignment = .center
        actionChromeStack.distribution = .fill
        actionRow.addSubview(actionChromeStack)

        versionCluster.axis = .horizontal
        versionCluster.spacing = 2
        versionCluster.alignment = .center
        versionCluster.isHidden = true
        versionLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        versionLabel.textAlignment = .center
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        versionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        versionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

        for b in [versionPrevButton, versionNextButton, copyButton, retryButton, forkButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 36).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        versionCluster.addArrangedSubview(versionPrevButton)
        versionCluster.addArrangedSubview(versionLabel)
        versionCluster.addArrangedSubview(versionNextButton)
        actionChromeStack.addArrangedSubview(copyButton)
        actionChromeStack.addArrangedSubview(retryButton)
        actionChromeStack.addArrangedSubview(forkButton)
        actionChromeStack.addArrangedSubview(versionCluster)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        forkButton.addTarget(self, action: #selector(forkTapped), for: .touchUpInside)
        versionPrevButton.addTarget(self, action: #selector(versionPrevTapped), for: .touchUpInside)
        versionNextButton.addTarget(self, action: #selector(versionNextTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            actionChromeStack.leadingAnchor.constraint(equalTo: actionRow.leadingAnchor),
            actionChromeStack.centerYAnchor.constraint(equalTo: actionRow.centerYAnchor),
            actionChromeStack.trailingAnchor.constraint(lessThanOrEqualTo: actionRow.trailingAnchor)
        ])

        // Fill available width up to max — avoids UILabel intrinsic-width collapse
        columnWidthFill = column.widthAnchor.constraint(equalTo: contentView.widthAnchor, constant: -48)
        columnWidthFill.priority = UILayoutPriority(999)
        columnWidthMax = column.widthAnchor.constraint(lessThanOrEqualToConstant: DSTheme.bubbleMaxWidth)
        columnCenterX = column.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        imageHeight = imageViewMsg.heightAnchor.constraint(equalToConstant: 0)
        actionHeight = actionRow.heightAnchor.constraint(equalToConstant: 0)
        searchHeaderH = searchHeader.heightAnchor.constraint(equalToConstant: 0)
        searchBoxH = searchBox.heightAnchor.constraint(equalToConstant: 0)
        searchTop = searchBox.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 0)
        searchToHeader = searchBox.bottomAnchor.constraint(equalTo: searchHeader.bottomAnchor)
        searchToBody = searchBox.bottomAnchor.constraint(equalTo: searchBody.bottomAnchor, constant: 10)

        searchBodyH = searchBody.heightAnchor.constraint(equalToConstant: 0)
        searchBodyH.isActive = false

        thinkingHeaderH = thinkingHeader.heightAnchor.constraint(equalToConstant: 0)
        thinkingBoxH = thinkingBox.heightAnchor.constraint(equalToConstant: 0)
        thinkingBodyH = thinkingBody.heightAnchor.constraint(equalToConstant: 0)
        thinkingBodyH.isActive = false
        thinkingTop = thinkingBox.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 0)
        thinkingToHeader = thinkingBox.bottomAnchor.constraint(equalTo: thinkingHeader.bottomAnchor)
        thinkingToBody = thinkingBox.bottomAnchor.constraint(equalTo: thinkingBody.bottomAnchor, constant: 10)

        assistantTopToRole = assistantLabel.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 0)
        assistantTopToImage = assistantLabel.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 10)
        assistantTopToThink = assistantLabel.topAnchor.constraint(equalTo: thinkingBox.bottomAnchor, constant: 10)
        assistantTopToEditCards = assistantLabel.topAnchor.constraint(
            equalTo: agentEditCardsStack.bottomAnchor,
            constant: 10
        )
        timelineTopToRole = agentTimelineStack.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 0)
        timelineTopToImage = agentTimelineStack.topAnchor.constraint(
            equalTo: imageViewMsg.bottomAnchor,
            constant: 10
        )
        agentEditCardsTop = agentEditCardsStack.topAnchor.constraint(
            equalTo: thinkingBox.bottomAnchor,
            constant: 0
        )
        agentEditCardsHeight = agentEditCardsStack.heightAnchor.constraint(equalToConstant: 0)
        nativeHeight = nativeRenderView.heightAnchor.constraint(equalToConstant: 0)
        nativeTopToRole = nativeRenderView.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 0)
        nativeTopToImage = nativeRenderView.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 10)
        nativeTopToThink = nativeRenderView.topAnchor.constraint(equalTo: thinkingBox.bottomAnchor, constant: 10)
        nativeTopToEditCards = nativeRenderView.topAnchor.constraint(
            equalTo: agentEditCardsStack.bottomAnchor,
            constant: 10
        )
        nativeBottom = nativeRenderView.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -4)
        columnBottomToNative = column.bottomAnchor.constraint(equalTo: nativeRenderView.bottomAnchor)
        columnBottomToLabel = column.bottomAnchor.constraint(equalTo: assistantLabel.bottomAnchor)
        columnBottomToTimeline = column.bottomAnchor.constraint(equalTo: agentTimelineStack.bottomAnchor)
        labelBottom = assistantLabel.bottomAnchor.constraint(equalTo: column.bottomAnchor)
        labelBottom.priority = UILayoutPriority(750)
        labelBottomFloor = column.bottomAnchor.constraint(greaterThanOrEqualTo: assistantLabel.bottomAnchor)

        assistantLabel.setContentHuggingPriority(.required, for: .vertical)
        searchBox.setContentHuggingPriority(.required, for: .vertical)
        searchBox.setContentCompressionResistancePriority(.required, for: .vertical)
        thinkingBox.setContentHuggingPriority(.required, for: .vertical)
        column.setContentHuggingPriority(.required, for: .vertical)
        column.setContentCompressionResistancePriority(.required, for: .vertical)
        contentView.setContentHuggingPriority(.required, for: .vertical)

        // Never stretch the column to fill an oversized UITableView estimate.
        let inset = ChatRowHeightResolver.cellContentInset
        let columnBottomPin = contentView.bottomAnchor.constraint(
            greaterThanOrEqualTo: column.bottomAnchor,
            constant: inset
        )
        columnBottomPin.priority = UILayoutPriority(250)
        self.columnBottomPin = columnBottomPin
        actionRowBottomToContent = actionRow.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor,
            constant: -inset
        )
        actionGapFromColumn = actionRow.topAnchor.constraint(equalTo: column.bottomAnchor, constant: 4)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: inset),
            columnBottomPin,
            columnCenterX,
            columnWidthFill,
            columnWidthMax,

            roleLabel.topAnchor.constraint(equalTo: column.topAnchor),
            roleLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            roleLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            roleLabel.heightAnchor.constraint(equalToConstant: 0),

            imageViewMsg.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 0),
            imageViewMsg.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            imageViewMsg.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            imageHeight,

            imageStripView.leadingAnchor.constraint(equalTo: imageViewMsg.leadingAnchor),
            imageStripView.trailingAnchor.constraint(equalTo: imageViewMsg.trailingAnchor),
            imageStripView.topAnchor.constraint(equalTo: imageViewMsg.topAnchor),
            imageStripView.bottomAnchor.constraint(equalTo: imageViewMsg.bottomAnchor),

            searchTop,
            searchBox.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            searchBox.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            searchBoxH,

            searchHeader.topAnchor.constraint(equalTo: searchBox.topAnchor),
            searchHeader.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor),
            searchHeader.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor),
            searchHeaderH,

            searchBody.topAnchor.constraint(equalTo: searchHeader.bottomAnchor, constant: 4),
            searchBody.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 12),
            searchBody.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -12),

            agentEditCardsTop,
            agentEditCardsStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            agentEditCardsStack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            agentEditCardsHeight,

            thinkingTop,
            thinkingBox.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            thinkingBox.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            thinkingBoxH,

            thinkingHeader.topAnchor.constraint(equalTo: thinkingBox.topAnchor),
            thinkingHeader.leadingAnchor.constraint(equalTo: thinkingBox.leadingAnchor),
            thinkingHeader.trailingAnchor.constraint(equalTo: thinkingBox.trailingAnchor),
            thinkingHeaderH,

            thinkingBody.topAnchor.constraint(equalTo: thinkingHeader.bottomAnchor, constant: 4),
            thinkingBody.leadingAnchor.constraint(equalTo: thinkingBox.leadingAnchor, constant: 12),
            thinkingBody.trailingAnchor.constraint(equalTo: thinkingBox.trailingAnchor, constant: -12),

            assistantTopToRole,
            assistantLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            assistantLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            labelBottom,
            labelBottomFloor,

            agentTimelineStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            agentTimelineStack.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            nativeRenderView.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            nativeRenderView.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            nativeHeight,

            actionRowBottomToContent,
            actionGapFromColumn,
            actionRow.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            actionRow.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            actionHeight
        ])
        // Default inactive pair ends — configure() enables the right set
        labelBottom.isActive = false
        labelBottomFloor.isActive = false
        nativeTopToRole.isActive = false
        nativeTopToImage.isActive = false
        nativeTopToThink.isActive = false
        nativeTopToEditCards.isActive = false
        nativeBottom.isActive = false
        columnBottomToNative.isActive = false
        columnBottomToLabel.isActive = false
        columnBottomToTimeline.isActive = false
        assistantTopToRole.isActive = false
        assistantTopToEditCards.isActive = false
        timelineTopToRole.isActive = false
        timelineTopToImage.isActive = false
        // Pre-draw glyphs once so first configure never waits on icon factory.
        styleActionIcons(DSTheme.c)
    }
}
