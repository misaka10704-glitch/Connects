import UIKit

/// Column + optional image attachment shared by user and assistant rows.
class BaseMessageCell: UITableViewCell, MessageCellType {
    var messageID: String = ""
    weak var cellDelegate: MessageCellDelegate?

    let column = UIView()
    let roleLabel = UILabel()
    let imageViewMsg = UIImageView()

    var columnWidthFill: NSLayoutConstraint!
    var columnWidthMax: NSLayoutConstraint!
    var columnBottomPin: NSLayoutConstraint!
    var imageHeight: NSLayoutConstraint!

    var cachedImage: UIImage?
    var preferredLayoutWidth: CGFloat = 0
    var configuredPreferredHeight: CGFloat?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupColumn()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupColumn()
    }

    func configure(with message: ChatMessage, preferredHeight: CGFloat?, layoutWidth: CGFloat) {
        fatalError("Subclasses must override configure(with:preferredHeight:layoutWidth:)")
    }

    func setCachedImage(_ image: UIImage?) {
        cachedImage = image
    }

    func measuredContentHeight() -> CGFloat {
        contentView.layoutIfNeeded()
        return column.bounds.height
    }

    func refreshRenderDebugOverlay() {
        let on = SettingsManager.shared.renderDebugOverlayEnabled
        column.layer.borderWidth = on ? 1 / UIScreen.main.scale : 0
        guard on else { return }
        let red: UIColor
        if #available(iOS 13.0, *) { red = .systemRed }
        else { red = UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1) }
        column.layer.borderColor = red.withAlphaComponent(0.45).cgColor
    }

    func applySharedImage(to message: ChatMessage) {
        if message.hasImage {
            if cellDelegate?.messageCellShouldDeferHeavyRender(self) == true {
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
    }

    func scheduleMeasuredHeightNotify(for messageID: String) {
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

    func resetSharedReuseState() {
        messageID = ""
        cachedImage = nil
        imageViewMsg.image = nil
        imageViewMsg.isHidden = true
        imageHeight.constant = 0
        configuredPreferredHeight = nil
        preferredLayoutWidth = 0
        roleLabel.isHidden = true
        roleLabel.text = nil
    }

    private func setupColumn() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = true
        clipsToBounds = true

        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)

        roleLabel.translatesAutoresizingMaskIntoConstraints = false
        roleLabel.isHidden = true
        column.addSubview(roleLabel)

        imageViewMsg.translatesAutoresizingMaskIntoConstraints = false
        imageViewMsg.contentMode = .scaleAspectFill
        imageViewMsg.clipsToBounds = true
        imageViewMsg.layer.cornerRadius = 12
        imageViewMsg.isHidden = true
        column.addSubview(imageViewMsg)

        columnWidthFill = column.widthAnchor.constraint(equalTo: contentView.widthAnchor, constant: -48)
        columnWidthFill.priority = UILayoutPriority(999)
        columnWidthMax = column.widthAnchor.constraint(lessThanOrEqualToConstant: DSTheme.bubbleMaxWidth)
        imageHeight = imageViewMsg.heightAnchor.constraint(equalToConstant: 0)

        column.setContentHuggingPriority(.required, for: .vertical)
        column.setContentCompressionResistancePriority(.required, for: .vertical)
        contentView.setContentHuggingPriority(.required, for: .vertical)

        let bottomPin = contentView.bottomAnchor.constraint(
            equalTo: column.bottomAnchor,
            constant: ChatRowHeightResolver.cellContentInset
        )
        bottomPin.priority = UILayoutPriority(999)
        columnBottomPin = bottomPin

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: ChatRowHeightResolver.cellContentInset
            ),
            bottomPin,
            column.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            columnWidthFill,
            columnWidthMax,

            roleLabel.topAnchor.constraint(equalTo: column.topAnchor),
            roleLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            roleLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            roleLabel.heightAnchor.constraint(equalToConstant: 0),

            imageViewMsg.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 0),
            imageViewMsg.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            imageViewMsg.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            imageHeight
        ])
    }
}
