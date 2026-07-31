import Foundation

struct StudyPageCapture {
    let label: String
    let text: String
    let imageJPEGBase64: String?
    /// When true, Chat should skip OCR/vision even if an image is present.
    let prefersTextOnly: Bool
    /// Keep JPEG for API /「图片转写」, but do not show the thumbnail in chat bubbles.
    let hidesImageInChatBubble: Bool
    /// Preformatted API prefix; if nil, `apiContextPrefix()` builds from text/label.
    let customAPIPrefix: String?

    private static let shortTextThreshold = 80

    init(label: String,
         text: String,
         imageJPEGBase64: String? = nil,
         prefersTextOnly: Bool = false,
         hidesImageInChatBubble: Bool = false,
         customAPIPrefix: String? = nil) {
        self.label = label
        self.text = text
        self.imageJPEGBase64 = imageJPEGBase64
        self.prefersTextOnly = prefersTextOnly
        self.hidesImageInChatBubble = hidesImageInChatBubble
        self.customAPIPrefix = customAPIPrefix
    }

    /// Enough extractable text that OCR / vision transcription would only duplicate
    /// reading context into the chat UI (same as a normal text turn + context).
    var hasRichExtractableText: Bool {
        if prefersTextOnly { return true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.shortTextThreshold
    }

    /// Thin / empty page text still needs the standalone image-transcription path.
    /// PDF study screenshots always use「图片转写」(never the chat bubble thumbnail).
    var needsImageTranscription: Bool {
        guard imageJPEGBase64 != nil else { return false }
        if hidesImageInChatBubble { return true }
        if prefersTextOnly { return false }
        return !hasRichExtractableText
    }

    func apiContextPrefix() -> String {
        if let custom = customAPIPrefix?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if imageJPEGBase64 != nil {
                return """
                [阅读上下文 · \(label)]
                （本页为图片或乐谱，请结合附带截图理解；发送后将先 OCR、再异步转写页面内容。）
                """
            }
            return "[阅读上下文 · \(label)]\n（无可用文本）"
        }
        let body = String(trimmed.prefix(prefersTextOnly ? 48_000 : 4_000))
        if prefersTextOnly || imageJPEGBase64 == nil {
            return """
            [阅读上下文 · \(label)]
            \(body)
            """
        }
        if trimmed.count < Self.shortTextThreshold {
            return """
            [阅读上下文 · \(label)]
            \(body)

            （可提取文字较少，请以附带页面截图为准。）
            """
        }
        return """
        [阅读上下文 · \(label)]
        \(body)

        （已附带当前页截图，请图文结合理解。）
        """
    }
}

/// Study AI panel size relative to the document reader.
enum StudyChatPanelStage: Int {
    case collapsed = 0  // full reading
    case half = 1       // half reading / half AI
    case full = 2       // full AI
}

protocol StudyReadingContextProviding: AnyObject {
    func captureCurrentStudyPage() -> StudyPageCapture?
    /// When true, ChatVC should not apply full-screen keyboard lift; the shell resizes the portrait panel.
    var managesPortraitKeyboardLayout: Bool { get }
    func applyStudyChatPanelStage(_ stage: StudyChatPanelStage, animated: Bool)
    var studyChatPanelStage: StudyChatPanelStage { get }
    /// Portrait study: stage control lives in the chat nav title. Landscape: floating side capsule.
    var studyIsPortraitLayout: Bool { get }
    /// Clear Ask range highlight in the active reader (code / markdown).
    func clearAskSelectionHighlightInReader()
    /// Study text/code: whether「AI 编辑」authorization is meaningful.
    var studyCodeAIEditSupported: Bool { get }
    /// Present a parsed CONNECTS_EDIT proposal in the code reader Diff surface.
    func presentStudyCodeEditProposal(_ proposal: CodeEditProposal) -> Bool
    func studyCodeDiffUndoAll()
    func studyCodeDiffKeepAll()
}

