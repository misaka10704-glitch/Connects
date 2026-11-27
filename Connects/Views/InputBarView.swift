import UIKit

protocol InputBarViewDelegate: AnyObject {
    func inputBarDidTapSend(text: String, imagesBase64: [String])
    func inputBarDidTapStop()
    func inputBarDidTapAttach()
    func inputBarDidToggleStudyCapture(_ enabled: Bool)
    func inputBarDidToggleCodeAIEdit(_ enabled: Bool)
    func inputBarDidTapContextUsage()
    func inputBarDidRequestStudyContextScope(from sourceView: UIView)
    func inputBarDidRequestReasoningEffort(from sourceView: UIView)
    func inputBarDidTapAIOptions()
    func inputBarDidTapDiffUndoAll()
    func inputBarDidTapDiffKeepAll()
    func inputBarDidTapDiffReview()
    func inputBarDidSelectDiffFile(documentID: String)
    func inputBarDidChangeStudyAgentMode(_ mode: StudyAgentMode)
    func inputBarDidRejectUnsupportedImage()
}

extension InputBarViewDelegate {
    func inputBarDidRequestStudyContextScope(from sourceView: UIView) {}
    func inputBarDidRequestReasoningEffort(from sourceView: UIView) {}
    func inputBarDidTapAIOptions() {}
    func inputBarDidToggleCodeAIEdit(_ enabled: Bool) {}
    func inputBarDidTapDiffUndoAll() {}
    func inputBarDidTapDiffKeepAll() {}
    func inputBarDidTapDiffReview() {}
    func inputBarDidSelectDiffFile(documentID: String) {}
    func inputBarDidChangeStudyAgentMode(_ mode: StudyAgentMode) {}
    func inputBarDidRejectUnsupportedImage() {}
}

/// ChatGPT-style composer: rounded pill, + / 联网 / 思考, inline image chip, send/stop.
final class InputBarView: UIView, ThemeRefreshable {
    weak var delegate: InputBarViewDelegate?

    /// Slim Undo All / Keep All strip inside the composer capsule (not a separate wide bar).
    private let diffReviewBanner = UIView()
    private let diffExpandButton = UIButton(type: .system)
    private let diffChangesLabel = UILabel()
    private let diffUndoAllButton = UIButton(type: .system)
    private let diffKeepAllButton = UIButton(type: .system)
    private let diffReviewButton = UIButton(type: .system)
    private let diffFileListStack = UIStackView()
    private var diffBannerHeightConstraint: NSLayoutConstraint?
    private var toolsTopToBanner: NSLayoutConstraint?
    private var toolsTopToContainer: NSLayoutConstraint?
    private var diffBannerVisible = false
    private var diffBannerExpanded = false
    private var diffBannerFiles: [(documentID: String, fileName: String, additions: Int, deletions: Int)] = []
    private var diffBannerMultifile = false

    /// Plan Build todo progress strip (above composer tools).
    private let buildTodoStrip = UIView()
    private let buildTodoLabel = UILabel()
    private var buildTodoHeightConstraint: NSLayoutConstraint?
    private var buildTodoVisible = false
    private var toolsTopToBuildTodo: NSLayoutConstraint?

    /// Workspace Agent / Plan / Ask mode chip.
    private let agentModeButton = UIButton(type: .custom)
    private var agentModeWidthConstraint: NSLayoutConstraint?
    private(set) var studyAgentMode: StudyAgentMode = .ask
    var studyAgentModeVisible = false {
        didSet {
            agentModeButton.isHidden = !studyAgentModeVisible
            agentModeWidthConstraint?.constant = studyAgentModeVisible ? 64 : 0
            updateAgentModeAppearance()
            setNeedsLayout()
        }
    }

