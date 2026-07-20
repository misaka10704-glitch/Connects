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
    private var copyLeadingToRow: NSLayoutConstraint!
    private var copyLeadingToPager: NSLayoutConstraint!
    private var thinkingHeaderH: NSLayoutConstraint!
    private var thinkingBoxH: NSLayoutConstraint!
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

    private var heightNotifyWork: DispatchWorkItem?
    private var hasThinking = false
    private var thinkingExpanded = false
    private var hasSearch = false
    private var searchExpanded = false
    private var imageTranscriptionFailed = false
    private var streamingPresentation = false
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
        guard !hasVisibleActionButtons else { return }
        refreshActionChrome(for: message, streaming: false, colors: cachedThemeColors ?? DSTheme.c)
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
        roleLabel.isHidden = true
        roleLabel.text = nil
        if message.hasImage {
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
        if hasVisibleNativePaint { return }
        paintOpenHistoryBody(with: message, layoutWidth: layoutWidth)
    }

    private func paintOpenHistoryBody(with message: ChatMessage, layoutWidth: CGFloat) {
        let c = DSTheme.c
        let font = SettingsManager.shared.chatBodyFontSize
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        roleLabel.isHidden = true
        roleLabel.text = nil
        if message.hasImage {
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
        paintOpenNativeBody(
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
        ensureActionButtonsVisible(for: message, requireBodyAlignment: true)
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
        paintOpenNativeBody(
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
        let priorAsync = nativeRenderView.layer.drawsAsynchronously
        nativeRenderView.layer.drawsAsynchronously = false
        configureNative(
            message: message,
            hasThinking: hasThinking,
            hasSearch: hasSearch,
            hasImage: hasImage,
            font: font,
            colors: colors,
            layoutWidth: layoutWidth,
            allowDefer: false
        )
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        nativeRenderView.layer.displayIfNeeded()
        nativeRenderView.layer.drawsAsynchronously = priorAsync
    }

    func syncThinkingPresentation(with message: ChatMessage, layoutWidth: CGFloat) {
        guard messageID == message.id else { return }
        preferredLayoutWidth = layoutWidth
        let c = DSTheme.c
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        cachedThinkingFontSize = thinkFont
        cachedThemeColors = c
        let think = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedReasoningText = think
        hasThinking = !think.isEmpty
        guard hasThinking else { return }
        thinkingExpanded = AssistantMessageLayout.isThinkingExpanded(messageID: message.id)
        populateThinkingBody(
            expanded: thinkingExpanded,
            streaming: message.isStreaming,
            colors: c,
            thinkFont: thinkFont
        )
        setThinking(visible: true, expanded: thinkingExpanded)
        let title = thinkingExpanded ? "▾  已深度思考" : "▸  已深度思考"
        thinkingHeader.setTitle(title, for: .normal)
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
        searchExpanded = AssistantMessageLayout.isSearchExpanded(messageID: message.id)
        if imageActivity {
            cachedSearchTitleCore = message.imageTranscriptionPhase.headerTitle
        } else {
            cachedSearchTitleCore = SearchProcessPhase.done.headerTitle
        }
        populateSearchBody(expanded: searchExpanded, colors: c, thinkFont: thinkFont)
        setSearch(visible: true, expanded: searchExpanded)
        let chevron = searchExpanded ? "▾" : "▸"
        searchHeader.setTitle("\(chevron)  \(cachedSearchTitleCore)", for: .normal)
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
        thinkingBody.attributedText = nil
        thinkingBody.text = nil
        searchBody.attributedText = nil
        searchBody.text = nil
        imageViewMsg.image = nil
        imageViewMsg.isHidden = true
        imageHeight.constant = 0
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
    }

    private var cachedImage: UIImage?

    func setCachedImage(_ image: UIImage?) {
        cachedImage = image
    }

    func applyCachedImageIfNeeded() {
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

    func finishChromeToggleLayout() {
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
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

        // Same row already painted native: skip teardown — kills Q↔A re-render flash.
        if !message.isStreaming,
           previousMessageID == message.id,
           hasVisibleNativePaint,
           freezeLayout,
           abs(lastNativeLayoutWidth - nativeLayoutWidth(for: layoutWidth)) < 1 {
            // No chrome/thinking relayout mid-gesture — prevents label shift and clip flash.
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

        if message.hasImage {
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
            labelBottom.isActive = true
            labelBottomFloor.isActive = true
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
                assistantLabel.text = message.content.isEmpty ? nil : message.content
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
        studyContentLeadingGutter = cellDelegate?.messageCellStudyContentLeadingGutter() ?? 0
        let c = DSTheme.c
        let font = SettingsManager.shared.chatBodyFontSize
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        roleLabel.isHidden = true
        roleLabel.text = nil

        if message.hasImage {
            imageViewMsg.image = cachedImage
            imageViewMsg.isHidden = cachedImage == nil
            imageHeight.constant = cachedImage != nil ? 160 : 0
        } else {
            imageViewMsg.image = nil
            imageViewMsg.isHidden = true
            imageHeight.constant = 0
        }

        applyAssistantChrome(
            message: message,
            colors: c,
            thinkFont: thinkFont,
            streaming: false,
            lightweightBodies: true,
            refreshActions: false
        )

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
    }

    private func applyAssistantChrome(message: ChatMessage,
                                      colors: ThemeColors,
                                      thinkFont: CGFloat,
                                      streaming: Bool,
                                      lightweightBodies: Bool = false,
                                      refreshActions: Bool = true) {
        let imageActivity = message.hasImageTranscription
        imageTranscriptionFailed = imageActivity && message.imageTranscriptionPhase == .failed
        let search = (imageActivity
            ? message.imageTranscriptionDisplayText(pairedUser: pairedUserMessage)
            : message.searchProcessContent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        cachedSearchText = search
        cachedImageActivity = imageActivity
        cachedImageTranscriptionPhase = message.imageTranscriptionPhase
        hasSearch = message.hasSearchProcess || imageActivity
        if hasSearch {
            let liveImageActivity = imageActivity && message.imageTranscriptionPhase == .transcribing
            let liveSearchActivity = !imageActivity && streaming && message.searchProcessPhase != .done
            let liveActivity = liveImageActivity || liveSearchActivity
            if liveActivity {
                searchExpanded = true
            } else {
                searchExpanded = AssistantMessageLayout.isSearchExpanded(messageID: message.id)
            }
            if imageActivity {
                cachedSearchTitleCore = message.imageTranscriptionPhase.headerTitle
            } else {
                cachedSearchTitleCore = liveSearchActivity
                    ? message.searchProcessPhase.headerTitle
                    : SearchProcessPhase.done.headerTitle
            }
            populateSearchBody(expanded: searchExpanded, colors: colors, thinkFont: thinkFont)
            setSearch(visible: true, expanded: searchExpanded)
            let chevron = searchExpanded ? "▾" : "▸"
            searchHeader.setTitle("\(chevron)  \(cachedSearchTitleCore)", for: .normal)
            searchHeader.setTitleColor(colors.textSecondary, for: .normal)
            searchBox.backgroundColor = colors.surface.withAlphaComponent(0.65)
            searchBox.layer.borderWidth = 0
        } else {
            setSearch(visible: false, expanded: false)
        }

        let think = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedReasoningText = think
        cachedThinkingFontSize = thinkFont
        cachedThemeColors = colors
        hasThinking = !think.isEmpty
        if hasThinking {
            if streaming {
                thinkingExpanded = true
            } else {
                thinkingExpanded = AssistantMessageLayout.isThinkingExpanded(messageID: message.id)
            }
            if lightweightBodies {
                applyThinkingLayoutWidth()
                if thinkingExpanded {
                    thinkingBody.attributedText = nil
                    thinkingBody.textColor = colors.textSecondary
                    thinkingBody.font = UIFont.systemFont(ofSize: thinkFont)
                    thinkingBody.text = cachedReasoningText
                } else {
                    thinkingBody.attributedText = nil
                    thinkingBody.text = nil
                }
            } else {
                populateThinkingBody(
                    expanded: thinkingExpanded,
                    streaming: streaming,
                    colors: colors,
                    thinkFont: thinkFont
                )
            }
            setThinking(visible: true, expanded: thinkingExpanded)
            let title = streaming && message.content.isEmpty
                ? (thinkingExpanded ? "▾  思考中…" : "▸  思考中…")
                : (thinkingExpanded ? "▾  已深度思考" : "▸  已深度思考")
            thinkingHeader.setTitle(title, for: .normal)
            thinkingHeader.setTitleColor(colors.textSecondary, for: .normal)
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
    private func refreshActionChrome(for message: ChatMessage,
                                     streaming: Bool? = nil,
                                     colors: ThemeColors? = nil) {
        let isStreaming = streaming ?? message.isStreaming
        let c = colors ?? cachedThemeColors ?? DSTheme.c
        let showAct = Self.shouldShowActionButtons(for: message, streaming: isStreaming)
        let layoutNow = cellDelegate?.messageCellShouldLayoutActionChromeNow(self) != false
        if !layoutNow {
            if showAct {
                reserveActionChromeSpace()
                lastChromeActionKey = "\(message.id)|scroll|reserved"
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
            !message.content.isEmpty
            || !message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || message.hasSearchProcess
            || message.hasImageTranscription
        )
    }

    /// True when the native body constraint matches the painted layout height.
    var isNativeBodyHeightAligned: Bool {
        guard !nativeRenderView.isHidden else { return true }
        guard let painted = nativeRenderView.paintedLayoutHeight, painted > 1 else { return false }
        return abs(nativeHeight.constant - ceil(painted)) <= 1.5
    }

    /// Pin native body height to the painted layout so action chrome sits flush under text.
    @discardableResult
    private func syncNativeBodyHeightToLayout() -> Bool {
        guard !nativeRenderView.isHidden else { return false }
        guard let painted = nativeRenderView.paintedLayoutHeight, painted > 1 else { return false }
        let target = ceil(painted)
        guard abs(nativeHeight.constant - target) > 0.5 else { return false }
        nativeHeight.constant = target
        return true
    }

    private func reconcileColumnBottomPinIfNeeded() {
        contentView.layoutIfNeeded()
        // Never squash the column into an underestimated UITableView row — that
        // clips action chrome and makes measuredContentHeight lie to the host.
        columnBottomPin.priority = UILayoutPriority(250)
    }

    /// Constraint-sum height before UITableView row compression.
    private func intrinsicColumnContentHeight() -> CGFloat {
        var total: CGFloat = 0
        if !imageViewMsg.isHidden, imageHeight.constant > 0.5 {
            total += imageHeight.constant
            if !nativeRenderView.isHidden || !assistantLabel.isHidden {
                total += 10
            }
        }
        if !searchBox.isHidden, searchBoxH.constant > 0.5 {
            total += searchBoxH.constant
            if total > 0, !thinkingBox.isHidden || !nativeRenderView.isHidden || !assistantLabel.isHidden {
                total += 10
            }
        }
        if !thinkingBox.isHidden, thinkingBoxH.constant > 0.5 {
            total += thinkingBoxH.constant
            if total > 0, !nativeRenderView.isHidden || !assistantLabel.isHidden {
                total += 10
            }
        }
        if !nativeRenderView.isHidden, nativeHeight.constant > 0.5 {
            total += nativeHeight.constant
        } else if !assistantLabel.isHidden {
            let width = max(column.bounds.width, 1)
            let labelH = assistantLabel.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            if labelH > 0.5 { total += labelH }
        }
        if !actionRow.isHidden, actionHeight.constant > 0.5 {
            if total > 0 { total += 4 }
            total += actionHeight.constant
        }
        return total
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
        if cellDelegate?.messageCellShouldLayoutActionChromeNow(self) == false {
            refreshActionChrome(
                for: message,
                streaming: message.isStreaming,
                colors: cachedThemeColors ?? DSTheme.c
            )
            return false
        }
        syncNativeBodyHeightToLayout()
        if requireBodyAlignment, !nativeRenderView.isHidden, !isNativeBodyHeightAligned {
            showActions(false)
            return false
        }
        let pager = message.showsVersionPager
        lastActionRowSignature = ""
        lastChromeActionKey = ""
        showActions(
            true,
            versionText: pager ? message.versionPagerText : nil,
            canPrev: pager && message.versionIndex > 0,
            canNext: pager && message.versionIndex < message.versions.count - 1
        )
        actionRow.alpha = 1
        styleActionIcons(cachedThemeColors ?? DSTheme.c)
        lastChromeActionKey = "\(message.id)|true|\(pager)|\(message.versionIndex)|\(message.versions.count)"
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        cellDelegate?.messageCellDidPaintContent(self)
        return true
    }

    /// True when finished-message action chrome is on and laid out.
    var hasVisibleActionButtons: Bool {
        !actionRow.isHidden && actionHeight.constant >= Self.actionRowVisibleHeight - 0.5
            && copyButton.image(for: .normal) != nil
            && !copyButton.isHidden
            && actionRow.alpha > 0.1
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
        searchBody.attributedText = nil
        searchBody.textColor = colors.textSecondary
        searchBody.font = UIFont.systemFont(ofSize: thinkFont)
        let body = cachedSearchText.isEmpty ? cachedSearchTitleCore : cachedSearchText
        searchBody.text = body
        if expanded {
            searchBody.isHidden = false
        }
    }

    func measuredColumnHeight() -> CGFloat {
        contentView.layoutIfNeeded()
        return column.bounds.height
    }

    private func applySearchLayoutWidth() {
        let width = max(column.bounds.width - 24, 80)
        if abs(searchBody.preferredMaxLayoutWidth - width) > 0.5 {
            searchBody.preferredMaxLayoutWidth = width
        }
    }

    private func populateThinkingBody(expanded: Bool,
                                      streaming: Bool,
                                      colors: ThemeColors,
                                      thinkFont: CGFloat) {
        applyThinkingLayoutWidth()
        guard expanded else {
            thinkingBody.attributedText = nil
            thinkingBody.text = nil
            return
        }
        if streaming {
            thinkingBody.attributedText = nil
            thinkingBody.textColor = colors.textSecondary
            thinkingBody.font = UIFont.systemFont(ofSize: thinkFont)
            thinkingBody.text = cachedReasoningText
        } else if cellDelegate?.messageCellShouldDeferHeavyRender(self) == true {
            thinkingBody.attributedText = nil
            thinkingBody.textColor = colors.textSecondary
            thinkingBody.font = UIFont.systemFont(ofSize: thinkFont)
            thinkingBody.text = cachedReasoningText
        } else {
            thinkingBody.attributedText = PlainMarkdown.attributed(
                cachedReasoningText,
                bodyFont: UIFont.systemFont(ofSize: thinkFont),
                textColor: colors.textSecondary,
                secondaryColor: colors.textTertiary
            )
        }
    }

    private func applyThinkingLayoutWidth() {
        let width = nativeLayoutWidth()
        if abs(thinkingBody.preferredMaxLayoutWidth - max(width - 24, 1)) > 0.5 {
            thinkingBody.preferredMaxLayoutWidth = max(width - 24, 1)
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

    /// `drawsAsynchronously` reduces open hitch but leaves scroll trails on iOS 12 — toggle per gesture.
    func setNativeAsyncDrawEnabled(_ enabled: Bool) {
        nativeRenderView.layer.drawsAsynchronously = enabled
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
            nativeMessageForRemeasure = message
            lastNativeLayoutWidth = width
            if hasCachedLayout,
               let height = nativeRenderView.bindCachedLayoutIfAvailable(
                   content: message.content,
                   width: width,
                   fontSize: font,
                   appearance: SettingsManager.shared.appearanceMode.rawValue,
                   colors: colors
               ) {
                nativeHeight.constant = height
                syncNativeBodyHeightToLayout()
                nativeRenderView.isHidden = false
                assistantLabel.isHidden = true
                assistantLabel.text = nil
                return
            }
            configurePlainFallback(
                message: message,
                hasThinking: hasThinking,
                hasSearch: hasSearch,
                hasImage: hasImage,
                font: font,
                colors: colors,
                scheduleHeightNotify: false,
                allowTruncate: cellDelegate?.messageCellShouldTruncatePlainBody(self) == true
            )
            return
        }
        deferredNativeBind = nil
        bindNativeBodyLayout(hasThinking: hasThinking, hasSearch: hasSearch, hasImage: hasImage)
        nativeMessageForRemeasure = message
        lastNativeLayoutWidth = width
        let renderResult = nativeRenderView.configure(
            content: message.content,
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
        nativeBottom.isActive = true
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
        assistantTopToRole.isActive = false
        assistantTopToImage.isActive = false
        assistantTopToThink.isActive = false
        setContentTops(hasThinking: hasThinking, hasSearch: hasSearch, hasImage: hasImage)
        assistantLabel.attributedText = nil
        assistantLabel.textColor = colors.textPrimary
        assistantLabel.font = UIFont.systemFont(ofSize: font)
        // Long plain UILabel layout hitches scroll; truncate only on the deferred path.
        let content = message.content
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
        let laidOut = column.bounds.height
        let intrinsic = intrinsicColumnContentHeight()
        // Only override when UITableView is compressing the column (clip risk).
        if intrinsic > laidOut + 2 { return intrinsic }
        return laidOut
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
            let height = self.column.bounds.height
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
    }

    /// Updates the already-bound streaming view without resetting constraints,
    /// renderer state, or action visibility on every token batch.
    @discardableResult
    func updateStreamingContent(_ message: ChatMessage, waitingGlyph: String? = nil) -> Bool {
        let searchEmpty = message.searchProcessContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.hasSearchProcess
            && message.imageTranscriptionContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.hasImageTranscription
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
        let content = message.content
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
            searchBody.attributedText = nil
            searchBody.text = search
            let titleCore = imageActivity
                ? message.imageTranscriptionPhase.headerTitle
                : (message.searchProcessPhase != .done
                    ? message.searchProcessPhase.headerTitle
                    : SearchProcessPhase.done.headerTitle)
            let chevron = searchExpanded ? "▾" : "▸"
            searchHeader.setTitle("\(chevron)  \(titleCore)", for: .normal)
        }
        if !thinkingBox.isHidden {
            thinkingBody.attributedText = nil
            // Laying out an ever-growing 10k+ character UILabel on every frame
            // overwhelms first-generation iPad Air. During generation show a
            // rolling window; the complete reasoning remains stored and is
            // available after the stream finishes.
            let reasoning = message.reasoningContent
            let liveLimit = 2_400
            thinkingBody.text = reasoning.count > liveLimit
                ? "…\n" + String(reasoning.suffix(liveLimit))
                : reasoning
            let chevron = thinkingExpanded ? "▾" : "▸"
            thinkingHeader.setTitle(
                content.isEmpty ? "\(chevron)  思考中…" : "\(chevron)  已深度思考",
                for: .normal
            )
        }
        if let glyph = waitingGlyph {
            if !content.isEmpty {
                assistantLabel.text = content + "  " + glyph
            } else if !thinkingBox.isHidden {
                thinkingBody.text = (thinkingBody.text ?? "") + "  " + glyph
            } else if !searchBox.isHidden {
                searchBody.text = (searchBody.text ?? "") + "  " + glyph
            } else {
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
        if !search.isEmpty {
            let chevron = searchExpanded ? "▾" : "▸"
            let title = imageActivity
                ? message.imageTranscriptionPhase.headerTitle
                : SearchProcessPhase.done.headerTitle
            searchHeader.setTitle("\(chevron)  \(title)", for: .normal)
        }
        let think = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !think.isEmpty {
            thinkingHeader.setTitle(thinkingExpanded ? "▾  已深度思考" : "▸  已深度思考", for: .normal)
        }
        let pager = message.showsVersionPager
        showActions(
            !message.content.isEmpty || !think.isEmpty || !search.isEmpty,
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
        if message.hasImageTranscription {
            let display = message.imageTranscriptionDisplayText(pairedUser: pairedUserMessage)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !display.isEmpty, !ImageDurableText.isStatusOnly(display) {
                AssistantMessageLayout.setSearchExpanded(true, messageID: message.id)
            }
        }
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
        if abs(thinkingBody.preferredMaxLayoutWidth - max(w - 24, 1)) > 0.5 {
            thinkingBody.preferredMaxLayoutWidth = max(w - 24, 1)
        }
        if abs(searchBody.preferredMaxLayoutWidth - max(w - 24, 1)) > 0.5 {
            searchBody.preferredMaxLayoutWidth = max(w - 24, 1)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = max(column.bounds.width, 1)
        if abs(assistantLabel.preferredMaxLayoutWidth - w) > 0.5 {
            assistantLabel.preferredMaxLayoutWidth = w
        }
        if abs(thinkingBody.preferredMaxLayoutWidth - max(w - 24, 1)) > 0.5 {
            thinkingBody.preferredMaxLayoutWidth = max(w - 24, 1)
        }
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

    /// Hold action-row height during scroll without painting icons (prevents settle pop-in).
    private func reserveActionChromeSpace() {
        if actionHeight.constant < Self.actionRowVisibleHeight - 0.5 {
            actionHeight.constant = Self.actionRowVisibleHeight
        }
        actionRow.isHidden = false
        actionRow.alpha = 0.02
        copyButton.isHidden = true
        retryButton.isHidden = true
        forkButton.isHidden = true
        versionCluster.isHidden = true
        versionPrevButton.isHidden = true
        versionNextButton.isHidden = true
        versionLabel.isHidden = true
    }

    private func showActions(_ on: Bool, versionText: String? = nil, canPrev: Bool = false, canNext: Bool = false) {
        let signature = actionSignature(on: on, versionText: versionText, canPrev: canPrev, canNext: canNext)
        if signature == lastActionRowSignature,
           actionRow.isHidden == !on,
           abs(actionHeight.constant - (on ? Self.actionRowVisibleHeight : 0)) < 0.5 {
            return
        }
        lastActionRowSignature = signature
        actionRow.isHidden = !on
        actionHeight.constant = on ? Self.actionRowVisibleHeight : 0
        actionRow.alpha = on ? 1 : 1
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
        copyLeadingToRow.isActive = !showPager
        copyLeadingToPager.isActive = showPager
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
                thinkingBody.isHidden = true
                thinkingToHeader.isActive = true
                thinkingToBody.isActive = false
            }
        } else {
            thinkingBody.isHidden = true
            thinkingToHeader.isActive = false
            thinkingToBody.isActive = false
            thinkingBoxH.constant = 0
            thinkingBoxH.isActive = true
            thinkingBody.attributedText = nil
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
                searchBody.isHidden = true
                searchToHeader.isActive = true
                searchToBody.isActive = false
            }
        } else {
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

    @objc private func toggleThink() {
        guard hasThinking else { return }
        thinkingExpanded.toggle()
        if thinkingExpanded { AssistantMessageLayout.setThinkingExpanded(true, messageID: messageID) }
        else { AssistantMessageLayout.setThinkingExpanded(false, messageID: messageID) }
        let c = cachedThemeColors ?? DSTheme.c
        populateThinkingBody(
            expanded: thinkingExpanded,
            streaming: false,
            colors: c,
            thinkFont: cachedThinkingFontSize
        )
        setThinking(visible: true, expanded: thinkingExpanded)
        let title = thinkingExpanded ? "▾  已深度思考" : "▸  已深度思考"
        thinkingHeader.setTitle(title, for: .normal)
        finishChromeToggleLayout()
        NotificationCenter.default.post(
            name: Notification.Name("ConnectsThinkingToggle"),
            object: nil,
            userInfo: ["messageID": messageID]
        )
    }

    @objc private func toggleSearch() {
        guard hasSearch else { return }
        if imageTranscriptionFailed {
            NotificationCenter.default.post(
                name: Notification.Name("ConnectsImageTranscriptionRetry"),
                object: nil,
                userInfo: ["messageID": messageID]
            )
            return
        }
        searchExpanded.toggle()
        if searchExpanded { AssistantMessageLayout.setSearchExpanded(true, messageID: messageID) }
        else { AssistantMessageLayout.setSearchExpanded(false, messageID: messageID) }
        let c = cachedThemeColors ?? DSTheme.c
        let thinkFont = cachedThinkingFontSize > 0
            ? cachedThinkingFontSize
            : SettingsManager.shared.chatThinkingFontSize
        populateSearchBody(expanded: searchExpanded, colors: c, thinkFont: thinkFont)
        setSearch(visible: true, expanded: searchExpanded)
        let chevron = searchExpanded ? "▾" : "▸"
        searchHeader.setTitle("\(chevron)  \(cachedSearchTitleCore)", for: .normal)
        finishChromeToggleLayout()
        if searchExpanded {
            scheduleMeasuredHeightNotify(for: messageID)
        }
        NotificationCenter.default.post(
            name: Notification.Name("ConnectsSearchToggle"),
            object: nil,
            userInfo: ["messageID": messageID]
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
        searchHeader.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        searchHeader.addTarget(self, action: #selector(toggleSearch), for: .touchUpInside)
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
        thinkingHeader.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        thinkingHeader.addTarget(self, action: #selector(toggleThink), for: .touchUpInside)
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
        nativeRenderView.onHeightChange = { [weak self] height in
            guard let self = self, !self.messageID.isEmpty else { return }
            self.nativeHeight.constant = height
            self.contentView.layoutIfNeeded()
            let columnH = self.measuredContentHeight()
            guard columnH > 40 else { return }
            // Formula warm-up must grow frozen rows — scheduleMeasuredHeightNotify is blocked mid-gesture.
            self.cellDelegate?.messageCell(self, didFinishStableRender: columnH, for: self.messageID)
        }
        column.addSubview(nativeRenderView)

        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionRow.isHidden = true
        column.addSubview(actionRow)

        versionCluster.translatesAutoresizingMaskIntoConstraints = false
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
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        versionCluster.addArrangedSubview(versionPrevButton)
        versionCluster.addArrangedSubview(versionLabel)
        versionCluster.addArrangedSubview(versionNextButton)
        actionRow.addSubview(versionCluster)
        for b in [copyButton, retryButton, forkButton] {
            actionRow.addSubview(b)
        }
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        forkButton.addTarget(self, action: #selector(forkTapped), for: .touchUpInside)
        versionPrevButton.addTarget(self, action: #selector(versionPrevTapped), for: .touchUpInside)
        versionNextButton.addTarget(self, action: #selector(versionNextTapped), for: .touchUpInside)

        copyLeadingToRow = copyButton.leadingAnchor.constraint(equalTo: actionRow.leadingAnchor)
        copyLeadingToPager = copyButton.leadingAnchor.constraint(equalTo: versionCluster.trailingAnchor, constant: 4)
        copyLeadingToRow.isActive = true
        NSLayoutConstraint.activate([
            versionCluster.leadingAnchor.constraint(equalTo: actionRow.leadingAnchor),
            versionCluster.centerYAnchor.constraint(equalTo: actionRow.centerYAnchor),
            copyButton.centerYAnchor.constraint(equalTo: actionRow.centerYAnchor),
            retryButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 4),
            retryButton.centerYAnchor.constraint(equalTo: actionRow.centerYAnchor),
            forkButton.leadingAnchor.constraint(equalTo: retryButton.trailingAnchor, constant: 4),
            forkButton.centerYAnchor.constraint(equalTo: actionRow.centerYAnchor),
            forkButton.trailingAnchor.constraint(lessThanOrEqualTo: actionRow.trailingAnchor)
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

        thinkingHeaderH = thinkingHeader.heightAnchor.constraint(equalToConstant: 0)
        thinkingBoxH = thinkingBox.heightAnchor.constraint(equalToConstant: 0)
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
        labelBottom = assistantLabel.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -4)
        labelBottom.priority = UILayoutPriority(750)
        labelBottomFloor = actionRow.topAnchor.constraint(greaterThanOrEqualTo: assistantLabel.bottomAnchor, constant: 4)

        assistantLabel.setContentHuggingPriority(.required, for: .vertical)
        searchBox.setContentHuggingPriority(.required, for: .vertical)
        thinkingBox.setContentHuggingPriority(.required, for: .vertical)
        column.setContentHuggingPriority(.required, for: .vertical)
        column.setContentCompressionResistancePriority(.required, for: .vertical)
        contentView.setContentHuggingPriority(.required, for: .vertical)

        // Never stretch the column to fill an oversized UITableView estimate.
        let inset = ChatRowHeightResolver.cellContentInset
        let columnBottomPin = contentView.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: inset)
        columnBottomPin.priority = UILayoutPriority(250)
        self.columnBottomPin = columnBottomPin

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
            nativeBottom,

            actionRow.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            actionRow.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            actionRow.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            actionHeight
        ])
        // Default inactive pair ends — configure() enables the right set
        labelBottom.isActive = false
        labelBottomFloor.isActive = false
        nativeTopToRole.isActive = false
        nativeTopToImage.isActive = false
        nativeTopToThink.isActive = false
        nativeBottom.isActive = false
        assistantTopToRole.isActive = false
        // Pre-draw glyphs once so first configure never waits on icon factory.
        styleActionIcons(DSTheme.c)
    }
}
