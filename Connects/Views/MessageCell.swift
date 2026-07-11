import UIKit
import WebKit
import ObjectiveC

protocol MessageCellDelegate: AnyObject {
    func messageCell(_ cell: MessageCell, didUpdateHeight height: CGFloat, for messageID: String)
    func messageCellDidTapCopy(_ cell: MessageCell, messageID: String)
    func messageCellDidTapRetry(_ cell: MessageCell, messageID: String)
    func messageCellDidTapFork(_ cell: MessageCell, messageID: String)
}

/// ChatGPT-style layout: centered column, user bubble right, assistant prose + collapsible thinking + icon actions.
final class MessageCell: UITableViewCell, WKScriptMessageHandler, WKNavigationDelegate {
    static let reuseID = "MessageCell"
    private static let processPool = WKProcessPool()
    private static var expandedThinkingIDs = Set<String>()

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
        lastHTMLKey = nil
        usesWeb = false
        userLabel.text = nil
        assistantLabel.attributedText = nil
        assistantLabel.text = nil
        thinkingBody.attributedText = nil
        thinkingBody.text = nil
        imageViewMsg.image = nil
        imageViewMsg.isHidden = true
        imageHeight.constant = 0
        hideWeb()
        showActions(false)
        setThinking(visible: false, expanded: false)
        userBubble.isHidden = true
        assistantLabel.isHidden = true
    }

    func configure(with message: ChatMessage, preferredHeight: CGFloat?) {
        messageID = message.id
        let c = DSTheme.c
        let font = SettingsManager.shared.chatBodyFontSize
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        roleLabel.textColor = c.textTertiary
        roleLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)

        if let b64 = message.imageJPEGBase64, let img = ImageAttachmentHelper.image(from: b64) {
            imageViewMsg.image = img
            imageViewMsg.isHidden = false
            imageHeight.constant = 160
        } else {
            imageViewMsg.image = nil
            imageViewMsg.isHidden = true
            imageHeight.constant = 0
        }

        if message.role == .user {
            roleLabel.text = "你"
            roleLabel.textAlignment = .right
            userBubble.isHidden = false
            userBubble.backgroundColor = c.userBubble
            assistantLabel.isHidden = true
            hideWeb()
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
        roleLabel.text = "Connects"
        roleLabel.textAlignment = .left
        userBubble.isHidden = true
        userTopToRole.isActive = false
        userTopToImage.isActive = false
        userBubbleBottom.isActive = false
        labelBottom.isActive = true

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
                ? (thinkingExpanded ? "▾  思考中" : "▸  思考中")
                : (thinkingExpanded ? "▾  已深度思考" : "▸  已深度思考")
            thinkingHeader.setTitle(title, for: .normal)
            thinkingHeader.setTitleColor(c.textSecondary, for: .normal)
            thinkingBox.backgroundColor = c.surface
            thinkingBox.layer.borderColor = c.border.cgColor
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

        if message.isStreaming || message.content.isEmpty {
            hideWeb()
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
        } else {
            assistantLabel.isHidden = true
            labelBottom.isActive = false
            ensureWeb()
            usesWeb = true
            webView?.isHidden = false
            webBottom?.isActive = true
            setContentTops(hasThinking: hasThinking, hasImage: hasImage, useWeb: true)
            if let h = preferredHeight, h > 40 { webHeight?.constant = h }
            let key = "\(message.id)|\(message.content.count)|\(Int(font))"
            if lastHTMLKey != key {
                lastHTMLKey = key
                let html = MarkdownHTMLRenderer.fullHTML(
                    content: message.content,
                    textColor: c.textPrimary,
                    backgroundColor: c.background,
                    secondaryColor: c.textSecondary,
                    fontSize: font
                )
                loadHTML(html, id: message.id)
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

    private func hideWeb() {
        usesWeb = false
        webView?.stopLoading()
        webView?.isHidden = true
        webBottom?.isActive = false
        webTopToRole?.isActive = false
        webTopToImage?.isActive = false
        webTopToThink?.isActive = false
        webHeight?.constant = 0
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
        wv.scrollView.backgroundColor = .clear
        if #available(iOS 11.0, *) {
            wv.scrollView.contentInsetAdjustmentBehavior = .never
        }
        column.insertSubview(wv, belowSubview: actionRow)
        webView = wv
        let h = wv.heightAnchor.constraint(equalToConstant: 40)
        h.priority = UILayoutPriority(999)
        webHeight = h
        webBottom = wv.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -6)
        webTopToRole = wv.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 8)
        webTopToImage = wv.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 10)
        webTopToThink = wv.topAnchor.constraint(equalTo: thinkingBox.bottomAnchor, constant: 10)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            h
        ])
    }

    private func loadHTML(_ html: String, id: String) {
        guard let wv = webView else { return }
        // Must use loadHTMLString + bundle baseURL so katex/markdown assets resolve (temp fileURL cannot read Bundle).
        wv.loadHTMLString(html, baseURL: MarkdownHTMLRenderer.resourceBaseURL)
    }

    @objc private func toggleThink() {
        guard hasThinking else { return }
        thinkingExpanded.toggle()
        if thinkingExpanded { MessageCell.expandedThinkingIDs.insert(messageID) }
        else { MessageCell.expandedThinkingIDs.remove(messageID) }
        NotificationCenter.default.post(name: Notification.Name("ConnectsThinkingToggle"), object: nil)
    }

    @objc private func copyTapped() { cellDelegate?.messageCellDidTapCopy(self, messageID: messageID) }
    @objc private func retryTapped() { cellDelegate?.messageCellDidTapRetry(self, messageID: messageID) }
    @objc private func forkTapped() { cellDelegate?.messageCellDidTapFork(self, messageID: messageID) }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "height", let n = message.body as? NSNumber else { return }
        let height = min(CGFloat(truncating: n), 5000)
        guard height > 1, usesWeb, !messageID.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.usesWeb else { return }
            if abs((self.webHeight?.constant ?? 0) - height) < 2 { return }
            self.webHeight?.constant = height
            self.cellDelegate?.messageCell(self, didUpdateHeight: height, for: self.messageID)
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
        thinkingBox.layer.borderWidth = 1
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