    private let containerView = UIView()
    private let attachButton = UIButton(type: .system)
    private let thinkingButton = UIButton(type: .system)
    /// Study code/text: grants the model permission to propose file edits (not forced).
    private let codeAIEditButton = UIButton(type: .system)
    private let studyCaptureButton = UIButton(type: .system)
    private let askSelectionButton = UIButton(type: .system)
    private let contextUsageButton = UIButton(type: .system)
    private let contextRing = ContextUsageRingView()
    /// Long capsule left of the context ring — picks Kimi / Qwen / etc.
    private let aiOptionsButton = UIButton(type: .system)
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)

    /// Horizontal attachment thumbnail strip inside the composer (ChatGPT-like).
    private let chip = UIView()
    private let attachmentScrollView = UIScrollView()
    private let attachmentStackView = UIStackView()
    private var attachmentRemoveButtons: [UIButton] = []

    private var textViewHeightConstraint: NSLayoutConstraint?
    private var chipHeightConstraint: NSLayoutConstraint?
    private var textTopToChip: NSLayoutConstraint?
    private var textTopToContainer: NSLayoutConstraint?
    private var studyCaptureWidthConstraint: NSLayoutConstraint?
    private var codeAIEditWidthConstraint: NSLayoutConstraint?
    private var askSelectionWidthConstraint: NSLayoutConstraint?
    private var aiOptionsWidthConstraint: NSLayoutConstraint?
    private var contextUsageWidthConstraint: NSLayoutConstraint?
    static let maxImageAttachments = 9
    /// Only bounded chip thumbnails plus base64 strings are retained — never picker originals.
    private(set) var pendingImages: [(image: UIImage, base64: String)] = []
    /// Slot reserved in the tool row for Ask (supported study docs).
    private var askSlotVisible = false
    /// Bright when a selection is attached; gray placeholder otherwise.
    private var askHasSelection = false
    /// Shown on the model chip before `setModelChip` runs.
    private var modelChipDisplayName = "AI"
    private var modelChipPressed = false

    /// Cleared when user dismisses the Ask 选区 badge.
    var onClearAskSelection: (() -> Void)?

    private let btnSize: CGFloat = 32
    private let textMaxHeight: CGFloat = 120

    var aiOptionsAnchorView: UIView { aiOptionsButton }

    var isStreaming = false {
        didSet { updateStreamingState() }
    }

    var attachEnabled = true {
        didSet {
            attachButton.isEnabled = attachEnabled && !isStreaming
            attachButton.alpha = attachButton.isEnabled ? 1 : 0.35
        }
    }

    /// Composer send is visually disabled when an image is staged on a text-only model.
    var modelSupportsVision = true {
        didSet { updateSendEnabled() }
    }

    private var blocksUnsupportedImageSend: Bool {
        !pendingImages.isEmpty && !modelSupportsVision
    }

    /// Window for anchoring menus to the + button.
    var attachAnchorView: UIView { attachButton }

    func attachAnchorRect() -> CGRect { attachButton.bounds }

    var hasAttachment: Bool { !pendingImages.isEmpty }
    var attachmentCount: Int { pendingImages.count }
    var pendingImageBase64List: [String] { pendingImages.map { $0.base64 } }
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

    var thinkingEnabled: Bool {
        get { SettingsManager.shared.thinkingEnabled }
        set {
            SettingsManager.shared.thinkingEnabled = newValue
            updateThinkingAppearance()
        }
    }

    /// When true, Study chat may inject edit-authorization and honor CONNECTS_EDIT proposals.
    private(set) var codeAIEditEnabled = false

    /// Show the「AI 编辑」slot (Study code/text docs only).
    var codeAIEditVisible = false {
        didSet {
            codeAIEditButton.isHidden = !codeAIEditVisible
            codeAIEditWidthConstraint?.constant = codeAIEditVisible ? btnSize : 0
            if !codeAIEditVisible, codeAIEditEnabled {
                setCodeAIEditEnabled(false, notify: true)
            }
            setNeedsLayout()
        }
    }

    func setCodeAIEditEnabled(_ enabled: Bool, notify: Bool = false) {
        guard codeAIEditEnabled != enabled else {
            updateCodeAIEditAppearance()
            return
        }
        codeAIEditEnabled = enabled
        updateCodeAIEditAppearance()
        // One-way bind: arming AI edit also turns on document context so the model can see the file.
        // Turning AI edit off (or toggling document alone) does not change the other switch.
        if enabled, studyCaptureVisible, !studyPageCaptureEnabled {
            studyPageCaptureEnabled = true
            delegate?.inputBarDidToggleStudyCapture(true)
        }
        if notify {
            delegate?.inputBarDidToggleCodeAIEdit(enabled)
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
        stopButton.setImage(ActionIconFactory.image(.stop, pointSize: ActionIconFactory.sendGlyph, color: .white), for: .normal)
        chip.backgroundColor = .clear
        for button in attachmentRemoveButtons {
            button.setTitleColor(c.textSecondary, for: .normal)
            button.backgroundColor = c.surface.withAlphaComponent(0.92)
        }
        applyDiffBannerTheme()
        updateAskSelectionAppearance()
        updateFocusBorder()
        updateSendEnabled()
        updateThinkingAppearance()
        updateCodeAIEditAppearance()
        updateAgentModeAppearance()
        updateStudyCaptureAppearance()
        updateAIOptionsAppearance()
        contextRing.applyTheme()
    }

    /// Show/hide the Keep / Review strip inside the composer capsule.
    func setDiffReviewBanner(visible: Bool, changeCount: Int = 0) {
        setDiffReviewBanner(
            visible: visible,
            files: changeCount > 0
                ? [(documentID: "", fileName: "\(changeCount) 处改动", additions: changeCount, deletions: 0)]
                : [],
            multifile: false
        )
    }

    func setDiffReviewBanner(
        visible: Bool,
        files: [(documentID: String, fileName: String, additions: Int, deletions: Int)],
        multifile: Bool
    ) {
        let show = visible && !files.isEmpty
        diffBannerVisible = show
        diffBannerFiles = files
        diffBannerMultifile = multifile && files.count >= 1
        if !show { diffBannerExpanded = false }
        diffReviewBanner.isHidden = !show
        rebuildDiffBannerChrome()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        UIView.animate(withDuration: 0.18) { self.layoutIfNeeded() }
    }

    /// Show workspace plan Build todo progress above the composer tools row.
    func setBuildTodoProgress(
        done: Int = 0,
        total: Int = 0,
        currentTitle: String? = nil,
        visible: Bool
    ) {
        let show = visible && total > 0
        buildTodoVisible = show
        buildTodoStrip.isHidden = !show
        if show {
            if let currentTitle, !currentTitle.isEmpty, done < total {
                let clip = String(currentTitle.prefix(36))
                buildTodoLabel.text = "待办 \(done)/\(total) · \(clip)"
            } else {
                buildTodoLabel.text = "待办 \(done)/\(total)"
            }
        }
        buildTodoHeightConstraint?.constant = show ? 24 : 0
        retargetToolsTopAnchor()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        UIView.animate(withDuration: 0.18) { self.layoutIfNeeded() }
    }

    private func retargetToolsTopAnchor() {
        if buildTodoVisible {
            toolsTopToBuildTodo?.isActive = true
            toolsTopToBanner?.isActive = false
            toolsTopToContainer?.isActive = false
        } else if diffBannerVisible {
            toolsTopToBuildTodo?.isActive = false
            toolsTopToBanner?.isActive = true
            toolsTopToContainer?.isActive = false
        } else {
            toolsTopToBuildTodo?.isActive = false
            toolsTopToBanner?.isActive = false
            toolsTopToContainer?.isActive = true
        }
    }

    private func rebuildDiffBannerChrome() {
        let show = diffBannerVisible
        let listRows = diffBannerExpanded && diffBannerMultifile ? diffBannerFiles.count : 0
        let rowH: CGFloat = 28
        let headerH: CGFloat = 30
        let height = show ? (headerH + CGFloat(listRows) * rowH) : 0
        diffBannerHeightConstraint?.constant = height
        retargetToolsTopAnchor()

        let n = diffBannerFiles.count
        if diffBannerMultifile {
            let chevron = diffBannerExpanded ? "▼" : "▶"
            diffExpandButton.setTitle("\(chevron) \(n) File\(n == 1 ? "" : "s")", for: .normal)
            diffExpandButton.isHidden = false
            diffChangesLabel.isHidden = true
            diffReviewButton.isHidden = false
        } else {
            diffExpandButton.isHidden = true
            diffChangesLabel.isHidden = false
            diffReviewButton.isHidden = true
            let add = diffBannerFiles.first?.additions ?? 0
            let del = diffBannerFiles.first?.deletions ?? 0
            if add > 0 || del > 0 {
                diffChangesLabel.text = "+\(add) −\(del)"
            } else {
                let changes = max(add, n)
                diffChangesLabel.text = changes == 1 ? "1 处改动" : "\(changes) 处改动"
            }
        }

        diffFileListStack.arrangedSubviews.forEach {
            diffFileListStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard show, diffBannerExpanded, diffBannerMultifile else { return }
        for file in diffBannerFiles {
            let row = UIButton(type: .system)
            row.contentHorizontalAlignment = .left
            row.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
            row.setTitle("  \(file.fileName)  +\(file.additions) −\(file.deletions)", for: .normal)
            row.accessibilityIdentifier = file.documentID
            row.addTarget(self, action: #selector(diffFileRowTapped(_:)), for: .touchUpInside)
            diffFileListStack.addArrangedSubview(row)
            row.heightAnchor.constraint(equalToConstant: rowH).isActive = true
        }
    }

    func updateContextUsage(_ usage: ContextBuilder.Usage, visible: Bool, animated: Bool = false) {
        contextUsageVisible = visible
        contextUsageButton.isHidden = !visible
        contextUsageButton.isEnabled = visible
        contextUsageButton.alpha = visible ? 1 : 0
        contextUsageWidthConstraint?.constant = visible ? btnSize : 0
        contextRing.setProgress(CGFloat(usage.ratio), animated: animated)
        contextUsageButton.accessibilityValue = usage.percentText
        containerView.bringSubviewToFront(aiOptionsButton)
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

    func setComposerText(_ text: String, focus: Bool = true) {
        textView.text = text
        placeholderLabel.isHidden = !text.isEmpty
        updateTextViewHeight()
        updateSendEnabled()
        if focus {
            textView.becomeFirstResponder()
            updateFocusBorder()
        }
    }

    func focusComposer() {
        textView.becomeFirstResponder()
        updateFocusBorder()
    }

    var isComposerFirstResponder: Bool {
        textView.isFirstResponder
    }

    /// Trigger the same path as tapping Send (for ⌘↩).
    func sendFromKeyboardShortcut() {
        sendTapped()
    }

    /// Show Ask in the tool row for supported docs (gray until a selection is armed).
    func setAskSelectionSlotVisible(_ visible: Bool) {
        askSlotVisible = visible
        if !visible { askHasSelection = false }
        askSelectionButton.isHidden = !visible
        askSelectionWidthConstraint?.constant = visible ? btnSize : 0
        updateAskSelectionAppearance()
        updateStreamingState()
        setNeedsLayout()
    }

    /// Bright when selection is attached; keeps the slot visible when armed clears.
    func setAskSelectionArmed(_ armed: Bool) {
        askHasSelection = armed && askSlotVisible
        updateAskSelectionAppearance()
        updateStreamingState()
    }

    /// Compatibility: arms/disarms Ask without hiding the slot when study docs keep it reserved.
    func setAskSelectionChipVisible(_ visible: Bool) {
        setAskSelectionArmed(visible)
    }

    /// Append one image to the composer. Returns false when the 9-image cap is full.
    @discardableResult
    func addAttachment(image: UIImage, base64: String) -> Bool {
        guard !base64.isEmpty else { return false }
        guard pendingImages.count < Self.maxImageAttachments else {
            showAttachmentCapToast()
            return false
        }
        // Never retain the picker/camera original — only this bounded chip bitmap.
        let chipImage = ImageAttachmentHelper.composerThumbnail(from: image)
        pendingImages.append((image: chipImage, base64: base64))
        rebuildAttachmentStrip(animated: true)
        return true
    }

    func clearAttachment() {
        guard !pendingImages.isEmpty else { return }
        pendingImages.removeAll()
        rebuildAttachmentStrip(animated: true)
    }

    private func showAttachmentCapToast() {
        let text = L("最多添加 9 张图片", "Up to 9 images")
        if let window = window {
            ConnectsToast.show(text, in: window, duration: 1.2)
        } else {
            ConnectsToast.show(text, in: self, duration: 1.2)
        }
    }

    private func rebuildAttachmentStrip(animated: Bool) {
        attachmentStackView.arrangedSubviews.forEach {
            attachmentStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        attachmentRemoveButtons.removeAll()

        let c = DSTheme.c
        for (index, item) in pendingImages.enumerated() {
            let tile = UIView()
            tile.translatesAutoresizingMaskIntoConstraints = false

            let imageView = UIImageView(image: item.image)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 10
            tile.addSubview(imageView)

            let remove = UIButton(type: .system)
            remove.translatesAutoresizingMaskIntoConstraints = false
            remove.setTitle("×", for: .normal)
            remove.setTitleColor(c.textSecondary, for: .normal)
            remove.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .bold)
            remove.backgroundColor = c.surface.withAlphaComponent(0.92)
            remove.layer.cornerRadius = 9
            remove.clipsToBounds = true
            remove.tag = index
            remove.accessibilityLabel = L("移除图片", "Remove image")
            remove.isEnabled = !isStreaming
            remove.addTarget(self, action: #selector(removeAttachmentAtIndex(_:)), for: .touchUpInside)
            tile.addSubview(remove)
            attachmentRemoveButtons.append(remove)

            attachmentStackView.addArrangedSubview(tile)
            NSLayoutConstraint.activate([
                tile.widthAnchor.constraint(equalToConstant: 56),
                tile.heightAnchor.constraint(equalToConstant: 56),
                imageView.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: tile.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
                remove.topAnchor.constraint(equalTo: tile.topAnchor, constant: 2),
                remove.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -2),
                remove.widthAnchor.constraint(equalToConstant: 18),
                remove.heightAnchor.constraint(equalToConstant: 18)
            ])
        }

        let hasImages = !pendingImages.isEmpty
        chip.isHidden = !hasImages
        chipHeightConstraint?.constant = hasImages ? 64 : 0
        textTopToChip?.isActive = hasImages
        textTopToContainer?.isActive = !hasImages
        updateSendEnabled()
        let applyLayout = { self.layoutIfNeeded() }
        if animated {
            UIView.animate(withDuration: 0.15, animations: applyLayout)
        } else {
            applyLayout()
        }
    }

    private func setup() {
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = DSTheme.cornerRadius
        containerView.layer.borderWidth = 1 / UIScreen.main.scale
        containerView.clipsToBounds = true
        addSubview(containerView)

        // Keep strip lives inside the capsule so width/corners match the composer.
        diffReviewBanner.translatesAutoresizingMaskIntoConstraints = false
        diffReviewBanner.isHidden = true
        diffReviewBanner.clipsToBounds = true
        containerView.addSubview(diffReviewBanner)

        diffExpandButton.translatesAutoresizingMaskIntoConstraints = false
        diffExpandButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        diffExpandButton.contentHorizontalAlignment = .left
        diffExpandButton.isHidden = true
        diffExpandButton.addTarget(self, action: #selector(diffExpandTapped), for: .touchUpInside)
        diffReviewBanner.addSubview(diffExpandButton)

        diffChangesLabel.translatesAutoresizingMaskIntoConstraints = false
        diffChangesLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        diffChangesLabel.text = "0 处改动"
        diffReviewBanner.addSubview(diffChangesLabel)

        for btn in [diffUndoAllButton, diffKeepAllButton, diffReviewButton] {
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            diffReviewBanner.addSubview(btn)
        }
        diffUndoAllButton.setTitle("全部撤销", for: .normal)
        diffKeepAllButton.setTitle("全部保留", for: .normal)
        diffReviewButton.setTitle("审阅", for: .normal)
        diffReviewButton.isHidden = true
        diffUndoAllButton.addTarget(self, action: #selector(diffUndoAllTapped), for: .touchUpInside)
        diffKeepAllButton.addTarget(self, action: #selector(diffKeepAllTapped), for: .touchUpInside)
        diffReviewButton.addTarget(self, action: #selector(diffReviewTapped), for: .touchUpInside)

        diffFileListStack.translatesAutoresizingMaskIntoConstraints = false
        diffFileListStack.axis = .vertical
        diffFileListStack.spacing = 0
        diffReviewBanner.addSubview(diffFileListStack)

        buildTodoStrip.translatesAutoresizingMaskIntoConstraints = false
        buildTodoStrip.isHidden = true
        buildTodoStrip.clipsToBounds = true
        containerView.addSubview(buildTodoStrip)

        buildTodoLabel.translatesAutoresizingMaskIntoConstraints = false
        buildTodoLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        buildTodoLabel.textColor = DSTheme.c.textSecondary
        buildTodoStrip.addSubview(buildTodoLabel)

        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.clipsToBounds = true
        chip.isHidden = true
        containerView.addSubview(chip)

        attachmentScrollView.translatesAutoresizingMaskIntoConstraints = false
        attachmentScrollView.showsHorizontalScrollIndicator = false
        attachmentScrollView.showsVerticalScrollIndicator = false
        attachmentScrollView.alwaysBounceHorizontal = true
        chip.addSubview(attachmentScrollView)

        attachmentStackView.translatesAutoresizingMaskIntoConstraints = false
        attachmentStackView.axis = .horizontal
        attachmentStackView.alignment = .center
        attachmentStackView.spacing = 8
        attachmentScrollView.addSubview(attachmentStackView)

        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.setImage(ActionIconFactory.image(.plus, pointSize: ActionIconFactory.toolGlyph), for: .normal)
        attachButton.accessibilityLabel = "添加图片"
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)
        containerView.addSubview(attachButton)

        thinkingButton.translatesAutoresizingMaskIntoConstraints = false
        thinkingButton.setImage(ActionIconFactory.image(.think, pointSize: ActionIconFactory.toolGlyph), for: .normal)
        thinkingButton.accessibilityLabel = "深度思考"
        thinkingButton.accessibilityHint = "长按可选择 Kimi K3 思考程度"
        thinkingButton.addTarget(self, action: #selector(thinkingTapped), for: .touchUpInside)
        containerView.addSubview(thinkingButton)
        let thinkingLong = UILongPressGestureRecognizer(target: self, action: #selector(thinkingLongPressed(_:)))
        thinkingButton.addGestureRecognizer(thinkingLong)

        codeAIEditButton.translatesAutoresizingMaskIntoConstraints = false
        codeAIEditButton.setImage(ActionIconFactory.image(.aiEdit, pointSize: ActionIconFactory.toolGlyph), for: .normal)
        codeAIEditButton.accessibilityLabel = "AI 编辑"
        codeAIEditButton.accessibilityHint = "开启后允许模型提出改文件提案，并同时打开文档上下文；关闭则仅问答（不影响文档开关）。默认关闭。"
        codeAIEditButton.addTarget(self, action: #selector(codeAIEditTapped), for: .touchUpInside)
        codeAIEditButton.isHidden = true
        containerView.addSubview(codeAIEditButton)

        agentModeButton.translatesAutoresizingMaskIntoConstraints = false
        agentModeButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        agentModeButton.titleLabel?.adjustsFontSizeToFitWidth = true
        agentModeButton.titleLabel?.minimumScaleFactor = 0.8
        agentModeButton.setTitle("Agent", for: .normal)
        agentModeButton.accessibilityLabel = "Agent 模式"
        agentModeButton.addTarget(self, action: #selector(agentModeTapped), for: .touchUpInside)
        agentModeButton.isHidden = true
        containerView.addSubview(agentModeButton)

        studyCaptureButton.translatesAutoresizingMaskIntoConstraints = false
        studyCaptureButton.setImage(ActionIconFactory.image(.docContext, pointSize: ActionIconFactory.toolGlyph), for: .normal)
        studyCaptureButton.accessibilityLabel = "附带文档上下文"
        studyCaptureButton.accessibilityHint = "开启后发送时附带文档上下文；长按可选择全文/选区/重新同步"
        studyCaptureButton.addTarget(self, action: #selector(studyCaptureTapped), for: .touchUpInside)
        let studyLong = UILongPressGestureRecognizer(target: self, action: #selector(studyCaptureLongPressed(_:)))
        studyLong.minimumPressDuration = 0.4
        studyCaptureButton.addGestureRecognizer(studyLong)
        studyCaptureButton.isHidden = true
        containerView.addSubview(studyCaptureButton)

        askSelectionButton.translatesAutoresizingMaskIntoConstraints = false
        askSelectionButton.setImage(ActionIconFactory.image(.ask, pointSize: ActionIconFactory.toolGlyph), for: .normal)
        askSelectionButton.accessibilityLabel = "Ask 选区"
        askSelectionButton.accessibilityHint = "选中文本并 Ask 后点亮；点按可取消附带选区"
        askSelectionButton.addTarget(self, action: #selector(askSelectionTapped), for: .touchUpInside)
        askSelectionButton.isHidden = true
        containerView.addSubview(askSelectionButton)

        for tool in [attachButton, studyCaptureButton, thinkingButton, codeAIEditButton, askSelectionButton] {
            styleIconToolButton(tool)
        }

        contextUsageButton.translatesAutoresizingMaskIntoConstraints = false
        contextUsageButton.accessibilityLabel = "上下文占用"
        contextUsageButton.accessibilityHint = "查看上下文组成与占用比例"
        contextUsageButton.addTarget(self, action: #selector(contextUsageTapped), for: .touchUpInside)
        contextUsageButton.isHidden = true
        containerView.addSubview(contextUsageButton)

        contextRing.translatesAutoresizingMaskIntoConstraints = false
        contextUsageButton.addSubview(contextRing)

        aiOptionsButton.translatesAutoresizingMaskIntoConstraints = false
        aiOptionsButton.titleLabel?.lineBreakMode = .byTruncatingTail
        aiOptionsButton.titleLabel?.adjustsFontSizeToFitWidth = true
        aiOptionsButton.titleLabel?.minimumScaleFactor = 0.85
        aiOptionsButton.accessibilityLabel = "选择模型"
        aiOptionsButton.accessibilityHint = "Kimi、Qwen 等"
        aiOptionsButton.layer.cornerRadius = btnSize / 2
        aiOptionsButton.layer.borderWidth = 1 / UIScreen.main.scale
        aiOptionsButton.clipsToBounds = true
        aiOptionsButton.addTarget(self, action: #selector(aiOptionsTapped), for: .touchUpInside)
        aiOptionsButton.addTarget(self, action: #selector(modelChipTouchDown), for: .touchDown)
        aiOptionsButton.addTarget(
            self,
            action: #selector(modelChipTouchUp),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        containerView.addSubview(aiOptionsButton)
        refreshModelChipAppearance()

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.font = DSTheme.bodyFont(size: 17)
        textView.isScrollEnabled = false
        textView.delegate = self
        // Keep vertical insets balanced so the first line optically matches + / 🌐 / send.
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        containerView.addSubview(textView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.text = L("问任何问题…", "Ask anything…")
        placeholderLabel.font = DSTheme.bodyFont(size: 17)
        containerView.addSubview(placeholderLabel)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setImage(ActionIconFactory.image(.send, pointSize: ActionIconFactory.sendGlyph, color: .white), for: .normal)
        sendButton.tintColor = .white
        sendButton.imageView?.contentMode = .scaleAspectFit
        sendButton.layer.cornerRadius = btnSize / 2
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        containerView.addSubview(sendButton)

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.setImage(ActionIconFactory.image(.stop, pointSize: ActionIconFactory.sendGlyph, color: .white), for: .normal)
        stopButton.tintColor = .white
        stopButton.imageView?.contentMode = .scaleAspectFit
        stopButton.layer.cornerRadius = btnSize / 2
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        stopButton.isHidden = true
        containerView.addSubview(stopButton)

        containerView.bringSubviewToFront(aiOptionsButton)

        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 40)
        chipHeightConstraint = chip.heightAnchor.constraint(equalToConstant: 0)
        textTopToChip = textView.topAnchor.constraint(equalTo: chip.bottomAnchor, constant: 4)
        textTopToContainer = textView.topAnchor.constraint(equalTo: attachButton.bottomAnchor, constant: 5)
        studyCaptureWidthConstraint = studyCaptureButton.widthAnchor.constraint(equalToConstant: 0)
        codeAIEditWidthConstraint = codeAIEditButton.widthAnchor.constraint(equalToConstant: 0)
        agentModeWidthConstraint = agentModeButton.widthAnchor.constraint(equalToConstant: 0)
        askSelectionWidthConstraint = askSelectionButton.widthAnchor.constraint(equalToConstant: 0)
        aiOptionsWidthConstraint = aiOptionsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 68)
        // iPhone portrait: keep the model chip short so tools don't collide.
        let modelChipMax: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 124 : 160
        let aiOptionsMaxW = aiOptionsButton.widthAnchor.constraint(lessThanOrEqualToConstant: modelChipMax)
        contextUsageWidthConstraint = contextUsageButton.widthAnchor.constraint(equalToConstant: 0)
        textTopToContainer?.isActive = true
        diffBannerHeightConstraint = diffReviewBanner.heightAnchor.constraint(equalToConstant: 0)
        buildTodoHeightConstraint = buildTodoStrip.heightAnchor.constraint(equalToConstant: 0)
        toolsTopToBanner = attachButton.topAnchor.constraint(equalTo: diffReviewBanner.bottomAnchor, constant: 4)
        toolsTopToBuildTodo = attachButton.topAnchor.constraint(equalTo: buildTodoStrip.bottomAnchor, constant: 4)
        toolsTopToContainer = attachButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4)
        toolsTopToContainer?.isActive = true

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            diffReviewBanner.topAnchor.constraint(equalTo: containerView.topAnchor),
            diffReviewBanner.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            diffReviewBanner.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            diffBannerHeightConstraint!,

            buildTodoStrip.topAnchor.constraint(equalTo: diffReviewBanner.bottomAnchor),
            buildTodoStrip.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            buildTodoStrip.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            buildTodoHeightConstraint!,

            buildTodoLabel.leadingAnchor.constraint(equalTo: buildTodoStrip.leadingAnchor, constant: 12),
            buildTodoLabel.trailingAnchor.constraint(lessThanOrEqualTo: buildTodoStrip.trailingAnchor, constant: -12),
            buildTodoLabel.centerYAnchor.constraint(equalTo: buildTodoStrip.centerYAnchor),

            diffExpandButton.leadingAnchor.constraint(equalTo: diffReviewBanner.leadingAnchor, constant: 10),
            diffExpandButton.topAnchor.constraint(equalTo: diffReviewBanner.topAnchor, constant: 4),
            diffExpandButton.heightAnchor.constraint(equalToConstant: 22),

            diffChangesLabel.leadingAnchor.constraint(equalTo: diffReviewBanner.leadingAnchor, constant: 12),
            diffChangesLabel.topAnchor.constraint(equalTo: diffReviewBanner.topAnchor, constant: 6),

            diffReviewButton.trailingAnchor.constraint(equalTo: diffReviewBanner.trailingAnchor, constant: -12),
            diffReviewButton.topAnchor.constraint(equalTo: diffReviewBanner.topAnchor, constant: 4),
            diffKeepAllButton.trailingAnchor.constraint(equalTo: diffReviewButton.leadingAnchor, constant: -10),
            diffKeepAllButton.topAnchor.constraint(equalTo: diffReviewBanner.topAnchor, constant: 4),
            diffUndoAllButton.trailingAnchor.constraint(equalTo: diffKeepAllButton.leadingAnchor, constant: -10),
            diffUndoAllButton.topAnchor.constraint(equalTo: diffReviewBanner.topAnchor, constant: 4),
            diffUndoAllButton.leadingAnchor.constraint(greaterThanOrEqualTo: diffChangesLabel.trailingAnchor, constant: 8),

            diffFileListStack.topAnchor.constraint(equalTo: diffReviewBanner.topAnchor, constant: 30),
            diffFileListStack.leadingAnchor.constraint(equalTo: diffReviewBanner.leadingAnchor, constant: 8),
            diffFileListStack.trailingAnchor.constraint(equalTo: diffReviewBanner.trailingAnchor, constant: -8),

            chip.topAnchor.constraint(equalTo: attachButton.bottomAnchor, constant: 6),
            chip.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            chip.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            chipHeightConstraint!,

            attachmentScrollView.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
            attachmentScrollView.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            attachmentScrollView.topAnchor.constraint(equalTo: chip.topAnchor, constant: 4),
            attachmentScrollView.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -4),

            attachmentStackView.leadingAnchor.constraint(equalTo: attachmentScrollView.contentLayoutGuide.leadingAnchor),
            attachmentStackView.trailingAnchor.constraint(equalTo: attachmentScrollView.contentLayoutGuide.trailingAnchor),
            attachmentStackView.topAnchor.constraint(equalTo: attachmentScrollView.contentLayoutGuide.topAnchor),
            attachmentStackView.bottomAnchor.constraint(equalTo: attachmentScrollView.contentLayoutGuide.bottomAnchor),
            attachmentStackView.heightAnchor.constraint(equalTo: attachmentScrollView.frameLayoutGuide.heightAnchor),

            // Composer tools live in a compact row above the editor, leaving the
            // input line its full width while keeping send in its usual place.
            attachButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            attachButton.widthAnchor.constraint(equalToConstant: btnSize),
            attachButton.heightAnchor.constraint(equalToConstant: btnSize),

            studyCaptureButton.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 2),
            studyCaptureButton.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor),
            studyCaptureWidthConstraint!,
            studyCaptureButton.heightAnchor.constraint(equalToConstant: btnSize),

            thinkingButton.leadingAnchor.constraint(equalTo: studyCaptureButton.trailingAnchor, constant: 2),
            thinkingButton.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor),
            thinkingButton.widthAnchor.constraint(equalToConstant: btnSize),
            thinkingButton.heightAnchor.constraint(equalToConstant: btnSize),

            // AI 编辑 sits right of 思考; grants optional file-edit permission.
            codeAIEditButton.leadingAnchor.constraint(equalTo: thinkingButton.trailingAnchor, constant: 2),
            codeAIEditButton.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor),
            codeAIEditWidthConstraint!,
            codeAIEditButton.heightAnchor.constraint(equalToConstant: btnSize),

            // Selection Ask (icon) then Agent/Plan/Ask mode chip.
            askSelectionButton.leadingAnchor.constraint(equalTo: codeAIEditButton.trailingAnchor, constant: 2),
            askSelectionButton.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor),
            askSelectionWidthConstraint!,
            askSelectionButton.heightAnchor.constraint(equalToConstant: btnSize),

            agentModeButton.leadingAnchor.constraint(equalTo: askSelectionButton.trailingAnchor, constant: 2),
            agentModeButton.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor),
            agentModeWidthConstraint!,
            agentModeButton.heightAnchor.constraint(equalToConstant: btnSize),
            agentModeButton.trailingAnchor.constraint(lessThanOrEqualTo: aiOptionsButton.leadingAnchor, constant: -4),

            // Model picker (Kimi / Qwen …) immediately left of the context ring.
            aiOptionsButton.trailingAnchor.constraint(equalTo: contextUsageButton.leadingAnchor, constant: -4),
            aiOptionsButton.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor),
            aiOptionsWidthConstraint!,
            aiOptionsMaxW,
            aiOptionsButton.heightAnchor.constraint(equalToConstant: btnSize),

            contextUsageButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            contextUsageButton.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor),
            contextUsageWidthConstraint!,
            contextUsageButton.heightAnchor.constraint(equalToConstant: btnSize),

            contextRing.centerXAnchor.constraint(equalTo: contextUsageButton.centerXAnchor),
            contextRing.centerYAnchor.constraint(equalTo: contextUsageButton.centerYAnchor),
            contextRing.widthAnchor.constraint(equalToConstant: 26),
            contextRing.heightAnchor.constraint(equalToConstant: 26),

            sendButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            sendButton.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: btnSize),
            sendButton.heightAnchor.constraint(equalToConstant: btnSize),

            stopButton.trailingAnchor.constraint(equalTo: sendButton.trailingAnchor),
            stopButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: btnSize),
            stopButton.heightAnchor.constraint(equalToConstant: btnSize),

            textView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            textView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -7),
            textViewHeightConstraint!,

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: textView.centerYAnchor)
        ])
    }

    // Multi-image strip constraints are installed in setup(); no separate width helper.
    private func updateStreamingState() {
        sendButton.isHidden = isStreaming
        stopButton.isHidden = !isStreaming
        textView.isEditable = !isStreaming
        attachButton.isEnabled = !isStreaming && attachEnabled
        attachButton.alpha = attachButton.isEnabled ? 1 : 0.35
        thinkingButton.isEnabled = !isStreaming
        thinkingButton.alpha = isStreaming ? 0.35 : 1
        codeAIEditButton.isEnabled = !isStreaming && codeAIEditVisible
        codeAIEditButton.alpha = (!codeAIEditVisible || isStreaming) ? 0.35 : 1
        agentModeButton.isEnabled = !isStreaming && studyAgentModeVisible
        agentModeButton.alpha = (!studyAgentModeVisible || isStreaming) ? 0.35 : 1
        studyCaptureButton.isEnabled = !isStreaming && studyCaptureVisible
        studyCaptureButton.alpha = studyCaptureButton.isEnabled ? 1 : 0.35
        // Gray placeholder stays visible; only armed Ask clears on tap.
        askSelectionButton.isEnabled = !isStreaming && askSlotVisible && askHasSelection
        if askSlotVisible {
            askSelectionButton.alpha = isStreaming ? 0.35 : (askHasSelection ? 1 : 0.42)
        }
        contextUsageButton.isEnabled = !isStreaming && contextUsageVisible
        if contextUsageVisible {
            contextUsageButton.alpha = isStreaming ? 0.35 : 1
        }
        aiOptionsButton.isEnabled = !isStreaming
        aiOptionsButton.alpha = isStreaming ? 0.35 : 1
        containerView.bringSubviewToFront(aiOptionsButton)
        attachmentRemoveButtons.forEach { $0.isEnabled = !isStreaming }
        updateSendEnabled()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if aiOptionsButton.isUserInteractionEnabled, !aiOptionsButton.isHidden {
            let p = convert(point, to: aiOptionsButton)
            if aiOptionsButton.point(inside: p, with: event) {
                return aiOptionsButton
            }
        }
        return super.hitTest(point, with: event)
    }

    private func styleIconToolButton(_ button: UIButton) {
        button.clipsToBounds = true
        button.layer.cornerRadius = btnSize / 2
        button.imageView?.contentMode = .scaleAspectFit
    }

    private func refreshModelChipAppearance() {
        let c = DSTheme.c
        let image = ActionIconFactory.image(.ai, pointSize: ActionIconFactory.chipGlyph, color: c.accent)
        let name = NSAttributedString(
            string: modelChipDisplayName,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: c.textPrimary
            ]
        )
        let chevron = NSAttributedString(
            string: " ▾",
            attributes: [
                .font: UIFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: c.textSecondary
            ]
        )
        let combined = NSMutableAttributedString(attributedString: name)
        combined.append(chevron)

        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 7, bottom: 0, trailing: 9)
        config.imagePadding = 4
        config.image = image
        config.attributedTitle = AttributedString(combined)
        config.titleLineBreakMode = .byTruncatingTail
        config.baseForegroundColor = c.textPrimary
        aiOptionsButton.configuration = config
        aiOptionsButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let baseFill = c.accent.withAlphaComponent(0.08)
        aiOptionsButton.backgroundColor = modelChipPressed
            ? c.accent.withAlphaComponent(0.16)
            : baseFill
        aiOptionsButton.layer.borderColor = c.accent.withAlphaComponent(0.22).cgColor
        aiOptionsButton.tintColor = c.accent
    }

    private func updateToggleAppearance(_ button: UIButton, on: Bool) {
        let c = DSTheme.c
        button.tintColor = on ? c.accent : c.textSecondary
        button.backgroundColor = on ? c.accent.withAlphaComponent(0.14) : .clear
        button.layer.cornerRadius = btnSize / 2
        button.accessibilityValue = on ? "开" : "关"
    }

    private func updateThinkingAppearance() {
        updateToggleAppearance(thinkingButton, on: thinkingEnabled)
    }

    private func updateCodeAIEditAppearance() {
        updateToggleAppearance(codeAIEditButton, on: codeAIEditEnabled)
    }

    /// Shows current model on the input-bar capsule (Kimi / Qwen / …).
    func setModelChip(title: String) {
        modelChipDisplayName = title
        aiOptionsButton.accessibilityValue = title
        refreshModelChipAppearance()
    }

    private func updateAIOptionsAppearance() {
        refreshModelChipAppearance()
    }

    private func updateStudyCaptureAppearance() {
        updateToggleAppearance(studyCaptureButton, on: studyPageCaptureEnabled)
    }

    private func updateAskSelectionAppearance() {
        let c = DSTheme.c
        let on = askHasSelection
        askSelectionButton.tintColor = on ? c.accent : c.textSecondary
        askSelectionButton.backgroundColor = on ? c.accent.withAlphaComponent(0.16) : .clear
        askSelectionButton.layer.cornerRadius = btnSize / 2
        askSelectionButton.clipsToBounds = true
        askSelectionButton.accessibilityValue = on ? "已附带选区" : "未选择"
    }

    private func updateSendEnabled() {
        let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContent = (hasText || !pendingImages.isEmpty) && !isStreaming
        let on = hasContent && !blocksUnsupportedImageSend
        // Stay tappable when blocked so the tap can explain why send is gray.
        sendButton.isEnabled = hasContent
        sendButton.alpha = on ? 1 : 0.45
        let c = DSTheme.c
        sendButton.backgroundColor = on ? c.sendEnabled : c.sendDisabled
        sendButton.tintColor = .white
        // Highlight attach when an image is staged.
        if !pendingImages.isEmpty {
            attachButton.tintColor = c.accent
            attachButton.backgroundColor = c.accent.withAlphaComponent(0.14)
        } else {
            attachButton.tintColor = c.textSecondary
            attachButton.backgroundColor = .clear
        }
    }

    @objc private func modelChipTouchDown() {
        modelChipPressed = true
        refreshModelChipAppearance()
    }

    @objc private func modelChipTouchUp() {
        modelChipPressed = false
        refreshModelChipAppearance()
    }

    private func updateTextViewHeight() {
        let width = textView.bounds.width > 0 ? textView.bounds.width : 400
        let size = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let maxH = textMaxHeight
        let height = min(max(36, size.height), maxH)
        textViewHeightConstraint?.constant = height
        textView.isScrollEnabled = size.height > maxH - 0.5
    }

    @objc private func sendTapped() {
        if blocksUnsupportedImageSend {
            delegate?.inputBarDidRejectUnsupportedImage()
            return
        }
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty else { return }
        delegate?.inputBarDidTapSend(text: text, imagesBase64: pendingImageBase64List)
    }

    @objc private func stopTapped() {
        delegate?.inputBarDidTapStop()
    }

    @objc private func attachTapped() {
        delegate?.inputBarDidTapAttach()
    }

    @objc private func thinkingTapped() {
        thinkingEnabled.toggle()
    }

    /// Re-apply placeholder copy after an app-language switch.
    func refreshLocalizedStrings() {
        placeholderLabel.text = codeAIEditEnabled
            ? L("提问；需要改代码时模型可提案…", "Ask — models can propose code edits…")
            : L("问任何问题…", "Ask anything…")
    }

    @objc private func codeAIEditTapped() {
        guard codeAIEditVisible else { return }
        setCodeAIEditEnabled(!codeAIEditEnabled, notify: true)
        if codeAIEditEnabled {
            placeholderLabel.text = L("提问；需要改代码时模型可提案…", "Ask — models can propose code edits…")
        } else {
            placeholderLabel.text = L("问任何问题…", "Ask anything…")
        }
    }

    @objc private func diffUndoAllTapped() {
        delegate?.inputBarDidTapDiffUndoAll()
    }

    @objc private func diffKeepAllTapped() {
        delegate?.inputBarDidTapDiffKeepAll()
    }

    @objc private func diffReviewTapped() {
        delegate?.inputBarDidTapDiffReview()
    }

    @objc private func diffExpandTapped() {
        guard diffBannerMultifile else { return }
        diffBannerExpanded.toggle()
        rebuildDiffBannerChrome()
        invalidateIntrinsicContentSize()
        UIView.animate(withDuration: 0.18) { self.layoutIfNeeded() }
    }

    @objc private func diffFileRowTapped(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier, !id.isEmpty else { return }
        delegate?.inputBarDidSelectDiffFile(documentID: id)
    }

    func setStudyAgentMode(_ mode: StudyAgentMode, notify: Bool = false) {
        studyAgentMode = StudyAgentMode.coerceForProduct(mode)
        updateAgentModeAppearance()
        if notify {
            delegate?.inputBarDidChangeStudyAgentMode(studyAgentMode)
        }
    }

    @objc private func agentModeTapped() {
        guard studyAgentModeVisible else { return }
        let modes = StudyAgentMode.selectableModes
        guard !modes.isEmpty else { return }
        let idx = modes.firstIndex(of: studyAgentMode) ?? 0
        let next = modes[(idx + 1) % modes.count]
        setStudyAgentMode(next, notify: true)
    }

    private func updateAgentModeAppearance() {
        let title: String
        switch studyAgentMode {
        case .agent: title = "Agent"
        case .plan: title = "Plan"
        case .ask: title = "Ask"
        }
        let c = DSTheme.c
        let on = studyAgentModeVisible && !StudyAgentMode.selectableModes.isEmpty
        let fg = on ? c.accent : c.textSecondary
        // Attributed title: UIButton.system often drops plain setTitleColor on title swaps
        // (sim QA: Plan/Ask chip looked empty while title(for:) was correct).
        agentModeButton.configuration = nil
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: fg
        ]
        let attributed = NSAttributedString(string: title, attributes: attrs)
        agentModeButton.setAttributedTitle(attributed, for: .normal)
        agentModeButton.setAttributedTitle(attributed, for: .highlighted)
        agentModeButton.setAttributedTitle(attributed, for: .disabled)
        agentModeButton.tintColor = fg
        agentModeButton.backgroundColor = on ? c.accent.withAlphaComponent(0.14) : .clear
        agentModeButton.layer.cornerRadius = btnSize / 2
        agentModeButton.clipsToBounds = true
        agentModeButton.alpha = on ? 1 : 0.35
        agentModeButton.isAccessibilityElement = true
        switch studyAgentMode {
        case .agent:
            agentModeButton.accessibilityLabel = "Agent 模式 · Agent"
        case .plan:
            agentModeButton.accessibilityLabel = "Agent 模式 · Plan"
        case .ask:
            agentModeButton.accessibilityLabel = "Agent 模式 · Ask"
        }
    }

    private func applyDiffBannerTheme() {
        let c = DSTheme.c
        diffReviewBanner.backgroundColor = c.surfaceHover.withAlphaComponent(0.55)
        diffChangesLabel.textColor = c.textSecondary
        diffExpandButton.setTitleColor(c.textPrimary, for: .normal)
        diffUndoAllButton.setTitleColor(c.textPrimary, for: .normal)
        diffKeepAllButton.setTitleColor(c.accent, for: .normal)
        diffReviewButton.setTitleColor(c.accent, for: .normal)
        for view in diffFileListStack.arrangedSubviews {
            (view as? UIButton)?.setTitleColor(c.textSecondary, for: .normal)
        }
    }

    @objc private func thinkingLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        delegate?.inputBarDidRequestReasoningEffort(from: thinkingButton)
    }

    @objc private func aiOptionsTapped() {
        let keepKeyboard = textView.isFirstResponder
        delegate?.inputBarDidTapAIOptions()
        // Tapping a chip outside UITextView normally resigns the keyboard — put it back.
        if keepKeyboard, !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
    }

    @objc private func studyCaptureTapped() {
        studyPageCaptureEnabled.toggle()
        delegate?.inputBarDidToggleStudyCapture(studyPageCaptureEnabled)
    }

    @objc private func studyCaptureLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        delegate?.inputBarDidRequestStudyContextScope(from: studyCaptureButton)
    }

    @objc private func askSelectionTapped() {
        guard askHasSelection else { return }
        setAskSelectionArmed(false)
        onClearAskSelection?()
    }

    @objc private func contextUsageTapped() {
        delegate?.inputBarDidTapContextUsage()
    }

    @objc private func removeAttachmentAtIndex(_ sender: UIButton) {
        let index = sender.tag
        guard pendingImages.indices.contains(index) else { return }
        pendingImages.remove(at: index)
        rebuildAttachmentStrip(animated: true)
    }
    func syncToolTogglesFromSettings() {
        updateThinkingAppearance()
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
