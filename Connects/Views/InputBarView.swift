import UIKit

protocol InputBarViewDelegate: AnyObject {
    func inputBarDidTapSend(text: String, imageBase64: String?)
    func inputBarDidTapStop()
    func inputBarDidTapAttach()
}

/// ChatGPT-style composer: single rounded pill, + left, send/stop right, vertically centered.
final class InputBarView: UIView, ThemeRefreshable {
    weak var delegate: InputBarViewDelegate?

    private let containerView = UIView()
    private let attachButton = UIButton(type: .system)
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let previewContainer = UIView()
    private let previewImageView = UIImageView()
    private let removePreviewButton = UIButton(type: .system)
    private var textViewHeightConstraint: NSLayoutConstraint?
    private var previewHeightConstraint: NSLayoutConstraint?
    private var pendingImageBase64: String?

    private let btnSize: CGFloat = 30

    var isStreaming = false {
        didSet { updateStreamingState() }
    }

    var attachEnabled = true {
        didSet {
            attachButton.isEnabled = attachEnabled
            attachButton.alpha = attachEnabled ? 1 : 0.35
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        applyTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
        applyTheme()
    }

    func applyTheme() {
        let c = DSTheme.c
        backgroundColor = c.background
        containerView.backgroundColor = c.inputBackground
        textView.textColor = c.textPrimary
        textView.tintColor = c.accent
        placeholderLabel.textColor = c.textSecondary
        attachButton.tintColor = c.textSecondary
        stopButton.backgroundColor = c.textPrimary
        stopButton.tintColor = c.background
        stopButton.setImage(ActionIconFactory.image(.stop, pointSize: 12, color: .white), for: .normal)
        previewContainer.backgroundColor = c.surface
        removePreviewButton.setTitleColor(c.textSecondary, for: .normal)
        updateFocusBorder()
        updateSendEnabled()
    }

    private func updateFocusBorder() {
        let c = DSTheme.c
        let focused = textView.isFirstResponder
        containerView.layer.borderWidth = focused ? 1.5 : 1 / UIScreen.main.scale
        containerView.layer.borderColor = focused ? c.accent.withAlphaComponent(0.55).cgColor : c.inputBorder.cgColor
    }

    func clearText() {
        textView.text = ""
        placeholderLabel.isHidden = false
        clearAttachment()
        updateTextViewHeight()
        updateSendEnabled()
    }

    func setAttachment(image: UIImage, base64: String) {
        pendingImageBase64 = base64
        previewImageView.image = image
        previewContainer.isHidden = false
        previewHeightConstraint?.constant = 64
        updateSendEnabled()
    }

    func clearAttachment() {
        pendingImageBase64 = nil
        previewImageView.image = nil
        previewContainer.isHidden = true
        previewHeightConstraint?.constant = 0
        updateSendEnabled()
    }

    private func setup() {
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.layer.cornerRadius = 12
        previewContainer.clipsToBounds = true
        previewContainer.isHidden = true
        addSubview(previewContainer)

        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.contentMode = .scaleAspectFill
        previewImageView.clipsToBounds = true
        previewContainer.addSubview(previewImageView)

        removePreviewButton.translatesAutoresizingMaskIntoConstraints = false
        removePreviewButton.setTitle("×", for: .normal)
        removePreviewButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        removePreviewButton.addTarget(self, action: #selector(removePreview), for: .touchUpInside)
        previewContainer.addSubview(removePreviewButton)

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = 22
        containerView.layer.borderWidth = 1 / UIScreen.main.scale
        addSubview(containerView)

        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.setImage(ActionIconFactory.image(.plus, pointSize: 16), for: .normal)
        attachButton.imageView?.contentMode = .scaleAspectFit
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)
        containerView.addSubview(attachButton)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.font = DSTheme.bodyFont(size: 16)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        containerView.addSubview(textView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.text = "问任何问题…"
        placeholderLabel.font = DSTheme.bodyFont(size: 16)
        containerView.addSubview(placeholderLabel)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setImage(ActionIconFactory.image(.send, pointSize: 14, color: .white), for: .normal)
        sendButton.tintColor = .white
        sendButton.imageView?.contentMode = .scaleAspectFit
        sendButton.layer.cornerRadius = btnSize / 2
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        containerView.addSubview(sendButton)

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.setImage(ActionIconFactory.image(.stop, pointSize: 12, color: .white), for: .normal)
        stopButton.tintColor = .white
        stopButton.imageView?.contentMode = .scaleAspectFit
        stopButton.layer.cornerRadius = btnSize / 2
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        stopButton.isHidden = true
        containerView.addSubview(stopButton)

        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 44)
        previewHeightConstraint = previewContainer.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: topAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewHeightConstraint!,

            previewImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 8),
            previewImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 6),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -6),
            previewImageView.widthAnchor.constraint(equalToConstant: 44),
            previewImageView.heightAnchor.constraint(equalToConstant: 44),

            removePreviewButton.leadingAnchor.constraint(equalTo: previewImageView.trailingAnchor, constant: 8),
            removePreviewButton.centerYAnchor.constraint(equalTo: previewImageView.centerYAnchor),

            containerView.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 6),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            // Pin attach/send to bottom of pill (ChatGPT: controls sit on last line)
            attachButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            attachButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -7),
            attachButton.widthAnchor.constraint(equalToConstant: btnSize),
            attachButton.heightAnchor.constraint(equalToConstant: btnSize),

            sendButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -7),
            sendButton.widthAnchor.constraint(equalToConstant: btnSize),
            sendButton.heightAnchor.constraint(equalToConstant: btnSize),

            stopButton.trailingAnchor.constraint(equalTo: sendButton.trailingAnchor),
            stopButton.bottomAnchor.constraint(equalTo: sendButton.bottomAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: btnSize),
            stopButton.heightAnchor.constraint(equalToConstant: btnSize),

            textView.topAnchor.constraint(equalTo: containerView.topAnchor),
            textView.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 6),
            textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            textView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            textViewHeightConstraint!,

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor)
        ])
    }

    private func updateStreamingState() {
        sendButton.isHidden = isStreaming
        stopButton.isHidden = !isStreaming
        textView.isEditable = !isStreaming
        attachButton.isEnabled = !isStreaming && attachEnabled
        updateSendEnabled()
    }

    private func updateSendEnabled() {
        let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let on = (hasText || pendingImageBase64 != nil) && !isStreaming
        sendButton.isEnabled = on
        sendButton.alpha = on ? 1 : 0.45
        let c = DSTheme.c
        sendButton.backgroundColor = on ? c.sendEnabled : c.sendDisabled
        sendButton.tintColor = .white
    }

    private func updateTextViewHeight() {
        let width = textView.bounds.width > 0 ? textView.bounds.width : 400
        let size = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = min(max(44, size.height), 120)
        textViewHeightConstraint?.constant = height
        textView.isScrollEnabled = height >= 120
    }

    @objc private func sendTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || pendingImageBase64 != nil else { return }
        delegate?.inputBarDidTapSend(text: text, imageBase64: pendingImageBase64)
    }

    @objc private func stopTapped() {
        delegate?.inputBarDidTapStop()
    }

    @objc private func attachTapped() {
        delegate?.inputBarDidTapAttach()
    }

    @objc private func removePreview() {
        clearAttachment()
    }
}

extension InputBarView: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateTextViewHeight()
        updateSendEnabled()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        updateFocusBorder()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        updateFocusBorder()
    }
}