extension StudyReadingContextProviding {
    var managesPortraitKeyboardLayout: Bool { false }
    func applyStudyChatPanelStage(_ stage: StudyChatPanelStage, animated: Bool) {}
    var studyChatPanelStage: StudyChatPanelStage { .collapsed }
    var studyIsPortraitLayout: Bool { true }
    func clearAskSelectionHighlightInReader() {}
    var studyCodeAIEditSupported: Bool { false }
    func presentStudyCodeEditProposal(_ proposal: CodeEditProposal) -> Bool { false }
    func studyCodeDiffUndoAll() {}
    func studyCodeDiffKeepAll() {}
}

/// Nav `titleView` host that pins itself to the bar’s horizontal center
/// (screen mid-line when the bar spans the window), so asymmetric left/right
/// bar buttons don’t nudge ▲▼ off the vertical mid-line.
final class StudyPanelNavTitleHost: UIView {
    let capsule: StudyPanelStageCapsule
    private let hostSize = CGSize(width: 156, height: 44)
    private let capsuleSize = CGSize(width: 148, height: 36)

    init(capsule: StudyPanelStageCapsule) {
        self.capsule = capsule
        super.init(frame: CGRect(origin: .zero, size: hostSize))
        isUserInteractionEnabled = true
        clipsToBounds = false
        capsule.translatesAutoresizingMaskIntoConstraints = true
        capsule.frame = CGRect(
            x: (hostSize.width - capsuleSize.width) / 2,
            y: (hostSize.height - capsuleSize.height) / 2,
            width: capsuleSize.width,
            height: capsuleSize.height
        )
        addSubview(capsule)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { hostSize }

    override func sizeThatFits(_ size: CGSize) -> CGSize { hostSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let bar = enclosingNavigationBar(), let container = superview else { return }
        let desiredX = bar.convert(CGPoint(x: bar.bounds.midX, y: 0), to: container).x
        if abs(center.x - desiredX) > 0.5 {
            center = CGPoint(x: desiredX, y: center.y)
        }
    }

    private func enclosingNavigationBar() -> UINavigationBar? {
        var node: UIView? = superview
        while let cur = node {
            if let bar = cur as? UINavigationBar { return bar }
            node = cur.superview
        }
        return nil
    }
}

/// ▲ expands AI / ▼ collapses reading — same left▲ right▼ chip.
/// Portrait: floating over chat nav mid / bottom edge. Landscape: −90° on the seam.
final class StudyPanelStageCapsule: UIView {
    var onStepTowardAI: (() -> Void)?
    var onStepTowardReading: (() -> Void)?

    private let upButton = UIButton(type: .custom)
    private let downButton = UIButton(type: .custom)
    private let divider = UIView()
    private var axisConstraints: [NSLayoutConstraint] = []
    private(set) var axis: NSLayoutConstraint.Axis = .vertical
    private let buttonHitSlop: CGFloat = 12

    /// When true, the whole capsule hits (nav overlay). When false, only ▲/▼
    /// so the seam doesn't steal highlighter strokes.
    var prefersFullBoundsHitTesting = false

    /// Match input-bar「AI 选项」chip height (`InputBarView.btnSize` = 30).
    /// Width is longer than the model chip so ▲/▼ halves stay easy to hit.
    static let chipHeight: CGFloat = 30
    static let chipWidth: CGFloat = 96

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        clipsToBounds = true
        layer.cornerRadius = Self.chipHeight / 2
        layer.borderWidth = 1 / UIScreen.main.scale
        // No drop shadow — same cost profile as the model chip.
        layer.shadowOpacity = 0

        [upButton, downButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.isExclusiveTouch = true
            addSubview($0)
        }
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.isUserInteractionEnabled = false
        addSubview(divider)

