import UIKit
import WebKit
import ObjectiveC

protocol MessageCellDelegate: AnyObject {
    func messageCell(_ cell: MessageCell, didUpdateHeight height: CGFloat, for messageID: String)
    func messageCell(_ cell: MessageCell, didFinishStableRender height: CGFloat, for messageID: String)
    func messageCellDidTapCopy(_ cell: MessageCell, messageID: String)
    func messageCellDidTapRetry(_ cell: MessageCell, messageID: String)
    func messageCellDidTapFork(_ cell: MessageCell, messageID: String)
    func messageCellDidShiftVersion(_ cell: MessageCell, messageID: String, delta: Int)
    /// When true, cell must not change webHeight / notify (prevents scroll flicker).
    func messageCellShouldFreezeHeight(_ cell: MessageCell) -> Bool
}

extension MessageCellDelegate {
    func messageCellShouldFreezeHeight(_ cell: MessageCell) -> Bool { false }
    func messageCell(_ cell: MessageCell, didFinishStableRender height: CGFloat, for messageID: String) {}
}

/// ChatGPT-style layout: centered column, user bubble right, assistant prose + collapsible thinking + icon actions.
final class MessageCell: UITableViewCell, WKScriptMessageHandler, WKNavigationDelegate {
    static let reuseID = "MessageCell"
    private static var expandedThinkingIDs = Set<String>()
    private static var expandedSearchIDs = Set<String>()
    /// Briefly shown while a recycled WKWebView restores an already-seen reply.
    /// This avoids blank/old-content flashes during table-cell reuse.
    private static let webSnapshots: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // Recent conversation switches should be memory-only. Decoding JPEG files
        // synchronously while UITableView is rebinding cells stalls iPad Air 1.
        cache.countLimit = 32
        cache.totalCostLimit = 40 * 1024 * 1024
        return cache
    }()
    private static var snapshotWaiters: [String: [(UIImage?) -> Void]] = [:]
    private static var nextRichRenderStart: TimeInterval = 0

    weak var cellDelegate: MessageCellDelegate?
    private(set) var messageID: String = ""

    private let column = UIView()
    private let roleLabel = UILabel()
    private let userBubble = UIView()
    private let userLabel = UILabel()
    private let imageViewMsg = UIImageView()

    private let thinkingHeader = UIButton(type: .system)
    private let thinkingBody = UILabel()
    private let thinkingBox = UIView()

    private let searchHeader = UIButton(type: .system)
    private let searchBody = UILabel()
    private let searchBox = UIView()

    private let assistantLabel = UILabel()
    private let nativeRenderView = NativeMessageRenderView()
    private let renderedReplyView = UIStackView()
    private var webView: WKWebView?
    private var webSnapshotView: UIImageView?
    private var webHeight: NSLayoutConstraint?

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
    private var userTopToRole: NSLayoutConstraint!
    private var userTopToImage: NSLayoutConstraint!
    private var userBubbleBottom: NSLayoutConstraint!
    private var userBubbleBottomFloor: NSLayoutConstraint!
    private var thinkingTop: NSLayoutConstraint!
    private var webBottom: NSLayoutConstraint?
    private var webTopToRole: NSLayoutConstraint?
    private var webTopToImage: NSLayoutConstraint?
    private var webTopToThink: NSLayoutConstraint?
    private var labelBottom: NSLayoutConstraint!
    private var labelBottomFloor: NSLayoutConstraint!
    private var renderedTopToRole: NSLayoutConstraint!
    private var renderedTopToImage: NSLayoutConstraint!
    private var renderedTopToThink: NSLayoutConstraint!
    private var renderedBottom: NSLayoutConstraint!
    private var nativeHeight: NSLayoutConstraint!
    private var nativeTopToRole: NSLayoutConstraint!
    private var nativeTopToImage: NSLayoutConstraint!
    private var nativeTopToThink: NSLayoutConstraint!
    private var nativeBottom: NSLayoutConstraint!
    private var columnBottom: NSLayoutConstraint!

    private var lastHTMLKey: String?
    private var usesWeb = false
    private var hasThinking = false
    private var thinkingExpanded = false
    private var hasSearch = false
    private var searchExpanded = false
    private var streamingPresentation = false
    /// Shell document loaded (katex/marked ready).
    private var webShellReady = false
    private var injectRetryWork: DispatchWorkItem?
    private var injectRetryCount = 0
    private static let maxInjectRetries = 8
    private var shellThemeKey: String?
    private var pendingMarkdown: String?
    private var pendingHTMLKey: String?
    private var renderGeneration: UInt = 0
    private var showingWebContent = false
    private var heightNotifyWork: DispatchWorkItem?
    private var widthRemeasureWork: DispatchWorkItem?
    /// Column width used for the last successful height measurement.
    private var lastMeasuredColumnWidth: CGFloat = 0
    /// Height measured while scrolling — applied when freeze lifts.
    private var deferredWebHeight: CGFloat?
    /// Safe temporary height used while a width transition waits for WebKit reflow.
    private var provisionalWebHeight: CGFloat = 120
    private var stableRenderKey: String?
    private var hasExactStableRender = false
    private var displayedStableKey: String?

    /// True when rich mode is active but content is still blank (cold-open race).
    var needsColdOpenRescue: Bool {
        guard usesWeb, !messageID.isEmpty else { return false }
        if pendingMarkdown != nil { return true }
        if showingWebContent, (webHeight?.constant ?? 0) < 28 { return true }
        if showingWebContent, (webView?.alpha ?? 0) < 0.5 { return true }
        return false
    }

    /// Retry a stuck cold-open inject from ChatVC.
    func retryColdOpenIfNeeded() {
        guard usesWeb, let md = pendingMarkdown, let key = pendingHTMLKey else {
            if usesWeb, webShellReady, lastHTMLKey != nil {
                requestWebRemeasure(force: true)
            }
            return
        }
        _ = md
        _ = key
        injectRetryCount = 0
        if webShellReady {
            injectPendingMarkdown(generation: renderGeneration)
        } else {
            scheduleInjectRetry(generation: renderGeneration)
        }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }

    private struct Assoc { static var h: UInt8 = 0 }

    override func prepareForReuse() {
        super.prepareForReuse()
        messageID = ""
        streamingPresentation = false
        // Cancel in-flight JS callbacks for the previous identity.
        renderGeneration &+= 1
        heightNotifyWork?.cancel()
        heightNotifyWork = nil
        widthRemeasureWork?.cancel()
        pendingMarkdown = nil
        pendingHTMLKey = nil
        deferredWebHeight = nil
        stableRenderKey = nil
        hasExactStableRender = false
        displayedStableKey = nil
        resetWebScrollPosition()
        // Do NOT parkWeb / hide WKWebView here — that blanks cells during scroll recycle
        // and causes the flash. configure() parks when the new row is not rich web.
        userLabel.text = nil
        assistantLabel.attributedText = nil
        assistantLabel.text = nil
        renderedReplyView.isHidden = true
        renderedReplyView.arrangedSubviews.forEach {
            renderedReplyView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
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
        userBubble.isHidden = true
        assistantLabel.isHidden = true
        hideNativeRender()
        webSnapshotView?.image = nil
        webSnapshotView?.isHidden = true
        cachedImage = nil
    }

    private var cachedImage: UIImage?

    func setCachedImage(_ image: UIImage?) {
        cachedImage = image
    }

    /// Parse and lay out nearby finished replies before they enter the viewport.
    static func prewarmSnapshots(for messages: [ChatMessage], targetWidth: CGFloat? = nil) {
        for message in messages.suffix(4)
            where message.role == .assistant &&
                  !message.isStreaming {
            _ = NativeMarkdownParser.shared.parse(message.content)
        }
        _ = targetWidth
    }

    func configure(with message: ChatMessage, preferredHeight: CGFloat?) {
        messageID = message.id
        streamingPresentation = message.isStreaming
        let c = DSTheme.c
        let font = SettingsManager.shared.chatBodyFontSize
        let thinkFont = SettingsManager.shared.chatThinkingFontSize

        // ChatGPT-like: no per-turn role chrome — alignment + bubble carry identity
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
            cachedImage = nil
        }

        if message.role == .user {
            userBubble.isHidden = false
            userBubble.backgroundColor = c.userBubble
            userBubble.layer.cornerRadius = DSTheme.bubbleCornerRadius
            assistantLabel.isHidden = true
            stableRenderKey = nil
            hideStableRenderedReply()
            hideNativeRender()
            parkWeb()
            setThinking(visible: false, expanded: false)
            setSearch(visible: false, expanded: false)
            showActions(false)
            userLabel.textColor = c.textPrimary
            userLabel.font = UIFont.systemFont(ofSize: font)
            userLabel.text = message.content.isEmpty && message.hasImage ? nil : message.content

            assistantTopToRole.isActive = false
            assistantTopToImage.isActive = false
            assistantTopToThink.isActive = false
            labelBottom.isActive = false
            labelBottomFloor.isActive = false
            userBubbleBottom.isActive = true
            userBubbleBottomFloor.isActive = true
            userTopToRole.isActive = imageViewMsg.isHidden
            userTopToImage.isActive = !imageViewMsg.isHidden
            return
        }

        // Assistant
        userBubble.isHidden = true
        userTopToRole.isActive = false
        userTopToImage.isActive = false
        userBubbleBottom.isActive = false
        userBubbleBottomFloor.isActive = false

        let search = message.searchProcessContent.trimmingCharacters(in: .whitespacesAndNewlines)
        hasSearch = message.hasSearchProcess
        if hasSearch {
            if message.isStreaming, message.searchProcessPhase != .done {
                searchExpanded = true
            } else {
                searchExpanded = MessageCell.expandedSearchIDs.contains(message.id)
            }
            setSearch(visible: true, expanded: searchExpanded)
            let live = message.isStreaming && message.searchProcessPhase != .done
            let titleCore = live ? message.searchProcessPhase.headerTitle : SearchProcessPhase.done.headerTitle
            let chevron = searchExpanded ? "▾" : "▸"
            searchHeader.setTitle("\(chevron)  \(titleCore)", for: .normal)
            searchHeader.setTitleColor(c.textSecondary, for: .normal)
            searchBox.backgroundColor = c.surface.withAlphaComponent(0.65)
            searchBox.layer.borderWidth = 0
            if searchExpanded {
                searchBody.attributedText = nil
                searchBody.textColor = c.textSecondary
                searchBody.font = UIFont.systemFont(ofSize: thinkFont)
                searchBody.text = search.isEmpty ? titleCore : search
            }
        } else {
            setSearch(visible: false, expanded: false)
        }

        let think = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        hasThinking = !think.isEmpty
        if hasThinking {
            if message.isStreaming {
                // Keep live reasoning visible, but do not persist this automatic
                // expansion. Once streaming finishes the reasoning should
                // collapse unless the user explicitly opens it.
                thinkingExpanded = true
            } else {
                thinkingExpanded = MessageCell.expandedThinkingIDs.contains(message.id)
            }
            setThinking(visible: true, expanded: thinkingExpanded)
            let title = message.isStreaming && message.content.isEmpty
                ? (thinkingExpanded ? "▾  思考中…" : "▸  思考中…")
                : (thinkingExpanded ? "▾  已深度思考" : "▸  已深度思考")
            thinkingHeader.setTitle(title, for: .normal)
            thinkingHeader.setTitleColor(c.textSecondary, for: .normal)
            thinkingBox.backgroundColor = c.surface.withAlphaComponent(0.65)
            thinkingBox.layer.borderWidth = 0
            if thinkingExpanded {
                if message.isStreaming {
                    thinkingBody.attributedText = nil
                    thinkingBody.textColor = c.textSecondary
                    thinkingBody.font = UIFont.systemFont(ofSize: thinkFont)
                    thinkingBody.text = think
                } else {
                    thinkingBody.attributedText = PlainMarkdown.attributed(
                        think,
                        bodyFont: UIFont.systemFont(ofSize: thinkFont),
                        textColor: c.textSecondary,
                        secondaryColor: c.textTertiary
                    )
                }
            }
        } else {
            setThinking(visible: false, expanded: false)
        }

        let showAct = !message.isStreaming && (!message.content.isEmpty || hasThinking || hasSearch)
        let pager = message.showsVersionPager
        showActions(
            showAct,
            versionText: pager ? message.versionPagerText : nil,
            canPrev: pager && message.versionIndex > 0,
            canNext: pager && message.versionIndex < message.versions.count - 1
        )
        styleActionIcons(c)

        let hasImage = !imageViewMsg.isHidden
        // Math/tables still need WKWebView+KaTeX even with deep-thinking.
        // Non-math thinking replies stay on PlainMarkdown (fast, no blank-gap risk).
        let needsRich = Self.needsRichRenderer(message.content)

        if message.isStreaming || message.content.isEmpty {
            parkWeb()
            hideNativeRender()
            hideStableRenderedReply()
            applyAssistantLayoutWidth()
            assistantLabel.isHidden = false
            labelBottom.isActive = true
            labelBottomFloor.isActive = true
            setContentTops(hasThinking: hasThinking, hasSearch: hasSearch, hasImage: hasImage, useWeb: false)
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
            _ = needsRich
            configureNative(
                message: message,
                hasThinking: hasThinking,
                hasSearch: hasSearch,
                hasImage: hasImage,
                font: font,
                colors: c
            )
        }
    }

    private func configureNative(message: ChatMessage,
                                 hasThinking: Bool,
                                 hasSearch: Bool = false,
                                 hasImage: Bool,
                                 font: CGFloat,
                                 colors: ThemeColors) {
        parkWeb()
        hideStableRenderedReply()
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
        let measuredWidth = column.bounds.width > 1
            ? column.bounds.width
            : max(bounds.width - 48, 120)
        let width = min(DSTheme.bubbleMaxWidth, max(measuredWidth, 120))
        nativeHeight.constant = nativeRenderView.configure(
            content: message.content,
            width: width,
            fontSize: font,
            appearance: SettingsManager.shared.appearanceMode.rawValue,
            colors: colors
        )
        nativeRenderView.isHidden = false
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.messageID == message.id else { return }
            self.contentView.layoutIfNeeded()
            let height = self.column.bounds.height
            if height > 40 {
                self.cellDelegate?.messageCell(self, didFinishStableRender: height, for: message.id)
            }
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
        let searchEmpty = message.searchProcessContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !message.hasSearchProcess
        let thinkEmpty = message.reasoningContent.isEmpty
        guard messageID == message.id,
              message.isStreaming,
              !assistantLabel.isHidden,
              renderedReplyView.isHidden,
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
            let search = message.searchProcessContent.trimmingCharacters(in: .whitespacesAndNewlines)
            searchBody.attributedText = nil
            searchBody.text = search
            let live = message.searchProcessPhase != .done
            let titleCore = live ? message.searchProcessPhase.headerTitle : SearchProcessPhase.done.headerTitle
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
        let search = message.searchProcessContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            let chevron = searchExpanded ? "▾" : "▸"
            searchHeader.setTitle("\(chevron)  \(SearchProcessPhase.done.headerTitle)", for: .normal)
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

    /// Covers the cell with its current pixels while constraints and renderer
    /// switch underneath, then fades the cover. The user never sees an empty
    /// stack or a half-laid-out rich reply.
    @discardableResult
    func transitionToStableRendering(_ message: ChatMessage, preferredHeight: CGFloat?) -> CGFloat? {
        guard messageID == message.id,
              !message.isStreaming,
              Self.needsRichRenderer(message.content) else { return nil }
        let exactKey = StableRichRenderer.key(
            messageID: message.id,
            content: message.content,
            font: SettingsManager.shared.chatBodyFontSize,
            appearance: SettingsManager.shared.appearanceMode.rawValue,
            width: stableRenderWidth()
        )
        if displayedStableKey == exactKey, !renderedReplyView.isHidden {
            return column.bounds.height > 40 ? column.bounds.height : nil
        }
        let cover = contentView.snapshotView(afterScreenUpdates: false)
        if let cover = cover {
            cover.frame = contentView.bounds
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.isUserInteractionEnabled = false
            contentView.addSubview(cover)
        }
        configure(with: message, preferredHeight: preferredHeight)
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        let measured = column.bounds.height
        if let cover = cover {
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction],
                animations: { cover.alpha = 0 },
                completion: { _ in cover.removeFromSuperview() }
            )
        }
        return measured > 40 ? measured : nil
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
        configure(with: message, preferredHeight: preferredHeight)
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
            guard self.messageID == id, !self.usesWeb else { return }
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

    // MARK: - Stable finished rich replies

    private func configureStableRich(message: ChatMessage,
                                     preferredHeight: CGFloat?,
                                     hasThinking: Bool,
                                     hasImage: Bool,
                                     font: CGFloat,
                                     colors: ThemeColors) {
        parkWeb()
        let width = stableRenderWidth()
        let key = StableRichRenderer.key(
            messageID: message.id,
            content: message.content,
            font: font,
            appearance: SettingsManager.shared.appearanceMode.rawValue,
            width: width
        )
        stableRenderKey = key
        hasExactStableRender = false
        // The hot scroll path is strictly synchronous: never clear image tiles
        // or paint a raw Markdown intermediary when the exact artifact exists.
        if let artifact = StableRichRenderer.shared.artifact(forKey: key) {
            hasExactStableRender = true
            showStableRenderedReply(
                artifact,
                renderKey: key,
                displayWidth: width,
                hasThinking: hasThinking,
                hasImage: hasImage
            )
            return
        }
        // The cell may already be displaying the exact immutable tiles even
        // after NSCache evicts them. Keep those pixels instead of replacing
        // them with a placeholder just to begin a disk reload.
        if displayedStableKey == key, !renderedReplyView.isHidden {
            return
        }
        let baseKey = StableRichRenderer.baseKey(
            messageID: message.id,
            content: message.content,
            font: font,
            appearance: SettingsManager.shared.appearanceMode.rawValue
        )
        if let preview = StableRichRenderer.shared.previewArtifact(forBaseKey: baseKey) {
            showStableRenderedReply(
                preview,
                renderKey: "preview|\(baseKey)",
                displayWidth: width,
                hasThinking: hasThinking,
                hasImage: hasImage
            )
        } else {
            // Keep readable content until the exact artifact is decoded.
            showStablePlainFallback(
                content: message.content,
                font: font,
                hasThinking: hasThinking,
                hasImage: hasImage,
                colors: colors
            )
            StableRichRenderer.shared.requestPreview(baseKey: baseKey, targetWidth: width) { _ in }
        }
        StableRichRenderer.shared.request(
            key: key,
            markdown: message.content,
            width: width,
            font: font,
            colors: colors,
            priority: .visible
        ) { [weak self] artifact in
            guard let self = self, artifact != nil else { return }
            if self.messageID == message.id,
               self.stableRenderKey == key,
               self.window != nil,
               self.cellDelegate?.messageCellShouldFreezeHeight(self) != true {
                _ = self.transitionToStableRendering(message, preferredHeight: preferredHeight)
            }
            self.prewarmLayoutProfiles(
                message: message,
                font: font,
                colors: colors,
                primaryWidth: width
            )
        }
    }

    private func showStablePlainFallback(content: String,
                                         font: CGFloat,
                                         hasThinking: Bool,
                                         hasImage: Bool,
                                         colors: ThemeColors) {
        parkWeb()
        hideStableRenderedReply()
        applyAssistantLayoutWidth()
        assistantLabel.isHidden = false
        labelBottom.isActive = true
        labelBottomFloor.isActive = true
        setContentTops(hasThinking: hasThinking, hasSearch: hasSearch || !searchBox.isHidden, hasImage: hasImage, useWeb: false)
        let cacheKey = "stable-fallback|\(RenderCacheStore.stamp(content))|\(Int(font))"
        assistantLabel.attributedText = PlainMarkdown.attributed(
            content,
            bodyFont: UIFont.systemFont(ofSize: font),
            textColor: colors.textPrimary,
            secondaryColor: colors.textSecondary,
            cacheKey: cacheKey
        )
        schedulePlainHeightNotify()
    }

    private func stablePlaceholderHeight(for content: String) -> CGFloat {
        let lines = max(3, min(22, content.count / 48))
        return CGFloat(lines * 22 + 30)
    }

    private func showStablePlaceholder(height: CGFloat,
                                       hasThinking: Bool,
                                       hasImage: Bool,
                                       colors: ThemeColors) {
        assistantLabel.isHidden = true
        assistantLabel.attributedText = nil
        assistantLabel.text = nil
        labelBottom.isActive = false
        labelBottomFloor.isActive = false
        assistantTopToRole.isActive = false
        assistantTopToImage.isActive = false
        assistantTopToThink.isActive = false
        hideStableRenderedReply()
        let placeholder = UIView()
        // Reserve final geometry without exposing a gray intermediate frame.
        placeholder.backgroundColor = .clear
        placeholder.layer.cornerRadius = 6
        renderedReplyView.addArrangedSubview(placeholder)
        placeholder.heightAnchor.constraint(equalToConstant: max(height, 44)).isActive = true
        renderedReplyView.isHidden = false
        if hasThinking || hasSearch { renderedTopToThink.isActive = true }
        else if hasImage { renderedTopToImage.isActive = true }
        else { renderedTopToRole.isActive = true }
        renderedBottom.isActive = true
        displayedStableKey = nil
    }

    private func stableRenderWidth() -> CGFloat {
        let screen = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let fallback = min(DSTheme.bubbleMaxWidth, screen - 56)
        let candidate = max(column.bounds.width, bounds.width - 48, fallback * 0.55, 280)
        return min(candidate, DSTheme.bubbleMaxWidth)
    }

    private func hideStableRenderedReply() {
        renderedReplyView.isHidden = true
        renderedTopToRole.isActive = false
        renderedTopToImage.isActive = false
        renderedTopToThink.isActive = false
        renderedBottom.isActive = false
        renderedReplyView.arrangedSubviews.forEach {
            renderedReplyView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func prewarmLayoutProfiles(message: ChatMessage,
                                       font: CGFloat,
                                       colors: ThemeColors,
                                       primaryWidth: CGFloat) {
        let appearance = SettingsManager.shared.appearanceMode.rawValue
        for width in StableRichRenderer.layoutProfileWidths(primary: primaryWidth)
            where abs(width - primaryWidth) > 1 {
            let key = StableRichRenderer.key(
                messageID: message.id,
                content: message.content,
                font: font,
                appearance: appearance,
                width: width
            )
            StableRichRenderer.shared.request(
                key: key,
                markdown: message.content,
                width: width,
                font: font,
                colors: colors
            ) { _ in }
        }
    }

    private func showStableRenderedReply(_ artifact: StableRenderedReply,
                                         renderKey: String,
                                         displayWidth: CGFloat,
                                         hasThinking: Bool,
                                         hasImage: Bool) {
        if displayedStableKey == renderKey, !renderedReplyView.isHidden {
            return
        }
        assistantLabel.isHidden = true
        assistantLabel.attributedText = nil
        assistantLabel.text = nil
        labelBottom.isActive = false
        labelBottomFloor.isActive = false
        assistantTopToRole.isActive = false
        assistantTopToImage.isActive = false
        assistantTopToThink.isActive = false
        hideStableRenderedReply()
        for (index, image) in artifact.tiles.enumerated() {
            let tile = UIImageView(image: image)
            tile.translatesAutoresizingMaskIntoConstraints = false
            tile.contentMode = .scaleToFill
            tile.clipsToBounds = true
            renderedReplyView.addArrangedSubview(tile)
            let height = artifact.tileHeights.indices.contains(index)
                ? artifact.tileHeights[index]
                : image.size.height / max(image.scale, 1)
            let scale = displayWidth / max(artifact.width, 1)
            tile.heightAnchor.constraint(equalToConstant: height * scale).isActive = true
        }
        renderedReplyView.isHidden = false
        if hasThinking || hasSearch { renderedTopToThink.isActive = true }
        else if hasImage { renderedTopToImage.isActive = true }
        else { renderedTopToRole.isActive = true }
        renderedBottom.isActive = true
        displayedStableKey = renderKey
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.contentView.layoutIfNeeded()
            let h = self.column.bounds.height
            if h > 40 {
                self.cellDelegate?.messageCell(self, didFinishStableRender: h, for: self.messageID)
            }
        }
    }

    private func configureRichWeb(message: ChatMessage,
                                  preferredHeight: CGFloat?,
                                  hasThinking: Bool,
                                  hasImage: Bool,
                                  font: CGFloat,
                                  colors: ThemeColors,
                                  isNewBinding: Bool) {
        let key = "\(message.id)|\(RenderCacheStore.stamp(message.content))|\(Int(font))|\(SettingsManager.shared.appearanceMode.rawValue)"
        // `normalizeForRender` turns ```latex fences into $$...$$. Use the
        // same representation for both routing and KaTeX shell selection.
        let needsMath = MathContentDetector.containsMath(
            MarkdownHTMLRenderer.normalizeForRender(message.content)
        )
        usesWeb = true

        let sameContent = (lastHTMLKey == key) && webShellReady
        let freezing = cellDelegate?.messageCellShouldFreezeHeight(self) ?? false
        let hasSnap = showCachedSnapshot(for: key, whileRendering: !sameContent)

        // Paint something readable FIRST — never block first frame on WebKit/KaTeX.
        if sameContent {
            showWebChrome(
                hasThinking: hasThinking,
                hasImage: hasImage,
                preferredHeight: preferredHeight,
                content: message.content,
                forceSeed: false,
                allowShrink: !freezing,
                showContent: true
            )
            // A reused cell can retain a slightly short WebView constraint.
            // Always remeasure: even a 2–6pt growth can otherwise hide the
            // last prose line behind the action row.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                self?.requestWebRemeasure(force: true)
            }
            return
        }

        if hasSnap {
            showWebChrome(
                hasThinking: hasThinking,
                hasImage: hasImage,
                preferredHeight: preferredHeight,
                content: message.content,
                forceSeed: isNewBinding,
                allowShrink: !freezing,
                showContent: false
            )
        } else {
            showInterimPlain(content: message.content, font: font, colors: colors)
        }

        pendingMarkdown = message.content
        pendingHTMLKey = key
        renderGeneration &+= 1
        injectRetryCount = 0
        let gen = renderGeneration
        let msgID = message.id

        if !hasSnap {
            Self.loadSnapshot(for: key) { [weak self] image in
                guard let self = self,
                      image != nil,
                      self.messageID == msgID,
                      self.renderGeneration == gen,
                      self.pendingHTMLKey == key,
                      !self.showingWebContent else { return }
                // Replace raw interim text with the already-rendered image
                // without waiting for a fresh KaTeX/WebKit pass.
                self.ensureWebShell(font: font, colors: colors, includeMath: needsMath)
                self.webSnapshotView?.image = image
                self.webSnapshotView?.isHidden = false
                self.showWebChrome(
                    hasThinking: hasThinking,
                    hasImage: hasImage,
                    preferredHeight: preferredHeight,
                    content: message.content,
                    forceSeed: true,
                    allowShrink: true,
                    showContent: false
                )
            }
        }

        // First paint is the PlainMarkdown fallback/snapshot. Start rich cells
        // one at a time afterwards: loading several KaTeX shells at once makes
        // conversation switches visibly freeze on the A7.
        let now = Date().timeIntervalSinceReferenceDate
        let startAt = max(now + 0.03, Self.nextRichRenderStart)
        Self.nextRichRenderStart = startAt + (needsMath ? 0.14 : 0.07)
        DispatchQueue.main.asyncAfter(deadline: .now() + (startAt - now)) { [weak self] in
            guard let self = self,
                  self.messageID == msgID,
                  self.renderGeneration == gen else { return }
            self.ensureWebShell(font: font, colors: colors, includeMath: needsMath)
            if self.webShellReady {
                self.injectPendingMarkdown(generation: gen)
            }
        }
    }

    private func showInterimPlain(content: String, font: CGFloat, colors: ThemeColors) {
        // Drive row height from PlainMarkdown until KaTeX shell finishes (cold open).
        parkWebLayoutOnly()
        labelBottom.isActive = true
        labelBottomFloor.isActive = true
        assistantLabel.isHidden = false
        assistantLabel.alpha = 1
        let hasThink = !thinkingBox.isHidden
        let hasImg = !imageViewMsg.isHidden
        setContentTops(hasThinking: hasThink, hasSearch: !searchBox.isHidden, hasImage: hasImg, useWeb: false)
        applyAssistantLayoutWidth()
        let key = "interim|\(RenderCacheStore.stamp(content))|\(Int(font))"
        assistantLabel.attributedText = PlainMarkdown.attributed(
            content,
            bodyFont: UIFont.systemFont(ofSize: font),
            textColor: colors.textPrimary,
            secondaryColor: colors.textSecondary,
            cacheKey: key
        )
        schedulePlainHeightNotify()
    }

    /// Collapse WKWebView out of layout without clearing pending markdown inject.
    private func parkWebLayoutOnly() {
        webBottom?.isActive = false
        webTopToRole?.isActive = false
        webTopToImage?.isActive = false
        webTopToThink?.isActive = false
        webHeight?.constant = 0
        webView?.isHidden = true
        webView?.alpha = 0
        webSnapshotView?.image = nil
        webSnapshotView?.isHidden = true
        showingWebContent = false
    }

    /// Called by ChatVC after rotation / Slide Over width changes.
    func remeasureAfterWidthChange() {
        guard usesWeb else {
            lastMeasuredColumnWidth = 0
            return
        }
        lastMeasuredColumnWidth = 0
        deferredWebHeight = nil
        // Do not retain the old-width document height. WKWebView can miss a
        // reflow callback after rotation / split-view changes; that otherwise
        // leaves a permanent blank area before the action row.
        webHeight?.constant = min(max(provisionalWebHeight, 44), 120)
        webView?.setNeedsLayout()
        webView?.scrollView.setNeedsLayout()
        guard webShellReady, lastHTMLKey != nil else { return }
        scheduleWidthRemeasure()
    }

    /// Apply height that was deferred while the table was scrolling.
    func applyDeferredHeightIfNeeded() {
        guard let h = deferredWebHeight else { return }
        deferredWebHeight = nil
        applyMeasuredWebHeight(h, force: true)
    }

    private func scheduleWidthRemeasure() {
        guard usesWeb else { return }
        widthRemeasureWork?.cancel()
        let gen = renderGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.usesWeb, self.renderGeneration == gen else { return }
            self.requestWebRemeasure(force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self = self, self.usesWeb, self.renderGeneration == gen else { return }
                self.requestWebRemeasure(force: true)
            }
            // iOS 12 WebKit sometimes commits a KaTeX/font reflow later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { [weak self] in
                guard let self = self, self.usesWeb, self.renderGeneration == gen else { return }
                self.requestWebRemeasure(force: true)
            }
        }
        widthRemeasureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func showWebChrome(hasThinking: Bool,
                               hasImage: Bool,
                               preferredHeight: CGFloat?,
                               content: String,
                               forceSeed: Bool,
                               allowShrink: Bool,
                               showContent: Bool) {
        usesWeb = true
        resetWebScrollPosition()
        assistantLabel.isHidden = true
        assistantLabel.attributedText = nil
        assistantLabel.text = nil
        labelBottom.isActive = false
        labelBottomFloor.isActive = false
        webBottom?.isActive = true
        webView?.isHidden = false
        // A reused WKWebView still contains its prior message. Keep that page
        // invisible until this message's JS render has completed, otherwise it
        // flashes while the table cell scrolls into view.
        webView?.alpha = showContent ? 1 : 0
        showingWebContent = showContent
        setContentTops(hasThinking: hasThinking, hasSearch: hasSearch || !searchBox.isHidden, hasImage: hasImage, useWeb: true)

        let estimate = Self.estimateWebHeight(for: content)
        provisionalWebHeight = estimate
        // Provisional only — never seed a multi-screen blank from a stale cache.
        var target = min(estimate, 120)
        if let h = preferredHeight, h > 40, h < 8000 {
            let capped = min(h, max(estimate * 1.15, 160), 360)
            if h < estimate * 0.45 {
                target = min(estimate, 120)
            } else {
                target = capped
            }
        }
        let current = webHeight?.constant ?? 0
        if forceSeed {
            deferredWebHeight = nil
            webHeight?.constant = target
            return
        }
        if target > current + 8 {
            webHeight?.constant = target
        } else if allowShrink, current - target > 8 {
            webHeight?.constant = target
        } else if current < 40 {
            webHeight?.constant = target
        }
    }

    /// ChatGPT / Claude / Gemini: GFM+KaTeX pipeline for tables, code, math.
    private static func needsRichRenderer(_ content: String) -> Bool {
        MarkdownHTMLRenderer.needsRichMarkdown(content)
    }

    private static func estimateWebHeight(for content: String) -> CGFloat {
        let lines = max(1, content.count / 36)
        var h = CGFloat(48 + lines * 24)
        if MathContentDetector.containsMath(content) { h *= 1.45 }
        if content.contains("```") { h *= 1.12 }
        if MarkdownHTMLRenderer.containsGFMTable(content) { h *= 1.25 }
        return min(max(h, 96), 3200)
    }

    private func applyMeasuredWebHeight(_ height: CGFloat, notify: Bool = true, force: Bool = false) {
        // Detailed proof-style replies can legitimately exceed 8,000pt. The
        // former fixed cap silently hid the tail of one reply in long threads.
        // Bound relative to the text estimate to protect memory without clipping
        // normal long-form content.
        let limit = min(max(8_000, provisionalWebHeight * 2.4), 30_000)
        let h = min(max(height, 20), limit)
        guard usesWeb else { return }

        let current = webHeight?.constant ?? 0
        let freezing = !force && (cellDelegate?.messageCellShouldFreezeHeight(self) == true)

        // Document-flow rule: never clip. Growth applies immediately; shrink waits for scroll end.
        if freezing, h + 4 < current {
            deferredWebHeight = min(deferredWebHeight ?? h, h)
            return
        }
        if freezing, h <= current + 8 {
            let colW = column.bounds.width
            if colW > 1 { lastMeasuredColumnWidth = colW }
            return
        }

        let threshold: CGFloat = force ? 1.5 : 8
        // Never suppress growth: a few points are enough for the final line
        // of a paragraph to be clipped under the actions. Only tiny shrink
        // changes are visual noise.
        if h <= current, current - h < threshold {
            let colW = column.bounds.width
            if colW > 1 { lastMeasuredColumnWidth = colW }
            return
        }

        webHeight?.constant = h
        deferredWebHeight = nil
        let colW = column.bounds.width
        if colW > 1 {
            lastMeasuredColumnWidth = colW
        }

        if !showingWebContent {
            revealWebContent()
        }

        guard notify else { return }
        heightNotifyWork?.cancel()
        let id = messageID
        let growing = h > current
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.usesWeb, self.messageID == id else { return }
            self.cellDelegate?.messageCell(self, didUpdateHeight: h, for: id)
        }
        heightNotifyWork = work
        // Growth must reach the table quickly so content is not clipped.
        let delay: TimeInterval = force ? 0.02 : (growing ? 0.04 : 0.16)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Reveal only content rendered for the current cell identity.
    private func revealWebContent() {
        assistantLabel.isHidden = true
        assistantLabel.attributedText = nil
        assistantLabel.alpha = 1
        labelBottom.isActive = false
        labelBottomFloor.isActive = false
        webBottom?.isActive = true
        webView?.isHidden = false
        webView?.alpha = 1
        webSnapshotView?.isHidden = true
        showingWebContent = true
        let hasThink = !thinkingBox.isHidden
        let hasImg = !imageViewMsg.isHidden
        setContentTops(hasThinking: hasThink, hasSearch: !searchBox.isHidden, hasImage: hasImg, useWeb: true)
    }

    @discardableResult
    private func showCachedSnapshot(for key: String, whileRendering: Bool) -> Bool {
        guard whileRendering else {
            webSnapshotView?.image = nil
            webSnapshotView?.isHidden = true
            return false
        }
        if let image = Self.webSnapshots.object(forKey: key as NSString) {
            webSnapshotView?.image = image
            webSnapshotView?.isHidden = false
            return true
        }
        // Never read/decode a disk JPEG here. This runs during cell binding on
        // the main thread and was the primary source of slow conversation switches.
        // The plain fallback below paints immediately while WebKit catches up.
        webSnapshotView?.image = nil
        webSnapshotView?.isHidden = true
        return false
    }

    private static func loadSnapshot(for key: String, completion: @escaping (UIImage?) -> Void) {
        if let image = webSnapshots.object(forKey: key as NSString) {
            completion(image)
            return
        }
        if snapshotWaiters[key] != nil {
            snapshotWaiters[key]?.append(completion)
            return
        }
        snapshotWaiters[key] = [completion]
        DispatchQueue.global(qos: .userInitiated).async {
            let image = RenderCacheStore.snapshot(forKey: key)
            DispatchQueue.main.async {
                let waiters = snapshotWaiters.removeValue(forKey: key) ?? []
                if let image = image {
                    let pixels = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
                    webSnapshots.setObject(image, forKey: key as NSString, cost: pixels)
                }
                for waiter in waiters {
                    waiter(image)
                }
            }
        }
    }

    private func captureWebSnapshot(for key: String, generation: UInt) {
        contentView.layoutIfNeeded()
        column.layoutIfNeeded()
        guard let wv = webView, wv.bounds.width > 1, wv.bounds.height > 1 else { return }
        wv.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self = self,
                  self.renderGeneration == generation,
                  self.lastHTMLKey == key,
                  let image = image else { return }
            let pixels = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            Self.webSnapshots.setObject(image, forKey: key as NSString, cost: pixels)
            RenderCacheStore.storeSnapshot(image, forKey: key)
        }
    }

    private func requestWebRemeasure(force: Bool = false) {
        guard usesWeb, let wv = webView else { return }
        let gen = renderGeneration
        wv.evaluateJavaScript(MarkdownHTMLRenderer.measureJavaScript()) { [weak self] result, _ in
            guard let self = self, self.usesWeb, self.renderGeneration == gen else { return }
            let height: CGFloat
            if let n = result as? NSNumber {
                height = CGFloat(truncating: n)
            } else if let d = result as? Double {
                height = CGFloat(d)
            } else {
                return
            }
            guard height > 1 else { return }
            DispatchQueue.main.async {
                guard self.renderGeneration == gen else { return }
                self.applyMeasuredWebHeight(height, force: force)
            }
        }
    }

    private func injectPendingMarkdown(generation: UInt) {
        guard usesWeb, webShellReady, let md = pendingMarkdown, let key = pendingHTMLKey else { return }
        guard let wv = webView else { return }
        // WKWebView is retained while cells are recycled. It can preserve a
        // contentOffset from the preceding reply even with scrolling disabled,
        // which makes the next reply visibly start in the middle.
        resetWebScrollPosition()
        let js = MarkdownHTMLRenderer.renderJavaScript(content: md)
        wv.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self, self.renderGeneration == generation else { return }
            DispatchQueue.main.async {
                guard self.renderGeneration == generation else { return }
                let height: CGFloat?
                if let n = result as? NSNumber {
                    height = CGFloat(truncating: n)
                } else if let d = result as? Double {
                    height = CGFloat(d)
                } else {
                    height = nil
                }

                // Cold start: JS libs may not be ready yet. Never wipe the interim
                // PlainMarkdown until we have a real measured height.
                if let h = height, h > 1, error == nil {
                    self.injectRetryCount = 0
                    self.injectRetryWork?.cancel()
                    self.lastHTMLKey = key
                    self.pendingMarkdown = nil
                    self.pendingHTMLKey = nil
                    self.applyMeasuredWebHeight(h, force: true)
                    self.revealWebContent()
                    // Snapshots captured from a provisional 120pt WebView are
                    // permanently truncated. Capture only after the delayed
                    // KaTeX/font reflow has been measured.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                        guard let self = self, self.renderGeneration == generation else { return }
                        self.requestWebRemeasure(force: true)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.78) { [weak self] in
                        self?.captureWebSnapshot(for: key, generation: generation)
                    }
                } else {
                    self.scheduleInjectRetry(generation: generation)
                }
            }
        }
    }

    private func scheduleInjectRetry(generation: UInt) {
        guard usesWeb, pendingMarkdown != nil, renderGeneration == generation else { return }
        guard injectRetryCount < Self.maxInjectRetries else {
            // Give up on WebKit for this bind — keep interim plain permanently.
            lastHTMLKey = nil
            webView?.alpha = 0
            webView?.isHidden = true
            webBottom?.isActive = false
            labelBottom.isActive = true
            labelBottomFloor.isActive = true
            assistantLabel.isHidden = false
            return
        }
        injectRetryCount += 1
        injectRetryWork?.cancel()
        let delay = 0.06 * Double(injectRetryCount)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.renderGeneration == generation else { return }
            // Light shells only need marked; math shells also need katex.
            let needsMath = self.shellThemeKey?.contains("math:1") == true
            let check = needsMath
                ? "(typeof marked!=='undefined'&&typeof katex!=='undefined')?1:0"
                : "(typeof marked!=='undefined')?1:0"
            self.webView?.evaluateJavaScript(check) { [weak self] result, _ in
                DispatchQueue.main.async {
                    guard let self = self, self.renderGeneration == generation else { return }
                    let ready = (result as? NSNumber)?.intValue == 1
                    if ready {
                        self.injectPendingMarkdown(generation: generation)
                    } else if self.injectRetryCount < Self.maxInjectRetries {
                        self.scheduleInjectRetry(generation: generation)
                    }
                }
            }
        }
        injectRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
        if abs(userLabel.preferredMaxLayoutWidth - max(w - 108, 1)) > 0.5 {
            userLabel.preferredMaxLayoutWidth = max(w - 108, 1)
        }
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

    private func showActions(_ on: Bool, versionText: String? = nil, canPrev: Bool = false, canNext: Bool = false) {
        actionRow.isHidden = !on
        actionHeight.constant = on ? 28 : 0
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
        thinkingBody.isHidden = !visible || !expanded
        thinkingTop.constant = visible ? 8 : 0
        if visible {
            thinkingBoxH.isActive = false
            thinkingToHeader.isActive = !expanded
            thinkingToBody.isActive = expanded
        } else {
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
        searchBody.isHidden = !visible || !expanded
        searchTop.constant = visible ? 8 : 0
        if visible {
            searchBoxH.isActive = false
            searchToHeader.isActive = !expanded
            searchToBody.isActive = expanded
        } else {
            searchToHeader.isActive = false
            searchToBody.isActive = false
            searchBoxH.constant = 0
            searchBoxH.isActive = true
            searchBody.attributedText = nil
            searchBody.text = nil
        }
    }

    private func setContentTops(hasThinking: Bool, hasSearch: Bool = false, hasImage: Bool, useWeb: Bool) {
        assistantTopToRole.isActive = false
        assistantTopToImage.isActive = false
        assistantTopToThink.isActive = false
        webTopToRole?.isActive = false
        webTopToImage?.isActive = false
        webTopToThink?.isActive = false

        let pinToStack = hasThinking || hasSearch
        if useWeb {
            if pinToStack { webTopToThink?.isActive = true }
            else if hasImage { webTopToImage?.isActive = true }
            else { webTopToRole?.isActive = true }
        } else {
            if pinToStack { assistantTopToThink.isActive = true }
            else if hasImage { assistantTopToImage.isActive = true }
            else { assistantTopToRole.isActive = true }
        }
    }

    private func parkWeb() {
        usesWeb = false
        showingWebContent = false
        pendingMarkdown = nil
        pendingHTMLKey = nil
        injectRetryWork?.cancel()
        injectRetryCount = 0
        heightNotifyWork?.cancel()
        widthRemeasureWork?.cancel()
        lastMeasuredColumnWidth = 0
        // Keep the WKWebView in hierarchy but out of layout — avoid alpha flicker on recycle.
        webBottom?.isActive = false
        webTopToRole?.isActive = false
        webTopToImage?.isActive = false
        webTopToThink?.isActive = false
        webHeight?.constant = 0
        webView?.isHidden = true
        webSnapshotView?.image = nil
        webSnapshotView?.isHidden = true
    }

    private func hideWeb() {
        parkWeb()
    }

    private func destroyWeb() {
        parkWeb()
        guard let wv = webView else { return }
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        wv.navigationDelegate = nil
        wv.removeFromSuperview()
        webView = nil
        webHeight = nil
        webBottom = nil
        webTopToRole = nil
        webTopToImage = nil
        webTopToThink = nil
        lastHTMLKey = nil
        webShellReady = false
        shellThemeKey = nil
    }

    @objc private func toggleThink() {
        guard hasThinking else { return }
        thinkingExpanded.toggle()
        if thinkingExpanded { MessageCell.expandedThinkingIDs.insert(messageID) }
        else { MessageCell.expandedThinkingIDs.remove(messageID) }
        NotificationCenter.default.post(
            name: Notification.Name("ConnectsThinkingToggle"),
            object: nil,
            userInfo: ["messageID": messageID]
        )
    }

    @objc private func toggleSearch() {
        guard hasSearch else { return }
        searchExpanded.toggle()
        if searchExpanded { MessageCell.expandedSearchIDs.insert(messageID) }
        else { MessageCell.expandedSearchIDs.remove(messageID) }
        NotificationCenter.default.post(
            name: Notification.Name("ConnectsSearchToggle"),
            object: nil,
            userInfo: ["messageID": messageID]
        )
    }

    private func ensureWebShell(font: CGFloat, colors: ThemeColors, includeMath: Bool) {
        let themeKey = "\(Int(font))|\(SettingsManager.shared.appearanceMode.rawValue)|math:\(includeMath ? 1 : 0)"
        ensureWeb()
        guard let wv = webView else { return }
        if webShellReady, shellThemeKey == themeKey { return }

        webShellReady = false
        shellThemeKey = themeKey
        let html = MarkdownHTMLRenderer.shellHTML(
            textColor: colors.textPrimary,
            backgroundColor: colors.background,
            secondaryColor: colors.textSecondary,
            fontSize: font,
            includeMath: includeMath
        )
        wv.loadHTMLString(html, baseURL: MarkdownHTMLRenderer.resourceBaseURL)
    }

    private func ensureWeb() {
        if webView != nil { return }
        let config = WKWebViewConfiguration()
        config.processPool = WebKitRenderWarmup.processPool
        config.preferences.javaScriptEnabled = true
        let proxy = WeakScriptMessageHandler(delegate: self)
        objc_setAssociatedObject(config, &Assoc.h, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        config.userContentController.add(proxy, name: "height")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.contentInset = .zero
        wv.scrollView.scrollIndicatorInsets = .zero
        wv.scrollView.backgroundColor = .clear
        wv.clipsToBounds = true
        if #available(iOS 11.0, *) {
            wv.scrollView.contentInsetAdjustmentBehavior = .never
        }
        column.insertSubview(wv, belowSubview: actionRow)
        webView = wv
        let snapshot = UIImageView()
        snapshot.translatesAutoresizingMaskIntoConstraints = false
        snapshot.contentMode = .top
        snapshot.clipsToBounds = true
        snapshot.isUserInteractionEnabled = false
        snapshot.isHidden = true
        column.insertSubview(snapshot, aboveSubview: wv)
        webSnapshotView = snapshot
        let h = wv.heightAnchor.constraint(equalToConstant: 40)
        h.priority = UILayoutPriority.required
        webHeight = h
        webBottom = wv.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -6)
        webTopToRole = wv.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 8)
        webTopToImage = wv.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 10)
        webTopToThink = wv.topAnchor.constraint(equalTo: thinkingBox.bottomAnchor, constant: 10)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            h,
            snapshot.leadingAnchor.constraint(equalTo: wv.leadingAnchor),
            snapshot.trailingAnchor.constraint(equalTo: wv.trailingAnchor),
            snapshot.topAnchor.constraint(equalTo: wv.topAnchor),
            snapshot.bottomAnchor.constraint(equalTo: wv.bottomAnchor)
        ])
        wv.alpha = 0
        wv.isHidden = true
    }

    private func resetWebScrollPosition() {
        guard let scrollView = webView?.scrollView else { return }
        scrollView.contentInset = .zero
        scrollView.setContentOffset(.zero, animated: false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webShellReady = true
        let gen = renderGeneration
        let needsMath = shellThemeKey?.contains("math:1") == true
        let check = needsMath
            ? "(typeof marked!=='undefined'&&typeof katex!=='undefined')?1:0"
            : "(typeof marked!=='undefined')?1:0"
        webView.evaluateJavaScript(check) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self = self, self.renderGeneration == gen else { return }
                let ready = (result as? NSNumber)?.intValue == 1
                if self.pendingMarkdown != nil {
                    if ready {
                        self.injectPendingMarkdown(generation: gen)
                    } else {
                        self.scheduleInjectRetry(generation: gen)
                    }
                } else if self.usesWeb, ready {
                    self.requestWebRemeasure()
                }
            }
        }
    }

    @objc private func copyTapped() { cellDelegate?.messageCellDidTapCopy(self, messageID: messageID) }
    @objc private func retryTapped() { cellDelegate?.messageCellDidTapRetry(self, messageID: messageID) }
    @objc private func forkTapped() { cellDelegate?.messageCellDidTapFork(self, messageID: messageID) }
    @objc private func versionPrevTapped() { cellDelegate?.messageCellDidShiftVersion(self, messageID: messageID, delta: -1) }
    @objc private func versionNextTapped() { cellDelegate?.messageCellDidShiftVersion(self, messageID: messageID, delta: 1) }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "height" else { return }
        // 0 = shell ready ping
        if let n = message.body as? NSNumber {
            let height = CGFloat(truncating: n)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if height <= 0.5 {
                    self.webShellReady = true
                    if self.pendingMarkdown != nil {
                        self.injectPendingMarkdown(generation: self.renderGeneration)
                    }
                    return
                }
                guard self.usesWeb, !self.messageID.isEmpty else { return }
                self.applyMeasuredWebHeight(height)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

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

        userBubble.translatesAutoresizingMaskIntoConstraints = false
        userBubble.layer.cornerRadius = 18
        userBubble.isHidden = true
        column.addSubview(userBubble)

        userLabel.translatesAutoresizingMaskIntoConstraints = false
        userLabel.numberOfLines = 0
        userBubble.addSubview(userLabel)

        assistantLabel.translatesAutoresizingMaskIntoConstraints = false
        assistantLabel.numberOfLines = 0
        assistantLabel.isHidden = true
        column.addSubview(assistantLabel)

        nativeRenderView.translatesAutoresizingMaskIntoConstraints = false
        nativeRenderView.isHidden = true
        nativeRenderView.onHeightChange = { [weak self] height in
            guard let self = self, !self.messageID.isEmpty else { return }
            self.nativeHeight.constant = height
            self.contentView.setNeedsLayout()
            self.contentView.layoutIfNeeded()
            let rowHeight = self.column.bounds.height
            if rowHeight > 40 {
                self.cellDelegate?.messageCell(
                    self,
                    didFinishStableRender: rowHeight,
                    for: self.messageID
                )
            }
        }
        column.addSubview(nativeRenderView)

        renderedReplyView.translatesAutoresizingMaskIntoConstraints = false
        renderedReplyView.axis = .vertical
        renderedReplyView.spacing = 0
        renderedReplyView.alignment = .fill
        renderedReplyView.distribution = .fill
        renderedReplyView.isHidden = true
        column.addSubview(renderedReplyView)

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
        renderedTopToRole = renderedReplyView.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 8)
        renderedTopToImage = renderedReplyView.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 10)
        renderedTopToThink = renderedReplyView.topAnchor.constraint(equalTo: thinkingBox.bottomAnchor, constant: 10)
        renderedBottom = renderedReplyView.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -4)
        nativeHeight = nativeRenderView.heightAnchor.constraint(equalToConstant: 0)
        nativeTopToRole = nativeRenderView.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 8)
        nativeTopToImage = nativeRenderView.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 10)
        nativeTopToThink = nativeRenderView.topAnchor.constraint(equalTo: thinkingBox.bottomAnchor, constant: 10)
        nativeBottom = nativeRenderView.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -4)
        userTopToRole = userBubble.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 8)
        userTopToImage = userBubble.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 10)
        // Soft equality + hard floor: when the table briefly oversizes a row (stale
        // estimatedHeight), the bubble/label keep intrinsic height instead of stretching.
        userBubbleBottom = userBubble.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -4)
        userBubbleBottom.priority = UILayoutPriority(750)
        userBubbleBottomFloor = actionRow.topAnchor.constraint(greaterThanOrEqualTo: userBubble.bottomAnchor, constant: 4)
        labelBottom = assistantLabel.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -4)
        labelBottom.priority = UILayoutPriority(750)
        labelBottomFloor = actionRow.topAnchor.constraint(greaterThanOrEqualTo: assistantLabel.bottomAnchor, constant: 4)

        userBubble.setContentHuggingPriority(.required, for: .vertical)
        userBubble.setContentCompressionResistancePriority(.required, for: .vertical)
        userLabel.setContentHuggingPriority(.required, for: .vertical)
        assistantLabel.setContentHuggingPriority(.required, for: .vertical)
        searchBox.setContentHuggingPriority(.required, for: .vertical)
        thinkingBox.setContentHuggingPriority(.required, for: .vertical)

        columnBottom = column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        columnBottom.priority = UILayoutPriority(750)
        let columnBottomFloor = contentView.bottomAnchor.constraint(greaterThanOrEqualTo: column.bottomAnchor, constant: 10)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            columnBottom,
            columnBottomFloor,
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

            userTopToRole,
            userBubble.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            userBubble.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor, constant: 96),
            userBubbleBottom,
            userBubbleBottomFloor,

            userLabel.topAnchor.constraint(equalTo: userBubble.topAnchor, constant: 10),
            userLabel.bottomAnchor.constraint(equalTo: userBubble.bottomAnchor, constant: -10),
            userLabel.leadingAnchor.constraint(equalTo: userBubble.leadingAnchor, constant: 14),
            userLabel.trailingAnchor.constraint(equalTo: userBubble.trailingAnchor, constant: -14),

            assistantTopToRole,
            assistantLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            assistantLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            labelBottom,
            labelBottomFloor,

            renderedReplyView.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            renderedReplyView.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            renderedBottom,

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
        userBubbleBottom.isActive = false
        userBubbleBottomFloor.isActive = false
        labelBottom.isActive = false
        labelBottomFloor.isActive = false
        renderedTopToRole.isActive = false
        renderedTopToImage.isActive = false
        renderedTopToThink.isActive = false
        renderedBottom.isActive = false
        nativeTopToRole.isActive = false
        nativeTopToImage.isActive = false
        nativeTopToThink.isActive = false
        nativeBottom.isActive = false
        assistantTopToRole.isActive = false
        userTopToRole.isActive = false
    }
}
