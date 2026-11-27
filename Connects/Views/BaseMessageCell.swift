import UIKit

/// Horizontal thumbnail row used when one chat message carries multiple images.
final class MessageImageStripView: UIView {
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 8
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func setImages(_ images: [UIImage]) {
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for image in images {
            let view = UIImageView(image: image)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.layer.cornerRadius = 10
            stackView.addArrangedSubview(view)
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 118),
                view.heightAnchor.constraint(equalToConstant: 152)
            ])
        }
    }

    func clear() {
        setImages([])
    }
}

/// Column + optional image attachment shared by user and assistant rows.
class BaseMessageCell: UITableViewCell, MessageCellType {
    var messageID: String = ""
    weak var cellDelegate: MessageCellDelegate?

    let column = UIView()
    let roleLabel = UILabel()
    let imageViewMsg = UIImageView()
    let imageStripView = MessageImageStripView()

    var columnWidthFill: NSLayoutConstraint!
    var columnWidthMax: NSLayoutConstraint!
    var columnBottomPin: NSLayoutConstraint!
    var imageHeight: NSLayoutConstraint!

    var cachedImage: UIImage?
    var cachedImages: [UIImage] = []
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
        cachedImages = image.map { [$0] } ?? []
    }

    func setCachedImages(_ images: [UIImage]?) {
        cachedImages = images ?? []
        cachedImage = cachedImages.first
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
        if message.showsImageInChat {
            let expectedCount = max(1, message.imageCount)
            let usableCache = cachedImages.count == expectedCount && !cachedImages.isEmpty
            let images: [UIImage]
            if cellDelegate?.messageCellShouldDeferHeavyRender(self) == true {
                images = usableCache ? cachedImages : []
            } else if usableCache {
                images = cachedImages
            } else {
                images = message.allImageBase64.compactMap {
                    ImageAttachmentHelper.thumbnail(from: $0)
                }
            }
            presentMessageImages(images)
        } else {
            clearMessageImages()
            cachedImage = nil
            cachedImages = []
        }
    }

    func presentMessageImages(_ images: [UIImage]) {
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

    func clearMessageImages() {
        imageViewMsg.image = nil
        imageViewMsg.isHidden = true
        imageHeight.constant = 0
        imageStripView.clear()
        imageStripView.isHidden = true
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
        cachedImages = []
        clearMessageImages()
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
        imageViewMsg.isUserInteractionEnabled = true
        column.addSubview(imageViewMsg)

        imageStripView.translatesAutoresizingMaskIntoConstraints = false
        imageStripView.isHidden = true
        imageViewMsg.addSubview(imageStripView)

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
            imageHeight,

            imageStripView.leadingAnchor.constraint(equalTo: imageViewMsg.leadingAnchor),
            imageStripView.trailingAnchor.constraint(equalTo: imageViewMsg.trailingAnchor),
            imageStripView.topAnchor.constraint(equalTo: imageViewMsg.topAnchor),
            imageStripView.bottomAnchor.constraint(equalTo: imageViewMsg.bottomAnchor)
        ])
    }
}
