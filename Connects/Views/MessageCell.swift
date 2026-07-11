import UIKit
import WebKit
import ObjectiveC

protocol MessageCellDelegate: AnyObject {
    func messageCell(_ cell: MessageCell, didUpdateHeight height: CGFloat, for messageID: String)
    func messageCellDidTapCopy(_ cell: MessageCell, messageID: String)
    func messageCellDidTapRetry(_ cell: MessageCell, messageID: String)
    func messageCellDidTapFork(_ cell: MessageCell, messageID: String)
    /// When true, cell must not change webHeight / notify (prevents scroll flicker).
    func messageCellShouldFreezeHeight(_ cell: MessageCell) -> Bool
}

extension MessageCellDelegate {
    func messageCellShouldFreezeHeight(_ cell: MessageCell) -> Bool { false }
}

/// ChatGPT-style layout: centered column, user bubble right, assistant prose + collapsible thinking + icon actions.
final class MessageCell: UITableViewCell, WKScriptMessageHandler, WKNavigationDelegate {
    static let reuseID = "MessageCell"
    private static let processPool = WKProcessPool()
    private static var expandedThinkingIDs = Set<String>()
    /// Briefly shown while a recycled WKWebView restores an already-seen reply.
    /// This avoids blank/old-content flashes during table-cell reuse.
    private static let webSnapshots: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

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

    private let assistantLabel = UILabel()
    private var webView: WKWebView?
    private var webSnapshotView: UIImageView?
    private var webHeight: NSLayoutConstraint?

    private let actionRow = UIStackView()
    private let copyButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let forkButton = UIButton(type: .system)

    private var columnWidthFill: NSLayoutConstraint!
    private var columnWidthMax: NSLayoutConstraint!
    private var imageHeight: NSLayoutConstraint!
    private var actionHeight: NSLayoutConstraint!
    private var thinkingHeaderH: NSLayoutConstraint!
    private var thinkingBoxH: NSLayoutConstraint!
    private var thinkingToHeader: NSLayoutConstraint!
    private var thinkingToBody: NSLayoutConstraint!
    private var assistantTopToRole: NSLayoutConstraint!
    private var assistantTopToImage: NSLayoutConstraint!
    private var assistantTopToThink: NSLayoutConstraint!
    private var userTopToRole: NSLayoutConstraint!
    private var userTopToImage: NSLayoutConstraint!
    private var userBubbleBottom: NSLayoutConstraint!
    private var thinkingTop: NSLayoutConstraint!
    private var webBottom: NSLayoutConstraint?
    private var webTopToRole: NSLayoutConstraint?
    private var webTopToImage: NSLayoutConstraint?
    private var webTopToThink: NSLayoutConstraint?
    private var labelBottom: NSLayoutConstraint!

