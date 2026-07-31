import UIKit

/// Assistant reply row: native markdown, thinking/search chrome, action row.
final class AssistantMessageCell: UITableViewCell, MessageCellType {
    static let reuseID = MessageCellReuseID.assistant
    private static let actionRowVisibleHeight: CGFloat = 28

    weak var cellDelegate: MessageCellDelegate?
    private(set) var messageID: String = ""

    private let column = UIView()
    private let roleLabel = UILabel()
    private let imageViewMsg = UIImageView()

    private let thinkingHeader = UIButton(type: .system)
    private let thinkingBody = UILabel()
    private let thinkingBox = UIView()

    private let searchHeader = UIButton(type: .system)
    private let searchBody = UILabel()
    private let searchBox = UIView()

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
    private var assistantTopToRole: NSLayoutConstraint!
    private var assistantTopToImage: NSLayoutConstraint!
    private var assistantTopToThink: NSLayoutConstraint!
    private var thinkingTop: NSLayoutConstraint!
    private var labelBottom: NSLayoutConstraint!
    private var labelBottomFloor: NSLayoutConstraint!
    private var nativeHeight: NSLayoutConstraint!
    private var nativeTopToRole: NSLayoutConstraint!
    private var nativeTopToImage: NSLayoutConstraint!
    private var nativeTopToThink: NSLayoutConstraint!
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
    private static let chromeHeaderFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
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
        refreshActionChrome(for: message, streaming: false, colors: cachedThemeColors ?? DSTheme.c)
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
        if message.showsImageInChat {
            imageViewMsg.image = cachedImage
            imageViewMsg.isHidden = cachedImage == nil
            imageHeight.constant = cachedImage != nil ? 160 : 0
        } else {
            imageViewMsg.image = nil
            imageViewMsg.isHidden = true
            imageHeight.constant = 0
        }
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
        if message.showsImageInChat {
            imageViewMsg.image = cachedImage ?? ImageAttachmentHelper.image(from: message.imageJPEGBase64 ?? "")
            imageViewMsg.isHidden = imageViewMsg.image == nil
            imageHeight.constant = imageViewMsg.isHidden ? 0 : 160
        } else {
            imageViewMsg.image = nil
            imageViewMsg.isHidden = true
            imageHeight.constant = 0
        }
        let hasImage = !imageViewMsg.isHidden
        hasThinking = !message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hasSearch = message.hasSearchProcess || message.hasImageTranscription
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
        hasSearch = message.hasSearchProcess || message.hasImageTranscription
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
        hasThinking = !think.isEmpty
        guard hasThinking else { return }
        thinkingExpanded = false
        populateThinkingBody(expanded: false, colors: c, thinkFont: thinkFont)
        setThinking(visible: true, expanded: false)
        let title = (message.isStreaming || streamingPresentation) ? "思考中…" : "已深度思考"
        applyChromeHeaderTitle(thinkingHeader, title: title, color: c.textSecondary)
        updateThinkingHeaderInteraction(messageIsStreaming: message.isStreaming)
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
        let search = (imageActivity
            ? message.imageTranscriptionDisplayText(pairedUser: pairedUserMessage)
            : message.searchProcessContent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        cachedSearchText = search
        cachedImageActivity = imageActivity
        cachedImageTranscriptionPhase = message.imageTranscriptionPhase
        hasSearch = message.hasSearchProcess || imageActivity
        guard hasSearch else { return }
        searchExpanded = false
        if imageActivity {
            cachedSearchTitleCore = message.imageTranscriptionPhase.headerTitle
        } else {
            cachedSearchTitleCore = SearchProcessPhase.done.headerTitle
        }
        populateSearchBody(expanded: false, colors: c, thinkFont: thinkFont)
        setSearch(visible: true, expanded: false)
        applyChromeHeaderTitle(searchHeader, title: cachedSearchTitleCore, color: c.textSecondary)
        updateSearchHeaderInteraction(messageIsStreaming: message.isStreaming)
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
        imageViewMsg.image = nil
        imageViewMsg.isHidden = true
        imageHeight.constant = 0
        showsImageInBubble = false
        showActions(false)
        setThinking(visible: false, expanded: false)
        setSearch(visible: false, expanded: false)
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
    private var showsImageInBubble = false

    func setCachedImage(_ image: UIImage?) {
        cachedImage = image
    }

    func applyCachedImageIfNeeded() {
        guard showsImageInBubble else { return }
        guard let image = cachedImage else { return }
        guard imageViewMsg.image !== image || imageViewMsg.isHidden else { return }
        imageViewMsg.image = image
        imageViewMsg.isHidden = false
        imageHeight.constant = 160
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

        if message.showsImageInChat {
            if deferHeavyRender {
                imageViewMsg.image = cachedImage
                imageViewMsg.isHidden = cachedImage == nil
                imageHeight.constant = cachedImage != nil ? 160 : 0
            } else {
                imageViewMsg.image = cachedImage ?? ImageAttachmentHelper.image(from: message.imageJPEGBase64 ?? "")
                imageViewMsg.isHidden = imageViewMsg.image == nil
                imageHeight.constant = imageViewMsg.isHidden ? 0 : 160
            }
        } else {
            imageViewMsg.image = nil
            imageViewMsg.isHidden = true
            imageHeight.constant = 0
            cachedImage = nil
        }

        let hasImage = !imageViewMsg.isHidden
        hasThinking = !message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hasSearch = message.hasSearchProcess || message.hasImageTranscription
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

        if message.isStreaming || message.content.isEmpty {
            hideNativeRender()
            applyAssistantLayoutWidth()
            assistantLabel.isHidden = false
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

        if message.showsImageInChat {
            imageViewMsg.image = cachedImage
            imageViewMsg.isHidden = cachedImage == nil
            imageHeight.constant = cachedImage != nil ? 160 : 0
        } else {
            imageViewMsg.image = nil
            imageViewMsg.isHidden = true
            imageHeight.constant = 0
        }

        let hasImage = !imageViewMsg.isHidden
        hasThinking = !message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hasSearch = message.hasSearchProcess || message.hasImageTranscription

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
        let think = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsThinking = !think.isEmpty
        let wantsSearch = message.hasSearchProcess || message.hasImageTranscription
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
        let search = (imageActivity
            ? message.imageTranscriptionDisplayText(pairedUser: pairedUserMessage)
            : message.searchProcessContent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        cachedSearchText = search
        cachedImageActivity = imageActivity
        cachedImageTranscriptionPhase = message.imageTranscriptionPhase
        hasSearch = message.hasSearchProcess || imageActivity
        if hasSearch {
            let liveSearchActivity = !imageActivity && streaming && message.searchProcessPhase != .done
            // Streaming search: header + 3-line live preview (mirrors thinking chrome).
            searchExpanded = false
            if imageActivity {
                cachedSearchTitleCore = message.imageTranscriptionPhase.headerTitle
                populateSearchBody(expanded: false, colors: colors, thinkFont: thinkFont)
                setSearch(visible: true, expanded: false)
            } else {
                cachedSearchTitleCore = liveSearchActivity
                    ? message.searchProcessPhase.headerTitle
                    : SearchProcessPhase.done.headerTitle
                if liveSearchActivity {
                    applySearchLivePreview(
                        text: search,
                        colors: colors,
                        thinkFont: thinkFont
                    )
                } else {
                    populateSearchBody(expanded: false, colors: colors, thinkFont: thinkFont)
                    setSearch(visible: true, expanded: false)
                }
            }
            applyChromeHeaderTitle(searchHeader, title: cachedSearchTitleCore, color: colors.textSecondary)
            updateSearchHeaderInteraction(messageIsStreaming: streaming)
            searchBox.backgroundColor = colors.surface.withAlphaComponent(0.65)
            searchBox.layer.borderWidth = 0
        } else {
            setSearch(visible: false, expanded: false)
        }

        let think = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedReasoningText = message.reasoningContent
        cachedThinkingFontSize = thinkFont
        cachedThemeColors = colors
        hasThinking = !think.isEmpty
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
            thinkingBox.backgroundColor = colors.surface.withAlphaComponent(0.65)
            thinkingBox.layer.borderWidth = 0
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
        !streaming && (
            !message.chatDisplayBody.isEmpty
            || !message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || message.hasSearchProcess
            || message.hasImageTranscription
        )
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
            if !nativeRenderView.isHidden || !assistantLabel.isHidden {
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
                if !nativeRenderView.isHidden || !assistantLabel.isHidden {
                    total += 10
                }
            }
        }
        if !nativeRenderView.isHidden, nativeHeight.constant > 0.5 {
            total += nativeHeight.constant
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

    private func setSearchLivePreviewMode(_ on: Bool, thinkFont: CGFloat) {
        if on {
            searchLivePreviewMode = true
            searchBody.numberOfLines = Self.thinkingLivePreviewLineCount
            searchBody.lineBreakMode = .byTruncatingTail
            searchBodyH.constant = thinkingLivePreviewBodyHeight(fontSize: thinkFont)
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
                                        waitingGlyph: String? = nil) {
        let preview = Self.thinkingLivePreview(text)
        applySearchLayoutWidth()
        setSearchLivePreviewMode(true, thinkFont: thinkFont)
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
        nativeTopToRole.isActive = false
        nativeTopToImage.isActive = false
        nativeTopToThink.isActive = false
        nativeBottom.isActive = false
        columnBottomToLabel.isActive = false
        columnBottomToNative.isActive = true
        if hasThinking || hasSearch { nativeTopToThink.isActive = true }
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
        columnBottomToLabel.isActive = true
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
        let imageActivity = message.hasImageTranscription
        let wantsSearchChrome = message.hasSearchProcess || imageActivity
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
            let search = (imageActivity
                ? message.imageTranscriptionDisplayText(pairedUser: pairedUserMessage)
                : message.searchProcessContent
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            cachedSearchText = search
            searchExpanded = false
            let titleCore = imageActivity
                ? message.imageTranscriptionPhase.headerTitle
                : (message.searchProcessPhase != .done
                    ? message.searchProcessPhase.headerTitle
                    : SearchProcessPhase.done.headerTitle)
            cachedSearchTitleCore = titleCore
            let colors = cachedThemeColors ?? DSTheme.c
            let thinkFont = cachedThinkingFontSize > 0
                ? cachedThinkingFontSize
                : SettingsManager.shared.chatThinkingFontSize
            let liveSearch = !imageActivity
                && message.searchProcessPhase != .done
                && message.searchProcessPhase != .idle
            if liveSearch {
                applySearchLivePreview(
                    text: search,
                    colors: colors,
                    thinkFont: thinkFont
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
        pinPlainBodyToColumnContent()
        if let glyph = waitingGlyph {
            if !content.isEmpty {
                assistantLabel.text = content + "  " + glyph
            } else if !thinkingBox.isHidden, content.isEmpty {
                applyThinkingLivePreview(
                    reasoning: message.reasoningContent,
                    colors: cachedThemeColors ?? DSTheme.c,
                    thinkFont: cachedThinkingFontSize > 0
                        ? cachedThinkingFontSize
                        : SettingsManager.shared.chatThinkingFontSize,
                    waitingGlyph: glyph
                )
            } else if !searchBox.isHidden,
                      content.isEmpty,
                      !message.hasImageTranscription,
                      message.searchProcessPhase != .done,
                      message.searchProcessPhase != .idle {
                applySearchLivePreview(
                    text: message.searchProcessContent,
                    colors: cachedThemeColors ?? DSTheme.c,
                    thinkFont: cachedThinkingFontSize > 0
                        ? cachedThinkingFontSize
                        : SettingsManager.shared.chatThinkingFontSize,
                    waitingGlyph: glyph
                )
            } else if thinkingBox.isHidden, searchBox.isHidden {
                assistantLabel.text = glyph
            }
        }
        schedulePlainHeightNotify()
        return true
    }

    /// Ends the live state without changing the renderer currently visible in
    /// this cell. Rich tiles are adopted only on a later normal cell binding,
    /// after they are already available synchronously.
    func finalizeStreamingPresentation(_ message: ChatMessage) {
        guard messageID == message.id else { return }
        streamingPresentation = false
        let c = DSTheme.c
        let imageActivity = message.hasImageTranscription
        let search = (imageActivity
            ? message.imageTranscriptionDisplayText(pairedUser: pairedUserMessage)
            : message.searchProcessContent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !searchBox.isHidden {
            let title = imageActivity
                ? message.imageTranscriptionPhase.headerTitle
                : SearchProcessPhase.done.headerTitle
            applyChromeHeaderTitle(searchHeader, title: title, color: c.textSecondary)
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
        let img = ActionIconFactory.image(kind, pointSize: 17)
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
        thinkingHeaderH.constant = visible ? 32 : 0
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
        searchHeaderH.constant = visible ? 32 : 0
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
        nativeTopToRole.isActive = false
        nativeTopToImage.isActive = false
        nativeTopToThink.isActive = false

        let pinToStack = hasThinking || hasSearch
        if pinToStack {
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
        column.addSubview(imageViewMsg)

        searchBox.translatesAutoresizingMaskIntoConstraints = false
        searchBox.layer.cornerRadius = 10
        searchBox.layer.borderWidth = 0
        searchBox.clipsToBounds = true
        searchBox.isHidden = true
        column.addSubview(searchBox)

        searchHeader.translatesAutoresizingMaskIntoConstraints = false
        searchHeader.contentHorizontalAlignment = .left
        searchHeader.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        searchHeader.connectsSetContentInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        searchHeader.addTarget(self, action: #selector(openSearchChrome), for: .touchUpInside)
        searchBox.addSubview(searchHeader)

        searchBody.translatesAutoresizingMaskIntoConstraints = false
        searchBody.numberOfLines = 0
        searchBody.isHidden = true
        searchBox.addSubview(searchBody)

        thinkingBox.translatesAutoresizingMaskIntoConstraints = false
        thinkingBox.layer.cornerRadius = 10
        thinkingBox.layer.borderWidth = 0
        thinkingBox.clipsToBounds = true
        thinkingBox.isHidden = true
        column.addSubview(thinkingBox)

        thinkingHeader.translatesAutoresizingMaskIntoConstraints = false
        thinkingHeader.contentHorizontalAlignment = .left
        thinkingHeader.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
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
        actionChromeStack.spacing = 10
        actionChromeStack.alignment = .center
        actionChromeStack.distribution = .fill
        actionRow.addSubview(actionChromeStack)

        versionCluster.axis = .horizontal
        versionCluster.spacing = 2
        versionCluster.alignment = .center
        versionCluster.isHidden = true
        versionLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        versionLabel.textAlignment = .center
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        versionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        versionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

        for b in [versionPrevButton, versionNextButton, copyButton, retryButton, forkButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
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
        nativeHeight = nativeRenderView.heightAnchor.constraint(equalToConstant: 0)
        nativeTopToRole = nativeRenderView.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 0)
        nativeTopToImage = nativeRenderView.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 10)
        nativeTopToThink = nativeRenderView.topAnchor.constraint(equalTo: thinkingBox.bottomAnchor, constant: 10)
        nativeBottom = nativeRenderView.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -4)
        columnBottomToNative = column.bottomAnchor.constraint(equalTo: nativeRenderView.bottomAnchor)
        columnBottomToLabel = column.bottomAnchor.constraint(equalTo: assistantLabel.bottomAnchor)
        labelBottom = assistantLabel.bottomAnchor.constraint(equalTo: column.bottomAnchor)
        labelBottom.priority = UILayoutPriority(750)
        labelBottomFloor = column.bottomAnchor.constraint(greaterThanOrEqualTo: assistantLabel.bottomAnchor)

        assistantLabel.setContentHuggingPriority(.required, for: .vertical)
        searchBox.setContentHuggingPriority(.required, for: .vertical)
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
        nativeBottom.isActive = false
        columnBottomToNative.isActive = false
        columnBottomToLabel.isActive = false
        assistantTopToRole.isActive = false
        // Pre-draw glyphs once so first configure never waits on icon factory.
        styleActionIcons(DSTheme.c)
    }
}