        upButton.addTarget(self, action: #selector(upTapped), for: .touchUpInside)
        downButton.addTarget(self, action: #selector(downTapped), for: .touchUpInside)
        upButton.accessibilityLabel = "展开 AI"
        downButton.accessibilityLabel = "收起 AI"
        upButton.addTarget(self, action: #selector(stageTouchDown(_:)), for: .touchDown)
        downButton.addTarget(self, action: #selector(stageTouchDown(_:)), for: .touchDown)
        upButton.addTarget(self, action: #selector(stageTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        downButton.addTarget(self, action: #selector(stageTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        upButton.setImage(ActionIconFactory.image(.chevronUp, pointSize: 12), for: .normal)
        downButton.setImage(ActionIconFactory.image(.chevronDown, pointSize: 12), for: .normal)
        upButton.connectsSetContentInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        downButton.connectsSetContentInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

        setAxis(.horizontal)
        applyTheme()
        setStage(.collapsed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if prefersFullBoundsHitTesting {
            return bounds.insetBy(dx: -buttonHitSlop, dy: -buttonHitSlop).contains(point)
        }
        // Only the ▲/▼ controls count — divider / padding pass through to highlighter & resize.
        return stageControl(at: point) != nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        if prefersFullBoundsHitTesting {
            guard self.point(inside: point, with: event) else { return nil }
            return stageControl(at: point) ?? self
        }
        return stageControl(at: point)
    }

    /// True when `point` in `view` lands on the stage chip hit target.
    func containsStageControl(at pointInView: CGPoint, in view: UIView) -> Bool {
        let local = convert(pointInView, from: view)
        if prefersFullBoundsHitTesting {
            return bounds.insetBy(dx: -buttonHitSlop, dy: -buttonHitSlop).contains(local)
        }
        return stageControl(at: local) != nil
    }

    private func stageControl(at point: CGPoint) -> UIView? {
        for button in [upButton, downButton] where button.isEnabled && !button.isHidden {
            let p = convert(point, to: button)
            if button.bounds.insetBy(dx: -buttonHitSlop, dy: -buttonHitSlop).contains(p) {
                return button
            }
        }
        return nil
    }

    func setAxis(_ axis: NSLayoutConstraint.Axis) {
        // Chip is always left▲ / right▼ (portrait top bar copied as-is).
        _ = axis
        if !axisConstraints.isEmpty, self.axis == .horizontal { return }
        self.axis = .horizontal
        NSLayoutConstraint.deactivate(axisConstraints)
        axisConstraints.removeAll()
        let hair = 1 / UIScreen.main.scale
        layer.cornerRadius = Self.chipHeight / 2
        axisConstraints = [
            upButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            upButton.topAnchor.constraint(equalTo: topAnchor),
            upButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            upButton.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5),

            downButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            downButton.topAnchor.constraint(equalTo: topAnchor),
            downButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            downButton.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5),

            divider.centerXAnchor.constraint(equalTo: centerXAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            divider.widthAnchor.constraint(equalToConstant: hair)
        ]
        NSLayoutConstraint.activate(axisConstraints)
    }

    func applyTheme() {
        applyTheme(elevated: false)
    }

    /// Matches input-bar model chip (accent wash + hairline). `elevated` kept for API compat.
    func applyTheme(elevated: Bool) {
        _ = elevated
        let c = DSTheme.c
        backgroundColor = c.accent.withAlphaComponent(0.08)
        layer.borderColor = c.accent.withAlphaComponent(0.22).cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowPath = nil
        divider.backgroundColor = c.accent.withAlphaComponent(0.18)
        upButton.tintColor = c.accent
        downButton.tintColor = c.textSecondary
        refreshStageButtonBackgrounds()
    }

    func setStage(_ stage: StudyChatPanelStage) {
        let canUp = stage != .full
        let canDown = stage != .collapsed
        upButton.isEnabled = canUp
        downButton.isEnabled = canDown
        upButton.alpha = canUp ? 1 : 0.32
        downButton.alpha = canDown ? 1 : 0.32
        upButton.isUserInteractionEnabled = canUp
        downButton.isUserInteractionEnabled = canDown
        refreshStageButtonBackgrounds()
    }

    private func refreshStageButtonBackgrounds() {
        let c = DSTheme.c
        upButton.backgroundColor = upButton.isEnabled ? c.accent.withAlphaComponent(0.10) : .clear
        downButton.backgroundColor = downButton.isEnabled ? c.surfaceHover.withAlphaComponent(0.55) : .clear
    }

    @objc private func stageTouchDown(_ sender: UIButton) {
        let c = DSTheme.c
        sender.backgroundColor = sender === upButton
            ? c.accent.withAlphaComponent(0.18)
            : c.textSecondary.withAlphaComponent(0.12)
    }

    @objc private func stageTouchUp(_ sender: UIButton) {
        refreshStageButtonBackgrounds()
    }

    @objc private func upTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onStepTowardAI?()
    }

    @objc private func downTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onStepTowardReading?()
    }
}
