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
    private var cachedThinkingFontSize: CGFloat = 14
    private var cachedThemeColors: ThemeColors?
    private var preferredLayoutWidth: CGFloat = 0
    private var configuredPreferredHeight: CGFloat?
    private var deferredNativeBind: DeferredNativeBind?
    private var nativeMessageForRemeasure: ChatMessage?
    private var lastActionSignature = ""

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

    func syncSearchPresentation(with message: ChatMessage, layoutWidth: CGFloat) {
        guard messageID == message.id else { return }
        preferredLayoutWidth = layoutWidth
        let c = DSTheme.c
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        cachedThinkingFontSize = thinkFont
        cachedThemeColors = c
        let imageActivity = message.hasImageTranscription
        let search = (imageActivity
            ? message.imageTranscriptionContent
            : message.searchProcessContent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        cachedSearchText = search
        cachedImageActivity = imageActivity
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
        if cellDelegate?.messageCellShouldFreezeHeight(self) == true {
            messageID = ""
            deferredNativeBind = nil
            configuredPreferredHeight = nil
            return
        }
        messageID = ""
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
        deferredNativeBind = nil
        lastActionSignature = ""
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
        if !suppressHeightNotify {
            scheduleMeasuredHeightNotify(for: messageID)
        }
    }

    func finishChromeToggleLayout() {
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
    }

    func configure(with message: ChatMessage, preferredHeight: CGFloat?, layoutWidth: CGFloat) {
        let previousMessageID = messageID
        let freezeLayout = cellDelegate?.messageCellShouldFreezeHeight(self) == true
        messageID = message.id
        preferredLayoutWidth = layoutWidth
        configuredPreferredHeight = preferredHeight

        guard message.role == .assistant else { return }

        // Scrolling the same painted row: skip full constraint teardown (Q↔A boundary hitch).
        if !message.isStreaming,
           previousMessageID == message.id,
           freezeLayout,
           hasVisibleAssistantBody() {
            return
        }

        // Mid-scroll reuse into a different assistant: keep chrome cheap, body = plain or cached native.
        if !message.isStreaming, freezeLayout, previousMessageID != message.id {
            configureWhileScrolling(message: message, layoutWidth: layoutWidth)
            return
        }

        let deferHeavyRender = cellDelegate?.messageCellShouldDeferHeavyRender(self) == true
        streamingPresentation = message.isStreaming
        let c = DSTheme.c
        let font = SettingsManager.shared.chatBodyFontSize
        let thinkFont = SettingsManager.shared.chatThinkingFontSize

        // ChatGPT-like: no per-turn role chrome — alignment + bubble carry identity
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

        applyAssistantChrome(message: message, colors: c, thinkFont: thinkFont, streaming: message.isStreaming)

        let hasImage = !imageViewMsg.isHidden

        if !message.isStreaming,
           deferredNativeBind != nil,
           AssistantMessageLayout.hasCachedNativeLayout(for: message, layoutWidth: layoutWidth) {
            applyDeferredNativeRenderIfNeeded()
            return
        }

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
                layoutWidth: layoutWidth
            )
        }
    }

    /// Lightweight path for UITableView reuse while the finger is down.
    private func configureWhileScrolling(message: ChatMessage, layoutWidth: CGFloat) {
        streamingPresentation = false
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
            lightweightBodies: true
        )

        let hasImage = !imageViewMsg.isHidden
        let deferHeavy = cellDelegate?.messageCellShouldDeferHeavyRender(self) == true
        let cacheReady = AssistantMessageLayout.hasCachedNativeLayout(for: message, layoutWidth: layoutWidth)
        if !deferHeavy, cacheReady {
            configureNative(
                message: message,
                hasThinking: hasThinking,
                hasSearch: hasSearch,
                hasImage: hasImage,
                font: font,
                colors: c,
                layoutWidth: layoutWidth,
                allowDefer: false
            )
        } else {
            deferredNativeBind = DeferredNativeBind(
                message: message,
                hasThinking: hasThinking,
                hasSearch: hasSearch,
                hasImage: hasImage,
                font: font,
                colors: c,
                layoutWidth: layoutWidth
            )
            configurePlainFallback(
                message: message,
                hasThinking: hasThinking,
                hasSearch: hasSearch,
                hasImage: hasImage,
                font: font,
                colors: c,
                scheduleHeightNotify: false
            )
        }
    }

    private func applyAssistantChrome(message: ChatMessage,
                                      colors: ThemeColors,
                                      thinkFont: CGFloat,
                                      streaming: Bool,
                                      lightweightBodies: Bool = false) {
        let imageActivity = message.hasImageTranscription
        imageTranscriptionFailed = imageActivity && message.imageTranscriptionPhase == .failed
        let search = (imageActivity
            ? message.imageTranscriptionContent
            : message.searchProcessContent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        cachedSearchText = search
        cachedImageActivity = imageActivity
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

        let showAct = !streaming && (!message.content.isEmpty || hasThinking || hasSearch)
        let pager = message.showsVersionPager
        let signature = "\(showAct)|\(pager)|\(message.versionIndex)|\(message.versions.count)"
        if signature != lastActionSignature {
            showActions(
                showAct,
                versionText: pager ? message.versionPagerText : nil,
                canPrev: pager && message.versionIndex > 0,
                canNext: pager && message.versionIndex < message.versions.count - 1
            )
            if showAct, !lightweightBodies {
                styleActionIcons(colors)
            }
            lastActionSignature = signature
        } else if showAct, actionHeight.constant < 1 {
            showActions(
                true,
                versionText: pager ? message.versionPagerText : nil,
                canPrev: pager && message.versionIndex > 0,
                canNext: pager && message.versionIndex < message.versions.count - 1
            )
        }
    }

    private func populateSearchBody(expanded: Bool,
                                    colors: ThemeColors,
                                    thinkFont: CGFloat) {
        applySearchLayoutWidth()
        searchBody.attributedText = nil
        searchBody.textColor = colors.textSecondary
        searchBody.font = UIFont.systemFont(ofSize: thinkFont)
        searchBody.text = cachedSearchText.isEmpty ? cachedSearchTitleCore : cachedSearchText
        if expanded {
            searchBody.isHidden = false
        }
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
        let reference = layoutWidth ?? preferredLayoutWidth
        let cellWidth = max(contentView.bounds.width, bounds.width, reference, 120)
        return min(DSTheme.bubbleMaxWidth, max(cellWidth - 48, 120))
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
        let scrolling = allowDefer && cellDelegate?.messageCellShouldDeferHeavyRender(self) == true
        if scrolling {
            deferredNativeBind = DeferredNativeBind(
                message: message,
                hasThinking: hasThinking,
                hasSearch: hasSearch,
                hasImage: hasImage,
                font: font,
                colors: colors,
                layoutWidth: layoutWidth
            )
            configurePlainFallback(
                message: message,
                hasThinking: hasThinking,
                hasSearch: hasSearch,
                hasImage: hasImage,
                font: font,
                colors: colors,
                scheduleHeightNotify: false
            )
            return
        }
        deferredNativeBind = nil
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
        nativeRenderView.isHidden = false
        if !renderResult.isProvisional {
            scheduleMeasuredHeightNotify(for: message.id)
        }
    }

    private func nativeLayoutIsCached(message: ChatMessage,
                                      width: CGFloat,
                                      font: CGFloat,
                                      colors: ThemeColors) -> Bool {
        let document = NativeMarkdownParser.shared.parse(message.content)
        let style = NativeLayoutStyle(
            width: width,
            bodyFontSize: font,
            appearance: SettingsManager.shared.appearanceMode.rawValue,
            colors: colors
        )
        return NativeMessageLayouter.shared.cachedLayout(document: document, style: style) != nil
    }

    private func hasVisibleAssistantBody() -> Bool {
        if !nativeRenderView.isHidden { return true }
        if !assistantLabel.isHidden {
            let text = assistantLabel.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { return true }
        }
        return false
    }

    private func configurePlainFallback(message: ChatMessage,
                                        hasThinking: Bool,
                                        hasSearch: Bool,
                                        hasImage: Bool,
                                        font: CGFloat,
                                        colors: ThemeColors,
                                        scheduleHeightNotify: Bool = true) {
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
        if !scheduleHeightNotify, content.count > 900 {
            assistantLabel.text = String(content.prefix(900)) + "\n…"
        } else {
            assistantLabel.text = content
        }
        applyAssistantLayoutWidth()
        if scheduleHeightNotify {
            scheduleMeasuredHeightNotify(for: message.id)
        }
    }

    /// Push the column's intrinsic height back to the table. iOS 12 can keep an
    /// oversized estimated row and stretch this cell unless we remeasure after
    /// configure — especially for reasoning/search chrome and user bubbles.
    /// Column content height used for UITableView self-sizing.
    func measuredContentHeight() -> CGFloat {
        contentView.layoutIfNeeded()
        return column.bounds.height
    }

    private func scheduleMeasuredHeightNotify(for messageID: String,
                                              allowWhileProvisional: Bool = true) {
        guard allowWhileProvisional else { return }
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
        column.layer.borderWidth = on ? 1 / UIScreen.main.scale : 0
        column.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.45).cgColor
        nativeRenderView.layer.borderWidth = on && !nativeRenderView.isHidden ? 1 / UIScreen.main.scale : 0
        nativeRenderView.layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.45).cgColor
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
        guard messageID == message.id,
              message.isStreaming,
              !assistantLabel.isHidden,
              (thinkingBox.isHidden == thinkEmpty),
              (searchBox.isHidden == searchEmpty) else {
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
                ? message.imageTranscriptionContent
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
            ? message.imageTranscriptionContent
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
    func transitionToFinishedPlainRendering(_ message: ChatMessage, preferredHeight: CGFloat?) -> CGFloat? {
        guard messageID == message.id,
              !message.isStreaming else { return nil }
        let cover = contentView.snapshotView(afterScreenUpdates: false)
        if let cover = cover {
            cover.frame = contentView.bounds
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.isUserInteractionEnabled = false
            contentView.addSubview(cover)
        }
        configure(with: message, preferredHeight: preferredHeight, layoutWidth: preferredLayoutWidth > 0 ? preferredLayoutWidth : nativeLayoutWidth())
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        let measured = column.bounds.height
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

    private func showActions(_ on: Bool, versionText: String? = nil, canPrev: Bool = false, canNext: Bool = false) {
        let signature = actionSignature(on: on, versionText: versionText, canPrev: canPrev, canNext: canNext)
        if signature == lastActionSignature, actionRow.isHidden == !on {
            return
        }
        lastActionSignature = signature
        actionRow.isHidden = !on
        actionHeight.constant = on ? Self.actionRowVisibleHeight : 0
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
            self.scheduleMeasuredHeightNotify(for: self.messageID)
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

        assistantTopToRole = assistantLabel.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 8)
        assistantTopToImage = assistantLabel.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 10)
        assistantTopToThink = assistantLabel.topAnchor.constraint(equalTo: thinkingBox.bottomAnchor, constant: 10)
        nativeHeight = nativeRenderView.heightAnchor.constraint(equalToConstant: 0)
        nativeTopToRole = nativeRenderView.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 8)
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
        columnBottomPin.priority = UILayoutPriority(999)
        self.columnBottomPin = columnBottomPin

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: inset),
            columnBottomPin,
            column.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            columnWidthFill,
            columnWidthMax,

            roleLabel.topAnchor.constraint(equalTo: column.topAnchor),
            roleLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            roleLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            roleLabel.heightAnchor.constraint(equalToConstant: 0),

            imageViewMsg.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 8),
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
    }
}
