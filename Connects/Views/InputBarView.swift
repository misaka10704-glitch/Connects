import UIKit

protocol InputBarViewDelegate: AnyObject {
    func inputBarDidTapSend(text: String, imageBase64: String?)
    func inputBarDidTapStop()
    func inputBarDidTapAttach()
    func inputBarDidTapAgent()
    func inputBarDidToggleStudyCapture(_ enabled: Bool)
    func inputBarDidTapContextUsage()
}

/// ChatGPT-style composer: rounded pill, + / 联网 / 思考, inline image chip, send/stop.
final class InputBarView: UIView, ThemeRefreshable {
    weak var delegate: InputBarViewDelegate?

    private let containerView = UIView()
    private let attachButton = UIButton(type: .system)
    private let webSearchButton = UIButton(type: .system)
    private let thinkingButton = UIButton(type: .system)
    private let studyCaptureButton = UIButton(type: .system)
    private let memoryButton = UIButton(type: .system)
    private let agentButton = UIButton(type: .system)
    private let contextUsageButton = UIButton(type: .system)
    private let contextRing = ContextUsageRingView()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)

    /// Inline attachment chip inside the composer (ChatGPT-like).
    private let chip = UIView()
    private let chipImage = UIImageView()
    private let chipRemove = UIButton(type: .system)
    private let chipLabel = UILabel()

    private var textViewHeightConstraint: NSLayoutConstraint?
    private var chipHeightConstraint: NSLayoutConstraint?
    private var textTopToChip: NSLayoutConstraint?
    private var textTopToContainer: NSLayoutConstraint?
    private var studyCaptureWidthConstraint: NSLayoutConstraint?
    private var pendingImageBase64: String?

    private let btnSize: CGFloat = 30

    var isStreaming = false {
        didSet { updateStreamingState() }
    }

    var attachEnabled = true {
        didSet {
            attachButton.isEnabled = attachEnabled && !isStreaming
            attachButton.alpha = attachButton.isEnabled ? 1 : 0.35
        }
    }

    /// Window for anchoring menus to the + button.
    var attachAnchorView: UIView { attachButton }

    func attachAnchorRect() -> CGRect { attachButton.bounds }

    var hasAttachment: Bool { pendingImageBase64 != nil }
    var agentAnchorView: UIView { agentButton }
    var contextUsageAnchorView: UIView { contextUsageButton }

    private var contextUsageVisible = false

    var studyCaptureVisible = false {
        didSet {
            studyCaptureButton.isHidden = !studyCaptureVisible
            studyCaptureWidthConstraint?.constant = studyCaptureVisible ? btnSize : 0
            setNeedsLayout()
        }
    }

    var studyPageCaptureEnabled = false {
        didSet { updateStudyCaptureAppearance() }
    }

    func setAgent(_ agent: CustomAgent?) {
        agentButton.setTitle(nil, for: .normal)
        agentButton.setImage(agent == nil
            ? ActionIconFactory.image(.tshirt, pointSize: 16)
            : AgentAppearancePreset.avatar(for: agent, size: 20).withRenderingMode(.alwaysOriginal), for: .normal)
        agentButton.tintColor = agent == nil ? DSTheme.c.textSecondary : .clear
        agentButton.backgroundColor = .clear
        agentButton.layer.cornerRadius = 0
        agentButton.accessibilityLabel = agent == nil ? "选择智能体" : "当前智能体：\(agent!.name)"
    }

    var webSearchEnabled: Bool {
        get { SettingsManager.shared.webSearchEnabled }
        set {
            SettingsManager.shared.webSearchEnabled = newValue
            updateWebSearchAppearance()
        }
    }

    var thinkingEnabled: Bool {
        get { SettingsManager.shared.thinkingEnabled }
        set {
            SettingsManager.shared.thinkingEnabled = newValue
            updateThinkingAppearance()
        }
    }

    var memoryEnabled: Bool {
        get { SettingsManager.shared.memoryEnabled }
        set {
            SettingsManager.shared.memoryEnabled = newValue
            updateMemoryAppearance()
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
        chip.backgroundColor = c.surfaceHover
        chip.layer.borderColor = c.border.cgColor
        chipLabel.textColor = c.textSecondary
        chipRemove.tintColor = c.textSecondary
        chipRemove.backgroundColor = c.surface.withAlphaComponent(0.92)
        updateFocusBorder()
        updateSendEnabled()
        updateWebSearchAppearance()
        updateThinkingAppearance()
        updateStudyCaptureAppearance()
        updateMemoryAppearance()
        contextRing.applyTheme()
    }

    func updateContextUsage(_ usage: ContextBuilder.Usage, visible: Bool, animated: Bool = false) {
        contextUsageVisible = visible
        contextUsageButton.isHidden = !visible
        contextUsageButton.isEnabled = visible
        contextUsageButton.alpha = visible ? 1 : 0
        contextRing.setProgress(CGFloat(usage.ratio), animated: animated)
        contextUsageButton.accessibilityValue = usage.percentText
    }

    func setContextUsageCompacting(_ on: Bool) {
        contextUsageButton.isEnabled = !on && contextUsageVisible
        contextUsageButton.accessibilityLabel = on ? "正在压缩上下文" : "上下文占用"
    }

    private func updateFocusBorder() {
        let c = DSTheme.c
        let focused = textView.isFirstResponder
        containerView.layer.borderWidth = focused ? 1.5 : 1 / UIScreen.main.scale
        containerView.layer.borderColor = focused
            ? c.accent.withAlphaComponent(0.55).cgColor
            : c.inputBorder.cgColor
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
        chipImage.image = image
        chip.isHidden = false
        chipHeightConstraint?.constant = 56
        textTopToChip?.isActive = true
        textTopToContainer?.isActive = false
        updateSendEnabled()
        UIView.animate(withDuration: 0.15) { self.layoutIfNeeded() }
    }

    func clearAttachment() {
        pendingImageBase64 = nil
        chipImage.image = nil
        chip.isHidden = true
        chipHeightConstraint?.constant = 0
        textTopToChip?.isActive = false
        textTopToContainer?.isActive = true
        updateSendEnabled()
        UIView.animate(withDuration: 0.15) { self.layoutIfNeeded() }
    }

    private func setup() {
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = 22
        containerView.layer.borderWidth = 1 / UIScreen.main.scale
        containerView.clipsToBounds = true
        addSubview(containerView)

        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.layer.cornerRadius = 12
        chip.layer.borderWidth = 1 / UIScreen.main.scale
        chip.clipsToBounds = true
        chip.isHidden = true
        containerView.addSubview(chip)

        chipImage.translatesAutoresizingMaskIntoConstraints = false
        chipImage.contentMode = .scaleAspectFill
        chipImage.clipsToBounds = true
        chipImage.layer.cornerRadius = 8
        chip.addSubview(chipImage)

        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chipLabel.text = "图片"
        chipLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        chip.addSubview(chipLabel)

        chipRemove.translatesAutoresizingMaskIntoConstraints = false
        chipRemove.setImage(ActionIconFactory.image(.plus, pointSize: 10), for: .normal)
        // Draw a small × via title for clarity on iOS 12.
        chipRemove.setImage(nil, for: .normal)
        chipRemove.setTitle("×", for: .normal)
        chipRemove.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        chipRemove.layer.cornerRadius = 11
        chipRemove.clipsToBounds = true
        chipRemove.addTarget(self, action: #selector(removePreview), for: .touchUpInside)
        chip.addSubview(chipRemove)

        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.setImage(ActionIconFactory.image(.plus, pointSize: 16), for: .normal)
        attachButton.imageView?.contentMode = .scaleAspectFit
        attachButton.accessibilityLabel = "添加图片"
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)
        containerView.addSubview(attachButton)

        webSearchButton.translatesAutoresizingMaskIntoConstraints = false
        webSearchButton.setImage(ActionIconFactory.image(.globe, pointSize: 16), for: .normal)
        webSearchButton.imageView?.contentMode = .scaleAspectFit
        webSearchButton.accessibilityLabel = "联网搜索"
        webSearchButton.addTarget(self, action: #selector(webSearchTapped), for: .touchUpInside)
        containerView.addSubview(webSearchButton)

        thinkingButton.translatesAutoresizingMaskIntoConstraints = false
        thinkingButton.setImage(ActionIconFactory.image(.think, pointSize: 16), for: .normal)
        thinkingButton.imageView?.contentMode = .scaleAspectFit
        thinkingButton.accessibilityLabel = "深度思考"
        thinkingButton.addTarget(self, action: #selector(thinkingTapped), for: .touchUpInside)
        containerView.addSubview(thinkingButton)

        studyCaptureButton.translatesAutoresizingMaskIntoConstraints = false
        studyCaptureButton.setImage(ActionIconFactory.image(.book, pointSize: 16), for: .normal)
        studyCaptureButton.imageView?.contentMode = .scaleAspectFit
        studyCaptureButton.accessibilityLabel = "同步阅读页"
        studyCaptureButton.accessibilityHint = "开启后，发送消息时附带当前 PDF 页文字"
        studyCaptureButton.addTarget(self, action: #selector(studyCaptureTapped), for: .touchUpInside)
        studyCaptureButton.isHidden = true
        containerView.addSubview(studyCaptureButton)

        memoryButton.translatesAutoresizingMaskIntoConstraints = false
        memoryButton.setImage(ActionIconFactory.image(.vinyl, pointSize: 16), for: .normal)
        memoryButton.accessibilityLabel = "跨会话记忆"
        memoryButton.addTarget(self, action: #selector(memoryTapped), for: .touchUpInside)
        containerView.addSubview(memoryButton)

        agentButton.translatesAutoresizingMaskIntoConstraints = false
        agentButton.setImage(ActionIconFactory.image(.tshirt, pointSize: 16), for: .normal)
        agentButton.accessibilityLabel = "选择智能体"
        agentButton.addTarget(self, action: #selector(agentTapped), for: .touchUpInside)
        containerView.addSubview(agentButton)

        contextUsageButton.translatesAutoresizingMaskIntoConstraints = false
        contextUsageButton.accessibilityLabel = "上下文占用"
        contextUsageButton.accessibilityHint = "查看上下文组成与占用比例"
        contextUsageButton.addTarget(self, action: #selector(contextUsageTapped), for: .touchUpInside)
        contextUsageButton.isHidden = true
        containerView.addSubview(contextUsageButton)

        contextRing.translatesAutoresizingMaskIntoConstraints = false
        contextUsageButton.addSubview(contextRing)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.font = DSTheme.bodyFont(size: 16)
        textView.isScrollEnabled = false
        textView.delegate = self
        // Keep vertical insets balanced so the first line optically matches + / 🌐 / send.
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
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

        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 36)
        chipHeightConstraint = chip.heightAnchor.constraint(equalToConstant: 0)
        textTopToChip = textView.topAnchor.constraint(equalTo: chip.bottomAnchor, constant: 4)
        textTopToContainer = textView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 39)
        studyCaptureWidthConstraint = studyCaptureButton.widthAnchor.constraint(equalToConstant: 0)
        textTopToContainer?.isActive = true

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            chip.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 40),
            chip.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            chip.trailingAnchor.constraint(lessThanOrEqualTo: sendButton.leadingAnchor, constant: -8),
            chipWidthConstraint(),
            chipHeightConstraint!,

            chipImage.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
            chipImage.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chipImage.widthAnchor.constraint(equalToConstant: 40),
            chipImage.heightAnchor.constraint(equalToConstant: 40),

            chipLabel.leadingAnchor.constraint(equalTo: chipImage.trailingAnchor, constant: 8),
            chipLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor),

            chipRemove.leadingAnchor.constraint(equalTo: chipLabel.trailingAnchor, constant: 6),
            chipRemove.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
            chipRemove.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chipRemove.widthAnchor.constraint(equalToConstant: 22),
            chipRemove.heightAnchor.constraint(equalToConstant: 22),

            // Composer tools live in a compact row above the editor, leaving the
            // input line its full width while keeping send in its usual place.
            agentButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            agentButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
            agentButton.widthAnchor.constraint(equalToConstant: btnSize),
            agentButton.heightAnchor.constraint(equalToConstant: btnSize),

            memoryButton.leadingAnchor.constraint(equalTo: agentButton.trailingAnchor, constant: 2),
            memoryButton.centerYAnchor.constraint(equalTo: agentButton.centerYAnchor),
            memoryButton.widthAnchor.constraint(equalToConstant: btnSize),
            memoryButton.heightAnchor.constraint(equalToConstant: btnSize),

            attachButton.leadingAnchor.constraint(equalTo: memoryButton.trailingAnchor, constant: 2),
            attachButton.centerYAnchor.constraint(equalTo: agentButton.centerYAnchor),
            attachButton.widthAnchor.constraint(equalToConstant: btnSize),
            attachButton.heightAnchor.constraint(equalToConstant: btnSize),

            studyCaptureButton.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 2),
            studyCaptureButton.centerYAnchor.constraint(equalTo: agentButton.centerYAnchor),
            studyCaptureWidthConstraint!,
            studyCaptureButton.heightAnchor.constraint(equalToConstant: btnSize),

            webSearchButton.leadingAnchor.constraint(equalTo: studyCaptureButton.trailingAnchor, constant: 2),
            webSearchButton.centerYAnchor.constraint(equalTo: agentButton.centerYAnchor),
            webSearchButton.widthAnchor.constraint(equalToConstant: btnSize),
            webSearchButton.heightAnchor.constraint(equalToConstant: btnSize),

            thinkingButton.leadingAnchor.constraint(equalTo: webSearchButton.trailingAnchor, constant: 2),
            thinkingButton.centerYAnchor.constraint(equalTo: agentButton.centerYAnchor),
            thinkingButton.widthAnchor.constraint(equalToConstant: btnSize),
            thinkingButton.heightAnchor.constraint(equalToConstant: btnSize),
            thinkingButton.trailingAnchor.constraint(lessThanOrEqualTo: contextUsageButton.leadingAnchor, constant: -2),

            contextUsageButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            contextUsageButton.centerYAnchor.constraint(equalTo: agentButton.centerYAnchor),
            contextUsageButton.widthAnchor.constraint(equalToConstant: btnSize),
            contextUsageButton.heightAnchor.constraint(equalToConstant: btnSize),

            contextRing.centerXAnchor.constraint(equalTo: contextUsageButton.centerXAnchor),
            contextRing.centerYAnchor.constraint(equalTo: contextUsageButton.centerYAnchor),
            contextRing.widthAnchor.constraint(equalToConstant: 22),
            contextRing.heightAnchor.constraint(equalToConstant: 22),

            sendButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            sendButton.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: btnSize),
            sendButton.heightAnchor.constraint(equalToConstant: btnSize),

            stopButton.trailingAnchor.constraint(equalTo: sendButton.trailingAnchor),
            stopButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: btnSize),
            stopButton.heightAnchor.constraint(equalToConstant: btnSize),

            textView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            textView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -7),
            textViewHeightConstraint!,

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: textView.centerYAnchor)
        ])
    }

    private func chipWidthConstraint() -> NSLayoutConstraint {
        // Hug content: image + label + remove + paddings ≈ 130
        let w = chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 118)
        w.priority = .defaultHigh
        return w
    }

    private func updateStreamingState() {
        sendButton.isHidden = isStreaming
        stopButton.isHidden = !isStreaming
        textView.isEditable = !isStreaming
        attachButton.isEnabled = !isStreaming && attachEnabled
        attachButton.alpha = attachButton.isEnabled ? 1 : 0.35
        webSearchButton.isEnabled = !isStreaming
        webSearchButton.alpha = isStreaming ? 0.35 : 1
        thinkingButton.isEnabled = !isStreaming
        thinkingButton.alpha = isStreaming ? 0.35 : 1
        studyCaptureButton.isEnabled = !isStreaming && studyCaptureVisible
        studyCaptureButton.alpha = studyCaptureButton.isEnabled ? 1 : 0.35
        memoryButton.isEnabled = !isStreaming
        memoryButton.alpha = isStreaming ? 0.35 : 1
        agentButton.isEnabled = !isStreaming
        agentButton.alpha = isStreaming ? 0.35 : 1
        contextUsageButton.isEnabled = !isStreaming && contextUsageVisible
        contextUsageButton.alpha = (isStreaming || !contextUsageVisible) ? 0.35 : 1
        chipRemove.isEnabled = !isStreaming
        updateSendEnabled()
    }

    private func updateToggleAppearance(_ button: UIButton, on: Bool) {
        let c = DSTheme.c
        button.tintColor = on ? c.accent : c.textSecondary
        button.backgroundColor = on ? c.accent.withAlphaComponent(0.14) : .clear
        button.layer.cornerRadius = btnSize / 2
        button.accessibilityValue = on ? "开" : "关"
    }

    private func updateWebSearchAppearance() {
        updateToggleAppearance(webSearchButton, on: webSearchEnabled)
    }

    private func updateThinkingAppearance() {
        updateToggleAppearance(thinkingButton, on: thinkingEnabled)
    }

    private func updateStudyCaptureAppearance() {
        updateToggleAppearance(studyCaptureButton, on: studyPageCaptureEnabled)
    }

    private func updateMemoryAppearance() {
        updateToggleAppearance(memoryButton, on: memoryEnabled)
    }

    private func updateSendEnabled() {
        let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let on = (hasText || pendingImageBase64 != nil) && !isStreaming
        sendButton.isEnabled = on
        sendButton.alpha = on ? 1 : 0.45
        let c = DSTheme.c
        sendButton.backgroundColor = on ? c.sendEnabled : c.sendDisabled
        sendButton.tintColor = .white
        // Highlight attach when an image is staged.
        if pendingImageBase64 != nil {
            attachButton.tintColor = c.accent
        } else {
            attachButton.tintColor = c.textSecondary
        }
    }

    private func updateTextViewHeight() {
        let width = textView.bounds.width > 0 ? textView.bounds.width : 400
        let size = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = min(max(36, size.height), 120)
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

    @objc private func webSearchTapped() {
        webSearchEnabled.toggle()
    }

    @objc private func thinkingTapped() {
        thinkingEnabled.toggle()
    }

    @objc private func studyCaptureTapped() {
        studyPageCaptureEnabled.toggle()
        delegate?.inputBarDidToggleStudyCapture(studyPageCaptureEnabled)
    }

    @objc private func memoryTapped() {
        memoryEnabled.toggle()
    }

    @objc private func agentTapped() {
        delegate?.inputBarDidTapAgent()
    }

    @objc private func contextUsageTapped() {
        delegate?.inputBarDidTapContextUsage()
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