    private var lastHTMLKey: String?
    private var usesWeb = false
    private var hasThinking = false
    private var thinkingExpanded = false
    /// Shell document loaded (katex/marked ready).
    private var webShellReady = false
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
        // Cancel in-flight JS callbacks for the previous identity.
        renderGeneration &+= 1
        heightNotifyWork?.cancel()
        widthRemeasureWork?.cancel()
        pendingMarkdown = nil
        pendingHTMLKey = nil
        deferredWebHeight = nil
        // Do NOT parkWeb / hide WKWebView here — that blanks cells during scroll recycle
        // and causes the flash. configure() parks when the new row is not rich web.
        userLabel.text = nil
        assistantLabel.attributedText = nil
        assistantLabel.text = nil
        thinkingBody.attributedText = nil
        thinkingBody.text = nil
        imageViewMsg.image = nil
        imageViewMsg.isHidden = true
        imageHeight.constant = 0
        showActions(false)
        setThinking(visible: false, expanded: false)
        userBubble.isHidden = true
        assistantLabel.isHidden = true
        webSnapshotView?.image = nil
        webSnapshotView?.isHidden = true
        cachedImage = nil
    }

    private var cachedImage: UIImage?

    func setCachedImage(_ image: UIImage?) {
        cachedImage = image
    }

    func configure(with message: ChatMessage, preferredHeight: CGFloat?) {
        // Binding a different message (incl. after prepareForReuse) must re-seed height.
        // Freezing the previous cell's webHeight caused truncation / huge gaps (1.4.12).
        let isNewBinding = messageID != message.id
        messageID = message.id
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
            parkWeb()
            setThinking(visible: false, expanded: false)
            showActions(false)
            userLabel.textColor = c.textPrimary
            userLabel.font = UIFont.systemFont(ofSize: font)
            userLabel.text = message.content.isEmpty && message.hasImage ? nil : message.content

            assistantTopToRole.isActive = false
            assistantTopToImage.isActive = false
            assistantTopToThink.isActive = false
            labelBottom.isActive = false
            userBubbleBottom.isActive = true
            userTopToRole.isActive = imageViewMsg.isHidden
            userTopToImage.isActive = !imageViewMsg.isHidden
            return
        }

        // Assistant
        userBubble.isHidden = true
        userTopToRole.isActive = false
        userTopToImage.isActive = false
        userBubbleBottom.isActive = false

        let think = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        hasThinking = !think.isEmpty
        if hasThinking {
            if message.isStreaming {
                thinkingExpanded = true
                MessageCell.expandedThinkingIDs.insert(message.id)
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

        let showAct = !message.isStreaming && (!message.content.isEmpty || hasThinking)
        showActions(showAct)
        styleActionIcons(c)

        let hasImage = !imageViewMsg.isHidden
        let needsWeb = Self.needsRichRenderer(message.content)

        if message.isStreaming || message.content.isEmpty {
            parkWeb()
            assistantLabel.isHidden = false
            labelBottom.isActive = true
            setContentTops(hasThinking: hasThinking, hasImage: hasImage, useWeb: false)
            if message.content.isEmpty && !hasThinking {
                assistantLabel.attributedText = nil
                assistantLabel.textColor = c.textPrimary
                assistantLabel.font = UIFont.systemFont(ofSize: font)
                assistantLabel.text = "▍"
            } else if message.isStreaming {
                assistantLabel.attributedText = nil
                assistantLabel.textColor = c.textPrimary
                assistantLabel.font = UIFont.systemFont(ofSize: font)
                assistantLabel.text = message.content.isEmpty ? nil : message.content
            } else {
                assistantLabel.attributedText = nil
                assistantLabel.text = nil
            }
        } else if needsWeb {
            configureRichWeb(
                message: message,
                preferredHeight: preferredHeight,
                hasThinking: hasThinking,
                hasImage: hasImage,
                font: font,
                colors: c,
                isNewBinding: isNewBinding
            )
        } else {
            parkWeb()
            assistantLabel.isHidden = false
            labelBottom.isActive = true
            setContentTops(hasThinking: hasThinking, hasImage: hasImage, useWeb: false)
            let key = "\(message.id)|\(message.content.count)|\(Int(font))"
            assistantLabel.attributedText = PlainMarkdown.attributed(
                message.content,
                bodyFont: UIFont.systemFont(ofSize: font),
                textColor: c.textPrimary,
                secondaryColor: c.textSecondary,
                cacheKey: key
            )
        }
    }

    private func configureRichWeb(message: ChatMessage,
                                  preferredHeight: CGFloat?,
                                  hasThinking: Bool,
                                  hasImage: Bool,
                                  font: CGFloat,
                                  colors: ThemeColors,
                                  isNewBinding: Bool) {
        let key = "\(message.id)|\(message.content.hashValue)|\(Int(font))|\(SettingsManager.shared.appearanceMode.rawValue)"
        usesWeb = true
        ensureWebShell(font: font, colors: colors)

        let sameContent = (lastHTMLKey == key) && webShellReady
        let freezing = cellDelegate?.messageCellShouldFreezeHeight(self) ?? false
        showCachedSnapshot(for: key, whileRendering: !sameContent)

        // ChatGPT-style: content drives layout. On bind, always seed a sane height
        // (preferred or estimate). Never keep a recycled neighbor's height.
        showWebChrome(
            hasThinking: hasThinking,
            hasImage: hasImage,
            preferredHeight: preferredHeight,
            content: message.content,
            forceSeed: isNewBinding || !sameContent,
            allowShrink: !freezing,
            showContent: sameContent
        )

        if sameContent {
            return
        }

        pendingMarkdown = message.content
        pendingHTMLKey = key
        renderGeneration &+= 1
        let gen = renderGeneration

        if webShellReady {
            injectPendingMarkdown(generation: gen)
        }
    }

    /// Called by ChatVC after rotation / Slide Over width changes.
    func remeasureAfterWidthChange() {
        guard usesWeb, webShellReady, lastHTMLKey != nil else {
            lastMeasuredColumnWidth = 0
            return
        }
        lastMeasuredColumnWidth = 0
        deferredWebHeight = nil
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
        assistantLabel.isHidden = true
        assistantLabel.attributedText = nil
        assistantLabel.text = nil
        labelBottom.isActive = false
        webBottom?.isActive = true
        webView?.isHidden = false
        // A reused WKWebView still contains its prior message. Keep that page
        // invisible until this message's JS render has completed, otherwise it
        // flashes while the table cell scrolls into view.
        webView?.alpha = showContent ? 1 : 0
        showingWebContent = showContent
        setContentTops(hasThinking: hasThinking, hasImage: hasImage, useWeb: true)

        let estimate = Self.estimateWebHeight(for: content)
        // Prefer a measured cache. Without one, use only a small provisional
        // frame: WebKit clips to this briefly, then the content measurement grows
        // it. A large character-count estimate can become a visible blank tail.
        var target = min(estimate, 140)
        if let h = preferredHeight, h > 40, h < 8000 {
            // Treat legacy implausibly-small entries as unmeasured; do not
            // replace them with a large character-count estimate.
            target = h < estimate * 0.45 ? min(estimate, 140) : h
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
        let h = min(max(height, 20), 8000)
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
        if abs(current - h) < threshold {
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
        labelBottom.isActive = false
        webBottom?.isActive = true
        webView?.isHidden = false
        webView?.alpha = 1
        webSnapshotView?.isHidden = true
        showingWebContent = true
        let hasThink = !thinkingBox.isHidden
        let hasImg = !imageViewMsg.isHidden
        setContentTops(hasThinking: hasThink, hasImage: hasImg, useWeb: true)
    }

    private func showCachedSnapshot(for key: String, whileRendering: Bool) {
        guard whileRendering,
              let image = Self.webSnapshots.object(forKey: key as NSString) else {
            webSnapshotView?.image = nil
            webSnapshotView?.isHidden = true
            return
        }
        webSnapshotView?.image = image
        webSnapshotView?.isHidden = false
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
        let js = MarkdownHTMLRenderer.renderJavaScript(content: md)
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, self.renderGeneration == generation else { return }
            DispatchQueue.main.async {
                guard self.renderGeneration == generation else { return }
                self.lastHTMLKey = key
                self.pendingMarkdown = nil
                self.pendingHTMLKey = nil
                if let n = result as? NSNumber {
                    let h = CGFloat(truncating: n)
                    if h > 1 { self.applyMeasuredWebHeight(h) }
                } else if let d = result as? Double, d > 1 {
                    self.applyMeasuredWebHeight(CGFloat(d))
                } else {
                    self.requestWebRemeasure()
                }
                // applyMeasuredWebHeight may reasonably reject a <8pt change;
                // this render is nevertheless current, so reveal it now.
                self.revealWebContent()
                self.captureWebSnapshot(for: key, generation: generation)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                    self?.captureWebSnapshot(for: key, generation: generation)
                }
            }
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
        if abs(userLabel.preferredMaxLayoutWidth - max(w - 108, 1)) > 0.5 {
            userLabel.preferredMaxLayoutWidth = max(w - 108, 1)
        }
        // Width remasure is owned by ChatVC (rotation / Slide Over) — not here.
        // layoutSubviews fires constantly while scrolling and was causing height thrash.
    }

    private func styleActionIcons(_ c: ThemeColors) {
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
        // Prevent UIButton from stretching template image
        if #available(iOS 13.0, *) {
            button.adjustsImageSizeForAccessibilityContentSizeCategory = false
        }
    }

    private func showActions(_ on: Bool) {
        actionRow.isHidden = !on
        actionHeight.constant = on ? 28 : 0
        copyButton.isHidden = !on
        retryButton.isHidden = !on
        forkButton.isHidden = !on
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

    private func setContentTops(hasThinking: Bool, hasImage: Bool, useWeb: Bool) {
        assistantTopToRole.isActive = false
        assistantTopToImage.isActive = false
        assistantTopToThink.isActive = false
        webTopToRole?.isActive = false
        webTopToImage?.isActive = false
        webTopToThink?.isActive = false

        if useWeb {
            if hasThinking { webTopToThink?.isActive = true }
            else if hasImage { webTopToImage?.isActive = true }
            else { webTopToRole?.isActive = true }
        } else {
            if hasThinking { assistantTopToThink.isActive = true }
            else if hasImage { assistantTopToImage.isActive = true }
            else { assistantTopToRole.isActive = true }
        }
    }

    private func parkWeb() {
        usesWeb = false
        showingWebContent = false
        pendingMarkdown = nil
        pendingHTMLKey = nil
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

    private func ensureWebShell(font: CGFloat, colors: ThemeColors) {
        let themeKey = "\(Int(font))|\(SettingsManager.shared.appearanceMode.rawValue)"
        ensureWeb()
        guard let wv = webView else { return }
        if webShellReady, shellThemeKey == themeKey { return }

        webShellReady = false
        shellThemeKey = themeKey
        let html = MarkdownHTMLRenderer.shellHTML(
            textColor: colors.textPrimary,
            backgroundColor: colors.background,
            secondaryColor: colors.textSecondary,
            fontSize: font
        )
        wv.loadHTMLString(html, baseURL: MarkdownHTMLRenderer.resourceBaseURL)
    }

    private func ensureWeb() {
        if webView != nil { return }
        let config = WKWebViewConfiguration()
        config.processPool = MessageCell.processPool
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webShellReady = true
        let gen = renderGeneration
        if pendingMarkdown != nil {
            injectPendingMarkdown(generation: gen)
        } else if usesWeb {
            requestWebRemeasure()
        }
    }

    @objc private func copyTapped() { cellDelegate?.messageCellDidTapCopy(self, messageID: messageID) }
    @objc private func retryTapped() { cellDelegate?.messageCellDidTapRetry(self, messageID: messageID) }
    @objc private func forkTapped() { cellDelegate?.messageCellDidTapFork(self, messageID: messageID) }

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

        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionRow.axis = .horizontal
        actionRow.spacing = 4
        actionRow.alignment = .center
        actionRow.isHidden = true
        column.addSubview(actionRow)

        for b in [copyButton, retryButton, forkButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            actionRow.addArrangedSubview(b)
        }
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        forkButton.addTarget(self, action: #selector(forkTapped), for: .touchUpInside)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionRow.addArrangedSubview(spacer)

        // Fill available width up to max — avoids UILabel intrinsic-width collapse
        columnWidthFill = column.widthAnchor.constraint(equalTo: contentView.widthAnchor, constant: -48)
        columnWidthFill.priority = UILayoutPriority(999)
        columnWidthMax = column.widthAnchor.constraint(lessThanOrEqualToConstant: DSTheme.bubbleMaxWidth)
        imageHeight = imageViewMsg.heightAnchor.constraint(equalToConstant: 0)
        actionHeight = actionRow.heightAnchor.constraint(equalToConstant: 0)
        thinkingHeaderH = thinkingHeader.heightAnchor.constraint(equalToConstant: 0)
        thinkingBoxH = thinkingBox.heightAnchor.constraint(equalToConstant: 0)
        thinkingTop = thinkingBox.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 0)
        thinkingToHeader = thinkingBox.bottomAnchor.constraint(equalTo: thinkingHeader.bottomAnchor)
        thinkingToBody = thinkingBox.bottomAnchor.constraint(equalTo: thinkingBody.bottomAnchor, constant: 10)

        assistantTopToRole = assistantLabel.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 8)
        assistantTopToImage = assistantLabel.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 10)
        assistantTopToThink = assistantLabel.topAnchor.constraint(equalTo: thinkingBox.bottomAnchor, constant: 10)
        userTopToRole = userBubble.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 8)
        userTopToImage = userBubble.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 10)
        userBubbleBottom = userBubble.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -4)
        labelBottom = assistantLabel.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -4)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
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

            userLabel.topAnchor.constraint(equalTo: userBubble.topAnchor, constant: 10),
            userLabel.bottomAnchor.constraint(equalTo: userBubble.bottomAnchor, constant: -10),
            userLabel.leadingAnchor.constraint(equalTo: userBubble.leadingAnchor, constant: 14),
            userLabel.trailingAnchor.constraint(equalTo: userBubble.trailingAnchor, constant: -14),

            assistantTopToRole,
            assistantLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            assistantLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            labelBottom,

            actionRow.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            actionRow.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            actionRow.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            actionHeight
        ])
        // Default inactive pair ends — configure() enables the right set
        userBubbleBottom.isActive = false
        labelBottom.isActive = false
        assistantTopToRole.isActive = false
        userTopToRole.isActive = false
    }
}
