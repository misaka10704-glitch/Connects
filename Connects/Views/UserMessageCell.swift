import UIKit

/// User question bubble — no assistant chrome, native render, or action row.
final class UserMessageCell: BaseMessageCell {
    static let reuseID = MessageCellReuseID.user

    private let userBubble = UIView()
    private let userLabel = UILabel()

    private var userTopToRole: NSLayoutConstraint!
    private var userTopToImage: NSLayoutConstraint!
    private var userBubbleBottom: NSLayoutConstraint!
    private var showsImageInBubble = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUserBubble()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUserBubble()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if cellDelegate?.messageCellShouldFreezeHeight(self) == true {
            messageID = ""
            configuredPreferredHeight = nil
            return
        }
        resetSharedReuseState()
        userLabel.text = nil
        userLabel.attributedText = nil
        userBubble.isHidden = true
        showsImageInBubble = false
    }

    override func configure(with message: ChatMessage, preferredHeight: CGFloat?, layoutWidth: CGFloat) {
        guard message.role == .user else { return }
        let previousMessageID = messageID
        let freezeLayout = cellDelegate?.messageCellShouldFreezeHeight(self) == true
        messageID = message.id
        preferredLayoutWidth = layoutWidth
        configuredPreferredHeight = preferredHeight

        if previousMessageID == message.id,
           freezeLayout,
           !userBubble.isHidden,
           (userLabel.text != nil || !imageViewMsg.isHidden),
           abs(preferredLayoutWidth - layoutWidth) < 1 {
            return
        }

        let c = DSTheme.c
        let font = SettingsManager.shared.chatBodyFontSize

        showsImageInBubble = message.showsImageInChat
        applySharedImage(to: message)

        userBubble.isHidden = false
        userBubble.backgroundColor = c.userBubble
        userBubble.layer.cornerRadius = DSTheme.bubbleCornerRadius
        userLabel.attributedText = nil
        userLabel.textColor = c.textPrimary
        userLabel.font = UIFont.systemFont(ofSize: font)
        userLabel.text = message.content.isEmpty && message.showsImageInChat ? nil : message.content

        userTopToRole.isActive = imageViewMsg.isHidden
        userTopToImage.isActive = !imageViewMsg.isHidden

        applyUserLayoutWidth()
        userLabel.setNeedsLayout()
        userLabel.invalidateIntrinsicContentSize()

        if configuredPreferredHeight == nil {
            scheduleMeasuredHeightNotify(for: message.id)
        }
    }

    func syncUserPresentation(with message: ChatMessage, layoutWidth: CGFloat) {
        guard messageID == message.id, message.role == .user else { return }
        preferredLayoutWidth = layoutWidth
        let c = DSTheme.c
        let font = SettingsManager.shared.chatBodyFontSize
        userLabel.attributedText = nil
        userLabel.textColor = c.textPrimary
        userLabel.font = UIFont.systemFont(ofSize: font)
        let text = message.content.isEmpty && message.showsImageInChat ? nil : message.content
        if userLabel.text != text {
            userLabel.text = text
        }
        applyUserLayoutWidth()
        userLabel.setNeedsLayout()
        userLabel.invalidateIntrinsicContentSize()
    }

    func userBubbleTop(in coordinateView: UIView) -> CGFloat? {
        guard !userBubble.isHidden, userBubble.window != nil else { return nil }
        return userBubble.convert(CGPoint.zero, to: coordinateView).y
    }

    override func refreshRenderDebugOverlay() {
        super.refreshRenderDebugOverlay()
        let on = SettingsManager.shared.renderDebugOverlayEnabled
        userBubble.layer.borderWidth = on && !userBubble.isHidden ? 1 / UIScreen.main.scale : 0
        guard on else { return }
        let blue: UIColor
        if #available(iOS 13.0, *) { blue = .systemBlue }
        else { blue = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1) }
        userBubble.layer.borderColor = blue.withAlphaComponent(0.45).cgColor
    }

    private func setupUserBubble() {
        userBubble.translatesAutoresizingMaskIntoConstraints = false
        userBubble.layer.cornerRadius = 18
        userBubble.isHidden = true
        column.addSubview(userBubble)

        userLabel.translatesAutoresizingMaskIntoConstraints = false
        userLabel.numberOfLines = 0
        userLabel.lineBreakMode = .byWordWrapping
        userBubble.addSubview(userLabel)

        userTopToRole = userBubble.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 0)
        userTopToImage = userBubble.topAnchor.constraint(equalTo: imageViewMsg.bottomAnchor, constant: 10)
        userBubbleBottom = userBubble.bottomAnchor.constraint(equalTo: column.bottomAnchor)

        userBubble.setContentHuggingPriority(.required, for: .vertical)
        userBubble.setContentCompressionResistancePriority(.required, for: .vertical)
        userBubble.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        userBubble.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        userLabel.setContentHuggingPriority(.required, for: .vertical)
        userLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            userTopToRole,
            userBubble.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            userBubble.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor, constant: 96),
            userBubbleBottom,

            userLabel.topAnchor.constraint(equalTo: userBubble.topAnchor, constant: 10),
            userLabel.bottomAnchor.constraint(equalTo: userBubble.bottomAnchor, constant: -10),
            userLabel.leadingAnchor.constraint(equalTo: userBubble.leadingAnchor, constant: 14),
            userLabel.trailingAnchor.constraint(equalTo: userBubble.trailingAnchor, constant: -14)
        ])
        userTopToImage.isActive = false
    }

    func applyCachedImageIfNeeded() {
        guard showsImageInBubble else { return }
        guard let image = cachedImage else { return }
        guard imageViewMsg.image !== image || imageViewMsg.isHidden else { return }
        imageViewMsg.image = image
        imageViewMsg.isHidden = false
        imageHeight.constant = 160
        userTopToRole.isActive = false
        userTopToImage.isActive = true
        applyUserLayoutWidth()
        userLabel.setNeedsLayout()
        userLabel.invalidateIntrinsicContentSize()
        scheduleMeasuredHeightNotify(for: messageID)
    }

    private func resolvedColumnWidth(for layoutWidth: CGFloat? = nil) -> CGFloat {
        let reference = layoutWidth ?? preferredLayoutWidth
        let columnW = column.bounds.width
        if columnW > 1 {
            return min(DSTheme.bubbleMaxWidth, columnW)
        }
        let cellW = max(contentView.bounds.width, bounds.width, reference, 120)
        return min(DSTheme.bubbleMaxWidth, max(cellW - 48, 120))
    }

    private func userLabelMaxWidth(for layoutWidth: CGFloat? = nil) -> CGFloat {
        max(resolvedColumnWidth(for: layoutWidth) - 124, 80)
    }

    private func applyUserLayoutWidth() {
        let width = userLabelMaxWidth()
        if abs(userLabel.preferredMaxLayoutWidth - width) > 0.5 {
            userLabel.preferredMaxLayoutWidth = width
            userLabel.invalidateIntrinsicContentSize()
        }
    }
}
